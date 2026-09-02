# _Dbg-ReadPreflight.ps1 — diagnostic: print verdict + conflict checks. Not a deliverable.
$ErrorActionPreference = "Stop"
$j = Get-Content "C:\Personal\DevTools\DevBridge\state\preflight.json" -Raw | ConvertFrom-Json
Write-Output ("VERDICT: {0}" -f $j.verdict)
Write-Output "--- blockingReasons ---"
foreach ($b in $j.blockingReasons) { Write-Output ("  - {0}" -f $b) }
Write-Output "--- activeChangeConflicts ---"
foreach ($c in $j.activeChangeConflicts) {
    if ($c.status -ne "PASS") { Write-Output ("  [{0}] {1} :: {2}" -f $c.status, $c.check, $c.detail) }
}
Write-Output "--- scope ---"
Write-Output ("  repos: {0}" -f ($j.repositories -join "; "))
Write-Output ("  projects: {0}" -f ($j.projects -join "; "))
Write-Output ("  filesGlobs: {0}" -f ($j.filesGlobs -join "; "))
Write-Output ("  contracts: {0}" -f ($j.contractsApis -join "; "))
Write-Output ("  affectedNodes: {0}" -f ($j.affectedNodes -join "; "))
Write-Output ("  scopeComplete-implied: {0}" -f ([bool]($j.repositories.Count -gt 0 -and $j.projects.Count -gt 0)))
