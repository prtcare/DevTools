# Confirm-CorrectedImplementation.ps1 - DB-M15 governed correction reconciliation
# (reusable lifecycle command for RECONCILE_CORRECTION).
#
# Detects whether a CORRECT_CURRENT_ATTEMPT was implemented OUTSIDE DevBridge by
# comparing the CURRENT post-correction current-task delta of every reserved
# repository against the reference delta captured at DB-M09 fix-context time:
#
#   reference (primary) : current-task dbM09.fixBaseline - repo-relative path +
#                         SHA-256, captured by New-CorrectionContext.ps1 (DB-M09)
#                         on a FRESH fix-context creation.
#   reference (fallback): tasks\CLAUDE_REVIEW_PACKAGE.md (DB-M07 manifest) section 5
#                         CURRENT_TASK_DELTA file list - path-only. A live cycle whose
#                         dbM09 predates the fixBaseline capture falls back here.
#
# It re-runs the READ-ONLY DB-M06 delta classifier (Measure-Dbm06ImplementationDelta)
# fresh over the reserved repositories. Any classification defect (out-of-scope /
# revert / staged / commit) STOPS with STOP_DELTA_CLASSIFICATION_DEFECT - DevBridge
# never reconciles an unattributable delta. The incremental correction delta is the
# current current-task delta MINUS the reference: files that are NET-NEW, or - when a
# SHA-256 baseline exists - previously-delta files whose content CHANGED since M09.
#
# When a delta is detected it stamps current-task dbM09.correctionReconciled
# { result: CORRECTION_DELTA_DETECTED, ... } while preserving every other dbM09 field
# and LEAVING the lifecycle status DB_M09_FIX_REQUIRED. The engine then enables
# RUN VERIFICATION so the corrected attempt is FRESH DB-M06 verified before it ever
# returns to Claude. When no incremental delta exists it reports CORRECTION_DELTA_NONE
# and stamps nothing. DB-M15 NEVER re-runs implementation or verification itself.
#
# Backend contract: ALWAYS exits 0; outcomes ONLY via stdout markers (DB15_*).
# State/tasks dirs redirect with DB15_STATE_DIR / DB15_TASKS_DIR. Selftest:
# DB15_SELFTEST=1 with DB15_SELFTEST_RESULT (CORRECTION_DELTA_DETECTED |
# CORRECTION_DELTA_NONE) and optional DB15_SELFTEST_DELTA (| delimited rel paths).
#
# ASCII-only source (PS 5.1 + BOM-safe).
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Set-DevBridgeStateEntry.ps1")

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:StateDir = Join-Path $script:Root "state"
$script:TasksDir = Join-Path $script:Root "tasks"
$script:CfgPath = Join-Path $script:Root "config\devbridge.json"
if ($env:DB15_STATE_DIR) { $script:StateDir = $env:DB15_STATE_DIR }
if ($env:DB15_TASKS_DIR) { $script:TasksDir = $env:DB15_TASKS_DIR }
$script:CurrentTaskPath = Join-Path $script:StateDir "current-task.json"
$script:ResPath = Join-Path $script:StateDir "reservation.json"
$script:ManifestPath = Join-Path $script:TasksDir "CLAUDE_REVIEW_PACKAGE.md"
$script:Classifier = Join-Path $PSScriptRoot "Measure-Dbm06ImplementationDelta.ps1"
$script:NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

function Out-Markers([string]$token, [bool]$pass, [string[]]$evidence) {
    Write-Output ("DB15_OUTCOME: " + $token)
    Write-Output ("DB15_RESULT_PASS: " + $(if ($pass) { "True" } else { "False" }))
    Write-Output ("DB15_RESULT_CODE: " + $token)
    Write-Output "DB15_WORKBOOK_MODIFIED: False"
    Write-Output "DB15_NEXUS_SOURCE_MODIFIED: False"
    Write-Output "DB15_GIT_MODIFIED: False"
    Write-Output "DB15_REQUIRES_HUMAN_ACTION: False"
    Write-Output "DB15_HUMAN_ACTION_TYPE:"
    foreach ($e in $evidence) { Write-Output ("DB15_EVIDENCE: " + $e) }
    exit 0
}

