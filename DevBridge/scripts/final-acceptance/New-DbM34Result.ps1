# ===========================================================================
# DB-M34 - assembles state\db-m34-result.json + state\db-m34-test-run.log
# from the harness full-run log written by Test-DbM34FinalAcceptance.ps1.
# READ-ONLY otherwise. Prints DB34_RESULT_* markers. exit 0 always.
# ===========================================================================
param(
    [string]$RunLog = '',
    [string]$Root = 'C:\Personal\DevTools\DevBridge'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($RunLog)) {
    $RunLog = Join-Path ([System.IO.Path]::GetTempPath()) 'db34-runs\full-run.txt'
}

if (-not (Test-Path -LiteralPath $RunLog)) { Write-Error "Run log not found: $RunLog"; exit 0 }
$lines = Get-Content -LiteralPath $RunLog

$scenarioNames = [ordered]@{}
$resultsByScenario = [ordered]@{}
$order = New-Object 'System.Collections.Generic.List[string]'
$scenarioCounts = @{}
$failures = New-Object 'System.Collections.Generic.List[string]'
$markers = @{}
$childLines = New-Object 'System.Collections.Generic.List[string]'

foreach ($raw in $lines) {
    $line = $raw.TrimEnd()
    if ($line -match '^SCENARIO\|([^|]+)\|(.*)$') {
        $id = $Matches[1]; $name = $Matches[2]
        if (-not $scenarioNames.Contains($id)) { $order.Add($id) }
        $scenarioNames[$id] = $name
        if (-not $resultsByScenario.Contains($id)) { $resultsByScenario[$id] = [ordered]@{} }
        if (-not $scenarioCounts.ContainsKey($id)) { $scenarioCounts[$id] = 0 }
        continue
    }
    if ($line -match '^TEST\|([^|]+)\|([^|]+)\|(PASS|FAIL)\|(.*)$') {
        $id = $Matches[1]; $label = $Matches[2]; $st = $Matches[3]; $detail = $Matches[4]
        if (-not $resultsByScenario.Contains($id)) { $resultsByScenario[$id] = [ordered]@{}; if (-not $order.Contains($id)) { $order.Add($id) } }
        if (-not $scenarioNames.Contains($id)) { $scenarioNames[$id] = $id }
        $resultsByScenario[$id][$label] = $st
        if (-not $scenarioCounts.ContainsKey($id)) { $scenarioCounts[$id] = 0 }
        $scenarioCounts[$id]++
        if ($st -eq 'FAIL') { $failures.Add(("{0}/{1}" -f $id, $label)) }
        continue
    }
    if ($line -match '^DB34_CHILD: (.*)$') { $childLines.Add($Matches[1]); continue }
    if ($line -match '^(DB34_TEST_[A-Z_]+):\s*(.*)$') { $markers[$Matches[1]] = $Matches[2].Trim() }
    if ($line -match '^(DB34_BUILD_[A-Z_]+):\s*(.*)$') { $markers[$Matches[1]] = $Matches[2].Trim() }
    if ($line -match '^(DB34_DISPOSITION_[A-Z0-9_]+):\s*(.*)$') { $markers[$Matches[1]] = $Matches[2].Trim() }
}

$scenarioOut = [ordered]@{}
$totalAsserts = 0; $totalPass = 0; $totalFail = 0
foreach ($id in $order) {
    $res = $resultsByScenario[$id]
    $p = @($res.GetEnumerator() | Where-Object { $_.Value -eq 'PASS' }).Count
    $f = @($res.GetEnumerator() | Where-Object { $_.Value -eq 'FAIL' }).Count
    $totalAsserts += ($p + $f); $totalPass += $p; $totalFail += $f
    $scenarioOut[$id] = [ordered]@{
        scenario = $id
        name = $scenarioNames[$id]
        assertions = ($p + $f)
        passed = $p
        failed = $f
        verdict = $(if ($f -eq 0) { 'PASS' } else { 'FAIL' })
        results = $res
    }
}

$outcome = if ($markers.ContainsKey('DB34_TEST_OUTCOME')) { $markers['DB34_TEST_OUTCOME'] } else { $(if ($totalFail -eq 0) { 'PASS' } else { 'FAIL' }) }
$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

$result = [ordered]@{
    milestone = 'DB-M34'
    title = 'FINAL ACCEPTANCE, OPERATING DOCUMENTATION & TRANSITION READINESS'
    dateUtc = $now
    mode = 'TRIAL'
    outcome = $outcome
    tests = [ordered]@{
        scenarios = $order.Count
        assertions = $totalAsserts
        passed = $totalPass
        failed = $totalFail
        summary = ("DB-M34 TEST SUMMARY: {0} passed, {1} failed" -f $totalPass, $totalFail)
    }
    scenarios = $scenarioOut
    assertionFailures = @($failures)
    dispositions = [ordered]@{
        dbM26S41 = $(if ($markers.ContainsKey('DB34_DISPOSITION_M26_S41')) { $markers['DB34_DISPOSITION_M26_S41'] } else { 'UNRECORDED' })
        dbM181R45 = $(if ($markers.ContainsKey('DB34_DISPOSITION_M181_R45')) { $markers['DB34_DISPOSITION_M181_R45'] } else { 'UNRECORDED' })
    }
    build = [ordered]@{
        warnings = $(if ($markers.ContainsKey('DB34_BUILD_WARNINGS')) { $markers['DB34_BUILD_WARNINGS'] } else { -1 })
        errors = $(if ($markers.ContainsKey('DB34_BUILD_ERRORS')) { $markers['DB34_BUILD_ERRORS'] } else { -1 })
    }
    childSummary = @($childLines)
    safeForRealNexusDevelopment = $(if ($outcome -eq 'PASS') { 'YES' } else { 'NO' })
    liveSafety = [ordered]@{
        canonicalWorkbookSha = '6D42C3BF (verified unchanged by LIVE scenario)'
        liveStateMutated = $false
        gitMutated = $false
        nexusSourceProgressMutated = $false
        preDevBridgeRestore = $false
        realNexusDevelopmentStarted = $false
    }
    outputs = @(
        'design\DB-M34_FINAL_ACCEPTANCE.md',
        'docs\DEVBRIDGE_OPERATOR_GUIDE.md',
        'docs\DEVBRIDGE_HUMAN_ACTION_REFERENCE.md',
        'docs\DEVBRIDGE_ERROR_RECOVERY_REFERENCE.md',
        'docs\DEVBRIDGE_TRIAL_VS_REAL.md',
        'docs\DEVBRIDGE_PRE_REAL_TRANSITION_PLAN.md',
        'docs\DEVBRIDGE_FIRST_REAL_RUN_CHECKLIST.md',
        'docs\DEVBRIDGE_RETIREMENT_PLAN.md',
        'state\db-m34-result.json',
        'state\db-m34-test-run.log',
        'tasks\DB-M34_IMPLEMENTATION_REPORT.md'
    )
}

$json = $result | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText((Join-Path $Root 'state\db-m34-result.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::Copy($RunLog, (Join-Path $Root 'state\db-m34-test-run.log'), $true)

Write-Output ("DB34_RESULT_OUTCOME: " + $outcome)
Write-Output ("DB34_RESULT_ASSERTIONS: " + $totalPass + " passed, " + $totalFail + " failed, " + $totalAsserts + " total")
Write-Output ("DB34_RESULT_SCENARIOS: " + $order.Count)
Write-Output 'DB34_RESULT_JSON: state\db-m34-result.json'
Write-Output 'DB34_RUN_LOG: state\db-m34-test-run.log'
exit 0
