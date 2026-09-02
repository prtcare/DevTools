# Show-DbM32EssentialSafety.ps1 -- DB-M32 CLI entry point.
#
# READ-ONLY observation, classification &amp; guidance engine. Always exits 0;
# outcomes communicated via DB32_* stdout markers. Accepts explicit surfaces for
# fixture testing; never writes the live canonical workbook, never advances the
# lifecycle, never deletes a writer lock, never runs a Git write or a
# destructive command, never restores a baseline, never executes a provider.

[CmdletBinding()]
param(
    [string]$Root = 'C:\Personal\DevTools\DevBridge',
    [string]$StateSource = 'LIVE',
    [string]$WorkbookPath = '',
    [string]$RepositoryPath = '',
    [string]$RenderPath = '',
    [string]$DiagnosticsPath = '',
    [string]$LastOperation = '',
    [string]$NowUtc = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'RecoveryContracts.ps1')
. (Join-Path $scriptDir 'RecoveryEngine.ps1')
. (Join-Path $scriptDir 'RecoveryRender.ps1')

$forbidden = Test-DbM32ForbiddenCommand -Command ($MyInvocation.Line)
if (-not $forbidden) {
    # Under `-File` invocation $MyInvocation.Line can be empty; scan the bound
    # parameter VALUES too so a forbidden value passed to any surface is caught.
    foreach ($k in $PSBoundParameters.Keys) {
        if ($null -ne $PSBoundParameters[$k]) {
            $val = [string]$PSBoundParameters[$k]
            if ($val -and (Test-DbM32ForbiddenCommand -Command $val)) { $forbidden = $true; break }
        }
    }
}
if ($forbidden) {
    'DB32_FORBIDDEN_COMMAND: FAIL'
    'DB32_OUTCOME: FAIL'
    'DB32_RESULT_PASS: False'
    'DB32_REQUIRES_HUMAN_ACTION: True'
    exit 0
}

$view = Get-DbM32ReconciledView -Root $Root -StateSource $StateSource -WorkbookPath $WorkbookPath -RepositoryPath $RepositoryPath -NowUtc $NowUtc -LastOperationOverride $LastOperation

$secret = Test-DbM32SecretLeak -Target $view
if ($secret.Leak) {
    'DB32_SECRET_SCAN: FAIL'
    'DB32_OUTCOME: FAIL'
    'DB32_RESULT_PASS: False'
    'DB32_REQUIRES_HUMAN_ACTION: True'
    exit 0
}
'DB32_SECRET_SCAN: PASS'

# head of the report
"DB32_VIEW: $($view.ViewId)"
"DB32_STATE_SOURCE: $($view.StateSource)"
"DB32_MODE: $($view.Lifecycle.Mode)"
"DB32_NODE: $($view.Task.NodeId)"
"DB32_CHANGE: $(if($view.Task.ChangeId){$view.Task.ChangeId}else{'NONE'})"
"DB32_STATUS: $($view.Task.Status)"
"DB32_NEXT_ALLOWED_ACTION: $($view.Task.NextAllowedAction)"
"DB32_RECOVERY_STATUS: $($view.RecoveryStatus)"
"DB32_LAST_OPERATION: $(if($view.LastOperation){$view.LastOperation.Command}else{'NONE'})"
"DB32_RECOVERY_CLASSIFICATION: $($view.Classification.Classification)"
"DB32_RECOMMENDED_ACTION: $($view.Classification.RecommendedAction)"
"DB32_WORKBOOK_VERDICT: $($view.Workbook.Verdict)"
"DB32_WORKBOOK_SHA: $(if($view.Workbook.Sha256){$view.Workbook.Sha256}else{'UNOBSERVED'})"
"DB32_WRITER_LOCK: $($view.Lock.State)"
"DB32_OPERATION_IDENTITY: $($view.Identity)"
"DB32_TOKEN_COUNT: $($view.Tokens.Count)"
"DB32_GIT_BRANCH: $(if($view.Git.Branch){$view.Git.Branch}else{'UNOBSERVED'})"
"DB32_GIT_HEAD: $(if($view.Git.HeadCommit){$view.Git.HeadCommit}else{'UNOBSERVED'})"
"DB32_GIT_PR_STATE: $($view.Git.PrState) (remote never inferred)"
"DB32_AUTO_EXECUTION_ENABLED: False"
"DB32_AUTOMATIC_ROLLBACK_CAPABILITY: NO"
"DB32_DESTRUCTIVE_GIT_RECOVERY: NO"
"DB32_AUTOMATIC_BASELINE_RESTORE: NO"
"DB32_AUTOMATIC_PR_CREATED: NO"
"DB32_AUTOMATIC_MERGE_PERFORMED: NO"
"DB32_AUTOMATIC_NEXT_TASK: NO"
"DB32_AUTONOMOUS_DEVELOPMENT_CYCLE: NO"
"DB32_AUTONOMOUS_PARALLEL_SCHEDULER: NO"

foreach ($t in @($view.Tokens)) { "DB32_INTERRUPTED_OPERATION_TOKEN: $t" }
foreach ($w in @($view.Warnings)) { "DB32_WARNING: $w" }

# render the HTML artifact when requested
if ($RenderPath) {
    try {
        Export-DbM32EssentialSafetyHtml -View $view -OutputPath $RenderPath
        "DB32_HTML: $RenderPath"
        "DB32_RENDER: PASS"
    } catch {
        "DB32_RENDER: FAIL -- $($_.Exception.Message)"
    }
}

# emit diagnostics when requested
if ($DiagnosticsPath) {
    try {
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($d in @($view.Diagnostics)) {
            [void]$lines.Add("$($d.Key)=$($d.Value)")
        }
        $leak2 = Test-DbM32SecretLeak -Target ($lines -join "`n")
        if ($leak2.Leak) {
            'DB32_DIAGNOSTICS: FAIL -- secret-like value present; nothing written.'
        } else {
            [System.IO.File]::WriteAllText($DiagnosticsPath, ($lines -join [Environment]::NewLine) + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
            "DB32_DIAGNOSTICS: $DiagnosticsPath"
            "DB32_DIAGNOSTICS_WRITE: PASS"
        }
    } catch {
        "DB32_DIAGNOSTICS_WRITE: FAIL -- $($_.Exception.Message)"
    }
}

# backend markers (always exit 0)
Out-DbM32Markers | ForEach-Object { $_ }
exit 0
