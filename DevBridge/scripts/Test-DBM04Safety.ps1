# Test-DBM04Safety.ps1
# DevBridge DB-M04 PART 14 safety driver. Runs Reserve-DevelopmentChange.ps1
# against throwaway workbook copies and temp state/log/tasks dirs under
# logs\selftest\. The real workbook and real state are NEVER modified.
#
# Scenarios:
#   T1 stale preflight      -> STOP_PREFLIGHT_STALE, no write
#   T2 full reservation     -> RESERVED on a temp copy (proves the write path)
#   T3 idempotent re-run    -> REUSED, no duplicate row
#   T4 conflicting reserve  -> STOP_RESERVATION_CONFLICT, no write
#   T5 scope widening       -> STOP_SCOPE_CHANGE_REQUIRED, no write
#
# Invariant asserted at the end: the REAL workbook's SHA256 is unchanged by the
# whole suite, and the Nexus repo git state is untouched.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:Cfg = Get-Content (Join-Path $script:Root "config\devbridge.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$script:RealWorkbook = $script:Cfg.developmentControlWorkbook
$script:Engine = Join-Path $PSScriptRoot "Reserve-DevelopmentChange.ps1"
$script:SelftestRoot = Join-Path $script:Root "logs\selftest"
if (-not (Test-Path $script:SelftestRoot)) { New-Item -ItemType Directory -Force -Path $script:SelftestRoot | Out-Null }
Get-ChildItem $script:SelftestRoot -Directory | Remove-Item -Recurse -Force

# Load library for entry-name resolution + temp re-reads (real workbook read-only)
. (Join-Path $PSScriptRoot "Read-DevelopmentControl.ps1")

function Get-Hash([string]$p) {
    $h = Get-FileHash $p -Algorithm SHA256
    return $h.Hash
}
$script:RealHashBefore = Get-Hash $script:RealWorkbook
# Snapshot of the Nexus repo git state BEFORE the suite runs. The suite must not
# introduce ANY git-state delta; pre-existing dirty lines (the governed workbook
# modification + untracked WI-07-0.2.3 adapter files) are the allowed baseline.
$script:RepoStatusBefore = @(& git -C "C:\Personal\Nexus.Developer" status --porcelain=v1 2>$null)

function Get-NextExpectedChangeId {
    $datePart = ([DateTime]::UtcNow).ToString("yyyyMMdd")
    $cands = New-Object System.Collections.Generic.List[int]
    foreach ($c in @(Get-AllActiveChanges)) {
        $m = [regex]::Match($c.ChangeId, ("CHG-" + $datePart + "-(\d{3})"))
        if ($m.Success) { $cands.Add([int]$m.Groups[1].Value) }
    }
    foreach ($r in @(Get-SheetRows "Version History" 5 6 957)) {
        $m = [regex]::Match([string](Get-Value "Version History" $r 5 "Change ID"), ("CHG-" + $datePart + "-(\d{3})"))
        if ($m.Success) { $cands.Add([int]$m.Groups[1].Value) }
    }
    foreach ($r in @(Get-SheetRows "Activity Log" 4 5 200)) {
        $m = [regex]::Match([string](Get-Value "Activity Log" $r 4 "Change ID"), ("CHG-" + $datePart + "-(\d{3})"))
        if ($m.Success) { $cands.Add([int]$m.Groups[1].Value) }
    }
    foreach ($r in @(Get-SheetRows "Architecture Decisions" 4 5 200)) {
        $m = [regex]::Match([string](Get-Value "Architecture Decisions" $r 4 "Change ID"), ("CHG-" + $datePart + "-(\d{3})"))
        if ($m.Success) { $cands.Add([int]$m.Groups[1].Value) }
    }
    foreach ($r in @(Get-SheetRows "Dependencies & Blockers" 4 5 200)) {
        $m = [regex]::Match([string](Get-Value "Dependencies & Blockers" $r 4 "Source Change"), ("CHG-" + $datePart + "-(\d{3})"))
        if ($m.Success) { $cands.Add([int]$m.Groups[1].Value) }
    }
    $maxN = 0
    if ($cands.Count -gt 0) { $maxN = ($cands | Sort-Object | Select-Object -Last 1) }
    return ("CHG-{0}-{1:D3}" -f $datePart, ($maxN + 1))
}

