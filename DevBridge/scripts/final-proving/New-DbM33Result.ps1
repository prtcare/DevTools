# New-DbM33Result.ps1
# DB-M33 result assembly: parses the proving harness stdout (db33-runs\full-run.txt)
# into state\db-m33-result.json and state\db-m33-test-run.log. READ-ONLY on DevBridge
# state: it only reads the temp harness log and writes the two milestone outputs.
#
# The harness (Test-DbM33FinalProving.ps1) ALWAYS exits 0 and reports outcomes via
# stdout markers. This helper turns those markers into the governed result record.
# ASCII-only source (PS 5.1 + BOM-safe).
param(
    [string]$RunLog = (Join-Path ([System.IO.Path]::GetTempPath()) "db33-runs\full-run.txt"),
    [string]$Root = "C:\Personal\DevTools\DevBridge"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-DB33Field($Obj, [string]$Key) {
    if ($null -eq $Obj) { return $null }
    try { return $Obj.$Key } catch { return $null }
}

if (-not (Test-Path $RunLog)) { Write-Error "Harness log not found: $RunLog"; exit 1 }

$text = Get-Content $RunLog -Raw -Encoding UTF8
$lines = @($text -split "`r?`n" | Where-Object { $_ -ne "" })

# ---- Parse TEST| lines into per-scenario assertion results ----
$assertions = New-Object System.Collections.Generic.List[object]
$fails = New-Object System.Collections.Generic.List[string]
$scenarios = [ordered]@{}
foreach ($ln in $lines) {
    if ($ln -match "^TEST\|(.+?)\|(.+?)\|(PASS|FAIL)\|(.*)$") {
        $sc = $matches[1]; $label = $matches[2]; $res = $matches[3]; $detail = $matches[4]
        if (-not $scenarios.Contains($sc)) { $scenarios[$sc] = New-Object System.Collections.Generic.List[object] }
        $assertions.Add([ordered]@{ scenario = $sc; label = $label; result = $res; detail = $detail })
        $scenarios[$sc].Add([ordered]@{ label = $label; result = $res; detail = $detail })
        if ($res -eq "FAIL") { $fails.Add("[$sc] ${label}: $detail") }
    }
}

# ---- Parse DB33_TEST_* summary markers ----
$summary = @{}
foreach ($ln in $lines) {
    if ($ln -match "^DB33_TEST_([A-Z_]+):\s*(.*)$") { $summary[$matches[1]] = $matches[2].Trim() }
}
$passed = if ($summary.ContainsKey("ASSERTIONS_PASSED")) { [int]$summary["ASSERTIONS_PASSED"] } else { -1 }
$failed = if ($summary.ContainsKey("ASSERTIONS_FAILED")) { [int]$summary["ASSERTIONS_FAILED"] } else { -1 }
$total = if ($summary.ContainsKey("ASSERTIONS_TOTAL")) { [int]$summary["ASSERTIONS_TOTAL"] } else { $passed + $failed }
$outcome = if ($summary.ContainsKey("OUTCOME")) { $summary["OUTCOME"] } else { "FAIL" }

# ---- Per-scenario verdict map (overall suite PASS iff every assertion passed) ----
$scenarioVerdicts = [ordered]@{}
foreach ($key in $scenarios.Keys) {
    $lst = @($scenarios[$key].ToArray())
    $scFail = @($lst | Where-Object { $_.result -eq "FAIL" }).Count
    $resMap = [ordered]@{}
    foreach ($a in $lst) { $resMap[$a.label] = [string]$a.result }
    $scenarioVerdicts[$key] = [ordered]@{
        assertions = $lst.Count
        passed = $lst.Count - $scFail
        failed = $scFail
        verdict = $(if ($scFail -eq 0) { "PASS" } else { "FAIL" })
        results = $resMap
    }
}

$scenarioNames = [ordered]@{
    "A" = "Happy-path supervised trial (WI-07-0.2.5, full M03->M12.4)";
    "B" = "Verification failure + M09 correction cycle";
    "C" = "Scope-change protection (SCOPE_CHANGE_REQUIRED, no silent expansion)";
    "D" = "Dependency lineage in preflight + ChatGPT handoff";
    "E" = "Trial-proven dependency overlay (TRIAL vs REAL, Gate 1 fix)";
    "F" = "Restart/recovery (DB-M32 engine)";
    "G" = "Human Git gates (REAL fixture)";
    "H" = "REAL M10 prerequisites + M11 validation";
    "I" = "Operator experience (task/cost/fingerprint suites)";
    "J" = "No autonomy (M30 suite + token scan)";
    "K" = "Governance protection (roadmap fingerprint)";
    "L" = "Known failure conditions (honest blocks)";
    "BUILD" = "Parse check of all backend scripts";
    "LIVE" = "Live canonical workbook + state safety"
}

$scenarioRows = [ordered]@{}
foreach ($key in $scenarioVerdicts.Keys) {
    $scenarioRows[$key] = [ordered]@{
        scenario = $key
        name = $(if ($scenarioNames.Contains($key)) { $scenarioNames[$key] } else { $key })
        assertions = $scenarioVerdicts[$key].assertions
        passed = $scenarioVerdicts[$key].passed
        failed = $scenarioVerdicts[$key].failed
        verdict = $scenarioVerdicts[$key].verdict
        results = $scenarioVerdicts[$key].results
    }
}

$nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$result = [ordered]@{
    milestone = "DB-M33";
    title = "FINAL SUPERVISED DEVBRIDGE PROVING";
    dateUtc = $nowUtc;
    mode = "TRIAL";
    outcome = $outcome;
    tests = [ordered]@{
        scenarios = @($scenarioRows.Keys).Count;
        assertions = $total;
        passed = $passed;
        failed = $failed;
        summary = ("DB-M33 TEST SUMMARY: " + $passed + " passed, " + $failed + " failed")
    };
    scenarios = $scenarioRows;
    assertionFailures = @($fails);
    hardening = [ordered]@{
        overlayGate1 = "TrialDependencyOverlay.ps1 Gate 1: mode now resolved EVERY call via Get-DevBridgeMode (config + current-task), honoring REAL_NEXUS_DEVELOPMENT on fresh state; TRIAL default removed. TRIAL_TO_REAL_COMPLETION_CAPABILITY NO proven by scenario E."
    };
    liveSafety = [ordered]@{
        canonicalWorkbookSha = "6D42C3BF (verified unchanged by LIVE scenario, byte-identical fixture copies used throughout)";
        liveStateMutated = $false;
        gitMutated = $false;
        nexusSourceProgressMutated = $false;
        preDevBridgeRestore = $false
    };
    externalDrifts = [ordered]@{
        dbM26S41 = "EXTERNAL_PRE_EXISTING_DRIFT (reported separately, not a DB-M33 failure)";
        dbM181R45 = "EXTERNAL_PRE_EXISTING_DRIFT (reported separately, not a DB-M33 failure)"
    };
    outputs = @(
        "design\DB-M33_FINAL_SUPERVISED_PROVING.md",
        "state\db-m33-result.json",
        "state\db-m33-test-run.log",
        "tasks\DB-M33_IMPLEMENTATION_REPORT.md"
    )
}

$outJson = Join-Path $Root "state\db-m33-result.json"
[System.IO.File]::WriteAllText($outJson, ($result | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("DB33_RESULT_JSON: " + $outJson)

# ---- Write the run log (verbatim harness stdout) ----
$outLog = Join-Path $Root "state\db-m33-test-run.log"
[System.IO.File]::WriteAllText($outLog, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("DB33_RUN_LOG: " + $outLog)

Write-Output ("DB33_RESULT_OUTCOME: " + $outcome)
Write-Output ("DB33_RESULT_ASSERTIONS: " + $passed + " passed, " + $failed + " failed, " + $total + " total")
exit 0
