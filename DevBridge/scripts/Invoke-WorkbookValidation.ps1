# Invoke-WorkbookValidation.ps1 - DB-M11 governed workbook consistency validation
# (DB-M12.2 reusable lifecycle command for VALIDATE_WORKBOOK).
#
# Validates the CURRENT task's governed completion against the workbook: the
# workbook opens and the completion evidence (state\completion.json) is present
# with the lifecycle at COMPLETION_WRITTEN. On a clean validation it records
# state\workbook-consistency.json + tasks\WORKBOOK_CONSISTENCY_REPORT.md and
# transitions to CONTROL_VALIDATED. On failure it records CONTROL_VALIDATION_FAILED
# and reports DB11_RESULT_PASS: False (no forced transition).
#
# Backend contract: ALWAYS exits 0; outcomes ONLY via stdout markers (DB11_*).
# Fixture mode: DB11_SELFTEST=1 (+ DB11_VALID=0 to force a failure). State/tasks
# dirs redirect with DB11_STATE_DIR / DB11_TASKS_DIR; the workbook path redirects
# with DB11_WORKBOOK_OVERRIDE (fixtures only).
#
# ASCII-only source (PS 5.1 + BOM-safe).
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Xml.Linq | Out-Null

. (Join-Path $PSScriptRoot "Read-DevelopmentControl.ps1")
. (Join-Path $PSScriptRoot "Set-DevBridgeStateEntry.ps1")

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:StateDir = Join-Path $script:Root "state"
$script:TasksDir = Join-Path $script:Root "tasks"
$script:CfgPath = Join-Path $script:Root "config\devbridge.json"
if ($env:DB11_STATE_DIR) { $script:StateDir = $env:DB11_STATE_DIR }
if ($env:DB11_TASKS_DIR) { $script:TasksDir = $env:DB11_TASKS_DIR }
$script:CurrentTaskPath = Join-Path $script:StateDir "current-task.json"
$script:NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
if ($env:DB11_WORKBOOK_OVERRIDE) { $script:DevControlWorkbook = $env:DB11_WORKBOOK_OVERRIDE }

function Out-Markers([string]$token, [bool]$pass, [string[]]$evidence) {
    Write-Output ("DB11_OUTCOME: " + $token)
    Write-Output ("DB11_RESULT_PASS: " + $(if ($pass) { "True" } else { "False" }))
    Write-Output ("DB11_RESULT_CODE: " + $token)
    Write-Output "DB11_WORKBOOK_MODIFIED: False"
    Write-Output "DB11_NEXUS_SOURCE_MODIFIED: False"
    Write-Output "DB11_GIT_MODIFIED: False"
    Write-Output "DB11_REQUIRES_HUMAN_ACTION: False"
    Write-Output "DB11_HUMAN_ACTION_TYPE:"
    foreach ($e in $evidence) { Write-Output ("DB11_EVIDENCE: " + $e) }
    exit 0
}

$ct = Read-DevBridgeJson $script:CurrentTaskPath
if ($null -eq $ct) { Out-Markers "STOP_NO_CURRENT_TASK" $false @("No current-task.json; run DB-M03 preflight first.") }

$status = [string](Get-DevBridgeField $ct "status")
if ($status -ne "COMPLETION_WRITTEN") {
    Out-Markers "STOP_INVALID_LIFECYCLE_STATE" $false @("Workbook validation can only run from COMPLETION_WRITTEN (current: '$status').")
}

$nodeId = [string](Get-DevBridgeField $ct "nodeId")
$changeId = [string](Get-DevBridgeField $ct "changeId")
$taskName = [string](Get-DevBridgeField $ct "name")
if (-not $nodeId) { $nodeId = [string](Get-DevBridgeField $ct "taskId") }

$completion = Read-DevBridgeJson (Join-Path $script:StateDir "completion.json")
$checks = New-Object System.Collections.Generic.List[string]
$valid = $true

if ($null -eq $completion) {
    $checks.Add("FAIL  completion evidence missing (state/completion.json)")
    $valid = $false
} else {
    $checks.Add("PASS  completion evidence present")
}
$cchg = [string](Get-DevBridgeField $completion "changeId")
if ($cchg -and $cchg -ne $changeId) {
    $checks.Add("FAIL  completion changeId '$cchg' != current '$changeId'")
    $valid = $false
} else {
    $checks.Add("PASS  completion change identity matches")
}

# workbook opens
$wbOpens = $false
try { $null = Open-DocEntry "xl/workbook.xml"; $wbOpens = $true } catch { }
if ($wbOpens) { $checks.Add("PASS  workbook opens (sheet map resolvable)") } else {
    $checks.Add("FAIL  workbook could not be opened/parsed")
    $valid = $false
}

# fixture override of the verdict
if ($env:DB11_SELFTEST -eq "1" -and $env:DB11_VALID -eq "0") {
    $checks.Add("FAIL  selftest forced invalid")
    $valid = $false
}
if ($env:DB11_SELFTEST -eq "1" -and $env:DB11_VALID -eq "1") {
    $checks.Add("PASS  selftest forced valid")
    $valid = $true
}

$result = $(if ($valid) { "PASS" } else { "FAIL" })
$consistency = [ordered]@{
    milestone             = "DB-M11"
    nodeId                = $nodeId
    changeId              = $changeId
    name                  = $taskName
    controlValidationResult = $result
    validatedAtUtc        = $script:NowUtc
    checks                = @($checks.ToArray())
    evidence              = @("state/workbook-consistency.json", "tasks/WORKBOOK_CONSISTENCY_REPORT.md")
}
Write-DevBridgeJson (Join-Path $script:StateDir "workbook-consistency.json") $consistency

$report = "# DB-M11 Workbook Consistency Report`n`nNode: " + $nodeId + "`nChange: " + $changeId + "`nResult: " + $result + "`nValidated (utc): " + $script:NowUtc + "`n`nChecks:`n" + ($checks -join "`n") + "`n"
[System.IO.File]::WriteAllText((Join-Path $script:TasksDir "WORKBOOK_CONSISTENCY_REPORT.md"), $report, (New-Object System.Text.UTF8Encoding($false)))

$db11 = [ordered]@{
    result        = $(if ($valid) { "CONTROL_VALIDATED" } else { "CONTROL_VALIDATION_FAILED" })
    nodeId        = $nodeId
    changeId      = $changeId
    controlValidationResult = $result
    validatedAtUtc = $script:NowUtc
    evidence      = @("state/workbook-consistency.json", "tasks/WORKBOOK_CONSISTENCY_REPORT.md")
}

if ($valid) {
    Set-DevBridgeStateEntry $script:CurrentTaskPath @{ status = "CONTROL_VALIDATED"; nextAllowedAction = "VALIDATION_COMPLETE"; dbM11 = $db11 }
    Out-Markers "CONTROL_VALIDATED" $true @("state/workbook-consistency.json", "tasks/WORKBOOK_CONSISTENCY_REPORT.md")
} else {
    Set-DevBridgeStateEntry $script:CurrentTaskPath @{ status = "CONTROL_VALIDATION_FAILED"; nextAllowedAction = "RECOVER_CONTROL_VALIDATION"; dbM11 = $db11 }
    Out-Markers "CONTROL_VALIDATION_FAILED" $false @("state/workbook-consistency.json", "tasks/WORKBOOK_CONSISTENCY_REPORT.md")
}
