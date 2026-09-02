# _Probe-DevControl.ps1 — diagnostic: F-07-0 / M-07-0.2 Development Control subtree
# and the freshest-reservation analysis. Not a deliverable.
param(
    [string]$OutFile = "C:\Personal\DevTools\DevBridge\state\db-m03-devcontrol.txt"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Read-DevelopmentControl.ps1"

$sb = New-Object System.Text.StringBuilder
function Out-Line([string]$t) { [void]$sb.AppendLine($t) }

Out-Line "=== F-07-0 / M-07-0.2 subtree ==="
foreach ($n in @(Get-AllRoadmapNodes)) {
    if ($n.NodeId -eq "F-07-0" -or $n.NodeId -eq "M-07-0.1" -or $n.NodeId -match "^M-07-0\.2" -or $n.NodeId -match "^WI-07-0\.2\." -or $n.NodeId -match "^T-07-0\.2\." -or $n.NodeId -match "^S-07-0\.2\.") {
        Out-Line ("  {0,-18} {1,-10} {2,-4} {3,-50} status={4} prio={5} prog={6} row={7}" -f $n.NodeId, $n.NodeType, $n.Phase, $n.Name, $n.Status, $n.Priority, $n.ReportedProgress, $n.Row)
        if ($n.Dependencies) { Out-Line ("      deps: {0}" -f $n.Dependencies) }
        if ($n.Projects) { Out-Line ("      projects: {0}" -f $n.Projects) }
        if ($n.FilesGlobs) { Out-Line ("      files: {0}" -f $n.FilesGlobs) }
        if ($n.SchemaContexts) { Out-Line ("      schema: {0}" -f $n.SchemaContexts) }
        if ($n.ContractsApis) { Out-Line ("      contracts: {0}" -f $n.ContractsApis) }
        if ($n.NextAction) { Out-Line ("      nextAction: {0}" -f $n.NextAction) }
        if ($n.AcceptanceCriteria) { Out-Line ("      ac: {0}" -f $n.AcceptanceCriteria) }
        if ($n.CurrentEvidence) { Out-Line ("      evidence: {0}" -f $n.CurrentEvidence) }
    }
}

Out-Line ""
Out-Line "=== Open reservations by row (freshest first) ==="
$ac = @(Get-ActiveChangesOpen)
$acSorted = $ac | Sort-Object Row -Descending
foreach ($c in $acSorted) {
    Out-Line ("  row={0} {1} node={2} worker={3}" -f $c.Row, $c.ChangeId, $c.NodeId, $c.Worker)
}

Out-Line ""
Out-Line "=== Any WI-07-0.2.3 row? ==="
$w = Get-RoadmapNodeById "WI-07-0.2.3"
if ($w) { Out-Line "  WI-07-0.2.3: row=$($w.Row) status=$($w.Status) name=$($w.Name) parent=$($w.ParentId)" }
else { Out-Line "  WI-07-0.2.3 NOT FOUND" }

[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "Wrote $OutFile"
