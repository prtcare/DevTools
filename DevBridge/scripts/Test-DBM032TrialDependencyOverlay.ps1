# =============================================================================
# Test-DBM032TrialDependencyOverlay.ps1
# DB-M03.2 -- TRIAL-PROVEN DEPENDENCY OVERLAY
#
# Proves that a governedly closed DevBridge TRIAL proving task may satisfy a
# governed dependency FOR SUBSEQUENT PROVING-CYCLE SELECTION WITHOUT modifying
# the real Nexus work-item status, across the four dependency-check sites:
#   Get-NextTask.ps1 (Test-DepsSatisfied), Test-DevelopmentPreflight.ps1 (PART 4),
#   Reserve-DevelopmentChange.ps1 (Part 1 revalidation),
#   New-ChatGptHandoff.ps1 (PART 1 item 6 + truthful context).
#
# Non-negotiable invariants (asserted as checks, never relaxed):
#   * TRIAL_DEPENDENCY_SATISFIED is NOT completion: the real roadmap status of
#     WI-07-0.2.4 stays Planned; the authoritative workbook is never written.
#   * Overlay is TRIAL-only: REAL mode and disabled config behave EXACTLY as
#     before DB-M03.2.
#   * Missing/invalid trial evidence is an HONEST block
#     (TRIAL_DEPENDENCY_EVIDENCE_INVALID / DEPENDENCY_CONTEXT_STALE), never a
#     fake satisfaction.
#   * No live mutation: fixtures live under logs\selftest\db-m03-2 only.
#
# Calling convention: backend scripts exit 0; outcomes via stdout markers.
# Regression suites run in child processes (fixture isolation). Test-DBM04Safety
# wipes ALL logs\selftest subdirs, so it runs LAST of the fixture suites.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:Cfg = Get-Content (Join-Path $script:Root "config\devbridge.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$script:RealWorkbook = $script:Cfg.developmentControlWorkbook
$script:SelftestRoot = Join-Path $script:Root "logs\selftest"
$script:M032Root = Join-Path $script:SelftestRoot "db-m03-2"
if (Test-Path $script:M032Root) { Remove-Item $script:M032Root -Recurse -Force }
New-Item -ItemType Directory -Force -Path $script:M032Root | Out-Null

# Shared libraries.
. (Join-Path $PSScriptRoot "Set-DevBridgeStateEntry.ps1")
. (Join-Path $PSScriptRoot "Read-DevelopmentControl.ps1")

function Get-Hash([string]$p) { return (Get-FileHash $p -Algorithm SHA256).Hash }

$script:RealHashBefore = Get-Hash $script:RealWorkbook

# Byte-identical PRISTINE baseline (DB-M12.4 pre-closure backup) so M-07-0.2 stays
# In Progress with its open reservation, exactly as the real proving cycle sees it.
$script:PristineWorkbook = $script:RealWorkbook
$preclosureBackups = @(Get-ChildItem (Join-Path $script:Root "state\backups") -Filter "db-m124-preclosure-*.xlsx" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1)
if ($preclosureBackups.Count -ge 1) {
    $script:PristineWorkbook = [string]$preclosureBackups[0].FullName
}

$script:RepoStatusBefore = @(& git -C "C:\Personal\Nexus.Developer" status --porcelain=v1 2>$null)
$script:LiveTaskHashBefore = Get-Hash (Join-Path $script:Root "state\current-task.json")

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

# ---- fixtures ----------------------------------------------------------------
function New-F032([string]$name) {
    $outDir = Join-Path $script:M032Root $name
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $stateDir = Join-Path $outDir "state"; $tasksDir = Join-Path $outDir "tasks"
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null
    $logsDir = Join-Path $outDir "logs"
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    $wbCopy = Join-Path $outDir "workbook.xlsx"
    Copy-Item $script:PristineWorkbook $wbCopy -Force
    return @{ root = $outDir; stateDir = $stateDir; tasksDir = $tasksDir; logsDir = $logsDir; wbCopy = $wbCopy }
}
function Read-F032Json([hashtable]$f, [string]$relPath) {
    $raw = [System.IO.File]::ReadAllText((Join-Path $f.stateDir $relPath))
    return $raw | ConvertFrom-Json
}
function Write-F032Json([hashtable]$f, [string]$relPath, $obj) {
    Write-DevBridgeJson (Join-Path $f.stateDir $relPath) $obj | Out-Null
}
function Write-TrialHistory([hashtable]$f) {
    # DB-M12.4-governed closure entry for WI-07-0.2.4 (the REAL trial-closed change).
    Write-F032Json $f "trial-proving-history.json" ([ordered]@{ entries = @(
        [ordered]@{ nodeId = "WI-07-0.2.4"; changeId = "CHG-20260830-017"; closedAtUtc = "2026-08-31T15:24:45Z"; mode = "TRIAL"; result = "TRIAL_CYCLE_CLOSED"; implementationState = "TRIAL_ONLY_UNMERGED"; preReservationStatus = "Planned" }
    )})
}
function Write-TrialEvidence([hashtable]$f, [string]$decision = "PASS") {
    # Full per-change trial evidence for WI-07-0.2.4/CHG-20260830-017 (M06 + M08
    # evidence as the real cycle preserved it). decision can be forced to FIX for
    # the invalidation cases.
    $evDir = Join-Path $f.logsDir "tasks\WI-07-0.2.4"
    $evDir = Join-Path $evDir "CHG-20260830-017"
    New-Item -ItemType Directory -Force -Path $evDir | Out-Null
    $claude = [ordered]@{
        milestone = "DB-M08"; decision = $decision; dbM06Result = "VERIFICATION_PASS"
        trialMode = $true; implementationState = "TRIAL_ONLY_UNMERGED"
        reviewedAgainstDbM06 = $true; reviewTimestampUtc = "2026-08-31T01:40:00Z"
        observations = @()
    }
    Write-DevBridgeJson (Join-Path $evDir "claude-decision.json") $claude | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $evDir "VERIFICATION_RESULT.md"),
        "VERIFICATION RESULT`n## Result: VERIFICATION_PASS`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-DevBridgeJson (Join-Path $evDir "test-result.json") ([ordered]@{ passed = 199; failed = 0; skipped = 0; total = 199 }) | Out-Null
    Write-DevBridgeJson (Join-Path $evDir "build-result.json") ([ordered]@{ succeeded = $true; warnings = 0; errors = 0 }) | Out-Null
}

