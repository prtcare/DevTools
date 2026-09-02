# TrialDependencyOverlay.ps1 - DB-M03.2 TRIAL-only dependency-satisfaction overlay.
#
# A previously verified and governedly closed DevBridge TRIAL proving task may
# satisfy a governed dependency for SUBSEQUENT PROVING-CYCLE SELECTION WITHOUT
# modifying the real Nexus work-item status. This is a SELECTION-TIME overlay
# ONLY. It is dot-sourceable and consulted from the four existing dependency-check
# sites (Get-NextTask.ps1 Test-DepsSatisfied, Test-DevelopmentPreflight.ps1
# PART 4, Reserve-DevelopmentChange.ps1 Part 1 revalidation,
# New-ChatGptHandoff.ps1 PART 1 item 6). No dependency engine is duplicated here.
#
# Invariants:
#   * Zero completion capability: this helper NEVER writes to the roadmap, the
#     workbook, or any Nexus status. TRIAL_DEPENDENCY_SATISFIED is NOT
#     Complete/Merged/REAL_VERIFIED_COMPLETE/M10_COMPLETE/READY_FOR_GOVERNED_COMPLETION.
#   * TRIAL-only (capability 3): when the resolved mode is not TRIAL the overlay is
#     ignored and every dependency check behaves exactly as before DB-M03.2.
#   * Real status remains authoritative (capability 2): a real Completed/Complete
#     dependency status is always evaluated FIRST; the overlay only covers the gap
#     left by a trial-proven-but-still-Planned predecessor, and both statuses stay
#     visible separately in the provenance.
#   * Qualification requires the FULL preserved per-change trial evidence
#     (capability 1/5/6): the DB-M12.4 closure entry in trial-proving-history.json
#     PLUS the M06 verification evidence (claude-decision.json dbM06Result
#     VERIFICATION_PASS) PLUS the M08 Claude evidence (decision PASS, trialMode
#     true, implementationState TRIAL_ONLY_UNMERGED) located by the directory
#     convention logs\tasks\<node>\<change>\ under the caller's state dir.
#   * Honest blocks (capability 6/7): missing/invalid trial evidence yields
#     TRIAL_DEPENDENCY_EVIDENCE_INVALID; an absent evidence directory or a
#     DB-M18.1 DEPENDENCY_CONTEXT_STALE freshness yields DEPENDENCY_CONTEXT_STALE
#     (rebuild via DB-M18.1).
#   * Restoration safety (capability 12): when the pre-DevBridge baseline is
#     restored (no trial-proving-history), or the mode is REAL, or the overlay is
#     disabled in config, the overlay returns NOT_SATISFIED and dependency checks
#     behave exactly as before.
#
# The evidence root is DERIVED from the caller's state dir (<stateDir>\..\logs\tasks)
# so fixture suites that redirect state also redirect trial evidence - an existing
# fixture history entry without a matching evidence dir is honestly reported as
# TRIAL_DEPENDENCY_EVIDENCE_INVALID, never falsely satisfied against the LIVE logs.
#
# ASCII-only source (PS 5.1 + BOM-safe; non-ASCII characters are forbidden here).
. (Join-Path $PSScriptRoot "Set-DevBridgeStateEntry.ps1")

function Read-TdoJson([string]$Path) {
    # Array-safe JSON read; missing/parse-failure -> $null (never throws).
    if (-not (Test-Path $Path)) { return $null }
    return Read-DevBridgeJson $Path
}

function Get-TdoField($Obj, [string]$Key) {
    return Get-DevBridgeField $Obj $Key
}

