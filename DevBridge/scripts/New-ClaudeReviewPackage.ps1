# New-ClaudeReviewPackage.ps1 - DB-M07 governed review package assembly
# (DB-M12.2 reusable lifecycle command for CREATE_CLAUDE_REVIEW_PACKAGE).
#
# Builds the Claude review package for the CURRENT task from the DB-M06
# verification evidence:
#   * tasks\CLAUDE_REVIEW_PACKAGE.md  - self-contained package with the complete
#                                       DB-GH01 governance header (all 9 items,
#                                       per ClaudeReviewPackageValidation)
#   * tasks\REVIEW_PACKET.md          - the review packet artifact
# The package is read-only: it assembles evidence and never edits the workbook or
# the roadmap. Idempotent: a package already stamped with this changeId+nodeId is
# REUSED, never duplicated. The lifecycle status stays VERIFIED.
#
# Backend contract: ALWAYS exits 0; outcomes ONLY via stdout markers (DB07_*).
# State/tasks dirs redirect with DB07_STATE_DIR / DB07_TASKS_DIR.
#
# ASCII-only source (PS 5.1 + BOM-safe).
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Set-DevBridgeStateEntry.ps1")
. (Join-Path $PSScriptRoot "TrialDependencyOverlay.ps1")

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:StateDir = Join-Path $script:Root "state"
$script:TasksDir = Join-Path $script:Root "tasks"
$script:CfgPath = Join-Path $script:Root "config\devbridge.json"
if ($env:DB07_STATE_DIR) { $script:StateDir = $env:DB07_STATE_DIR }
if ($env:DB07_TASKS_DIR) { $script:TasksDir = $env:DB07_TASKS_DIR }
$script:CurrentTaskPath = Join-Path $script:StateDir "current-task.json"
$script:PackagePath = Join-Path $script:TasksDir "CLAUDE_REVIEW_PACKAGE.md"
$script:PacketPath = Join-Path $script:TasksDir "REVIEW_PACKET.md"
$script:NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

function Out-Markers([string]$token, [bool]$pass, [string[]]$evidence) {
    Write-Output ("DB07_OUTCOME: " + $token)
    Write-Output ("DB07_RESULT_PASS: " + $(if ($pass) { "True" } else { "False" }))
    Write-Output ("DB07_RESULT_CODE: " + $token)
    Write-Output "DB07_WORKBOOK_MODIFIED: False"
    Write-Output "DB07_NEXUS_SOURCE_MODIFIED: False"
    Write-Output "DB07_GIT_MODIFIED: False"
    Write-Output "DB07_REQUIRES_HUMAN_ACTION: False"
    Write-Output "DB07_HUMAN_ACTION_TYPE:"
    foreach ($e in $evidence) { Write-Output ("DB07_EVIDENCE: " + $e) }
    exit 0
}

$ct = Read-DevBridgeJson $script:CurrentTaskPath
if ($null -eq $ct) { Out-Markers "STOP_NO_CURRENT_TASK" $false @("No current-task.json; run DB-M03 preflight first.") }

$nodeId = [string](Get-DevBridgeField $ct "nodeId")
$changeId = [string](Get-DevBridgeField $ct "changeId")
$taskName = [string](Get-DevBridgeField $ct "name")
if (-not $nodeId) { $nodeId = [string](Get-DevBridgeField $ct "taskId") }

# DB-M06 verification evidence is the review scope; without a PASS there is nothing
# to package.
$verif = Read-DevBridgeJson (Join-Path $script:StateDir "verification.json")
$primary = [string](Get-DevBridgeField $verif "primaryResult")
if ($primary -notmatch "^VERIFICATION_PASSED") {
    Out-Markers "STOP_VERIFICATION_REQUIRED" $false @("DB-M06 verification must PASS before a Claude review package can be assembled.")
}

$mode = Get-DevBridgeMode $ct $script:CfgPath
if ($env:DB_COMMAND_INPUT_MODE) { $mode = $env:DB_COMMAND_INPUT_MODE }
$trial = ($mode -eq "TRIAL")

# Idempotency: an existing package already stamped for this exact change is REUSED.
if ((Test-Path $script:PackagePath) -and (Test-Path $script:PacketPath)) {
    $existing = [System.IO.File]::ReadAllText($script:PackagePath)
    if ($existing.Contains($changeId) -and $existing.Contains($nodeId)) {
        Out-Markers "REUSED" $true @("tasks/CLAUDE_REVIEW_PACKAGE.md", "tasks/REVIEW_PACKET.md")
    }
}

