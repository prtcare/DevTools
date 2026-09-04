# Test-ClaudeReviewManifestStage.ps1
#
# FOCUSED self-tests for the DB-M07 / COPY-FOR-CLAUDE / DB-M08 Claude-independent
# review stage (Request F: Claude is the independent READ-ONLY reviewer of the
# ACTUAL Nexus files on the computer).
#
# These tests drive the REAL backend scripts (New-ClaudeReviewPackage.ps1,
# Copy-ClaudeReviewManifest.ps1, Set-ClaudeReviewResult.ps1) against synthetic,
# throwaway workspaces + throwaway git repositories. They assert the consistency
# gate, the current-manifest COPY behaviour and the DB-M08 identity hardening
# without touching the real DevBridge state, the real Nexus repositories, the
# workbook, or the OS clipboard (copy is redirected to a test seam file).
#
# The 14 focused cases map 1:1 to the governing request:
#   T01 current review manifest identity
#   T02 stale task packet is never copied (COPY refusal)
#   T03 DB-M06 node/change identity mismatch -> NOT_READY
#   T04 current-task delta is the exact file list in the manifest
#   T05 actual (absolute) repository path rendering
#   T06 stale historical IDs cannot become the review subject (brief gate)
#   T07 COPY FOR CLAUDE copies the CURRENT manifest
#   T08 copy-time identity validation refuses a stale/historical manifest
#   T09 an invalid Claude result node is rejected (CLAUDE_RESULT_IDENTITY_MISMATCH)
#   T10 an invalid Claude result change is rejected
#   T11 allowed decisions are recorded (PASS -> CLAUDE_RESULT_RECORDED)
#   T12 review instructions are read-only
#   T13 Nexus source is not modified by any stage
#   T14 DB-M06 is not re-run (its commands are quoted, never executed)
#
# Usage:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File \
#             scripts\Test-ClaudeReviewManifestStage.ps1 [-Keep]
#
# ASCII-only source (PS 5.1 + BOM-safe). Exit code 0 == all checks green.
param([switch]$Keep)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ScriptsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Scripts = @{
    M07  = Join-Path $script:ScriptsDir "New-ClaudeReviewPackage.ps1"
    Copy = Join-Path $script:ScriptsDir "Copy-ClaudeReviewManifest.ps1"
    M08  = Join-Path $script:ScriptsDir "Set-ClaudeReviewResult.ps1"
}
foreach ($s in $script:Scripts.Values) {
    if (-not (Test-Path -LiteralPath $s)) { Write-Output ("FATAL: missing backend script " + $s); exit 2 }
}

$script:NODE = "WI-12-0.4.1"
$script:CHANGE = "CHG-20260903-001"
$script:VERIFIED_AT = "2026-09-04T10:00:00Z"
$script:OLD_NODE = "WI-07-0.2.3"
$script:OLD_CHANGE = "CHG-20260830-016"

$script:PassCount = 0
$script:FailCount = 0
$script:TestRoot = Join-Path $env:TEMP ("DevBridgeCrm-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

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
    # current-task delta (untracked, inside the reserved project)
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
TRIAL

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
        status = "VERIFIED"; nextAllowedAction = "CLAUDE_REVIEW"; mode = "TRIAL"
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
        $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Scripts[$which])
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

# ---- build a GOOD (pre-create) fixture for the shared create/copy assertions ----
$good = New-GoodFixture (Join-Path $script:TestRoot "good") $script:NODE $script:CHANGE $script:VERIFIED_AT

