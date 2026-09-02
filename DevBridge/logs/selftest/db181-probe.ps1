$ErrorActionPreference = 'Stop'
. 'C:\Personal\DevTools\DevBridge\scripts\ai-routing\DependencyLineage.ps1'

# Replicate the lineage-record shape produced by Get-DbM181TaskLineage.
$record = [pscustomobject]@{
    TaskId             = 'M-07-0.2'
    ChangeIds          = @('CHG-20260825-013')   # single-element array
    FilesCreated       = @('a.cs', 'b.cs')         # multi-element array
    BlockingFindings   = @()                       # empty array
    ClaudeReviewOutcome = [pscustomobject]@{
        Decision           = 'PASS'
        ImplementationState = 'TRIAL_ONLY_UNMERGED'
        Observations       = @('NB-1')             # single-element array nested
    }
    ScopeAmendments    = @()
    Provenance         = @('WORKBOOK')             # single-element array
    Completions        = $null
}

Write-Host '--- sorted dump (types) ---'
$sorted = ConvertTo-DbM181Sorted -InputObject $record
function Walk($o, [int]$d) {
    if ($null -eq $o) { Write-Host ('{0}-> NULL' -f (' ' * $d)); return }
    if ($o -is [System.Management.Automation.PSMethod]) { Write-Host ('{0}-> PSMETHOD!!! {1}' -f (' ' * $d), $o.Name); return }
    if ($o -is [System.Collections.IDictionary]) {
        Write-Host ('{0}-> {1}' -f (' ' * $d), $o.GetType().FullName)
        foreach ($k in $o.Keys) {
            $v = $o[$k]
            if ($null -eq $v) { Write-Host ('{0}  [{1}] = NULL' -f (' ' * $d), $k); continue }
            if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) {
                Write-Host ('{0}  [{1}] = {2} (count {3})' -f (' ' * $d), $k, $v.GetType().FullName, @($v).Count)
                foreach ($item in $v) { Walk $item ($d + 4) }
            } else {
                Write-Host ('{0}  [{1}] = {2}' -f (' ' * $d), $k, $v.GetType().FullName)
                Walk $v ($d + 4)
            }
        }
        return
    }
    Write-Host ('{0}-> {1}' -f (' ' * $d), $o.GetType().FullName)
}
Walk $sorted 0

Write-Host '--- JSON serialization (library ConvertTo-DbM181Json) ---'
try { $json = ConvertTo-DbM181Json -Object $record; Write-Host "OK: $json" }
catch { Write-Host "CRASH: $($_.Exception.Message)" }
Write-Host '--- determinism check (twice, identical bytes) ---'
$a = ConvertTo-DbM181Json -Object $record
$b = ConvertTo-DbM181Json -Object $record
Write-Host "identical: $($a -ceq $b)"
