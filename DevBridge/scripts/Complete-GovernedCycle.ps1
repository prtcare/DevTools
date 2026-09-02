# Complete-GovernedCycle.ps1 - DB-M10 governed completion (DB-M12.2 reusable
# lifecycle command for RUN_GOVERNED_COMPLETION).
#
# Runs the full DB-GH01 completion gate for the CURRENT task:
#   * mode (TRIAL -> TRIAL_COMPLETION_NOT_APPLICABLE, no write);
#   * DB-M06 verification PASS;
#   * Claude review PASS;
#   * CONFIRMED human git merge (gitLifecycleState MERGED /
#     READY_FOR_GOVERNED_COMPLETION -- never inferred);
#   * protected roadmap fingerprint preserved (before == after over the protected
#     columns of config\roadmap-protection.json).
# When eligible in REAL mode the command applies state\sheet-update-plan.json (the
# per-change cell plan) to the workbook with backup + read-back + fingerprint
# before/after and records state\completion.json + tasks\COMPLETION_REPORT.md +
# COMPLETION_WRITTEN. Any unmet gate emits a governed STOP with no write.
#
# SELFTEST mode (DB10_SELFTEST=1) exercises the same gate + evidence + transition
# WITHOUT touching any workbook: the gate inputs and the fingerprint before/after
# come from DB10_MODE / DB10_M06_PASS / DB10_CLAUDE_PASS /
# DB10_GIT_MERGE_CONFIRMED / DB10_FINGERPRINT_BEFORE / DB10_FINGERPRINT_AFTER.
#
# Backend contract: ALWAYS exits 0; outcomes ONLY via stdout markers (DB10_*).
# State/tasks dirs redirect with DB10_STATE_DIR / DB10_TASKS_DIR; the workbook path
# redirects with DB10_WORKBOOK_OVERRIDE (fixtures only -- the authoritative
# workbook stays byte-identical during DB-M12.2).
#
# ASCII-only source (PS 5.1 + BOM-safe).
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null

. (Join-Path $PSScriptRoot "Read-DevelopmentControl.ps1")
. (Join-Path $PSScriptRoot "Set-DevBridgeStateEntry.ps1")
$xmlNs = [System.Xml.Linq.XNamespace]"http://www.w3.org/XML/1998/namespace"

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:StateDir = Join-Path $script:Root "state"
$script:TasksDir = Join-Path $script:Root "tasks"
$script:CfgPath = Join-Path $script:Root "config\devbridge.json"
if ($env:DB10_STATE_DIR) { $script:StateDir = $env:DB10_STATE_DIR }
if ($env:DB10_TASKS_DIR) { $script:TasksDir = $env:DB10_TASKS_DIR }
$script:CurrentTaskPath = Join-Path $script:StateDir "current-task.json"
$script:NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# Effective workbook path: fixture override wins, else the canonical one.
$script:Wb = $script:DevControlWorkbook
if ($env:DB10_WORKBOOK_OVERRIDE) {
    $script:Wb = $env:DB10_WORKBOOK_OVERRIDE
    $script:DevControlWorkbook = $script:Wb
}

function Out-Markers([string]$token, [bool]$pass, [bool]$wbModified, [bool]$human, [string]$humanType, [string[]]$evidence) {
    Write-Output ("DB10_OUTCOME: " + $token)
    Write-Output ("DB10_RESULT_PASS: " + $(if ($pass) { "True" } else { "False" }))
    Write-Output ("DB10_RESULT_CODE: " + $token)
    Write-Output ("DB10_WORKBOOK_MODIFIED: " + $(if ($wbModified) { "True" } else { "False" }))
    Write-Output "DB10_NEXUS_SOURCE_MODIFIED: False"
    Write-Output "DB10_GIT_MODIFIED: False"
    Write-Output ("DB10_REQUIRES_HUMAN_ACTION: " + $(if ($human) { "True" } else { "False" }))
    Write-Output ("DB10_HUMAN_ACTION_TYPE: " + $humanType)
    foreach ($e in $evidence) { Write-Output ("DB10_EVIDENCE: " + $e) }
    exit 0
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
function Append-Row($sheetData, [int]$rowNum, [hashtable]$cells, [string[]]$NumericCols) {
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
            if (Get-DevBridgeField $op "prepend") {
                $rowNum = [int]$op.prepend.row
                $col = [string]$op.prepend.col
                $text = [string]$op.prepend.text
                $shared = Get-SharedStrings $zip
                $existing = Resolve-CellText $sd $rowNum $col $shared
                Write-Cell $sd $rowNum $col ($text + $existing)
            }
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
        if (Get-DevBridgeField $op "prepend") {
            $rowNum = [int]$op.prepend.row
            $col = [string]$op.prepend.col
            $text = [string]$op.prepend.text
            $actual = Get-PlanCellValue $path $entry $rowNum $col
            if (-not $actual.StartsWith($text)) { $fails.Add("$sheetName R$rowNum $col prepend expected prefix not present") }
        }
    }
    return @($fails.ToArray())
}

