# Measure-Dbm06ImplementationDelta.ps1
# DevBridge DB-M06 git-baseline delta classification stage.
#
# Classifies, for ONE reserved repository, whether the post-implementation
# working tree differs from the captured DB-M04 pre-implementation baseline in a
# way that is attributable to the CURRENT TASK - and, critically, separates files
# that were ALREADY dirty/untracked before reservation from incremental edits the
# current task makes afterwards.
#
# Policy (guards the DB-M05 handoff wording):
#   - Pre-existing content stays PRE-EXISTING CHANGE; the task must not revert,
#     clean, stage, commit or claim it.
#   - A pre-existing dirty/untracked file may receive a MINIMAL current-task edit
#     only when it is inside the exact reserved scope and required by the
#     acceptance criteria, and DevBridge captured its pre-reservation content
#     hash so the incremental delta can be attributed.
#   - If DevBridge cannot attribute the delta for a reserved pre-existing file
#     (baseline hash missing), the stage STOPS with
#     PREEXISTING_FILE_BASELINE_INSUFFICIENT rather than guessing.
#
# Hash model (important): DB-M04 captures SHA-256 of pre-existing file CONTENT.
# This stage therefore compares SHA-256 (on-disk file) ONLY against captured
# SHA-256 baselines. git object ids are never compared to content hashes.
# "Working tree == HEAD content" for a tracked file is inferred from porcelain
# absence: a tracked file that git status does NOT list provably has
# index == HEAD and worktree == index, i.e. content == HEAD.
#
# This stage is READ-ONLY over the repository working tree (git status /
# rev-parse / file hashing). It never modifies the workbook, the repo, or any
# Nexus source. Fixture/test mode: point DB06D_REPO at a throwaway repo and
# DB06D_RESERVATION at a synthetic or real reservation.json.
#
# Backend contract: ALWAYS exits 0. Outcomes are communicated ONLY via stdout
# markers (DB06D_*). ASCII-only source (PS 5.1).
param()
$ErrorActionPreference = "Continue"

$script:RepoPath = [string]$env:DB06D_REPO
$script:ResPath = [string]$env:DB06D_RESERVATION

function Get-DevBridgeField([object]$obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $f = $obj.PSObject.Properties[$name]
    if ($null -eq $f) { return $null }
    return $f.Value
}

function Read-JsonFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function ConvertTo-RelPath([string]$p) {
    $p = [string]$p
    # porcelain lines are "XY path": index 2 is always a literal space separator.
    # Test on the UNTRIMMED string (a leading space in " M path" is the X column);
    # bare paths (pre-existing untracked entries) have no such prefix.
    if ($p.Length -ge 3 -and $p[2] -eq ' ') { return $p.Substring(3).Trim() }
    return $p.Trim()
}

function Get-FileSha256([string]$fullPath) {
    $h = Get-FileHash -LiteralPath $fullPath -Algorithm SHA256
    return ([string]$h.Hash).ToUpperInvariant()
}

function Get-CurrentGitState([string]$repo) {
    # returns PSCustomObject { present, staged, head }
    $present = New-Object 'System.Collections.Generic.HashSet[string]'
    $staged = New-Object 'System.Collections.Generic.HashSet[string]'
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $lines = @(& git -C $repo status --porcelain=v1 2>$null) } catch { $lines = @() }
    $ErrorActionPreference = $oldEap
    foreach ($_ln in $lines) {
        $_ln = [string]$_ln
        if ($_ln.Length -lt 4) { continue }
        $_code = $_ln.Substring(0, 2)
        $_rel = $_ln.Substring(3)
        $null = $present.Add($_rel)
        $_x = $_code[0]
        if ($_x -ne ' ' -and $_x -ne '?') { $null = $staged.Add($_rel) }
    }
    $st = New-Object PSCustomObject
    $st | Add-Member -NotePropertyName present -NotePropertyValue $present -Force
    $st | Add-Member -NotePropertyName staged -NotePropertyValue $staged -Force
    return $st
}

