# Close-TrialCycle.ps1 - DB-M12.4 governed TRIAL cycle closure (CLOSE_TRIAL_CYCLE).
#
# Closes a TRIAL-mode proving cycle that has reached its governed safe stop and
# releases the trial reservation, preserving every piece of trial evidence and the
# historical truth:
#
#   CLAUDE_REVIEW_PASSED_TRIAL / TRIAL_CYCLE_SAFE_STOP  ->  TRIAL_CYCLE_CLOSED
#
# What closure does:
#   * marks the Active Changes reservation row with a Terminal "Closed" status
#     (distinct from Completed/Cancelled; the roadmap node is NOT completed);
#   * appends one Activity Log row (Operation "Governed Trial Cycle Closure");
#   * records state/trial-closure.json + appends to state/trial-proving-history.json
#     (consumed by DB-M03 so a fresh proving cycle never re-selects the same item);
#   * writes tasks/TRIAL_CYCLE_CLOSURE_REPORT.md;
#   * transitions current-task.json to TRIAL_CYCLE_CLOSED / START_NEXT_CYCLE.
#
# Closure NEVER runs M10, NEVER produces COMPLETED / MERGED /
# READY_FOR_GOVERNED_COMPLETION / M10_COMPLETE, NEVER creates a PR, NEVER merges,
# and NEVER mutates roadmap structure. The protected roadmap fingerprint must be
# byte-identical before and after.
#
# Pre-reservation execution status is proven from the recorded M04 reservation
# backup workbook (reservationEvidence.backupSha256 must match). If the backup is
# missing/unreadable, its SHA mismatches, or the node is absent from it, the script
# STOPS with TRIAL_PRE_RESERVATION_STATE_UNKNOWN - the previous state is never
# guessed. When the pre-reservation status differs from the live status, the live
# Master Roadmap Status cell (an execution-state column, not protected) is restored
# to the proven pre-reservation value.
#
# PROHIBITED in REAL_NEXUS_DEVELOPMENT mode: DB24_OUTCOME
# TRIAL_CYCLE_CLOSURE_PROHIBITED_REAL_MODE with no write.
#
# Idempotent: a second invocation (current-task already TRIAL_CYCLE_CLOSED, or the
# reservation row already Closed-terminal) returns DB24_OUTCOME
# TRIAL_CYCLE_ALREADY_CLOSED with no duplicate writes.
#
# Backend contract: ALWAYS exits 0; outcomes ONLY via stdout markers (DB24_*).
# State/tasks dirs redirect with DB24_STATE_DIR / DB24_TASKS_DIR; the workbook
# path redirects with DB24_WORKBOOK_OVERRIDE; mode overrides with DB24_MODE
# (fixtures only - the authoritative workbook stays byte-identical during tests).
#
# ASCII-only source (PS 5.1 + BOM-safe).
param(
    [string]$NodeId,
    [string]$ChangeId,
    [string]$TaskIdentity
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null

. (Join-Path $PSScriptRoot "Read-DevelopmentControl.ps1")
. (Join-Path $PSScriptRoot "Set-DevBridgeStateEntry.ps1")
$xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
# $xmlNs is the reserved 'xml:' namespace required for xml:space="preserve" in
# inlineStr cells (New-TCell). It was referenced but never declared, which is a
# $null under lax mode and a hard StrictMode error; declare it explicitly.
$xmlNs = [System.Xml.Linq.XNamespace]"http://www.w3.org/XML/1998/namespace"

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:StateDir = Join-Path $script:Root "state"
$script:TasksDir = Join-Path $script:Root "tasks"
$script:CfgPath = Join-Path $script:Root "config\devbridge.json"
if ($env:DB24_STATE_DIR) { $script:StateDir = $env:DB24_STATE_DIR }
if ($env:DB24_TASKS_DIR) { $script:TasksDir = $env:DB24_TASKS_DIR }
$script:CurrentTaskPath = Join-Path $script:StateDir "current-task.json"
$script:NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# Effective workbook path: fixture override wins, else the canonical one.
$script:Wb = $script:DevControlWorkbook
if ($env:DB24_WORKBOOK_OVERRIDE) {
    $script:Wb = $env:DB24_WORKBOOK_OVERRIDE
    $script:DevControlWorkbook = $script:Wb
}

function Out-Markers([string]$token, [bool]$pass, [bool]$wbModified, [bool]$human, [string]$humanType, [string[]]$evidence) {
    Write-Output ("DB24_OUTCOME: " + $token)
    Write-Output ("DB24_RESULT_PASS: " + $(if ($pass) { "True" } else { "False" }))
    Write-Output ("DB24_RESULT_CODE: " + $token)
    Write-Output ("DB24_WORKBOOK_MODIFIED: " + $(if ($wbModified) { "True" } else { "False" }))
    Write-Output "DB24_NEXUS_SOURCE_MODIFIED: False"
    Write-Output "DB24_GIT_MODIFIED: False"
    Write-Output ("DB24_REQUIRES_HUMAN_ACTION: " + $(if ($human) { "True" } else { "False" }))
    Write-Output ("DB24_HUMAN_ACTION_TYPE: " + $humanType)
    foreach ($e in $evidence) { Write-Output ("DB24_EVIDENCE: " + $e) }
    exit 0
}

function Get-FileSha256([string]$p) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($p)
    try { $h = $sha.ComputeHash($fs) } finally { $fs.Dispose() }
    return (($h | ForEach-Object { $_.ToString("X2") }) -join "")
}

