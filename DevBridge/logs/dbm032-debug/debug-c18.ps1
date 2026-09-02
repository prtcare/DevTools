# debug-c18.ps1 -- reproduce the C18 M05 engine run in isolation (full stderr).
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = "C:\Personal\DevTools\DevBridge"
. (Join-Path $root "scripts\Set-DevBridgeStateEntry.ps1")
. (Join-Path $root "scripts\Read-DevelopmentControl.ps1")

# ---- OOXML cell helpers (from the DB-M03.2 suite; proven) ----
function ColToIndex([string]$col) {
    $idx = 0
    foreach ($ch in $col.ToCharArray()) { $idx = $idx * 26 + ([int][char]$ch - 64) }
    return $idx
}
function ColOf([string]$ref) { return ($ref -replace '\d+$', '') }
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
function Set-CellValue($cellEl, [string]$value) {
    foreach ($child in @($cellEl.Elements($xNs + "v"))) { $child.Remove() }
    foreach ($child in @($cellEl.Elements($xNs + "is"))) { $child.Remove() }
    $cellEl.SetAttributeValue("t", "inlineStr")
    $is = New-Object System.Xml.Linq.XElement($xNs + "is"); $is.Add((New-TCell $value)); $cellEl.Add($is)
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
    if ($cell) { Set-CellValue $cell $value }
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
function Get-DevControlMap {
    $m = @($script:DevControlMap.sheets | Where-Object { $_.name -eq "Active Changes" })[0]
    return $m
}

$outDir = "C:\Personal\DevTools\DevBridge\logs\dbm032-debug\c18_repro"
if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $outDir "state") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $outDir "tasks") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $outDir "logs") | Out-Null
$wbCopy = Join-Path $outDir "workbook.xlsx"
$pristine = (Get-ChildItem (Join-Path $root "state\backups") -Filter "db-m124-preclosure-*.xlsx" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
Copy-Item $pristine $wbCopy -Force

# trial history + evidence for WI-07-0.2.4/CHG-20260830-017
$hist = @{ entries = @(
    [ordered]@{ nodeId = "WI-07-0.2.4"; changeId = "CHG-20260830-017"; closedAtUtc = "2026-08-31T15:24:45Z"; mode = "TRIAL"; result = "TRIAL_CYCLE_CLOSED"; implementationState = "TRIAL_ONLY_UNMERGED"; preReservationStatus = "Planned" }
) }
Write-DevBridgeJson (Join-Path $outDir "state\trial-proving-history.json") $hist | Out-Null

$evDir = Join-Path $outDir "logs\tasks\WI-07-0.2.4"
$evDir = Join-Path $evDir "CHG-20260830-017"
New-Item -ItemType Directory -Force -Path $evDir | Out-Null
Write-DevBridgeJson (Join-Path $evDir "claude-decision.json") ([ordered]@{ milestone = "DB-M08"; decision = "PASS"; dbM06Result = "VERIFICATION_PASS"; trialMode = $true; implementationState = "TRIAL_ONLY_UNMERGED"; reviewedAgainstDbM06 = $true; reviewTimestampUtc = "2026-08-31T01:40:00Z"; observations = @() }) | Out-Null
Write-DevBridgeJson (Join-Path $evDir "test-result.json") ([ordered]@{ passed = 199; failed = 0; skipped = 0; total = 199 }) | Out-Null
Write-DevBridgeJson (Join-Path $evDir "build-result.json") ([ordered]@{ succeeded = $true; warnings = 0; errors = 0 }) | Out-Null
[System.IO.File]::WriteAllText((Join-Path $evDir "VERIFICATION_RESULT.md"), "VERIFICATION RESULT`n## Result: VERIFICATION_PASS`n", (New-Object System.Text.UTF8Encoding($false)))

$scope = @{
    repos          = @("Nexus.Developer")
    projects       = @("Nexus.Developer.Core","Nexus.Developer.Infrastructure")
    filesGlobs     = @("src/Nexus.Developer.Core/DevelopmentControl/**","src/Nexus.Developer.Infrastructure/DevelopmentControl/ExcelDevelopmentControlStore.cs")
    schemaContexts = @()
    contractsApis  = @("IDevelopmentControlStore","IDevelopmentControlAtomicWorkUnitRunner")
    affectedNodes  = @("F-07-0","M-07-0.2","WI-07-0.2.1","WI-07-0.2.2","WI-07-0.2.3","WI-07-0.2.4","WI-07-0.2.5","WI-07-0.2.6","WI-07-0.2.7","WI-07-0.2.8","WI-07-0.2.9","WI-07-0.2.10")
}

# add reservation row (Active Changes) for CHG-20260901-040 / WI-07-0.2.5
$acMap = Get-DevControlMap
$hdr = [int]$acMap.headerRow; $start = [int]$acMap.dataStartRow
$rows = @(With-Workbook $wbCopy { @(Get-SheetRows "Active Changes" $hdr $start 100) })
$maxRow = $start
foreach ($r in $rows) { if ([int]$r.Row -gt $maxRow) { $maxRow = [int]$r.Row } }
$newRow = $maxRow + 1
Write-WorkbookCell $wbCopy "Active Changes" $newRow "Change ID" "CHG-20260901-040"
Write-WorkbookCell $wbCopy "Active Changes" $newRow "Node ID" "WI-07-0.2.5"
Write-WorkbookCell $wbCopy "Active Changes" $newRow "Repositories" ($scope.repos -join " | ")
Write-WorkbookCell $wbCopy "Active Changes" $newRow "Projects" ($scope.projects -join " | ")
Write-WorkbookCell $wbCopy "Active Changes" $newRow "Files / Globs" ($scope.filesGlobs -join " | ")
Write-WorkbookCell $wbCopy "Active Changes" $newRow "Contracts / APIs" ($scope.contractsApis -join " | ")
Write-WorkbookCell $wbCopy "Active Changes" $newRow "Affected Nodes" ($scope.affectedNodes -join " | ")
Write-WorkbookCell $wbCopy "Active Changes" $newRow "Status" "In Progress"
Write-WorkbookCell $wbCopy "Active Changes" $newRow "Preflight Verdict" "CLEAR"
Write-WorkbookCell $wbCopy "Active Changes" $newRow "Started At" "2026-09-01T00:00:00Z"

# preflight
$pre = [ordered]@{
    taskId = "WI-07-0.2.5"; nodeId = "WI-07-0.2.5"; name = "DB-M03.2 M05 fixture debug"
    verdict = "CLEAR"; phase = "P0"; parentNodeId = "M-07-0.2"; currentWorkNodeId = "M-07-0.2"; featureNodeId = "F-07-0"
    repositories = $scope.repos
    projects = $scope.projects
    filesGlobs = $scope.filesGlobs
    schemaContexts = $scope.schemaContexts
    contractsApis = $scope.contractsApis
    affectedNodes = $scope.affectedNodes
    dependencies = @(
        @{ dependencyId = "WI-07-0.2.4"; type = "Textual (node Dependencies)"; state = "TRIAL_DEPENDENCY_SATISFIED"; status = "Planned"; detail = "Concurrency, locking and atomic writes" }
        @{ dependencyId = "REL-001..011"; type = "Explicit D&B"; state = "NOT_APPLICABLE"; status = $null; detail = "No Dependencies & Blockers row references the target or its chain" }
    )
    openDecisions = @(); auditFindings = @()
    risk = "Low"; parallelSafe = $true
    workbookSha256 = (Get-FileHash $wbCopy -Algorithm SHA256).Hash
}
Write-DevBridgeJson (Join-Path $outDir "state\preflight.json") $pre | Out-Null

$cur = [ordered]@{
    nodeId = "WI-07-0.2.5"; taskId = "WI-07-0.2.5"; name = "DB-M03.2 M05 fixture debug"
    nodeType = "WorkItem"; phase = "P0"; layer = "App"
    status = "RESERVED"; nextAllowedAction = "CHATGPT_HANDOFF"; changeId = "CHG-20260901-040"
    selectedAt = "2026-09-01T00:00:00Z"; mode = "TRIAL"
    pendingGovernanceItems = @()
}
Write-DevBridgeJson (Join-Path $outDir "state\current-task.json") $cur | Out-Null
$untrackedNow = @()
foreach ($gline in @(& git -C "C:\Personal\Nexus.Developer" status --porcelain=v1 2>$null)) {
    if ($gline -match '^\?\?\s+(.+)$') { $untrackedNow += $matches[1] }
}
Write-DevBridgeJson (Join-Path $outDir "state\reservation.json") ([ordered]@{
    changeId = "CHG-20260901-040"; nodeId = "WI-07-0.2.5"; name = "DB-M03.2 M05 fixture debug"
    mode = "TRIAL"; nextAllowedAction = "CHATGPT_HANDOFF"
    parallelLaneCheck = [ordered]@{
        status = "PASS"
        lanes = @(
            [ordered]@{ id = "DB-M12"; focus = "DevBridge Operator UI"; root = "C:\\Personal\\DevTools\\DevBridge"; lane = "A"; overlap = $false; status = "RUNNING" }
            [ordered]@{ id = "DB-M13"; focus = "AI Routing/Cost Platform"; root = "C:\\Personal\\DevTools\\DevBridge"; lane = "B"; overlap = $false; status = "RUNNING" }
            [ordered]@{ id = "Nexus WI-07-0.2.5"; focus = "Development Control continuation"; root = "C:\\Personal\\Nexus.Developer"; lane = "C"; overlap = $false; status = "RESERVED (this lane)" }
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
}) | Out-Null

$env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE = $wbCopy
$env:DB05_STATE_DIR = (Join-Path $outDir "state")
$env:DB05_TASKS_DIR = (Join-Path $outDir "tasks")
$env:DB05_LOGS_DIR = (Join-Path $outDir "logs")

# mirror the suite's Age-SelftestFiles: age the fixture so the engine's tree sweep
# (LastWriteTimeUtc >= RunStart-5s) does not flag fixture setup as "touched".
Get-ChildItem $outDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    try { $_.LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddSeconds(-120) } catch {}
}

# simulate the suite parent writing its log right before spawning the engine
try { [System.IO.File]::AppendAllText((Join-Path $root "logs\db-m03-2-suite.log"), ("[debug-c18 probe touch] " + (Get-Date).ToString("o") + "`r`n")) } catch {}

$oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
$out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\New-ChatGptHandoff.ps1") 2>&1)
$ErrorActionPreference = $oldEAP
foreach ($k in @("DB_DEV_CONTROL_WORKBOOK_OVERRIDE","DB05_STATE_DIR","DB05_TASKS_DIR","DB05_LOGS_DIR")) { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue }

Write-Output "===== M05 ENGINE OUTPUT ====="
$out | ForEach-Object { Write-Output ("{0}" -f $_) }
Write-Output "===== END ====="
$hd = Join-Path $outDir "tasks\CHATGPT_HANDOFF.md"
Write-Output ("handoff exists: " + (Test-Path $hd))
if (Test-Path $hd) {
    $md = [System.IO.File]::ReadAllText($hd)
    Write-Output ("has Trial-Proven Dependency Context: " + ($md -match "Trial-Proven Dependency Context \(DB-M03.2\)"))
    Write-Output ("has NOT real Nexus completion: " + ($md -match "NOT real Nexus completion"))
    Write-Output ("has real roadmap status.*Planned: " + ($md -match "real roadmap status.*Planned"))
    Write-Output ("has real completion capability NO: " + ($md -match "real completion capability = \*\*NO\*\*"))
    Write-Output ("has disposable DevBridge proving context: " + ($md -match "disposable DevBridge proving context"))
    Write-Output ("has TRIAL_DEPENDENCY_SATISFIED | NO: " + ($md -match "TRIAL_DEPENDENCY_SATISFIED \| NO"))
    Write-Output ("no WI-07-0.2.4 marked Complete: " + (-not ($md -match "WI-07-0.2.4.*\|\s*Complete\s*\|")))
}
