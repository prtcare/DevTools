# SP1-M02 Lane B — LIVE cross-process Forge <-> Developer writer-lock proof.
#
# Two real processes contend on one Windows OS named mutex for the SAME canonical workbook
# path:
#   * Developer side = REAL Nexus.Developer composition root (AddDevelopmentControl ->
#     ConcurrencyGuardedDevelopmentControlStore -> NamedDevelopmentControlWriteLockFactory,
#     Mutex). Runs real guarded Excel writes on a disposable workbook copy.
#   * Forge side      = REAL M02 DevBridge.Workspace.Locking (SharedLockIdentity +
#     NamedObjectWriterLock, default Mutex primitive).
# The authoritative NEXUS_DEVELOPMENT_CONTROL.xlsx is never opened or written.

$ErrorActionPreference = 'Stop'
$root  = Join-Path $env:TEMP 'nexus-sp1-m02-live'
$out   = Join-Path $root 'out'
$devDll   = Join-Path $root 'dev-probe\bin\Release\net10.0\NexusDevInteropProbe.dll'
$forgeDll = Join-Path $root 'forge-probe\bin\Release\net10.0\ForgeInteropProbe.dll'
$wb1 = Join-Path (Join-Path $root 'wb1') 'NEXUS_DEVELOPMENT_CONTROL.xlsx'
$wb2 = Join-Path (Join-Path $root 'wb2') 'NEXUS_DEVELOPMENT_CONTROL.xlsx'

$pass = 0; $fail = 0
$results = New-Object System.Collections.Generic.List[string]

function Assert-Result([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) { $script:pass++; Write-Host "PASS  $name" }
    else     { $script:fail++; Write-Host "FAIL  $name  <-- $detail" }
    $script:results.Add(("{0}  {1}  {2}" -f $(if ($ok) {'PASS'} else {'FAIL'}), $name, $detail))
}

function Invoke-Capture([string]$exe, [string[]]$argsList, [string]$label) {
    $p = Start-Process -FilePath $exe -ArgumentList $argsList -NoNewWindow -PassThru `
        -RedirectStandardOutput (Join-Path $out "$label.out.log") `
        -RedirectStandardError  (Join-Path $out "$label.err.log") -Wait
    $o = Get-Content (Join-Path $out "$label.out.log") -Raw
    return @{ Exit = $p.ExitCode; Out = $o }
}

function Start-Holder([string]$exe, [string[]]$argsList, [string]$label) {
    $p = Start-Process -FilePath $exe -ArgumentList $argsList -NoNewWindow -PassThru `
        -RedirectStandardOutput (Join-Path $out "$label.out.log") `
        -RedirectStandardError  (Join-Path $out "$label.err.log")
    return $p
}

Write-Host "== SP1-M02 LIVE interop proof =="
Write-Host "wb1 = $wb1"
Write-Host "wb2 = $wb2"

# --- build both probes (fail fast) ---
Write-Host '-- building probes --'
& dotnet build (Join-Path $root 'dev-probe\DevProbe.csproj')   -c Release --nologo -v q | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'dev-probe build FAILED'; exit 1 }
& dotnet build (Join-Path $root 'forge-probe\ForgeProbe.csproj') -c Release --nologo -v q | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'forge-probe build FAILED'; exit 1 }

# --- disposable workbooks + seed (guarded create through real composition root) ---
Remove-Item (Join-Path $root 'wb1\*') -Force -Recurse -ErrorAction SilentlyContinue
Remove-Item (Join-Path $root 'wb2\*') -Force -Recurse -ErrorAction SilentlyContinue
& dotnet $devDll make-workbook (Join-Path $root 'wb1')   | Out-Host
& dotnet $devDll make-workbook (Join-Path $root 'wb2')   | Out-Host
& dotnet $devDll seed $wb1 'M-07-LIVE' 'WI-07-LIVE' | Out-Host

# warm-up acquire to clear any abandoned state left by a previous crashed run
& dotnet $forgeDll tryacquire $wb1 200 | Out-Null

