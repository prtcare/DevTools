$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
. "C:\Personal\DevTools\DevBridge\scripts\Set-DevBridgeStateEntry.ps1"
. "C:\Personal\DevTools\DevBridge\scripts\Read-DevelopmentControl.ps1"
$Root = "C:\Personal\DevTools\DevBridge"
$outDir = Join-Path $Root "logs\selftest\_repro_s4"
if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
$stateDir = Join-Path $outDir "state"; $tasksDir = Join-Path $outDir "tasks"
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null
$wbCopy = Join-Path $outDir "workbook.xlsx"
Copy-Item "C:\Personal\DevTools\DevBridge\state\backups\db-m124-preclosure-20260831152502.xlsx" $wbCopy -Force
$backupDir = Join-Path $stateDir "backups"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$backup = [string](Join-Path $backupDir "pre-reservation.xlsx")
Copy-Item $wbCopy $backup -Force
$backupSha = [string](Get-FileHash $backup -Algorithm SHA256).Hash
$cur = [ordered]@{
  nodeId = "WI-07-0.2.4"; taskId = "WI-07-0.2.4"; name = "DB-M12.4 fixture s4"
  nodeType = "WorkItem"; phase = "P0"; layer = "App"; changeId = "CHG-20260830-017"
  status = "CLAUDE_REVIEW_PASSED_TRIAL"; nextAllowedAction = "TRIAL_CYCLE_SAFE_STOP"; selectedAt = "2026-08-31T00:00:00Z"
  mode = "TRIAL"
  dbM08 = [ordered]@{ implementationState = "TRIAL_ONLY_UNMERGED"; m10Run = $false; trialMode = $true }
  dbM06 = [ordered]@{ implementationState = "TRIAL_ONLY_UNMERGED"; trialMode = $true }
  gitLifecycleState = "NOT_APPLICABLE"
  reservationEvidence = [ordered]@{ backupPath = $backup; backupSha256 = $backupSha }
}
Write-DevBridgeJson (Join-Path $stateDir "current-task.json") $cur | Out-Null
$env:DB24_STATE_DIR = $stateDir
$env:DB24_TASKS_DIR = $tasksDir
$env:DB24_WORKBOOK_OVERRIDE = $wbCopy
$oldEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Close-TrialCycle.ps1") 2>&1)
$ErrorActionPreference = $oldEAP
$out | ForEach-Object { "$_" }
Write-Output "=== EXIT: $LASTEXITCODE ==="