# ---------------------------------------------------------------------------
# Protected roadmap fingerprint (mirrors Get-ProtectedRoadmapFingerprint.ps1,
# resolved against the effective workbook path).
# ---------------------------------------------------------------------------
function Get-ProtectedCellVal($row, [string]$col, $shared) {
    foreach ($cell in $row.Elements($xNs + "c")) {
        $refAttr = $cell.Attribute("r")
        if (-not $refAttr) { continue }
        $ref = [string]$refAttr.Value
        if (($ref -replace "[0-9]", "") -ne $col) { continue }
        $tAttr = $cell.Attribute("t"); $t = ""
        if ($tAttr) { $t = [string]$tAttr.Value }
        if ($t -eq "inlineStr") { $is = $cell.Element($xNs + "is"); if ($is) { return [string]$is.Value } }
        if ($t -eq "s") {
            $v = $cell.Element($xNs + "v")
            if ($v) {
                $idx = 0; [void][int]::TryParse([string]$v.Value, [ref]$idx)
                if ($idx -ge 0 -and $idx -lt $shared.Count) { return [string]$shared[$idx] }
            }
            return ""
        }
        $fEl = $cell.Element($xNs + "f")
        if ($fEl) { return "" }
        $v = $cell.Element($xNs + "v"); if ($v) { return [string]$v.Value }
        return ""
    }
    return ""
}

function Get-RoadmapFingerprint {
    $cfgPath = Join-Path $script:Root "config\roadmap-protection.json"
    if (-not (Test-Path $cfgPath)) { return @{ value = $null; error = "roadmap-protection.json missing" } }
    $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.schemaVersion -ne 1) { return @{ value = $null; error = "roadmap-protection schema version != 1" } }

    $shared = New-Object System.Collections.Generic.List[string]
    try {
        $ssDoc = Open-DocEntry "xl/sharedStrings.xml"
        foreach ($si in $ssDoc.Root.Elements($xNs + "si")) {
            $txt = ""
            foreach ($t in $si.Elements($xNs + "t")) { $txt += [string]$t.Value }
            foreach ($r in $si.Elements($xNs + "r")) { $txt += [string]$r.Value }
            $shared.Add($txt)
        }
    } catch { }

    $mapSheets = @{}
    foreach ($ms in @($script:DevControlMap.sheets)) { $mapSheets[[string]$ms.name] = [int]$ms.dataStartRow }
    $canonical = New-Object System.Text.StringBuilder
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($ps in @($cfg.sheets)) {
        $sheetName = [string]$ps.sheet
        if (-not $mapSheets.ContainsKey($sheetName)) {
            $errors.Add("no dataStartRow mapped for sheet '$sheetName'")
            continue
        }
        $dataStart = $mapSheets[$sheetName]
        $allCols = @($ps.identityColumns) + @($ps.structureColumns) + @($ps.architectureColumns)
        $allCols = @($allCols | Sort-Object -Unique)
        try { $doc = Open-DocEntry (Get-SheetEntryName $sheetName) } catch {
            $errors.Add("sheet '$sheetName' failed to open")
            continue
        }
        foreach ($row in $doc.Root.Elements($xNs + "sheetData").Elements($xNs + "row")) {
            $rn = Get-RowNumber $row
            if ($rn -lt $dataStart) { continue }
            foreach ($col in $allCols) {
                $v = Get-ProtectedCellVal $row $col $shared
                if ($null -eq $v) { continue }
                $v = ([string]$v).Trim()
                if ($v.Length -eq 0) { continue }
                [void]$canonical.Append($sheetName).Append("|").Append($col).Append("|").Append($rn).Append("|").Append($v).Append(";")
            }
        }
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical.ToString())
    $hashHex = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "")
    return @{ value = $hashHex; error = $(if ($errors.Count -gt 0) { ($errors -join "; ") } else { $null }) }
}

