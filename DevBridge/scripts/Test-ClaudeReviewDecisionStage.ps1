# Test-ClaudeReviewDecisionStage.ps1
#
# FOCUSED self-tests for the DB-M08 Claude-decision PARSER HARDENING inside
# Set-ClaudeReviewResult.ps1 (Request I: the live cycle recorded PASS when the
# independent Claude review actually returned "Review decision: FIX").
#
# These tests drive the REAL Set-ClaudeReviewResult.ps1 against synthetic,
# throwaway workspaces + throwaway git repositories (identical fixtures to
# Test-ClaudeReviewManifestStage.ps1). They never touch the real DevBridge
# state, the real Nexus repositories, the workbook, or the OS clipboard.
#
# The recorder is now TEXT-AUTHORITATIVE: the recorded decision is recognized
# ONLY from an explicit review-decision field ("Decision: X", "Review decision:
# X", "### Review decision: X", "**Decision:** X" where X is PASS | FIX |
# GOVERNANCE_ISSUE | HUMAN_DECISION_REQUIRED). A review text naming no decision
# is rejected (CLAUDE_RESULT_DECISION_NOT_PARSEABLE), one naming conflicting
# decisions is rejected (CLAUDE_RESULT_DECISION_AMBIGUOUS), and PASS is NEVER
# silently defaulted - the lifecycle is NOT advanced on either rejection.
#
# Focused cases (map to the governing request):
#   D01  "Decision: FIX"                          -> FIX (DB_M09_FIX_REQUIRED)
#   D02  "### Review decision: FIX" (multiline)   -> FIX
#   D03  "**Decision:** FIX"                      -> FIX
#   D04  "Decision: PASS" (TRIAL)                 -> CLAUDE_REVIEW_PASSED_TRIAL
#   D05  "Review decision: GOVERNANCE_ISSUE"      -> GOVERNANCE_ISSUE route
#   D06  "Decision: HUMAN_DECISION_REQUIRED"      -> HUMAN_DECISION_REQUIRED route
#   D07  no explicit decision field               -> CLAUDE_RESULT_DECISION_NOT_PARSEABLE
#   D08  conflicting "Decision: PASS" + "Decision: FIX"
#                                                 -> CLAUDE_RESULT_DECISION_AMBIGUOUS
#   D09  wrong Node                               -> CLAUDE_RESULT_IDENTITY_MISMATCH
#   D10  wrong Change                             -> CLAUDE_RESULT_IDENTITY_MISMATCH
#   D11  supplied PASS but text has NO decision   -> NOT_PARSEABLE (no silent PASS)
#   D12  supplied PASS but text says "Decision: FIX" -> FIX recorded (override)
#   D13  erroneous PASS cycle is correctable to FIX via a re-record (live repro)
#   D14  Nexus source + workbook roadmap untouched by an M08 FIX record
#
# Usage:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File \
#             scripts\Test-ClaudeReviewDecisionStage.ps1 [-Keep]
#
# ASCII-only source (PS 5.1 + BOM-safe). Exit code 0 == all checks green.
param([switch]$Keep)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ScriptsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:M07 = Join-Path $script:ScriptsDir "New-ClaudeReviewPackage.ps1"
$script:M08 = Join-Path $script:ScriptsDir "Set-ClaudeReviewResult.ps1"
foreach ($s in @($script:M07, $script:M08)) {
    if (-not (Test-Path -LiteralPath $s)) { Write-Output ("FATAL: missing backend script " + $s); exit 2 }
}

$script:NODE = "WI-12-0.4.1"
$script:CHANGE = "CHG-20260903-001"
$script:VERIFIED_AT = "2026-09-04T10:00:00Z"
$script:OLD_NODE = "WI-07-0.2.3"
$script:OLD_CHANGE = "CHG-20260830-016"
$script:MODE = "TRIAL"

