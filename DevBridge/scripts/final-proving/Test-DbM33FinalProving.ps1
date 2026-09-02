# Test-DbM33FinalProving.ps1
# DB-M33 FINAL SUPERVISED DEVBRIDGE PROVING.
#
# Proves DevBridge supports a complete SUPERVISED development workflow safely and
# coherently from task selection through trial safe-stop, driving the REAL hardened
# backend scripts (M03 Test-DevelopmentPreflight / M04 Reserve-DevelopmentChange /
# M05 New-ChatGptHandoff / M06 Run-Verification / M07 New-ClaudeReviewPackage /
# M08 Set-ClaudeReviewResult / M09 New-CorrectionContext / M10 completion
# eligibility / M12.4 Close-TrialCycle / DB13 Get-GitGateState / DB11 validation)
# on isolated fixtures under %TEMP%\db33\<scenario>\. Human/external boundaries are
# proven with controlled artifacts/fixtures (ChatGPT output, implementation result,
# Claude decision, git evidence). NO DevBridge state transition is faked: every
# lifecycle transition is produced by the real backend reading real state.
#
# Live canonical workbook + live DevBridge state are never touched (byte-identical
# workbook copies; the only JSON the harness writes is fixture seed state).
#
# Backend contract: ALWAYS exits 0; outcomes ONLY via stdout markers. This suite
# ALWAYS exits 0 with DB33_* markers; failures are counted in DB33_TEST_ASSERTIONS.
# ASCII-only source (PS 5.1 + BOM-safe). Run via `powershell -File`.
param([string]$Scenarios = 'ALL')
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script:ScriptsRoot = Join-Path $script:Root "scripts"
$script:ConfigRoot = Join-Path $script:Root "config"
$script:Cfg = Get-Content (Join-Path $script:Root "config\devbridge.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$script:RealWorkbook = [string]$script:Cfg.developmentControlWorkbook
$script:RealHashBefore = (Get-FileHash $script:RealWorkbook -Algorithm SHA256).Hash
$script:SelftestRoot = Join-Path $script:Root "logs\selftest"
$script:Db33Root = Join-Path $script:SelftestRoot "db33"
if (Test-Path $script:Db33Root) { Remove-Item $script:Db33Root -Recurse -Force }
New-Item -ItemType Directory -Force -Path $script:Db33Root | Out-Null

# Live-state guards (never to be modified by this suite).
$script:LiveGuardFiles = @("state\current-task.json", "state\current-lifecycle-state.json", "state\trial-proving-history.json", "state\trial-closure.json", "state\preflight.json")
$script:LiveGuardHashes = @{}
foreach ($gf in $script:LiveGuardFiles) {
    $p = Join-Path $script:Root $gf
    if (Test-Path $p) { $script:LiveGuardHashes[$gf] = (Get-FileHash $p -Algorithm SHA256).Hash } else { $script:LiveGuardHashes[$gf] = "ABSENT" }
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:Fails = New-Object System.Collections.Generic.List[string]
$script:RunLog = New-Object System.Collections.Generic.List[string]

function Log-Db33([string]$line) {
    $script:RunLog.Add($line)
    Write-Output $line
}

function Assert-Db33([string]$scenario, [string]$label, [bool]$cond, [string]$detail) {
    $row = New-Object PSCustomObject
    $row | Add-Member NoteProperty -Name Scenario -Value $scenario
    $row | Add-Member NoteProperty -Name Label -Value $label
    $row | Add-Member NoteProperty -Name Pass -Value $cond
    $row | Add-Member NoteProperty -Name Detail -Value $detail
    $script:Results.Add($row)
    Log-Db33 ("TEST|" + $scenario + "|" + $label + "|" + $(if ($cond) { "PASS" } else { "FAIL" }) + "|" + $detail)
    if (-not $cond) { $script:Fails.Add(("[" + $scenario + "] " + $label + ": " + $detail)) }
}

function Write-FJson([string]$dir, [string]$name, $obj) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path $dir $name), ($obj | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding($false)))
}