# ---- load reservation + locate the baseline entry for this repository ----
$res = Read-JsonFile $script:ResPath
if ($null -eq $res) {
    Write-Output "DB06D_OUTCOME: STOP_RESERVATION_MISSING"
    Write-Output "DB06D_RESULT_PASS: False"
    Write-Output ("DB06D_EVIDENCE: reservation not readable at " + $script:ResPath)
    exit 0
}
if (-not $script:RepoPath -or -not (Test-Path -LiteralPath $script:RepoPath)) {
    Write-Output "DB06D_OUTCOME: STOP_REPO_MISSING"
    Write-Output "DB06D_RESULT_PASS: False"
    Write-Output ("DB06D_EVIDENCE: repo not readable at " + $script:RepoPath)
    exit 0
}
$script:RepoRoot = (Resolve-Path -LiteralPath $script:RepoPath).Path
$script:RepoLeaf = Split-Path $script:RepoRoot -Leaf
$script:RepoLabel = if ($env:DB06D_REPO_NAME) { [string]$env:DB06D_REPO_NAME } else { $script:RepoLeaf }

$baselines = @(Get-DevBridgeField $res 'repositoryBaselines')
$rb = $null
foreach ($_b in $baselines) {
    $_p = [string](Get-DevBridgeField $_b 'path')
    if (-not $_p) { continue }
    try { $_full = (Resolve-Path -LiteralPath $_p -ErrorAction Stop).Path } catch { continue }
    if ($_full -ieq $script:RepoRoot) { $rb = $_b; break }
    $_name = [string](Get-DevBridgeField $_b 'name')
    if ($_name -and $_name -ieq $script:RepoLeaf) { $rb = $_b; break }
    if ($_name -and $_name -ieq $script:RepoLabel) { $rb = $_b; break }
}
if ($null -eq $rb) {
    # legacy single gitBaseline shape - synthesize a baseline object
    $gb = Get-DevBridgeField $res 'gitBaseline'
    if ($null -ne $gb) {
        $rb = New-Object PSCustomObject
        $rb | Add-Member -NotePropertyName name -NotePropertyValue $script:RepoLabel -Force
        $rb | Add-Member -NotePropertyName path -NotePropertyValue $script:RepoRoot -Force
        $rb | Add-Member -NotePropertyName isPrimary -NotePropertyValue $true -Force
        $rb | Add-Member -NotePropertyName headCommit -NotePropertyValue (Get-DevBridgeField $gb 'headCommit') -Force
        $pre = Get-DevBridgeField $gb 'preExistingChanges'
        if ($null -eq $pre) {
            $pre = New-Object PSCustomObject
            $pre | Add-Member -NotePropertyName modified -NotePropertyValue @() -Force
            $pre | Add-Member -NotePropertyName staged -NotePropertyValue @() -Force
            $pre | Add-Member -NotePropertyName untracked -NotePropertyValue @() -Force
        }
        $rb | Add-Member -NotePropertyName preExistingChanges -NotePropertyValue $pre -Force
        $rb | Add-Member -NotePropertyName scopeFileHashes -NotePropertyValue @(Get-DevBridgeField $gb 'scopeFileHashes') -Force
    }
}
if ($null -eq $rb) {
    Write-Output "DB06D_OUTCOME: STOP_RESERVATION_REPO_NOT_FOUND"
    Write-Output "DB06D_RESULT_PASS: False"
    Write-Output ("DB06D_EVIDENCE: no repositoryBaselines entry matches repo " + $script:RepoRoot)
    exit 0
}

# captured head commit - used to detect that the task committed (forbidden)
$capturedHead = ([string](Get-DevBridgeField $rb 'headCommit')).Trim()
if ($capturedHead) {
    $nowHead = ""
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $ho = @(& git -C $script:RepoRoot rev-parse HEAD 2>$null) } catch { $ho = @() }
    $ErrorActionPreference = $oldEap
    if ($ho.Count -ge 1 -and $ho[0]) { $nowHead = ([string]$ho[0]).Trim() }
    if ($nowHead -and ($nowHead -ne $capturedHead)) {
        Write-Output "DB06D_OUTCOME: STAGED_PREEXISTING_CHANGE"
        Write-Output "DB06D_RESULT_PASS: False"
        Write-Output "DB06D_EVIDENCE: repository HEAD advanced during implementation (a commit was made); committing is outside this task's authority - human handles git"
        exit 0
    }
}

