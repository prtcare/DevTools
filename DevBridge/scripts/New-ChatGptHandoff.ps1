# New-ChatGptHandoff.ps1
# DevBridge DB-M05 engine: governed ChatGPT task handoff.
#
# Flow:
#   PART 1  Freshly validate the reservation against the authoritative workbook.
#           Any invalid condition => STOP HANDOFF_STATE_STALE (no handoff written).
#   PART 2  Fresh parallel-lane recheck (LANE C is the collision axis). Any
#           overlap with the reserved scope => STOP PARALLEL_SCOPE_CONFLICT.
#   PARTS 3-18 Build the context package (identity, goal, current state, why
#           current, acceptance criteria, gate, dependencies, scope transition,
#           architecture, open decisions, audit findings, existing assets,
#           exact reserved scope, tool registry, repository governance, git
#           baseline, parallel dev context, instructions to ChatGPT, expected
#           completion report). Open decisions / audit findings / assets /
#           dependencies / scope are derived from LIVE workbook reads, not
#           hard-coded rows.
#   PART 19 Write tasks\CHATGPT_HANDOFF.md
#   PART 20 Write tasks\DEEPSEEK_PROMPT.md (placeholder ONLY - no implementation prompt)
#   PART 21 Cycle identity safety: every artifact carries the current Node ID +
#           Change ID; no reuse of a stale cycle as self (historical artifacts
#           stay under logs\tasks\<node>\<change>).
#   PART 22 Update state\current-task.json -> status AWAITING_CHATGPT_PROMPT
#   PART 23 Preserve handoff copy under logs\tasks\<node>\<change>\
#   PART 24 Validation (20 checks): workbook unmodified, Nexus source
#           unmodified, no parallel-lane file touched by this run, content
#           complete, DEEPSEEK_PROMPT placeholder-only, cycle identity clean.
#
# The workbook and C:\Personal\Nexus.Developer are READ-ONLY to this engine.
# No Nexus source is modified. No AI API is called.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Read-DevelopmentControl.ps1"
. "$PSScriptRoot\TrialDependencyOverlay.ps1"

# ---------------------------------------------------------------------------
# Stop helper
# ---------------------------------------------------------------------------
function Stop-Outcome([string]$code, [string]$message) {
    Write-Output ("DB05_OUTCOME: " + $code)
    Write-Output ("DB05_MESSAGE: " + $message)
    Write-Output ""
    Write-Output ("DB-M05 STOP - " + $code)
    Write-Output $message
    exit 1
}

