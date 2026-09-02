# New-CorrectionContext.ps1 - DB-M09 governed correction context (DB-M12.2 reusable
# lifecycle command for CREATE_CORRECTION_CONTEXT).
#
# Assembles tasks\FIX_CONTEXT.md for the CURRENT task from the Claude FIX decision
# (state\claude-review.json). The existing task evidence is preserved and the scope
# is never widened silently: the context records the exact fix findings and the
# fix-task rule (CORRECT_CURRENT_ATTEMPT vs NEW_FIX_TASK_REQUIRED) so the next
# attempt stays within the existing task. Idempotent: a FIX_CONTEXT.md already
# stamped with this changeId is REUSED, never duplicated. The lifecycle status stays
# DB_M09_FIX_REQUIRED.
#
# Backend contract: ALWAYS exits 0; outcomes ONLY via stdout markers (DB09_*).
# State/tasks dirs redirect with DB09_STATE_DIR / DB09_TASKS_DIR.
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
if ($env:DB09_STATE_DIR) { $script:StateDir = $env:DB09_STATE_DIR }
if ($env:DB09_TASKS_DIR) { $script:TasksDir = $env:DB09_TASKS_DIR }
$script:CurrentTaskPath = Join-Path $script:StateDir "current-task.json"
$script:ContextPath = Join-Path $script:TasksDir "FIX_CONTEXT.md"
$script:NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

function Out-Markers([string]$token, [bool]$pass, [string[]]$evidence) {
    Write-Output ("DB09_OUTCOME: " + $token)
    Write-Output ("DB09_RESULT_PASS: " + $(if ($pass) { "True" } else { "False" }))
    Write-Output ("DB09_RESULT_CODE: " + $token)
    Write-Output "DB09_WORKBOOK_MODIFIED: False"
    Write-Output "DB09_NEXUS_SOURCE_MODIFIED: False"
    Write-Output "DB09_GIT_MODIFIED: False"
    Write-Output "DB09_REQUIRES_HUMAN_ACTION: False"
    Write-Output "DB09_HUMAN_ACTION_TYPE:"
    foreach ($e in $evidence) { Write-Output ("DB09_EVIDENCE: " + $e) }
    exit 0
}

$ct = Read-DevBridgeJson $script:CurrentTaskPath
if ($null -eq $ct) { Out-Markers "STOP_NO_CURRENT_TASK" $false @("No current-task.json; run DB-M03 preflight first.") }

$status = [string](Get-DevBridgeField $ct "status")
if ($status -ne "DB_M09_FIX_REQUIRED") {
    Out-Markers "STOP_INVALID_LIFECYCLE_STATE" $false @("A correction context can only be created from DB_M09_FIX_REQUIRED (current: '$status').")
}

$nodeId = [string](Get-DevBridgeField $ct "nodeId")
$changeId = [string](Get-DevBridgeField $ct "changeId")
$taskName = [string](Get-DevBridgeField $ct "name")
if (-not $nodeId) { $nodeId = [string](Get-DevBridgeField $ct "taskId") }

$claude = Read-DevBridgeJson (Join-Path $script:StateDir "claude-review.json")
$decision = [string](Get-DevBridgeField $claude "decision")
if ($decision -ne "FIX") {
    Out-Markers "STOP_NO_FIX_DECISION" $false @("Claude decision is '$decision'; a FIX decision is required to build a correction context.")
}

# Idempotency: an existing context already stamped for this exact change is REUSED.
if ((Test-Path $script:ContextPath)) {
    $existing = [System.IO.File]::ReadAllText($script:ContextPath)
    if ($existing.Contains($changeId) -and $existing.Contains($nodeId)) {
        Out-Markers "REUSED" $true @("tasks/FIX_CONTEXT.md")
    }
}

$reviewText = [string](Get-DevBridgeField $claude "reviewText")
if (-not $reviewText) { $reviewText = "(no review text captured in claude-review.json)" }

$mode = Get-DevBridgeMode $ct $script:CfgPath
if ($env:DB_COMMAND_INPUT_MODE) { $mode = $env:DB_COMMAND_INPUT_MODE }
$trial = ($mode -eq "TRIAL")

$context = @"
# Correction Context - $changeId

Node: $nodeId
Task: $taskName
Mode: $mode
Decision: FIX (recorded via DB-M08)
Generated (utc): $script:NowUtc

## Fix findings (verbatim review text)
$reviewText

## Fix-task rule
- A defect in THIS attempt is corrected as CORRECT_CURRENT_ATTEMPT: the fix stays
  within the existing task scope; no new task is created.
- A defect found AFTER completion requires NEW_FIX_TASK_REQUIRED under the existing
  structure.
- A defect that cannot be represented under the existing structure is
  HUMAN_GOVERNANCE_REQUIRED.

## Scope note
The scope of the correction is the delta of changeId $changeId on nodeId $nodeId.
Scope is never widened silently: any change to the recorded scope requires an
explicit operator decision before work proceeds.

## Preserved evidence
state/current-task.json, state/claude-review.json, tasks/CLAUDE_REVIEW_RESULT.md,
state/verification.json (unchanged by this context assembly).
"@

# ---- Dependency context (DB-M18.1, additive; never alters markers/exit codes) ----
$script:Db181Block = ''
$db181Lib = Join-Path $script:Root 'scripts\ai-routing\DependencyLineage.ps1'
$db181Evidence = Join-Path $script:Root 'logs\tasks'
if ((Test-Path -LiteralPath $db181Lib) -and (Test-Path -LiteralPath $db181Evidence)) {
    try {
        . $db181Lib
        $db181Bundle = Get-DbM181TaskDependencyContext -Task $ct -TaskCatalog $null -EvidenceRoot $db181Evidence -RepositoryRoot $null -NowUtc $script:NowUtc
        $script:Db181Block = Get-DbM181CorrectionDependencyContext -Task $ct -Context $db181Bundle.Context
    } catch { $script:Db181Block = '' }
}
if ($script:Db181Block) { $context = $context + "`r`n`r`n" + $script:Db181Block }

if (-not (Test-Path $script:TasksDir)) { New-Item -ItemType Directory -Force -Path $script:TasksDir | Out-Null }
[System.IO.File]::WriteAllText($script:ContextPath, $context, (New-Object System.Text.UTF8Encoding($false)))

$db9 = [ordered]@{
    result        = "FIX_CONTEXT_CREATED"
    nodeId        = $nodeId
    changeId      = $changeId
    mode          = $mode
    trialMode     = $trial
    fixTaskRule   = "CORRECT_CURRENT_ATTEMPT (in-attempt); NEW_FIX_TASK_REQUIRED (post-completion); HUMAN_GOVERNANCE_REQUIRED (unrepresentable)"
    generatedAtUtc = $script:NowUtc
    evidence      = @("tasks/FIX_CONTEXT.md")
}
Set-DevBridgeStateEntry $script:CurrentTaskPath @{ dbM09 = $db9 }

Out-Markers "FIX_CONTEXT_CREATED" $true @("tasks/FIX_CONTEXT.md")
