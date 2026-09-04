# New-ClaudeReviewPackage.ps1 - DB-M07 governed CLAUDE REVIEW MANIFEST assembly
# (DB-M12.2 reusable lifecycle command for CREATE_CLAUDE_REVIEW_PACKAGE).
#
# NEW REVIEW MODEL (Request F): Claude is the INDEPENDENT READ-ONLY reviewer of the
# ACTUAL Nexus files on the computer. DB-M07 therefore builds a CLAUDE REVIEW
# MANIFEST -- an identity-bound review brief -- NOT a stale/source-heavy packet:
#   * tasks\CLAUDE_REVIEW_PACKAGE.md - the CLAUDE REVIEW MANIFEST. Carries the
#     review identity (node/change/task/mode/stage/DB-M06 evidence), the
#     authoritative goal + current acceptance criteria + applicable architecture/
#     ADR constraints (from the governed brief tasks\DEEPSEEK_PROMPT.md of the
#     CURRENT task only), the reserved scope with ABSOLUTE repository roots and
#     reserved projects (from state\reservation.json of the CURRENT task), the
#     EXACT current-task changed-file list (obtained from the DB-M06/baseline
#     evidence by re-invoking the read-only Measure-Dbm06ImplementationDelta
#     classifier per reserved repo -- never hard-coded), pre-existing state as
#     baseline references, the DB-M06 PASS evidence (quoted, never re-run), the
#     read-only file-review instructions, review questions A-I and the required
#     decision vocabulary.
#   * tasks\REVIEW_PACKET.md             - short pointer to the manifest (kept so
#     legacy navigation/display stays valid).
#
# DB-M07 CONSISTENCY GATE: verifies current Node == current task, current Change ==
# current reservation, the DB-M06 verification PASS belongs to the same Node/Change,
# the governed brief belongs to the same Node/Change (no historical Node/Change can
# become the review subject), and every reserved repository root is reachable and
# classifiable. On ANY mismatch the stage emits DB07_OUTCOME:
# CLAUDE_REVIEW_PACKAGE_NOT_READY (DB07_RESULT_PASS: False), records the reasons in
# current-task dbM07 (ready=false) and does NOT write/enable a copyable manifest.
#
# DB-M06 is never re-run: build/test commands are never executed here; the
# classifier is read-only git/hash observation over the same baseline evidence.
#
# Backend contract: ALWAYS exits 0; outcomes ONLY via stdout markers (DB07_*).
# State/tasks dirs redirect with DB07_STATE_DIR / DB07_TASKS_DIR.
#
# ASCII-only source (PS 5.1 + BOM-safe).
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Set-DevBridgeStateEntry.ps1")
. (Join-Path $PSScriptRoot "ClaudeReviewManifestSupport.ps1")
. (Join-Path $PSScriptRoot "TrialDependencyOverlay.ps1")

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:StateDir = Join-Path $script:Root "state"
$script:TasksDir = Join-Path $script:Root "tasks"
$script:CfgPath = Join-Path $script:Root "config\devbridge.json"
if ($env:DB07_STATE_DIR) { $script:StateDir = $env:DB07_STATE_DIR }
if ($env:DB07_TASKS_DIR) { $script:TasksDir = $env:DB07_TASKS_DIR }
$script:CurrentTaskPath = Join-Path $script:StateDir "current-task.json"
$script:PackagePath = Join-Path $script:TasksDir "CLAUDE_REVIEW_PACKAGE.md"
$script:PacketPath = Join-Path $script:TasksDir "REVIEW_PACKET.md"
$script:VerificationPath = Join-Path $script:StateDir "verification.json"
$script:ReservationPath = Join-Path $script:StateDir "reservation.json"
$script:BriefPath = Join-Path $script:TasksDir "DEEPSEEK_PROMPT.md"
$script:Classifier = Join-Path $PSScriptRoot "Measure-Dbm06ImplementationDelta.ps1"
$script:NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

function Out-Markers([string]$token, [bool]$pass, [string[]]$evidence) {
    Write-Output ("DB07_OUTCOME: " + $token)
    Write-Output ("DB07_RESULT_PASS: " + $(if ($pass) { "True" } else { "False" }))
    Write-Output ("DB07_RESULT_CODE: " + $token)
    Write-Output "DB07_WORKBOOK_MODIFIED: False"
    Write-Output "DB07_NEXUS_SOURCE_MODIFIED: False"
    Write-Output "DB07_GIT_MODIFIED: False"
    Write-Output "DB07_REQUIRES_HUMAN_ACTION: False"
    Write-Output "DB07_HUMAN_ACTION_TYPE:"
    foreach ($e in $evidence) { Write-Output ("DB07_EVIDENCE: " + $e) }
    exit 0
}

