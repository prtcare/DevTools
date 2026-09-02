<#
Test-DBM031ImplementableLeafSelection.ps1
DevBridge DB-M03.1 self-test suite: governed IMPLEMENTABLE_LEAF selection & preflight
resolution (32-test matrix + invariants). Exercises the REAL backend engines
(Get-NextTask.ps1, Test-DevelopmentPreflight.ps1, Reserve-DevelopmentChange.ps1,
New-ChatGptHandoff.ps1) against throwaway fixture state/tasks dirs and byte-identical
workbook copies under logs\selftest\db-m03-1. The authoritative workbook, the Nexus
repo, and live state are asserted byte-identical at the end (I1-I3).

Matrix (DB-M03.1 acceptance):
  Group A (A1-A10)  deterministic node implementability classification
  Group B (B11-B17) container-node handling + honest block states
  Group C (C18-C23) selection flow: CURRENT WORK FIRST, NEXT WORK fallback,
                    dependency order, trial-proving-history exclusion
  Group D (D24-D28) preflight integration: leaf CLEAR, block records, leafValidation ledger
  Group E (E29-E32) M04 / M05 gates: container refusal + backward compatibility

No live mutation: every write lands in the fixture copy / fixture dirs. No Nexus
source is touched. Build must stay 0 warnings / 0 errors (I4).
#>
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:Cfg = Get-Content (Join-Path $script:Root "config\devbridge.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$script:RealWorkbook = $script:Cfg.developmentControlWorkbook
$script:SelftestRoot = Join-Path $script:Root "logs\selftest"
if (-not (Test-Path $script:SelftestRoot)) { New-Item -ItemType Directory -Force -Path $script:SelftestRoot | Out-Null }
$dbM031Root = Join-Path $script:SelftestRoot "db-m03-1"
if (Test-Path $dbM031Root) { Remove-Item $dbM031Root -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dbM031Root | Out-Null

# Shared library (array-safe JSON) + read-only workbook library (for read-backs).
. (Join-Path $PSScriptRoot "Set-DevBridgeStateEntry.ps1")
. (Join-Path $PSScriptRoot "Read-DevelopmentControl.ps1")

function Get-Hash([string]$p) { return (Get-FileHash $p -Algorithm SHA256).Hash }

$script:RealHashBefore = Get-Hash $script:RealWorkbook

# Fixture baseline decoupling: byte-identical PRISTINE copies (the recorded DB-M12.4
# pre-closure baseline) so M-07-0.2 is still In Progress with its open reservation.
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
function New-F031([string]$name) {
    $outDir = Join-Path $dbM031Root $name
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $stateDir = Join-Path $outDir "state"; $tasksDir = Join-Path $outDir "tasks"
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null
    $wbCopy = Join-Path $outDir "workbook.xlsx"
    Copy-Item $script:PristineWorkbook $wbCopy -Force
    return @{ root = $outDir; stateDir = $stateDir; tasksDir = $tasksDir; wbCopy = $wbCopy }
}
function Read-F031Json([hashtable]$f, [string]$relPath) {
    $raw = [System.IO.File]::ReadAllText((Join-Path $f.stateDir $relPath))
    return $raw | ConvertFrom-Json
}
function Write-F031Json([hashtable]$f, [string]$relPath, $obj) {
    Write-DevBridgeJson (Join-Path $f.stateDir $relPath) $obj | Out-Null
}

# ---- minimal OOXML cell writer (drift fixture only) --------------------------
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
function With-Workbook([string]$path, [scriptblock]$body) {
    $prev = $script:DevControlWorkbook
    $script:DevControlWorkbook = $path
    try { & $body } finally { $script:DevControlWorkbook = $prev }
}

# ---- drift helpers (write to a byte-identical workbook copy only) ------------
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
    } finally {
        $zip.Dispose()
        $fs.Dispose()
    }
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
        if ($rowEl) {
            $cell = Find-Cell $rowEl $col $rowNum
            if ($cell) { $cell.Remove() }
        }
        Save-SheetDoc $zip $entry $doc
    } finally {
        $zip.Dispose()
        $fs.Dispose()
    }
}
function Set-NodeCell([hashtable]$f, [string]$nodeId, [string]$columnName, [string]$value) {
    $row = Get-RoadmapRow $f.wbCopy $nodeId
    Write-WorkbookCell $f.wbCopy "Master Roadmap" $row $columnName $value
}
function Clear-NodeCell([hashtable]$f, [string]$nodeId, [string]$columnName) {
    $row = Get-RoadmapRow $f.wbCopy $nodeId
    Clear-WorkbookCell $f.wbCopy "Master Roadmap" $row $columnName
}
# Append an OPEN Active Changes reservation row naming $nodeId. The appended row is
# the freshest row in the ledger, so the node becomes the top current-work candidate.
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
function Write-ProvingHistory([hashtable]$f, [string[]]$nodeIds) {
    $entries = @()
    foreach ($id in $nodeIds) {
        $entries += [ordered]@{
            nodeId = $id; changeId = ("CHG-" + $id); closedAtUtc = "2026-08-31T01:00:00Z"
            mode = "TRIAL"; result = "TRIAL_CYCLE_CLOSED"; implementationState = "TRIAL_ONLY_UNMERGED"
        }
    }
    Write-F031Json $f "trial-proving-history.json" ([ordered]@{ entries = $entries })
}

