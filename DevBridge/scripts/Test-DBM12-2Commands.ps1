# Test-DBM12-2Commands.ps1
# DevBridge DB-M12.2 fixture driver. Runs the 9 reusable lifecycle backend
# commands (Run-Verification / New-ClaudeReviewPackage / Set-ClaudeReviewResult /
# New-CorrectionContext / Complete-GovernedCycle / Invoke-WorkbookValidation /
# New-ClaudeWorkbookReviewPackage / Get-GitGateState / Get-CurrentLifecycleState)
# against throwaway state/tasks dirs and workbook copies under logs\selftest\.
#
# Every scenario uses a GENERIC fixture identity (N-01-0.1 / CHG-20260831-0xx) so
# the suite proves the commands are generic - nothing is hard-coded to a prior
# WI/CHG work item.
#
# Invariants asserted at the end (nothing outside the fixtures may change):
#   I1  real workbook SHA256 unchanged;
#   I2  Nexus repo git state delta == 0;
#   I3  live state\current-task.json + state\claude-review.json unchanged;
#   I4  DB-M23 files (scripts\ai-routing, design\ai-routing) unchanged;
#   I5  no prior WI-07 / CHG-20260830-017 / ACT-20260830-018 identity hard-coded
#       in the reusable scripts;
#   I6  the DevBridge solution still builds.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:Cfg = Get-Content (Join-Path $script:Root "config\devbridge.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$script:RealWorkbook = $script:Cfg.developmentControlWorkbook
$script:SelftestRoot = Join-Path $script:Root "logs\selftest"
if (-not (Test-Path $script:SelftestRoot)) { New-Item -ItemType Directory -Force -Path $script:SelftestRoot | Out-Null }
$db12Root = Join-Path $script:SelftestRoot "db12"
if (Test-Path $db12Root) { Remove-Item $db12Root -Recurse -Force }
New-Item -ItemType Directory -Force -Path $db12Root | Out-Null

# Shared library (array-safe JSON) + read-only workbook library (for read-backs).
. (Join-Path $PSScriptRoot "Set-DevBridgeStateEntry.ps1")
. (Join-Path $PSScriptRoot "Read-DevelopmentControl.ps1")

function Get-Hash([string]$p) { return (Get-FileHash $p -Algorithm SHA256).Hash }

$script:RealHashBefore = Get-Hash $script:RealWorkbook
$script:RepoStatusBefore = @(& git -C "C:\Personal\Nexus.Developer" status --porcelain=v1 2>$null)
$script:LiveTaskHashBefore = Get-Hash (Join-Path $script:Root "state\current-task.json")
$script:LiveClaudeHashBefore = Get-Hash (Join-Path $script:Root "state\claude-review.json")
$script:Db23Before = @()
foreach ($f in @(Get-ChildItem (Join-Path $script:Root "scripts\ai-routing") -Recurse -File -ErrorAction SilentlyContinue)) { $script:Db23Before += $f.FullName.Substring($script:Root.Length) + "=" + (Get-Hash $f.FullName) }
foreach ($f in @(Get-ChildItem (Join-Path $script:Root "design\ai-routing") -Recurse -File -ErrorAction SilentlyContinue)) { $script:Db23Before += $f.FullName.Substring($script:Root.Length) + "=" + (Get-Hash $f.FullName) }

$script:Results = @()
$script:Fails = New-Object System.Collections.Generic.List[string]

function Assert-True([string]$label, [bool]$cond, [string]$detail) {
    $row = New-Object PSCustomObject
    $row | Add-Member NoteProperty -Name Scenario -Value $label
    $row | Add-Member NoteProperty -Name Pass -Value $cond
    $row | Add-Member NoteProperty -Name Detail -Value $detail
    $script:Results += $row
    if (-not $cond) {
        $script:Fails.Add(("{0}: {1}" -f $label, $detail))
        Write-Output ("  [FAIL] {0} - {1}" -f $label, $detail)
    } else {
        Write-Output ("  [PASS] {0}" -f $label)
    }
}

