# _Probe-DBM06-Part1.ps1 - DB-M06 Part 1 governance revalidation, READ-ONLY.
# Re-reads the authoritative workbook freshly and verifies the reservation,
# node identity, scope, dependencies, conflicts, and blocking findings for
# WI-07-0.2.3 / CHG-20260830-016. Never writes to the workbook.
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Read-DevelopmentControl.ps1"

$expectedHash = "F52A1A8FE491B6C91809EAC92DB2F0DCCD43FF7C5C80BA2618E19B64D3FDD4F7"
$actualHash = Get-WorkbookSha256
Write-Output ("WORKBOOK SHA256: {0}" -f $actualHash)
Write-Output ("  matches reservation/current-task (F52A1A8F...): {0}" -f ($actualHash -eq $expectedHash))
Write-Output ""

# ---- 1. Active Changes: locate CHG-20260830-016 ----
$allChanges = @(Get-AllActiveChanges)
$target = @($allChanges | Where-Object { $_.ChangeId -eq "CHG-20260830-016" })
Write-Output "=== ACTIVE CHANGES: CHG-20260830-016 ==="
Write-Output ("  occurrences in Active Changes: {0}" -f $target.Count)
foreach ($c in $target) {
    Write-Output ("  row={0} status='{1}' classification={2} node='{3}' worker='{4}' verdict='{5}'" -f $c.Row, $c.Status, $c.Classification, $c.NodeId, $c.Worker, $c.PreflightVerdict)
    Write-Output ("  repos='{0}' projects='{1}' files='{2}' contracts='{3}'" -f $c.Repositories, $c.Projects, $c.FilesGlobs, $c.ContractsApis)
    Write-Output ("  affected='{0}'" -f $c.AffectedNodes)
    Write-Output ("  summary='{0}'" -f $c.Summary)
}
Write-Output ""

# ---- 2. Open reservations naming WI-07-0.2.3 (conflict check) ----
$open = @(Get-ActiveChangesOpen)
Write-Output ("=== OPEN (non-terminal) RESERVATIONS: {0} ===" -f $open.Count)
$naming = @($open | Where-Object { $_.NodeId -match "WI-07-0.2.3" -or $_.AffectedNodes -match "WI-07-0.2.3" })
Write-Output ("  open reservations naming WI-07-0.2.3: {0}" -f $naming.Count)
foreach ($c in $naming) { Write-Output ("    {0} row={1} status='{2}'" -f $c.ChangeId, $c.Row, $c.Status) }
Write-Output ""

# ---- 3. Master Roadmap row 327 (WI-07-0.2.3) ----
$node = Get-RoadmapNodeById "WI-07-0.2.3"
Write-Output "=== MASTER ROADMAP: WI-07-0.2.3 ==="
if ($node) {
    Write-Output ("  row={0} type={1} parent='{2}' status='{3}' phase={4} layer={5}" -f $node.Row, $node.NodeType, $node.ParentId, $node.Status, $node.Phase, $node.Layer)
    Write-Output ("  name='{0}'" -f $node.Name)
    Write-Output ("  goal='{0}'" -f $node.SimpleGoal)
    Write-Output ("  deps='{0}'" -f $node.Dependencies)
    Write-Output ("  projects='{0}' files='{1}'" -f $node.Projects, $node.FilesGlobs)
    Write-Output ("  gate='{0}' priority='{1}' risk='{2}'" -f $node.Gate, $node.Priority, $node.Risk)
    Write-Output ("  nextAction='{0}'" -f $node.NextAction)
} else {
    Write-Output "  NOT FOUND"
}
Write-Output ""

# ---- 4. Dependency WI-07-0.2.2 status ----
$dep = Get-RoadmapNodeById "WI-07-0.2.2"
Write-Output "=== DEPENDENCY: WI-07-0.2.2 ==="
if ($dep) {
    Write-Output ("  row={0} status='{1}' name='{2}'" -f $dep.Row, $dep.Status, $dep.Name)
} else {
    Write-Output "  NOT FOUND"
}
Write-Output ""

# ---- 5. Parent milestone M-07-0.2 status ----
$m = Get-RoadmapNodeById "M-07-0.2"
Write-Output "=== PARENT MILESTONE: M-07-0.2 ==="
if ($m) {
    Write-Output ("  row={0} status='{1}' progress manual='{2}' derived='{3}'" -f $m.Row, $m.Status, $m.ManualProgress, $m.DerivedProgress)
} else {
    Write-Output "  NOT FOUND"
}
Write-Output ""

# ---- 6. Audit findings: blocking/constrains classification ----
$findings = @(Get-AllAuditFindings)
Write-Output "=== AUDIT FINDINGS relevant to WI-07-0.2.3 ==="
$relevant = @($findings | Where-Object { $_.FindingId -eq "AF-010" -or $_.FindingId -eq "AF-011" -or $_.FindingId -eq "AF-012" -or $_.FindingId -eq "AF-018" })
foreach ($f in $relevant) {
    Write-Output ("  {0} [{1}] status='{2}' roadmap='{3}'" -f $f.FindingId, $f.Severity, $f.Status, $f.RoadmapLink)
}
$blocking = @($findings | Where-Object { $_.Status -match "Blocking|Open" -and $_.RoadmapLink -match "WI-07-0.2.3" })
Write-Output ("  findings whose Roadmap Link names WI-07-0.2.3: {0}" -f $blocking.Count)
Write-Output ""

# ---- 7. Dependencies & Blockers referencing the chain ----
$rels = @(Get-DependencyRelations)
$chainRels = @($rels | Where-Object { $_.FromNode -match "WI-07-0.2.3|M-07-0.2|F-07-0" -or $_.DependsOnBlocks -match "WI-07-0.2.3|M-07-0.2|F-07-0" })
Write-Output ("=== DEPENDENCIES & BLOCKERS rows referencing chain: {0} ===" -f $chainRels.Count)
foreach ($r in $chainRels) {
    Write-Output ("  {0}: {1} {2} {3} (blocking={4} status='{5}')" -f $r.RelationId, $r.FromNode, $r.RelationType, $r.DependsOnBlocks, $r.Blocking, $r.Status)
}

Write-Output "=== DONE ==="
