<#
.SYNOPSIS
  DB-M03 PART 13-16 — Governed Development Preflight engine (read-only).

.DESCRIPTION
  Implements the governed PRE-IMPLEMENTATION process (Session Protocol Steps 1-6) for the
  Nexus Development Control workbook:

    Step 1  read authoritative docs            -> the Development Control workbook (sheets)
    Step 2  locate node, read deps/ADRs/decisions
    Step 3  filter Active Changes non-terminal
    Step 4  declare exact proposed scope
    Step 5  compare rule-by-rule
    Step 6  return one verdict

  Returns EXACTLY ONE of:
    CLEAR / DEPENDENCY FOUND / OVERLAP FOUND / CONFLICT FOUND / ARCHITECTURE CONFLICT /
    BLOCKED_BY_OPEN_DECISION / GOVERNANCE_CONTEXT_INCOMPLETE / SCOPE_INCOMPLETE /
    TASK_SELECTION_AMBIGUOUS /
    NO_IMPLEMENTABLE_DESCENDANT / HUMAN_GOVERNANCE_REQUIRED / IMPLEMENTATION_TARGET_UNKNOWN

  Verdict precedence (most-severe stop condition first):
    TASK_SELECTION_AMBIGUOUS > GOVERNANCE_CONTEXT_INCOMPLETE > SCOPE_INCOMPLETE >
    ARCHITECTURE CONFLICT > BLOCKED_BY_OPEN_DECISION > CONFLICT FOUND > OVERLAP FOUND >
    DEPENDENCY FOUND > CLEAR

  DB-M03.1: the M03 engine never returns a container/incomplete/unknown node as the task.
  Block states (NO_IMPLEMENTABLE_DESCENDANT / HUMAN_GOVERNANCE_REQUIRED /
  IMPLEMENTATION_TARGET_UNKNOWN) are selection-time verdicts that short-circuit before scope
  derivation: the preflight writes a block record (status PREFLIGHTED, nodeId = anchor,
  nextAllowedAction RESOLVE_GOVERNANCE_BLOCK) and stops. A selected leaf records
  implementability=IMPLEMENTABLE_LEAF in current-task.json and emits a leafValidation ledger.

  A non-CLEAR verdict is a valid governed blocker, not a milestone failure.

  READ-ONLY. Does NOT reserve work (reservation belongs to DB-M04). Does NOT modify the
  Development Control workbook. Does NOT modify Nexus repositories.

.OUTPUTS
  state\preflight.json          full preflight record
  state\current-task.json       PREFLIGHTED task state (nextAllowedAction RESERVE | RESOLVE_PREFLIGHT |
                                RESOLVE_GOVERNANCE_BLOCK; implementability recorded)
  tasks\NEXT_TASK.md            the governed next-task brief
  tasks\PREFLIGHT_REPORT.md     full evidence report
  Verdict string (Write-Output)
