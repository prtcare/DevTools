# Test-DBM124TrialCycleClosure.ps1
# DevBridge DB-M12.4 fixture driver. Runs the governed TRIAL cycle closure backend
# (Close-TrialCycle.ps1) and the DB-M03 fresh-cycle selection exclusion
# (Get-NextTask.ps1) against throwaway state/tasks dirs and byte-identical workbook
# copies under logs\selftest\db124.
#
# The DB-M12.4 fixture identity is the real proven trial cycle
# (WI-07-0.2.4 / CHG-20260830-017) because the closure contract requires the node to
# exist in the workbook and proves its pre-reservation status from the recorded M04
# reservation backup. The reusable scripts themselves are proven generic by invariant
# I5 (no WI/CHG literals in Close-TrialCycle.ps1 / Get-NextTask.ps1).
#
# Every write lands in the fixture copy. The authoritative workbook, the Nexus repo,
# and the live trial evidence are asserted byte-identical at the end (I1-I3).
#
# Scenario coverage (DB-M12.4 acceptance matrix):
#   S1  safe-stop eligible closure -> TRIAL_CYCLE_CLOSED, row terminal, activity +1,
#       no completion.json, no M10, fingerprint unchanged, TRIAL_ONLY_UNMERGED kept,
#       state transition, evidence preserved, no PR/merge;
#   S2  non-terminal trial state -> STOP_NOT_A_TRIAL_SAFE_STOP;
#   S3  REAL mode -> TRIAL_CYCLE_CLOSURE_PROHIBITED_REAL_MODE, no write;
#   S4  live status drifted from pre-reservation -> restored to the proven value;
#   S5  unprovable pre-reservation evidence -> TRIAL_PRE_RESERVATION_STATE_UNKNOWN;
#   S6  idempotence -> TRIAL_CYCLE_ALREADY_CLOSED, no duplicate write;
#   S7  M03 control (TRIAL, no history) reproduces the prior WI-07-0.2.4 selection;
#   S8  M03 TRIAL + proving history excludes the closed node, selects the parent;
#   S9  M03 after closure excludes the closed node and surfaces genuine current work;
#   S10 M03 REAL + proving history still selects the governed current work;
#   S11 M10 regression: Complete-GovernedCycle still not-applicable for a TRIAL stop;
#   S12 prior-cycle completion.json (different change) does NOT block closure;
#   S13 completion.json recording THIS change blocks closure (STOP_TRIAL_HAS_REAL_LIFECYCLE).
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:Cfg = Get-Content (Join-Path $script:Root "config\devbridge.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$script:RealWorkbook = $script:Cfg.developmentControlWorkbook
$script:SelftestRoot = Join-Path $script:Root "logs\selftest"
if (-not (Test-Path $script:SelftestRoot)) { New-Item -ItemType Directory -Force -Path $script:SelftestRoot | Out-Null }
$db124Root = Join-Path $script:SelftestRoot "db124"
if (Test-Path $db124Root) { Remove-Item $db124Root -Recurse -Force }
New-Item -ItemType Directory -Force -Path $db124Root | Out-Null

# Shared library (array-safe JSON) + read-only workbook library (for read-backs).
. (Join-Path $PSScriptRoot "Set-DevBridgeStateEntry.ps1")
. (Join-Path $PSScriptRoot "Read-DevelopmentControl.ps1")

function Get-Hash([string]$p) { return (Get-FileHash $p -Algorithm SHA256).Hash }

$script:RealHashBefore = Get-Hash $script:RealWorkbook

# Fixture baseline decoupling (post-live-closure): fixture workbooks must be
# generated from a PRISTINE workbook whose trial reservation row is still OPEN,
# never from the live authoritative workbook. The live workbook legitimately
# transitions as governed closures are performed (the DB-M12.4 live closure closed
# row 80 for CHG-20260830-017), so copying it would hand every fixture a Closed
# reservation row and the closure script would hit its ALREADY_CLOSED idempotence
# path instead of testing the open->closed transition. Source the pristine baseline
# from the most recent DB-M12.4 pre-closure backup (byte-identical to the recorded
# F520060C baseline) when present; fall back to the live workbook only in a fresh
# environment where no closure has ever run.
$script:PristineWorkbook = $script:RealWorkbook
$preclosureBackups = @(Get-ChildItem (Join-Path $script:Root "state\backups") -Filter "db-m124-preclosure-*.xlsx" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1)
if ($preclosureBackups.Count -ge 1) {
    $script:PristineWorkbook = [string]$preclosureBackups[0].FullName
}

$script:RepoStatusBefore = @(& git -C "C:\Personal\Nexus.Developer" status --porcelain=v1 2>$null)
$script:LiveTaskHashBefore = Get-Hash (Join-Path $script:Root "state\current-task.json")
$script:LiveClaudeHashBefore = Get-Hash (Join-Path $script:Root "state\claude-review.json")
$script:LiveHistoryHashBefore = $null
if (Test-Path (Join-Path $script:Root "state\trial-proving-history.json")) {
    $script:LiveHistoryHashBefore = Get-Hash (Join-Path $script:Root "state\trial-proving-history.json")
}

$script:Results = @()
$script:Fails = New-Object System.Collections.Generic.List[string]

function Assert-True([string]$label, [bool]$cond, [string]$detail) {
    $row = New-Object PSCustomObject
    $row | Add-Member NoteProperty -Name Scenario -Value $label
    $row | Add-Member NoteProperty -Name Pass -Value $cond
    $row | Add-Member NoteProperty -Name Detail -Value $detail
    $script:Results += $row
    if (-not $cond) {
        $script:Fails.Add(("{0}: {1}" -f $label, $detail))
        Write-Output ("  [FAIL] {0} - {1}" -f $label, $detail)
    } else {
        Write-Output ("  [PASS] {0}" -f $label)
    }
}

# ---- DB-M12.4 fixture --------------------------------------------------------
# A byte-identical workbook copy (live) + a second byte-identical copy standing in
# for the recorded M04 pre-reservation backup. current-task.json carries the full
# proven trial identity: dbM08/dbM06 TRIAL_ONLY_UNMERGED, m10Run false, git
# NOT_APPLICABLE, and reservationEvidence pointing at the backup with its SHA.
function New-F124([string]$name, [string]$status, [string]$nextAction, [string]$mode = "TRIAL") {
    $outDir = Join-Path $db124Root $name
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $stateDir = Join-Path $outDir "state"; $tasksDir = Join-Path $outDir "tasks"
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null
    $wbCopy = Join-Path $outDir "workbook.xlsx"
    Copy-Item $script:PristineWorkbook $wbCopy -Force
    $backupDir = Join-Path $stateDir "backups"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    # [string] coercion: Join-Path/Get-Hash outputs are PSObject-wrapped strings in
    # PS 5.1; a wrapped leaf inside a state hashtable breaks JavaScriptSerializer
    # ("circular reference: PSParameterizedProperty"). Coerce to plain strings.
    $backup = [string](Join-Path $backupDir "pre-reservation.xlsx")
    Copy-Item $script:PristineWorkbook $backup -Force
    $backupSha = [string](Get-Hash $backup)
    $cur = [ordered]@{
        nodeId = "WI-07-0.2.4"; taskId = "WI-07-0.2.4"; name = ("DB-M12.4 fixture " + $name)
        nodeType = "WorkItem"; phase = "P0"; layer = "App"; changeId = "CHG-20260830-017"
        status = $status; nextAllowedAction = $nextAction; selectedAt = "2026-08-31T00:00:00Z"
        mode = $mode
        dbM08 = [ordered]@{ implementationState = "TRIAL_ONLY_UNMERGED"; m10Run = $false; trialMode = $true }
        dbM06 = [ordered]@{ implementationState = "TRIAL_ONLY_UNMERGED"; trialMode = $true }
        gitLifecycleState = "NOT_APPLICABLE"
        reservationEvidence = [ordered]@{ backupPath = $backup; backupSha256 = $backupSha }
    }
    Write-DevBridgeJson (Join-Path $stateDir "current-task.json") $cur | Out-Null
    return @{ outDir = $outDir; stateDir = $stateDir; tasksDir = $tasksDir; wbCopy = $wbCopy; changeId = "CHG-20260830-017"; backup = $backup }
}

function Read-F124Task([hashtable]$f) {
    $raw = [System.IO.File]::ReadAllText((Join-Path $f.stateDir "current-task.json"))
    return $raw | ConvertFrom-Json
}

function Read-F124Json([hashtable]$f, [string]$relPath) {
    $raw = [System.IO.File]::ReadAllText((Join-Path $f.stateDir $relPath))
    return $raw | ConvertFrom-Json
}

function Write-F124Json([hashtable]$f, [string]$relPath, $obj) {
    Write-DevBridgeJson (Join-Path $f.stateDir $relPath) $obj | Out-Null
}

# ---- minimal OOXML cell writer (drift fixture only) --------------------------
# Mirrors the write helpers used by Close-TrialCycle.ps1 so the harness can drift a
# single Master Roadmap Status cell on a workbook copy. Only ever exercised against
# the fixture copy.
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
    $t.SetAttributeValue([System.Xml.Linq.XNamespace]"http://www.w3.org/XML/1998/namespace" + "space", "preserve")
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
function Write-Cell($sheetData, [int]$rowNum, [string]$col, [string]$value) {
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
        Set-CellValue $cell $value $false
    } else {
        $style = Get-ColStyle $sheetData $rowNum $col
        $nc = New-InlineCell ($col + $rowNum) $value $style
        Insert-CellSorted $rowEl $nc
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
# Drift one Master Roadmap Status cell on a workbook copy (fixture only).
function Set-RoadmapStatus([string]$path, [string]$nodeId, [string]$newStatus) {
    $prev = $script:DevControlWorkbook
    $statusCol = $null
    $rowNum = 0
    try {
        $script:DevControlWorkbook = $path
        $node = Get-RoadmapNodeById $nodeId
        if ($null -eq $node) { throw "node not found for drift: $nodeId" }
        $rowNum = [int]$node.Row
        $mrMap = @($script:DevControlMap.sheets | Where-Object { $_.name -eq "Master Roadmap" })[0]
        $mrHeader = [int]$mrMap.headerRow
        $statusCol = Get-ColumnForSheet "Master Roadmap" $mrHeader "Status"
    } finally {
        $script:DevControlWorkbook = $prev
    }
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry = Get-SheetEntryName "Master Roadmap"
        $doc = Load-SheetDoc $zip $entry
        $sd = $doc.Root.Element($xNs + "sheetData")
        Write-Cell $sd $rowNum $statusCol $newStatus
        Save-SheetDoc $zip $entry $doc
    } finally {
        $zip.Dispose()
        $fs.Dispose()
    }
}

# ---- workbook read-backs under a given workbook path --------------------------
function With-Workbook([string]$path, [scriptblock]$body) {
    $prev = $script:DevControlWorkbook
    $script:DevControlWorkbook = $path
    try { & $body } finally { $script:DevControlWorkbook = $prev }
}

# ---- Close-TrialCycle invocation (backend contract: always exit 0, markers only) -
function Invoke-Close([hashtable]$f, [hashtable]$envOverrides) {
    $engine = Join-Path $PSScriptRoot "Close-TrialCycle.ps1"
    Set-Item "env:DB24_STATE_DIR" $f.stateDir
    Set-Item "env:DB24_TASKS_DIR" $f.tasksDir
    Set-Item "env:DB24_WORKBOOK_OVERRIDE" $f.wbCopy
    Set-Item "env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE" $f.wbCopy
    foreach ($k in $envOverrides.Keys) { Set-Item ("env:" + $k) ([string]$envOverrides[$k]) }
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine 2>&1)
    } finally {
        $ErrorActionPreference = $oldEAP
    }
    $out = @($out | ForEach-Object { "$_" })
    foreach ($k in @("DB24_STATE_DIR","DB24_TASKS_DIR","DB24_WORKBOOK_OVERRIDE","DB_DEV_CONTROL_WORKBOOK_OVERRIDE")) { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue }
    foreach ($k in $envOverrides.Keys) { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue }

    $res = @{ outcome = "NO_OUTCOME"; pass = $false; resultCode = ""; wbModified = $false; gitModified = $false; human = $false; humanType = ""; evidence = @(); preState = ""; restoreRequired = $false; output = ($out -join "`n") }
    $ol = $out | Select-String -Pattern '^DB24_OUTCOME:\s*' | Select-Object -First 1
    if ($ol) { $res.outcome = ($ol.Line -replace '^DB24_OUTCOME:\s*', '') }
    $pl = $out | Select-String -Pattern '^DB24_RESULT_PASS: True' | Select-Object -First 1
    $res.pass = ($null -ne $pl)
    $wml = $out | Select-String -Pattern '^DB24_WORKBOOK_MODIFIED: True' | Select-Object -First 1
    $res.wbModified = ($null -ne $wml)
    $gml = $out | Select-String -Pattern '^DB24_GIT_MODIFIED: True' | Select-Object -First 1
    $res.gitModified = ($null -ne $gml)
    $hl = $out | Select-String -Pattern '^DB24_REQUIRES_HUMAN_ACTION: True' | Select-Object -First 1
    $res.human = ($null -ne $hl)
    $htl = $out | Select-String -Pattern '^DB24_HUMAN_ACTION_TYPE:\s*' | Select-Object -First 1
    if ($htl) { $res.humanType = ($htl.Line -replace '^DB24_HUMAN_ACTION_TYPE:\s*', '').Trim() }
    $psl = $out | Select-String -Pattern '^DB24_PRE_RESERVATION_STATE:\s*' | Select-Object -First 1
    if ($psl) { $res.preState = ($psl.Line -replace '^DB24_PRE_RESERVATION_STATE:\s*', '').Trim() }
    $rrl = $out | Select-String -Pattern '^DB24_RESTORE_REQUIRED:\s*' | Select-Object -First 1
    if ($rrl) { $res.restoreRequired = (($rrl.Line -replace '^DB24_RESTORE_REQUIRED:\s*', '').Trim() -eq "True") }
    foreach ($el in @($out | Select-String -Pattern '^DB24_EVIDENCE:\s*(.+)$')) {
        if ($el.Matches.Count -gt 0) { $res.evidence += [string]$el.Matches[0].Groups[1].Value }
    }
    return $res
}