# ---------------------------------------------------------------------------
# Generic OOXML cell-write helpers (from the proven DB-M10 apply; all new text is
# inlineStr, sharedStrings untouched).
# ---------------------------------------------------------------------------
function ColToIndex([string]$col) {
    $idx = 0
    foreach ($ch in $col.ToCharArray()) { $idx = $idx * 26 + ([int][char]$ch - 64) }
    return $idx
}
function ColOf([string]$ref) { return ($ref -replace '\d+$', '') }
function Convert-ColIndex([int]$idx) {
    $s = ""
    while ($idx -gt 0) {
        $idx--
        $s = [char](65 + ($idx % 26)) + $s
        $idx = [int][Math]::Floor($idx / 26)
    }
    return $s
}
function New-TCell([string]$value) {
    $t = New-Object System.Xml.Linq.XElement($xNs + "t")
    $t.Add([string]$value)
    $t.SetAttributeValue($xmlNs + "space", "preserve")
    return $t
}
function New-InlineCell([string]$ref, [string]$value, [string]$style) {
    $is = New-Object System.Xml.Linq.XElement($xNs + "is")
    $is.Add((New-TCell $value))
    $c = New-Object System.Xml.Linq.XElement($xNs + "c")
    $c.SetAttributeValue("r", $ref)
    $c.SetAttributeValue("t", "inlineStr")
    if ($style) { $c.SetAttributeValue("s", $style) }
    $c.Add($is)
    return $c
}
function New-NumCell([string]$ref, [string]$value, [string]$style) {
    $v = New-Object System.Xml.Linq.XElement($xNs + "v")
    $v.Add([string]$value)
    $c = New-Object System.Xml.Linq.XElement($xNs + "c")
    $c.SetAttributeValue("r", $ref)
    if ($style) { $c.SetAttributeValue("s", $style) }
    $c.Add($v)
    return $c
}
function Find-Cell($rowEl, [string]$col, [int]$rowNum) {
    if ($null -eq $rowEl) { return $null }
    $want = $col + $rowNum
    foreach ($cell in $rowEl.Elements($xNs + "c")) {
        $r = [string]$cell.Attribute("r").Value
        if ($r -eq $want) { return $cell }
    }
    return $null
}
function Resolve-CellText($sd, [int]$rowNum, [string]$col, $shared) {
    foreach ($row in $sd.Elements($xNs + "row")) {
        if ([int]$row.Attribute("r").Value -ne $rowNum) { continue }
        foreach ($cell in $row.Elements($xNs + "c")) {
            $ref = [string]$cell.Attribute("r").Value
            if (($ref -replace '\d+$','') -ne $col) { continue }
            $tAttr = $cell.Attribute("t"); $t = if ($tAttr) { [string]$tAttr.Value } else { "" }
            if ($t -eq "inlineStr") { $is = $cell.Element($xNs + "is"); if ($is) { return [string]$is.Value } }
            $v = $cell.Element($xNs + "v"); if ($v) {
                if ($t -eq "s") { $idx = [int]$v.Value; if ($idx -ge 0 -and $idx -lt $shared.Count) { return $shared[$idx] }; return "" }
                return [string]$v.Value
            }
            return ""
        }
    }
    return ""
}
function Get-SharedStrings($zip) {
    $shared = New-Object System.Collections.Generic.List[string]
    $ssEntry = $zip.GetEntry("xl/sharedStrings.xml")
    if ($ssEntry) {
        $sr = New-Object System.IO.StreamReader($ssEntry.Open())
        $ssXml = [System.Xml.Linq.XDocument]::Load($sr); $sr.Close()
        foreach ($si in $ssXml.Root.Elements($xNs + "si")) { $shared.Add([string]$si.Value) }
    }
    return $shared
}
function Insert-CellSorted($rowEl, $newCell) {
    $newCol = ColOf([string]$newCell.Attribute("r").Value)
    $newIdx = ColToIndex $newCol
    $inserted = $false
    foreach ($cell in @($rowEl.Elements($xNs + "c"))) {
        $ref = [string]$cell.Attribute("r").Value
        $idx = ColToIndex (ColOf $ref)
        if ($idx -gt $newIdx) { $cell.AddBeforeSelf($newCell); $inserted = $true; break }
    }
    if (-not $inserted) { $rowEl.Add($newCell) }
}
function Get-ColStyle($sheetData, [int]$rowNum, [string]$col) {
    for ($r = $rowNum - 1; $r -ge 1; $r--) {
        foreach ($rowEl in $sheetData.Elements($xNs + "row")) {
            $rn = [int]$rowEl.Attribute("r").Value
            if ($rn -ne $r) { continue }
            $cell = Find-Cell $rowEl $col $r
            if ($cell) {
                $s = $cell.Attribute("s")
                if ($s) { return [string]$s.Value }
                return $null
            }
        }
    }
    return $null
}
function Set-CellValue($cellEl, [string]$value, [bool]$numeric) {
    foreach ($child in @($cellEl.Elements($xNs + "v"))) { $child.Remove() }
    foreach ($child in @($cellEl.Elements($xNs + "is"))) { $child.Remove() }
    if ($numeric) {
        $cellEl.SetAttributeValue("t", $null)
        $v = New-Object System.Xml.Linq.XElement($xNs + "v"); $v.Add([string]$value); $cellEl.Add($v)
    } else {
        $cellEl.SetAttributeValue("t", "inlineStr")
        $is = New-Object System.Xml.Linq.XElement($xNs + "is"); $is.Add((New-TCell $value)); $cellEl.Add($is)
    }
}
function Write-Cell($sheetData, [int]$rowNum, [string]$col, [string]$value, [bool]$numeric = $false) {
    if ($value -eq $null -or $value -eq "") { return }
    $rowEl = $null
    foreach ($r in $sheetData.Elements($xNs + "row")) {
        if ([int]$r.Attribute("r").Value -eq $rowNum) { $rowEl = $r; break }
    }
    if (-not $rowEl) {
        $rowEl = New-Object System.Xml.Linq.XElement($xNs + "row")
        $rowEl.SetAttributeValue("r", $rowNum)
        $inserted = $false
        foreach ($r in @($sheetData.Elements($xNs + "row"))) {
            if ([int]$r.Attribute("r").Value -gt $rowNum) { $r.AddBeforeSelf($rowEl); $inserted = $true; break }
        }
        if (-not $inserted) { $sheetData.Add($rowEl) }
    }
    $cell = Find-Cell $rowEl $col $rowNum
    if ($cell) {
        Set-CellValue $cell $value $numeric
    } else {
        $style = Get-ColStyle $sheetData $rowNum $col
        if ($numeric) { $nc = New-NumCell ($col + $rowNum) $value $style } else { $nc = New-InlineCell ($col + $rowNum) $value $style }
        Insert-CellSorted $rowEl $nc
    }
}
function Append-Row($sheetData, [int]$rowNum, $cells, [string[]]$NumericCols) {
    if (-not $NumericCols) { $NumericCols = @() }
    $rowEl = $null
    foreach ($r in $sheetData.Elements($xNs + "row")) {
        if ([int]$r.Attribute("r").Value -eq $rowNum) { $rowEl = $r; break }
    }
    if (-not $rowEl) {
        $rowEl = New-Object System.Xml.Linq.XElement($xNs + "row")
        $rowEl.SetAttributeValue("r", $rowNum)
        $inserted = $false
        foreach ($r in @($sheetData.Elements($xNs + "row"))) {
            if ([int]$r.Attribute("r").Value -gt $rowNum) { $r.AddBeforeSelf($rowEl); $inserted = $true; break }
        }
        if (-not $inserted) { $sheetData.Add($rowEl) }
    }
    foreach ($k in $cells.Keys) {
        $col = [string]$k
        $val = [string]$cells[$k]
        if ($val -eq "") { continue }
        $cell = Find-Cell $rowEl $col $rowNum
        $numeric = ($NumericCols -contains $col)
        if ($cell) {
            Set-CellValue $cell $val $numeric
        } else {
            $style = Get-ColStyle $sheetData $rowNum $col
            if ($numeric) { $nc = New-NumCell ($col + $rowNum) $val $style } else { $nc = New-InlineCell ($col + $rowNum) $val $style }
            Insert-CellSorted $rowEl $nc
        }
    }
}
function Load-SheetDoc($zip, [string]$entryName) {
    $rd = New-Object System.IO.StreamReader($zip.GetEntry($entryName).Open())
    $doc = [System.Xml.Linq.XDocument]::Load($rd)
    $rd.Close()
    return $doc
}
function Save-SheetDoc($zip, [string]$entryName, $doc) {
    $entry = $zip.GetEntry($entryName)
    $stream = $entry.Open()
    $stream.SetLength(0)
    $stream.Position = 0
    $doc.Save($stream)
    $stream.Dispose()
}
function Update-SheetDimension($doc) {
    $sd = $doc.Root.Element($xNs + "sheetData")
    if ($null -eq $sd) { return }
    $maxRow = 0
    $maxCol = 0
    foreach ($row in $sd.Elements($xNs + "row")) {
        $rn = 0
        $rnAttr = $row.Attribute("r")
        if ($rnAttr) { [void][int]::TryParse([string]$rnAttr.Value, [ref]$rn) }
        if ($rn -gt $maxRow) { $maxRow = $rn }
        foreach ($cell in $row.Elements($xNs + "c")) {
            $refAttr = $cell.Attribute("r")
            if ($refAttr) {
                $ci = ColToIndex (ColOf ([string]$refAttr.Value))
                if ($ci -gt $maxCol) { $maxCol = $ci }
            }
        }
    }
    if ($maxRow -lt 1) { return }
    $dim = $doc.Root.Element($xNs + "dimension")
    if ($dim) { $dim.SetAttributeValue("ref", "A1:" + (Convert-ColIndex $maxCol) + $maxRow) }
}