# ---------------------------------------------------------------------------
# State + gate
# ---------------------------------------------------------------------------
$ct = Read-DevBridgeJson $script:CurrentTaskPath
if ($null -eq $ct) { Out-Markers "STOP_NO_CURRENT_TASK" $false $false $false "" @("No current-task.json; run DB-M03 preflight first.") }

$nodeId = [string](Get-DevBridgeField $ct "nodeId")
$changeId = [string](Get-DevBridgeField $ct "changeId")
$taskName = [string](Get-DevBridgeField $ct "name")
if (-not $nodeId) { $nodeId = [string](Get-DevBridgeField $ct "taskId") }

# Duplicate-completion safety: an already-completed cycle is REUSED, never re-written.
$completionPath = Join-Path $script:StateDir "completion.json"
$existingStatus = [string](Get-DevBridgeField $ct "status")
if ($existingStatus -eq "COMPLETION_WRITTEN" -and (Test-Path $completionPath)) {
    $comp = Read-DevBridgeJson $completionPath
    if ($null -ne $comp -and [string](Get-DevBridgeField $comp "changeId") -eq $changeId) {
        Out-Markers "REUSED" $true $false $false "" @("state/completion.json", "tasks/COMPLETION_REPORT.md")
    }
}

$mode = Get-DevBridgeMode $ct $script:CfgPath
if ($env:DB10_MODE) { $mode = $env:DB10_MODE }
if ($env:DB_COMMAND_INPUT_MODE) { $mode = $env:DB_COMMAND_INPUT_MODE }
$script:Trial = ($mode -eq "TRIAL")

$selftest = ($env:DB10_SELFTEST -eq "1")
$script:M06Pass = $false
$script:ClaudePass = $false
$script:Merge = $false
if ($selftest) {
    $script:M06Pass = ($env:DB10_M06_PASS -eq "True")
    $script:ClaudePass = ($env:DB10_CLAUDE_PASS -eq "True")
    $script:Merge = ($env:DB10_GIT_MERGE_CONFIRMED -eq "True")
} else {
    $verif = Read-DevBridgeJson (Join-Path $script:StateDir "verification.json")
    $script:M06Pass = ([string](Get-DevBridgeField $verif "primaryResult")).StartsWith("VERIFICATION_PASSED")
    $claude = Read-DevBridgeJson (Join-Path $script:StateDir "claude-review.json")
    $script:ClaudePass = ([string](Get-DevBridgeField $claude "decision")).StartsWith("PASS")
    $gitTok = [string](Get-DevBridgeField $ct "gitLifecycleState")
    $script:Merge = ($gitTok -in @("MERGED", "READY_FOR_GOVERNED_COMPLETION"))
}

function Get-GateVerdict {
    if ($script:Trial) { return "TRIAL_COMPLETION_NOT_APPLICABLE" }
    if (-not $script:M06Pass) { return "STOP_NO_DB_M06_VERIFICATION_PASS" }
    if (-not $script:ClaudePass) { return "STOP_NO_CLAUDE_PASS" }
    if (-not $script:Merge) { return "STOP_HUMAN_GIT_MERGE_GATE_PENDING" }
    return "ELIGIBLE"
}

