# Test-DBM04MultiRepositoryBaseline.ps1
# DevBridge DB-M04/DB-M05 multi-repository baseline driver.
#
# Guards the multi-repository baseline integrity fix:
#   - DB-M04 captures an independent pre-implementation git baseline for EVERY
#     repository in the exact reserved scope (not only the workbook-owner repo),
#     written as reservation.repositoryBaselines (primary first) and one entry per
#     repo in current-task.repositoryStates.
#   - DB-M05 renders every reserved repository's baseline in the handoff and STOPS
#     (BASELINE_COVERAGE_GAP) when any reserved repository has no baseline.
#   - Regenerating a handoff never creates a second reservation.
#
# Engine runs are all self-test redirections against THROWAWAY workbook copies and
# temp state/task/log dirs. The real workbook and the real reserved repositories are
# only ever read (git status/rev-parse/hash), never written. No DB-M06 run, no Nexus
# source modified, no new live reservation.
#
# Behaviors under test:
#   B1  single-repository reservation still works (backward compatibility)
#   B2  two-repository reservation captures BOTH baselines
#   B3  each repository retains an independent branch/HEAD/status record
#   B4  pre-existing changes + reserved-scope hashes are classified per repository
#   B5  DB-M05 renders every reserved repository baseline in the handoff
#   B6  per-repo evidence is shaped for DB-M06 to consume (repositoryStates[*])
#   B7  missing baseline for any reserved repository blocks the handoff
#   B8  no duplicate reservation is created (M04 re-run reuses; M05 adds none)
$ErrorActionPreference = "Stop"

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:Cfg = Get-Content (Join-Path $script:Root "config\devbridge.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$script:RealWorkbook = $script:Cfg.developmentControlWorkbook
$script:EngineM04 = Join-Path $PSScriptRoot "Reserve-DevelopmentChange.ps1"
$script:EngineM05 = Join-Path $PSScriptRoot "New-ChatGptHandoff.ps1"

. (Join-Path $PSScriptRoot "Read-DevelopmentControl.ps1")
$script:DevControlWorkbook = $script:RealWorkbook

# Primary workbook-owner repo derives from the config workbook path (leaf of parent dir).
$script:WbRepoDir = Split-Path $script:RealWorkbook -Parent
$script:PrimaryRepoName = Split-Path $script:WbRepoDir -Leaf
$script:SecondRepoName = "Nexus.Experience"
$script:SecondRepoPath = "C:\Personal\" + $script:SecondRepoName
if (-not (Test-Path (Join-Path $script:SecondRepoPath ".git"))) {
    Write-Output ("SECOND_REPO_MISSING: " + $script:SecondRepoPath)
    Write-Output "This suite requires the sibling reserved repository to be present (read-only baselining)."
    exit 2
}

function Get-Hash([string]$p) { return (Get-FileHash $p -Algorithm SHA256).Hash }
function Read-Json([string]$p) { return (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json) }

$script:Results = @()
$script:Fails = New-Object System.Collections.Generic.List[string]
$script:Skips = New-Object System.Collections.Generic.List[string]

function Assert-True([string]$label, [bool]$cond, [string]$detail) {
    $script:Results += [PSCustomObject]@{ Scenario = $label; Pass = $cond; Detail = $detail }
    if (-not $cond) {
        $script:Fails.Add(("{0}: {1}" -f $label, $detail))
        Write-Output ("  [FAIL] {0} - {1}" -f $label, $detail)
    } else {
        Write-Output ("  [PASS] {0}" -f $label)
    }
}
function Assert-Skip([string]$label, [string]$why) {
    $script:Skips.Add($label)
    $script:Results += [PSCustomObject]@{ Scenario = $label; Pass = $true; Detail = "SKIPPED: " + $why }
    Write-Output ("  [SKIP] {0} - {1}" -f $label, $why)
}

# --- workbook XML row helpers (throwaway copies only) --------------------------
function Get-AcRowNodeIds([string]$wbPath) {
    $entry = Get-SheetEntryName "Active Changes"
    $xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    $fs = [System.IO.File]::Open($wbPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
    $rd = New-Object System.IO.StreamReader($zip.GetEntry($entry).Open())
    $doc = [System.Xml.Linq.XDocument]::Load($rd)
    $rd.Close(); $zip.Dispose(); $fs.Dispose()
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($row in $doc.Root.Element($xNs + "sheetData").Elements($xNs + "row")) {
        foreach ($cell in $row.Elements($xNs + "c")) {
            $ra = $cell.Attribute("r")
            $col = if ($ra) { ([string]$ra.Value) -replace "\d+$", "" } else { "" }
            if ($col -eq "B") {
                $isEl = $cell.Element($xNs + "is"); $tEl = if ($isEl) { $isEl.Element($xNs + "t") } else { $null }
                $v = if ($tEl) { [string]$tEl.Value } else { $null }
                if ($v) { foreach ($tok in @(($v -split "\|") | ForEach-Object { $_.Trim() })) { if ($tok) { $out.Add($tok) } } }
                break
            }
        }
    }
    return @($out)
}
function Remove-ActiveRows([string]$wbPath, [scriptblock]$matchRow) {
    # Remove every Active Changes row for which $matchRow(nodeId, cellTextByCol) is true.
    # Returns number removed. cellTextByCol = { "A"=...; "G"=... } map for the row.
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
        $cells = @{}
        foreach ($cell in $row.Elements($xNs + "c")) {
            $ra = $cell.Attribute("r")
            $col = if ($ra) { ([string]$ra.Value) -replace "\d+$", "" } else { "" }
            $isEl = $cell.Element($xNs + "is"); $tEl = if ($isEl) { $isEl.Element($xNs + "t") } else { $null }
            $cells[$col] = if ($tEl) { [string]$tEl.Value } else { "" }
        }
        $nodeB = [string]$cells["B"]
        $toks = @(($nodeB -split "\|") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if (& $matchRow $toks $cells) { $row.Remove(); $removed++ }
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

# --- M04 fixture (throwaway copy under TEMP) ----------------------------------
function New-M04Fixture([string]$name, [string[]]$repositories, [string[]]$projects, [switch]$NoIsolation) {
    $outDir = Join-Path $env:TEMP ("dbm04multi-" + $name + "-" + [guid]::NewGuid().ToString("N"))
    $stateDir = Join-Path $outDir "state"; $tasksDir = Join-Path $outDir "tasks"; $logsDir = Join-Path $outDir "logs"
    New-Item -ItemType Directory -Force -Path $stateDir, $tasksDir, $logsDir | Out-Null
    $wbCopy = Join-Path $outDir "workbook.xlsx"
    Copy-Item $script:RealWorkbook $wbCopy -Force

    # Isolation: strip rows that carry a live/open reservation overlapping the
    # fixture's reserved scope so the fixture exercises a CLEAN two-repository
    # reservation. Any row referencing the second reserved repository (open or not)
    # and the workbook-owner's live current WI-12 reservation are removed.
    $rm = 0
    if (-not $NoIsolation) {
        $rm = Remove-ActiveRows $wbCopy {
            param($nodeToks, $cells)
            ($cells["G"] -match [regex]::Escape($script:SecondRepoName)) -or
            (@($nodeToks | Where-Object { $_ -eq "WI-12-0.4.1" }).Count -gt 0)
        }
    }
    Write-Host ("  (fixture isolation: removed " + $rm + " overlapping reservation row(s) from copy)")

    $pre = @{
        taskId = "WI-07-0.2.4"; nodeId = "WI-07-0.2.4"; name = "Concurrency, locking and atomic writes"
        verdict = "CLEAR"; phase = "P0"; parentNodeId = "M-07-0.2"; currentWorkNodeId = "M-07-0.2"; featureNodeId = "F-07-0"
        repositories = @($repositories)
        projects = @($projects)
        filesGlobs = @("src/Nexus.Developer.Core/DevelopmentControl/**", "src/Nexus.Experience.Client/**")
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
    $cur = @{ taskId = "WI-07-0.2.4"; nodeId = "WI-07-0.2.4"; status = "PREFLIGHTED"; selectedAt = "2026-09-03T00:00:00Z"; nextAllowedAction = "RESERVE"; changeId = "" }
    Write-JsonU8 (Join-Path $stateDir "preflight.json") $pre
    Write-JsonU8 (Join-Path $stateDir "current-task.json") $cur
    return @{ outDir = $outDir; stateDir = $stateDir; tasksDir = $tasksDir; logsDir = $logsDir; wbCopy = $wbCopy }
}
function Write-JsonU8([string]$path, $obj) {
    [System.IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 40), (New-Object System.Text.UTF8Encoding($false)))
}

# --- engine invocation (child process, env redirection, real files untouched) --
function Invoke-Engine([string]$engine, [hashtable]$fixture, [hashtable]$envOverrides) {
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($engine -eq $script:EngineM04) {
            $env:DB04_SELFTEST = "1"; $env:DB04_WORKBOOK_OVERRIDE = $fixture.wbCopy
            $env:DB04_STATE_DIR = $fixture.stateDir; $env:DB04_TASKS_DIR = $fixture.tasksDir; $env:DB04_LOGS_DIR = $fixture.logsDir
            $env:DB04_TEST_STALE = ""; $env:DB04_TEST_CONFLICT = ""; $env:DB04_TEST_SCOPE_WIDEN = ""
            foreach ($k in $envOverrides.Keys) { Set-Item ("env:" + $k) ($envOverrides[$k]) }
            $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine 2>&1)
            foreach ($k in @("DB04_SELFTEST","DB04_WORKBOOK_OVERRIDE","DB04_STATE_DIR","DB04_TASKS_DIR","DB04_LOGS_DIR","DB04_TEST_STALE","DB04_TEST_CONFLICT","DB04_TEST_SCOPE_WIDEN")) { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue }
            $oc = "NO_OUTCOME"; $ocLine = $out | Select-String -Pattern '^DB04_OUTCOME:' | Select-Object -First 1
            if ($ocLine) { $oc = ($ocLine.Line -replace '^DB04_OUTCOME:\s*', '').Trim() }
            $cid = ""; $cidLine = $out | Select-String -Pattern '^DB04_CHANGE_ID:' | Select-Object -First 1
            if ($cidLine) { $cid = ($cidLine.Line -replace '^DB04_CHANGE_ID:\s*', '').Trim() }
            $pass = ($null -ne ($out | Select-String -Pattern '^DB04_RESULT_PASS: True' | Select-Object -First 1))
            return @{ outcome = $oc; pass = $pass; changeId = $cid; output = ($out -join "`n") }
        } else {
            $env:DB05_STATE_DIR = $fixture.stateDir; $env:DB05_TASKS_DIR = $fixture.tasksDir; $env:DB05_LOGS_DIR = $fixture.logsDir
            $env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE = $fixture.wbCopy
            foreach ($k in $envOverrides.Keys) { Set-Item ("env:" + $k) ($envOverrides[$k]) }
            $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine 2>&1)
            foreach ($k in @("DB05_STATE_DIR","DB05_TASKS_DIR","DB05_LOGS_DIR","DB_DEV_CONTROL_WORKBOOK_OVERRIDE")) { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue }
            $oc = "NO_OUTCOME"; $ocLine = $out | Select-String -Pattern '^DB05_OUTCOME:' | Select-Object -First 1
            if ($ocLine) { $oc = ($ocLine.Line -replace '^DB05_OUTCOME:\s*', '').Trim() }
            $pass = ($null -ne ($out | Select-String -Pattern '^DB05_RESULT_PASS: True' | Select-Object -First 1))
            $cons = ($null -ne ($out | Select-String -Pattern '^DB05_CONSISTENCY_GATE: PASS' | Select-Object -First 1))
            return @{ outcome = $oc; pass = $pass; consistency = $cons; changeId = ""; output = ($out -join "`n") }
        }
    } finally {
        $ErrorActionPreference = $oldEAP
    }
}

function Get-ProjectOfPath([string]$relPath, [string]$prefix1, [string]$prefix2) {
    $n = $relPath -replace '\\', '/'
    if ($n.StartsWith($prefix1, [System.StringComparison]::OrdinalIgnoreCase)) { return $prefix1 }
    if ($prefix2 -and $n.StartsWith($prefix2, [System.StringComparison]::OrdinalIgnoreCase)) { return $prefix2 }
    return ""
}

# =============================================================================
Write-Output "== B1/B2/B3/B4/B6/B8a: DB-M04 multi-repository baseline capture =="

# B1  Single-repository reservation (historical shape) must still work and emit
#     exactly one primary baseline.
#     NOTE: like S2, the throwaway workbook copy is isolated from the LIVE open
#     reservations (the current governed change CHG-20260903-001 holds the same
#     project Nexus.Developer.Core). DB-M04 must not refuse a single-repo fixture
#     because the live multi-repo reservation already occupies that project - that
#     is governed conflict detection, not single-repo backward compatibility. The
#     fixture still reserves one repo/one project and must emit one primary baseline.
Write-Output "== S1 single-repository reservation (backward compatibility) =="
$f1 = New-M04Fixture "s1_single" @($script:PrimaryRepoName) @("Nexus.Developer.Core")
$r1 = Invoke-Engine $script:EngineM04 $f1 @{}
Assert-True "B1 M04 single-repo outcome RESERVED" ($r1.outcome -eq "RESERVED") ("got " + $r1.outcome + " :: HEAD[" + ((($r1.output -split "`n") | Select-Object -First 40) -join " / ") + "] TAIL[" + ((($r1.output -split "`n") | Select-Object -Last 15) -join " / ") + "]")
$res1 = Read-Json (Join-Path $f1.stateDir "reservation.json")
$rb1 = @($res1.repositoryBaselines)
Assert-True "B1 repositoryBaselines has exactly one (primary) baseline" ($rb1.Count -eq 1) ("count " + $rb1.Count)
Assert-True "B1 primary baseline is the workbook-owner repo" ($rb1[0].isPrimary -eq $true -and $rb1[0].name -eq $script:PrimaryRepoName) ("got " + $rb1[0].name)
Assert-True "B1 flat gitBaseline still present (backward compat)" ([bool]$res1.gitBaseline) ("missing gitBaseline")

# B2/B3/B4/B6  Two-repository reservation.
Write-Output "== S2 two-repository reservation =="
$f2 = New-M04Fixture "s2_two" @($script:PrimaryRepoName, $script:SecondRepoName) @("Nexus.Developer.Core", "Nexus.Experience.Client")
$r2 = Invoke-Engine $script:EngineM04 $f2 @{}
Assert-True "B2 M04 two-repo outcome RESERVED" ($r2.outcome -eq "RESERVED") ("got " + $r2.outcome + " :: " + (($r2.output -split "`n" | Select-Object -Last 25) -join " / "))
if ($r2.outcome -eq "RESERVED") {
    $res2 = Read-Json (Join-Path $f2.stateDir "reservation.json")
    $rb2 = @($res2.repositoryBaselines)
    $bdev = @($rb2 | Where-Object { $_.name -eq $script:PrimaryRepoName })[0]
    $bexp = @($rb2 | Where-Object { $_.name -eq $script:SecondRepoName })[0]

    Assert-True "B2 repositoryBaselines captures BOTH reserved repositories" ($rb2.Count -eq 2) ("count " + $rb2.Count)
    Assert-True "B2 reservedScope lists both repositories" (@(@($res2.reservedScope.repositories) | Where-Object { $_ -in @($script:PrimaryRepoName, $script:SecondRepoName) }).Count -eq 2) ("got " + (@($res2.reservedScope.repositories) -join ","))

    Assert-True "B3 workbook-owner repo is PRIMARY; sibling is non-primary" ($bdev.isPrimary -eq $true -and $bexp.isPrimary -eq $false) ("dev " + $bdev.isPrimary + " exp " + $bexp.isPrimary)
    Assert-True "B3 each baseline has its own repository path" ($bdev.path -ne $bexp.path -and $bdev.path -eq [string]$res2.gitBaseline.repository) ("dev " + $bdev.path + " exp " + $bexp.path)
    Assert-True "B3 each baseline retains an independent branch + HEAD" ([bool]$bdev.branch -and [bool]$bdev.headCommit -and [bool]$bexp.branch -and [bool]$bexp.headCommit -and $bdev.headCommit -ne $bexp.headCommit) ("dev " + $bdev.branch + "@" + $bdev.headCommit + " ; exp " + $bexp.branch + "@" + $bexp.headCommit)
    Assert-True "B3 primary branch/HEAD agree with flat gitBaseline" ($bdev.branch -eq $res2.gitBaseline.branch -and $bdev.headCommit -eq $res2.gitBaseline.headCommit) ("flat " + $res2.gitBaseline.branch + "@" + $res2.gitBaseline.headCommit)

    Assert-True "B4 each baseline carries its own preExistingChanges record" ([bool]$bdev.preExistingChanges -and [bool]$bexp.preExistingChanges -and ($bdev.preExistingChanges.note -match $script:PrimaryRepoName -or $bdev.preExistingChanges.note -match "pre-existing") -and $bexp.preExistingChanges.note -match $script:SecondRepoName) "pre-existing note missing per-repo"
    # Each repo's pre-existing dirty set is attributed to that repo only (independent).
    $devPref = @($bdev.preExistingChanges.modified) + @($bdev.preExistingChanges.staged) + @($bdev.preExistingChanges.untracked)
    $expPref = @($bexp.preExistingChanges.modified) + @($bexp.preExistingChanges.staged) + @($bexp.preExistingChanges.untracked)
    Assert-True "B4 pre-existing changes classified per repo (not duplicated onto primary)" (($devPref.Count -gt 0 -and $expPref.Count -gt 0) -and (@($devPref | Where-Object { $s = $_ -replace '\\','/'; $s.StartsWith('src/Nexus.Experience.Client/') }).Count -eq 0)) ("dev " + $devPref.Count + " exp " + $expPref.Count)

    Assert-True "B6 per-repo scopeFileHashes present for both repositories" (@($bdev.scopeFileHashes).Count -gt 0 -and @($bexp.scopeFileHashes).Count -gt 0) ("dev " + @($bdev.scopeFileHashes).Count + " exp " + @($bexp.scopeFileHashes).Count)
    $badDevHash = @($bdev.scopeFileHashes | Where-Object { -not $_.path.StartsWith('src/Nexus.Developer.Core/') })
    $badExpHash = @($bexp.scopeFileHashes | Where-Object { -not $_.path.StartsWith('src/Nexus.Experience.Client/') })
    Assert-True "B4 reserved-scope hashes are owned by the matching repository project" (@($badDevHash).Count -eq 0 -and @($badExpHash).Count -eq 0) ("devOff " + @($badDevHash).Count + " expOff " + @($badExpHash).Count)
    $hashShape = @($bexp.scopeFileHashes | Where-Object { -not ($_.path -and $_.sha256 -and $_.bytes) }).Count
    Assert-True "B4 scope hash entries carry path/sha256/bytes" ($hashShape -eq 0) ("bad " + $hashShape)

    # B6  DB-M06 consumes current-task.repositoryStates; each reserved repo has an
    #     independent entry carrying branch/HEAD/status/scope hashes.
    $ct2 = Read-Json (Join-Path $f2.stateDir "current-task.json")
    $rs2 = @($ct2.repositoryStates)
    $rsDev = @($rs2 | Where-Object { $_.repository -eq $script:PrimaryRepoName })[0]
    $rsExp = @($rs2 | Where-Object { $_.repository -eq $script:SecondRepoName })[0]
    Assert-True "B6 current-task.repositoryStates has one independent entry per repo" ($rs2.Count -eq 2 -and [bool]$rsDev -and [bool]$rsExp) ("count " + $rs2.Count)
    Assert-True "B6 each repositoryState carries path/branch/headCommit/dirty/scopeFileHashes for DB-M06" ([bool]$rsDev.path -and [bool]$rsDev.branch -and [bool]$rsDev.headCommit -and ($null -ne $rsDev.dirty) -and [bool]$rsExp.path -and [bool]$rsExp.branch -and [bool]$rsExp.headCommit -and ($null -ne $rsExp.dirty) -and @($rsExp.scopeFileHashes).Count -gt 0) "repositoryState shape incomplete"
    Assert-True "B6 repositoryState[0] is the primary (workbook-owner) repo" ($rs2[0].repository -eq $script:PrimaryRepoName) ("got " + $rs2[0].repository)

    # B8a  Re-running M04 on the same reservation reuses it - no duplicate row/baseline.
    Write-Output "== S3 idempotent re-run (no duplicate reservation) =="
    $r3 = Invoke-Engine $script:EngineM04 $f2 @{}
    Assert-True "B8 M04 re-run outcome REUSED (no second reservation)" ($r3.outcome -eq "REUSED") ("got " + $r3.outcome)
    $script:DevControlWorkbook = $f2.wbCopy
    $ac3 = @(Get-AllActiveChanges | Where-Object { $_.ChangeId -eq $r2.changeId })
    $script:DevControlWorkbook = $script:RealWorkbook
    Assert-True "B8 exactly one Active Changes row for the change remains" ($ac3.Count -eq 1) ("count " + $ac3.Count)
    $res3 = Read-Json (Join-Path $f2.stateDir "reservation.json")
    Assert-True "B8 repositoryBaselines still two after re-run (unchanged scope)" (@($res3.repositoryBaselines).Count -eq 2) ("count " + @($res3.repositoryBaselines).Count)
}

# =============================================================================
Write-Output "== B5/B7/B8b: DB-M05 multi-repository baseline rendering =="

# DB-M05 has no synthetic-fixture automation seam and revalidates the workbook's
# governed reservation chain, so its multi-repo scenarios run against a THROWAWAY
# copy of the live workbook + a temp copy of the current live reserved state. This
# is the exact precondition set DB-M05 is designed for (proven by the governed
# WI-12 handoff) and exercises the NEW multi-repo baseline rendering + coverage
# gate without touching live state or the live workbook.
$liveCt = Read-Json (Join-Path $script:Root "state\current-task.json")
$liveRes = Read-Json (Join-Path $script:Root "state\reservation.json")
$liveCid = [string]$liveCt.changeId
$liveRb = @($liveRes.repositoryBaselines)
$liveNode = [string]$liveCt.nodeId

if ($liveCid -and $liveRb.Count -ge 2) {
    $f5 = @{}
    $f5["outDir"] = Join-Path $env:TEMP ("dbm05multi-" + [guid]::NewGuid().ToString("N"))
    $f5dir = $f5["outDir"]
    New-Item -ItemType Directory -Force -Path (Join-Path $f5dir "state"), (Join-Path $f5dir "tasks"), (Join-Path $f5dir "logs") | Out-Null
    Copy-Item (Join-Path $script:Root "state\current-task.json") (Join-Path $f5dir "state\current-task.json") -Force
    Copy-Item (Join-Path $script:Root "state\reservation.json") (Join-Path $f5dir "state\reservation.json") -Force
    Copy-Item (Join-Path $script:Root "state\preflight.json") (Join-Path $f5dir "state\preflight.json") -Force
    Copy-Item $script:RealWorkbook (Join-Path $f5dir "workbook.xlsx") -Force
    $f5["stateDir"] = Join-Path $f5dir "state"; $f5["tasksDir"] = Join-Path $f5dir "tasks"; $f5["logsDir"] = Join-Path $f5dir "logs"; $f5["wbCopy"] = Join-Path $f5dir "workbook.xlsx"
    # Re-open the handoff step on the temp copy (mirror of the governed reset - no new reservation).
    $ct5 = Read-Json (Join-Path $f5["stateDir"] "current-task.json")
    $ct5.status = "RESERVED"; $ct5.nextAllowedAction = "CHATGPT_HANDOFF"
    Write-JsonU8 (Join-Path $f5["stateDir"] "current-task.json") $ct5

    Write-Output "== S4 DB-M05 renders every reserved repository baseline (live-snapshot copy) =="
    $r5 = Invoke-Engine $script:EngineM05 $f5 @{}
    Assert-True "B5 M05 outcome HANDOFF_GENERATED (two-repo reservation passes)" ($r5.outcome -eq "HANDOFF_GENERATED") ("got " + $r5.outcome)
    Assert-True "B5 M05 consistency gate PASS" ($r5.consistency) "DB05_CONSISTENCY_GATE not PASS"
    $hd = Join-Path $f5["tasksDir"] "CHATGPT_HANDOFF.md"
    if ($r5.outcome -eq "HANDOFF_GENERATED" -and (Test-Path $hd)) {
        $hText = Get-Content $hd -Raw
        $rendered = @($liveRb | ForEach-Object {
            ($hText -match [regex]::Escape($_.name)) -and ($hText -match [regex]::Escape($_.headCommit))
        })
        Assert-True "B5 every reserved repository baseline is rendered in the handoff" (@($rendered | Where-Object { -not $_ }).Count -eq 0) ("missing render for one of " + (@($liveRb | ForEach-Object { $_.name }) -join ","))
        Assert-True "B5 handoff marks the workbook-owner repo PRIMARY" ($hText -match [regex]::Escape($script:PrimaryRepoName) -and $hText -match "PRIMARY") "no PRIMARY baseline in handoff"
    } else {
        Assert-True "B5 handoff file written to fixture tasks dir" (Test-Path $hd) ("missing " + $hd)
    }
    $script:DevControlWorkbook = $f5["wbCopy"]
    $ac5 = @(Get-AllActiveChanges | Where-Object { $_.ChangeId -eq $liveCid })
    $script:DevControlWorkbook = $script:RealWorkbook
    Assert-True "B8 DB-M05 added no second reservation (row count still one)" ($ac5.Count -eq 1) ("count " + $ac5.Count)
    $res5 = Read-Json (Join-Path $f5["stateDir"] "reservation.json")
    Assert-True "B8 DB-M05 changed no baseline evidence (repositoryBaselines still two)" (@($res5.repositoryBaselines).Count -eq 2) ("count " + @($res5.repositoryBaselines).Count)

    # B7  Coverage gap: a reserved repository WITHOUT a baseline blocks the handoff.
    #     Strip repositoryBaselines -> legacy single-gitBaseline shape while the
    #     workbook row still reserves both repos -> must STOP BASELINE_COVERAGE_GAP.
    Write-Output "== S5 missing baseline for a reserved repository blocks handoff =="
    $res6 = Read-Json (Join-Path $f5["stateDir"] "reservation.json")
    $res6.PSObject.Properties.Remove("repositoryBaselines") | Out-Null
    Write-JsonU8 (Join-Path $f5["stateDir"] "reservation.json") $res6
    # Re-open the handoff step exactly as S4 did (S4's M05 run advanced the temp
    # current-task state to post-handoff, which would otherwise stop S5 as stale) and
    # clear S4's rendered handoff so a coverage-gap STOP must produce NO handoff file.
    $ct6 = Read-Json (Join-Path $f5["stateDir"] "current-task.json")
    $ct6.status = "RESERVED"; $ct6.nextAllowedAction = "CHATGPT_HANDOFF"
    Write-JsonU8 (Join-Path $f5["stateDir"] "current-task.json") $ct6
    $s5hd = Join-Path $f5["tasksDir"] "CHATGPT_HANDOFF.md"
    if (Test-Path $s5hd) { Remove-Item $s5hd -Force }
    $r6 = Invoke-Engine $script:EngineM05 $f5 @{}
    Assert-True "B7 M05 STOPS BASELINE_COVERAGE_GAP when a reserved repo has no baseline" ($r6.outcome -eq "BASELINE_COVERAGE_GAP") ("got " + $r6.outcome)
    Assert-True "B7 no handoff written on coverage gap" (-not (Test-Path (Join-Path $f5["tasksDir"] "CHATGPT_HANDOFF.md"))) "handoff must not be written"
    Assert-True "B7 no pass flag on coverage gap" (-not $r6.pass) "engine must not pass"
    $script:DevControlWorkbook = $f5["wbCopy"]
    $ac6 = @(Get-AllActiveChanges | Where-Object { $_.ChangeId -eq $liveCid })
    $script:DevControlWorkbook = $script:RealWorkbook
    Assert-True "B8 coverage-gap stop created no reservation" ($ac6.Count -eq 1) ("count " + $ac6.Count)
} else {
    Assert-Skip "B5/B7/B8b DB-M05 multi-repo scenarios" "live reservation is not currently two-repository-baselined (need repositoryBaselines >= 2 for changeId $liveCid)"
}

# =============================================================================
Write-Output ""
Write-Output "== Summary =="
$failCount = $script:Fails.Count
Write-Output ("DBM04MULTI_PASS: " + (@($script:Results | Where-Object { $_.Pass }).Count) + " assertions")
Write-Output ("DBM04MULTI_FAIL: " + $failCount + ($(if ($script:Skips.Count) { ("; skipped: " + ($script:Skips -join ", ")) } else { "" })))
if ($failCount -gt 0) {
    Write-Output "Failures:"
    foreach ($fl in $script:Fails) { Write-Output ("  - " + $fl) }
}
Write-Output ("DBM04MULTI_RESULT: " + $(if ($failCount -eq 0) { "PASS" } else { "FAIL" }))
if ($failCount -gt 0) { exit 1 }
exit 0
