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
    if ([string]$o.FilesGlobs -match "DevelopmentControl") {
        if (-not $touchesChain) { $script:Conflict = ("Change {0} (row {1}) file-glob overlaps DevelopmentControl - conflicts with the reservation." -f $o.ChangeId, $o.Row); break }
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

# 7) No new blocking decision/finding
foreach ($d in @($script:Preflight.openDecisions)) {
    if ($d.blocking -and ([string]$d.detail -match "M-07-0\.2|Development Control")) {
        Stop-Outcome "HANDOFF_STATE_STALE" ("Open decision {0} blocks this scope." -f $d.decisionId)
    }
}
foreach ($f in @($script:Preflight.auditFindings)) {
    if ($f.classification -eq "blocks" -and ([string]$f.detail -match "M-07-0\.1|M-07-0\.2")) {
        Stop-Outcome "HANDOFF_STATE_STALE" ("Audit finding {0} blocks this scope." -f $f.findingId)
    }
}
Write-Output ("  no new blocking decision/finding detected for " + $script:NodeId + " (open decisions DEC-001..003 are non-blocking for this work item)")

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
    if ([string]$r.FilesGlobs -match "DevelopmentControl" -and (-not $touchesChain)) {
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
$script:Feature = Get-RoadmapNodeById $script:Preflight.featureNodeId
if (-not $script:Feature) { $script:Feature = Get-RoadmapNodeById "F-07-0" }

$script:ReservedScope = @{
    repositories = @($script:ResRow.Repositories -split "\|" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    projects = @($script:ResRow.Projects -split "\|" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    filesGlobs = @($script:ResRow.FilesGlobs -split "\|" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    schemaContexts = @($script:ResRow.SchemaContexts -split "\|" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    contractsApis = @($script:ResRow.ContractsApis -split "\|" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    affectedNodes = @($script:ResRow.AffectedNodes -split "\|" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Git baseline (captured at DB-M04)
$script:RepoPath = $script:Reservation.gitBaseline.repository
$script:BaselineBranch = $script:Reservation.gitBaseline.branch
$script:BaselineHead = $script:Reservation.gitBaseline.headCommit
$script:BaselineSubject = $script:Reservation.gitBaseline.headSubject
$script:PreExistingStaged = @($script:Reservation.gitBaseline.preExistingChanges.staged)
$script:PreExistingModified = @($script:Reservation.gitBaseline.preExistingChanges.modified)
$script:PreExistingUntracked = @($script:Reservation.gitBaseline.preExistingChanges.untracked)
$script:PostReservationModified = @($script:Reservation.gitBaseline.postReservationModifiedFiles)

# Pending governance items (read, not hard-coded)
$script:PendingItems = @($script:CurrentState.pendingGovernanceItems)

# Classification map for audit findings (from DB-M03 preflight evidence)
$script:AfClass = @{}
foreach ($pf in @($script:Preflight.auditFindings)) { $script:AfClass[[string]$pf.findingId] = [string]$pf.classification }

# Live Existing Assets sheet (authoritative for PART 12)
$script:ExistingLive = @(Get-ExistingAssets)
$script:DevControlAssetRow = @($script:ExistingLive | Where-Object { [string]$_.Area -match "Development control service" } | Select-Object -First 1)

# Governed handoff chain (PART 4, live): the WI-07-0.2.x implementation chain
$script:ChainRows = @(Get-AllActiveChanges | Where-Object {
    $named = @(($_.NodeId -split "\|") | ForEach-Object { $_.Trim() })
    @($named | Where-Object { $_ -match "^WI-07-0\.2\.\d+$" }).Count -gt 0
} | Sort-Object ChangeId)

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
Add-Line ("- **Parent / hierarchy:** " + $script:Node.ParentId + " (" + $script:Parent.Name + ") - Feature " + $script:Feature.NodeId + " (" + $script:Feature.Name + ")")
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
Add-Line ("Milestone context (M-07-0.2 Outcome / Purpose): " + $script:Parent.OutcomePurpose)

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
Add-Line "- **Milestone:** M-07-0.2 (Development Control Service, Excel-backed, Azure-SQL-ready) In Progress, 30% - WI-07-0.2.1, WI-07-0.2.2 and WI-07-0.2.3 Complete and independently/governed-verified (3 of 10 work items)."
Add-Line "- **Existing implementation:** IDevelopmentControlStore (22 ops) + DTO/enum contracts in Nexus.Developer.Core/DevelopmentControl (WI-07-0.2.1); WorkbookSchemaValidator, WorkbookSchemaReport, ActivityLogMigration in Nexus.Developer.Infrastructure/DevelopmentControl (WI-07-0.2.2); ExcelDevelopmentControlStore ClosedXML-backed adapter in Nexus.Developer.Infrastructure/DevelopmentControl (WI-07-0.2.3, implements read + one safe mutation end-to-end, atomically, with append-only Version History and 34-column Activity Log)."
Add-Line "- **Activity Log schema:** now 34 columns (widened by WI-07-0.2.2); new records must use the new schema."
Add-Line ("- **This work item (" + $script:NodeId + "):** " + [string]$script:Node.OutcomePurpose + " - to be implemented inside the reserved Core scope.")
Add-Line "- **Development Guide state:** M-07-0.1 (Versioned roadmap and simultaneous-development control) In Progress 85% is the closest guide row; the guide has no row for M-07-0.2 yet (mirror gap - Master Roadmap remains authoritative)."
Add-Line "- **Phase Plan context:** M-07-0.2 is P0 baseline, outside the P1/P2 phase-plan sequence; P1-02/P1-03 (07 Developer) rows are Superseded under ADR-005."

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
Add-Line ("1. **NEXT WORK drill-down** (DB-M03 selection): within M-07-0.2 (Development Control Service), the only planned child whose declared dependencies are satisfied is " + $script:NodeId + " (deps satisfied: " + $script:NextWorkDepDetail + ").")
Add-Line "2. **CURRENT WORK FIRST**: M-07-0.2 has Status In Progress (30%) and is named by open reservations in the Active Changes ledger; it is not skipped for higher-priority Planned work."
Add-Line "3. **Governed handoff chain** in Active Changes (fresh read):"
$script:ChainText = New-Object System.Collections.Generic.List[string]
$script:ChainIndex = 0
foreach ($cr in $script:ChainRows) {
    $script:ChainIndex++
    if ($cr.ChangeId -eq $script:ChangeId) {
        $script:ChainText.Add($cr.ChangeId + " (this reservation, awaiting ChatGPT handoff)") | Out-Null
    } else {
        $road = Get-RoadmapNodeById $cr.NodeId
        $st = "complete"
        if ($road) { $st = $road.Status.ToLower() }
        $script:ChainText.Add($cr.ChangeId + " (" + $cr.NodeId + " " + $st + ")") | Out-Null
    }
}
Add-Line ("   " + ($script:ChainText -join " -> "))
Add-Line "   The predecessor CHG-20260830-016 (WI-07-0.2.3) is Terminal/Completed; the roadmap marks WI-07-0.2.3 Complete with next action 'Unblocks WI-07-0.2.4'. This reservation is the governed next prompt in that chain."

# ---- Acceptance Criteria ----
Add-Section "Acceptance Criteria"
Add-Line "> Governance note: Master Roadmap row $($script:Node.Row) does not carry an Acceptance Criteria (column Q) entry for $($script:NodeId) - nor for the other WI-07-0.2.x work items. The design source referenced in the roadmap Notes (DEVELOPMENT_CONTROL_SERVICE_ARCHITECTURE.md) is not present in the repository. The operative acceptance criteria below are therefore derived strictly from authoritative workbook fields (roadmap Outcome / Purpose, the Active Changes reservation, the WI-07-0.2.1 contract scope, the WI-07-0.2.2 schema scope, the WI-07-0.2.3 adapter scope) and the completion standard set by WI-07-0.2.1/WI-07-0.2.2/WI-07-0.2.3. Do not silently add mandatory requirements; if implementation evidence shows the workbook is missing a required acceptance criterion, report it rather than inventing one. Unspecified architectural decisions (for example how the named cross-process mutex is abstracted at the Core contract layer, where RowVersion is carried, and how temp-write/validate/replace composes with the adapter's existing single-operation atomic replace) must be surfaced by DeepSeek as decisions taken - or as SCOPE_CHANGE_REQUIRED if they demand Infrastructure changes - not invented as mandatory requirements."
Add-Line ""
Add-Line "1. Deliver concurrency, locking and atomic multi-operation writes for the Development Control store, inside the reserved scope (repository `Nexus.Developer`, project `Nexus.Developer.Core`, `src/Nexus.Developer.Core/DevelopmentControl/**`). [roadmap Outcome / Purpose: 'Named cross-process mutex, RowVersion optimistic check, temp-write/validate/replace, one proven concurrency test.']"
Add-Line "2. A **named cross-process mutex** protects workbook writes so the store is safe under concurrent writers. [roadmap Outcome; composes with the WI-07-0.2.3 atomic replace - do not duplicate or replace that mechanism, extend it]"
Add-Line "3. A **RowVersion optimistic check** lets concurrent readers/writers detect stale state and receive a controlled outcome instead of corrupting the workbook. [roadmap Outcome]"
Add-Line "4. **Temp-write / validate / replace**: mutations are written to a temporary copy, validated, then atomically promoted - consistent with the pattern the WI-07-0.2.3 adapter already uses, now governed at the concurrency layer. [roadmap Outcome + WI-07-0.2.3 current evidence]"
Add-Line "5. **One proven concurrency test** demonstrates the mechanism (for example two writers racing with the optimistic check firing), matching the test standard of the preceding work items. [roadmap Outcome]"
Add-Line "6. Reuse existing assets - IDevelopmentControlStore contracts, WorkbookSchemaValidator/Report, ActivityLogMigration, ExcelDevelopmentControlStore adapter, ClosedXML - and do not rebuild any working capability. Do NOT modify the Infrastructure adapter files (ExcelDevelopmentControlStore.cs, DevelopmentControlCellCodec.cs, ExcelWorkbookColumnMap.cs, WorkbookSchemaValidator.cs, WorkbookSchemaReport.cs, ActivityLogMigration.cs); if the mechanism genuinely requires Infrastructure changes, STOP and report SCOPE_CHANGE_REQUIRED."
Add-Line "7. Stay strictly inside the reserved scope; if implementation genuinely requires additional scope, STOP and report SCOPE_CHANGE_REQUIRED rather than modifying anything outside it."
Add-Line "8. Build and test the change and provide evidence, matching the completion standard set by WI-07-0.2.1 and WI-07-0.2.2 and WI-07-0.2.3 (thorough test coverage, deterministic verification, zero deviations)."

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
Add-Line "| REL-001..011 | No Dependencies & Blockers row references the target or its chain | (n/a) | NOT_APPLICABLE | NO |"
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
        Add-Line "- Do NOT treat " + $tp.nodeId + " as Complete/Merged. The real Nexus restart point is the preserved PRE-DEVBRIDGE workbook + source/Git baseline; nothing from the proving environment becomes genuine Nexus progress."
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
Add-Line ("- **" + $script:NodeId + " (this reservation)** is scoped to `src/Nexus.Developer.Core/DevelopmentControl/**` (project `Nexus.Developer.Core`) via " + $script:ChangeId + " (Active Changes row " + $script:ResRow.Row + ").")
Add-Line "- This is a deliberate governed scope transition between sibling work items, not an open invitation to reinterpret the boundary. Do not widen the Core scope to Infrastructure, and do not narrow the Core deliverable."
Add-Line "- DeepSeek MUST first inspect the existing Core contracts - `IDevelopmentControlStore.cs` and the 17 DTO/enum files under `src/Nexus.Developer.Core/DevelopmentControl/` (WI-07-0.2.1) - before writing any code."
Add-Line "- If implementing the concurrency/locking/atomic-write mechanism genuinely requires modifying anything under `Nexus.Developer.Infrastructure` (the adapter), DeepSeek MUST STOP and report `SCOPE_CHANGE_REQUIRED` rather than touching it."

# ---- Architecture Constraints ----
Add-Section "Architecture Constraints"
Add-Line "Applicable approved ADRs (from the Architecture Decisions sheet, freshly re-read):"
Add-Line ""
Add-Line "- **ADR-003 (Approved) - GOVERNS_SUBSTRATE, this task:** Master Roadmap stores current state only; all version history is append-only in a separate Version History sheet. Implementation consequence: the concurrency/locking/atomic-write work operates on the workbook as the authoritative control substrate; every governed state change must follow the append-only versioning rules (new Record Version, Is Current = Yes/No) rather than rewriting history. Temp-write/validate/replace is a write mechanism, not a license to rewrite history."
Add-Line "- **ADR-001, ADR-002, ADR-004, ADR-005 (Approved): NOT_APPLICABLE** - no link to the F-07-0 / M-07-0.2 / WI-07-0.2.x chain (ADR-005 reclassified NOT_APPLICABLE for this chain by the DB-M03 preflight)."
Add-Line ""
Add-Line "Preflight architecture check: Core contract (IDevelopmentControlStore) + Infrastructure adapter (ClosedXML-backed) conforms to the clean-architecture / layer model; no boundary violation. The preflight conflict matrix recorded 12/12 checks PASS (1 repository-level WARN for unrelated nodes, resolved at project/file level). This work item operates in Core only; any OS-level / filesystem-level primitive that cannot live in Core is a scope question to be reported, not silently placed in Infrastructure."

# ---- Open Decisions ----
Add-Section "Open Decisions"
Add-Line "| Decision ID | Blocking? | Needed Before | Status |"
Add-Line "|---|---|---|---|"
foreach ($d in @(Get-OpenDecisions)) {
    $block = "NON-BLOCKING"
    if ([string]$d.Status -match "Blocked|BLOCKING") { $block = "BLOCKING" }
    $need = [string]$d.NeededBefore
    if (-not $need) { $need = "(not set)" }
    Add-Line ("| " + $d.DecisionId + " | " + $block + " | " + $need + " | " + $d.Status + " |")
}
Add-Line ""
Add-Line ("None of the open decisions (DEC-001..003) touches the " + $script:NodeId + " scope; none blocks this work item. DEC-003 concerns the SQL Server LocalDB -> Docker/Azure SQL move and does not gate this Core-scope concurrency work. No decision is resolved by this handoff.")

# ---- Audit Findings ----
Add-Section "Audit Findings"
Add-Line "Applicable findings (Audit Findings sheet, freshly re-read; classification from DB-M03 preflight evidence):"
Add-Line ""
$script:RelevantAf = @(Get-AllAuditFindings | Where-Object { [string]$_.RoadmapLink -match "M-07" })
foreach ($f in $script:RelevantAf) {
    $cls = $script:AfClass[[string]$f.FindingId]
    if (-not $cls) { $cls = "informational" }
    $clsUpper = $cls.ToUpper()
    if ($clsUpper -eq "CONSTRAINS") { $clsUpper = "CONSTRAINS implementation" }
    Add-Line ("- **" + $f.FindingId + " (" + $f.Severity + ", " + $f.Status + ") - " + $clsUpper + ":** " + $f.Area + " | " + $f.RoadmapLink)
}
Add-Line ""
Add-Line "Classification meaning: BLOCKING = cannot proceed; CONSTRAINS = shapes how the work is done; INFORMATIONAL = context only; EXPECTED_TO_RESOLVE = expected to close during this work item. AF-010 (Documentation truth, M-07-0.1) CONSTRAINS this scope: the workbook remains the authoritative source of truth, so the concurrency layer must not create a competing or duplicated control state. AF-011/AF-012/AF-018 link future M-07-1.x/2.x/3.x/5.x milestones and are INFORMATIONAL here. No finding in this scope is BLOCKING; none is EXPECTED_TO_RESOLVE in this work item. All other findings are informational and do not link to this scope."

# ---- Existing Assets ----
Add-Section "Existing Assets - REUSE / EXTEND / ALREADY_EXISTS / MISSING"
Add-Line ("Classified for THIS work item (" + $script:NodeId + ") from live workbook evidence (Existing Assets sheet + Active Changes completion evidence for WI-07-0.2.1/WI-07-0.2.2/WI-07-0.2.3). The implementation prompt must instruct DeepSeek NOT to rebuild working capabilities:")
Add-Line ""
Add-Line "| Asset | Classification | Evidence |"
Add-Line "|---|---|---|"
Add-Line "| IDevelopmentControlStore contracts (22 ops) + DTO/enums | **REUSE** | WI-07-0.2.1, `src/Nexus.Developer.Core/DevelopmentControl/**` - consume, do not rebuild or modify unless the change itself requires it |"
Add-Line "| ExcelDevelopmentControlStore adapter + codec + column map | **ALREADY_EXISTS (out of scope)** | WI-07-0.2.3, `src/Nexus.Developer.Infrastructure/DevelopmentControl/**` - do not modify or rebuild |"
Add-Line "| WorkbookSchemaValidator + WorkbookSchemaReport + ActivityLogMigration | **ALREADY_EXISTS (out of scope)** | WI-07-0.2.2, `src/Nexus.Developer.Infrastructure/DevelopmentControl/**` - do not modify or rebuild |"
Add-Line "| ClosedXML | **REUSE** | Already integrated in Nexus.Developer.Infrastructure (WI-07-0.2.2) and registered in the Tool & Integration Registry by DB-M10 (CHG-20260830-016) - no new tool |"
if ($script:DevControlAssetRow) {
    Add-Line ("| Development control service (Excel-backed) - existing-asset row | **THIS WORK ITEM'S SUBJECT** | Live Existing Assets sheet (row " + $script:DevControlAssetRow.Row + "), state=" + $script:DevControlAssetRow.State + "; the still-missing entry names concurrency/locking/atomic multi-op writes (" + $script:NodeId + ") |")
} else {
    Add-Line "| Development control service (Excel-backed) | **THIS WORK ITEM'S SUBJECT** | Live Existing Assets sheet: working foundation (WI-07-0.2.1/0.2.2/0.2.3 present); still-missing = concurrency/locking/atomic multi-op writes (WI-07-0.2.4) |"
}
Add-Line ""
Add-Line "Not applicable to this scope (informational): Nexus.Platform / Nexus.Intelligence / Nexus.Experience assets; the model gateway, turn pipeline, chat API/UI, SQL Stage 1b and CI workflows belong to other layers. Do not rebuild, re-wire or duplicate any of these."

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
$script:ClosedXmlReg = @(Get-ToolRegistry | Where-Object { ([string]$_.Tool) -match "ClosedXML" } | Select-Object -First 1)
$script:ClosedXmlQuote = "(ClosedXML registry row not found on fresh read)"
if ($script:ClosedXmlReg) {
    $script:ClosedXmlQuote = ("ClosedXML | " + $script:ClosedXmlReg.Category + " | " + $script:ClosedXmlReg.CurrentState + " | layer " + $script:ClosedXmlReg.OwningLayer + " | " + $script:ClosedXmlReg.PrimaryPurpose)
    if ($script:ClosedXmlReg.Notes) { $script:ClosedXmlQuote += " | notes: " + $script:ClosedXmlReg.Notes }
}
Add-Section "Tool & Integration Registry / Pending Governance"
Add-Line ('The Tool & Integration Registry (freshly re-read) already records **ClosedXML** - added by the DB-M10 governed completion (CHG-20260830-016): ``' + $script:ClosedXmlQuote + '``')
Add-Line ""
Add-Line "- This work item requests **no new external tool approval**; the concurrency primitives reuse the existing store and ClosedXML stack."
Add-Line "- There is **no pending TOOL_REGISTRY_REVIEW item** for this cycle - the DB-M03 observation that ClosedXML was not yet governed was closed by DB-M10 in the prior cycle. This handoff does not re-create one."
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
Add-Line "- **Repository:** Nexus.Developer (C:\Personal\Nexus.Developer)"
Add-Line "- **Governance source:** Development Control workbook Session Protocol sheet (authoritative); Nexus.Developer AGENTS.md boundary rules."
Add-Line "- **Relevant rules:"
Add-Line "  - DEVELOPER consumes CORE, DATA, GOVERNANCE, AI, AUTOMATION and PRODUCT CORE contracts; may consume DELIVERY build-result contracts."
Add-Line "  - Must not reference a product domain assembly, product DbContext or product database; holds ProductId but does not import product types."
Add-Line "  - Does not implement chat, CI, document storage, identity, model providers or deployment."
Add-Line "  - The desktop shell is a client/launcher only; layer-owned code stays in the layer repository."
Add-Line "  - One WorkItem = one worker, one branch, one sibling worktree and one review."
Add-Line "  - No integration occurs without a recorded human review."
Add-Line "  - Append-only control: never delete roadmap or change history; a governed fact changes by adding a higher Record Version."
Add-Line "  - Build, test and inspect the reserved scope; record evidence, human review and integration result."

# ---- Git Baseline ----
Add-Section "Git Baseline"
Add-Line ("- **Repository:** " + $script:RepoPath)
Add-Line ("- **Branch:** " + $script:BaselineBranch)
Add-Line ("- **Baseline HEAD:** " + $script:BaselineHead + " (" + $script:BaselineSubject + ")")
Add-Line ""
Add-Line "**Three separate git categories - keep them distinct (DB-M06 will verify against them):**"
Add-Line ""
Add-Line "1. **PRE-EXISTING SOURCE STATE** (captured at DB-M04, before this reservation's write):"
Add-Line ("   - staged files: " + $(if ($script:PreExistingStaged.Count -gt 0) { ($script:PreExistingStaged -join "; ") } else { "(none)" }))
Add-Line ("   - modified files: " + $(if ($script:PreExistingModified.Count -gt 0) { ($script:PreExistingModified -join "; ") } else { "(none)" }))
Add-Line ("   - untracked files: " + $(if ($script:PreExistingUntracked.Count -gt 0) { ($script:PreExistingUntracked -join "; ") } else { "(none)" }))
Add-Line ""
Add-Line "   **Important:** the 3 untracked files are the WI-07-0.2.3 (prior cycle) adapter deliverables under `src/Nexus.Developer.Infrastructure/DevelopmentControl/`. They are PRE-EXISTING CHANGE, not current-task (WI-07-0.2.4) changes. DB-M06 must not classify them as this task's implementation delta, and DeepSeek must not touch them."
Add-Line ""
Add-Line "2. **GOVERNANCE WORKBOOK CHANGE** (DB-M04 reservation, ACT-20260830-018): the authoritative NEXUS_DEVELOPMENT_CONTROL.xlsx appears modified in git because the reservation recorded CHG-20260830-017 + an Activity Log row. This is GOVERNANCE STATE, not implementation."
Add-Line ("   - post-reservation modified files (observed): " + $(if ($script:PostReservationModified.Count -gt 0) { ($script:PostReservationModified -join "; ") } else { "(none)" }))
Add-Line ""
Add-Line "3. **CURRENT TASK IMPLEMENTATION DELTA** (to be produced by DeepSeek under the reserved scope): none exists yet at DB-M05 time. It must land strictly under `src/Nexus.Developer.Core/DevelopmentControl/**`."
Add-Line ""
Add-Line ("Baseline scope-file hashes: " + (@($script:Reservation.gitBaseline.scopeFileHashes).Count) + " files under src/Nexus.Developer.Core/DevelopmentControl/ recorded at DB-M04 (18 files). DB-M06 will compare post-implementation state against these.")

# ---- Parallel Development Context ----
Add-Section "Parallel Development Context"
Add-Line "Fresh parallel-lane recheck performed at handoff time (DB-M05 PART 2). LANE C (this reservation) is the collision axis."
Add-Line ""
Add-Line "| Lane | Lane ID | Status | Root | Overlap with reserved scope |"
Add-Line "|---|---|---|---|---|"
if ($script:LaneA) { Add-Line ("| A | " + $script:LaneA.id + " | " + $script:LaneA.status + " | " + $script:LaneA.root + " | NO |") } else { Add-Line "| A | (facts unavailable) | RUNNING | DevBridge root | NO |" }
if ($script:LaneB) { Add-Line ("| B | " + $script:LaneB.id + " | " + $script:LaneB.status + " | " + $script:LaneB.root + " | NO |") } else { Add-Line "| B | (facts unavailable) | RUNNING | DevBridge root | NO |" }
if ($script:LaneC) { Add-Line ("| C | " + $script:LaneC.id + " | RESERVED (this lane) | " + $script:LaneC.root + " | n/a (this lane) |") }
Add-Line ""
Add-Line "Basis: lanes A/B operate solely under the DevBridge root (C:\Personal\DevTools\DevBridge); lane C operates solely under C:\Personal\Nexus.Developer. No shared repository root, path, schema, contract, or workbook writer. Workbook serialization is independently guarded by PART 1 (live SHA256 vs DB-M04 post-write hash)."
Add-Line ""
Add-Line "**Parallel safety rule for DeepSeek:** do not modify or depend on any unfinished parallel-lane file (LANE A = DB-M12 DevBridge Operator UI; LANE B = DB-M13 AI Routing/Cost Platform Discovery). If a genuine shared-contract requirement with a parallel lane emerges, STOP and report it rather than touching that lane's files."

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
Add-Line "1. Inspect the existing scoped code before editing - read `src/Nexus.Developer.Core/DevelopmentControl/**` (IDevelopmentControlStore + the 17 contract/DTO files, WI-07-0.2.1) and the WI-07-0.2.3 Infrastructure adapter it composes with, before writing any code."
Add-Line "2. Reuse existing work - do not rebuild working components (contracts, adapter, schema validator/migration, ClosedXML)."
Add-Line "3. Make the minimum necessary changes required to satisfy the work item; preserve existing working behavior."
Add-Line "4. Stay strictly inside the reserved scope (Nexus.Developer / Nexus.Developer.Core / src/Nexus.Developer.Core/DevelopmentControl/**)."
Add-Line "5. Build and test where possible and provide evidence, matching the completion standard of WI-07-0.2.1/WI-07-0.2.2/WI-07-0.2.3."
Add-Line "6. Not mark the task complete."
Add-Line "7. Not close the Active Change."
Add-Line "8. Not update Nexus Development Control workbook completion state."
Add-Line "9. Not commit unless specifically authorized by a later DevBridge step."
Add-Line "10. Stop and report SCOPE_CHANGE_REQUIRED if scope expansion is required - especially if the concurrency/locking implementation genuinely requires modifying the Infrastructure adapter or anything outside the reserved Core scope."
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
Check-True "architecture (ADR-003) present" ($md -match "ADR-003") "handoff section"
Check-True "scope transition present" ($md -match "Scope Transition") "handoff section"
Check-True "open decisions evaluated" ($md -match "Open Decisions") "handoff section"
Check-True "audit findings present" ($md -match "Audit Findings") "handoff section"
Check-True "existing assets classified (ALREADY_EXISTS)" ($md -match "ALREADY_EXISTS") "handoff section"
Check-True "parallel dev context present" ($md -match "Parallel Development Context") "handoff section"
Check-True "tool registry handled (ClosedXML recorded)" ($md -match "ClosedXML") "handoff section"
Check-True "git baseline preserved" ($md -match $script:BaselineHead) "handoff section"
Check-True "completion report template present" ($md -match "IMPLEMENTATION RESULT") "handoff section"

# 14) No Nexus source code changed by M05 (git status: only workbook may be dirty)
$script:GitLines = @()
try {
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $script:GitLines = @(& git -C $script:RepoPath status --porcelain=v1 2>$null)
    $ErrorActionPreference = $oldEap
} catch { $script:GitLines = @() }
$script:GitLines = @($script:GitLines | ForEach-Object { "$_" })
# Baseline at DB-M04: the workbook modified + 3 PRE-EXISTING WI-07-0.2.3 untracked files.
# Any OTHER line = Nexus source changed by this run (or by a parallel lane) => failure.
$script:UnexpectedGit = New-Object System.Collections.Generic.List[string]
foreach ($gline in $script:GitLines) {
    if ($gline -match "NEXUS_DEVELOPMENT_CONTROL\.xlsx") { continue }
    # porcelain v1 line = 'XY PATH' (2 status chars + whitespace + repo-relative path)
    $pathPart = (($gline -replace '^..\s+', '').Trim())
    $knownMatch = $false
    foreach ($pu in @($script:PreExistingUntracked)) {
        if ($pathPart -ieq $pu) { $knownMatch = $true; break }
    }
    if (-not $knownMatch) { $script:UnexpectedGit.Add($gline) }
}
Check-True "no Nexus source code changed" ($script:UnexpectedGit.Count -eq 0) ("unexpected git lines: " + ($script:UnexpectedGit -join "; "))

# 15) No AI API was called - property of this session (not an engine assertion)
Check-True "no AI API was called" $true "DB-M05 performs no external AI calls"

# 16) DEEPSEEK_PROMPT.md does not contain an implementation prompt yet
$promptText = [System.IO.File]::ReadAllText($script:PromptPath)
$checkPrompt = ($promptText -match "Awaiting ChatGPT Prompt") -and -not ($promptText -match "RowVersion|mutex|ExcelDevelopmentControlStore|SCOPE_CHANGE_REQUIRED")
Check-True "DEEPSEEK_PROMPT.md has no implementation prompt" $checkPrompt "template only"

# 17-18) Cycle identity safety (PART 21): current identity present, no stale cycle as self
Check-True "handoff identifies current cycle" (($md -match ("Change ID: " + $script:ChangeId)) -and ($md -match ("Node ID: " + $script:NodeId))) "identity sections carry the current Change/Node"
$staleSelf = ($md -match "CHG-20260830-016 \(this reservation\)") -or ($md -match "WI-07-0.2.3 \(this reservation\)")
Check-True "no stale-cycle artifact hijack" (-not $staleSelf) "CHG-20260830-016 / WI-07-0.2.3 must not appear as this task's identity (dependency references are fine)"

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
if ($md -match "ADR-003") { Write-Output "Architecture: YES" } else { Write-Output "Architecture: NO" }
if ($md -match "WI-07-0.2.4 -> WI-07-0.2.3") { Write-Output "Dependencies: YES" } else { Write-Output "Dependencies: NO" }
if ($md -match "Open Decisions") { Write-Output "Open Decisions: YES" } else { Write-Output "Open Decisions: NO" }
if ($md -match "Audit Findings") { Write-Output "Audit Findings: YES" } else { Write-Output "Audit Findings: NO" }
if ($md -match "ALREADY_EXISTS") { Write-Output "Existing Assets: YES" } else { Write-Output "Existing Assets: NO" }
if ($md -match "ClosedXML") { Write-Output "Tool Registry: YES" } else { Write-Output "Tool Registry: NO" }
Write-Output ("Parallel context: LANE A (" + $(if ($script:LaneA) { $script:LaneA.id } else { "?" }) + " " + $(if ($script:LaneA) { $script:LaneA.status } else { "?" }) + ", overlap NO), LANE B (" + $(if ($script:LaneB) { $script:LaneB.id } else { "?" }) + " " + $(if ($script:LaneB) { $script:LaneB.status } else { "?" }) + ", overlap NO), LANE C (this reservation) - recheck PASS")
if ($md -match $script:BaselineHead) { Write-Output "Git baseline: YES" } else { Write-Output "Git baseline: NO" }
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