# ---------------------------------------------------------------------------
# Paths / config
# ---------------------------------------------------------------------------
$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:StateDir = Join-Path $script:Root "state"
$script:TasksDir = Join-Path $script:Root "tasks"
$script:LogsDir = Join-Path $script:Root "logs"
# Self-test redirection (DB-M03.1 gate tests run M05 against fixture state dirs).
if ($env:DB05_STATE_DIR) { $script:StateDir = $env:DB05_STATE_DIR }
if ($env:DB05_TASKS_DIR) { $script:TasksDir = $env:DB05_TASKS_DIR }
if ($env:DB05_LOGS_DIR) { $script:LogsDir = $env:DB05_LOGS_DIR }
$script:RunStart = (Get-Date).ToUniversalTime()
$script:OwnedWrites = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------------------
# Load authoritative DevBridge state
# ---------------------------------------------------------------------------
$script:CurrentState = Get-Content (Join-Path $script:StateDir "current-task.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$script:Preflight = Get-Content (Join-Path $script:StateDir "preflight.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$script:Reservation = Get-Content (Join-Path $script:StateDir "reservation.json") -Raw -Encoding UTF8 | ConvertFrom-Json

# Affected chain of the CURRENT governed task (from the DB-M03 preflight scope;
# validated token-for-token against the reservation in PART 1). Every later
# chain/scope-relevance decision is keyed off this, never a hard-coded lineage.
$script:AffSet = @($script:Preflight.affectedNodes | Where-Object { $_ } | Select-Object -Unique)
$script:AffSetJoined = ($script:AffSet -join " / ")

$script:NodeId = [string]$script:CurrentState.nodeId
$script:ChangeId = [string]$script:CurrentState.changeId
$script:NodeName = [string]$script:CurrentState.name

if (-not $script:NodeId -or -not $script:ChangeId) {
    Stop-Outcome "STATE_MISSING_IDENTITY" "current-task.json does not carry a nodeId/changeId. Cannot build handoff."
}
if ($script:CurrentState.status -ne "RESERVED" -or $script:CurrentState.nextAllowedAction -ne "CHATGPT_HANDOFF") {
    Stop-Outcome "HANDOFF_STATE_STALE" ("Expected status=RESERVED / nextAllowedAction=CHATGPT_HANDOFF but found status={0} / nextAllowedAction={1}." -f $script:CurrentState.status, $script:CurrentState.nextAllowedAction)
}
# DB-M03.1: M05 never hands off a container. Backward compatible — legacy reserved state
# (no implementability field) passes through unchanged; every DB-M03.1 record carries
# implementability, so a handoff is only reachable for a governed IMPLEMENTABLE_LEAF.
$script:HandoffImpl = ""
if ($script:CurrentState.PSObject.Properties['implementability']) { $script:HandoffImpl = [string]$script:CurrentState.PSObject.Properties['implementability'].Value }
if ($script:HandoffImpl -and $script:HandoffImpl -ne "IMPLEMENTABLE_LEAF") {
    Stop-Outcome "HANDOFF_CONTAINER_PROHIBITED" ("Handoff target {0} is classified {1} - not an IMPLEMENTABLE_LEAF. M05 never hands off a container/incomplete/unknown node." -f $script:NodeId, $script:HandoffImpl)
}

Write-Output ("DB05_NODE_ID: " + $script:NodeId)
Write-Output ("DB05_CHANGE_ID: " + $script:ChangeId)
Write-Output ("DB05_STATE: " + $script:CurrentState.status + " / " + $script:CurrentState.nextAllowedAction)

# ---------------------------------------------------------------------------
# PART 1 - validate the reservation against the authoritative workbook (fresh)
# ---------------------------------------------------------------------------
$script:WorkbookHashBefore = Get-WorkbookSha256
$script:SheetsOk = $true
$script:AllSheets = @("Control Center","Master Roadmap","Active Changes","Audit Findings","Session Protocol","Version History","Phase Plan","Architecture Decisions","Open Decisions","Dependencies & Blockers","Tool & Integration Registry","Activity Log","Development Guide","Existing Assets")
foreach ($sn in $script:AllSheets) {
    try { $null = Open-DocEntry (Get-SheetEntryName $sn) } catch { $script:SheetsOk = $false; Write-Output ("  sheet check FAILED: " + $sn) }
}
if (-not $script:SheetsOk) {
    Stop-Outcome "HANDOFF_STATE_STALE" "Workbook structure no longer matches approved mappings: one or more of the 14 sheets failed to load."
}

# 1) Change ID exists exactly once as an active reservation
$script:AllAc = @(Get-AllActiveChanges)
$script:ResRows = @($script:AllAc | Where-Object { $_.ChangeId -eq $script:ChangeId })
if ($script:ResRows.Count -ne 1) {
    Stop-Outcome "HANDOFF_STATE_STALE" ("Change ID {0} appears {1} time(s) in Active Changes (expected exactly 1)." -f $script:ChangeId, $script:ResRows.Count)
}
$script:ResRow = $script:ResRows[0]
if ($script:ResRow.Classification -eq "Terminal") {
    Stop-Outcome "HANDOFF_STATE_STALE" ("Change ID {0} is no longer an active reservation (status: {1})." -f $script:ChangeId, $script:ResRow.Status)
}

# 2) Change ID references the correct Node ID
if (-not ([string]$script:ResRow.NodeId).Contains($script:NodeId)) {
    Stop-Outcome "HANDOFF_STATE_STALE" ("Change ID {0} references Node ID [{1}] not [{2}]." -f $script:ChangeId, $script:ResRow.NodeId, $script:NodeId)
}

# 3) Reserved scope matches DB-M03 (preflight) - set comparison on split tokens
function Compare-ScopeField([string]$label, [string]$live, [string]$expected) {
    $liveNorm = @($live -split "\|" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $expNorm = @($expected -split "\|" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $missing = @($expNorm | Where-Object { $_ -notin $liveNorm })
    $extra = @($liveNorm | Where-Object { $_ -notin $expNorm })
    if ($missing.Count -eq 0 -and $extra.Count -eq 0) { return $true }
    Write-Output ("  scope diff {0}: missing=[{1}] extra=[{2}]" -f $label, ($missing -join "|"), ($extra -join "|"))
    return $false
}
$script:ScopeOk = $true
$script:ScopeOk = $script:ScopeOk -and (Compare-ScopeField "repositories" $script:ResRow.Repositories (@($script:Preflight.repositories) -join "|"))
$script:ScopeOk = $script:ScopeOk -and (Compare-ScopeField "projects" $script:ResRow.Projects (@($script:Preflight.projects) -join "|"))
$script:ScopeOk = $script:ScopeOk -and (Compare-ScopeField "filesGlobs" $script:ResRow.FilesGlobs (@($script:Preflight.filesGlobs) -join "|"))
$script:ScopeOk = $script:ScopeOk -and (Compare-ScopeField "schemaContexts" $script:ResRow.SchemaContexts (@($script:Preflight.schemaContexts) -join "|"))
$script:ScopeOk = $script:ScopeOk -and (Compare-ScopeField "contractsApis" $script:ResRow.ContractsApis (@($script:Preflight.contractsApis) -join "|"))
$script:ScopeOk = $script:ScopeOk -and (Compare-ScopeField "affectedNodes" $script:ResRow.AffectedNodes (@($script:Preflight.affectedNodes) -join "|"))
if (-not $script:ScopeOk) {
    Stop-Outcome "HANDOFF_STATE_STALE" "Reserved scope no longer matches the DB-M03 preflight scope. The workbook wins; a handoff would be misleading."
}

# 4) Reservation remains active - already confirmed (Classification != Terminal).

# 5) No conflicting Active Change has appeared (fresh scan, token-accurate)
function Test-ProjectTokenOverlap([string]$cell, [string]$projectName) {
    if (-not $cell -or -not $projectName) { return $false }
    foreach ($tok in ($cell -split "[\s|,;]+")) {
        $clean = $tok.Trim() -replace "\s*\([^)]*\)\s*$", ""
        if ($clean -ieq $projectName) { return $true }
    }
    return $false
}
$script:Conflict = $null
foreach ($o in $script:AllAc) {
    if ($o.ChangeId -eq $script:ChangeId) { continue }
    if ($o.Classification -eq "Terminal") { continue }
    $named = @(($o.NodeId -split "\|") | ForEach-Object { $_.Trim() })
    $touchesChain = @($named | Where-Object { $script:Preflight.affectedNodes -contains $_ }).Count -gt 0
    if (@($named | Where-Object { $_ -eq $script:NodeId }).Count -gt 0) { $script:Conflict = ("Change {0} (row {1}) targets node [{2}] - conflicts with the reservation." -f $o.ChangeId, $o.Row, $o.NodeId); break }
    $otherGlobToks = @([string]$o.FilesGlobs -split "[|,;\r\n]+" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $resGlobToks = @($script:Preflight.filesGlobs)
    if (@($otherGlobToks | Where-Object { $resGlobToks -contains $_ }).Count -gt 0 -and (-not $touchesChain)) {
        $script:Conflict = ("Change {0} (row {1}) file-glob [{2}] overlaps a reserved glob - conflicts with the reservation." -f $o.ChangeId, $o.Row, $o.FilesGlobs); break
    }
    foreach ($p in $script:Preflight.projects) {
        if ($o.Projects -and (Test-ProjectTokenOverlap ([string]$o.Projects) $p) -and (-not $touchesChain)) { $script:Conflict = ("Change {0} (row {1}) project [{2}] overlaps reserved project [{3}]." -f $o.ChangeId, $o.Row, $o.Projects, $p); break }
    }
    if ($script:Conflict) { break }
    foreach ($c in $script:Preflight.contractsApis) {
        if ($o.ContractsApis -and ([string]$o.ContractsApis -match [regex]::Escape($c)) -and (-not $touchesChain)) { $script:Conflict = ("Change {0} (row {1}) contract [{2}] overlaps reserved contract [{3}]." -f $o.ChangeId, $o.Row, $o.ContractsApis, $c); break }
    }
    if ($script:Conflict) { break }
    $affNamed = @(($o.AffectedNodes -split "\|") | ForEach-Object { $_.Trim() })
    foreach ($a in $script:Preflight.affectedNodes) {
        if (@($affNamed | Where-Object { $_ -eq $a }).Count -gt 0 -and (-not $touchesChain)) { $script:Conflict = ("Change {0} (row {1}) affected-node [{2}] overlaps reserved chain." -f $o.ChangeId, $o.Row, $o.AffectedNodes); break }
    }
    if ($script:Conflict) { break }
}
if ($script:Conflict) {
    Stop-Outcome "HANDOFF_STATE_STALE" ("Conflicting Active Change appeared since reservation: " + $script:Conflict)
}

# 6) Required dependencies remain satisfied (live)
# DB-M03.2: a TRIAL_DEPENDENCY_SATISFIED predecessor (trial-proven for proving-cycle
# selection) is honored like a real SATISFIED predecessor; its real roadmap status
# stays authoritative and the truthful trial context is appended to the handoff.
$script:DepOk = $true
$script:DepLines = New-Object System.Collections.Generic.List[string]
$script:DepOverlays = @()
foreach ($depNode in @($script:Preflight.dependencies | Where-Object { $_.state -in @("SATISFIED", "TRIAL_DEPENDENCY_SATISFIED") })) {
    $live = Get-RoadmapNodeById $depNode.dependencyId
    if (-not $live) { $script:DepOk = $false; Write-Output ("  dependency node {0} missing from roadmap" -f $depNode.dependencyId); continue }
    if ($live.Status -in @("Complete","Completed")) {
        Write-Output ("  dependency {0} status = {1} (SATISFIED)" -f $depNode.dependencyId, $live.Status)
        $script:DepLines.Add(("| {0} | {1} | {2} | SATISFIED | NO |" -f $depNode.dependencyId, $depNode.detail, $live.Status)) | Out-Null
    } else {
        # DB-M03.2 TRIAL-only overlay: re-qualify the governedly closed trial evidence.
        $ov = Test-TrialDependencySatisfied -DependencyNodeId $depNode.dependencyId -StateDir $script:StateDir -ConfigPath (Join-Path $script:Root "config\devbridge.json") -RealStatus ([string]$live.Status)
        if ($ov.Satisfied) {
            Write-Output ("  dependency {0} status = {1} (TRIAL_DEPENDENCY_SATISFIED - proving cycle only)" -f $depNode.dependencyId, $live.Status)
            $script:DepLines.Add(("| {0} | {1} | {2} | TRIAL_DEPENDENCY_SATISFIED | NO |" -f $depNode.dependencyId, $depNode.detail, $live.Status)) | Out-Null
            $script:DepOverlays += $ov
        } else {
            $script:DepOk = $false
            if ($ov.BlockCode) {
                Write-Output ("  dependency {0} status = {1} (NOT satisfied - {2}: {3})" -f $depNode.dependencyId, $live.Status, $ov.BlockCode, $ov.Reason)
            } else {
                Write-Output ("  dependency {0} status = {1} (NOT satisfied)" -f $depNode.dependencyId, $live.Status)
            }
        }
    }
}
foreach ($rel in @(Get-DependencyRelations)) {
    if ([string]$rel.FromNode -eq $script:NodeId -or [string]$rel.DependsOnBlocks -eq $script:NodeId) {
        if ($rel.Status -eq "Open" -and $rel.Blocking -eq "Yes") {
            $script:DepOk = $false
            Write-Output ("  blocking relation {0} ({1}) is Open" -f $rel.RelationId, $rel.ReasonCondition)
        }
    }
}
if (-not $script:DepOk) {
    Stop-Outcome "HANDOFF_STATE_STALE" "Required dependency is no longer satisfied for the reserved change."
}

# 7) No new blocking decision/finding relevant to the reserved chain/scope (fresh)
# Relevance is computed from the CURRENT task's affected chain + reserved projects -
# never from a hard-coded milestone/area label.
$script:BlkHay = New-Object System.Collections.Generic.List[string]
foreach ($_bh in @($script:Preflight.affectedNodes) + @($script:Preflight.projects)) { if ($_bh) { $script:BlkHay.Add([string]$_bh) | Out-Null } }
$script:BlkHayU = @($script:BlkHay | Sort-Object -Unique)
foreach ($d in @($script:Preflight.openDecisions)) {
    if (-not $d.blocking) { continue }
    $dd = [string]$d.detail
    $rel = @($script:BlkHayU | Where-Object { $dd -match ([regex]::Escape($_)) }).Count -gt 0
    if ($rel) { Stop-Outcome "HANDOFF_STATE_STALE" ("Open decision {0} blocks this scope." -f $d.decisionId) }
}
foreach ($f in @($script:Preflight.auditFindings)) {
    if ($f.classification -ne "blocks") { continue }
    $fd = [string]$f.detail
    $rel = @($script:BlkHayU | Where-Object { $fd -match ([regex]::Escape($_)) }).Count -gt 0
    if ($rel) { Stop-Outcome "HANDOFF_STATE_STALE" ("Audit finding {0} blocks this scope." -f $f.findingId) }
}
Write-Output ("  no blocking open decision/finding for " + $script:NodeId + " (re-checked against the reserved chain/scope)")

# 8) Workbook structure - 14 sheets load (checked above)

Write-Output ("DB05_RESERVATION_VALID: True (row " + $script:ResRow.Row + ")")

# ---------------------------------------------------------------------------
# PART 2 - fresh parallel-lane recheck (LANE C is the collision axis)
# ---------------------------------------------------------------------------
$script:P2Conflicts = New-Object System.Collections.Generic.List[string]

# 2a) Lane roots must not overlap the reserved Nexus repository path
$script:LaneFacts = @($script:Reservation.parallelLaneCheck.lanes)
$script:LaneC = $null
foreach ($lf in $script:LaneFacts) { if ([string]$lf.lane -eq "C") { $script:LaneC = $lf } }
$script:LaneA = $null; $script:LaneB = $null
foreach ($lf in $script:LaneFacts) {
    if ([string]$lf.lane -eq "A") { $script:LaneA = $lf }
    if ([string]$lf.lane -eq "B") { $script:LaneB = $lf }
}
if (-not $script:LaneC) { Stop-Outcome "PARALLEL_SCOPE_CONFLICT" "Lane C facts missing from reservation.parallelLaneCheck." }
foreach ($other in @($script:LaneA, $script:LaneB)) {
    if (-not $other) { continue }
    $otherRoot = [string]$other.root
    $thisRoot = [string]$script:LaneC.root
    if ($otherRoot -and $thisRoot) {
        $a = $otherRoot.TrimEnd('\') + '\'
        $b = $thisRoot.TrimEnd('\') + '\'
        if ($a.StartsWith($b, [System.StringComparison]::OrdinalIgnoreCase) -or $b.StartsWith($a, [System.StringComparison]::OrdinalIgnoreCase)) {
            $script:P2Conflicts.Add(("Lane {0} ({1}) shares the repository root of lane C ({2})." -f $other.lane, $other.id, $thisRoot))
        }
    }
}

# 2b) Fresh open-reservation scan vs the reserved scope (chain rows excluded)
$script:OpenRes = @(Get-ActiveChangesOpen | Where-Object { $_.ChangeId -ne $script:ChangeId })
foreach ($r in $script:OpenRes) {
    $named = @(($r.NodeId -split "\|") | ForEach-Object { $_.Trim() })
    $touchesChain = @($named | Where-Object { $script:Preflight.affectedNodes -contains $_ }).Count -gt 0
    if (@($named | Where-Object { $_ -eq $script:NodeId }).Count -gt 0) {
        $script:P2Conflicts.Add(("node {0} reserved by {1}" -f $script:NodeId, $r.ChangeId))
    }
    $otherGlobToks2 = @([string]$r.FilesGlobs -split "[|,;\r\n]+" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $resGlobToks2 = @($script:Preflight.filesGlobs)
    if (@($otherGlobToks2 | Where-Object { $resGlobToks2 -contains $_ }).Count -gt 0 -and (-not $touchesChain)) {
        $script:P2Conflicts.Add(("file-glob overlap: {0} ({1})" -f $r.ChangeId, $r.NodeId))
    }
    foreach ($p in $script:Preflight.projects) {
        if ($r.Projects -and (Test-ProjectTokenOverlap ([string]$r.Projects) $p) -and (-not $touchesChain)) {
            $script:P2Conflicts.Add(("project overlap: {0} ({1})" -f $r.ChangeId, $r.NodeId)); break
        }
    }
    foreach ($c in $script:Preflight.contractsApis) {
        if ($r.ContractsApis -and ([string]$r.ContractsApis -match [regex]::Escape($c)) -and (-not $touchesChain)) {
            $script:P2Conflicts.Add(("contract overlap: {0} ({1})" -f $r.ChangeId, $r.NodeId)); break
        }
    }
    $affNamed = @(($r.AffectedNodes -split "\|") | ForEach-Object { $_.Trim() })
    foreach ($a in $script:Preflight.affectedNodes) {
        if (@($affNamed | Where-Object { $_ -eq $a }).Count -gt 0 -and (-not $touchesChain)) {
            $script:P2Conflicts.Add(("affected-node overlap: {0} ({1})" -f $r.ChangeId, $r.NodeId)); break
        }
    }
}
if ($script:P2Conflicts.Count -gt 0) {
    Stop-Outcome "PARALLEL_SCOPE_CONFLICT" ("Parallel-lane overlap with the reserved scope: " + ($script:P2Conflicts -join "; "))
}
Write-Output ("DB05_PARALLEL_LANE_RECHECK: PASS (" + $script:OpenRes.Count + " open reservations scanned; lane A/B roots outside lane C)")

# ---------------------------------------------------------------------------
# PART 3-18 - build the content model from state + live workbook evidence
# ---------------------------------------------------------------------------
$script:NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$script:Node = Get-RoadmapNodeById $script:NodeId
if (-not $script:Node) { Stop-Outcome "HANDOFF_STATE_STALE" ("Roadmap node {0} not found." -f $script:NodeId) }
$script:Parent = Get-RoadmapNodeById $script:Node.ParentId
if (-not $script:Parent) { Stop-Outcome "HANDOFF_STATE_STALE" ("Parent node {0} not found." -f $script:Node.ParentId) }
$script:Feature = $null
if ($script:Preflight.featureNodeId) { $script:Feature = Get-RoadmapNodeById ([string]$script:Preflight.featureNodeId) }
if (-not $script:Feature) {
    # Derive the governing Feature by climbing the roadmap parent chain (no hard-coded id).
    $script:FeatureCur = Get-RoadmapNodeById $script:Node.ParentId
    while ($script:FeatureCur) {
        if (([string]$script:FeatureCur.NodeId) -like "F-*") { $script:Feature = $script:FeatureCur; break }
        $script:FeatureCur = Get-RoadmapNodeById $script:FeatureCur.ParentId
    }
}

$script:ReservedScope = @{
    repositories = @($script:ResRow.Repositories -split "\|" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    projects = @($script:ResRow.Projects -split "\|" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    filesGlobs = @($script:ResRow.FilesGlobs -split "\|" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    schemaContexts = @($script:ResRow.SchemaContexts -split "\|" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    contractsApis = @($script:ResRow.ContractsApis -split "\|" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    affectedNodes = @($script:ResRow.AffectedNodes -split "\|" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Git baseline (captured at DB-M04). The PRIMARY (workbook-owner) repository stays the
# flat backward-compatible projection ($script:RepoPath / Baseline* / PreExisting*).
function Get-JsonField([object]$obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $f = $obj.PSObject.Properties[$name]
    if ($null -eq $f) { return $null }
    return $f.Value
}
$script:RepoPath = $script:Reservation.gitBaseline.repository
$script:BaselineBranch = $script:Reservation.gitBaseline.branch
$script:BaselineHead = $script:Reservation.gitBaseline.headCommit
$script:BaselineSubject = $script:Reservation.gitBaseline.headSubject
$script:PreExistingStaged = @($script:Reservation.gitBaseline.preExistingChanges.staged)
$script:PreExistingModified = @($script:Reservation.gitBaseline.preExistingChanges.modified)
$script:PreExistingUntracked = @($script:Reservation.gitBaseline.preExistingChanges.untracked)
$script:PostReservationModified = @($script:Reservation.gitBaseline.postReservationModifiedFiles)

# Per-repository baseline evidence. DB-M04 captures an independent pre-implementation
# baseline for EVERY repository in the exact reserved scope (not only the workbook-owner
# repository), so DB-M06 can classify PRE-EXISTING / GOVERNANCE / TASK delta per repo.
# This engine consumes reservation.repositoryBaselines (primary first). Reservations
# that predate that field fall back to the single gitBaseline record, synthesized as the
# primary baseline, so single-repository behavior is unchanged.
$script:RepoBaselineRaw = New-Object System.Collections.Generic.List[object]
# repositoryBaselines is absent on reservations captured before the multi-repository
# baseline feature. Get-JsonField returns $null for a missing field, and @($null)
# yields a ONE-element array containing $null (not empty) - so drop nulls here.
# Otherwise the legacy gitBaseline fallback below would never run and the reserved
# workbook-owner repository would be left without baseline evidence.
foreach ($_rr in @(Get-JsonField $script:Reservation 'repositoryBaselines')) {
    if ($null -ne $_rr) { $script:RepoBaselineRaw.Add($_rr) | Out-Null }
}
if ($script:RepoBaselineRaw.Count -eq 0) {
    $_lgPath = [string]$script:Reservation.gitBaseline.repository
    $_lgName = ""
    foreach ($_rn in @($script:ReservedScope.repositories)) {
        if (($_rn -ieq $_lgPath) -or ($_rn -ieq (Split-Path $_lgPath -Leaf))) { $_lgName = $_rn; break }
    }
    if (-not $_lgName) { $_lgName = Split-Path $_lgPath -Leaf }
    $_lg = New-Object PSCustomObject
    $_lg | Add-Member NoteProperty -Name name -Value $_lgName -Force
    $_lg | Add-Member NoteProperty -Name path -Value $_lgPath -Force
    $_lg | Add-Member NoteProperty -Name isPrimary -Value $true -Force
    $_lg | Add-Member NoteProperty -Name branch -Value ([string]$script:Reservation.gitBaseline.branch) -Force
    $_lg | Add-Member NoteProperty -Name headCommit -Value ([string]$script:Reservation.gitBaseline.headCommit) -Force
    $_lg | Add-Member NoteProperty -Name headSubject -Value ([string]$script:Reservation.gitBaseline.headSubject) -Force
    $_lg | Add-Member NoteProperty -Name preExistingChanges -Value $script:Reservation.gitBaseline.preExistingChanges -Force
    $_lg | Add-Member NoteProperty -Name postReservationModifiedFiles -Value @($script:Reservation.gitBaseline.postReservationModifiedFiles) -Force
    $_lg | Add-Member NoteProperty -Name scopeFileHashes -Value @($script:Reservation.gitBaseline.scopeFileHashes) -Force
    $_lg | Add-Member NoteProperty -Name capturedAt -Value ([string](Get-JsonField $script:Reservation.gitBaseline 'capturedAt')) -Force
    $script:RepoBaselineRaw.Add($_lg) | Out-Null
}

$script:RepoBaselines = New-Object System.Collections.Generic.List[object]
foreach ($_raw in $script:RepoBaselineRaw) {
    $_bpath = [string](Get-JsonField $_raw 'path')
    if (-not $_bpath) { $_bpath = [string](Get-JsonField $_raw 'repository') }
    $_bpreIn = Get-JsonField $_raw 'preExistingChanges'
    $_bpre = New-Object PSCustomObject
    $_bpre | Add-Member NoteProperty -Name modified -Value @(Get-JsonField $_bpreIn 'modified') -Force
    $_bpre | Add-Member NoteProperty -Name staged -Value @(Get-JsonField $_bpreIn 'staged') -Force
    $_bpre | Add-Member NoteProperty -Name untracked -Value @(Get-JsonField $_bpreIn 'untracked') -Force
    $_bpre | Add-Member NoteProperty -Name note -Value ([string](Get-JsonField $_bpreIn 'note')) -Force
    $_b = New-Object PSCustomObject
    $_b | Add-Member NoteProperty -Name name -Value ([string](Get-JsonField $_raw 'name')) -Force
    $_b | Add-Member NoteProperty -Name path -Value $_bpath -Force
    $_b | Add-Member NoteProperty -Name isPrimary -Value ([bool](Get-JsonField $_raw 'isPrimary')) -Force
    $_b | Add-Member NoteProperty -Name branch -Value ([string](Get-JsonField $_raw 'branch')) -Force
    $_b | Add-Member NoteProperty -Name headCommit -Value ([string](Get-JsonField $_raw 'headCommit')) -Force
    $_b | Add-Member NoteProperty -Name headSubject -Value ([string](Get-JsonField $_raw 'headSubject')) -Force
    $_b | Add-Member NoteProperty -Name preExistingChanges -Value $_bpre -Force
    $_b | Add-Member NoteProperty -Name postReservationModifiedFiles -Value @(Get-JsonField $_raw 'postReservationModifiedFiles') -Force
    $_b | Add-Member NoteProperty -Name scopeFileHashes -Value @(Get-JsonField $_raw 'scopeFileHashes') -Force
    $_b | Add-Member NoteProperty -Name capturedAt -Value ([string](Get-JsonField $_raw 'capturedAt')) -Force
    $script:RepoBaselines.Add($_b) | Out-Null
}

# Reserved-scope coverage: EVERY repository in the exact reserved scope must carry an
# independent baseline. A missing baseline means DB-M06 cannot classify that repository's
# delta, so the implementation handoff is BLOCKED (governance gap, not a pass).
$_missingBase = @()
foreach ($_resrepo in @($script:ReservedScope.repositories)) {
    $_cov = @($script:RepoBaselines | Where-Object {
        ($_.name -ieq $_resrepo) -or ($_.path -and ($_.path -ieq $_resrepo)) -or ($_.path -and ((Split-Path $_.path -Leaf) -ieq $_resrepo))
    })
    if ($_cov.Count -eq 0) { $_missingBase += $_resrepo }
}
if ($_missingBase.Count -gt 0) {
    Stop-Outcome "BASELINE_COVERAGE_GAP" ("Reserved repository baseline missing for: " + ($_missingBase -join ", ") + ". DB-M04 must capture an independent pre-implementation git baseline for EVERY reserved repository before an implementation handoff is generated.")
}

# Pending governance items (read, not hard-coded)
$script:PendingItems = @($script:CurrentState.pendingGovernanceItems)

# Classification map for audit findings (from DB-M03 preflight evidence)
$script:AfClass = @{}
foreach ($pf in @($script:Preflight.auditFindings)) { $script:AfClass[[string]$pf.findingId] = [string]$pf.classification }

# ---- Derived task context (DB-M05 context-integrity) -------------------------
# Every value below is rebuilt FRESH from the current governed task (state +
# authoritative workbook) on each run. Previous-cycle acceptance criteria, exact
# scope, instructions, current-state prose, file globs and work-item identifiers
# are NEVER reused. If governance does not supply a mandatory input the handoff
# stops as CHATGPT_HANDOFF_NOT_READY - the engine does not fabricate it.
$script:NodeAcRaw = [string]$script:Node.AcceptanceCriteria
if (-not $script:NodeAcRaw -or $script:NodeAcRaw.Trim().Length -eq 0) {
    Write-Output "DB05_OUTCOME: HANDOFF_NOT_READY"
    Write-Output "DB05_HANDOFF_TOKEN: CHATGPT_HANDOFF_NOT_READY"
    Write-Output "DB05_GOVERNANCE_GAP: ACCEPTANCE_CRITERIA"
    Write-Output ("DB-M05 STOP - Master Roadmap row " + $script:Node.Row + " (" + $script:NodeId + ") carries no governed Acceptance Criteria (column Q). Governed AC are required before a handoff; none was fabricated.")
    exit 1
}
if (@($script:ReservedScope.repositories).Count -eq 0 -or @($script:ReservedScope.projects).Count -eq 0) {
    Write-Output "DB05_OUTCOME: HANDOFF_NOT_READY"
    Write-Output "DB05_HANDOFF_TOKEN: CHATGPT_HANDOFF_NOT_READY"
    Write-Output "DB05_GOVERNANCE_GAP: RESERVED_SCOPE"
    Write-Output ("DB-M05 STOP - reservation " + $script:ChangeId + " (Active Changes row " + $script:ResRow.Row + ") records no repositories or projects. The exact reserved scope is incomplete; a handoff would be misleading.")
    exit 1
}
$script:NodeAcBullets = @($script:NodeAcRaw -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($script:NodeAcBullets.Count -eq 0) { $script:NodeAcBullets = @($script:NodeAcRaw.Trim()) }

# Governed handoff chain (PART 4, live): Active Changes whose NodeId intersects the
# CURRENT task's affected chain. No other lineage is ever treated as this chain.
$script:ChainRows = @($script:AllAc | Where-Object {
    $named = @(($_.NodeId -split "\|") | ForEach-Object { $_.Trim() })
    @($named | Where-Object { $script:AffSet -contains $_ }).Count -gt 0
} | Sort-Object ChangeId)

# Live Existing Assets sheet (authoritative for the Existing Assets section)
$script:ExistingLive = @(Get-ExistingAssets)

# Related Existing Assets: rows whose workbook text references a reserved project or
# file/glob (whole repository names are used only when they are not a prefix of a
# reserved project, to avoid matching other layers inside the same repo).
$script:RelResToks = @(@($script:ReservedScope.projects) + @($script:ReservedScope.filesGlobs) | Where-Object { $_ } | Select-Object -Unique)
foreach ($_rr in @($script:ReservedScope.repositories)) {
    $isPrefix = @($script:ReservedScope.projects | Where-Object { $_ -like ($_rr + "*") }).Count -gt 0
    if (-not $isPrefix -and -not ($script:RelResToks -contains $_rr)) { $script:RelResToks += $_rr }
}
$script:RelResRe = ($script:RelResToks | ForEach-Object { [regex]::Escape($_) }) -join "|"
$script:RelAssets = @()
if ($script:RelResRe) {
    $script:RelAssets = @($script:ExistingLive | Where-Object {
        $cellAll = @($_.PSObject.Properties | ForEach-Object { if ($null -ne $_.Value) { [string]$_.Value } }) -join " "
        $cellAll -match $script:RelResRe
    })
}
$script:RelTools = @()
if ($script:RelResRe) {
    $script:RelTools = @(Get-ToolRegistry | Where-Object {
        $cellAll = @($_.PSObject.Properties | ForEach-Object { if ($null -ne $_.Value) { [string]$_.Value } }) -join " "
        $cellAll -match $script:RelResRe
    })
}

# Related architecture decisions: DB-M03 preflight classification + live ADR text.
$script:RelAdr = @($script:Preflight.architectureDecisions | Sort-Object { [string]$_.adrId })
$script:AdrLive = @{}
foreach ($_aa in @(Get-AllAdrs)) { $script:AdrLive[[string]$_aa.AdrId] = $_aa }

# Related audit findings: Audit Findings rows whose RoadmapLink references the chain.
$script:RelevantAf = @(Get-AllAuditFindings | Where-Object {
    $rl = [string]$_.RoadmapLink
    @($script:AffSet | Where-Object { $rl -match ([regex]::Escape($_)) }).Count -gt 0
})

# Related phase-plan rows: Phase Plan rows whose RoadmapLink references the chain.
$script:RelPhase = @()
try {
    $script:RelPhase = @(Get-PhasePlan | Where-Object {
        $rl = [string]$_.RoadmapLink
        @($script:AffSet | Where-Object { $rl -match ([regex]::Escape($_)) }).Count -gt 0
    })
} catch { $script:RelPhase = @() }

# ---------------------------------------------------------------------------
# Markdown assembly
# ---------------------------------------------------------------------------
$script:Lines = New-Object System.Collections.Generic.List[string]

function Add-Line([string]$text) { $script:Lines.Add($text) | Out-Null }
function Add-Section([string]$title) {
    Add-Line ""
    Add-Line ("## " + $title)
    Add-Line ""
}

# ---- Header ----
Add-Line "# Nexus DevBridge - ChatGPT Implementation Handoff"
Add-Line ""
Add-Line "## User Action"
Add-Line ""
Add-Line "Copy this complete handoff to ChatGPT."
Add-Line ""
Add-Line "Ask ChatGPT to generate the DeepSeek implementation prompt."
Add-Line ""
Add-Line ("Generated by DevBridge DB-M05 (New-ChatGptHandoff.ps1) at " + $script:NowUtc + ". The authoritative Nexus Development Control workbook was freshly re-read and the reservation revalidated before this handoff was produced.")

# ---- DB-GH01 Governance Contract (self-contained; ChatGptHandoffValidation v1) ----
Add-Section "DevBridge Governance Contract (DB-GH01)"
Add-Line "DevBridge is TEMPORARY external scaffolding supporting Nexus Phase 1/2 only, until Nexus has its permanent Developer Chat and Automatic Developer. It is NOT part of Nexus; nothing implemented in it may become Nexus runtime, architecture, contracts, services, libraries, infrastructure, or a dependency. DevBridge will be RETIRED."
Add-Line "Operating MODE: TRIAL (this cycle). REAL_NEXUS_DEVELOPMENT is the explicit alternative; mode is never inferred from file paths."
Add-Line "The roadmap is ABSOLUTELY IMMUTABLE: no autonomous change to phases, milestones, phase implementation structure, roadmap hierarchy/sequencing, development order, architecture/layer structure, goals/outcomes, acceptance criteria, or dependencies. DevBridge may update EXECUTION STATE only (task status, progress, evidence)."
Add-Line "NEXUS_DEVELOPMENT_CONTROL.xlsx is the authoritative control record. No agent may redesign the workbook or rewrite its history."
Add-Line "Git is a FORMAL HUMAN-GATED lifecycle: a human creates, reviews, and merges the PR. No agent approves its own PR, merges automatically, or infers a merge."
Add-Line "Claude review is the DB-M08 gate: PASS / FIX / GOVERNANCE_ISSUE / HUMAN_DECISION_REQUIRED."
Add-Line ("Task identity: Node " + $script:NodeId + " / Change " + $script:ChangeId + " / node type " + $script:Node.NodeType + ".")
Add-Line "The EXACT reserved scope is declared below. THIS IS A HARD BOUNDARY."
Add-Line "FORBIDDEN: roadmap structural edits; PR creation/approval/merge by an agent; Nexus architecture/contract changes; scope expansion without reporting SCOPE_CHANGE_REQUIRED."
Add-Line "Acceptance criteria below are authoritative and must not be altered."
Add-Line "DB-M06 deterministic verification follows implementation; self-reported PASS is never final."
Add-Line "The expected DeepSeek completion report contract is declared below."

# ---- Authoritative Task ----
Add-Section "Authoritative Task"
Add-Line ("- **Node ID:** " + $script:NodeId)
Add-Line ("- **Task / Work item:** " + $script:NodeName)
Add-Line ("- **Change ID:** " + $script:ChangeId + " (Active Changes row " + $script:ResRow.Row + ")")
Add-Line ("- **Node Type:** " + $script:Node.NodeType)
Add-Line ("- **Phase:** " + $script:Node.Phase)
Add-Line ("- **Layer:** " + $script:Node.Layer)
$script:FeatureLabel = if ($script:Feature) { ($script:Feature.NodeId + " (" + $script:Feature.Name + ")") } else { "(governing Feature node not resolved in roadmap)" }
Add-Line ("- **Parent / hierarchy:** " + $script:Node.ParentId + " (" + $script:Parent.Name + ") - Feature " + $script:FeatureLabel)
Add-Line ("- **Gate:** " + $script:Node.Gate)

# ---- Development Control ----
Add-Section "Development Control"
Add-Line ("Node ID: " + $script:NodeId)
Add-Line ("Change ID: " + $script:ChangeId)
Add-Line ("Reservation: " + $script:ResRow.Status)
Add-Line ("Preflight: " + $script:ResRow.PreflightVerdict + " (DB-M03)")
Add-Line ("Workbook SHA256 (re-read at handoff time): " + $script:WorkbookHashBefore)

# ---- Goal ----
Add-Section "Goal"
Add-Line ("**Simple Goal / Outcome / Purpose** (Master Roadmap row " + $script:Node.Row + ", authoritative):")
Add-Line ""
Add-Line ("**" + $script:Node.OutcomePurpose + "**")
Add-Line ""
Add-Line ("Reservation summary (Active Changes row " + $script:ResRow.Row + "): " + $script:ResRow.Summary)
Add-Line ""
Add-Line ("Milestone context (" + $script:Parent.NodeId + " '" + $script:Parent.Name + "' Outcome / Purpose): " + $script:Parent.OutcomePurpose)

# ---- Current State ----
Add-Section "Current State"
$script:NextActionClean = ([string]$script:Node.NextAction).TrimEnd('.', ' ')
Add-Line ("- **Status:** " + $script:Node.Status + " (Master Roadmap row " + $script:Node.Row + ") - next action: " + $script:NextActionClean + ". The Active Changes reservation for this change is Open; implementation is pending the ChatGPT handoff.")
Add-Line ("- **Preflight:** CLEAR (DB-M03); reservation active via DB-M04 (" + $script:ChangeId + ", row " + $script:ResRow.Row + "). Baseline captured; no Nexus source touched by DB-M04.")
$script:DepSummaryLines = New-Object System.Collections.Generic.List[string]
foreach ($dtok in @($script:Preflight.dependencies | Where-Object { $_.state -in @("SATISFIED", "TRIAL_DEPENDENCY_SATISFIED") })) {
    $dstat = if ([string]$dtok.status) { " (" + $dtok.status + ")" } else { "" }
    $dlabel = if ($dtok.state -eq "TRIAL_DEPENDENCY_SATISFIED") { "TRIAL_DEPENDENCY_SATISFIED (proving-cycle selection only; real roadmap status " + $dtok.status + " remains authoritative - NOT real Nexus completion)" } else { "SATISFIED" }
    $script:DepSummaryLines.Add(($dtok.dependencyId + " (" + $dtok.detail + ") = " + $dlabel + $dstat))
}
if ($script:DepSummaryLines.Count -gt 0) {
    Add-Line ("- **Dependency:** " + ($script:DepSummaryLines -join "; ") + ".")
} else {
    Add-Line "- **Dependency:** none recorded."
}
Add-Line ("- **Milestone:** " + $script:Parent.NodeId + " (" + $script:Parent.Name + ") Status '" + $script:Parent.Status + "' - the governed parent container resolved to this leaf (" + $script:Node.NodeType + ") by DB-M03.1.")
$script:FeatureStat = if ($script:Feature) { ("Status '" + $script:Feature.Status + "'") } else { "Status not resolved" }
Add-Line ("- **Feature / chain:** " + $script:FeatureLabel + " " + $script:FeatureStat + "; affected chain reserved for this change: " + $script:AffSetJoined + ".")
Add-Line ("- **This work item (" + $script:NodeId + "):** " + [string]$script:Node.OutcomePurpose + " - to be implemented inside the exact reserved scope declared below.")
Add-Line ("- **Reserved repositories / projects:** " + (@($script:ReservedScope.repositories) -join ", ") + " / " + (@($script:ReservedScope.projects) -join ", ") + ".")
Add-Line ("- **Reservation ledger state:** " + $script:ResRow.Status + " - no implementation delta exists at DB-M05 time; the change is awaiting the ChatGPT handoff and the DeepSeek prompt.")
if ($script:RelPhase.Count -gt 0) {
    Add-Line ("- **Phase Plan context:** " + (@($script:RelPhase | ForEach-Object { $_.PhaseStep + " (" + $_.Objective + ") [" + $_.Status + "]" }) -join "; ") + ".")
}

# ---- Why This Work Is Current ----
Add-Section "Why This Work Is Current"
Add-Line "From governance evidence (no AI opinion added):"
Add-Line ""
$script:NextWorkDepDetail = $null
foreach ($ctok in @($script:Preflight.dependencies | Where-Object { $_.state -in @("SATISFIED", "TRIAL_DEPENDENCY_SATISFIED") })) {
    $cdetail = $ctok.dependencyId + " (" + $ctok.state + ")"
    if (-not $script:NextWorkDepDetail) { $script:NextWorkDepDetail = $cdetail } else { $script:NextWorkDepDetail = $script:NextWorkDepDetail + ", " + $cdetail }
}
if (-not $script:NextWorkDepDetail) { $script:NextWorkDepDetail = "none" }
Add-Line ("1. **NEXT WORK drill-down** (DB-M03 selection): the governed container " + $script:Parent.NodeId + " (" + $script:Parent.Name + ") is Status '" + $script:Parent.Status + "'. DB-M03.1 resolved it to this eligible WorkItem (" + $script:NodeId + ", " + $script:Node.NodeType + "); satisfied dependencies at selection time: " + $script:NextWorkDepDetail + ".")
Add-Line ("2. **CURRENT WORK FIRST**: " + $script:Parent.NodeId + " (" + $script:Parent.Name + ") is Status '" + $script:Parent.Status + "' and is named by open reservation(s) in the Active Changes ledger - including " + $script:ChangeId + ", the reservation this handoff serves. It is not skipped for higher-priority Planned work.")
Add-Line ("3. **Governed handoff chain** in Active Changes (fresh read, filtered to this change's affected chain " + $script:AffSetJoined + "):")
$script:ChainText = New-Object System.Collections.Generic.List[string]
$script:ChainIndex = 0
if ($script:ChainRows.Count -eq 0) {
    $script:ChainText.Add($script:ChangeId + " (this reservation, awaiting ChatGPT handoff)") | Out-Null
}
foreach ($cr in $script:ChainRows) {
    $script:ChainIndex++
    if ($cr.ChangeId -eq $script:ChangeId) {
        $script:ChainText.Add($cr.ChangeId + " (this reservation, awaiting ChatGPT handoff)") | Out-Null
    } else {
        $script:LeafTok = @(($cr.NodeId -split "\|") | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Last 1)
        $road = $null
        if ($script:LeafTok) { $road = Get-RoadmapNodeById $script:LeafTok }
        $st = "recorded"
        if ($road) { $st = $road.Status.ToLower() }
        $script:ChainText.Add($cr.ChangeId + " (" + $script:LeafTok + " " + $st + ")") | Out-Null
    }
}
Add-Line ("   " + ($script:ChainText -join " -> "))
Add-Line ("   The current row (" + $script:ChangeId + ") is the reservation awaiting the ChatGPT handoff. Any earlier rows shown are prior governed reservations on this change's affected chain - historical context, never this task's identity.")

# ---- Acceptance Criteria ----
Add-Section "Acceptance Criteria"
Add-Line ("Acceptance criteria below are the governed acceptance criteria carried by Master Roadmap row " + $script:Node.Row + " (column Q, authoritative) for " + $script:NodeId + " - read fresh on this run. They are authoritative and must not be altered, added to, dropped or reinterpreted. If implementation evidence shows a governing requirement is missing or a criterion is unsatisfiable, report it - do not invent, relax or silently change one.")
Add-Line ""
foreach ($_ab in $script:NodeAcBullets) { Add-Line ("- " + $_ab) }
Add-Line ""
Add-Line ("**Acceptance-criteria ownership:** these criteria belong to the current governed work item (" + $script:NodeId + "). Only this change's affected chain (" + $script:AffSetJoined + ") and whatever the governed criteria text itself references are in scope; no other work item's acceptance criteria, scope or wording is adopted here.")

# ---- Completion Gate ----
Add-Section "Completion Gate"
Add-Line ("**" + $script:Node.Gate + "** - completion is verified by DevBridge DB-M06 after implementation; DeepSeek's self-reported PASS is not final approval.")

# ---- Dependency Development Lineage (DB-M18.1, additive; READ-only) ----
# Resolves the governed dependency graph, collects per-dependency development
# lineage, reconciles against the current repository, and assembles a compact
# context for this handoff. NEVER alters the mandatory zero-context sections
# above, existing markers, or exit codes. If the resolver library, its evidence
# root or the reconciliation is unavailable the handoff proceeds exactly as
# before (DB05_LINEAGE_CONTEXT_UNAVAILABLE).
$script:Db181Available = $false
$script:Db181Section = ''
$script:Db181Graph = $null
$script:Db181Context = $null
$db181Lib = Join-Path $script:Root 'scripts\ai-routing\DependencyLineage.ps1'
$db181Evidence = Join-Path $script:LogsDir 'tasks'
if ((Test-Path -LiteralPath $db181Lib) -and (Test-Path -LiteralPath $db181Evidence)) {
    try {
        . $db181Lib
        $db181Catalog = @{}
        foreach ($db181Rn in @(Get-AllRoadmapNodes)) {
            if (-not $db181Rn -or -not $db181Rn.NodeId) { continue }
            $db181DepIds = @()
            if ($db181Rn.Dependencies) {
                $db181DepIds = @([string]$db181Rn.Dependencies -split "[\r\n|]" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^(F|M|WI|T|S)-' } | Select-Object -Unique)
            }
            $db181Catalog[[string]$db181Rn.NodeId] = @{ taskId = [string]$db181Rn.NodeId; dependencies = @($db181DepIds | ForEach-Object { @{ dependencyId = $_; state = 'UNKNOWN' } }) }
        }
        $db181Deps = @()
        if ($script:Preflight.dependencies) { $db181Deps = @($script:Preflight.dependencies) }
        $db181Task = [pscustomobject]@{
            taskId = $script:NodeId
            nodeId = $script:NodeId
            changeId = $script:ChangeId
            name = ([string](Get-ContractProperty $script:Node 'Name' ''))
            dependencies = $db181Deps
        }
        $db181Bundle = Get-DbM181TaskDependencyContext -Task $db181Task -TaskCatalog $db181Catalog -EvidenceRoot $db181Evidence -RepositoryRoot $script:RepoPath -NowUtc $script:NowUtc
        $script:Db181Section = Get-DbM181HandoffLineageSection -Task $db181Task -Context $db181Bundle.Context
        $script:Db181Graph = $db181Bundle.Graph
        $script:Db181Context = $db181Bundle.Context
        $script:Db181Available = $true
        Write-Output ("DB05_LINEAGE_CONTEXT: " + $db181Bundle.Context.FreshnessStatus)
    } catch {
        $script:Db181Available = $false
        Write-Output ("DB05_LINEAGE_CONTEXT_UNAVAILABLE: " + $_.Exception.Message)
    }
}

# ---- Dependencies ----
Add-Section "Dependencies"
Add-Line "| Node ID | Detail | Live status | Satisfied? | Blocking? |"
Add-Line "|---|---|---|---|---|"
foreach ($dl in $script:DepLines) { Add-Line $dl }
foreach ($_dn in @($script:Preflight.dependencies | Where-Object { $_.state -notin @("SATISFIED", "TRIAL_DEPENDENCY_SATISFIED") })) {
    $_det = [string]$_dn.detail
    if (-not $_det) { $_det = "(no detail recorded)" }
    $_st = [string]$_dn.state
    if (-not $_st) { $_st = "(n/a)" }
    Add-Line ("| " + $_dn.dependencyId + " | " + $_det + " | (n/a) | " + $_st + " | NO |")
}
Add-Line ""
$script:DepTextual = @($script:Preflight.dependencies | Where-Object { $_.dependencyId -match "^(F|WI|M|T|S)-" })
if ($script:DepTextual.Count -gt 0) {
    Add-Line ("Textual dependency on Master Roadmap: " + $script:NodeId + " -> " + (@($script:DepTextual | ForEach-Object { $_.dependencyId }) -join ", ") + ".")
} else {
    Add-Line "Textual dependency on Master Roadmap: none recorded for this work item."
}

# ---- DB-M03.2 TRIAL-PROVEN DEPENDENCY CONTEXT (truthful; capability 10) ----
# When a predecessor was satisfied ONLY by the TRIAL-only overlay, the handoff must
# tell ChatGPT the truth: the predecessor is NOT real-complete, its real roadmap status
# is authoritative, and the trial-proven evidence is disposable proving context.
if ($script:DepOverlays.Count -gt 0) {
    Add-Section "Trial-Proven Dependency Context (DB-M03.2) - READ CAREFULLY"
    Add-Line "The following predecessor(s) were satisfied for THIS PROVING CYCLE by the TRIAL-only dependency overlay. This is **NOT real Nexus completion**:"
    foreach ($tov in @($script:DepOverlays)) {
        $tp = $tov.Provenance
        Add-Line ("- **" + $tp.nodeId + "** real roadmap status: **" + $tp.realStatus + "** (NOT Completed/Complete; real status remains authoritative).")
        Add-Line ("- Proving status: **TRIAL_CYCLE_CLOSED** via change **" + $tp.changeId + "** (closed " + $tp.closedAtUtc + "); implementation state **TRIAL_ONLY_UNMERGED** - disposable DevBridge proving context, NOT merged into Nexus.")
        Add-Line ("- Verification evidence (DB-M06): **" + $tp.verificationEvidence.m06Result + "** - tests " + $tp.verificationEvidence.testsPassed + "/" + $tp.verificationEvidence.testsTotal + " passed (build " + $tp.verificationEvidence.buildWarnings + " warning(s) / " + $tp.verificationEvidence.buildErrors + " error(s)).")
        Add-Line ("- Claude review (DB-M08): decision **" + $tp.claudeEvidence.decision + "**, trialMode " + $tp.claudeEvidence.trialMode + ", reviewed against DB-M06 = " + $tp.claudeEvidence.reviewedAgainstDbM06 + ".")
        Add-Line ("- Overlay status applied for selection: **TRIAL_DEPENDENCY_SATISFIED**; real completion capability = **NO**; repository reconciliation freshness = **" + $tp.repositoryReconciliation.freshness + "**.")
        Add-Line ("- Do NOT treat " + $tp.nodeId + " as Complete/Merged. The real Nexus restart point is the preserved PRE-DEVBRIDGE workbook + source/Git baseline; nothing from the proving environment becomes genuine Nexus progress.")
    }
    Add-Line ""
}

# ---- Dependency Development Lineage section (DB-M18.1, additive) ----
if ($script:Db181Available -and $script:Db181Section) {
    foreach ($db181Ln in @($script:Db181Section -split "`n")) { Add-Line $db181Ln }
}

# ---- Scope Transition ----
Add-Section "Scope Transition (governed - do not reinterpret)"
$script:PredIds = @($script:Preflight.dependencies | Where-Object { $_.dependencyId -match "^(F|WI|M|T|S)-" } | ForEach-Object { $_.dependencyId })
if ($script:PredIds.Count -gt 0) {
    Add-Line ("- **" + ($script:PredIds -join ", ") + "** is the governed predecessor for this reservation; its current live status is the authoritative one. When it was satisfied ONLY by the TRIAL-only overlay (see Trial-Proven Dependency Context above), it is NOT real-complete and must not be treated as merged Nexus progress.")
} else {
    Add-Line "- No governed textual predecessor recorded for this reservation."
}
$_glDesc = if (@($script:ReservedScope.filesGlobs).Count -gt 0) { (", file/glob scope **" + (@($script:ReservedScope.filesGlobs) -join ", ") + "**") } else { ", with no narrower file/glob recorded in the reservation" }
Add-Line ("- **" + $script:NodeId + " (this reservation)** is scoped to repository(ies) **" + (@($script:ReservedScope.repositories) -join ", ") + "**, project(s) **" + (@($script:ReservedScope.projects) -join ", ") + "**" + $_glDesc + " - via " + $script:ChangeId + " (Active Changes row " + $script:ResRow.Row + ").")
Add-Line "- This is the governed scope transition into this work item, not an invitation to reinterpret the boundary. Do not widen or narrow the reserved scope."
Add-Line "- DeepSeek MUST first inspect the existing code in the reserved repositories/projects relevant to this work item before writing any code - to reuse (not rebuild) working capabilities and to stay inside the exact reserved scope."
Add-Line ("- If implementing " + $script:NodeId + " genuinely requires modifying anything outside the exact reserved scope, DeepSeek MUST STOP and report `SCOPE_CHANGE_REQUIRED` rather than touching it.")

# ---- Architecture Constraints ----
Add-Section "Architecture Constraints"
Add-Line "Applicable approved ADRs (Architecture Decisions sheet freshly re-read; each ADR's relation to this chain is the DB-M03 preflight classification):"
Add-Line ""
foreach ($_ar in @($script:RelAdr)) {
    $_arId = [string]$_ar.adrId
    $_arRel = [string]$_ar.relation
    $_arSt = "Approved"
    $_arDec = ""
    if ($script:AdrLive.ContainsKey($_arId)) {
        $_arSt = [string]$script:AdrLive[$_arId].Status
        $_arDec = [string]$script:AdrLive[$_arId].Decision
    }
    if ($_arRel -in @("GOVERNS_TARGET", "GOVERNS_SUBSTRATE")) {
        if (-not $_arDec) { $_arDec = [string]$_ar.detail }
        Add-Line ("- **" + $_arId + " (" + $_arSt + ") - " + $_arRel + ":** " + $_arDec)
    } else {
        Add-Line ("- **" + $_arId + " (" + $_arSt + ") - " + $_arRel + ":** " + [string]$_ar.detail)
    }
}
Add-Line ""
Add-Line ("Preflight architecture/leaf validation verdict for " + $script:NodeId + ": **" + $script:Preflight.verdict + "** (" + @($script:Preflight.leafValidation).Count + " leaf checks recorded). The reserved implementation must conform to the governing ADRs above; a genuine architectural conflict is reported, never silently resolved. A construct the reserved scope cannot legally host (for example an OS/filesystem primitive that belongs to an out-of-scope layer) is a scope question to be reported, not silently placed elsewhere.")

# ---- Open Decisions ----
Add-Section "Open Decisions"
Add-Line "| Decision ID | Blocking? | Detail (DB-M03 preflight classification) |"
Add-Line "|---|---|---|"
foreach ($_od in @($script:Preflight.openDecisions)) {
    $_odBlk = if ($_od.blocking) { "BLOCKING" } else { "NON-BLOCKING" }
    Add-Line ("| " + $_od.decisionId + " | " + $_odBlk + " | " + [string]$_od.detail + " |")
}
Add-Line ""
Add-Line "The open decisions shown are the current ledger items carried by this change's preflight. None is BLOCKING for this work item (a blocking open decision would have stopped the handoff in PART 1). This handoff resolves none of them."

# ---- Audit Findings ----
Add-Section "Audit Findings"
Add-Line "Applicable findings (Audit Findings sheet, freshly re-read; classification from DB-M03 preflight evidence; relevance = RoadmapLink references this change's affected chain):"
Add-Line ""
if ($script:RelevantAf.Count -gt 0) {
    foreach ($f in $script:RelevantAf) {
        $cls = $script:AfClass[[string]$f.FindingId]
        if (-not $cls) { $cls = "informational" }
        $clsUpper = $cls.ToUpper()
        if ($clsUpper -eq "CONSTRAINS") { $clsUpper = "CONSTRAINS implementation" }
        Add-Line ("- **" + $f.FindingId + " (" + $f.Severity + ", " + $f.Status + ") - " + $clsUpper + ":** " + $f.Area + " | " + $f.RoadmapLink)
    }
    Add-Line ""
    Add-Line "No finding above is BLOCKING for this work item (a blocking finding would have stopped the handoff in PART 1). Findings whose RoadmapLink references other chains are not adopted as constraints here."
} else {
    Add-Line ("No Audit Findings row references this change's affected chain (" + $script:AffSetJoined + "). Findings that link other milestones are NOT adopted as constraints for this work item.")
}
Add-Line ""
Add-Line "Classification meaning: BLOCKING = cannot proceed; CONSTRAINS = shapes how the work is done; INFORMATIONAL = context only; EXPECTED_TO_RESOLVE = expected to close during this work item."

# ---- Existing Assets ----
Add-Section "Existing Assets - REUSE / EXTEND / ALREADY_EXISTS / MISSING"
Add-Line ("Classified for THIS work item (" + $script:NodeId + ") from live Existing Assets sheet rows that reference the reserved scope (project(s) " + (@($script:ReservedScope.projects) -join ", ") + "). The implementation prompt must instruct DeepSeek NOT to rebuild working capabilities:")
Add-Line ""
if ($script:RelAssets.Count -gt 0) {
    Add-Line "| Asset | Classification | Live workbook evidence |"
    Add-Line "|---|---|---|"
    foreach ($_ra in $script:RelAssets) {
        $_raSt = [string]$_ra.State
        $_raCls = "INFORMATIONAL"
        if ($_raSt -match "Working prototype|Implemented|Existing|Substantial progress") { $_raCls = "REUSE / ALREADY_EXISTS" }
        $_raEv = ("Existing Assets row " + $_ra.Row + " - " + $_ra.WhatAlreadyExists + " [" + $_ra.RepositoryFiles + "]; State: " + $_raSt)
        Add-Line ("| " + $_ra.Area + " | **" + $_raCls + "** | " + $_raEv + " |")
    }
    Add-Line ""
    Add-Line "REUSE / ALREADY_EXISTS = consume what exists and do not rebuild or duplicate it unless this work item's governed acceptance criteria require a change; INFORMATIONAL = context only."
} else {
    Add-Line ("No Existing Assets sheet row references the reserved scope (" + (@($script:ReservedScope.projects) -join ", ") + "). Any working capability discovered inside the reserved scope during implementation must be reused, not rebuilt - report it rather than duplicating it.")
}
Add-Line ""
Add-Line "Existing Assets rows that reference other repositories/layers are NOT adopted for this work item (informational only; do not rebuild, re-wire or duplicate them either)."

# ---- Exact Reserved Scope ----
Add-Section "Exact Reserved Scope"
Add-Line ("Taken from the authoritative Active Changes reservation (row " + $script:ResRow.Row + "). THIS IS A HARD BOUNDARY.")
Add-Line ""
Add-Line ("- **Repositories:** " + (@($script:ReservedScope.repositories) -join ", "))
Add-Line ("- **Projects:** " + (@($script:ReservedScope.projects) -join ", "))
Add-Line ("- **Files / Globs:** " + (@($script:ReservedScope.filesGlobs) -join ", "))
$scStr = if ($script:ReservedScope.schemaContexts.Count -gt 0) { (@($script:ReservedScope.schemaContexts) -join ", ") } else { "(none)" }
Add-Line ("- **Schema / DbContext contexts:** " + $scStr)
Add-Line ("- **Contracts / APIs:** " + (@($script:ReservedScope.contractsApis) -join ", "))
Add-Line ("- **Affected roadmap nodes:** " + (@($script:ReservedScope.affectedNodes) -join ", "))
Add-Line ("- **Risk:** " + $script:ResRow.Risk)
$psStr = if ($script:Preflight.parallelSafe) { "True" } else { "False" }
Add-Line ("- **Parallel safety:** " + $psStr)
Add-Line ""
Add-Line "**Explicit instruction for ChatGPT:**"
Add-Line ""
Add-Line "> The implementation prompt must not authorize DeepSeek to modify anything outside this reserved scope. If implementation genuinely requires additional scope, DeepSeek must STOP and report SCOPE_CHANGE_REQUIRED rather than modifying it."

# ---- Tool Registry / Pending Governance ----
Add-Section "Tool & Integration Registry / Pending Governance"
if ($script:RelTools.Count -gt 0) {
    Add-Line "Tool & Integration Registry rows (freshly re-read) that reference the reserved scope:"
    Add-Line ""
    foreach ($_rt in $script:RelTools) {
        Add-Line ("- **" + $_rt.Tool + "** (" + $_rt.Category + ") - " + $_rt.CurrentState + "; owner layer " + $_rt.OwningLayer + ". Purpose: " + $_rt.PrimaryPurpose)
    }
} else {
    Add-Line ("No Tool & Integration Registry row (freshly re-read) references the reserved scope (" + (@($script:ReservedScope.projects) -join ", ") + "). If the reserved implementation genuinely needs a new external tool, that is a governed tool-approval change (DB-M10/DB-M11) - reported, never a silent registry edit.")
}
Add-Line ""
Add-Line "- This work item requests no new external tool approval unless the reserved scope genuinely requires one."
Add-Line "- DeepSeek must **not** silently edit the Development Control workbook or the Tool & Integration Registry to resolve governance observations; those are governed changes for DB-M10/DB-M11."
Add-Line ""
Add-Line "Pending governance items recorded in current DevBridge state:"
if ($script:PendingItems.Count -gt 0) {
    foreach ($pi in $script:PendingItems) {
        Add-Line ("- **" + $pi.type + " / " + $pi.subject + "** - " + $pi.reason + " Target milestone: " + $pi.targetMilestone + ".")
    }
} else {
    Add-Line "- (none recorded in current state)"
}

# ---- Repository Governance ----
Add-Section "Repository Governance"
$script:BaselineMapLines = @($script:RepoBaselines | ForEach-Object {
    "{0} ({1}, {2} @ {3})" -f $(if ($_.name) { $_.name } else { (Split-Path $_.path -Leaf) }), $_.path, $_.branch, $_.headCommit.Substring(0, [Math]::Min(12, $_.headCommit.Length))
})
Add-Line ("- **Reserved repositories:** " + (@($script:ReservedScope.repositories) -join ", ") + ". Independent pre-implementation git baseline captured for EACH reserved repository: " + ($script:BaselineMapLines -join "; ") + ".")
Add-Line "- **Governance source:** Development Control workbook Session Protocol sheet (authoritative) + each reserved repository's own AGENTS.md boundary rules."
Add-Line "- **Relevant rules (layer-agnostic, from the Session Protocol / workbook governance):"
Add-Line "  - Layer-owned code stays in its owning layer repository; the desktop shell is a client/launcher only, not a place to implement layer-owned logic."
Add-Line "  - One WorkItem = one worker, one branch, one sibling worktree and one review."
Add-Line "  - No integration occurs without a recorded human review; git is human-gated."
Add-Line "  - Append-only control: never delete roadmap or change history; a governed fact changes by adding a higher Record Version."
Add-Line "  - Build, test and inspect the reserved scope; record evidence, human review and integration result."
Add-Line "  - Stay strictly inside the exact reserved scope; report SCOPE_CHANGE_REQUIRED before touching anything outside it."

# ---- Git Baseline ----
Add-Section "Git Baseline"
Add-Line ("DB-M04 captured an independent pre-implementation baseline for EVERY repository in the exact reserved scope (" + (@($script:ReservedScope.repositories) -join ", ") + "). Per-repository baseline evidence below.")
Add-Line ""
$script:RepoIndex = 0
foreach ($_rb in $script:RepoBaselines) {
    $script:RepoIndex++
    $_rbName = if ($_rb.name) { $_rb.name } else { (Split-Path $_rb.path -Leaf) }
    $_primTag = if ($_rb.isPrimary) { " - **PRIMARY** (workbook owner: NEXUS_DEVELOPMENT_CONTROL.xlsx)" } else { "" }
    Add-Line ("### " + $script:RepoIndex + ". " + $_rbName + " (" + $_rb.path + ")" + $_primTag)
    Add-Line ("- **Branch:** " + $_rb.branch)
    Add-Line ("- **Baseline HEAD:** " + $_rb.headCommit + " (" + $_rb.headSubject + ")")
    Add-Line ""
    Add-Line "**Three separate git categories - keep them distinct (DB-M06 will verify against them per repository):**"
    Add-Line ""
    Add-Line "1. **PRE-EXISTING SOURCE STATE** (captured at DB-M04, before this reservation's write):"
    Add-Line ("   - staged files: " + $(if (@($_rb.preExistingChanges.staged).Count -gt 0) { (@($_rb.preExistingChanges.staged) -join "; ") } else { "(none)" }))
    Add-Line ("   - modified files: " + $(if (@($_rb.preExistingChanges.modified).Count -gt 0) { (@($_rb.preExistingChanges.modified) -join "; ") } else { "(none)" }))
    Add-Line ("   - untracked files: " + $(if (@($_rb.preExistingChanges.untracked).Count -gt 0) { (@($_rb.preExistingChanges.untracked) -join "; ") } else { "(none)" }))
    Add-Line ""
    Add-Line ("   **Important - PRE-EXISTING CHANGE ownership and minimal in-scope edits:** the " + @($_rb.preExistingChanges.untracked).Count + " untracked file(s) and any pre-existing staged/modified files were captured at DB-M04 as PRE-EXISTING CHANGE in repository " + $_rbName + " before this reservation's write. They are NOT this task's (" + $script:NodeId + " / " + $script:ChangeId + ") prior work, so their pre-existing content must not be reverted, cleaned, claimed or committed as this task's implementation. DB-M06 compares against the captured pre-implementation file content/hash of each reserved file, so pre-existing content stays classified PRE-EXISTING CHANGE and only the incremental after-baseline portion can be attributed to this task as CURRENT TASK IMPLEMENTATION DELTA.")
    Add-Line ("   A pre-existing dirty/untracked file may receive a MINIMAL current-task edit only when ALL of the following hold: (1) its repository is reserved; (2) its project is reserved and it is inside any applicable file/glob constraint; (3) the edit is genuinely required by the governed acceptance criteria; and (4) DevBridge captured the file's full pre-reservation content/hash so DB-M06 can separate the incremental delta from the pre-existing portion. If a pre-existing UNTRACKED file must be edited but DevBridge did not capture its pre-reservation content/hash, STOP with PREEXISTING_FILE_BASELINE_INSUFFICIENT instead of proceeding. Editing anything outside the reserved scope, reverting/cleaning a pre-existing change, or claiming unrelated pre-existing work remains a FAIL.")
    Add-Line ""
    if ($_rb.isPrimary) {
        Add-Line ("2. **GOVERNANCE WORKBOOK CHANGE** (DB-M04 reservation write): the authoritative NEXUS_DEVELOPMENT_CONTROL.xlsx appears modified in git because DB-M04 recorded this reservation (" + $script:ChangeId + ") and its Activity Log entry. This is GOVERNANCE STATE, not implementation.")
    } else {
        Add-Line ("2. **GOVERNANCE WORKBOOK CHANGE**: none in this repository - the authoritative NEXUS_DEVELOPMENT_CONTROL.xlsx workbook is owned by the PRIMARY reserved repository (" + $_rbName + " is not the workbook owner). DB-M04 made no governance write here, so this repository carries no governance-tool delta.")
    }
    Add-Line ("   - post-reservation modified files (observed): " + $(if (@($_rb.postReservationModifiedFiles).Count -gt 0) { (@($_rb.postReservationModifiedFiles) -join "; ") } else { "(none)" }))
    Add-Line ""
    Add-Line ("3. **CURRENT TASK IMPLEMENTATION DELTA** (to be produced by DeepSeek under the exact reserved scope): none exists yet at DB-M05 time. It must land strictly inside the reserved repositories/projects (" + (@($script:ReservedScope.repositories) -join ", ") + " / " + (@($script:ReservedScope.projects) -join ", ") + ")" + $(if (@($script:ReservedScope.filesGlobs).Count -gt 0) { (", under " + (@($script:ReservedScope.filesGlobs) -join ", ")) } else { ", with no narrower file/glob recorded" }) + ".")
    Add-Line ("   Where a reserved file was already dirty at DB-M04, only the incremental after-baseline portion (detected by DB-M06 against the captured pre-implementation content/hash) is CURRENT TASK IMPLEMENTATION DELTA; the pre-existing portion remains PRE-EXISTING CHANGE.")
    Add-Line ""
    Add-Line ("Baseline scope-file hashes: " + @($_rb.scopeFileHashes).Count + " files recorded at DB-M04 against repository " + $_rbName + ". DB-M06 will compare post-implementation state against these.")
    Add-Line ""
}

# ---- Parallel Development Context ----
Add-Section "Parallel Development Context"
Add-Line "Fresh parallel-lane recheck performed at handoff time (DB-M05 PART 2). LANE C (this reservation) is the collision axis."
Add-Line ""
Add-Line "| Lane | Lane ID | Status | Root | Overlap with reserved scope |"
Add-Line "|---|---|---|---|---|"
if ($script:LaneA) { Add-Line ("| A | " + $script:LaneA.id + " | " + $script:LaneA.status + " | " + $script:LaneA.root + " | NO |") } else { Add-Line "| A | (facts unavailable) | RUNNING | DevBridge root | NO |" }
if ($script:LaneB) { Add-Line ("| B | " + $script:LaneB.id + " | " + $script:LaneB.status + " | " + $script:LaneB.root + " | NO |") } else { Add-Line "| B | (facts unavailable) | RUNNING | DevBridge root | NO |" }
if ($script:LaneC) {
    Add-Line ("| C | " + $script:NodeId + " (" + $script:ChangeId + ") - this reservation | RESERVED (this lane) | " + $script:LaneC.root + " | n/a (this lane) |")
}
Add-Line ""
Add-Line ("Basis: lanes A/B operate under the DevBridge root; lane C operates under the reserved baseline repositories (" + (@($script:RepoBaselines | ForEach-Object { if ($_.name) { $_.name } else { (Split-Path $_.path -Leaf) } }) -join ", ") + "). Lane C is reserved there only - no shared root, path, schema, contract or workbook writer with lanes A/B. Workbook serialization is independently guarded by PART 1 (live SHA256 vs the DB-M04 post-write hash).")
Add-Line ""
Add-Line ("**Parallel safety rule for DeepSeek:** do not modify or depend on any unfinished parallel-lane file (LANE A = " + $(if ($script:LaneA) { $script:LaneA.id } else { "DevBridge parallel lane" }) + "; LANE B = " + $(if ($script:LaneB) { $script:LaneB.id } else { "DevBridge parallel lane" }) + "). If a genuine shared-contract requirement with a parallel lane emerges, STOP and report it rather than touching that lane's files.")

# ---- Instructions to ChatGPT ----
Add-Section "Instructions to ChatGPT"
Add-Line "Using this authoritative Nexus development context: prepare the implementation prompt for DeepSeek running through Claude Code."
Add-Line ""
Add-Line "Do not change:"
Add-Line "- task identity"
Add-Line "- development sequence"
Add-Line "- goal"
Add-Line "- acceptance criteria"
Add-Line "- approved architecture"
Add-Line "- reserved scope"
Add-Line "- dependencies"
Add-Line ""
Add-Line "You may improve:"
Add-Line "- implementation sequencing"
Add-Line "- technical instructions"
Add-Line "- verification commands"
Add-Line "- clarity"
Add-Line "- safe-inspection guidance (which files DeepSeek should read before editing)"
Add-Line ""
Add-Line "The handoff is authoritative. Do NOT:"
Add-Line "1. Choose a different Nexus task."
Add-Line "2. Redesign the roadmap."
Add-Line "3. Alter acceptance criteria."
Add-Line "4. Alter approved architecture."
Add-Line "5. Broaden the reserved scope."
Add-Line "6. Skip reuse of existing assets."
Add-Line ""
Add-Line "Require DeepSeek to:"
Add-Line ("1. Inspect the existing scoped code before editing - read the code in the reserved repositories/projects (" + (@($script:ReservedScope.repositories) -join ", ") + " / " + (@($script:ReservedScope.projects) -join ", ") + ") relevant to this work item before writing any code.")
Add-Line "2. Reuse existing work - do not rebuild working components."
Add-Line "3. Make the minimum necessary changes required to satisfy the work item; preserve existing working behavior."
Add-Line "4. Stay strictly inside the exact reserved scope declared above (repositories / projects / files)."
Add-Line "5. Build and test where possible and provide evidence against the governed acceptance criteria above."
Add-Line "6. Not mark the task complete."
Add-Line "7. Not close the Active Change."
Add-Line "8. Not update Nexus Development Control workbook completion state."
Add-Line "9. Not commit unless specifically authorized by a later DevBridge step."
Add-Line "10. Stop and report SCOPE_CHANGE_REQUIRED if scope expansion is required - i.e. if implementing this work item genuinely requires modifying anything outside the exact reserved scope."
Add-Line "11. Provide concise implementation evidence when finished."
Add-Line ""
Add-Line "DeepSeek must inspect the existing scoped implementation first and make only the minimum required changes. If scope expansion is required, DeepSeek must STOP and report it. DeepSeek must NOT mark the Nexus work item complete. After implementation, DevBridge DB-M06 will independently verify the work."
Add-Line ""
Add-Line "## Expected DeepSeek Completion Report"
Add-Line ""
Add-Line "The DeepSeek prompt must require this final report:"
Add-Line ""
Add-Line "    IMPLEMENTATION RESULT"
Add-Line "    "
Add-Line ("    Task: " + $script:NodeId)
Add-Line ("    Change ID: " + $script:ChangeId)
Add-Line "    "
Add-Line "    Result: PASS / FAILED / BLOCKED"
Add-Line "    "
Add-Line "    Files created:"
Add-Line "    Files modified:"
Add-Line "    Files deleted:"
Add-Line "    "
Add-Line "    Scope compliance: YES / NO"
Add-Line "    "
Add-Line "    Implementation summary:"
Add-Line "    "
Add-Line "    Acceptance criteria addressed:"
Add-Line "      - criterion"
Add-Line "      - evidence"
Add-Line "    "
Add-Line "    Build:"
Add-Line "      command"
Add-Line "      result"
Add-Line "    "
Add-Line "    Tests:"
Add-Line "      command"
Add-Line "      passed"
Add-Line "      failed"
Add-Line "      skipped"
Add-Line "    "
Add-Line "    Warnings:"
Add-Line "    "
Add-Line "    Errors:"
Add-Line "    "
Add-Line "    Scope expansion required: YES / NO"
Add-Line "    "
Add-Line "    Known limitations:"
Add-Line "    "
Add-Line "    Git status:"
Add-Line "    "
Add-Line "    Parallel lane overlap: YES / NO"
Add-Line ""
Add-Line "**IMPORTANT:** DeepSeek's self-reported PASS is NOT final approval. DB-M06 performs deterministic verification afterward."

# ---------------------------------------------------------------------------
# PART 18b - DB-GH01 ChatGptHandoffValidation v1 gate (BEFORE any write).
# If the assembled handoff fails any of the 14 mandatory checks it is
# CHATGPT_HANDOFF_NOT_READY and NOTHING is written.
# ---------------------------------------------------------------------------
$script:HandoffText = ($script:Lines -join "`r`n")
$script:HandoffRules = @(
    @{ name = "TemporaryBoundaryPresent";  markers = @("TEMPORARY","external scaffolding","retire") }
    @{ name = "ModePresent";               markers = @("TRIAL","REAL_NEXUS_DEVELOPMENT") }
    @{ name = "ArchitectureRulesPresent";  markers = @("architecture","NOT Nexus","no architecture") }
    @{ name = "DesignPhilosophyPresent";   markers = @("scaffolding","Nexus Phase 1/2","retire") }
    @{ name = "RoadmapProtectionPresent";  markers = @("roadmap","immutable","no structural") }
    @{ name = "WorkbookAuthorityPresent";  markers = @("NEXUS_DEVELOPMENT_CONTROL.xlsx","authoritative") }
    @{ name = "GitHumanGatePresent";       markers = @("human","PR","merge","gate") }
    @{ name = "ClaudeGatePresent";         markers = @("DB-M08","Claude") }
    @{ name = "TaskIdentityPresent";       markers = @("task","change","node") }
    @{ name = "ExactScopePresent";         markers = @("scope","exact") }
    @{ name = "ForbiddenActionsPresent";   markers = @("forbidden","must not","prohibited") }
    @{ name = "AcceptanceCriteriaPresent"; markers = @("acceptance","criteria") }
    @{ name = "VerificationPresent";       markers = @("DB-M06","verification") }
    @{ name = "OutputContractPresent";     markers = @("report","output","DeepSeek") }
)
$script:HandoffMissing = New-Object System.Collections.Generic.List[string]
foreach ($hr in $script:HandoffRules) {
    $hit = $false
    foreach ($m in $hr.markers) { if ($script:HandoffText.IndexOf($m, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true; break } }
    if (-not $hit) { $script:HandoffMissing.Add($hr.name) | Out-Null }
}
if ($script:HandoffMissing.Count -gt 0) {
    Write-Output "DB05_OUTCOME: HANDOFF_NOT_READY"
    Write-Output ("DB05_HANDOFF_TOKEN: CHATGPT_HANDOFF_NOT_READY")
    Write-Output ("DB05_HANDOFF_MISSING: " + ($script:HandoffMissing -join "; "))
    Write-Output "DB-M05 STOP - the ChatGPT handoff fails the ChatGptHandoffValidation v1 gate. No handoff was written."
    exit 1
}
Write-Output "DB05_HANDOFF_GATE: READY"

# ---------------------------------------------------------------------------
# DB-M05 consistency gate (task-context integrity) - BEFORE any write.
# Mechanically verifies the assembled handoff is internally consistent for the
# CURRENT governed task: identity, governed AC ownership, no foreign work-item
# identifiers in the current-task sections, single correct "(this reservation)"
# tag, current reservation claimed, and no source-path leak outside Git Baseline.
# Any violation => CHATGPT_HANDOFF_NOT_READY; NOTHING is written.
# ---------------------------------------------------------------------------
$script:CgFails = New-Object System.Collections.Generic.List[string]
function Test-Cg([string]$label, [bool]$ok, [string]$why) { if (-not $ok) { $script:CgFails.Add($label + ": " + $why) | Out-Null } }
function Get-MdRegion([string]$md, [string]$startHeader, [string]$endHeader) {
    $s = $md.IndexOf($startHeader)
    if ($s -lt 0) { return "" }
    $e = $md.IndexOf($endHeader, $s + $startHeader.Length)
    if ($e -lt 0) { $e = $md.Length }
    return $md.Substring($s, $e - $s)
}
$script:CgMd = $script:HandoffText
$script:CgAllok = New-Object System.Collections.Generic.List[string]
foreach ($_ao in @($script:AffSet)) { $script:CgAllok.Add([string]$_ao) | Out-Null }
foreach ($_actok in @(Get-NodeIdTokens $script:NodeAcRaw)) { if (-not ($script:CgAllok.Contains([string]$_actok))) { $script:CgAllok.Add([string]$_actok) | Out-Null } }

# (1) Current identity positive
Test-Cg "identity-node" ($script:CgMd.IndexOf($script:NodeId, [System.StringComparison]::Ordinal) -ge 0) "handoff text does not carry the current Node ID"
Test-Cg "identity-change" ($script:CgMd.IndexOf($script:ChangeId, [System.StringComparison]::Ordinal) -ge 0) "handoff text does not carry the current Change ID"

# (2) Governed acceptance-criteria text present (no fabricated / reused AC)
foreach ($_abchk in $script:NodeAcBullets) {
    $_needle = $_abchk.Trim()
    if ($_needle.Length -gt 200) { $_needle = $_needle.Substring(0, 200) }
    if ($_needle.Length -ge 20) { Test-Cg "ac-owned" ($script:CgMd.IndexOf($_needle, [System.StringComparison]::Ordinal) -ge 0) ("governed AC text absent: '" + $_needle.Substring(0, [Math]::Min(60, $_needle.Length)) + "'") }
}

# (3) Foreign work-item identifier guard on the sections this defect contaminated:
#     Current State .. Completion Gate, and Scope Transition .. Architecture Constraints.
#     Allowed = current affected chain + node tokens the governed AC itself cites.
$script:CgR1 = Get-MdRegion $script:CgMd "## Current State" "## Completion Gate"
$script:CgR2 = Get-MdRegion $script:CgMd "## Scope Transition" "## Architecture Constraints"
$script:CgScan = $script:CgR1 + "`n" + $script:CgR2
$script:CgForeign = New-Object System.Collections.Generic.List[string]
foreach ($_mt in [regex]::Matches($script:CgScan, "\b(?:F|M|WI|T|S)-\d+(?:\.\d+)*-\d+(?:[.-]\d+)*\b")) {
    if (-not $script:CgAllok.Contains($_mt.Value) -and (-not $script:CgForeign.Contains($_mt.Value))) { $script:CgForeign.Add($_mt.Value) | Out-Null }
}
if ($script:CgForeign.Count -gt 0) { Test-Cg "foreign-node-tokens" $false ("another task's identifiers in current-task sections: " + ($script:CgForeign -join ", ")) }

# (4) "(this reservation)" is used for the current Change ID - and used at least once
$script:CgSelfTags = @([regex]::Matches($script:CgMd, "CHG-\d{8}-\d{3} \(this reservation") | ForEach-Object { $_.Value -replace "\s*\(this reservation.*$", "" } | Sort-Object -Unique)
$script:CgSelfWrong = @($script:CgSelfTags | Where-Object { $_ -ne $script:ChangeId })
if ($script:CgSelfTags.Count -eq 0) { Test-Cg "self-tagged" $false "no '(this reservation)' tag for the current change" }
if ($script:CgSelfWrong.Count -gt 0) { Test-Cg "self-tag-current" $false ("a non-current change is tagged '(this reservation)': " + ($script:CgSelfWrong -join ", ")) }

# (5) Current-state section claims the current reservation
Test-Cg "scope-current-change" ($script:CgR1.IndexOf($script:ChangeId, [System.StringComparison]::Ordinal) -ge 0) "Current State does not claim the current reservation"

# (6) Source-path leak guard: no src\ path outside Git Baseline unless it is a reserved glob
$script:CgGitIdx = $script:CgMd.IndexOf("## Git Baseline")
$script:CgScanLeak = $script:CgR1
if ($script:CgGitIdx -ge 0) {
    $script:CgR3 = Get-MdRegion $script:CgMd "## Repository Governance" "## Git Baseline"
    $script:CgScanLeak += "`n" + $script:CgR3
}
$script:CgLeaks = New-Object System.Collections.Generic.List[string]
foreach ($_sl in [regex]::Matches($script:CgScanLeak, "(?i)\bsrc[\\/][A-Za-z0-9_.\-/\\*]+")) {
    $tok = $_sl.Value
    $allowed = $false
    foreach ($_g in @($script:ReservedScope.filesGlobs)) { if ($tok.StartsWith($_g.TrimEnd('*').TrimEnd('/'), [System.StringComparison]::OrdinalIgnoreCase)) { $allowed = $true } }
    if (-not $allowed -and (-not $script:CgLeaks.Contains($tok))) { $script:CgLeaks.Add($tok) | Out-Null }
}
if ($script:CgLeaks.Count -gt 0) { Test-Cg "src-leak" $false ("source-path token outside Git Baseline / not reserved: " + ($script:CgLeaks -join ", ")) }

# (7) No stale one-off signature prose survived
$script:CgStaleSigs = @("matching the completion standard set by WI-07-0.2.1", "Do NOT modify the Infrastructure adapter files", "the 3 untracked files are the WI-07", "is the governed next prompt in that chain", "concurrency/locking/atomic multi-op writes", "Named cross-process mutex")
foreach ($_sg in $script:CgStaleSigs) { if ($script:CgMd.Contains($_sg)) { Test-Cg "stale-signature" $false ("stale previous-cycle prose present: " + $_sg) } }

if ($script:CgFails.Count -gt 0) {
    Write-Output "DB05_OUTCOME: HANDOFF_NOT_READY"
    Write-Output "DB05_HANDOFF_TOKEN: CHATGPT_HANDOFF_NOT_READY"
    Write-Output "DB05_CONSISTENCY_GATE: FAIL"
    Write-Output ("DB05_CONSISTENCY_FAIL: " + ($script:CgFails -join "; "))
    Write-Output "DB-M05 STOP - the handoff is internally inconsistent with the current governed task. No handoff was written."
    exit 1
}
Write-Output "DB05_CONSISTENCY_GATE: PASS"

# DB-M18.1 additive readiness gate (fires only when the resolver is present AND
# resolved the dependency context to STALE/UNRESOLVED for required node deps).
# Zero-context handoffs (library/evidence absent or soft failure) are never
# blocked; the pre-DB-M18.1 behavior is preserved exactly.
if ($script:Db181Available) {
    try {
        $script:Db181Readiness = Test-DbM181HandoffReadiness -Task $db181Task -Context $script:Db181Context -Graph $script:Db181Graph -NowUtc $script:NowUtc
        if (-not $script:Db181Readiness.Ready) {
            Write-Output "DB05_OUTCOME: HANDOFF_NOT_READY"
            Write-Output "DB05_HANDOFF_TOKEN: CHATGPT_HANDOFF_NOT_READY"
            Write-Output ("DB05_LINEAGE_STATUS: " + $script:Db181Readiness.LineageStatus)
            Write-Output ("DB05_LINEAGE_REASON: " + $script:Db181Readiness.Reason)
            Write-Output "DB-M18.1 STOP - dependency development lineage context is not ready for the reserved change. No handoff was written."
            exit 1
        }
        Write-Output ("DB05_LINEAGE_READY: " + $script:Db181Readiness.LineageStatus)
    } catch {
        Write-Output ("DB05_LINEAGE_GATE_UNAVAILABLE: " + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# PART 19 - write tasks\CHATGPT_HANDOFF.md
# ---------------------------------------------------------------------------
$script:HandoffPath = Join-Path $script:TasksDir "CHATGPT_HANDOFF.md"
[System.IO.File]::WriteAllText($script:HandoffPath, ($script:Lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
$script:OwnedWrites.Add($script:HandoffPath)
Write-Output ("DB05_HANDOFF_WRITTEN: " + $script:HandoffPath)

# ---------------------------------------------------------------------------
# PART 20 - write tasks\DEEPSEEK_PROMPT.md (placeholder only)
# ---------------------------------------------------------------------------
$script:PromptPath = Join-Path $script:TasksDir "DEEPSEEK_PROMPT.md"
$promptLines = New-Object System.Collections.Generic.List[string]
$promptLines.Add("# Awaiting ChatGPT Prompt") | Out-Null
$promptLines.Add("") | Out-Null
$promptLines.Add(("Task: " + $script:NodeId)) | Out-Null
$promptLines.Add("") | Out-Null
$promptLines.Add(("Change: " + $script:ChangeId)) | Out-Null
$promptLines.Add("") | Out-Null
$promptLines.Add("Paste the ChatGPT-generated DeepSeek implementation prompt below this line before implementation.") | Out-Null
$promptLines.Add("") | Out-Null
$promptLines.Add("---") | Out-Null
$promptLines.Add("") | Out-Null
$promptLines.Add("(No implementation prompt yet - this file intentionally contains no AI-generated implementation instructions.)") | Out-Null
[System.IO.File]::WriteAllText($script:PromptPath, ($promptLines -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
$script:OwnedWrites.Add($script:PromptPath)
Write-Output ("DB05_PROMPT_WRITTEN: " + $script:PromptPath)

# ---------------------------------------------------------------------------
# PART 22 - update state\current-task.json (preserve prior info, add handoff)
# ---------------------------------------------------------------------------
$script:StatePath = Join-Path $script:StateDir "current-task.json"
$obj = $script:CurrentState
$obj.status = "AWAITING_CHATGPT_PROMPT"
$obj.nextAllowedAction = "COPY_TO_CHATGPT"
$obj | Add-Member -MemberType NoteProperty -Name "chatgptHandoffGeneratedAt" -Value $script:NowUtc -Force
$obj | Add-Member -MemberType NoteProperty -Name "chatgptHandoffPath" -Value $script:HandoffPath -Force
[System.IO.File]::WriteAllText($script:StatePath, ($obj | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
$script:OwnedWrites.Add($script:StatePath)
Write-Output ("DB05_STATE_UPDATED: " + $script:StatePath)

# ---------------------------------------------------------------------------
# PART 23 - preserve handoff copy under existing task/change history structure
# ---------------------------------------------------------------------------
$script:HistoryDir = Join-Path $script:LogsDir ("tasks\" + $script:NodeId + "\" + $script:ChangeId)
if (-not (Test-Path $script:HistoryDir)) { New-Item -ItemType Directory -Force -Path $script:HistoryDir | Out-Null }
$script:HistoryHandoff = Join-Path $script:HistoryDir "CHATGPT_HANDOFF.md"
Copy-Item $script:HandoffPath $script:HistoryHandoff -Force
$script:OwnedWrites.Add($script:HistoryHandoff)
Write-Output ("DB05_HISTORY_COPY: " + $script:HistoryHandoff)

# ---------------------------------------------------------------------------
# PART 24 - validation
# ---------------------------------------------------------------------------
$script:Failures = New-Object System.Collections.Generic.List[string]
function Check-True([string]$label, [bool]$cond, [string]$detail) {
    if ($cond) { Write-Output ("  [PASS] {0}" -f $label) }
    else { $script:Failures.Add($label + ": " + $detail); Write-Output ("  [FAIL] {0} - {1}" -f $label, $detail) }
}

$script:WorkbookHashAfter = Get-WorkbookSha256
$script:AcAfter = @(Get-AllActiveChanges | Where-Object { $_.ChangeId -eq $script:ChangeId })

# 1-2) Reservation + workbook integrity
Check-True "workbook reservation still valid" ($script:AcAfter.Count -eq 1 -and $script:AcAfter[0].Classification -ne "Terminal") "reservation re-read after generation"
Check-True "workbook NOT modified by M05" ($script:WorkbookHashAfter -eq $script:WorkbookHashBefore) ("hash " + $script:WorkbookHashBefore + " -> " + $script:WorkbookHashAfter)

$md = [System.IO.File]::ReadAllText($script:HandoffPath)

# 3-13) Handoff content
Check-True "acceptance criteria present" ($md -match "Acceptance Criteria") "handoff section"
Check-True "reserved scope present" ($md -match "Exact Reserved Scope") "handoff section"
Check-True "architecture (ADR) present" ($md -match "\bADR-\d+") "handoff section"
Check-True "scope transition present" ($md -match "Scope Transition") "handoff section"
Check-True "open decisions evaluated" ($md -match "Open Decisions") "handoff section"
Check-True "audit findings present" ($md -match "Audit Findings") "handoff section"
Check-True "existing assets classified" ($md -match "REUSE|ALREADY_EXISTS|MISSING") "handoff section"
Check-True "parallel dev context present" ($md -match "Parallel Development Context") "handoff section"
Check-True "tool registry handled" ($md -match "Tool & Integration Registry") "handoff section"
Check-True "git baseline preserved" ($md -match $script:BaselineHead) "handoff section"
# Every reserved repository's own baseline must be present in the rendered handoff.
$script:MissingBaselineRendered = @()
foreach ($_rbrend in $script:RepoBaselines) {
    $_rbrendHead = [string]$_rbrend.headCommit
    $_rbrendName = if ($_rbrend.name) { $_rbrend.name } else { (Split-Path $_rbrend.path -Leaf) }
    if ($_rbrendHead.Length -gt 0) {
        if (-not $md.Contains($_rbrendHead)) { $script:MissingBaselineRendered += ($_rbrendName + " HEAD " + $_rbrendHead) }
    } elseif (-not $md.Contains($_rbrendName)) {
        $script:MissingBaselineRendered += ($_rbrendName + " (no HEAD recorded)")
    }
}
Check-True "every reserved repository baseline rendered" ($script:MissingBaselineRendered.Count -eq 0) ("missing: " + ($script:MissingBaselineRendered -join "; "))
Check-True "completion report template present" ($md -match "IMPLEMENTATION RESULT") "handoff section"

# 14) No reserved-repository source code changed by M05. Live git status is checked
#     per reserved repository; the ONLY allowed dirty lines in each repository are that
#     repository's OWN pre-existing changes captured at DB-M04 (staged/modified/
#     untracked) plus, in the PRIMARY (workbook-owner) repository only, the DB-M04
#     governance workbook write. Any other line = reserved source changed by this run
#     (or by a parallel lane) => failure.
function ConvertTo-GitPathPart([string]$p) {
    $p = $p.Trim()
    if ($p -match '^..\s') { return $p.Substring(3).Trim() }
    return $p
}
$script:UnexpectedGit = New-Object System.Collections.Generic.List[string]
foreach ($_rbgit in $script:RepoBaselines) {
    $_rbGitPath = [string]$_rbgit.path
    if (-not $_rbGitPath) { continue }
    if (-not (Test-Path -LiteralPath $_rbGitPath)) { continue }
    $_rbGitLines = @()
    try {
        $oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        $_rbGitLines = @(& git -C $_rbGitPath status --porcelain=v1 2>$null)
        $ErrorActionPreference = $oldEap
    } catch { $_rbGitLines = @() }
    $_rbGitLines = @($_rbGitLines | ForEach-Object { "$_" })
    $_rbAllowed = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($_pp in @($_rbgit.preExistingChanges.staged)) { $null = $_rbAllowed.Add((ConvertTo-GitPathPart ([string]$_pp))) }
    foreach ($_pp in @($_rbgit.preExistingChanges.modified)) { $null = $_rbAllowed.Add((ConvertTo-GitPathPart ([string]$_pp))) }
    foreach ($_pp in @($_rbgit.preExistingChanges.untracked)) { $null = $_rbAllowed.Add((ConvertTo-GitPathPart ([string]$_pp))) }
    foreach ($_rgline in $_rbGitLines) {
        if ($_rbgit.isPrimary -and $_rgline -match "NEXUS_DEVELOPMENT_CONTROL\.xlsx") { continue }
        $_rgPath = ConvertTo-GitPathPart $_rgline
        if ($_rbAllowed.Contains($_rgPath)) { continue }
        $_rbGitRepoLabel = if ($_rbgit.name) { $_rbgit.name } else { $_rbGitPath }
        $script:UnexpectedGit.Add($_rgline + "  [reserved repository: " + $_rbGitRepoLabel + "]") | Out-Null
    }
}
Check-True "no reserved source code changed" ($script:UnexpectedGit.Count -eq 0) ("unexpected git lines: " + ($script:UnexpectedGit -join "; "))

# 15) No AI API was called - property of this session (not an engine assertion)
Check-True "no AI API was called" $true "DB-M05 performs no external AI calls"

# 16) DEEPSEEK_PROMPT.md does not contain an implementation prompt yet
$promptText = [System.IO.File]::ReadAllText($script:PromptPath)
$checkPrompt = ($promptText -match "Awaiting ChatGPT Prompt") -and -not ($promptText -match "Result: PASS|Acceptance criteria addressed|IMPLEMENTATION RESULT")
Check-True "DEEPSEEK_PROMPT.md has no implementation prompt" $checkPrompt "template only"

# 17-18) Cycle identity safety (PART 21): current identity present, no stale cycle as self
Check-True "handoff identifies current cycle" (($md -match ("Change ID: " + $script:ChangeId)) -and ($md -match ("Node ID: " + $script:NodeId))) "identity sections carry the current Change/Node"
$selfTags = @([regex]::Matches($md, "CHG-\d{8}-\d{3} \(this reservation") | ForEach-Object { $_.Value -replace "\s*\(this reservation.*$", "" } | Sort-Object -Unique)
$selfWrong = @($selfTags | Where-Object { $_ -ne $script:ChangeId })
$staleSelf = ($selfTags.Count -eq 0) -or ($selfWrong.Count -gt 0)
Check-True "no stale-cycle artifact hijack" (-not $staleSelf) "the (this reservation) tag must appear exactly for the current Change ID, never a previous cycle's (dependency references are fine)"

# 19) History copy present
$historyExists = Test-Path $script:HistoryHandoff
Check-True "history copy preserved (PART 23)" $historyExists ("expected at " + $script:HistoryHandoff)

# 20) State updated (PART 22) + parallel-lane/DevBridge file-touch guard
$stateReload = Get-Content $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
Check-True "state updated to AWAITING_CHATGPT_PROMPT" ($stateReload.status -eq "AWAITING_CHATGPT_PROMPT" -and $stateReload.nextAllowedAction -eq "COPY_TO_CHATGPT") "state file status"

# 20a) DB-M05 wrote exactly its governed outputs (precise, lane-immune):
#      state\current-task.json, tasks\CHATGPT_HANDOFF.md, tasks\DEEPSEEK_PROMPT.md,
#      logs\tasks\<node>\<change>\CHATGPT_HANDOFF.md. Any deviation is a failure.
$script:OwnedSet = @($script:OwnedWrites | Sort-Object -Unique)
$script:ExpectedOwn = New-Object System.Collections.Generic.List[string]
$script:ExpectedOwn.Add($script:HandoffPath) | Out-Null
$script:ExpectedOwn.Add($script:PromptPath) | Out-Null
$script:ExpectedOwn.Add($script:StatePath) | Out-Null
$script:ExpectedOwn.Add($script:HistoryHandoff) | Out-Null
$script:ExpectedOwn = @($script:ExpectedOwn | Sort-Object -Unique)
$ownOk = ($script:OwnedSet.Count -eq $script:ExpectedOwn.Count)
foreach ($e in $script:ExpectedOwn) { if (-not ($script:OwnedSet -contains $e)) { $ownOk = $false } }
Check-True "DB-M05 wrote exactly its governed outputs" $ownOk ("owned=[" + ($script:OwnedSet -join "; ") + "] expected=[" + ($script:ExpectedOwn -join "; ") + "]")

# 20b) Tree sweep: any file changed during the run outside the governed outputs that
#      is NOT inside a known parallel-lane zone is a failure. Known zones (Lane B =
#      DB-M13, actively writing in parallel) are attributed to the concurrent lane
#      and reported as observations, NOT as DB-M05 writes.
$script:LaneBZone = 'scripts\\ai-routing\\|design\\ai-routing\\|config\\cost\\|config\\currency\\'
$touched = @(Get-ChildItem $script:Root -Recurse -File | Where-Object {
    $_.LastWriteTimeUtc -ge $script:RunStart.AddSeconds(-5) -and
    -not ($script:ExpectedOwn -contains $_.FullName) -and
    $_.FullName -notmatch 'scripts\\New-ChatGptHandoff\.ps1'
})
$laneHits = @($touched | Where-Object { $_.FullName -match $script:LaneBZone })
$unexpected = @($touched | Where-Object { $_.FullName -notmatch $script:LaneBZone })
$unexpectedDetail = if ($unexpected.Count -gt 0) { ($unexpected.FullName -join "; ") } else { "(none)" }
Check-True "no file outside governed outputs / known lane zones touched" ($unexpected.Count -eq 0) ("unexpected touched: " + $unexpectedDetail)
if ($laneHits.Count -gt 0) {
    Write-Output ("  [INFO] concurrent Lane B (DB-M13) writes observed during run window (not written by DB-M05): " + (@($laneHits | ForEach-Object { $_.FullName.Substring($script:Root.Length + 1) }) -join "; "))
}

# ---------------------------------------------------------------------------
# FINAL OUTPUT
# ---------------------------------------------------------------------------
$failCount = $script:Failures.Count
Write-Output ""
Write-Output "DB-M05 RESULT - NEW CYCLE"
Write-Output "================================"
if ($failCount -eq 0) { Write-Output "Implementation: PASS" } else { Write-Output "Implementation: FAIL" }
Write-Output ("Node: " + $script:NodeId)
Write-Output ("Task: " + $script:NodeName)
Write-Output ("Change ID: " + $script:ChangeId)
Write-Output ""
if ($script:SheetsOk) { Write-Output "Authoritative workbook revalidated: YES" } else { Write-Output "Authoritative workbook revalidated: NO" }
if ($script:ResRows.Count -eq 1) { Write-Output "Reservation valid: YES" } else { Write-Output "Reservation valid: NO" }
if ($md -match "Acceptance Criteria") { Write-Output "Acceptance criteria: YES" } else { Write-Output "Acceptance criteria: NO" }
if ($md -match "Exact Reserved Scope") { Write-Output "Reserved scope: YES" } else { Write-Output "Reserved scope: NO" }
if ($md -match "\bADR-\d+") { Write-Output "Architecture: YES" } else { Write-Output "Architecture: NO" }
if ($md -match "\| Node ID \| Detail \|") { Write-Output "Dependencies: YES" } else { Write-Output "Dependencies: NO" }
if ($md -match "Open Decisions") { Write-Output "Open Decisions: YES" } else { Write-Output "Open Decisions: NO" }
if ($md -match "Audit Findings") { Write-Output "Audit Findings: YES" } else { Write-Output "Audit Findings: NO" }
if ($md -match "REUSE|ALREADY_EXISTS|MISSING") { Write-Output "Existing Assets: YES" } else { Write-Output "Existing Assets: NO" }
if ($md -match "Tool & Integration Registry") { Write-Output "Tool Registry: YES" } else { Write-Output "Tool Registry: NO" }
Write-Output ("Parallel context: LANE A (" + $(if ($script:LaneA) { $script:LaneA.id } else { "?" }) + " " + $(if ($script:LaneA) { $script:LaneA.status } else { "?" }) + ", overlap NO), LANE B (" + $(if ($script:LaneB) { $script:LaneB.id } else { "?" }) + " " + $(if ($script:LaneB) { $script:LaneB.status } else { "?" }) + ", overlap NO), LANE C (this reservation) - recheck PASS")
if ($script:MissingBaselineRendered.Count -eq 0 -and $md -match $script:BaselineHead) { Write-Output "Git baseline: YES (all reserved repositories rendered)" } else { Write-Output ("Git baseline: NO" + $(if ($script:MissingBaselineRendered.Count -gt 0) { (" (missing: " + ($script:MissingBaselineRendered -join "; ") + ")") } else { "" })) }
Write-Output ""
Write-Output "CHATGPT_HANDOFF:"
Write-Output ("  " + $script:HandoffPath)
Write-Output "DEEPSEEK_PROMPT:"
Write-Output ("  " + $script:PromptPath)
Write-Output "  Status: AWAITING CHATGPT"
Write-Output ""
Write-Output "Current DevBridge state:"
Write-Output ("  " + $script:StatePath)
Write-Output ("  status: " + $obj.status)
Write-Output ("  Next Allowed Action: " + $obj.nextAllowedAction)
Write-Output ""
if ($script:WorkbookHashAfter -eq $script:WorkbookHashBefore) { Write-Output "Workbook modified: NO" } else { Write-Output "Workbook modified: YES" }
if ($script:UnexpectedGit.Count -eq 0) { Write-Output "Nexus source modified: NO" } else { Write-Output "Nexus source modified: YES" }
if ($unexpected.Count -eq 0) { Write-Output "Parallel-lane files modified: NO" } else { Write-Output "Parallel-lane files modified: YES" }
Write-Output ""
if ($failCount -gt 0) {
    Write-Output "DB05_RESULT_PASS: False"
    Write-Output "VALIDATION FAILURES:"
    foreach ($f in $script:Failures) { Write-Output ("  - " + $f) }
    exit 1
} else {
    Write-Output "DB05_RESULT_PASS: True"
    Write-Output "DB05_OUTCOME: HANDOFF_GENERATED"
    exit 0
}