function Write-CompletionEvidence([bool]$wbModified, [string]$fpBefore, [string]$fpAfter) {
    $completion = [ordered]@{
        milestone    = "DB-M10"
        nodeId       = $nodeId
        changeId     = $changeId
        name         = $taskName
        mode         = $mode
        trialMode    = $script:Trial
        completedAtUtc = $script:NowUtc
        workbookModified = $wbModified
        fingerprintGuard = [ordered]@{
            before    = $fpBefore
            after     = $fpAfter
            preserved = ($fpBefore -eq $fpAfter)
        }
        evidence     = @("state/completion.json", "tasks/COMPLETION_REPORT.md")
    }
    Write-DevBridgeJson (Join-Path $script:StateDir "completion.json") $completion

    $report = "# DB-M10 Completion Report`n`nNode: " + $nodeId + "`nChange: " + $changeId + "`nMode: " + $mode + "`nResult: COMPLETION_WRITTEN`nCompleted (utc): " + $script:NowUtc + "`nFingerprint preserved: " + ($fpBefore -eq $fpAfter) + "`nWorkbook modified: " + $wbModified + "`n`nEvidence: state/completion.json, tasks/COMPLETION_REPORT.md`n"
    [System.IO.File]::WriteAllText((Join-Path $script:TasksDir "COMPLETION_REPORT.md"), $report, (New-Object System.Text.UTF8Encoding($false)))

    $db10 = [ordered]@{
        result         = "COMPLETION_WRITTEN"
        nodeId         = $nodeId
        changeId       = $changeId
        mode           = $mode
        trialMode      = $script:Trial
        workbookModified = $wbModified
        completedAtUtc = $script:NowUtc
        evidence       = @("state/completion.json", "tasks/COMPLETION_REPORT.md")
    }
    Set-DevBridgeStateEntry $script:CurrentTaskPath @{ status = "COMPLETION_WRITTEN"; nextAllowedAction = "CONTROL_VALIDATION"; dbM10 = $db10 }
}

$verdict = Get-GateVerdict

# ---- TRIAL: completion is NOT applicable; no write, no state change ----
if ($verdict -eq "TRIAL_COMPLETION_NOT_APPLICABLE") {
    Out-Markers $verdict $true $false $false "" @("TRIAL cycle: governed completion is not applicable; trial evidence stops at the trial safe stop.")
}

# ---- governed STOP (gate unmet): no write, human action surfaced for the merge gate ----
if ($verdict -ne "ELIGIBLE") {
    $human = ($verdict -eq "STOP_HUMAN_GIT_MERGE_GATE_PENDING" -or $verdict -eq "STOP_ROADMAP_STRUCTURE_WRITE_PROHIBITED")
    $humanType = ""
    if ($verdict -eq "STOP_HUMAN_GIT_MERGE_GATE_PENDING") { $humanType = "HUMAN_GIT_MERGE" }
    if ($verdict -eq "STOP_ROADMAP_STRUCTURE_WRITE_PROHIBITED") { $humanType = "HUMAN_GOVERNANCE_REVIEW" }
    Out-Markers $verdict $false $false $human $humanType @("Completion gate not satisfied; the canonical workbook was NOT modified.")
}

# ---- fingerprint guard ----
$fpBefore = $null
$fpAfter = $null
if ($selftest) {
    $fpBefore = [string]$env:DB10_FINGERPRINT_BEFORE
    $fpAfter = [string]$env:DB10_FINGERPRINT_AFTER
    if (-not $fpBefore -or -not $fpAfter) {
        Out-Markers "STOP_ROADMAP_STRUCTURE_WRITE_PROHIBITED" $false $false $true "HUMAN_GOVERNANCE_REVIEW" @("Selftest fingerprint before/after not both supplied; the write is blocked (NotComparable).")
    }
} else {
    $fpBefore = Get-RoadmapFingerprint
    if ($fpBefore.error) {
        Out-Markers "STOP_ROADMAP_STRUCTURE_WRITE_PROHIBITED" $false $false $true "HUMAN_GOVERNANCE_REVIEW" @("Protected roadmap fingerprint could not be computed: " + $fpBefore.error)
    }
    $fpBefore = $fpBefore.value
}
if ($fpBefore -and $fpAfter -and $fpBefore -ne $fpAfter) {
    Out-Markers "STOP_ROADMAP_STRUCTURE_WRITE_PROHIBITED" $false $false $true "HUMAN_GOVERNANCE_REVIEW" @("The protected roadmap surface changed between fingerprint capture and the governed write.")
}