function Get-NextExpectedActivityId {
    $datePart = ([DateTime]::UtcNow).ToString("yyyyMMdd")
    $cands = New-Object System.Collections.Generic.List[int]
    foreach ($r in @(Get-SheetRows "Activity Log" 4 5 200)) {
        $m = [regex]::Match([string](Get-Value "Activity Log" $r 4 "Activity ID"), ("ACT-" + $datePart + "-(\d{3})"))
        if ($m.Success) { $cands.Add([int]$m.Groups[1].Value) }
    }
    $maxN = 0
    if ($cands.Count -gt 0) { $maxN = ($cands | Sort-Object | Select-Object -Last 1) }
    return ("ACT-{0}-{1:D3}" -f $datePart, ($maxN + 1))
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
        Write-Output ("  [PASS] {0} - {1}" -f $label, $detail)
    }
}

# --- fixture helpers ---------------------------------------------------------
function New-Fixture([string]$name, [string]$verdict, [string]$nextAction, [string]$status) {
    $outDir = Join-Path $script:SelftestRoot $name
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $stateDir = Join-Path $outDir "state"; $tasksDir = Join-Path $outDir "tasks"; $logsDir = Join-Path $outDir "logs"
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    $wbCopy = Join-Path $outDir "workbook.xlsx"
    Copy-Item $script:RealWorkbook $wbCopy -Force
    # Isolation: the live workbook may already carry an open reservation for the
    # fixture's exact target node (e.g. the real CHG-20260830-017). Strip those rows
    # from the fixture copy so the suite exercises a clean reservation for the node
    # rather than inheriting a live conflict.
    $stripped = Remove-ReservationsForNode $wbCopy "WI-07-0.2.4"
    if ($stripped -gt 0) { Write-Host ("  (fixture isolation: stripped {0} live reservation row(s) for WI-07-0.2.4)" -f $stripped) }

    $pre = @{
        taskId = "WI-07-0.2.4"; nodeId = "WI-07-0.2.4"; name = "Concurrency, locking and atomic writes"
        verdict = $verdict; phase = "P0"; parentNodeId = "M-07-0.2"; currentWorkNodeId = "M-07-0.2"; featureNodeId = "F-07-0"
        repositories = @("Nexus.Developer")
        projects = @("Nexus.Developer.Core")
        filesGlobs = @("src/Nexus.Developer.Core/DevelopmentControl/**")
        schemaContexts = @()
        contractsApis = @("IDevelopmentControlStore")
        affectedNodes = @("F-07-0","M-07-0.2","WI-07-0.2.1","WI-07-0.2.2","WI-07-0.2.3","WI-07-0.2.4","WI-07-0.2.5","WI-07-0.2.6","WI-07-0.2.7","WI-07-0.2.8","WI-07-0.2.9","WI-07-0.2.10")
        dependencies = @(
            @{ dependencyId = "WI-07-0.2.3"; type = "Textual (node Dependencies)"; state = "SATISFIED"; status = "Complete"; detail = "Excel persistence adapter" }
            @{ dependencyId = "REL-001..011"; type = "Explicit D&B"; state = "NOT_APPLICABLE"; status = $null; detail = "No Dependencies & Blockers row references the target or its chain" }
        )
        risk = "Low"; parallelSafe = $true
    }
    $pre.workbookSha256 = Get-Hash $wbCopy
    $cur = @{ taskId = "WI-07-0.2.4"; nodeId = "WI-07-0.2.4"; status = $status; selectedAt = "2026-08-30T13:08:07Z"; nextAllowedAction = $nextAction; changeId = "" }
    $pre | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 (Join-Path $stateDir "preflight.json")
    $cur | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 (Join-Path $stateDir "current-task.json")

    return @{ outDir = $outDir; stateDir = $stateDir; tasksDir = $tasksDir; logsDir = $logsDir; wbCopy = $wbCopy }
}