$pre = Get-DevBridgeField $rb 'preExistingChanges'
$baseDirty = New-Object 'System.Collections.Generic.HashSet[string]'
$baseUntracked = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($_s in @(Get-DevBridgeField $pre 'staged'))   { $null = $baseDirty.Add((ConvertTo-RelPath ([string]$_s)).Replace('\','/')) }
foreach ($_m in @(Get-DevBridgeField $pre 'modified')) { $null = $baseDirty.Add((ConvertTo-RelPath ([string]$_m)).Replace('\','/')) }
foreach ($_u in @(Get-DevBridgeField $pre 'untracked')){ $null = $baseUntracked.Add(([string]$_u).Trim().Replace('\','/')) }

$baseHash = @{}
foreach ($_h in @(Get-DevBridgeField $rb 'scopeFileHashes')) {
    $_p = ([string](Get-DevBridgeField $_h 'path')).Replace('\','/')
    $_s = [string](Get-DevBridgeField $_h 'sha256')
    if ($_p) { $baseHash[$_p] = $_s.ToUpperInvariant() }
}

# ---- reserved project dirs owned by THIS repo: repo\src\<project>\ exists ----
$ownedProjects = @()
foreach ($_pr in @(Get-DevBridgeField (Get-DevBridgeField $res 'reservedScope') 'projects')) {
    $_pr = [string]$_pr
    if (-not $_pr) { continue }
    if (Test-Path -LiteralPath (Join-Path $script:RepoRoot ("src\" + $_pr))) { $ownedProjects += $_pr }
}
function Test-InScope([string]$rel) {
    $rel = $rel -replace '\\','/'
    foreach ($_pr in $ownedProjects) {
        if ($rel.StartsWith(("src/" + $_pr + "/"), [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

$isPrimary = [bool](Get-DevBridgeField $rb 'isPrimary')
$state = Get-CurrentGitState $script:RepoRoot
$presentSet = $state.present
$stagedSet = $state.staged

# ---- candidate paths ----
$cands = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($_p in $baseDirty)     { $null = $cands.Add($_p) }
foreach ($_p in $baseUntracked) { $null = $cands.Add($_p) }
foreach ($_p in $baseHash.Keys) { $null = $cands.Add($_p) }
foreach ($_p in $presentSet)    { $null = $cands.Add($_p) }

$verdicts = New-Object System.Collections.Generic.List[string]
$fails = New-Object System.Collections.Generic.List[string]
$stops = New-Object System.Collections.Generic.List[string]

foreach ($_rel in $cands) {
    $_rel = $_rel -replace '\\','/'
    if (-not $_rel) { continue }
    if ($isPrimary -and $_rel -match 'NEXUS_DEVELOPMENT_CONTROL\.xlsx$') { continue }

    $wasDirty = $baseDirty.Contains($_rel)
    $wasUntracked = $baseUntracked.Contains($_rel)
    $baseH = if ($baseHash.ContainsKey($_rel)) { $baseHash[$_rel] } else { "" }
    $inScope = Test-InScope $_rel
    $present = $presentSet.Contains($_rel)
    $stagedNow = $stagedSet.Contains($_rel)

    $full = Join-Path $script:RepoRoot $_rel
    $exists = Test-Path -LiteralPath $full
    if ($exists) {
        $item = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue
        if ($null -ne $item -and $item.PSIsContainer) {
            # git collapses a wholly-untracked directory to a single "?? dir/" line;
            # files added inside it surface as their own porcelain lines when the
            # parent tree is tracked, so skipping the directory itself is safe.
            continue
        }
    }
    $curH = if ($exists) { Get-FileSha256 $full } else { "" }

    # ---- governance workbook writes are not task delta ----
    # (handled above)

    # ---- 1. pre-existing UNTRACKED file ----
    if ($wasUntracked) {
        if (-not $exists) {
            $fails.Add("REVERT_CLEANED_PRE_EXISTING") | Out-Null
            $verdicts.Add("DB06D_FILE: " + $_rel + " | REVERT_CLEANED_PRE_EXISTING (deleted pre-existing untracked file)") | Out-Null
            continue
        }
        if ($inScope) {
            if ($baseH -eq "") {
                # task is allowed to edit in-scope pre-existing files ONLY when a
                # baseline hash was captured; without it the delta is unattributable.
                $stops.Add("PREEXISTING_FILE_BASELINE_INSUFFICIENT") | Out-Null
                $verdicts.Add("DB06D_FILE: " + $_rel + " | PREEXISTING_FILE_BASELINE_INSUFFICIENT (in-scope pre-existing untracked file has no captured baseline hash)") | Out-Null
                continue
            }
            if ($stagedNow -and ($curH -ieq $baseH)) {
                $fails.Add("STAGED_PREEXISTING_CHANGE") | Out-Null
                $verdicts.Add("DB06D_FILE: " + $_rel + " | STAGED_PREEXISTING_CHANGE (staged pre-existing untracked content unchanged)") | Out-Null
                continue
            }
            if ($curH -ieq $baseH) {
                $verdicts.Add("DB06D_FILE: " + $_rel + " | PRE_EXISTING_ONLY (untracked; unchanged since baseline)") | Out-Null
            } else {
                $verdicts.Add("DB06D_FILE: " + $_rel + " | PRE_EXISTING_AND_CURRENT_TASK_DELTA (untracked baseline captured; incremental edit detectable)") | Out-Null
            }
            continue
        }
        # out of scope
        if (($baseH -ne "") -and ($curH -ine $baseH)) {
            $fails.Add("OUT_OF_SCOPE_MODIFICATION") | Out-Null
            $verdicts.Add("DB06D_FILE: " + $_rel + " | OUT_OF_SCOPE_MODIFICATION (pre-existing out-of-scope untracked file changed after baseline)") | Out-Null
            continue
        }
        if ($stagedNow) {
            $fails.Add("STAGED_PREEXISTING_CHANGE") | Out-Null
            $verdicts.Add("DB06D_FILE: " + $_rel + " | STAGED_PREEXISTING_CHANGE (staged pre-existing out-of-scope untracked file)") | Out-Null
            continue
        }
        $verdicts.Add("DB06D_FILE: " + $_rel + " | PRE_EXISTING_ONLY (untracked; out of scope)") | Out-Null
        continue
    }

    # ---- 2. pre-existing tracked (modified/staged) file ----
    if ($wasDirty) {
        if (-not $exists) {
            $fails.Add("REVERT_CLEANED_PRE_EXISTING") | Out-Null
            $verdicts.Add("DB06D_FILE: " + $_rel + " | REVERT_CLEANED_PRE_EXISTING (deleted pre-existing tracked change)") | Out-Null
            continue
        }
        if ($inScope) {
            if ($baseH -eq "") {
                $stops.Add("PREEXISTING_FILE_BASELINE_INSUFFICIENT") | Out-Null
                $verdicts.Add("DB06D_FILE: " + $_rel + " | PREEXISTING_FILE_BASELINE_INSUFFICIENT (in-scope pre-existing dirty file has no captured baseline hash)") | Out-Null
                continue
            }
            if (-not $present) {
                # porcelain absence proves worktree content == HEAD: the pre-existing
                # edit was cleaned/reverted away - forbidden.
                $fails.Add("REVERT_CLEANED_PRE_EXISTING") | Out-Null
                $verdicts.Add("DB06D_FILE: " + $_rel + " | REVERT_CLEANED_PRE_EXISTING (cleaned/reverted to HEAD, dropping the pre-existing edit)") | Out-Null
                continue
            }
            if ($stagedNow -and ($curH -ieq $baseH)) {
                $fails.Add("STAGED_PREEXISTING_CHANGE") | Out-Null
                $verdicts.Add("DB06D_FILE: " + $_rel + " | STAGED_PREEXISTING_CHANGE (staged pre-existing content unchanged)") | Out-Null
                continue
            }
            if ($curH -ieq $baseH) {
                $verdicts.Add("DB06D_FILE: " + $_rel + " | PRE_EXISTING_ONLY (unchanged since baseline)") | Out-Null
            } else {
                $verdicts.Add("DB06D_FILE: " + $_rel + " | PRE_EXISTING_AND_CURRENT_TASK_DELTA (incremental edit on pre-existing dirty file)") | Out-Null
            }
            continue
        }
        # out of scope
        if (-not $present) {
            $fails.Add("REVERT_CLEANED_PRE_EXISTING") | Out-Null
            $verdicts.Add("DB06D_FILE: " + $_rel + " | REVERT_CLEANED_PRE_EXISTING (out-of-scope pre-existing change cleaned/reverted to HEAD)") | Out-Null
            continue
        }
        if (($baseH -ne "") -and ($curH -ine $baseH)) {
            $fails.Add("OUT_OF_SCOPE_MODIFICATION") | Out-Null
            $verdicts.Add("DB06D_FILE: " + $_rel + " | OUT_OF_SCOPE_MODIFICATION (pre-existing out-of-scope tracked file changed after baseline)") | Out-Null
            continue
        }
        if ($stagedNow) {
            $fails.Add("STAGED_PREEXISTING_CHANGE") | Out-Null
            $verdicts.Add("DB06D_FILE: " + $_rel + " | STAGED_PREEXISTING_CHANGE (staged pre-existing out-of-scope change)") | Out-Null
            continue
        }
        $verdicts.Add("DB06D_FILE: " + $_rel + " | PRE_EXISTING_ONLY (out of scope)") | Out-Null
        continue
    }

    # ---- 3. file clean at baseline (incl. governed-folder files hashed but clean) ----
    if ($present) {
        if ($inScope) {
            $verdicts.Add("DB06D_FILE: " + $_rel + " | CURRENT_TASK_DELTA (changed/new inside reserved scope)") | Out-Null
        } else {
            $fails.Add("OUT_OF_SCOPE_MODIFICATION") | Out-Null
            $verdicts.Add("DB06D_FILE: " + $_rel + " | OUT_OF_SCOPE_MODIFICATION (clean/new file outside reserved scope modified or created)") | Out-Null
        }
    }
    # not present and clean at baseline: nothing to report
}

# ---- emit ----
foreach ($v in $verdicts) { Write-Output $v }
if ($fails.Count -gt 0) {
    $top = @('OUT_OF_SCOPE_MODIFICATION','REVERT_CLEANED_PRE_EXISTING','STAGED_PREEXISTING_CHANGE') | Where-Object { $fails.Contains($_) } | Select-Object -First 1
    if (-not $top) { $top = $fails[0] }
    Write-Output ("DB06D_OUTCOME: " + $top)
    Write-Output "DB06D_RESULT_PASS: False"
    Write-Output ("DB06D_EVIDENCE: " + (($fails | Sort-Object -Unique) -join "; "))
    exit 0
}
if ($stops.Count -gt 0) {
    Write-Output "DB06D_OUTCOME: PREEXISTING_FILE_BASELINE_INSUFFICIENT"
    Write-Output "DB06D_RESULT_PASS: False"
    Write-Output ("DB06D_EVIDENCE: " + ($stops[0]) + " - baseline cannot attribute an incremental delta for a reserved pre-existing file; stop rather than guess")
    exit 0
}
Write-Output "DB06D_OUTCOME: DELTA_CLASSIFICATION_PASS"
Write-Output "DB06D_RESULT_PASS: True"
Write-Output ("DB06D_REPO: " + $script:RepoLabel)
exit 0
