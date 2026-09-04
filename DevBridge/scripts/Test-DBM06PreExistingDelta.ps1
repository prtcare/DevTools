# Test-DBM06PreExistingDelta.ps1
# Targeted self-test for DB-M06 git-baseline delta classification of
# PRE-EXISTING DIRTY FILES inside a reserved task scope (Measure-Dbm06ImplementationDelta.ps1).
#
# Runs each scenario in a THROWAWAY git repository (real `git init`) with a
# synthetic reservation.json shaped exactly like DB-M04 output:
#   preExistingChanges.modified / .staged  -> raw porcelain lines
#   preExistingChanges.untracked           -> bare rel paths
#   scopeFileHashes                        -> { path, sha256, bytes } (mode-B mirror,
#                                             only pre-existing dirty/untracked under
#                                             the reserved project; forceInc/forceExc
#                                             let a scenario model wider/narrower capture)
#
# Reserved project in every fixture is "Widget" under src/Widget/. Files under
# src/Other/ are OUT of the reserved scope.
#
# Required scenarios (DB-M06 brief):
#   1 clean reserved modified                                  -> CURRENT_TASK_DELTA
#   2 dirty reserved unchanged                                 -> PRE_EXISTING_ONLY
#   3 dirty reserved + valid incremental edit                  -> PRE_EXISTING_AND_CURRENT_TASK_DELTA
#   4 dirty out-of-scope modified (baseline hash available)    -> FAIL (OUT_OF_SCOPE_MODIFICATION)
#   5 dirty reserved reverted/cleaned                          -> FAIL (REVERT_CLEANED_PRE_EXISTING)
#   6 unrelated pre-existing staged/claimed                    -> FAIL (STAGED_PREEXISTING_CHANGE)
#   7 untracked w/ captured baseline modified                  -> incremental delta detectable
#   8 untracked w/o sufficient baseline                        -> STOP (PREEXISTING_FILE_BASELINE_INSUFFICIENT)
# Plus guards: clean out-of-scope modified / created, deletion of a pre-existing
# change, and a HEAD advance (a commit made during the task window).
#
# ASCII-only. Run from repo root:  powershell -File scripts\Test-DBM06PreExistingDelta.ps1
param()
$ErrorActionPreference = "Stop"
$script:Engine = Join-Path $PSScriptRoot "Measure-Dbm06ImplementationDelta.ps1"
if (-not (Test-Path -LiteralPath $script:Engine)) { throw "Engine missing: $($script:Engine)" }

$script:PassCount = 0
$script:FailCount = 0

function Report([bool]$ok, [string]$name, [string]$detail) {
    if ($ok) { $script:PassCount++; Write-Output ("PASS  " + $name + " - " + $detail) }
    else     { $script:FailCount++; Write-Output ("FAIL  " + $name + " - " + $detail) }
}

function New-FxRepo([string]$tag) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("dbm6_" + $tag + "_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    & git -C $dir init -q
    if ($LASTEXITCODE -ne 0) { throw "git init failed" }
    & git -C $dir config user.name  "DevBridge Fixture" | Out-Null
    & git -C $dir config user.email "dbm6@fixture.local" | Out-Null
    & git -C $dir config core.autocrlf false | Out-Null
    return $dir
}

