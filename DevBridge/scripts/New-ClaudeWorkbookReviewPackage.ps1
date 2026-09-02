# New-ClaudeWorkbookReviewPackage.ps1 - DB-M11 periodic advisory (Role B), DB-M12.2
# reusable lifecycle command for CREATE_CLAUDE_WORKBOOK_REVIEW_PACKAGE.
#
# READ-ONLY. Computes whether a read-only Claude workbook review is RECOMMENDED
# (deterministic DB-M11 consistency evidence) and, when recommended, assembles
# tasks\CLAUDE_WORKBOOK_REVIEW_PACKET.md (advisory only -- never a blocking verdict,
# never auto-invokes Claude, never edits the workbook or the roadmap). Writes
# state\db-m11-review-recommendation.json (the engine's M11Recommendation evidence).
#
# Backend contract: ALWAYS exits 0; outcomes ONLY via stdout markers (DB12_*).
# Fixture override: DB12_RECOMMEND=1/0 forces the recommendation. State/tasks dirs
# redirect with DB12_STATE_DIR / DB12_TASKS_DIR.
#
# ASCII-only source (PS 5.1 + BOM-safe).
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Set-DevBridgeStateEntry.ps1")

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:StateDir = Join-Path $script:Root "state"
$script:TasksDir = Join-Path $script:Root "tasks"
if ($env:DB12_STATE_DIR) { $script:StateDir = $env:DB12_STATE_DIR }
if ($env:DB12_TASKS_DIR) { $script:TasksDir = $env:DB12_TASKS_DIR }
$script:NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$script:OutPath = Join-Path $script:StateDir "db-m11-review-recommendation.json"
$script:PacketPath = Join-Path $script:TasksDir "CLAUDE_WORKBOOK_REVIEW_PACKET.md"
$script:ReadOnlyContract = "Role B periodic review is READ-ONLY: it must not modify NEXUS_DEVELOPMENT_CONTROL.xlsx and must not redesign the roadmap."

function Out-Markers([string]$token, [bool]$pass, [string[]]$evidence) {
    Write-Output ("DB12_OUTCOME: " + $token)
    Write-Output ("DB12_RESULT_PASS: " + $(if ($pass) { "True" } else { "False" }))
    Write-Output ("DB12_RESULT_CODE: " + $token)
    Write-Output "DB12_WORKBOOK_MODIFIED: False"
    Write-Output "DB12_NEXUS_SOURCE_MODIFIED: False"
    Write-Output "DB12_GIT_MODIFIED: False"
    Write-Output "DB12_REQUIRES_HUMAN_ACTION: False"
    Write-Output "DB12_HUMAN_ACTION_TYPE:"
    foreach ($e in $evidence) { Write-Output ("DB12_EVIDENCE: " + $e) }
    exit 0
}

# Deterministic DB-M11 consistency pass (from the DB-M11 evidence).
$deterministicPass = $false
$consistencyResult = ""
$consistencyPath = Join-Path $script:StateDir "workbook-consistency.json"
if (Test-Path $consistencyPath) {
    $c = Read-DevBridgeJson $consistencyPath
    $consistencyResult = [string](Get-DevBridgeField $c "controlValidationResult")
    if ($consistencyResult.StartsWith("PASS", [System.StringComparison]::OrdinalIgnoreCase)) { $deterministicPass = $true }
}
if (-not $deterministicPass) {
    $mdPath = Join-Path $script:TasksDir "WORKBOOK_CONSISTENCY_REPORT.md"
    if (Test-Path $mdPath) {
        $md = [System.IO.File]::ReadAllText($mdPath)
        if ($md -match "DB-M11 RESULT|FULL WORKBOOK CONSISTENCY" -and $md -match "PASS") { $deterministicPass = $true }
    }
}

$recommend = $false
$reason = ""
if ($env:DB12_RECOMMEND -eq "1") {
    $recommend = $true
    $reason = "Fixture/operator override requested a read-only Claude workbook review."
} elseif ($env:DB12_RECOMMEND -eq "0") {
    $recommend = $false
    $reason = "Fixture/operator override suppressed the read-only Claude workbook review."
} elseif (-not $deterministicPass) {
    $reason = "Deterministic DB-M11 consistency validation did not report a full PASS; a Claude workbook review is recommended before governed completion."
    $recommend = $true
} else {
    $reason = "Deterministic DB-M11 validation passed. No Claude workbook review is currently recommended by the advisory triggers."
}

$out = [ordered]@{
    deterministicValidationPassed = $deterministicPass
    claudeWorkbookReviewRecommended = $recommend
    reason = $reason
    readOnlyContract = $script:ReadOnlyContract
    consistencyResult = $consistencyResult
    generatedAtUtc = $script:NowUtc
}
Write-DevBridgeJson $script:OutPath $out

if ($recommend) {
    $packet = @"
# Claude Workbook Review Packet (advisory, READ-ONLY)

Generated (utc): $script:NowUtc
Recommendation: read-only Claude workbook review is recommended.

$script:ReadOnlyContract

Review focus: the workbook consistency evidence (state/workbook-consistency.json,
tasks/WORKBOOK_CONSISTENCY_REPORT.md) did not report a full deterministic PASS.
The review is advisory and non-blocking. It must not modify the workbook and must
not redesign the roadmap.
"@
    [System.IO.File]::WriteAllText($script:PacketPath, $packet, (New-Object System.Text.UTF8Encoding($false)))
    Out-Markers "ADVISORY_REVIEW_PACKAGE_CREATED" $true @("state/db-m11-review-recommendation.json", "tasks/CLAUDE_WORKBOOK_REVIEW_PACKET.md")
}

Out-Markers "NO_ADVISORY_REVIEW_RECOMMENDED" $true @("state/db-m11-review-recommendation.json")
