# Set-ClaudeReviewResult.ps1 - DB-M08 governed Claude decision recording
# (DB-M12.2 reusable lifecycle command for RECORD_CLAUDE_RESULT).
#
# Records the CURRENT task's Claude review verdict verbatim and routes the cycle:
#   PASS + TRIAL                 -> CLAUDE_REVIEW_PASSED_TRIAL / TRIAL_CYCLE_SAFE_STOP
#   PASS + REAL_NEXUS_DEVELOPMENT-> CLAUDE_REVIEW_PASSED_REAL / AWAITING_HUMAN_PR
#   FIX                          -> DB_M09_FIX_REQUIRED / CORRECT_CURRENT_ATTEMPT
#   GOVERNANCE_ISSUE             -> GOVERNANCE_ISSUE / human review
#   HUMAN_DECISION_REQUIRED      -> HUMAN_DECISION_REQUIRED / human decision
#
# DB-M07 identity gate (hardened): the recorded result must belong to the CURRENT
# node/change and the CURRENT CLAUDE REVIEW MANIFEST (Test-CrmManifestCurrent) with
# a DB-M06 PASS for the same identity. A historical/stale review (e.g. a previous
# node/change or an old manifest) is rejected with DB08_OUTCOME:
# CLAUDE_RESULT_IDENTITY_MISMATCH and is NEVER recorded for the current cycle.
# The reviewed identity + manifest id are persisted in state\claude-review.json.
#
# The verbatim review text comes from DB08_REVIEW_TEXT (fixture/operator channel)
# or from the DB-M12.2 one-command input parameters
# (DB_COMMAND_INPUT_PARAMETERS = {"decision": "...", "reviewText": "..."}).
#
# DB-M08 DECISION PARSER HARDENING: the recorded decision is recognized ONLY
# from an explicit review-decision field in the review text ("Decision: X",
# "Review decision: X", "### Review decision: X", "**Decision:** X", where X is
# PASS | FIX | GOVERNANCE_ISSUE | HUMAN_DECISION_REQUIRED). The supplied
# decision is advisory/confirmatory only. A review text that names NO explicit
# decision is rejected (CLAUDE_RESULT_DECISION_NOT_PARSEABLE) and one that names
# CONFLICTING decisions is rejected (CLAUDE_RESULT_DECISION_AMBIGUOUS) - PASS is
# NEVER silently defaulted and the lifecycle is NOT advanced on either rejection.
#
# Writes tasks\CLAUDE_REVIEW_RESULT.md + state\claude-review.json and transitions
# current-task.json. Never modifies the workbook.
#
# Backend contract: ALWAYS exits 0; outcomes ONLY via stdout markers (DB08_*).
# State/tasks dirs redirect with DB08_STATE_DIR / DB08_TASKS_DIR.
#
# ASCII-only source (PS 5.1 + BOM-safe).
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Set-DevBridgeStateEntry.ps1")
. (Join-Path $PSScriptRoot "ClaudeReviewManifestSupport.ps1")

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:StateDir = Join-Path $script:Root "state"
$script:TasksDir = Join-Path $script:Root "tasks"
$script:CfgPath = Join-Path $script:Root "config\devbridge.json"
if ($env:DB08_STATE_DIR) { $script:StateDir = $env:DB08_STATE_DIR }
if ($env:DB08_TASKS_DIR) { $script:TasksDir = $env:DB08_TASKS_DIR }
$script:CurrentTaskPath = Join-Path $script:StateDir "current-task.json"
$script:ResultMdPath = Join-Path $script:TasksDir "CLAUDE_REVIEW_RESULT.md"
$script:JsonPath = Join-Path $script:StateDir "claude-review.json"
$script:NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

function Out-Markers([string]$token, [bool]$pass, [string[]]$evidence, [bool]$human, [string]$humanType) {
    Write-Output ("DB08_OUTCOME: " + $token)
    Write-Output ("DB08_RESULT_PASS: " + $(if ($pass) { "True" } else { "False" }))
    Write-Output ("DB08_RESULT_CODE: " + $token)
    Write-Output "DB08_WORKBOOK_MODIFIED: False"
    Write-Output "DB08_NEXUS_SOURCE_MODIFIED: False"
    Write-Output "DB08_GIT_MODIFIED: False"
    Write-Output ("DB08_REQUIRES_HUMAN_ACTION: " + $(if ($human) { "True" } else { "False" }))
    Write-Output ("DB08_HUMAN_ACTION_TYPE: " + $humanType)
    foreach ($e in $evidence) { Write-Output ("DB08_EVIDENCE: " + $e) }
    exit 0
}

