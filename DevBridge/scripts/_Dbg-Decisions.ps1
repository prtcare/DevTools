# _Dbg-Decisions.ps1 — diagnostic: which open decision flags blocking for the chain. Not a deliverable.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. "C:\Personal\DevTools\DevBridge\scripts\Test-DevelopmentPreflight.ps1"

$nodes = @(Get-AllRoadmapNodes)
$decisions = @(Get-OpenDecisions)
$chain = Get-AncestorChain (Get-Node "WI-07-0.2.3" $nodes) $nodes
$chainIds = @($chain | ForEach-Object { $_.NodeId })
Write-Output ("Chain: {0}" -f ($chainIds -join " | "))

foreach ($d in $decisions) {
    $needs = [string]$d.NeededBefore
    $links = [string]$d.RoadmapLinks
    $touches = @($chainIds | Where-Object { $needs -match [regex]::Escape($_) -or $links -match [regex]::Escape($_) })
    Write-Output ("DECISION {0} | status={1} | neededBefore='{2}' | links='{3}' | touches=[{4}]" -f $d.DecisionId, $d.Status, $needs, $links, ($touches -join ";"))
    Write-Output ("    question: {0}" -f $d.Question)
}