# ---- Get-NextTask invocation --------------------------------------------------
function Invoke-NextTask([hashtable]$f, [string]$configPath) {
    $engine = Join-Path $PSScriptRoot "Get-NextTask.ps1"
    Set-Item "env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE" $f.wbCopy
    Set-Item "env:DB_NEXTTASK_STATE_DIR" $f.stateDir
    Set-Item "env:DB_NEXTTASK_CONFIG_PATH" $configPath
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine 2>&1)
    } finally {
        $ErrorActionPreference = $oldEAP
    }
    $out = @($out | ForEach-Object { "$_" })
    foreach ($k in @("DB_DEV_CONTROL_WORKBOOK_OVERRIDE","DB_NEXTTASK_STATE_DIR","DB_NEXTTASK_CONFIG_PATH")) { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue }

    $res = @{ status = ""; currentWork = ""; task = ""; blockState = ""; blockReason = ""; basis = @(); output = ($out -join "`n") }
    $sl = $out | Select-String -Pattern '^TaskSelectionStatus\s*:\s*' | Select-Object -First 1
    if ($sl) { $res.status = ($sl.Line -replace '^TaskSelectionStatus\s*:\s*', '').Trim() }
    $cl = $out | Select-String -Pattern '^CurrentWork\s*:\s*' | Select-Object -First 1
    if ($cl) { $res.currentWork = ($cl.Line -replace '^CurrentWork\s*:\s*', '').Trim() }
    $tl = $out | Select-String -Pattern '^Task\s*:\s*([A-Z0-9.-]+)' | Select-Object -First 1
    if ($tl) { $res.task = $tl.Matches[0].Groups[1].Value }
    $bs = $out | Select-String -Pattern '^BlockState\s*:\s*' | Select-Object -First 1
    if ($bs) { $res.blockState = ($bs.Line -replace '^BlockState\s*:\s*', '').Trim() }
    $br = $out | Select-String -Pattern '^BlockReason\s*:\s*' | Select-Object -First 1
    if ($br) { $res.blockReason = ($br.Line -replace '^BlockReason\s*:\s*', '').Trim() }
    foreach ($bl in @($out | Select-String -Pattern '^  - ')) { $res.basis += $bl.Line.Trim() }
    return $res
}