# ---- apply the plan to a workbook copy (never the canonical file directly) ----
function Apply-PlanToWorkbook([string]$path, $plan) {
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        foreach ($op in @($plan.operations)) {
            $sheetName = [string]$op.sheet
            $entry = Get-SheetEntryName $sheetName
            $doc = Load-SheetDoc $zip $entry
            $sd = $doc.Root.Element($xNs + "sheetData")
            $rowsSpec = Get-DevBridgeField $op "rows"
            if ($rowsSpec) {
                foreach ($rowSpec in @($rowsSpec)) {
                    $rowNum = [int]$rowSpec.row
                    $numericCols = @()
                    $ncSpec = Get-DevBridgeField $rowSpec "numericCols"
                    if ($ncSpec) { $numericCols = @($ncSpec) }
                    $cells = @{}
                    foreach ($k in @($rowSpec.cells.Keys)) { $cells[$k] = [string]$rowSpec.cells[$k] }
                    Append-Row $sd $rowNum $cells $numericCols
                }
            }
            if (Get-DevBridgeField $op "updateDimension") { Update-SheetDimension $doc }
            Save-SheetDoc $zip $entry $doc
        }
    } finally {
        $zip.Dispose()
        $fs.Dispose()
    }
}

function Get-PlanCellValue([string]$path, [string]$entryName, [int]$rowNum, [string]$col) {
    $vfs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    $vzip = New-Object System.IO.Compression.ZipArchive($vfs, [System.IO.Compression.ZipArchiveMode]::Read)
    try {
        $shared = Get-SharedStrings $vzip
        $rd = New-Object System.IO.StreamReader($vzip.GetEntry($entryName).Open())
        $doc = [System.Xml.Linq.XDocument]::Load($rd); $rd.Close()
        foreach ($row in $doc.Root.Element($xNs + "sheetData").Elements($xNs + "row")) {
            if ([int]$row.Attribute("r").Value -ne $rowNum) { continue }
            foreach ($cell in $row.Elements($xNs + "c")) {
                $ref = [string]$cell.Attribute("r").Value
                if (($ref -replace '\d+$','') -ne $col) { continue }
                $tAttr = $cell.Attribute("t"); $t = if ($tAttr) { [string]$tAttr.Value } else { "" }
                if ($t -eq "inlineStr") { $is = $cell.Element($xNs + "is"); if ($is) { return [string]$is.Value } }
                $v = $cell.Element($xNs + "v"); if ($v) {
                    if ($t -eq "s") { $idx = [int]$v.Value; if ($idx -ge 0 -and $idx -lt $shared.Count) { return $shared[$idx] } }
                    return [string]$v.Value
                }
                return ""
            }
        }
    } finally {
        $vzip.Dispose()
        $vfs.Dispose()
    }
    return ""
}

function Test-PlanApplied([string]$path, $plan) {
    $fails = New-Object System.Collections.Generic.List[string]
    foreach ($op in @($plan.operations)) {
        $sheetName = [string]$op.sheet
        $entry = Get-SheetEntryName $sheetName
        if (Get-DevBridgeField $op "rows") {
            foreach ($rowSpec in @($op.rows)) {
                $rowNum = [int]$rowSpec.row
                foreach ($k in @($rowSpec.cells.Keys)) {
                    $expected = [string]$rowSpec.cells[$k]
                    $actual = Get-PlanCellValue $path $entry $rowNum ([string]$k)
                    if ($actual -ne $expected) { $fails.Add("$sheetName R$rowNum $k expected='$expected' actual='$actual'") }
                }
            }
        }
    }
    return @($fails.ToArray())
}

# ---------------------------------------------------------------------------
# State + identity
# ---------------------------------------------------------------------------
$ct = Read-DevBridgeJson $script:CurrentTaskPath
if ($null -eq $ct) { Out-Markers "STOP_NO_CURRENT_TASK" $false $false $false "" @("No current-task.json; the trial cycle cannot be closed without the active task.") }

$nodeId = [string](Get-DevBridgeField $ct "nodeId")
$changeId = [string](Get-DevBridgeField $ct "changeId")
$taskName = [string](Get-DevBridgeField $ct "name")
$status = [string](Get-DevBridgeField $ct "status")
if (-not $nodeId) { $nodeId = [string](Get-DevBridgeField $ct "taskId") }
if (-not $nodeId -or -not $changeId) { Out-Markers "STOP_TRIAL_CYCLE_IDENTITY_UNKNOWN" $false $false $false "" @("The active task has no provable NodeId/ChangeId; the trial cycle cannot be closed.") }