# ---- DB-M07 manifest section 5 parse (path-only reference fallback) ----
# Format (emitted by New-ClaudeReviewPackage.ps1), one block per reserved repository:
#   ### <Name> (<absolute repo path>)
#   - Classification: DELTA_CLASSIFICATION_PASS
#   - CURRENT_TASK_DELTA files: NONE
#   ...or...
#   - CURRENT_TASK_DELTA files (review each of these):
#       - <repo-relative path>
# Returns a hashtable keyed by lower-cased absolute repo path -> List[string] rels.
function Get-ManifestCurrentTaskDelta {
    $result = @{}
    if (-not (Test-Path -LiteralPath $script:ManifestPath)) { return $result }
    $lines = [System.IO.File]::ReadAllLines($script:ManifestPath)
    $curRepoKey = $null
    $inDeltaList = $false
    foreach ($_raw in $lines) {
        $_t = [string]$_raw
        $h = [regex]::Match($_t, '^###\s+(.+?)\s+\((.+)\)\s*$')
        if ($h.Success) {
            $curRepoKey = $h.Groups[2].Value.Trim().ToLowerInvariant()
            $inDeltaList = $false
            if (-not $result.ContainsKey($curRepoKey)) {
                $result[$curRepoKey] = (New-Object System.Collections.Generic.List[string])
            }
            continue
        }
        if ($null -eq $curRepoKey) { continue }
        if ($_t -match '^-\s*CURRENT_TASK_DELTA files:\s*NONE\s*$') { $inDeltaList = $false; continue }
        if ($_t -match '^-\s*CURRENT_TASK_DELTA files\b.*:\s*$') { $inDeltaList = $true; continue }
        if ($_t -match '^-\s*\S') { $inDeltaList = $false; continue }
        if ($inDeltaList -and $_t -match '^\s{4}-\s+(.+?)\s*$') {
            $result[$curRepoKey].Add(($Matches[1].Trim()).Replace('\', '/'))
        }
    }
    return $result
}

# ---- fresh DB06D classification of ONE reserved repository ----
# Returns { Outcome, Rels } ; Rels holds the CURRENT_TASK_DELTA repo-relative paths.
function Invoke-DeltaClassification([string]$repoPath, [string]$resPath) {
    $env:DB06D_REPO = $repoPath
    $env:DB06D_RESERVATION = $resPath
    $co = @()
    try {
        $co = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Classifier 2>&1)
    } finally {
        Remove-Item env:DB06D_REPO -ErrorAction SilentlyContinue
        Remove-Item env:DB06D_RESERVATION -ErrorAction SilentlyContinue
    }
    $co = @($co | ForEach-Object { "$_" })
    $joined = ($co -join "`n")
    $om = [regex]::Match($joined, 'DB06D_OUTCOME:\s*(\S+)')
    $outcome = if ($om.Success) { $om.Groups[1].Value } else { "NO_OUTCOME" }
    if ($outcome -ne "DELTA_CLASSIFICATION_PASS") {
        return @{ Outcome = $outcome; Rels = @() }
    }
    $rels = New-Object System.Collections.Generic.List[string]
    foreach ($_line in $co) {
        if ($_line -notlike 'DB06D_FILE:*') { continue }
        $dm = [regex]::Match($_line, 'DB06D_FILE:\s*([^|]+?)\s*\|\s*([A-Z_]+)')
        if (-not $dm.Success) { continue }
        if ($dm.Groups[2].Value -like '*CURRENT_TASK_DELTA*') { $rels.Add($dm.Groups[1].Value.Trim()) }
    }
    return @{ Outcome = $outcome; Rels = @($rels) }
}

function Get-Sha256([string]$fullPath) {
    if (-not (Test-Path -LiteralPath $fullPath)) { return "" }
    try { return ([string](Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash).ToUpperInvariant() }
    catch { return "" }
}

$ct = Read-DevBridgeJson $script:CurrentTaskPath
if ($null -eq $ct) { Out-Markers "STOP_NO_CURRENT_TASK" $false @("No current-task.json; run DB-M03 preflight first.") }

$status = [string](Get-DevBridgeField $ct "status")
if ($status -ne "DB_M09_FIX_REQUIRED") {
    Out-Markers "STOP_INVALID_LIFECYCLE_STATE" $false @("A corrected implementation can only be reconciled from DB_M09_FIX_REQUIRED (current: '$status').")
}

$nodeId = [string](Get-DevBridgeField $ct "nodeId")
$changeId = [string](Get-DevBridgeField $ct "changeId")
if (-not $nodeId) { $nodeId = [string](Get-DevBridgeField $ct "taskId") }

$claude = Read-DevBridgeJson (Join-Path $script:StateDir "claude-review.json")
$decision = [string](Get-DevBridgeField $claude "decision")
if ($decision -ne "FIX") {
    Out-Markers "STOP_NO_FIX_DECISION" $false @("Claude decision is '$decision'; a FIX decision is required to reconcile a corrected implementation.")
}

# ---- selftest mode: driven outcome, still exercises the reconciliation stamp ----
if ($env:DB15_SELFTEST -eq "1") {
    $sr = [string]$env:DB15_SELFTEST_RESULT
    $delta = @()
    if ($env:DB15_SELFTEST_DELTA) { $delta = @($env:DB15_SELFTEST_DELTA -split '\|') }
    if ($sr -ne "CORRECTION_DELTA_DETECTED") {
        Out-Markers "CORRECTION_DELTA_NONE" $true @("Selftest: no incremental correction delta detected.")
    }
    # Build the reconciliation stamp through the SAME shape the live detection path
    # uses (a List[object] of per-repo entries embedded via .ToArray()). This keeps
    # the selftest a faithful regression for the real stamp construction.
    $deltaRepos = New-Object System.Collections.Generic.List[object]
    $deltaRepos.Add([ordered]@{ name = "selftest"; deltaFiles = @($delta) })
    $rec = [ordered]@{
        result          = "CORRECTION_DELTA_DETECTED"
        reconciledAtUtc = $script:NowUtc
        reference       = "selftest"
        nodeId          = $nodeId
        changeId        = $changeId
        repos           = @($deltaRepos.ToArray())
    }
    $db9 = Get-DevBridgeField $ct "dbM09"
    if ($null -eq $db9) { $db9 = [ordered]@{ nodeId = $nodeId; changeId = $changeId } }
    $db9["correctionReconciled"] = $rec
    Set-DevBridgeStateEntry $script:CurrentTaskPath @{ dbM09 = $db9 }
    foreach ($_d in $delta) { Write-Output ("DB15_DELTA_FILE: selftest|" + $_d) }
    Out-Markers "CORRECTION_DELTA_DETECTED" $true @("Selftest: current-task dbM09.correctionReconciled stamped (CORRECTION_DELTA_DETECTED).")
}

# ---- reference selection: dbM09.fixBaseline (hash) primary, manifest section 5 (path) ----
$db9 = Get-DevBridgeField $ct "dbM09"
$fixBaseline = Get-DevBridgeField $db9 "fixBaseline"
$referenceToken = "manifest_current_task_delta"
$refRepoByPath = @{}   # lower abs path -> { files: @(rel), hashes: @{rel -> sha} }
$manifestRefs = @{}
if ($null -ne $fixBaseline) {
    $referenceToken = "dbM09_fixBaseline"
    foreach ($_repo in @(Get-DevBridgeField $fixBaseline "repos")) {
        $_p = [string](Get-DevBridgeField $_repo "path")
        if (-not $_p) { continue }
        $files = New-Object System.Collections.Generic.List[string]
        $hashes = @{}
        foreach ($_f in @(Get-DevBridgeField $_repo "deltaFiles")) {
            $rel = ([string](Get-DevBridgeField $_f "path")).Replace('\', '/')
            if (-not $rel) { continue }
            $files.Add($rel)
            $sha = [string](Get-DevBridgeField $_f "sha256")
            if ($sha) { $hashes[$rel] = $sha.ToUpperInvariant() }
        }
        $refRepoByPath[$_p.Trim().ToLowerInvariant()] = @{ files = @($files); hashes = $hashes }
    }
} else {
    $manifestRefs = Get-ManifestCurrentTaskDelta
}
$referenceAvailable = ($refRepoByPath.Count -gt 0) -or ($manifestRefs.Count -gt 0)

# ---- iterate the reserved repositories and classify their CURRENT delta ----
$res = Read-DevBridgeJson $script:ResPath
if ($null -eq $res) { Out-Markers "STOP_RESERVATION_MISSING" $false @("reservation.json is required to know the reserved repositories.") }
$baselines = @(Get-DevBridgeField $res "repositoryBaselines")

$repoResults = New-Object System.Collections.Generic.List[object]  # { name, netNew, changed }
$totalNetNew = 0
$totalChanged = 0
$defectEvidence = @()
$reservedRepoCount = 0

foreach ($_b in $baselines) {
    $_repoPath = [string](Get-DevBridgeField $_b "path")
    if (-not $_repoPath) { continue }
    $reservedRepoCount++
    $_repoFull = ""
    try { $_repoFull = (Resolve-Path -LiteralPath $_repoPath -ErrorAction Stop).Path } catch { $_repoFull = "" }
    if (-not $_repoFull) { continue }
    $_label = [string](Get-DevBridgeField $_b "name")
    if (-not $_label) { $_label = Split-Path $_repoFull -Leaf }
    $key = $_repoFull.Trim().ToLowerInvariant()

    $cls = Invoke-DeltaClassification $_repoPath $script:ResPath
    if ($cls.Outcome -ne "DELTA_CLASSIFICATION_PASS") {
        $defectEvidence += ($_label + ": delta classification " + $cls.Outcome + " (the classifier evidence names the file)")
        continue
    }
    $currentRels = @($cls.Rels)

    # reference for THIS repo
    $refFiles = @()
    $refHashes = @{}
    if ($referenceToken -eq "dbM09_fixBaseline") {
        if ($refRepoByPath.ContainsKey($key)) {
            $refFiles = @($refRepoByPath[$key].files)
            $refHashes = $refRepoByPath[$key].hashes
        }
    } elseif ($manifestRefs.ContainsKey($key)) {
        $refFiles = @($manifestRefs[$key])
    }
    $refSet = @{}
    foreach ($_r in $refFiles) { $refSet[$_r] = $true }

    $netNew = New-Object System.Collections.Generic.List[string]
    $changed = New-Object System.Collections.Generic.List[string]
    foreach ($_rel in $currentRels) {
        if (-not $refSet.ContainsKey($_rel)) {
            $netNew.Add($_rel)
        } elseif ($refHashes.ContainsKey($_rel)) {
            $cur = Get-Sha256 (Join-Path $_repoFull $_rel)
            if ($cur -and ($cur -ne $refHashes[$_rel])) { $changed.Add($_rel) }
        }
    }
    if ($netNew.Count -gt 0 -or $changed.Count -gt 0) {
        $repoResults.Add(@{ name = $_label; netNew = @($netNew); changed = @($changed) })
        $totalNetNew += $netNew.Count
        $totalChanged += $changed.Count
    }
}

if ($defectEvidence.Count -gt 0) {
    Out-Markers "STOP_DELTA_CLASSIFICATION_DEFECT" $false @($defectEvidence)
}
if ($reservedRepoCount -eq 0) {
    Out-Markers "STOP_RESERVATION_MISSING" $false @("No repositoryBaselines present in reservation.json.")
}

# ---- verdict ----
# Without any reference (no DB-M09 fixBaseline and no DB-M07 manifest current-task
# delta) a NON-EMPTY post-correction delta is unattributable: stop rather than guess.
if (-not $referenceAvailable) {
    if ($totalNetNew -gt 0 -or $totalChanged -gt 0) {
        Out-Markers "STOP_NO_REFERENCE" $false @("No DB-M09 fixBaseline and no DB-M07 manifest current-task delta to compare the post-correction delta against; cannot attribute the correction.")
    }
    Out-Markers "CORRECTION_DELTA_NONE" $true @("No reserved current-task delta present after the correction; nothing to reconcile.")
}
if ($totalNetNew -eq 0 -and $totalChanged -eq 0) {
    Out-Markers "CORRECTION_DELTA_NONE" $true @("No incremental correction delta detected over the reserved repositories (net-new and content changes: none).")
}

# ---- CORRECTION_DELTA_DETECTED: stamp dbM09.correctionReconciled (preserve dbM09) ----
$recRepos = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[string]
foreach ($_rr in $repoResults) {
    $deltas = New-Object System.Collections.Generic.List[string]
    foreach ($_d in $_rr.netNew)  { $deltas.Add($_d) }
    foreach ($_d in $_rr.changed) { if (-not $deltas.Contains($_d)) { $deltas.Add($_d) } }
    $recRepos.Add([ordered]@{ name = $_rr.name; deltaFiles = @($deltas) })
    $evidence.Add($_rr.name + ": incremental correction delta " + $deltas.Count + " file(s)")
    foreach ($_d in $deltas) { Write-Output ("DB15_DELTA_FILE: " + $_rr.name + "|" + $_d) }
}

$rec = [ordered]@{
    result          = "CORRECTION_DELTA_DETECTED"
    reconciledAtUtc = $script:NowUtc
    reference       = $referenceToken
    nodeId          = $nodeId
    changeId        = $changeId
    repos           = @($recRepos.ToArray())
}
if ($null -eq $db9) { $db9 = [ordered]@{ nodeId = $nodeId; changeId = $changeId } }
$db9["correctionReconciled"] = $rec
Set-DevBridgeStateEntry $script:CurrentTaskPath @{ dbM09 = $db9 }

$evidence.Add("Current-task dbM09.correctionReconciled stamped (CORRECTION_DELTA_DETECTED); lifecycle stays DB_M09_FIX_REQUIRED until DB-M06 re-verifies the corrected attempt.")
Out-Markers "CORRECTION_DELTA_DETECTED" $true @($evidence)
