# New-PeriodicClaudeWorkbookReview.ps1
# DevBridge DB-GH01 DB-M11 advisory layer (Role B) -- READ-ONLY. Periodic,
# advisory Claude workbook review recommendation. It is NEVER a blocking verdict
# and never auto-invokes Claude; it only RECOMMENDS. Deterministic validation
# (the probes) and the advisory review are separate concerns: the deterministic
# pass never depends on Claude, and the advisory review never blocks
# deterministic work.
#
# Emits state\db-m11-review-recommendation.json consumed by the engine as
# M11Recommendation (deterministicValidationPassed / claudeWorkbookReviewRecommended
# / reason) -> token CLAUDE_WORKBOOK_REVIEW_RECOMMENDED.
#
# Backend contract: ALWAYS exits 0; outcomes communicated ONLY via stdout markers.
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:StateDir = Join-Path $script:Root "state"
$script:TasksDir = Join-Path $script:Root "tasks"
$script:OutPath = Join-Path $script:StateDir "db-m11-review-recommendation.json"
$script:NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$script:ReadOnlyContract = "Role B periodic review is READ-ONLY: it must not modify NEXUS_DEVELOPMENT_CONTROL.xlsx and must not redesign the roadmap."

# Deterministic validation pass from the DB-M11 consistency evidence.
$script:DeterministicPass = $false
$script:ConsistencyResult = ""
$consistencyPath = Join-Path $script:StateDir "workbook-consistency.json"
if (Test-Path $consistencyPath) {
    try {
        $c = Get-Content $consistencyPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:ConsistencyResult = [string]$c.controlValidationResult
        if ($script:ConsistencyResult.StartsWith("PASS", [System.StringComparison]::OrdinalIgnoreCase)) { $script:DeterministicPass = $true }
    } catch { }
}
if (-not $script:DeterministicPass) {
    $mdPath = Join-Path $script:TasksDir "WORKBOOK_CONSISTENCY_REPORT.md"
    if (Test-Path $mdPath) {
        $md = [System.IO.File]::ReadAllText($mdPath)
        if ($md -match "DB-M11 RESULT|FULL WORKBOOK CONSISTENCY" -and $md -match "PASS") { $script:DeterministicPass = $true }
    }
}

# Advisory triggers (configurable). Defaults: recommend after a milestone
# completion or when a suspicious non-structural M11 condition appears.
$script:Recommend = $false
$script:Reason = ""
if (-not $script:DeterministicPass) {
    $script:Reason = "Deterministic DB-M11 consistency validation did not report a full PASS; a Claude workbook review is recommended before governed completion."
    $script:Recommend = $true
} else {
    $script:Reason = "Deterministic DB-M11 validation passed. No Claude workbook review is currently recommended by the advisory triggers."
}

$script:Out = [ordered]@{
    deterministicValidationPassed = $script:DeterministicPass
    claudeWorkbookReviewRecommended = $script:Recommend
    reason = $script:Reason
    readOnlyContract = $script:ReadOnlyContract
    consistencyResult = $script:ConsistencyResult
    generatedAtUtc = $script:NowUtc
}
[System.IO.File]::WriteAllText($script:OutPath, ($script:Out | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

Write-Output ("DBGH01_M11_DETERMINISTIC_PASS: " + $script:DeterministicPass)
Write-Output ("DBGH01_M11_RECOMMENDED: " + $script:Recommend)
Write-Output ("DBGH01_M11_TOKEN: " + $(if ($script:Recommend) { "CLAUDE_WORKBOOK_REVIEW_RECOMMENDED" } else { "NO_ADVISORY_REVIEW_RECOMMENDED" }))
Write-Output ("DBGH01_M11_REASON: " + $script:Reason)
Write-Output ("DBGH01_M11_STATE_FILE: " + $script:OutPath)
Write-Output "DBGH01_OUTCOME: M11_ADVISORY_RECOMMENDATION_RECORDED"
exit 0