# ---- scenario S1: eligible safe-stop closure --------------------------------
Write-Output "== S1 safe-stop closure =="
$f = New-F124 "s1" "CLAUDE_REVIEW_PASSED_TRIAL" "TRIAL_CYCLE_SAFE_STOP"
$r = Invoke-Close $f @{}
Assert-True "S1 outcome TRIAL_CYCLE_CLOSED + pass + workbook modified" ($r.outcome -eq "TRIAL_CYCLE_CLOSED" -and $r.pass -and $r.wbModified -and -not $r.gitModified) ("got " + $r.outcome + " wb=" + $r.wbModified)
Assert-True "S1 no M10 / no PR / no human-gate" ($r.outcome -ne "COMPLETED" -and -not $r.human) ("human=" + $r.human)
Assert-True "S1 pre-reservation state proven Planned, restore no-op" ($r.preState -eq "Planned" -and -not $r.restoreRequired) ("pre=" + $r.preState + " restore=" + $r.restoreRequired)
$t = Read-F124Task $f
Assert-True "S1 state transition TRIAL_CYCLE_CLOSED / START_NEXT_CYCLE" ($t.status -eq "TRIAL_CYCLE_CLOSED" -and $t.nextAllowedAction -eq "START_NEXT_CYCLE") ("got " + $t.status + "/" + $t.nextAllowedAction)
$closure = Read-F124Json $f "trial-closure.json"
Assert-True "S1 trial-closure.json recorded (result/row/evidence/fingerprint)" ($closure.result -eq "TRIAL_CYCLE_CLOSED" -and $closure.nodeId -eq "WI-07-0.2.4" -and $closure.changeId -eq "CHG-20260830-017" -and $closure.fingerprintGuard.preserved) ("got " + $closure.result)
Assert-True "S1 pre-write backup SHA recorded as a real 64-hex SHA (not the path)" ($closure.preWriteBackupSha256 -match "^[0-9A-F]{64}$" -and $closure.preWriteBackupPath -match "db-m124-preclosure-") ("sha=" + $closure.preWriteBackupSha256)
Assert-True "S1 TRIAL_ONLY_UNMERGED preserved, no completion.json" ($closure.implementationState -eq "TRIAL_ONLY_UNMERGED" -and -not (Test-Path (Join-Path $f.stateDir "completion.json"))) ("impl=" + $closure.implementationState)
Assert-True "S1 no false completion text in closure evidence" (($closure | ConvertTo-Json -Depth 6) -notmatch "M10_COMPLETE|READY_FOR_GOVERNED_COMPLETION") "completion vocabulary found"
$hist = Read-F124Json $f "trial-proving-history.json"
Assert-True "S1 proving history appended with used nodeId" ($hist.entries.Count -eq 1 -and $hist.entries[0].nodeId -eq "WI-07-0.2.4" -and $hist.entries[0].implementationState -eq "TRIAL_ONLY_UNMERGED") ("entries=" + $hist.entries.Count)
Assert-True "S1 closure report written" (Test-Path (Join-Path $f.tasksDir "TRIAL_CYCLE_CLOSURE_REPORT.md")) "missing"
$bk = @(Get-ChildItem (Join-Path $f.stateDir "backups") -Filter "db-m124-preclosure-*.xlsx" -File -ErrorAction SilentlyContinue)
Assert-True "S1 pre-closure backup created" ($bk.Count -ge 1) ("backups=" + $bk.Count)