function Write-FxFile([string]$dir, [string]$rel, [string]$content) {
    $full = Join-Path $dir ($rel -replace '/', '\')
    $parent = Split-Path -Parent $full
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($full, $content, $enc)
}

function Commit-FxAll([string]$dir, [string]$msg) {
    & git -C $dir add -A
    if ($LASTEXITCODE -ne 0) { throw "git add failed: $msg" }
    & git -C $dir commit -q -m $msg
    if ($LASTEXITCODE -ne 0) { throw "git commit failed: $msg" }
}

function Remove-FxFile([string]$dir, [string]$rel) {
    $full = Join-Path $dir ($rel -replace '/', '\')
    Remove-Item -LiteralPath $full -Force
}

# Mirror DB-M04 Get-GitSnapshot + mode-B Get-RepoScopeHashes, with scenario hooks.
function Export-FxReservation([string]$dir, [string[]]$resProjects, [string]$outJson,
                              [string[]]$forceInc, [string[]]$forceExc) {
    $status = @(& git -C $dir status --porcelain=v1 2>$null)
    $staged = New-Object System.Collections.Generic.List[string]
    $modified = New-Object System.Collections.Generic.List[string]
    $untracked = New-Object System.Collections.Generic.List[string]
    foreach ($line in $status) {
        if ($line.Length -lt 4) { continue }
        $code = $line.Substring(0, 2)
        $path = $line.Substring(3)
        if ($code -eq "??") { $untracked.Add($path); continue }
        if ($code[0] -ne " ") { $staged.Add($line) }
        if ($code[1] -ne " ") { $modified.Add($line) }
    }
    $cand = New-Object System.Collections.Generic.List[string]
    foreach ($ln in $staged)  { if ($ln.Length -ge 4) { $cand.Add($ln.Substring(3)) } }
    foreach ($ln in $modified){ if ($ln.Length -ge 4) { $cand.Add($ln.Substring(3)) } }
    foreach ($p in $untracked){ if ($p) { $cand.Add($p) } }
    foreach ($r in $forceInc) { $cand.Add($r) }
    $seen = @{}
    $hashes = @()
    foreach ($rel in $cand) {
        $relN = ($rel -replace '\\', '/')
        if ($forceExc -contains $relN) { continue }
        if ($seen.ContainsKey($relN)) { continue }
        if ($relN -match '/bin/|/obj/') { continue }
        $full = Join-Path $dir $rel
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $inProj = $false
        foreach ($pr in $resProjects) {
            if ($relN.StartsWith(("src/" + $pr + "/"), [System.StringComparison]::OrdinalIgnoreCase)) { $inProj = $true }
        }
        if (-not ($inProj -or ($forceInc -contains $relN))) { continue }
        $seen[$relN] = $true
        $h = Get-FileHash -LiteralPath $full -Algorithm SHA256
        $hashes += [pscustomobject]@{ path = $relN; sha256 = $h.Hash.ToUpperInvariant(); bytes = (Get-Item -LiteralPath $full).Length }
    }
    $head = ""
    $ho = @(& git -C $dir rev-parse HEAD 2>$null)
    if ($ho.Count -ge 1 -and $ho[0]) { $head = ([string]$ho[0]).Trim() }
    $root = (Resolve-Path -LiteralPath $dir).Path
    $leaf = Split-Path $root -Leaf
    $obj = [ordered]@{
        changeId = "CHG-TEST-0001"
        mode     = "TRIAL"
        reservedScope = [ordered]@{ projects = @($resProjects) }
        repositoryBaselines = @([ordered]@{
            name = $leaf
            path = $root
            isPrimary = $true
            branch = "main"
            headCommit = $head
            preReservationClean = (($staged.Count + $modified.Count + $untracked.Count) -eq 0)
            preExistingChanges = [ordered]@{
                modified = @($modified.ToArray())
                staged   = @($staged.ToArray())
                untracked = @($untracked.ToArray())
            }
            scopeFileHashes = @($hashes)
        })
    }
    ($obj | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $outJson -Encoding UTF8
    return $root
}

function Invoke-Classifier([string]$repoRoot, [string]$resJson) {
    $env:DB06D_REPO = $repoRoot
    $env:DB06D_RESERVATION = $resJson
    Remove-Item Env:\DB06D_REPO_NAME -ErrorAction SilentlyContinue
    $out = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:Engine 2>&1)
    return ($out | ForEach-Object { "$_" }) -join "`n"
}

function Assert-Classified([string]$tag, [string]$outcome, [bool]$expectPass,
                           [string]$expectOutcome, [string]$expectLineSubstring) {
    $hasOutcome = $outcome -match ('DB06D_OUTCOME:\s*' + [regex]::Escape($expectOutcome) + '(\s|$)')
    Report $hasOutcome "$tag outcome" ("expected DB06D_OUTCOME=" + $expectOutcome)
    $resLine = ($outcome -split "`n" | Where-Object { $_ -match 'DB06D_RESULT_PASS' } | Select-Object -First 1)
    $resOk = ($resLine -and (($expectPass -and $resLine -match 'DB06D_RESULT_PASS:\s*True') -or ((-not $expectPass) -and $resLine -match 'DB06D_RESULT_PASS:\s*False')))
    Report $resOk "$tag result" ("expected DB06D_RESULT_PASS=" + $expectPass + "  saw: " + $resLine)
    if ($expectLineSubstring) {
        Report ($outcome -match [regex]::Escape($expectLineSubstring)) "$tag file-verdict" ("expected line containing: " + $expectLineSubstring)
    }
}

$w = "src/Widget"
$o = "src/Other"
$scenario = 0

# ---------------------------------------------------------------- scenario 1
$scenario++
$tag = "S{0:D2}_clean_reserved_modified" -f $scenario
$repo = New-FxRepo $tag
$resJson = Join-Path ([IO.Path]::GetTempPath()) ($tag + "_res.json")
Write-FxFile $repo "$w/Clean.ts" "module v1`n"
Commit-FxAll $repo "baseline"
$root = Export-FxReservation $repo @("Widget") $resJson @() @()
Write-FxFile $repo "$w/Clean.ts" "module v2 (task edit)`n"
Write-FxFile $repo "$w/NewFile.ts" "brand new task file`n"
$out = Invoke-Classifier $root $resJson
Write-Output "--- scenario $scenario ($tag) ---"
$out
Assert-Classified $tag $out $true "DELTA_CLASSIFICATION_PASS" "$w/Clean.ts | CURRENT_TASK_DELTA"
Assert-Classified $tag $out $true "DELTA_CLASSIFICATION_PASS" "$w/NewFile.ts | CURRENT_TASK_DELTA"

# ---------------------------------------------------------------- scenario 2
$scenario++
$tag = "S{0:D2}_dirty_reserved_unchanged" -f $scenario
$repo = New-FxRepo $tag
$resJson = Join-Path ([IO.Path]::GetTempPath()) ($tag + "_res.json")
Write-FxFile $repo "$w/Dirty.ts" "orig`n"
Commit-FxAll $repo "baseline"
Write-FxFile $repo "$w/Dirty.ts" "orig + preexisting edit`n"
$root = Export-FxReservation $repo @("Widget") $resJson @() @()
$out = Invoke-Classifier $root $resJson
Write-Output "--- scenario $scenario ($tag) ---"
$out
Assert-Classified $tag $out $true "DELTA_CLASSIFICATION_PASS" "$w/Dirty.ts | PRE_EXISTING_ONLY"

# ---------------------------------------------------------------- scenario 3
$scenario++
$tag = "S{0:D2}_dirty_reserved_incremental_edit" -f $scenario
$repo = New-FxRepo $tag
$resJson = Join-Path ([IO.Path]::GetTempPath()) ($tag + "_res.json")
Write-FxFile $repo "$w/Dirty.ts" "orig`n"
Commit-FxAll $repo "baseline"
Write-FxFile $repo "$w/Dirty.ts" "orig + preexisting edit`n"
$root = Export-FxReservation $repo @("Widget") $resJson @() @()
Write-FxFile $repo "$w/Dirty.ts" "orig + preexisting edit + task increment`n"
$out = Invoke-Classifier $root $resJson
Write-Output "--- scenario $scenario ($tag) ---"
$out
Assert-Classified $tag $out $true "DELTA_CLASSIFICATION_PASS" "$w/Dirty.ts | PRE_EXISTING_AND_CURRENT_TASK_DELTA"

# ---------------------------------------------------------------- scenario 4
$scenario++
$tag = "S{0:D2}_dirty_out_of_scope_modified" -f $scenario
$repo = New-FxRepo $tag
$resJson = Join-Path ([IO.Path]::GetTempPath()) ($tag + "_res.json")
Write-FxFile $repo "$w/Base.ts" "base`n"
Write-FxFile $repo "$o/Out.ts" "orig`n"
Commit-FxAll $repo "baseline"
# pre-existing dirty file OUT of the reserved scope; fixture models a capture that
# includes its baseline hash (governed DevelopmentControl / repo-wide capture), so a
# later in-place modification is attributable and must FAIL.
Write-FxFile $repo "$o/Out.ts" "orig + preexisting edit`n"
$root = Export-FxReservation $repo @("Widget") $resJson @("$o/Out.ts") @()
Write-FxFile $repo "$o/Out.ts" "orig + preexisting edit + task tamper`n"
$out = Invoke-Classifier $root $resJson
Write-Output "--- scenario $scenario ($tag) ---"
$out
Assert-Classified $tag $out $false "OUT_OF_SCOPE_MODIFICATION" "$o/Out.ts | OUT_OF_SCOPE_MODIFICATION"

# clean out-of-scope tracked modified (guard)
$scenario++
$tag = "S{0:D2}_clean_out_of_scope_modified" -f $scenario
$repo = New-FxRepo $tag
$resJson = Join-Path ([IO.Path]::GetTempPath()) ($tag + "_res.json")
Write-FxFile $repo "$w/Base.ts" "base`n"
Write-FxFile $repo "$o/Clean.ts" "orig`n"
Commit-FxAll $repo "baseline"
$root = Export-FxReservation $repo @("Widget") $resJson @() @()
Write-FxFile $repo "$o/Clean.ts" "task touched out of scope`n"
$out = Invoke-Classifier $root $resJson
Write-Output "--- scenario $scenario ($tag) ---"
$out
Assert-Classified $tag $out $false "OUT_OF_SCOPE_MODIFICATION" "$o/Clean.ts | OUT_OF_SCOPE_MODIFICATION"

# brand-new out-of-scope file created by the task (guard)
$scenario++
$tag = "S{0:D2}_new_out_of_scope_file" -f $scenario
$repo = New-FxRepo $tag
$resJson = Join-Path ([IO.Path]::GetTempPath()) ($tag + "_res.json")
Write-FxFile $repo "$w/Base.ts" "base`n"
Write-FxFile $repo "$o/Keep.ts" "keep`n"
Commit-FxAll $repo "baseline"
$root = Export-FxReservation $repo @("Widget") $resJson @() @()
Write-FxFile $repo "$o/BrandNew.ts" "task created out of scope`n"
$out = Invoke-Classifier $root $resJson
Write-Output "--- scenario $scenario ($tag) ---"
$out
Assert-Classified $tag $out $false "OUT_OF_SCOPE_MODIFICATION" "$o/BrandNew.ts | OUT_OF_SCOPE_MODIFICATION"

# ---------------------------------------------------------------- scenario 5
$scenario++
$tag = "S{0:D2}_dirty_reserved_reverted" -f $scenario
$repo = New-FxRepo $tag
$resJson = Join-Path ([IO.Path]::GetTempPath()) ($tag + "_res.json")
Write-FxFile $repo "$w/Dirty.ts" "orig`n"
Commit-FxAll $repo "baseline"
Write-FxFile $repo "$w/Dirty.ts" "orig + preexisting edit`n"
$root = Export-FxReservation $repo @("Widget") $resJson @() @()
& git -C $repo checkout -- "$w/Dirty.ts"
if ($LASTEXITCODE -ne 0) { throw "git checkout failed" }
$out = Invoke-Classifier $root $resJson
Write-Output "--- scenario $scenario ($tag) ---"
$out
Assert-Classified $tag $out $false "REVERT_CLEANED_PRE_EXISTING" "$w/Dirty.ts | REVERT_CLEANED_PRE_EXISTING"

# pre-existing tracked change deleted (guard)
$scenario++
$tag = "S{0:D2}_dirty_reserved_deleted" -f $scenario
$repo = New-FxRepo $tag
$resJson = Join-Path ([IO.Path]::GetTempPath()) ($tag + "_res.json")
Write-FxFile $repo "$w/Dirty.ts" "orig`n"
Commit-FxAll $repo "baseline"
Write-FxFile $repo "$w/Dirty.ts" "orig + preexisting edit`n"
$root = Export-FxReservation $repo @("Widget") $resJson @() @()
Remove-FxFile $repo "$w/Dirty.ts"
$out = Invoke-Classifier $root $resJson
Write-Output "--- scenario $scenario ($tag) ---"
$out
Assert-Classified $tag $out $false "REVERT_CLEANED_PRE_EXISTING" "$w/Dirty.ts | REVERT_CLEANED_PRE_EXISTING"

# ---------------------------------------------------------------- scenario 6
$scenario++
$tag = "S{0:D2}_preexisting_staged_claimed" -f $scenario
$repo = New-FxRepo $tag
$resJson = Join-Path ([IO.Path]::GetTempPath()) ($tag + "_res.json")
Write-FxFile $repo "$w/Dirty.ts" "orig`n"
Commit-FxAll $repo "baseline"
Write-FxFile $repo "$w/Dirty.ts" "orig + preexisting edit`n"
$root = Export-FxReservation $repo @("Widget") $resJson @() @()
# task stages the pre-existing content WITHOUT adding any of its own delta
& git -C $repo add "$w/Dirty.ts"
if ($LASTEXITCODE -ne 0) { throw "git add failed" }
$out = Invoke-Classifier $root $resJson
Write-Output "--- scenario $scenario ($tag) ---"
$out
Assert-Classified $tag $out $false "STAGED_PREEXISTING_CHANGE" "$w/Dirty.ts | STAGED_PREEXISTING_CHANGE"

# ---------------------------------------------------------------- scenario 7
$scenario++
$tag = "S{0:D2}_untracked_baseline_edit" -f $scenario
$repo = New-FxRepo $tag
$resJson = Join-Path ([IO.Path]::GetTempPath()) ($tag + "_res.json")
Write-FxFile $repo "$w/Base.ts" "base`n"
Commit-FxAll $repo "baseline"
Write-FxFile $repo "$w/Untr.ts" "untracked pre-existing`n"
$root = Export-FxReservation $repo @("Widget") $resJson @() @()
Write-FxFile $repo "$w/Untr.ts" "untracked pre-existing + task increment`n"
$out = Invoke-Classifier $root $resJson
Write-Output "--- scenario $scenario ($tag) ---"
$out
Assert-Classified $tag $out $true "DELTA_CLASSIFICATION_PASS" "$w/Untr.ts | PRE_EXISTING_AND_CURRENT_TASK_DELTA"

# ---------------------------------------------------------------- scenario 8
$scenario++
$tag = "S{0:D2}_untracked_no_baseline" -f $scenario
$repo = New-FxRepo $tag
$resJson = Join-Path ([IO.Path]::GetTempPath()) ($tag + "_res.json")
Write-FxFile $repo "$w/Base.ts" "base`n"
Commit-FxAll $repo "baseline"
Write-FxFile $repo "$w/NoHash.ts" "untracked pre-existing`n"
# DB-M04 did NOT capture a pre-reservation content hash for this in-scope untracked file
$root = Export-FxReservation $repo @("Widget") $resJson @() @("$w/NoHash.ts")
Write-FxFile $repo "$w/NoHash.ts" "untracked pre-existing + task increment`n"
$out = Invoke-Classifier $root $resJson
Write-Output "--- scenario $scenario ($tag) ---"
$out
Assert-Classified $tag $out $false "PREEXISTING_FILE_BASELINE_INSUFFICIENT" "$w/NoHash.ts | PREEXISTING_FILE_BASELINE_INSUFFICIENT"

# --------------------------------------------- HEAD-advance guard (a commit was made)
$scenario++
$tag = "S{0:D2}_head_advanced_commit" -f $scenario
$repo = New-FxRepo $tag
$resJson = Join-Path ([IO.Path]::GetTempPath()) ($tag + "_res.json")
Write-FxFile $repo "$w/A.ts" "a`n"
Commit-FxAll $repo "baseline"
$root = Export-FxReservation $repo @("Widget") $resJson @() @()
Write-FxFile $repo "$w/B.ts" "task commit`n"
& git -C $repo add "$w/B.ts"
if ($LASTEXITCODE -ne 0) { throw "git add failed" }
& git -C $repo commit -q -m "task committed (forbidden)"
if ($LASTEXITCODE -ne 0) { throw "git commit failed" }
$out = Invoke-Classifier $root $resJson
Write-Output "--- scenario $scenario ($tag) ---"
$out
Report ($out -match 'DB06D_OUTCOME:\s*STAGED_PREEXISTING_CHANGE') "$tag outcome" "expected commit/HEAD-advance to FAIL"
$resLine = ($out -split "`n" | Where-Object { $_ -match 'DB06D_RESULT_PASS' } | Select-Object -First 1)
Report ($resLine -and ($resLine -match 'DB06D_RESULT_PASS:\s*False')) "$tag result" "expected PASS=False"

Write-Output ""
Write-Output ("DB-M06 PRE-EXISTING DELTA SUMMARY: {0} passed, {1} failed" -f $script:PassCount, $script:FailCount)
if ($script:FailCount -gt 0) { exit 1 } else { exit 0 }
