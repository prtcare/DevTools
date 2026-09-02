# Read-DevelopmentControl.ps1
# DevBridge DB-M03 shared read-only workbook library.
# Dot-source this file; it defines read-only accessors over the authoritative
# NEXUS_DEVELOPMENT_CONTROL.xlsx workbook. Nothing in this library writes to the
# workbook or to any Nexus repository. Column letters are resolved dynamically
# from each sheet's header row (normalized matching), so header text (not column
# letters) is the contract.
#
# Usage:
#   . "$PSScriptRoot\Read-DevelopmentControl.ps1"
#   $nodes = Get-AllRoadmapNodes
#   $open  = Get-ActiveChangesOpen
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null

$xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
$xRel = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/officeDocument/2006/relationships"

$script:DevBridgeRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:DevBridgeCfg = Get-Content (Join-Path $script:DevBridgeRoot "config\devbridge.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$script:DevControlMap = Get-Content (Join-Path $script:DevBridgeRoot "config\development-control-map.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$script:DevControlWorkbook = $script:DevBridgeCfg.developmentControlWorkbook

# DB-M12.4 fixture override (tests only): point this read-only library at a temp
# byte-identical workbook copy instead of the authoritative workbook.
if ($env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE) {
    $script:DevControlWorkbook = $env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE
}

if (-not (Test-Path $script:DevControlWorkbook)) {
    throw "Development Control workbook not found: $script:DevControlWorkbook"
}

# ---------------------------------------------------------------------------
# Low-level read helpers
# ---------------------------------------------------------------------------
function Open-DocEntry([string]$entry) {
    # Read-only open of one zip entry as an XDocument. Shares the file with the
    # owning process (Excel) and permits deletion-free read concurrency.
    $fs = [System.IO.File]::Open($script:DevControlWorkbook, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
    $rd = New-Object System.IO.StreamReader($zip.GetEntry($entry).Open())
    $doc = [System.Xml.Linq.XDocument]::Load($rd)
    $rd.Close(); $zip.Dispose(); $fs.Dispose()
    return $doc
}

$script:SheetEntryCache = @{}
function Get-SheetEntryName([string]$sheetName) {
    if ($script:SheetEntryCache.ContainsKey($sheetName)) { return $script:SheetEntryCache[$sheetName] }
    $doc = Open-DocEntry "xl/workbook.xml"
    $targetId = $null
    foreach ($s in $doc.Root.Elements($xNs + "sheets").Elements($xNs + "sheet")) {
        if ([string]$s.Attribute("name").Value -eq $sheetName) { $targetId = [string]$s.Attribute($xRel + "id").Value; break }
    }
    if (-not $targetId) { throw "Sheet not found in workbook.xml: $sheetName" }
    $rels = Open-DocEntry "xl/_rels/workbook.xml.rels"
    $targetPath = $null
    foreach ($rel in $rels.Root.Elements()) {
        if ([string]$rel.Attribute("Id").Value -eq $targetId) { $targetPath = [string]$rel.Attribute("Target").Value; break }
    }
    if (-not $targetPath) { throw "No relationship for sheet $sheetName" }
    if ($targetPath.StartsWith("/")) { $targetPath = $targetPath.TrimStart("/") }
    else { $targetPath = "xl/" + $targetPath }
    if (-not $targetPath.ToLower().EndsWith(".xml")) { $targetPath = $targetPath + ".xml" }
    $script:SheetEntryCache[$sheetName] = $targetPath
    return $targetPath
}

# ---------------------------------------------------------------------------
# Shared-string support (Excel re-save compatibility). Microsoft Excel stores text
# cells as t="s" integer indexes into xl/sharedStrings.xml rather than inline
# <is><t>. The part is loaded lazily and is keyed to the workbook path so an
# override switch (DB_DEV_CONTROL_WORKBOOK_OVERRIDE / With-Workbook) re-reads the
# correct table. Plain <si><t>, rich-text runs (<si><r><t>...), and xml:space
# preserved text are all handled by XElement.Value (identical semantics to the
# inlineStr reader). Invalid references raise an explicit parse/validation error;
# a value is never fabricated.
# ---------------------------------------------------------------------------
$script:SharedStringsState = $null
$script:SharedStringsWorkbook = ""
function Get-SharedStringState {
    if ($null -ne $script:SharedStringsState -and $script:SharedStringsWorkbook -eq $script:DevControlWorkbook) {
        return $script:SharedStringsState
    }
    $fs = [System.IO.File]::Open($script:DevControlWorkbook, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
    $entry = $zip.GetEntry("xl/sharedStrings.xml")
    if ($null -eq $entry) {
        $zip.Dispose(); $fs.Dispose()
        $script:SharedStringsState = @{ Exists = $false; Values = @() }
        $script:SharedStringsWorkbook = $script:DevControlWorkbook
        return $script:SharedStringsState
    }
    $rd = New-Object System.IO.StreamReader($entry.Open())
    $doc = [System.Xml.Linq.XDocument]::Load($rd)
    $rd.Close(); $zip.Dispose(); $fs.Dispose()
    $vals = New-Object System.Collections.Generic.List[string]
    foreach ($si in $doc.Root.Elements($xNs + "si")) {
        $vals.Add([string]$si.Value)
    }
    $script:SharedStringsState = @{ Exists = $true; Values = $vals.ToArray() }
    $script:SharedStringsWorkbook = $script:DevControlWorkbook
    return $script:SharedStringsState
}

function Resolve-SharedString([string]$cellRef, $vEl) {
    $st = Get-SharedStringState
    if (-not $st.Exists) {
        throw ("DevBridge workbook validation error: cell {0} is typed as a shared string ('s') but the workbook has no xl/sharedStrings.xml part." -f $cellRef)
    }
    if ($null -eq $vEl) { return "" }
    $raw = [string]$vEl.Value
    if ($raw -eq "") { return "" }
    $idx = 0
    try { $idx = [int]$raw } catch {
        throw ("DevBridge workbook parse error: cell {0} has non-integer shared-string index '{1}'." -f $cellRef, $raw)
    }
    if ($idx -lt 0 -or $idx -ge $st.Values.Length) {
        throw ("DevBridge workbook validation error: cell {0} references shared-string index {1}, out of range (shared string table holds {2} entr{3})." -f $cellRef, $idx, $st.Values.Length, $(if ($st.Values.Length -eq 1) { "y" } else { "ies" }))
    }
    return $st.Values[$idx]
}

function Get-CellVal($row, [string]$col) {
    foreach ($cell in $row.Elements($xNs + "c")) {
        $refAttr = $cell.Attribute("r")
        if (-not $refAttr) { continue }
        $ref = [string]$refAttr.Value
        if (($ref -replace "[0-9]", "") -eq $col) {
            $tAttr = $cell.Attribute("t"); $t = ""
            if ($tAttr) { $t = [string]$tAttr.Value }
            if ($t -eq "inlineStr") { $is = $cell.Element($xNs + "is"); if ($is) { return [string]$is.Value } }
            if ($t -eq "s") { return (Resolve-SharedString $ref ($cell.Element($xNs + "v"))) }
            $fEl = $cell.Element($xNs + "f")
            if ($fEl) { return "" }   # formula cells: no cached value in this workbook
            $v = $cell.Element($xNs + "v"); if ($v) { return $v.Value }
            return ""
        }
    }
    return ""
}

function Get-RowNumber($row) {
    $ra = $row.Attribute("r")
    if ($ra) { return [int]$ra.Value }
    return 0
}

function Normalize-Header([string]$s) {
    if ($null -eq $s) { return "" }
    return (($s -replace "\s+", "").Trim())
}

$script:ColumnCache = @{}
function Get-ColumnLetters($doc, [int]$headerRow, [string]$cacheKey) {
    # Returns hashtable: NormalizedHeader -> column letter, resolved from headerRow.
    if ($script:ColumnCache.ContainsKey($cacheKey)) { return $script:ColumnCache[$cacheKey] }
    $map = @{}
    foreach ($row in $doc.Root.Elements($xNs + "sheetData").Elements($xNs + "row")) {
        if ((Get-RowNumber $row) -ne $headerRow) { continue }
        foreach ($cell in $row.Elements($xNs + "c")) {
            $refAttr = $cell.Attribute("r"); if (-not $refAttr) { continue }
            $colLetter = ([string]$refAttr.Value) -replace "[0-9]", ""
            $tAttr = $cell.Attribute("t"); $t = ""
            if ($tAttr) { $t = [string]$tAttr.Value }
            $val = ""
            if ($t -eq "inlineStr") { $is = $cell.Element($xNs + "is"); if ($is) { $val = [string]$is.Value } }
            elseif ($t -eq "s") { $val = Resolve-SharedString ([string]$refAttr.Value) ($cell.Element($xNs + "v")) }
            else { $v = $cell.Element($xNs + "v"); if ($v) { $val = $v.Value } }
            if ($val -and $colLetter) { $map[(Normalize-Header $val)] = $colLetter }
        }
        break
    }
    $script:ColumnCache[$cacheKey] = $map
    return $map
}

function Get-ColumnValue($doc, $row, [int]$headerRow, [string]$logicalName, [string]$cacheKey) {
    $cols = Get-ColumnLetters $doc $headerRow $cacheKey
    $col = $cols[(Normalize-Header $logicalName)]
    if (-not $col) { return "" }
    return Get-CellVal $row $col
}

function Get-ColumnForSheet($sheetName, [int]$headerRow, [string]$logicalName) {
    $doc = Open-DocEntry (Get-SheetEntryName $sheetName)
    $cols = Get-ColumnLetters $doc $headerRow (Get-SheetEntryName $sheetName)
    return $cols[(Normalize-Header $logicalName)]
}

# ---------------------------------------------------------------------------
# Shared data row loaders. Each returns an array of PSCustomObject rows.
# A row object exposes: .Sheet, .Row, .Values (hashtable colLetter->value), and
# strongly typed convenience properties where the loader names them.
# ---------------------------------------------------------------------------
function Get-SheetRows([string]$sheetName, [int]$headerRow, [int]$dataStart, [int]$dataEnd) {
    $doc = Open-DocEntry (Get-SheetEntryName $sheetName)
    $cols = Get-ColumnLetters $doc $headerRow (Get-SheetEntryName $sheetName)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($row in $doc.Root.Elements($xNs + "sheetData").Elements($xNs + "row")) {
        $rn = Get-RowNumber $row
        if ($rn -lt $dataStart -or $rn -gt $dataEnd) { continue }
        $vals = @{}
        foreach ($cell in $row.Elements($xNs + "c")) {
            $refAttr = $cell.Attribute("r"); if (-not $refAttr) { continue }
            $colLetter = ([string]$refAttr.Value) -replace "[0-9]", ""
            $tAttr = $cell.Attribute("t"); $t = ""
            if ($tAttr) { $t = [string]$tAttr.Value }
            $val = ""
            if ($t -eq "inlineStr") { $is = $cell.Element($xNs + "is"); if ($is) { $val = [string]$is.Value } }
            elseif ($t -eq "s") { $val = Resolve-SharedString ([string]$refAttr.Value) ($cell.Element($xNs + "v")) }
            else { $fEl = $cell.Element($xNs + "f"); if (-not $fEl) { $v = $cell.Element($xNs + "v"); if ($v) { $val = $v.Value } } }
            $vals[$colLetter] = $val
        }
        $obj = New-Object PSCustomObject
        $obj | Add-Member -MemberType NoteProperty -Name "Sheet" -Value $sheetName
        $obj | Add-Member -MemberType NoteProperty -Name "Row" -Value $rn
        $obj | Add-Member -MemberType NoteProperty -Name "Values" -Value $vals
        $obj | Add-Member -MemberType NoteProperty -Name "Columns" -Value $cols
        $rows.Add($obj)
    }
    return $rows
}

function Get-Value([string]$sheetName, $rowObj, [int]$headerRow, [string]$logicalName) {
    $col = $rowObj.Columns[(Normalize-Header $logicalName)]
    if (-not $col) { return "" }
    return $rowObj.Values[$col]
}

# ---------------------------------------------------------------------------
# Domain accessors (map the logical property names from development-control-map.json)
# ---------------------------------------------------------------------------
function Get-AllRoadmapNodes {
    $map = $script:DevControlMap.sheets | Where-Object { $_.name -eq "Master Roadmap" }
    $rows = Get-SheetRows "Master Roadmap" $map.headerRow $map.dataStartRow $map.governedDataRange.endRow
    $out = New-Object System.Collections.Generic.List[object]
    $headerRow = [int]$map.headerRow
    foreach ($r in $rows) {
        $id = Get-Value "Master Roadmap" $r $headerRow "Node ID"
        $typ = Get-Value "Master Roadmap" $r $headerRow "Node Type"
        if (-not $id -or -not $typ) { continue }
        $node = New-Object PSCustomObject
        $node | Add-Member NoteProperty -Name "Row" -Value $r.Row
        $node | Add-Member NoteProperty -Name "NodeId" -Value $id
        $node | Add-Member NoteProperty -Name "ParentId" -Value (Get-Value "Master Roadmap" $r $headerRow "Parent ID")
        $node | Add-Member NoteProperty -Name "NodeType" -Value $typ
        $node | Add-Member NoteProperty -Name "SortKey" -Value (Get-Value "Master Roadmap" $r $headerRow "Sort Key")
        $node | Add-Member NoteProperty -Name "HierarchyPath" -Value (Get-Value "Master Roadmap" $r $headerRow "Hierarchy Path")
        $node | Add-Member NoteProperty -Name "Layer" -Value (Get-Value "Master Roadmap" $r $headerRow "Layer")
        $node | Add-Member NoteProperty -Name "Phase" -Value (Get-Value "Master Roadmap" $r $headerRow "Phase")
        $node | Add-Member NoteProperty -Name "Name" -Value (Get-Value "Master Roadmap" $r $headerRow "Name")
        $node | Add-Member NoteProperty -Name "OutcomePurpose" -Value (Get-Value "Master Roadmap" $r $headerRow "Outcome / Purpose")
        $node | Add-Member NoteProperty -Name "Dependencies" -Value (Get-Value "Master Roadmap" $r $headerRow "Dependencies")
        $node | Add-Member NoteProperty -Name "ParallelSafe" -Value (Get-Value "Master Roadmap" $r $headerRow "Parallel Safe")
        $node | Add-Member NoteProperty -Name "Projects" -Value (Get-Value "Master Roadmap" $r $headerRow "Projects")
        $node | Add-Member NoteProperty -Name "FilesGlobs" -Value (Get-Value "Master Roadmap" $r $headerRow "Files / Globs")
        $node | Add-Member NoteProperty -Name "SchemaContexts" -Value (Get-Value "Master Roadmap" $r $headerRow "Schema Contexts")
        $node | Add-Member NoteProperty -Name "ContractsApis" -Value (Get-Value "Master Roadmap" $r $headerRow "Contracts / APIs")
        $node | Add-Member NoteProperty -Name "Gate" -Value (Get-Value "Master Roadmap" $r $headerRow "Gate")
        $node | Add-Member NoteProperty -Name "AcceptanceCriteria" -Value (Get-Value "Master Roadmap" $r $headerRow "Acceptance Criteria")
        $node | Add-Member NoteProperty -Name "Status" -Value (Get-Value "Master Roadmap" $r $headerRow "Status")
        $node | Add-Member NoteProperty -Name "BreakdownComplete" -Value (Get-Value "Master Roadmap" $r $headerRow "Breakdown Complete")
        $node | Add-Member NoteProperty -Name "ManualProgress" -Value (Get-Value "Master Roadmap" $r $headerRow "Manual Progress")
        $node | Add-Member NoteProperty -Name "DerivedProgress" -Value (Get-Value "Master Roadmap" $r $headerRow "Derived Progress")
        $node | Add-Member NoteProperty -Name "ReportedProgress" -Value (Get-Value "Master Roadmap" $r $headerRow "Reported Progress")
        $node | Add-Member NoteProperty -Name "Owner" -Value (Get-Value "Master Roadmap" $r $headerRow "Owner")
        $node | Add-Member NoteProperty -Name "Priority" -Value (Get-Value "Master Roadmap" $r $headerRow "Priority")
        $node | Add-Member NoteProperty -Name "Risk" -Value (Get-Value "Master Roadmap" $r $headerRow "Risk")
        $node | Add-Member NoteProperty -Name "Source" -Value (Get-Value "Master Roadmap" $r $headerRow "Source")
        $node | Add-Member NoteProperty -Name "Notes" -Value (Get-Value "Master Roadmap" $r $headerRow "Notes")
        $node | Add-Member NoteProperty -Name "SimpleGoal" -Value (Get-Value "Master Roadmap" $r $headerRow "Simple Goal")
        $node | Add-Member NoteProperty -Name "CurrentEvidence" -Value (Get-Value "Master Roadmap" $r $headerRow "Current Evidence")
        $node | Add-Member NoteProperty -Name "NextAction" -Value (Get-Value "Master Roadmap" $r $headerRow "Next Action")
        $out.Add($node)
    }
    return $out
}

function Get-RoadmapNodeById([string]$nodeId) {
    $all = Get-AllRoadmapNodes
    foreach ($n in $all) { if ($n.NodeId -eq $nodeId) { return $n } }
    return $null
}

function Get-RoadmapNodeByRow([int]$row) {
    $all = Get-AllRoadmapNodes
    foreach ($n in $all) { if ($n.Row -eq $row) { return $n } }
    return $null
}

function Get-AllActiveChanges {
    $map = $script:DevControlMap.sheets | Where-Object { $_.name -eq "Active Changes" }
    # Active Changes real data runs to row 78 (usedRange A1:AD78); read generously.
    $rows = Get-SheetRows "Active Changes" $map.headerRow $map.dataStartRow 100
    $out = New-Object System.Collections.Generic.List[object]
    $headerRow = [int]$map.headerRow
    foreach ($r in $rows) {
        $id = Get-Value "Active Changes" $r $headerRow "Change ID"
        if (-not $id) { continue }
        $status = Get-Value "Active Changes" $r $headerRow "Status"
        $obj = New-Object PSCustomObject
        $obj | Add-Member NoteProperty -Name "Row" -Value $r.Row
        $obj | Add-Member NoteProperty -Name "ChangeId" -Value $id
        $obj | Add-Member NoteProperty -Name "NodeId" -Value (Get-Value "Active Changes" $r $headerRow "Node ID")
        $obj | Add-Member NoteProperty -Name "MilestoneFeature" -Value (Get-Value "Active Changes" $r $headerRow "Milestone / Feature")
        $obj | Add-Member NoteProperty -Name "Summary" -Value (Get-Value "Active Changes" $r $headerRow "Summary")
        $obj | Add-Member NoteProperty -Name "RequestedBy" -Value (Get-Value "Active Changes" $r $headerRow "Requested By")
        $obj | Add-Member NoteProperty -Name "Worker" -Value (Get-Value "Active Changes" $r $headerRow "Worker")
        $obj | Add-Member NoteProperty -Name "Repositories" -Value (Get-Value "Active Changes" $r $headerRow "Repositories")
        $obj | Add-Member NoteProperty -Name "Projects" -Value (Get-Value "Active Changes" $r $headerRow "Projects")
        $obj | Add-Member NoteProperty -Name "FilesGlobs" -Value (Get-Value "Active Changes" $r $headerRow "Files / Globs")
        $obj | Add-Member NoteProperty -Name "SchemaContexts" -Value (Get-Value "Active Changes" $r $headerRow "Schema Contexts")
        $obj | Add-Member NoteProperty -Name "ContractsApis" -Value (Get-Value "Active Changes" $r $headerRow "Contracts / APIs")
        $obj | Add-Member NoteProperty -Name "Status" -Value $status
        $obj | Add-Member NoteProperty -Name "PreflightVerdict" -Value (Get-Value "Active Changes" $r $headerRow "Preflight Verdict")
        $obj | Add-Member NoteProperty -Name "ConflictsWith" -Value (Get-Value "Active Changes" $r $headerRow "Conflicts With")
        $obj | Add-Member NoteProperty -Name "DependencyOn" -Value (Get-Value "Active Changes" $r $headerRow "Dependency On")
        $obj | Add-Member NoteProperty -Name "Risk" -Value (Get-Value "Active Changes" $r $headerRow "Risk")
        $obj | Add-Member NoteProperty -Name "Branch" -Value (Get-Value "Active Changes" $r $headerRow "Branch")
        $obj | Add-Member NoteProperty -Name "Worktree" -Value (Get-Value "Active Changes" $r $headerRow "Worktree")
        $obj | Add-Member NoteProperty -Name "StartedAt" -Value (Get-Value "Active Changes" $r $headerRow "Started At")
        $obj | Add-Member NoteProperty -Name "LastHeartbeat" -Value (Get-Value "Active Changes" $r $headerRow "Last Heartbeat")
        $obj | Add-Member NoteProperty -Name "CompletedAt" -Value (Get-Value "Active Changes" $r $headerRow "Completed At")
        $obj | Add-Member NoteProperty -Name "ResultEvidence" -Value (Get-Value "Active Changes" $r $headerRow "Result / Evidence")
        $obj | Add-Member NoteProperty -Name "ChangeVersion" -Value (Get-Value "Active Changes" $r $headerRow "Change Version")
        $obj | Add-Member NoteProperty -Name "SessionChat" -Value (Get-Value "Active Changes" $r $headerRow "Session / Chat")
        $obj | Add-Member NoteProperty -Name "Notes" -Value (Get-Value "Active Changes" $r $headerRow "Notes")
        $obj | Add-Member NoteProperty -Name "VersionHistoryId" -Value (Get-Value "Active Changes" $r $headerRow "Version History ID")
        $obj | Add-Member NoteProperty -Name "AdrId" -Value (Get-Value "Active Changes" $r $headerRow "ADR ID")
        $obj | Add-Member NoteProperty -Name "AffectedNodes" -Value (Get-Value "Active Changes" $r $headerRow "Affected Nodes")
        $obj | Add-Member NoteProperty -Name "ChangeType" -Value (Get-Value "Active Changes" $r $headerRow "Change Type")
        $obj | Add-Member NoteProperty -Name "ValidationResult" -Value (Get-Value "Active Changes" $r $headerRow "Validation Result")
        # Classification by leading keyword (map unresolved note U-6)
        $cls = "Open"
        $s = ($status -replace "^\s*", "")
        if ($s -match "^(Completed|Cancelled|Closed)") { $cls = "Terminal" }
        elseif ($s -match "^(Blocked)") { $cls = "Blocked" }
        elseif ($s -match "^(In Progress|Active|Started)") { $cls = "InProgress" }
        else { $cls = "Open" }
        $obj | Add-Member NoteProperty -Name "Classification" -Value $cls
        $out.Add($obj)
    }
    return $out
}

function Get-ActiveChangesOpen {
    $all = Get-AllActiveChanges
    return @($all | Where-Object { $_.Classification -ne "Terminal" })
}

function Get-DependencyRelations {
    $map = $script:DevControlMap.sheets | Where-Object { $_.name -eq "Dependencies & Blockers" }
    $rows = Get-SheetRows "Dependencies & Blockers" $map.headerRow $map.dataStartRow 100
    $out = New-Object System.Collections.Generic.List[object]
    $headerRow = [int]$map.headerRow
    foreach ($r in $rows) {
        $id = Get-Value "Dependencies & Blockers" $r $headerRow "Relation ID"
        if (-not $id) { continue }
        $obj = New-Object PSCustomObject
        $obj | Add-Member NoteProperty -Name "Row" -Value $r.Row
        $obj | Add-Member NoteProperty -Name "RelationId" -Value $id
        $obj | Add-Member NoteProperty -Name "FromNode" -Value (Get-Value "Dependencies & Blockers" $r $headerRow "From Node")
        $obj | Add-Member NoteProperty -Name "DependsOnBlocks" -Value (Get-Value "Dependencies & Blockers" $r $headerRow "Depends On / Blocks")
        $obj | Add-Member NoteProperty -Name "RelationType" -Value (Get-Value "Dependencies & Blockers" $r $headerRow "Relation Type")
        $obj | Add-Member NoteProperty -Name "Blocking" -Value (Get-Value "Dependencies & Blockers" $r $headerRow "Blocking?")
        $obj | Add-Member NoteProperty -Name "Status" -Value (Get-Value "Dependencies & Blockers" $r $headerRow "Status")
        $obj | Add-Member NoteProperty -Name "ReasonCondition" -Value (Get-Value "Dependencies & Blockers" $r $headerRow "Reason / Condition")
        $obj | Add-Member NoteProperty -Name "Owner" -Value (Get-Value "Dependencies & Blockers" $r $headerRow "Owner")
        $obj | Add-Member NoteProperty -Name "SourceChange" -Value (Get-Value "Dependencies & Blockers" $r $headerRow "Source Change")
        $obj | Add-Member NoteProperty -Name "Notes" -Value (Get-Value "Dependencies & Blockers" $r $headerRow "Notes")
        $out.Add($obj)
    }
    return $out
}

function Get-AllAdrs {
    $map = $script:DevControlMap.sheets | Where-Object { $_.name -eq "Architecture Decisions" }
    $rows = Get-SheetRows "Architecture Decisions" $map.headerRow $map.dataStartRow 100
    $out = New-Object System.Collections.Generic.List[object]
    $headerRow = [int]$map.headerRow
    foreach ($r in $rows) {
        $id = Get-Value "Architecture Decisions" $r $headerRow "ADR ID"
        if (-not $id) { continue }
        $obj = New-Object PSCustomObject
        $obj | Add-Member NoteProperty -Name "Row" -Value $r.Row
        $obj | Add-Member NoteProperty -Name "AdrId" -Value $id
        $obj | Add-Member NoteProperty -Name "Date" -Value (Get-Value "Architecture Decisions" $r $headerRow "Date")
        $obj | Add-Member NoteProperty -Name "Status" -Value (Get-Value "Architecture Decisions" $r $headerRow "Status")
        $obj | Add-Member NoteProperty -Name "Decision" -Value (Get-Value "Architecture Decisions" $r $headerRow "Decision")
        $obj | Add-Member NoteProperty -Name "LayerOwner" -Value (Get-Value "Architecture Decisions" $r $headerRow "Layer / Owner")
        $obj | Add-Member NoteProperty -Name "RoadmapLinks" -Value (Get-Value "Architecture Decisions" $r $headerRow "Roadmap Links")
        $obj | Add-Member NoteProperty -Name "SupersedesRelated" -Value (Get-Value "Architecture Decisions" $r $headerRow "Supersedes / Related")
        $obj | Add-Member NoteProperty -Name "Reason" -Value (Get-Value "Architecture Decisions" $r $headerRow "Reason")
        $obj | Add-Member NoteProperty -Name "Consequences" -Value (Get-Value "Architecture Decisions" $r $headerRow "Consequences")
        $obj | Add-Member NoteProperty -Name "ChangeId" -Value (Get-Value "Architecture Decisions" $r $headerRow "Change ID")
        $out.Add($obj)
    }
    return $out
}

function Get-ApprovedAdrs {
    return @(Get-AllAdrs | Where-Object { $_.Status -eq "Approved" })
}

function Get-AllOpenDecisions {
    $map = $script:DevControlMap.sheets | Where-Object { $_.name -eq "Open Decisions" }
    $rows = Get-SheetRows "Open Decisions" $map.headerRow $map.dataStartRow 100
    $out = New-Object System.Collections.Generic.List[object]
    $headerRow = [int]$map.headerRow
    foreach ($r in $rows) {
        $id = Get-Value "Open Decisions" $r $headerRow "Decision ID"
        if (-not $id) { continue }
        $obj = New-Object PSCustomObject
        $obj | Add-Member NoteProperty -Name "Row" -Value $r.Row
        $obj | Add-Member NoteProperty -Name "DecisionId" -Value $id
        $obj | Add-Member NoteProperty -Name "RaisedDate" -Value (Get-Value "Open Decisions" $r $headerRow "Raised Date")
        $obj | Add-Member NoteProperty -Name "Area" -Value (Get-Value "Open Decisions" $r $headerRow "Area")
        $obj | Add-Member NoteProperty -Name "Question" -Value (Get-Value "Open Decisions" $r $headerRow "Question / Decision Needed")
        $obj | Add-Member NoteProperty -Name "RoadmapLinks" -Value (Get-Value "Open Decisions" $r $headerRow "Roadmap Links")
        $obj | Add-Member NoteProperty -Name "OptionsConstraints" -Value (Get-Value "Open Decisions" $r $headerRow "Options / Constraints")
        $obj | Add-Member NoteProperty -Name "NeededBefore" -Value (Get-Value "Open Decisions" $r $headerRow "Needed Before")
        $obj | Add-Member NoteProperty -Name "Owner" -Value (Get-Value "Open Decisions" $r $headerRow "Owner")
        $obj | Add-Member NoteProperty -Name "Status" -Value (Get-Value "Open Decisions" $r $headerRow "Status")
        $obj | Add-Member NoteProperty -Name "ResolutionAdr" -Value (Get-Value "Open Decisions" $r $headerRow "Resolution / ADR")
        $out.Add($obj)
    }
    return $out
}

function Get-OpenDecisions {
    return @(Get-AllOpenDecisions | Where-Object { $_.Status -eq "Open" })
}

function Get-AllAuditFindings {
    $map = $script:DevControlMap.sheets | Where-Object { $_.name -eq "Audit Findings" }
    $rows = Get-SheetRows "Audit Findings" $map.headerRow $map.dataStartRow 100
    $out = New-Object System.Collections.Generic.List[object]
    $headerRow = [int]$map.headerRow
    foreach ($r in $rows) {
        $id = Get-Value "Audit Findings" $r $headerRow "Finding ID"
        if (-not $id) { continue }
        $obj = New-Object PSCustomObject
        $obj | Add-Member NoteProperty -Name "Row" -Value $r.Row
        $obj | Add-Member NoteProperty -Name "FindingId" -Value $id
        $obj | Add-Member NoteProperty -Name "Severity" -Value (Get-Value "Audit Findings" $r $headerRow "Severity")
        $obj | Add-Member NoteProperty -Name "Area" -Value (Get-Value "Audit Findings" $r $headerRow "Area")
        $obj | Add-Member NoteProperty -Name "Repository" -Value (Get-Value "Audit Findings" $r $headerRow "Repository")
        $obj | Add-Member NoteProperty -Name "Evidence" -Value (Get-Value "Audit Findings" $r $headerRow "Evidence")
        $obj | Add-Member NoteProperty -Name "Impact" -Value (Get-Value "Audit Findings" $r $headerRow "Impact")
        $obj | Add-Member NoteProperty -Name "RequiredAction" -Value (Get-Value "Audit Findings" $r $headerRow "Required Action")
        $obj | Add-Member NoteProperty -Name "RoadmapLink" -Value (Get-Value "Audit Findings" $r $headerRow "Roadmap Link")
        $obj | Add-Member NoteProperty -Name "Status" -Value (Get-Value "Audit Findings" $r $headerRow "Status")
        $obj | Add-Member NoteProperty -Name "Owner" -Value (Get-Value "Audit Findings" $r $headerRow "Owner")
        $obj | Add-Member NoteProperty -Name "DueGate" -Value (Get-Value "Audit Findings" $r $headerRow "Due Gate")
        $obj | Add-Member NoteProperty -Name "Verification" -Value (Get-Value "Audit Findings" $r $headerRow "Verification")
        $obj | Add-Member NoteProperty -Name "Notes" -Value (Get-Value "Audit Findings" $r $headerRow "Notes")
        $out.Add($obj)
    }
    return $out
}

function Get-PhasePlan {
    $map = $script:DevControlMap.sheets | Where-Object { $_.name -eq "Phase Plan" }
    $rows = Get-SheetRows "Phase Plan" $map.headerRow $map.dataStartRow 100
    $out = New-Object System.Collections.Generic.List[object]
    $headerRow = [int]$map.headerRow
    foreach ($r in $rows) {
        $id = Get-Value "Phase Plan" $r $headerRow "Phase Step"
        if (-not $id) { continue }
        $obj = New-Object PSCustomObject
        $obj | Add-Member NoteProperty -Name "Row" -Value $r.Row
        $obj | Add-Member NoteProperty -Name "PhaseStep" -Value $id
        $obj | Add-Member NoteProperty -Name "LayerArea" -Value (Get-Value "Phase Plan" $r $headerRow "Layer / Area")
        $obj | Add-Member NoteProperty -Name "RoadmapLink" -Value (Get-Value "Phase Plan" $r $headerRow "Roadmap Link")
        $obj | Add-Member NoteProperty -Name "Objective" -Value (Get-Value "Phase Plan" $r $headerRow "Objective")
        $obj | Add-Member NoteProperty -Name "DependsOn" -Value (Get-Value "Phase Plan" $r $headerRow "Depends On")
        $obj | Add-Member NoteProperty -Name "ExitEvidence" -Value (Get-Value "Phase Plan" $r $headerRow "Exit Evidence")
        $obj | Add-Member NoteProperty -Name "Status" -Value (Get-Value "Phase Plan" $r $headerRow "Status")
        $obj | Add-Member NoteProperty -Name "Priority" -Value (Get-Value "Phase Plan" $r $headerRow "Priority")
        $obj | Add-Member NoteProperty -Name "Notes" -Value (Get-Value "Phase Plan" $r $headerRow "Notes")
        $out.Add($obj)
    }
    return $out
}

function Get-ToolRegistry {
    $map = $script:DevControlMap.sheets | Where-Object { $_.name -eq "Tool & Integration Registry" }
    $rows = Get-SheetRows "Tool & Integration Registry" $map.headerRow $map.dataStartRow 100
    $out = New-Object System.Collections.Generic.List[object]
    $headerRow = [int]$map.headerRow
    foreach ($r in $rows) {
        $id = Get-Value "Tool & Integration Registry" $r $headerRow "Tool / Service"
        if (-not $id) { continue }
        $obj = New-Object PSCustomObject
        $obj | Add-Member NoteProperty -Name "Row" -Value $r.Row
        $obj | Add-Member NoteProperty -Name "Tool" -Value $id
        $obj | Add-Member NoteProperty -Name "Category" -Value (Get-Value "Tool & Integration Registry" $r $headerRow "Category")
        $obj | Add-Member NoteProperty -Name "PrimaryPurpose" -Value (Get-Value "Tool & Integration Registry" $r $headerRow "Primary Purpose")
        $obj | Add-Member NoteProperty -Name "OwningLayer" -Value (Get-Value "Tool & Integration Registry" $r $headerRow "Owning Layer")
        $obj | Add-Member NoteProperty -Name "IntegrationMethod" -Value (Get-Value "Tool & Integration Registry" $r $headerRow "Integration Method")
        $obj | Add-Member NoteProperty -Name "CurrentState" -Value (Get-Value "Tool & Integration Registry" $r $headerRow "Current State")
        $obj | Add-Member NoteProperty -Name "Phase1Need" -Value (Get-Value "Tool & Integration Registry" $r $headerRow "Phase 1 Need")
        $obj | Add-Member NoteProperty -Name "ApprovalSafety" -Value (Get-Value "Tool & Integration Registry" $r $headerRow "Approval / Safety")
        $obj | Add-Member NoteProperty -Name "DevChatTarget" -Value (Get-Value "Tool & Integration Registry" $r $headerRow "Developer Chat Target")
        $obj | Add-Member NoteProperty -Name "Notes" -Value (Get-Value "Tool & Integration Registry" $r $headerRow "Notes")
        $out.Add($obj)
    }
    return $out
}

function Get-DevGuide {
    $map = $script:DevControlMap.sheets | Where-Object { $_.name -eq "Development Guide" }
    $rows = Get-SheetRows "Development Guide" $map.headerRow $map.dataStartRow 200
    $out = New-Object System.Collections.Generic.List[object]
    $headerRow = [int]$map.headerRow
    foreach ($r in $rows) {
        $id = Get-Value "Development Guide" $r $headerRow "Milestone ID"
        if (-not $id) { continue }
        $obj = New-Object PSCustomObject
        $obj | Add-Member NoteProperty -Name "Row" -Value $r.Row
        $obj | Add-Member NoteProperty -Name "Phase" -Value (Get-Value "Development Guide" $r $headerRow "Phase")
        $obj | Add-Member NoteProperty -Name "Layer" -Value (Get-Value "Development Guide" $r $headerRow "Layer")
        $obj | Add-Member NoteProperty -Name "MilestoneId" -Value $id
        $obj | Add-Member NoteProperty -Name "Milestone" -Value (Get-Value "Development Guide" $r $headerRow "Milestone")
        $obj | Add-Member NoteProperty -Name "InPlainWords" -Value (Get-Value "Development Guide" $r $headerRow "In Plain Words")
        $obj | Add-Member NoteProperty -Name "Status" -Value (Get-Value "Development Guide" $r $headerRow "Status")
        $obj | Add-Member NoteProperty -Name "ProgressPct" -Value (Get-Value "Development Guide" $r $headerRow "Progress %")
        $obj | Add-Member NoteProperty -Name "WhatExistsNow" -Value (Get-Value "Development Guide" $r $headerRow "What Exists Now")
        $obj | Add-Member NoteProperty -Name "NextStep" -Value (Get-Value "Development Guide" $r $headerRow "Next Step")
        $obj | Add-Member NoteProperty -Name "DependsOn" -Value (Get-Value "Development Guide" $r $headerRow "Depends On")
        $obj | Add-Member NoteProperty -Name "Gate" -Value (Get-Value "Development Guide" $r $headerRow "Gate")
        $out.Add($obj)
    }
    return $out
}

function Get-ExistingAssets {
    $map = $script:DevControlMap.sheets | Where-Object { $_.name -eq "Existing Assets" }
    $rows = Get-SheetRows "Existing Assets" $map.headerRow $map.dataStartRow 100
    $out = New-Object System.Collections.Generic.List[object]
    $headerRow = [int]$map.headerRow
    foreach ($r in $rows) {
        $id = Get-Value "Existing Assets" $r $headerRow "Area"
        if (-not $id) { continue }
        $obj = New-Object PSCustomObject
        $obj | Add-Member NoteProperty -Name "Row" -Value $r.Row
        $obj | Add-Member NoteProperty -Name "Area" -Value $id
        $obj | Add-Member NoteProperty -Name "WhatAlreadyExists" -Value (Get-Value "Existing Assets" $r $headerRow "What Already Exists")
        $obj | Add-Member NoteProperty -Name "RepositoryFiles" -Value (Get-Value "Existing Assets" $r $headerRow "Repository / Files")
        $obj | Add-Member NoteProperty -Name "RoadmapMeaning" -Value (Get-Value "Existing Assets" $r $headerRow "Roadmap Meaning")
        $obj | Add-Member NoteProperty -Name "State" -Value (Get-Value "Existing Assets" $r $headerRow "State")
        $obj | Add-Member NoteProperty -Name "WhatIsStillMissing" -Value (Get-Value "Existing Assets" $r $headerRow "What Is Still Missing")
        $out.Add($obj)
    }
    return $out
}

function Get-SessionProtocolSteps {
    $map = $script:DevControlMap.sheets | Where-Object { $_.name -eq "Session Protocol" }
    $rows = Get-SheetRows "Session Protocol" $map.headerRow 6 24
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $rows) {
        $step = Get-Value "Session Protocol" $r $map.headerRow "Step"
        if (-not $step) { continue }
        $obj = New-Object PSCustomObject
        $obj | Add-Member NoteProperty -Name "Row" -Value $r.Row
        $obj | Add-Member NoteProperty -Name "Step" -Value $step
        $obj | Add-Member NoteProperty -Name "RequiredAction" -Value (Get-Value "Session Protocol" $r $map.headerRow "Required action")
        $obj | Add-Member NoteProperty -Name "EvidenceRecorded" -Value (Get-Value "Session Protocol" $r $map.headerRow "Evidence recorded")
        $obj | Add-Member NoteProperty -Name "StopCondition" -Value (Get-Value "Session Protocol" $r $map.headerRow "Stop condition")
        $out.Add($obj)
    }
    return $out
}

function Get-NodeIdTokens([string]$text) {
    # Extract RoadmapNode ID tokens from free text (F-, M-, WI-, T-, S-, 2-digit layers).
    $tokens = New-Object System.Collections.Generic.List[string]
    if (-not $text) { return $tokens }
    foreach ($m in [regex]::Matches($text, '(F-\d+-\d+|M-\d+-\d+\.\d+|WI-\d+-\d+\.\d+\.\d+|T-\d+-\d+\.\d+\.\d+\.\d+|S-\d+-\d+\.\d+\.\d+\.\d+\.\d+)')) { $tokens.Add($m.Value) }
    foreach ($m in [regex]::Matches($text, '(^|[^0-9])(0\d)([^0-9]|$)')) { $tokens.Add($m.Groups[2].Value) }
    return $tokens
}

function Get-WorkbookSha256 {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($script:DevControlWorkbook)
    try { $hash = $sha.ComputeHash($fs) } finally { $fs.Dispose() }
    return (($hash | ForEach-Object { $_.ToString("X2") }) -join "")
}

$script:DevBridgeLoaded = $true