# =====================================================================
# T01 current review manifest identity
# =====================================================================
$o1 = Invoke-Backend "M07" @{ DB07_STATE_DIR = $good.State; DB07_TASKS_DIR = $good.Tasks }
$t1 = Get-Marker $o1 "DB07_OUTCOME"
Check "T01" "DB-M07 creates the current manifest (CLAUDE_REVIEW_PACKAGE_CREATED)" `
    ($t1 -eq "CLAUDE_REVIEW_PACKAGE_CREATED") ("outcome=" + $t1)
$manifestPath = Join-Path $good.Tasks "CLAUDE_REVIEW_PACKAGE.md"
$manifest = ""
if (Test-Path -LiteralPath $manifestPath) { $manifest = [System.IO.File]::ReadAllText($manifestPath) }
$expectedId = "DB07-MANIFEST|" + $script:CHANGE + "|" + $script:NODE + "|" + $script:VERIFIED_AT
Check "T01" "manifest carries current identity lines + deterministic Manifest ID" `
    ($manifest.Contains("# Claude Review Manifest") -and $manifest.Contains(("Node: " + $script:NODE)) -and $manifest.Contains(("Change: " + $script:CHANGE)) -and $manifest.Contains(("Manifest ID: " + $expectedId))) `
    ("manifest len=" + $manifest.Length + "; expectedId=" + $expectedId)
$ct1 = Read-Json (Join-Path $good.State "current-task.json")
Check "T01" "current-task dbM07 ready=True result=CLAUDE_REVIEW_MANIFEST_CREATED with manifestId" `
    ($null -ne $ct1.dbM07 -and $ct1.dbM07.ready -eq $true -and $ct1.dbM07.result -eq "CLAUDE_REVIEW_MANIFEST_CREATED" -and $ct1.dbM07.manifestId -eq $expectedId) `
    ("dbM07=" + (($ct1.dbM07 | ConvertTo-Json -Compress)))

# =====================================================================
# T02 stale task packet is never copied (COPY refusal)
# =====================================================================
# (a) a leftover CLAUDE_REVIEW_PACKAGE.md with NO dbM07 ready stamp for the current
#     task must not be copyable - the source of COPY is never a stale packet.
$stale = New-GoodFixture (Join-Path $script:TestRoot "staleA") $script:NODE $script:CHANGE $script:VERIFIED_AT
$staleOldManifest = "# Claude Review Manifest`nNode: " + $script:OLD_NODE + "`nChange: " + $script:OLD_CHANGE + "`nManifest ID: DB07-MANIFEST|" + $script:OLD_CHANGE + "|" + $script:OLD_NODE + "|2020-01-01T00:00:00Z`n(old cycle packet)"
Write-TextUtf8 (Join-Path $stale.Tasks "CLAUDE_REVIEW_PACKAGE.md") $staleOldManifest
$targetA = Join-Path $stale.Base "copied-a.txt"
$o2a = Invoke-Backend "Copy" @{ DB07_STATE_DIR = $stale.State; DB07_TASKS_DIR = $stale.Tasks; DB07_COPY_TARGET_FILE = $targetA }
Check "T02a" "COPY refuses a stale packet (no ready dbM07 stamp) with NOT_READY + pass False" `
    ((Get-Marker $o2a "DB07_OUTCOME") -eq "CLAUDE_REVIEW_PACKAGE_NOT_READY" -and (Get-Marker $o2a "DB07_RESULT_PASS") -eq "False") `
    ((Get-Marker $o2a "DB07_OUTCOME") + " / " + (Get-Marker $o2a "DB07_RESULT_PASS"))
Check "T02a" "COPY did not emit COPIED FOR CLAUDE nor write any file for the stale packet" `
    ((Get-Marker $o2a "DB07_OUTCOME") -ne "CLAUDE_MANIFEST_COPIED" -and -not (Test-Path -LiteralPath $targetA)) `
    ("target written=" + (Test-Path -LiteralPath $targetA))

# (b) a ready dbM07 stamp that belongs to a DIFFERENT node/change is an identity
#     mismatch -> COPY refuses (historical manifest never the current source).
$staleB = New-GoodFixture (Join-Path $script:TestRoot "staleB") $script:NODE $script:CHANGE $script:VERIFIED_AT
Write-TextUtf8 (Join-Path $staleB.Tasks "CLAUDE_REVIEW_PACKAGE.md") $staleOldManifest
$staleCt = @{
    nodeId = $script:NODE; changeId = $script:CHANGE; name = "Fixture"
    dbM07 = @{ ready = $true; result = "CLAUDE_REVIEW_MANIFEST_CREATED"; manifestId = "DB07-MANIFEST|" + $script:OLD_CHANGE + "|" + $script:OLD_NODE + "|2020-01-01T00:00:00Z"; nodeId = $script:OLD_NODE; changeId = $script:OLD_CHANGE }
}
Write-Json (Join-Path $staleB.State "current-task.json") $staleCt
$targetB = Join-Path $staleB.Base "copied-b.txt"
$o2b = Invoke-Backend "Copy" @{ DB07_STATE_DIR = $staleB.State; DB07_TASKS_DIR = $staleB.Tasks; DB07_COPY_TARGET_FILE = $targetB }
Check "T02b" "COPY refuses when the ready dbM07 stamp identity mismatches the current task" `
    ((Get-Marker $o2b "DB07_OUTCOME") -eq "CLAUDE_REVIEW_PACKAGE_NOT_READY" -and (Get-Marker $o2b "DB07_RESULT_PASS") -eq "False" -and -not (Test-Path -LiteralPath $targetB)) `
    ((Get-Marker $o2b "DB07_OUTCOME") + " / target=" + (Test-Path -LiteralPath $targetB))

# =====================================================================
# T03 DB-M06 node/change identity mismatch -> NOT_READY
# =====================================================================
$badM06 = New-GoodFixture (Join-Path $script:TestRoot "badm06") $script:NODE $script:CHANGE $script:VERIFIED_AT
$verifBad = @{
    milestone = "DB-M06"; nodeId = $script:OLD_NODE; changeId = $script:OLD_CHANGE
    primaryResult = "VERIFICATION_PASSED"; verifiedAtUtc = "2020-01-01T00:00:00Z"
    commands = @("> npm run build")
}
Write-Json (Join-Path $badM06.State "verification.json") $verifBad
$o3 = Invoke-Backend "M07" @{ DB07_STATE_DIR = $badM06.State; DB07_TASKS_DIR = $badM06.Tasks }
$joined3 = ($o3 -join "`n")
Check "T03" "DB-M06 evidence from another node/change -> CLAUDE_REVIEW_PACKAGE_NOT_READY" `
    ((Get-Marker $o3 "DB07_OUTCOME") -eq "CLAUDE_REVIEW_PACKAGE_NOT_READY" -and (Get-Marker $o3 "DB07_RESULT_PASS") -eq "False") `
    ((Get-Marker $o3 "DB07_OUTCOME") + " / " + (Get-Marker $o3 "DB07_RESULT_PASS"))