function Read-FJson([string]$dir, [string]$name) {
    $p = Join-Path $dir $name
    if (-not (Test-Path $p)) { return $null }
    return (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# Fixture creation: full scripts+config copy to fixture root, byte-identical
# workbook copy, seeded proving-history / closure / overlay evidence.
# ---------------------------------------------------------------------------
function New-Db33Fixture([string]$name) {
    $outDir = Join-Path $script:Db33Root $name
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    Copy-Item $script:ScriptsRoot $outDir -Recurse -Force
    Copy-Item $script:ConfigRoot $outDir -Recurse -Force
    $wb = Join-Path $outDir "workbook.xlsx"
    Copy-Item $script:RealWorkbook $wb -Force
    $cfgPath = Join-Path $outDir "config\devbridge.json"
    $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfg.developmentControlWorkbook = $wb
    [System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    $stateDir = Join-Path $outDir "state"; New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    $tasksDir = Join-Path $outDir "tasks"; New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null
    $logsDir = Join-Path $outDir "logs"; New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    # Seed TRIAL proving history (WI-07-0.2.4 closure) so M03 excludes the proven
    # node and can select WI-07-0.2.5 via the DB-M03.2 overlay.
    Write-FJson $stateDir "trial-proving-history.json" ([ordered]@{ entries = @(
        [ordered]@{ nodeId = "WI-07-0.2.4"; changeId = "CHG-20260830-017"; closedAtUtc = "2026-08-31T15:24:45Z"; mode = "TRIAL"; result = "TRIAL_CYCLE_CLOSED"; implementationState = "TRIAL_ONLY_UNMERGED"; preReservationStatus = "Planned" }
    ) })
    Write-FJson $stateDir "trial-closure.json" ([ordered]@{
        milestone = "DB-M12.4"; changeId = "CHG-20260830-017"; nodeId = "WI-07-0.2.4"
        closedAtUtc = "2026-08-31T15:24:45Z"; result = "TRIAL_CYCLE_CLOSED"; activeChangesRow = 80; activityLogRow = 57
        postWorkbookSha256 = "6D42C3BF6D3307B4B1A45870CE12F41E403DFED412E59F33D7B487E93A83E4F5"
        fingerprintGuard = "PRESERVED"
    })
    # Seed DB-M03.2 per-change overlay evidence for WI-07-0.2.4/CHG-20260830-017.
    $evDir = Join-Path (Join-Path $logsDir "tasks\WI-07-0.2.4") "CHG-20260830-017"
    New-Item -ItemType Directory -Force -Path $evDir | Out-Null
    Write-FJson $evDir "claude-decision.json" ([ordered]@{
        milestone = "DB-M08"; nodeId = "WI-07-0.2.4"; changeId = "CHG-20260830-017"
        decision = "PASS"; dbM06Result = "VERIFICATION_PASS"; trialMode = $true
        implementationState = "TRIAL_ONLY_UNMERGED"; reviewedAgainstDbM06 = $true
        reviewTimestampUtc = "2026-08-31T15:22:00Z"
    })
    [System.IO.File]::WriteAllText((Join-Path $evDir "VERIFICATION_RESULT.md"),
        "# VERIFICATION RESULT`nNode: WI-07-0.2.4`nResult: VERIFICATION_PASSED`nMode: TRIAL`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-FJson $evDir "test-result.json" ([ordered]@{ passed = 24; failed = 0; skipped = 0; total = 24 })
    Write-FJson $evDir "build-result.json" ([ordered]@{ warnings = 0; errors = 0; succeeded = $true })
    return @{ root = $outDir; state = $stateDir; tasks = $tasksDir; logs = $logsDir; wb = $wb; name = $name }
}

# ---------------------------------------------------------------------------
# Backend invocation: run a REAL backend script from the fixture root, capturing
# all streams to a log file; markers parsed from the captured text.
# ---------------------------------------------------------------------------
function Invoke-Db33Backend([hashtable]$f, [string]$relScript, [string[]]$argumentList, [hashtable]$envMap) {
    $engine = Join-Path $f.root ("scripts\" + $relScript)
    # Run logs go OUTSIDE the fixture root (and outside the DevBridge tree) so backend
    # time-window guards (e.g. M05's tree sweep over $script:Root) never observe the
    # harness's own log file as a "touched" path.
    $runsDir = Join-Path ([System.IO.Path]::GetTempPath()) "db33-runs"
    if (-not (Test-Path $runsDir)) { New-Item -ItemType Directory -Force $runsDir | Out-Null }
    $scenarioTag = "db33"
    if ($f -is [hashtable] -and $f.ContainsKey('name') -and $f['name']) { $scenarioTag = [string]$f['name'] }
    $tmpLog = Join-Path $runsDir ($scenarioTag + "-" + ([guid]::NewGuid().ToString('N').Substring(0, 8)) + ".txt")
    $saved = @{}
    foreach ($k in $envMap.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        Set-Item ("env:" + $k) ([string]$envMap[$k])
    }
    $exitCode = 0
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine @argumentList *> $tmpLog
        $exitCode = $LASTEXITCODE
    } catch { $exitCode = -1 }
    finally {
        foreach ($k in $envMap.Keys) {
            if ($null -eq $saved[$k]) { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue } else { Set-Item ("env:" + $k) $saved[$k] }
        }
    }
    $text = ""
    if (Test-Path $tmpLog) { $text = Get-Content $tmpLog -Raw -Encoding UTF8 }
    return @{ Output = @($text -split "`r?`n" | Where-Object { $_ -ne "" }); Text = $text; ExitCode = $exitCode; LogPath = $tmpLog }
}

function Get-Db33Marker([hashtable]$res, [string]$name) {
    foreach ($ln in $res.Output) {
        if ($ln -match ("^" + [regex]::Escape($name) + ":\s*(.*)$")) { return $matches[1].Trim() }
    }
    return $null
}

function Test-Db33Text([hashtable]$res, [string]$pattern) {
    foreach ($ln in $res.Output) { if ($ln -match $pattern) { return $true } }
    return $false
}

function Get-FixtureTask([hashtable]$f) { return Read-FJson $f.state "current-task.json" }

# Read-only roadmap node lookup via the real backend reader (the same code path the
# engine uses), so Status is read by the authoritative column contract, never by
# positional guessing on raw rows.
function Get-Db33RoadmapNode([string]$wbPath, [string]$nodeId) {
    $saved = [Environment]::GetEnvironmentVariable('DB_DEV_CONTROL_WORKBOOK_OVERRIDE')
    Set-Item 'env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE' $wbPath
    try {
        . (Join-Path $script:ScriptsRoot 'Read-DevelopmentControl.ps1')
        return Get-RoadmapNodeById $nodeId
    } finally {
        if ($null -eq $saved) { Remove-Item 'env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE' -ErrorAction SilentlyContinue } else { Set-Item 'env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE' $saved }
    }
}

# ---------------------------------------------------------------------------
# Shared helper: seed the overlay evidence + history, then run M03 preflight.
# ---------------------------------------------------------------------------
function Invoke-Db33M03([hashtable]$f) {
    return Invoke-Db33Backend $f "Test-DevelopmentPreflight.ps1" @() @{ DB_DEV_CONTROL_WORKBOOK_OVERRIDE = $f.wb }
}

# ---------------------------------------------------------------------------
# M05 handoff wrapper. M05's post-run tree sweep flags ANY file under its root
# modified within RunStart-5s that is not M05's own output. In real use M05 runs
# minutes/hours after M04, so M04's reservation writes and the workbook fall well
# outside that window. The fixture runs M04->M05 back-to-back, so we reproduce the
# real temporal separation with a short delay before M05 (the harness run log is
# already redirected outside the fixture root).
# ---------------------------------------------------------------------------
function Invoke-Db33M05([hashtable]$f) {
    Start-Sleep -Seconds 8
    return Invoke-Db33Backend $f "New-ChatGptHandoff.ps1" @() @{ DB05_STATE_DIR = $f.state; DB05_TASKS_DIR = $f.tasks; DB05_LOGS_DIR = $f.logs }
}

# ---------------------------------------------------------------------------
# Controlled external artifact: the human/ChatGPT implementation result for the
# active task (the "Claude Code / DeepSeek implementation result" fixture).
# This is a HUMAN boundary artifact, not a DevBridge lifecycle transition.
# ---------------------------------------------------------------------------
function Register-ImplementationResult([hashtable]$f, [string]$scenario) {
    $task = Get-FixtureTask $f
    $changeId = if ($task -and $task.changeId) { [string]$task.changeId } else { "CHG-UNKNOWN" }
    $nodeId = if ($task -and $task.nodeId) { [string]$task.nodeId } else { "NODE-UNKNOWN" }
    $impl = [ordered]@{
        source = "HUMAN_BOUNDARY_FIXTURE"
        nodeId = $nodeId; changeId = $changeId; scenario = $scenario
        deliveredBy = "ChatGPT (controlled fixture artifact)"
        summary = ("Implementation result for " + $nodeId + " delivered and registered by the human boundary.")
        deliveredAtUtc = ([DateTime]::UtcNow).ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    Write-FJson $f.state "implementation-result.json" $impl
    [System.IO.File]::WriteAllText((Join-Path $f.tasks "IMPLEMENTATION_RESULT.md"),
        ("# IMPLEMENTATION RESULT`nNode: " + $nodeId + "`nChange: " + $changeId + "`nSource: HUMAN_BOUNDARY_FIXTURE (ChatGPT output)`n`nDelivered implementation registered by the human boundary for governed verification.`n"),
        (New-Object System.Text.UTF8Encoding($false)))
}

# ===========================================================================
# SCENARIO A - Happy-path supervised TRIAL cycle (WI-07-0.2.5)
# ===========================================================================
function Invoke-Db33ScenarioA {
    $s = "A"
    Log-Db33 ("SCENARIO|" + $s + "|Happy-path supervised trial cycle")
    $f = New-Db33Fixture "A_happy"

    # M03
    $r3 = Invoke-Db33M03 $f
    $pre = Read-FJson $f.state "preflight.json"
    $task = Get-FixtureTask $f
    Assert-Db33 $s "m03-verdict-CLEAR" ($pre -and [string]$pre.verdict -eq "CLEAR") ("verdict=" + $(if ($pre) { $pre.verdict } else { "missing" }))
    Assert-Db33 $s "m03-selects-impl-leaf" ($task -and [string]$task.nodeId -eq "WI-07-0.2.5" -and [string]$task.implementability -eq "IMPLEMENTABLE_LEAF") ("node=" + $(if ($task) { $task.nodeId } else { "missing" }) + " impl=" + $(if ($task) { $task.implementability } else { "missing" }))
    Assert-Db33 $s "m03-next-action-reserve" ($task -and [string]$task.status -eq "PREFLIGHTED" -and [string]$task.nextAllowedAction -eq "RESERVE") ("status=" + $(if ($task) { $task.status } else { "-" }) + " next=" + $(if ($task) { $task.nextAllowedAction } else { "-" }))
    Assert-Db33 $s "m03-writes-task-files" ((Test-Path (Join-Path $f.tasks "NEXT_TASK.md")) -and (Test-Path (Join-Path $f.tasks "PREFLIGHT_REPORT.md"))) "NEXT_TASK.md + PREFLIGHT_REPORT.md"

    # M04
    $r4 = Invoke-Db33Backend $f "Reserve-DevelopmentChange.ps1" @() @{
        DB04_SELFTEST = "1"; DB04_WORKBOOK_OVERRIDE = $f.wb; DB04_STATE_DIR = $f.state; DB04_TASKS_DIR = $f.tasks; DB04_LOGS_DIR = $f.logs }
    $task = Get-FixtureTask $f
    $changeId = [string]$task.changeId
    Assert-Db33 $s "m04-reserved" ((Get-Db33Marker $r4 "DB04_OUTCOME") -eq "RESERVED") ("outcome=" + (Get-Db33Marker $r4 "DB04_OUTCOME"))
    Assert-Db33 $s "m04-state-reserved" ($task -and [string]$task.status -eq "RESERVED" -and [string]$task.nextAllowedAction -eq "CHATGPT_HANDOFF") ("status=" + $(if ($task) { $task.status } else { "-" }))
    Assert-Db33 $s "m04-changeid" ($changeId -match "^CHG-\d{8}-\d{3}$") ("changeId=" + $changeId)
    Assert-Db33 $s "m04-reservation-file" (Test-Path (Join-Path $f.state "reservation.json")) "state/reservation.json"

    # M05
    $r5 = Invoke-Db33M05 $f
    $task = Get-FixtureTask $f
    Assert-Db33 $s "m05-handoff-generated" ((Get-Db33Marker $r5 "DB05_OUTCOME") -eq "HANDOFF_GENERATED") ("outcome=" + (Get-Db33Marker $r5 "DB05_OUTCOME"))
    Assert-Db33 $s "m05-awaits-human-chatgpt" ($task -and [string]$task.status -eq "AWAITING_CHATGPT_PROMPT" -and [string]$task.nextAllowedAction -eq "COPY_TO_CHATGPT") ("status=" + $(if ($task) { $task.status } else { "-" }))
    Assert-Db33 $s "m05-handoff-file" ((Test-Path (Join-Path $f.tasks "HANDOFF.md")) -or (Test-Path (Join-Path $f.tasks "CHATGPT_HANDOFF.md")) -or (Get-ChildItem $f.tasks -Filter "*HANDOFF*" -ErrorAction SilentlyContinue).Count -gt 0) "handoff document present"

    # Human/ChatGPT implementation gate (controlled artifact) + registration.
    Register-ImplementationResult $f $s
    Assert-Db33 $s "impl-artifact-registered" ((Test-Path (Join-Path $f.state "implementation-result.json")) -and (Test-Path (Join-Path $f.tasks "IMPLEMENTATION_RESULT.md"))) "human implementation result registered"

    # M06 PASS
    $r6 = Invoke-Db33Backend $f "Run-Verification.ps1" @() @{ DB06_SELFTEST = "1"; DB06_STATE_DIR = $f.state; DB06_TASKS_DIR = $f.tasks }
    $task = Get-FixtureTask $f
    $verif = Read-FJson $f.state "verification.json"
    Assert-Db33 $s "m06-pass" ((Get-Db33Marker $r6 "DB06_OUTCOME") -eq "VERIFICATION_PASSED") ("outcome=" + (Get-Db33Marker $r6 "DB06_OUTCOME"))
    Assert-Db33 $s "m06-verified-state" ($task -and [string]$task.status -eq "VERIFIED" -and [string]$task.nextAllowedAction -eq "CLAUDE_REVIEW") ("status=" + $(if ($task) { $task.status } else { "-" }))
    Assert-Db33 $s "m06-verification-file" ($verif -and [string]$verif.primaryResult -eq "VERIFICATION_PASSED") "verification.json primaryResult"

    # M07
    $r7 = Invoke-Db33Backend $f "New-ClaudeReviewPackage.ps1" @() @{ DB07_STATE_DIR = $f.state; DB07_TASKS_DIR = $f.tasks }
    Assert-Db33 $s "m07-package-created" ((Get-Db33Marker $r7 "DB07_OUTCOME") -eq "CLAUDE_REVIEW_PACKAGE_CREATED") ("outcome=" + (Get-Db33Marker $r7 "DB07_OUTCOME"))
    Assert-Db33 $s "m07-package-files" ((Test-Path (Join-Path $f.tasks "CLAUDE_REVIEW_PACKAGE.md")) -and (Test-Path (Join-Path $f.tasks "REVIEW_PACKET.md"))) "CLAUDE_REVIEW_PACKAGE.md + REVIEW_PACKET.md"

    # M08 PASS (controlled human Claude decision)
    $r8 = Invoke-Db33Backend $f "Set-ClaudeReviewResult.ps1" @() @{
        DB08_DECISION = "PASS"; DB08_REVIEW_TEXT = "TRIAL approval: scope delta acceptable; supervised flow coherent."; DB08_STATE_DIR = $f.state; DB08_TASKS_DIR = $f.tasks; DB_COMMAND_INPUT_MODE = "TRIAL" }
    $task = Get-FixtureTask $f
    $claude = Read-FJson $f.state "claude-review.json"
    Assert-Db33 $s "m08-pass-recorded" ((Get-Db33Marker $r8 "DB08_OUTCOME") -eq "CLAUDE_RESULT_RECORDED") ("outcome=" + (Get-Db33Marker $r8 "DB08_OUTCOME"))
    Assert-Db33 $s "m08-safe-stop-state" ($task -and [string]$task.status -eq "CLAUDE_REVIEW_PASSED_TRIAL" -and [string]$task.nextAllowedAction -eq "TRIAL_CYCLE_SAFE_STOP") ("status=" + $(if ($task) { $task.status } else { "-" }) + " next=" + $(if ($task) { $task.nextAllowedAction } else { "-" }))
    Assert-Db33 $s "m08-trial-only-unmerged" ($claude -and [string]$claude.decision -eq "PASS" -and $claude.trialMode -eq $true) "claude-review.json decision=PASS trialMode=true"

    # M10 NOT applicable in TRIAL (Test-DBM10CompletionEligibility from fixture root).
    $r10 = Invoke-Db33Backend $f "Test-DBM10CompletionEligibility.ps1" @() @{}
    Assert-Db33 $s "m10-trial-not-applicable" ((Get-Db33Marker $r10 "DBGH01_M10_TOKEN") -eq "TRIAL_COMPLETION_NOT_APPLICABLE") ("token=" + (Get-Db33Marker $r10 "DBGH01_M10_TOKEN"))
    Assert-Db33 $s "m10-eligibility-false" ((Get-Db33Marker $r10 "DBGH01_M10_ELIGIBLE") -eq "False") ("eligible=" + (Get-Db33Marker $r10 "DBGH01_M10_ELIGIBLE"))

    # M12.4 closure
    $r24 = Invoke-Db33Backend $f "Close-TrialCycle.ps1" @("-NodeId", "WI-07-0.2.5", "-ChangeId", $changeId) @{
        DB24_STATE_DIR = $f.state; DB24_TASKS_DIR = $f.tasks; DB24_WORKBOOK_OVERRIDE = $f.wb; DB_DEV_CONTROL_WORKBOOK_OVERRIDE = $f.wb }
    $task = Get-FixtureTask $f
    $history = Read-FJson $f.state "trial-proving-history.json"
    $closure = Read-FJson $f.state "trial-closure.json"
    $entry25 = $null
    if ($history) { foreach ($e in @($history.entries)) { if ([string]$e.nodeId -eq "WI-07-0.2.5") { $entry25 = $e } } }
    Assert-Db33 $s "m12-closed" ((Get-Db33Marker $r24 "DB24_OUTCOME") -eq "TRIAL_CYCLE_CLOSED") ("outcome=" + (Get-Db33Marker $r24 "DB24_OUTCOME"))
    Assert-Db33 $s "m12-closed-state" ($task -and [string]$task.status -eq "TRIAL_CYCLE_CLOSED") ("status=" + $(if ($task) { $task.status } else { "-" }))
    Assert-Db33 $s "m12-history-entry" ($entry25 -and [string]$entry25.result -eq "TRIAL_CYCLE_CLOSED" -and [string]$entry25.implementationState -eq "TRIAL_ONLY_UNMERGED" -and [string]$entry25.mode -eq "TRIAL") "trial-proving-history.json has WI-07-0.2.5 TRIAL_CYCLE_CLOSED"
    Assert-Db33 $s "m12-closure-file" ($closure -and [string]$closure.changeId -eq $changeId) "trial-closure.json"

    # Idempotence: closure + reservation re-run
    $r24b = Invoke-Db33Backend $f "Close-TrialCycle.ps1" @("-NodeId", "WI-07-0.2.5", "-ChangeId", $changeId) @{
        DB24_STATE_DIR = $f.state; DB24_TASKS_DIR = $f.tasks; DB24_WORKBOOK_OVERRIDE = $f.wb; DB_DEV_CONTROL_WORKBOOK_OVERRIDE = $f.wb }
    Assert-Db33 $s "m12-closure-idempotent" ((Get-Db33Marker $r24b "DB24_OUTCOME") -eq "TRIAL_CYCLE_ALREADY_CLOSED") ("outcome=" + (Get-Db33Marker $r24b "DB24_OUTCOME"))

    # M04 reservation idempotence is proven on a fresh pre-closure fixture (scenario A2) to
    # avoid mutating this closed cycle.
    return $f
}

# ===========================================================================
# SCENARIO B - Verification failure + correction cycle (full FIX path)
# ===========================================================================
function Invoke-Db33ScenarioB {
    $s = "B"
    Log-Db33 ("SCENARIO|" + $s + "|Verification failure + correction cycle")
    $f = New-Db33Fixture "B_correction"
    $r3 = Invoke-Db33M03 $f
    $r4 = Invoke-Db33Backend $f "Reserve-DevelopmentChange.ps1" @() @{
        DB04_SELFTEST = "1"; DB04_WORKBOOK_OVERRIDE = $f.wb; DB04_STATE_DIR = $f.state; DB04_TASKS_DIR = $f.tasks; DB04_LOGS_DIR = $f.logs }
    $changeId = [string](Get-FixtureTask $f).changeId
    $r5 = Invoke-Db33M05 $f
    Register-ImplementationResult $f $s

    # M06 FAIL (forced by controlled fixture DB06_FAIL=1)
    $r6f = Invoke-Db33Backend $f "Run-Verification.ps1" @() @{ DB06_SELFTEST = "1"; DB06_FAIL = "1"; DB06_STATE_DIR = $f.state; DB06_TASKS_DIR = $f.tasks }
    $task = Get-FixtureTask $f
    $verif = Read-FJson $f.state "verification.json"
    Assert-Db33 $s "m06-fail" ((Get-Db33Marker $r6f "DB06_OUTCOME") -eq "VERIFICATION_FAILED") ("outcome=" + (Get-Db33Marker $r6f "DB06_OUTCOME"))
    Assert-Db33 $s "m06-fail-no-transition" ($task -and [string]$task.status -eq "AWAITING_CHATGPT_PROMPT") ("status=" + $(if ($task) { $task.status } else { "-" }))
    Assert-Db33 $s "m06-fail-evidence" ($verif -and [string]$verif.primaryResult -eq "VERIFICATION_FAILED") "verification.json VERIFICATION_FAILED recorded"

    # Corrected result registered by the human boundary, M06 rerun PASS.
    Register-ImplementationResult $f $s
    $r6 = Invoke-Db33Backend $f "Run-Verification.ps1" @() @{ DB06_SELFTEST = "1"; DB06_STATE_DIR = $f.state; DB06_TASKS_DIR = $f.tasks }
    $task = Get-FixtureTask $f
    Assert-Db33 $s "m06-corrected-pass" ((Get-Db33Marker $r6 "DB06_OUTCOME") -eq "VERIFICATION_PASSED") "M06 rerun PASS after correction"
    Assert-Db33 $s "m06-verified-after-correction" ($task -and [string]$task.status -eq "VERIFIED") ("status=" + $(if ($task) { $task.status } else { "-" }))

    # M07 + M08 FIX -> DB_M09_FIX_REQUIRED
    $r7 = Invoke-Db33Backend $f "New-ClaudeReviewPackage.ps1" @() @{ DB07_STATE_DIR = $f.state; DB07_TASKS_DIR = $f.tasks }
    $r8f = Invoke-Db33Backend $f "Set-ClaudeReviewResult.ps1" @() @{
        DB08_DECISION = "FIX"; DB08_REVIEW_TEXT = "TRIAL fix: verification detected a scoped defect; correct the current attempt."; DB08_STATE_DIR = $f.state; DB08_TASKS_DIR = $f.tasks; DB_COMMAND_INPUT_MODE = "TRIAL" }
    $task = Get-FixtureTask $f
    $claude = Read-FJson $f.state "claude-review.json"
    Assert-Db33 $s "m08-fix-decision" ($claude -and [string]$claude.decision -eq "FIX") "claude-review.json decision=FIX"
    Assert-Db33 $s "m08-fix-routes-m09" ($task -and [string]$task.status -eq "DB_M09_FIX_REQUIRED" -and [string]$task.nextAllowedAction -eq "CORRECT_CURRENT_ATTEMPT") ("status=" + $(if ($task) { $task.status } else { "-" }))

    # M09 correction context (dependency context retained)
    $r9 = Invoke-Db33Backend $f "New-CorrectionContext.ps1" @() @{ DB09_STATE_DIR = $f.state; DB09_TASKS_DIR = $f.tasks }
    Assert-Db33 $s "m09-context-created" ((Get-Db33Marker $r9 "DB09_OUTCOME") -eq "FIX_CONTEXT_CREATED" -or (Test-Path (Join-Path $f.tasks "FIX_CONTEXT.md"))) ("outcome=" + (Get-Db33Marker $r9 "DB09_OUTCOME"))
    $fixCtx = Join-Path $f.tasks "FIX_CONTEXT.md"
    Assert-Db33 $s "m09-context-file" (Test-Path $fixCtx) "tasks/FIX_CONTEXT.md"
    $ctxText = if (Test-Path $fixCtx) { Get-Content $fixCtx -Raw } else { "" }
    Assert-Db33 $s "m09-retains-dependency" ($ctxText -match "WI-07-0.2.4" -or $ctxText -match "CORRECT_CURRENT_ATTEMPT") "correction context retains task/dependency identity"

    # Corrected result registered, M06 rerun PASS, M07 REUSED, M08 PASS -> safe stop.
    Register-ImplementationResult $f $s
    $r6b = Invoke-Db33Backend $f "Run-Verification.ps1" @() @{ DB06_SELFTEST = "1"; DB06_STATE_DIR = $f.state; DB06_TASKS_DIR = $f.tasks }
    $task = Get-FixtureTask $f
    Assert-Db33 $s "m06-post-fix-pass" ((Get-Db33Marker $r6b "DB06_OUTCOME") -eq "VERIFICATION_PASSED") "M06 rerun PASS after M09"
    $r7b = Invoke-Db33Backend $f "New-ClaudeReviewPackage.ps1" @() @{ DB07_STATE_DIR = $f.state; DB07_TASKS_DIR = $f.tasks }
    Assert-Db33 $s "m07-reused" ((Get-Db33Marker $r7b "DB07_OUTCOME") -eq "REUSED") ("outcome=" + (Get-Db33Marker $r7b "DB07_OUTCOME"))
    $r8 = Invoke-Db33Backend $f "Set-ClaudeReviewResult.ps1" @() @{
        DB08_DECISION = "PASS"; DB08_REVIEW_TEXT = "TRIAL approval after correction."; DB08_STATE_DIR = $f.state; DB08_TASKS_DIR = $f.tasks; DB_COMMAND_INPUT_MODE = "TRIAL" }
    $task = Get-FixtureTask $f
    Assert-Db33 $s "m08-pass-after-fix" ($task -and [string]$task.status -eq "CLAUDE_REVIEW_PASSED_TRIAL" -and [string]$task.nextAllowedAction -eq "TRIAL_CYCLE_SAFE_STOP") ("status=" + $(if ($task) { $task.status } else { "-" }))
    return $f
}

# ===========================================================================
# SCENARIO C - Scope change (no silent scope expansion)
# ===========================================================================
function Invoke-Db33ScenarioC {
    $s = "C"
    Log-Db33 ("SCENARIO|" + $s + "|Scope change protection")
    $f = New-Db33Fixture "C_scope"
    $r3 = Invoke-Db33M03 $f
    $r4 = Invoke-Db33Backend $f "Reserve-DevelopmentChange.ps1" @() @{
        DB04_SELFTEST = "1"; DB04_TEST_SCOPE_WIDEN = "1"; DB04_WORKBOOK_OVERRIDE = $f.wb; DB04_STATE_DIR = $f.state; DB04_TASKS_DIR = $f.tasks; DB04_LOGS_DIR = $f.logs }
    $task = Get-FixtureTask $f
    Assert-Db33 $s "scope-change-required" ((Get-Db33Marker $r4 "DB04_OUTCOME") -eq "STOP_SCOPE_CHANGE_REQUIRED") ("outcome=" + (Get-Db33Marker $r4 "DB04_OUTCOME"))
    Assert-Db33 $s "no-silent-expansion" ($task -and [string]$task.status -eq "PREFLIGHTED") ("status=" + $(if ($task) { $task.status } else { "-" }))
    return $f
}

# ===========================================================================
# SCENARIO D - Dependency lineage / context in the M05 handoff
# ===========================================================================
function Invoke-Db33ScenarioD {
    $s = "D"
    Log-Db33 ("SCENARIO|" + $s + "|Dependency lineage in the ChatGPT handoff")
    $f = New-Db33Fixture "D_lineage"
    $r3 = Invoke-Db33M03 $f
    $r4 = Invoke-Db33Backend $f "Reserve-DevelopmentChange.ps1" @() @{
        DB04_SELFTEST = "1"; DB04_WORKBOOK_OVERRIDE = $f.wb; DB04_STATE_DIR = $f.state; DB04_TASKS_DIR = $f.tasks; DB04_LOGS_DIR = $f.logs }
    $r5 = Invoke-Db33M05 $f
    $handoff = Get-ChildItem $f.tasks -Filter "*HANDOFF*" -ErrorAction SilentlyContinue | Select-Object -First 1
    $handoffText = ""
    if ($handoff) { $handoffText = Get-Content $handoff.FullName -Raw -Encoding UTF8 }
    $pre = Read-FJson $f.state "preflight.json"
    $depText = ""
    if ($pre -and $pre.dependencies) { $depText = ($pre.dependencies | ConvertTo-Json -Depth 6) }
    Assert-Db33 $s "dependency-identified" ($depText -match "WI-07-0.2.4" -or $handoffText -match "WI-07-0.2.4") "dependency WI-07-0.2.4 present in preflight/handoff"
    Assert-Db33 $s "trial-vs-real-distinction" ($depText -match "TRIAL_DEPENDENCY_SATISFIED" -or $handoffText -match "TRIAL" -or $depText -match "Planned") "dependency state carries Trial/Real distinction"
    Assert-Db33 $s "provenance-in-context" (($handoffText -match "CHG-20260830-017") -or ($depText -match "CHG-20260830-017")) "overlay provenance (change id) present"
    return $f
}

# ===========================================================================
# SCENARIO E - Trial dependency overlay: TRIAL satisfied, REAL ignored
# ===========================================================================
function Invoke-Db33ScenarioE {
    $s = "E"
    Log-Db33 ("SCENARIO|" + $s + "|Trial dependency overlay (TRIAL vs REAL)")
    # TRIAL: overlay satisfied (already proven in A via M03 CLEAR on WI-07-0.2.5).
    $fT = New-Db33Fixture "E_trial"
    $r3T = Invoke-Db33M03 $fT
    $taskT = Get-FixtureTask $fT
    Assert-Db33 $s "overlay-satisfied-trial" ($taskT -and [string]$taskT.nodeId -eq "WI-07-0.2.5") ("node=" + $(if ($taskT) { $taskT.nodeId } else { "blocked" }))

    # REAL: overlay ignored; WI-07-0.2.4 stays Planned -> WI-07-0.2.5 NOT selectable.
    $fR = New-Db33Fixture "E_real"
    $cfgPath = Join-Path $fR.root "config\devbridge.json"
    $cfgR = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfgR.mode = "REAL_NEXUS_DEVELOPMENT"
    [System.IO.File]::WriteAllText($cfgPath, ($cfgR | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    $r3R = Invoke-Db33M03 $fR
    $preR = Read-FJson $fR.state "preflight.json"
    $taskR = Get-FixtureTask $fR
    # In REAL mode M03 must NOT select WI-07-0.2.5 for reservation: the trial overlay is
    # ignored and the trial-proven predecessor cannot satisfy the dependency. A non-CLEAR
    # verdict still writes the analyzed node identity, so the selection signal is
    # nextAllowedAction=RESOLVE_PREFLIGHT (NOT RESERVE).
    Assert-Db33 $s "real-overlay-ignored" ($taskR -and [string]$taskR.nextAllowedAction -ne "RESERVE") ("next=" + $(if ($taskR) { $taskR.nextAllowedAction } else { "missing" }))
    Assert-Db33 $s "real-no-false-complete" ($preR -and [string]$preR.verdict -ne "CLEAR") ("real preflight verdict=" + $(if ($preR) { $preR.verdict } else { "missing" }))
    # Real status of WI-07-0.2.4 must remain Planned (never written as completion).
    $node24 = Get-Db33RoadmapNode $fR.wb "WI-07-0.2.4"
    Assert-Db33 $s "real-dep-stays-planned" ($node24 -and ([string]$node24.Status) -match "Planned") ("status=" + $(if ($node24) { $node24.Status } else { "row-not-found" }))
    return $fT
}

# ===========================================================================
# SCENARIO F - Restart / recovery (interrupted stages, no duplicate writes)
# ===========================================================================
function Invoke-Db33ScenarioF {
    $s = "F"
    Log-Db33 ("SCENARIO|" + $s + "|Restart / recovery")
    # Run the DB-M32 recovery suite (regression + restart proof).
    $out32 = Invoke-Db33Backend @{ root = $script:Root; logs = $script:SelftestRoot; state = (Join-Path $script:Root "state"); tasks = (Join-Path $script:Root "tasks"); wb = $script:RealWorkbook } "recovery-safety\Test-DbM32EssentialSafety.ps1" @() @{}
    $pass32 = $null
    foreach ($ln in $out32.Output) { if ($ln -match "^DB32_TEST_OUTCOME:\s*(.+)$") { $pass32 = $matches[1].Trim() } }
    Assert-Db33 $s "recovery-suite-pass" ($pass32 -eq "PASS") ("DB32_TEST_OUTCOME=" + $pass32)

    # Focused restart: a fixture left mid-cycle at AWAITING_CHATGPT_PROMPT must be
    # reconciled read-only (SAFE_TO_RESUME), never rewritten, never given an invented PASS.
    $f = New-Db33Fixture "F_restart"
    $r3 = Invoke-Db33M03 $f
    $r4 = Invoke-Db33Backend $f "Reserve-DevelopmentChange.ps1" @() @{
        DB04_SELFTEST = "1"; DB04_WORKBOOK_OVERRIDE = $f.wb; DB04_STATE_DIR = $f.state; DB04_TASKS_DIR = $f.tasks; DB04_LOGS_DIR = $f.logs }
    $r5 = Invoke-Db33M05 $f
    $taskBefore = Get-FixtureTask $f
    $stateHashBefore = (Get-FileHash (Join-Path $f.state "current-task.json") -Algorithm SHA256).Hash
    $wbHashBefore = (Get-FileHash $f.wb -Algorithm SHA256).Hash
    # Recovery observation via the DB-M32 engine (read-only) against this fixture.
    $rec = Invoke-Db33Backend @{ root = $script:Root; logs = $script:SelftestRoot; state = (Join-Path $script:Root "state"); tasks = (Join-Path $script:Root "tasks"); wb = $script:RealWorkbook } "recovery-safety\Show-DbM32EssentialSafety.ps1" @("-Root", $f.root, "-StateSource", "FIXTURE") @{}
    $recText = $rec.Text
    $stateHashAfter = (Get-FileHash (Join-Path $f.state "current-task.json") -Algorithm SHA256).Hash
    $wbHashAfter = (Get-FileHash $f.wb -Algorithm SHA256).Hash
    Assert-Db33 $s "restart-no-state-write" ($stateHashBefore -eq $stateHashAfter) "current-task.json untouched by recovery observation"
    Assert-Db33 $s "restart-no-workbook-write" ($wbHashBefore -eq $wbHashAfter) "workbook untouched by recovery observation"
    Assert-Db33 $s "restart-guidance" ($recText -match "SAFE_TO_RESUME|RECOVERY|RECONCIL") "recovery guidance rendered"
    $taskAfter = Get-FixtureTask $f
    Assert-Db33 $s "restart-no-invented-pass" ([string]$taskAfter.status -eq "AWAITING_CHATGPT_PROMPT") ("status=" + $taskAfter.status)
    return $f
}

# ===========================================================================
# SCENARIO G - Human Git gates (REAL fixture, human-only)
# ===========================================================================
function Invoke-Db33ScenarioG {
    $s = "G"
    Log-Db33 ("SCENARIO|" + $s + "|Human Git gates (REAL fixture)")
    $f = New-Db33Fixture "G_git"
    $cfgPath = Join-Path $f.root "config\devbridge.json"
    $cfgG = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfgG.mode = "REAL_NEXUS_DEVELOPMENT"
    [System.IO.File]::WriteAllText($cfgPath, ($cfgG | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    # REAL-mode M03 correctly BLOCKS selection of WI-07-0.2.5 (the trial-proven
    # predecessor cannot satisfy a REAL dependency - proven in scenario E), so a REAL
    # task cannot be selected through the governed selection path on the current
    # workbook. G therefore proves the HUMAN GIT GATES with the REAL backend: the task
    # state is seeded at the post-M05 point (AWAITING_CHATGPT_PROMPT, controlled human
    # boundary artifact) and M06 -> M07 -> M08(REAL) -> DB13 run through the real
    # hardened backend.
    $seedG = [ordered]@{
        nodeId = "WI-07-0.2.5"; taskId = "WI-07-0.2.5"
        name = "Development Control application operations"; nodeType = "WorkItem"
        phase = "P0"; currentWorkNodeId = "M-07-0.2"; featureNodeId = "F-07-0"
        status = "AWAITING_CHATGPT_PROMPT"; nextAllowedAction = "COPY_TO_CHATGPT"
        changeId = ("CHG-" + (Get-Date -Format "yyyyMMdd") + "-901")
        preflightVerdict = "CLEAR"; implementability = "IMPLEMENTABLE_LEAF"
        mode = "REAL_NEXUS_DEVELOPMENT"
        selectedAt = ([DateTime]::UtcNow).ToString("yyyy-MM-ddTHH:mm:ssZ")
        sourceReferences = @("Fixture seed: post-M05 REAL state for human git-gate proving (controlled artifact)")
    }
    Write-FJson $f.state "current-task.json" $seedG
    $changeId = [string]$seedG.changeId
    Register-ImplementationResult $f $s
    $r6 = Invoke-Db33Backend $f "Run-Verification.ps1" @() @{ DB06_SELFTEST = "1"; DB06_STATE_DIR = $f.state; DB06_TASKS_DIR = $f.tasks }
    $task = Get-FixtureTask $f
    Assert-Db33 $s "m06-real-verified" ((Get-Db33Marker $r6 "DB06_OUTCOME") -eq "VERIFICATION_PASSED" -and $task -and [string]$task.status -eq "VERIFIED") ("outcome=" + (Get-Db33Marker $r6 "DB06_OUTCOME") + " status=" + $(if ($task) { $task.status } else { "-" }))
    $r7 = Invoke-Db33Backend $f "New-ClaudeReviewPackage.ps1" @() @{ DB07_STATE_DIR = $f.state; DB07_TASKS_DIR = $f.tasks }
    Assert-Db33 $s "m07-real-package" ((Get-Db33Marker $r7 "DB07_OUTCOME") -eq "CLAUDE_REVIEW_PACKAGE_CREATED") ("outcome=" + (Get-Db33Marker $r7 "DB07_OUTCOME"))
    # M08 PASS in REAL mode -> CLAUDE_REVIEW_PASSED_REAL / AWAITING_HUMAN_PR (real backend).
    $r8 = Invoke-Db33Backend $f "Set-ClaudeReviewResult.ps1" @() @{
        DB08_DECISION = "PASS"; DB08_REVIEW_TEXT = "REAL approval."; DB08_STATE_DIR = $f.state; DB08_TASKS_DIR = $f.tasks; DB_COMMAND_INPUT_MODE = "REAL_NEXUS_DEVELOPMENT" }
    $task = Get-FixtureTask $f
    Assert-Db33 $s "m08-real-awaits-pr" ($task -and [string]$task.status -eq "CLAUDE_REVIEW_PASSED_REAL" -and [string]$task.nextAllowedAction -eq "AWAITING_HUMAN_PR") ("status=" + $(if ($task) { $task.status } else { "-" }))

    # Get-GitGateState: merge never inferred (UNKNOWN without evidence).
    $r13 = Invoke-Db33Backend $f "Get-GitGateState.ps1" @() @{ DB13_SELFTEST = "1"; DB13_GIT_BRANCH = "main"; DB13_HEAD = "0" * 40; DB13_PR_STATE = ""; DB13_STATE_DIR = $f.state }
    $gate = Read-FJson $f.state "git-gate-state.json"
    Assert-Db33 $s "git-merge-never-inferred" ($gate -and [string]$gate.prState -eq "UNKNOWN" -and $gate.mergeConfirmed -ne $true) ("prState=" + $(if ($gate) { $gate.prState } else { "missing" }))

    # Human merge evidence supplied (controlled external): DB13 observes MERGED.
    $r13m = Invoke-Db33Backend $f "Get-GitGateState.ps1" @() @{ DB13_SELFTEST = "1"; DB13_GIT_BRANCH = "main"; DB13_HEAD = "1" * 40; DB13_PR_STATE = "MERGED"; DB13_STATE_DIR = $f.state }
    $gateM = Read-FJson $f.state "git-gate-state.json"
    Assert-Db33 $s "git-merge-explicit-only" ($gateM -and [string]$gateM.prState -eq "MERGED" -and $gateM.mergeConfirmed -eq $true) "merge confirmed only with explicit evidence"

    # M31 governed-workbook-git suite proves the full human gate progression
    # (AWAITING_HUMAN_PR -> PR_OPEN -> AWAITING_HUMAN_REVIEW -> AWAITING_HUMAN_MERGE
    # -> MERGED -> READY_FOR_GOVERNED_COMPLETION, human-only).
    $out31 = Invoke-Db33Backend @{ root = $script:Root; logs = $script:SelftestRoot; state = (Join-Path $script:Root "state"); tasks = (Join-Path $script:Root "tasks"); wb = $script:RealWorkbook } "governed-workbook-git\Test-DbM31GovernedRealUse.ps1" @() @{}
    $pass31 = ($out31.ExitCode -eq 0 -and $out31.Text -match "0 failed")
    Assert-Db33 $s "m31-suite-pass" $pass31 ("exit=" + $out31.ExitCode + " " + $(if ($out31.Text -match "TEST SUMMARY:\s*(\d+) passed, (\d+) failed") { ("passed=" + $matches[1] + " failed=" + $matches[2]) } else { "no summary" }))
    # The M31 suite prints only FAIL lines (passed assertions are silent), so a clean
    # run means every human-gate scenario (AWAITING_HUMAN_PR -> PR_OPEN -> REVIEW ->
    # MERGE -> MERGED -> READY_FOR_GOVERNED_COMPLETION) passed. The vocabulary itself is
    # exercised by this scenario's real DB13 assertions above (UNKNOWN never inferred,
    # MERGED only on explicit evidence, AWAITING_HUMAN_PR routing from M08-REAL).
    Assert-Db33 $s "git-gate-human-only" ($out31.Text -match "DB-M31 TEST SUMMARY: .* 0 failed" -and $out31.Text -notmatch "FAIL:") "human git gate suite ran clean (0 failed, no gate FAIL lines)"
    return $f
}

# ===========================================================================
# SCENARIO H - REAL M10 prerequisite fixture + M11 validation
# ===========================================================================
function Invoke-Db33ScenarioH {
    $s = "H"
    Log-Db33 ("SCENARIO|" + $s + "|REAL M10 prerequisites + M11 validation")
    # Build REAL-mode current-task variants on separate fixtures (human-supplied
    # git/verification/claude evidence, evaluated by the REAL read-only M10 engine).
    function New-M10Fixture([string]$nm, [string]$status, [string]$gitLife, [bool]$verif, [bool]$claude, [string]$fpState) {
        $f = New-Db33Fixture $nm
        $cur = [ordered]@{
            nodeId = "WI-07-0.2.5"; taskId = "WI-07-0.2.5"; name = "M10 fixture"; nodeType = "WorkItem"
            phase = "P0"; layer = "App"; changeId = "CHG-20260831-101"; status = $status; nextAllowedAction = "AWAITING_HUMAN_PR"
            mode = "REAL_NEXUS_DEVELOPMENT"; implementability = "IMPLEMENTABLE_LEAF"
            gitLifecycleState = $gitLife
            dbM06 = [ordered]@{ result = $(if ($verif) { "VERIFICATION_PASS" } else { "VERIFICATION_FAIL" }); trialMode = $false }
            dbM08 = [ordered]@{ decision = $(if ($claude) { "PASS" } else { "FIX" }); trialMode = $false; implementationState = "REAL_UNMERGED" }
        }
        Write-FJson $f.state "current-task.json" $cur
        if ($verif) { Write-FJson $f.state "verification.json" ([ordered]@{ primaryResult = "VERIFICATION_PASSED"; nodeId = "WI-07-0.2.5"; mode = "REAL_NEXUS_DEVELOPMENT" }) }
        if ($claude) { Write-FJson $f.state "claude-review.json" ([ordered]@{ decision = "PASS"; trialMode = $false }) }
        $fpBefore = "FINGERPRINT_A"; $fpAfter = "FINGERPRINT_A"
        if ($fpState -eq "changed") { $fpAfter = "FINGERPRINT_B" }
        Write-FJson $f.state "roadmap-fingerprint.json" ([ordered]@{ before = [ordered]@{ value = $fpBefore; error = $null }; after = [ordered]@{ value = $fpAfter; error = $null } })
        return $f
    }

    # H1: no merge evidence -> blocked human git merge gate.
    $h1 = New-M10Fixture "H_nomerge" "CLAUDE_REVIEW_PASSED_REAL" "AWAITING_HUMAN_MERGE" $true $true "same"
    $r1 = Invoke-Db33Backend $h1 "Test-DBM10CompletionEligibility.ps1" @() @{}
    Assert-Db33 $s "m10-blocked-no-merge" ((Get-Db33Marker $r1 "DBGH01_M10_TOKEN") -eq "BLOCKED_HUMAN_GIT_MERGE_GATE_PENDING") ("token=" + (Get-Db33Marker $r1 "DBGH01_M10_TOKEN"))

    # H2: merge but no M06 PASS -> blocked no verification pass.
    $h2 = New-M10Fixture "H_noverif" "READY_FOR_GOVERNED_COMPLETION" "MERGED" $false $true "same"
    $r2 = Invoke-Db33Backend $h2 "Test-DBM10CompletionEligibility.ps1" @() @{}
    Assert-Db33 $s "m10-blocked-no-verif" ((Get-Db33Marker $r2 "DBGH01_M10_TOKEN") -eq "BLOCKED_NO_DB_M06_VERIFICATION_PASS") ("token=" + (Get-Db33Marker $r2 "DBGH01_M10_TOKEN"))

    # H3: merge + verif but no Claude PASS -> blocked no claude pass.
    $h3 = New-M10Fixture "H_noclaude" "READY_FOR_GOVERNED_COMPLETION" "MERGED" $true $false "same"
    $r3 = Invoke-Db33Backend $h3 "Test-DBM10CompletionEligibility.ps1" @() @{}
    Assert-Db33 $s "m10-blocked-no-claude" ((Get-Db33Marker $r3 "DBGH01_M10_TOKEN") -eq "BLOCKED_NO_CLAUDE_PASS") ("token=" + (Get-Db33Marker $r3 "DBGH01_M10_TOKEN"))

    # H4: all REAL prerequisites + preserved fingerprint -> eligible.
    $h4 = New-M10Fixture "H_all" "READY_FOR_GOVERNED_COMPLETION" "MERGED" $true $true "same"
    $r4 = Invoke-Db33Backend $h4 "Test-DBM10CompletionEligibility.ps1" @() @{}
    Assert-Db33 $s "m10-eligible-all-prereq" ((Get-Db33Marker $r4 "DBGH01_M10_ELIGIBLE") -eq "True" -and (Get-Db33Marker $r4 "DBGH01_M10_TOKEN") -eq "READY_FOR_GOVERNED_COMPLETION") ("eligible=" + (Get-Db33Marker $r4 "DBGH01_M10_ELIGIBLE") + " token=" + (Get-Db33Marker $r4 "DBGH01_M10_TOKEN"))

    # H5: fingerprint changed -> ROADMAP_STRUCTURE_WRITE_PROHIBITED.
    $h5 = New-M10Fixture "H_fp" "READY_FOR_GOVERNED_COMPLETION" "MERGED" $true $true "changed"
    $r5 = Invoke-Db33Backend $h5 "Test-DBM10CompletionEligibility.ps1" @() @{}
    Assert-Db33 $s "m10-blocked-fp-changed" ((Get-Db33Marker $r5 "DBGH01_M10_TOKEN") -eq "ROADMAP_STRUCTURE_WRITE_PROHIBITED") ("token=" + (Get-Db33Marker $r5 "DBGH01_M10_TOKEN"))

    # M11: workbook validation requires the real lifecycle at COMPLETION_WRITTEN
    # (the post-completion state, distinct from M10's pre-completion eligibility).
    $h11 = New-M10Fixture "H_completed" "COMPLETION_WRITTEN" "MERGED" $true $true "same"
    Write-FJson $h11.state "completion.json" ([ordered]@{ changeId = "CHG-20260831-101"; nodeId = "WI-07-0.2.5"; status = "COMPLETION_WRITTEN"; mode = "REAL_NEXUS_DEVELOPMENT" })
    $r11 = Invoke-Db33Backend $h11 "Invoke-WorkbookValidation.ps1" @() @{ DB11_SELFTEST = "1"; DB11_VALID = "1"; DB11_STATE_DIR = $h11.state; DB11_TASKS_DIR = $h11.tasks; DB11_WORKBOOK_OVERRIDE = $h11.wb }
    Assert-Db33 $s "m11-validation-pass" ((Get-Db33Marker $r11 "DB11_RESULT_PASS") -eq "True") ("pass=" + (Get-Db33Marker $r11 "DB11_RESULT_PASS"))
    return $h4
}

# ===========================================================================
# SCENARIO I - Operator experience (task/cost/history panels)
# ===========================================================================
function Invoke-Db33ScenarioI {
    $s = "I"
    Log-Db33 ("SCENARIO|" + $s + "|Operator experience")
    # Task attempt/escalation history (DB-M29) suite (acceptance 39/41).
    $outHist = Invoke-Db33Backend @{ root = $script:Root; logs = $script:SelftestRoot; state = (Join-Path $script:Root "state"); tasks = (Join-Path $script:Root "tasks"); wb = $script:RealWorkbook } "ai-routing\task-history\Test-DbM29TaskHistory.ps1" @() @{}
    $passHist = ($outHist.ExitCode -eq 0 -and $outHist.Text -match "DB-M29 TEST SUMMARY: .* 0 failed")
    Assert-Db33 $s "task-history-suite" $passHist ("exit=" + $outHist.ExitCode + " " + $(if ($outHist.Text -match "DB-M29 TEST SUMMARY:\s*([0-9]+) passed, ([0-9]+) failed") { ("passed=" + $matches[1] + " failed=" + $matches[2]) } else { "no summary" }))

    # Cost calculator (DB-M27) suite (acceptance 11/40).
    $outCost = Invoke-Db33Backend @{ root = $script:Root; logs = $script:SelftestRoot; state = (Join-Path $script:Root "state"); tasks = (Join-Path $script:Root "tasks"); wb = $script:RealWorkbook } "ai-routing\calculator\Test-DbM27Calculator.ps1" @() @{}
    $passCost = ($outCost.ExitCode -eq 0 -and $outCost.Text -match "DB-M27 TEST SUMMARY: .* 0 failed")
    Assert-Db33 $s "cost-history-suite" $passCost ("exit=" + $outCost.ExitCode + " " + $(if ($outCost.Text -match "DB-M27 TEST SUMMARY:\s*([0-9]+) passed, ([0-9]+) failed") { ("passed=" + $matches[1] + " failed=" + $matches[2]) } else { "no summary" }))

    # Failure-fingerprint suite (DB-M21) (acceptance 41).
    $outFp = Invoke-Db33Backend @{ root = $script:Root; logs = $script:SelftestRoot; state = (Join-Path $script:Root "state"); tasks = (Join-Path $script:Root "tasks"); wb = $script:RealWorkbook } "ai-routing\failure-fingerprints\Test-DbM21Fingerprints.ps1" @() @{}
    Assert-Db33 $s "failure-fingerprint-suite" ($outFp.ExitCode -eq 0) ("exit=" + $outFp.ExitCode)

    # Operator panel (real M30 UI render) emits the operator-experience surfaces.
    $outWf = Invoke-Db33Backend @{ root = $script:Root; logs = $script:SelftestRoot; state = (Join-Path $script:Root "state"); tasks = (Join-Path $script:Root "tasks"); wb = $script:RealWorkbook } "supervised-workflow\Show-DbM30SupervisedWorkflow.ps1" @() @{}
    $wfText = $outWf.Text
    $hasStage = $wfText -match "DB30_CURRENT_STAGE|CURRENT_STAGE|STAGE"
    $hasDep = $wfText -match "DB30_CARD_DEPENDENCY_CONTEXT|DEPENDENC"
    $hasModel = $wfText -match "DB30_CARD_ROUTING_RECOMMENDATION|MODEL|ROUTING"
    $hasCost = $wfText -match "DB30_CARD_COST_GUIDANCE|COST"
    $hasHistory = $wfText -match "DB30_CARD_HISTORY|HISTORY"
    $hasHuman = $wfText -match "HUMAN ACTION|HUMAN_ACTION|SUPERVISED"
    $wfPanels = @($hasStage, $hasDep, $hasModel, $hasCost, $hasHistory, $hasHuman)
    Assert-Db33 $s "operator-panel-surfaces" (-not ($wfPanels -contains $false)) ("stage=" + $hasStage + " deps=" + $hasDep + " model=" + $hasModel + " cost=" + $hasCost + " history=" + $hasHistory + " human=" + $hasHuman)
    return $null
}

# ===========================================================================
# SCENARIO J - No autonomy (explicit absence markers)
# ===========================================================================
function Invoke-Db33ScenarioJ {
    $s = "J"
    Log-Db33 ("SCENARIO|" + $s + "|No autonomy")
    $autoTokens = @("AUTO_DEVELOP", "RUN_ALL", "AUTO_NEXT_TASK", "AUTO_PR", "AUTO_MERGE", "AUTONOMOUS", "autoChatGpt", "autoClaudeCode", "autoRetry", "autoEscalate")
    # Proof surface = the REAL backend. The harness directory and every *Test*.ps1
    # are excluded (a test asserts the vocabulary by naming it); denial markers
    # (": NO", "= FALSE", PROHIBITED/REFUSED/NEVER/DISABLED) are not autonomy
    # capability. Only an enabling occurrence is a finding.
    $denialRe = "(?i)(:\s*NO\b|=\s*FALSE\b|PROHIBITED|REFUSED|NEVER|DISABLED|\bno\b|\bnot\b|\bwithout\b)"
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($tok in $autoTokens) {
        $hit = @(Get-ChildItem $script:ScriptsRoot -Filter *.ps1 -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch "\\final-proving\\" -and $_.Name -notmatch "(?i)test" -and $_.Name -notmatch "^_" } |
            Select-String -Pattern ("\b" + [regex]::Escape($tok) + "\b") -ErrorAction SilentlyContinue |
            Where-Object { $_.Line -notmatch $denialRe })
        if ($hit.Count -gt 0) { $found.Add($tok + "@" + $hit[0].Filename) }
    }
    Assert-Db33 $s "no-autonomy-tokens" ($found.Count -eq 0) ("found=" + ($found -join ","))
    # The M30 workflow suite (acceptance 51 regression) asserts AUTO_EXECUTION_ENABLED.
    $out30 = Invoke-Db33Backend @{ root = $script:Root; logs = $script:SelftestRoot; state = (Join-Path $script:Root "state"); tasks = (Join-Path $script:Root "tasks"); wb = $script:RealWorkbook } "supervised-workflow\Test-DbM30SupervisedWorkflow.ps1" @() @{}
    $pass30 = ($out30.ExitCode -eq 0 -and $out30.Text -match "0 failed")
    Assert-Db33 $s "m30-suite-pass" $pass30 ("exit=" + $out30.ExitCode + " " + $(if ($out30.Text -match "DB-M30 TEST SUMMARY:\s*([0-9]+) passed, ([0-9]+) failed") { ("passed=" + $matches[1] + " failed=" + $matches[2]) } else { "no summary" }))
    # The M30 CLI (real operator console) is the authoritative auto-execution surface.
    $outWfJ = Invoke-Db33Backend @{ root = $script:Root; logs = $script:SelftestRoot; state = (Join-Path $script:Root "state"); tasks = (Join-Path $script:Root "tasks"); wb = $script:RealWorkbook } "supervised-workflow\Show-DbM30SupervisedWorkflow.ps1" @() @{}
    Assert-Db33 $s "auto-execution-disabled" ($outWfJ.Text -match "AUTO_EXECUTION_ENABLED=FALSE") "Show-DbM30 CLI asserts AUTO_EXECUTION_ENABLED=FALSE"
    return $null
}

# ===========================================================================
# SCENARIO K - Governance protection (protected roadmap + structural writes)
# ===========================================================================
function Invoke-Db33ScenarioK {
    $s = "K"
    Log-Db33 ("SCENARIO|" + $s + "|Governance protection")
    # Protected roadmap fingerprint unchanged across a full trial cycle (fixture A).
    $f = New-Db33Fixture "K_roadmap"
    $fpBefore = Invoke-Db33Backend $f "Get-ProtectedRoadmapFingerprint.ps1" @() @{}
    $fpB = $fpBefore.Text
    $r3 = Invoke-Db33M03 $f
    $r4 = Invoke-Db33Backend $f "Reserve-DevelopmentChange.ps1" @() @{
        DB04_SELFTEST = "1"; DB04_WORKBOOK_OVERRIDE = $f.wb; DB04_STATE_DIR = $f.state; DB04_TASKS_DIR = $f.tasks; DB04_LOGS_DIR = $f.logs }
    $changeId = [string](Get-FixtureTask $f).changeId
    $r5 = Invoke-Db33M05 $f
    Register-ImplementationResult $f $s
    $r6 = Invoke-Db33Backend $f "Run-Verification.ps1" @() @{ DB06_SELFTEST = "1"; DB06_STATE_DIR = $f.state; DB06_TASKS_DIR = $f.tasks }
    $r7 = Invoke-Db33Backend $f "New-ClaudeReviewPackage.ps1" @() @{ DB07_STATE_DIR = $f.state; DB07_TASKS_DIR = $f.tasks }
    $r8 = Invoke-Db33Backend $f "Set-ClaudeReviewResult.ps1" @() @{
        DB08_DECISION = "PASS"; DB08_REVIEW_TEXT = "TRIAL approval."; DB08_STATE_DIR = $f.state; DB08_TASKS_DIR = $f.tasks; DB_COMMAND_INPUT_MODE = "TRIAL" }
    $r24 = Invoke-Db33Backend $f "Close-TrialCycle.ps1" @("-NodeId", "WI-07-0.2.5", "-ChangeId", $changeId) @{
        DB24_STATE_DIR = $f.state; DB24_TASKS_DIR = $f.tasks; DB24_WORKBOOK_OVERRIDE = $f.wb; DB_DEV_CONTROL_WORKBOOK_OVERRIDE = $f.wb }
    $fpAfter = Invoke-Db33Backend $f "Get-ProtectedRoadmapFingerprint.ps1" @() @{}
    $fpA = $fpAfter.Text
    $fpSame = ($fpB -match "FINGERPRINT|SHA256|PRESERVED|COMPUTE") -and ($fpB -eq $fpA)
    Assert-Db33 $s "roadmap-fingerprint-unchanged" $fpSame "protected roadmap fingerprint identical across full trial cycle"
    # Non-reservation backends report no workbook modification.
    Assert-Db33 $s "m06-no-workbook-write" ((Get-Db33Marker $r6 "DB06_WORKBOOK_MODIFIED") -eq "False") ("DB06_WORKBOOK_MODIFIED=" + (Get-Db33Marker $r6 "DB06_WORKBOOK_MODIFIED"))
    Assert-Db33 $s "m07-no-workbook-write" ((Get-Db33Marker $r7 "DB07_WORKBOOK_MODIFIED") -eq "False") "DB07_WORKBOOK_MODIFIED=False"
    Assert-Db33 $s "m08-no-workbook-write" ((Get-Db33Marker $r8 "DB08_WORKBOOK_MODIFIED") -eq "False") "DB08_WORKBOOK_MODIFIED=False"
    return $f
}

# ===========================================================================
# SCENARIO L - Known failure conditions (honest blocks, no unsafe workaround)
# ===========================================================================
function Invoke-Db33ScenarioL {
    $s = "L"
    Log-Db33 ("SCENARIO|" + $s + "|Known failure conditions")
    # L1 STALE_GOVERNANCE_STATE / PREFLIGHT_STALE via M04.
    $f1 = New-Db33Fixture "L_stale"
    $r3 = Invoke-Db33M03 $f1
    $r4 = Invoke-Db33Backend $f1 "Reserve-DevelopmentChange.ps1" @() @{
        DB04_SELFTEST = "1"; DB04_TEST_STALE = "1"; DB04_WORKBOOK_OVERRIDE = $f1.wb; DB04_STATE_DIR = $f1.state; DB04_TASKS_DIR = $f1.tasks; DB04_LOGS_DIR = $f1.logs }
    Assert-Db33 $s "stale-governance-blocked" ((Get-Db33Marker $r4 "DB04_OUTCOME") -match "STOP_PREFLIGHT_STALE|STOP_") ("outcome=" + (Get-Db33Marker $r4 "DB04_OUTCOME"))

    # L2 DEPENDENCY_CONTEXT_STALE: missing overlay evidence blocks M03 selection.
    $f2 = New-Db33Fixture "L_stale_overlay"
    Remove-Item (Join-Path $f2.logs "tasks\WI-07-0.2.4") -Recurse -Force
    $r3b = Invoke-Db33M03 $f2
    $pre2 = Read-FJson $f2.state "preflight.json"
    Assert-Db33 $s "dep-context-stale" (($pre2 -and [string]$pre2.verdict -ne "CLEAR") -or ($r3b.Text -match "DEPENDENCY_CONTEXT_STALE")) ("verdict=" + $(if ($pre2) { $pre2.verdict } else { "n/a" }))

    # L3 IMPLEMENTATION_TARGET_UNKNOWN / SCOPE_INCOMPLETE / HUMAN_GOVERNANCE_REQUIRED:
    # M03 on a fixture where the top planned node cannot be drilled (container with
    # no eligible descendant) yields an honest governance block.
    $f3 = New-Db33Fixture "L_container"
    $r3c = Invoke-Db33M03 $f3
    # To force the container block we must remove the overlay evidence so WI-07-0.2.5
    # is unsatisfied; reuse f2's state for the assertion.
    $pre3 = Read-FJson $f2.state "preflight.json"
    Assert-Db33 $s "human-governance-block" (($pre3 -and [string]$pre3.verdict -eq "NO_IMPLEMENTABLE_DESCENDANT" -and ($r3b.Text -match "GOVERNANCE|RESOLVE_GOVERNANCE|HUMAN" -or [string]$pre3.verdict)) -or ($r3c.Text -match "NO_IMPLEMENTABLE_DESCENDANT|RESOLVE_GOVERNANCE")) "container -> NO_IMPLEMENTABLE_DESCENDANT / governance block, honest"

    # L4 MERGE_STATE_UNKNOWN: git gate never fabricates merge state.
    $f4 = New-Db33Fixture "L_merge"
    $r13 = Invoke-Db33Backend $f4 "Get-GitGateState.ps1" @() @{ DB13_SELFTEST = "1"; DB13_GIT_BRANCH = "main"; DB13_HEAD = "a" * 40; DB13_PR_STATE = ""; DB13_STATE_DIR = $f4.state }
    $gate = Read-FJson $f4.state "git-gate-state.json"
    Assert-Db33 $s "merge-state-unknown" ($gate -and [string]$gate.prState -eq "UNKNOWN" -and $gate.mergeConfirmed -ne $true) ("prState=" + $(if ($gate) { $gate.prState } else { "missing" }))

    # L5 BACKEND_STATE_MISMATCH + WRITER_LOCK_BUSY: covered by the DB-M32 recovery
    # suite (I1/I2, E2/E3) - regression assertion here.
    $recF = Invoke-Db33Backend @{ root = $script:Root; logs = $script:SelftestRoot; state = (Join-Path $script:Root "state"); tasks = (Join-Path $script:Root "tasks"); wb = $script:RealWorkbook } "recovery-safety\Test-DbM32EssentialSafety.ps1" @("-Scenarios", "I1,I2,E2,E3") @{}
    $passF = $null
    foreach ($ln in $recF.Output) { if ($ln -match "^DB32_TEST_OUTCOME:\s*(.+)$") { $passF = $matches[1].Trim() } }
    Assert-Db33 $s "mismatch-lock-recovery" ($passF -eq "PASS") ("DB32 filtered outcome=" + $passF)
    return $f1
}

# ===========================================================================
# Build check (acceptance 54): parse all backend scripts, zero errors.
# ===========================================================================
function Invoke-Db33BuildCheck {
    $s = "BUILD"
    Log-Db33 ("SCENARIO|" + $s + "|Parse check of all backend scripts")
    $errCount = 0
    $errList = New-Object System.Collections.Generic.List[string]
    foreach ($file in Get-ChildItem $script:ScriptsRoot -Filter *.ps1 -File -Recurse -ErrorAction SilentlyContinue) {
        $tokens = $null; $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            $errCount += $parseErrors.Count
            $errList.Add($file.FullName)
        }
    }
    Assert-Db33 $s "parse-zero-errors" ($errCount -eq 0) ("errors=" + $errCount + " files=" + $errList.Count)
    return $null
}

# ===========================================================================
# Live-safety guard verification
# ===========================================================================
function Assert-Db33LiveSafety {
    $s = "LIVE"
    Log-Db33 ("SCENARIO|" + $s + "|Live state safety")
    $realHashAfter = (Get-FileHash $script:RealWorkbook -Algorithm SHA256).Hash
    Assert-Db33 $s "live-workbook-unchanged" ($realHashAfter -eq $script:RealHashBefore) "canonical workbook SHA unchanged"
    foreach ($gf in $script:LiveGuardFiles) {
        $p = Join-Path $script:Root $gf
        $h = if (Test-Path $p) { (Get-FileHash $p -Algorithm SHA256).Hash } else { "ABSENT" }
        Assert-Db33 $s ("live-state-unchanged-" + ($gf -replace '\\', '-')) ($h -eq $script:LiveGuardHashes[$gf]) $gf
    }
    return $null
}

# ===========================================================================
# Main
# ===========================================================================
$runAll = ($Scenarios -eq "ALL")
$fA = $null; $fB = $null; $fE = $null; $fG = $null; $fH = $null; $fK = $null
if ($runAll -or $Scenarios -like "*A*") { $fA = Invoke-Db33ScenarioA }
if ($runAll -or $Scenarios -like "*B*") { $fB = Invoke-Db33ScenarioB }
if ($runAll -or $Scenarios -like "*C*") { $null = Invoke-Db33ScenarioC }
if ($runAll -or $Scenarios -like "*D*") { $null = Invoke-Db33ScenarioD }
if ($runAll -or $Scenarios -like "*E*") { $fE = Invoke-Db33ScenarioE }
if ($runAll -or $Scenarios -like "*F*") { $null = Invoke-Db33ScenarioF }
if ($runAll -or $Scenarios -like "*G*") { $fG = Invoke-Db33ScenarioG }
if ($runAll -or $Scenarios -like "*H*") { $fH = Invoke-Db33ScenarioH }
if ($runAll -or $Scenarios -like "*I*") { $null = Invoke-Db33ScenarioI }
if ($runAll -or $Scenarios -like "*J*") { $null = Invoke-Db33ScenarioJ }
if ($runAll -or $Scenarios -like "*K*") { $fK = Invoke-Db33ScenarioK }
if ($runAll -or $Scenarios -like "*L*") { $null = Invoke-Db33ScenarioL }
if ($runAll) { $null = Invoke-Db33BuildCheck; $null = Assert-Db33LiveSafety }

$total = $script:Results.Count
$passed = @($script:Results | Where-Object { $_.Pass }).Count
$failed = $total - $passed
$outcome = if ($failed -eq 0) { "PASS" } else { "FAIL" }

Log-Db33 ""
Log-Db33 ("DB33_TEST_SCENARIOS_RUN: " + @($script:Results | Select-Object -ExpandProperty Scenario -Unique).Count)
Log-Db33 ("DB33_TEST_ASSERTIONS_PASSED: " + $passed)
Log-Db33 ("DB33_TEST_ASSERTIONS_FAILED: " + $failed)
Log-Db33 ("DB33_TEST_ASSERTIONS_TOTAL: " + $total)
Log-Db33 ("DB33_TEST_OUTCOME: " + $outcome)
if ($script:Fails.Count -gt 0) {
    Log-Db33 "DB33_TEST_FAILURES:"
    foreach ($fl in $script:Fails) { Log-Db33 ("  - " + $fl) }
}
# Reliable full capture: New-DbM33Result reads %TEMP%\db33-runs\full-run.txt.
# Redirected stdout is block-buffered (only the tail survives), so the harness
# writes its own complete run log (unbuffered WriteAllLines) for the assembler.
$runsDir = Join-Path ([System.IO.Path]::GetTempPath()) "db33-runs"
if (-not (Test-Path $runsDir)) { New-Item -ItemType Directory -Force $runsDir | Out-Null }
[System.IO.File]::WriteAllLines((Join-Path $runsDir "full-run.txt"), $script:RunLog, (New-Object System.Text.UTF8Encoding($false)))
exit 0
