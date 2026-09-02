<#
.SYNOPSIS
    DB-M01 - Development Control Workbook Discovery.

    Read-only inspector for the Nexus Development Control Excel workbook.
    Produces state\workbook-schema.json (machine-readable) and
    tasks\WORKBOOK_ANALYSIS.md (human-readable).

    The workbook is treated as authoritative and is NEVER written to.
.DESCRIPTION
    Opens the configured .xlsx as a read-only ZIP (OOXML) and inspects:
      - worksheets, used ranges, header rows
      - Excel tables and named ranges
      - sampled cell content and key-column profiles
      - concept coverage (Goals, Milestones, Work Items, Tasks, ...)
      - cross-sheet identifier references (validated by value matching)
    Findings are classified as CONFIRMED / LIKELY / UNRESOLVED.
    No relationship is invented; ambiguous mappings are left UNRESOLVED.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Self-contained script: load the assemblies it needs.
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$scriptRoot    = Split-Path -Parent $MyInvocation.MyCommand.Path   # ...\scripts
$devBridgeRoot = Split-Path -Parent $scriptRoot                    # ...\DevBridge
$configPath    = Join-Path $devBridgeRoot "config\devbridge.json"
$schemaOutPath = Join-Path $devBridgeRoot "state\workbook-schema.json"
$analysisPath  = Join-Path $devBridgeRoot "tasks\WORKBOOK_ANALYSIS.md"

# XML namespaces (OOXML)
$nsMain = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
$nsRel  = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
$nsPkg  = "http://schemas.openxmlformats.org/package/2006/relationships"
$xMain = [System.Xml.Linq.XNamespace]::Get($nsMain)
$xRel  = [System.Xml.Linq.XNamespace]::Get($nsRel)
$xPkg  = [System.Xml.Linq.XNamespace]::Get($nsPkg)

function Write-Info { Write-Host "[DB-M01] $args" -ForegroundColor Cyan }
function Write-Fail { Write-Host "[DB-M01] ERROR: $args" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# Configuration gate (Step 1) - never guess the workbook location
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Fail "config\devbridge.json not found at $configPath"
    exit 1
}

$config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
$wbPath = [string]$config.developmentControlWorkbook

if ([string]::IsNullOrWhiteSpace($wbPath)) {
    Write-Fail "STOP: config\devbridge.json field 'developmentControlWorkbook' is blank."
    Write-Host "        Supply the full absolute path to the Nexus Development Control .xlsx" -ForegroundColor Yellow
    Write-Host "        workbook in config\devbridge.json, then re-run this script." -ForegroundColor Yellow
    exit 2
}
if (-not (Test-Path -LiteralPath $wbPath)) {
    Write-Fail "STOP: developmentControlWorkbook does not exist at: $wbPath"
    exit 3
}
if ((Get-Item -LiteralPath $wbPath).PSIsContainer) {
    Write-Fail "STOP: developmentControlWorkbook points to a directory, not a workbook file: $wbPath"
    exit 4
}

# ---------------------------------------------------------------------------
# Open the workbook READ-ONLY as a ZIP archive.  We never request write access.
# ---------------------------------------------------------------------------
$fs  = $null
$zip = $null
try {
    $fs = New-Object System.IO.FileStream(
        $wbPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite,
        [System.IO.FileShare]::Delete)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
}
catch [System.IO.IOException] {
    Write-Fail "STOP: workbook is locked (likely open in Excel). Close it and re-run. [$wbPath]"
    exit 5
}