function Out-NotReady([string[]]$reasons) {
    $bad = [ordered]@{
        result = "CLAUDE_REVIEW_PACKAGE_NOT_READY"
        ready  = $false
        nodeId = $script:NodeId; changeId = $script:ChangeId
        mode   = $script:Mode; trialMode = $script:Trial
        generatedAtUtc = $script:NowUtc
        reasons = @($reasons)
        evidence = @()
    }
    Set-DevBridgeStateEntry $script:CurrentTaskPath @{ dbM07 = $bad }
    Out-Markers "CLAUDE_REVIEW_PACKAGE_NOT_READY" $false @($reasons)
}

# Read-only current-task delta classification for ONE reserved repository (the same
# classifier DB-M06 ran; results come from the baseline evidence, never re-run M06).
function Invoke-CrmClassify([string]$repoPath, [string]$resPath) {
    $env:DB06D_REPO = $repoPath
    $env:DB06D_RESERVATION = $resPath
    try {
        $co = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Classifier 2>&1)
    } finally {
        Remove-Item env:DB06D_REPO -ErrorAction SilentlyContinue
        Remove-Item env:DB06D_RESERVATION -ErrorAction SilentlyContinue
    }
    $co = @($co | ForEach-Object { "$_" })
    $joined = ($co -join "`n")
    $outcome = "NO_OUTCOME"
    $om = [regex]::Match($joined, 'DB06D_OUTCOME:\s*(\S+)')
    if ($om.Success) { $outcome = $om.Groups[1].Value }
    $delta = New-Object System.Collections.Generic.List[string]
    $pre = New-Object System.Collections.Generic.List[string]
    $fails = New-Object System.Collections.Generic.List[string]
    foreach ($line in $co) {
        if ($line -notlike 'DB06D_FILE:*') { continue }
        $dm = [regex]::Match($line, 'DB06D_FILE:\s*([^|]+?)\s*\|\s*([A-Z_]+)')
        if (-not $dm.Success) { continue }
        $rel = $dm.Groups[1].Value.Trim()
        $verdict = $dm.Groups[2].Value
        if ($verdict -eq 'CURRENT_TASK_DELTA' -or $verdict -eq 'PRE_EXISTING_AND_CURRENT_TASK_DELTA') { $delta.Add($rel) }
        elseif ($verdict -eq 'PRE_EXISTING_ONLY') { $pre.Add($rel) }
        else { $fails.Add($line.Trim()) }
    }
    $ev = @($co | Where-Object { $_ -like 'DB06D_EVIDENCE:*' })
    return @{ Outcome = $outcome; Delta = $delta; PreExisting = $pre; Fails = $fails; Evidence = $ev }
}

# ---- identity: current task ----
$ct = Read-DevBridgeJson $script:CurrentTaskPath
if ($null -eq $ct) { Out-Markers "STOP_NO_CURRENT_TASK" $false @("No current-task.json; run DB-M03 preflight first.") }

$script:NodeId = [string](Get-DevBridgeField $ct "nodeId")
$script:ChangeId = [string](Get-DevBridgeField $ct "changeId")
$taskName = [string](Get-DevBridgeField $ct "name")
if (-not $script:NodeId) { $script:NodeId = [string](Get-DevBridgeField $ct "taskId") }
$script:Mode = Get-DevBridgeMode $ct $script:CfgPath
if ($env:DB_COMMAND_INPUT_MODE) { $script:Mode = $env:DB_COMMAND_INPUT_MODE }
$script:Trial = ($script:Mode -eq "TRIAL")

if (-not $script:NodeId -or -not $script:ChangeId) {
    Out-NotReady @("Current task has no Node/Change identity yet.")
}

$reasons = New-Object System.Collections.Generic.List[string]

# ---- DB-M06 evidence: must be a PASS for the SAME node/change ----
$verifiedAt = ""
$m06Commands = @()
$verif = Read-DevBridgeJson $script:VerificationPath
if ($null -eq $verif) {
    $reasons.Add("DB-M06 verification evidence (state/verification.json) is missing.")
} else {
    $vn = [string](Get-DevBridgeField $verif "nodeId")
    $vc = [string](Get-DevBridgeField $verif "changeId")
    $vr = [string](Get-DevBridgeField $verif "primaryResult")
    if ($vn -ne $script:NodeId -or $vc -ne $script:ChangeId) {
        $reasons.Add("DB-M06 verification belongs to " + $vn + " / " + $vc + ", not the current " + $script:NodeId + " / " + $script:ChangeId + ".")
    }
    if ($vr -notlike "VERIFICATION_PASSED*") {
        $reasons.Add("DB-M06 verification has not PASSED (primaryResult=" + $vr + ").")
    }
    $verifiedAt = [string](Get-DevBridgeField $verif "verifiedAtUtc")
    $m06Commands = @(Get-DevBridgeField $verif "commands")
}