# ---- engine invocation wrappers (backend contract: stdout markers, exit 0) ----
function Invoke-NextTaskD31([hashtable]$f) {
    $engine = Join-Path $PSScriptRoot "Get-NextTask.ps1"
    Set-Item "env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE" $f.wbCopy
    Set-Item "env:DB_NEXTTASK_STATE_DIR" $f.stateDir
    Set-Item "env:DB_NEXTTASK_CONFIG_PATH" (Join-Path $script:Root "config\devbridge.json")
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine 2>&1)
    } finally {
        $ErrorActionPreference = $oldEAP
    }
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
function Invoke-Preflight([hashtable]$f) {
    # In-process dot-source with $script:DevBridgeRoot overridden so the real preflight
    # engine writes preflight.json / current-task.json / reports into the fixture dirs
    # only. Env overrides steer the workbook + Get-NextTask state to the same fixture.
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
function Invoke-Reserve([hashtable]$f) {
    $engine = Join-Path $PSScriptRoot "Reserve-DevelopmentChange.ps1"
    Set-Item "env:DB04_SELFTEST" "1"
    Set-Item "env:DB04_STATE_DIR" $f.stateDir
    Set-Item "env:DB04_TASKS_DIR" $f.tasksDir
    Set-Item "env:DB04_LOGS_DIR" (Join-Path $f.root "logs")
    Set-Item "env:DB04_WORKBOOK_OVERRIDE" $f.wbCopy
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine 2>&1)
    } finally {
        $ErrorActionPreference = $oldEAP
    }
    $out = @($out | ForEach-Object { "$_" })
    foreach ($k in @("DB04_SELFTEST","DB04_STATE_DIR","DB04_TASKS_DIR","DB04_LOGS_DIR","DB04_WORKBOOK_OVERRIDE")) { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue }
    $res = @{ outcome = "NO_MARKER"; pass = $false; output = ($out -join "`n") }
    $ol = $out | Select-String -Pattern '^DB04_OUTCOME:\s*' | Select-Object -First 1
    if ($ol) { $res.outcome = ($ol.Line -replace '^DB04_OUTCOME:\s*', '').Trim() }
    $pl = $out | Select-String -Pattern '^DB04_RESULT_PASS:\s*' | Select-Object -First 1
    if ($pl) { $res.pass = (($pl.Line -replace '^DB04_RESULT_PASS:\s*', '').Trim() -eq "True") }
    return $res
}
function Invoke-Handoff([hashtable]$f) {
    $engine = Join-Path $PSScriptRoot "New-ChatGptHandoff.ps1"
    Set-Item "env:DB05_STATE_DIR" $f.stateDir
    Set-Item "env:DB05_TASKS_DIR" $f.tasksDir
    Set-Item "env:DB05_LOGS_DIR" (Join-Path $f.root "logs")
    Set-Item "env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE" $f.wbCopy
    # M05's final tree-sweep (New-ChatGptHandoff.ps1) scans the WHOLE DevBridge root
    # for files touched in the run window (RunStart - 5s). Every fixture file under
    # logs\selftest is "recent" when the engine starts, so age them back before
    # spawning the engine — M05 reads them, it never needs fresh timestamps. This
    # keeps the sweep green for the E32 legacy-state run (E31 stops at the gate and
    # never sweeps). The suite's own redirect log must live outside the DevBridge
    # root (caller redirects to $env:TEMP) so it never appears in the sweep either.
    $selftestRoot = Join-Path (Split-Path $PSScriptRoot -Parent) "logs\selftest"
    if (Test-Path $selftestRoot) {
        $oldEAP2 = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        Get-ChildItem $selftestRoot -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            try { $_.LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddSeconds(-120) } catch {}
        }
        $ErrorActionPreference = $oldEAP2
    }
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine 2>&1)
    } finally {
        $ErrorActionPreference = $oldEAP
    }
    $out = @($out | ForEach-Object { "$_" })
    foreach ($k in @("DB05_STATE_DIR","DB05_TASKS_DIR","DB05_LOGS_DIR","DB_DEV_CONTROL_WORKBOOK_OVERRIDE")) { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue }
    $res = @{ outcome = "NO_MARKER"; output = ($out -join "`n") }
    $ol = $out | Select-String -Pattern '^DB05_OUTCOME:\s*' | Select-Object -First 1
    if ($ol) { $res.outcome = ($ol.Line -replace '^DB05_OUTCOME:\s*', '').Trim() }
    if ($res.outcome -eq "NO_MARKER") {
        # M05's own stop convention: "DB-M05 STOP - <CODE>" (New-ChatGptHandoff.ps1:41).
        # Success emits DB05_OUTCOME; every governed stop emits DB-M05 STOP - <CODE>.
        $sl = $out | Select-String -Pattern 'DB-M05 STOP - ([A-Z0-9_]+)' | Select-Object -First 1
        if ($sl -and $sl.Matches -and $sl.Matches.Count -gt 0) { $res.outcome = $sl.Matches[0].Groups[1].Value }
    }
    return $res
}
# ---- M04 / M05 gate fixtures (E29-E32) --------------------------------------
# Shared governed scope for the WI-07-0.2.4 fixture chain. Mirrors the scope the
# real DB-M03 preflight recorded for the node (verified against the pristine
# baseline's reservation row) so the M05 engine's exact-set scope comparison
# (New-ChatGptHandoff ScopeOk) passes rather than stopping HANDOFF_STATE_STALE.
$script:M031Scope = @{
    repos          = @("Nexus.Developer")
    projects       = @("Nexus.Developer.Core","Nexus.Developer.Infrastructure")
    filesGlobs     = @("src/Nexus.Developer.Core/DevelopmentControl/**","src/Nexus.Developer.Infrastructure/DevelopmentControl/ExcelDevelopmentControlStore.cs")
    schemaContexts = @()
    contractsApis  = @("IDevelopmentControlStore","IDevelopmentControlAtomicWorkUnitRunner")
    affectedNodes  = @("F-07-0","M-07-0.2","WI-07-0.2.1","WI-07-0.2.2","WI-07-0.2.3","WI-07-0.2.4","WI-07-0.2.5","WI-07-0.2.6","WI-07-0.2.7","WI-07-0.2.8","WI-07-0.2.9","WI-07-0.2.10")
}

function Remove-ReservationsForNode([string]$wbPath, [string]$nodeId) {
    # Remove every Active Changes row whose Node ID (column B) token equals $nodeId.
    # Isolates M04/M05 fixtures from the pristine baseline's terminal CHG-20260830-017
    # row (and any inherited conflict) so the engines validate a clean reservation.
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
    # Append a fresh OPEN Active Changes row carrying the full governed scope, so the
    # M05 engine validates a live non-terminal reservation whose scope matches preflight.
    $acMap = @($script:DevControlMap.sheets | Where-Object { $_.name -eq "Active Changes" })[0]
    $hdr = [int]$acMap.headerRow; $start = [int]$acMap.dataStartRow
    $rows = @(With-Workbook $f.wbCopy { @(Get-SheetRows "Active Changes" $hdr $start 100) })
    $maxRow = $start
    foreach ($r in $rows) { if ([int]$r.Row -gt $maxRow) { $maxRow = [int]$r.Row } }
    $newRow = $maxRow + 1
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Change ID" $changeId
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Node ID" $nodeId
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Repositories" ($script:M031Scope.repos -join " | ")
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Projects" ($script:M031Scope.projects -join " | ")
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Files / Globs" ($script:M031Scope.filesGlobs -join " | ")
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Contracts / APIs" ($script:M031Scope.contractsApis -join " | ")
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Affected Nodes" ($script:M031Scope.affectedNodes -join " | ")
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Status" "In Progress"
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Preflight Verdict" "CLEAR"
    Write-WorkbookCell $f.wbCopy "Active Changes" $newRow "Started At" "2026-08-31T00:00:00Z"
    return $newRow
}