Check "T03" "reason names the DB-M06 identity mismatch" `
    ($joined3.Contains("DB-M06 verification belongs to " + $script:OLD_NODE)) `
    $joined3
$ct3 = Read-Json (Join-Path $badM06.State "current-task.json")
Check "T03" "NOT_READY stamped in current-task dbM07 (ready=False)" `
    ($null -ne $ct3.dbM07 -and $ct3.dbM07.ready -eq $false -and $ct3.dbM07.result -eq "CLAUDE_REVIEW_PACKAGE_NOT_READY") `
    ("dbM07=" + (($ct3.dbM07 | ConvertTo-Json -Compress)))

# =====================================================================
# T04 current-task delta is the exact file list in the manifest
# =====================================================================
Check "T04" "manifest section 5 lists the exact CURRENT_TASK_DELTA file (repo-relative, in scope)" `
    ($manifest.Contains("## 5. Current-task delta (exact file list from the DB-M06/baseline evidence)") -and $manifest.Contains("- CURRENT_TASK_DELTA files (review each of these):") -and $manifest.Contains("src/FooProj/Delta.txt") -and -not $manifest.Contains("- CURRENT_TASK_DELTA files: NONE")) `
    ("manifest contains Delta.txt=" + $manifest.Contains("src/FooProj/Delta.txt"))
Check "T04" "delta classification is DELTA_CLASSIFICATION_PASS and README is NOT in the delta" `
    ($manifest.Contains("- Classification: DELTA_CLASSIFICATION_PASS") -and -not $manifest.Contains("README.md | CURRENT_TASK_DELTA")) `
    "README must stay out of the current-task delta"

