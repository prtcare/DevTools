# _Dbg-Chain.ps1 — diagnostic: raw ancestor chain. Not a deliverable.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. "C:\Personal\DevTools\DevBridge\scripts\Test-DevelopmentPreflight.ps1"

$nodes = @(Get-AllRoadmapNodes)
Write-Output ("total nodes: {0}" -f $nodes.Count)

$t = @($nodes | Where-Object { $_.NodeId -eq "WI-07-0.2.3" } | Select-Object -First 1)
Write-Output ("target: id={0} type={1} parent={2}" -f $t[0].NodeId, $t[0].NodeType, $t[0].ParentId)

foreach ($id in @("M-07-0.2","F-07-0")) {
    $n = @($nodes | Where-Object { $_.NodeId -eq $id } | Select-Object -First 1)
    if ($n.Count -eq 0) { Write-Output ("{0}: NOT FOUND" -f $id); continue }
    Write-Output ("{0}: id={1} type='{2}' parent='{3}'" -f $id, $n[0].NodeId, $n[0].NodeType, $n[0].ParentId)
}

$chain = Get-AncestorChain $t[0] $nodes
Write-Output ("chain count: {0}" -f $chain.Count)
for ($i = 0; $i -lt $chain.Count; $i++) {
    Write-Output ("  [{0}] id={1} type='{2}' parent='{3}'" -f $i, $chain[$i].NodeId, $chain[$i].NodeType, $chain[$i].ParentId)
}