$header = @"
# Claude Review Package

Change under review: $changeId
Node: $nodeId
Task: $taskName
Mode: $mode
Generated (utc): $script:NowUtc

## 1. Temporary boundary
DevBridge is TEMPORARY external scaffolding for Nexus Phase 1/2. It will be
retired. Nothing reviewed here becomes Nexus runtime architecture, contracts,
services, libraries, infrastructure or a dependency.

## 2. Trial or real mode
This change was developed in mode: $mode. In TRIAL, evidence stops at the trial
safe-stop and governed completion is NOT applicable. In REAL_NEXUS_DEVELOPMENT,
completion requires the human git gates and a preserved protected roadmap.

## 3. Architecture independence
A review PASS approves the change DELTA only. The reviewer is NOT authorized to
redesign Nexus architecture, contracts or services as a condition of review.

## 4. Roadmap immutability
The roadmap is immutable to this review. No roadmap redesign or structural edit is
authorized. Protected phase/milestone/goal/outcome/acceptance-criteria/dependency
surfaces must remain unchanged by the change under review.

## 5. Fix-task rule
A defect found in this attempt is addressed as CORRECT_CURRENT_ATTEMPT. A defect
found after completion requires a NEW_FIX_TASK_REQUIRED under the existing
structure. Anything unrepresentable is HUMAN_GOVERNANCE_REQUIRED.

## 6. Exact scope
The exact scope under review is the delta of this change: changeId $changeId on
nodeId $nodeId. The review verdict applies to this scope only.

## 7. Forbidden edits
The following are FORBIDDEN during this change: unauthorized workbook edits,
modifications to DB-M23-owned files, source changes outside the recorded scope,
and edits to the protected roadmap surface. These must not be introduced and are
prohibited from this package.

## 8. Human git gates
PR creation, review and merge are HUMAN-gated actions. DevBridge never creates,
approves, infers or merges PRs. The merge gate is confirmed only by an explicit
observed gitLifecycleState.

## 9. Decision vocabulary
The reviewer returns exactly one of: PASS, FIX, GOVERNANCE_ISSUE,
HUMAN_DECISION_REQUIRED. PASS approves the delta; FIX routes to the correction
loop; GOVERNANCE_ISSUE is escalated to a human; HUMAN_DECISION_REQUIRED suspends
for an explicit human decision.

---

## Verification evidence

Result: $primary
Verified (utc): $(if ($verif) { [string](Get-DevBridgeField $verif "verifiedAtUtc") } else { "" })
Evidence: state/verification.json, tasks/VERIFICATION_REPORT.md
"@

# ---- Dependency context (DB-M18.1, additive; never alters markers/exit codes) ----
$script:Db181Block = ''
$db181Lib = Join-Path $script:Root 'scripts\ai-routing\DependencyLineage.ps1'
$db181Evidence = Join-Path $script:Root 'logs\tasks'
if ((Test-Path -LiteralPath $db181Lib) -and (Test-Path -LiteralPath $db181Evidence)) {
    try {
        . $db181Lib
        $db181Bundle = Get-DbM181TaskDependencyContext -Task $ct -TaskCatalog $null -EvidenceRoot $db181Evidence -RepositoryRoot $null -NowUtc $script:NowUtc
        $script:Db181Block = Get-DbM181ClaudeDependencyContext -Task $ct -Context $db181Bundle.Context
    } catch { $script:Db181Block = '' }
}
if ($script:Db181Block) { $header = $header + "`r`n`r`n" + $script:Db181Block }