# =====================================================================
# T05 actual (absolute) repository path rendering
# =====================================================================
$repoAbsGood = (Resolve-Path -LiteralPath $good.Repo).Path
Check "T05" "manifest section 4 renders the ABSOLUTE repository root" `
    ($manifest.Contains(("Root: " + $repoAbsGood))) `
    ("expected absolute root " + $repoAbsGood)
Check "T05" "manifest section 5 header carries the repo label + absolute root and lists the reserved project" `
    ($manifest.Contains(("### repoA (" + $repoAbsGood + ")")) -and $manifest.Contains("Reserved project(s): FooProj")) `
    "repo section render"

# =====================================================================
# T06 stale historical IDs cannot become the review subject (brief gate)
# =====================================================================
$badBrief = New-GoodFixture (Join-Path $script:TestRoot "badbrief") $script:NODE $script:CHANGE $script:VERIFIED_AT
Write-TextUtf8 (Join-Path $badBrief.Tasks "DEEPSEEK_PROMPT.md") (Build-Brief $script:OLD_NODE $script:OLD_CHANGE)
$o6 = Invoke-Backend "M07" @{ DB07_STATE_DIR = $badBrief.State; DB07_TASKS_DIR = $badBrief.Tasks }
$joined6 = ($o6 -join "`n")
Check "T06" "a historical governed brief (old Node/Change) -> NOT_READY" `
    ((Get-Marker $o6 "DB07_OUTCOME") -eq "CLAUDE_REVIEW_PACKAGE_NOT_READY" -and (Get-Marker $o6 "DB07_RESULT_PASS") -eq "False") `
    ((Get-Marker $o6 "DB07_OUTCOME") + " / " + (Get-Marker $o6 "DB07_RESULT_PASS"))
Check "T06" "reason says the brief node/change != current (historical must not become review subject)" `
    ($joined6.Contains("Governed brief node " + $script:OLD_NODE + " != current node " + $script:NODE)) `
    $joined6

# =====================================================================
# T07 COPY FOR CLAUDE copies the CURRENT manifest
# =====================================================================
$target7 = Join-Path $good.Base "copied-current.txt"
$o7 = Invoke-Backend "Copy" @{ DB07_STATE_DIR = $good.State; DB07_TASKS_DIR = $good.Tasks; DB07_COPY_TARGET_FILE = $target7 }
Check "T07" "COPY FOR CLAUDE reports CLAUDE_MANIFEST_COPIED + visible confirmation" `
    ((Get-Marker $o7 "DB07_OUTCOME") -eq "CLAUDE_MANIFEST_COPIED" -and (Get-Marker $o7 "DB07_RESULT_PASS") -eq "True" -and ($o7 -contains "COPIED FOR CLAUDE")) `
    ((Get-Marker $o7 "DB07_OUTCOME") + " / " + (Get-Marker $o7 "DB07_RESULT_PASS"))
$copied7 = ""
if (Test-Path -LiteralPath $target7) { $copied7 = [System.IO.File]::ReadAllText($target7) }
Check "T07" "the copied text IS the current manifest (exact bytes of tasks/CLAUDE_REVIEW_PACKAGE.md)" `
    ($copied7 -eq $manifest) `
    ("copied len=" + $copied7.Length + " manifest len=" + $manifest.Length)

# =====================================================================
# T08 copy-time identity validation refuses a stale/historical manifest
# =====================================================================
# A manifest file whose identity lines do NOT match the current task must be
# refused at COPY time even if a ready dbM07 stamp exists with matching ids but
# the FILE is stale. Simulate by keeping the ready stamp but swapping the file to
# the historical packet -> Test-CrmManifestCurrent detects id mismatch.
$staleC = New-GoodFixture (Join-Path $script:TestRoot "staleC") $script:NODE $script:CHANGE $script:VERIFIED_AT
# first produce a valid manifest, then overwrite it with a stale historical one
$null = Invoke-Backend "M07" @{ DB07_STATE_DIR = $staleC.State; DB07_TASKS_DIR = $staleC.Tasks }
Write-TextUtf8 (Join-Path $staleC.Tasks "CLAUDE_REVIEW_PACKAGE.md") $staleOldManifest
$targetC = Join-Path $staleC.Base "copied-c.txt"
$o8 = Invoke-Backend "Copy" @{ DB07_STATE_DIR = $staleC.State; DB07_TASKS_DIR = $staleC.Tasks; DB07_COPY_TARGET_FILE = $targetC }
Check "T08" "copy-time identity validation refuses a manifest whose identity lines are stale/historical" `
    ((Get-Marker $o8 "DB07_OUTCOME") -eq "CLAUDE_REVIEW_PACKAGE_NOT_READY" -and (Get-Marker $o8 "DB07_RESULT_PASS") -eq "False" -and -not (Test-Path -LiteralPath $targetC)) `
    ((Get-Marker $o8 "DB07_OUTCOME") + " / target=" + (Test-Path -LiteralPath $targetC))

