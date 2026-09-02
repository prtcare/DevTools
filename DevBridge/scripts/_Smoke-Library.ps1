# _Smoke-Library.ps1 — diagnostic: verify Read-DevelopmentControl.ps1 loads and
# returns the expected governed universe. Not a milestone deliverable.
param(
    [string]$OutFile = "C:\Personal\DevTools\DevBridge\state\db-m03-smoke.txt"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Read-DevelopmentControl.ps1"

$sb = New-Object System.Text.StringBuilder
function Out-Line([string]$t) { [void]$sb.AppendLine($t) }

Out-Line "Workbook SHA256: $(Get-WorkbookSha256)"

$nodes = @(Get-AllRoadmapNodes)
Out-Line "Roadmap nodes loaded: $($nodes.Count)  (expected 659)"

# Status vocabulary distribution
$byStatus = $nodes | Group-Object Status | Sort-Object Count -Descending
Out-Line ""
Out-Line "=== Master Roadmap Status distribution ==="
foreach ($g in $byStatus) { Out-Line ("  {0,-28} {1}" -f $g.Name, $g.Count) }

# In-Progress / Active / Started nodes
$activeStatuses = @("In Progress", "Active", "Started", "Implemented - Verify")
Out-Line ""
Out-Line "=== Nodes with current-work statuses ==="
foreach ($n in ($nodes | Where-Object { $_.Status -in $activeStatuses })) {
    Out-Line ("  {0,-22} {1,-12} {2,-6} {3}  (row {4})" -f $n.NodeId, $n.NodeType, $n.Phase, $n.Name, $n.Row)
}

# Candidate nodes full rows
$candidates = @("F-12-0", "M-12-0.1", "M-12-0.2", "M-12-0.3", "M-12-0.4", "F-07-6", "M-07-6.1", "M-07-6.2", "M-07-6.3", "M-04-3.3", "WI-07-10.3.1", "M-07-5.3", "M-02-1.2")
Out-Line ""
Out-Line "=== Candidate node full rows (selected fields) ==="
foreach ($cid in $candidates) {
    $n = Get-RoadmapNodeById $cid
    if (-not $n) { Out-Line "  $cid : NOT FOUND"; continue }
    Out-Line "  --- $cid ($($n.Name)) row=$($n.Row) type=$($n.NodeType) ---"
    Out-Line "      Phase=$($n.Phase) Layer=$($n.Layer) Status=$($n.Status) Priority=$($n.Priority) Risk=$($n.Risk) ParallelSafe=$($n.ParallelSafe) Gate=$($n.Gate)"
    Out-Line "      Parent=$($n.ParentId) SortKey=$($n.SortKey) Breakdown=$($n.BreakdownComplete) Progress=$($n.ReportedProgress)"
    Out-Line "      Deps: $($n.Dependencies)"
    if ($n.FilesGlobs) { Out-Line "      Files: $($n.FilesGlobs)" }
    if ($n.Projects) { Out-Line "      Projects: $($n.Projects)" }
    if ($n.SchemaContexts) { Out-Line "      Schema: $($n.SchemaContexts)" }
    if ($n.ContractsApis) { Out-Line "      Contracts: $($n.ContractsApis)" }
    if ($n.NextAction) { Out-Line "      NextAction: $($n.NextAction)" }
    if ($n.CurrentEvidence) { Out-Line "      Evidence: $($n.CurrentEvidence)" }
    if ($n.SimpleGoal) { Out-Line "      SimpleGoal: $($n.SimpleGoal)" }
    if ($n.AcceptanceCriteria) { Out-Line "      AC: $($n.AcceptanceCriteria)" }
    if ($n.Notes) { Out-Line "      Notes: $($n.Notes)" }
}

# Active changes classification
Out-Line ""
Out-Line "=== Active Changes ==="
$ac = @(Get-AllActiveChanges)
$byCls = $ac | Group-Object Classification | Sort-Object Name
foreach ($g in $byCls) { Out-Line ("  {0}: {1}" -f $g.Name, $g.Count) }
Out-Line "  total rows: $($ac.Count)"

# Dependency relations
Out-Line ""
Out-Line "=== Dependencies & Blockers ==="
foreach ($d in @(Get-DependencyRelations)) {
    Out-Line ("  {0} | from={1} | depsOn={2} | type={3} | blocking={4} | status={5}" -f $d.RelationId, $d.FromNode, $d.DependsOnBlocks, $d.RelationType, $d.Blocking, $d.Status)
}

# ADRs / Open Decisions / Audit / Phase Plan
Out-Line ""
Out-Line "=== Approved ADRs ==="
foreach ($a in @(Get-ApprovedAdrs)) { Out-Line ("  {0} | {1} | links={2}" -f $a.AdrId, $a.Status, $a.RoadmapLinks) }
Out-Line "=== Open Decisions ==="
foreach ($d in @(Get-OpenDecisions)) { Out-Line ("  {0} | {1} | links={2} | neededBefore={3}" -f $d.DecisionId, $d.Question, $d.RoadmapLinks, $d.NeededBefore) }
Out-Line "=== Audit Findings ==="
foreach ($f in @(Get-AllAuditFindings)) { Out-Line ("  {0} | {1} | {2} | link={3} | status={4} | due={5}" -f $f.FindingId, $f.Severity, $f.Area, $f.RoadmapLink, $f.Status, $f.DueGate) }
Out-Line "=== Phase Plan ==="
foreach ($p in @(Get-PhasePlan)) { Out-Line ("  {0} | {1} | link={2} | status={3} | depsOn={4}" -f $p.PhaseStep, $p.Objective, $p.RoadmapLink, $p.Status, $p.DependsOn) }
Out-Line "=== Dev Guide ==="
foreach ($g in @(Get-DevGuide)) { if ($g.Status -ne "Complete" -and $g.Status -ne "Completed") { Out-Line ("  {0} | {1} | status={2} | next={3} | deps={4}" -f $g.MilestoneId, $g.Milestone, $g.Status, $g.NextStep, $g.DependsOn) } }

[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "Wrote $OutFile"
