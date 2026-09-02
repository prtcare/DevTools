# DB-M05 ground-truth probe - dump live workbook + state facts needed for handoff prose
$ErrorActionPreference = 'Stop'
$root = 'C:\Personal\DevTools\DevBridge'
Set-Location $root
. .\scripts\Read-DevelopmentControl.ps1

Write-Output "=== WORKBOOK HASH ==="
Write-Output ('hash=' + (Get-WorkbookSha256))
Write-Output ('expected=93D2620D919789D9C7199C417FF3A9FD5B09DA0464F0D3800DB0748E62772372 (DB-M04 post-write)')

Write-Output ""
Write-Output "=== ACTIVE CHANGES CHAIN (WI-07-0.2.x) ==="
foreach ($ac in @(Get-AllActiveChanges | Where-Object { ([string]$_.NodeId) -match 'WI-07-0\.2' } | Sort-Object ChangeId)) {
    Write-Output ('{0} | row {1} | {2} | status={3} | cls={4} | summary={5}' -f $ac.ChangeId, $ac.Row, $ac.NodeId, $ac.Status, $ac.Classification, $ac.Summary)
    Write-Output ('    repo={0} proj={1} glob={2} contract={3} affected={4} depOn={5}' -f $ac.Repositories, $ac.Projects, $ac.FilesGlobs, $ac.ContractsApis, $ac.AffectedNodes, $ac.DependencyOn)
    Write-Output ('    risk={0} preflight={1} branch={2}' -f $ac.Risk, $ac.PreflightVerdict, $ac.Branch)
}