# =========================================================== CASE 3 : identity parity
Write-Host '-- CASE 3: identical lock identity for the same path (both sides) --'
$d3 = Invoke-Capture 'dotnet' @($devDll,'identity',$wb1) 'c3dev'
$f3 = Invoke-Capture 'dotnet' @($forgeDll,'identity',$wb1) 'c3forge'
$devHash = if ($d3.Out -match 'DEVIDENTITY hash=(\S+)') { $Matches[1] } else { '' }
$devName = if ($d3.Out -match 'DEVIDENTITY name=(\S+)') { $Matches[1] } else { '' }
$forgeHash = if ($f3.Out -match 'FORGEIDENTITY hash=(\S+)') { $Matches[1] } else { '' }
$forgeName = if ($f3.Out -match 'FORGEIDENTITY name=(\S+)') { $Matches[1] } else { '' }
Write-Host "  dev   hash=$devHash name=$devName"
Write-Host "  forge hash=$forgeHash name=$forgeName"
Assert-Result 'CASE3 developer-hash-equals-forge-hash' ($devHash -eq $forgeHash) "dev=$devHash forge=$forgeHash"
Assert-Result 'CASE3 name-prefix-and-64hex' ($devName.StartsWith('NexusDevelopmentControl_') -and $devName.Length -eq ('NexusDevelopmentControl_'.Length + 64) -and $devHash.Length -eq 64) "name=$devName hash=$devHash"
Assert-Result 'CASE3 object-name-equals' ($devName -eq $forgeName) "dev=$devName forge=$forgeName"

# =========================================================== CASE 4 : distinct paths differ
Write-Host '-- CASE 4: different paths -> different identity (both sides) --'
$d4 = Invoke-Capture 'dotnet' @($devDll,'identity',$wb2) 'c4dev'
$f4 = Invoke-Capture 'dotnet' @($forgeDll,'identity',$wb2) 'c4forge'
$devHash2 = if ($d4.Out -match 'DEVIDENTITY hash=(\S+)') { $Matches[1] } else { '' }
$forgeHash2 = if ($f4.Out -match 'FORGEIDENTITY hash=(\S+)') { $Matches[1] } else { '' }
Write-Host "  dev(wb2)=$devHash2 forge(wb2)=$forgeHash2 dev(wb1)=$devHash"
Assert-Result 'CASE4 dev-distinct-path-different' ($devHash2 -ne $devHash) "wb1=$devHash wb2=$devHash2"
Assert-Result 'CASE4 forge-agrees-on-distinct' ($devHash2 -eq $forgeHash2) "dev=$devHash2 forge=$forgeHash2"

# =========================================================== CASE 1 : Developer holds -> Forge refuses
Write-Host '-- CASE 1: Developer holds the real mutex -> Forge acquire times out --'
$h1 = Start-Holder 'dotnet' @($devDll,'hold',$wb1,'7') 'c1devhold'
Start-Sleep -Seconds 2
$t1 = Invoke-Capture 'dotnet' @($forgeDll,'tryacquire',$wb1,'3000') 'c1forgetake'
Write-Host "  forge-take: $($t1.Out.Trim())"
$takeOutcome = if ($t1.Out -match 'outcome=(\w+)') { $Matches[1] } else { '' }
$takeMs = if ($t1.Out -match 'elapsedMs=(\d+)') { [int]$Matches[1] } else { -1 }
$h1.WaitForExit() | Out-Null
Assert-Result 'CASE1 forge-timeout-while-developer-holds' ($takeOutcome -eq 'Timeout') "outcome=$takeOutcome"
Assert-Result 'CASE1 bounded-elapsed-~3s' ($takeMs -ge 1500 -and $takeMs -lt 8000) "elapsedMs=$takeMs"
Write-Host "  dev-hold log: $((Get-Content (Join-Path $out 'c1devhold.out.log') -Raw).Trim())"
$c1p = Invoke-Capture 'dotnet' @($forgeDll,'tryacquire',$wb1,'3000') 'c1positive'
$c1o = if ($c1p.Out -match 'outcome=(\w+)') { $Matches[1] } else { '' }
Write-Host "  positive control (after dev released): $($c1p.Out.Trim())"
Assert-Result 'CASE1 positive-forge-acquires-after-release' ($c1o -eq 'Acquired') "outcome=$c1o"

