# ============================================
# Nexus Development Launcher
# ============================================

Clear-Host

Write-Host ""
Write-Host "========================================"
Write-Host "       NEXUS DEVELOPMENT LAUNCHER"
Write-Host "========================================"
Write-Host ""

$repositories = @{
    "1" = @{
        Name = "Nexus.Intelligence"
        Path = "C:\Personal\Nexus.Intelligence"
    }
    "2" = @{
        Name = "Nexus.Platform"
        Path = "C:\Personal\Nexus.Platform"
    }
    "3" = @{
        Name = "Nexus.Experience"
        Path = "C:\Personal\Nexus.Experience"
    }
}

Write-Host "1. NexusAI"
Write-Host "2. Nexus.Int"
Write-Host "3. Nexus.Web"
Write-Host ""

$choice = Read-Host "Select repository"

if (-not $repositories.ContainsKey($choice)) {
    Write-Host ""
    Write-Host "Invalid selection."
    exit 1
}

$repo = $repositories[$choice]

if (-not (Test-Path $repo.Path)) {
    Write-Host ""
    Write-Host "Repository not found:"
    Write-Host $repo.Path
    exit 1
}

Set-Location $repo.Path

Clear-Host

Write-Host ""
Write-Host "========================================"
Write-Host "       NEXUS DEVELOPMENT SESSION"
Write-Host "========================================"
Write-Host ""

Write-Host "Repository : $($repo.Name)"
Write-Host "Location   : $($repo.Path)"

# --------------------------------------------
# Git information
# --------------------------------------------

if (Test-Path ".git") {

    $branch = git branch --show-current

    Write-Host "Branch     : $branch"

    $gitStatus = git status --porcelain

    if ([string]::IsNullOrWhiteSpace(($gitStatus -join ""))) {
        Write-Host "Git Status : CLEAN"
    }
    else {
        Write-Host "Git Status : CHANGES PRESENT"
        Write-Host ""
        git status --short
    }

}
else {
    Write-Host "Git Status : Not a Git repository"
}

# --------------------------------------------
# Agent governance check
# --------------------------------------------

Write-Host ""

if (Test-Path "AGENTS.md") {
    Write-Host "AGENTS.md  : FOUND"
}
else {
    Write-Host "AGENTS.md  : NOT FOUND"
}

Write-Host ""
Write-Host "Starting DeepSeek through Claude Code..."
Write-Host ""

# --------------------------------------------
# Launch existing DeepCode function
# --------------------------------------------

deepcode