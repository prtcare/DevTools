param(
    [Parameter(Mandatory=$false)]
    [string]$RepoPath = (Get-Location).Path,
    [Parameter(Mandatory=$false)]
    [string]$Label = "Pre-implementation checkpoint"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path (Join-Path $RepoPath ".git"))) {
    Write-Host "Not a Git repository: $RepoPath" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "NEXUS CHECKPOINT" -ForegroundColor Cyan
Write-Host "Repository : $RepoPath"

$branch = git -C $RepoPath branch --show-current
Write-Host "Branch     : $branch"

Write-Host ""
Write-Host "Checking repository integrity..."
git -C $RepoPath fsck --no-progress
if ($LASTEXITCODE -ne 0) {
    Write-Host "git fsck failed. No checkpoint created." -ForegroundColor Red
    exit 1
}

$changes = @(git -C $RepoPath status --porcelain)
if ($changes.Count -gt 0) {
    Write-Host ""
    Write-Host "Working tree has uncommitted changes:" -ForegroundColor Yellow
    git -C $RepoPath status --short
    Write-Host ""
    Write-Host "Checkpoint aborted. Commit/stash/review these changes first." -ForegroundColor Yellow
    exit 2
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$tag = "checkpoint/$stamp"
git -C $RepoPath tag -a $tag -m $Label
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to create checkpoint tag." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Checkpoint created: $tag" -ForegroundColor Green
Write-Host "Label: $Label"