# =====================================================================
# helpers for DB-M08 tests: a fresh POST-CREATE copy (manifest + ready stamp)
# =====================================================================
function New-PostCreateCopy([string]$label) {
    $c = Join-Path $script:TestRoot $label
    Copy-Dir $good.State (Join-Path $c "state")
    Copy-Dir $good.Tasks (Join-Path $c "tasks")
    return [pscustomobject]@{ State = Join-Path $c "state"; Tasks = Join-Path $c "tasks" }
}

# =====================================================================
# T09 an invalid Claude result node is rejected
# =====================================================================
$c9 = New-PostCreateCopy "m08-badnode"
$o9 = Invoke-Backend "M08" @{ DB08_STATE_DIR = $c9.State; DB08_TASKS_DIR = $c9.Tasks; DB08_NODE_ID = $script:OLD_NODE; DB08_CHANGE_ID = $script:CHANGE; DB08_DECISION = "PASS"; DB08_REVIEW_TEXT = "old review node" }
Check "T09" "a Claude result for the WRONG node is rejected with CLAUDE_RESULT_IDENTITY_MISMATCH" `
    ((Get-Marker $o9 "DB08_OUTCOME") -eq "CLAUDE_RESULT_IDENTITY_MISMATCH" -and (Get-Marker $o9 "DB08_RESULT_PASS") -eq "False") `
    ((Get-Marker $o9 "DB08_OUTCOME") + " / " + (Get-Marker $o9 "DB08_RESULT_PASS"))
Check "T09" "the rejected (historical WI-07) result is NOT recorded and state is unchanged" `
    (-not (Test-Path -LiteralPath (Join-Path $c9.State "claude-review.json")) -and -not (Test-Path -LiteralPath (Join-Path $c9.Tasks "CLAUDE_REVIEW_RESULT.md"))) `
    "no record files"

# =====================================================================
# T10 an invalid Claude result change is rejected
# =====================================================================
$c10 = New-PostCreateCopy "m08-badchange"
$o10 = Invoke-Backend "M08" @{ DB08_STATE_DIR = $c10.State; DB08_TASKS_DIR = $c10.Tasks; DB08_NODE_ID = $script:NODE; DB08_CHANGE_ID = $script:OLD_CHANGE; DB08_DECISION = "PASS"; DB08_REVIEW_TEXT = "old review change" }
Check "T10" "a Claude result for the WRONG change is rejected with CLAUDE_RESULT_IDENTITY_MISMATCH" `
    ((Get-Marker $o10 "DB08_OUTCOME") -eq "CLAUDE_RESULT_IDENTITY_MISMATCH" -and (Get-Marker $o10 "DB08_RESULT_PASS") -eq "False") `
    ((Get-Marker $o10 "DB08_OUTCOME") + " / " + (Get-Marker $o10 "DB08_RESULT_PASS"))
Check "T10" "the rejected (historical WI-07/016) result is NOT recorded" `
    (-not (Test-Path -LiteralPath (Join-Path $c10.State "claude-review.json"))) `
    "no claude-review.json"