# Command identity (the service channel for RequiresTaskIdentity commands) must
# match the active cycle; otherwise the closure is addressed at the wrong cycle.
if ($NodeId) { if ($NodeId -ne $nodeId) { Out-Markers "TRIAL_CYCLE_IDENTITY_MISMATCH" $false $false $false "" @("Command NodeId '$NodeId' does not match the active task node '$nodeId'.") } }
if ($ChangeId) { if ($ChangeId -ne $changeId) { Out-Markers "TRIAL_CYCLE_IDENTITY_MISMATCH" $false $false $false "" @("Command ChangeId '$ChangeId' does not match the active task change '$changeId'.") } }
if ($env:DB_COMMAND_INPUT_NODE_ID) { if ($env:DB_COMMAND_INPUT_NODE_ID -ne $nodeId) { Out-Markers "TRIAL_CYCLE_IDENTITY_MISMATCH" $false $false $false "" @("Command NodeId '$($env:DB_COMMAND_INPUT_NODE_ID)' does not match the active task node '$nodeId'.") } }
if ($env:DB_COMMAND_INPUT_CHANGE_ID) { if ($env:DB_COMMAND_INPUT_CHANGE_ID -ne $changeId) { Out-Markers "TRIAL_CYCLE_IDENTITY_MISMATCH" $false $false $false "" @("Command ChangeId '$($env:DB_COMMAND_INPUT_CHANGE_ID)' does not match the active task change '$changeId'.") } }
if ($TaskIdentity) {
    try {
        $ident = ConvertFrom-DevBridgeJsonString $TaskIdentity
        if ($ident) {
            $iNode = [string](Get-DevBridgeField $ident "nodeId")
            $iChange = [string](Get-DevBridgeField $ident "changeId")
            if ($iNode -and $iNode -ne $nodeId) { Out-Markers "TRIAL_CYCLE_IDENTITY_MISMATCH" $false $false $false "" @("TaskIdentity node mismatch.") }
            if ($iChange -and $iChange -ne $changeId) { Out-Markers "TRIAL_CYCLE_IDENTITY_MISMATCH" $false $false $false "" @("TaskIdentity change mismatch.") }
        }
    } catch { }
}

# ---- idempotence: a closed cycle is never re-closed ----
if ($status -eq "TRIAL_CYCLE_CLOSED") {
    Out-Markers "TRIAL_CYCLE_ALREADY_CLOSED" $true $false $false "" @("state/trial-closure.json")
}

# ---- mode: closure is TRIAL-only ----
$mode = Get-DevBridgeMode $ct $script:CfgPath
if ($env:DB24_MODE) { $mode = $env:DB24_MODE }
if ($env:DB_COMMAND_INPUT_MODE) { $mode = $env:DB_COMMAND_INPUT_MODE }
$script:Trial = ($mode -eq "TRIAL")
if (-not $script:Trial) {
    Out-Markers "TRIAL_CYCLE_CLOSURE_PROHIBITED_REAL_MODE" $false $false $false "" @("CLOSE_TRIAL_CYCLE is prohibited in mode '" + $mode + "'. Trial-cycle closure exists only for TRIAL-mode proving evidence; REAL cycles use M10 governed completion.")
}

# ---- lifecycle: only a legitimate terminal/safe-stop trial state is closable ----
$legitStatuses = @("CLAUDE_REVIEW_PASSED_TRIAL", "TRIAL_CYCLE_SAFE_STOP")
if ($status -notin $legitStatuses) {
    Out-Markers "STOP_NOT_A_TRIAL_SAFE_STOP" $false $false $false "" @("Current lifecycle status '" + $status + "' is not a terminal/safe-stop trial state; the trial cycle cannot be closed from here.")
}

# ---- no real PR/merge/completion lifecycle: closure must never mask a real result ----
$m08 = Get-DevBridgeField $ct "dbM08"
$m06 = Get-DevBridgeField $ct "dbM06"
$implM08 = [string](Get-DevBridgeField $m08 "implementationState")
$implM06 = [string](Get-DevBridgeField $m06 "implementationState")
$m10Run = Get-DevBridgeField $m08 "m10Run"
if ($implM08 -and $implM08 -ne "TRIAL_ONLY_UNMERGED") { Out-Markers "STOP_TRIAL_HAS_REAL_LIFECYCLE" $false $false $true "HUMAN_GOVERNANCE_REVIEW" @("dbM08 implementationState '$implM08' is not TRIAL_ONLY_UNMERGED; the trial lifecycle is not a proving-only lifecycle.") }
if ($implM06 -and $implM06 -ne "TRIAL_ONLY_UNMERGED") { Out-Markers "STOP_TRIAL_HAS_REAL_LIFECYCLE" $false $false $true "HUMAN_GOVERNANCE_REVIEW" @("dbM06 implementationState '$implM06' is not TRIAL_ONLY_UNMERGED; the trial lifecycle is not a proving-only lifecycle.") }
if ($null -ne $m10Run -and ($m10Run -eq $true -or "$m10Run" -eq "True" -or "$m10Run" -eq "true")) { Out-Markers "STOP_TRIAL_HAS_REAL_LIFECYCLE" $false $false $true "HUMAN_GOVERNANCE_REVIEW" @("M10 has already run for this change; it is not a proving-only trial lifecycle.") }
$completionPath = Join-Path $script:StateDir "completion.json"
if (Test-Path $completionPath) {
    # completion.json is a single, per-latest-cycle record that M10 overwrites per
    # completion and never clears when the next cycle is reserved. A PRIOR cycle's
    # genuine record can therefore persist in the shared state dir next to the
    # current trial -- mere existence is NOT proof that THIS change has a real
    # completion lifecycle (DB-M12.4 design: "no completion.json FOR THIS change").
    # Scope the guard by the record's own changeId. An unprovable record still
    # blocks closure: the previous lifecycle is never guessed.
    $completionDoc = Read-DevBridgeJson $completionPath
    $completionChange = [string](Get-DevBridgeField $completionDoc "changeId")
    if ($completionChange -eq $changeId) {
        Out-Markers "STOP_TRIAL_HAS_REAL_LIFECYCLE" $false $false $true "HUMAN_GOVERNANCE_REVIEW" @("state/completion.json records a real completion for THIS change '" + $changeId + "'; the trial lifecycle is not proving-only.")
    }
    if (-not $completionChange) {
        Out-Markers "STOP_TRIAL_HAS_REAL_LIFECYCLE" $false $false $true "HUMAN_GOVERNANCE_REVIEW" @("state/completion.json exists but its owning change cannot be proven; closure is prohibited (never guessed).")
    }
}
$gitLifecycle = [string](Get-DevBridgeField $ct "gitLifecycleState")
if ($gitLifecycle -in @("MERGED", "READY_FOR_GOVERNED_COMPLETION")) { Out-Markers "STOP_TRIAL_HAS_REAL_LIFECYCLE" $false $false $true "HUMAN_GOVERNANCE_REVIEW" @("git lifecycle '$gitLifecycle' indicates a real merge lifecycle; closure is prohibited.") }

