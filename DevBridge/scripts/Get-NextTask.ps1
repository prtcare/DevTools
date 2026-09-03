<#
.SYNOPSIS
  DB-M03 PART 1 — Governed current/next Nexus task selection (read-only).

.DESCRIPTION
  Determines the correct CURRENT WORK FIRST / NEXT WORK development target from the
  authoritative Development Control workbook, per the DB-M03 specification:

  * CURRENT WORK FIRST: an In-Progress / Active / Started node that should continue per the
    workbook is selected ahead of any Planned node regardless of priority. Among multiple
    current-work nodes the workbook's own concurrency authority — the append-only Active
    Changes reservation ledger — decides which node is the live current work: the node named
    by the freshest open reservation (highest row in the ledger). "Do NOT skip for higher
    priority."

  * NEXT WORK: drills into the selected current-work node and picks the first planned child
    whose declared dependencies are satisfied, ordered by Sort Key, honoring hierarchy,
    Phase Plan link, explicit D&B blockers, gates, priority, parent readiness, Next Action
    and Development Guide.

  * AMBIGUITY: if two or more candidates tie on every ranking signal with no safe governing
    method, returns TASK_SELECTION_AMBIGUOUS with candidate Node IDs / titles / reason.

  READ-ONLY. Does NOT reserve work (reservation belongs to DB-M04). Does NOT modify the
  Development Control workbook. Does NOT modify Nexus repositories.

.OUTPUTS
  PSCustomObject:
    TaskSelectionStatus    "SELECTED" | "TASK_SELECTION_AMBIGUOUS" |
                           "NO_IMPLEMENTABLE_DESCENDANT" | "HUMAN_GOVERNANCE_REQUIRED" |
                           "IMPLEMENTATION_TARGET_UNKNOWN"
    CurrentWorkNodeId      Node id of the current-work anchor (or null)
    CurrentWorkNode        The current-work roadmap node object (or null)
    TaskNodeId             Node id of the selected task (or null when blocked/ambiguous)
    TaskNode               The selected task roadmap node object (or null)
    SelectionBasis         String[] of reasoning lines
    Candidates             Node ids of all current-work candidates (ranked)
    CandidateIds           Node ids (ambiguity payload)
    AmbiguityReason        String when ambiguous, else null
    BlockState             Block token when selection is blocked, else null
    BlockReason            String when selection is blocked, else null

  DB-M03.1: a governed container (Layer/Feature/Milestone) or an incomplete/unknown node is
  NEVER returned as the selected task. Containers resolve recursively to the first eligible
  IMPLEMENTABLE_LEAF descendant; when no eligible descendant exists the engine returns an
  honest block state (NO_IMPLEMENTABLE_DESCENDANT / HUMAN_GOVERNANCE_REQUIRED /
  IMPLEMENTATION_TARGET_UNKNOWN) instead of selecting a container as the task.
