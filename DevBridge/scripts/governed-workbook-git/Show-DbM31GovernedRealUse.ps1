# Show-DbM31GovernedRealUse.ps1 -- DB-M31 CLI entry point.
#
# READ-ONLY supervised guide. Always exits 0; outcomes communicated via DB31_*
# stdout markers. Accepts explicit surfaces for fixture testing; never writes the
# live canonical workbook, never advances the lifecycle, never runs a Git write
# or a destructive command.

[CmdletBinding()]
param(
    [string]$Root = 'C:\Personal\DevTools\DevBridge',
    [string]$StateSource = 'LIVE',
    [string]$WorkbookPath = '',
    [string]$RepositoryPath = '',
    [string]$RenderPath = '',
    [string]$NowUtc = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'WorkbookGitContracts.ps1')
. (Join-Path $scriptDir 'WorkbookGitEngine.ps1')
. (Join-Path $scriptDir 'WorkbookGitRender.ps1')

# explicit surfaces for fixture testing; LIVE derives defaults from config
$cfg = Get-DbM31Config -Root $Root
if (-not $WorkbookPath) { $WorkbookPath = $cfg.WorkbookPath }

$view = Get-DbM31View -Root $Root -StateSource $StateSource -WorkbookPath $WorkbookPath -RepositoryPath $RepositoryPath -NowUtc $NowUtc

$secret = Test-DbM31SecretLeak -Target $view
if ($secret.Leak) {
    'DB31_SECRET_SCAN: FAIL'
    'DB31_OUTCOME: FAIL'
    'DB31_RESULT_PASS: False'
    'DB31_REQUIRES_HUMAN_ACTION: True'
    exit 0
}

$forbidden = Test-DbM31ForbiddenCommand -Command ($MyInvocation.Line)
if ($forbidden) {
    'DB31_FORBIDDEN_COMMAND: FAIL'
    'DB31_OUTCOME: FAIL'
    'DB31_RESULT_PASS: False'
    'DB31_REQUIRES_HUMAN_ACTION: True'
    exit 0
}

# head of the report
"DB31_VIEW: $($view.ViewId)"
"DB31_MODE: $($view.Lifecycle.Mode)"
"DB31_STATE_SOURCE: $($view.StateSource)"
"DB31_NODE: $($view.Lifecycle.NodeId)"
"DB31_CHANGE: $($view.Lifecycle.ChangeId)"
"DB31_STATUS: $($view.Lifecycle.Status)"
"DB31_NEXT_ALLOWED_ACTION: $($view.Lifecycle.NextAllowedAction)"
"DB31_TRIAL_FLOW_POSITION: $($view.TrialFlow.Position)"
"DB31_GIT_GATE_STATE: $($view.GitGate.GateState)"
"DB31_MERGE_CONFIRMED: $($view.GitGate.MergeConfirmed)"
"DB31_MERGE_EVIDENCE: $(if($view.GitGate.MergeEvidence){$view.GitGate.MergeEvidence}else{'NONE'})"
"DB31_PR_STATE_OBSERVED: $($view.GitGate.PrStateObserved)"
"DB31_PR_STATE_HONESTY: $($view.GitObservation.PrState) (remote never inferred)"
"DB31_M10_TOKEN: $($view.M10.Token)"
"DB31_M10_ELIGIBLE: $($view.M10.Eligible)"
"DB31_FINGERPRINT: $(if($view.Fingerprint.Sha256){$view.Fingerprint.Sha256}else{'NOT_COMPARABLE'})"
"DB31_FINGERPRINT_ROWS: $($view.Fingerprint.ProtectedRows)"
"DB31_FINGERPRINT_CELLS: $($view.Fingerprint.ProtectedCells)"
"DB31_FINGERPRINT_VERDICT: $($view.FingerprintVerdict)"
"DB31_ROADMAP_STRUCTURE_WRITE_CAPABILITY: NO"
"DB31_AUTOMATIC_PR_CREATED: NO"
"DB31_AUTOMATIC_MERGE_PERFORMED: NO"
"DB31_AUTOMATIC_NEXT_TASK: NO"
"DB31_BASELINE_RESTORE: NO"
"DB31_AUTO_EXECUTION_ENABLED: False"

foreach ($w in @($view.Warnings)) { "DB31_WARNING: $w" }

# render the HTML artifact when requested
if ($RenderPath) {
    try {
        Export-DbM31GovernedRealUseHtml -View $view -OutputPath $RenderPath
        "DB31_HTML: $RenderPath"
        "DB31_RENDER: PASS"
    } catch {
        "DB31_RENDER: FAIL -- $($_.Exception.Message)"
    }
}

# backend markers (always exit 0)
Out-DbM31Markers | ForEach-Object { $_ }
exit 0