# ---- pre-reservation execution status: proven from recorded evidence, never guessed ----
$resEvidence = Get-DevBridgeField $ct "reservationEvidence"
$backupPath = [string](Get-DevBridgeField $resEvidence "backupPath")
$backupSha = [string](Get-DevBridgeField $resEvidence "backupSha256")
$resolvedBackup = $backupPath
if ($resolvedBackup -and -not ([System.IO.Path]::IsPathRooted($resolvedBackup))) {
    $resolvedBackup = Join-Path $script:Root $resolvedBackup
}
if (-not $resolvedBackup -or -not (Test-Path $resolvedBackup)) {
    Out-Markers "TRIAL_PRE_RESERVATION_STATE_UNKNOWN" $false $false $true "HUMAN_GOVERNANCE_REVIEW" @("The recorded pre-reservation backup workbook is missing; the previous execution status cannot be proven. No guess is made.")
}
$actualBackupSha = Get-FileSha256 $resolvedBackup
if ($actualBackupSha -ne $backupSha) {
    Out-Markers "TRIAL_PRE_RESERVATION_STATE_UNKNOWN" $false $false $true "HUMAN_GOVERNANCE_REVIEW" @("The recorded pre-reservation backup SHA ('" + $backupSha + "') does not match the backup file ('" + $actualBackupSha + "'); the previous execution status cannot be proven. No guess is made.")
}
$prevWb = $script:DevControlWorkbook
$preNode = $null
try {
    $script:DevControlWorkbook = $resolvedBackup
    $preNode = Get-RoadmapNodeById $nodeId
} finally {
    $script:DevControlWorkbook = $prevWb
}
if ($null -eq $preNode) {
    Out-Markers "TRIAL_PRE_RESERVATION_STATE_UNKNOWN" $false $false $true "HUMAN_GOVERNANCE_REVIEW" @("The reserved node was absent from the pre-reservation backup workbook; the previous execution status cannot be proven. No guess is made.")
}
$preStatus = [string]$preNode.Status
$liveNode = Get-RoadmapNodeById $nodeId
if ($null -eq $liveNode) {
    Out-Markers "TRIAL_PRE_RESERVATION_STATE_UNKNOWN" $false $false $true "HUMAN_GOVERNANCE_REVIEW" @("The reserved node is absent from the live workbook; the live execution status cannot be proven. No guess is made.")
}
$liveStatus = [string]$liveNode.Status
$restoreRequired = ($preStatus -ne $liveStatus)

Write-Output ("DB24_PRE_RESERVATION_STATE: " + $preStatus)
Write-Output ("DB24_RESTORE_REQUIRED: " + $(if ($restoreRequired) { "True" } else { "False" }))

# ---- reservation row: must exist and must not already be closed ----
$acMap = @($script:DevControlMap.sheets | Where-Object { $_.name -eq "Active Changes" })[0]
$acHeader = [int]$acMap.headerRow
$acRows = @(Get-AllActiveChanges | Where-Object { $_.ChangeId -eq $changeId })
if ($acRows.Count -eq 0) { Out-Markers "STOP_RESERVATION_ROW_NOT_FOUND" $false $false $true "HUMAN_OPERATOR" @("No Active Changes reservation row exists for change '$changeId'; the trial reservation cannot be closed.") }
$acRow = [int]$acRows[0].Row
$acStatus = [string]$acRows[0].Status
if ($acStatus -match "^\s*Closed") { Out-Markers "TRIAL_CYCLE_ALREADY_CLOSED" $true $false $false "" @("Active Changes row " + $acRow + " is already Closed-terminal.") }

# ---- fingerprint guard: before ----
$fpBefore = Get-RoadmapFingerprint
if ($fpBefore.error) {
    Out-Markers "STOP_ROADMAP_STRUCTURE_WRITE_PROHIBITED" $false $false $true "HUMAN_GOVERNANCE_REVIEW" @("Protected roadmap fingerprint could not be computed: " + $fpBefore.error)
}
$fpBefore = $fpBefore.value

# ---- build the workbook closure plan (Active Changes Status + Activity Log row) ----
$statusCol = Get-ColumnForSheet "Active Changes" $acHeader "Status"
$closedStatusText = "Closed -- governed TRIAL cycle closure (DB-M12.4); trial proving evidence preserved; roadmap node NOT completed (remains Planned); not a real completion; M10 not applicable to trial evidence."