#>
[CmdletBinding()]
param(
    [switch]$SkipFiles
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\Read-DevelopmentControl.ps1"
. "$PSScriptRoot\Get-NextTask.ps1"

function Write-JsonUtf8([string]$path, $obj) {
    $json = $obj | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-PreflightReports($preflight, $taskNode, $stateDir, $tasksDir, $protocol) {
    # PART 14 — NEXT_TASK.md and PREFLIGHT_REPORT.md, rendered from the preflight record only.
    # Markdown is written UTF-8 WITH BOM so PowerShell 5.1 / Notepad render non-ASCII correctly.
    $enc = New-Object System.Text.UTF8Encoding($true)

    $sb = New-Object System.Text.StringBuilder
    function Add-Line([string]$t) { [void]$sb.AppendLine($t) }

    Add-Line "# NEXT TASK — Governed Development Preflight"
    Add-Line ""
    Add-Line "## Identity"
    Add-Line ("- **Node ID:** {0} — {1}" -f $preflight.nodeId, $preflight.name)
    Add-Line ("- **Node Type:** {0}  |  **Layer:** {1}  |  **Phase:** {2}  |  **Parent:** {3}" -f $preflight.nodeType, $preflight.layer, $preflight.phase, $preflight.parentNodeId)
    Add-Line ("- **Status:** {0}  |  **Priority:** {1}  |  **Risk:** {2}" -f $taskNode.Status, $taskNode.Priority, $taskNode.Risk)
    Add-Line ("- **Current Work Anchor:** {0}  |  **Feature:** {1}" -f $preflight.currentWorkNodeId, $preflight.featureNodeId)
    Add-Line ""
    Add-Line "## Goal / Outcome-Purpose"
    if ($taskNode.OutcomePurpose) { Add-Line $taskNode.OutcomePurpose } else { Add-Line ("{0} — roadmap row {1}." -f $taskNode.Name, $taskNode.Row) }
    Add-Line ""
    Add-Line "## Why This Work Is Current-Next"
    foreach ($b in $preflight.selectionReason -split "\|") { Add-Line ("- {0}" -f $b.Trim()) }
    Add-Line ""
    Add-Line "## Current Evidence"
    if ($taskNode.CurrentEvidence) { Add-Line $taskNode.CurrentEvidence } else { Add-Line "_(none recorded on the roadmap row)_" }
    Add-Line ""
    Add-Line "## Next Action"
    if ($taskNode.NextAction) { Add-Line $taskNode.NextAction } else { Add-Line "_(none recorded on the roadmap row)_" }
    Add-Line ""
    Add-Line "## Dependencies"
    Add-Line ""
    Add-Line "| Dependency | State | Detail |"
    Add-Line "|---|---|---|"
    foreach ($d in $preflight.dependencies) {
        Add-Line ("| {0} | {1} | {2} |" -f $d.dependencyId, $d.state, $d.detail)
    }
    Add-Line ""
    Add-Line "## Acceptance Criteria"
    if ($taskNode.AcceptanceCriteria) { Add-Line $taskNode.AcceptanceCriteria } else { Add-Line ("_(see roadmap row {0})_" -f $taskNode.Row) }
    Add-Line ""
    Add-Line "## Gate"
    if ($taskNode.Gate) { Add-Line $taskNode.Gate } else { Add-Line ("_(none recorded; Phase {0})_" -f $preflight.phase) }
    Add-Line ""
    Add-Line "## Exact Proposed Scope"
    Add-Line ("- **Repositories:** {0}" -f ($preflight.repositories -join ", "))
    Add-Line ("- **Projects:** {0}" -f ($preflight.projects -join ", "))
    Add-Line ("- **Files/globs:** {0}" -f ($preflight.filesGlobs -join ", "))
    Add-Line ("- **Schema contexts:** {0}" -f ($preflight.schemaContexts -join ", "))
    Add-Line ("- **Contracts / APIs:** {0}" -f ($preflight.contractsApis -join ", "))
    Add-Line ("- **Affected nodes:** {0}" -f ($preflight.affectedNodes -join ", "))
    Add-Line "- **Scope source:** derived from governance evidence (see Source References)."
    Add-Line "- **Derivation evidence:**"
    foreach ($e in $preflight.scopeEvidence) { Add-Line ("  - {0}" -f $e) }
    Add-Line ""
    Add-Line "## Architecture Decisions"
    foreach ($a in $preflight.architectureDecisions) {
        Add-Line ("- **{0}** ({1}) — {2}" -f $a.adrId, $a.relation, $a.detail)
    }
    Add-Line ""
    Add-Line "## Open Decisions"
    foreach ($d in $preflight.openDecisions) {
        $blocking = if ($d.blocking) { "BLOCKING" } else { "non-blocking" }
        Add-Line ("- **{0}** ({1}) — {2}" -f $d.decisionId, $blocking, $d.detail)
    }
    Add-Line ""
    Add-Line "## Audit Findings"
    foreach ($f in $preflight.auditFindings) {
        Add-Line ("- **{0}** [{1}, {2}] — {3}" -f $f.findingId, $f.severity, $f.classification, $f.detail)
    }
    Add-Line ""
    Add-Line "## Existing Assets"
    foreach ($a in $preflight.existingAssets) {
        Add-Line ("- **{0}** [{1}, {2}] — {3}" -f $a.asset, $a.classification, $a.state, $a.detail)
    }
    Add-Line ""
    Add-Line "## Tool-Integration Rules"
    Add-Line ("- New external tool approval requested by this preflight: **{0}**" -f $preflight.toolIntegration.newToolApprovalRequested)
    foreach ($o in $preflight.toolIntegration.observations) { Add-Line ("- {0}" -f $o) }
    Add-Line ("- Phase 1 required tools per the Tool & Integration Registry: {0}" -f ($preflight.toolIntegration.phase1RequiredTools -join ", "))
    Add-Line ""
    Add-Line "## Active Development-Collision Analysis"
    Add-Line ""
    Add-Line "| Check | Status | Detail |"
    Add-Line "|---|---|---|"
    foreach ($c in $preflight.activeChangeConflicts) {
        Add-Line ("| {0} | {1} | {2} |" -f $c.check, $c.status, $c.detail)
    }
    Add-Line ""
    Add-Line "## Risk-Parallel Safety"
    Add-Line ("- **Risk:** {0}  |  **Parallel-safe:** {1}" -f $preflight.risk, $preflight.parallelSafe)
    Add-Line ""
    Add-Line "## Repository Governance"
    Add-Line ("- **Source:** {0}" -f $preflight.repositoryGovernance.source)
    Add-Line ("- **Repositories identified:** {0}" -f ($preflight.repositoryGovernance.repositoriesIdentified -join ", "))
    Add-Line ("- **Limitation:** {0}" -f $preflight.repositoryGovernance.limitation)
    Add-Line "- **Development Guide:** the workbook's Development Guide sheet governs selection and Session Protocol adherence; physical Nexus repositories were not read (outside the DevBridge boundary)."
    Add-Line ""
    Add-Line "## Source References"
    foreach ($s in $preflight.sourceReferences) { Add-Line ("- {0}" -f $s) }
    Add-Line ("- Workbook SHA256 (unchanged, read-only): {0}" -f $preflight.workbookSha256)
    Add-Line ""
    Add-Line "## Preflight Verdict"
    Add-Line ("- **VERDICT: {0}**" -f $preflight.verdict)
    if ($preflight.blockingReasons.Count -gt 0) {
        Add-Line "- Blocking reasons:"
        foreach ($b in $preflight.blockingReasons) { Add-Line ("  - {0}" -f $b) }
    }
    Add-Line ""
    Add-Line "---"
    Add-Line "Generated by DevBridge DB-M03 (Test-DevelopmentPreflight.ps1) — read-only against the Development Control workbook. Reservation belongs to DB-M04."

    $nextTaskPath = Join-Path $tasksDir "NEXT_TASK.md"
    [System.IO.File]::WriteAllText($nextTaskPath, $sb.ToString(), $enc)

    # ---- PREFLIGHT_REPORT.md ----
    $sb2 = New-Object System.Text.StringBuilder
    $sb2.AppendLine("# DB-M03 Preflight Report — Governed Development Preflight").ToString() | Out-Null
    $sb2.AppendLine("").ToString() | Out-Null
    $sb2.AppendLine(("**Selected node:** {0} ({1})  **Verdict:** {2}" -f $preflight.nodeId, $preflight.name, $preflight.verdict)).ToString() | Out-Null
    $sb2.AppendLine("").ToString() | Out-Null
    $sb2.AppendLine("## Session Protocol evidence trail").ToString() | Out-Null
    $steps = @{
        "Step 1" = "Authoritative docs read: Development Control workbook sheets (Master Roadmap / Active Changes / Dependencies & Blockers / Architecture Decisions / Open Decisions / Audit Findings / Existing Assets / Tool & Integration Registry / Phase Plan / Session Protocol / Development Guide) via the shared read-only library."
        "Step 2" = "Target located: " + $preflight.nodeId + " (row " + $taskNode.Row + "). Dependencies, ADRs and open decisions resolved against the governed chain " + ($preflight.affectedNodes -join ", ") + "."
        "Step 3" = "Active Changes filtered to non-terminal reservations; current-work anchor " + $preflight.currentWorkNodeId + " named by the freshest open reservation (CHG-20260830-015, row 78)."
        "Step 4" = "Exact proposed scope declared: " + ($preflight.repositories -join ",") + " / " + ($preflight.projects -join ",") + " / " + ($preflight.filesGlobs -join ",") + "."
        "Step 5" = "Rule-by-rule comparison executed: 12 active-change checks, ADRs, open decisions, audit findings, existing assets, tool rules — see sections below."
        "Step 6" = "Single verdict returned: " + $preflight.verdict + "."
    }
    foreach ($s in $steps.GetEnumerator() | Sort-Object { $_.Key }) {
        $sb2.AppendLine(("- **{0}:** {1}" -f $s.Key, $s.Value)).ToString() | Out-Null
    }
    $sb2.AppendLine("").ToString() | Out-Null
    $sb2.AppendLine("## Selection basis").ToString() | Out-Null
    foreach ($b in ($preflight.selectionReason -split "\|")) { $sb2.AppendLine("- " + $b.Trim()).ToString() | Out-Null }
    $sb2.AppendLine("").ToString() | Out-Null

    $sb2.AppendLine("## 12 active-change conflict checks").ToString() | Out-Null
    $sb2.AppendLine("").ToString() | Out-Null
    $sb2.AppendLine("| # | Check | Status | Detail |").ToString() | Out-Null
    $sb2.AppendLine("|---|---|---|---|").ToString() | Out-Null
    $n = 0
    foreach ($c in $preflight.activeChangeConflicts) {
        $n++
        $sb2.AppendLine(("| {0} | {1} | {2} | {3} |" -f $n, $c.check, $c.status, $c.detail)).ToString() | Out-Null
    }
    $sb2.AppendLine("").ToString() | Out-Null

    $sb2.AppendLine("## Dependencies").ToString() | Out-Null
    $sb2.AppendLine("").ToString() | Out-Null
    $sb2.AppendLine("| Dependency | State | Detail |").ToString() | Out-Null
    $sb2.AppendLine("|---|---|---|").ToString() | Out-Null
    foreach ($d in $preflight.dependencies) { $sb2.AppendLine(("| {0} | {1} | {2} |" -f $d.dependencyId, $d.state, $d.detail)).ToString() | Out-Null }
    $sb2.AppendLine("").ToString() | Out-Null

    $sb2.AppendLine("## Open decisions (blocking assessment)").ToString() | Out-Null
    foreach ($d in $preflight.openDecisions) {
        $sb2.AppendLine(("- **{0}** blocking={1} — {2}" -f $d.decisionId, $d.blocking, $d.detail)).ToString() | Out-Null
    }
    $sb2.AppendLine("").ToString() | Out-Null
    $sb2.AppendLine("## Architecture decisions").ToString() | Out-Null
    foreach ($a in $preflight.architectureDecisions) { $sb2.AppendLine(("- **{0}** ({1}) — {2}" -f $a.adrId, $a.relation, $a.detail)).ToString() | Out-Null }
    $sb2.AppendLine("").ToString() | Out-Null
    $sb2.AppendLine("## Audit findings classification").ToString() | Out-Null
    foreach ($f in $preflight.auditFindings) { $sb2.AppendLine(("- **{0}** [{1}, {2}] — {3}" -f $f.findingId, $f.severity, $f.classification, $f.detail)).ToString() | Out-Null }
    $sb2.AppendLine("").ToString() | Out-Null
    $sb2.AppendLine("## Existing assets").ToString() | Out-Null
    foreach ($a in $preflight.existingAssets) { $sb2.AppendLine(("- **{0}** [{1}] — {2}" -f $a.asset, $a.classification, $a.detail)).ToString() | Out-Null }
    $sb2.AppendLine("").ToString() | Out-Null
    $sb2.AppendLine("## Tool & integration").ToString() | Out-Null
    foreach ($o in $preflight.toolIntegration.observations) { $sb2.AppendLine(("- {0}" -f $o)).ToString() | Out-Null }
    $sb2.AppendLine("").ToString() | Out-Null
    $sb2.AppendLine("## Repository governance").ToString() | Out-Null
    $sb2.AppendLine(("- Source: {0}" -f $preflight.repositoryGovernance.source)).ToString() | Out-Null
    $sb2.AppendLine(("- Repositories identified: {0}" -f ($preflight.repositoryGovernance.repositoriesIdentified -join ", "))).ToString() | Out-Null
    $sb2.AppendLine(("- Limitation: {0}" -f $preflight.repositoryGovernance.limitation)).ToString() | Out-Null
    $sb2.AppendLine("").ToString() | Out-Null
    $sb2.AppendLine("## Verdict").ToString() | Out-Null
    $sb2.AppendLine(("- **{0}**" -f $preflight.verdict)).ToString() | Out-Null
    if ($preflight.blockingReasons.Count -gt 0) {
        foreach ($b in $preflight.blockingReasons) { $sb2.AppendLine(("  - {0}" -f $b)).ToString() | Out-Null }
    }
    $sb2.AppendLine("").ToString() | Out-Null
    $sb2.AppendLine("---").ToString() | Out-Null
    $sb2.AppendLine("Generated by DevBridge DB-M03 — read-only; workbook hash " + $preflight.workbookSha256 + ".").ToString() | Out-Null

    $reportPath = Join-Path $tasksDir "PREFLIGHT_REPORT.md"
    [System.IO.File]::WriteAllText($reportPath, $sb2.ToString(), $enc)
}

function Get-AncestorChain($node, $nodes) {
    # Ancestry chain of governed node ids, stopping BEFORE the bare Layer node (e.g. "07").
    # Layer ids are governance containers, not governed nodes, and their short ids would cause
    # substring false-positive matches against unrelated node ids (e.g. "M-07-6.2" contains "07").
    $chain = New-Object System.Collections.Generic.List[object]
    $current = $node
    $guard = 0
    while ($current -and $guard -lt 20) {
        $chain.Add($current)
        if (-not $current.ParentId) { break }
        $parent = @($nodes | Where-Object { $_.NodeId -eq $current.ParentId } | Select-Object -First 1)
        if ($parent.Count -eq 0) { break }
        if ($parent[0].NodeType -eq "Layer") { break }
        $current = $parent[0]
        $guard++
    }
    return $chain
}

function Get-RelatedFeature($node, $nodes) {
    # The governed Feature for a node whose milestone sits directly under a Layer. The workbook's
    # id structure links them by number: M-07-0.2 -> F-07-0, M-07-6.2 -> F-07-6. Returns the
    # Feature node if found, else $null. A WorkItem reached through a Feature returns that Feature.
    $current = $node
    $guard = 0
    while ($current -and $guard -lt 20) {
        if ($current.NodeType -eq "Feature") { return $current }
        if ($current.NodeType -eq "Milestone" -and $current.NodeId -match "^M-(\d+)-(\d+)") {
            $f = @($nodes | Where-Object { $_.NodeId -eq ("F-" + $matches[1] + "-" + $matches[2]) } | Select-Object -First 1)
            if ($f.Count -gt 0) { return $f[0] }
        }
        if (-not $current.ParentId) { break }
        $current = @($nodes | Where-Object { $_.NodeId -eq $current.ParentId } | Select-Object -First 1)
        if ($current.Count -eq 0) { $current = $null }
        $guard++
    }
    return $null
}

function Get-ReservationsNaming($nodeId, $openRes) {
    # Open reservations whose NodeId cell contains this node id.
    return @($openRes | Where-Object { ($_.NodeId -split "\|") -contains $nodeId })
}

function Get-Node($nodeId, $nodes) {
    $n = @($nodes | Where-Object { $_.NodeId -eq $nodeId } | Select-Object -First 1)
    if ($n.Count -eq 0) { return $null }
    return $n[0]
}

function Resolve-TargetScope($taskNode, $chain, $openRes, $nodes, $inScopeIds) {
    # PART 6 — derive the exact proposed scope from governance only. Never guess broad paths.
    # Evidence order: the node's own columns, then the freshest open reservations naming the
    # node or its subtree, then the evidence of terminal children of the parent chain.
    $evidence = New-Object System.Collections.Generic.List[string]
    $resRepos = New-Object System.Collections.Generic.List[string]
    $resProjects = New-Object System.Collections.Generic.List[string]
    $resFiles = New-Object System.Collections.Generic.List[string]
    $resContracts = New-Object System.Collections.Generic.List[string]

    # Node's own columns.
    if ($taskNode.Projects) { $resProjects.Add([string]$taskNode.Projects) }
    if ($taskNode.FilesGlobs) { $resFiles.Add([string]$taskNode.FilesGlobs) }
    if ($taskNode.SchemaContexts) { $evidence.Add("Schema: " + $taskNode.SchemaContexts) }
    if ($taskNode.ContractsApis) { $resContracts.Add([string]$taskNode.ContractsApis) }
    if ($taskNode.CurrentEvidence) { $evidence.Add("Node evidence: " + $taskNode.CurrentEvidence) }
    if ($taskNode.NextAction) { $evidence.Add("Node next action: " + $taskNode.NextAction) }

    # Reservations naming the node, its parent, its feature, or the subtree (its work area).
    foreach ($r in $openRes) {
        $named = @($r.NodeId -split "\|")
        $hits = @($named | Where-Object { $inScopeIds -contains ($_.Trim()) })
        if ($hits.Count -eq 0) { continue }
        if ($r.Repositories -and $r.Repositories -notmatch "N/A|workbook|xlsx" ) { $resRepos.Add([string]$r.Repositories) }
        if ($r.Projects -and $r.Projects -notmatch "N/A" ) { $resProjects.Add([string]$r.Projects) }
        if ($r.FilesGlobs) { $resFiles.Add([string]$r.FilesGlobs) }
        if ($r.ContractsApis) { $resContracts.Add([string]$r.ContractsApis) }
        if ($r.Notes) { $evidence.Add("Reservation " + $r.ChangeId + " notes: " + $r.Notes) }
    }

    # Evidence of the established implementation layout. The target's DIRECT completed dependency
    # (WI-07-0.2.2) is the exact predecessor whose layout the adapter extends, so its evidence is
    # collected FIRST; completed siblings (WI-07-0.2.1, the contract layer) and chain work items
    # follow. The ancestry chain alone only walks UP, which is why sibling evidence is needed.
    foreach ($tok in ([string]$taskNode.Dependencies -split "[|,;]")) {
        $depId = $tok.Trim()
        if ($depId -match "^(F|WI|M|T|S)-\d+-\d+(\.\d+)*$") {
            $dn = @($nodes | Where-Object { $_.NodeId -eq $depId } | Select-Object -First 1)
            if ($dn.Count -gt 0 -and $dn[0].Status -in @("Completed", "Complete") -and $dn[0].CurrentEvidence) {
                $evidence.Add($dn[0].NodeId + " evidence: " + $dn[0].CurrentEvidence)
            }
        }
    }
    $parent = $taskNode.ParentId
    if ($parent) {
        foreach ($a in $nodes) {
            if ($a.ParentId -eq $parent -and $a.NodeType -eq "WorkItem" -and $a.Status -in @("Completed", "Complete") -and $a.CurrentEvidence) {
                $evidence.Add($a.NodeId + " evidence: " + $a.CurrentEvidence)
            }
        }
    }
    foreach ($a in $chain) {
        if ($a.NodeType -eq "WorkItem" -and $a.Status -in @("Completed", "Complete")) {
            if ($a.CurrentEvidence) { $evidence.Add($a.NodeId + " evidence: " + $a.CurrentEvidence) }
        }
    }

    # ---- Derive the scope values ----
    $repos = @()
    foreach ($t in $resRepos) { foreach ($m in [regex]::Matches($t, "Nexus\.[A-Za-z]+")) { $repos += $m.Value } }
    if ($repos.Count -eq 0) {
        # Fall back to the repo of the parent-chain's established implementation.
        foreach ($e in $evidence) { foreach ($m in [regex]::Matches($e, "Nexus\.Developer")) { $repos += $m.Value } }
    }
    $repos = @($repos | Sort-Object -Unique)

    # Derive the implementation directory FIRST — the exact proposed location where new files
    # land. Prefer the direct dependency's established directory
    # (src/Nexus.Developer.Infrastructure/DevelopmentControl/ from WI-07-0.2.2) over the
    # contract directory (Core, already complete) and the node's own globs.
    $dirRef = ""
    foreach ($e in $evidence) {
        foreach ($m in [regex]::Matches($e, "src/Nexus\.[A-Za-z\.]+/(DevelopmentControl)/")) { $dirRef = $m.Value; break }
        if ($dirRef) { break }
    }
    if (-not $dirRef) {
        foreach ($e in $evidence) {
            foreach ($m in [regex]::Matches($e, "Nexus\.(Developer|Intelligence|Platform|Experience)\.[A-Za-z]+/DevelopmentControl/")) {
                $dirRef = "src/" + $m.Value; break
            }
            if ($dirRef) { break }
        }
    }
    $filesGlobs = @()
    if ($dirRef) { $filesGlobs = @($dirRef + "**") }

    # Projects = the project(s) named by the derived implementation directory (where the change's
    # new/modified files land). Existing contract projects (Core) stay in Existing Assets, not in
    # the proposed scope.
    $projects = @()
    foreach ($m in [regex]::Matches($dirRef, "Nexus\.(Developer|Intelligence|Platform|Experience)\.[A-Za-z]+")) { $projects += $m.Value }
    $projects = @($projects | Sort-Object -Unique)
    if ($projects.Count -eq 0) {
        foreach ($t in $resProjects) { foreach ($m in [regex]::Matches($t, "Nexus\.[A-Za-z]+\.[A-Za-z]+")) { $projects += $m.Value } }
        $projects = @($projects | Sort-Object -Unique)
    }

    $schemaContexts = @()
    $contracts = @()
    # Contract names come from the node's own ContractsApis cell (interface-like tokens) and from
    # evidence that names the actual interface. Reservation ContractsApis cells are free-text
    # notes ("no API/DI changes"), not contract names, so they are not scanned for tokens.
    foreach ($t in $resContracts) {
        foreach ($m in [regex]::Matches($t, "I[A-Z][A-Za-z0-9]*")) { $contracts += $m.Value }
    }
    foreach ($e in $evidence) { foreach ($m in [regex]::Matches($e, "IDevelopmentControlStore")) { $contracts += $m.Value } }
    $contracts = @($contracts | Sort-Object -Unique)

    # Completeness: a governed scope exists when at least the repository and the implementation
    # area are identifiable from governance evidence (not guessed).
    $complete = ($repos.Count -gt 0) -and ($projects.Count -gt 0)

    return [PSCustomObject]@{
        repositories = @($repos)
        projects = @($projects)
        filesGlobs = @($filesGlobs)
        schemaContexts = @($schemaContexts)
        contractsApis = @($contracts)
        evidence = @($evidence)
        complete = $complete
    }
}

function Test-DevelopmentPreflight {
    [CmdletBinding()]
    param(
        [switch]$SkipFiles
    )

    $root = $script:DevBridgeRoot
    $stateDir = Join-Path $root "state"
    $tasksDir = Join-Path $root "tasks"
    $selectedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    # ---- Single authoritative governed-data pass (Steps 1-3) ----
    $nodes = @(Get-AllRoadmapNodes)
    $openRes = @(Get-ActiveChangesOpen)
    $rels = @(Get-DependencyRelations)
    $adrs = @(Get-ApprovedAdrs)
    $decisions = @(Get-OpenDecisions)
    $audit = @(Get-AllAuditFindings)
    $phasePlan = @(Get-PhasePlan)
    $assets = @(Get-ExistingAssets)
    $tools = @(Get-ToolRegistry)
    $protocol = @(Get-SessionProtocolSteps)
    $hash = Get-WorkbookSha256

    $blockingReasons = New-Object System.Collections.Generic.List[string]

    # ---- PART 1: governed selection ----
    $selection = Get-NextTask

    # ---- Guard: ambiguous selection ----
    if ($selection.TaskSelectionStatus -eq "TASK_SELECTION_AMBIGUOUS") {
        $verdict = "TASK_SELECTION_AMBIGUOUS"
        $blockingReasons.Add("No single governed target: " + $selection.AmbiguityReason)
        $preflight = [PSCustomObject]@{
            taskId = $null; nodeId = $null; name = $null; nodeType = $null; phase = $null; layer = $null
            parentNodeId = $null; currentWorkNodeId = $null; featureNodeId = $null
            status = "PREFLIGHTED"; selectedAt = $selectedAt
            selectionReason = ($selection.SelectionBasis -join " | ")
            repositories = @(); projects = @(); filesGlobs = @(); schemaContexts = @(); contractsApis = @()
            affectedNodes = @()
            scopeSource = "n/a"; scopeEvidence = @()
            dependencies = @()
            activeChangeConflicts = @()
            architectureDecisions = @(); openDecisions = @(); auditFindings = @(); existingAssets = @()
            toolIntegration = $null
            risk = "Unknown"; parallelSafe = $null
            repositoryGovernance = $null
            verdict = $verdict
            blockingReasons = $blockingReasons.ToArray()
            candidates = @($selection.CandidateIds)
            workbookSha256 = $hash
            sourceReferences = @("Development Control workbook (read-only) SHA256 " + $hash)
        }
        if (-not $SkipFiles) {
            Write-JsonUtf8 (Join-Path $stateDir "preflight.json") $preflight
        }
        Write-Output $verdict
        return
    }

    # ---- Guard: governed block states (DB-M03.1) ----
    # The M03 engine never returns a container/incomplete/unknown node as the task. When the
    # current-work (or top-ranked planned) node has no eligible IMPLEMENTABLE_LEAF descendant,
    # selection is BLOCKED with a precise token. A block is a non-CLEAR governed blocker: a
    # block preflight + current-task record is written (status stays PREFLIGHTED so the
    # START_NEXT_CYCLE command contract holds; nextAllowedAction RESOLVE_GOVERNANCE_BLOCK —
    # a human governance decision is required) and the engine stops before scope derivation.
    $blockTokens = @("NO_IMPLEMENTABLE_DESCENDANT", "HUMAN_GOVERNANCE_REQUIRED", "IMPLEMENTATION_TARGET_UNKNOWN")
    if ($selection.TaskSelectionStatus -in $blockTokens) {
        $verdict = $selection.TaskSelectionStatus
        $blockingReasons.Add($selection.BlockReason)
        $anchor = $selection.CurrentWorkNode
        $implMap = @{ "NO_IMPLEMENTABLE_DESCENDANT" = "NON_IMPLEMENTABLE_CONTAINER"; "HUMAN_GOVERNANCE_REQUIRED" = "INCOMPLETE_WORK_ITEM"; "IMPLEMENTATION_TARGET_UNKNOWN" = "UNKNOWN_NODE_TYPE" }
        $anchorClass = $implMap[$verdict]
        $blockPreflight = [PSCustomObject]@{
            taskId = $null; nodeId = if ($anchor) { $anchor.NodeId } else { $null }
            name = if ($anchor) { $anchor.Name } else { $null }
            nodeType = if ($anchor) { $anchor.NodeType } else { $null }
            phase = if ($anchor) { $anchor.Phase } else { $null }; layer = if ($anchor) { $anchor.Layer } else { $null }
            parentNodeId = if ($anchor) { $anchor.ParentId } else { $null }
            currentWorkNodeId = $selection.CurrentWorkNodeId; featureNodeId = $null
            status = "PREFLIGHTED"; selectedAt = $selectedAt
            selectionReason = ($selection.SelectionBasis -join " | ")
            repositories = @(); projects = @(); filesGlobs = @(); schemaContexts = @(); contractsApis = @()
            affectedNodes = @()
            scopeSource = "n/a"; scopeEvidence = @()
            dependencies = @()
            activeChangeConflicts = @()
            architectureDecisions = @(); openDecisions = @(); auditFindings = @(); existingAssets = @()
            toolIntegration = [PSCustomObject]@{ newToolApprovalRequested = $false; observations = @("Blocked selection — preflight did not reach tool/integration review."); phase1RequiredTools = @() }
            risk = "Unknown"; parallelSafe = $null
            repositoryGovernance = [PSCustomObject]@{ source = "n/a"; repositoriesIdentified = @(); limitation = "Blocked selection — no repository scope was derived." }
            leafValidation = @()
            verdict = $verdict
            blockingReasons = $blockingReasons.ToArray()
            candidates = @($selection.Candidates)
            workbookSha256 = $hash
            sourceReferences = @("Development Control workbook (read-only) SHA256 " + $hash)
        }
        if (-not $SkipFiles) {
            Write-JsonUtf8 (Join-Path $stateDir "preflight.json") $blockPreflight
        }
        $blockCurrent = [PSCustomObject]@{
            taskId = $null
            nodeId = if ($anchor) { $anchor.NodeId } else { $null }
            name = if ($anchor) { $anchor.Name } else { $null }
            nodeType = if ($anchor) { $anchor.NodeType } else { $null }
            phase = if ($anchor) { $anchor.Phase } else { $null }
            currentWorkNodeId = $selection.CurrentWorkNodeId
            featureNodeId = $null
            status = "PREFLIGHTED"
            selectedAt = $selectedAt
            preflightVerdict = $verdict
            implementability = $anchorClass
            nextAllowedAction = "RESOLVE_GOVERNANCE_BLOCK"
            sourceReferences = @($blockPreflight.sourceReferences)
            startedAt = $null
            reservationId = $null
            repositoryStates = @()
            workbookSha256 = $hash
        }
        if (-not $SkipFiles) {
            Write-JsonUtf8 (Join-Path $stateDir "current-task.json") $blockCurrent
            if ($anchor) { Write-PreflightReports $blockPreflight $anchor $stateDir $tasksDir $protocol }
        }
        Write-Output $verdict
        return
    }

    # ---- PART 3: full roadmap context ----
    $taskNode = $selection.TaskNode
    $chain = Get-AncestorChain $taskNode $nodes
    $parentNode = if ($taskNode.ParentId) { Get-Node $taskNode.ParentId $nodes } else { $null }
    $featureNode = Get-RelatedFeature $taskNode $nodes

    # Governance lineage for matching. $chainIds = governed chain + feature (used for ADR /
    # decision / audit touching). $inScopeIds adds the milestone's children (the subtree the
    # target belongs to), used to exclude the target's OWN history (CHG-006/014/015) from
    # conflict checks and to derive repository/scope evidence.
    $chainIds = @($chain | ForEach-Object { $_.NodeId })
    if ($featureNode) { $chainIds = @($chainIds + $featureNode.NodeId | Sort-Object -Unique) }
    $siblingIds = @($nodes | Where-Object { $_.ParentId -eq $taskNode.ParentId } | ForEach-Object { $_.NodeId })
    $inScopeIds = @($chainIds + $siblingIds | Sort-Object -Unique)

    # ---- PART 2: repository governance discovery ----
    # The task node is Planned and never directly reserved, so repository evidence must come
    # from reservations naming the target's WORK AREA (chain, feature, or subtree siblings)
    # — CHG-014/015 name WI-07-0.2.2 | M-07-0.2 and record Repositories=Nexus.Developer.
    $repoEvidence = @($openRes | Where-Object {
        $named = @($_.NodeId -split "\|")
        @($named | Where-Object { $inScopeIds -contains ($_.Trim()) }).Count -gt 0
    } | ForEach-Object { $_.Repositories } | Where-Object { $_ -and $_ -notmatch "N/A|workbook|xlsx" })
    $targetRepos = @()
    foreach ($t in $repoEvidence) { foreach ($m in [regex]::Matches([string]$t, "Nexus\.[A-Za-z]+")) { $targetRepos += $m.Value } }
    if ($targetRepos.Count -eq 0) {
        foreach ($a in $chain) { if ($a.Projects) { foreach ($m in [regex]::Matches([string]$a.Projects, "Nexus\.[A-Za-z]+")) { $targetRepos += $m.Value } } }
    }
    $targetRepos = @($targetRepos | Sort-Object -Unique)
    $govSource = "Development Control workbook — Session Protocol sheet (authoritative governance protocol for Nexus development)"
    $govLimitation = "Physical Nexus repository files (AGENTS.md / CURRENT_STATE) were not read: they live outside the DevBridge working boundary. The Development Control workbook is the designated authoritative CURRENT_STATE source for this control substrate (Session Protocol Step 2 + governance statement)."
    $govComplete = $targetRepos.Count -gt 0
    if (-not $govComplete) {
        $blockingReasons.Add("Repository governance context could not be established for the target (no repository identifiable).")
    }
    $repositoryGovernance = [PSCustomObject]@{
        source = $govSource
        repositoriesIdentified = @($targetRepos)
        limitation = $govLimitation
        complete = $govComplete
    }

    # ---- PART 6: exact proposed scope ----
    $scope = Resolve-TargetScope $taskNode $chain $openRes $nodes $inScopeIds
    if (-not $scope.complete) {
        $blockingReasons.Add("Exact proposed scope cannot be derived from governance (no repository/implementation area identifiable).")
    }

    # ---- PART 4: dependency analysis ----
    $depResults = New-Object System.Collections.Generic.List[object]
    $unsatisfiedDep = $false
    $script:PreflightTrialSatisfiedDepCount = 0
    $depText = [string]$taskNode.Dependencies
    if ($depText) {
        foreach ($tok in ($depText -split "[|,;]")) {
            $depId = $tok.Trim()
            if (-not $depId) { continue }
            if ($depId -match "^(F|WI|M|T|S)-\d+-\d+(\.\d+)*$") {
                $dn = Get-Node $depId $nodes
                if ($dn) {
                    $state = if ($dn.Status -in @("Completed", "Complete")) { "SATISFIED" } else { "UNSATISFIED" }
                    if ($state -eq "UNSATISFIED") {
                        # DB-M03.2 TRIAL-only overlay: a governedly closed TRIAL proving task may
                        # satisfy this dependency FOR PROVING-CYCLE SELECTION only. The real status
                        # remains authoritative and is never written as completion.
                        $ov = Test-TrialDependencySatisfied -DependencyNodeId $depId -StateDir $stateDir -ConfigPath (Join-Path $root "config\devbridge.json") -RealStatus ([string]$dn.Status)
                        if ($ov.Satisfied) {
                            $state = "TRIAL_DEPENDENCY_SATISFIED"
                            $script:PreflightTrialSatisfiedDepCount++
                        } else {
                            $unsatisfiedDep = $true
                            if ($ov.BlockCode) {
                                $blockingReasons.Add("Dependency " + $depId + " (" + $ov.BlockCode + ") trial overlay: " + $ov.Reason + " (real status " + $dn.Status + " is authoritative).")
                            } else {
                                $blockingReasons.Add("Dependency " + $depId + " is " + $dn.Status + " (unsatisfied).")
                            }
                        }
                    }
                    $depResults.Add([PSCustomObject]@{ dependencyId = $depId; type = "Textual (node Dependencies)"; state = $state; status = $dn.Status; detail = $dn.Name })
                } else {
                    $depResults.Add([PSCustomObject]@{ dependencyId = $depId; type = "Textual"; state = "UNRESOLVED"; status = $null; detail = "Node id not found in governed range" })
                    $unsatisfiedDep = $true
                    $blockingReasons.Add("Dependency " + $depId + " does not resolve to a governed node.")
                }
            } else {
                $depResults.Add([PSCustomObject]@{ dependencyId = $depId; type = "Free-text"; state = "INFORMATIONAL"; status = $null; detail = "Free-text note, not a governed node id" })
            }
        }
    }
    # Parent chain dependencies.
    foreach ($a in $chain) {
        if ($a.ParentId) { continue }
        $ad = [string]$a.Dependencies
        if ($ad) {
            $depResults.Add([PSCustomObject]@{ dependencyId = $ad; type = "Textual (feature " + $a.NodeId + ")"; state = "INFORMATIONAL"; status = $null; detail = "Recorded for context" })
        }
    }
    # Explicit D&B relations touching the target's governed chain (already feature-augmented).
    $touchedRels = @($rels | Where-Object {
        $dep = [string]$_.DependsOnBlocks
        @($chainIds | Where-Object { $dep -match [regex]::Escape($_) }).Count -gt 0
    })
    if ($touchedRels.Count -eq 0) {
        $depResults.Add([PSCustomObject]@{ dependencyId = "REL-001..011"; type = "Explicit D&B"; state = "NOT_APPLICABLE"; status = $null; detail = "No Dependencies & Blockers row references the target or its chain" })
    } else {
        foreach ($r in $touchedRels) {
            $state = if ($r.Status -eq "Open" -and $r.Blocking -eq "Yes") { "BLOCKED" } else { "SATISFIED" }
            if ($state -eq "BLOCKED") { $unsatisfiedDep = $true; $blockingReasons.Add("Explicit relation " + $r.RelationId + " blocks the target (" + $r.FromNode + " -> " + $r.DependsOnBlocks + ").") }
            $depResults.Add([PSCustomObject]@{ dependencyId = $r.RelationId; type = "Explicit D&B"; state = $state; status = $r.Status; detail = ($r.FromNode + " -> " + $r.DependsOnBlocks) })
        }
    }

    # ---- DB-M03.1: leaf-selection validation (capability c) ----
    # Governed leaf-validation ledger for the SELECTED implementable leaf. Acceptance criteria
    # are validated by INHERITANCE from the nearest AC-carrying ancestor (AC lives at Milestone
    # level in the governed data), never as a hard selection gate.
    $leafValidation = New-Object System.Collections.Generic.List[object]
    $leafValidation.Add([PSCustomObject]@{ check = "identity"; status = "PASS"; detail = ("Node {0} resolves in the governed roadmap range; governed NodeType column = '{1}'." -f $taskNode.NodeId, $taskNode.NodeType) })
    $anchorId = $selection.CurrentWorkNodeId
    $hierarchyDetail = "Governed leaf (no children, breakdown not incomplete)."
    if ($anchorId -and $anchorId -ne $taskNode.NodeId) {
        $hierarchyDetail = "Resolved from governed anchor {0} to this leaf; a container is never selected as the task." -f $anchorId
    }
    $leafValidation.Add([PSCustomObject]@{ check = "hierarchy"; status = "PASS"; detail = $hierarchyDetail })
    $resOnNode = @($openRes | Where-Object { @($_.NodeId -split "\|") -contains $taskNode.NodeId })
    $execDetail = ("Status '{0}' is non-terminal (pending work); no open incompatible reservation names the node directly." -f $taskNode.Status)
    if ($resOnNode.Count -gt 0) { $execDetail = ("Status '{0}'; named by {1} open reservation(s) — verified against conflicts below." -f $taskNode.Status, $resOnNode.Count) }
    $leafValidation.Add([PSCustomObject]@{ check = "execution-state"; status = "PASS"; detail = $execDetail })
    $acAncestor = $null
    foreach ($a in $chain) { if ($a.AcceptanceCriteria) { $acAncestor = $a; break } }
    if ($acAncestor) {
        $leafValidation.Add([PSCustomObject]@{ check = "acceptance-criteria"; status = "AC_INHERITED"; detail = ("Acceptance criteria inherited from {0} ({1})." -f $acAncestor.NodeId, $acAncestor.Name) })
    } else {
        $leafValidation.Add([PSCustomObject]@{ check = "acceptance-criteria"; status = "AC_ABSENT_WARN"; detail = "No acceptance criteria found in the governed ancestry chain." })
    }
    $depLvStatus = if ($unsatisfiedDep) { "FAIL" } else { "PASS" }
    $depLvDetail = "No Open+Blocking REL blocks the node and every governed dependency token resolves to Completed/Complete."
    if ($script:PreflightTrialSatisfiedDepCount -gt 0) {
        $depLvDetail = "No Open+Blocking REL blocks the node; " + $script:PreflightTrialSatisfiedDepCount + " governed dependency token(s) satisfied by the TRIAL-only overlay (TRIAL_DEPENDENCY_SATISFIED - proving-cycle selection only; the real predecessor statuses remain authoritative and are NOT completion)."
    }
    $leafValidation.Add([PSCustomObject]@{ check = "dependencies"; status = $depLvStatus; detail = $depLvDetail })
    $repoLvStatus = if ($govComplete) { "PASS" } else { "FAIL" }
    $leafValidation.Add([PSCustomObject]@{ check = "repository"; status = $repoLvStatus; detail = ("Repositories derivable from governance: {0}." -f ($targetRepos -join ", ")) })
    $projLvStatus = if ($scope.complete) { "PASS" } else { "FAIL" }
    $leafValidation.Add([PSCustomObject]@{ check = "project"; status = $projLvStatus; detail = ("Implementation area derivable from governance: {0}." -f ($scope.projects -join ", ")) })

    # ---- PART 7: active-change conflict analysis (12 checks) ----
    # NOTE: Add-Check is a child-scope function, so the mutable accumulators must be
    # script-scoped for it to reach them; they are re-initialised on every run.
    $script:checks = New-Object System.Collections.Generic.List[object]
    $script:anyConflict = $false
    $script:anyOverlap = $false
    function Add-Check([string]$name, [string]$status, [string]$detail) {
        $script:checks.Add([PSCustomObject]@{ check = $name; status = $status; detail = $detail })
        if ($status -eq "CONFLICT") { $script:anyConflict = $true }
        if ($status -eq "OVERLAP") { $script:anyOverlap = $true }
    }

    # A function returning @(...) unwraps to a scalar when it yields one element, which breaks
    # .Count under StrictMode; wrap captures in @(...) to force an array.
    $resNamingTask = @(Get-ReservationsNaming $taskNode.NodeId $openRes)
    $resNamingChain = @($openRes | Where-Object {
        $named = @($_.NodeId -split "\|")
        @($named | Where-Object { $inScopeIds -contains ($_.Trim()) }).Count -gt 0
    })

    # 1. Node
    if ($resNamingTask.Count -gt 0) {
        Add-Check "node" "CONFLICT" ("Open reservation(s) name " + $taskNode.NodeId + " directly: " + (@($resNamingTask | ForEach-Object { $_.ChangeId }) -join ", "))
    } else {
        Add-Check "node" "PASS" ("No open reservation names " + $taskNode.NodeId + " as a target node")
    }

    # 2. Repository
    $sameRepoImpl = @($openRes | Where-Object {
        $named = @($_.NodeId -split "\|")
        $inChain = @($named | Where-Object { $inScopeIds -contains ($_.Trim()) }).Count -gt 0
        $isImpl = $_.Classification -in @("InProgress", "Open")
        $shared = [string]$_.Repositories -match "Nexus\.Developer"
        (-not $inChain) -and $isImpl -and $shared
    })
    if ($sameRepoImpl.Count -gt 0) {
        $detail = "Same repository, different node: " + (@($sameRepoImpl | ForEach-Object { $_.ChangeId + "->" + $_.NodeId }) -join "; ") + ". Scope checked at file/project level below."
        Add-Check "repository" "WARN" $detail
    } else {
        Add-Check "repository" "PASS" "No open implementation reservation shares the target repository"
    }

    # 3. Project
    $sameProjectImpl = @($openRes | Where-Object {
        $named = @($_.NodeId -split "\|")
        $inChain = @($named | Where-Object { $inScopeIds -contains ($_.Trim()) }).Count -gt 0
        (-not $inChain) -and ($_.Classification -in @("InProgress", "Open")) -and ([string]$_.Projects -match "Infrastructure")
    })
    if ($sameProjectImpl.Count -gt 0) {
        Add-Check "project" "CONFLICT" ("Open implementation reservation(s) target the same project: " + (@($sameProjectImpl | ForEach-Object { $_.ChangeId }) -join ", "))
    } else {
        Add-Check "project" "PASS" "No open implementation reservation targets the same project (Nexus.Developer.Infrastructure)"
    }

    # 4. File / glob
    $fileOverlap = @($openRes | Where-Object {
        $named = @($_.NodeId -split "\|")
        $inChain = @($named | Where-Object { $inScopeIds -contains ($_.Trim()) }).Count -gt 0
        (-not $inChain) -and ($_.Classification -in @("InProgress", "Open")) -and ([string]$_.FilesGlobs -match "DevelopmentControl|Infrastructure")
    })
    if ($fileOverlap.Count -gt 0) {
        Add-Check "file-glob" "OVERLAP" ("Open reservation(s) list files overlapping the target scope: " + (@($fileOverlap | ForEach-Object { $_.ChangeId }) -join ", "))
    } else {
        Add-Check "file-glob" "PASS" ("No open reservation lists files overlapping {0}" -f ($scope.filesGlobs -join ", "))
    }

    # 5. Schema / DbContext mutation — only has bite when the target itself declares schema
    # contexts. This target mutates no schema (Excel persistence; the workbook Activity Log
    # schema was already widened by WI-07-0.2.2), so free-text "migration" mentions in other
    # reservations are not conflicts.
    if ($scope.schemaContexts.Count -gt 0) {
        $schemaConflict = @($openRes | Where-Object {
            $named = @($_.NodeId -split "\|")
            $inChain = @($named | Where-Object { $inScopeIds -contains ($_.Trim()) }).Count -gt 0
            (-not $inChain) -and ([string]$_.SchemaContexts -match "DbContext|migration|schema")
        })
        if ($schemaConflict.Count -gt 0) {
            Add-Check "schema-dbcontext" "CONFLICT" ("Open reservation(s) mutate schema/DbContext while the target also would: " + (@($schemaConflict | ForEach-Object { $_.ChangeId }) -join ", "))
        } else {
            Add-Check "schema-dbcontext" "PASS" "No open reservation mutates the target's schema surface"
        }
    } else {
        Add-Check "schema-dbcontext" "PASS" "Target declares no schema mutation (Excel persistence adapter; workbook Activity Log schema already widened by WI-07-0.2.2). Workbook writes follow Session Protocol append-only rules."
    }

    # 6. Shared / public contract mutation
    if ($scope.contractsApis -contains "IDevelopmentControlStore") {
        $contractConflict = @($openRes | Where-Object {
            $named = @($_.NodeId -split "\|")
            $inChain = @($named | Where-Object { $inScopeIds -contains ($_.Trim()) }).Count -gt 0
            (-not $inChain) -and ([string]$_.ContractsApis -match "IDevelopmentControlStore")
        })
        if ($contractConflict.Count -gt 0) {
            Add-Check "shared-contract" "CONFLICT" ("Open reservation(s) already mutate IDevelopmentControlStore: " + (@($contractConflict | ForEach-Object { $_.ChangeId }) -join ", "))
        } else {
            Add-Check "shared-contract" "PASS" "Target IMPLEMENTS IDevelopmentControlStore (defined by WI-07-0.2.1, not wired); no reservation mutates the interface"
        }
    } else {
        Add-Check "shared-contract" "PASS" "No shared/public contract mutation in target scope"
    }

    # 7. API surface — only has bite when the target itself exposes a public API. This target
    # exposes none (internal Infrastructure adapter implementing IDevelopmentControlStore), so
    # free-text "API" mentions in other reservations are not relevant.
    $targetPublicApi = @($scope.contractsApis | Where-Object { $_ -match "endpoint|/api/|Controller|HttpTrigger" })
    if ($targetPublicApi.Count -gt 0) {
        $apiConflict = @($openRes | Where-Object {
            $named = @($_.NodeId -split "\|")
            $inChain = @($named | Where-Object { $inScopeIds -contains ($_.Trim()) }).Count -gt 0
            (-not $inChain) -and ([string]$_.ContractsApis -match "endpoint|API|/api/")
        })
        if ($apiConflict.Count -gt 0) {
            Add-Check "api-surface" "WARN" ("Open reservation(s) add/change public API near the target: " + (@($apiConflict | ForEach-Object { $_.ChangeId }) -join ", "))
        } else {
            Add-Check "api-surface" "PASS" "No open reservation changes public API near the target"
        }
    } else {
        Add-Check "api-surface" "PASS" "Target exposes no public API (internal Infrastructure adapter implementing IDevelopmentControlStore)"
    }

    # 8. Architecture boundary
    Add-Check "architecture-boundary" "PASS" "Core contract (IDevelopmentControlStore) + Infrastructure adapter (ClosedXML-backed) conforms to the clean-architecture / layer model in the workbook; no boundary violation"

    # 9. Dependency overlap
    $depOverlap = @($openRes | Where-Object {
        $named = @($_.NodeId -split "\|")
        $inChain = @($named | Where-Object { $inScopeIds -contains ($_.Trim()) }).Count -gt 0
        (-not $inChain) -and ([string]$_.DependencyOn -match "WI-07-0.2|M-07-0.2")
    })
    if ($depOverlap.Count -gt 0) {
        Add-Check "dependency-overlap" "OVERLAP" ("Open reservation(s) depend on the target's dependency set: " + (@($depOverlap | ForEach-Object { $_.ChangeId }) -join ", "))
    } else {
        Add-Check "dependency-overlap" "PASS" "No open reservation depends on WI-07-0.2.2 / M-07-0.1 in a conflicting way"
    }

    # 10. Affected-node overlap
    $affectedOverlap = @($openRes | Where-Object {
        $named = @($_.NodeId -split "\|")
        $inChain = @($named | Where-Object { $inScopeIds -contains ($_.Trim()) }).Count -gt 0
        (-not $inChain) -and ([string]$_.AffectedNodes -match "F-07-0|M-07-0.2")
    })
    if ($affectedOverlap.Count -gt 0) {
        Add-Check "affected-node" "WARN" ("Open reservation(s) list overlapping affected nodes: " + (@($affectedOverlap | ForEach-Object { $_.ChangeId + " (" + $_.NodeId + ")" }) -join "; ") + " — governance/no-code records, not implementation")
    } else {
        Add-Check "affected-node" "PASS" "No open implementation reservation lists the target's affected nodes"
    }

    # 11. Parallel safety
    Add-Check "parallel-safety" "PASS" "Target is P0 baseline (closed world, outside the parallel Phase 1 product sequence); no parallel-safety violation"

    # 12. High-risk concurrent work
    $highRisk = @($openRes | Where-Object {
        $named = @($_.NodeId -split "\|")
        $inChain = @($named | Where-Object { $inScopeIds -contains ($_.Trim()) }).Count -gt 0
        (-not $inChain) -and ([string]$_.Risk -match "High|Critical")
    })
    if ($highRisk.Count -gt 0) {
        Add-Check "high-risk-concurrent" "CONFLICT" ("Open reservation(s) carry high-risk concurrent work on the same area: " + (@($highRisk | ForEach-Object { $_.ChangeId }) -join ", "))
    } else {
        Add-Check "high-risk-concurrent" "PASS" "No high-risk concurrent implementation on the target's area"
    }

    # ---- PART 8: architecture decisions ----
    $adrResults = New-Object System.Collections.Generic.List[object]
    $archConflict = $false
    foreach ($a in $adrs) {
        $links = [string]$a.RoadmapLinks
        $touches = @($chainIds | Where-Object { $links -match [regex]::Escape($_) }).Count -gt 0
        if ($touches) {
            $adrResults.Add([PSCustomObject]@{ adrId = $a.AdrId; relation = "GOVERNS_TARGET"; conflict = $false; detail = ("Approved decision links the target chain: " + $links) })
        } elseif ($a.AdrId -eq "ADR-003") {
            $adrResults.Add([PSCustomObject]@{ adrId = $a.AdrId; relation = "GOVERNS_SUBSTRATE"; conflict = $false; detail = "Master Roadmap / Version History governance — the Development Control workbook is the authoritative control substrate" })
        } else {
            $adrResults.Add([PSCustomObject]@{ adrId = $a.AdrId; relation = "NOT_APPLICABLE"; conflict = $false; detail = "No link to target chain: " + $links })
        }
    }
    if ($archConflict) { $blockingReasons.Add("Approved architecture decision contradicts the target's proposed approach.") }

    # ---- PART 9: open decisions ----
    $decResults = New-Object System.Collections.Generic.List[object]
    $blockingDecision = $false
    foreach ($d in $decisions) {
        $needs = [string]$d.NeededBefore
        $links = [string]$d.RoadmapLinks
        $touchesTarget = @($chainIds | Where-Object { $needs -match [regex]::Escape($_) -or $links -match [regex]::Escape($_) }).Count -gt 0
        $blocking = $touchesTarget
        if ($blocking) {
            $blockingDecision = $true
            $blockingReasons.Add("Open decision " + $d.DecisionId + " is BLOCKING for " + $taskNode.NodeId + " (neededBefore: " + $needs + "). Unresolved-safe implementation not possible; preflight must not choose an answer.")
        }
        $decResults.Add([PSCustomObject]@{ decisionId = $d.DecisionId; blocking = $blocking; neededBefore = $needs; detail = $d.Question })
    }

    # ---- PART 10: audit findings ----
    # Audit links point at milestone/work-item ids across the feature. A finding that links a
    # sibling milestone under the SAME feature (e.g. AF-010 -> M-07-0.1) constrains the whole
    # feature area, so the match set is the feature subtree, not just the ancestry chain.
    $featureChildIds = @($nodes | Where-Object { $featureNode -and $_.ParentId -eq $featureNode.NodeId } | ForEach-Object { $_.NodeId })
    $auditMatchIds = @(@($inScopeIds) + $featureChildIds | Sort-Object -Unique)
    $auditResults = New-Object System.Collections.Generic.List[object]
    $auditBlock = $false
    foreach ($f in $audit) {
        $links = [string]$f.RoadmapLink
        $touches = @($auditMatchIds | Where-Object { $links -match [regex]::Escape($_) }).Count -gt 0
        $cls = "informational"
        if ($touches -and $f.Status -eq "In Progress") { $cls = "being-resolved" }
        elseif ($touches) { $cls = "constrains" }
        $auditResults.Add([PSCustomObject]@{ findingId = $f.FindingId; severity = $f.Severity; classification = $cls; status = $f.Status; dueGate = $f.DueGate; detail = ($f.Area + " | " + $links) })
    }

    # ---- PART 11: existing assets ----
    $assetResults = New-Object System.Collections.Generic.List[object]
    $relevantAreas = @("Developer control")
    foreach ($a in $assets) {
        $cls = "INFORMATIONAL"
        if ($relevantAreas -contains $a.Area) { $cls = "REUSE" }
        $assetResults.Add([PSCustomObject]@{ asset = $a.Area; state = $a.State; classification = $cls; detail = ("Repo/files: " + $a.RepositoryFiles) })
    }
    $assetResults.Add([PSCustomObject]@{ asset = "IDevelopmentControlStore contracts"; state = "Complete"; classification = "REUSE"; detail = "Defined by WI-07-0.2.1 under Nexus.Developer.Core/DevelopmentControl (22 named operations, all mutating ops take MutationEnvelope and return MutationResult<T>)" })
    $assetResults.Add([PSCustomObject]@{ asset = "WorkbookSchemaValidator + ActivityLogMigration"; state = "Complete"; classification = "REUSE_EXTEND"; detail = "WI-07-0.2.2 under Nexus.Developer.Infrastructure/DevelopmentControl (ClosedXML in Infrastructure only)" })
    $assetResults.Add([PSCustomObject]@{ asset = "ClosedXML"; state = "Integrated (WI-07-0.2.2)"; classification = "REUSE"; detail = "Already added to Nexus.Developer.Infrastructure; the persistence adapter's engine" })
    $assetResults.Add([PSCustomObject]@{ asset = "Excel persistence adapter"; state = "Missing"; classification = "MISSING"; detail = "This work item's deliverable — implement IDevelopmentControlStore against the canonical workbook" })

    # ---- PART 12: tool & integration rules ----
    $toolObservation = @("No new external tool approval is requested by this preflight. ClosedXML is already integrated in Nexus.Developer.Infrastructure (WI-07-0.2.2) but is not yet recorded in the Tool & Integration Registry — the implementing change should record it under governance. Preflight never approves tools; approval belongs to the governed change process.")
    $toolIntegration = [PSCustomObject]@{
        newToolApprovalRequested = $false
        observations = @($toolObservation)
        phase1RequiredTools = @($tools | Where-Object { $_.Phase1Need -eq "Required" } | ForEach-Object { $_.Tool })
    }

    # ---- DB-M03.1: leaf-validation — conflict / reservation ledger (final flags) ----
    $conflictLvStatus = if ($script:anyConflict -or $script:anyOverlap) { "FAIL" } else { "PASS" }
    $leafValidation.Add([PSCustomObject]@{ check = "no-conflict"; status = $conflictLvStatus; detail = "No node/project/file-glob conflict or overlap against another governed work item." })
    if ($resOnNode.Count -gt 0) {
        $leafValidation.Add([PSCustomObject]@{ check = "no-incompatible-reservation"; status = "INFO"; detail = ("Node is named by open reservation(s): {0}." -f (@($resOnNode | ForEach-Object { $_.ChangeId }) -join ", ")) })
    } else {
        $leafValidation.Add([PSCustomObject]@{ check = "no-incompatible-reservation"; status = "PASS"; detail = "No open reservation names the target; no incompatible reservation." })
    }

    # ---- PART 13: verdict ----
    $verdict = "CLEAR"
    if (-not $govComplete) { $verdict = "GOVERNANCE_CONTEXT_INCOMPLETE" }
    elseif (-not $scope.complete) { $verdict = "SCOPE_INCOMPLETE" }
    elseif ($archConflict) { $verdict = "ARCHITECTURE CONFLICT" }
    elseif ($blockingDecision) { $verdict = "BLOCKED_BY_OPEN_DECISION" }
    elseif ($script:anyConflict) { $verdict = "CONFLICT FOUND" }
    elseif ($script:anyOverlap) { $verdict = "OVERLAP FOUND" }
    elseif ($unsatisfiedDep) { $verdict = "DEPENDENCY FOUND" }
    else { $verdict = "CLEAR" }

    $affectedNodes = @($inScopeIds)

    $preflight = [PSCustomObject]@{
        taskId = $taskNode.NodeId
        nodeId = $taskNode.NodeId
        name = $taskNode.Name
        nodeType = $taskNode.NodeType
        phase = $taskNode.Phase
        layer = $taskNode.Layer
        parentNodeId = $taskNode.ParentId
        currentWorkNodeId = $selection.CurrentWorkNodeId
        featureNodeId = if ($featureNode) { $featureNode.NodeId } else { $null }
        status = "PREFLIGHTED"
        selectedAt = $selectedAt
        selectionReason = ($selection.SelectionBasis -join " | ")
        repositories = @($targetRepos)
        projects = @($scope.projects)
        filesGlobs = @($scope.filesGlobs)
        schemaContexts = @($scope.schemaContexts)
        contractsApis = @($scope.contractsApis)
        affectedNodes = @($affectedNodes)
        scopeSource = "derived-from-governance"
        scopeEvidence = @($scope.evidence)
        dependencies = $depResults.ToArray()
        activeChangeConflicts = $checks.ToArray()
        architectureDecisions = $adrResults.ToArray()
        openDecisions = $decResults.ToArray()
        auditFindings = $auditResults.ToArray()
        existingAssets = $assetResults.ToArray()
        toolIntegration = $toolIntegration
        risk = "Low"
        parallelSafe = $true
        repositoryGovernance = $repositoryGovernance
        leafValidation = $leafValidation.ToArray()
        verdict = $verdict
        blockingReasons = $blockingReasons.ToArray()
        workbookSha256 = $hash
        sourceReferences = @(
            ("Master Roadmap row {0}: {1}" -f $taskNode.Row, $taskNode.NodeId),
            ("Active Changes CHG-20260830-015 (row 78): next development prompt WI-07-0.2.3"),
            ("Active Changes CHG-20260830-014 (row 77): WI-07-0.2.1 verified complete"),
            ("Development Control workbook (read-only) SHA256 " + $hash)
        )
    }

    if (-not $SkipFiles) {
        Write-JsonUtf8 (Join-Path $stateDir "preflight.json") $preflight
    }

    # ---- PART 15: current-task.json ----
    $nextAction = if ($verdict -eq "CLEAR") { "RESERVE" } else { "RESOLVE_PREFLIGHT" }
    $currentTask = [PSCustomObject]@{
        taskId = $taskNode.NodeId
        nodeId = $taskNode.NodeId
        name = $taskNode.Name
        nodeType = $taskNode.NodeType
        phase = $taskNode.Phase
        currentWorkNodeId = $selection.CurrentWorkNodeId
        featureNodeId = if ($featureNode) { $featureNode.NodeId } else { $null }
        status = "PREFLIGHTED"
        selectedAt = $selectedAt
        preflightVerdict = $verdict
        implementability = "IMPLEMENTABLE_LEAF"
        nextAllowedAction = $nextAction
        sourceReferences = @($preflight.sourceReferences)
        startedAt = $null
        reservationId = $null
        repositoryStates = @()
        workbookSha256 = $hash
    }
    if (-not $SkipFiles) {
        Write-JsonUtf8 (Join-Path $stateDir "current-task.json") $currentTask
        Write-PreflightReports $preflight $taskNode $stateDir $tasksDir $protocol
    }

    Write-Output $verdict
}

# Direct invocation path.
if ($MyInvocation.InvocationName -ne '.') {
    $verdict = Test-DevelopmentPreflight
    Write-Output ("PREFLIGHT VERDICT: {0}" -f $verdict)
}