$script:PassCount = 0
$script:FailCount = 0
$script:TestRoot = Join-Path $env:TEMP ("DevBridgeDec-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

function Write-TextUtf8([string]$path, [string]$text) {
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-Json([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Write-Json([string]$path, $obj) {
    $json = $obj | ConvertTo-Json -Depth 8
    Write-TextUtf8 $path $json
}

function Invoke-Git([string]$repo, [string[]]$arguments) {
    return @(& git -C $repo $arguments)
}

function New-TestRepo([string]$repo) {
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    $null = @(& git init -q $repo)
    & git -C $repo config user.name "DevBridge Test"
    & git -C $repo config user.email "test@devbridge.local"
    Write-TextUtf8 (Join-Path $repo "README.md") "fixture repo baseline readme"
    $null = Invoke-Git $repo @("add", "-A")
    $null = Invoke-Git $repo @("commit", "-qm", "base")
    New-Item -ItemType Directory -Force -Path (Join-Path $repo "src\FooProj") | Out-Null
    Write-TextUtf8 (Join-Path $repo "src\FooProj\.gitkeep") ""
    $null = Invoke-Git $repo @("add", "-A")
    $null = Invoke-Git $repo @("commit", "-qm", "scaffold reserved project")
    $head = (Invoke-Git $repo @("rev-parse", "HEAD") | Select-Object -First 1)
    Write-TextUtf8 (Join-Path $repo "src\FooProj\Delta.txt") "fixture current-task delta content"
    return ([string]$head).Trim()
}

function Build-Brief([string]$node, [string]$change) {
    return @"
Implement the fixture exactly as governed.
==================================================
GOVERNED TASK
==================================================

Node ID:
$node

Task:
Fixture navigation shell

Change ID:
$change

Mode:
$($script:MODE)

==================================================
GOAL
==================================================

Build a routing shell fixture that reuses existing patterns.

Do NOT redesign Nexus.

==================================================
EXACT RESERVED SCOPE - HARD BOUNDARY
==================================================

Reserved repository:
repoA

Reserved project:
FooProj

==================================================
AUTHORITATIVE ACCEPTANCE CRITERIA
==================================================

- AC-1: routing navigates correctly.
- AC-2: existing shell stays intact.

==================================================
ARCHITECTURE RULES
==================================================

- Reuse existing routing patterns.
- Do NOT introduce a new service or architecture.

"@
}

function New-GoodFixture([string]$base, [string]$node, [string]$change, [string]$verifiedAt) {
    $state = Join-Path $base "state"
    $tasks = Join-Path $base "tasks"
    $repo = Join-Path $base "repoA"
    New-Item -ItemType Directory -Force -Path $state, $tasks | Out-Null
    $head = New-TestRepo $repo
    $repoAbs = (Resolve-Path -LiteralPath $repo).Path

    Write-TextUtf8 (Join-Path $tasks "DEEPSEEK_PROMPT.md") (Build-Brief $node $change)

    $ct = @{
        nodeId = $node; taskId = $node; changeId = $change; name = "Fixture navigation shell"
        status = "VERIFIED"; nextAllowedAction = "CLAUDE_REVIEW"; mode = $script:MODE
    }
    Write-Json (Join-Path $state "current-task.json") $ct

    $verif = @{
        milestone = "DB-M06"; nodeId = $node; changeId = $change
        primaryResult = "VERIFICATION_PASSED"; verifiedAtUtc = $verifiedAt
        commands = @("(discovery) node.exe --version", "> npm run build", "> npm test")
    }
    Write-Json (Join-Path $state "verification.json") $verif

    $res = @{
        nodeId = $node; changeId = $change
        reservedScope = @{ projects = @("FooProj") }
        repositoryBaselines = @(@{
            name = "repoA"; path = $repoAbs; isPrimary = $true; headCommit = $head
            preExistingChanges = @{ modified = @(); staged = @(); untracked = @() }
            scopeFileHashes = @()
        })
    }
    Write-Json (Join-Path $state "reservation.json") $res

    return [pscustomobject]@{ Base = $base; State = $state; Tasks = $tasks; Repo = $repo; Head = $head }
}

function Copy-Dir([string]$src, [string]$dst) {
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    foreach ($child in (Get-ChildItem -LiteralPath $src -Force)) {
        Copy-Item -LiteralPath $child.FullName -Destination $dst -Recurse -Force
    }
}

# Run one backend script as a child powershell with the given env vars; returns
# the child stdout lines. Env vars are removed afterwards (never leak across tests).
function Invoke-Backend([string]$which, [hashtable]$envVars) {
    $keys = @($envVars.Keys)
    foreach ($k in $keys) { Set-Item -Path ("env:" + $k) -Value ([string]$envVars[$k]) }
    $out = @()
    try {
        if ($which -eq "M07") { $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:M07) }
        else { $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:M08) }
    } finally {
        foreach ($k in $keys) { Remove-Item -Path ("env:" + $k) -ErrorAction SilentlyContinue }
    }
    return ,@($out)
}

function Get-Marker([string[]]$out, [string]$marker) {
    foreach ($line in $out) {
        if ($line -like ($marker + ":*")) {
            $idx = $line.IndexOf(':')
            return ($line.Substring($idx + 1)).Trim()
        }
    }
    return ""
}

function Check([string]$id, [string]$name, [bool]$cond, [string]$detail) {
    if ($cond) {
        $script:PassCount++
        Write-Output ("FOCUSED-TEST PASS: " + $id + " " + $name)
    } else {
        $script:FailCount++
        Write-Output ("FOCUSED-TEST FAIL: " + $id + " " + $name + "  -> " + $detail)
    }
}

# A single M08-ready fixture is built once and M07 is run on it; every case is a
# throwaway COPY of that ready fixture (same identity + current manifest), so a
# failed case can never leak into another case.
$base = New-GoodFixture (Join-Path $script:TestRoot "ready") $script:NODE $script:CHANGE $script:VERIFIED_AT
$null = Invoke-Backend "M07" @{ DB07_STATE_DIR = $base.State; DB07_TASKS_DIR = $base.Tasks }
$readyManifest = Join-Path $base.Tasks "CLAUDE_REVIEW_PACKAGE.md"
if (-not (Test-Path -LiteralPath $readyManifest)) { Write-Output "FATAL: fixture M07 did not produce a manifest"; exit 2 }
$expectedId = "DB07-MANIFEST|" + $script:CHANGE + "|" + $script:NODE + "|" + $script:VERIFIED_AT

function New-M08Case([string]$label) {
    $c = Join-Path $script:TestRoot $label
    Copy-Dir $base.State (Join-Path $c "state")
    Copy-Dir $base.Tasks (Join-Path $c "tasks")
    return [pscustomobject]@{ Base = $c; State = Join-Path $c "state"; Tasks = Join-Path $c "tasks"; Repo = $base.Repo }
}

# =====================================================================
# D01  "Decision: FIX" (no supplied decision) -> FIX / DB_M09_FIX_REQUIRED
# =====================================================================
$d01 = New-M08Case "d01-fix-plain"
$o_D01 = Invoke-Backend "M08" @{ DB08_STATE_DIR = $d01.State; DB08_TASKS_DIR = $d01.Tasks; DB08_REVIEW_TEXT = "Decision: FIX" }
Check "D01" "text 'Decision: FIX' (no supplied decision) records CLAUDE_RESULT_RECORDED" `
    ((Get-Marker $o_D01 "DB08_OUTCOME") -eq "CLAUDE_RESULT_RECORDED") ("outcome=" + (Get-Marker $o_D01 "DB08_OUTCOME"))
$recD01 = Read-Json (Join-Path $d01.State "claude-review.json")
Check "D01" "persisted decision FIX + dbM09Required true + DB_M09_FIX_REQUIRED / CORRECT_CURRENT_ATTEMPT route" `
    ($null -ne $recD01 -and $recD01.decision -eq "FIX" -and $recD01.dbM09Required -eq $true -and $recD01.routeLifecycleState -eq "DB_M09_FIX_REQUIRED" -and $recD01.routeNextAllowedAction -eq "CORRECT_CURRENT_ATTEMPT") `
    ("record=" + (($recD01 | ConvertTo-Json -Compress)))
$ctD01 = Read-Json (Join-Path $d01.State "current-task.json")
Check "D01" "current-task routes to DB_M09_FIX_REQUIRED / CORRECT_CURRENT_ATTEMPT with dbM08 FIX" `
    ($ctD01.status -eq "DB_M09_FIX_REQUIRED" -and $ctD01.nextAllowedAction -eq "CORRECT_CURRENT_ATTEMPT" -and $ctD01.dbM08.decision -eq "FIX") `
    ("status=" + $ctD01.status + " next=" + $ctD01.nextAllowedAction)
$mdD01 = ""
if (Test-Path -LiteralPath (Join-Path $d01.Tasks "CLAUDE_REVIEW_RESULT.md")) { $mdD01 = [System.IO.File]::ReadAllText((Join-Path $d01.Tasks "CLAUDE_REVIEW_RESULT.md")) }
Check "D01" "CLAUDE_REVIEW_RESULT.md records DecisionToken: FIX" `
    ($mdD01.Contains("DecisionToken: FIX")) ("md head=" + ($mdD01.Split("`n")[0]))

# =====================================================================
# D02  "### Review decision: FIX" (multiline) -> FIX
# =====================================================================
$d02 = New-M08Case "d02-fix-h3"
$body2 = "### Review decision: FIX`n`nAcceptance criterion 3 (reachability) is not met: SubprojectsPage.tsx cannot open an actual Subproject.`nThe backend already persists Subprojects, so this is an achievable in-scope client gap.`n`nBlocking findings: 1`nNon-blocking observations: 1`n"
$o_D02 = Invoke-Backend "M08" @{ DB08_STATE_DIR = $d02.State; DB08_TASKS_DIR = $d02.Tasks; DB08_REVIEW_TEXT = $body2 }
Check "D02" "multiline text '### Review decision: FIX' records FIX (CLAUDE_RESULT_RECORDED)" `
    ((Get-Marker $o_D02 "DB08_OUTCOME") -eq "CLAUDE_RESULT_RECORDED") ("outcome=" + (Get-Marker $o_D02 "DB08_OUTCOME"))
$recD02 = Read-Json (Join-Path $d02.State "claude-review.json")
Check "D02" "persisted decision FIX + dbM09Required true" `
    ($recD02.decision -eq "FIX" -and $recD02.dbM09Required -eq $true) ("decision=" + $recD02.decision)
Check "D02" "verbatim multiline review text preserved in the record" `
    ($recD02.reviewText.Contains("### Review decision: FIX") -and $recD02.reviewText.Contains("in-scope client gap")) ("text len=" + $recD02.reviewText.Length)

# =====================================================================
# D03  "**Decision:** FIX" -> FIX
# =====================================================================
$d03 = New-M08Case "d03-fix-bold"
$o_D03 = Invoke-Backend "M08" @{ DB08_STATE_DIR = $d03.State; DB08_TASKS_DIR = $d03.Tasks; DB08_REVIEW_TEXT = "**Decision:** FIX - correct the current attempt" }
Check "D03" "text '**Decision:** FIX' records FIX" `
    ((Get-Marker $o_D03 "DB08_OUTCOME") -eq "CLAUDE_RESULT_RECORDED" -and (Read-Json (Join-Path $d03.State "claude-review.json")).decision -eq "FIX") `
    ("outcome=" + (Get-Marker $o_D03 "DB08_OUTCOME"))

# =====================================================================
# D04  "Decision: PASS" (TRIAL) -> CLAUDE_REVIEW_PASSED_TRIAL
# =====================================================================
$d04 = New-M08Case "d04-pass-trial"
$o_D04 = Invoke-Backend "M08" @{ DB08_STATE_DIR = $d04.State; DB08_TASKS_DIR = $d04.Tasks; DB08_REVIEW_TEXT = "Decision: PASS - all acceptance criteria are met." }
Check "D04" "text 'Decision: PASS' (TRIAL) records PASS and routes to CLAUDE_REVIEW_PASSED_TRIAL / TRIAL_CYCLE_SAFE_STOP" `
    ((Get-Marker $o_D04 "DB08_OUTCOME") -eq "CLAUDE_RESULT_RECORDED") ("outcome=" + (Get-Marker $o_D04 "DB08_OUTCOME"))
$recD04 = Read-Json (Join-Path $d04.State "claude-review.json")
$ctD04 = Read-Json (Join-Path $d04.State "current-task.json")
Check "D04" "persisted PASS + CLAUDE_REVIEW_PASSED_TRIAL / TRIAL_CYCLE_SAFE_STOP + dbM09Required false" `
    ($recD04.decision -eq "PASS" -and $recD04.dbM09Required -eq $false -and $recD04.routeLifecycleState -eq "CLAUDE_REVIEW_PASSED_TRIAL" -and $ctD04.status -eq "CLAUDE_REVIEW_PASSED_TRIAL" -and $ctD04.nextAllowedAction -eq "TRIAL_CYCLE_SAFE_STOP") `
    ("decision=" + $recD04.decision + " status=" + $ctD04.status)

# =====================================================================
# D05  "Review decision: GOVERNANCE_ISSUE" -> GOVERNANCE_ISSUE route
# =====================================================================
$d05 = New-M08Case "d05-governance"
$o_D05 = Invoke-Backend "M08" @{ DB08_STATE_DIR = $d05.State; DB08_TASKS_DIR = $d05.Tasks; DB08_REVIEW_TEXT = "Review decision: GOVERNANCE_ISSUE - roadmap boundary concern." }
Check "D05" "text 'Review decision: GOVERNANCE_ISSUE' records GOVERNANCE_ISSUE + governance route" `
    ((Get-Marker $o_D05 "DB08_OUTCOME") -eq "CLAUDE_RESULT_RECORDED" -and (Get-Marker $o_D05 "DB08_REQUIRES_HUMAN_ACTION") -eq "True") ("outcome=" + (Get-Marker $o_D05 "DB08_OUTCOME"))
$recD05 = Read-Json (Join-Path $d05.State "claude-review.json")
$ctD05 = Read-Json (Join-Path $d05.State "current-task.json")
Check "D05" "persisted GOVERNANCE_ISSUE / HUMAN_GOVERNANCE_REVIEW route" `
    ($recD05.decision -eq "GOVERNANCE_ISSUE" -and $recD05.routeLifecycleState -eq "GOVERNANCE_ISSUE" -and $ctD05.status -eq "GOVERNANCE_ISSUE" -and $ctD05.nextAllowedAction -eq "HUMAN_GOVERNANCE_REVIEW") `
    ("decision=" + $recD05.decision + " status=" + $ctD05.status)

# =====================================================================
# D06  "Decision: HUMAN_DECISION_REQUIRED" -> HUMAN_DECISION_REQUIRED route
# =====================================================================
$d06 = New-M08Case "d06-human"
$o_D06 = Invoke-Backend "M08" @{ DB08_STATE_DIR = $d06.State; DB08_TASKS_DIR = $d06.Tasks; DB08_REVIEW_TEXT = "Decision: HUMAN_DECISION_REQUIRED - a human must decide." }
Check "D06" "text 'Decision: HUMAN_DECISION_REQUIRED' records HUMAN_DECISION_REQUIRED + human route" `
    ((Get-Marker $o_D06 "DB08_OUTCOME") -eq "CLAUDE_RESULT_RECORDED" -and (Get-Marker $o_D06 "DB08_REQUIRES_HUMAN_ACTION") -eq "True") ("outcome=" + (Get-Marker $o_D06 "DB08_OUTCOME"))
$ctD06 = Read-Json (Join-Path $d06.State "current-task.json")
Check "D06" "persisted HUMAN_DECISION_REQUIRED / HUMAN_DECISION route" `
    ($ctD06.status -eq "HUMAN_DECISION_REQUIRED" -and $ctD06.nextAllowedAction -eq "HUMAN_DECISION") ("status=" + $ctD06.status)

# =====================================================================
# D07  no explicit decision field -> CLAUDE_RESULT_DECISION_NOT_PARSEABLE
# =====================================================================
$d07 = New-M08Case "d07-notparseable"
$o_D07 = Invoke-Backend "M08" @{ DB08_STATE_DIR = $d07.State; DB08_TASKS_DIR = $d07.Tasks; DB08_REVIEW_TEXT = "All acceptance criteria are satisfied. No issues found." }
Check "D07" "review text with NO explicit decision field is rejected with CLAUDE_RESULT_DECISION_NOT_PARSEABLE + pass False" `
    ((Get-Marker $o_D07 "DB08_OUTCOME") -eq "CLAUDE_RESULT_DECISION_NOT_PARSEABLE" -and (Get-Marker $o_D07 "DB08_RESULT_PASS") -eq "False") `
    ("outcome=" + (Get-Marker $o_D07 "DB08_OUTCOME") + " pass=" + (Get-Marker $o_D07 "DB08_RESULT_PASS"))
$recD07 = Read-Json (Join-Path $d07.State "claude-review.json")
$md07 = Test-Path -LiteralPath (Join-Path $d07.Tasks "CLAUDE_REVIEW_RESULT.md")
$ctD07 = Read-Json (Join-Path $d07.State "current-task.json")
Check "D07" "NOT_PARSEABLE persists nothing and does not advance the lifecycle" `
    (($null -eq $recD07) -and (-not $md07) -and $ctD07.status -eq "VERIFIED" -and (-not ($ctD07.PSObject.Properties.Name -contains "dbM08"))) `
    ("rec=" + ($null -ne $recD07) + " md=" + $md07 + " status=" + $ctD07.status)

# =====================================================================
# D08  conflicting PASS + FIX -> CLAUDE_RESULT_DECISION_AMBIGUOUS
# =====================================================================
$d08 = New-M08Case "d08-ambiguous"
$o_D08 = Invoke-Backend "M08" @{ DB08_STATE_DIR = $d08.State; DB08_TASKS_DIR = $d08.Tasks; DB08_REVIEW_TEXT = "Decision: PASS`nDecision: FIX" }
Check "D08" "conflicting explicit decisions are rejected with CLAUDE_RESULT_DECISION_AMBIGUOUS + pass False" `
    ((Get-Marker $o_D08 "DB08_OUTCOME") -eq "CLAUDE_RESULT_DECISION_AMBIGUOUS" -and (Get-Marker $o_D08 "DB08_RESULT_PASS") -eq "False") `
    ("outcome=" + (Get-Marker $o_D08 "DB08_OUTCOME") + " pass=" + (Get-Marker $o_D08 "DB08_RESULT_PASS"))
$recD08 = Read-Json (Join-Path $d08.State "claude-review.json")
$ctD08 = Read-Json (Join-Path $d08.State "current-task.json")
Check "D08" "AMBIGUOUS persists nothing and does not advance the lifecycle" `
    (($null -eq $recD08) -and $ctD08.status -eq "VERIFIED" -and (-not ($ctD08.PSObject.Properties.Name -contains "dbM08"))) ("status=" + $ctD08.status)

# =====================================================================
# D09  wrong Node -> CLAUDE_RESULT_IDENTITY_MISMATCH (still enforced before parse)
# =====================================================================
$d09 = New-M08Case "d09-badnode"
$o_D09 = Invoke-Backend "M08" @{ DB08_STATE_DIR = $d09.State; DB08_TASKS_DIR = $d09.Tasks; DB08_NODE_ID = $script:OLD_NODE; DB08_CHANGE_ID = $script:CHANGE; DB08_REVIEW_TEXT = "Decision: FIX" }
Check "D09" "a FIX result for the WRONG node is rejected with CLAUDE_RESULT_IDENTITY_MISMATCH (never recorded for current cycle)" `
    ((Get-Marker $o_D09 "DB08_OUTCOME") -eq "CLAUDE_RESULT_IDENTITY_MISMATCH" -and (Get-Marker $o_D09 "DB08_RESULT_PASS") -eq "False") `
    ("outcome=" + (Get-Marker $o_D09 "DB08_OUTCOME"))
$recD09 = Read-Json (Join-Path $d09.State "claude-review.json")
Check "D09" "the rejected historical-node FIX is NOT recorded" `
    ($null -eq $recD09) ("rec=" + ($null -ne $recD09))

# =====================================================================
# D10  wrong Change -> CLAUDE_RESULT_IDENTITY_MISMATCH
# =====================================================================
$d10 = New-M08Case "d10-badchange"
$o_D10 = Invoke-Backend "M08" @{ DB08_STATE_DIR = $d10.State; DB08_TASKS_DIR = $d10.Tasks; DB08_NODE_ID = $script:NODE; DB08_CHANGE_ID = $script:OLD_CHANGE; DB08_REVIEW_TEXT = "Decision: FIX" }
Check "D10" "a FIX result for the WRONG change is rejected with CLAUDE_RESULT_IDENTITY_MISMATCH (never recorded for current cycle)" `
    ((Get-Marker $o_D10 "DB08_OUTCOME") -eq "CLAUDE_RESULT_IDENTITY_MISMATCH" -and (Get-Marker $o_D10 "DB08_RESULT_PASS") -eq "False") `
    ("outcome=" + (Get-Marker $o_D10 "DB08_OUTCOME"))
$recD10 = Read-Json (Join-Path $d10.State "claude-review.json")
Check "D10" "the rejected historical-change FIX is NOT recorded" `
    ($null -eq $recD10) ("rec=" + ($null -ne $recD10))

# =====================================================================
# D11  supplied PASS but text has NO decision -> NOT_PARSEABLE (no silent PASS)
# =====================================================================
$d11 = New-M08Case "d11-nosilentpass"
$o_D11 = Invoke-Backend "M08" @{ DB08_STATE_DIR = $d11.State; DB08_TASKS_DIR = $d11.Tasks; DB08_DECISION = "PASS"; DB08_REVIEW_TEXT = "Looks fine; nothing to change." }
Check "D11" "supplied PASS with NO explicit text decision is rejected with CLAUDE_RESULT_DECISION_NOT_PARSEABLE (PASS never silently defaulted)" `
    ((Get-Marker $o_D11 "DB08_OUTCOME") -eq "CLAUDE_RESULT_DECISION_NOT_PARSEABLE" -and (Get-Marker $o_D11 "DB08_RESULT_PASS") -eq "False") `
    ("outcome=" + (Get-Marker $o_D11 "DB08_OUTCOME") + " pass=" + (Get-Marker $o_D11 "DB08_RESULT_PASS"))
$recD11 = Read-Json (Join-Path $d11.State "claude-review.json")
$ctD11 = Read-Json (Join-Path $d11.State "current-task.json")
Check "D11" "NOT_PARSEABLE persists nothing (no PASS record) and does not advance the lifecycle" `
    (($null -eq $recD11) -and $ctD11.status -eq "VERIFIED" -and (-not ($ctD11.PSObject.Properties.Name -contains "dbM08"))) ("status=" + $ctD11.status)

# =====================================================================
# D12  supplied PASS but text says FIX -> FIX recorded (text-authoritative override)
# =====================================================================
$d12 = New-M08Case "d12-override"
$o_D12 = Invoke-Backend "M08" @{ DB08_STATE_DIR = $d12.State; DB08_TASKS_DIR = $d12.Tasks; DB08_DECISION = "PASS"; DB08_REVIEW_TEXT = "Decision: FIX" }
Check "D12" "supplied PASS + text 'Decision: FIX' records FIX (the review text is authoritative), outcome CLAUDE_RESULT_RECORDED" `
    ((Get-Marker $o_D12 "DB08_OUTCOME") -eq "CLAUDE_RESULT_RECORDED" -and (Get-Marker $o_D12 "DB08_NOTE") -like "*differs from the review text*") `
    ("outcome=" + (Get-Marker $o_D12 "DB08_OUTCOME"))
$recD12 = Read-Json (Join-Path $d12.State "claude-review.json")
$ctD12 = Read-Json (Join-Path $d12.State "current-task.json")
Check "D12" "persisted decision is FIX (NOT PASS) with DB_M09_FIX_REQUIRED / CORRECT_CURRENT_ATTEMPT" `
    ($recD12.decision -eq "FIX" -and $ctD12.status -eq "DB_M09_FIX_REQUIRED" -and $ctD12.nextAllowedAction -eq "CORRECT_CURRENT_ATTEMPT") `
    ("decision=" + $recD12.decision + " status=" + $ctD12.status)

# =====================================================================
# D13  an erroneous PASS cycle is correctable to FIX by a re-record
#      (exact live repro: UI default PASS was recorded against a FIX review)
# =====================================================================
$d13 = New-M08Case "d13-correct-pass-to-fix"
$body13 = "Review decision: FIX`n`nQ A (acceptance criteria): Mostly satisfied but criterion 3 is not fully met: SubprojectsPage.tsx has no way to open an actual Subproject.`nThis decision is for the operator to record in DevBridge.`n`n---`nBlocking findings: 0`nNon-blocking observations: 0`n"
# Step 1: reproduce the erroneous recording (operator supplied PASS, text actually FIX).
$o13a = Invoke-Backend "M08" @{ DB08_STATE_DIR = $d13.State; DB08_TASKS_DIR = $d13.Tasks; DB08_DECISION = "PASS"; DB08_REVIEW_TEXT = $body13 }
$ct13a = Read-Json (Join-Path $d13.State "current-task.json")
Check "D13" "step 1 reproduces the erroneous cycle: hardened recorder already records FIX (not PASS) from this exact text" `
    ($ct13a.status -eq "DB_M09_FIX_REQUIRED" -and $ct13a.dbM08.decision -eq "FIX") `
    ("status=" + $ct13a.status + " decision=" + $ct13a.dbM08.decision)
# (The old buggy behaviour would have recorded PASS here; the hardened recorder
#  cannot be driven into the wrong state even with a PASS advisory.)
# Step 2: an already-wrong PASS record (as exists on the live cycle) is corrected
# by re-recording the SAME original evidence (text-authoritative, no advisory).
$pre13 = Read-Json (Join-Path $d13.State "claude-review.json")
$pre13.decision = "PASS"; $pre13.dbM09Required = $false
$pre13.routeLifecycleState = "CLAUDE_REVIEW_PASSED_TRIAL"; $pre13.routeNextAllowedAction = "TRIAL_CYCLE_SAFE_STOP"
Write-Json (Join-Path $d13.State "claude-review.json") $pre13
# Fabricate the erroneous current-task exactly as the live one reads: status
# CLAUDE_REVIEW_PASSED_TRIAL / TRIAL_CYCLE_SAFE_STOP but the M07 ready stamp +
# current manifest still in place (so the record-time current-manifest gate passes).
$readyCtD13 = Read-Json (Join-Path $base.State "current-task.json")
$ct13pre = @{
    nodeId = $script:NODE; changeId = $script:CHANGE; name = "Fixture navigation shell"
    status = "CLAUDE_REVIEW_PASSED_TRIAL"; nextAllowedAction = "TRIAL_CYCLE_SAFE_STOP"; mode = $script:MODE
    dbM07 = $readyCtD13.dbM07
    dbM08 = @{ result = "CLAUDE_RESULT_RECORDED"; decision = "PASS"; nodeId = $script:NODE; changeId = $script:CHANGE; routeLifecycleState = "CLAUDE_REVIEW_PASSED_TRIAL" }
}
Write-Json (Join-Path $d13.State "current-task.json") $ct13pre
Write-TextUtf8 (Join-Path $d13.Tasks "CLAUDE_REVIEW_RESULT.md") ("DecisionToken: PASS`nNode: " + $script:NODE + "`nChange: " + $script:CHANGE + "`n`n" + $body13)
$o13b = Invoke-Backend "M08" @{ DB08_STATE_DIR = $d13.State; DB08_TASKS_DIR = $d13.Tasks; DB08_REVIEW_TEXT = $body13 }
Check "D13" "step 2 re-record of the SAME original evidence corrects PASS -> FIX (CLAUDE_RESULT_RECORDED)" `
    ((Get-Marker $o13b "DB08_OUTCOME") -eq "CLAUDE_RESULT_RECORDED") ("outcome=" + (Get-Marker $o13b "DB08_OUTCOME"))
$rec13 = Read-Json (Join-Path $d13.State "claude-review.json")
$ct13 = Read-Json (Join-Path $d13.State "current-task.json")
Check "D13" "corrected cycle: decision FIX + dbM09Required true + DB_M09_FIX_REQUIRED / CORRECT_CURRENT_ATTEMPT" `
    ($rec13.decision -eq "FIX" -and $rec13.dbM09Required -eq $true -and $ct13.status -eq "DB_M09_FIX_REQUIRED" -and $ct13.nextAllowedAction -eq "CORRECT_CURRENT_ATTEMPT") `
    ("decision=" + $rec13.decision + " status=" + $ct13.status)
Check "D13" "corrected record preserves identity + manifest binding + original verbatim evidence" `
    ($rec13.nodeId -eq $script:NODE -and $rec13.changeId -eq $script:CHANGE -and $rec13.reviewedManifestId -eq $expectedId -and $rec13.reviewText -eq $body13) `
    ("node=" + $rec13.nodeId + " change=" + $rec13.changeId + " manifest=" + $rec13.reviewedManifestId)
$md13 = ""
if (Test-Path -LiteralPath (Join-Path $d13.Tasks "CLAUDE_REVIEW_RESULT.md")) { $md13 = [System.IO.File]::ReadAllText((Join-Path $d13.Tasks "CLAUDE_REVIEW_RESULT.md")) }
Check "D13" "CLAUDE_REVIEW_RESULT.md header corrected to DecisionToken: FIX with the verbatim body preserved" `
    ($md13.Contains("DecisionToken: FIX") -and $md13.Contains("criterion 3 is not fully met")) ("md len=" + $md13.Length)

# =====================================================================
# D14  Nexus source + workbook roadmap untouched by an M08 FIX record
# =====================================================================
function Get-RepoSnapshot([string]$repo) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($f in (Get-ChildItem -LiteralPath $repo -Recurse -File -Force | Where-Object { $_.FullName -notmatch '\\\.git\\' })) {
        $rel = $f.FullName.Substring($repo.Length).TrimStart('\')
        $parts.Add($rel)
    }
    $parts.Sort()
    return ($parts -join "|")
}
$d14 = New-M08Case "d14-source-untouched"
$snapBefore = Get-RepoSnapshot $d14.Repo
$headBefore = (Invoke-Git $d14.Repo @("rev-parse", "HEAD") | Select-Object -First 1)
$o_D14 = Invoke-Backend "M08" @{ DB08_STATE_DIR = $d14.State; DB08_TASKS_DIR = $d14.Tasks; DB08_REVIEW_TEXT = "Decision: FIX" }
Check "D14" "M08 FIX record declares DB08_NEXUS_SOURCE_MODIFIED False + DB08_WORKBOOK_MODIFIED False + DB08_GIT_MODIFIED False" `
    ((Get-Marker $o_D14 "DB08_NEXUS_SOURCE_MODIFIED") -eq "False" -and (Get-Marker $o_D14 "DB08_WORKBOOK_MODIFIED") -eq "False" -and (Get-Marker $o_D14 "DB08_GIT_MODIFIED") -eq "False") `
    ("nexus=" + (Get-Marker $o_D14 "DB08_NEXUS_SOURCE_MODIFIED") + " wb=" + (Get-Marker $o_D14 "DB08_WORKBOOK_MODIFIED") + " git=" + (Get-Marker $o_D14 "DB08_GIT_MODIFIED"))
$snapAfter = Get-RepoSnapshot $d14.Repo
$headAfter = (Invoke-Git $d14.Repo @("rev-parse", "HEAD") | Select-Object -First 1)
Check "D14" "fixture repo working tree + HEAD are byte-identical after the M08 FIX record (Nexus source untouched)" `
    ($snapBefore -eq $snapAfter -and $headBefore -eq $headAfter) ("head unchanged=" + ($headBefore -eq $headAfter))

# =====================================================================
# summary
# =====================================================================
Write-Output ""
Write-Output ("FOCUSED-TEST SUMMARY: passed=" + $script:PassCount + " failed=" + $script:FailCount)
if ($Keep) {
    Write-Output ("FOCUSED-TEST KEEP: fixture root " + $script:TestRoot)
} else {
    Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:FailCount -gt 0) { exit 1 }
exit 0
