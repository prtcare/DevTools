# _Probe-ActiveChanges.ps1 — diagnostic: dump full scope columns of all non-terminal
# Active Changes reservations plus the F-12-0 subtree node list. Not a deliverable.
param(
    [string]$OutFile = "C:\Personal\DevTools\DevBridge\state\db-m03-activechanges.txt"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Read-DevelopmentControl.ps1"

$sb = New-Object System.Text.StringBuilder
function Out-Line([string]$t) { [void]$sb.AppendLine($t) }

Out-Line "=== NON-TERMINAL ACTIVE CHANGES (full scope columns) ==="
foreach ($c in @(Get-ActiveChangesOpen)) {
    Out-Line ("--- {0} | class={1} | node={2} | worker={3} | verdict={4} | status={5}" -f $c.ChangeId, $c.Classification, $c.NodeId, $c.Worker, $c.PreflightVerdict, $c.Status)
    if ($c.Repositories) { Out-Line ("    Repositories: {0}" -f $c.Repositories) }
    if ($c.Projects) { Out-Line ("    Projects: {0}" -f $c.Projects) }
    if ($c.FilesGlobs) { Out-Line ("    Files/Globs: {0}" -f $c.FilesGlobs) }
    if ($c.SchemaContexts) { Out-Line ("    Schema: {0}" -f $c.SchemaContexts) }
    if ($c.ContractsApis) { Out-Line ("    Contracts/APIs: {0}" -f $c.ContractsApis) }
    if ($c.ConflictsWith) { Out-Line ("    ConflictsWith: {0}" -f $c.ConflictsWith) }
    if ($c.DependencyOn) { Out-Line ("    DependencyOn: {0}" -f $c.DependencyOn) }
    if ($c.Branch) { Out-Line ("    Branch: {0}" -f $c.Branch) }
    if ($c.Worktree) { Out-Line ("    Worktree: {0}" -f $c.Worktree) }
    if ($c.AffectedNodes) { Out-Line ("    AffectedNodes: {0}" -f $c.AffectedNodes) }
    if ($c.AdrId) { Out-Line ("    ADR: {0}" -f $c.AdrId) }
    if ($c.Risk) { Out-Line ("    Risk: {0}" -f $c.Risk) }
    if ($c.StartedAt) { Out-Line ("    StartedAt: {0}" -f $c.StartedAt) }
    if ($c.LastHeartbeat) { Out-Line ("    Heartbeat: {0}" -f $c.LastHeartbeat) }
    if ($c.Notes) { Out-Line ("    Notes: {0}" -f $c.Notes) }
}

Out-Line ""
Out-Line "=== F-12-0 SUBTREE (nodes under Developer Chat) ==="
foreach ($n in @(Get-AllRoadmapNodes)) {
    if ($n.NodeId -eq "F-12-0" -or $n.NodeId -match "^M-12-0\.|^WI-12-0\.") {
        Out-Line ("  {0,-18} {1,-10} {2,-4} {3,-20} status={4} prio={5} row={6}" -f $n.NodeId, $n.NodeType, $n.Phase, $n.Name, $n.Status, $n.Priority, $n.Row)
    }
}

Out-Line ""
Out-Line "=== Nodes referenced by REL-006/007/008 (F-12-0 explicit deps) ==="
foreach ($mid in @("M-06-7.5", "M-07-6.3", "M-11-1.2")) {
    $n = Get-RoadmapNodeById $mid
    if ($n) { Out-Line ("  {0}: status={1} phase={2} layer={3} row={4}" -f $n.NodeId, $n.Status, $n.Phase, $n.Layer, $n.Row) }
    else { Out-Line "  $mid : NOT FOUND" }
}

[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "Wrote $OutFile"