# Workbook read-backs on the fixture copy.
# NOTE: With-Workbook runs the body via & inside its own scope; a variable
# assigned inside the body never reaches the caller, so values must escape by
# being EMITTED from the body and captured by the assignment.
$acRow = With-Workbook $f.wbCopy {
    $ac = @(Get-AllActiveChanges | Where-Object { $_.ChangeId -eq "CHG-20260830-017" })
    if ($ac.Count -eq 1) { $ac[0] }
}
Assert-True "S1 reservation row exists and is now Closed-terminal (not Completed)" ($null -ne $acRow -and $acRow.Status -match "^\s*Closed") ("status='" + $(if ($null -eq $acRow) { "<null>" } else { $acRow.Status }) + "'")
$nodeStatus = [string](With-Workbook $f.wbCopy { [string](Get-RoadmapNodeById "WI-07-0.2.4").Status })
Assert-True "S1 roadmap node NOT completed (remains Planned)" ($nodeStatus -eq "Planned") ("got " + $nodeStatus)
$alMap = @($script:DevControlMap.sheets | Where-Object { $_.name -eq "Activity Log" })[0]
# Activity-log delta must be measured against the SAME pristine baseline the fixture
# was copied from, NOT the live workbook: the governed live closure legitimately
# appended one activity row to the live workbook, so its count is now one higher
# than the fixture's starting state. The assertion's intent is "the closure appends
# exactly one row to the fixture it ran against".
$alRowsBefore = @(With-Workbook $script:PristineWorkbook { @(Get-SheetRows "Activity Log" ([int]$alMap.headerRow) ([int]$alMap.dataStartRow) 2000) })
$alRowsAfter = @(With-Workbook $f.wbCopy { @(Get-SheetRows "Activity Log" ([int]$alMap.headerRow) ([int]$alMap.dataStartRow) 2000) })
Assert-True "S1 activity log grown by exactly one row" ($alRowsAfter.Count -eq ($alRowsBefore.Count + 1)) ("before=" + $alRowsBefore.Count + " after=" + $alRowsAfter.Count)
$actOp = With-Workbook $f.wbCopy {
    $hit = @(Get-SheetRows "Activity Log" ([int]$alMap.headerRow) ([int]$alMap.dataStartRow) 2000 | Where-Object { [string](Get-Value "Activity Log" $_ ([int]$alMap.headerRow) "Operation") -eq "Governed Trial Cycle Closure" })
    if ($hit.Count -eq 1) {
        [PSCustomObject]@{
            Op      = [string](Get-Value "Activity Log" $hit[0] ([int]$alMap.headerRow) "Operation")
            Entity  = [string](Get-Value "Activity Log" $hit[0] ([int]$alMap.headerRow) "Entity ID")
            Change  = [string](Get-Value "Activity Log" $hit[0] ([int]$alMap.headerRow) "Change ID")
            Result  = [string](Get-Value "Activity Log" $hit[0] ([int]$alMap.headerRow) "Result")
            Review  = [string](Get-Value "Activity Log" $hit[0] ([int]$alMap.headerRow) "Human Review Status")
        }
    }
}
Assert-True "S1 closure activity row correct (op/entity/change/result/not-reviewed)" ($null -ne $actOp -and $actOp.Op -eq "Governed Trial Cycle Closure" -and $actOp.Entity -match "WI-07-0.2.4" -and $actOp.Change -eq "CHG-20260830-017" -and $actOp.Result -eq "CLOSED" -and $actOp.Review -eq "Not Reviewed") ("got " + $actOp.Entity)

