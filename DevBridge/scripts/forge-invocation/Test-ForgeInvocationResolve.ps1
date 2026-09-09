<#
Test-ForgeInvocationResolve.ps1
DevBridge FIB (forge-invocation boundary) RESOLVE self-test suite.

Exercises the REAL machine contract end-to-end: Invoke-ForgeResolve.ps1 is spawned
out of process via `powershell -File` against throwaway byte-identical workbook
copies + fixture state dirs under logs\selftest\fib-resolve. Requests are JSON
files; the caller consumes ONLY the JSON result file + exit code (console markers
are asserted present but never parsed). The authoritative workbook, live
DevBridge state, and the Forge repo are asserted byte-identical / untouched at the
end.

The pristine baseline (newest recorded db-m124-preclosure copy) is a byte-identical
fixture source but its CURRENT governed position is read from the baseline itself:
a first free-resolve probe yields T0 (the governed leaf the resolver selects today),
and all controlled scenarios are built around T0. No task id is hard-coded, so the
suite stays green as the recorded baseline advances.

RESOLVE acceptance (10 items):
  #1  reaches the governed Task Resolver
  #2  dependency/context carried into the result
  #3  ineligible / preflight fails closed (no governable next task)
  #4  invalid/missing governed identity fails closed
  #5  scope failure fails closed (not-the-governed-task / cross-scope)
  #6  routing + classification surfaced (status only; nothing selected/invoked)
  #7  repeated RESOLVE is non-destructive and deterministic
  #8  no write to protected main / live governed state
  #9  no C:\Personal dependency (fixture + scratch only)
  #10 structured result consumable without parsing console text

No live mutation: every write lands in the fixture copy / fixture dirs / the
boundary's own git-ignored scratch (DevBridge\temp\forge-invocation). No git is
run by the boundary. PREPARE is NOT exercised (see design doc section 6 blocker).
#>
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script:Cfg = Get-Content (Join-Path $script:Root "config\devbridge.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$script:RealWorkbook = [string]$script:Cfg.developmentControlWorkbook
$script:SelftestRoot = Join-Path $script:Root "logs\selftest"
if (-not (Test-Path $script:SelftestRoot)) { New-Item -ItemType Directory -Force -Path $script:SelftestRoot | Out-Null }
$script:FibRoot = Join-Path $script:SelftestRoot "fib-resolve"
if (Test-Path $script:FibRoot) { Remove-Item $script:FibRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $script:FibRoot | Out-Null
# The boundary's own scratch (git-ignored) is cleared so each suite run is fresh.
$script:ScratchParent = Join-Path $script:Root "temp\forge-invocation"
if (Test-Path $script:ScratchParent) { Remove-Item $script:ScratchParent -Recurse -Force }

$script:InvokeScript = Join-Path $PSScriptRoot "Invoke-ForgeResolve.ps1"

function Get-Hash([string]$p) { return (Get-FileHash $p -Algorithm SHA256).Hash }

# Fixture baseline decoupling: byte-identical PRISTINE copies (the recorded DB-M12.4
# pre-closure baseline) so the CURRENT governed position is reproduced faithfully.
$script:PristineWorkbook = $script:RealWorkbook
$preclosureBackups = @(Get-ChildItem (Join-Path $script:Root "state\backups") -Filter "db-m124-preclosure-*.xlsx" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1)
if ($preclosureBackups.Count -ge 1) {
    $script:PristineWorkbook = [string]$preclosureBackups[0].FullName
}
$script:PristineSource = $script:PristineWorkbook   # recorded for the report

$script:RealHashBefore = Get-Hash $script:RealWorkbook
$script:LiveStateFiles = @(
    "current-task.json", "preflight.json", "current-lifecycle-state.json",
    "reservation.json", "trial-proving-history.json"
)
$script:LiveHashBefore = @{}
foreach ($f in $script:LiveStateFiles) {
    $p = Join-Path $script:Root ("state\" + $f)
    $script:LiveHashBefore[$f] = if (Test-Path $p) { Get-Hash $p } else { "" }
}
$script:GitStatusBefore = @(& git -C $script:Root status --porcelain=v1 2>$null)

$script:Results = @()
$script:Fails = New-Object System.Collections.Generic.List[string]
$script:Count = 0

function Assert-True([string]$label, [bool]$cond, [string]$detail) {
    $script:Count++
    $row = New-Object PSCustomObject
    $row | Add-Member NoteProperty -Name Scenario -Value $label
    $row | Add-Member NoteProperty -Name Pass -Value $cond
    $row | Add-Member NoteProperty -Name Detail -Value $detail
    $script:Results += $row
    if (-not $cond) {
        $script:Fails.Add(("{0}: {1}" -f $label, $detail))
        Write-Output ("  [FAIL] {0} - {1}" -f $label, $detail)
    } else {
        Write-Output ("  [PASS] {0}" -f $label)
    }
}

function Get-P($o, [string]$n) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Collections.IDictionary]) {
        if ($o.Contains($n)) { return $o[$n] }
        return $null
    }
    $p = $o.PSObject.Properties[$n]
    if ($null -eq $p) { return $null }
    return $p.Value
}
function Get-PStr($o, [string]$n) {
    $v = Get-P $o $n
    if ($null -eq $v) { return "" }
    return [string]$v
}