# =====================================================================
# T11 allowed decisions are recorded (PASS -> CLAUDE_RESULT_RECORDED)
# =====================================================================
$c11 = New-PostCreateCopy "m08-good-pass"
$o11 = Invoke-Backend "M08" @{ DB08_STATE_DIR = $c11.State; DB08_TASKS_DIR = $c11.Tasks; DB08_DECISION = "PASS"; DB08_REVIEW_TEXT = "Review decision: PASS - all acceptance criteria met" }
Check "T11" "a valid PASS for the CURRENT node/change is recorded (CLAUDE_RESULT_RECORDED)" `
    ((Get-Marker $o11 "DB08_OUTCOME") -eq "CLAUDE_RESULT_RECORDED" -and (Get-Marker $o11 "DB08_RESULT_PASS") -eq "True") `
    ((Get-Marker $o11 "DB08_OUTCOME") + " / " + (Get-Marker $o11 "DB08_RESULT_PASS"))
$rec = Read-Json (Join-Path $c11.State "claude-review.json")
Check "T11" "record persists reviewed identity + current manifest id + DB-M06 evidence binding" `
    ($null -ne $rec -and $rec.reviewedNodeId -eq $script:NODE -and $rec.reviewedChangeId -eq $script:CHANGE -and $rec.reviewedManifestId -eq $expectedId -and $rec.reviewedAgainstDbM06 -eq $script:VERIFIED_AT -and $rec.decision -eq "PASS") `
    ("record=" + (($rec | ConvertTo-Json -Compress)))
$ct11 = Read-Json (Join-Path $c11.State "current-task.json")
Check "T11" "TRIAL PASS routes the cycle to CLAUDE_REVIEW_PASSED_TRIAL / TRIAL_CYCLE_SAFE_STOP with dbM08" `
    ($ct11.status -eq "CLAUDE_REVIEW_PASSED_TRIAL" -and $ct11.nextAllowedAction -eq "TRIAL_CYCLE_SAFE_STOP" -and $null -ne $ct11.dbM08 -and $ct11.dbM08.result -eq "CLAUDE_RESULT_RECORDED") `
    ("status=" + $ct11.status + " next=" + $ct11.nextAllowedAction)
$resMd = ""
if (Test-Path -LiteralPath (Join-Path $c11.Tasks "CLAUDE_REVIEW_RESULT.md")) { $resMd = [System.IO.File]::ReadAllText((Join-Path $c11.Tasks "CLAUDE_REVIEW_RESULT.md")) }
Check "T11" "CLAUDE_REVIEW_RESULT.md records DecisionToken + identity + Manifest ID + verbatim text" `
    ($resMd.Contains("DecisionToken: PASS") -and $resMd.Contains(("Node: " + $script:NODE)) -and $resMd.Contains(("Change: " + $script:CHANGE)) -and $resMd.Contains(("Manifest ID: " + $expectedId)) -and $resMd.Contains("all acceptance criteria met")) `
    ("result md len=" + $resMd.Length)

# =====================================================================
# T12 review instructions are read-only
# =====================================================================
Check "T12" "manifest contains the read-only file-review instructions + forbidden-mutation text" `
    ($manifest.Contains("## 8. File review instructions - review the ACTUAL files (read-only)") -and $manifest.Contains("Review must be READ-ONLY") -and $manifest.Contains("You MUST NOT modify, create, stage, commit, push, revert, or clean any file")) `
    "read-only instructions present"
Check "T12" "manifest carries review questions A-I and the required decision vocabulary" `
    ($manifest.Contains("## 9. Review questions") -and $manifest.Contains("A. Are all current acceptance criteria") -and $manifest.Contains("I. Are there material security / maintainability / correctness issues in the delta?") -and $manifest.Contains("## 10. Required review decision") -and $manifest.Contains("- PASS") -and $manifest.Contains("- FIX") -and $manifest.Contains("- GOVERNANCE_ISSUE") -and $manifest.Contains("- HUMAN_DECISION_REQUIRED")) `
    "questions + decision vocabulary"
Check "T12" "manifest governance header items 1-9 are present" `
    ($manifest.Contains("### 1. Temporary boundary") -and $manifest.Contains("### 9. Decision vocabulary")) `
    "governance header"

