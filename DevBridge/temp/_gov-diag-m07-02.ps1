# READ-ONLY governance diagnosis probe for M-07-0.2 (Final Hardened Lane C).
# Replicates the engine's classification (Get-ImplementabilityClass /
# Resolve-ImplementableDescendant / Test-DepsSatisfied / trial-proving exclusion)
# against the authoritative workbook. Writes nothing to the workbook, Nexus
# source, or DevBridge lifecycle state — stdout only.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "C:\Personal\DevTools\DevBridge\scripts\Read-DevelopmentControl.ps1"

$nodes = @(Get-AllRoadmapNodes)
$allRes = @(Get-AllActiveChanges)
$openRes = @(Get-ActiveChangesOpen)
$phasePlan = @(Get-PhasePlan)
$rels = @(Get-DependencyRelations)
$adrs = @(Get-AllAdrs)
$openDec = @(Get-AllOpenDecisions)
$audit = @(Get-AllAuditFindings)
$assets = @(Get-ExistingAssets)
$guide = @(Get-DevGuide)

# Trial proving history (read-only)
$histPath = Join-Path $script:DevBridgeRoot "state\trial-proving-history.json"
$usedProving = New-Object 'System.Collections.Generic.HashSet[string]'
if (Test-Path $histPath) {
    $h = Get-Content $histPath -Raw | ConvertFrom-Json
    foreach ($e in @($h.entries)) { $nid = [string]$e.nodeId; if ($nid) { [void]$usedProving.Add($nid) } }
}

