# _Dbg-Preflight.ps1 — diagnostic wrapper for Test-DevelopmentPreflight. Not a deliverable.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. "C:\Personal\DevTools\DevBridge\scripts\Test-DevelopmentPreflight.ps1"
try {
    $v = Test-DevelopmentPreflight
    Write-Output ("VERDICT: {0}" -f $v)
} catch {
    Write-Output ("MSG: {0}" -f $_.Exception.Message)
    Write-Output ("STACK:`n{0}" -f $_.ScriptStackTrace)
    exit 1
}