Write-Output ""
Write-Output "=== ACTIVE CHANGES row 80 (CHG-20260830-017) FULL ==="
$row80 = @(Get-AllActiveChanges | Where-Object { $_.ChangeId -eq 'CHG-20260830-017' })
if ($row80.Count -eq 1) {
    $map = Get-Content (Join-Path $root 'config\development-control-map.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $ac = $map.sheets | Where-Object { $_.name -eq 'Active Changes' } | Select-Object -First 1
    $rows = Get-SheetRows 'Active Changes' ([int]$ac.headerRow) ([int]$ac.dataStartRow) 100
    $r80 = @($rows | Where-Object { $_.Row -eq $row80[0].Row })[0]
    Write-Output ('rows-with-CHG-017: ' + $row80.Count + '  live-row-number: ' + $r80.Row)
    foreach ($c in ($r80.Columns.Keys | Sort-Object { if ($_.Length -lt 3) { 'A' + $_.PadLeft(2,' ') } else { $_ } })) {
        $v = $r80.Values[$c]
        if ($v) { Write-Output ('  ' + $c + ' = ' + $v) }
    }
} else { Write-Output ('CHG-017 count != 1: ' + $row80.Count) }

Write-Output ""
Write-Output "=== ROADMAP 0.2.x CHAIN ==="
foreach ($id in @('F-07-0','M-07-0.2','WI-07-0.2.1','WI-07-0.2.2','WI-07-0.2.3','WI-07-0.2.4','WI-07-0.2.5','WI-07-0.2.6','WI-07-0.2.7','WI-07-0.2.8','WI-07-0.2.9','WI-07-0.2.10')) {
    $n = Get-RoadmapNodeById $id
    if (-not $n) { Write-Output ('MISSING: ' + $id); continue }
    Write-Output ('--- ' + $id + ' (row ' + $n.Row + ', ' + $n.NodeType + ') ' + $n.Name)
    Write-Output ('  status=' + $n.Status + ' | next=' + $n.NextAction + ' | progress manual=' + $n.ManualProgress + ' derived=' + $n.DerivedProgress + ' reported=' + $n.ReportedProgress)
    Write-Output ('  parent=' + $n.ParentId + ' | layer=' + $n.Layer + ' | phase=' + $n.Phase + ' | gate=' + $n.Gate)
    Write-Output ('  deps=' + $n.Dependencies)
    Write-Output ('  projects=' + $n.Projects)
    Write-Output ('  files=' + $n.FilesGlobs)
    Write-Output ('  contracts=' + $n.ContractsApis)
    Write-Output ('  risk=' + $n.Risk + ' | parallelSafe=' + $n.ParallelSafe)
    Write-Output ('  outcome=' + $n.OutcomePurpose)
    Write-Output ('  notes=' + $n.Notes)
    Write-Output ('  acceptance=' + $n.AcceptanceCriteria)
    Write-Output ('  currentEvidence=' + $n.CurrentEvidence)
}

Write-Output ""
Write-Output "=== D&B RELATIONS referencing 0.2.x ==="
$db = @(Get-DependencyRelations | Where-Object { ([string]$_.FromNode) -match 'WI-07-0\.2|M-07-0\.2' -or ([string]$_.DependsOnBlocks) -match 'WI-07-0\.2|M-07-0\.2' })
if ($db.Count -eq 0) { Write-Output '(none reference the 0.2.x chain)' }
foreach ($r in $db) {
    Write-Output ('{0} | {1} -> {2} | type={3} | blocking={4} | status={5} | reason={6}' -f $r.RelationId, $r.FromNode, $r.DependsOnBlocks, $r.RelationType, $r.Blocking, $r.Status, $r.ReasonCondition)
}

Write-Output ""
Write-Output "=== OPEN DECISIONS (all, live) ==="
foreach ($d in @(Get-AllOpenDecisions)) {
    Write-Output ('{0} | status={1} | neededBefore={2} | links={3} | q={4}' -f $d.DecisionId, $d.Status, $d.NeededBefore, $d.RoadmapLinks, $d.Question)
}

Write-Output ""
Write-Output "=== AUDIT FINDINGS linking M-07 ==="
foreach ($f in @(Get-AllAuditFindings | Where-Object { [string]$_.RoadmapLink -match 'M-07' })) {
    Write-Output ('{0} | sev={1} | status={2} | link={3} | area={4}' -f $f.FindingId, $f.Severity, $f.Status, $f.RoadmapLink, $f.Area)
}

Write-Output ""
Write-Output "=== AUDIT FINDINGS (all, for classification) ==="
foreach ($f in @(Get-AllAuditFindings)) {
    Write-Output ('{0} | sev={1} | status={2} | link={3} | area={4} | due={5}' -f $f.FindingId, $f.Severity, $f.Status, $f.RoadmapLink, $f.Area, $f.DueGate)
}

Write-Output ""
Write-Output "=== EXISTING ASSETS (all) ==="
foreach ($e in @(Get-ExistingAssets)) {
    Write-Output ('{0} | state={1} | exists={2} | repo={3} | meaning={4}' -f $e.Area, $e.State, $e.WhatAlreadyExists, $e.RepositoryFiles, $e.RoadmapMeaning)
    if ($e.WhatIsStillMissing) { Write-Output ('    stillMissing=' + $e.WhatIsStillMissing) }
}

Write-Output ""
Write-Output "=== TOOL & INTEGRATION REGISTRY (ClosedXML + workbook tools) ==="
foreach ($t in @(Get-ToolRegistry | Where-Object { [string]$_.Tool -match 'ClosedXML|Excel|Development Control|OpenXML' })) {
    Write-Output ('{0} | cat={1} | state={2} | layer={3} | purpose={4} | notes={5}' -f $t.Tool, $t.Category, $t.CurrentState, $t.OwningLayer, $t.PrimaryPurpose, $t.Notes)
}

Write-Output ""
Write-Output "=== M-07-0.2 PROGRESS (Development Guide row, mirror) ==="
foreach ($g in @(Get-DevGuide | Where-Object { [string]$_.MilestoneId -match 'M-07' })) {
    Write-Output ('{0} | {1} | progress={2} | status={3} | next={4}' -f $g.MilestoneId, $g.Milestone, $g.ProgressPct, $g.Status, $g.NextStep)
}

Write-Output ""
Write-Output "PROBE DONE"