function Get-PriorityRank([string]$p) {
    $rank = @{ "Critical" = 6; "High" = 5; "Medium" = 4; "Low" = 3; "Backlog" = 2 }
    if ($rank.ContainsKey($p)) { return $rank[$p] }
    return 1
}
function Get-NodeSpecRank([string]$t) {
    $rank = @{ "Subtask" = 6; "Task" = 5; "WorkItem" = 4; "Milestone" = 3; "Feature" = 2; "Layer" = 1 }
    if ($rank.ContainsKey($t)) { return $rank[$t] }
    return 0
}
function Test-NodeId([string]$s) {
    return ($s -match "^(F|WI|M|T|S)-\d+-\d+(\.\d+)*$")
}
function Get-RelBlockedIds($rels) {
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
    if ($blocked -and $blocked.Contains($node.NodeId)) { return $false }
    $deps = [string]$node.Dependencies
    if (-not $deps) { return $true }
    foreach ($tok in ($deps -split "[|,;]")) {
        $depId = $tok.Trim()
        if (-not $depId) { continue }
        if (-not (Test-NodeId $depId)) { continue }
        $depNode = $nodes | Where-Object { $_.NodeId -eq $depId } | Select-Object -First 1
        if ($depNode -and $depNode.Status -notin @("Completed", "Complete")) { return $false }
    }
    return $true
}
function Get-ImplementabilityClass($node, $allNodes) {
    $nodeType = [string]$node.NodeType
    if (-not $nodeType) { return "UNKNOWN_NODE_TYPE" }
    $breakdown = [string]$node.BreakdownComplete
    $childCount = @($allNodes | Where-Object { $_.ParentId -eq $node.NodeId }).Count
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

# Reservation map by node
$resByNode = @{}
foreach ($r in $openRes) {
    foreach ($tok in ($r.NodeId -split "\|")) {
        $id = $tok.Trim()
        if (-not $id) { continue }
        if (-not $resByNode.ContainsKey($id)) { $resByNode[$id] = New-Object System.Collections.Generic.List[object] }
        $resByNode[$id].Add($r)
    }
}

$blocked = Get-RelBlockedIds $rels

# ---------------- STEP 1: anchor dump ----------------
$anchor = $nodes | Where-Object { $_.NodeId -eq "M-07-0.2" } | Select-Object -First 1
if (-not $anchor) { Write-Output "ANCHOR_NOT_FOUND"; exit 1 }
Write-Output "=== M-07-0.2 GOVERNANCE DIAGNOSIS ==="
Write-Output "anchor row            : $($anchor.Row)"
Write-Output "node type             : $($anchor.NodeType)"
Write-Output "parent node           : $($anchor.ParentId)"
$parent = $nodes | Where-Object { $_.NodeId -eq $anchor.ParentId } | Select-Object -First 1
if ($parent) { Write-Output "parent title          : $($parent.Name) (type=$($parent.NodeType), row=$($parent.Row))" }
Write-Output "phase                 : $($anchor.Phase)"
Write-Output "layer                 : $($anchor.Layer)"
Write-Output "name/title            : $($anchor.Name)"
Write-Output "outcome / purpose     : $($anchor.OutcomePurpose)"
Write-Output "status                : $($anchor.Status)"
Write-Output "sort key              : $($anchor.SortKey)"
Write-Output "hierarchy path        : $($anchor.HierarchyPath)"
Write-Output "dependencies          : $($anchor.Dependencies)"
Write-Output "priority              : $($anchor.Priority)"
Write-Output "gate                  : $($anchor.Gate)"
Write-Output "acceptance criteria   : $($anchor.AcceptanceCriteria)"
Write-Output "breakdown complete    : $($anchor.BreakdownComplete)"
Write-Output "projects              : $($anchor.Projects)"
Write-Output "files / globs         : $($anchor.FilesGlobs)"
Write-Output "schema contexts       : $($anchor.SchemaContexts)"
Write-Output "contracts / APIs      : $($anchor.ContractsApis)"
Write-Output "parallel safe         : $($anchor.ParallelSafe)"
Write-Output "risk                  : $($anchor.Risk)"
Write-Output "notes                 : $($anchor.Notes)"
Write-Output "next action (col)     : $($anchor.NextAction)"
Write-Output "current evidence      : $($anchor.CurrentEvidence)"
Write-Output "anchor class          : $(Get-ImplementabilityClass $anchor $nodes)"
Write-Output "deps satisfied (anch) : $(Test-DepsSatisfied $anchor $nodes $blocked)"
Write-Output "trial-proven (anch)   : $($usedProving.Contains($anchor.NodeId))"
Write-Output "open reservations     : $($resByNode.ContainsKey($anchor.NodeId))"
if ($resByNode.ContainsKey($anchor.NodeId)) {
    foreach ($r in $resByNode[$anchor.NodeId]) { Write-Output "  res $($r.ChangeId) row=$($r.Row) status=$($r.Status)" }
}

# ---------------- descendants ----------------
Write-Output ""
Write-Output "=== DESCENDANTS (recursive) ==="
$descSet = New-Object 'System.Collections.Generic.HashSet[string]'
$descList = New-Object System.Collections.Generic.List[object]
function Add-Desc([string]$parentNodeId) {
    $kids = @($nodes | Where-Object { $_.ParentId -eq $parentNodeId } | Sort-Object @{Expression="SortKey";Ascending=$true}, @{Expression="Row";Ascending=$true})
    foreach ($k in $kids) {
        if ($descSet.Contains($k.NodeId)) { continue }
        [void]$descSet.Add($k.NodeId)
        $descList.Add($k)
        Add-Desc $k.NodeId
    }
}
Add-Desc "M-07-0.2"
Write-Output "direct children of M-07-0.2 : $((@($nodes | Where-Object { $_.ParentId -eq 'M-07-0.2' })).Count)"
Write-Output "total descendant nodes       : $($descList.Count)"

# per-descendant classification
$implLeaves = 0
$eligible = 0
foreach ($n in $descList) {
    $cls = Get-ImplementabilityClass $n $nodes
    $depsOk = Test-DepsSatisfied $n $nodes $blocked
    $tp = $usedProving.Contains($n.NodeId)
    $term = $n.Status -in @("Completed", "Complete")
    $ac = [string]$n.AcceptanceCriteria
    $proj = [string]$n.Projects; $files = [string]$n.FilesGlobs
    $scope = "none"
    if ($cls -eq "IMPLEMENTABLE_LEAF") { $scope = "leaf" }
    # first blocking condition (mirrors Resolve-ImplementableDescendant ordering)
    $why = ""
    if ($term) { $why = "COMPLETED (terminal)" }
    elseif ($tp) { $why = "TRIAL_PROVING_ALREADY_USED" }
    elseif (-not $depsOk) { $why = "DEPENDENCY_BLOCKED" }
    elseif ($cls -eq "NON_IMPLEMENTABLE_CONTAINER") { $why = "NON_IMPLEMENTABLE_CONTAINER" }
    elseif ($cls -eq "INCOMPLETE_WORK_ITEM") { $why = "SCOPE_INCOMPLETE (BreakdownComplete=No)" }
    elseif ($cls -eq "UNKNOWN_NODE_TYPE") { $why = "IMPLEMENTATION_TARGET_UNKNOWN" }
    elseif ($cls -eq "IMPLEMENTABLE_LEAF") { $why = "ELIGIBLE"; $eligible++ ; $implLeaves++ }
    if ($cls -eq "IMPLEMENTABLE_LEAF") { $implLeaves++ }
    Write-Output ("-- {0} | type={1} | class={2} | status={3} | sort={4} | row={5} | deps='{6}' depsOk={7} | trialProven={8} | AC={9} | proj='{10}' files='{11}' | {12}" -f `
        $n.NodeId, $n.NodeType, $cls, $n.Status, $n.SortKey, $n.Row, $n.Dependencies, $depsOk, $tp, $ac, $proj, $files, $why)
}
Write-Output "implementable leaf descendants : $implLeaves"
Write-Output "eligible implementable leaves  : $eligible"

# ---------------- STEP 3: dependency / scope / trial breakdown ----------------
Write-Output ""
Write-Output "=== BLOCKER BREAKDOWN ==="
Write-Output "open+blocking D&B relations affecting M-07-0.2 subtree:"
$relevantRels = @($rels | Where-Object { ($_.FromNode -match "M-07-0.2") -or ($_.DependsOnBlocks -match "M-07-0.2") -or ($_.FromNode -in $descSet) -or (($_.DependsOnBlocks -split "[|,;]") | Where-Object { $_.Trim() -in $descSet }) })
foreach ($r in $relevantRels) { Write-Output "  $($r.RelationId) | $($r.FromNode) -> $($r.DependsOnBlocks) | type=$($r.RelationType) blocking=$($r.Blocking) status=$($r.Status) | $($r.ReasonCondition)" }
Write-Output "open reservations naming any descendant:"
foreach ($n in $descList) {
    if ($resByNode.ContainsKey($n.NodeId)) { foreach ($r in $resByNode[$n.NodeId]) { Write-Output "  $($n.NodeId) <- $($r.ChangeId) row=$($r.Row) status=$($r.Status)" } }
}
Write-Output "terminal (Completed/Complete) descendants count: $((@($descList | Where-Object { $_.Status -in @('Completed','Complete') })).Count)"
Write-Output "trial-proven descendants count: $((@($descList | Where-Object { $usedProving.Contains($_.NodeId) })).Count)"
Write-Output "dependency-blocked descendants count: $((@($descList | Where-Object { -not (Test-DepsSatisfied $_ $nodes $blocked) })).Count)"
Write-Output "non-leaf / incomplete / unknown descendants count: $((@($descList | Where-Object { (Get-ImplementabilityClass $_ $nodes) -in @('NON_IMPLEMENTABLE_CONTAINER','INCOMPLETE_WORK_ITEM','UNKNOWN_NODE_TYPE') })).Count)"

# ---------------- STEP 4: roadmap continuation ----------------
Write-Output ""
Write-Output "=== ROADMAP CONTINUATION ==="
$sibs = @($nodes | Where-Object { $_.ParentId -eq $anchor.ParentId } | Sort-Object @{Expression="SortKey";Ascending=$true}, @{Expression="Row";Ascending=$true})
Write-Output "siblings of M-07-0.2 (parent $($anchor.ParentId)):"
foreach ($s in $sibs) {
    $mark = if ($s.NodeId -eq "M-07-0.2") { "  <-- CURRENT" } else { "" }
    Write-Output ("  {0} | {1} | status={2} | sort={3} | row={4}{5}" -f $s.NodeId, $s.Name, $s.Status, $s.SortKey, $s.Row, $mark)
}
$idx = -1; for ($i=0; $i -lt $sibs.Count; $i++) { if ($sibs[$i].NodeId -eq "M-07-0.2") { $idx = $i; break } }
if ($idx -gt 0) { Write-Output "previous sibling      : $($sibs[$idx-1].NodeId) ($($sibs[$idx-1].Name)) status=$($sibs[$idx-1].Status)" }
if ($idx -ge 0 -and $idx -lt $sibs.Count-1) { Write-Output "next sibling          : $($sibs[$idx+1].NodeId) ($($sibs[$idx+1].Name)) status=$($sibs[$idx+1].Status)" }
Write-Output "phase plan links for layer 07 / M-07:"
foreach ($p in $phasePlan) {
    $link = [string]$p.RoadmapLink
    if ($link -match "07" -or $link -match "M-07") { Write-Output "  $($p.PhaseStep) | $($link) | status=$($p.Status) | $($p.Objective)" }
}
Write-Output "development guide rows for M-07-0.2 / layer 07:"
foreach ($g in $guide) {
    if ($g.MilestoneId -match "M-07" -or $g.Layer -eq "07") { Write-Output "  $($g.MilestoneId) | $($g.Milestone) | status=$($g.Status) | next=$($g.NextStep) | deps=$($g.DependsOn)" }
}

# ---------------- STEP 5/6: other governed targets & data gaps ----------------
Write-Output ""
Write-Output "=== OTHER GOVERNED TARGETS (context, not selection) ==="
$otherInProgress = @($nodes | Where-Object { $_.Status -in @("In Progress","Active","Started") -and $_.NodeId -ne "M-07-0.2" } | Sort-Object @{Expression="Row";Ascending=$true})
Write-Output "other In Progress / Active / Started roadmap nodes:"
foreach ($n in $otherInProgress) {
    $cls = Get-ImplementabilityClass $n $nodes
    $hasRes = $resByNode.ContainsKey($n.NodeId)
    Write-Output ("  {0} | {1} | type={2} class={3} | status={4} | sort={5} | row={6} | openRes={7}" -f $n.NodeId, $n.Name, $n.NodeType, $cls, $n.Status, $n.SortKey, $n.Row, $hasRes)
}
Write-Output "planned nodes (next-work universe), top by rank:"
$planned = @($nodes | Where-Object { $_.Status -eq "Planned" -and (Test-DepsSatisfied $_ $nodes $blocked) })
$plannedRanked = @($planned | ForEach-Object {
    $pp = 999
    foreach ($p in $phasePlan) {
        if ($p.Status -in @("Superseded","Completed","Complete")) { continue }
        if ([string]$p.RoadmapLink -match [regex]::Escape($_.NodeId)) { $pp = 0; break }
    }
    [PSCustomObject]@{ N=$_; Prio=(Get-PriorityRank $_.Priority); Spec=(Get-NodeSpecRank $_.NodeType); Sort=$_.SortKey; Row=$_.Row }
} | Sort-Object @{Expression="Prio";Descending=$true}, @{Expression="Spec";Descending=$true}, @{Expression="Sort";Ascending=$true}, @{Expression="Row";Ascending=$true})
$plannedRanked | Select-Object -First 10 | ForEach-Object {
    $cls = Get-ImplementabilityClass $_.N $nodes
    Write-Output ("  {0} | {1} | type={2} class={3} | prio={4} | sort={5} | row={6}" -f $_.N.NodeId, $_.N.Name, $_.N.NodeType, $cls, $_.N.Priority, $_.Sort, $_.Row)
}
Write-Output "open decisions referencing layer 07 / M-07 / Development Control:"
foreach ($d in $openDec) {
    if ($d.RoadmapLinks -match "07" -or $d.Area -match "07" -or $d.Question -match "Development Control") { Write-Output "  $($d.DecisionId) | $($d.Question) | area=$($d.Area) | status=$($d.Status) | links=$($d.RoadmapLinks)" }
}
Write-Output "approved ADRs referencing layer 07 / M-07:"
foreach ($a in $adrs) {
    if ($a.RoadmapLinks -match "07" -or $a.LayerOwner -match "07") { Write-Output "  $($a.AdrId) | $($a.Decision) | links=$($a.RoadmapLinks) | status=$($a.Status)" }
}
Write-Output "existing assets for Development Control area:"
foreach ($x in $assets) {
    if ($x.Area -match "Development Control" -or $x.WhatAlreadyExists -match "Development Control") { Write-Output "  $($x.Area) | $($x.WhatAlreadyExists) | missing=$($x.WhatIsStillMissing)" }
}
Write-Output ""
Write-Output "=== DIAGNOSIS COMPLETE (read-only) ==="