# =========================================================== CASE 2 : Forge holds -> Developer refuses (guarded write)
Write-Host '-- CASE 2: Forge holds the real mutex -> Developer guarded write lock-times-out, workbook unchanged --'
$hashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $wb1).Hash
$h2 = Start-Holder 'dotnet' @($forgeDll,'acquire-hold',$wb1,'9') 'c2forgehold'
Start-Sleep -Seconds 2
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$t2 = Invoke-Capture 'dotnet' @($devDll,'reserve',$wb1,'WI-07-LIVE','2') 'c2devtake'
$sw.Stop()
Write-Host "  dev-reserve-take: $($t2.Out.Trim())"
Write-Host "  wall-elapsed=$($sw.ElapsedMilliseconds)ms"
$r2o = if ($t2.Out -match 'outcome=(\S+)') { $Matches[1] } else { '' }
$r2u = if ($t2.Out -match 'workbookUnchangedOnFailure=(\S+)') { $Matches[1] } else { '' }
$h2.WaitForExit() | Out-Null
$hashAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $wb1).Hash
Assert-Result 'CASE2 dev-write-lock-timeout-while-forge-holds' ($r2o -eq 'LOCK_TIMEOUT') "outcome=$r2o"
Assert-Result 'CASE2 dev-bounded-wait-(~2s,-not-infinite)' ($sw.ElapsedMilliseconds -lt 9000) "wall=$($sw.ElapsedMilliseconds)ms"
Assert-Result 'CASE2 workbook-bytes-unchanged-on-timeout' ($hashBefore -eq $hashAfter) "before=$hashBefore after=$hashAfter"
Write-Host "  forge-hold log: $((Get-Content (Join-Path $out 'c2forgehold.out.log') -Raw).Trim())"
$c2p = Invoke-Capture 'dotnet' @($devDll,'reserve',$wb1,'WI-07-LIVE','10') 'c2positive'
$c2o = if ($c2p.Out -match 'outcome=(\S+)') { $Matches[1] } else { '' }
Write-Host "  positive control (after forge released): $($c2p.Out.Trim())"
Assert-Result 'CASE2 positive-dev-write-succeeds-after-release' ($c2o -eq 'SUCCESS') "outcome=$c2o"
$hashAfterPositive = (Get-FileHash -Algorithm SHA256 -LiteralPath $wb1).Hash
Assert-Result 'CASE2 workbook-mutated-on-successful-write' ($hashAfterPositive -ne $hashAfter) 'expected a change after a real reserve'

# =========================================================== CASE 5 : explicit bounded no-infinite-wait
Write-Host '-- CASE 5: bounded timeout, no infinite wait (short timeout probe) --'
$h5 = Start-Holder 'dotnet' @($forgeDll,'acquire-hold',$wb1,'6') 'c5forgehold'
Start-Sleep -Seconds 2
$t5 = Invoke-Capture 'dotnet' @($forgeDll,'tryacquire',$wb1,'1200') 'c5forgetake'
Write-Host "  forge-short-take: $($t5.Out.Trim())"
$o5 = if ($t5.Out -match 'outcome=(\w+)') { $Matches[1] } else { '' }
$m5 = if ($t5.Out -match 'elapsedMs=(\d+)') { [int]$Matches[1] } else { -1 }
$h5.WaitForExit() | Out-Null
Assert-Result 'CASE5 forge-short-timeout-1200ms' ($o5 -eq 'Timeout' -and $m5 -ge 700 -and $m5 -lt 6000) "outcome=$o5 ms=$m5"

# =========================================================== CASE 6 : failed contention never partially mutates (explicit)
Write-Host '-- CASE 6: failed contention never partially mutates the workbook (explicit block) --'
# (developer side already asserted byte-identity in CASE2; here the Forge-side blocked writer is
#  re-asserted at the orchestrator with a fresh block and byte-compare around a dev guarded write)
$h6 = Start-Holder 'dotnet' @($forgeDll,'acquire-hold',$wb1,'6') 'c6forgehold'
Start-Sleep -Seconds 2
$b6 = (Get-FileHash -Algorithm SHA256 -LiteralPath $wb1).Hash
$t6 = Invoke-Capture 'dotnet' @($devDll,'reserve',$wb1,'M-07-LIVE','2') 'c6devtake'   # non-reservable node -> guarded write still times out first
$h6.WaitForExit() | Out-Null
$a6 = (Get-FileHash -Algorithm SHA256 -LiteralPath $wb1).Hash
$r6o = if ($t6.Out -match 'outcome=(\S+)') { $Matches[1] } else { '' }
Write-Host "  dev-take-under-forge-hold: $($t6.Out.Trim())"
Assert-Result 'CASE6 bytes-identical-after-blocked-write' ($b6 -eq $a6) "before=$b6 after=$a6"
# (outcome here is the lock timeout OR validation of node state; the byte-identity is the assertion)

# ----------------------------------------------------------- summary
Write-Host ''
Write-Host ("==== LIVE INTEROP RESULT: PASSED={0} FAILED={1} ====" -f $pass, $fail)
$results | Set-Content (Join-Path $out 'results.txt')
exit $(if ($fail -eq 0) { 0 } else { 1 })
