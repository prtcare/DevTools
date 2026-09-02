# _Probe-DBM05-Part1.ps1 — DB-M05 PART 1: fresh validation of CHG-20260830-016
# against the authoritative workbook. READ-ONLY. Diagnostic, not a deliverable.
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Read-DevelopmentControl.ps1"

$changeId = "CHG-20260830-016"
$nodeId = "WI-07-0.2.3"

Write-Output "===== WORKBOOK HASH ====="
Write-Output ("  sha256 = " + (Get-WorkbookSha256))

Write-Output "===== 1. RESERVATION EXISTENCE / UNIQUENESS ====="
$ac = @(Get-AllActiveChanges | Where-Object { $_.ChangeId -eq $changeId })
Write-Output ("  count = " + $ac.Count)
if ($ac.Count -eq 1) {
    $r = $ac[0]
    Write-Output ("  row = {0} | nodeId = [{1}] | status = [{2}] | preflight = [{3}]" -f $r.Row, $r.NodeId, $r.Status, $r.PreflightVerdict)
    Write-Output ("  repositories = [{0}]" -f $r.Repositories)
    Write-Output ("  projects = [{0}]" -f $r.Projects)
    Write-Output ("  filesGlobs = [{0}]" -f $r.FilesGlobs)
    Write-Output ("  schemaContexts = [{0}]" -f $r.SchemaContexts)
    Write-Output ("  contractsApis = [{0}]" -f $r.ContractsApis)
    Write-Output ("  affectedNodes = [{0}]" -f $r.AffectedNodes)
    Write-Output ("  risk = [{0}]" -f $r.Risk)
    Write-Output ("  summary = [{0}]" -f $r.Summary)
    Write-Output ("  branch = [{0}]" -f $r.Branch)
    Write-Output ("  startedAt = [{0}]" -f $r.StartedAt)
}

Write-Output "===== 2. ROADMAP NODE WI-07-0.2.3 (LIVE) ====="
$node = Get-RoadmapNodeById $nodeId
if ($node) {
    Write-Output ("  row = {0} | type = {1} | layer = {2} | phase = {3} | name = [{4}]" -f $node.Row, $node.NodeType, $node.Layer, $node.Phase, $node.Name)
    Write-Output ("  parent = [{0}] | hierarchy = [{1}] | sortKey = [{2}]" -f $node.ParentId, $node.HierarchyPath, $node.SortKey)
    Write-Output ("  gate = [{0}] | status = [{1}] | priority = [{2}] | risk = [{3}] | parallelSafe = [{4}]" -f $node.Gate, $node.Status, $node.Priority, $node.Risk, $node.ParallelSafe)
    Write-Output ("  projects = [{0}]" -f $node.Projects)
    Write-Output ("  filesGlobs = [{0}]" -f $node.FilesGlobs)
    Write-Output ("  schemaContexts = [{0}]" -f $node.SchemaContexts)
    Write-Output ("  contractsApis = [{0}]" -f $node.ContractsApis)
    Write-Output ("  dependencies = [{0}]" -f $node.Dependencies)
    Write-Output ("  simpleGoal = [{0}]" -f $node.SimpleGoal)
    Write-Output ("  outcomePurpose = [{0}]" -f $node.OutcomePurpose)
    Write-Output ("  currentEvidence = [{0}]" -f $node.CurrentEvidence)
    Write-Output ("  nextAction = [{0}]" -f $node.NextAction)
    Write-Output ("  owner = [{0}] | source = [{1}] | breakdown = [{2}]" -f $node.Owner, $node.Source, $node.BreakdownComplete)
    Write-Output "  ACCEPTANCE CRITERIA:"
    Write-Output ("    " + $node.AcceptanceCriteria)
    Write-Output "  NOTES:"
    Write-Output ("    " + $node.Notes)
}

Write-Output "===== 3. PARENT CHAIN ====="
foreach ($pid_ in @("M-07-0.2", "F-07-0")) {
    $p = Get-RoadmapNodeById $pid_
    if ($p) {
        Write-Output ("  {0} | row {1} | {2} | status [{3}] | name [{4}] | outcome [{5}]" -f $p.NodeId, $p.Row, $p.NodeType, $p.Status, $p.Name, $p.OutcomePurpose)
    } else { Write-Output ("  {0} NOT FOUND" -f $pid_) }
}

Write-Output "===== 4. OPEN ACTIVE CHANGES (CONFLICT SCAN) ====="
$open = @(Get-ActiveChangesOpen)
Write-Output ("  open count = " + $open.Count)
foreach ($o in $open) {
    $nodeMatch = $o.NodeId -eq $nodeId
    $affectMatch = $o.AffectedNodes -and ($o.AffectedNodes -match $nodeId)
    $overlap = $o.FilesGlobs -and ($o.FilesGlobs -match "DevelopmentControl")
    $flag = ""
    if ($nodeMatch -or $affectMatch) { $flag = " <== TARGET NODE MATCH" }
    elseif ($overlap) { $flag = " <== FILES OVERLAP" }
    Write-Output ("  {0} | row {1} | node [{2}] | status [{3}]{4}" -f $o.ChangeId, $o.Row, $o.NodeId, $o.Status, $flag)
}