# S1 continuation: idempotence (S6) reuses the closed fixture.
Write-Output "== S6 idempotence =="
$alCountBeforeIdem = @(With-Workbook $f.wbCopy { @(Get-SheetRows "Activity Log" ([int]$alMap.headerRow) ([int]$alMap.dataStartRow) 2000) }).Count
$r6 = Invoke-Close $f @{}
Assert-True "S6 re-close -> TRIAL_CYCLE_ALREADY_CLOSED, pass true, no write" ($r6.outcome -eq "TRIAL_CYCLE_ALREADY_CLOSED" -and $r6.pass -and -not $r6.wbModified) ("got " + $r6.outcome)
$alCountAfterIdem = @(With-Workbook $f.wbCopy { @(Get-SheetRows "Activity Log" ([int]$alMap.headerRow) ([int]$alMap.dataStartRow) 2000) }).Count
Assert-True "S6 no duplicate activity rows on idempotent re-close" ($alCountAfterIdem -eq $alCountBeforeIdem) ("before=" + $alCountBeforeIdem + " after=" + $alCountAfterIdem)
$hist2 = Read-F124Json $f "trial-proving-history.json"
Assert-True "S6 proving history not duplicated" ($hist2.entries.Count -eq 1) ("entries=" + $hist2.entries.Count)

# ---- scenario S2: non-terminal trial state not closable -----------------------
Write-Output "== S2 not a safe stop =="
$f2 = New-F124 "s2" "VERIFIED" "CLAUDE_REVIEW"
$r2 = Invoke-Close $f2 @{}
Assert-True "S2 active/incomplete trial -> STOP_NOT_A_TRIAL_SAFE_STOP, no write" ($r2.outcome -eq "STOP_NOT_A_TRIAL_SAFE_STOP" -and -not $r2.pass -and -not $r2.wbModified) ("got " + $r2.outcome)
$t2 = Read-F124Task $f2
Assert-True "S2 no forced lifecycle transition" ($t2.status -eq "VERIFIED") ("got " + $t2.status)
Assert-True "S2 no closure evidence written" (-not (Test-Path (Join-Path $f2.stateDir "trial-closure.json"))) "trial-closure.json present"

# ---- scenario S3: REAL mode prohibited ----------------------------------------
Write-Output "== S3 REAL mode prohibited =="
$f3 = New-F124 "s3" "CLAUDE_REVIEW_PASSED_TRIAL" "TRIAL_CYCLE_SAFE_STOP" "REAL_NEXUS_DEVELOPMENT"
$r3 = Invoke-Close $f3 @{}
Assert-True "S3 REAL mode -> TRIAL_CYCLE_CLOSURE_PROHIBITED_REAL_MODE, no write" ($r3.outcome -eq "TRIAL_CYCLE_CLOSURE_PROHIBITED_REAL_MODE" -and -not $r3.pass -and -not $r3.wbModified) ("got " + $r3.outcome)
$t3 = Read-F124Task $f3
Assert-True "S3 no transition in REAL mode" ($t3.status -eq "CLAUDE_REVIEW_PASSED_TRIAL") ("got " + $t3.status)

# ---- scenario S4: restore drifted live status --------------------------------
Write-Output "== S4 restore drift =="
$f4 = New-F124 "s4" "CLAUDE_REVIEW_PASSED_TRIAL" "TRIAL_CYCLE_SAFE_STOP"
Set-RoadmapStatus $f4.wbCopy "WI-07-0.2.4" "In Progress"
$driftBefore = ""
$driftBefore = [string](With-Workbook $f4.wbCopy { [string](Get-RoadmapNodeById "WI-07-0.2.4").Status })
Assert-True "S4 drift applied on fixture copy only (live In Progress)" ($driftBefore -eq "In Progress") ("got " + $driftBefore)
$r4 = Invoke-Close $f4 @{}
Assert-True "S4 closure proceeds with restore required" ($r4.outcome -eq "TRIAL_CYCLE_CLOSED" -and $r4.pass -and $r4.restoreRequired -and $r4.preState -eq "Planned") ("got " + $r4.outcome + " pre=" + $r4.preState + " restore=" + $r4.restoreRequired)
$restoredStatus = [string](With-Workbook $f4.wbCopy { [string](Get-RoadmapNodeById "WI-07-0.2.4").Status })
Assert-True "S4 roadmap Status restored to the proven pre-reservation value" ($restoredStatus -eq "Planned") ("got " + $restoredStatus)
$c4 = Read-F124Json $f4 "trial-closure.json"
Assert-True "S4 restore recorded in closure evidence" ($c4.restoreRequired -and $c4.preReservationStatus -eq "Planned") ("restore=" + $c4.restoreRequired)

# ---- scenario S5: unprovable pre-reservation evidence blocks ------------------
Write-Output "== S5 unprovable pre-reservation state =="
$f5 = New-F124 "s5" "CLAUDE_REVIEW_PASSED_TRIAL" "TRIAL_CYCLE_SAFE_STOP"
$cur5 = [ordered]@{
    nodeId = "WI-07-0.2.4"; taskId = "WI-07-0.2.4"; name = "DB-M12.4 fixture s5"
    nodeType = "WorkItem"; phase = "P0"; layer = "App"; changeId = "CHG-20260830-017"
    status = "CLAUDE_REVIEW_PASSED_TRIAL"; nextAllowedAction = "TRIAL_CYCLE_SAFE_STOP"
    mode = "TRIAL"
    dbM08 = [ordered]@{ implementationState = "TRIAL_ONLY_UNMERGED"; m10Run = $false; trialMode = $true }
    dbM06 = [ordered]@{ implementationState = "TRIAL_ONLY_UNMERGED"; trialMode = $true }
    gitLifecycleState = "NOT_APPLICABLE"
    reservationEvidence = [ordered]@{ backupPath = [string](Join-Path $f5.stateDir "missing-backup.xlsx"); backupSha256 = [string](Get-Hash $f5.backup) }
}
Write-F124Json $f5 "current-task.json" $cur5
$r5 = Invoke-Close $f5 @{}
Assert-True "S5 missing backup -> TRIAL_PRE_RESERVATION_STATE_UNKNOWN, no write, human governance review" ($r5.outcome -eq "TRIAL_PRE_RESERVATION_STATE_UNKNOWN" -and -not $r5.pass -and -not $r5.wbModified -and $r5.human -and $r5.humanType -eq "HUMAN_GOVERNANCE_REVIEW") ("got " + $r5.outcome + " type=" + $r5.humanType)
$t5b = Read-F124Task $f5
Assert-True "S5 no transition when the previous state is unprovable" ($t5b.status -eq "CLAUDE_REVIEW_PASSED_TRIAL") ("got " + $t5b.status)

