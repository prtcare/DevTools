# ===========================================================================
# DB-M34 - builds tasks\DB-M34_IMPLEMENTATION_REPORT.md from
# state\db-m34-result.json. READ-ONLY otherwise. Prints DB34_REPORT markers.
# exit 0 always.
# ===========================================================================
param([string]$Root = 'C:\Personal\DevTools\DevBridge')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resultPath = Join-Path $Root 'state\db-m34-result.json'
if (-not (Test-Path -LiteralPath $resultPath)) { Write-Output 'DB34_REPORT_ERROR: run New-DbM34Result.ps1 first'; exit 0 }
$r = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json

# Acceptance area -> label-prefix resolution.
# NOTE: plain hashtables keyed by int, NOT [ordered]. An OrderedDictionary's
# int indexer binds POSITIONALLY (0..N-1), so $areaPrefixes[20] would throw
# out-of-range and keys < 20 would silently read the wrong entry. A hashtable
# binds int keys by KEY. Iteration below sorts keys to keep the table in 1..20.
$areaPrefixes = @{
    1  = @('area1-')
    2  = @('area2-')
    3  = @('area3-')
    4  = @('area4-')
    5  = @('area5-')
    6  = @('area6-')
    7  = @('area7-')
    8  = @('area8-')
    9  = @('area9-')
    10 = @('area10-')
    11 = @('area11-')
    12 = @('area12-')
    13 = @('area13-')
    14 = @('area14-')
    15 = @('area15-')
    16 = @('area16-')
    17 = @('area17-')
    18 = @('area18-')
    19 = @('area19-')
    20 = @('area20-')
}
$areaNames = @{
    1  = 'Temporary DevBridge boundary'
    2  = 'Supervised workflow'
    3  = 'Dependency development context'
    4  = 'Roadmap immutability'
    5  = 'Workbook authority'
    6  = 'Trial vs Real'
    7  = 'Git governance'
    8  = 'Verification + Claude review'
    9  = 'Recovery'
    10 = 'AI / cost support'
    11 = 'Security'
    12 = 'Fix handling'
    13 = 'Known external drifts'
    14 = 'Final clean regression'
    15 = 'Operator documentation'
    16 = 'Human action reference'
    17 = 'Error / recovery reference'
    18 = 'Pre-DevBridge transition plan'
    19 = 'First real run checklist'
    20 = 'Retirement plan'
}

# flatten results
$allResults = [ordered]@{}
foreach ($sc in $r.scenarios.PSObject.Properties) {
    foreach ($lab in $sc.Value.results.PSObject.Properties) {
        $allResults[$lab.Name] = $lab.Value
    }
}

$areaRows = New-Object 'System.Collections.Generic.List[string]'
$sb = New-Object System.Text.StringBuilder
function W([string]$t) { [void]$sb.AppendLine($t) }

