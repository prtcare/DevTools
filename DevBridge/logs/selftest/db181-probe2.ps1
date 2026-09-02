$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions

function TrySer([string]$label, [object]$o) {
    $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $js.MaxJsonLength = [int]::MaxValue
    try { $j = $js.Serialize($o); Write-Host "OK   $label -> $j" }
    catch { Write-Host "CRASH $label -> $($_.Exception.InnerException.Message)" }
}

# 1. Bare OrderedDictionary
$od = New-Object System.Collections.Specialized.OrderedDictionary
$od['a'] = 'x'
TrySer 'OrderedDictionary scalar' $od

# 2. OrderedDictionary with null value
$od2 = New-Object System.Collections.Specialized.OrderedDictionary
$od2['a'] = $null
TrySer 'OrderedDictionary null' $od2

# 3. OrderedDictionary with Object[] value
$od3 = New-Object System.Collections.Specialized.OrderedDictionary
$od3['a'] = @('x','y')
TrySer 'OrderedDictionary objarray' $od3

# 4. Nested OrderedDictionary
$od4 = New-Object System.Collections.Specialized.OrderedDictionary
$od4['n'] = $od
TrySer 'OrderedDictionary nested' $od4

# 5. Plain hashtable with array values
$ht = @{ a = 'x'; b = @('y','z'); c = @() }
TrySer 'hashtable mixed' $ht

# 6. Single-element Object[] bare
TrySer 'bare Object[] of 1' @('x')
# 7. Empty Object[]
TrySer 'bare Object[] empty' @()

# 8. OrderedDictionary whose value is an OrderedDictionary containing a null
$od8 = New-Object System.Collections.Specialized.OrderedDictionary
$od8['x'] = $od2
TrySer 'OD containing OD-with-null' $od8