# =====================================================================
# T13 Nexus source is not modified by any stage
# =====================================================================
$good13 = New-GoodFixture (Join-Path $script:TestRoot "nosrc") $script:NODE $script:CHANGE $script:VERIFIED_AT
function Get-RepoSnapshot([string]$repo) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($f in (Get-ChildItem -LiteralPath $repo -Recurse -File -Force | Where-Object { $_.FullName -notmatch '\\\.git\\' })) {
        $rel = $f.FullName.Substring($repo.Length).TrimStart('\')
        $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        $parts.Add($rel + "=" + $hash)
    }
    $s = $parts | Sort-Object
    $porcelain = @(Invoke-Git $repo @("status", "--porcelain=v1") | Sort-Object)
    return [pscustomobject]@{ Snapshot = ($s -join "|"); Porcelain = ($porcelain -join "|"); Head = (([string](Invoke-Git $repo @("rev-parse", "HEAD") | Select-Object -First 1)).Trim()) }
}
$snapBefore = Get-RepoSnapshot $good13.Repo
$target13 = Join-Path $good13.Base "copied.txt"
$null = Invoke-Backend "M07" @{ DB07_STATE_DIR = $good13.State; DB07_TASKS_DIR = $good13.Tasks }
$null = Invoke-Backend "Copy" @{ DB07_STATE_DIR = $good13.State; DB07_TASKS_DIR = $good13.Tasks; DB07_COPY_TARGET_FILE = $target13 }
$null = Invoke-Backend "M08" @{ DB08_STATE_DIR = $good13.State; DB08_TASKS_DIR = $good13.Tasks; DB08_DECISION = "PASS"; DB08_REVIEW_TEXT = "Decision: PASS. ok" }
$snapAfter = Get-RepoSnapshot $good13.Repo
Check "T13" "DB-M07 + COPY + DB-M08 leave the reserved repository working tree byte-for-byte unchanged" `
    ($snapAfter.Snapshot -eq $snapBefore.Snapshot -and $snapAfter.Head -eq $snapBefore.Head) `
    ("before head=" + $snapBefore.Head + " after head=" + $snapAfter.Head)
Check "T13" "git status porcelain is identical (no new tracked/untracked mutations by the stages)" `
    ($snapAfter.Porcelain -eq $snapBefore.Porcelain) `
    ("before=[" + $snapBefore.Porcelain + "] after=[" + $snapAfter.Porcelain + "]")

# =====================================================================
# T14 DB-M06 is not re-run (its commands are quoted in evidence, never executed)
# =====================================================================
$good14 = New-GoodFixture (Join-Path $script:TestRoot "nom06") $script:NODE $script:CHANGE $script:VERIFIED_AT
$poison = Join-Path $good14.State "m06-poison.txt"
$poisonCmd = "> echo M06_POISON >> " + $poison
$verif14 = Read-Json (Join-Path $good14.State "verification.json")
$verif14.commands = @("(discovery) node.exe --version", $poisonCmd)
Write-Json (Join-Path $good14.State "verification.json") $verif14
$o14 = Invoke-Backend "M07" @{ DB07_STATE_DIR = $good14.State; DB07_TASKS_DIR = $good14.Tasks }
Check "T14" "DB-M07 completes with the manifest while NEVER executing the DB-M06 build/test commands" `
    ((Get-Marker $o14 "DB07_OUTCOME") -eq "CLAUDE_REVIEW_PACKAGE_CREATED" -and -not (Test-Path -LiteralPath $poison)) `
    ("outcome=" + (Get-Marker $o14 "DB07_OUTCOME") + " poison written=" + (Test-Path -LiteralPath $poison))
$m14 = ""
if (Test-Path -LiteralPath (Join-Path $good14.Tasks "CLAUDE_REVIEW_PACKAGE.md")) { $m14 = [System.IO.File]::ReadAllText((Join-Path $good14.Tasks "CLAUDE_REVIEW_PACKAGE.md")) }
Check "T14" "the DB-M06 command text appears ONLY as quoted evidence in the manifest" `
    ($m14.Contains("echo M06_POISON") -and $m14.Contains("## 7. DB-M06 verification evidence (quoted; NOT re-run)")) `
    "quoted evidence"

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