function Invoke-Engine([hashtable]$fixture, [hashtable]$envOverrides) {
    $env:DB04_SELFTEST = "1"
    $env:DB04_WORKBOOK_OVERRIDE = $fixture.wbCopy
    $env:DB04_STATE_DIR = $fixture.stateDir
    $env:DB04_TASKS_DIR = $fixture.tasksDir
    $env:DB04_LOGS_DIR = $fixture.logsDir
    $env:DB04_TEST_STALE = ""; $env:DB04_TEST_CONFLICT = ""; $env:DB04_TEST_SCOPE_WIDEN = ""
    foreach ($k in $envOverrides.Keys) { Set-Item ("env:" + $k) ($envOverrides[$k]) }
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Engine 2>&1)
    $ErrorActionPreference = $oldEAP
    $out = @($out | ForEach-Object { "$_" })
    # clean env
    foreach ($k in @("DB04_SELFTEST","DB04_WORKBOOK_OVERRIDE","DB04_STATE_DIR","DB04_TASKS_DIR","DB04_LOGS_DIR","DB04_TEST_STALE","DB04_TEST_CONFLICT","DB04_TEST_SCOPE_WIDEN")) {
        Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue
    }
    $line = $out | Select-String -Pattern '^DB04_OUTCOME:' | Select-Object -First 1
    $outcome = "NO_OUTCOME"
    if ($line) { $outcome = $line.Line -replace '^DB04_OUTCOME:\s*', '' }
    $passLine = $out | Select-String -Pattern '^DB04_RESULT_PASS: True' | Select-Object -First 1
    $pass = ($null -ne $passLine)
    $cidLine = $out | Select-String -Pattern '^DB04_CHANGE_ID:' | Select-Object -First 1
    $cid = ""
    if ($cidLine) { $cid = $cidLine.Line -replace '^DB04_CHANGE_ID:\s*', '' }
    return @{ outcome = $outcome; pass = $pass; changeId = $cid; output = ($out -join "`n") }
}