# ---- reservation: must belong to the SAME node/change + carry repo baselines ----
$res = Read-DevBridgeJson $script:ReservationPath
$baselines = @()
$reservedProjects = @()
$reservedScopeProjects = @()
if ($null -eq $res) {
    $reasons.Add("Reservation (state/reservation.json) is missing; the review scope cannot be proven.")
} else {
    $rn = [string](Get-DevBridgeField $res "nodeId")
    $rc = [string](Get-DevBridgeField $res "changeId")
    if ($rn -and $rn -ne $script:NodeId) { $reasons.Add("Reservation node " + $rn + " != current node " + $script:NodeId + ".") }
    if ($rc -and $rc -ne $script:ChangeId) { $reasons.Add("Reservation change " + $rc + " != current change " + $script:ChangeId + ".") }
    $baselines = @(Get-DevBridgeField $res "repositoryBaselines")
    if ($baselines.Count -eq 0) { $reasons.Add("Reservation has no repositoryBaselines; repository roots cannot be proven.") }
    $rs = Get-DevBridgeField $res "reservedScope"
    if ($null -ne $rs) {
        $reservedScopeProjects = @(Get-DevBridgeField $rs "projects")
    }
}

# Read a "Label:" field from the governed brief, tolerating BOTH inline values
# ("Node ID: WI-12-0.4.1") and the real live layout where the value sits on the
# NEXT non-blank line ("Node ID:" then "WI-12-0.4.1" below it).
function Get-BriefIdField([string]$raw, [string]$label) {
    if (-not $raw) { return "" }
    $esc = [regex]::Escape($label)
    $lines = $raw -split "\r?\n"
    foreach ($line in $lines) {
        if ($line -match ("^\s*" + $esc + "\s*:\s*(\S+)\s*$")) { return $Matches[1].Trim() }
    }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match ("^\s*" + $esc + "\s*:\s*$")) {
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                if (([string]$lines[$j]).Trim()) {
                    $v = ([string]$lines[$j]).Trim()
                    if ($v -notmatch '^=+$') { return $v }
                }
            }
        }
    }
    return ""
}

# ---- governed brief (DEEPSEEK_PROMPT.md): goal / acceptance / ADR of the CURRENT
# task only; a historical brief must never become the review subject ----
$briefRaw = ""
$briefMap = @{}
if (Test-Path -LiteralPath $script:BriefPath) {
    $briefRaw = [System.IO.File]::ReadAllText($script:BriefPath)
    $briefMap = Get-CrmSectionMap ([System.IO.File]::ReadAllLines($script:BriefPath))
} else {
    $reasons.Add("Governed brief (tasks/DEEPSEEK_PROMPT.md) is missing; the authoritative goal/acceptance/ADR cannot be sourced.")
}
if ($briefRaw) {
    $bmNode = Get-BriefIdField $briefRaw "Node ID"
    $bmChange = Get-BriefIdField $briefRaw "Change ID"
    if ($bmNode -and $bmNode -ne $script:NodeId) { $reasons.Add("Governed brief node " + $bmNode + " != current node " + $script:NodeId + " (a historical brief must not become the review subject).") }
    if ($bmChange -and $bmChange -ne $script:ChangeId) { $reasons.Add("Governed brief change " + $bmChange + " != current change " + $script:ChangeId + " (a historical brief must not become the review subject).") }
    if ((Get-CrmSectionText $briefMap "GOAL") -eq "") { $reasons.Add("Governed brief GOAL section is missing.") }
    if ((Get-CrmSectionText $briefMap "AUTHORITATIVE ACCEPTANCE CRITERIA") -eq "") { $reasons.Add("Governed brief acceptance-criteria section is missing.") }
}

# ---- manifest idempotency: an existing manifest that is ALREADY the current
# manifest (same identity + same DB-M06 evidence + ready stamp) is REUSED ----
$manifestId = Get-CrmManifestId $script:NodeId $script:ChangeId $verifiedAt
$cur = Test-CrmManifestCurrent -StateDir $script:StateDir -TasksDir $script:TasksDir

