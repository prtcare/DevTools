# DB-M06 fresh governance read for WI-07-0.2.4 / CHG-20260830-017 (READ-ONLY).
$ErrorActionPreference = "Stop"
. "C:\Personal\DevTools\DevBridge\scripts\Read-DevelopmentControl.ps1"

$hash = Get-WorkbookSha256
Write-Output ("WORKBOOK SHA256: {0}" -f $hash)

# --- Master Roadmap: WI-07-0.2.4 ---
$node = Get-RoadmapNodeById "WI-07-0.2.4"
Write-Output ("=== MR WI-07-0.2.4 row={0} ===" -f $node.Row)
Write-Output ("  status='{0}' name='{1}' layer='{2}' phase='{3}'" -f $node.Status, $node.Name, $node.Layer, $node.Phase)
Write-Output ("  dependency='{0}'" -f $node.Dependencies)

# --- Active Changes: CHG-20260830-017 occurrences ---
$all = @(Get-AllActiveChanges)
$tgt = @($all | Where-Object { $_.ChangeId -eq "CHG-20260830-017" })
Write-Output ("=== AC CHG-20260830-017 occurrences={0} ===" -f $tgt.Count)
foreach ($c in $tgt) {
    Write-Output ("  row={0} status='{1}' classification={2} node='{3}' worker='{4}' verdict='{5}'" -f $c.Row, $c.Status, $c.Classification, $c.NodeId, $c.Worker, $c.PreflightVerdict)
    Write-Output ("  repos='{0}'" -f $c.Repositories)
    Write-Output ("  projects='{0}'" -f $c.Projects)
    Write-Output ("  files='{0}'" -f $c.FilesGlobs)
    Write-Output ("  contracts='{0}'" -f $c.ContractsApis)
    Write-Output ("  affected='{0}'" -f $c.AffectedNodes)
    Write-Output ("  summary='{0}'" -f $c.Summary)
    Write-Output ("  dependencyOn='{0}'" -f $c.DependencyOn)
}

# --- open reservations naming WI-07-0.2.4 (conflict) ---
$open = @(Get-ActiveChangesOpen)
Write-Output ("=== OPEN reservations total={0} ===" -f $open.Count)
foreach ($o in $open) {
    Write-Output ("  {0} row={1} node='{2}' status='{3}'" -f $o.ChangeId, $o.Row, $o.NodeId, $o.Status)
}

# --- open decisions ---
$od = @(Get-OpenDecisions)
Write-Output ("=== OPEN decisions={0} ===" -f $od.Count)

# --- audit findings: open/blocking ---
$af = @(Get-AllAuditFindings)
Write-Output ("=== AUDIT FINDINGS total={0} ===" -f $af.Count)
foreach ($f in $af) {
    Write-Output ("  {0} severity='{1}' area='{2}' status='{3}'" -f $f.FindingId, $f.Severity, $f.Area, $f.Status)
}