$f5c = New-F124 "s5c" "CLAUDE_REVIEW_PASSED_TRIAL" "TRIAL_CYCLE_SAFE_STOP"
$cur5c = [ordered]@{
    nodeId = "WI-07-0.2.4"; taskId = "WI-07-0.2.4"; name = "DB-M12.4 fixture s5c"
    nodeType = "WorkItem"; phase = "P0"; layer = "App"; changeId = "CHG-20260830-017"
    status = "CLAUDE_REVIEW_PASSED_TRIAL"; nextAllowedAction = "TRIAL_CYCLE_SAFE_STOP"
    mode = "TRIAL"
    dbM08 = [ordered]@{ implementationState = "TRIAL_ONLY_UNMERGED"; m10Run = $false; trialMode = $true }
    dbM06 = [ordered]@{ implementationState = "TRIAL_ONLY_UNMERGED"; trialMode = $true }
    gitLifecycleState = "NOT_APPLICABLE"
    reservationEvidence = [ordered]@{ backupPath = $f5c.backup; backupSha256 = "0000000000000000000000000000000000000000000000000000000000000000" }
}
Write-F124Json $f5c "current-task.json" $cur5c
$r5c = Invoke-Close $f5c @{}
Assert-True "S5 SHA mismatch -> TRIAL_PRE_RESERVATION_STATE_UNKNOWN (never guessed)" ($r5c.outcome -eq "TRIAL_PRE_RESERVATION_STATE_UNKNOWN" -and -not $r5c.pass -and -not $r5c.wbModified) ("got " + $r5c.outcome)

# ---- scenario S7: M03 control reproduces the prior selection ------------------
Write-Output "== M03 control / exclusion =="
$configPath = Join-Path $script:Root "config\devbridge.json"
$f7 = New-F124 "m03_control" "CLAUDE_REVIEW_PASSED_TRIAL" "TRIAL_CYCLE_SAFE_STOP"
$s7 = Invoke-NextTask $f7 $configPath
Assert-True "S7 M03 control (TRIAL, no history) selects the proven WI-07-0.2.4 (gap reproduced)" ($s7.status -eq "SELECTED" -and $s7.task -eq "WI-07-0.2.4") ("got " + $s7.status + " / " + $s7.task)

# ---- scenario S8: M03 TRIAL + proving history excludes the closed node --------
# DB-M03.1: M-07-0.2 is a governed Milestone container, NEVER the task. Its only
# planned child WI-07-0.2.4 is trial-proven-excluded; 5-10 are transitively
# dependency-blocked -> the honest block token is NO_IMPLEMENTABLE_DESCENDANT.
$f8 = New-F124 "m03_exclude" "CLAUDE_REVIEW_PASSED_TRIAL" "TRIAL_CYCLE_SAFE_STOP"
Write-F124Json $f8 "trial-proving-history.json" ([ordered]@{ entries = @([ordered]@{ nodeId = "WI-07-0.2.4"; changeId = "CHG-20260830-017"; closedAtUtc = "2026-08-31T01:00:00Z"; mode = "TRIAL"; result = "TRIAL_CYCLE_CLOSED"; implementationState = "TRIAL_ONLY_UNMERGED" }) })
$s8 = Invoke-NextTask $f8 $configPath
Assert-True "S8 M03 TRIAL excludes the closed WI-07-0.2.4 (never reselected)" ($s8.status -eq "NO_IMPLEMENTABLE_DESCENDANT" -and $s8.task -ne "WI-07-0.2.4") ("got " + $s8.status + " / " + $s8.task)
Assert-True "S8 M03 blocks the governed container M-07-0.2 (DB-M03.1: containers are never tasks; no eligible leaf descendant)" ($s8.status -eq "NO_IMPLEMENTABLE_DESCENDANT" -and $s8.task -eq "" -and $s8.currentWork -eq "M-07-0.2" -and $s8.blockState -eq "NO_IMPLEMENTABLE_DESCENDANT") ("got task=" + $s8.task + " cw=" + $s8.currentWork + " block=" + $s8.blockState)

# ---- scenario S9: M03 after an actual closure --------------------------------
# Same governed block: the S1 closure wrote the proving-history entry that excludes
# WI-07-0.2.4, so post-closure M03 also blocks M-07-0.2 rather than surfacing a container.
$s9 = Invoke-NextTask $f $configPath
Assert-True "S9 post-closure M03 blocks M-07-0.2 (NO_IMPLEMENTABLE_DESCENDANT; closed WI-07-0.2.4 trial-excluded, 5-10 dependency-blocked)" ($s9.status -eq "NO_IMPLEMENTABLE_DESCENDANT" -and $s9.task -eq "" -and $s9.currentWork -eq "M-07-0.2" -and $s9.blockState -eq "NO_IMPLEMENTABLE_DESCENDANT") ("got " + $s9.status + " / task=" + $s9.task + " cw=" + $s9.currentWork)