$alMap = @($script:DevControlMap.sheets | Where-Object { $_.name -eq "Activity Log" })[0]
$alHeader = [int]$alMap.headerRow
$alRows = @(Get-SheetRows "Activity Log" $alHeader ([int]$alMap.dataStartRow) 2000)
$alNext = [int]$alMap.dataStartRow
$maxSeq = 0
foreach ($r in $alRows) {
    $aid = [string](Get-Value "Activity Log" $r $alHeader "Activity ID")
    if ($aid -match "ACT-(\d{8})-(\d+)$") {
        $seq = [int]$matches[2]
        if ($seq -gt $maxSeq) { $maxSeq = $seq }
    }
    if ([int]$r.Row -ge $alNext) { $alNext = [int]$r.Row + 1 }
}
$activityId = "ACT-" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd") + "-" + ($maxSeq + 1).ToString("D3")

$alC = @{}
foreach ($name in @("Activity ID","Timestamp UTC","Actor Type","Actor Name","Source","Change ID","Operation","Entity ID","Reason","Repository","Project","Branch","Worktree","Files/Globs","Preflight Verdict","Result","Evidence","Human Review Status","Created At")) {
    $alC[$name] = Get-ColumnForSheet "Activity Log" $alHeader $name
}

$ops = New-Object System.Collections.ArrayList
$ops.Add([ordered]@{
    sheet = "Active Changes"
    rows  = @([ordered]@{ row = $acRow; cells = [ordered]@{ $statusCol = $closedStatusText } })
}) | Out-Null
$ops.Add([ordered]@{
    sheet = "Activity Log"
    updateDimension = $true
    rows  = @([ordered]@{
        row   = $alNext
        cells = [ordered]@{
            $alC["Activity ID"]          = $activityId
            $alC["Timestamp UTC"]        = $script:NowUtc
            $alC["Actor Type"]           = "Agent"
            $alC["Actor Name"]           = "Claude Code (DevBridge)"
            $alC["Source"]               = "DevBridge"
            $alC["Change ID"]            = $changeId
            $alC["Operation"]            = "Governed Trial Cycle Closure"
            $alC["Entity ID"]            = ($nodeId + " | " + $(if ($liveNode.ParentId) { $liveNode.ParentId } else { "" }))
            $alC["Reason"]               = "DB-M12.4 governed closure of a proven TRIAL cycle: trial evidence preserved, reservation released, roadmap node NOT completed (remains " + $preStatus + "), M10 not applicable to trial evidence."
            $alC["Repository"]           = "N/A"
            $alC["Project"]              = "DevBridge"
            $alC["Branch"]               = "N/A"
            $alC["Worktree"]             = "None"
            $alC["Files/Globs"]          = "state/trial-closure.json; state/trial-proving-history.json; tasks/TRIAL_CYCLE_CLOSURE_REPORT.md"
            $alC["Preflight Verdict"]    = "CLEAR"
            $alC["Result"]               = "CLOSED"
            $alC["Evidence"]             = "state/trial-closure.json; state/trial-proving-history.json; tasks/TRIAL_CYCLE_CLOSURE_REPORT.md"
            $alC["Human Review Status"]  = "Not Reviewed"
            $alC["Created At"]           = $script:NowUtc
        }
    })
}) | Out-Null

# When the live status drifted from the proven pre-reservation status, restore the
# roadmap Status cell (execution-state column, fingerprint-safe) to the recorded
# pre-reservation value. Never touches roadmap structure.
if ($restoreRequired) {
    $mrMap = @($script:DevControlMap.sheets | Where-Object { $_.name -eq "Master Roadmap" })[0]
    $mrHeader = [int]$mrMap.headerRow
    $mrStatusCol = Get-ColumnForSheet "Master Roadmap" $mrHeader "Status"
    $ops.Add([ordered]@{
        sheet = "Master Roadmap"
        rows  = @([ordered]@{ row = [int]$liveNode.Row; cells = [ordered]@{ $mrStatusCol = $preStatus } })
    }) | Out-Null
}

$plan = [ordered]@{ operations = $ops.ToArray() }

# ---- backup + temp copy + mutate + verify + fingerprint-after + atomic replace ----
if (-not (Test-Path $script:Wb)) { Out-Markers "STOP_WORKBOOK_UNAVAILABLE" $false $false $true "HUMAN_OPERATOR" @("Effective workbook not found: " + $script:Wb) }
$backupDir = Join-Path $script:StateDir "backups"
if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }
# [string] coercion: Join-Path returns a PSObject-wrapped string (PowerShell 5.1
# pipeline wrapping); a wrapped leaf stored in a state hashtable breaks
# JavaScriptSerializer ("circular reference: PSParameterizedProperty"). Coerce so
# the preWriteBackupSha256 value serializes as plain data.
$preWriteBackup = [string](Join-Path $backupDir ("db-m124-preclosure-" + ([DateTime]::UtcNow.ToString("yyyyMMddHHmmss")) + ".xlsx"))
Copy-Item $script:Wb $preWriteBackup -Force
if (-not (Test-Path $preWriteBackup)) { Out-Markers "STOP_BACKUP_FAILED" $false $false $true "HUMAN_OPERATOR" @("Pre-closure backup could not be created; the authoritative write is blocked.") }
# Evidence fidelity: the closure doc records the backup's ACTUAL SHA256 (the name
# says Sha256; a path there would be misleading) plus its path as a separate field.
$preWriteBackupSha = Get-FileSha256 $preWriteBackup

$tmp = [System.IO.Path]::GetTempFileName()
Remove-Item $tmp -Force
Copy-Item $script:Wb $tmp -Force
Apply-PlanToWorkbook $tmp $plan
$failT = @(Test-PlanApplied $tmp $plan)
if ($failT.Count -gt 0) {
    Remove-Item $tmp -Force
    Out-Markers "STOP_PLAN_VERIFICATION_FAILED" $false $false $false "" @("Closure cells did not read back on the temp copy: " + ($failT -join "; "))
}