function Test-TrialDependencySatisfied {
    <#
    .SYNOPSIS
    DB-M03.2 overlay: decides whether a governedly closed DevBridge TRIAL proving
    task may satisfy a governed dependency for TRIAL proving-cycle selection.

    .DESCRIPTION
    Returns a result object:
      Satisfied  $true  -> the dependency is TRIAL_DEPENDENCY_SATISFIED (proving
                          cycle selection only; never real completion).
      Satisfied  $false -> the dependency is NOT satisfied by the overlay. When
                          BlockCode is set the overlay is HONESTLY BLOCKING on
                          TRIAL_DEPENDENCY_EVIDENCE_INVALID or
                          DEPENDENCY_CONTEXT_STALE; otherwise it is simply not
                          satisfied (NO_TRIAL_HISTORY / NOT_TRIAL_MODE /
                          OVERLAY_DISABLED) and the caller keeps its pre-overlay
                          behavior.
      Provenance          full chained trial-provenance record (real status,
                          trial evidence used, verification evidence, Claude
                          evidence, closure evidence, source cycle, repository
                          reconciliation).

    .PARAMETER DependencyNodeId  the governed dependency node id (e.g. WI-07-0.2.4)
    .PARAMETER StateDir          the caller's state dir (fixture-aware); the trial
                                 history and current-task are read from here and the
                                 evidence root is derived as <stateDir>\..\logs\tasks
                                 unless TaskLogsDir is given.
    .PARAMETER ConfigPath        path to config\devbridge.json (mode + overlay flag)
    .PARAMETER TaskLogsDir       optional explicit evidence root (logs\tasks); derived
                                 from StateDir when omitted.
    .PARAMETER RealStatus        the CURRENT real roadmap status of the dependency
                                 node (e.g. "Planned"); recorded in the provenance.
    .PARAMETER DbM181Context     optional precomputed DB-M18.1 Context bundle; when its
                                 FreshnessStatus is DEPENDENCY_CONTEXT_STALE the overlay
                                 blocks (capability 7) rather than qualifying.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$DependencyNodeId,
        [Parameter(Mandatory = $true)][string]$StateDir,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [AllowNull()][string]$TaskLogsDir = $null,
        [AllowNull()][string]$RealStatus = '',
        [AllowNull()][object]$DbM181Context = $null
    )

    # ---- Gate 0: overlay enabled? (restoration safety / explicit disable) ----
    $overlayEnabled = $true
    if ($env:DB_TRIAL_DEPENDENCY_OVERLAY -in @('0', 'false', 'False', 'FALSE')) { $overlayEnabled = $false }
    if ($overlayEnabled -and $ConfigPath -and (Test-Path $ConfigPath)) {
        try {
            $tdoCfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($tdoCfg.PSObject.Properties['trialDependencyOverlay']) {
                $tdo = $tdoCfg.trialDependencyOverlay
                if ($tdo.PSObject.Properties['enabled'] -and -not [bool]$tdo.enabled) { $overlayEnabled = $false }
            }
        } catch { }
    }
    if (-not $overlayEnabled) {
        return [pscustomobject]@{ Satisfied = $false; Reason = 'OVERLAY_DISABLED'; BlockCode = $null; Detail = 'Trial dependency overlay is disabled by configuration; the dependency check behaves exactly as before DB-M03.2.'; Provenance = $null }
    }

    # ---- Gate 1: TRIAL mode only (capability 3 + restoration safety) ----
    # Resolve the effective mode from config (and current-task when present) EVERY
    # time. The overlay is TRIAL-only; in REAL_NEXUS_DEVELOPMENT it must be ignored
    # even on a fresh state where no current-task.json exists yet (DB-M03's preflight
    # dependency analysis runs before the task write). Defaulting to TRIAL here would
    # silently let a trial-proven predecessor satisfy a REAL-mode dependency during
    # task selection (TRIAL_TO_REAL_COMPLETION_CAPABILITY NO).
    $ctObj = Read-TdoJson (Join-Path $StateDir 'current-task.json')
    $mode = Get-DevBridgeMode $ctObj $ConfigPath
    if ($mode -ne 'TRIAL') {
        return [pscustomobject]@{ Satisfied = $false; Reason = 'NOT_TRIAL_MODE'; BlockCode = $null; Detail = 'Resolved DevBridge mode is ' + $mode + '; the TRIAL-only overlay is ignored in REAL_NEXUS_DEVELOPMENT.'; Provenance = $null }
    }

    # ---- Gate 2: DB-M12.4 closure entry present ----
    $hist = Read-TdoJson (Join-Path $StateDir 'trial-proving-history.json')
    $entry = $null
    if ($null -ne $hist) {
        foreach ($e in @(Get-TdoField $hist 'entries')) {
            if ([string](Get-TdoField $e 'nodeId') -eq $DependencyNodeId) { $entry = $e; break }
        }
    }
    if ($null -eq $entry) {
        return [pscustomobject]@{ Satisfied = $false; Reason = 'NO_TRIAL_HISTORY'; BlockCode = $null; Detail = 'Node ' + $DependencyNodeId + ' has no governed TRIAL proving-history closure entry; the dependency is unsatisfied.'; Provenance = $null }
    }
    $entryResult = [string](Get-TdoField $entry 'result')
    $entryImpl = [string](Get-TdoField $entry 'implementationState')
    $entryMode = [string](Get-TdoField $entry 'mode')
    $changeId = [string](Get-TdoField $entry 'changeId')
    $closedAtUtc = [string](Get-TdoField $entry 'closedAtUtc')
    $preReservation = [string](Get-TdoField $entry 'preReservationStatus')
    if ($entryResult -ne 'TRIAL_CYCLE_CLOSED' -or $entryImpl -ne 'TRIAL_ONLY_UNMERGED' -or $entryMode -ne 'TRIAL') {
        return [pscustomobject]@{ Satisfied = $false; Reason = 'TRIAL_DEPENDENCY_EVIDENCE_INVALID'; BlockCode = 'TRIAL_DEPENDENCY_EVIDENCE_INVALID'; Detail = 'Proving-history entry for ' + $DependencyNodeId + ' does not describe a qualified TRIAL_CYCLE_CLOSED / TRIAL_ONLY_UNMERGED closure (result=' + $entryResult + ' implementationState=' + $entryImpl + ' mode=' + $entryMode + ').'; Provenance = $null }
    }
    if (-not $changeId) {
        return [pscustomobject]@{ Satisfied = $false; Reason = 'TRIAL_DEPENDENCY_EVIDENCE_INVALID'; BlockCode = 'TRIAL_DEPENDENCY_EVIDENCE_INVALID'; Detail = 'Proving-history entry for ' + $DependencyNodeId + ' carries no changeId; per-change trial evidence cannot be resolved.'; Provenance = $null }
    }

    # ---- Gate 3: DB-M18.1 freshness (capability 7) ----
    $freshness = 'UNVERIFIED'
    $staleReasons = @('DB-M18.1 context not supplied; local evidence reconciliation governs.')
    if ($null -ne $DbM181Context) {
        $fs = $null
        try { $fs = Get-TdoField $DbM181Context 'FreshnessStatus' } catch { }
        if ($null -eq $fs -and $DbM181Context -is [pscustomobject]) {
            try { if ($DbM181Context.PSObject.Properties['FreshnessStatus']) { $fs = [string]$DbM181Context.FreshnessStatus } } catch { }
        }
        if ($null -ne $fs) {
            $freshness = [string]$fs
            $staleReasons = @('DB-M18.1 dependency context supplied.')
        }
        if ($freshness -eq 'DEPENDENCY_CONTEXT_STALE') {
            return [pscustomobject]@{ Satisfied = $false; Reason = 'DEPENDENCY_CONTEXT_STALE'; BlockCode = 'DEPENDENCY_CONTEXT_STALE'; Detail = 'DB-M18.1 reconciliation reports DEPENDENCY_CONTEXT_STALE for the trial-proven predecessor ' + $DependencyNodeId + '; rebuild the dependency context via DB-M18.1 before qualifying.'; Provenance = $null }
        }
    }

    # ---- Gate 4: per-change evidence directory present in current repository ----
    if (-not $TaskLogsDir) {
        $parentOfState = Split-Path $StateDir -Parent
        $TaskLogsDir = Join-Path $parentOfState 'logs\tasks'
    }
    $changeDir = Join-Path (Join-Path $TaskLogsDir $DependencyNodeId) $changeId
    if (-not (Test-Path $changeDir)) {
        return [pscustomobject]@{ Satisfied = $false; Reason = 'DEPENDENCY_CONTEXT_STALE'; BlockCode = 'DEPENDENCY_CONTEXT_STALE'; Detail = 'Per-change trial evidence directory for ' + $DependencyNodeId + '/' + $changeId + ' is absent from the current repository reality; the DB-M18.1 dependency context is stale and must be rebuilt.'; Provenance = $null }
    }

    # ---- Gate 5: M06 verification evidence + M08 Claude evidence ----
    $claudePath = Join-Path $changeDir 'claude-decision.json'
    $verifPath = Join-Path $changeDir 'VERIFICATION_RESULT.md'
    $testPath = Join-Path $changeDir 'test-result.json'
    $buildPath = Join-Path $changeDir 'build-result.json'
    if (-not (Test-Path $claudePath) -or -not (Test-Path $verifPath) -or -not (Test-Path $testPath) -or -not (Test-Path $buildPath)) {
        return [pscustomobject]@{ Satisfied = $false; Reason = 'TRIAL_DEPENDENCY_EVIDENCE_INVALID'; BlockCode = 'TRIAL_DEPENDENCY_EVIDENCE_INVALID'; Detail = 'Per-change trial evidence for ' + $DependencyNodeId + '/' + $changeId + ' is incomplete (missing claude-decision.json / VERIFICATION_RESULT.md / test-result.json / build-result.json).'; Provenance = $null }
    }
    $claude = Read-TdoJson $claudePath
    if ($null -eq $claude) {
        return [pscustomobject]@{ Satisfied = $false; Reason = 'TRIAL_DEPENDENCY_EVIDENCE_INVALID'; BlockCode = 'TRIAL_DEPENDENCY_EVIDENCE_INVALID'; Detail = 'claude-decision.json for ' + $DependencyNodeId + '/' + $changeId + ' is unreadable.'; Provenance = $null }
    }
    $dbM06 = [string](Get-TdoField $claude 'dbM06Result')
    $decision = [string](Get-TdoField $claude 'decision')
    $trialMode = $null
    try { $trialMode = Get-TdoField $claude 'trialMode' } catch { }
    $implState = [string](Get-TdoField $claude 'implementationState')
    if ($dbM06 -ne 'VERIFICATION_PASS' -or $decision -ne 'PASS' -or $trialMode -ne $true -or $implState -ne 'TRIAL_ONLY_UNMERGED') {
        return [pscustomobject]@{ Satisfied = $false; Reason = 'TRIAL_DEPENDENCY_EVIDENCE_INVALID'; BlockCode = 'TRIAL_DEPENDENCY_EVIDENCE_INVALID'; Detail = 'Trial evidence for ' + $DependencyNodeId + '/' + $changeId + ' does not satisfy the qualification gate (dbM06Result=' + $dbM06 + ' decision=' + $decision + ' trialMode=' + $trialMode + ' implementationState=' + $implState + ').'; Provenance = $null }
    }
    $milestone = [string](Get-TdoField $claude 'milestone')
    $reviewAt = [string](Get-TdoField $claude 'reviewTimestampUtc')
    $reviewed = [bool](Get-TdoField $claude 'reviewedAgainstDbM06')

    # ---- Evidence enrichment (tolerant; missing fields never block) ----
    $testsPassed = -1; $testsTotal = -1; $testsFailed = -1; $testsSkipped = -1
    $testObj = Read-TdoJson $testPath
    if ($null -ne $testObj) {
        $tp = Get-TdoField $testObj 'passed'; $tf = Get-TdoField $testObj 'failed'; $ts = Get-TdoField $testObj 'skipped'; $tt = Get-TdoField $testObj 'total'
        if ($null -ne $tp) { $testsPassed = [int]$tp }; if ($null -ne $tf) { $testsFailed = [int]$tf }
        if ($null -ne $ts) { $testsSkipped = [int]$ts }; if ($null -ne $tt) { $testsTotal = [int]$tt }
        if ($testsTotal -lt 0 -and $testsPassed -ge 0 -and $testsFailed -ge 0 -and $testsSkipped -ge 0) { $testsTotal = $testsPassed + $testsFailed + $testsSkipped }
    }
    $buildWarnings = -1; $buildErrors = -1; $buildSucceeded = $false
    $buildObj = Read-TdoJson $buildPath
    if ($null -ne $buildObj) {
        $bw = Get-TdoField $buildObj 'warnings'; $be = Get-TdoField $buildObj 'errors'; $bs = Get-TdoField $buildObj 'succeeded'
        if ($null -ne $bw) { $buildWarnings = [int]$bw }; if ($null -ne $be) { $buildErrors = [int]$be }
        if ($null -ne $bs) { $buildSucceeded = [bool]$bs }
    }

    # ---- Provenance (capability 5: chained trial proving, per-node) ----
    $historicalFiles = @('claude-decision.json', 'VERIFICATION_RESULT.md', 'test-result.json', 'build-result.json')
    $provenance = [ordered]@{
        nodeId = $DependencyNodeId
        changeId = $changeId
        closedAtUtc = $closedAtUtc
        result = $entryResult
        mode = $entryMode
        implementationState = $entryImpl
        preReservationStatus = $preReservation
        realStatus = $RealStatus
        realStatusAuthoritative = $true
        overlayStatus = 'TRIAL_DEPENDENCY_SATISFIED'
        realNexusCompletion = $false
        disposableProvingContext = $true
        trialEvidenceUsed = @($historicalFiles)
        sourceCycle = $changeId
        verificationEvidence = [ordered]@{
            m06Result = $dbM06
            testsPassed = $testsPassed
            testsFailed = $testsFailed
            testsSkipped = $testsSkipped
            testsTotal = $testsTotal
            buildSucceeded = $buildSucceeded
            buildWarnings = $buildWarnings
            buildErrors = $buildErrors
            harness = 'VERIFICATION_RESULT.md'
        }
        claudeEvidence = [ordered]@{
            milestone = $milestone
            decision = $decision
            trialMode = $trialMode
            implementationState = $implState
            reviewedAgainstDbM06 = $reviewed
            reviewTimestampUtc = $reviewAt
        }
        closureEvidence = [ordered]@{
            result = $entryResult
            mode = $entryMode
            implementationState = $entryImpl
            preReservationStatus = $preReservation
            closedAtUtc = $closedAtUtc
        }
        repositoryReconciliation = [ordered]@{
            historicalTrialEvidence = @($historicalFiles)
            currentTrialRepositoryReality = 'EVIDENCE_PRESENT'
            freshness = $freshness
            staleReasons = @($staleReasons)
        }
    }

    return [pscustomobject]@{
        Satisfied = $true
        Reason = 'TRIAL_DEPENDENCY_SATISFIED'
        BlockCode = $null
        Detail = ('Dependency ' + $DependencyNodeId + ' is satisfied for TRIAL proving-cycle selection by governedly closed trial evidence (change ' + $changeId + '); the real roadmap status ' + $RealStatus + ' remains authoritative and is NOT real Nexus completion.')
        Provenance = [pscustomobject]$provenance
    }
}