if ($reasons.Count -eq 0) {
    if ($cur.Ready) {
        Out-Markers "REUSED" $true @("tasks/CLAUDE_REVIEW_PACKAGE.md", "tasks/REVIEW_PACKET.md")
    }
}

# ---- current-task delta from the DB-M06/baseline evidence (read-only classifier) ----
$perRepo = New-Object System.Collections.Generic.List[object]
if ($reasons.Count -eq 0) {
    foreach ($_b in $baselines) {
        $_label = [string](Get-DevBridgeField $_b "name")
        $_repoPath = [string](Get-DevBridgeField $_b "path")
        $_isPrimary = ([bool](Get-DevBridgeField $_b "isPrimary"))
        if (-not $_repoPath) { $reasons.Add("Reservation baseline '" + $_label + "' has no path."); continue }
        $_root = ""
        try { $_root = (Resolve-Path -LiteralPath $_repoPath -ErrorAction Stop).Path } catch { $_root = "" }
        if (-not $_root) { $reasons.Add("Reserved repository " + $_repoPath + " is not reachable; the manifest cannot list its actual files."); continue }
        if (-not (Test-Path -LiteralPath $script:Classifier)) { $reasons.Add("Delta classifier missing; current-task files cannot be listed."); break }
        $owned = New-Object System.Collections.Generic.List[string]
        foreach ($_pr in $reservedScopeProjects) {
            if (Test-Path -LiteralPath (Join-Path $_root ("src\" + $_pr))) { $owned.Add([string]$_pr) }
        }
        $headNow = ""
        try { $ho = @(& git -C $_root rev-parse HEAD 2>$null) } catch { $ho = @() }
        if ($ho.Count -ge 1 -and $ho[0]) { $headNow = ([string]$ho[0]).Trim() }
        $cls = Invoke-CrmClassify $_root $script:ReservationPath
        $perRepo.Add(@{
            Label = $_label; Root = $_root; IsPrimary = $_isPrimary; Head = $headNow
            Owned = $owned; Outcome = $cls.Outcome; Delta = $cls.Delta
            PreExisting = $cls.PreExisting; Evidence = $cls.Evidence
        })
        if ($cls.Outcome -ne "DELTA_CLASSIFICATION_PASS") {
            $evText = ""
            if ($cls.Evidence.Count -gt 0) { $evText = " (" + (($cls.Evidence | ForEach-Object { $_.Trim() }) -join "; ") + ")" }
            $reasons.Add("Reserved repository " + $_label + " delta classification " + $cls.Outcome + $evText)
        }
    }
}

if ($reasons.Count -gt 0) {
    Out-NotReady @($reasons)
}

# ---- assemble the CLAUDE REVIEW MANIFEST ----
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# Claude Review Manifest")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("Change under review: " + $script:ChangeId)
[void]$sb.AppendLine("Change: " + $script:ChangeId)
[void]$sb.AppendLine("Node: " + $script:NodeId)
[void]$sb.AppendLine("Task: " + $taskName)
[void]$sb.AppendLine("Mode: " + $script:Mode)
[void]$sb.AppendLine("Stage: DB-M07 -> CLAUDE_REVIEW (recorded by DB-M08)")
[void]$sb.AppendLine("Manifest ID: " + $manifestId)
[void]$sb.AppendLine("Generated (utc): " + $script:NowUtc)
[void]$sb.AppendLine("DB-M06 verified (utc): " + $verifiedAt)
[void]$sb.AppendLine("")
[void]$sb.AppendLine("You are the INDEPENDENT READ-ONLY reviewer of the ACTUAL Nexus")
[void]$sb.AppendLine("files on this computer. Read the real current files listed below from")
[void]$sb.AppendLine("disk. Do NOT rely primarily on copied source. Do NOT modify anything.")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Governance header")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("### 1. Temporary boundary")
[void]$sb.AppendLine("DevBridge is TEMPORARY external scaffolding for Nexus Phase 1/2. It will be")
[void]$sb.AppendLine("retired. Nothing reviewed here becomes Nexus runtime architecture, contracts,")
[void]$sb.AppendLine("services, libraries, infrastructure or a dependency.")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("### 2. Trial or real mode")
[void]$sb.AppendLine("This change was developed in mode: " + $script:Mode + ". In TRIAL, evidence stops at the trial")
[void]$sb.AppendLine("safe-stop and governed completion is NOT applicable. In REAL_NEXUS_DEVELOPMENT,")
[void]$sb.AppendLine("completion requires the human git gates and a preserved protected roadmap.")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("### 3. Architecture independence")
[void]$sb.AppendLine("A review PASS approves the change DELTA only. The reviewer is NOT authorized to")
[void]$sb.AppendLine("redesign Nexus architecture, contracts or services as a condition of review.")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("### 4. Roadmap immutability")
[void]$sb.AppendLine("The roadmap is immutable to this review. No roadmap redesign or structural edit is")
[void]$sb.AppendLine("authorized. Protected phase/milestone/goal/outcome/acceptance-criteria/dependency")
[void]$sb.AppendLine("surfaces must remain unchanged by the change under review.")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("### 5. Fix-task rule")
[void]$sb.AppendLine("A defect found in this attempt is addressed as CORRECT_CURRENT_ATTEMPT. A defect")
[void]$sb.AppendLine("found after completion requires a NEW_FIX_TASK_REQUIRED under the existing")
[void]$sb.AppendLine("structure. Anything unrepresentable is HUMAN_GOVERNANCE_REQUIRED.")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("### 6. Exact scope")
[void]$sb.AppendLine("The exact scope under review is the delta of this change: changeId " + $script:ChangeId + " on")
[void]$sb.AppendLine("nodeId " + $script:NodeId + ". The review verdict applies to this scope only.")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("### 7. Forbidden edits")
[void]$sb.AppendLine("The following are FORBIDDEN during this change: unauthorized workbook edits,")
[void]$sb.AppendLine("modifications to DB-M23-owned files, source changes outside the recorded scope,")
[void]$sb.AppendLine("and edits to the protected roadmap surface. These must not be introduced and are")
[void]$sb.AppendLine("prohibited from this package.")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("### 8. Human git gates")
[void]$sb.AppendLine("PR creation, review and merge are HUMAN-gated actions. DevBridge never creates,")
[void]$sb.AppendLine("approves, infers or merges PRs. The merge gate is confirmed only by an explicit")
[void]$sb.AppendLine("observed gitLifecycleState.")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("### 9. Decision vocabulary")
[void]$sb.AppendLine("The reviewer returns exactly one of: PASS, FIX, GOVERNANCE_ISSUE,")
[void]$sb.AppendLine("HUMAN_DECISION_REQUIRED. PASS approves the delta; FIX routes to the correction")
[void]$sb.AppendLine("loop; GOVERNANCE_ISSUE is escalated to a human; HUMAN_DECISION_REQUIRED suspends")
[void]$sb.AppendLine("for an explicit human decision.")
[void]$sb.AppendLine("")

# ---- 1. authoritative goal (governed brief, current task) ----
[void]$sb.AppendLine("## 1. Authoritative goal")
[void]$sb.AppendLine("Quoted verbatim from the governed brief (tasks/DEEPSEEK_PROMPT.md) of the CURRENT task. It is the review's authority - not any developer summary.")
[void]$sb.AppendLine("")
$goal = (Get-CrmSectionText $briefMap "GOAL") -split "`n"
foreach ($g in $goal) { [void]$sb.AppendLine($g) }
[void]$sb.AppendLine("")

# ---- 2. acceptance criteria ----
[void]$sb.AppendLine("## 2. Acceptance criteria (current, authoritative)")
[void]$sb.AppendLine("The implementation must satisfy ALL of these to PASS. They are the current acceptance criteria of this change.")
[void]$sb.AppendLine("")
$acc = (Get-CrmSectionText $briefMap "AUTHORITATIVE ACCEPTANCE CRITERIA") -split "`n"
foreach ($g in $acc) { [void]$sb.AppendLine($g) }
[void]$sb.AppendLine("")

# ---- 3. architecture / ADR constraints (applicable) ----
[void]$sb.AppendLine("## 3. Architecture and ADR constraints (applicable only)")
[void]$sb.AppendLine("The applicable architecture/ADR constraints from the governed brief. They are the current constraints this delta must respect.")
[void]$sb.AppendLine("")
$arch = (Get-CrmSectionText $briefMap "ARCHITECTURE RULES") -split "`n"
foreach ($g in $arch) { [void]$sb.AppendLine($g) }
[void]$sb.AppendLine("")

# ---- 4. reserved scope ----
[void]$sb.AppendLine("## 4. Reserved scope (absolute repository roots, reserved projects)")
[void]$sb.AppendLine("Repository roots are ABSOLUTE paths on this computer. Reserved projects are the only projects this change may touch. No narrower file/glob constraint is recorded.")
[void]$sb.AppendLine("")
foreach ($repo in $perRepo) {
    [void]$sb.AppendLine("- Repository (reserved): " + $repo.Label + $(if ($repo.IsPrimary) { " [primary]" } else { "" }))
    [void]$sb.AppendLine("  Root: " + $repo.Root)
    if ($repo.Owned.Count -gt 0) { [void]$sb.AppendLine("  Reserved project(s): " + ($repo.Owned -join ", ")) }
    else { [void]$sb.AppendLine("  Reserved project(s): (none physically present under src in this repo)") }
}
[void]$sb.AppendLine("Reserved roadmap nodes (informational): the current task's node/change; review does not alter roadmap structure.")
[void]$sb.AppendLine("")

# ---- 5. current-task delta (exact list) ----
[void]$sb.AppendLine("## 5. Current-task delta (exact file list from the DB-M06/baseline evidence)")
[void]$sb.AppendLine("These are the ACTUAL files of THIS change that you must read and review. Paths are repository-relative. No unrelated historical task files are included.")
[void]$sb.AppendLine("")
foreach ($repo in $perRepo) {
    [void]$sb.AppendLine("### " + $repo.Label + " (" + $repo.Root + ")")
    [void]$sb.AppendLine("- Classification: " + $repo.Outcome)
    if ($repo.Head) { [void]$sb.AppendLine("- Baseline head: " + $repo.Head) }
    if ($repo.Delta.Count -gt 0) {
        [void]$sb.AppendLine("- CURRENT_TASK_DELTA files (review each of these):")
        foreach ($d in $repo.Delta) { [void]$sb.AppendLine("    - " + $d) }
    } else {
        [void]$sb.AppendLine("- CURRENT_TASK_DELTA files: NONE")
        [void]$sb.AppendLine("- This reserved repository is expected to have NO unintended current-task delta. Verify none exists.")
    }
    if ($repo.PreExisting.Count -gt 0) {
        [void]$sb.AppendLine("- PRE_EXISTING_ONLY files (baseline pre-existing; NOT this change - do not require them committed): " + $repo.PreExisting.Count + " file(s). See git status.")
    }
    [void]$sb.AppendLine("")
}

# ---- 6. pre-existing state (references only) ----
[void]$sb.AppendLine("## 6. Pre-existing state (baseline references, not copied source)")
[void]$sb.AppendLine("Both reserved repositories carry PRE-EXISTING changes captured at reservation. They are references so you can distinguish pre-existing content from THIS change; they are not review scope.")
[void]$sb.AppendLine("")
foreach ($_b in $baselines) {
    $_label2 = [string](Get-DevBridgeField $_b "name")
    $_path2 = [string](Get-DevBridgeField $_b "path")
    $_head2 = [string](Get-DevBridgeField $_b "headCommit")
    $_pre2 = Get-DevBridgeField $_b "preExistingChanges"
    $pm = 0; $ps = 0; $pu = 0; $ph = 0
    if ($null -ne $_pre2) {
        $pm = @(Get-DevBridgeField $_pre2 "modified").Count
        $ps = @(Get-DevBridgeField $_pre2 "staged").Count
        $pu = @(Get-DevBridgeField $_pre2 "untracked").Count
    }
    $ph = @(Get-DevBridgeField $_b "scopeFileHashes").Count
    [void]$sb.AppendLine("- " + $_label2 + " (" + $_path2 + ") baseline head " + $_head2 + "; pre-existing modified=" + $pm + ", staged=" + $ps + ", untracked=" + $pu + "; in-scope baseline hashes=" + $ph + ". Baseline is recorded in state/reservation.json.")
}
[void]$sb.AppendLine("")

# ---- 7. DB-M06 evidence ----
[void]$sb.AppendLine("## 7. DB-M06 verification evidence (quoted; NOT re-run)")
[void]$sb.AppendLine("The verification was run once by DB-M06; its evidence is quoted from state/verification.json + tasks/VERIFICATION_REPORT.md. This stage did NOT re-run DB-M06.")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("Result: VERIFICATION_PASSED (primary). Verified (utc): " + $verifiedAt)
[void]$sb.AppendLine("Evidence files: state/verification.json, tasks/VERIFICATION_REPORT.md")
[void]$sb.AppendLine("Executed commands (from the DB-M06 record):")
foreach ($cmd in $m06Commands) {
    $line = [string]$cmd
    if ($line.StartsWith("> ") -or $line.StartsWith("(discovery)")) {
        $single = ($line -split "`n" | Select-Object -First 1)
        [void]$sb.AppendLine("  - " + $single)
    }
}
[void]$sb.AppendLine("Scope verification: per reserved repository the read-only baseline classifier reported DELTA_CLASSIFICATION_PASS (section 5).")
[void]$sb.AppendLine("Workbook unchanged: DB-M06 and this stage never write the workbook.")
[void]$sb.AppendLine("No commit / PR / merge was performed by DevBridge.")
[void]$sb.AppendLine("Warnings/limitations: the delta list is valid as of DB-M06 (" + $verifiedAt + "). If the working tree changes after DB-M06, DB-M06 must be re-run before this review is authoritative.")
[void]$sb.AppendLine("")

# ---- 8. file review instructions (read-only) ----
[void]$sb.AppendLine("## 8. File review instructions - review the ACTUAL files (read-only)")
[void]$sb.AppendLine("- Read the real current files listed in section 5 from disk under the repository roots in section 4.")
[void]$sb.AppendLine("- You may also read: git status, git diff, git show, git log, and the referenced evidence files.")
[void]$sb.AppendLine("- Review must be READ-ONLY. You MUST NOT modify, create, stage, commit, push, revert, or clean any file.")
[void]$sb.AppendLine("- You MUST NOT change the workbook, roadmap, reservation, task identity, acceptance criteria, or architecture.")
[void]$sb.AppendLine("- Do NOT run commands that mutate the repositories. Safe read-only inspection only.")
[void]$sb.AppendLine("- Independently inspect the real files; do not rely primarily on copied source.")
[void]$sb.AppendLine("")

# ---- 9. review questions A-I ----
[void]$sb.AppendLine("## 9. Review questions")
[void]$sb.AppendLine("A. Are all current acceptance criteria (section 2) satisfied by the current-task delta (section 5)?")
[void]$sb.AppendLine("B. Is the architecture/ADR (section 3) respected?")
[void]$sb.AppendLine("C. Is there unnecessary duplication introduced?")
[void]$sb.AppendLine("D. Is there a scope violation (a change outside section 4 reserved scope)?")
[void]$sb.AppendLine("E. Is there a regression risk not caught by the DB-M06 tests (section 7)?")
[void]$sb.AppendLine("F. Is navigation / routing / context semantically correct?")
[void]$sb.AppendLine("G. Is the Developer Chat (and surrounding app) architecturally and functionally intact?")
[void]$sb.AppendLine("H. Are pre-existing changes (section 6) correctly distinguished from this change's delta?")
[void]$sb.AppendLine("I. Are there material security / maintainability / correctness issues in the delta?")
[void]$sb.AppendLine("")

# ---- 10. required decision ----
[void]$sb.AppendLine("## 10. Required review decision")
[void]$sb.AppendLine("Return EXACTLY ONE of:")
[void]$sb.AppendLine("- PASS")
[void]$sb.AppendLine("- FIX")
[void]$sb.AppendLine("- GOVERNANCE_ISSUE")
[void]$sb.AppendLine("- HUMAN_DECISION_REQUIRED")
[void]$sb.AppendLine("Report the decision together with your verdict on questions A-I. Give the decision back to the operator, who records it in DevBridge (DB-M08) - you do not record it yourself.")

# ---- dependency context (DB-M18.1, additive; never alters markers/exit codes) ----
$script:Db181Block = ''
$db181Lib = Join-Path $script:Root 'scripts\ai-routing\DependencyLineage.ps1'
$db181Evidence = Join-Path $script:Root 'logs\tasks'
if ((Test-Path -LiteralPath $db181Lib) -and (Test-Path -LiteralPath $db181Evidence)) {
    try {
        . $db181Lib
        $db181Bundle = Get-DbM181TaskDependencyContext -Task $ct -TaskCatalog $null -EvidenceRoot $db181Evidence -RepositoryRoot $null -NowUtc $script:NowUtc
        $script:Db181Block = Get-DbM181ClaudeDependencyContext -Task $ct -Context $db181Bundle.Context
    } catch { $script:Db181Block = '' }
}
if ($script:Db181Block) { [void]$sb.AppendLine(""); [void]$sb.AppendLine($script:Db181Block) }

# ---- Trial-proven dependency distinction (DB-M03.2, additive; capability 11) ----
$script:TrialDepBlock = ''
$pfObj = Read-DevBridgeJson (Join-Path $script:StateDir "preflight.json")
$trialDepEntries = @()
if ($null -ne $pfObj) {
    $pfDeps = Get-DevBridgeField $pfObj "dependencies"
    if ($null -ne $pfDeps) { $trialDepEntries = @($pfDeps | Where-Object { [string](Get-DevBridgeField $_ "state") -eq "TRIAL_DEPENDENCY_SATISFIED" }) }
}
if ($trialDepEntries.Count -gt 0) {
    $trialSb = New-Object System.Text.StringBuilder
    [void]$trialSb.AppendLine("## Trial-Proven Dependency Distinction (DB-M03.2)")
    [void]$trialSb.AppendLine("The change under review depends on a predecessor satisfied ONLY by the TRIAL-only proving overlay. Its trial-proven IMPLEMENTATION state is distinct from its real ROADMAP status:")
    foreach ($tde in $trialDepEntries) {
        $tdeId = [string](Get-DevBridgeField $tde "dependencyId")
        $tdeStatus = [string](Get-DevBridgeField $tde "status")
        $tov2 = Test-TrialDependencySatisfied -DependencyNodeId $tdeId -StateDir $script:StateDir -ConfigPath $script:CfgPath -RealStatus $tdeStatus
        if ($tov2.Satisfied) {
            $tprov = $tov2.Provenance
            [void]$trialSb.AppendLine("- **" + $tdeId + "** real roadmap status: **" + $tprov.realStatus + "** (NOT Completed/Complete; authoritative). Proving status: **TRIAL_CYCLE_CLOSED** via change " + $tprov.changeId + " (" + $tprov.closedAtUtc + "); implementation state **TRIAL_ONLY_UNMERGED**. DB-M06 **" + $tprov.verificationEvidence.m06Result + "** (tests " + $tprov.verificationEvidence.testsPassed + "/" + $tprov.verificationEvidence.testsTotal + "), Claude review **" + $tprov.claudeEvidence.decision + "** (trialMode " + $tprov.claudeEvidence.trialMode + ", reviewedAgainstDbM06 " + $tprov.claudeEvidence.reviewedAgainstDbM06 + "). Overlay status **TRIAL_DEPENDENCY_SATISFIED**, real completion capability **NO**, disposable proving context **true**, repository freshness **" + $tprov.repositoryReconciliation.freshness + "**.")
        } else {
            [void]$trialSb.AppendLine("- **" + $tdeId + "** recorded as TRIAL_DEPENDENCY_SATISFIED in the preflight, but the overlay does not currently qualify (" + $tov2.Reason + "). Treat the dependency as unsatisfied for real completion purposes.")
        }
    }
    [void]$trialSb.AppendLine("This distinction does NOT make the predecessor real-complete. The real Nexus restart point is the preserved PRE-DEVBRIDGE workbook + source/Git baseline; nothing from the proving environment becomes genuine Nexus progress.")
    $script:TrialDepBlock = $trialSb.ToString().TrimEnd()
}
if ($script:TrialDepBlock) { [void]$sb.AppendLine(""); [void]$sb.AppendLine($script:TrialDepBlock) }

$manifestText = $sb.ToString().TrimEnd() + "`n"

$packet = @"
# Review Packet - $script:ChangeId

Change: $script:ChangeId
Node: $script:NodeId
Task: $taskName
Mode: $script:Mode
Package: tasks/CLAUDE_REVIEW_PACKAGE.md

This packet points to the CLAUDE REVIEW MANIFEST (tasks/CLAUDE_REVIEW_PACKAGE.md),
which tells the independent reviewer exactly which ACTUAL files on the computer to
read. This packet is READ-ONLY evidence assembly; it contains no copied source.
"@

if (-not (Test-Path $script:TasksDir)) { New-Item -ItemType Directory -Force -Path $script:TasksDir | Out-Null }
[System.IO.File]::WriteAllText($script:PackagePath, $manifestText, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($script:PacketPath, $packet, (New-Object System.Text.UTF8Encoding($false)))

$db7 = [ordered]@{
    result        = "CLAUDE_REVIEW_MANIFEST_CREATED"
    ready         = $true
    manifestId    = $manifestId
    nodeId        = $script:NodeId
    changeId      = $script:ChangeId
    mode          = $script:Mode
    trialMode     = $script:Trial
    verifiedAtUtc = $verifiedAt
    generatedAtUtc = $script:NowUtc
    governanceHeader = "COMPLETE"
    evidence      = @("tasks/CLAUDE_REVIEW_PACKAGE.md", "tasks/REVIEW_PACKET.md")
}
Set-DevBridgeStateEntry $script:CurrentTaskPath @{ dbM07 = $db7 }

Out-Markers "CLAUDE_REVIEW_PACKAGE_CREATED" $true @("tasks/CLAUDE_REVIEW_PACKAGE.md", "tasks/REVIEW_PACKET.md")