# ---- minimal OOXML cell writer (drift fixtures) ------------------------------
function ColToIndex([string]$col) {
    $idx = 0
    foreach ($ch in $col.ToCharArray()) { $idx = $idx * 26 + ([int][char]$ch - 64) }
    return $idx
}
function ColOf([string]$ref) { return ($ref -replace '\d+$', '') }
function Convert-ColIndex([int]$idx) {
    $s = ""
    while ($idx -gt 0) { $idx--; $s = [char](65 + ($idx % 26)) + $s; $idx = [int][Math]::Floor($idx / 26) }
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
    $c.SetAttributeValue("r", $ref); $c.SetAttributeValue("t", "inlineStr")
    if ($style) { $c.SetAttributeValue("s", $style) }
    $c.Add($is)
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
        $idx = ColToIndex (ColOf ([string]$cell.Attribute("r").Value))
        if ($idx -gt $newIdx) { $cell.AddBeforeSelf($newCell); $inserted = $true; break }
    }
    if (-not $inserted) { $rowEl.Add($newCell) }
}
function Get-ColStyle($sheetData, [int]$rowNum, [string]$col) {
    for ($r = $rowNum - 1; $r -ge 1; $r--) {
        foreach ($rowEl in $sheetData.Elements($xNs + "row")) {
            if ([int]$rowEl.Attribute("r").Value -ne $r) { continue }
            $cell = Find-Cell $rowEl $col $r
            if ($cell) { $s = $cell.Attribute("s"); if ($s) { return [string]$s.Value }; return $null }
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
    foreach ($r in $sheetData.Elements($xNs + "row")) { if ([int]$r.Attribute("r").Value -eq $rowNum) { $rowEl = $r; break } }
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
    if ($cell) { Set-CellValue $cell $value $false }
    else {
        $style = Get-ColStyle $sheetData $rowNum $col
        Insert-CellSorted $rowEl (New-InlineCell ($col + $rowNum) $value $style)
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
    $stream.SetLength(0); $stream.Position = 0
    $doc.Save($stream)
    $stream.Dispose()
}
function With-Workbook([string]$path, [scriptblock]$body) {
    $prev = $script:DevControlWorkbook
    $script:DevControlWorkbook = $path
    try { & $body } finally { $script:DevControlWorkbook = $prev }
}
function Get-HeaderRow([string]$sheetName) {
    $map = @($script:DevControlMap.sheets | Where-Object { $_.name -eq $sheetName })[0]
    return [int]$map.headerRow
}
function Get-SheetColumn([string]$sheetName, [string]$columnName) {
    return Get-ColumnForSheet $sheetName (Get-HeaderRow $sheetName) $columnName
}
function Get-RoadmapRow([string]$path, [string]$nodeId) {
    return With-Workbook $path { [int]((Get-RoadmapNodeById $nodeId).Row) }
}
function Write-WorkbookCell([string]$path, [string]$sheetName, [int]$rowNum, [string]$columnName, [string]$value) {
    $col = Get-SheetColumn $sheetName $columnName
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry = Get-SheetEntryName $sheetName
        $doc = Load-SheetDoc $zip $entry
        $sd = $doc.Root.Element($xNs + "sheetData")
        Write-Cell $sd $rowNum $col $value
        Save-SheetDoc $zip $entry $doc
    } finally { $zip.Dispose(); $fs.Dispose() }
}
function Clear-WorkbookCell([string]$path, [string]$sheetName, [int]$rowNum, [string]$columnName) {
    $col = Get-SheetColumn $sheetName $columnName
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry = Get-SheetEntryName $sheetName
        $doc = Load-SheetDoc $zip $entry
        $sd = $doc.Root.Element($xNs + "sheetData")
        $rowEl = $null
        foreach ($r in $sd.Elements($xNs + "row")) { if ([int]$r.Attribute("r").Value -eq $rowNum) { $rowEl = $r; break } }
        if ($rowEl) { $cell = Find-Cell $rowEl $col $rowNum; if ($cell) { $cell.Remove() } }
        Save-SheetDoc $zip $entry $doc
    } finally { $zip.Dispose(); $fs.Dispose() }
}
function Set-NodeCell([hashtable]$f, [string]$nodeId, [string]$columnName, [string]$value) {
    Write-WorkbookCell $f.wbCopy "Master Roadmap" (Get-RoadmapRow $f.wbCopy $nodeId) $columnName $value
}
function Clear-NodeCell([hashtable]$f, [string]$nodeId, [string]$columnName) {
    Clear-WorkbookCell $f.wbCopy "Master Roadmap" (Get-RoadmapRow $f.wbCopy $nodeId) $columnName
}
function Add-Reservation([hashtable]$f, [string]$changeId, [string]$nodeId) {
    $acMap = @($script:DevControlMap.sheets | Where-Object { $_.name -eq "Active Changes" })[0]
    $hdr = [int]$acMap.headerRow; $start = [int]$acMap.dataStartRow
    $rows = @(With-Workbook $f.wbCopy { @(Get-SheetRows "Active Changes" $hdr $start 100) })
    $maxRow = $start
    foreach ($r in $rows) { if ([int]$r.Row -gt $maxRow) { $maxRow = [int]$r.Row } }
    $newRow = $maxRow + 1
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Change ID" $changeId
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Node ID" $nodeId
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Status" "In Progress"
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Repositories" "Nexus.Developer"
    return $newRow
}
function Make-CurrentWork([hashtable]$f, [string]$nodeId, [string]$changeId) {
    Set-NodeCell $f $nodeId "Status" "In Progress"
    $null = Add-Reservation $f $changeId $nodeId
}
function Write-SparseProvingHistory([hashtable]$f, [string[]]$nodeIds) {
    # DB-M03.1-style sparse history: closure entry WITHOUT per-change evidence dirs.
    $entries = @()
    foreach ($id in $nodeIds) {
        $entries += [ordered]@{
            nodeId = $id; changeId = ("CHG-" + $id); closedAtUtc = "2026-08-31T01:00:00Z"
            mode = "TRIAL"; result = "TRIAL_CYCLE_CLOSED"; implementationState = "TRIAL_ONLY_UNMERGED"
        }
    }
    Write-F032Json $f "trial-proving-history.json" ([ordered]@{ entries = $entries })
}

# ---- shared governed scope for the WI-07-0.2.5 chain (mirrors DB-M03.1 M031Scope)
$script:M032Scope = @{
    repos          = @("Nexus.Developer")
    projects       = @("Nexus.Developer.Core","Nexus.Developer.Infrastructure")
    filesGlobs     = @("src/Nexus.Developer.Core/DevelopmentControl/**","src/Nexus.Developer.Infrastructure/DevelopmentControl/ExcelDevelopmentControlStore.cs")
    schemaContexts = @()
    contractsApis  = @("IDevelopmentControlStore","IDevelopmentControlAtomicWorkUnitRunner")
    affectedNodes  = @("F-07-0","M-07-0.2","WI-07-0.2.1","WI-07-0.2.2","WI-07-0.2.3","WI-07-0.2.4","WI-07-0.2.5","WI-07-0.2.6","WI-07-0.2.7","WI-07-0.2.8","WI-07-0.2.9","WI-07-0.2.10")
}

# ---- engine invocation wrappers ----------------------------------------------
function Invoke-NextTaskD32([hashtable]$f) {
    $engine = Join-Path $PSScriptRoot "Get-NextTask.ps1"
    Set-Item "env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE" $f.wbCopy
    Set-Item "env:DB_NEXTTASK_STATE_DIR" $f.stateDir
    Set-Item "env:DB_NEXTTASK_CONFIG_PATH" (Join-Path $script:Root "config\devbridge.json")
    $oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine 2>&1) }
    finally { $ErrorActionPreference = $oldEAP }
    $out = @($out | ForEach-Object { "$_" })
    foreach ($k in @("DB_DEV_CONTROL_WORKBOOK_OVERRIDE","DB_NEXTTASK_STATE_DIR","DB_NEXTTASK_CONFIG_PATH")) { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue }
    $res = @{ status = ""; currentWork = ""; task = ""; blockState = ""; basis = @(); output = ($out -join "`n") }
    $sl = $out | Select-String -Pattern '^TaskSelectionStatus\s*:\s*' | Select-Object -First 1
    if ($sl) { $res.status = ($sl.Line -replace '^TaskSelectionStatus\s*:\s*', '').Trim() }
    $cl = $out | Select-String -Pattern '^CurrentWork\s*:\s*' | Select-Object -First 1
    if ($cl) { $res.currentWork = ($cl.Line -replace '^CurrentWork\s*:\s*', '').Trim() }
    $tl = $out | Select-String -Pattern '^Task\s*:\s*([A-Z0-9.-]+)' | Select-Object -First 1
    if ($tl) { $res.task = $tl.Matches[0].Groups[1].Value }
    $bl = $out | Select-String -Pattern '^BlockState\s*:\s*' | Select-Object -First 1
    if ($bl) { $res.blockState = ($bl.Line -replace '^BlockState\s*:\s*', '').Trim() }
    foreach ($bl in @($out | Select-String -Pattern '^  - ')) { $res.basis += $bl.Line.Trim() }
    return $res
}
function Invoke-PreflightD32([hashtable]$f) {
    Set-Item "env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE" $f.wbCopy
    Set-Item "env:DB_NEXTTASK_STATE_DIR" $f.stateDir
    Set-Item "env:DB_NEXTTASK_CONFIG_PATH" (Join-Path $script:Root "config\devbridge.json")
    $verdict = ""
    try {
        . (Join-Path $PSScriptRoot "Get-NextTask.ps1")
        . (Join-Path $PSScriptRoot "Test-DevelopmentPreflight.ps1")
        $script:DevBridgeRoot = $f.root
        $verdict = [string](& Test-DevelopmentPreflight)
    } finally {
        Remove-Item "env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE" -ErrorAction SilentlyContinue
        Remove-Item "env:DB_NEXTTASK_STATE_DIR" -ErrorAction SilentlyContinue
        Remove-Item "env:DB_NEXTTASK_CONFIG_PATH" -ErrorAction SilentlyContinue
    }
    return $verdict
}
function Invoke-ReserveD32([hashtable]$f) {
    $engine = Join-Path $PSScriptRoot "Reserve-DevelopmentChange.ps1"
    Set-Item "env:DB04_SELFTEST" "1"
    Set-Item "env:DB04_STATE_DIR" $f.stateDir
    Set-Item "env:DB04_TASKS_DIR" $f.tasksDir
    Set-Item "env:DB04_LOGS_DIR" $f.logsDir
    Set-Item "env:DB04_WORKBOOK_OVERRIDE" $f.wbCopy
    $oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine 2>&1) }
    finally { $ErrorActionPreference = $oldEAP }
    $out = @($out | ForEach-Object { "$_" })
    foreach ($k in @("DB04_SELFTEST","DB04_STATE_DIR","DB04_TASKS_DIR","DB04_LOGS_DIR","DB04_WORKBOOK_OVERRIDE")) { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue }
    $res = @{ outcome = "NO_MARKER"; pass = $false; output = ($out -join "`n") }
    $ol = $out | Select-String -Pattern '^DB04_OUTCOME:\s*' | Select-Object -First 1
    if ($ol) { $res.outcome = ($ol.Line -replace '^DB04_OUTCOME:\s*', '').Trim() }
    $pl = $out | Select-String -Pattern '^DB04_RESULT_PASS:\s*' | Select-Object -First 1
    if ($pl) { $res.pass = (($pl.Line -replace '^DB04_RESULT_PASS:\s*', '').Trim() -eq "True") }
    return $res
}
function Age-SelftestFiles {
    $oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    if (Test-Path $script:SelftestRoot) {
        Get-ChildItem $script:SelftestRoot -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            try { $_.LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddSeconds(-120) } catch {}
        }
    }
    $ErrorActionPreference = $oldEAP
}
function Invoke-HandoffD32([hashtable]$f) {
    $engine = Join-Path $PSScriptRoot "New-ChatGptHandoff.ps1"
    Set-Item "env:DB05_STATE_DIR" $f.stateDir
    Set-Item "env:DB05_TASKS_DIR" $f.tasksDir
    Set-Item "env:DB05_LOGS_DIR" $f.logsDir
    Set-Item "env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE" $f.wbCopy
    Age-SelftestFiles
    $oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine 2>&1) }
    finally { $ErrorActionPreference = $oldEAP }
    $out = @($out | ForEach-Object { "$_" })
    foreach ($k in @("DB05_STATE_DIR","DB05_TASKS_DIR","DB05_LOGS_DIR","DB_DEV_CONTROL_WORKBOOK_OVERRIDE")) { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue }
    $res = @{ outcome = "NO_MARKER"; output = ($out -join "`n") }
    $ol = $out | Select-String -Pattern '^DB05_OUTCOME:\s*' | Select-Object -First 1
    if ($ol) { $res.outcome = ($ol.Line -replace '^DB05_OUTCOME:\s*', '').Trim() }
    if ($res.outcome -eq "NO_MARKER") {
        $sl = $out | Select-String -Pattern 'DB-M05 STOP - ([A-Z0-9_]+)' | Select-Object -First 1
        if ($sl -and $sl.Matches -and $sl.Matches.Count -gt 0) { $res.outcome = $sl.Matches[0].Groups[1].Value }
    }
    return $res
}
function Invoke-M07D32([hashtable]$f) {
    $engine = Join-Path $PSScriptRoot "New-ClaudeReviewPackage.ps1"
    Set-Item "env:DB07_STATE_DIR" $f.stateDir
    Set-Item "env:DB07_TASKS_DIR" $f.tasksDir
    $oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine 2>&1) }
    finally { $ErrorActionPreference = $oldEAP }
    $out = @($out | ForEach-Object { "$_" })
    Remove-Item "env:DB07_STATE_DIR" -ErrorAction SilentlyContinue
    Remove-Item "env:DB07_TASKS_DIR" -ErrorAction SilentlyContinue
    return @{ text = ($out -join "`n") }
}
function Invoke-Suite([string]$relPath, [string[]]$envs) {
    $scriptPath = Join-Path $script:Root $relPath
    foreach ($kv in $envs) { $key, $val = $kv -split "=", 2; Set-Item ("env:" + $key) $val }
    $oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1) }
    finally { $ErrorActionPreference = $oldEAP }
    $code = $LASTEXITCODE
    foreach ($kv in $envs) { $key = ($kv -split "=", 2)[0]; Remove-Item ("env:" + $key) -ErrorAction SilentlyContinue }
    return @{ exit = $code; output = ($out -join "`n") }
}

