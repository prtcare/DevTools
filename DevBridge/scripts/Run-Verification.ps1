# Run-Verification.ps1 - DB-M06 governed verification (DB-M12.2 reusable lifecycle
# command for RUN_VERIFICATION).
#
# Runs the configured build/test commands for the CURRENT task (or auto-discovers
# the DevBridge solution when config\devbridge.json leaves defaultBuildCommands/
# defaultTestCommands empty), then records state\verification.json +
# tasks\VERIFICATION_REPORT.md and, on PASS, transitions current-task.json to
# VERIFIED. On FAIL it records the failure evidence and reports DB06_RESULT_PASS:
# False without forcing any lifecycle transition (the operator re-runs after fixing).
#
# Backend contract: ALWAYS exits 0; outcomes communicated ONLY via stdout markers
# (DB06_*). Fixture mode: DB06_SELFTEST=1 (+ DB06_FAIL=1 to force a failure).
# State/tasks dirs redirect with DB06_STATE_DIR / DB06_TASKS_DIR. M06 never
# modifies the workbook. No work-item identity is hard-coded: everything comes from
# the current task or the one-command input environment.
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
if ($env:DB06_STATE_DIR) { $script:StateDir = $env:DB06_STATE_DIR }
if ($env:DB06_TASKS_DIR) { $script:TasksDir = $env:DB06_TASKS_DIR }
$script:CurrentTaskPath = Join-Path $script:StateDir "current-task.json"
$script:NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

function Out-Markers([string]$token, [bool]$pass, [string[]]$evidence) {
    Write-Output ("DB06_OUTCOME: " + $token)
    Write-Output ("DB06_RESULT_PASS: " + $(if ($pass) { "True" } else { "False" }))
    Write-Output ("DB06_RESULT_CODE: " + $token)
    Write-Output "DB06_WORKBOOK_MODIFIED: False"
    Write-Output "DB06_NEXUS_SOURCE_MODIFIED: False"
    Write-Output "DB06_GIT_MODIFIED: False"
    Write-Output "DB06_REQUIRES_HUMAN_ACTION: False"
    Write-Output "DB06_HUMAN_ACTION_TYPE:"
    foreach ($e in $evidence) { Write-Output ("DB06_EVIDENCE: " + $e) }
    exit 0
}

function Invoke-CommandCapture([string]$commandLine) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/d /c " + $commandLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEnd()
    $se = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return @{ ExitCode = $p.ExitCode; Output = ($so + "`n" + $se) }
}

$ct = Read-DevBridgeJson $script:CurrentTaskPath
if ($null -eq $ct) { Out-Markers "STOP_NO_CURRENT_TASK" $false @("No current-task.json; run DB-M03 preflight first.") }

$nodeId = [string](Get-DevBridgeField $ct "nodeId")
$changeId = [string](Get-DevBridgeField $ct "changeId")
$taskName = [string](Get-DevBridgeField $ct "name")
if (-not $nodeId) { $nodeId = [string](Get-DevBridgeField $ct "taskId") }

$mode = Get-DevBridgeMode $ct $script:CfgPath
if ($env:DB_COMMAND_INPUT_MODE) { $mode = $env:DB_COMMAND_INPUT_MODE }
$trial = ($mode -eq "TRIAL")

# ---- build/test commands (config) or auto-discovery of the solution ----
$buildCommands = @(); $testCommands = @()
if (Test-Path $script:CfgPath) {
    $cfg = Get-Content $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.defaultBuildCommands) { $buildCommands = @($cfg.defaultBuildCommands) }
    if ($cfg.defaultTestCommands) { $testCommands = @($cfg.defaultTestCommands) }
}
$selftest = ($env:DB06_SELFTEST -eq "1")
if (-not $selftest -and $buildCommands.Count -eq 0 -and $testCommands.Count -eq 0) {
    $sln = Get-ChildItem -Path $script:Root -Filter *.sln* -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($sln) { $buildCommands = @('dotnet build "' + $sln.FullName + '"') }
    else { Out-Markers "STOP_VERIFICATION_ENVIRONMENT_UNAVAILABLE" $false @("No defaultBuildCommands/defaultTestCommands configured and no solution found to auto-discover.") }
}

# ---- run (or fixture-drive) the verification ----
$log = New-Object System.Collections.Generic.List[string]
$resultPass = $true
if ($selftest) {
    $fail = ($env:DB06_FAIL -eq "1")
    $log.Add("(selftest) verification fixture: " + $(if ($fail) { "forced FAIL" } else { "forced PASS" }))
    $resultPass = -not $fail
} else {
    foreach ($cmd in (@($buildCommands) + @($testCommands))) {
        $r = Invoke-CommandCapture $cmd
        $log.Add("> " + $cmd)
        $log.Add($r.Output)
        if ($r.ExitCode -ne 0) { $resultPass = $false }
    }
}

$primaryResult = $(if ($resultPass) { "VERIFICATION_PASSED" } else { "VERIFICATION_FAILED" })
$verification = [ordered]@{
    milestone     = "DB-M06"
    nodeId        = $nodeId
    changeId      = $changeId
    name          = $taskName
    primaryResult = $primaryResult
    verifiedAtUtc = $script:NowUtc
    mode          = $mode
    trialMode     = $trial
    commands      = @($log.ToArray())
    evidence      = @("state/verification.json", "tasks/VERIFICATION_REPORT.md")
}
Write-DevBridgeJson (Join-Path $script:StateDir "verification.json") $verification

$report = "# DB-M06 Verification Report`n`nNode: " + $nodeId + "`nChange: " + $changeId + "`nResult: " + $primaryResult + "`nVerified (utc): " + $script:NowUtc + "`nMode: " + $mode + "`n`nCommands and output:`n`n" + ($log -join "`n")
[System.IO.File]::WriteAllText((Join-Path $script:TasksDir "VERIFICATION_REPORT.md"), $report, (New-Object System.Text.UTF8Encoding($false)))

$db6 = [ordered]@{
    result        = $(if ($resultPass) { "VERIFICATION_PASS" } else { "VERIFICATION_FAIL" })
    nodeId        = $nodeId
    changeId      = $changeId
    mode          = $mode
    trialMode     = $trial
    primaryResult = $primaryResult
    verifiedAtUtc = $script:NowUtc
    evidence      = @("state/verification.json", "tasks/VERIFICATION_REPORT.md")
}

if ($resultPass) {
    Set-DevBridgeStateEntry $script:CurrentTaskPath @{ status = "VERIFIED"; nextAllowedAction = "CLAUDE_REVIEW"; dbM06 = $db6 }
    Out-Markers "VERIFICATION_PASSED" $true @("state/verification.json", "tasks/VERIFICATION_REPORT.md")
} else {
    # Record the failure evidence; do NOT force a lifecycle transition.
    Set-DevBridgeStateEntry $script:CurrentTaskPath @{ dbM06 = $db6 }
    Out-Markers "VERIFICATION_FAILED" $false @("state/verification.json", "tasks/VERIFICATION_REPORT.md")
}
