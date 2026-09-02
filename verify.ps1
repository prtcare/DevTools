param(
    [Parameter(Mandatory=$false)]
    [string]$RepoPath = (Get-Location).Path
)

$ErrorActionPreference = "Continue"

if (-not (Test-Path (Join-Path $RepoPath ".git"))) {
    Write-Host "Not a Git repository: $RepoPath" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "========================================"
Write-Host "      NEXUS IMPLEMENTATION VERIFY"
Write-Host "========================================"
Write-Host ""
Write-Host "Repository : $RepoPath"
Write-Host "Branch     : $(git -C $RepoPath branch --show-current)"
Write-Host ""

Write-Host "GIT STATUS"
git -C $RepoPath status --short

Write-Host ""
Write-Host "DIFF SUMMARY"
git -C $RepoPath diff --stat

$solution = Get-ChildItem -Path $RepoPath -File -Filter *.slnx | Select-Object -First 1
if (-not $solution) {
    $solution = Get-ChildItem -Path $RepoPath -File -Filter *.sln | Select-Object -First 1
}

$buildResult = "NOT RUN"
if ($solution) {
    Write-Host ""
    Write-Host "BUILD"
    Write-Host "dotnet build $($solution.Name)"
    Push-Location $RepoPath
    dotnet build $solution.Name
    if ($LASTEXITCODE -eq 0) { $buildResult = "PASS" } else { $buildResult = "FAIL" }
    Pop-Location
} else {
    Write-Host ""
    Write-Host "BUILD"
    Write-Host "No .slnx/.sln file found; build skipped." -ForegroundColor Yellow
}

$testProjects = Get-ChildItem -Path $RepoPath -Recurse -Filter *.csproj -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match "Test|Tests" }

$testResult = "NOT RUN"
if ($testProjects.Count -gt 0) {
    Write-Host ""
    Write-Host "TESTS"
    Push-Location $RepoPath
    dotnet test --no-build
    if ($LASTEXITCODE -eq 0) { $testResult = "PASS" } else { $testResult = "FAIL" }
    Pop-Location
} else {
    Write-Host ""
    Write-Host "TESTS"
    Write-Host "No .NET test projects detected; test command skipped." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================"
Write-Host "RESULT"
Write-Host "Build : $buildResult"
Write-Host "Tests : $testResult"
Write-Host "========================================"
Write-Host ""
Write-Host "Review the complete git diff before Claude approval:"
Write-Host "git -C `"$RepoPath`" diff"