# ---- DB-M08 decision-parser: extract the SINGLE explicit review-decision field
# from the review text. Supported forms (case-insensitive label + token):
#   Decision: PASS                 Review decision: FIX
#   ### Review decision: FIX       **Decision:** GOVERNANCE_ISSUE
#   - **Review decision:** HUMAN_DECISION_REQUIRED
# The token must be one of the four allowed decisions. Returns:
#   @{ Status = "Unique";      Decision = "<token>" }
#   @{ Status = "NotParseable" }  (no explicit valid decision field)
#   @{ Status = "Ambiguous";   Values = @(<conflicting tokens>) }
function Test-ReviewDecisionText([string]$text) {
    $validTokens = @("PASS", "FIX", "GOVERNANCE_ISSUE", "HUMAN_DECISION_REQUIRED")
    $found = @{}
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        foreach ($line in ($text -split "\r?\n")) {
            # strip leading markdown/heading/bullet decoration, then test for an
            # explicit "decision" (optionally "review decision") assignment.
            $candidate = [string]$line.TrimStart('#', ' ', "`t", '*', '_', '`', '>', '-', '(', ')', '[')
            if ($candidate -match '^(?<label>(review\s+)?decision)\s*[*_`]*\s*[:：]\s*(?<rest>.*)$') {
                $chunk = [string]$Matches['rest']
                $chunk = [string]($chunk -replace '^[\s*_`>#\-\(\)\[\]]+', '')
                if ($chunk -match '^(?<tok>[A-Za-z_][A-Za-z_]*)(\s|$|[^A-Za-z_])') {
                    $tok = $Matches['tok'].ToUpperInvariant()
                    if ($validTokens -contains $tok) { $found[$tok] = $true }
                }
            }
        }
    }
    $keys = @($found.Keys)
    if ($keys.Count -eq 0) { return @{ Status = "NotParseable"; Decision = ""; Values = @() } }
    if ($keys.Count -gt 1) { return @{ Status = "Ambiguous"; Decision = ""; Values = $keys } }
    return @{ Status = "Unique"; Decision = [string]$keys[0]; Values = $keys }
}

$ct = Read-DevBridgeJson $script:CurrentTaskPath
if ($null -eq $ct) { Out-Markers "STOP_NO_CURRENT_TASK" $false @("No current-task.json; run DB-M03 preflight first.") $false "" }

$nodeId = [string](Get-DevBridgeField $ct "nodeId")
$changeId = [string](Get-DevBridgeField $ct "changeId")
$taskName = [string](Get-DevBridgeField $ct "name")
if (-not $nodeId) { $nodeId = [string](Get-DevBridgeField $ct "taskId") }

# ---- decision + verbatim text (one-command parameters or DB08_* env) ----
$decision = ""
$reviewText = ""
if ($env:DB_COMMAND_INPUT_PARAMETERS) {
    $p = ConvertFrom-DevBridgeJsonString $env:DB_COMMAND_INPUT_PARAMETERS
    if ($null -ne $p) {
        $decision = [string](Get-DevBridgeField $p "decision")
        $reviewText = [string](Get-DevBridgeField $p "reviewText")
    }
}
if (-not $decision) { $decision = [string]$env:DB08_DECISION }
if (-not $reviewText -and $env:DB08_REVIEW_TEXT) { $reviewText = [string]$env:DB08_REVIEW_TEXT }
if (-not $reviewText) { $reviewText = "(no review text supplied)" }

$valid = @("PASS", "FIX", "GOVERNANCE_ISSUE", "HUMAN_DECISION_REQUIRED")
# A supplied (advisory) decision is validated when present; an empty supplied
# decision is allowed here so the authoritative text parse below can fill it in.
if ($decision -and ($valid -notcontains $decision)) {
    Out-Markers "STOP_INVALID_DECISION" $false @("Decision must be one of: " + ($valid -join ", ")) $false ""
}

