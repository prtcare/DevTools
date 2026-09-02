# Test-DBM10CompletionEligibility.ps1
# DevBridge DB-GH01 DB-M10 CRITICAL gate -- READ-ONLY. Declares whether governed
# completion is ELIGIBLE, mirroring the engine's M10CompletionEligibility.Evaluate:
#   * TRIAL mode -> TRIAL_COMPLETION_NOT_APPLICABLE (M10 never runs for a trial).
#   * REAL mode -> requires DB-M06 PASS, Claude PASS, a CONFIRMED human merge
#     (gitLifecycleState MERGED / READY_FOR_GOVERNED_COMPLETION), and a preserved
#     protected roadmap fingerprint (before == after).
# This script NEVER performs the completion write.
#
# Backend contract: ALWAYS exits 0; outcomes communicated ONLY via stdout markers.
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:StateDir = Join-Path $script:Root "state"
$script:TasksDir = Join-Path $script:Root "tasks"
$script:CurrentPath = Join-Path $script:StateDir "current-task.json"
$script:VerifPath = Join-Path $script:StateDir "verification.json"
$script:ClaudePath = Join-Path $script:StateDir "claude-review.json"
$script:FpPath = Join-Path $script:StateDir "roadmap-fingerprint.json"

function Read-Json([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    try { return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}
function Str($obj, [string]$key) {
    if ($null -eq $obj) { return $null }
    if ($obj.PSObject.Properties.Name -contains $key) { return [string]$obj.$key }
    return $null
}
function IsTrue([string]$token) {
    return ($token -and $token.StartsWith("True", [System.StringComparison]::OrdinalIgnoreCase))
}

$script:Ct = Read-Json $script:CurrentPath
$script:Verif = Read-Json $script:VerifPath
$script:Claude = Read-Json $script:ClaudePath
$script:Fp = Read-Json $script:FpPath

# ---- mode: current-task "mode" wins, else config, else cycle trial evidence ----
$script:Mode = "TRIAL"
$modeToken = Str $script:Ct "mode"
if ($modeToken) { $script:Mode = $modeToken } else {
    if ((Str $script:Ct "dbM08.trialMode") -or (Str $script:Ct "dbM06.trialMode")) { $script:Mode = "TRIAL" }
    else { $script:Mode = "TRIAL" }   # config default remains TRIAL for DevBridge
}
$script:TrialMode = ($script:Mode -eq "TRIAL")

# ---- DB-M06 verification pass ----
$script:VerifPass = $false
$verifResult = Str $script:Verif "primaryResult"
if ($verifResult -and $verifResult.StartsWith("VERIFICATION_PASSED", [System.StringComparison]::OrdinalIgnoreCase)) { $script:VerifPass = $true }

# ---- Claude review pass ----
$script:ClaudePass = $false
$claudeDecision = Str $script:Claude "decision"
if ($claudeDecision -and $claudeDecision.StartsWith("PASS", [System.StringComparison]::OrdinalIgnoreCase)) { $script:ClaudePass = $true }

# ---- human git gate: explicit gitLifecycleState (merged = confirmed) ----
$script:MergeConfirmed = $false
$gitToken = Str $script:Ct "gitLifecycleState"
if ($gitToken -in @("MERGED","READY_FOR_GOVERNED_COMPLETION")) { $script:MergeConfirmed = $true }

# ---- protected roadmap fingerprint guard (before vs after) ----
$script:GuardVerdict = "NOT_COMPARABLE"
$fpBefore = $null; $fpAfter = $null
if ($script:Fp) {
    if ($script:Fp.PSObject.Properties.Name -contains "before") { $fpBefore = $script:Fp.before }
    if ($script:Fp.PSObject.Properties.Name -contains "after") { $fpAfter = $script:Fp.after }
    if ($fpBefore -and $fpAfter) {
        $bVal = [string]$fpBefore.value; $aVal = [string]$fpAfter.value
        $bErr = [string]$fpBefore.error; $aErr = [string]$fpAfter.error
        if ($bErr -or $aErr) { $script:GuardVerdict = "NOT_COMPARABLE" }
        elseif ($bVal -eq $aVal) { $script:GuardVerdict = "PRESERVED" }
        else { $script:GuardVerdict = "STRUCTURE_CHANGED" }
    }
}

# ---- verdict (mirrors M10CompletionEligibility.Evaluate) ----
$script:Verdict = "ReadyForGovernedCompletion"
$script:Token = "READY_FOR_GOVERNED_COMPLETION"
$script:Reason = "All gates satisfied: DB-M06 PASS, Claude PASS, human merge confirmed, protected roadmap fingerprint preserved."
if ($script:TrialMode) {
    $script:Verdict = "NotApplicable"
    $script:Token = "TRIAL_COMPLETION_NOT_APPLICABLE"
    $script:Reason = "TRIAL cycle: M10 governed completion is NOT applicable. The cycle stops at TRIAL_CYCLE_SAFE_STOP; completion is never run for trial evidence."
} elseif (-not $script:VerifPass) {
    $script:Verdict = "BlockedNoVerificationPass"
    $script:Token = "BLOCKED_NO_DB_M06_VERIFICATION_PASS"
    $script:Reason = "DB-M06 verification has not passed. Completion requires DB-M06 PASS first."
} elseif (-not $script:ClaudePass) {
    $script:Verdict = "BlockedNoClaudePass"
    $script:Token = "BLOCKED_NO_CLAUDE_PASS"
    $script:Reason = "Claude review has not passed. Completion requires Claude PASS."
} elseif (-not $script:MergeConfirmed) {
    $script:Verdict = "BlockedHumanGitGatePending"
    $script:Token = "BLOCKED_HUMAN_GIT_MERGE_GATE_PENDING"
    $script:Reason = "The human Git merge gate is not confirmed. A REAL completion requires a CONFIRMED merge -- never an inferred one."
} elseif ($script:GuardVerdict -ne "PRESERVED") {
    $script:Verdict = "BlockedRoadmapStructureWriteProhibited"
    $script:Token = "ROADMAP_STRUCTURE_WRITE_PROHIBITED"
    $script:Reason = if ($script:GuardVerdict -eq "STRUCTURE_CHANGED") { "The protected roadmap surface changed between fingerprint capture and the governed write." } else { "The protected roadmap fingerprint could not be computed or compared; the write is blocked." }
}

$script:Eligible = ($script:Verdict -eq "ReadyForGovernedCompletion")
Write-Output ("DBGH01_M10_ELIGIBLE: " + $script:Eligible)
Write-Output ("DBGH01_M10_VERDICT: " + $script:Verdict)
Write-Output ("DBGH01_M10_TOKEN: " + $script:Token)
Write-Output ("DBGH01_M10_REASON: " + $script:Reason)
Write-Output ("DBGH01_M10_MODE: " + $script:Mode)
Write-Output ("DBGH01_M10_VERIFICATION_PASS: " + $script:VerifPass)
Write-Output ("DBGH01_M10_CLAUDE_PASS: " + $script:ClaudePass)
Write-Output ("DBGH01_M10_MERGE_CONFIRMED: " + $script:MergeConfirmed)
Write-Output ("DBGH01_M10_FINGERPRINT_GUARD: " + $script:GuardVerdict)
Write-Output ("DBGH01_OUTCOME: " + $(if ($script:Eligible) { "M10_ELIGIBLE" } else { "M10_BLOCKED" }))
exit 0