function Write-CompletePreflight([hashtable]$f) {
    # Full DB-M03 preflight schema for the WI-07-0.2.4 chain: every field the real
    # M04/M05 engines read under Set-StrictMode (dependencies, scope arrays, open
    # decisions/findings, featureNodeId). workbookSha256 is computed AFTER the fixture
    # workbook's final edit so M04's serialized-writer guard (line 385) passes.
    $pre = [ordered]@{
        taskId = "WI-07-0.2.4"; nodeId = "WI-07-0.2.4"; name = "Excel-based Development Control store: concurrency, locking and atomic writes (DB-M03.1 fixture)"
        verdict = "CLEAR"; phase = "P0"; parentNodeId = "M-07-0.2"; currentWorkNodeId = "M-07-0.2"; featureNodeId = "F-07-0"
        repositories = $script:M031Scope.repos
        projects = $script:M031Scope.projects
        filesGlobs = $script:M031Scope.filesGlobs
        schemaContexts = $script:M031Scope.schemaContexts
        contractsApis = $script:M031Scope.contractsApis
        affectedNodes = $script:M031Scope.affectedNodes
        dependencies = @(
            @{ dependencyId = "WI-07-0.2.3"; type = "Textual (node Dependencies)"; state = "SATISFIED"; status = "Complete"; detail = "Excel persistence adapter" }
            @{ dependencyId = "REL-001..011"; type = "Explicit D&B"; state = "NOT_APPLICABLE"; status = $null; detail = "No Dependencies & Blockers row references the target or its chain" }
        )
        openDecisions = @()
        auditFindings = @()
        risk = "Low"; parallelSafe = $true
        workbookSha256 = (Get-Hash $f.wbCopy)
    }
    Write-F031Json $f "preflight.json" $pre
}

function New-M04Fixture([string]$name, [hashtable]$extraCurrent) {
    $f = New-F031 $name
    New-Item -ItemType Directory -Force -Path (Join-Path $f.root "logs") | Out-Null
    $null = Remove-ReservationsForNode $f.wbCopy "WI-07-0.2.4"
    Write-CompletePreflight $f
    $cur = [ordered]@{
        nodeId = "WI-07-0.2.4"; taskId = "WI-07-0.2.4"; name = ("DB-M03.1 M04 fixture " + $name)
        nodeType = "WorkItem"; phase = "P0"; layer = "App"
        status = "PREFLIGHTED"; nextAllowedAction = "RESERVE"; changeId = ""
        selectedAt = "2026-08-31T00:00:00Z"; mode = "TRIAL"
        pendingGovernanceItems = @()
    }
    foreach ($k in $extraCurrent.Keys) { $cur[$k] = $extraCurrent[$k] }
    Write-F031Json $f "current-task.json" $cur
    return $f
}
function New-M05Fixture([string]$name, [hashtable]$extraCurrent) {
    $f = New-F031 $name
    New-Item -ItemType Directory -Force -Path (Join-Path $f.root "logs") | Out-Null
    $null = Remove-ReservationsForNode $f.wbCopy "WI-07-0.2.4"
    $null = Add-ReservationFull $f "CHG-20260830-017" "WI-07-0.2.4"
    Write-CompletePreflight $f
    $cur = [ordered]@{
        nodeId = "WI-07-0.2.4"; taskId = "WI-07-0.2.4"; name = ("DB-M03.1 M05 fixture " + $name)
        nodeType = "WorkItem"; phase = "P0"; layer = "App"
        status = "RESERVED"; nextAllowedAction = "CHATGPT_HANDOFF"; changeId = "CHG-20260830-017"
        selectedAt = "2026-08-31T00:00:00Z"; mode = "TRIAL"
        pendingGovernanceItems = @()
    }
    foreach ($k in $extraCurrent.Keys) { $cur[$k] = $extraCurrent[$k] }
    Write-F031Json $f "current-task.json" $cur
    # Record the LIVE Nexus git baseline so M05's "no Nexus source code changed"
    # check (New-ChatGptHandoff.ps1, compares live git status against this recorded
    # baseline) passes. A real DB-M04 reserve captures exactly this state; the
    # workbook-modified line is exempted by the engine itself. Self-maintaining:
    # whatever the repo currently has is the honest pre-existing baseline.
    $untrackedNow = @()
    foreach ($gline in @(& git -C "C:\Personal\Nexus.Developer" status --porcelain=v1 2>$null)) {
        if ($gline -match '^\?\?\s+(.+)$') { $untrackedNow += $matches[1] }
    }
    # Complete reservation.json: the M05 engine reads parallelLaneCheck + gitBaseline
    # under Set-StrictMode. Shape mirrors a real DB-M04 RESERVE (lane roots prove no
    # DevBridge/Nexus root overlap; gitBaseline is the recorded Nexus baseline).
    Write-F031Json $f "reservation.json" ([ordered]@{
        changeId = "CHG-20260830-017"; nodeId = "WI-07-0.2.4"; name = ("DB-M03.1 M05 fixture " + $name)
        mode = "TRIAL"; nextAllowedAction = "CHATGPT_HANDOFF"
        parallelLaneCheck = [ordered]@{
            status = "PASS"
            lanes = @(
                [ordered]@{ id = "DB-M12"; focus = "DevBridge Operator UI (UI/application layer only)"; root = "C:\\Personal\\DevTools\\DevBridge"; lane = "A"; overlap = $false; status = "RUNNING" }
                [ordered]@{ id = "DB-M13"; focus = "AI Routing/Cost Platform Discovery (design/discovery artifacts only, no executable router)"; root = "C:\\Personal\\DevTools\\DevBridge"; lane = "B"; overlap = $false; status = "RUNNING" }
                [ordered]@{ id = "Nexus WI-07-0.2.4"; focus = "Concurrency, locking and atomic writes"; root = "C:\\Personal\\Nexus.Developer"; lane = "C"; overlap = $false; status = "RESERVED (this lane)" }
            )
        }
        gitBaseline = [ordered]@{
            repository = "C:\\Personal\\Nexus.Developer"
            branch = "feature/m-08-1-2-ci-pipeline"
            headCommit = "ea39db910a6e3b00bff880316996a696ae7460dc"
            headSubject = "CHG-20260830-015: workbook v3.26 - WI-07-0.2.2 verified clean, marked Complete; M-07-0.2 at 20%"
            preExistingChanges = [ordered]@{ staged = @(); modified = @(); untracked = @($untrackedNow) }
            postReservationModifiedFiles = @()
            scopeFileHashes = @()
        }
    })
    return $f
}