# ---- scenario S10: M03 REAL mode unaffected by proving history ---------------
$f10 = New-F124 "m03_real" "CLAUDE_REVIEW_PASSED_TRIAL" "TRIAL_CYCLE_SAFE_STOP" "REAL_NEXUS_DEVELOPMENT"
Write-F124Json $f10 "trial-proving-history.json" ([ordered]@{ entries = @([ordered]@{ nodeId = "WI-07-0.2.4"; changeId = "CHG-20260830-017"; closedAtUtc = "2026-08-31T01:00:00Z"; mode = "TRIAL"; result = "TRIAL_CYCLE_CLOSED"; implementationState = "TRIAL_ONLY_UNMERGED" }) })
$s10 = Invoke-NextTask $f10 $configPath
Assert-True "S10 M03 REAL unaffected: still selects WI-07-0.2.4" ($s10.status -eq "SELECTED" -and $s10.task -eq "WI-07-0.2.4") ("got " + $s10.status + " / " + $s10.task)

# ---- scenario S11: M10 regression (unchanged for TRIAL stops) -----------------
Write-Output "== S11 M10 regression =="
$f11 = New-F124 "s11" "CLAUDE_REVIEW_PASSED_TRIAL" "TRIAL_CYCLE_SAFE_STOP"
Set-Item "env:DB10_STATE_DIR" $f11.stateDir
Set-Item "env:DB10_TASKS_DIR" $f11.tasksDir
$oldEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$m10out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Complete-GovernedCycle.ps1") -NodeId "WI-07-0.2.4" -ChangeId "CHG-20260830-017" 2>&1)
$ErrorActionPreference = $oldEAP
foreach ($k in @("DB10_STATE_DIR","DB10_TASKS_DIR")) { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue }
$m10line = $m10out | Select-String -Pattern '^DB10_OUTCOME:\s*' | Select-Object -First 1
$m10token = if ($m10line) { ($m10line.Line -replace '^DB10_OUTCOME:\s*', '').Trim() } else { "NO_MARKER" }
Assert-True "S11 M10 unchanged: TRIAL safe-stop -> TRIAL_COMPLETION_NOT_APPLICABLE, no write" ($m10token -eq "TRIAL_COMPLETION_NOT_APPLICABLE") ("got " + $m10token)
Assert-True "S11 no completion evidence produced by M10" (-not (Test-Path (Join-Path $f11.stateDir "completion.json"))) "completion.json present"

# ---- scenario S12: a PRIOR cycle's completion.json (different change) must NOT ----
# block closure. M10 writes a single per-cycle state/completion.json that is never
# cleared when the next cycle is reserved; the shared state dir can hold a genuine
# completion record for a PREVIOUS work item next to the current trial. The
# real-lifecycle guard must scope by the completion record's OWN changeId.
Write-Output "== S12 prior-cycle completion.json does not block =="
$f12 = New-F124 "s12" "CLAUDE_REVIEW_PASSED_TRIAL" "TRIAL_CYCLE_SAFE_STOP"
Write-F124Json $f12 "completion.json" ([ordered]@{
    milestone = "DB-M10"; nodeId = "WI-07-0.2.3"; changeId = "CHG-20260830-016"
    status = "COMPLETION_WRITTEN"; completedAtUtc = "2026-08-31T00:00:00Z"
})
$r12 = Invoke-Close $f12 @{}
Assert-True "S12 prior-cycle completion.json (CHG-20260830-016) does not block closure" ($r12.outcome -eq "TRIAL_CYCLE_CLOSED" -and $r12.pass -and $r12.wbModified) ("got " + $r12.outcome)
Assert-True "S12 prior completion record preserved untouched" ([string]((Read-F124Json $f12 "completion.json").changeId) -eq "CHG-20260830-016") "completion.json altered"
Assert-True "S12 closure evidence written" (Test-Path (Join-Path $f12.stateDir "trial-closure.json")) "trial-closure.json missing"

# ---- scenario S13: a completion.json recording THIS change must block closure -----
Write-Output "== S13 same-change completion.json blocks =="
$f13 = New-F124 "s13" "CLAUDE_REVIEW_PASSED_TRIAL" "TRIAL_CYCLE_SAFE_STOP"
Write-F124Json $f13 "completion.json" ([ordered]@{
    milestone = "DB-M10"; nodeId = "WI-07-0.2.4"; changeId = "CHG-20260830-017"
    status = "COMPLETION_WRITTEN"; completedAtUtc = "2026-08-31T00:00:00Z"
})
$r13 = Invoke-Close $f13 @{}
Assert-True "S13 same-change completion.json -> STOP_TRIAL_HAS_REAL_LIFECYCLE, no write" ($r13.outcome -eq "STOP_TRIAL_HAS_REAL_LIFECYCLE" -and -not $r13.pass -and -not $r13.wbModified -and $r13.human) ("got " + $r13.outcome)
Assert-True "S13 no closure evidence written" (-not (Test-Path (Join-Path $f13.stateDir "trial-closure.json"))) "trial-closure.json present"
$t13 = Read-F124Task $f13
Assert-True "S13 no forced lifecycle transition" ($t13.status -eq "CLAUDE_REVIEW_PASSED_TRIAL") ("got " + $t13.status)

