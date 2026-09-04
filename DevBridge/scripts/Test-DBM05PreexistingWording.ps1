# Test-DBM05PreexistingWording.ps1
# Guard for the DB-M05 handoff wording change that governs PRE-EXISTING DIRTY
# FILES inside a reserved task scope.
#
# Old (too broad) wording told DeepSeek that pre-existing dirty/untracked files
# "must not be touched or committed" - which contradicts legitimate MINIMAL
# incremental edits to reserved in-scope files (e.g. App.tsx / AppLayout.tsx /
# AppRoutes.tsx under a reserved Nexus.Experience.Client) required by the
# acceptance criteria. The replacement wording (New-ChatGptHandoff.ps1) keeps
# pre-existing content classified PRE-EXISTING CHANGE while allowing a minimal
# in-scope edit when a pre-reservation content/hash was captured, and STOPS with
# PREEXISTING_FILE_BASELINE_INSUFFICIENT when an untracked file cannot be
# attributed.
#
# This test regenerates DB-M05 on a THROWAWAY copy of the live reserved state and
# workbook (exactly the DB-M05 precondition, mirroring the S4 pattern in
# Test-DBM04MultiRepositoryBaseline.ps1 - no new reservation, no live write) and
# asserts:
#   - DB-M05 outcome HANDOFF_GENERATED and consistency gate PASS
#   - the regenerated handoff contains the new ownership/minimal-edit wording
#     and STOPS-with-insufficient-baseline instruction
#   - the old blanket phrase ("must not touch or commit them") is GONE
#   - both reserved repository baselines are still rendered (names + HEADs)
#   - the live workbook and live current-task state are byte-identical (untouched)
#
# When the live reservation is not a two-repository baseline the scenario is
# skipped (like the rest of the multi-repo suite).
#
# ASCII-only. Run: powershell -File scripts\Test-DBM05PreexistingWording.ps1
param()
$ErrorActionPreference = "Stop"

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:EngineM05 = Join-Path $PSScriptRoot "New-ChatGptHandoff.ps1"
$script:Cfg = Get-Content (Join-Path $script:Root "config\devbridge.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$script:RealWorkbook = [string]$script:Cfg.developmentControlWorkbook

$script:Results = @()
$script:Fails = New-Object System.Collections.Generic.List[string]
$script:Skips = New-Object System.Collections.Generic.List[string]

function Assert-True([string]$label, [bool]$cond, [string]$detail) {
    $script:Results += [PSCustomObject]@{ Scenario = $label; Pass = $cond; Detail = $detail }
    if (-not $cond) { $script:Fails.Add(("{0}: {1}" -f $label, $detail)); Write-Output ("  [FAIL] {0} - {1}" -f $label, $detail) }
    else { Write-Output ("  [PASS] {0}" -f $label) }
}
function Assert-Skip([string]$label, [string]$why) {
    $script:Skips.Add($label)
    $script:Results += [PSCustomObject]@{ Scenario = $label; Pass = $true; Detail = "SKIPPED: " + $why }
    Write-Output ("  [SKIP] {0} - {1}" -f $label, $why)
}
function Read-Json([string]$p) { return (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json) }
function Write-JsonU8([string]$p, $obj) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($p, ($obj | ConvertTo-Json -Depth 30), $enc)
}

$liveCt = Read-Json (Join-Path $script:Root "state\current-task.json")
$liveRes = Read-Json (Join-Path $script:Root "state\reservation.json")
$liveCid = [string]$liveCt.changeId
$liveRb = @($liveRes.repositoryBaselines)

Write-Output "== DB-M05 pre-existing-change wording regression =="

