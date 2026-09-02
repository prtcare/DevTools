# _Probe-DBM05-ParentChain.ps1 - verify the roadmap parent chain for the handoff line
# READ-ONLY diagnostic.
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Read-DevelopmentControl.ps1"
foreach ($id in @("WI-07-0.2.3","M-07-0.2","F-07-0","07")) {
    $n = Get-RoadmapNodeById $id
    if ($n) {
        Write-Output ("{0} | row {1} | type [{2}] | name [{3}] | parentId [{4}] | hierarchy [{5}]" -f $id, $n.Row, $n.NodeType, $n.Name, $n.ParentId, $n.HierarchyPath)
    } else { Write-Output ("{0} | NOT FOUND" -f $id) }
}