# ---- invariants over the real workbook + repo + live evidence ----------------
Write-Output "== invariants =="
$realHashAfter = Get-Hash $script:RealWorkbook
Assert-True "I1 authoritative workbook untouched by suite" ($realHashAfter -eq $script:RealHashBefore) "authoritative workbook hash changed"
# I1 (governed recorded state): after a governed live closure the authoritative
# workbook is LEGITIMATELY no longer the pristine F520060C baseline (the closure
# closed row 80 for CHG-20260830-017). The reference for "where the live workbook
# must be" is the recorded post-closure SHA in state/trial-closure.json once a live
# closure has been performed; with no closure ever run it must still be the pristine
# F520060C baseline. The suite itself never writes the live workbook (checked above).
$expectedLiveSha = "F520060CB753EC8EC96B44BCBD193BDAB69CA68D4CC27198663665D5FE63F884"
$liveClosurePath = Join-Path $script:Root "state\trial-closure.json"
if (Test-Path $liveClosurePath) {
    $lcDoc = Read-DevBridgeJson $liveClosurePath
    $recordedSha = [string](Get-DevBridgeField $lcDoc "postWorkbookSha256")
    if ($recordedSha) { $expectedLiveSha = $recordedSha }
}
Assert-True "I1 authoritative workbook matches its governed recorded state" ($realHashAfter -eq $expectedLiveSha) ("got " + $realHashAfter + " expected " + $expectedLiveSha)
$repoStatusAfter = @(& git -C "C:\Personal\Nexus.Developer" status --porcelain=v1 2>$null)
$repoDelta = @($repoStatusAfter | Where-Object { $script:RepoStatusBefore -notcontains $_ })
$repoDeltaRev = @($script:RepoStatusBefore | Where-Object { $repoStatusAfter -notcontains $_ })
Assert-True "I2 nexus repo git state untouched by suite" ($repoDelta.Count -eq 0 -and $repoDeltaRev.Count -eq 0) ("delta: " + (($repoDelta + $repoDeltaRev) -join "; "))
$liveTaskHashAfter = Get-Hash (Join-Path $script:Root "state\current-task.json")
$liveClaudeHashAfter = Get-Hash (Join-Path $script:Root "state\claude-review.json")
Assert-True "I3 live trial evidence (current-task.json) untouched" ($liveTaskHashAfter -eq $script:LiveTaskHashBefore) "current-task.json changed"
Assert-True "I3 live trial evidence (claude-review.json) untouched" ($liveClaudeHashAfter -eq $script:LiveClaudeHashBefore) "claude-review.json changed"
if ($null -ne $script:LiveHistoryHashBefore) {
    $liveHistoryHashAfter = Get-Hash (Join-Path $script:Root "state\trial-proving-history.json")
    Assert-True "I3 live trial proving history untouched" ($liveHistoryHashAfter -eq $script:LiveHistoryHashBefore) "trial-proving-history.json changed"
}

# I4 no prior WI/CHG identity hard-coded in the DB-M12.4 reusable scripts
$hardcoded = ""
foreach ($name in @("Close-TrialCycle.ps1","Get-NextTask.ps1")) {
    $content = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot $name))
    if ($content -match "WI-07-0\.2\.4|CHG-20260830-017|CHG-20260830-016|ACT-20260830-018") { $hardcoded += " " + $name }
}
Assert-True "I4 no prior WI/CHG identity hard-coded in DB-M12.4 scripts" ($hardcoded -eq "") ("hardcoded in:" + $hardcoded)

# I5 no roadmap-structure mutation capability in the DB-M12.4 scripts.
# The completion vocabulary itself is REQUIRED here: Close-TrialCycle.ps1 must DETECT and
# REJECT a real merge/completion lifecycle ($gitLifecycle -in @("MERGED",
# "READY_FOR_GOVERNED_COMPLETION")), and Get-NextTask.ps1 reads Phase Plan step status
# ("Completed"/"Complete") to skip already-done steps. A bare-word scan would be a false
# positive. What the scripts must never do is WRITE such a status or EMIT it as an outcome
# token. So this probes the write/emit surfaces only: Set-DevBridgeStateEntry status values,
# Out-Markers outcome tokens, and any structural-edit primitive.
$structMarks = ""
foreach ($name in @("Close-TrialCycle.ps1","Get-NextTask.ps1")) {
    $content = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot $name))
    if ($content -match "Phase Plan" -and $content -match "Set-.*Phase") { $structMarks += " phase-sheet:" + $name }
    if ($content -match 'Set-DevBridgeStateEntry\s+[^\r\n]*status\s*=\s*["'']?(COMPLETED|READY_FOR_GOVERNED_COMPLETION|M10_COMPLETE)') { $structMarks += " completion-write:" + $name }
    if ($content -match 'Out-Markers\s+["''](COMPLETED|READY_FOR_GOVERNED_COMPLETION|M10_COMPLETE)["'']') { $structMarks += " completion-outcome:" + $name }
    if ($content -match "Add-RoadmapNode|New-RoadmapNode|Remove-RoadmapNode|Insert-Roadmap") { $structMarks += " structure-edit:" + $name }
}
Assert-True "I5 no completion/roadmap-structure mutation capability in DB-M12.4 scripts" ($structMarks -eq "") ("markers:" + $structMarks)

# I6 the DevBridge solution still builds
Write-Output "== I6 solution build =="
$sln = Join-Path $script:Root "src\DevBridge.slnx"
$oldEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$buildOut = @(& dotnet build $sln 2>&1)
$buildExit = $LASTEXITCODE
$ErrorActionPreference = $oldEAP
Assert-True "I6 solution build passes" ($buildExit -eq 0) ("build exit " + $buildExit)
$warnCount = @($buildOut | Select-String -Pattern "warning CS").Count
$errCount = @($buildOut | Select-String -Pattern "error CS").Count
Assert-True "I6 build has no compiler warnings" ($warnCount -eq 0) ("warnings " + $warnCount)
Assert-True "I6 build has no compiler errors" ($errCount -eq 0) ("errors " + $errCount)

# --- summary ------------------------------------------------------------------
Write-Output ""
$failCount = $script:Fails.Count
Write-Output ("DB-M12.4 SAFETY SUMMARY: {0} checks, {1} passed, {2} failed" -f $script:Results.Count, ($script:Results.Count - $failCount), $failCount)
if ($failCount -gt 0) {
    Write-Output "FAILURES:"
    foreach ($f in $script:Fails) { Write-Output ("  - " + $f) }
    exit 1
}
Write-Output "DB-M12.4: ALL PASS"
exit 0