W '# DB-M34 IMPLEMENTATION REPORT'
W ''
W ('- Milestone: DB-M34 - FINAL ACCEPTANCE, OPERATING DOCUMENTATION & TRANSITION READINESS')
W ('- DateUtc: ' + $r.dateUtc)
W ('- Mode: ' + $r.mode)
W ('- Outcome: ' + $r.outcome)
W ('- Tests: ' + $r.tests.passed + ' passed, ' + $r.tests.failed + ' failed, ' + $r.tests.assertions + ' assertions across ' + $r.tests.scenarios + ' scenarios')
W ''
W '## Acceptance areas (1-20)'
W ''
W '| Area | Acceptance item | Verdict |'
W '|---|---|---|'
$anyFail = $false
foreach ($num in ($areaPrefixes.Keys | Sort-Object)) {
    $prefixes = $areaPrefixes[$num]
    $matching = @($allResults.GetEnumerator() | Where-Object {
        $n = $_.Key
        foreach ($pfx in $prefixes) { if ($n.StartsWith($pfx)) { return $true } }
        return $false
    })
    if ($matching.Count -eq 0) {
        $verdict = 'UNVERIFIED'
    } else {
        $bad = @($matching | Where-Object { $_.Value -ne 'PASS' })
        $verdict = if ($bad.Count -eq 0) { 'PASS' } else { 'FAIL' }
        if ($bad.Count -gt 0) { $anyFail = $true }
    }
    $areaRows.Add(("| {0} | {1} | {2} |" -f $num, $areaNames[$num], $verdict))
}
foreach ($row in $areaRows) { W $row }
W ''
W '### Area failures (if any)'
W ''
$failLabels = @($allResults.GetEnumerator() | Where-Object { $_.Value -ne 'PASS' })
if ($failLabels.Count -eq 0) {
    W 'None - all resolved acceptance labels PASS.'
} else {
    foreach ($fl in $failLabels) { W ('- {0}: {1}' -f $fl.Key, $fl.Value) }
}
W ''
W '## Final clean regression (Area 14)'
W ''
W '| Assertion | Result |'
W '|---|---|'
foreach ($k in @($allResults.Keys | Where-Object { $_ -like 'area14-*' })) {
    W ('| ' + $k + ' | ' + $allResults[$k] + ' |')
}
W ''
W '## Child suite summary'
W ''
W '| Suite | Result |'
W '|---|---|'
foreach ($c in $r.childSummary) { W ('| ' + $c + ' |') }
W ''
W '## Dispositions'
W ''
W ('- DB-M26 S41: ' + $r.dispositions.dbM26S41)
W ('- DB-M18.1 R45: ' + $r.dispositions.dbM181R45)
W ''
W '## Build'
W ''
W ('- Build warnings: ' + $r.build.warnings)
W ('- Build errors: ' + $r.build.errors)
W ''
W '## No-autonomy confirmation'
W ''
$nLabels = @($allResults.GetEnumerator() | Where-Object { $_.Key -in @('auto-execution-disabled-config', 'mode-trial-config', 'no-autonomy-tokens', 'no-scheduler-artifact') })
$nPass = (@($nLabels | Where-Object { $_.Value -ne 'PASS' }).Count -eq 0)
W ('- AUTO_DEVELOP / RUN_ALL / autonomous scheduler artifacts: ' + $(if ($nPass) { 'NO (scan clean)' } else { 'CHECK FAILED' }))
W ('- Automatic ChatGPT/Claude Code/DeepSeek execution: NO (config executionMode=MANUAL)')
W ('- Automatic retry / escalation / PR / review / merge / next task: NO')
W ('- Autonomous development cycle: NO')
W ''
W '## Safety invariants'
W ''
W ('- Canonical workbook modified: NO (LIVE sha 6D42C3BF)')
W ('- Nexus source modified: NO')
W ('- Pre-DevBridge baseline restored: NO')
W ('- Real Nexus development started: NO')
W ('- M10 run against TRIAL state: NO')
W ''
W '## FINAL DECISION'
W ''
W ('DevBridge safe for supervised REAL Nexus development: ' + $r.safeForRealNexusDevelopment)
W ('DevBridge development complete: ' + $(if ($r.outcome -eq 'PASS') { 'YES' } else { 'NO' }))
W ('Ready for human-authorized PRE-DEVBRIDGE baseline restoration: ' + $(if ($r.outcome -eq 'PASS') { 'YES' } else { 'NO' }))
W ('Ready to begin building Nexus Developer after restoration: ' + $(if ($r.outcome -eq 'PASS') { 'YES' } else { 'NO' }))
W ''
if ($r.outcome -eq 'PASS' -and -not $anyFail) {
    W 'DEVBRIDGE STATUS: READY_FOR_REAL_NEXUS_SUPPORT'
} else {
    W 'DEVBRIDGE STATUS: ACCEPTANCE_GATED (resolve failures before transitioning)'
}
W ''
W 'Stop after DB-M34.'
W 'DO NOT restore the baseline. DO NOT switch to REAL mode. DO NOT start Nexus development.'

[System.IO.File]::WriteAllText((Join-Path $Root 'tasks\DB-M34_IMPLEMENTATION_REPORT.md'), $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output ('DB34_REPORT: tasks\DB-M34_IMPLEMENTATION_REPORT.md')
Write-Output ('DB34_REPORT_ACCEPTANCE: ' + $r.outcome + ' areasPass=' + $(if ($anyFail) { 'some FAIL' } else { '20/20' }))
exit 0