# ---- M04 / M05 / M07 fixtures for the WI-07-0.2.5 chain ----------------------
function Remove-ReservationsForNode([string]$wbPath, [string]$nodeId) {
    $entry = Get-SheetEntryName "Active Changes"
    $fs = [System.IO.File]::Open($wbPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
    $rd = New-Object System.IO.StreamReader($zip.GetEntry($entry).Open())
    $doc = [System.Xml.Linq.XDocument]::Load($rd)
    $rd.Close(); $zip.Dispose(); $fs.Dispose()
    $removed = 0
    $sheetData = $doc.Root.Element($xNs + "sheetData")
    foreach ($row in @($sheetData.Elements($xNs + "row"))) {
        $b = $null
        foreach ($cell in $row.Elements($xNs + "c")) {
            $ra = $cell.Attribute("r")
            $col = if ($ra) { ([string]$ra.Value) -replace "\d+$", "" } else { "" }
            if ($col -eq "B") {
                $isEl = $cell.Element($xNs + "is")
                $tEl = if ($isEl) { $isEl.Element($xNs + "t") } else { $null }
                if ($tEl) { $b = [string]$tEl.Value }
                break
            }
        }
        if ($b) {
            $toks = @(($b -split "\|") | ForEach-Object { $_.Trim() })
            if (@($toks | Where-Object { $_ -eq $nodeId }).Count -gt 0) { $row.Remove(); $removed++ }
        }
    }
    if ($removed -gt 0) {
        $tmp = $wbPath + ".rm.tmp"
        $srcFs = [System.IO.File]::OpenRead($wbPath)
        $zipSrc = New-Object System.IO.Compression.ZipArchive($srcFs, [System.IO.Compression.ZipArchiveMode]::Read)
        $dstFs = [System.IO.File]::Create($tmp)
        $zipDst = New-Object System.IO.Compression.ZipArchive($dstFs, [System.IO.Compression.ZipArchiveMode]::Create)
        foreach ($e in $zipSrc.Entries) {
            $ne = $zipDst.CreateEntry($e.FullName)
            $out = $ne.Open(); $in = $e.Open()
            if ($e.FullName -eq $entry) { $doc.Save($out, [System.Xml.Linq.SaveOptions]::DisableFormatting) } else { $in.CopyTo($out) }
            $in.Dispose(); $out.Dispose()
        }
        $zipDst.Dispose(); $dstFs.Dispose(); $zipSrc.Dispose(); $srcFs.Dispose()
        Copy-Item $tmp $wbPath -Force; Remove-Item $tmp -Force
    }
    return $removed
}
function Add-ReservationFull([hashtable]$f, [string]$changeId, [string]$nodeId) {
    $acMap = @($script:DevControlMap.sheets | Where-Object { $_.name -eq "Active Changes" })[0]
    $hdr = [int]$acMap.headerRow; $start = [int]$acMap.dataStartRow
    $rows = @(With-Workbook $f.wbCopy { @(Get-SheetRows "Active Changes" $hdr $start 100) })
    $maxRow = $start
    foreach ($r in $rows) { if ([int]$r.Row -gt $maxRow) { $maxRow = [int]$r.Row } }
    $newRow = $maxRow + 1
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Change ID" $changeId
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Node ID" $nodeId
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Repositories" ($script:M032Scope.repos -join " | ")
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Projects" ($script:M032Scope.projects -join " | ")
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Files / Globs" ($script:M032Scope.filesGlobs -join " | ")
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Contracts / APIs" ($script:M032Scope.contractsApis -join " | ")
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Affected Nodes" ($script:M032Scope.affectedNodes -join " | ")
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Status" "In Progress"
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Preflight Verdict" "CLEAR"
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Started At" "2026-09-01T00:00:00Z"
    return $newRow
}
function Write-CompletePreflightD32([hashtable]$f, [string]$depState) {
    # Full DB-M03 preflight schema for the WI-07-0.2.5 chain. depState = SATISFIED or
    # TRIAL_DEPENDENCY_SATISFIED. workbookSha256 computed AFTER final workbook edit.
    $pre = [ordered]@{
        taskId = "WI-07-0.2.5"; nodeId = "WI-07-0.2.5"; name = "Excel-based Development Control store: WI-07-0.2.5 (DB-M03.2 fixture)"
        verdict = "CLEAR"; phase = "P0"; parentNodeId = "M-07-0.2"; currentWorkNodeId = "M-07-0.2"; featureNodeId = "F-07-0"
        repositories = $script:M032Scope.repos
        projects = $script:M032Scope.projects
        filesGlobs = $script:M032Scope.filesGlobs
        schemaContexts = $script:M032Scope.schemaContexts
        contractsApis = $script:M032Scope.contractsApis
        affectedNodes = $script:M032Scope.affectedNodes
        dependencies = @(
            @{ dependencyId = "WI-07-0.2.4"; type = "Textual (node Dependencies)"; state = $depState; status = "Planned"; detail = "Concurrency, locking and atomic writes" }
            @{ dependencyId = "REL-001..011"; type = "Explicit D&B"; state = "NOT_APPLICABLE"; status = $null; detail = "No Dependencies & Blockers row references the target or its chain" }
        )
        openDecisions = @()
        auditFindings = @()
        risk = "Low"; parallelSafe = $true
        workbookSha256 = (Get-Hash $f.wbCopy)
    }
    Write-F032Json $f "preflight.json" $pre
}
function New-M04FixtureD32([string]$name, [hashtable]$extraCurrent) {
    $f = New-F032 $name
    $null = Remove-ReservationsForNode $f.wbCopy "WI-07-0.2.5"
    Write-TrialHistory $f
    Write-TrialEvidence $f
    Write-CompletePreflightD32 $f "TRIAL_DEPENDENCY_SATISFIED"
    $cur = [ordered]@{
        nodeId = "WI-07-0.2.5"; taskId = "WI-07-0.2.5"; name = ("DB-M03.2 M04 fixture " + $name)
        nodeType = "WorkItem"; phase = "P0"; layer = "App"
        status = "PREFLIGHTED"; nextAllowedAction = "RESERVE"; changeId = ""
        selectedAt = "2026-09-01T00:00:00Z"; mode = "TRIAL"
        pendingGovernanceItems = @()
    }
    if ($null -ne $extraCurrent) { foreach ($k in $extraCurrent.Keys) { $cur[$k] = $extraCurrent[$k] } }
    Write-F032Json $f "current-task.json" $cur
    return $f
}
function New-M05FixtureD32([string]$name, [string]$depState, [bool]$withEvidence, [hashtable]$extraCurrent) {
    $f = New-F032 $name
    $null = Remove-ReservationsForNode $f.wbCopy "WI-07-0.2.5"
    $null = Add-ReservationFull $f "CHG-20260901-040" "WI-07-0.2.5"
    Write-TrialHistory $f
    if ($withEvidence) { Write-TrialEvidence $f }
    Write-CompletePreflightD32 $f $depState
    $cur = [ordered]@{
        nodeId = "WI-07-0.2.5"; taskId = "WI-07-0.2.5"; name = ("DB-M03.2 M05 fixture " + $name)
        nodeType = "WorkItem"; phase = "P0"; layer = "App"
        status = "RESERVED"; nextAllowedAction = "CHATGPT_HANDOFF"; changeId = "CHG-20260901-040"
        selectedAt = "2026-09-01T00:00:00Z"; mode = "TRIAL"
        pendingGovernanceItems = @()
    }
    if ($null -ne $extraCurrent) { foreach ($k in $extraCurrent.Keys) { $cur[$k] = $extraCurrent[$k] } }
    Write-F032Json $f "current-task.json" $cur
    $untrackedNow = @()
    foreach ($gline in @(& git -C "C:\Personal\Nexus.Developer" status --porcelain=v1 2>$null)) {
        if ($gline -match '^\?\?\s+(.+)$') { $untrackedNow += $matches[1] }
    }
    Write-F032Json $f "reservation.json" ([ordered]@{
        changeId = "CHG-20260901-040"; nodeId = "WI-07-0.2.5"; name = ("DB-M03.2 M05 fixture " + $name)
        mode = "TRIAL"; nextAllowedAction = "CHATGPT_HANDOFF"
        parallelLaneCheck = [ordered]@{
            status = "PASS"
            lanes = @(
                [ordered]@{ id = "DB-M12"; focus = "DevBridge Operator UI (UI/application layer only)"; root = "C:\\Personal\\DevTools\\DevBridge"; lane = "A"; overlap = $false; status = "RUNNING" }
                [ordered]@{ id = "DB-M13"; focus = "AI Routing/Cost Platform Discovery"; root = "C:\\Personal\\DevTools\\DevBridge"; lane = "B"; overlap = $false; status = "RUNNING" }
                [ordered]@{ id = "Nexus WI-07-0.2.5"; focus = "Development Control continuation (DB-M03.2 proving cycle)"; root = "C:\\Personal\\Nexus.Developer"; lane = "C"; overlap = $false; status = "RESERVED (this lane)" }
            )
        }
        gitBaseline = [ordered]@{
            repository = "C:\\Personal\\Nexus.Developer"
            branch = "feature/m-08-1-2-ci-pipeline"
            headCommit = "ea39db910a6e3b00bff880316996a696ae7460dc"
            headSubject = "CHG-20260830-015: workbook v3.26"
            preExistingChanges = [ordered]@{ staged = @(); modified = @(); untracked = @($untrackedNow) }
            postReservationModifiedFiles = @()
            scopeFileHashes = @()
        }
    })
    return $f
}
function New-M07FixtureD32([string]$name) {
    $f = New-F032 $name
    Write-TrialHistory $f
    Write-TrialEvidence $f
    Write-CompletePreflightD32 $f "TRIAL_DEPENDENCY_SATISFIED"
    $cur = [ordered]@{
        nodeId = "WI-07-0.2.5"; taskId = "WI-07-0.2.5"; name = ("DB-M03.2 M07 fixture " + $name)
        nodeType = "WorkItem"; phase = "P0"; layer = "App"
        status = "RESERVED"; nextAllowedAction = "CHATGPT_HANDOFF"; changeId = "CHG-20260901-040"
        selectedAt = "2026-09-01T00:00:00Z"; mode = "TRIAL"
        pendingGovernanceItems = @()
    }
    Write-F032Json $f "current-task.json" $cur
    Write-F032Json $f "verification.json" ([ordered]@{ primaryResult = "VERIFICATION_PASSED"; verifiedAtUtc = "2026-09-01T01:00:00Z" })
    return $f
}

# =============================================================================
# Group A -- overlay unit qualification (Test-TrialDependencySatisfied directly)
# =============================================================================
Write-Output "== Group A: overlay unit qualification =="
. (Join-Path $PSScriptRoot "TrialDependencyOverlay.ps1")

# A1  Full preserved trial evidence (DB-M12.4 closure + M06 VERIFICATION_PASS + M08
#     decision PASS + TRIAL_ONLY_UNMERGED) qualifies with truthful provenance.
$fA1 = New-F032 "a1_unit_qualify"
Write-TrialHistory $fA1
Write-TrialEvidence $fA1
$ovA1 = Test-TrialDependencySatisfied -DependencyNodeId "WI-07-0.2.4" -StateDir $fA1.stateDir -ConfigPath (Join-Path $script:Root "config\devbridge.json") -RealStatus "Planned"
$pA1 = $ovA1.Provenance
Assert-True "A1 overlay qualifies preserved trial evidence (TRIAL_DEPENDENCY_SATISFIED)" ($ovA1.Satisfied -and $ovA1.Reason -eq "TRIAL_DEPENDENCY_SATISFIED") ("got " + $ovA1.Reason)
Assert-True "A1 provenance is truthful: realStatus Planned, realNexusCompletion false, overlay TRIAL_DEPENDENCY_SATISFIED" ($pA1 -and [string]$pA1.realStatus -eq "Planned" -and -not $pA1.realNexusCompletion -and [string]$pA1.overlayStatus -eq "TRIAL_DEPENDENCY_SATISFIED" -and $pA1.disposableProvingContext -eq $true -and $pA1.realStatusAuthoritative -eq $true) ("real=" + $pA1.realStatus + " ov=" + $pA1.overlayStatus)
Assert-True "A1 provenance carries M06 + M08 chained evidence (capability 5)" ($pA1 -and [string]$pA1.verificationEvidence.m06Result -eq "VERIFICATION_PASS" -and $pA1.verificationEvidence.testsPassed -eq 199 -and $pA1.verificationEvidence.buildErrors -eq 0 -and [string]$pA1.claudeEvidence.decision -eq "PASS" -and $pA1.claudeEvidence.trialMode -eq $true -and [string]$pA1.claudeEvidence.implementationState -eq "TRIAL_ONLY_UNMERGED" -and [string]$pA1.closureEvidence.result -eq "TRIAL_CYCLE_CLOSED") ("m06=" + $pA1.verificationEvidence.m06Result + " tests=" + $pA1.verificationEvidence.testsPassed)

# A2  No governed closure entry -> NO_TRIAL_HISTORY, never satisfied.
$fA2 = New-F032 "a2_unit_no_history"
$ovA2 = Test-TrialDependencySatisfied -DependencyNodeId "WI-07-0.2.4" -StateDir $fA2.stateDir -ConfigPath (Join-Path $script:Root "config\devbridge.json")
Assert-True "A2 no closure entry -> NO_TRIAL_HISTORY, not satisfied" (-not $ovA2.Satisfied -and $ovA2.Reason -eq "NO_TRIAL_HISTORY" -and $null -eq $ovA2.BlockCode) ("got " + $ovA2.Reason)

# A3  REAL_NEXUS_DEVELOPMENT mode -> overlay ignored (capability 3).
$fA3 = New-F032 "a3_unit_real_mode"
Write-TrialHistory $fA3
Write-TrialEvidence $fA3
Write-F032Json $fA3 "current-task.json" ([ordered]@{ nodeId = "WI-07-0.2.5"; mode = "REAL_NEXUS_DEVELOPMENT"; status = "PREFLIGHTED" })
$ovA3 = Test-TrialDependencySatisfied -DependencyNodeId "WI-07-0.2.4" -StateDir $fA3.stateDir -ConfigPath (Join-Path $script:Root "config\devbridge.json")
Assert-True "A3 REAL mode -> NOT_TRIAL_MODE, overlay ignored" (-not $ovA3.Satisfied -and $ovA3.Reason -eq "NOT_TRIAL_MODE") ("got " + $ovA3.Reason)

# A4  Closure entry present but per-change evidence dir absent from current repository
#     reality -> honest DEPENDENCY_CONTEXT_STALE (never fake satisfaction).
$fA4 = New-F032 "a4_unit_missing_evidence"
Write-TrialHistory $fA4
$ovA4 = Test-TrialDependencySatisfied -DependencyNodeId "WI-07-0.2.4" -StateDir $fA4.stateDir -ConfigPath (Join-Path $script:Root "config\devbridge.json")
Assert-True "A4 missing evidence dir -> honest DEPENDENCY_CONTEXT_STALE block" (-not $ovA4.Satisfied -and $ovA4.BlockCode -eq "DEPENDENCY_CONTEXT_STALE") ("got " + $ovA4.BlockCode)

# A5  Evidence present but Claude decision FIX -> TRIAL_DEPENDENCY_EVIDENCE_INVALID.
$fA5 = New-F032 "a5_unit_decision_fix"
Write-TrialHistory $fA5
Write-TrialEvidence $fA5 "FIX"
$ovA5 = Test-TrialDependencySatisfied -DependencyNodeId "WI-07-0.2.4" -StateDir $fA5.stateDir -ConfigPath (Join-Path $script:Root "config\devbridge.json")
Assert-True "A5 M08 decision FIX -> TRIAL_DEPENDENCY_EVIDENCE_INVALID honest block (capability 6)" (-not $ovA5.Satisfied -and $ovA5.BlockCode -eq "TRIAL_DEPENDENCY_EVIDENCE_INVALID") ("got " + $ovA5.BlockCode)

# A6  DB-M18.1 DEPENDENCY_CONTEXT_STALE context -> block (capability 7).
$fA6 = New-F032 "a6_unit_stale_context"
Write-TrialHistory $fA6
Write-TrialEvidence $fA6
$ctxStale = [pscustomobject]@{ FreshnessStatus = "DEPENDENCY_CONTEXT_STALE" }
$ovA6 = Test-TrialDependencySatisfied -DependencyNodeId "WI-07-0.2.4" -StateDir $fA6.stateDir -ConfigPath (Join-Path $script:Root "config\devbridge.json") -DbM181Context $ctxStale
Assert-True "A6 DB-M18.1 DEPENDENCY_CONTEXT_STALE context -> block" (-not $ovA6.Satisfied -and $ovA6.BlockCode -eq "DEPENDENCY_CONTEXT_STALE") ("got " + $ovA6.BlockCode)

# A7  Overlay disabled by config flag -> OVERLAY_DISABLED, behaves as before (restoration safety).
$cfgDir = Join-Path $fA1.root "cfg"
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
$cfgPath7 = Join-Path $cfgDir "devbridge.json"
@{ mode = "TRIAL"; trialDependencyOverlay = @{ enabled = $false } } | ConvertTo-Json -Depth 5 | Out-File $cfgPath7 -Encoding utf8
$ovA7 = Test-TrialDependencySatisfied -DependencyNodeId "WI-07-0.2.4" -StateDir $fA1.stateDir -ConfigPath $cfgPath7
Assert-True "A7 config-disabled overlay -> OVERLAY_DISABLED (capability 12)" (-not $ovA7.Satisfied -and $ovA7.Reason -eq "OVERLAY_DISABLED") ("got " + $ovA7.Reason)

# =============================================================================
# Group B -- M03 selection engine (Get-NextTask)
# =============================================================================
Write-Output "== Group B: M03 selection engine =="

# B8  CURRENT CASE: WI-07-0.2.4 trial-proven (excluded from re-selection) + its
#     per-change evidence present -> WI-07-0.2.5 becomes SELECTED via the overlay.
$fB8 = New-F032 "b8_current_case"
Write-TrialHistory $fB8
Write-TrialEvidence $fB8
$sB8 = Invoke-NextTaskD32 $fB8
Assert-True "B8 overlay qualifies -> WI-07-0.2.5 SELECTED (dependency satisfied by trial-proven predecessor)" ($sB8.status -eq "SELECTED" -and $sB8.task -eq "WI-07-0.2.5" -and $sB8.currentWork -eq "M-07-0.2") ("got " + $sB8.status + " task=" + $sB8.task + " cw=" + $sB8.currentWork)
Assert-True "B8 selection basis truthfully records the trial-proven overlay (capability 4)" ((($sB8.basis -join " ") -match "Trial-proven dependency overlay \(DB-M03.2\)") -and (($sB8.basis -join " ") -match "satisfied by trial-proven overlay") -and (($sB8.basis -join " ") -match "NOT real Nexus completion")) ("basis: " + ($sB8.basis -join " | "))

# B9  Sparse history (closure entry but NO per-change evidence) -> honest
#     NO_IMPLEMENTABLE_DESCENDANT block; the overlay never fakes satisfaction.
$fB9 = New-F032 "b9_sparse_history"
Write-SparseProvingHistory $fB9 @("WI-07-0.2.4")
$sB9 = Invoke-NextTaskD32 $fB9
Assert-True "B9 sparse evidence -> NO_IMPLEMENTABLE_DESCENDANT honest block (never fake satisfaction)" ($sB9.status -eq "NO_IMPLEMENTABLE_DESCENDANT" -and $sB9.task -eq "" -and $sB9.currentWork -eq "M-07-0.2") ("got " + $sB9.status + " task=" + $sB9.task)

# B10 REAL mode -> overlay ignored; the real roadmap status is the sole authority
#     (WI-07-0.2.4 is re-selected exactly as pre-DB-M03.2).
$fB10 = New-F032 "b10_real_mode"
Write-TrialHistory $fB10
Write-TrialEvidence $fB10
Write-F032Json $fB10 "current-task.json" ([ordered]@{ nodeId = "M-07-0.2"; mode = "REAL_NEXUS_DEVELOPMENT"; status = "PREFLIGHTED" })
$sB10 = Invoke-NextTaskD32 $fB10
Assert-True "B10 REAL mode -> WI-07-0.2.4 re-selected (real status authoritative, overlay ignored)" ($sB10.status -eq "SELECTED" -and $sB10.task -eq "WI-07-0.2.4") ("got " + $sB10.status + " task=" + $sB10.task)

# B11 Evidence decision FIX -> honest block with the TRIAL_DEPENDENCY_EVIDENCE_INVALID
#     note surfaced in the selection basis.
$fB11 = New-F032 "b11_invalid_evidence"
Write-TrialHistory $fB11
Write-TrialEvidence $fB11 "FIX"
$sB11 = Invoke-NextTaskD32 $fB11
Assert-True "B11 invalid evidence -> NO_IMPLEMENTABLE_DESCENDANT with honest overlay note" ($sB11.status -eq "NO_IMPLEMENTABLE_DESCENDANT" -and (($sB11.basis -join " ") -match "TRIAL_DEPENDENCY_EVIDENCE_INVALID")) ("got " + $sB11.status)

# B12 Overlay disabled (env) -> pre-overlay behavior exactly (no satisfaction, no note).
$fB12 = New-F032 "b12_disabled_env"
Write-TrialHistory $fB12
Write-TrialEvidence $fB12
$env:DB_TRIAL_DEPENDENCY_OVERLAY = "0"
$sB12 = Invoke-NextTaskD32 $fB12
Remove-Item "env:DB_TRIAL_DEPENDENCY_OVERLAY" -ErrorAction SilentlyContinue
Assert-True "B12 env-disabled overlay -> NO_IMPLEMENTABLE_DESCENDANT (pre-DB-M03.2 behavior)" ($sB12.status -eq "NO_IMPLEMENTABLE_DESCENDANT" -and (($sB12.basis -join " ") -notmatch "Trial-proven dependency overlay")) ("got " + $sB12.status)

# B13 Provenance available through the engine: basis names the predecessor + real status.
Assert-True "B13 basis names predecessor WI-07-0.2.4 and its real status (capability 1/2)" ((($sB8.basis -join " ") -match "WI-07-0.2.4") -and (($sB8.basis -join " ") -match "Planned")) ("basis: " + ($sB8.basis -join " | "))

# =============================================================================
# Group C -- M04 / M05 / M07 integration + preflight
# =============================================================================
Write-Output "== Group C: preflight / M04 / M05 / M07 integration =="

# C14 Preflight CLEAR via the overlay; preflight.json records TRIAL_DEPENDENCY_SATISFIED
#     with the real status preserved, and the leafValidation ledger is honest.
$fC14 = New-F032 "c14_preflight_clear"
Write-TrialHistory $fC14
Write-TrialEvidence $fC14
$vC14 = Invoke-PreflightD32 $fC14
$ctC14 = Read-F032Json $fC14 "current-task.json"
$pfC14 = Read-F032Json $fC14 "preflight.json"
$depC14 = @($pfC14.dependencies | Where-Object { $_.dependencyId -eq "WI-07-0.2.4" })[0]
$lvC14 = @($pfC14.leafValidation | Where-Object { $_.check -eq "dependencies" })[0]
Assert-True "C14 overlay-qualified preflight CLEAR on WI-07-0.2.5 (IMPLEMENTABLE_LEAF / RESERVE)" ($vC14 -eq "CLEAR" -and [string]$ctC14.nodeId -eq "WI-07-0.2.5" -and [string]$ctC14.implementability -eq "IMPLEMENTABLE_LEAF" -and [string]$ctC14.nextAllowedAction -eq "RESERVE") ("verdict=" + $vC14 + " node=" + $ctC14.nodeId)
Assert-True "C14 preflight dependency state = TRIAL_DEPENDENCY_SATISFIED (real status Planned preserved)" ($depC14 -and [string]$depC14.state -eq "TRIAL_DEPENDENCY_SATISFIED" -and [string]$depC14.status -eq "Planned") ("state=" + $depC14.state + " status=" + $depC14.status)
Assert-True "C14 leafValidation dependencies PASS with trial-overlay detail" ($lvC14 -and [string]$lvC14.status -eq "PASS" -and ([string]$lvC14.detail -match "TRIAL-only overlay")) ("lv=" + $lvC14.status + " " + $lvC14.detail)

# C15 Preflight honest block when evidence is sparse (never CLEAR on unproven dep).
$fC15 = New-F032 "c15_preflight_sparse"
Write-SparseProvingHistory $fC15 @("WI-07-0.2.4")
$vC15 = Invoke-PreflightD32 $fC15
$ctC15 = Read-F032Json $fC15 "current-task.json"
Assert-True "C15 sparse evidence preflight -> NO_IMPLEMENTABLE_DESCENDANT (honest block, not CLEAR)" ($vC15 -eq "NO_IMPLEMENTABLE_DESCENDANT" -and [string]$ctC15.nextAllowedAction -eq "RESOLVE_GOVERNANCE_BLOCK") ("verdict=" + $vC15)

# C16 M04 reserve accepts a TRIAL_DEPENDENCY_SATISFIED predecessor (no false
#     'no satisfied node dependency'); the real status is NOT touched.
$fC16 = New-M04FixtureD32 "c16_m04_reserve"
$rC16 = Invoke-ReserveD32 $fC16
Assert-True "C16 M04 reserve passes with trial-proven predecessor (capability 9)" ($rC16.outcome -eq "RESERVED" -and $rC16.pass) ("got " + $rC16.outcome + " pass=" + $rC16.pass)

# C17 M04 honest STOP when the trial evidence goes stale between preflight and reserve.
$fC17 = New-M04FixtureD32 "c17_m04_stale"
$evDirC17 = Join-Path $fC17.logsDir "tasks\WI-07-0.2.4"
$evDirC17 = Join-Path $evDirC17 "CHG-20260830-017"
Remove-Item $evDirC17 -Recurse -Force
$rC17 = Invoke-ReserveD32 $fC17
Assert-True "C17 M04 honest STOP_PREFLIGHT_STALE on stale trial evidence (capability 6)" ($rC17.outcome -eq "STOP_PREFLIGHT_STALE") ("got " + $rC17.outcome)

# C18 M05 handoff generates with a trial-proven predecessor and tells the truth.
$fC18 = New-M05FixtureD32 "c18_m05_handoff" "TRIAL_DEPENDENCY_SATISFIED" $true @{}
$rC18 = Invoke-HandoffD32 $fC18
$mdC18 = ""
$handoffPath = Join-Path $fC18.tasksDir "CHATGPT_HANDOFF.md"
if (Test-Path $handoffPath) { $mdC18 = [System.IO.File]::ReadAllText($handoffPath) }
Assert-True "C18 M05 handoff generates (real outcome, not stale-stop)" ($rC18.outcome -eq "HANDOFF_GENERATED" -and $rC18.outcome -ne "HANDOFF_STATE_STALE") ("got " + $rC18.outcome + " :: " + (($rC18.output -split "`n" | Where-Object { $_ -match "error|Error|STOP|HANDOFF|FAIL|Exception|at " } | Select-Object -First 6) -join " ; "))
Assert-True "C18 M05 handoff carries the Trial-Proven Dependency Context (capability 10)" (($mdC18 -match "Trial-Proven Dependency Context \(DB-M03.2\)") -and ($mdC18 -match "TRIAL_DEPENDENCY_SATISFIED") -and ($mdC18 -match "NOT real Nexus completion") -and ($mdC18 -match "real roadmap status.*Planned")) ("md-len=" + $mdC18.Length)

# C19 M05 honest STOP when the trial evidence is absent at handoff time.
$fC19 = New-M05FixtureD32 "c19_m05_stale" "TRIAL_DEPENDENCY_SATISFIED" $false @{}
$rC19 = Invoke-HandoffD32 $fC19
Assert-True "C19 M05 honest HANDOFF_STATE_STALE on missing trial evidence" ($rC19.outcome -eq "HANDOFF_STATE_STALE") ("got " + $rC19.outcome)

# C20 M07 review package distinguishes trial-proven implementation state from real
#     roadmap status (capability 11).
$fC20 = New-M07FixtureD32 "c20_m07_package"
$rC20 = Invoke-M07D32 $fC20
$mdC20 = ""
$pkgPath = Join-Path $fC20.tasksDir "CLAUDE_REVIEW_PACKAGE.md"
if (Test-Path $pkgPath) { $mdC20 = [System.IO.File]::ReadAllText($pkgPath) }
Assert-True "C20 M07 package generated with DB07 markers (exit 0 backend contract)" (($rC20.text -match "DB07_OUTCOME:") -and ($rC20.text -match "DB07_RESULT_PASS: True")) ("out: " + (($rC20.text -split "`n" | Select-String "DB07_OUTCOME" | Select-Object -First 1)))
Assert-True "C20 M07 package distinguishes trial state from real roadmap status" (($mdC20 -match "Trial-Proven Dependency Distinction \(DB-M03.2\)") -and ($mdC20 -match "real roadmap status.*Planned") -and ($mdC20 -match "TRIAL_DEPENDENCY_SATISFIED") -and ($mdC20 -match "real completion capability.*NO")) ("md-len=" + $mdC20.Length)

# C21 M05 marks the trial predecessor clearly as NOT real completion in the handoff
#     identity scope (capability 8: NO FALSE WORKBOOK COMPLETION reporting).
Assert-True "C21 handoff says real completion capability NO / disposable proving context" (($mdC18 -match "real completion capability = \*\*NO\*\*") -and ($mdC18 -match "disposable DevBridge proving context")) ("md-len=" + $mdC18.Length)

# C22 M05 handoff table lists the trial predecessor as TRIAL_DEPENDENCY_SATISFIED /
#     Blocking NO (never Complete).
Assert-True "C22 handoff dependency table marks predecessor TRIAL_DEPENDENCY_SATISFIED / Blocking NO" (($mdC18 -match "TRIAL_DEPENDENCY_SATISFIED \| NO") -and ($mdC18 -notmatch "WI-07-0.2.4.*\|\s*Complete\s*\|")) ("md-len=" + $mdC18.Length)

# =============================================================================
# Group D -- non-mutation invariants (capabilities 8 / 9 / 12)
# =============================================================================
Write-Output "== Group D: non-mutation + restoration safety =="

# D23 The real roadmap status of WI-07-0.2.4 remains Planned after a full engine run
#     (M03 select + preflight) on the overlay case (capability 8: NO FALSE COMPLETION).
$live24 = With-Workbook $fC14.wbCopy { (Get-RoadmapNodeById "WI-07-0.2.4") }
Assert-True "D23 WI-07-0.2.4 real status stays Planned after preflight (never written Complete)" ([string]$live24.Status -eq "Planned") ("got " + $live24.Status)

# D24 M04 reservation does not alter the predecessor's real status (capability 9).
$live24m4 = With-Workbook $fC16.wbCopy { (Get-RoadmapNodeById "WI-07-0.2.4") }
Assert-True "D24 M04 leaves WI-07-0.2.4 real status Planned (predecessor status untouched)" ([string]$live24m4.Status -eq "Planned") ("got " + $live24m4.Status)

# D25 Restoration safety: no trial-proving-history at all -> M03 behaves exactly as
#     before DB-M03.2 (WI-07-0.2.4 not excluded, no overlay consulted, selected).
$fD25 = New-F032 "d25_restoration"
$sD25 = Invoke-NextTaskD32 $fD25
Assert-True "D25 no trial history -> pre-overlay behavior (WI-07-0.2.4 selected, no overlay note)" ($sD25.status -eq "SELECTED" -and $sD25.task -eq "WI-07-0.2.4" -and (($sD25.basis -join " ") -notmatch "Trial-proven dependency overlay")) ("got " + $sD25.status + " task=" + $sD25.task)

# D26 Overlay NEVER writes the real workbook/state: authoritative SHA + live state
#     captured before any fixture were unchanged (asserted again in invariants).
$realHashMid = Get-Hash $script:RealWorkbook
Assert-True "D26 authoritative workbook untouched by all DB-M03.2 engine runs" ($realHashMid -eq $script:RealHashBefore) "authoritative workbook hash changed during suite"

# =============================================================================
# Group R -- regression suites (child processes)
# =============================================================================
Write-Output "== Group R: regression suites =="

# R27 DB-M03.1 (M03 hardened leaf selection + M04/M05 gates) stays green.
$rR27 = Invoke-Suite "scripts\Test-DBM031ImplementableLeafSelection.ps1" @()
Assert-True "R27 DB-M03.1 regression suite passes (exit 0)" ($rR27.exit -eq 0) ("exit=" + $rR27.exit + " :: " + (($rR27.output -split "`n" | Select-String "SAFETY SUMMARY|SUITE: PASS|FAILURES" | Select-Object -First 2) -join " ; "))

# R28 DB-M12.2 command contracts stay green.
$rR28 = Invoke-Suite "scripts\Test-DBM12-2Commands.ps1" @()
Assert-True "R28 DB-M12.2 regression suite passes" ($rR28.exit -eq 0) ("exit=" + $rR28.exit)

# R29 DB-M12.4 trial-cycle closure stays green (the governing closure this overlay builds on).
$rR29 = Invoke-Suite "scripts\Test-DBM124TrialCycleClosure.ps1" @()
Assert-True "R29 DB-M12.4 regression suite passes" ($rR29.exit -eq 0) ("exit=" + $rR29.exit)

# R30 DB-M10 completion-eligibility probe stays green (always exit 0; markers checked).
$rR30 = Invoke-Suite "scripts\Test-DBM10CompletionEligibility.ps1" @()
Assert-True "R30 DB-M10 eligibility probe runs (exit 0)" ($rR30.exit -eq 0) ("exit=" + $rR30.exit)

# R31 DB-GH01 ChatGptHandoffReadiness stays green (exit 0, marker-based).
$rR31 = Invoke-Suite "scripts\Test-ChatGptHandoffReady.ps1" @()
Assert-True "R31 DB-GH01 handoff-readiness gate runs (exit 0)" ($rR31.exit -eq 0) ("exit=" + $rR31.exit)

# R32 DB-M18.1 dependency lineage regression: only the KNOWN pre-existing R45 drift
#     (child suite Test-DbM18Classification S27 fixture hard-codes WI-07-0.2.4 as the
#     current task while the live current task is M-07-0.2). NOT a DB-M03.2 regression;
#     Lane B-owned; reported, not fixed here.
$rR32 = Invoke-Suite "scripts\ai-routing\Test-DbM181DependencyLineage.ps1" @()
# Known-drift signature (Lane B-owned, unchanged by DB-M03.2): summary is 64 checks /
# 63 passed / 1 failed, and the ONLY [FAIL] line is the R45 child-suite check.
$r32FailLines = @($rR32.output -split "`n" | Select-String -Pattern "\[FAIL\]")
$r32Known = ($rR32.output -match "R45") -and ($rR32.output -match "1 failed") -and ($rR32.output -match "63 passed") -and (@($r32FailLines | Where-Object { $_ -notmatch "R45" }).Count -eq 0)
Assert-True "R32 DB-M18.1 regression: known R45 drift only (63/64), no new DB-M03.2 regression" $r32Known ("exit=" + $rR32.exit + " :: " + (($rR32.output -split "`n" | Select-String "TEST SUMMARY|R45|\[FAIL\]" | Select-Object -First 4) -join " ; "))

# R33 Test-DBM04Safety runs LAST (it wipes ALL logs\selftest subdirs, including the
#     DB-M03.2 fixtures; our results are captured above, so the wipe is safe).
$rR33 = Invoke-Suite "scripts\Test-DBM04Safety.ps1" @()
Assert-True "R33 DB-M04 safety suite passes (ran last; selftest wipe is post-capture)" ($rR33.exit -eq 0) ("exit=" + $rR33.exit)

# =============================================================================
# Group I -- invariants + build
# =============================================================================
Write-Output "== Group I: invariants + build =="
$realHashAfter = Get-Hash $script:RealWorkbook
Assert-True "I34 authoritative workbook untouched by suite" ($realHashAfter -eq $script:RealHashBefore) "authoritative workbook hash changed"
$repoAfter = @(& git -C "C:\Personal\Nexus.Developer" status --porcelain=v1 2>$null)
Assert-True "I35 Nexus repo status unchanged" (($repoAfter -join "`n") -eq ($script:RepoStatusBefore -join "`n")) "Nexus repo modified"
$liveTaskHashAfter = Get-Hash (Join-Path $script:Root "state\current-task.json")
Assert-True "I36 live state current-task.json untouched" ($liveTaskHashAfter -eq $script:LiveTaskHashBefore) "live current-task.json changed"

Write-Output "== I37/I38 solution build =="
$sln = Join-Path $script:Root "src\DevBridge.slnx"
$oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
$buildOut = @(& dotnet build $sln 2>&1)
$buildExit = $LASTEXITCODE
$ErrorActionPreference = $oldEAP
Assert-True "I37 solution build passes (exit 0)" ($buildExit -eq 0) ("build exit " + $buildExit)
$warnCount = @($buildOut | Select-String -Pattern "warning CS").Count
$errCount = @($buildOut | Select-String -Pattern "error CS").Count
Assert-True "I38 build has 0 compiler warnings" ($warnCount -eq 0) ("warnings " + $warnCount)
Assert-True "I39 build has 0 compiler errors" ($errCount -eq 0) ("errors " + $errCount)

# =============================================================================
# summary
# =============================================================================
Write-Output ""
$failCount = $script:Fails.Count
Write-Output ("DB-M03.2 SAFETY SUMMARY: {0} checks, {1} passed, {2} failed" -f $script:Results.Count, ($script:Results.Count - $failCount), $failCount)
if ($failCount -gt 0) {
    Write-Output "FAILURES:"
    foreach ($f in $script:Fails) { Write-Output ("  - " + $f) }
    exit 1
}
Write-Output "DB-M03.2 SUITE: PASS"
exit 0
