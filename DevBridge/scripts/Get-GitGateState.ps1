# Get-GitGateState.ps1 - DB-GH01 git gate observation, DB-M12.2 reusable lifecycle
# command for REFRESH_GIT_GATE_STATE.
#
# READ-ONLY. Refreshes the observed git lifecycle state (branch, head commit, PR
# position) into state\git-gate-state.json. PR state is UNKNOWN whenever it cannot
# be verified -- it is NEVER fabricated and never inferred from anything less than
# explicit observation. The command does not change any lifecycle status and does
# not create, approve or merge PRs.
#
# Backend contract: ALWAYS exits 0; outcomes ONLY via stdout markers (DB13_*).
# Fixture mode: DB13_SELFTEST=1 supplies DB13_GIT_BRANCH / DB13_HEAD / DB13_PR_STATE
# without invoking git. Repository dir: DB13_GIT_DIR (fixture) or the current
# task's repositoryStates[0].path. State dir redirects with DB13_STATE_DIR.
#
# ASCII-only source (PS 5.1 + BOM-safe).
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Set-DevBridgeStateEntry.ps1")

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:StateDir = Join-Path $script:Root "state"
if ($env:DB13_STATE_DIR) { $script:StateDir = $env:DB13_STATE_DIR }
$script:CurrentTaskPath = Join-Path $script:StateDir "current-task.json"
$script:NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

function Out-Markers([string]$token, [bool]$pass, [string[]]$evidence) {
    Write-Output ("DB13_OUTCOME: " + $token)
    Write-Output ("DB13_RESULT_PASS: " + $(if ($pass) { "True" } else { "False" }))
    Write-Output ("DB13_RESULT_CODE: " + $token)
    Write-Output "DB13_WORKBOOK_MODIFIED: False"
    Write-Output "DB13_NEXUS_SOURCE_MODIFIED: False"
    Write-Output "DB13_GIT_MODIFIED: False"
    Write-Output "DB13_REQUIRES_HUMAN_ACTION: False"
    Write-Output "DB13_HUMAN_ACTION_TYPE:"
    foreach ($e in $evidence) { Write-Output ("DB13_EVIDENCE: " + $e) }
    exit 0
}

# repository root: DB13_GIT_DIR (fixture) or the current task's first repository
$repoDir = $null
if ($env:DB13_GIT_DIR) { $repoDir = $env:DB13_GIT_DIR }
else {
    $ct = Read-DevBridgeJson $script:CurrentTaskPath
    if ($null -ne $ct) {
        $repos = Get-DevBridgeField $ct "repositoryStates"
        if ($null -ne $repos -and $repos.Count -gt 0) { $repoDir = [string]$repos[0]["path"] }
    }
}

$selftest = ($env:DB13_SELFTEST -eq "1")
$branch = ""
$head = ""
$prState = "UNKNOWN"
$isGitRepo = $false
$source = ""

if ($selftest) {
    $branch = [string]$env:DB13_GIT_BRANCH
    $head = [string]$env:DB13_HEAD
    $prState = [string]$env:DB13_PR_STATE
    if (-not $prState) { $prState = "UNKNOWN" }
    $isGitRepo = [bool]$env:DB13_GIT_BRANCH
    $source = "selftest env"
} elseif ($repoDir -and (Test-Path $repoDir)) {
    $gitCheck = & git -C $repoDir rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -eq 0 -and $gitCheck -match "true") {
        $isGitRepo = $true
        $branch = (& git -C $repoDir rev-parse --abbrev-ref HEAD 2>$null)
        $head = (& git -C $repoDir rev-parse HEAD 2>$null)
        $source = "git -C " + $repoDir + " (read-only observation)"
        # PR state cannot be verified locally without a remote/API call; default
        # UNKNOWN (never fabricated). An explicit DB13_PR_STATE overrides.
        if ($env:DB13_PR_STATE) { $prState = [string]$env:DB13_PR_STATE }
    }
} else {
    $source = "no repository root available; PR state UNKNOWN"
}

# mergeConfirmed is only true when a PR is explicitly observed as merged/completed.
$mergeConfirmed = ($prState -in @("MERGED", "READY_FOR_GOVERNED_COMPLETION"))

$snapshot = [ordered]@{
    observedAtUtc   = $script:NowUtc
    repository      = $repoDir
    isGitRepo       = $isGitRepo
    branch          = $branch
    headCommit      = $head
    prState         = $prState
    mergeConfirmed  = $mergeConfirmed
    source          = $source
    note            = "PR state is UNKNOWN whenever it cannot be explicitly verified; it is never fabricated."
}
Write-DevBridgeJson (Join-Path $script:StateDir "git-gate-state.json") $snapshot

Out-Markers "GIT_GATE_STATE_REFRESHED" $true @("state/git-gate-state.json")