$script:DevControlWorkbook = $tmp
$fpAfter = Get-RoadmapFingerprint
if ($fpAfter.error) { $fpAfter = $null } else { $fpAfter = $fpAfter.value }
$script:DevControlWorkbook = $script:Wb
if ($fpBefore -ne $fpAfter) {
    Remove-Item $tmp -Force
    Out-Markers "STOP_ROADMAP_STRUCTURE_WRITE_PROHIBITED" $false $false $true "HUMAN_GOVERNANCE_REVIEW" @("The protected roadmap surface changed between fingerprint capture and the closure write.")
}

try {
    Move-Item -Path $tmp -Destination $script:Wb -Force -ErrorAction Stop
} catch {
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    Out-Markers "STOP_ATOMIC_REPLACE_FAILED" $false $false $true "HUMAN_OPERATOR" @("Atomic replace failed (workbook open?): " + $_.Exception.Message)
}
$failC = @(Test-PlanApplied $script:Wb $plan)
if ($failC.Count -gt 0) {
    Out-Markers "STOP_PLAN_VERIFICATION_FAILED_POST_WRITE" $false $true $true "HUMAN_OPERATOR" @("Reopened workbook did not read back the closure cells: " + ($failC -join "; ") + ". A human must review the backup: " + $preWriteBackup)
}
$postSha = Get-WorkbookSha256

# ---- DevBridge-local evidence + state transition ----
$closureDoc = [ordered]@{
    milestone            = "DB-M12.4"
    nodeId               = $nodeId
    changeId             = $changeId
    name                 = $taskName
    mode                 = $mode
    trialMode            = $true
    closedAtUtc          = $script:NowUtc
    result               = "TRIAL_CYCLE_CLOSED"
    workbookModified     = $true
    preReservationStatus = $preStatus
    restoreRequired      = $restoreRequired
    backupSha256         = $backupSha
    preWriteBackupSha256 = $preWriteBackupSha
    preWriteBackupPath   = $preWriteBackup
    postWorkbookSha256   = $postSha
    activeChangesRow     = $acRow
    activityLogRow       = $alNext
    implementationState  = "TRIAL_ONLY_UNMERGED"
    nextAction           = "START_NEXT_CYCLE"
    fingerprintGuard     = [ordered]@{ before = $fpBefore; after = $fpAfter; preserved = ($fpBefore -eq $fpAfter) }
    evidence             = @("state/trial-closure.json", "state/trial-proving-history.json", "tasks/TRIAL_CYCLE_CLOSURE_REPORT.md")
}
Write-DevBridgeJson (Join-Path $script:StateDir "trial-closure.json") $closureDoc

# proving-cycle history: append this used NodeId (consumed by DB-M03 in TRIAL mode)
$historyPath = Join-Path $script:StateDir "trial-proving-history.json"
$entries = New-Object System.Collections.Generic.List[object]
$hist = Read-DevBridgeJson $historyPath
$already = $false
if ($null -ne $hist) {
    $existing = Get-DevBridgeField $hist "entries"
    if ($existing) {
        foreach ($e in @($existing)) {
            $entries.Add($e)
            if ([string](Get-DevBridgeField $e "nodeId") -eq $nodeId -and [string](Get-DevBridgeField $e "changeId") -eq $changeId) { $already = $true }
        }
    }
}
if (-not $already) {
    $entries.Add([ordered]@{
        nodeId               = $nodeId
        changeId             = $changeId
        closedAtUtc          = $script:NowUtc
        mode                 = $mode
        result               = "TRIAL_CYCLE_CLOSED"
        implementationState  = "TRIAL_ONLY_UNMERGED"
        preReservationStatus = $preStatus
    })
}
Write-DevBridgeJson $historyPath ([ordered]@{ entries = $entries.ToArray() })

$report = "# DB-M12.4 TRIAL CYCLE CLOSURE REPORT`n`nNode: " + $nodeId + "`nChange: " + $changeId + "`nName: " + $taskName + "`nMode: " + $mode + "`nResult: TRIAL_CYCLE_CLOSED`nClosed (utc): " + $script:NowUtc + "`nPre-reservation status: " + $preStatus + "`nRestore required: " + $restoreRequired + "`nImplementation state preserved: TRIAL_ONLY_UNMERGED`nActive Changes row: " + $acRow + "`nActivity Log row: " + $alNext + "`nFingerprint preserved: " + ($fpBefore -eq $fpAfter) + "`nWorkbook modified: True`n`nNOT a real completion: the roadmap node remains " + $preStatus + "; M10 was NOT run; no PR, no merge, no completion.json.`n`nEvidence: state/trial-closure.json, state/trial-proving-history.json, tasks/TRIAL_CYCLE_CLOSURE_REPORT.md`n"
[System.IO.File]::WriteAllText((Join-Path $script:TasksDir "TRIAL_CYCLE_CLOSURE_REPORT.md"), $report, (New-Object System.Text.UTF8Encoding($false)))

$db124 = [ordered]@{
    result               = "TRIAL_CYCLE_CLOSED"
    nodeId               = $nodeId
    changeId             = $changeId
    mode                 = $mode
    trialMode            = $true
    closedAtUtc          = $script:NowUtc
    workbookModified     = $true
    preReservationStatus = $preStatus
    restoreRequired      = $restoreRequired
    implementationState  = "TRIAL_ONLY_UNMERGED"
    activityLogRow       = $alNext
    evidence             = @("state/trial-closure.json", "state/trial-proving-history.json", "tasks/TRIAL_CYCLE_CLOSURE_REPORT.md")
}
# 'dbM12.4' must be quoted: a dot in a bare hash-literal key is a PS 5.1 parser error.
Set-DevBridgeStateEntry $script:CurrentTaskPath @{ status = "TRIAL_CYCLE_CLOSED"; nextAllowedAction = "START_NEXT_CYCLE"; 'dbM12.4' = $db124 }

Out-Markers "TRIAL_CYCLE_CLOSED" $true $true $false "" @("state/trial-closure.json", "state/trial-proving-history.json", "tasks/TRIAL_CYCLE_CLOSURE_REPORT.md", $preWriteBackup)