Write-Output "===== 5. DEPENDENCIES ====="
foreach ($d in @(Get-DependencyRelations)) {
    if ($d.FromNode -eq $nodeId -or $d.DependsOnBlocks -eq $nodeId) {
        Write-Output ("  {0} | from [{1}] | dependsOnBlocks [{2}] | type [{3}] | blocking [{4}] | status [{5}] | reason [{6}]" -f $d.RelationId, $d.FromNode, $d.DependsOnBlocks, $d.RelationType, $d.Blocking, $d.Status, $d.ReasonCondition)
    }
}
Write-Output "  (roadmap textual dependency: WI-07-0.2.3 depends on WI-07-0.2.2)"
$dep = Get-RoadmapNodeById "WI-07-0.2.2"
if ($dep) { Write-Output ("  WI-07-0.2.2 status = [{0}]" -f $dep.Status) }

Write-Output "===== 6. ADRs ====="
foreach ($a in @(Get-AllAdrs)) {
    $links = [string]$a.RoadmapLinks
    $relevant = $links -match "07" -or $links -match $nodeId -or $a.AdrId -eq "ADR-003"
    if ($relevant) {
        Write-Output ("  {0} | status [{1}] | links [{2}]" -f $a.AdrId, $a.Status, $a.RoadmapLinks)
        Write-Output ("    decision: {0}" -f $a.Decision)
        Write-Output ("    consequence: {0}" -f $a.Consequences)
    }
}

Write-Output "===== 7. OPEN DECISIONS ====="
foreach ($d in @(Get-OpenDecisions)) {
    $relevant = [string]$d.RoadmapLinks -match "07" -or $d.DecisionId -in @("DEC-001","DEC-002","DEC-003")
    if ($relevant) {
        Write-Output ("  {0} | area [{1}] | neededBefore [{2}] | links [{3}] | question [{4}]" -f $d.DecisionId, $d.Area, $d.NeededBefore, $d.RoadmapLinks, $d.Question)
    }
}

Write-Output "===== 8. AUDIT FINDINGS (07 area) ====="
foreach ($f in @(Get-AllAuditFindings)) {
    $link = [string]$f.RoadmapLink
    if ($link -match "07" -or $f.FindingId -in @("AF-010","AF-012","AF-018")) {
        Write-Output ("  {0} | [{1}] | status [{2}] | dueGate [{3}] | link [{4}] | action [{5}]" -f $f.FindingId, $f.Severity, $f.Status, $f.DueGate, $f.RoadmapLink, $f.RequiredAction)
    }
}

Write-Output "===== 9. EXISTING ASSETS (07 area) ====="
foreach ($e in @(Get-ExistingAssets)) {
    if ($e.Area -match "Development|Developer|Excel|Workbook|ClosedXML|Store|Adapter") {
        Write-Output ("  {0} | state [{1}] | exists [{2}] | repo/files [{3}] | missing [{4}]" -f $e.Area, $e.State, $e.WhatAlreadyExists, $e.RepositoryFiles, $e.WhatIsStillMissing)
    }
}

Write-Output "===== 10. TOOL REGISTRY — ClosedXML present? ====="
$found = $false
foreach ($t in @(Get-ToolRegistry)) {
    if ($t.Tool -match "ClosedXML|OpenXML|Excel") {
        Write-Output ("  {0} | category [{1}] | state [{2}] | phase1 [{3}]" -f $t.Tool, $t.Category, $t.CurrentState, $t.Phase1Need)
        $found = $true
    }
}
if (-not $found) { Write-Output "  ClosedXML / OpenXML / Excel NOT present in Tool & Integration Registry (confirms TOOL_REGISTRY_REVIEW pending item)" }

Write-Output "===== 11. PHASE PLAN (P0 / 07 context) ====="
foreach ($p in @(Get-PhasePlan)) {
    $link = [string]$p.RoadmapLink
    if ($link -match "07" -or $p.Status -eq "In Progress") {
        Write-Output ("  {0} | layer [{1}] | link [{2}] | status [{3}] | objective [{4}]" -f $p.PhaseStep, $p.LayerArea, $p.RoadmapLink, $p.Status, $p.Objective)
    }
}

Write-Output "===== 12. DEVELOPMENT GUIDE (M-07-0.2) ====="
foreach ($g in @(Get-DevGuide)) {
    if ($g.MilestoneId -eq "M-07-0.2") {
        Write-Output ("  {0} | {1} | status [{2}] | progress [{3}] | plain [{4}] | next [{5}] | gate [{6}]" -f $g.MilestoneId, $g.Milestone, $g.Status, $g.ProgressPct, $g.InPlainWords, $g.NextStep, $g.Gate)
    }
}