# ---- Group A: deterministic node implementability classification ------------
Write-Output "== Group A: classification =="

# A1  Milestone -> NON_IMPLEMENTABLE_CONTAINER. M-07-0.2 is the governed current-work
#     anchor; its first eligible planned child WI-07-0.2.4 is resolved as the task. The
#     container itself is never returned as the task.
$fA1 = New-F031 "a1_milestone"
$sA1 = Invoke-NextTaskD31 $fA1
Assert-True "A1 Milestone classified NON_IMPLEMENTABLE_CONTAINER; resolved to eligible leaf descendant" ($sA1.status -eq "SELECTED" -and $sA1.task -eq "WI-07-0.2.4" -and $sA1.currentWork -eq "M-07-0.2" -and (($sA1.basis -join " ") -match "NON_IMPLEMENTABLE_CONTAINER") -and (($sA1.basis -join " ") -match "chain WI-07-0.2.4")) ("got " + $sA1.status + " task=" + $sA1.task + " cw=" + $sA1.currentWork)

# A2  Feature -> NON_IMPLEMENTABLE_CONTAINER (NodeType column governs, not NodeId prefix).
$fA2 = New-F031 "a2_feature"
Set-NodeCell $fA2 "M-07-0.2" "Node Type" "Feature"
$sA2 = Invoke-NextTaskD31 $fA2
Assert-True "A2 Feature classified NON_IMPLEMENTABLE_CONTAINER; resolved to WI-07-0.2.4" ($sA2.status -eq "SELECTED" -and $sA2.task -eq "WI-07-0.2.4" -and (($sA2.basis -join " ") -match "NON_IMPLEMENTABLE_CONTAINER")) ("got " + $sA2.status + " task=" + $sA2.task)

# A3  Layer -> NON_IMPLEMENTABLE_CONTAINER.
$fA3 = New-F031 "a3_layer"
Set-NodeCell $fA3 "M-07-0.2" "Node Type" "Layer"
$sA3 = Invoke-NextTaskD31 $fA3
Assert-True "A3 Layer classified NON_IMPLEMENTABLE_CONTAINER; resolved to WI-07-0.2.4" ($sA3.status -eq "SELECTED" -and $sA3.task -eq "WI-07-0.2.4" -and (($sA3.basis -join " ") -match "NON_IMPLEMENTABLE_CONTAINER")) ("got " + $sA3.status + " task=" + $sA3.task)

# A4  Leaf WorkItem -> IMPLEMENTABLE_LEAF; the current-work node itself is the task.
$fA4 = New-F031 "a4_leaf_workitem"
Make-CurrentWork $fA4 "WI-07-0.2.4" "CHG-20260901-004"
$sA4 = Invoke-NextTaskD31 $fA4
Assert-True "A4 leaf WorkItem classified IMPLEMENTABLE_LEAF; selected as itself" ($sA4.status -eq "SELECTED" -and $sA4.task -eq "WI-07-0.2.4" -and $sA4.currentWork -eq "WI-07-0.2.4" -and (($sA4.basis -join " ") -match "IMPLEMENTABLE_LEAF")) ("got " + $sA4.status + " task=" + $sA4.task)

# A5  WorkItem BreakdownComplete=No -> INCOMPLETE_WORK_ITEM -> HUMAN_GOVERNANCE_REQUIRED.
$fA5 = New-F031 "a5_incomplete"
Make-CurrentWork $fA5 "WI-07-0.2.4" "CHG-20260901-005"
Set-NodeCell $fA5 "WI-07-0.2.4" "Breakdown Complete" "No"
$sA5 = Invoke-NextTaskD31 $fA5
Assert-True "A5 WorkItem BreakdownComplete=No -> INCOMPLETE_WORK_ITEM -> HUMAN_GOVERNANCE_REQUIRED" ($sA5.status -eq "HUMAN_GOVERNANCE_REQUIRED" -and $sA5.blockState -eq "HUMAN_GOVERNANCE_REQUIRED" -and $sA5.task -eq "" -and (($sA5.basis -join " ") -match "INCOMPLETE_WORK_ITEM")) ("got " + $sA5.status + " block=" + $sA5.blockState)

# A6  WorkItem with children -> NON_IMPLEMENTABLE_CONTAINER (children imply container).
$fA6 = New-F031 "a6_workitem_container"
Set-NodeCell $fA6 "M-07-0.2" "Node Type" "WorkItem"
$sA6 = Invoke-NextTaskD31 $fA6
Assert-True "A6 WorkItem with children classified NON_IMPLEMENTABLE_CONTAINER; resolved to WI-07-0.2.4" ($sA6.status -eq "SELECTED" -and $sA6.task -eq "WI-07-0.2.4" -and (($sA6.basis -join " ") -match "NON_IMPLEMENTABLE_CONTAINER")) ("got " + $sA6.status + " task=" + $sA6.task)

# A7  Task with children -> NON_IMPLEMENTABLE_CONTAINER.
$fA7 = New-F031 "a7_task_container"
Set-NodeCell $fA7 "M-07-0.2" "Node Type" "Task"
$sA7 = Invoke-NextTaskD31 $fA7
Assert-True "A7 Task with children classified NON_IMPLEMENTABLE_CONTAINER; resolved to WI-07-0.2.4" ($sA7.status -eq "SELECTED" -and $sA7.task -eq "WI-07-0.2.4" -and (($sA7.basis -join " ") -match "NON_IMPLEMENTABLE_CONTAINER")) ("got " + $sA7.status + " task=" + $sA7.task)