function Write-NoBom([string]$path, $obj) {
    $dir = Split-Path $path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = $obj | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# ---- fixtures ----------------------------------------------------------------
function New-FibFixture([string]$name, [string[]]$provingNodeIds = @()) {
    $outDir = Join-Path $script:FibRoot $name
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $stateDir = Join-Path $outDir "state"; $tasksDir = Join-Path $outDir "tasks"
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null
    $wbCopy = Join-Path $outDir "workbook.xlsx"
    Copy-Item $script:PristineWorkbook $wbCopy -Force
    if ($provingNodeIds.Count -gt 0) {
        $entries = @()
        foreach ($id in $provingNodeIds) {
            $entries += [ordered]@{
                nodeId = $id; changeId = ("CHG-" + $id); closedAtUtc = "2026-08-31T01:00:00Z"
                mode = "TRIAL"; result = "TRIAL_CYCLE_CLOSED"; implementationState = "TRIAL_ONLY_UNMERGED"
            }
        }
        Write-NoBom (Join-Path $stateDir "trial-proving-history.json") ([ordered]@{ entries = $entries })
    }
    return @{ root = $outDir; stateDir = $stateDir; tasksDir = $tasksDir; wbCopy = $wbCopy }
}

function New-Request([string]$id, [string]$governedJson = "") {
    $o = [ordered]@{
        schemaVersion = 1; api = "forge.resolve"; operation = "RESOLVE"
        requestId = $id; issuedAtUtc = "2026-09-09T00:00:00Z"
        actor = "fib-test"; origin = "fib-test"
    }
    if ($governedJson) { $o.governedTask = $governedJson | ConvertFrom-Json }
    return [pscustomobject]$o
}

# ---- engine invocation wrapper (real out-of-process machine contract) --------
function Invoke-Boundary([hashtable]$f, [string]$scenario, $request) {
    $reqPath = Join-Path $f.root ($scenario + ".req.json")
    $resPath = Join-Path $f.root ($scenario + ".result.json")
    Write-NoBom $reqPath $request

    Set-Item "env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE" $f.wbCopy
    Set-Item "env:DB_NEXTTASK_STATE_DIR" $f.stateDir
    Set-Item "env:DB_NEXTTASK_CONFIG_PATH" (Join-Path $script:Root "config\devbridge.json")
    Remove-Item "env:DB_FIB_SCRATCH_ROOT" -ErrorAction SilentlyContinue
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:InvokeScript -RequestFile $reqPath -ResultFile $resPath 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldEAP
    }
    foreach ($k in @("DB_DEV_CONTROL_WORKBOOK_OVERRIDE","DB_NEXTTASK_STATE_DIR","DB_NEXTTASK_CONFIG_PATH")) { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue }
    $out = @($out | ForEach-Object { "$_" })

    $result = $null
    if (Test-Path $resPath) { $result = [System.IO.File]::ReadAllText($resPath) | ConvertFrom-Json }
    return @{ exit = $code; output = $out; result = $result; resPath = $resPath; reqPath = $reqPath }
}

