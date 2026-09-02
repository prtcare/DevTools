# _Probe-AssetsTools.ps1 — diagnostic: Existing Assets + Tool & Integration registry. Not a deliverable.
param(
    [string]$OutFile = "C:\Personal\DevTools\DevBridge\state\db-m03-assets-tools.txt"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Read-DevelopmentControl.ps1"

$sb = New-Object System.Text.StringBuilder
function Out-Line([string]$t) { [void]$sb.AppendLine($t) }

Out-Line "=== Existing Assets ==="
foreach ($a in @(Get-ExistingAssets)) {
    Out-Line "  --- $($a.Area) | state=$($a.State) | row=$($a.Row)"
    if ($a.RepositoryFiles) { Out-Line ("      repo/files: {0}" -f $a.RepositoryFiles) }
    if ($a.WhatAlreadyExists) { Out-Line ("      exists: {0}" -f $a.WhatAlreadyExists) }
    if ($a.WhatIsStillMissing) { Out-Line ("      missing: {0}" -f $a.WhatIsStillMissing) }
    if ($a.RoadmapMeaning) { Out-Line ("      roadmap: {0}" -f $a.RoadmapMeaning) }
}

Out-Line ""
Out-Line "=== Tool & Integration Registry ==="
foreach ($t in @(Get-ToolRegistry)) {
    Out-Line ("  {0} | {1} | layer={2} | state={3} | phase1={4} | approval={5}" -f $t.Tool, $t.Category, $t.OwningLayer, $t.CurrentState, $t.Phase1Need, $t.ApprovalSafety)
}

[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "Wrote $OutFile"