# A8  Leaf Task -> IMPLEMENTABLE_LEAF.
$fA8 = New-F031 "a8_leaf_task"
Make-CurrentWork $fA8 "T-01-1.1.3.1" "CHG-20260901-008"
$sA8 = Invoke-NextTaskD31 $fA8
Assert-True "A8 leaf Task classified IMPLEMENTABLE_LEAF; selected as itself" ($sA8.status -eq "SELECTED" -and $sA8.task -eq "T-01-1.1.3.1" -and $sA8.currentWork -eq "T-01-1.1.3.1" -and (($sA8.basis -join " ") -match "IMPLEMENTABLE_LEAF")) ("got " + $sA8.status + " task=" + $sA8.task)

# A9  Subtask -> IMPLEMENTABLE_LEAF.
$fA9 = New-F031 "a9_subtask"
Make-CurrentWork $fA9 "S-01-1.1.1.1.1" "CHG-20260901-009"
$sA9 = Invoke-NextTaskD31 $fA9
Assert-True "A9 Subtask classified IMPLEMENTABLE_LEAF; selected as itself" ($sA9.status -eq "SELECTED" -and $sA9.task -eq "S-01-1.1.1.1.1" -and $sA9.currentWork -eq "S-01-1.1.1.1.1" -and (($sA9.basis -join " ") -match "IMPLEMENTABLE_LEAF")) ("got " + $sA9.status + " task=" + $sA9.task)

# A10 Unknown NodeType (unclassifiable LEAF) -> UNKNOWN_NODE_TYPE -> IMPLEMENTATION_TARGET_UNKNOWN.
# Note: an unknown-type node WITH children is still resolved through (its descendants can be
# identified), so the deterministic UNKNOWN trigger is a leaf carrying an out-of-vocabulary type.
$fA10 = New-F031 "a10_unknown"
Make-CurrentWork $fA10 "S-01-1.1.1.1.1" "CHG-20260901-010"
Set-NodeCell $fA10 "S-01-1.1.1.1.1" "Node Type" "Widget"
$sA10 = Invoke-NextTaskD31 $fA10
Assert-True "A10 unknown NodeType leaf -> IMPLEMENTATION_TARGET_UNKNOWN (never a task)" ($sA10.status -eq "IMPLEMENTATION_TARGET_UNKNOWN" -and $sA10.blockState -eq "IMPLEMENTATION_TARGET_UNKNOWN" -and $sA10.task -eq "" -and $sA10.currentWork -eq "S-01-1.1.1.1.1" -and (($sA10.basis -join " ") -match "outside the governed vocabulary")) ("got " + $sA10.status + " block=" + $sA10.blockState + " cw=" + $sA10.currentWork)

# ---- Group B: container-node handling + honest block states -----------------
Write-Output "== Group B: container resolution & block states =="

# B11 Container -> eligible planned leaf SELECTED (chain reported).
$fB11 = New-F031 "b11_container_to_leaf"
$sB11 = Invoke-NextTaskD31 $fB11
Assert-True "B11 container resolves to the eligible planned leaf WI-07-0.2.4 (deps satisfied, not trial-proven)" ($sB11.status -eq "SELECTED" -and $sB11.task -eq "WI-07-0.2.4" -and (($sB11.basis -join " ") -match "deps satisfied") -and (($sB11.basis -join " ") -match "not trial-proven")) ("got " + $sB11.status + " task=" + $sB11.task)

# B12 Deep chain container -> container -> leaf (re-pointed Subtask under a Task-typed
#     WI-07-0.2.4). Resolver must recurse two levels and return the leaf Subtask.
$fB12 = New-F031 "b12_deep_chain"
Set-NodeCell $fB12 "WI-07-0.2.4" "Node Type" "Task"
Set-NodeCell $fB12 "S-01-1.1.1.1.1" "Parent ID" "WI-07-0.2.4"
$sB12 = Invoke-NextTaskD31 $fB12
Assert-True "B12 deep chain (M-07-0.2 -> WI-07-0.2.4 -> S-01-1.1.1.1.1) resolves to the leaf Subtask" ($sB12.status -eq "SELECTED" -and $sB12.task -eq "S-01-1.1.1.1.1" -and (($sB12.basis -join " ") -match "chain WI-07-0.2.4 -> S-01-1.1.1.1.1")) ("got " + $sB12.status + " task=" + $sB12.task)

# B13 Dependency-unsatisfied descendants -> NO_IMPLEMENTABLE_DESCENDANT. History
#     excludes WI-07-0.2.4 (Planned); WI-07-0.2.5..10 are transitively dep-blocked.
$fB13 = New-F031 "b13_dep_blocked"
Write-ProvingHistory $fB13 @("WI-07-0.2.4")
$sB13 = Invoke-NextTaskD31 $fB13
Assert-True "B13 dependency-unsatisfied descendants -> NO_IMPLEMENTABLE_DESCENDANT (container never the task)" ($sB13.status -eq "NO_IMPLEMENTABLE_DESCENDANT" -and $sB13.blockState -eq "NO_IMPLEMENTABLE_DESCENDANT" -and $sB13.task -eq "" -and $sB13.currentWork -eq "M-07-0.2") ("got " + $sB13.status + " task=" + $sB13.task)

# B14 Trial-proven-excluded-only child -> NO_IMPLEMENTABLE_DESCENDANT. Every other
#     child is terminal (Completed), so the block is caused ONLY by trial exclusion.
$fB14 = New-F031 "b14_trial_only"
Write-ProvingHistory $fB14 @("WI-07-0.2.4")
Set-NodeCell $fB14 "WI-07-0.2.5" "Status" "Completed"
Set-NodeCell $fB14 "WI-07-0.2.6" "Status" "Completed"
Set-NodeCell $fB14 "WI-07-0.2.7" "Status" "Completed"
Set-NodeCell $fB14 "WI-07-0.2.8" "Status" "Completed"
Set-NodeCell $fB14 "WI-07-0.2.9" "Status" "Completed"
Set-NodeCell $fB14 "WI-07-0.2.10" "Status" "Completed"
$sB14 = Invoke-NextTaskD31 $fB14
Assert-True "B14 trial-proven-excluded-only child -> NO_IMPLEMENTABLE_DESCENDANT" ($sB14.status -eq "NO_IMPLEMENTABLE_DESCENDANT" -and $sB14.task -eq "" -and $sB14.currentWork -eq "M-07-0.2" -and (($sB14.basis -join " ") -match "M-07-0.2")) ("got " + $sB14.status + " task=" + $sB14.task)

