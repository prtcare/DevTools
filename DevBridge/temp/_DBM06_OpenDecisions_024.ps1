$ErrorActionPreference = "Stop"
. "C:\Personal\DevTools\DevBridge\scripts\Read-DevelopmentControl.ps1"
$od = @(Get-OpenDecisions)
Write-Output ("OPEN decisions: {0}" -f $od.Count)
foreach ($d in $od) {
    Write-Output ("  {0} | {1}" -f ($d.PSObject.Properties | ForEach-Object { $_.Name } | Select-Object -First 6) -join ',', '')
    $ps = $d.PSObject.Properties
    $line = ""
    foreach ($p in $ps) { $line += $p.Name + "='" + [string]$p.Value + "'; " }
    Write-Output ("  " + $line)
}