# --- fixture helpers ---------------------------------------------------------
function New-Fixture([string]$name, [string]$status, [string]$nextAction, [string]$nodeId, [string]$changeId, [string]$mode = "TRIAL") {
    $outDir = Join-Path $script:SelftestRoot ("db12\" + $name)
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $stateDir = Join-Path $outDir "state"; $tasksDir = Join-Path $outDir "tasks"
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null
    $wbCopy = Join-Path $outDir "workbook.xlsx"
    Copy-Item $script:RealWorkbook $wbCopy -Force
    $cur = [ordered]@{
        nodeId = $nodeId; taskId = $nodeId; name = ("DB-M12.2 fixture " + $name)
        nodeType = "WorkItem"; phase = "P0"; layer = "App"; changeId = $changeId
        status = $status; nextAllowedAction = $nextAction; selectedAt = "2026-08-31T00:00:00Z"
        mode = $mode
    }
    Write-DevBridgeJson (Join-Path $stateDir "current-task.json") $cur | Out-Null
    return @{ outDir = $outDir; stateDir = $stateDir; tasksDir = $tasksDir; wbCopy = $wbCopy; changeId = $changeId }
}

function Read-FixtureTask([hashtable]$fixture) {
    $raw = [System.IO.File]::ReadAllText((Join-Path $fixture.stateDir "current-task.json"))
    return $raw | ConvertFrom-Json
}

function Write-FixtureJson([hashtable]$fixture, [string]$relPath, $obj) {
    Write-DevBridgeJson (Join-Path $fixture.stateDir $relPath) $obj | Out-Null
}

function Write-FixtureMd([hashtable]$fixture, [string]$relPath, [string]$content) {
    [System.IO.File]::WriteAllText((Join-Path $fixture.tasksDir $relPath), $content, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Script([string]$name, [string]$prefix, [hashtable]$fixture, [hashtable]$envOverrides) {
    $engine = Join-Path $PSScriptRoot $name
    Set-Item ("env:" + $prefix + "_STATE_DIR") $fixture.stateDir
    Set-Item ("env:" + $prefix + "_TASKS_DIR") $fixture.tasksDir
    foreach ($k in $envOverrides.Keys) { Set-Item ("env:" + $k) ([string]$envOverrides[$k]) }
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine 2>&1)
    $ErrorActionPreference = $oldEAP
    $out = @($out | ForEach-Object { "$_" })
    $envKeys = @()
    foreach ($k in $envOverrides.Keys) { $envKeys += $k }
    $envKeys += ($prefix + "_STATE_DIR"); $envKeys += ($prefix + "_TASKS_DIR")
    foreach ($k in $envKeys) { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue }

    $res = @{ outcome = "NO_OUTCOME"; pass = $false; resultCode = ""; wbModified = $false; gitModified = $false; human = $false; humanType = ""; evidence = @(); output = ($out -join "`n") }
    $ol = $out | Select-String -Pattern ('^' + $prefix + '_OUTCOME:\s*') | Select-Object -First 1
    if ($ol) { $res.outcome = ($ol.Line -replace ('^' + $prefix + '_OUTCOME:\s*'), '') }
    $pl = $out | Select-String -Pattern ('^' + $prefix + '_RESULT_PASS: True') | Select-Object -First 1
    $res.pass = ($null -ne $pl)
    $rcl = $out | Select-String -Pattern ('^' + $prefix + '_RESULT_CODE:\s*') | Select-Object -First 1
    if ($rcl) { $res.resultCode = ($rcl.Line -replace ('^' + $prefix + '_RESULT_CODE:\s*'), '') }
    $wml = $out | Select-String -Pattern ('^' + $prefix + '_WORKBOOK_MODIFIED: True') | Select-Object -First 1
    $res.wbModified = ($null -ne $wml)
    $gml = $out | Select-String -Pattern ('^' + $prefix + '_GIT_MODIFIED: True') | Select-Object -First 1
    $res.gitModified = ($null -ne $gml)
    $hl = $out | Select-String -Pattern ('^' + $prefix + '_REQUIRES_HUMAN_ACTION: True') | Select-Object -First 1
    $res.human = ($null -ne $hl)
    $htl = $out | Select-String -Pattern ('^' + $prefix + '_HUMAN_ACTION_TYPE:\s*') | Select-Object -First 1
    if ($htl) { $res.humanType = ($htl.Line -replace ('^' + $prefix + '_HUMAN_ACTION_TYPE:\s*'), '').Trim() }
    foreach ($el in @($out | Select-String -Pattern ('^' + $prefix + '_EVIDENCE:\s*(.+)$'))) {
        if ($el.Matches.Count -gt 0) { $res.evidence += [string]$el.Matches[0].Groups[1].Value }
    }
    return $res
}

function Has-Property($obj, [string]$key) {
    return ($null -ne $obj -and ($obj.PSObject.Properties.Name -contains $key))
}

# Stamps the DB-M07 current-manifest evidence chain into a fixture so the DB-M08
# record-time gate (Test-CrmManifestCurrent) is satisfiable with a GENERIC identity:
# current-task dbM07 ready stamp + verification.json PASS (verifiedAtUtc) + a
# CLAUDE_REVIEW_PACKAGE.md bound to the deterministic manifest id. This mirrors what
# a real DB-M06 + DB-M07 run leaves behind, without any real reservation/repo.
function Add-CrmCurrentEvidence([hashtable]$fixture, [string]$verifiedAtUtc) {
    $id = "DB07-MANIFEST|" + $fixture.changeId + "|N-01-0.1|" + $verifiedAtUtc
    Set-DevBridgeStateEntry (Join-Path $fixture.stateDir "current-task.json") @{ dbM07 = [ordered]@{ ready = $true; nodeId = "N-01-0.1"; changeId = $fixture.changeId; manifestId = $id } } | Out-Null
    Write-FixtureJson $fixture "verification.json" @{ milestone = "DB-M06"; nodeId = "N-01-0.1"; changeId = $fixture.changeId; primaryResult = "VERIFICATION_PASSED"; verifiedAtUtc = $verifiedAtUtc }
    Write-FixtureMd $fixture "CLAUDE_REVIEW_PACKAGE.md" ("# Claude Review Manifest`nNode: N-01-0.1`nChange: " + $fixture.changeId + "`nManifest ID: " + $id + "`n`nCURRENT_TASK_DELTA files: NONE`n")
}

# --- M06 RUN_VERIFICATION ----------------------------------------------------
Write-Output "== M06 Run-Verification =="
$f = New-Fixture "m06_pass" "AWAITING_CHATGPT_PROMPT" "COPY_TO_CHATGPT" "N-01-0.1" "CHG-20260831-010"
$r = Invoke-Script "Run-Verification.ps1" "DB06" $f @{ DB06_SELFTEST = "1" }
Assert-True "M06 S1 forced PASS -> VERIFICATION_PASSED" ($r.outcome -eq "VERIFICATION_PASSED" -and $r.pass) ("got " + $r.outcome)
Assert-True "M06 S1 never modifies workbook/source/git" (-not $r.wbModified -and -not $r.gitModified) "flags set"
$t1 = Read-FixtureTask $f
Assert-True "M06 S1 transitions to VERIFIED" ($t1.status -eq "VERIFIED" -and $t1.nextAllowedAction -eq "CLAUDE_REVIEW") ("got " + $t1.status)
$v1 = Get-Content (Join-Path $f.stateDir "verification.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True "M06 S1 generic fixture identity used (no WI-07)" ($v1.nodeId -eq "N-01-0.1" -and $v1.primaryResult -eq "VERIFICATION_PASSED") ("nodeId=" + $v1.nodeId)
Assert-True "M06 S1 report written" (Test-Path (Join-Path $f.tasksDir "VERIFICATION_REPORT.md")) "missing"

$f2 = New-Fixture "m06_fail" "AWAITING_CHATGPT_PROMPT" "COPY_TO_CHATGPT" "N-01-0.1" "CHG-20260831-011"
$r2 = Invoke-Script "Run-Verification.ps1" "DB06" $f2 @{ DB06_SELFTEST = "1"; DB06_FAIL = "1" }
Assert-True "M06 S2 forced FAIL -> VERIFICATION_FAILED, pass false" ($r2.outcome -eq "VERIFICATION_FAILED" -and -not $r2.pass) ("got " + $r2.outcome)
$t2 = Read-FixtureTask $f2
Assert-True "M06 S2 no forced lifecycle transition on fail" ($t2.status -eq "AWAITING_CHATGPT_PROMPT") ("got " + $t2.status)

# --- M07 CREATE_CLAUDE_REVIEW_PACKAGE ----------------------------------------
# A real package is only produced for a reserved repo with a governed brief of the
# CURRENT task (reservation.json + reachable repo baselines + DEEPSEEK_PROMPT.md).
# A generic fixture has no such scope chain, so DB-M07 must report NOT_READY and
# NEVER leave a copyable manifest behind (no stale package to record against). The
# positive create path is covered separately (real DB-M07 runs + the
# DevBridge.Tests FakeScriptRunner scenario).
Write-Output "== M07 New-ClaudeReviewPackage (readiness gate) =="
$f = New-Fixture "m07_notready" "VERIFIED" "CLAUDE_REVIEW" "N-01-0.1" "CHG-20260831-012"
Write-FixtureJson $f "verification.json" @{ milestone = "DB-M06"; nodeId = "N-01-0.1"; changeId = "CHG-20260831-012"; primaryResult = "VERIFICATION_PASSED"; verifiedAtUtc = "2026-08-31T02:00:00Z" }
$r = Invoke-Script "New-ClaudeReviewPackage.ps1" "DB07" $f @{}
Assert-True "M07 S3 generic fixture (no scope chain) -> CLAUDE_REVIEW_PACKAGE_NOT_READY" ($r.outcome -eq "CLAUDE_REVIEW_PACKAGE_NOT_READY" -and -not $r.pass) ("got " + $r.outcome)
Assert-True "M07 S3 never writes a copyable manifest (no stale package)" (-not (Test-Path (Join-Path $f.tasksDir "CLAUDE_REVIEW_PACKAGE.md")) -and -not (Test-Path (Join-Path $f.tasksDir "REVIEW_PACKET.md"))) "package file present"
$t = Read-FixtureTask $f
Assert-True "M07 S3 lifecycle unchanged (VERIFIED) + dbM07 ready=false recorded" ($t.status -eq "VERIFIED" -and -not $t.dbM07.ready -and $t.dbM07.nodeId -eq "N-01-0.1") ("got " + $t.status + " dbM07.ready=" + $t.dbM07.ready)
$r3 = Invoke-Script "New-ClaudeReviewPackage.ps1" "DB07" $f @{}
Assert-True "M07 S4 re-run NOT_READY is not a false REUSED" ($r3.outcome -eq "CLAUDE_REVIEW_PACKAGE_NOT_READY" -and -not $r3.pass) ("got " + $r3.outcome)

# --- M08 RECORD_CLAUDE_RESULT ------------------------------------------------
# Every recorded decision must be made against the CURRENT CLAUDE REVIEW MANIFEST
# (DB-M07 identity gate). The fixtures below satisfy that gate with a GENERIC
# identity (dbM07 ready stamp + verification PASS + bound manifest file) so each
# route is proven independent of any real WI/CHG work item.
Write-Output "== M08 Set-ClaudeReviewResult =="
$f = New-Fixture "m08_pass" "VERIFIED" "CLAUDE_REVIEW" "N-01-0.1" "CHG-20260831-013"
Add-CrmCurrentEvidence $f "2026-08-31T02:00:00Z"
$r = Invoke-Script "Set-ClaudeReviewResult.ps1" "DB08" $f @{ DB08_DECISION = "PASS"; DB08_REVIEW_TEXT = "Decision: PASS. Looks good for trial." }
Assert-True "M08 S5 PASS trial -> recorded + routed to trial stop" ($r.outcome -eq "CLAUDE_RESULT_RECORDED" -and $r.pass -and -not $r.human) ("got " + $r.outcome + " human=" + $r.human)
$t = Read-FixtureTask $f
Assert-True "M08 S5 trial route CLAUDE_REVIEW_PASSED_TRIAL / TRIAL_CYCLE_SAFE_STOP" ($t.status -eq "CLAUDE_REVIEW_PASSED_TRIAL" -and $t.nextAllowedAction -eq "TRIAL_CYCLE_SAFE_STOP") ("got " + $t.status + "/" + $t.nextAllowedAction)
$c5 = Get-Content (Join-Path $f.stateDir "claude-review.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True "M08 S5 claude-review.json decision/trial/route recorded" ($c5.decision -eq "PASS" -and $c5.trialMode -and $c5.routeLifecycleState -eq "CLAUDE_REVIEW_PASSED_TRIAL") ("got " + $c5.decision)
$r6 = Invoke-Script "Set-ClaudeReviewResult.ps1" "DB08" $f @{ DB08_DECISION = "PASS"; DB08_REVIEW_TEXT = "Decision: PASS. Looks good for trial." }
Assert-True "M08 S6 duplicate decision is REUSED (no duplicate evidence)" ($r6.outcome -eq "REUSED" -and $r6.pass) ("got " + $r6.outcome)

$f = New-Fixture "m08_real" "VERIFIED" "CLAUDE_REVIEW" "N-01-0.1" "CHG-20260831-014" "REAL_NEXUS_DEVELOPMENT"
Add-CrmCurrentEvidence $f "2026-08-31T03:00:00Z"
$r = Invoke-Script "Set-ClaudeReviewResult.ps1" "DB08" $f @{ DB08_DECISION = "PASS"; DB08_REVIEW_TEXT = "Review decision: PASS. Approved for real change." }
$t = Read-FixtureTask $f
Assert-True "M08 S7 PASS real -> CLAUDE_REVIEW_PASSED_REAL / AWAITING_HUMAN_PR" ($r.outcome -eq "CLAUDE_RESULT_RECORDED" -and $t.status -eq "CLAUDE_REVIEW_PASSED_REAL" -and $t.nextAllowedAction -eq "AWAITING_HUMAN_PR") ("got " + $t.status)

$f = New-Fixture "m08_fix" "VERIFIED" "CLAUDE_REVIEW" "N-01-0.1" "CHG-20260831-015"
Add-CrmCurrentEvidence $f "2026-08-31T04:00:00Z"
$r = Invoke-Script "Set-ClaudeReviewResult.ps1" "DB08" $f @{ DB08_DECISION = "FIX"; DB08_REVIEW_TEXT = "### Review decision: FIX - Row 9 needs a correction." }
$t = Read-FixtureTask $f
$c8 = Get-Content (Join-Path $f.stateDir "claude-review.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True "M08 S8 FIX -> DB_M09_FIX_REQUIRED / CORRECT_CURRENT_ATTEMPT + dbM09Required" ($t.status -eq "DB_M09_FIX_REQUIRED" -and $t.nextAllowedAction -eq "CORRECT_CURRENT_ATTEMPT" -and $c8.dbM09Required) ("got " + $t.status)

$f = New-Fixture "m08_gov" "VERIFIED" "CLAUDE_REVIEW" "N-01-0.1" "CHG-20260831-016"
Add-CrmCurrentEvidence $f "2026-08-31T05:00:00Z"
$r = Invoke-Script "Set-ClaudeReviewResult.ps1" "DB08" $f @{ DB08_DECISION = "GOVERNANCE_ISSUE"; DB08_REVIEW_TEXT = "**Decision:** GOVERNANCE_ISSUE - Roadmap boundary concern." }
$t = Read-FixtureTask $f
Assert-True "M08 S9 GOVERNANCE_ISSUE -> human governance review" ($t.status -eq "GOVERNANCE_ISSUE" -and $r.human -and $r.humanType -eq "HUMAN_GOVERNANCE_REVIEW") ("got " + $t.status + " type=" + $r.humanType)

$f = New-Fixture "m08_hdr" "VERIFIED" "CLAUDE_REVIEW" "N-01-0.1" "CHG-20260831-017"
Add-CrmCurrentEvidence $f "2026-08-31T06:00:00Z"
$r = Invoke-Script "Set-ClaudeReviewResult.ps1" "DB08" $f @{ DB08_DECISION = "HUMAN_DECISION_REQUIRED"; DB08_REVIEW_TEXT = "Decision: HUMAN_DECISION_REQUIRED - a human must decide." }
$t = Read-FixtureTask $f
Assert-True "M08 S10 HUMAN_DECISION_REQUIRED -> human decision" ($t.status -eq "HUMAN_DECISION_REQUIRED" -and $r.human -and $r.humanType -eq "HUMAN_DECISION") ("got " + $t.status)

# STOP_INVALID_DECISION fires before the manifest gate, so m08_bad needs NO evidence.
$f = New-Fixture "m08_bad" "VERIFIED" "CLAUDE_REVIEW" "N-01-0.1" "CHG-20260831-018"
$r = Invoke-Script "Set-ClaudeReviewResult.ps1" "DB08" $f @{ DB08_DECISION = "BOGUS"; DB08_REVIEW_TEXT = "x" }
$t = Read-FixtureTask $f
Assert-True "M08 S11 invalid decision -> STOP_INVALID_DECISION, no transition" ($r.outcome -eq "STOP_INVALID_DECISION" -and -not $r.pass -and $t.status -eq "VERIFIED") ("got " + $r.outcome + " status=" + $t.status)

# --- M09 CREATE_CORRECTION_CONTEXT -------------------------------------------
Write-Output "== M09 New-CorrectionContext =="
$f = New-Fixture "m09" "DB_M09_FIX_REQUIRED" "CORRECT_CURRENT_ATTEMPT" "N-01-0.1" "CHG-20260831-019"
Write-FixtureJson $f "claude-review.json" @{ nodeId = "N-01-0.1"; changeId = "CHG-20260831-019"; decision = "FIX"; dbM09Required = $true; reviewText = "Fix row 9." }
$r = Invoke-Script "New-CorrectionContext.ps1" "DB09" $f @{}
Assert-True "M09 S12 fix context created" ($r.outcome -eq "FIX_CONTEXT_CREATED" -and $r.pass) ("got " + $r.outcome)
Assert-True "M09 S12 FIX_CONTEXT.md carries fix-task rule + scope note" ((Test-Path (Join-Path $f.tasksDir "FIX_CONTEXT.md")) -and ((Get-Content (Join-Path $f.tasksDir "FIX_CONTEXT.md") -Raw) -match "CORRECT_CURRENT_ATTEMPT") -and ((Get-Content (Join-Path $f.tasksDir "FIX_CONTEXT.md") -Raw) -match "never widened silently")) "missing"
$t = Read-FixtureTask $f
Assert-True "M09 S12 existing task preserved (status + identity unchanged)" ($t.status -eq "DB_M09_FIX_REQUIRED" -and $t.nodeId -eq "N-01-0.1" -and $t.name -match "fixture m09") ("got " + $t.status)
$r9 = Invoke-Script "New-CorrectionContext.ps1" "DB09" $f @{}
Assert-True "M09 S13 re-run is idempotent REUSED" ($r9.outcome -eq "REUSED" -and $r9.pass) ("got " + $r9.outcome)

# --- DB-M15 RECONCILE_CORRECTION ----------------------------------------------
Write-Output "== DB-M15 Confirm-CorrectedImplementation =="
# Real M09 -> DB-M15 sequence: a FIX context is created first (dbM09 stamped), then
# the externally-implemented CORRECT_CURRENT_ATTEMPT is reconciled as a detected delta.
$f = New-Fixture "m15_detected" "DB_M09_FIX_REQUIRED" "CORRECT_CURRENT_ATTEMPT" "N-01-0.1" "CHG-20260831-040"
Write-FixtureJson $f "claude-review.json" @{ nodeId = "N-01-0.1"; changeId = "CHG-20260831-040"; decision = "FIX"; dbM09Required = $true; reviewText = "Fix row 9." }
$r09b = Invoke-Script "New-CorrectionContext.ps1" "DB09" $f @{}
Assert-True "M15 S27a M09 fix context pre-stamped" ($r09b.outcome -eq "FIX_CONTEXT_CREATED") ("got " + $r09b.outcome)
$r = Invoke-Script "Confirm-CorrectedImplementation.ps1" "DB15" $f @{ DB15_SELFTEST = "1"; DB15_SELFTEST_RESULT = "CORRECTION_DELTA_DETECTED"; DB15_SELFTEST_DELTA = "a.tsx|b.tsx" }
Assert-True "M15 S27 DETECTED -> reconciliation pass" ($r.outcome -eq "CORRECTION_DELTA_DETECTED" -and $r.pass) ("got " + $r.outcome)
Assert-True "M15 S27 read-only (no workbook/source/git)" (-not $r.wbModified -and -not $r.gitModified) "flags set"
$t = Read-FixtureTask $f
Assert-True "M15 S27 lifecycle stays DB_M09_FIX_REQUIRED (no re-run/verification)" ($t.status -eq "DB_M09_FIX_REQUIRED" -and $t.nextAllowedAction -eq "CORRECT_CURRENT_ATTEMPT") ("got " + $t.status)
$c15 = Get-Content (Join-Path $f.stateDir "current-task.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True "M15 S27 dbM09.correctionReconciled stamped with detected result" ($c15.dbM09.correctionReconciled.result -eq "CORRECTION_DELTA_DETECTED") ("got " + $c15.dbM09.correctionReconciled.result)
Assert-True "M15 S27 dbM09 preserved (nodeId + changeId not clobbered)" ($c15.dbM09.nodeId -eq "N-01-0.1" -and $c15.dbM09.changeId -eq "CHG-20260831-040") ("got " + $c15.dbM09.nodeId)
$deltaLines = @($r.output -split "`n" | Where-Object { $_ -match '^DB15_DELTA_FILE:' })
Assert-True "M15 S27 delta files emitted per repo" ($deltaLines.Count -ge 2) ("delta lines=" + $deltaLines.Count)

$f = New-Fixture "m15_none" "DB_M09_FIX_REQUIRED" "CORRECT_CURRENT_ATTEMPT" "N-01-0.1" "CHG-20260831-041"
Write-FixtureJson $f "claude-review.json" @{ nodeId = "N-01-0.1"; changeId = "CHG-20260831-041"; decision = "FIX"; dbM09Required = $true }
$r = Invoke-Script "Confirm-CorrectedImplementation.ps1" "DB15" $f @{ DB15_SELFTEST = "1"; DB15_SELFTEST_RESULT = "CORRECTION_DELTA_NONE" }
Assert-True "M15 S28 NONE -> no incremental delta, pass true" ($r.outcome -eq "CORRECTION_DELTA_NONE" -and $r.pass) ("got " + $r.outcome)
$c15b = Get-Content (Join-Path $f.stateDir "current-task.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$db9b = $null
if ($c15b.PSObject.Properties.Name -contains "dbM09") { $db9b = $c15b.dbM09 }
Assert-True "M15 S28 no reconciliation stamp written" (-not (Has-Property $db9b "correctionReconciled")) "stamp present"

$f = New-Fixture "m15_badstate" "VERIFIED" "CLAUDE_REVIEW" "N-01-0.1" "CHG-20260831-042"
$r = Invoke-Script "Confirm-CorrectedImplementation.ps1" "DB15" $f @{ DB15_SELFTEST = "1"; DB15_SELFTEST_RESULT = "CORRECTION_DELTA_DETECTED" }
Assert-True "M15 S29 reconcile only from DB_M09_FIX_REQUIRED" ($r.outcome -eq "STOP_INVALID_LIFECYCLE_STATE" -and -not $r.pass) ("got " + $r.outcome)

# --- M10 RUN_GOVERNED_COMPLETION ---------------------------------------------
Write-Output "== M10 Complete-GovernedCycle =="
$f = New-Fixture "m10_trial" "CLAUDE_REVIEW_PASSED_TRIAL" "TRIAL_CYCLE_SAFE_STOP" "N-01-0.1" "CHG-20260831-020"
$r = Invoke-Script "Complete-GovernedCycle.ps1" "DB10" $f @{ DB10_SELFTEST = "1"; DB10_M06_PASS = "True"; DB10_CLAUDE_PASS = "True"; DB10_GIT_MERGE_CONFIRMED = "True"; DB10_FINGERPRINT_BEFORE = "FP-A"; DB10_FINGERPRINT_AFTER = "FP-A" }
Assert-True "M10 S14 TRIAL -> TRIAL_COMPLETION_NOT_APPLICABLE, no write" ($r.outcome -eq "TRIAL_COMPLETION_NOT_APPLICABLE" -and $r.pass -and -not $r.wbModified) ("got " + $r.outcome)
Assert-True "M10 S14 no completion evidence written" (-not (Test-Path (Join-Path $f.stateDir "completion.json"))) "completion.json present"

$f = New-Fixture "m10_merge" "READY_FOR_GOVERNED_COMPLETION" "RUN_GOVERNED_COMPLETION" "N-01-0.1" "CHG-20260831-021" "REAL_NEXUS_DEVELOPMENT"
$r = Invoke-Script "Complete-GovernedCycle.ps1" "DB10" $f @{ DB10_SELFTEST = "1"; DB10_M06_PASS = "True"; DB10_CLAUDE_PASS = "True"; DB10_GIT_MERGE_CONFIRMED = "False"; DB10_FINGERPRINT_BEFORE = "FP-A"; DB10_FINGERPRINT_AFTER = "FP-A" }
Assert-True "M10 S15 merge gate unmet -> STOP_HUMAN_GIT_MERGE_GATE_PENDING" ($r.outcome -eq "STOP_HUMAN_GIT_MERGE_GATE_PENDING" -and -not $r.pass) ("got " + $r.outcome)
Assert-True "M10 S15 requires human action HUMAN_GIT_MERGE, no write" ($r.human -and $r.humanType -eq "HUMAN_GIT_MERGE" -and -not $r.wbModified) ("human=" + $r.human + " type=" + $r.humanType)

$f = New-Fixture "m10_ok" "READY_FOR_GOVERNED_COMPLETION" "RUN_GOVERNED_COMPLETION" "N-01-0.1" "CHG-20260831-022" "REAL_NEXUS_DEVELOPMENT"
$r = Invoke-Script "Complete-GovernedCycle.ps1" "DB10" $f @{ DB10_SELFTEST = "1"; DB10_M06_PASS = "True"; DB10_CLAUDE_PASS = "True"; DB10_GIT_MERGE_CONFIRMED = "True"; DB10_FINGERPRINT_BEFORE = "FP-A"; DB10_FINGERPRINT_AFTER = "FP-A" }
Assert-True "M10 S16 eligible -> COMPLETED (selftest, no write)" ($r.outcome -eq "COMPLETED" -and $r.pass -and -not $r.wbModified) ("got " + $r.outcome)
$t = Read-FixtureTask $f
Assert-True "M10 S16 transitions to COMPLETION_WRITTEN" ($t.status -eq "COMPLETION_WRITTEN" -and $t.nextAllowedAction -eq "CONTROL_VALIDATION") ("got " + $t.status)
$comp = Get-Content (Join-Path $f.stateDir "completion.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True "M10 S16 completion evidence + fingerprint preserved" ((Test-Path (Join-Path $f.stateDir "completion.json")) -and $comp.fingerprintGuard.preserved -and $comp.changeId -eq "CHG-20260831-022") "missing/incomplete"

$f = New-Fixture "m10_fp" "READY_FOR_GOVERNED_COMPLETION" "RUN_GOVERNED_COMPLETION" "N-01-0.1" "CHG-20260831-023" "REAL_NEXUS_DEVELOPMENT"
$r = Invoke-Script "Complete-GovernedCycle.ps1" "DB10" $f @{ DB10_SELFTEST = "1"; DB10_M06_PASS = "True"; DB10_CLAUDE_PASS = "True"; DB10_GIT_MERGE_CONFIRMED = "True"; DB10_FINGERPRINT_BEFORE = "FP-A"; DB10_FINGERPRINT_AFTER = "FP-B" }
Assert-True "M10 S17 fingerprint drift -> STOP_ROADMAP_STRUCTURE_WRITE_PROHIBITED" ($r.outcome -eq "STOP_ROADMAP_STRUCTURE_WRITE_PROHIBITED" -and -not $r.pass -and -not $r.wbModified) ("got " + $r.outcome)
Assert-True "M10 S17 human governance review surfaced" ($r.human -and $r.humanType -eq "HUMAN_GOVERNANCE_REVIEW") ("type=" + $r.humanType)

# M10 S18: REAL real-apply against a workbook COPY (authoritative workbook untouched).
Write-Output "== M10 real apply (workbook copy) =="
$f = New-Fixture "m10_real" "READY_FOR_GOVERNED_COMPLETION" "RUN_GOVERNED_COMPLETION" "N-01-0.1" "CHG-20260831-024" "REAL_NEXUS_DEVELOPMENT"
Set-DevBridgeStateEntry (Join-Path $f.stateDir "current-task.json") @{ gitLifecycleState = "MERGED" } | Out-Null
Write-FixtureJson $f "verification.json" @{ milestone = "DB-M06"; nodeId = "N-01-0.1"; changeId = "CHG-20260831-024"; primaryResult = "VERIFICATION_PASSED"; trialMode = $false }
Write-FixtureJson $f "claude-review.json" @{ nodeId = "N-01-0.1"; changeId = "CHG-20260831-024"; decision = "PASS"; dbM09Required = $false; trialMode = $false; routeLifecycleState = "CLAUDE_REVIEW_PASSED_REAL" }
$script:DevControlWorkbook = $f.wbCopy
$rows = @(Get-SheetRows "Activity Log" 4 5 5000)
$maxRow = 0
foreach ($rw in $rows) { $rn = [int]$rw.Row; if ($rn -gt $maxRow) { $maxRow = $rn } }
$newRow = $maxRow + 1
$marker = "DB-M12-2-REAL-" + ([Guid]::NewGuid().ToString("N").Substring(0, 8))
$plan = [ordered]@{
    changeId = "CHG-20260831-024"
    operations = @( [ordered]@{ sheet = "Activity Log"; rows = @( [ordered]@{ row = $newRow; cells = [ordered]@{ A = $marker; E = "read-back" } } ) } )
}
Write-DevBridgeJson (Join-Path $f.stateDir "sheet-update-plan.json") $plan
$r = Invoke-Script "Complete-GovernedCycle.ps1" "DB10" $f @{ DB10_WORKBOOK_OVERRIDE = $f.wbCopy }
Assert-True "M10 S18 real apply -> COMPLETED with workbook write" ($r.outcome -eq "COMPLETED" -and $r.pass -and $r.wbModified) ("got " + $r.outcome + " wb=" + $r.wbModified)
$t = Read-FixtureTask $f
Assert-True "M10 S18 status COMPLETION_WRITTEN" ($t.status -eq "COMPLETION_WRITTEN") ("got " + $t.status)
$comp = Get-Content (Join-Path $f.stateDir "completion.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True "M10 S18 completion evidence present with fingerprint preserved" ($comp.changeId -eq "CHG-20260831-024" -and $comp.fingerprintGuard.preserved -and $comp.workbookModified) "incomplete"
$bk = @(Get-ChildItem (Join-Path $f.stateDir "backups") -Filter *.xlsx -File -ErrorAction SilentlyContinue)
Assert-True "M10 S18 backup created before the write" ($bk.Count -ge 1) ("backups=" + $bk.Count)
$rp = @(Get-SheetRows "Activity Log" 4 5 5000 | Where-Object { $_.Row -eq $newRow })
$readBack = ""
if ($rp.Count -eq 1) { $readBack = [string](Get-Value "Activity Log" $rp[0] 4 "Activity ID") }
Assert-True "M10 S18 planned cell read back after write" ($readBack -eq $marker) ("got '" + $readBack + "'")
$script:DevControlWorkbook = $script:RealWorkbook
$r19 = Invoke-Script "Complete-GovernedCycle.ps1" "DB10" $f @{ DB10_WORKBOOK_OVERRIDE = $f.wbCopy }
Assert-True "M10 S19 duplicate completion is REUSED (no re-write)" ($r19.outcome -eq "REUSED" -and $r19.pass -and -not $r19.wbModified) ("got " + $r19.outcome)

# --- M11 VALIDATE_WORKBOOK ---------------------------------------------------
Write-Output "== M11 Invoke-WorkbookValidation =="
$f = New-Fixture "m11" "COMPLETION_WRITTEN" "CONTROL_VALIDATION" "N-01-0.1" "CHG-20260831-025"
Write-FixtureJson $f "completion.json" @{ nodeId = "N-01-0.1"; changeId = "CHG-20260831-025"; completedAtUtc = "2026-08-31T00:00:00Z" }
$r = Invoke-Script "Invoke-WorkbookValidation.ps1" "DB11" $f @{ DB11_SELFTEST = "1"; DB11_VALID = "1" }
Assert-True "M11 S20 valid -> CONTROL_VALIDATED" ($r.outcome -eq "CONTROL_VALIDATED" -and $r.pass -and -not $r.wbModified) ("got " + $r.outcome)
$t = Read-FixtureTask $f
$cons = Get-Content (Join-Path $f.stateDir "workbook-consistency.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True "M11 S20 transitions to CONTROL_VALIDATED with PASS evidence" ($t.status -eq "CONTROL_VALIDATED" -and $cons.controlValidationResult -eq "PASS") ("got " + $t.status)

$f = New-Fixture "m11_bad" "COMPLETION_WRITTEN" "CONTROL_VALIDATION" "N-01-0.1" "CHG-20260831-026"
Write-FixtureJson $f "completion.json" @{ nodeId = "N-01-0.1"; changeId = "CHG-20260831-026" }
$r = Invoke-Script "Invoke-WorkbookValidation.ps1" "DB11" $f @{ DB11_SELFTEST = "1"; DB11_VALID = "0" }
$t = Read-FixtureTask $f
Assert-True "M11 S21 invalid -> CONTROL_VALIDATION_FAILED, pass false" ($r.outcome -eq "CONTROL_VALIDATION_FAILED" -and -not $r.pass -and $t.status -eq "CONTROL_VALIDATION_FAILED") ("got " + $r.outcome)

# --- DB12 CREATE_CLAUDE_WORKBOOK_REVIEW_PACKAGE ------------------------------
Write-Output "== DB12 New-ClaudeWorkbookReviewPackage =="
$f = New-Fixture "db12" "COMPLETION_WRITTEN" "CONTROL_VALIDATION" "N-01-0.1" "CHG-20260831-027"
$r = Invoke-Script "New-ClaudeWorkbookReviewPackage.ps1" "DB12" $f @{ DB12_RECOMMEND = "1" }
Assert-True "DB12 S22 recommended -> ADVISORY_REVIEW_PACKAGE_CREATED, read-only" ($r.outcome -eq "ADVISORY_REVIEW_PACKAGE_CREATED" -and $r.pass -and -not $r.wbModified) ("got " + $r.outcome)
Assert-True "DB12 S22 packet written" (Test-Path (Join-Path $f.tasksDir "CLAUDE_WORKBOOK_REVIEW_PACKET.md")) "missing"
$r = Invoke-Script "New-ClaudeWorkbookReviewPackage.ps1" "DB12" $f @{ DB12_RECOMMEND = "0" }
Assert-True "DB12 S23 suppressed -> NO_ADVISORY_REVIEW_RECOMMENDED, pass true" ($r.outcome -eq "NO_ADVISORY_REVIEW_RECOMMENDED" -and $r.pass) ("got " + $r.outcome)

# --- DB13 REFRESH_GIT_GATE_STATE ---------------------------------------------
Write-Output "== DB13 Get-GitGateState =="
$f = New-Fixture "db13" "MERGED" "RUN_GOVERNED_COMPLETION" "N-01-0.1" "CHG-20260831-028" "REAL_NEXUS_DEVELOPMENT"
$r = Invoke-Script "Get-GitGateState.ps1" "DB13" $f @{ DB13_SELFTEST = "1"; DB13_GIT_BRANCH = "main"; DB13_HEAD = "abc123"; DB13_PR_STATE = "MERGED" }
Assert-True "DB13 S24 refresh -> GIT_GATE_STATE_REFRESHED, read-only" ($r.outcome -eq "GIT_GATE_STATE_REFRESHED" -and $r.pass -and -not $r.gitModified) ("got " + $r.outcome)
$g = Get-Content (Join-Path $f.stateDir "git-gate-state.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True "DB13 S24 observed MERGED + mergeConfirmed" ($g.prState -eq "MERGED" -and $g.mergeConfirmed) ("got " + $g.prState)
$f = New-Fixture "db13_unknown" "AWAITING_HUMAN_PR" "CREATE_PR" "N-01-0.1" "CHG-20260831-029" "REAL_NEXUS_DEVELOPMENT"
$r = Invoke-Script "Get-GitGateState.ps1" "DB13" $f @{ DB13_SELFTEST = "1"; DB13_GIT_BRANCH = "main"; DB13_HEAD = "abc124" }
$g = Get-Content (Join-Path $f.stateDir "git-gate-state.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True "DB13 S25 unverifiable PR stays UNKNOWN (never fabricated)" ($g.prState -eq "UNKNOWN" -and -not $g.mergeConfirmed) ("got " + $g.prState)

# --- DB14 GET_CURRENT_LIFECYCLE_STATE ----------------------------------------
Write-Output "== DB14 Get-CurrentLifecycleState =="
$f = New-Fixture "db14" "VERIFIED" "CLAUDE_REVIEW" "N-01-0.1" "CHG-20260831-030"
$r = Invoke-Script "Get-CurrentLifecycleState.ps1" "DB14" $f @{}
Assert-True "DB14 S26 lifecycle snapshot -> LIFECYCLE_STATE_SNAPSHOT, read-only" ($r.outcome -eq "LIFECYCLE_STATE_SNAPSHOT" -and $r.pass -and -not $r.wbModified) ("got " + $r.outcome)
$snap = Get-Content (Join-Path $f.stateDir "current-lifecycle-state.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True "DB14 S26 snapshot reflects the generic fixture state" ($snap.task.nodeId -eq "N-01-0.1" -and $snap.status -eq "VERIFIED" -and $snap.mode -eq "TRIAL") ("got " + $snap.task.nodeId + "/" + $snap.status)

# --- invariants over the real workbook + repo + live evidence -----------------
Write-Output "== invariants =="
$realHashAfter = Get-Hash $script:RealWorkbook
Assert-True "I1 real workbook untouched by suite" ($realHashAfter -eq $script:RealHashBefore) "real workbook hash changed"
# I1 (governed recorded state): after a governed live closure the authoritative
# workbook is LEGITIMATELY no longer the pristine F520060C baseline (the closure
# closed row 80 for CHG-20260830-017). The reference for "where the live workbook
# must be" is the recorded post-closure SHA in state/trial-closure.json once a live
# closure has been performed; with no closure ever run it must still be the pristine
# F520060C baseline. The suite itself never writes the live workbook (checked above).
$expectedLiveSha = "F520060CB753EC8EC96B44BCBD193BDAB69CA68D4CC27198663665D5FE63F884"
$liveClosurePath = Join-Path $script:Root "state\trial-closure.json"
if (Test-Path $liveClosurePath) {
    $lcDoc = Read-DevBridgeJson $liveClosurePath
    $recordedSha = [string](Get-DevBridgeField $lcDoc "postWorkbookSha256")
    if ($recordedSha) { $expectedLiveSha = $recordedSha }
}
Assert-True "I1 real workbook matches its governed recorded state" ($realHashAfter -eq $expectedLiveSha) ("got " + $realHashAfter + " expected " + $expectedLiveSha)
$repoStatusAfter = @(& git -C "C:\Personal\Nexus.Developer" status --porcelain=v1 2>$null)
$repoDelta = @($repoStatusAfter | Where-Object { $script:RepoStatusBefore -notcontains $_ })
$repoDeltaRev = @($script:RepoStatusBefore | Where-Object { $repoStatusAfter -notcontains $_ })
Assert-True "I2 nexus repo git state untouched by suite" ($repoDelta.Count -eq 0 -and $repoDeltaRev.Count -eq 0) ("delta: " + (($repoDelta + $repoDeltaRev) -join "; "))
$liveTaskHashAfter = Get-Hash (Join-Path $script:Root "state\current-task.json")
$liveClaudeHashAfter = Get-Hash (Join-Path $script:Root "state\claude-review.json")
Assert-True "I3 live trial evidence (current-task.json) untouched" ($liveTaskHashAfter -eq $script:LiveTaskHashBefore) "current-task.json changed"
Assert-True "I3 live trial evidence (claude-review.json) untouched" ($liveClaudeHashAfter -eq $script:LiveClaudeHashBefore) "claude-review.json changed"
$db23After = @()
foreach ($f in @(Get-ChildItem (Join-Path $script:Root "scripts\ai-routing") -Recurse -File -ErrorAction SilentlyContinue)) { $db23After += $f.FullName.Substring($script:Root.Length) + "=" + (Get-Hash $f.FullName) }
foreach ($f in @(Get-ChildItem (Join-Path $script:Root "design\ai-routing") -Recurse -File -ErrorAction SilentlyContinue)) { $db23After += $f.FullName.Substring($script:Root.Length) + "=" + (Get-Hash $f.FullName) }
$db23Same = ($(($db23After | Sort-Object) -join ";") -eq $(($script:Db23Before | Sort-Object) -join ";"))
Assert-True "I4 DB-M23 files untouched by suite" $db23Same "ai-routing files changed"

# I5 no prior WI/CHG identity hard-coded in the reusable scripts
$hardcoded = ""
foreach ($name in @("Run-Verification.ps1","New-ClaudeReviewPackage.ps1","Set-ClaudeReviewResult.ps1","New-CorrectionContext.ps1","Confirm-CorrectedImplementation.ps1","Complete-GovernedCycle.ps1","Invoke-WorkbookValidation.ps1","New-ClaudeWorkbookReviewPackage.ps1","Get-GitGateState.ps1","Get-CurrentLifecycleState.ps1","Set-DevBridgeStateEntry.ps1")) {
    $content = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot $name))
    if ($content -match "WI-07-0\.2\.4|CHG-20260830-017|CHG-20260830-016|ACT-20260830-018") { $hardcoded += " " + $name }
}
Assert-True "I5 no prior WI/CHG identity hard-coded in reusable scripts" ($hardcoded -eq "") ("hardcoded in:" + $hardcoded)

# I6 the DevBridge solution still builds
Write-Output "== I6 solution build =="
$sln = Join-Path $script:Root "src\DevBridge.slnx"
$oldEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$buildOut = @(& dotnet build $sln 2>&1)
$buildExit = $LASTEXITCODE
$ErrorActionPreference = $oldEAP
Assert-True "I6 solution build passes" ($buildExit -eq 0) ("build exit " + $buildExit)
$warnCount = @($buildOut | Select-String -Pattern "warning CS").Count
Assert-True "I6 build has no compiler warnings" ($warnCount -eq 0) ("warnings " + $warnCount)

# --- summary -----------------------------------------------------------------
Write-Output ""
$failCount = $script:Fails.Count
Write-Output ("DB-M12.2 SAFETY SUMMARY: {0} checks, {1} passed, {2} failed" -f $script:Results.Count, ($script:Results.Count - $failCount), $failCount)
if ($failCount -gt 0) {
    Write-Output "FAILURES:"
    foreach ($f in $script:Fails) { Write-Output ("  - " + $f) }
    exit 1
}
Write-Output "DB-M12.2: ALL PASS"
exit 0