# B15 Dependency order preserved: completing WI-07-0.2.4 unblocks WI-07-0.2.5, which
#     becomes the next eligible leaf (first in governed order, not 6).
$fB15 = New-F031 "b15_dep_order"
Set-NodeCell $fB15 "WI-07-0.2.4" "Status" "Completed"
$sB15 = Invoke-NextTaskD31 $fB15
Assert-True "B15 completing the dep-blocker unblocks the next sibling; WI-07-0.2.5 selected in governed order" ($sB15.status -eq "SELECTED" -and $sB15.task -eq "WI-07-0.2.5" -and $sB15.currentWork -eq "M-07-0.2") ("got " + $sB15.status + " task=" + $sB15.task)

# B16 INCOMPLETE_WORK_ITEM descendant does not block a ready sibling.
$fB16 = New-F031 "b16_incomplete_sibling"
Set-NodeCell $fB16 "WI-07-0.2.4" "Breakdown Complete" "No"
Clear-NodeCell $fB16 "WI-07-0.2.5" "Dependencies"
$sB16 = Invoke-NextTaskD31 $fB16
Assert-True "B16 INCOMPLETE child skipped; ready sibling WI-07-0.2.5 selected" ($sB16.status -eq "SELECTED" -and $sB16.task -eq "WI-07-0.2.5") ("got " + $sB16.status + " task=" + $sB16.task)

# B17 UNKNOWN_NODE_TYPE child subtree is skipped whole (never fatal, never selected).
$fB17 = New-F031 "b17_unknown_child"
Set-NodeCell $fB17 "WI-07-0.2.4" "Node Type" "Widget"
Clear-NodeCell $fB17 "WI-07-0.2.5" "Dependencies"
$sB17 = Invoke-NextTaskD31 $fB17
Assert-True "B17 unknown child subtree skipped; ready sibling WI-07-0.2.5 selected" ($sB17.status -eq "SELECTED" -and $sB17.task -eq "WI-07-0.2.5") ("got " + $sB17.status + " task=" + $sB17.task)

# ---- Group C: selection flow (CURRENT WORK FIRST / NEXT WORK / ordering) -----
Write-Output "== Group C: selection flow =="

# C18 Freshest-reservation anchoring: a fresh reservation naming a leaf outranks the
#     higher-priority container M-07-0.2 (row 80) because the freshest row wins.
$fC18 = New-F031 "c18_freshest_anchor"
Make-CurrentWork $fC18 "T-01-1.1.3.1" "CHG-20260901-018"
$sC18 = Invoke-NextTaskD31 $fC18
Assert-True "C18 freshest reservation anchors the leaf T-01-1.1.3.1 over container M-07-0.2" ($sC18.status -eq "SELECTED" -and $sC18.currentWork -eq "T-01-1.1.3.1" -and $sC18.task -eq "T-01-1.1.3.1") ("got " + $sC18.status + " cw=" + $sC18.currentWork + " task=" + $sC18.task)

# C19 CURRENT WORK FIRST preserved: M-07-0.2 (In Progress) is honored as the anchor and
#     NOT skipped for higher-ranked NEXT WORK planned Features (e.g. F-06-2).
$fC19 = New-F031 "c19_current_work_first"
$sC19 = Invoke-NextTaskD31 $fC19
Assert-True "C19 CURRENT WORK FIRST: M-07-0.2 anchors (not F-06-2); resolved to WI-07-0.2.4" ($sC19.status -eq "SELECTED" -and $sC19.currentWork -eq "M-07-0.2" -and $sC19.task -eq "WI-07-0.2.4" -and (($sC19.basis -join " ") -match "CURRENT WORK FIRST")) ("got " + $sC19.status + " cw=" + $sC19.currentWork + " task=" + $sC19.task)

# C20 NEXT WORK fallback (no current work): the top-ranked planned node F-06-2 is a
#     governed container with no eligible descendant -> honest NO_IMPLEMENTABLE_DESCENDANT.
$fC20 = New-F031 "c20_next_work_block"
Write-ProvingHistory $fC20 @("M-07-0.2", "M-07-10.3", "M-12-0.4")
$sC20 = Invoke-NextTaskD31 $fC20
Assert-True "C20 NEXT WORK fallback: container F-06-2 blocked honestly (never the task)" ($sC20.status -eq "NO_IMPLEMENTABLE_DESCENDANT" -and $sC20.blockState -eq "NO_IMPLEMENTABLE_DESCENDANT" -and $sC20.currentWork -eq "" -and $sC20.task -eq "" -and (($sC20.basis -join " ") -match "F-06-2")) ("got " + $sC20.status + " cw=" + $sC20.currentWork + " task=" + $sC20.task)

# C21 NEXT WORK SELECTED leaf: with the five earlier-ranked Features terminal, the top-ranked
#     Planned node is the Critical-priority leaf WI-06-8.1.1. The workbook marks it
#     BreakdownComplete=No, so without intervention the engine would honestly block with
#     HUMAN_GOVERNANCE_REQUIRED (a clean governance signal). Clearing the breakdown to "Yes"
#     (completing the governed breakdown) makes it a clean IMPLEMENTABLE_LEAF that NEXT WORK
#     selects as the task - the container is never the task.
$fC21 = New-F031 "c21_next_work_leaf"
Write-ProvingHistory $fC21 @("M-07-0.2", "M-07-10.3", "M-12-0.4")
Set-NodeCell $fC21 "F-06-2" "Status" "Completed"
Set-NodeCell $fC21 "F-06-3" "Status" "Completed"
Set-NodeCell $fC21 "F-06-4" "Status" "Completed"
Set-NodeCell $fC21 "F-06-5" "Status" "Completed"
Set-NodeCell $fC21 "F-06-6" "Status" "Completed"
Set-NodeCell $fC21 "WI-06-8.1.1" "Breakdown Complete" "Yes"
$sC21 = Invoke-NextTaskD31 $fC21
Assert-True "C21 NEXT WORK selects the top-ranked Planned leaf WI-06-8.1.1 (container never the task)" ($sC21.status -eq "SELECTED" -and $sC21.currentWork -eq "" -and $sC21.task -eq "WI-06-8.1.1" -and (($sC21.basis -join " ") -match "NEXT WORK")) ("got " + $sC21.status + " cw=" + $sC21.currentWork + " task=" + $sC21.task)

