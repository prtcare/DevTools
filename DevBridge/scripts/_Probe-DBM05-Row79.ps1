# _Probe-DBM05-Row79.ps1 - dump the EXACT raw cell strings for CHG-20260830-016 (row 79)
# READ-ONLY diagnostic. Needed to confirm scope-set comparison semantics.
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Read-DevelopmentControl.ps1"

$ac = @(Get-AllActiveChanges | Where-Object { $_.ChangeId -eq "CHG-20260830-016" })
if ($ac.Count -ne 1) { Write-Output ("COUNT=" + $ac.Count); exit 1 }
$r = $ac[0]
Write-Output "=== RAW CELL STRINGS (bracketed) row 79 ==="
Write-Output ("Repositories    = [{0}]" -f $r.Repositories)
Write-Output ("Projects        = [{0}]" -f $r.Projects)
Write-Output ("FilesGlobs      = [{0}]" -f $r.FilesGlobs)
Write-Output ("SchemaContexts  = [{0}]" -f $r.SchemaContexts)
Write-Output ("ContractsApis   = [{0}]" -f $r.ContractsApis)
Write-Output ("AffectedNodes   = [{0}]" -f $r.AffectedNodes)
Write-Output ("Risk            = [{0}]" -f $r.Risk)
Write-Output ("Branch          = [{0}]" -f $r.Branch)
Write-Output ("PreflightVerdict= [{0}]" -f $r.PreflightVerdict)
Write-Output ""
Write-Output "=== SPLIT TOKENS ==="
foreach ($label in @("Repositories","Projects","FilesGlobs","SchemaContexts","ContractsApis","AffectedNodes")) {
    $v = [string]$r.$label
    $tokens = @($v -split "\|" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Write-Output ("{0}: [{1}]" -f $label, ($tokens -join "],["))
}
Write-Output ""
Write-Output "=== PREFLIGHT ENUMERATED AFFECTED NODES ==="
$pf = Get-Content "C:\Personal\DevTools\DevBridge\state\preflight.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$prefAffected = @($pf.affectedNodes)
Write-Output ("count={0}: [{1}]" -f $prefAffected.Count, ($prefAffected -join "],["))
