# Get-CurrentLifecycleState.ps1 - DB-M12.2 reusable lifecycle command for
# GET_CURRENT_LIFECYCLE_STATE.
#
# READ-ONLY. Emits the full current lifecycle state (task identity, mode, status,
# next allowed action, git gate position, M10 eligibility, milestone evidence) to
# stdout and records state\current-lifecycle-state.json. No lifecycle transition.
#
# Backend contract: ALWAYS exits 0; outcomes ONLY via stdout markers (DB14_*).
# State/tasks dirs redirect with DB14_STATE_DIR / DB14_TASKS_DIR.
#
# ASCII-only source (PS 5.1 + BOM-safe).
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Set-DevBridgeStateEntry.ps1")

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:StateDir = Join-Path $script:Root "state"
$script:TasksDir = Join-Path $script:Root "tasks"
$script:CfgPath = Join-Path $script:Root "config\devbridge.json"
if ($env:DB14_STATE_DIR) { $script:StateDir = $env:DB14_STATE_DIR }
if ($env:DB14_TASKS_DIR) { $script:TasksDir = $env:DB14_TASKS_DIR }
$script:NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

function Out-Markers([string]$token, [bool]$pass, [string[]]$evidence) {
    Write-Output ("DB14_OUTCOME: " + $token)
    Write-Output ("DB14_RESULT_PASS: " + $(if ($pass) { "True" } else { "False" }))
    Write-Output ("DB14_RESULT_CODE: " + $token)
    Write-Output "DB14_WORKBOOK_MODIFIED: False"
    Write-Output "DB14_NEXUS_SOURCE_MODIFIED: False"
    Write-Output "DB14_GIT_MODIFIED: False"
    Write-Output "DB14_REQUIRES_HUMAN_ACTION: False"
    Write-Output "DB14_HUMAN_ACTION_TYPE:"
    foreach ($e in $evidence) { Write-Output ("DB14_EVIDENCE: " + $e) }
    exit 0
}

$ct = Read-DevBridgeJson (Join-Path $script:StateDir "current-task.json")
$verif = Read-DevBridgeJson (Join-Path $script:StateDir "verification.json")
$claude = Read-DevBridgeJson (Join-Path $script:StateDir "claude-review.json")
$completion = Read-DevBridgeJson (Join-Path $script:StateDir "completion.json")
$gitObs = Read-DevBridgeJson (Join-Path $script:StateDir "git-gate-state.json")
$fp = Read-DevBridgeJson (Join-Path $script:StateDir "roadmap-fingerprint.json")

$nodeId = ""; $changeId = ""; $taskName = ""; $status = ""; $nextAction = ""; $gitLifecycle = ""
if ($null -ne $ct) {
    $nodeId = [string](Get-DevBridgeField $ct "nodeId"); if (-not $nodeId) { $nodeId = [string](Get-DevBridgeField $ct "taskId") }
    $changeId = [string](Get-DevBridgeField $ct "changeId")
    $taskName = [string](Get-DevBridgeField $ct "name")
    $status = [string](Get-DevBridgeField $ct "status")
    $nextAction = [string](Get-DevBridgeField $ct "nextAllowedAction")
    $gitLifecycle = [string](Get-DevBridgeField $ct "gitLifecycleState")
}
$mode = "TRIAL"
if ($null -ne $ct) { $mode = Get-DevBridgeMode $ct $script:CfgPath }
$trial = ($mode -eq "TRIAL")
$mergeConfirmed = ($gitLifecycle -in @("MERGED", "READY_FOR_GOVERNED_COMPLETION"))

# M10 eligibility summary (observation only)
$m10 = [ordered]@{
    mode                   = $mode
    trialCycleSafeStop     = $(if ($null -ne $ct) { ($status -eq "CLAUDE_REVIEW_PASSED_TRIAL" -and $nextAction -eq "TRIAL_CYCLE_SAFE_STOP") } else { $false })
    verificationPassed     = ([string](Get-DevBridgeField $verif "primaryResult")).StartsWith("VERIFICATION_PASSED")
    claudePassed           = ([string](Get-DevBridgeField $claude "decision")).StartsWith("PASS")
    mergeConfirmed         = $mergeConfirmed
    gitLifecycleState      = $gitLifecycle
    prStateObserved        = $(if ($null -ne $gitObs) { [string](Get-DevBridgeField $gitObs "prState") } else { "UNKNOWN" })
}

$snapshot = [ordered]@{
    generatedAtUtc = $script:NowUtc
    task = [ordered]@{ nodeId = $nodeId; changeId = $changeId; name = $taskName }
    mode = $mode
    trialMode = $trial
    status = $status
    nextAllowedAction = $nextAction
    m10Eligibility = $m10
    evidence = [ordered]@{
        verification  = $(if ($null -ne $verif) { [string](Get-DevBridgeField $verif "primaryResult") } else { "ABSENT" })
        claudeReview  = $(if ($null -ne $claude) { [string](Get-DevBridgeField $claude "decision") } else { "ABSENT" })
        completion    = $(if ($null -ne $completion) { "PRESENT" } else { "ABSENT" })
        fingerprint   = $(if ($null -ne $fp -and (Get-DevBridgeField $fp "before")) { "PRESENT" } else { "ABSENT" })
    }
    snapshotPath = "state/current-lifecycle-state.json"
}
Write-DevBridgeJson (Join-Path $script:StateDir "current-lifecycle-state.json") $snapshot

Write-Output "DB14 LIFECYCLE SNAPSHOT"
Write-Output ("  nodeId=" + $nodeId + " changeId=" + $changeId)
Write-Output ("  status=" + $status + " nextAllowedAction=" + $nextAction + " mode=" + $mode)
Write-Output ("  gitLifecycleState=" + $gitLifecycle + " mergeConfirmed=" + $mergeConfirmed)
Write-Output "  snapshot written to state/current-lifecycle-state.json"
Out-Markers "LIFECYCLE_STATE_SNAPSHOT" $true @("state/current-lifecycle-state.json")