# C22 Dependency-order first-eligible: with both WI-07-0.2.5 and WI-07-0.2.6 eligible
#     (blocker Completed + 6's deps cleared), 5 (lower Row) wins governed order.
$fC22 = New-F031 "c22_dep_order_first"
Set-NodeCell $fC22 "WI-07-0.2.4" "Status" "Completed"
Clear-NodeCell $fC22 "WI-07-0.2.6" "Dependencies"
$sC22 = Invoke-NextTaskD31 $fC22
Assert-True "C22 both siblings eligible; first in governed order WI-07-0.2.5 selected (not 6)" ($sC22.status -eq "SELECTED" -and $sC22.task -eq "WI-07-0.2.5") ("got " + $sC22.status + " task=" + $sC22.task)

# C23 Trial-history exclusion reaches current-work detection: WI-07-0.2.4 is In Progress
#     with a FRESH open reservation yet is excluded (proven), so selection never returns
#     it; the fallback blocks honestly on the top planned container F-06-2.
$fC23 = New-F031 "c23_trial_exclusion_candidate"
Write-ProvingHistory $fC23 @("M-07-0.2", "M-07-10.3", "M-12-0.4", "WI-07-0.2.4")
Make-CurrentWork $fC23 "WI-07-0.2.4" "CHG-20260901-023"
$sC23 = Invoke-NextTaskD31 $fC23
Assert-True "C23 trial-proven node excluded even with a fresh reservation; never reselected" ($sC23.status -eq "NO_IMPLEMENTABLE_DESCENDANT" -and $sC23.task -ne "WI-07-0.2.4" -and (($sC23.basis -join " ") -match "F-06-2")) ("got " + $sC23.status + " task=" + $sC23.task)

# ---- Group D: preflight integration (real Test-DevelopmentPreflight engine) ----
Write-Output "== Group D: preflight integration =="

# D24 CLEAR leaf preflight: container M-07-0.2 resolves to WI-07-0.2.4; the preflight
#     clears and records implementability=IMPLEMENTABLE_LEAF / nextAction RESERVE.
$fD24 = New-F031 "d24_clear_leaf"
$vD24 = Invoke-Preflight $fD24
$ctD24 = Read-F031Json $fD24 "current-task.json"
Assert-True "D24 leaf preflight CLEAR with implementability IMPLEMENTABLE_LEAF / RESERVE" ($vD24 -eq "CLEAR" -and [string]$ctD24.implementability -eq "IMPLEMENTABLE_LEAF" -and [string]$ctD24.nextAllowedAction -eq "RESERVE" -and [string]$ctD24.nodeId -eq "WI-07-0.2.4") ("verdict=" + $vD24 + " impl=" + $ctD24.implementability + " next=" + $ctD24.nextAllowedAction)

# D25 Container block preflight: no eligible descendant -> NO_IMPLEMENTABLE_DESCENDANT
#     record; current-task stays PREFLIGHTED at the anchor with RESOLVE_GOVERNANCE_BLOCK.
$fD25 = New-F031 "d25_container_block"
Write-ProvingHistory $fD25 @("WI-07-0.2.4")
$vD25 = Invoke-Preflight $fD25
$ctD25 = Read-F031Json $fD25 "current-task.json"
Assert-True "D25 container block preflight -> NO_IMPLEMENTABLE_DESCENDANT, anchor PREFLIGHTED, RESOLVE_GOVERNANCE_BLOCK" ($vD25 -eq "NO_IMPLEMENTABLE_DESCENDANT" -and [string]$ctD25.status -eq "PREFLIGHTED" -and [string]$ctD25.nodeId -eq "M-07-0.2" -and [string]$ctD25.implementability -eq "NON_IMPLEMENTABLE_CONTAINER" -and [string]$ctD25.nextAllowedAction -eq "RESOLVE_GOVERNANCE_BLOCK") ("verdict=" + $vD25 + " node=" + $ctD25.nodeId + " impl=" + $ctD25.implementability)

# D26 Human-governance block preflight: incomplete WorkItem anchor.
$fD26 = New-F031 "d26_human_block"
Make-CurrentWork $fD26 "WI-07-0.2.4" "CHG-20260901-026"
Set-NodeCell $fD26 "WI-07-0.2.4" "Breakdown Complete" "No"
$vD26 = Invoke-Preflight $fD26
$ctD26 = Read-F031Json $fD26 "current-task.json"
Assert-True "D26 incomplete anchor -> HUMAN_GOVERNANCE_REQUIRED, node WI-07-0.2.4, INCOMPLETE_WORK_ITEM" ($vD26 -eq "HUMAN_GOVERNANCE_REQUIRED" -and [string]$ctD26.nodeId -eq "WI-07-0.2.4" -and [string]$ctD26.implementability -eq "INCOMPLETE_WORK_ITEM" -and [string]$ctD26.nextAllowedAction -eq "RESOLVE_GOVERNANCE_BLOCK") ("verdict=" + $vD26 + " node=" + $ctD26.nodeId + " impl=" + $ctD26.implementability)

# D27 Unknown-type block preflight (unclassifiable leaf anchor).
$fD27 = New-F031 "d27_unknown_block"
Make-CurrentWork $fD27 "S-01-1.1.1.1.1" "CHG-20260901-027"
Set-NodeCell $fD27 "S-01-1.1.1.1.1" "Node Type" "Widget"
$vD27 = Invoke-Preflight $fD27
$ctD27 = Read-F031Json $fD27 "current-task.json"
Assert-True "D27 unknown anchor -> IMPLEMENTATION_TARGET_UNKNOWN, UNKNOWN_NODE_TYPE" ($vD27 -eq "IMPLEMENTATION_TARGET_UNKNOWN" -and [string]$ctD27.nodeId -eq "S-01-1.1.1.1.1" -and [string]$ctD27.implementability -eq "UNKNOWN_NODE_TYPE") ("verdict=" + $vD27 + " impl=" + $ctD27.implementability)