function Add-SyntheticReservation([string]$wbPath, [string]$changeId, [string]$nodeId, [string]$filesGlobs, [string]$projects) {
    $entry = Get-SheetEntryName "Active Changes"
    $xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    $fs = [System.IO.File]::Open($wbPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
    $rd = New-Object System.IO.StreamReader($zip.GetEntry($entry).Open())
    $doc = [System.Xml.Linq.XDocument]::Load($rd)
    $rd.Close(); $zip.Dispose(); $fs.Dispose()

    $lastRow = 0
    foreach ($row in $doc.Root.Element($xNs + "sheetData").Elements($xNs + "row")) {
        $ra = $row.Attribute("r"); if ($ra) { $n = [int]$ra.Value; if ($n -gt $lastRow) { $lastRow = $n } }
    }
    $newRow = $lastRow + 1
    $rowEl = New-Object System.Xml.Linq.XElement($xNs + "row")
    $rowEl.SetAttributeValue("r", $newRow)
    $cellMap = @{ "A"=$changeId; "B"=$nodeId; "D"="Synthetic conflicting reservation"; "F"="Selftest"; "G"="Nexus.Developer"; "H"=$projects; "I"=$filesGlobs; "L"="Open -- synthetic"; "M"="CLEAR" }
    foreach ($col in $cellMap.Keys) {
        $c = New-Object System.Xml.Linq.XElement($xNs + "c")
        $c.SetAttributeValue("r", ($col + $newRow)); $c.SetAttributeValue("t", "inlineStr")
        $is = New-Object System.Xml.Linq.XElement($xNs + "is")
        $t = New-Object System.Xml.Linq.XElement($xNs + "t"); $t.Value = $cellMap[$col]; $is.Add($t)
        $c.Add($is); $rowEl.Add($c)
    }
    $doc.Root.Element($xNs + "sheetData").Add($rowEl)
    $dim = $doc.Root.Element($xNs + "dimension"); if ($dim) { $dim.SetAttributeValue("ref", ("A1:AD{0}" -f $newRow)) }

    $tmp = $wbPath + ".inj.tmp"
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

function Remove-ReservationsForNode([string]$wbPath, [string]$nodeId) {
    # Remove every Active Changes row whose Node ID (column B) token equals $nodeId.
    # Used by New-Fixture to isolate fixtures from live reservations on the target.
    $entry = Get-SheetEntryName "Active Changes"
    $xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
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
            if (@($toks | Where-Object { $_ -eq $nodeId }).Count -gt 0) {
                $row.Remove(); $removed++
            }
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

# --- T1 stale preflight ------------------------------------------------------
Write-Output "== T1 stale preflight =="
$t1 = New-Fixture "T1_stale" "CONFLICT_FOUND" "RESERVE" "PREFLIGHTED"
$t1HashBefore = Get-Hash $t1.wbCopy
$r1 = Invoke-Engine $t1 @{}
Assert-True "T1 outcome STOP_PREFLIGHT_STALE" ($r1.outcome -eq "STOP_PREFLIGHT_STALE") ("got " + $r1.outcome)
Assert-True "T1 no pass flag" (-not $r1.pass) "engine must not pass on stale"
Assert-True "T1 workbook untouched" ((Get-Hash $t1.wbCopy) -eq $t1HashBefore) "engine must not modify the stale fixture"

# --- T2 full self-test reservation (write path proof) ------------------------
Write-Output "== T2 full reservation on temp copy =="
$expectedCid = Get-NextExpectedChangeId
$expectedAid = Get-NextExpectedActivityId
$t2 = New-Fixture "T2_reserve" "CLEAR" "RESERVE" "PREFLIGHTED"
$r2 = Invoke-Engine $t2 @{}
Assert-True "T2 outcome RESERVED" ($r2.outcome -eq "RESERVED") ("got " + $r2.outcome)
Assert-True "T2 pass flag" $r2.pass "engine must pass"
Assert-True "T2 changeId is next in sequence" ($r2.changeId -eq $expectedCid) ("got " + $r2.changeId + ", expected " + $expectedCid)
Assert-True "T2 workbook changed by reservation" ((Get-Hash $t2.wbCopy) -ne $script:RealHashBefore) "reservation must write"

# Re-read the temp copy: reservation present exactly once, activity once, all sheets load
$script:DevControlWorkbook = $t2.wbCopy
$acRows = @(Get-AllActiveChanges | Where-Object { $_.ChangeId -eq $expectedCid })
$alAll = @(Get-SheetRows "Activity Log" 4 5 300)
$alRows = @($alAll | Where-Object { (Get-Value "Activity Log" $_ 4 "Activity ID") -eq $expectedAid })
$sheetOk = $true
foreach ($sn in @("Control Center","Master Roadmap","Active Changes","Audit Findings","Session Protocol","Version History","Phase Plan","Architecture Decisions","Open Decisions","Dependencies & Blockers","Tool & Integration Registry","Activity Log","Development Guide","Existing Assets")) {
    try { $null = Open-DocEntry (Get-SheetEntryName $sn) } catch { $sheetOk = $false }
}
Assert-True "T2 reservation row exists once" ($acRows.Count -eq 1) ("count " + $acRows.Count)
Assert-True "T2 activity row exists once" ($alRows.Count -eq 1) ("count " + $alRows.Count)
Assert-True "T2 all 14 sheets load" $sheetOk "re-opened temp workbook"
$script:DevControlWorkbook = $script:RealWorkbook

# --- T3 idempotent re-run (same fixture) -------------------------------------
Write-Output "== T3 idempotent re-run =="
$r3 = Invoke-Engine $t2 @{}
Assert-True "T3 outcome REUSED" ($r3.outcome -eq "REUSED") ("got " + $r3.outcome)
$script:DevControlWorkbook = $t2.wbCopy
$acRows3 = @(Get-AllActiveChanges | Where-Object { $_.ChangeId -eq $expectedCid })
$script:DevControlWorkbook = $script:RealWorkbook
Assert-True "T3 no duplicate reservation" ($acRows3.Count -eq 1) ("count " + $acRows3.Count)

# --- T4 conflicting reservation (injected live, no test flag) ----------------
Write-Output "== T4 conflicting reservation =="
$t4 = New-Fixture "T4_conflict" "CLEAR" "RESERVE" "PREFLIGHTED"
Add-SyntheticReservation $t4.wbCopy "CHG-20260830-999" "M-99-9.9" "src/Nexus.Developer.Infrastructure/DevelopmentControl/**" "Nexus.Developer.Infrastructure"
# The injection changed the workbook hash; refresh the fixture preflight's
# recorded hash so PART 1's serialization guard passes and PART 2's conflict
# guard is the single stop. (The stale-hash stop path is covered by T6.)
$t4pre = Get-Content (Join-Path $t4.stateDir "preflight.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$t4pre.workbookSha256 = Get-Hash $t4.wbCopy
$t4pre | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 (Join-Path $t4.stateDir "preflight.json")
$r4 = Invoke-Engine $t4 @{}
Assert-True "T4 outcome STOP_RESERVATION_CONFLICT" ($r4.outcome -eq "STOP_RESERVATION_CONFLICT") ("got " + $r4.outcome)
Assert-True "T4 no pass flag" (-not $r4.pass) "engine must not pass on conflict"

# --- T5 scope widening --------------------------------------------------------
Write-Output "== T5 scope widening =="
$t5 = New-Fixture "T5_scope" "CLEAR" "RESERVE" "PREFLIGHTED"
$t5HashBefore = Get-Hash $t5.wbCopy
$r5 = Invoke-Engine $t5 @{ DB04_TEST_SCOPE_WIDEN = "1" }
Assert-True "T5 outcome STOP_SCOPE_CHANGE_REQUIRED" ($r5.outcome -eq "STOP_SCOPE_CHANGE_REQUIRED") ("got " + $r5.outcome)
Assert-True "T5 no write occurred" ((Get-Hash $t5.wbCopy) -eq $t5HashBefore) "scope guard must stop before write"

# --- T6 stale workbook (external/parallel-lane write since DB-M03) -----------
# The fixture preflight records the ORIGINAL copy hash; injecting a non-conflicting
# row changes the workbook hash. PART 1 must STOP_PREFLIGHT_STALE before any
# reservation (the serialized-writer guard). Without the guard the injected row
# would NOT hard-conflict (different node/project/glob), proving the hash guard is
# what catches the external write.
Write-Output "== T6 stale workbook (external write since DB-M03) =="
$t6 = New-Fixture "T6_stale_wb" "CLEAR" "RESERVE" "PREFLIGHTED"
Add-SyntheticReservation $t6.wbCopy "CHG-20260830-998" "M-88-8.8" "some/other/glob/**" "Nexus.Developer.Other"
$r6 = Invoke-Engine $t6 @{}
Assert-True "T6 outcome STOP_PREFLIGHT_STALE" ($r6.outcome -eq "STOP_PREFLIGHT_STALE") ("got " + $r6.outcome)
Assert-True "T6 no pass flag" (-not $r6.pass) "engine must not pass on stale workbook"

# --- T7 DB-GH01 hardening: explicit mode + trial containment + pre-baseline ref --
Write-Output "== T7 DB-GH01 mode / trial containment / pre-DevBridge baseline =="
$t2State = Get-Content (Join-Path $t2.stateDir "current-task.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$t2Res = Get-Content (Join-Path $t2.stateDir "reservation.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True "T7 current-task.json carries explicit mode=TRIAL" ([string]$t2State.mode -eq "TRIAL") ("got " + [string]$t2State.mode)
Assert-True "T7 current-task.json carries trialContainment=true" ([string]$t2State.trialContainment -eq "True") ("got " + [string]$t2State.trialContainment)
Assert-True "T7 reservation.json carries mode=TRIAL" ([string]$t2Res.mode -eq "TRIAL") ("got " + [string]$t2Res.mode)
Assert-True "T7 reservation.json carries preDevBridgeBaseline reference" ($null -ne $t2Res.preDevBridgeBaseline) "preDevBridgeBaseline object must be present"
Assert-True "T7 self-test never captures the real baseline (represented=false)" ([string]$t2Res.preDevBridgeBaseline.represented -eq "False") ("got " + [string]$t2Res.preDevBridgeBaseline.represented)
Assert-True "T7 preDevBridgeBaseline.restoreForbidden states no auto-restore" (([string]$t2Res.preDevBridgeBaseline.restoreForbidden) -match "never restores") "restore-forbidden contract must be present"

# --- invariants over the real workbook + repo --------------------------------
Write-Output "== invariants =="
$realHashAfter = Get-Hash $script:RealWorkbook
Assert-True "real workbook untouched by suite" ($realHashAfter -eq $script:RealHashBefore) "self-tests must never write the real workbook"
# The Nexus tree legitimately carries pre-existing dirty lines (the governed
# workbook modification + untracked WI-07-0.2.3 adapter files). The invariant is
# that the SUITE introduces NO git-state delta relative to the startup snapshot.
$repoStatusAfter = @(& git -C "C:\Personal\Nexus.Developer" status --porcelain=v1 2>$null)
$repoDelta = @($repoStatusAfter | Where-Object { $script:RepoStatusBefore -notcontains $_ })
$repoDeltaRev = @($script:RepoStatusBefore | Where-Object { $repoStatusAfter -notcontains $_ })
Assert-True "nexus repo git state untouched by suite" ($repoDelta.Count -eq 0 -and $repoDeltaRev.Count -eq 0) ("git status delta introduced by suite: " + (($repoDelta + $repoDeltaRev) -join "; "))

# --- summary -----------------------------------------------------------------
Write-Output ""
$failCount = $script:Fails.Count
Write-Output ("SAFETY SUMMARY: {0} checks, {1} passed, {2} failed" -f $script:Results.Count, ($script:Results.Count - $failCount), $failCount)
if ($failCount -gt 0) {
    Write-Output "FAILURES:"
    foreach ($f in $script:Fails) { Write-Output ("  - " + $f) }
    exit 1
}
Write-Output "SAFETY: ALL PASS"
exit 0