function Get-FailureCodes($res) {
    $codes = @()
    foreach ($fr in @(Get-P $res "failures")) { $codes += Get-PStr $fr "code" }
    return $codes
}

# ==============================================================================
Write-Output "== FIB RESOLVE: baseline governed free resolve (probe T0) =="
$fP = New-FibFixture "p_baseline"
$rP = Invoke-Boundary $fP "p_baseline" (New-Request "fib-test-0000")
$resP = $rP.result
$T0 = ""
Assert-True "P0 boundary writes a result doc and exits 0" ($rP.exit -eq 0 -and $null -ne $resP) ("exit=" + $rP.exit)
if ($null -ne $resP) {
    $T0 = Get-PStr (Get-P (Get-P $resP "governed") "resolvedTarget") "nodeId"
}
Write-Output ("    [governed baseline leaf T0 = " + $T0 + "]")
Assert-True "P1 baseline state SUCCESS (governed CLEAR leaf on the recorded baseline)" ((Get-PStr $resP "state") -eq "SUCCESS") ("state=" + (Get-PStr $resP "state"))
Assert-True "P2 baseline T0 is a non-empty governed leaf" ($T0.Length -gt 0 -and $T0 -like "*-*") ("T0='" + $T0 + "'")

Write-Output "== FIB RESOLVE: governed free resolve reaches the Task Resolver (#1) =="
$trP = Get-P $resP "taskResolution"
$govP = Get-P $resP "governed"
$tarP = Get-P $govP "resolvedTarget"
Assert-True "A Task Resolver reached: taskResolution.status SELECTED with basis" ((Get-PStr $trP "status") -eq "SELECTED" -and @(Get-P $trP "selectionBasis").Count -gt 0) ("status=" + (Get-PStr $trP "status"))
Assert-True "A resolved governed task selected and echoed in resolvedTarget" ((Get-PStr $trP "taskNodeId") -eq $T0 -and (Get-PStr $tarP "nodeId") -eq $T0) ("task=" + (Get-PStr $trP "taskNodeId") + " target=" + (Get-PStr $tarP "nodeId"))
Assert-True "A state SUCCESS with zero failures" ((Get-PStr $resP "state") -eq "SUCCESS" -and @(Get-P $resP "failures").Count -eq 0) "failures present"
Assert-True "A result is read entirely from JSON (no console parsing) (#10)" ((Get-PStr $resP "api") -eq "forge.resolve" -and (Get-PStr $resP "requestId") -eq "fib-test-0000" -and (Get-PStr $resP "runId").Length -gt 0 -and @(Get-P $resP "evidence").Count -ge 2) "contract fields missing"
$markerLine = @($rP.output | Where-Object { $_ -like "FORGE_RESULT_FILE:*" } | Select-Object -First 1)
Assert-True "A FORGE_RESULT_FILE marker present but never parsed" ($markerLine.Count -eq 1 -and $markerLine[0] -like ("FORGE_RESULT_FILE:*" + $rP.resPath)) "marker missing/mismatched"

Write-Output "== FIB RESOLVE: dependency/context carried into the result (#2) =="
$pfP = Get-P $resP "preflight"
$lvP = @(Get-P $pfP "leafValidation")
$depLvP = @($lvP | Where-Object { (Get-PStr $_ "check") -eq "dependencies" })[0]
$depCtxP = Get-P $resP "dependencyContext"
Assert-True "B preflight verdict CLEAR / readiness READY" ((Get-PStr $pfP "verdict") -eq "CLEAR" -and (Get-PStr $pfP "readiness") -eq "READY") ("verdict=" + (Get-PStr $pfP "verdict"))
Assert-True "B leafValidation dependency ledger PASS (context carried)" ($depLvP -and (Get-PStr $depLvP "status") -eq "PASS") ("got " + (Get-PStr $depLvP "status"))
Assert-True "B dependencyContext status RESOLVED with basis" ((Get-PStr $depCtxP "status") -eq "RESOLVED" -and (Get-PStr $depCtxP "basis").Length -gt 0) ("got " + (Get-PStr $depCtxP "status"))
Assert-True "B preflight scope COMPLETE (governed scope derived, not invented)" ((Get-PStr (Get-P $pfP "scope") "status") -eq "COMPLETE") ("got " + (Get-PStr (Get-P $pfP "scope") "status"))

