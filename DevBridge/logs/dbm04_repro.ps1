# Manual T2-style fixture repro to capture the engine's real output/error
$ErrorActionPreference = 'Stop'
$root = 'C:\Personal\DevTools\DevBridge'
$fixtureRoot = Join-Path $root 'logs\selftest\repro_t2'
if (Test-Path $fixtureRoot) { Remove-Item $fixtureRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $fixtureRoot 'state') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $fixtureRoot 'tasks') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $fixtureRoot 'logs') | Out-Null
$wbCopy = Join-Path $fixtureRoot 'workbook.xlsx'
Copy-Item 'C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx' $wbCopy -Force
$h = (Get-FileHash $wbCopy -Algorithm SHA256).Hash
$pre = @{
    taskId = 'WI-07-0.2.4'; nodeId = 'WI-07-0.2.4'; name = 'Concurrency, locking and atomic writes'
    verdict = 'CLEAR'; phase = 'P0'; parentNodeId = 'M-07-0.2'; currentWorkNodeId = 'M-07-0.2'; featureNodeId = 'F-07-0'
    repositories = @('Nexus.Developer'); projects = @('Nexus.Developer.Core')
    filesGlobs = @('src/Nexus.Developer.Core/DevelopmentControl/**'); schemaContexts = @(); contractsApis = @('IDevelopmentControlStore')
    affectedNodes = @('F-07-0','M-07-0.2','WI-07-0.2.1','WI-07-0.2.2','WI-07-0.2.3','WI-07-0.2.4','WI-07-0.2.5','WI-07-0.2.6','WI-07-0.2.7','WI-07-0.2.8','WI-07-0.2.9','WI-07-0.2.10')
    dependencies = @(
        @{ dependencyId = 'WI-07-0.2.3'; type = 'Textual (node Dependencies)'; state = 'SATISFIED'; status = 'Complete'; detail = 'Excel persistence adapter' }
        @{ dependencyId = 'REL-001..011'; type = 'Explicit D&B'; state = 'NOT_APPLICABLE'; status = $null; detail = 'no ref' }
    )
    risk = 'Low'; parallelSafe = $true; workbookSha256 = $h
}
$cur = @{ taskId = 'WI-07-0.2.4'; nodeId = 'WI-07-0.2.4'; status = 'PREFLIGHTED'; selectedAt = '2026-08-30T13:08:07Z'; nextAllowedAction = 'RESERVE' }
$pre | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 (Join-Path $fixtureRoot 'state\preflight.json')
$cur | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 (Join-Path $fixtureRoot 'state\current-task.json')

$env:DB04_SELFTEST = '1'
$env:DB04_WORKBOOK_OVERRIDE = $wbCopy
$env:DB04_STATE_DIR = Join-Path $fixtureRoot 'state'
$env:DB04_TASKS_DIR = Join-Path $fixtureRoot 'tasks'
$env:DB04_LOGS_DIR = Join-Path $fixtureRoot 'logs'
$env:DB04_TEST_STALE = ''; $env:DB04_TEST_CONFLICT = ''; $env:DB04_TEST_SCOPE_WIDEN = ''

$out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Personal\DevTools\DevBridge\scripts\Reserve-DevelopmentChange.ps1' 2>&1)
$out | ForEach-Object { Write-Output $_ }
Write-Output "--- exit=done ---"
