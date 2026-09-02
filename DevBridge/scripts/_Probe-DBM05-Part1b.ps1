# _Probe-DBM05-Part1b.ps1 - locate authoritative acceptance criteria for WI-07-0.2.3
# READ-ONLY. Diagnostic, not a deliverable.
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Read-DevelopmentControl.ps1"

Write-Output "===== VERSION HISTORY for WI-07-0.2.3 / M-07-0.2 / F-07-0 ====="
$vh = @(Get-SheetRows "Version History" 5 6 957)
$hdr = 5
foreach ($r in $vh) {
    $nid = Get-Value "Version History" $r $hdr "Node ID"
    if ($nid -in @("WI-07-0.2.3","M-07-0.2","F-07-0")) {
        Write-Output ("  row {0} | node [{1}] | ver [{2}] | isCurrent [{3}] | change [{4}] | status [{5}] | type [{6}] | effFrom [{7}]" -f $r.Row, $nid, (Get-Value "Version History" $r $hdr "Record Version"), (Get-Value "Version History" $r $hdr "Is Current"), (Get-Value "Version History" $r $hdr "Change ID"), (Get-Value "Version History" $r $hdr "Status"), (Get-Value "Version History" $r $hdr "Change Type"), (Get-Value "Version History" $r $hdr "Effective From"))
        $ac = Get-Value "Version History" $r $hdr "Acceptance Criteria"
        if ($ac) { Write-Output ("    ACCEPTANCE CRITERIA: " + $ac) }
        $cs = Get-Value "Version History" $r $hdr "Change Summary"
        if ($cs) { Write-Output ("    change summary: " + $cs) }
        $note = Get-Value "Version History" $r $hdr "Notes"
        if ($note) { Write-Output ("    notes: " + $note) }
    }
}

Write-Output ""
Write-Output "===== M-07-0.2 milestone row (324) ACCEPTANCE CRITERIA + all fields ====="
$m = Get-RoadmapNodeById "M-07-0.2"
if ($m) {
    Write-Output ("  gate [{0}] | status [{1}] | projects [{2}]" -f $m.Gate, $m.Status, $m.Projects)
    Write-Output ("  filesGlobs [{0}]" -f $m.FilesGlobs)
    Write-Output ("  schemaContexts [{0}]" -f $m.SchemaContexts)
    Write-Output ("  contractsApis [{0}]" -f $m.ContractsApis)
    Write-Output ("  acceptance criteria: [{0}]" -f $m.AcceptanceCriteria)
    Write-Output ("  notes: [{0}]" -f $m.Notes)
    Write-Output ("  simpleGoal: [{0}]" -f $m.SimpleGoal)
    Write-Output ("  nextAction: [{0}]" -f $m.NextAction)
    Write-Output ("  currentEvidence: [{0}]" -f $m.CurrentEvidence)
    Write-Output ("  dependencies: [{0}]" -f $m.Dependencies)
}

Write-Output ""
Write-Output "===== ALL WORK ITEMS under M-07-0.2 (WI-07-0.2.x) - AC column ====="
$nodes = @(Get-AllRoadmapNodes | Where-Object { $_.ParentId -eq "M-07-0.2" })
foreach ($n in $nodes) {
    $ac = [string]$n.AcceptanceCriteria
    $short = if ($ac) { $ac } else { "(EMPTY)" }
    if ($short.Length -gt 200) { $short = $short.Substring(0,200) + "..." }
    Write-Output ("  {0} | row {1} | name [{2}] | status [{3}] | AC: {4}" -f $n.NodeId, $n.Row, $n.Name, $n.Status, $short)
}

Write-Output ""
Write-Output "===== ACTIVE CHANGES referencing WI-07-0.2.3 (CHG-20260830-006, 014, 015, 016) - notes/summary ====="
foreach ($cid in @("CHG-20260830-006","CHG-20260830-014","CHG-20260830-015","CHG-20260830-016")) {
    $row = @(Get-AllActiveChanges | Where-Object { $_.ChangeId -eq $cid })
    if ($row.Count -gt 0) {
        $r = $row[0]
        Write-Output ("  {0} | summary: {1}" -f $cid, $r.Summary)
        if ($r.Notes) { Write-Output ("    notes: {0}" -f $r.Notes) }
    }
}

Write-Output ""
Write-Output "===== DEVELOPMENT GUIDE rows for 07 Developer / M-07 ====="
foreach ($g in @(Get-DevGuide)) {
    $name = [string]$g.Milestone
    if ($g.MilestoneId -like "M-07*" -or $name -match "Development Control") {
        Write-Output ("  {0} | {1} | status [{2}] | progress [{3}] | plain [{4}] | existsNow [{5}] | next [{6}] | gate [{7}]" -f $g.MilestoneId, $g.Milestone, $g.Status, $g.ProgressPct, $g.InPlainWords, $g.WhatExistsNow, $g.NextStep, $g.Gate)
    }
}

Write-Output ""
Write-Output "===== ROADMAP nodes with acceptance criteria mentioning ExcelDevelopmentControlStore or 0.2.3 ====="
foreach ($n in @(Get-AllRoadmapNodes)) {
    $ac = [string]$n.AcceptanceCriteria
    $out = [string]$n.OutcomePurpose
    if ($ac -match "ExcelDevelopmentControlStore|persistence adapter|0\.2\.3" -or $out -match "ExcelDevelopmentControlStore") {
        Write-Output ("  {0} | row {1} | AC: {2}" -f $n.NodeId, $n.Row, $ac)
    }
}