if (-not $liveCid -or $liveRb.Count -lt 2) {
    Assert-Skip "DB-M05 wording regression" "live reservation is not two-repository-baselined (need repositoryBaselines >= 2 for changeId '$liveCid')"
} else {
    $f5dir = Join-Path $env:TEMP ("dbm05wording-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path (Join-Path $f5dir "state"), (Join-Path $f5dir "tasks"), (Join-Path $f5dir "logs") | Out-Null
    Copy-Item (Join-Path $script:Root "state\current-task.json") (Join-Path $f5dir "state\current-task.json") -Force
    Copy-Item (Join-Path $script:Root "state\reservation.json")  (Join-Path $f5dir "state\reservation.json") -Force
    Copy-Item (Join-Path $script:Root "state\preflight.json")    (Join-Path $f5dir "state\preflight.json") -Force
    Copy-Item $script:RealWorkbook (Join-Path $f5dir "workbook.xlsx") -Force
    $f = @{
        stateDir = Join-Path $f5dir "state"
        tasksDir = Join-Path $f5dir "tasks"
        logsDir  = Join-Path $f5dir "logs"
        wbCopy   = Join-Path $f5dir "workbook.xlsx"
    }
    # Re-open the handoff step on the fixture (mirror of the governed reset - no new reservation).
    $ct5 = Read-Json (Join-Path $f["stateDir"] "current-task.json")
    $ct5.status = "RESERVED"; $ct5.nextAllowedAction = "CHATGPT_HANDOFF"
    Write-JsonU8 (Join-Path $f["stateDir"] "current-task.json") $ct5

    $liveWbBytes = [IO.File]::ReadAllBytes($script:RealWorkbook)
    $liveCtBytes = [IO.File]::ReadAllBytes((Join-Path $script:Root "state\current-task.json"))

    $env:DB05_STATE_DIR = $f["stateDir"]; $env:DB05_TASKS_DIR = $f["tasksDir"]; $env:DB05_LOGS_DIR = $f["logsDir"]
    $env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE = $f["wbCopy"]
    try {
        $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:EngineM05 2>&1)
    } finally {
        foreach ($k in @("DB05_STATE_DIR","DB05_TASKS_DIR","DB05_LOGS_DIR","DB_DEV_CONTROL_WORKBOOK_OVERRIDE")) { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue }
    }
    $joined = ($out | ForEach-Object { "$_" }) -join "`n"
    $oc = "NO_OUTCOME"; $m = [regex]::Match($joined, 'DB05_OUTCOME:\s*(\S+)'); if ($m.Success) { $oc = $m.Groups[1].Value }
    $pass = ($joined -match 'DB05_RESULT_PASS: True')
    $cons = ($joined -match 'DB05_CONSISTENCY_GATE: PASS')
    Write-Output ("  engine outcome: " + $oc)

    Assert-True "DB-M05 regenerates handoff on the fixture (HANDOFF_GENERATED)" ($oc -eq "HANDOFF_GENERATED") ("got " + $oc)
    Assert-True "DB-M05 consistency gate PASS" $cons "DB05_CONSISTENCY_GATE not PASS"

    $hd = Join-Path $f["tasksDir"] "CHATGPT_HANDOFF.md"
    Assert-True "handoff written to fixture tasks dir" (Test-Path $hd) ("missing " + $hd)

    if ($oc -eq "HANDOFF_GENERATED" -and (Test-Path $hd)) {
        $h = Get-Content $hd -Raw
        # new wording (one block per dirty reserved repository baseline)
        Assert-True "handoff carries PRE-EXISTING CHANGE ownership wording" ($h -match 'PRE-EXISTING CHANGE ownership and minimal in-scope edits') "ownership paragraph missing"
        Assert-True "handoff allows MINIMAL current-task edit inside reserved scope" ($h -match 'MINIMAL current-task edit') "minimal-edit rule missing"
        Assert-True "handoff names the STOP result PREEXISTING_FILE_BASELINE_INSUFFICIENT" ($h -match 'PREEXISTING_FILE_BASELINE_INSUFFICIENT') "insufficient-baseline stop missing"
        Assert-True "handoff forbids reverting/cleaning/claiming pre-existing content" ($h -match 'must not be reverted, cleaned, claimed or committed') "ownership-protection wording missing"
        Assert-True "OLD blanket phrase removed (must not touch or commit them)" (-not ($h -match 'must not touch or commit')) "old over-broad rule still present"
        # both reserved repository baselines still rendered
        $allPresent = $true
        foreach ($_b in $liveRb) {
            $_n = [string]$_b.name; $_h = [string]$_b.headCommit
            if (-not ($h -match [regex]::Escape($_n)) -or -not ($h -match [regex]::Escape($_h))) { $allPresent = $false }
        }
        Assert-True "both reserved repository baselines still rendered (names + HEADs)" $allPresent ("repos: " + (@($liveRb | ForEach-Object { $_.name }) -join ", "))
        Assert-True "workbook-owner baseline marked PRIMARY" ($h -match 'PRIMARY') "no PRIMARY marker in handoff"
    }

    # the fixture run must not have touched the live workbook or live state
    Assert-True "live workbook byte-identical after regeneration" ([System.Linq.Enumerable]::SequenceEqual([byte[]]$liveWbBytes, [byte[]]([IO.File]::ReadAllBytes($script:RealWorkbook)))) "live workbook changed"
    Assert-True "live current-task byte-identical after regeneration" ([System.Linq.Enumerable]::SequenceEqual([byte[]]$liveCtBytes, [byte[]]([IO.File]::ReadAllBytes((Join-Path $script:Root "state\current-task.json"))))) "live current-task changed"
    $res5 = Read-Json (Join-Path $f["stateDir"] "reservation.json")
    Assert-True "DB-M05 changed no baseline evidence (repositoryBaselines still two)" (@($res5.repositoryBaselines).Count -eq 2) ("count " + @($res5.repositoryBaselines).Count)
}

Write-Output ""
$failCount = $script:Fails.Count
Write-Output ("DBM05WORDING_PASS: " + (@($script:Results | Where-Object { $_.Pass }).Count) + " assertions")
Write-Output ("DBM05WORDING_FAIL: " + $failCount + ($(if ($script:Skips.Count) { ("; skipped: " + ($script:Skips -join ", ")) } else { "" })))
if ($failCount -gt 0) { foreach ($fl in $script:Fails) { Write-Output ("  - " + $fl) } }
Write-Output ("DBM05WORDING_RESULT: " + $(if ($failCount -eq 0) { "PASS" } else { "FAIL" }))
if ($failCount -gt 0) { exit 1 }
exit 0
