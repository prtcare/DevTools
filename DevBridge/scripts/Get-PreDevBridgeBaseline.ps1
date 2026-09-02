# Get-PreDevBridgeBaseline.ps1
# DevBridge DB-GH01 PRE-DEVBRIDGE BASELINE -- captures and REPRESENTS the real
# Nexus restart point: the authoritative workbook SHA-256 and the Nexus git
# branch/HEAD as they existed before DevBridge began operating.
#
# ABSOLUTE RULE: this script only REPRESENTS the baseline. It contains NO
# restore function and no destructive code path. Restoration is a human-governed
# decision made later; DevBridge never auto-runs `git reset --hard`, `git clean`,
# overwrites the workbook with a backup, or deletes trial source.
#
# Idempotent: an existing baseline capture is preserved (never overwritten)
# unless -Force is passed.
#
# Backend contract: ALWAYS exits 0; outcomes communicated ONLY via stdout markers.
param(
    [switch]$Force,
    [string]$NexusRepo = "C:\Personal\Nexus.Developer"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Read-DevelopmentControl.ps1"

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:StateDir = Join-Path $script:Root "state"
$script:OutPath = Join-Path $script:StateDir "pre-devbridge-baseline.json"
$script:NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# Preserve an existing capture (idempotent).
if (-not $Force -and (Test-Path $script:OutPath)) {
    Write-Output "DBGH01_BASELINE_PRESENT: True"
    Write-Output ("DBGH01_BASELINE_FILE: " + $script:OutPath)
    Write-Output "DBGH01_BASELINE_ACTION: PRESERVED_EXISTING"
    Write-Output "DBGH01_OUTCOME: PRE_DEVBRIDGE_BASELINE_PRESERVED"
    exit 0
}

$script:Errors = New-Object System.Collections.Generic.List[string]

# Workbook baseline (read-only SHA-256 of the authoritative workbook).
$script:WbSha = ""
try { $script:WbSha = Get-WorkbookSha256 } catch { $script:Errors.Add("workbook sha: " + $_.Exception.Message) }

# Git baseline (observed, read-only; never mutated).
$script:GitBranch = ""; $script:GitHead = ""
if (Test-Path $script:NexusRepo) {
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $script:GitBranch = [string](& git -C $script:NexusRepo rev-parse --abbrev-ref HEAD 2>$null) } catch { }
    try { $script:GitHead = [string](& git -C $script:NexusRepo rev-parse HEAD 2>$null) } catch { }
    $ErrorActionPreference = $oldEap
} else {
    $script:Errors.Add("Nexus repo not found: $script:NexusRepo")
}

$script:Out = [ordered]@{
    workbook = [ordered]@{
        path          = $script:DevControlWorkbook
        sha256        = $script:WbSha
        capturedAtUtc = $script:NowUtc
    }
    git = [ordered]@{
        repository    = $script:NexusRepo
        branch        = $script:GitBranch
        headCommit    = $script:GitHead
        capturedAtUtc = $script:NowUtc
    }
    errors = $script:Errors
    representOnly = "NO RESTORE FUNCTION EXISTS. Restoration of this baseline is a HUMAN action taken later; DevBridge never restores it automatically."
}

[System.IO.File]::WriteAllText($script:OutPath, ($script:Out | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

Write-Output ("DBGH01_BASELINE_PRESENT: True")
Write-Output ("DBGH01_BASELINE_WORKBOOK_SHA: " + $script:WbSha)
Write-Output ("DBGH01_BASELINE_GIT_BRANCH: " + $script:GitBranch)
Write-Output ("DBGH01_BASELINE_GIT_HEAD: " + $script:GitHead)
if ($script:Errors.Count -gt 0) { Write-Output ("DBGH01_BASELINE_ERROR: " + ($script:Errors -join "; ")) }
Write-Output ("DBGH01_BASELINE_FILE: " + $script:OutPath)
Write-Output "DBGH01_BASELINE_ACTION: CAPTURED"
Write-Output "DBGH01_OUTCOME: PRE_DEVBRIDGE_BASELINE_CAPTURED"
exit 0