# D28 leafValidation ledger: identity/hierarchy/execution-state/dependencies PASS, and
#     acceptance criteria honestly recorded as AC_ABSENT_WARN (no ancestor carries AC).
$fD28 = New-F031 "d28_leaf_validation"
$vD28 = Invoke-Preflight $fD28
$pfD28 = Read-F031Json $fD28 "preflight.json"
$lvD28 = @($pfD28.leafValidation)
$identityLv = @($lvD28 | Where-Object { $_.check -eq "identity" })[0]
$acLv = @($lvD28 | Where-Object { $_.check -eq "acceptance-criteria" })[0]
$depLv = @($lvD28 | Where-Object { $_.check -eq "dependencies" })[0]
Assert-True "D28 leafValidation ledger emitted on CLEAR with identity PASS" ($vD28 -eq "CLEAR" -and $lvD28.Count -ge 5 -and $identityLv -and [string]$identityLv.status -eq "PASS") ("verdict=" + $vD28 + " checks=" + $lvD28.Count)
Assert-True "D28 acceptance-criteria honestly AC_ABSENT_WARN (no governed AC in ancestry)" ($acLv -and [string]$acLv.status -eq "AC_ABSENT_WARN") ("got " + $acLv.status)
Assert-True "D28 dependencies ledger PASS" ($depLv -and [string]$depLv.status -eq "PASS") ("got " + $depLv.status)

# ---- Group E: M04 / M05 gates ------------------------------------------------
Write-Output "== Group E: M04 / M05 gates =="

# E29 M04 refuses a container-classified target (STOP_NOT_IMPLEMENTABLE_LEAF).
$fE29 = New-M04Fixture "e29_m04_refuse" @{ implementability = "NON_IMPLEMENTABLE_CONTAINER" }
$rE29 = Invoke-Reserve $fE29
Assert-True "E29 M04 refuses NON_IMPLEMENTABLE_CONTAINER target" ($rE29.outcome -eq "STOP_NOT_IMPLEMENTABLE_LEAF" -and -not $rE29.pass) ("got " + $rE29.outcome)

# E30 M04 backward compatible: legacy state (no implementability field) passes the new
#     gate and produces a REAL engine outcome (never STOP_NOT_IMPLEMENTABLE_LEAF, never a
#     crash/NO_MARKER — the StrictMode property-access regression is asserted non-vacuous).
$fE30 = New-M04Fixture "e30_m04_legacy" @{}
$rE30 = Invoke-Reserve $fE30
Assert-True "E30 M04 legacy state (no implementability) passes the gate with a real outcome" ($rE30.outcome -ne "STOP_NOT_IMPLEMENTABLE_LEAF" -and $rE30.outcome -ne "NO_MARKER") ("got " + $rE30.outcome)

# E31 M05 refuses a container-classified target (HANDOFF_CONTAINER_PROHIBITED).
$fE31 = New-M05Fixture "e31_m05_refuse" @{ implementability = "NON_IMPLEMENTABLE_CONTAINER" }
$rE31 = Invoke-Handoff $fE31
Assert-True "E31 M05 refuses NON_IMPLEMENTABLE_CONTAINER target" ($rE31.outcome -eq "HANDOFF_CONTAINER_PROHIBITED") ("got " + $rE31.outcome)

# E32 M05 backward compatible: legacy state (no implementability field) passes the new
#     gate and produces a REAL engine outcome (never HANDOFF_CONTAINER_PROHIBITED, never a
#     crash/NO_MARKER — non-vacuous like E30).
$fE32 = New-M05Fixture "e32_m05_legacy" @{}
$rE32 = Invoke-Handoff $fE32
Assert-True "E32 M05 legacy state (no implementability) passes the gate with a real outcome" ($rE32.outcome -ne "HANDOFF_CONTAINER_PROHIBITED" -and $rE32.outcome -ne "NO_MARKER") ("got " + $rE32.outcome)

# ---- invariants over the real workbook + repo + live evidence ----------------
Write-Output "== invariants =="
$realHashAfter = Get-Hash $script:RealWorkbook
Assert-True "I1 authoritative workbook untouched by suite" ($realHashAfter -eq $script:RealHashBefore) "authoritative workbook hash changed"
$repoAfter = @(& git -C "C:\Personal\Nexus.Developer" status --porcelain=v1 2>$null)
Assert-True "I2 Nexus repo status unchanged" (($repoAfter -join "`n") -eq ($script:RepoStatusBefore -join "`n")) "Nexus repo modified"
$liveTaskHashAfter = Get-Hash (Join-Path $script:Root "state\current-task.json")
Assert-True "I3 live state current-task.json untouched" ($liveTaskHashAfter -eq $script:LiveTaskHashBefore) "live current-task.json changed"

# I4 the DevBridge solution still builds
Write-Output "== I4 solution build =="
$sln = Join-Path $script:Root "src\DevBridge.slnx"
$oldEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$buildOut = @(& dotnet build $sln 2>&1)
$buildExit = $LASTEXITCODE
$ErrorActionPreference = $oldEAP
Assert-True "I4 solution build passes" ($buildExit -eq 0) ("build exit " + $buildExit)
$warnCount = @($buildOut | Select-String -Pattern "warning CS").Count
$errCount = @($buildOut | Select-String -Pattern "error CS").Count
Assert-True "I4 build has no compiler warnings" ($warnCount -eq 0) ("warnings " + $warnCount)
Assert-True "I4 build has no compiler errors" ($errCount -eq 0) ("errors " + $errCount)

# --- summary ------------------------------------------------------------------
Write-Output ""
$failCount = $script:Fails.Count
Write-Output ("DB-M03.1 SAFETY SUMMARY: {0} checks, {1} passed, {2} failed" -f $script:Results.Count, ($script:Results.Count - $failCount), $failCount)
if ($failCount -gt 0) {
    Write-Output "FAILURES:"
    foreach ($f in $script:Fails) { Write-Output ("  - " + $f) }
    exit 1
}
Write-Output "DB-M03.1 SUITE: PASS"
exit 0