#>
[CmdletBinding()]
param(
    [switch]$ShowCandidates
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\Read-DevelopmentControl.ps1"
. "$PSScriptRoot\Set-DevBridgeStateEntry.ps1"
. "$PSScriptRoot\TrialDependencyOverlay.ps1"

# DB-M12.4 TRIAL-only proving-history exclusion (read at dot-source time so both the
# direct invocation path and Test-DevelopmentPreflight's dot-source see it).
# State-dir / config-path overrides exist for the DB-M12.4 fixture tests only.
$script:NextTaskStateDir = Join-Path $script:DevBridgeRoot "state"
$script:NextTaskConfigPath = Join-Path $script:DevBridgeRoot "config\devbridge.json"
if ($env:DB_NEXTTASK_STATE_DIR) { $script:NextTaskStateDir = $env:DB_NEXTTASK_STATE_DIR }
if ($env:DB_NEXTTASK_CONFIG_PATH) { $script:NextTaskConfigPath = $env:DB_NEXTTASK_CONFIG_PATH }
$script:NextTaskMode = "TRIAL"
$script:UsedProvingIds = New-Object 'System.Collections.Generic.HashSet[string]'
try {
    $ntCt = Read-DevBridgeJson (Join-Path $script:NextTaskStateDir "current-task.json")
    if ($null -ne $ntCt) { $script:NextTaskMode = Get-DevBridgeMode $ntCt $script:NextTaskConfigPath }
    $ntHist = Read-DevBridgeJson (Join-Path $script:NextTaskStateDir "trial-proving-history.json")
    if ($null -ne $ntHist) {
        foreach ($e in @(Get-DevBridgeField $ntHist "entries")) {
            $nid = [string](Get-DevBridgeField $e "nodeId")
            if ($nid) { [void]$script:UsedProvingIds.Add($nid) }
        }
    }
} catch { }
$script:TrialExclusion = ($script:NextTaskMode -eq "TRIAL") -and ($script:UsedProvingIds.Count -gt 0)

# TRIAL-only: a closed/proven trial task is excluded from re-selection. REAL mode is
# never affected (the roadmap's own status remains the sole sequencing authority).
function Test-NotTrialProven([string]$nodeId) {
    if (-not $script:TrialExclusion) { return $true }
    return -not $script:UsedProvingIds.Contains($nodeId)
}

$script:PriorityRank = @{ "Critical" = 6; "High" = 5; "Medium" = 4; "Low" = 3; "Backlog" = 2 }
$script:NodeSpecRank  = @{ "Subtask" = 6; "Task" = 5; "WorkItem" = 4; "Milestone" = 3; "Feature" = 2; "Layer" = 1 }

function Get-PriorityRank([string]$p) {
    if (-not $p) { return 1 }
    if ($script:PriorityRank.ContainsKey($p)) { return $script:PriorityRank[$p] }
    return 1
}

function Get-SpecRank([string]$t) {
    if (-not $t) { return 0 }
    if ($script:NodeSpecRank.ContainsKey($t)) { return $script:NodeSpecRank[$t] }
    return 0
}

function Test-NodeId([string]$s) {
    # Node ids: F-<layer>-<n> (Feature), WI-<layer>-<n>.<n> (WorkItem), M-<layer>-<n>.<n> (Milestone),
    # T-<layer>-<n>.<n>.<n>.<n> (Task), S-<layer>-<n>.<n>.<n>.<n>.<n> (Subtask).
    # WI is a two-letter prefix — a single [FMWTS] class would fail every WorkItem id.
    return ($s -match "^(F|WI|M|T|S)-\d+-\d+(\.\d+)*$")
}

function Get-NextTask {
    [CmdletBinding()]
    param()

    $nodes = @(Get-AllRoadmapNodes)
    $openRes = @(Get-ActiveChangesOpen)
    $phasePlan = @(Get-PhasePlan)
    $rels = @(Get-DependencyRelations)
    $script:OverlayNotes = New-Object System.Collections.Generic.List[string]   # DB-M03.2 honest-block notes

    # --- Map open reservations to the node ids they name (NodeId cell is "|"-separated) ---
    $resByNode = @{}
    foreach ($r in $openRes) {
        foreach ($tok in ($r.NodeId -split "\|")) {
            $id = $tok.Trim()
            if (-not $id) { continue }
            if (-not $resByNode.ContainsKey($id)) { $resByNode[$id] = New-Object System.Collections.Generic.List[object] }
            $resByNode[$id].Add($r)
        }
    }

    function Get-FreshestRow([string]$nodeId) {
        if (-not $resByNode.ContainsKey($nodeId)) { return -1 }
        $max = -1
        foreach ($r in $resByNode[$nodeId]) { if ($r.Row -gt $max) { $max = $r.Row } }
        return $max
    }

    function Get-FreshestChangeId([string]$nodeId) {
        if (-not $resByNode.ContainsKey($nodeId)) { return "" }
        $best = $null
        foreach ($r in $resByNode[$nodeId]) { if (-not $best -or $r.Row -gt $best.Row) { $best = $r } }
        if ($best) { return $best.ChangeId }
        return ""
    }

    function Get-PhaseStepRank($node, $phasePlan) {
        # Earliest eligible (non-superseded, non-completed) Phase Plan step whose link mentions
        # this node or its parent. 999 when the node is not sequenced by the Phase Plan (e.g. P0
        # baseline work), which ranks last on this signal.
        $best = 999
        foreach ($p in $phasePlan) {
            if ($p.Status -eq "Superseded" -or $p.Status -eq "Completed" -or $p.Status -eq "Complete") { continue }
            $stepNum = 0
            if ($p.PhaseStep -match "(\d+)-(\d+)") { $stepNum = [int]$matches[1] * 100 + [int]$matches[2] }
            if ($stepNum -eq 0) { continue }
            $link = [string]$p.RoadmapLink
            if ($link -match [regex]::Escape($node.NodeId)) { if ($stepNum -lt $best) { $best = $stepNum }; continue }
            if ($node.ParentId -and $link -match [regex]::Escape($node.ParentId)) { if ($stepNum -lt $best) { $best = $stepNum } }
        }
        return $best
    }

    function Get-RelBlockedIds($rels) {
        # Node ids blocked by an Open + Blocking explicit D&B relation.
        $blocked = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($r in $rels) {
            if ($r.Blocking -eq "Yes" -and $r.Status -eq "Open") {
                foreach ($t in ($r.DependsOnBlocks -split "[|,;]")) {
                    $id = $t.Trim()
                    if (Test-NodeId $id) { [void]$blocked.Add($id) }
                }
            }
        }
        return $blocked
    }

    function Test-DepsSatisfied($node, $nodes, $blocked) {
        # A node is dependency-satisfied when (a) no Open+Blocking REL blocks it and
        # (b) every node-id token in its Dependencies column resolves to a Terminal node,
        # OR (DB-M03.2, TRIAL mode only) is satisfied for PROVING-CYCLE SELECTION by a
        # governedly closed TRIAL proving task (TRIAL_DEPENDENCY_SATISFIED overlay).
        # The overlay is a selection-time concern: the real roadmap status of the
        # predecessor remains authoritative and is NEVER written as completion.
        if ($blocked -and $blocked.Contains($node.NodeId)) { return $false }
        $deps = [string]$node.Dependencies
        if (-not $deps) { return $true }
        foreach ($tok in ($deps -split "[|,;]")) {
            $depId = $tok.Trim()
            if (-not $depId) { continue }
            if (-not (Test-NodeId $depId)) { continue }   # free-text note, not a governed node id
            $depNode = $nodes | Where-Object { $_.NodeId -eq $depId } | Select-Object -First 1
            if ($depNode -and $depNode.Status -notin @("Completed", "Complete")) {
                # DB-M03.2 TRIAL-only overlay: consult the governedly closed trial
                # proving evidence before declaring the dependency unsatisfied.
                $ov = Test-TrialDependencySatisfied -DependencyNodeId $depId -StateDir $script:NextTaskStateDir -ConfigPath $script:NextTaskConfigPath -RealStatus ([string]$depNode.Status)
                if (-not $ov.Satisfied) {
                    if ($ov.BlockCode) {
                        $script:OverlayNotes.Add(("dependency {0}: {1} ({2})" -f $depId, $ov.BlockCode, $ov.Reason))
                    }
                    return $false
                }
                # Truthful selection basis: record that this dependency was satisfied by
                # the TRIAL-only overlay (real status remains authoritative; NOT completion).
                $script:OverlayNotes.Add(("dependency {0}: satisfied by trial-proven overlay ({1}; real status '{2}' remains authoritative, NOT real Nexus completion)" -f $depId, $ov.Reason, $depNode.Status))
            }
        }
        return $true
    }

    # DB-M03.1 — deterministic node-implementability classification from GOVERNED WORKBOOK
    # SEMANTICS (NodeType column + BreakdownComplete + child presence). NodeId prefixes are
    # NOT used for classification: NodeId prefix and governed NodeType are independent signals.
    function Get-ImplementabilityClass($node, $allNodes) {
        $nodeType = [string]$node.NodeType
        if (-not $nodeType) { return "UNKNOWN_NODE_TYPE" }
        $breakdown = [string]$node.BreakdownComplete
        $childCount = 0
        if ($allNodes) { $childCount = @($allNodes | Where-Object { $_.ParentId -eq $node.NodeId }).Count }

        switch ($nodeType) {
            "Layer"    { return "NON_IMPLEMENTABLE_CONTAINER" }
            "Feature"  { return "NON_IMPLEMENTABLE_CONTAINER" }
            "Milestone" { return "NON_IMPLEMENTABLE_CONTAINER" }
            "Subtask"  { return "IMPLEMENTABLE_LEAF" }
            "WorkItem" {
                if ($breakdown -eq "No") { return "INCOMPLETE_WORK_ITEM" }
                if ($childCount -gt 0) { return "NON_IMPLEMENTABLE_CONTAINER" }
                return "IMPLEMENTABLE_LEAF"
            }
            "Task" {
                if ($breakdown -eq "No") { return "INCOMPLETE_WORK_ITEM" }
                if ($childCount -gt 0) { return "NON_IMPLEMENTABLE_CONTAINER" }
                return "IMPLEMENTABLE_LEAF"
            }
            default { return "UNKNOWN_NODE_TYPE" }
        }
    }

    # DB-M03.1 — resolve a governed container anchor to its first eligible implementable leaf
    # descendant, DFS pre-order over governed reading order (SortKey then Row). A descendant is
    # eligible iff class==IMPLEMENTABLE_LEAF AND dependency-satisfied AND not trial-proven.
    # Terminal subtrees (Completed/Complete) and trial-proven subtrees are skipped whole.
    function Resolve-ImplementableDescendant($anchor, $nodes, $blocked) {
        $children = @($nodes | Where-Object { $_.ParentId -eq $anchor.NodeId } |
            Sort-Object @{Expression="SortKey";Ascending=$true}, @{Expression="Row";Ascending=$true})
        foreach ($child in $children) {
            if ($child.Status -in @("Completed", "Complete")) { continue }      # terminal subtree = done work
            if (-not (Test-NotTrialProven $child.NodeId)) { continue }          # trial-proven subtree excluded
            if (-not (Test-DepsSatisfied $child $nodes $blocked)) { continue }  # dependency-blocked subtree
            $childClass = Get-ImplementabilityClass $child $nodes
            if ($childClass -eq "IMPLEMENTABLE_LEAF") {
                return @{ Found = $true; Leaf = $child; Chain = @($child.NodeId) }
            }
            if ($childClass -eq "UNKNOWN_NODE_TYPE") { continue }  # cannot classify -> cannot resolve through
            $sub = Resolve-ImplementableDescendant $child $nodes $blocked
            if ($sub.Found) {
                return @{ Found = $true; Leaf = $sub.Leaf; Chain = @($child.NodeId) + @($sub.Chain) }
            }
        }
        return @{ Found = $false; Leaf = $null; Chain = @() }
    }

    $currentStatuses = @("In Progress", "Active", "Started")
    $currentWork = @($nodes | Where-Object { $_.Status -in $currentStatuses })

    # Current-work candidates = current-work nodes that are named by at least one open
    # reservation (the workbook's proof that the work is actively being continued).
    $candidates = @($currentWork | Where-Object { $resByNode.ContainsKey($_.NodeId) -and (Test-NotTrialProven $_.NodeId) })

    if ($candidates.Count -eq 0) {
        # --- NEXT WORK fallback: no active current work; select from Planned nodes. ---
        $blocked = Get-RelBlockedIds $rels
        $planned = @($nodes | Where-Object {
            $_.Status -eq "Planned" -and (Test-DepsSatisfied $_ $nodes $blocked) -and (Test-NotTrialProven $_.NodeId)
        })
        $plannedRanked = @($planned | ForEach-Object {
            [PSCustomObject]@{
                Node      = $_
                PrioRank  = (Get-PriorityRank $_.Priority)
                PhaseRank = (Get-PhaseStepRank $_ $phasePlan)
                SpecRank  = (Get-SpecRank $_.NodeType)
                SortKey   = $_.SortKey
            }
        } | Sort-Object @{Expression="PhaseRank";Ascending=$true}, @{Expression="PrioRank";Descending=$true}, @{Expression="SpecRank";Descending=$true}, @{Expression="SortKey";Ascending=$true}, @{Expression="Row";Ascending=$true})

        if ($plannedRanked.Count -eq 0) {
            $selection = [PSCustomObject]@{
                TaskSelectionStatus = "TASK_SELECTION_AMBIGUOUS"
                CurrentWorkNodeId = $null; CurrentWorkNode = $null
                TaskNodeId = $null; TaskNode = $null
                SelectionBasis = @("No current-work candidate exists and no dependency-satisfied Planned node exists in the governed universe.")
                Candidates = @(); CandidateIds = @()
                AmbiguityReason = "No governed next-work target exists to select."
            }
            return $selection
        }

        $topPlanned = $plannedRanked[0].Node
        $topClass = Get-ImplementabilityClass $topPlanned $nodes
        if ($topClass -eq "IMPLEMENTABLE_LEAF") {
            $taskNode = $topPlanned
            $selection = [PSCustomObject]@{
                TaskSelectionStatus = "SELECTED"
                CurrentWorkNodeId = $null; CurrentWorkNode = $null
                TaskNodeId = $taskNode.NodeId; TaskNode = $taskNode
                SelectionBasis = @("NEXT WORK (no current work): first dependency-satisfied Planned node by Phase Plan link, priority, specificity, Sort Key: $($taskNode.NodeId) ($($taskNode.Name)); classified IMPLEMENTABLE_LEAF.")
                Candidates = @($plannedRanked | ForEach-Object { $_.Node.NodeId })
                CandidateIds = @()
                AmbiguityReason = $null
            }
            return $selection
        }

        # DB-M03.1: the top-ranked planned node is a governed container / incomplete / unknown —
        # containers are NEVER tasks. Resolve it to an eligible implementable leaf descendant.
        $resolveNw = Resolve-ImplementableDescendant $topPlanned $nodes $blocked
        if ($resolveNw.Found) {
            $taskNode = $resolveNw.Leaf
            $chainNw = ($resolveNw.Chain -join " -> ")
            $nwBasis = "NEXT WORK container resolution (DB-M03.1): top-ranked planned node {0} ({1}) is a governed {2}; resolved to the eligible IMPLEMENTABLE_LEAF descendant {3} ({4}) via chain {5}." -f $topPlanned.NodeId, $topPlanned.Name, $topClass, $taskNode.NodeId, $taskNode.Name, $chainNw
            if ($script:OverlayNotes.Count -gt 0) {
                $nwBasis = $nwBasis + " Trial-proven dependency overlay (DB-M03.2): " + ($script:OverlayNotes -join "; ") + "."
            }
            $selection = [PSCustomObject]@{
                TaskSelectionStatus = "SELECTED"
                CurrentWorkNodeId = $null; CurrentWorkNode = $null
                TaskNodeId = $taskNode.NodeId; TaskNode = $taskNode
                SelectionBasis = @($nwBasis)
                Candidates = @($plannedRanked | ForEach-Object { $_.Node.NodeId })
                CandidateIds = @()
                AmbiguityReason = $null
            }
            return $selection
        }

        # Honest block for the NEXT WORK path (DB-M03.1 block states).
        $blockState = "NO_IMPLEMENTABLE_DESCENDANT"
        $blockReason = "Top-ranked planned node {0} ({1}) is a governed {2} and no dependency-satisfied, non-trial-proven IMPLEMENTABLE_LEAF descendant exists; a human governance decision is required." -f $topPlanned.NodeId, $topPlanned.Name, $topClass
        if ($topClass -eq "INCOMPLETE_WORK_ITEM") {
            $blockState = "HUMAN_GOVERNANCE_REQUIRED"
            $blockReason = "Top-ranked planned node {0} ({1}) is governed BreakdownComplete=No (INCOMPLETE_WORK_ITEM) with no eligible IMPLEMENTABLE_LEAF descendant; the human operator must complete the governed breakdown." -f $topPlanned.NodeId, $topPlanned.Name
        } elseif ($topClass -eq "UNKNOWN_NODE_TYPE") {
            $blockState = "IMPLEMENTATION_TARGET_UNKNOWN"
            $blockReason = "Top-ranked planned node {0} ({1}) carries a node type outside the governed vocabulary; the implementation target cannot be classified. Human governance is required." -f $topPlanned.NodeId, $topPlanned.Name
        }
        if ($script:OverlayNotes.Count -gt 0) {
            $blockReason = $blockReason + " Trial-proven dependency overlay (DB-M03.2): " + ($script:OverlayNotes -join "; ") + "."
        }
        $selection = [PSCustomObject]@{
            TaskSelectionStatus = $blockState
            CurrentWorkNodeId = $null; CurrentWorkNode = $null
            TaskNodeId = $null; TaskNode = $null
            SelectionBasis = @($blockReason)
            Candidates = @($plannedRanked | ForEach-Object { $_.Node.NodeId })
            CandidateIds = @()
            AmbiguityReason = $null
            BlockState = $blockState
            BlockReason = $blockReason
        }
        return $selection
    }

    # --- CURRENT WORK FIRST: rank candidates. ---
    # R1 freshest reservation row (the workbook's own concurrency ledger — append-only, row =
    # chronological). R2 priority. R3 earliest Phase Plan step. R4 node specificity. R5 Sort Key.
    $ranked = @($candidates | ForEach-Object {
        [PSCustomObject]@{
            Node            = $_
            FreshestRow     = (Get-FreshestRow $_.NodeId)
            FreshestChange  = (Get-FreshestChangeId $_.NodeId)
            PrioRank        = (Get-PriorityRank $_.Priority)
            PhaseRank       = (Get-PhaseStepRank $_ $phasePlan)
            SpecRank        = (Get-SpecRank $_.NodeType)
            SortKey         = $_.SortKey
            ReservationIds  = (@($resByNode[$_.NodeId] | ForEach-Object { $_.ChangeId }) -join ", ")
        }
    } | Sort-Object @{Expression="FreshestRow";Descending=$true}, @{Expression="PrioRank";Descending=$true}, @{Expression="PhaseRank";Ascending=$true}, @{Expression="SpecRank";Descending=$true}, @{Expression="SortKey";Ascending=$true}, @{Expression="Row";Ascending=$true})

    $top = $ranked[0]
    # A single current-work candidate has no runner-up and is therefore never ambiguous.
    # Guard the access (Set-StrictMode -Version Latest throws on out-of-range indexing).
    $runnerUp = $null
    if ($ranked.Count -gt 1) { $runnerUp = $ranked[1] }

    # Ambiguity only when the top candidate ties the runner-up on every ranking signal.
    $ambiguous = $false
    $ambigReason = ""
    if ($runnerUp) {
        if ($top.FreshestRow -eq $runnerUp.FreshestRow -and
            $top.PrioRank -eq $runnerUp.PrioRank -and
            $top.PhaseRank -eq $runnerUp.PhaseRank -and
            $top.SpecRank -eq $runnerUp.SpecRank) {
            $ambiguous = $true
            $ambigReason = "Candidates {0} ({1}) and {2} ({3}) tie on reservation freshness (row {4}), priority, Phase Plan link, and node specificity; the workbook provides no governing signal to break the tie. Missing decision: which current-work node is the designated continuation target." -f $top.Node.NodeId, $top.Node.Name, $runnerUp.Node.NodeId, $runnerUp.Node.Name, $top.FreshestRow
        }
    }

    if ($ambiguous) {
        $selection = [PSCustomObject]@{
            TaskSelectionStatus = "TASK_SELECTION_AMBIGUOUS"
            CurrentWorkNodeId = $null; CurrentWorkNode = $null
            TaskNodeId = $null; TaskNode = $null
            SelectionBasis = @($ambigReason)
            Candidates = @($ranked | ForEach-Object { $_.Node.NodeId })
            CandidateIds = @($ranked | ForEach-Object { $_.Node.NodeId })
            AmbiguityReason = $ambigReason
        }
        return $selection
    }

    # --- Selected current work. Classify the anchor; resolve containers to an eligible leaf. ---
    $cw = $top.Node
    $blocked = Get-RelBlockedIds $rels

    # NB: never wrap a System.Collections.Generic.List[object] variable in @(...) on PS 5.1 —
    # the array subexpression throws "Argument types do not match". Use the list's native
    # .Count and pipelines (which unroll the list) instead.
    $basisCurrentWork = ("CURRENT WORK FIRST: {0} ({1}) has Status '{2}' and is named by {3} open reservation(s) in the Active Changes ledger; its freshest open reservation is {4} (row {5}) — the workbook's most recent governed activity. Per the rule it is NOT skipped for higher-priority Planned work." -f $cw.NodeId, $cw.Name, $cw.Status, $resByNode[$cw.NodeId].Count, $top.FreshestChange, $top.FreshestRow)

    $cwClass = Get-ImplementabilityClass $cw $nodes
    if ($cwClass -eq "IMPLEMENTABLE_LEAF") {
        # DB-M03.1 leaf selection: the current-work node itself is an implementable leaf.
        $drillBasis = "CURRENT WORK node {0} ({1}) is governed NodeType '{2}' with no children and no incomplete-breakdown signal — classified IMPLEMENTABLE_LEAF; the current-work node itself is the task." -f $cw.NodeId, $cw.Name, $cw.NodeType
        $basis = @($drillBasis, $basisCurrentWork)
        $selection = [PSCustomObject]@{
            TaskSelectionStatus = "SELECTED"
            CurrentWorkNodeId = $cw.NodeId
            CurrentWorkNode = $cw
            TaskNodeId = $cw.NodeId
            TaskNode = $cw
            SelectionBasis = @($basis)
            Candidates = @($ranked | ForEach-Object { $_.Node.NodeId })
            CandidateIds = @()
            AmbiguityReason = $null
        }
        return $selection
    }

    # Container / incomplete / unknown: resolve to the first eligible implementable leaf
    # descendant. Containers are NEVER returned as the task (DB-M03.1).
    $resolve = Resolve-ImplementableDescendant $cw $nodes $blocked
    if ($resolve.Found) {
        $taskNode = $resolve.Leaf
        $chainText = ($resolve.Chain -join " -> ")
        $drillBasis = "CURRENT WORK container resolution (DB-M03.1): {0} ({1}) is a governed {2}; resolved to the eligible IMPLEMENTABLE_LEAF descendant {3} ({4}) via chain {5} (deps satisfied, not trial-proven)." -f $cw.NodeId, $cw.Name, $cwClass, $taskNode.NodeId, $taskNode.Name, $chainText
        if ($script:OverlayNotes.Count -gt 0) {
            $drillBasis = $drillBasis + " Trial-proven dependency overlay (DB-M03.2): " + ($script:OverlayNotes -join "; ") + "."
        }
        $basis = @($drillBasis, $basisCurrentWork)
        $selection = [PSCustomObject]@{
            TaskSelectionStatus = "SELECTED"
            CurrentWorkNodeId = $cw.NodeId
            CurrentWorkNode = $cw
            TaskNodeId = $taskNode.NodeId
            TaskNode = $taskNode
            SelectionBasis = @($basis)
            Candidates = @($ranked | ForEach-Object { $_.Node.NodeId })
            CandidateIds = @()
            AmbiguityReason = $null
        }
        return $selection
    }

    # Honest block (DB-M03.1): a governed container/incomplete/unknown node is never a task,
    # and no eligible leaf descendant exists to continue its work.
    $blockState = "NO_IMPLEMENTABLE_DESCENDANT"
    $blockReason = "{0} ({1}) is a governed {2} and no dependency-satisfied, non-trial-proven IMPLEMENTABLE_LEAF descendant exists to continue its work; a human governance decision is required to identify an implementation target." -f $cw.NodeId, $cw.Name, $cwClass
    if ($cwClass -eq "INCOMPLETE_WORK_ITEM") {
        $blockState = "HUMAN_GOVERNANCE_REQUIRED"
        $blockReason = "{0} ({1}) is governed BreakdownComplete=No (INCOMPLETE_WORK_ITEM) and no eligible IMPLEMENTABLE_LEAF descendant exists; the human operator must complete the governed breakdown before work can be selected." -f $cw.NodeId, $cw.Name
    } elseif ($cwClass -eq "UNKNOWN_NODE_TYPE") {
        $blockState = "IMPLEMENTATION_TARGET_UNKNOWN"
        $blockReason = "{0} ({1}) carries a node type outside the governed vocabulary; the implementation target cannot be classified. Human governance is required." -f $cw.NodeId, $cw.Name
    }
    if ($script:OverlayNotes.Count -gt 0) {
        $blockReason = $blockReason + " Trial-proven dependency overlay (DB-M03.2): " + ($script:OverlayNotes -join "; ") + "."
    }
    $basis = @($blockReason, $basisCurrentWork)
    $selection = [PSCustomObject]@{
        TaskSelectionStatus = $blockState
        CurrentWorkNodeId = $cw.NodeId
        CurrentWorkNode = $cw
        TaskNodeId = $null
        TaskNode = $null
        SelectionBasis = @($basis)
        Candidates = @($ranked | ForEach-Object { $_.Node.NodeId })
        CandidateIds = @()
        AmbiguityReason = $null
        BlockState = $blockState
        BlockReason = $blockReason
    }
    return $selection
}

# Direct invocation path (not dot-sourced).
if ($MyInvocation.InvocationName -ne '.') {
    $sel = Get-NextTask
    Write-Output ("TaskSelectionStatus : {0}" -f $sel.TaskSelectionStatus)
    Write-Output ("CurrentWork         : {0}" -f $sel.CurrentWorkNodeId)
    if ($sel.TaskNode) {
        Write-Output ("Task                : {0} ({1})  status={2} phase={3} prio={4} row={5}" -f $sel.TaskNodeId, $sel.TaskNode.Name, $sel.TaskNode.Status, $sel.TaskNode.Phase, $sel.TaskNode.Priority, $sel.TaskNode.Row)
    } else {
        Write-Output ("Task                : (none)")
    }
    Write-Output "Selection basis:"
    foreach ($b in $sel.SelectionBasis) { Write-Output ("  - {0}" -f $b) }
    if ($sel.TaskSelectionStatus -eq "TASK_SELECTION_AMBIGUOUS") {
        Write-Output ("Candidate Node IDs  : {0}" -f ($sel.CandidateIds -join ", "))
        Write-Output ("Reason              : {0}" -f $sel.AmbiguityReason)
    } else {
        Write-Output ("Candidates (ranked) : {0}" -f ($sel.Candidates -join " > "))
        # StrictMode-safe: only SELECTED shapes omit BlockState/BlockReason; block shapes carry both.
        $selHasBlock = $null -ne $sel.PSObject.Properties["BlockState"]
        if ($selHasBlock -and $sel.BlockState) {
            Write-Output ("BlockState          : {0}" -f $sel.BlockState)
            Write-Output ("BlockReason         : {0}" -f $sel.BlockReason)
        }
    }
}