$mode = Get-DevBridgeMode $ct $script:CfgPath
if ($env:DB_COMMAND_INPUT_MODE) { $mode = $env:DB_COMMAND_INPUT_MODE }
$trial = ($mode -eq "TRIAL")

# ---- DB-M07 identity gate: the recorded result must belong to the CURRENT
# review subject and the CURRENT CLAUDE REVIEW MANIFEST. An old/historical
# review (e.g. a previous node/change or a stale manifest) is rejected with
# CLAUDE_RESULT_IDENTITY_MISMATCH and is NEVER recorded for the current cycle.
$resultNodeId = $nodeId
$resultChangeId = $changeId
if ($env:DB_COMMAND_INPUT_NODE_ID)   { $resultNodeId = [string]$env:DB_COMMAND_INPUT_NODE_ID }
elseif ($env:DB08_NODE_ID)           { $resultNodeId = [string]$env:DB08_NODE_ID }
if ($env:DB_COMMAND_INPUT_CHANGE_ID) { $resultChangeId = [string]$env:DB_COMMAND_INPUT_CHANGE_ID }
elseif ($env:DB08_CHANGE_ID)         { $resultChangeId = [string]$env:DB08_CHANGE_ID }

function Out-IdentityMismatch([string]$reason) {
    Out-Markers "CLAUDE_RESULT_IDENTITY_MISMATCH" $false @("Claude result rejected for the current cycle: " + $reason) $false ""
}

if ($resultNodeId -ne $nodeId) { Out-IdentityMismatch ("result node " + $resultNodeId + " != current node " + $nodeId + ".") }
if ($resultChangeId -ne $changeId) { Out-IdentityMismatch ("result change " + $resultChangeId + " != current change " + $changeId + ".") }

# The review must have been performed against the CURRENT manifest (identity +
# deterministic Manifest ID bound to the current DB-M06 evidence + ready stamp).
$manifest = Test-CrmManifestCurrent -StateDir $script:StateDir -TasksDir $script:TasksDir
if (-not $manifest.Ready) {
    Out-IdentityMismatch ("there is no current CLAUDE REVIEW MANIFEST for " + $nodeId + " / " + $changeId + " (" + $manifest.Reason + ").")
}

# DB-M06 must be a PASS for the SAME node/change (covered by the manifest gate,
# asserted explicitly for a clear reason when the manifest is missing).
$verifGate = Read-DevBridgeJson (Join-Path $script:StateDir "verification.json")
if ($null -eq $verifGate -or [string](Get-DevBridgeField $verifGate "primaryResult") -notlike "VERIFICATION_PASSED*") {
    Out-Markers "STOP_DBM06_PASS_REQUIRED" $false @("DB-M06 verification must PASS for the same node/change before a Claude result can be recorded.") $false ""
}

# ---- DB-M08 hardening: the recorded decision is the review text's SINGLE
# explicit decision field. A text naming no decision or conflicting decisions is
# rejected and the lifecycle is never advanced; PASS is never silently defaulted.
$parse = Test-ReviewDecisionText $reviewText
if ($parse.Status -eq "Ambiguous") {
    Out-Markers "CLAUDE_RESULT_DECISION_AMBIGUOUS" $false @("Review text contains conflicting explicit decisions: " + (($parse.Values | Sort-Object) -join ", ") + ". Record exactly ONE explicit decision field; nothing was written and the lifecycle was not advanced.") $false ""
}
if ($parse.Status -eq "NotParseable") {
    Out-Markers "CLAUDE_RESULT_DECISION_NOT_PARSEABLE" $false @("No explicit review decision field found in the review text (expected 'Decision: PASS|FIX|GOVERNANCE_ISSUE|HUMAN_DECISION_REQUIRED' or a 'Review decision: <token>' variant). PASS is never silently defaulted; nothing was written and the lifecycle was not advanced.") $false ""
}
if ($decision -and $decision -ne $parse.Decision) {
    Write-Output ("DB08_NOTE: supplied decision '" + $decision + "' differs from the review text's explicit decision '" + $parse.Decision + "'; recording the review text decision.")
}
$decision = $parse.Decision