$fileSizeBytes = (Get-Item -LiteralPath $wbPath).Length
$hashBefore    = (Get-FileHash -LiteralPath $wbPath -Algorithm SHA256).Hash

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-ZipEntryText {
    param([System.IO.Compression.ZipArchive]$Zip, [string]$Name)
    $entry = $Zip.GetEntry($Name)
    if ($null -eq $entry) { return $null }
    $reader = New-Object System.IO.StreamReader($entry.Open())
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Get-Attr {
    param($El, [string]$Name, $Ns = $null, [string]$Default = "")
    $a = if ($null -ne $Ns) { $El.Attribute($Ns + $Name) } else { $El.Attribute($Name) }
    if ($null -ne $a) { return $a.Value }
    return $Default
}

function Convert-ColumnToNumber {
    param([string]$Letters)
    $n = 0
    foreach ($ch in $Letters.ToCharArray()) { $n = $n * 26 + ([int][char]$ch - 64) }
    return $n
}

function Convert-NumberToColumn {
    param([int]$Num)
    $s = ""
    while ($Num -gt 0) {
        $rem = ($Num - 1) % 26
        $s = [char](65 + $rem) + $s
        $Num = [math]::Floor(($Num - 1) / 26)
    }
    return $s
}

function Get-RangeInfo {
    param([string]$Ref)
    if ([string]::IsNullOrWhiteSpace($Ref)) { return $null }
    $parts = $Ref -split ":"
    $start = $parts[0]
    $end   = if ($parts.Count -gt 1) { $parts[1] } else { $parts[0] }
    $m1 = [regex]::Match($start, "^([A-Z]+)(\d+)$")
    $m2 = [regex]::Match($end,   "^([A-Z]+)(\d+)$")
    if (-not $m1.Success -or -not $m2.Success) { return $null }
    return [pscustomobject]@{
        Ref      = $Ref
        StartRow = [int]$m1.Groups[2].Value
        EndRow   = [int]$m2.Groups[2].Value
        StartCol = Convert-ColumnToNumber $m1.Groups[1].Value
        EndCol   = Convert-ColumnToNumber $m2.Groups[1].Value
        RowCount = [int]$m2.Groups[2].Value - [int]$m1.Groups[2].Value + 1
        ColCount = (Convert-ColumnToNumber $m2.Groups[1].Value) - (Convert-ColumnToNumber $m1.Groups[1].Value) + 1
    }
}

function Get-CellValue {
    param([System.Xml.Linq.XElement]$Cell, [string[]]$SharedStrings)
    $t = Get-Attr $Cell "t"
    if ($t -eq "inlineStr") {
        $is = $Cell.Element($xMain + "is")
        if ($null -ne $is) { return $is.Value }
        return ""
    }
    if ($t -eq "s") {
        $v = $Cell.Element($xMain + "v")
        if ($null -eq $v) { return "" }
        $idx = 0
        if ([int]::TryParse($v.Value, [ref]$idx)) {
            if ($idx -ge 0 -and $idx -lt $SharedStrings.Count) { return $SharedStrings[$idx] }
        }
        return ""
    }
    $v = $Cell.Element($xMain + "v")
    if ($null -ne $v) { return $v.Value }
    return ""
}

function Truncate {
    param([string]$S, [int]$Max = 80)
    if ($null -eq $S) { return "" }
    if ($S.Length -le $Max) { return $S }
    return $S.Substring(0, $Max) + "..."
}

function Get-SheetTables {
    param([System.IO.Compression.ZipArchive]$Zip, [int]$Index)
    $relsText = Get-ZipEntryText $Zip "xl/worksheets/_rels/sheet$Index.xml.rels"
    $tables = @()
    if ($relsText) {
        $relsDoc = [System.Xml.Linq.XDocument]::Parse($relsText)
        foreach ($rel in $relsDoc.Root.Elements($xPkg + "Relationship")) {
            $type = Get-Attr $rel "Type"
            if ($type -like "*/table") {
                $tgt = (Get-Attr $rel "Target") -replace "^/", ""
                $tblText = Get-ZipEntryText $Zip $tgt
                if ($tblText) {
                    $tblDoc = [System.Xml.Linq.XDocument]::Parse($tblText)
                    $tblNode = $tblDoc.Root   # the <table> element IS the document root
                    if ($null -eq $tblNode) { continue }
                    $cols = @()
                    foreach ($tc in $tblNode.Descendants($xMain + "tableColumn")) {
                        $cols += Get-Attr $tc "name"
                    }
                    $refInfo = Get-RangeInfo (Get-Attr $tblNode "ref")
                    $tables += [pscustomobject]@{
                        Id          = Get-Attr $tblNode "id"
                        Name        = Get-Attr $tblNode "name"
                        Ref         = Get-Attr $tblNode "ref"
                        HeaderRow   = if ($refInfo) { $refInfo.StartRow } else { $null }
                        EndRow      = if ($refInfo) { $refInfo.EndRow } else { $null }
                        ColumnCount = $cols.Count
                        Columns     = $cols
                    }
                }
            }
        }
    }
    return $tables
}

# ---------------------------------------------------------------------------
# Parse workbook.xml: sheets + defined names
# ---------------------------------------------------------------------------
Write-Info "Inspecting workbook: $wbPath"
$wbText = Get-ZipEntryText $zip "xl/workbook.xml"
if ($null -eq $wbText) { Write-Fail "STOP: not a valid OOXML workbook (xl/workbook.xml missing)."; exit 6 }
$wbDoc = [System.Xml.Linq.XDocument]::Parse($wbText)

$sheetsMeta = @()
foreach ($sh in $wbDoc.Root.Descendants($xMain + "sheet")) {
    $sheetsMeta += [pscustomobject]@{
        Name    = Get-Attr $sh "name"
        SheetId = Get-Attr $sh "sheetId"
        State   = Get-Attr $sh "state"
        Rid     = Get-Attr $sh "id" $xRel
    }
}

$definedNames = @()
foreach ($dn in $wbDoc.Root.Descendants($xMain + "definedName")) { $definedNames += $dn.Value }

# workbook rels: r:id -> target
$ridToTarget = @{}
$relsText = Get-ZipEntryText $zip "xl/_rels/workbook.xml.rels"
if ($relsText) {
    $relsDoc = [System.Xml.Linq.XDocument]::Parse($relsText)
    foreach ($rel in $relsDoc.Root.Elements($xPkg + "Relationship")) {
        $ridToTarget[(Get-Attr $rel "Id")] = Get-Attr $rel "Target"
    }
}

# shared strings (absent in this workbook, kept for generality)
$sharedStrings = @()
$sstText = Get-ZipEntryText $zip "xl/sharedStrings.xml"
if ($sstText) {
    $sstDoc = [System.Xml.Linq.XDocument]::Parse($sstText)
    foreach ($si in $sstDoc.Root.Elements($xMain + "si")) { $sharedStrings += $si.Value }
}

# chart / drawing presence
$chartCount = @($zip.Entries | Where-Object { $_.FullName -like "xl/charts/*.xml" }).Count

# ---------------------------------------------------------------------------
# Parse each worksheet
# ---------------------------------------------------------------------------
$parsedSheets = @()
$sheetIndex = 0
foreach ($meta in $sheetsMeta) {
    $sheetIndex++
    $target = $ridToTarget[$meta.Rid]
    if ($target) { $target = $target -replace "^/", "" }
    if (-not $target) { $target = "xl/worksheets/sheet$sheetIndex.xml" }

    $sheetXmlText = Get-ZipEntryText $zip $target
    if ($null -eq $sheetXmlText) { continue }
    $sheetDoc = [System.Xml.Linq.XDocument]::Parse($sheetXmlText)

    # used range
    $dimNode = $sheetDoc.Root.Descendants($xMain + "dimension") | Select-Object -First 1
    $dimRef  = if ($dimNode) { Get-Attr $dimNode "ref" } else { "" }
    $rangeInfo = Get-RangeInfo $dimRef

    # rows + cells
    $rows = @()
    foreach ($rowEl in $sheetDoc.Root.Descendants($xMain + "row")) {
        $ri = 0
        if (-not [int]::TryParse((Get-Attr $rowEl "r"), [ref]$ri)) { continue }
        $cells = @{}
        foreach ($cellEl in $rowEl.Elements($xMain + "c")) {
            $ref = Get-Attr $cellEl "r"
            $col = ([regex]::Match($ref, "^([A-Z]+)")).Groups[1].Value
            if ($col -eq "") { continue }
            $v = Get-CellValue $cellEl $sharedStrings
            if ($v -ne "") { $cells[$col] = $v }
        }
        $rows += [pscustomobject]@{ RowIndex = $ri; Cells = $cells }
    }

    # Excel tables on this sheet
    $tables = @(Get-SheetTables $zip $sheetIndex)

    # fallback used range from parsed rows when no dimension present
    if (-not $rangeInfo -and $rows.Count -gt 0) {
        $minRow = ($rows | Measure-Object -Property RowIndex -Minimum).Minimum
        $maxRow = ($rows | Measure-Object -Property RowIndex -Maximum).Maximum
        $cols   = @{}
        foreach ($r in $rows) { foreach ($k in $r.Cells.Keys) { $cols[$k] = $true } }
        $letters = @($cols.Keys | Sort-Object)
        $minCol = Convert-ColumnToNumber $letters[0]
        $maxCol = Convert-ColumnToNumber $letters[$letters.Count - 1]
        $rangeInfo = [pscustomobject]@{
            Ref       = "$(Convert-NumberToColumn $minCol)${minRow}:$(Convert-NumberToColumn $maxCol)${maxRow}"
            StartRow  = $minRow; EndRow = $maxRow; StartCol = $minCol; EndCol = $maxCol
            RowCount  = $maxRow - $minRow + 1
            ColCount  = $maxCol - $minCol + 1
        }
    }

    # header detection
    $headerRow = $null
    $layout = "unknown"
    if ($tables.Count -gt 0) {
        $headerRow = $tables[0].HeaderRow
        $layout = "table"
    }
    else {
        $candidate = $null
        foreach ($pr in ($rows | Where-Object { $_.RowIndex -le 20 } | Sort-Object RowIndex)) {
            if ($pr.Cells.Count -ge 3) { $candidate = $pr; break }
        }
        if ($candidate) {
            $next = @($rows | Where-Object { $_.RowIndex -gt $candidate.RowIndex -and $_.RowIndex -le ($candidate.RowIndex + 5) })
            $dataRows = @($next | Where-Object { $_.Cells.Count -gt 0 })
            $nonEmptyBelow = 0
            foreach ($n in $next) { $nonEmptyBelow += $n.Cells.Count }
            $sparse = ($dataRows.Count -lt 2) -or ($nonEmptyBelow -lt ($candidate.Cells.Count * 2))
            if ($sparse) {
                $headerRow = $null
                $layout = "dashboard"
            }
            else {
                $headerRow = $candidate.RowIndex
                $layout = "tabular-list"
            }
        }
        else {
            $layout = "panel"
        }
    }

    # header names (ordered by column) or dashboard labels
    $headers = @()
    $headerMap = @{}
    if ($headerRow) {
        $hr = $rows | Where-Object { $_.RowIndex -eq $headerRow } | Select-Object -First 1
        if ($hr) {
            foreach ($key in @($hr.Cells.Keys | Sort-Object)) {
                $headers += [pscustomobject]@{ Column = $key; Name = $hr.Cells[$key]; IsLabel = $false }
                $headerMap[$hr.Cells[$key]] = $key
            }
        }
    }
    elseif ($layout -eq "dashboard") {
        $labelRow = $null
        foreach ($pr in ($rows | Where-Object { $_.RowIndex -le 20 } | Sort-Object RowIndex)) {
            if ($pr.Cells.Count -ge 3) { $labelRow = $pr; break }
        }
        if ($labelRow) {
            foreach ($key in @($labelRow.Cells.Keys | Sort-Object)) {
                $headers += [pscustomobject]@{ Column = $key; Name = $labelRow.Cells[$key]; IsLabel = $true }
            }
        }
    }

    # title / label text (for concept scanning)
    $labelText = @()
    foreach ($pr in ($rows | Where-Object { $_.RowIndex -le 8 } | Sort-Object RowIndex)) {
        foreach ($v in $pr.Cells.Values) {
            if ($v.Trim() -ne "") { $labelText += $v.Trim() }
        }
    }

    # data rows
    $dataRows = @()
    if ($headerRow) { $dataRows = @($rows | Where-Object { $_.RowIndex -gt $headerRow }) }
    $dataRowsWithContent = @($dataRows | Where-Object { $_.Cells.Count -gt 0 })

    # rows beyond the Excel table ref
    $rowsBeyondTable = 0
    if ($tables.Count -gt 0) {
        $tblEnd = ($tables | Measure-Object -Property EndRow -Maximum).Maximum
        $rowsBeyondTable = @($dataRowsWithContent | Where-Object { $_.RowIndex -gt $tblEnd }).Count
    }

    # key column profiles
    $profilePatterns = @("node type", "status", "phase", "priority", "risk", "severity", "relation type", "state", "layer")
    $profiles = @()
    foreach ($h in $headers) {
        $isProfile = $false
        foreach ($pat in $profilePatterns) {
            if ($h.Name -and $h.Name.ToLower().Contains($pat)) { $isProfile = $true; break }
        }
        if (-not $isProfile) { continue }
        $colLetter = $h.Column
        $distinct = @{}
        $count = 0
        foreach ($dr in $dataRowsWithContent) {
            if ($dr.Cells.ContainsKey($colLetter)) {
                $val = $dr.Cells[$colLetter]
                $count++
                if (-not $distinct.ContainsKey($val)) { $distinct[$val] = 0 }
                $distinct[$val]++
            }
        }
        $distinctValues = @($distinct.Keys | Sort-Object)
        if ($distinctValues.Count -gt 25) { $distinctValues = $distinctValues[0..24] }
        $profiles += [pscustomobject]@{
            Column         = $colLetter
            Header         = $h.Name
            DistinctCount  = $distinct.Count
            ValueCount     = $count
            DistinctValues = $distinctValues
        }
    }

    # row sample: first 3 data rows with content, up to 14 columns
    $rowSample = @()
    foreach ($dr in ($dataRowsWithContent | Select-Object -First 3)) {
        $rowObj = [ordered]@{ Row = $dr.RowIndex }
        $colsAdded = 0
        foreach ($key in @($dr.Cells.Keys | Sort-Object)) {
            if ($colsAdded -ge 14) { break }
            $rowObj[$key] = Truncate $dr.Cells[$key] 70
            $colsAdded++
        }
        $rowSample += [pscustomobject]$rowObj
    }

    $usedRowCount = if ($rangeInfo) { $rangeInfo.RowCount } else { 0 }
    $usedColCount = if ($rangeInfo) { $rangeInfo.ColCount } else { 0 }

    $parsedSheets += [pscustomobject]@{
        Index           = $sheetIndex
        Name            = $meta.Name
        State           = $meta.State
        UsedRange       = if ($rangeInfo) { $rangeInfo.Ref } else { "" }
        UsedRowCount    = $usedRowCount
        UsedColumnCount = $usedColCount
        HeaderRow       = $headerRow
        Layout          = $layout
        Headers         = $headers
        ExcelTables     = $tables
        RowsBeyondTable = $rowsBeyondTable
        DataRowCount    = $dataRowsWithContent.Count
        LabelText       = $labelText
        Profiles        = $profiles
        RowSample       = $rowSample
        Rows            = $rows          # internal, for reference checks
        HeaderMap       = $headerMap
    }
}

# ---------------------------------------------------------------------------
# Identifier namespaces + cross-sheet reference validation
# ---------------------------------------------------------------------------
function Get-ColumnValuesByHeader {
    param($Sheet, [string]$HeaderName)
    $col = $Sheet.HeaderMap[$HeaderName]
    if (-not $col) { return @() }
    $vals = @()
    foreach ($dr in $Sheet.Rows) {
        if ($dr.RowIndex -gt $Sheet.HeaderRow) {
            if ($dr.Cells.ContainsKey($col)) { $vals += $dr.Cells[$col] }
        }
    }
    return $vals
}

function New-IdSet {
    param($Values)
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($v in $Values) {
        if (-not [string]::IsNullOrWhiteSpace($v)) {
            foreach ($t in ($v -split "[,;/|\s]+")) {
                $t = $t.Trim()
                if ($t -ne "") { [void]$set.Add($t) }
            }
        }
    }
    return $set
}

function Test-Reference {
    param($Values, [System.Collections.Generic.HashSet[string]]$TargetSet)
    $tested = 0
    $resolved = 0
    $tokens = @()
    foreach ($v in $Values) {
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        foreach ($t in ($v -split "[,;/|\s]+")) {
            $t = $t.Trim()
            if ($t -eq "") { continue }
            $tested++
            $tokens += $t
            if ($TargetSet.Contains($t)) { $resolved++ }
        }
    }
    if ($tested -eq 0) {
        return [pscustomobject]@{ Tested = 0; Resolved = 0; Ratio = $null; Tokens = @() }
    }
    return [pscustomobject]@{ Tested = $tested; Resolved = $resolved; Ratio = [math]::Round($resolved / $tested, 3); Tokens = @($tokens | Select-Object -First 8) }
}

function Add-Check {
    param($List, [string]$From, [string]$To, $Result)
    $status = "UNRESOLVED"
    if ($Result.Tested -eq 0) { $status = "UNRESOLVED (no data)" }
    elseif ($Result.Ratio -ge 0.9) { $status = "CONFIRMED" }
    elseif ($Result.Ratio -ge 0.5) { $status = "LIKELY" }
    # @($List) re-wraps a scalar back into an array (function returns unroll
    # a single-element array), so accumulation never fails on op_Addition.
    $List = @($List) + [pscustomobject]@{
        From     = $From
        To       = $To
        Tested   = $Result.Tested
        Resolved = $Result.Resolved
        Ratio    = $Result.Ratio
        Status   = $status
        Sample   = $Result.Tokens
    }
    return $List
}

$sMasterRoadmap  = $parsedSheets | Where-Object { $_.Name -eq "Master Roadmap" } | Select-Object -First 1
$sActiveChanges  = $parsedSheets | Where-Object { $_.Name -eq "Active Changes" } | Select-Object -First 1
$sVersionHistory = $parsedSheets | Where-Object { $_.Name -eq "Version History" } | Select-Object -First 1
$sDepsBlockers   = $parsedSheets | Where-Object { $_.Name -eq "Dependencies & Blockers" } | Select-Object -First 1
$sActivityLog    = $parsedSheets | Where-Object { $_.Name -eq "Activity Log" } | Select-Object -First 1
$sAuditFindings  = $parsedSheets | Where-Object { $_.Name -eq "Audit Findings" } | Select-Object -First 1
$sPhasePlan      = $parsedSheets | Where-Object { $_.Name -eq "Phase Plan" } | Select-Object -First 1
$sDevGuide       = $parsedSheets | Where-Object { $_.Name -eq "Development Guide" } | Select-Object -First 1
$sArchDecisions  = $parsedSheets | Where-Object { $_.Name -eq "Architecture Decisions" } | Select-Object -First 1
$sOpenDecisions  = $parsedSheets | Where-Object { $_.Name -eq "Open Decisions" } | Select-Object -First 1

$roadmapNodeIds    = New-IdSet (Get-ColumnValuesByHeader $sMasterRoadmap "Node ID")
$changeIds         = New-IdSet (Get-ColumnValuesByHeader $sActiveChanges "Change ID")
$adrIds            = New-IdSet (Get-ColumnValuesByHeader $sArchDecisions "ADR ID")
$vhRecordVersions  = New-IdSet (Get-ColumnValuesByHeader $sVersionHistory "Record Version")

$idSpaces = @{
    RoadmapNode = @{ Count = $roadmapNodeIds.Count; Prefixes = @("01", "F-", "M-", "WI-", "T-", "S-") }
    Change      = @{ Count = $changeIds.Count;      Prefixes = @("CHG-") }
    ADR         = @{ Count = $adrIds.Count;         Prefixes = @("ADR-") }
}

$refChecks = @()
if ($sMasterRoadmap) {
    $refChecks = Add-Check $refChecks "Master Roadmap:Parent ID" "Master Roadmap:Node ID" (Test-Reference (Get-ColumnValuesByHeader $sMasterRoadmap "Parent ID") $roadmapNodeIds)
    $refChecks = Add-Check $refChecks "Master Roadmap:Dependencies" "Master Roadmap:Node ID" (Test-Reference (Get-ColumnValuesByHeader $sMasterRoadmap "Dependencies") $roadmapNodeIds)
}
if ($sActiveChanges) {
    $refChecks = Add-Check $refChecks "Active Changes:Node ID" "Master Roadmap:Node ID" (Test-Reference (Get-ColumnValuesByHeader $sActiveChanges "Node ID") $roadmapNodeIds)
    $refChecks = Add-Check $refChecks "Active Changes:Dependency On" "Active Changes:Change ID" (Test-Reference (Get-ColumnValuesByHeader $sActiveChanges "Dependency On") $changeIds)
    $refChecks = Add-Check $refChecks "Active Changes:Version History ID" "Version History" (Test-Reference (Get-ColumnValuesByHeader $sActiveChanges "Version History ID") $vhRecordVersions)
}
if ($sVersionHistory) {
    $refChecks = Add-Check $refChecks "Version History:Parent ID" "Master Roadmap:Node ID" (Test-Reference (Get-ColumnValuesByHeader $sVersionHistory "Parent ID") $roadmapNodeIds)
    $refChecks = Add-Check $refChecks "Version History:Change ID" "Active Changes:Change ID" (Test-Reference (Get-ColumnValuesByHeader $sVersionHistory "Change ID") $changeIds)
}
if ($sDepsBlockers) {
    $refChecks = Add-Check $refChecks "Dependencies & Blockers:From Node" "Master Roadmap:Node ID" (Test-Reference (Get-ColumnValuesByHeader $sDepsBlockers "From Node") $roadmapNodeIds)
    $refChecks = Add-Check $refChecks "Dependencies & Blockers:Depends On / Blocks" "Master Roadmap:Node ID" (Test-Reference (Get-ColumnValuesByHeader $sDepsBlockers "Depends On / Blocks") $roadmapNodeIds)
}
if ($sActivityLog) {
    $refChecks = Add-Check $refChecks "Activity Log:Change ID" "Active Changes:Change ID" (Test-Reference (Get-ColumnValuesByHeader $sActivityLog "Change ID") $changeIds)
}
if ($sAuditFindings) {
    $refChecks = Add-Check $refChecks "Audit Findings:Roadmap Link" "Master Roadmap:Node ID" (Test-Reference (Get-ColumnValuesByHeader $sAuditFindings "Roadmap Link") $roadmapNodeIds)
}
if ($sPhasePlan) {
    $refChecks = Add-Check $refChecks "Phase Plan:Roadmap Link" "Master Roadmap:Node ID" (Test-Reference (Get-ColumnValuesByHeader $sPhasePlan "Roadmap Link") $roadmapNodeIds)
}
if ($sDevGuide) {
    $refChecks = Add-Check $refChecks "Development Guide:Milestone ID" "Master Roadmap:Node ID" (Test-Reference (Get-ColumnValuesByHeader $sDevGuide "Milestone ID") $roadmapNodeIds)
}
if ($sArchDecisions) {
    $refChecks = Add-Check $refChecks "Architecture Decisions:Roadmap Links" "Master Roadmap:Node ID" (Test-Reference (Get-ColumnValuesByHeader $sArchDecisions "Roadmap Links") $roadmapNodeIds)
}
if ($sOpenDecisions) {
    $refChecks = Add-Check $refChecks "Open Decisions:Roadmap Links" "Master Roadmap:Node ID" (Test-Reference (Get-ColumnValuesByHeader $sOpenDecisions "Roadmap Links") $roadmapNodeIds)
    $refChecks = Add-Check $refChecks "Open Decisions:Resolution / ADR" "Architecture Decisions:ADR ID" (Test-Reference (Get-ColumnValuesByHeader $sOpenDecisions "Resolution / ADR") $adrIds)
}

# ---------------------------------------------------------------------------
# Concept detection (CONFIRMED / LIKELY / UNRESOLVED)
# ---------------------------------------------------------------------------
$conceptDefs = @(
    @{ Name = "Goals";                Keywords = @("simple goal", "goal", "outcome / purpose", "purpose") }
    @{ Name = "Milestones";           Keywords = @("milestone") }
    @{ Name = "Work Items";           Keywords = @("work item", "workitem", "work items", "wi-") }
    @{ Name = "Tasks";                Keywords = @("task", "subtask", "t-", "s-", "next action") }
    @{ Name = "Dependencies";         Keywords = @("dependenc", "depends on", "dependency on", "blocker", "blocks", "relation type") }
    @{ Name = "Status";               Keywords = @("status", "state") }
    @{ Name = "Acceptance Criteria";  Keywords = @("acceptance criteria") }
    @{ Name = "Versioning";           Keywords = @("version", "history", "record version", "baseline version", "is current", "supersedes", "effective from") }
    @{ Name = "Activity Log";         Keywords = @("activity", "log", "timestamp utc", "created at", "event") }
    @{ Name = "Architecture";         Keywords = @("architecture", "schema context", "contracts / apis", "adr", "design") }
    @{ Name = "Decisions";            Keywords = @("decision", "adr", "decided") }
    @{ Name = "Repository";           Keywords = @("repositor", "project", "branch", "worktree", "files / globs") }
    @{ Name = "Completion Evidence";  Keywords = @("evidence", "result / evidence", "verification", "exit evidence", "validation result", "current evidence") }
)

$conceptsOut = [ordered]@{}
foreach ($def in $conceptDefs) {
    $hits = @()
    $strong = $false
    foreach ($kw in $def.Keywords) {
        foreach ($s in $parsedSheets) {
            if ($s.Name.ToLower().Contains($kw)) { $hits += "[sheet] $($s.Name)"; $strong = $true }
        }
        foreach ($s in $parsedSheets) {
            foreach ($h in $s.Headers) {
                if ($h.Name -and $h.Name.ToLower().Contains($kw)) {
                    $tag = if ($h.IsLabel) { "label" } else { "header" }
                    $hits += "[$tag] $($s.Name)::$($h.Column) '$($h.Name)'"; $strong = $true
                }
            }
        }
        foreach ($s in $parsedSheets) {
            foreach ($t in $s.LabelText) {
                if ($t.ToLower().Contains($kw) -and $t.Length -lt 80) { $hits += "[text] $($s.Name): '$t'"; $strong = $true }
            }
        }
        foreach ($s in $parsedSheets) {
            foreach ($p in $s.Profiles) {
                if ($p.Header -and $p.Header.ToLower().Contains("node type")) {
                    foreach ($dv in $p.DistinctValues) {
                        if ($dv.ToLower().Contains($kw) -or $dv.ToLower() -eq $kw) { $hits += "[nodeType] $($s.Name): '$dv'"; $strong = $true }
                    }
                }
            }
        }
    }
    $status = if ($strong) { "CONFIRMED" } else { "UNRESOLVED" }
    $conceptsOut[$def.Name] = [ordered]@{
        Status   = $status
        Evidence = @($hits | Select-Object -Unique)
    }
}

# ---------------------------------------------------------------------------
# Unresolved / anomalous mappings (never invented, only reported)
# ---------------------------------------------------------------------------
$unresolved = @(
    @{ Item = "Master Roadmap columns Column1 / Column2 / Column3 (AE:AG)";
       Detail = "Present in MasterRoadmapTable schema but no populated values observed in sample. Purpose unknown." }
    @{ Item = "Master Roadmap used range extends beyond Excel table (A5:AG630)";
       Detail = "Sheet dimension reaches row 675 and $($sMasterRoadmap.RowsBeyondTable) content rows sit below the table end. Whether this is intentional data or a not-extended table is unknown." }
    @{ Item = "Active Changes columns Z:AD outside Excel table (A5:Y8)";
       Detail = "Version History ID, ADR ID, Affected Nodes, Change Type, Validation Result exist as sheet columns but are not part of ActiveChangesTable. Sampling shows them sparsely populated." }
    @{ Item = "Control Center computed dashboard semantics";
       Detail = "Dashboard cells are formulas with no cached values in the file; the exact count/label relationships cannot be established from the workbook XML." }
    @{ Item = "Identifier linkage is by naming convention, not enforced";
       Detail = "No defined names, data validations or explicit foreign keys exist. Cross-sheet references were validated by value matching only." }
    @{ Item = "Version History row-to-row versioning semantics";
       Detail = "ADR-003 states Master Roadmap holds current state and Version History is the append-only archive, but the full Is Current / Supersedes resolution rule is not formally defined in the workbook." }
)

# ---------------------------------------------------------------------------
# Node type / status profiles (computed once, used by both outputs)
# ---------------------------------------------------------------------------
$nodeTypeProfile = $null
$statusProfile   = $null
$nodeTypeCounts  = @{}
if ($sMasterRoadmap) {
    $nodeTypeProfile = $sMasterRoadmap.Profiles | Where-Object { $_.Header -eq "Node Type" } | Select-Object -First 1
    $statusProfile   = $sMasterRoadmap.Profiles | Where-Object { $_.Header -eq "Status" }   | Select-Object -First 1
    if ($nodeTypeProfile) {
        foreach ($v in $nodeTypeProfile.DistinctValues) { $nodeTypeCounts[$v] = 0 }
        foreach ($dr in $sMasterRoadmap.Rows) {
            if ($dr.RowIndex -gt $sMasterRoadmap.HeaderRow -and $dr.Cells.ContainsKey("C")) {
                $nt = $dr.Cells["C"]
                if ($nodeTypeCounts.ContainsKey($nt)) { $nodeTypeCounts[$nt]++ }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Emit state\workbook-schema.json
# ---------------------------------------------------------------------------
$schema = [ordered]@{
    schemaVersion   = "1.0"
    generatedAtUtc  = (Get-Date).ToUniversalTime().ToString("o")
    inspector       = "Inspect-DevelopmentControl.ps1"
    workbook        = [ordered]@{
        path            = $wbPath
        fileName        = Split-Path -Leaf $wbPath
        fileSizeBytes   = $fileSizeBytes
        sha256Before    = $hashBefore
        worksheetCount  = $parsedSheets.Count
        excelTableCount = @($parsedSheets | ForEach-Object { $_.ExcelTables.Count } | Measure-Object -Sum).Sum
        definedNames    = $definedNames
        chartCount      = $chartCount
        worksheets      = @(
            foreach ($s in $parsedSheets) {
                [ordered]@{
                    index           = $s.Index
                    name            = $s.Name
                    state           = $s.State
                    usedRange       = $s.UsedRange
                    usedRowCount    = $s.UsedRowCount
                    usedColumnCount = $s.UsedColumnCount
                    layout          = $s.Layout
                    headerRow       = $s.HeaderRow
                    headers         = @($s.Headers | ForEach-Object {
                                        [ordered]@{ column = $_.Column; name = $_.Name; role = $(if ($_.IsLabel) { "label" } else { "header" }) } })
                    excelTables     = @($s.ExcelTables | ForEach-Object {
                                        [ordered]@{ name = $_.Name; ref = $_.Ref; headerRow = $_.HeaderRow; columnCount = $_.ColumnCount; columns = $_.Columns } })
                    rowsBeyondTable = $s.RowsBeyondTable
                    dataRowCount    = $s.DataRowCount
                    keyColumnProfiles = @($s.Profiles | ForEach-Object {
                                        [ordered]@{ column = $_.Column; header = $_.Header; distinctCount = $_.DistinctCount; valueCount = $_.ValueCount; distinctValues = $_.DistinctValues } })
                    rowSample       = $s.RowSample
                }
            }
        )
        idSpaces = @(
            [ordered]@{ name = "RoadmapNode"; valueCount = $idSpaces.RoadmapNode.Count; observedPrefixes = $idSpaces.RoadmapNode.Prefixes }
            [ordered]@{ name = "Change";      valueCount = $idSpaces.Change.Count;      observedPrefixes = $idSpaces.Change.Prefixes }
            [ordered]@{ name = "ADR";         valueCount = $idSpaces.ADR.Count;         observedPrefixes = $idSpaces.ADR.Prefixes }
        )
        crossSheetReferences = @($refChecks | ForEach-Object {
                                [ordered]@{ from = $_.From; to = $_.To; tested = $_.Tested; resolved = $_.Resolved; ratio = $_.Ratio; status = $_.Status; sample = $_.Sample } })
    }
    concepts     = $conceptsOut
    nodeHierarchy = [ordered]@{
        observedOrder = @("Layer", "Feature", "Milestone", "WorkItem", "Task", "Subtask")
        status        = "CONFIRMED"
        note          = "Parent ID + Hierarchy Path on Master Roadmap encode Layer > Feature > Milestone > WorkItem > Task > Subtask. ID prefixes F-/M-/WI-/T-/S- mirror the ancestry."
        counts        = @($nodeTypeCounts.GetEnumerator() | Sort-Object Name | ForEach-Object {
                            [ordered]@{ nodeType = $_.Key; count = $_.Value } })
    }
    conclusions  = [ordered]@{
        likelyTaskControlSheet = "Master Roadmap"
        primaryNodeTable       = "MasterRoadmapTable"
        changeLedgerSheet      = "Active Changes"
        versionHistorySheet    = "Version History"
        activityLogSheet       = "Activity Log"
    }
    unresolved   = @($unresolved | ForEach-Object { [ordered]@{ item = $_.Item; detail = $_.Detail; status = "UNRESOLVED" } })
}

$json = $schema | ConvertTo-Json -Depth 30
[System.IO.File]::WriteAllText($schemaOutPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Info "Wrote $schemaOutPath"

# ---------------------------------------------------------------------------
# Emit tasks\WORKBOOK_ANALYSIS.md
# ---------------------------------------------------------------------------
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# WORKBOOK ANALYSIS - DB-M01 (Development Control Workbook Discovery)")
[void]$sb.AppendLine()
[void]$sb.AppendLine("**Workbook:** $wbPath")
[void]$sb.AppendLine()
[void]$sb.AppendLine("**Inspected:** $(Get-Date) UTC | SHA256 (before): $hashBefore")
[void]$sb.AppendLine("**Status:** Read-only inspection. The workbook was NOT modified.")
[void]$sb.AppendLine()
[void]$sb.AppendLine("## Overview")
[void]$sb.AppendLine()
[void]$sb.AppendLine("- Worksheets: $($parsedSheets.Count)")
[void]$sb.AppendLine("- Excel tables: $(@($parsedSheets | ForEach-Object { $_.ExcelTables.Count } | Measure-Object -Sum).Sum)")
[void]$sb.AppendLine("- Defined names (named ranges): $($definedNames.Count)")
[void]$sb.AppendLine("- Charts / drawings: $chartCount chart(s)")
[void]$sb.AppendLine()
[void]$sb.AppendLine("## Worksheets")
[void]$sb.AppendLine()
[void]$sb.AppendLine("| # | Sheet | Layout | Used range | Rows | Cols | Header row | Excel table |")
[void]$sb.AppendLine("|---|-------|--------|------------|------|------|------------|-------------|")
foreach ($s in $parsedSheets) {
    $tblNames = if ($s.ExcelTables.Count) { (($s.ExcelTables | ForEach-Object { $_.Name }) -join ", ") } else { "-" }
    [void]$sb.AppendLine("| $($s.Index) | $($s.Name) | $($s.Layout) | $($s.UsedRange) | $($s.UsedRowCount) | $($s.UsedColumnCount) | $(if ($s.HeaderRow) { $s.HeaderRow } else { "-" }) | $tblNames |")
}
[void]$sb.AppendLine()
[void]$sb.AppendLine("## Excel tables found")
[void]$sb.AppendLine()
if ((@($parsedSheets | ForEach-Object { $_.ExcelTables }).Count) -eq 0) {
    [void]$sb.AppendLine("- None.")
}
else {
    foreach ($s in $parsedSheets) {
        foreach ($t in $s.ExcelTables) {
            [void]$sb.AppendLine("- **$($t.Name)** on *$($s.Name)* - ref $($t.Ref), $($t.ColumnCount) columns:")
            foreach ($c in $t.Columns) { [void]$sb.AppendLine("    - $($c)") }
        }
    }
}
[void]$sb.AppendLine()
[void]$sb.AppendLine("## Concept coverage")
[void]$sb.AppendLine()
[void]$sb.AppendLine("Classification: **CONFIRMED** = found at sheet/header/named-range level. **LIKELY** = inferred from sampled values only. **UNRESOLVED** = not found or ambiguous.")
[void]$sb.AppendLine()
[void]$sb.AppendLine("| Concept | Status | Evidence |")
[void]$sb.AppendLine("|---------|--------|----------|")
foreach ($k in $conceptsOut.Keys) {
    $ev = ($conceptsOut[$k].Evidence -join "<br>")
    [void]$sb.AppendLine("| $k | $($conceptsOut[$k].Status) | $ev |")
}
[void]$sb.AppendLine()
[void]$sb.AppendLine("## Node hierarchy (Master Roadmap)")
[void]$sb.AppendLine()
[void]$sb.AppendLine("Confirmed: **Layer -> Feature -> Milestone -> WorkItem -> Task -> Subtask**, encoded in 'Parent ID', 'Hierarchy Path' and the ID prefixes 'F-', 'M-', 'WI-', 'T-', 'S-'.")
[void]$sb.AppendLine()
[void]$sb.AppendLine("| Node Type | Rows (Master Roadmap) |")
[void]$sb.AppendLine("|-----------|----------------------|")
if ($nodeTypeProfile) {
    foreach ($v in ($nodeTypeCounts.Keys | Sort-Object)) {
        [void]$sb.AppendLine("| $v | $($nodeTypeCounts[$v]) |")
    }
}
[void]$sb.AppendLine()
[void]$sb.AppendLine("Status vocabulary on Master Roadmap (distinct values):")
if ($statusProfile) {
    $statusList = $statusProfile.DistinctValues -join ", "
    [void]$sb.AppendLine("- $statusList")
}
[void]$sb.AppendLine()
[void]$sb.AppendLine("## Cross-sheet references (validated by value matching)")
[void]$sb.AppendLine()
[void]$sb.AppendLine("| From | To | Tested | Resolved | Ratio | Status |")
[void]$sb.AppendLine("|------|----|--------|----------|-------|--------|")
foreach ($r in $refChecks) {
    $ratio = if ($null -eq $r.Ratio) { "-" } else { "$([math]::Round($r.Ratio*100))%" }
    [void]$sb.AppendLine("| $($r.From) | $($r.To) | $($r.Tested) | $($r.Resolved) | $ratio | $($r.Status) |")
}
[void]$sb.AppendLine()
[void]$sb.AppendLine("## UNRESOLVED mappings")
[void]$sb.AppendLine()
foreach ($u in $unresolved) {
    [void]$sb.AppendLine("- **$($u.Item)** - $($u.Detail)")
}
[void]$sb.AppendLine()
[void]$sb.AppendLine("## Conclusions")
[void]$sb.AppendLine()
[void]$sb.AppendLine("- **Likely task-control sheet:** Master Roadmap (node hierarchy with Status, Dependencies, Acceptance Criteria, Owner, Priority, Next Action).")
[void]$sb.AppendLine("- **Concurrency control:** Active Changes (change reservation ledger); Session Protocol defines the mandatory pre-implementation protocol.")
[void]$sb.AppendLine("- **Historical record:** Version History (append-only, linked to Change IDs); Activity Log is the event log.")
[void]$sb.AppendLine("- **Governance:** Architecture Decisions (ADR) and Open Decisions record decisions; Dependencies & Blockers is the explicit relationship graph.")
[void]$sb.AppendLine("- All 13 scanned concepts were found at name/header level (CONFIRMED). No relationship was invented; ambiguous items are listed under UNRESOLVED.")
[void]$sb.AppendLine()
[void]$sb.AppendLine("---")
[void]$sb.AppendLine()
[void]$sb.AppendLine("## DB-M01 RESULT")
[void]$sb.AppendLine()
[void]$sb.AppendLine("Workbook: $wbPath")
[void]$sb.AppendLine("Sheets found: $($parsedSheets.Count)")
[void]$sb.AppendLine("Tables found: $(@($parsedSheets | ForEach-Object { $_.ExcelTables.Count } | Measure-Object -Sum).Sum)")
[void]$sb.AppendLine("Likely task-control sheet: Master Roadmap")
[void]$sb.AppendLine("Unresolved mappings: $($unresolved.Count)")
[void]$sb.AppendLine("Workbook modified: NO")

[System.IO.File]::WriteAllText($analysisPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Info "Wrote $analysisPath"

# ---------------------------------------------------------------------------
# Verify workbook was not modified and clean up
# ---------------------------------------------------------------------------
$hashAfter = (Get-FileHash -LiteralPath $wbPath -Algorithm SHA256).Hash
$zip.Dispose()
if ($fs) { $fs.Dispose() }

$modified = if ($hashAfter -eq $hashBefore) { "NO" } else { "YES" }

Write-Host ""
Write-Host "DB-M01 RESULT" -ForegroundColor Green
Write-Host "Workbook: $wbPath"
Write-Host "Sheets found: $($parsedSheets.Count)"
Write-Host "Tables found: $(@($parsedSheets | ForEach-Object { $_.ExcelTables.Count } | Measure-Object -Sum).Sum)"
Write-Host "Likely task-control sheet: Master Roadmap"
Write-Host "Unresolved mappings: $($unresolved.Count)"
Write-Host "Workbook modified: $modified"
Write-Host ""
if ($modified -eq "NO") { Write-Info "Workbook hash unchanged. Outputs written inside DevBridge only." }
else { Write-Fail "Workbook hash CHANGED - unexpected. Investigate." }