# ---- eligible: selftest records evidence only; real mode applies the plan ----
if ($selftest) {
    Write-CompletionEvidence $false $fpBefore $fpAfter
    Out-Markers "COMPLETED" $true $false $false "" @("state/completion.json", "tasks/COMPLETION_REPORT.md")
}

# ---- real mode: apply state\sheet-update-plan.json with backup + read-back ----
$planPath = Join-Path $script:StateDir "sheet-update-plan.json"
$plan = Read-DevBridgeJson $planPath
if ($null -eq $plan) {
    Out-Markers "STOP_SHEET_UPDATE_PLAN_MISSING" $false $false $true "HUMAN_OPERATOR" @("No sheet-update-plan.json for this change; the governed completion cannot write cells without a plan.")
}
if (-not (Test-Path $script:Wb)) {
    Out-Markers "STOP_WORKBOOK_UNAVAILABLE" $false $false $true "HUMAN_OPERATOR" @("Effective workbook not found: " + $script:Wb)
}

# backup before the authoritative write
$backupDir = Join-Path $script:StateDir "backups"
if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }
$backupPath = Join-Path $backupDir ("db-m10-backup-" + ([DateTime]::UtcNow.ToString("yyyyMMddHHmmss")) + ".xlsx")
Copy-Item $script:Wb $backupPath -Force
if (-not (Test-Path $backupPath)) {
    Out-Markers "STOP_BACKUP_FAILED" $false $false $true "HUMAN_OPERATOR" @("Backup could not be created; the authoritative write is blocked.")
}

# temp copy -> mutate -> verify -> fingerprint-after
$tmp = [System.IO.Path]::GetTempFileName()
Remove-Item $tmp -Force
Copy-Item $script:Wb $tmp -Force
Apply-PlanToWorkbook $tmp $plan
$failT = @(Test-PlanApplied $tmp $plan)
if ($failT.Count -gt 0) {
    Remove-Item $tmp -Force
    Out-Markers "STOP_PLAN_VERIFICATION_FAILED" $false $false $false "" @("Planned cells did not read back on the temp copy: " + ($failT -join "; "))
}

$script:DevControlWorkbook = $tmp
$fpAfter = Get-RoadmapFingerprint
if ($fpAfter.error) { $fpAfter = $null } else { $fpAfter = $fpAfter.value }
$script:DevControlWorkbook = $script:Wb
if ($fpBefore -ne $fpAfter) {
    Remove-Item $tmp -Force
    Out-Markers "STOP_ROADMAP_STRUCTURE_WRITE_PROHIBITED" $false $false $true "HUMAN_GOVERNANCE_REVIEW" @("The protected roadmap surface changed between fingerprint capture and the governed write.")
}

# atomic replace + reopen read-back
try {
    Move-Item -Path $tmp -Destination $script:Wb -Force -ErrorAction Stop
} catch {
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    Out-Markers "STOP_ATOMIC_REPLACE_FAILED" $false $false $true "HUMAN_OPERATOR" @("Atomic replace failed (workbook open?): " + $_.Exception.Message)
}
$failC = @(Test-PlanApplied $script:Wb $plan)
if ($failC.Count -gt 0) {
    Out-Markers "STOP_PLAN_VERIFICATION_FAILED_POST_WRITE" $false $true $true "HUMAN_OPERATOR" @("Reopened workbook did not read back the planned cells: " + ($failC -join "; ") + ". A human must review the backup: " + $backupPath)
}

# fingerprint evidence file + completion evidence
$fpFile = [ordered]@{ before = @{ value = $fpBefore }; after = @{ value = $fpAfter }; updatedAtUtc = $script:NowUtc }
Write-DevBridgeJson (Join-Path $script:StateDir "roadmap-fingerprint.json") $fpFile

Write-CompletionEvidence $true $fpBefore $fpAfter
Out-Markers "COMPLETED" $true $true $false "" @("state/completion.json", "tasks/COMPLETION_REPORT.md", $backupPath)
