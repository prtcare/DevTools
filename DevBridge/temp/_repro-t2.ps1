$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
$Root = (Resolve-Path "C:\Personal\DevTools\DevBridge").Path
$Cfg = Get-Content (Join-Path $Root "config\devbridge.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$Real = $Cfg.developmentControlWorkbook
$outDir = Join-Path $Root "logs\selftest\_repro_t2"
if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $outDir "state") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $outDir "tasks") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $outDir "logs") | Out-Null
$wbCopy = Join-Path $outDir "workbook.xlsx"
Copy-Item $Real $wbCopy -Force
$pre = @{ taskId = "WI-07-0.2.4"; nodeId = "WI-07-0.2.4"; name = "Concurrency, locking and atomic writes"; verdict = "CLEAR"; phase = "P0"; repositories = @("Nexus.Developer"); projects = @("Nexus.Developer.Core"); filesGlobs = @("src/Nexus.Developer.Core/DevelopmentControl/**"); dependencies = @(@{ dependencyId = "WI-07-0.2.3"; state = "SATISFIED"; status = "Complete" }) }
$pre.workbookSha256 = (Get-FileHash $wbCopy -Algorithm SHA256).Hash
$cur = @{ taskId = "WI-07-0.2.4"; nodeId = "WI-07-0.2.4"; status = "PREFLIGHTED"; selectedAt = "2026-08-30T13:08:07Z"; nextAllowedAction = "RESERVE"; changeId = "" }
$pre | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 (Join-Path $outDir "state\preflight.json")
$cur | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 (Join-Path $outDir "state\current-task.json")
$env:DB04_SELFTEST = "1"
$env:DB04_WORKBOOK_OVERRIDE = $wbCopy
$env:DB04_STATE_DIR = Join-Path $outDir "state"
$env:DB04_TASKS_DIR = Join-Path $outDir "tasks"
$env:DB04_LOGS_DIR = Join-Path $outDir "logs"
$oldEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Reserve-DevelopmentChange.ps1") 2>&1)
$ErrorActionPreference = $oldEAP
Write-Output "=== ENGINE RAW OUTPUT ==="
$out | ForEach-Object { "$_" }
Write-Output "=== EXIT: $LASTEXITCODE ==="
