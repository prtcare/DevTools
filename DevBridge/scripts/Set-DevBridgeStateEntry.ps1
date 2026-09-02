# Set-DevBridgeStateEntry.ps1 - DB-M12.2 shared dot-sourceable library.
#
# PowerShell 5.1 ConvertFrom-Json/ConvertTo-Json round-trips FLATTEN single-element
# arrays (a JSON array with one object becomes a scalar). current-task.json carries
# array-bearing properties (repositoryStates, preExistingChanges.*, lanes), so any
# script that rewrites it must round-trip JSON with array preservation. This library
# uses System.Web.Script.Serialization.JavaScriptSerializer, which keeps object[]
# arrays intact, and exposes:
#
#   Get-DevBridgeField <obj> <key>   -> value (or $null) from a JS-parsed object
#   Get-DevBridgeMode  <ct> <cfg>    -> TRIAL | REAL_NEXUS_DEVELOPMENT (state reader
#                                       precedence: current-task "mode" -> config
#                                       -> dbM08/dbM06 trialMode evidence)
#   Read-DevBridgeJson <path>        -> Dictionary[string,object] or $null
#   Write-DevBridgeJson <path> <obj> -> serialize preserving arrays, no BOM
#   Set-DevBridgeStateEntry <path> <hashtable>  -> merge top-level fields, write
#
# ASCII-only source (PS 5.1 + BOM-safe; em-dashes and non-ASCII are forbidden here).
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Web.Extensions | Out-Null

function Get-DevBridgeField($obj, [string]$key) {
    if ($null -eq $obj) { return $null }
    $d = $obj -as [System.Collections.IDictionary]
    if ($null -eq $d) { return $null }
    # Portable key probe. Dictionary[string,object] (JS parsing) exposes only
    # .ContainsKey; OrderedDictionary exposes only .Contains(object) -- neither
    # single method is universal. An indexer read (which uses each type's own
    # comparer) plus an exception probe matches the old contract: missing key -> $null.
    $found = $false
    try { $v = $d[$key]; $found = $true } catch { $found = $false }
    if ($found) { return $v }
    return $null
}

function Get-DevBridgeMode($CurrentTask, [string]$ConfigPath) {
    $mode = "TRIAL"
    $m = Get-DevBridgeField $CurrentTask "mode"
    if ($null -ne $m -and [string]$m) { return [string]$m }
    if ($ConfigPath -and (Test-Path $ConfigPath)) {
        $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.mode) { $mode = [string]$cfg.mode }
    }
    foreach ($k in @("dbM08", "dbM06")) {
        $block = Get-DevBridgeField $CurrentTask $k
        $t = Get-DevBridgeField $block "trialMode"
        if ($null -ne $t) { $mode = $(if ([bool]$t) { "TRIAL" } else { "REAL_NEXUS_DEVELOPMENT" }) }
    }
    return $mode
}

function ConvertFrom-DevBridgeJsonString([string]$json) {
    if (-not $json) { return $null }
    try {
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = 16MB
        return $ser.DeserializeObject($json)
    } catch { return $null }
}

function Read-DevBridgeJson([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try {
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = 16MB
        return $ser.DeserializeObject([System.IO.File]::ReadAllText($Path))
    } catch { return $null }
}

function Write-DevBridgeJson([string]$Path, $Obj) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = 16MB
    [System.IO.File]::WriteAllText($Path, $ser.Serialize($Obj), (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}

function Set-DevBridgeStateEntry([string]$Path, [hashtable]$Fields) {
    $obj = Read-DevBridgeJson $Path
    if ($null -eq $obj) { throw "State file not found: $Path" }
    foreach ($k in $Fields.Keys) { $obj[[string]$k] = $Fields[$k] }
    Write-DevBridgeJson $Path $obj
    return $Path
}