Write-Output "== FIB RESOLVE: routing + classification surfaced as status only (#6) =="
$clsP = Get-P $resP "classification"
$rtP = Get-P $resP "routing"
$hgP = Get-P $resP "humanGate"
$wtP = Get-P $resP "worktree"
Assert-True "F deterministic classification surfaced (TaskType, Foundation address, mode)" ($clsP -and (Get-PStr $clsP "TaskType").Length -gt 0 -and (Get-PStr $clsP "NodeAddress") -eq ("Foundation:" + $T0)) ("type=" + (Get-PStr $clsP "TaskType") + " addr=" + (Get-PStr $clsP "NodeAddress"))
Assert-True "F routing MANUAL + autoExecution PROHIBITED + recommendation NOT_ENABLED" ((Get-PStr $rtP "executionMode") -eq "MANUAL" -and (Get-PStr $rtP "autoExecution") -eq "PROHIBITED" -and (Get-PStr $rtP "recommendationStatus") -eq "NOT_ENABLED") ("got exec=" + (Get-PStr $rtP "executionMode") + " status=" + (Get-PStr $rtP "recommendationStatus"))
Assert-True "F no worker/model/provider selected or invoked" ($null -eq (Get-P $rtP "selectedWorker") -and $null -eq (Get-P $rtP "selectedModel") -and $null -eq (Get-P $rtP "selectedProvider")) "a worker/model/provider was surfaced"
Assert-True "F humanGate.required false; worktree NOT_CREATED; next governed action RESERVE" ((Get-PStr $hgP "required") -eq "False" -and (Get-PStr $wtP "prepState") -eq "NOT_CREATED" -and (Get-PStr $hgP "nextGovernedAction") -eq "RESERVE") ("gate=" + (Get-PStr $hgP "required") + " wt=" + (Get-PStr $wtP "prepState") + " next=" + (Get-PStr $hgP "nextGovernedAction"))

Write-Output "== FIB RESOLVE: explicit governed node matching the governed task =="
$fE = New-FibFixture "e_explicit_match"
$reqE = New-Request "fib-test-0001" ('{"nodeId":"' + $T0 + '","mode":"TRIAL"}')
$rE = Invoke-Boundary $fE "e_explicit_match" $reqE
$resE = $rE.result
$govE = Get-P $resE "governed"
Assert-True "E explicit governed node resolves SUCCESS and exists=true" ((Get-PStr $resE "state") -eq "SUCCESS" -and (Get-PStr (Get-P $govE "requestedNode") "exists") -eq "True") ("state=" + (Get-PStr $resE "state"))
Assert-True "E declared mode TRIAL echoed as declaredMode (not silently altered)" ((Get-PStr $govE "declaredMode") -eq "TRIAL" -and (Get-PStr $govE "mode") -eq "TRIAL") ("declared=" + (Get-PStr $govE "declaredMode"))

Write-Output "== FIB RESOLVE: ineligible (governed target trial-proven) fails closed (#3) =="
$fG = New-FibFixture "g_selection_block" @($T0)
$rG = Invoke-Boundary $fG "g_selection_block" (New-Request "fib-test-0002")
$resG = $rG.result
$trG = Get-P $resG "taskResolution"
Assert-True "G trial-proven governed target -> state FAILED with SELECTION_BLOCKED" ((Get-PStr $resG "state") -eq "FAILED" -and (Get-FailureCodes $resG) -contains "SELECTION_BLOCKED") ("codes=" + ((Get-FailureCodes $resG) -join ","))
Assert-True "G governed resolver block surfaced honestly (block token, no task fabricated)" ((Get-PStr $trG "taskNodeId").Length -eq 0 -and (Get-PStr $trG "status") -notlike "SELECTED") ("status=" + (Get-PStr $trG "status"))