# ---- Trial-proven dependency distinction (DB-M03.2, additive; capability 11) ----
# The review package must distinguish a REAL Completed/Complete predecessor from a
# TRIAL_DEPENDENCY_SATISFIED predecessor (trial-proven implementation state, real
# roadmap status still Planned). Additive text only; markers/exit codes unchanged.
$script:TrialDepBlock = ''
$pfObj = Read-DevBridgeJson (Join-Path $script:StateDir "preflight.json")
$trialDepEntries = @()
if ($null -ne $pfObj) {
    $pfDeps = Get-DevBridgeField $pfObj "dependencies"
    if ($null -ne $pfDeps) { $trialDepEntries = @($pfDeps | Where-Object { [string](Get-DevBridgeField $_ "state") -eq "TRIAL_DEPENDENCY_SATISFIED" }) }
}
if ($trialDepEntries.Count -gt 0) {
    $trialSb = New-Object System.Text.StringBuilder
    [void]$trialSb.AppendLine("## Trial-Proven Dependency Distinction (DB-M03.2)")
    [void]$trialSb.AppendLine("The change under review depends on a predecessor satisfied ONLY by the TRIAL-only proving overlay. Its trial-proven IMPLEMENTATION state is distinct from its real ROADMAP status:")
    foreach ($tde in $trialDepEntries) {
        $tdeId = [string](Get-DevBridgeField $tde "dependencyId")
        $tdeStatus = [string](Get-DevBridgeField $tde "status")
        $tdeDetail = [string](Get-DevBridgeField $tde "detail")
        $tov2 = Test-TrialDependencySatisfied -DependencyNodeId $tdeId -StateDir $script:StateDir -ConfigPath $script:CfgPath -RealStatus $tdeStatus
        if ($tov2.Satisfied) {
            $tprov = $tov2.Provenance
            [void]$trialSb.AppendLine("- **" + $tdeId + "** real roadmap status: **" + $tprov.realStatus + "** (NOT Completed/Complete; authoritative). Proving status: **TRIAL_CYCLE_CLOSED** via change " + $tprov.changeId + " (" + $tprov.closedAtUtc + "); implementation state **TRIAL_ONLY_UNMERGED**. DB-M06 **" + $tprov.verificationEvidence.m06Result + "** (tests " + $tprov.verificationEvidence.testsPassed + "/" + $tprov.verificationEvidence.testsTotal + "), Claude review **" + $tprov.claudeEvidence.decision + "** (trialMode " + $tprov.claudeEvidence.trialMode + ", reviewedAgainstDbM06 " + $tprov.claudeEvidence.reviewedAgainstDbM06 + "). Overlay status **TRIAL_DEPENDENCY_SATISFIED**, real completion capability **NO**, disposable proving context **true**, repository freshness **" + $tprov.repositoryReconciliation.freshness + "**.")
        } else {
            [void]$trialSb.AppendLine("- **" + $tdeId + "** recorded as TRIAL_DEPENDENCY_SATISFIED in the preflight, but the overlay does not currently qualify (" + $tov2.Reason + "). Treat the dependency as unsatisfied for real completion purposes.")
        }
    }
    [void]$trialSb.AppendLine("This distinction does NOT make the predecessor real-complete. The real Nexus restart point is the preserved PRE-DEVBRIDGE workbook + source/Git baseline; nothing from the proving environment becomes genuine Nexus progress.")
    $script:TrialDepBlock = $trialSb.ToString().TrimEnd()
}
if ($script:TrialDepBlock) { $header = $header + "`r`n`r`n" + $script:TrialDepBlock }

$packet = @"
# Review Packet - $changeId

Change: $changeId
Node: $nodeId
Task: $taskName
Mode: $mode
Package: tasks/CLAUDE_REVIEW_PACKAGE.md

This packet is the review input for the change above. It is READ-ONLY evidence
assembly. The governing constraints of the review are the nine header items in
tasks/CLAUDE_REVIEW_PACKAGE.md.
"@

if (-not (Test-Path $script:TasksDir)) { New-Item -ItemType Directory -Force -Path $script:TasksDir | Out-Null }
[System.IO.File]::WriteAllText($script:PackagePath, $header, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($script:PacketPath, $packet, (New-Object System.Text.UTF8Encoding($false)))

$db7 = [ordered]@{
    result        = "REVIEW_PACKAGE_CREATED"
    nodeId        = $nodeId
    changeId      = $changeId
    mode          = $mode
    trialMode     = $trial
    generatedAtUtc = $script:NowUtc
    governanceHeader = "COMPLETE"
    evidence      = @("tasks/CLAUDE_REVIEW_PACKAGE.md", "tasks/REVIEW_PACKET.md")
}
Set-DevBridgeStateEntry $script:CurrentTaskPath @{ dbM07 = $db7 }

Out-Markers "CLAUDE_REVIEW_PACKAGE_CREATED" $true @("tasks/CLAUDE_REVIEW_PACKAGE.md", "tasks/REVIEW_PACKET.md")