# ---- route ----
$dbM09Required = ($decision -eq "FIX")
$routeLifecycleState = ""
$routeNextAllowedAction = ""
switch ($decision) {
    "PASS" {
        if ($trial) { $routeLifecycleState = "CLAUDE_REVIEW_PASSED_TRIAL"; $routeNextAllowedAction = "TRIAL_CYCLE_SAFE_STOP" }
        else { $routeLifecycleState = "CLAUDE_REVIEW_PASSED_REAL"; $routeNextAllowedAction = "AWAITING_HUMAN_PR" }
    }
    "FIX" { $routeLifecycleState = "DB_M09_FIX_REQUIRED"; $routeNextAllowedAction = "CORRECT_CURRENT_ATTEMPT" }
    "GOVERNANCE_ISSUE" { $routeLifecycleState = "GOVERNANCE_ISSUE"; $routeNextAllowedAction = "HUMAN_GOVERNANCE_REVIEW" }
    "HUMAN_DECISION_REQUIRED" { $routeLifecycleState = "HUMAN_DECISION_REQUIRED"; $routeNextAllowedAction = "HUMAN_DECISION" }
}
$requiresHuman = ($decision -eq "GOVERNANCE_ISSUE" -or $decision -eq "HUMAN_DECISION_REQUIRED")

# ---- idempotency: the same decision for the same change is REUSED, never duplicated ----
$existing = Read-DevBridgeJson $script:JsonPath
if ($null -ne $existing -and [string](Get-DevBridgeField $existing "changeId") -eq $changeId -and [string](Get-DevBridgeField $existing "nodeId") -eq $nodeId -and [string](Get-DevBridgeField $existing "decision") -eq $decision) {
    Out-Markers "REUSED" $true @("tasks/CLAUDE_REVIEW_RESULT.md", "state/claude-review.json") $requiresHuman $(if ($decision -eq "GOVERNANCE_ISSUE") { "HUMAN_GOVERNANCE_REVIEW" } elseif ($decision -eq "HUMAN_DECISION_REQUIRED") { "HUMAN_DECISION" } else { "" })
}

# ---- evidence files ----
$md = "DecisionToken: " + $decision + "`nNode: " + $nodeId + "`nChange: " + $changeId + "`nManifest ID: " + $manifest.ManifestId + "`n`n" + $reviewText + "`n"
[System.IO.File]::WriteAllText($script:ResultMdPath, $md, (New-Object System.Text.UTF8Encoding($false)))

$json = [ordered]@{
    milestone            = "DB-M08"
    nodeId               = $nodeId
    changeId             = $changeId
    name                 = $taskName
    reviewedNodeId       = $resultNodeId
    reviewedChangeId     = $resultChangeId
    reviewedManifestId   = $manifest.ManifestId
    reviewedAgainstDbM06 = $manifest.VerifiedAtUtc
    decision             = $decision
    dbM09Required        = $dbM09Required
    trialMode            = $trial
    routeLifecycleState  = $routeLifecycleState
    routeNextAllowedAction = $routeNextAllowedAction
    reviewedAt           = $script:NowUtc
    recordedVia          = "Set-ClaudeReviewResult.ps1 (DB-M12.2 RECORD_CLAUDE_RESULT command)"
    reviewText           = $reviewText
}
Write-DevBridgeJson $script:JsonPath $json

$db8 = [ordered]@{
    result       = "CLAUDE_RESULT_RECORDED"
    decision     = $decision
    nodeId       = $nodeId
    changeId     = $changeId
    trialMode    = $trial
    routeLifecycleState = $routeLifecycleState
    reviewedAt   = $script:NowUtc
    evidence     = @("tasks/CLAUDE_REVIEW_RESULT.md", "state/claude-review.json")
}
Set-DevBridgeStateEntry $script:CurrentTaskPath @{
    status = $routeLifecycleState; nextAllowedAction = $routeNextAllowedAction; dbM08 = $db8
}

Out-Markers "CLAUDE_RESULT_RECORDED" $true @("tasks/CLAUDE_REVIEW_RESULT.md", "state/claude-review.json") $requiresHuman $(if ($decision -eq "GOVERNANCE_ISSUE") { "HUMAN_GOVERNANCE_REVIEW" } elseif ($decision -eq "HUMAN_DECISION_REQUIRED") { "HUMAN_DECISION" } else { "" })