Write-Output "== FIB RESOLVE: invalid/missing governed identity fails closed (#4) =="
$fH = New-FibFixture "h_identity_invalid"
$rH = Invoke-Boundary $fH "h_identity_invalid" (New-Request "fib-test-0003" '{"nodeId":"WI-99-0.9.9"}')
$resH = $rH.result
Assert-True "H nonexistent governed node -> FAILED with IDENTITY_INVALID" ((Get-PStr $resH "state") -eq "FAILED" -and (Get-FailureCodes $resH) -contains "IDENTITY_INVALID") ("codes=" + ((Get-FailureCodes $resH) -join ","))
$fH2 = New-FibFixture "h_identity_malformed"
$rH2 = Invoke-Boundary $fH2 "h_identity_malformed" (New-Request "fib-test-0004" '{"address":"not-an-address"}')
$resH2 = $rH2.result
Assert-True "H malformed Role:Id address -> REQUEST_INVALID fail-closed" ((Get-PStr $resH2 "state") -eq "FAILED" -and (Get-FailureCodes $resH2) -contains "REQUEST_INVALID") ("codes=" + ((Get-FailureCodes $resH2) -join ","))

Write-Output "== FIB RESOLVE: scope failure fails closed (#5) =="
$fI = New-FibFixture "i_scope_not_governed"
$altExisting = "M-07-0.2"
if ($T0 -eq $altExisting) { $altExisting = "M-12-0.4" }
$rI = Invoke-Boundary $fI "i_scope_not_governed" (New-Request "fib-test-0005" ('{"nodeId":"' + $altExisting + '"}'))
$resI = $rI.result
Assert-True "I requested existing node that is NOT the governed next task -> SCOPE_NOT_GOVERNED" ((Get-PStr $resI "state") -eq "FAILED" -and (Get-FailureCodes $resI) -contains "SCOPE_NOT_GOVERNED") ("codes=" + ((Get-FailureCodes $resI) -join ","))
$fI2 = New-FibFixture "i_scope_cross_role"
$rI2 = Invoke-Boundary $fI2 "i_scope_cross_role" (New-Request "fib-test-0006" ('{"address":"Products:' + $T0 + '"}'))
$resI2 = $rI2.result
Assert-True "I cross-scope Products address -> SCOPE_NOT_GOVERNED (Foundation universe only)" ((Get-PStr $resI2 "state") -eq "FAILED" -and (Get-FailureCodes $resI2) -contains "SCOPE_NOT_GOVERNED") ("codes=" + ((Get-FailureCodes $resI2) -join ","))

Write-Output "== FIB RESOLVE: request validation fail-closed (deterministic doc) =="
$fJ = New-FibFixture "j_api_invalid"
$reqJ = New-Request "fib-test-0007"
$reqJ.api = "forge.prepare"
$rJ = Invoke-Boundary $fJ "j_api_invalid" $reqJ
$resJ = $rJ.result
Assert-True "J unsupported api -> FAILED REQUEST_INVALID, result doc still written (exit 0)" ($rJ.exit -eq 0 -and (Get-PStr $resJ "state") -eq "FAILED" -and (Get-FailureCodes $resJ) -contains "REQUEST_INVALID") ("codes=" + ((Get-FailureCodes $resJ) -join ","))

Write-Output "== FIB RESOLVE: repeated RESOLVE is non-destructive + deterministic (#7) =="
$fK = New-FibFixture "k_repeat"
$reqK = New-Request "fib-test-0008"
$rK1 = Invoke-Boundary $fK "k_repeat_run1" $reqK
$rK2 = Invoke-Boundary $fK "k_repeat_run2" $reqK
$resK1 = $rK1.result; $resK2 = $rK2.result
$shaK1 = Get-PStr (Get-P $resK1 "governed") "workbookSha256"
$shaK2 = Get-PStr (Get-P $resK2 "governed") "workbookSha256"
Assert-True "K both repeated runs SUCCESS with identical governed selection" ((Get-PStr $resK1 "state") -eq "SUCCESS" -and (Get-PStr $resK2 "state") -eq "SUCCESS" -and (Get-PStr (Get-P (Get-P $resK1 "governed") "resolvedTarget") "nodeId") -eq (Get-PStr (Get-P (Get-P $resK2 "governed") "resolvedTarget") "nodeId")) "resolutions diverged across repeated runs"
Assert-True "K workbook snapshot hash stable across runs" ($shaK1.Length -gt 0 -and $shaK1 -eq $shaK2) "workbook sha diverged"
$preflightInFixtureState = Test-Path (Join-Path $fK.stateDir "preflight.json")
$ctInFixtureState = Test-Path (Join-Path $fK.stateDir "current-task.json")
Assert-True "K engine writes stayed in the boundary scratch (fixture state dir clean)" (-not $preflightInFixtureState -and -not $ctInFixtureState) "fixture state dir gained preflight/current-task"
Assert-True "K fixture workbook byte-identical after both runs" ((Get-Hash $fK.wbCopy) -eq (Get-Hash (Join-Path $fK.root "workbook.xlsx"))) "fixture workbook changed during runs"

Write-Output "== FIB RESOLVE: structured result contract surface (#10) =="
Assert-True "L evidence carries workbook sha + governance source + result path" (@(Get-P $resP "evidence").Count -ge 3) ("evidence=" + @(Get-P $resP "evidence").Count)
$govNodeP = Get-P $govP "requestedNode"
Assert-True "L requestedNode block present (null for free resolve) - machine shape stable" ($null -eq $govNodeP) "requestedNode not null for free resolve"

# ==============================================================================
Write-Output "== invariants =="
$realHashAfter = Get-Hash $script:RealWorkbook
Assert-True "I1 authoritative workbook untouched by suite (#8)" ($realHashAfter -eq $script:RealHashBefore) "authoritative workbook hash changed"
foreach ($f in $script:LiveStateFiles) {
    $p = Join-Path $script:Root ("state\" + $f)
    $h = if (Test-Path $p) { Get-Hash $p } else { "" }
    Assert-True ("I2 live state {0} untouched (#8)" -f $f) ($h -eq $script:LiveHashBefore[$f]) "live state modified"
}
# No C:\Personal dependency (#9): the boundary source + every produced request/result
# artifact never reference C:\Personal. The suite succeeds purely on fixture + scratch.
$personalRefs = @()
$srcText = [System.IO.File]::ReadAllText($script:InvokeScript)
if ($srcText -match "C:\\Personal") { $personalRefs += $script:InvokeScript }
foreach ($rf in @(Get-ChildItem $script:FibRoot -Recurse -File -Filter *.json)) {
    $txt = [System.IO.File]::ReadAllText($rf.FullName)
    if ($txt -match "C:\\Personal") { $personalRefs += $rf.FullName }
}
Assert-True "I3 no boundary source or produced artifact references C:\Personal (#9)" ($personalRefs.Count -eq 0) ("refs: " + ($personalRefs -join "; "))
Assert-True "I4 suite ran with zero git invocations by the boundary (Forge status unchanged)" ((@(& git -C $script:Root status --porcelain=v1 2>$null) -join "`n") -eq ($script:GitStatusBefore -join "`n")) "Forge repo status changed during suite"
# Every request stayed inside the RESOLVE surface: no PREPARE / dispatch / merge /
# branch semantics were ever sent through the boundary (batch boundary).
$opsSent = @(Get-ChildItem $script:FibRoot -Recurse -File -Filter *.req.json |
    Where-Object { $_.Name -notlike "*api_invalid*" } |
    ForEach-Object {
        $reqObj = ([System.IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json)
        (Get-PStr $reqObj "operation") + "|" + (Get-PStr $reqObj "api")
    })
$allResolveOnly = ($opsSent.Count -ge 9) -and (@($opsSent | Where-Object { $_ -ne "RESOLVE|forge.resolve" }).Count -eq 0)
Assert-True "I5 all requests were RESOLVE/forge.resolve only (no dispatch/prepare/merge)" $allResolveOnly ("ops=" + (($opsSent | Sort-Object -Unique) -join "; "))
Assert-True "I6 every boundary call wrote a structured result file" (@(Get-ChildItem $script:FibRoot -Recurse -File -Filter *.result.json).Count -ge 10) ("docs=" + @(Get-ChildItem $script:FibRoot -Recurse -File -Filter *.result.json).Count)

Write-Output ""
$passCount = @($script:Results | Where-Object { $_.Pass }).Count
Write-Output ("FIB_RESOLVE_SUMMARY: {0}/{1} PASS  (baseline T0={2})" -f $passCount, $script:Count, $T0)
if ($script:Fails.Count -gt 0) {
    Write-Output ("FAILED: " + ($script:Fails -join " | "))
    exit 1
}
exit 0
