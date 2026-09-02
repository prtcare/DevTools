# WorkflowEngine.ps1 -- DB-M30 SUPERVISED DEVELOPMENT WORKFLOW INTEGRATION engine.
#
# PURE view builder. Takes durable lifecycle artifacts (state dir), the per-change
# evidence tree, an optional task catalog, optional attempt/decision/health
# records and an injected NowUtc, and returns a SupervisedWorkflowView v1: the
# 13-stage workflow catalog with evidence-grounded display tokens, the operator's
# current stage and next human action, and the guidance cards (DB-M18.1 dependency
# context, DB-M19 routing recommendation, DB-M27/M21/M25 cost+budget, DB-M22
# provider health, DB-M26/M29 history).
#
# READ-ONLY and deterministic. The engine NEVER advances the lifecycle, executes a
# model/provider, invokes ChatGPT/Claude, creates/approves/merges PRs, modifies
# the roadmap, or restores a baseline. Every external step belongs to the human
# operator. AUTO_EXECUTION_ENABLED = FALSE. No AI/provider/paid/network calls, no
# writes beyond the operator-requested HTML artifact, no secrets stored.
#
# Reuse READ-ONLY (each subsystem is lazy-loaded inside a fault-isolated card
# resolver so an unavailable/disabled subsystem degrades to an honest card):
#   DB-M18.1 Get-DbM181TaskDependencyContext (DependencyLineage.ps1)
#   DB-M19   Get-AiRoutingRecommendation / Get-DefaultRoutingPolicy (router)
#   DB-M27   Invoke-DbM27Calculator (calculator)
#   DB-M21   Test-AiBudget (budget)  DB-M22  Get-EffectiveProviderHealth (health)
#   DB-M26   Get-DbM26DashboardView (dashboard)   DB-M29  Get-DbM29TaskHistoryView
#   DB-M17   Get-AiAttemptsAll (attempt store, READ-ONLY)
#   DB-M25   Resolve-DbM25RecordCost (cost authority, READ-ONLY)

. (Join-Path $PSScriptRoot "WorkflowContracts.ps1")

# --- JSON reading (fault-isolated) ------------------------------------------------

function Read-DbM30JsonFile {
    <#
    .SYNOPSIS
    Read a JSON artifact into a PSCustomObject. Returns @{ Present; Value; Error }.
    A present-but-unparseable file reports Present=$true, Value=$null, Error set.
    #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return @{ Present = $false; Value = $null; Error = '' }
    }
    try {
        $v = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        return @{ Present = $true; Value = $v; Error = '' }
    } catch {
        return @{ Present = $true; Value = $null; Error = [string]$_.Exception.Message }
    }
}

# --- lifecycle evidence loading ---------------------------------------------------

function Resolve-DbM30LifecycleEvidence {
    <#
    .SYNOPSIS
    Load the durable lifecycle artifacts from the state dir + evidence tree and
    compute the evidence predicates that drive the stage tokens. Everything is
    READ-ONLY. Evidence is bound to the CURRENT task's identity (nodeId/changeId)
    so a stale global artifact from a different task never invents state.
    #>
    param(
        [string]$StateDir,
        [string]$EvidenceRoot,
        [string]$Root,
        [string]$NowUtc
    )
    $ev = @{
        Root = $Root
        NowUtc = $NowUtc
        StateDir = $StateDir
        EvidenceRoot = $EvidenceRoot
        NodeId = ''
        ChangeId = ''
        TaskName = ''
        CurrentTaskPresent = $false
        CurrentTaskStatus = ''
        CurrentTaskNextAllowedAction = ''
        CurrentTaskPreflightVerdict = ''
        CurrentTaskImplementability = ''
        WorkbookSha256 = ''
        LifecycleMode = ''
        LifecycleTrialMode = $false
        LifecycleStatus = ''
        LifecycleGeneratedAtUtc = ''
        SelectedAtUtc = ''
        PreflightPresent = $false
        PreflightClear = $false
        PreflightBlocked = $false
        PreflightVerdict = ''
        ReservationDone = $false
        ChangeIdKnown = $false
        HandoffDone = $false
        VerificationEvidence = $false
        VerificationFile = $false
        VerificationPrimaryResult = ''
        VerificationFailed = $false
        VerificationDone = $false
        PackageDone = $false
        ClaudeDecisionDone = $false
        ClaudeDecision = ''
        CorrectionNeeded = $false
        CorrectionDone = $false
        TrialMode = $false
        GitMerged = $false
        CompletionDone = $false
        Warnings = New-Object System.Collections.Generic.List[string]
    }

    # -- current-task.json ---------------------------------------------------------
    $ct = Read-DbM30JsonFile (Join-Path $StateDir 'current-task.json')
    if ($ct.Present -and $null -ne $ct.Value) {
        $ev.CurrentTaskPresent = $true
        $ev.NodeId = [string](Get-ContractProperty $ct.Value 'nodeId' '')
        if (-not $ev.NodeId) { $ev.NodeId = [string](Get-ContractProperty $ct.Value 'taskId' '') }
        $ev.ChangeId = [string](Get-ContractProperty $ct.Value 'changeId' '')
        $ev.TaskName = [string](Get-ContractProperty $ct.Value 'name' '')
        $ev.CurrentTaskStatus = [string](Get-ContractProperty $ct.Value 'status' '')
        $ev.CurrentTaskNextAllowedAction = [string](Get-ContractProperty $ct.Value 'nextAllowedAction' '')
        $ev.CurrentTaskPreflightVerdict = [string](Get-ContractProperty $ct.Value 'preflightVerdict' '')
        $ev.CurrentTaskImplementability = [string](Get-ContractProperty $ct.Value 'implementability' '')
        $ev.WorkbookSha256 = [string](Get-ContractProperty $ct.Value 'workbookSha256' '')
        $ev.SelectedAtUtc = [string](Get-ContractProperty $ct.Value 'selectedAt' '')
        if (-not $ev.ChangeId) {
            $changeFromTask = [string](Get-ContractProperty $ct.Value 'changeId' $null)
            if (-not $changeFromTask) {
                $cid = [string](Get-ContractProperty $ct.Value 'activeChange' $null)
                if (-not $cid) { $cid = [string](Get-ContractProperty $ct.Value 'reservationId' '') }
                $ev.ChangeId = $cid
            }
        }
    } elseif ($ct.Present) {
        $ev.Warnings.Add('state/current-task.json present but unreadable.')
    }

    # -- current-lifecycle-state.json ----------------------------------------------
    $ls = Read-DbM30JsonFile (Join-Path $StateDir 'current-lifecycle-state.json')
    if ($ls.Present -and $null -ne $ls.Value) {
        $ev.LifecycleMode = [string](Get-ContractProperty $ls.Value 'mode' '')
        $ev.LifecycleTrialMode = [bool](Get-ContractProperty $ls.Value 'trialMode' $false)
        $ev.LifecycleStatus = [string](Get-ContractProperty $ls.Value 'status' '')
        $ev.LifecycleGeneratedAtUtc = [string](Get-ContractProperty $ls.Value 'generatedAtUtc' '')
    }

    # -- preflight.json ------------------------------------------------------------
    $pf = Read-DbM30JsonFile (Join-Path $StateDir 'preflight.json')
    if ($pf.Present -and $null -ne $pf.Value) {
        $ev.PreflightPresent = $true
        $ev.PreflightVerdict = [string](Get-ContractProperty $pf.Value 'verdict' '')
        if (-not $ev.PreflightVerdict) { $ev.PreflightVerdict = [string](Get-ContractProperty $pf.Value 'preflightVerdict' '') }
        if ($ev.PreflightVerdict -eq 'CLEAR') { $ev.PreflightClear = $true }
        elseif ($ev.PreflightVerdict) { $ev.PreflightBlocked = $true }
        if ([string](Get-ContractProperty $pf.Value 'nodeId' '') -and [string](Get-ContractProperty $pf.Value 'nodeId' '') -ine $ev.NodeId) {
            $ev.Warnings.Add('state/preflight.json belongs to node ' + [string](Get-ContractProperty $pf.Value 'nodeId' '') + '; the current task node is ' + $ev.NodeId + '. The preflight is not counted for the current task.')
            $ev.PreflightClear = $false
            $ev.PreflightBlocked = $false
        }
    }

    # -- reservation.json ----------------------------------------------------------
    $rs = Read-DbM30JsonFile (Join-Path $StateDir 'reservation.json')
    if ($rs.Present -and $null -ne $rs.Value) {
        $rsNode = [string](Get-ContractProperty $rs.Value 'nodeId' '')
        $rsChange = [string](Get-ContractProperty $rs.Value 'changeId' '')
        if (-not $rsChange) { $rsChange = [string](Get-ContractProperty $rs.Value 'activeChange' '') }
        if (-not $rsChange -and $null -ne $rs.Value.activeChange) {
            $rsChange = [string](Get-ContractProperty $rs.Value.activeChange 'changeId' '')
        }
        if (-not $ev.NodeId) { $ev.NodeId = $rsNode }
        # adopt the reservation's changeId ONLY when the reservation is for THIS
        # node -- a reservation for another node never becomes this task's change.
        if (-not $ev.ChangeId -and $rsNode -and $rsNode -ieq $ev.NodeId) { $ev.ChangeId = $rsChange }
        if ($rsNode -and $rsChange) {
            $ev.ReservationDone = ($rsNode -ieq $ev.NodeId)
            if (-not $ev.ReservationDone) {
                $ev.Warnings.Add('state/reservation.json belongs to node ' + $rsNode + '; the current task node is ' + $ev.NodeId + '. The reservation is not counted for the current task.')
            }
        }
    }
    $ev.ChangeIdKnown = [bool]$ev.ChangeId
    $ev.TrialMode = ($ev.LifecycleTrialMode -or $ev.LifecycleMode -ieq 'TRIAL')

    # -- per-change evidence tree ---------------------------------------------------
    $changeFolder = if ($ev.NodeId -and $ev.ChangeId) { Join-Path (Join-Path $EvidenceRoot $ev.NodeId) $ev.ChangeId } else { $null }
    $ev.EvidenceFolder = $changeFolder
    $hasEvidenceFolder = $changeFolder -and (Test-Path -LiteralPath $changeFolder)
    if ($hasEvidenceFolder) {
        $ev.HandoffDone = Test-Path -LiteralPath (Join-Path $changeFolder 'CHATGPT_HANDOFF.md')
        $ev.VerificationFile = Test-Path -LiteralPath (Join-Path $changeFolder 'VERIFICATION_RESULT.md')
        $ev.PackageDone = Test-Path -LiteralPath (Join-Path $changeFolder 'CLAUDE_REVIEW_PACKAGE.md')
        $ev.ClaudeDecisionFile = Test-Path -LiteralPath (Join-Path $changeFolder 'CLAUDE_DECISION_RESULT.md')
        $ev.ClaudeDecisionJson = Test-Path -LiteralPath (Join-Path $changeFolder 'claude-decision.json')
    }

    # -- verification.json (bound to the current task identity) --------------------
    $vf = Read-DbM30JsonFile (Join-Path $StateDir 'verification.json')
    if ($vf.Present -and $null -ne $vf.Value) {
        $vfNode = [string](Get-ContractProperty $vf.Value 'nodeId' '')
        if (-not $vfNode) { $vfNode = [string](Get-ContractProperty $vf.Value 'taskId' '') }
        $vfChange = [string](Get-ContractProperty $vf.Value 'changeId' '')
        $matchesNode = (-not $vfNode -or $vfNode -ieq $ev.NodeId -or ($ev.NodeId -and $vfNode -ieq $ev.NodeId))
        $matchesChange = (-not $vfChange -or $ev.ChangeId -ieq $vfChange)
        $bound = ($matchesNode -and ($ev.ChangeIdKnown -eq $false -or $matchesChange -or -not $vfChange))
        if ($bound) {
            $ev.VerificationEvidence = $true
            $ev.VerificationPrimaryResult = [string](Get-ContractProperty $vf.Value 'primaryResult' '')
            if (-not $ev.VerificationPrimaryResult) { $ev.VerificationPrimaryResult = [string](Get-ContractProperty $vf.Value 'verificationResult' '') }
            if ($ev.VerificationPrimaryResult -and $ev.VerificationPrimaryResult -ine 'VERIFICATION_PASSED' -and $ev.VerificationPrimaryResult -ine 'VERIFIED') {
                $ev.VerificationFailed = $true
            }
        } else {
            $ev.Warnings.Add('state/verification.json belongs to change ' + $vfChange + '; not counted for the current task.')
        }
    }
    $ev.VerificationDone = (($ev.VerificationEvidence -and $ev.VerificationFile) -or ($ev.VerificationEvidence -and -not $ev.ChangeIdKnown))
    if ($ev.VerificationFailed -and $ev.VerificationDone) { $ev.VerificationDone = $false }

    # -- claude-review.json (bound to the current task identity) -------------------
    $cr = Read-DbM30JsonFile (Join-Path $StateDir 'claude-review.json')
    if ($cr.Present -and $null -ne $cr.Value) {
        $crNode = [string](Get-ContractProperty $cr.Value 'nodeId' '')
        $crChange = [string](Get-ContractProperty $cr.Value 'changeId' '')
        $bound = ((-not $crNode -or $crNode -ieq $ev.NodeId) -and (-not $crChange -or -not $ev.ChangeId -or $crChange -ieq $ev.ChangeId))
        if ($bound) {
            $ev.ClaudeDecision = [string](Get-ContractProperty $cr.Value 'decision' '')
            $ev.ClaudeDecisionDone = (($ev.ClaudeDecision -ne '' -and ($ev.ClaudeDecisionFile -or $ev.ClaudeDecisionJson)) -or ($ev.ClaudeDecision -ne '' -and -not $ev.ChangeIdKnown))
        } else {
            $ev.Warnings.Add('state/claude-review.json belongs to change ' + $crChange + '; not counted for the current task.')
        }
    }
    $ev.CorrectionNeeded = ($ev.ClaudeDecisionDone -and $ev.ClaudeDecision -ieq 'FIX')
    $ev.CorrectionEvidence = Test-Path -LiteralPath (Join-Path $Root 'tasks\FIX_CONTEXT.md')
    $ev.CorrectionDone = ($ev.CorrectionNeeded -and $ev.CorrectionEvidence -and $ev.VerificationDone)

    # -- completion.json -----------------------------------------------------------
    $co = Read-DbM30JsonFile (Join-Path $StateDir 'completion.json')
    if ($co.Present -and $null -ne $co.Value) {
        $coNode = [string](Get-ContractProperty $co.Value 'nodeId' '')
        if (-not $coNode -or $coNode -ieq $ev.NodeId) { $ev.CompletionDone = $true }
    }

    # -- staleness note ------------------------------------------------------------
    $gAt = ConvertTo-DbM30Utc $ev.LifecycleGeneratedAtUtc
    $sAt = ConvertTo-DbM30Utc $ev.SelectedAtUtc
    if ($null -ne $gAt -and $null -ne $sAt -and $sAt -gt $gAt) {
        $ev.Warnings.Add('current-lifecycle-state.json is older than current-task.json (lifecycle ' + $ev.LifecycleGeneratedAtUtc + ' vs selectedAt ' + $ev.SelectedAtUtc + '). Snapshot may be stale.')
    }

    return $ev
}

# --- stage token derivation -------------------------------------------------------

function Resolve-DbM30StageTokens {
    <#
    .SYNOPSIS
    Derive the 13 stage display tokens from the evidence predicates. The catalog
    is static; only the Token (and a stage-specific Note) is derived here from
    durable artifacts -- never invented.
    #>
    param([hashtable]$Ev)
    $catalog = Get-DbM30StageCatalog
    $rows = New-Object System.Collections.ArrayList
    foreach ($s in $catalog) {
        $key = [string]$s.StageKey
        $token = 'NOT_STARTED'
        $note = ''
        switch ($key) {
            'GOVERNED_TASK' {
                $token = if ($ev.NodeId) { 'PASS' } else { 'READY' }
            }
            'M03_SELECTION' {
                if (-not $ev.NodeId) { $token = 'NOT_STARTED' }
                elseif ($ev.PreflightClear) { $token = 'PASS' }
                elseif ($ev.PreflightBlocked) {
                    $token = 'BLOCKED'
                    $note = 'Governance block: preflight verdict ' + $ev.PreflightVerdict + '. Resolve the governance decision before proceeding (current-task nextAllowedAction: ' + $ev.CurrentTaskNextAllowedAction + ').'
                }
                elseif ($ev.PreflightPresent) { $token = 'NOT_STARTED'; $note = 'Preflight present but not CLEAR for the current task.' }
                else { $token = 'READY' }
            }
            'DEPENDENCY_CONTEXT' {
                $m03 = ($rows | Where-Object { $_.StageKey -eq 'M03_SELECTION' } | Select-Object -First 1)
                if ($null -ne $m03 -and $m03.Token -eq 'PASS') { $token = 'PASS' }
                elseif ($null -ne $m03 -and $m03.Token -eq 'BLOCKED') { $token = 'BLOCKED' }
                elseif (-not $ev.NodeId) { $token = 'NOT_STARTED' }
                else { $token = 'NOT_STARTED' }
            }
            'M04_RESERVATION' {
                if ($ev.ReservationDone) { $token = 'PASS' }
                elseif ($ev.NodeId -and ($ev.PreflightClear -or $ev.ReservationDone)) { $token = 'READY' }
                elseif ($ev.NodeId -and -not $ev.PreflightPresent) { $token = 'NOT_STARTED' }
                elseif ($ev.NodeId -and $ev.PreflightBlocked) { $token = 'NOT_STARTED' }
                else { $token = 'NOT_STARTED' }
            }
            'M05_CHATGPT_HANDOFF' {
                if ($ev.HandoffDone) { $token = 'PASS' }
                elseif ($ev.ReservationDone) { $token = 'READY' }
                else { $token = 'NOT_STARTED' }
            }
            'AI_RECOMMENDATION_COST' {
                if ($ev.HandoffDone) { $token = 'PASS' }
                elseif ($ev.ReservationDone) { $token = 'READY'; $note = 'Guidance cards are available to review before/during the external implementation.' }
                else { $token = 'NOT_STARTED' }
            }
            'EXTERNAL_IMPLEMENTATION' {
                if ($ev.VerificationDone) { $token = 'PASS' }
                elseif ($ev.HandoffDone) {
                    $token = 'HUMAN_ACTION'
                    $note = 'HUMAN: copy the M05 handoff to ChatGPT; copy ChatGPT''s implementation prompt to Claude Code / DeepSeek; run the implementation externally; return the result for M06 verification.'
                }
                else { $token = 'NOT_STARTED' }
            }
            'M06_VERIFICATION' {
                if ($ev.VerificationFailed) {
                    $token = 'FAIL'
                    $note = 'Verification result was ' + $ev.VerificationPrimaryResult + '. Fix the implementation and re-run verification.'
                }
                elseif ($ev.VerificationDone) { $token = 'PASS' }
                elseif ($ev.HandoffDone) { $token = 'READY' }
                else { $token = 'NOT_STARTED' }
            }
            'M07_REVIEW_PACKAGE' {
                if ($ev.PackageDone) { $token = 'PASS' }
                elseif ($ev.VerificationDone) { $token = 'READY' }
                elseif ($ev.VerificationFailed) { $token = 'NOT_STARTED'; $note = 'Verification failed; a review package cannot be generated until it passes.' }
                else { $token = 'NOT_STARTED' }
            }
            'M08_CLAUDE_DECISION' {
                if ($ev.ClaudeDecisionDone) { $token = 'PASS' }
                elseif ($ev.PackageDone) {
                    $token = 'HUMAN_ACTION'
                    $note = 'HUMAN: send the M07 review package to Claude and record Claude''s decision (scripts\Set-ClaudeReviewResult.ps1).'
                }
                else { $token = 'NOT_STARTED' }
            }
            'CORRECTION_LOOP' {
                if (-not $ev.CorrectionNeeded) { $token = 'NOT_APPLICABLE'; $note = 'Claude decision is not FIX; no correction required.' }
                elseif ($ev.CorrectionDone) { $token = 'PASS' }
                else {
                    $token = 'HUMAN_ACTION'
                    $note = 'HUMAN: run the correction context (scripts\New-CorrectionContext.ps1), fix externally, re-run M06 and M07.'
                }
            }
            'HUMAN_GIT_GATE' {
                if ($ev.TrialMode) { $token = 'NOT_APPLICABLE'; $note = 'TRIAL mode: trial evidence is never merged into Nexus; the human Git gate does not apply.' }
                elseif ($ev.GitMerged) { $token = 'PASS' }
                else { $token = 'READY' }
            }
            'GOVERNED_COMPLETION' {
                if ($ev.TrialMode) { $token = 'NOT_APPLICABLE'; $note = 'TRIAL mode: real completion does not apply. The governed trial-cycle closure path (DB-M12.4) replaces it -- the trial cycle closes with evidence preserved and real roadmap status untouched.' }
                elseif ($ev.CompletionDone) { $token = 'PASS' }
                else { $token = 'READY' }
            }
        }
        $null = $rows.Add([pscustomobject]@{
            StageKey        = $key
            Order           = [int]$s.Order
            Label           = [string]$s.Label
            HumanAction     = [string]$s.HumanAction
            Commands        = @($s.Commands)
            EvidenceSources = @($s.EvidenceSources)
            Token           = $token
            Note            = $note
        })
    }

    # current stage = first READY / HUMAN_ACTION / FAIL / BLOCKED; else terminal.
    $current = $null
    foreach ($r in @($rows)) {
        if ($r.Token -in @('READY', 'HUMAN_ACTION', 'FAIL', 'BLOCKED')) { $current = $r; break }
    }
    if ($null -eq $current) {
        $current = ($rows | Select-Object -Last 1)
    }
    return [pscustomobject]@{
        Stages = @($rows)
        CurrentStage = $current
    }
}

# --- guidance card: DB-M18.1 dependency context ------------------------------------

function Resolve-DbM30DependencyContextCard {
    <#
    .SYNOPSIS
    DB-M18.1 dependency development context for the current task. Reuses the exact
    M05 integration pattern (Task shape + TaskCatalog). Fault-isolated: an
    unavailable resolver degrades to an honest NOT_AVAILABLE card.
    #>
    param(
        [string]$Root,
        [string]$NodeId,
        [string]$ChangeId,
        [string]$TaskName,
        [AllowNull()][object[]]$Dependencies,
        [AllowNull()][hashtable]$TaskCatalog,
        [string]$EvidenceRoot,
        [AllowNull()][string]$RepositoryRoot,
        [string]$NowUtc
    )
    $card = [pscustomobject]@{
        Key = 'DependencyContext'
        CardStatus = 'NOT_AVAILABLE'
        Available = $false
        Note = ''
        FreshnessStatus = ''
        DirectDependencyCount = 0
        DeliveredSummaryCount = 0
        ReusePointCount = 0
        ExtensionPointCount = 0
        CollisionPointCount = 0
        ContextId = ''
        PackageHash = ''
        Error = ''
    }
    if (-not $NodeId) {
        $card.Note = 'No current task selected; dependency context is not applicable yet.'
        return $card
    }
    try {
        $lib = Join-Path $Root 'scripts\ai-routing\DependencyLineage.ps1'
        if (-not (Test-Path -LiteralPath $lib)) { $card.Note = 'DependencyLineage.ps1 unavailable.'; return $card }
        if (-not (Get-Command 'Get-DbM181TaskDependencyContext' -ErrorAction SilentlyContinue)) { . $lib }
        $task = [pscustomobject]@{
            taskId = $NodeId
            nodeId = $NodeId
            changeId = $(if ($ChangeId) { $ChangeId } else { '' })
            name = $TaskName
            dependencies = @($Dependencies)
        }
        if ($null -eq $TaskCatalog) { $TaskCatalog = @{} }
        $bundle = Get-DbM181TaskDependencyContext -Task $task -TaskCatalog $TaskCatalog -EvidenceRoot $EvidenceRoot -RepositoryRoot $RepositoryRoot -NowUtc $NowUtc
        $ctx = $bundle.Context
        $card.CardStatus = 'AVAILABLE'
        $card.Available = $true
        $card.FreshnessStatus = [string](Get-ContractProperty $ctx 'FreshnessStatus' '')
        $card.DirectDependencyCount = @(Get-ContractProperty $ctx 'DirectDependencies' @()).Count
        $card.DeliveredSummaryCount = @(Get-ContractProperty $ctx 'DeliveredSummary' @()).Count
        $card.ReusePointCount = @(Get-ContractProperty $ctx 'ReusePoints' @()).Count
        $card.ExtensionPointCount = @(Get-ContractProperty $ctx 'ExtensionPoints' @()).Count
        $card.CollisionPointCount = @(Get-ContractProperty $ctx 'CollisionPoints' @()).Count
        $card.ContextId = [string](Get-ContractProperty $ctx 'ContextId' '')
        $card.PackageHash = [string](Get-ContractProperty $ctx 'PackageHash' '')
        $card.Note = 'Dependency development context resolved (freshness ' + $card.FreshnessStatus + ').'
        return $card
    } catch {
        $card.CardStatus = 'NOT_AVAILABLE'
        $card.Note = 'Dependency context could not be resolved.'
        $card.Error = [string]$_.Exception.Message
        return $card
    }
}

# --- guidance card: DB-M19 routing recommendation ----------------------------------

function Resolve-DbM30RoutingCard {
    <#
    .SYNOPSIS
    DB-M19 dry-run routing recommendation card. The config gate
    (config/ai-routing.json routingDefaults.enabled) MUST be open; when the gate is
    closed (live config today) the card truthfully reports NOT_ENABLED and never
    enables routing. The enabled path requires a validated dry-run RoutingRequest
    v1 (built from a DB-M14 CapabilityRequirement) injected by the caller.
    Fault-isolated; never executes a provider/model.
    #>
    param(
        [string]$Root,
        [AllowNull()][object]$Configuration,
        [AllowNull()][pscustomobject]$RoutingPolicy,
        [AllowNull()][pscustomobject]$RoutingRequest,
        [AllowNull()][System.Collections.IDictionary]$RoutingProviderHealth,
        [string]$NowUtc
    )
    $card = [pscustomobject]@{
        Key = 'RoutingRecommendation'
        CardStatus = 'NOT_AVAILABLE'
        Available = $false
        Note = ''
        PolicyId = ''
        PolicyEnabled = $false
        RecommendationStatus = ''
        WinnerProviderId = ''
        WinnerModelId = ''
        WinnerReasoningLevel = ''
        WinnerEligible = $false
        EligibleCandidateCount = 0
        RejectedCandidateCount = 0
        RecommendationReason = ''
        Error = ''
    }
    # config gate -- the live gate is closed, so the card reports NOT_ENABLED.
    $gateEnabled = $false
    $cfgPath = Join-Path $Root 'config\ai-routing.json'
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
            $rd = Get-ContractProperty $cfg 'routingDefaults' $null
            $gateEnabled = [bool](Get-ContractProperty $rd 'enabled' $false)
        } catch { $gateEnabled = $false }
    }
    if (-not $gateEnabled) {
        $card.CardStatus = 'NOT_ENABLED'
        $card.Note = 'Routing policy gate (routingDefaults.enabled) is false in config/ai-routing.json. The DB-M19 dry-run recommendation is not enabled; DevBridge never auto-routes. (Enabled path is proven by fixture in the DB-M30 suite.)'
        return $card
    }
    try {
        $policy = $RoutingPolicy
        if ($null -eq $policy) {
            $polLib = Join-Path $Root 'scripts\ai-routing\router\RoutingPolicy.ps1'
            if (Test-Path -LiteralPath $polLib) { . $polLib }
            $policy = Get-DefaultRoutingPolicy
        }
        if ($null -eq $policy) {
            $card.CardStatus = 'NOT_AVAILABLE'
            $card.Note = 'Routing policy could not be loaded.'
            return $card
        }
        $card.PolicyId = [string](Get-ContractProperty $policy 'PolicyId' '')
        $card.PolicyEnabled = ([bool](Get-ContractProperty $policy 'Enabled' $false))
        if (-not $card.PolicyEnabled) {
            $card.CardStatus = 'NOT_ENABLED'
            $card.Note = 'Routing policy ' + $card.PolicyId + ' is disabled.'
            return $card
        }
        if ($null -eq $RoutingRequest) {
            $card.CardStatus = 'NOT_AVAILABLE'
            $card.Note = 'A dry-run routing request (validated DB-M14 CapabilityRequirement) is required for the enabled path; none was supplied.'
            return $card
        }
        $routerLib = Join-Path $Root 'scripts\ai-routing\router\Router.ps1'
        if (-not (Test-Path -LiteralPath $routerLib)) { $card.Note = 'Router.ps1 unavailable.'; return $card }
        if (-not (Get-Command 'Get-AiRoutingRecommendation' -ErrorAction SilentlyContinue)) { . $routerLib }
        $rec = Get-AiRoutingRecommendation -Request $RoutingRequest -Configuration $Configuration -ProviderHealth $RoutingProviderHealth -PerformanceRecords @() -Policy $policy
        $winner = Get-ContractProperty $rec 'Winner' $null
        $card.CardStatus = 'AVAILABLE'
        $card.Available = $true
        $card.RecommendationStatus = [string](Get-ContractProperty $rec 'Status' '')
        $card.WinnerEligible = [bool](Get-ContractProperty $rec 'WinnerEligible' $false)
        if ($null -ne $winner) {
            $card.WinnerProviderId = [string](Get-ContractProperty $winner 'ProviderId' '')
            $card.WinnerModelId = [string](Get-ContractProperty $winner 'ModelId' '')
            $card.WinnerReasoningLevel = [string](Get-ContractProperty $winner 'ReasoningLevel' '')
        }
        $card.EligibleCandidateCount = @(Get-ContractProperty $rec 'EligibleCandidates' @()).Count
        $card.RejectedCandidateCount = @(Get-ContractProperty $rec 'RejectedCandidates' @()).Count
        $card.RecommendationReason = [string](Get-ContractProperty $rec 'RecommendationReason' '')
        $card.Note = 'Dry-run recommendation (MANUAL; nothing is executed).'
        return $card
    } catch {
        $card.CardStatus = 'NOT_AVAILABLE'
        $card.Note = 'Routing recommendation could not be resolved.'
        $card.Error = [string]$_.Exception.Message
        return $card
    }
}

# --- guidance card: DB-M27 cost estimate + DB-M21 budget + DB-M25 history cost ----

function Resolve-DbM30CostGuidanceCard {
    <#
    .SYNOPSIS
    Cost guidance: DB-M27 illustrative estimate for the default coding model,
    a DB-M21 budget-policy summary (informational), and the DB-M25 cost-authority
    totals from the attempt records (ACTUAL vs ESTIMATED). All READ-ONLY.
    Fault-isolated.
    #>
    param(
        [string]$Root,
        [AllowNull()][object]$Configuration,
        [AllowNull()][object[]]$AttemptRecords,
        [AllowNull()][pscustomobject]$BudgetPolicy,
        [string]$DefaultProviderId,
        [string]$DefaultModelId,
        [string]$RouteType,
        [string]$ReasoningLevel,
        [string]$TargetCurrency,
        [string]$NowUtc,
        [Nullable[long]]$InputTokens,
        [Nullable[long]]$OutputTokens
    )
    $card = [pscustomobject]@{
        Key = 'CostGuidance'
        CardStatus = 'NOT_AVAILABLE'
        Available = $false
        Note = ''
        Scenario = ''
        EstimatedCost = $null
        CostCurrency = ''
        EstimateSource = ''
        BudgetDecision = ''
        BudgetCurrency = ''
        BudgetNote = ''
        TotalActualCost = 0.0
        TotalEstimatedCost = 0.0
        AttemptCount = 0
        Error = ''
    }
    try {
        $calcLib = Join-Path $Root 'scripts\ai-routing\calculator\CalculatorEngine.ps1'
        $foundationLib = Join-Path $Root 'scripts\ai-routing\AiRoutingCostFoundation.ps1'
        if (-not (Test-Path -LiteralPath $calcLib)) { $card.Note = 'CalculatorEngine.ps1 unavailable.'; return $card }
        $cfg = $Configuration
        if ($null -eq $cfg -and (Test-Path -LiteralPath $foundationLib)) {
            if (-not (Get-Command 'Import-AiCostConfiguration' -ErrorAction SilentlyContinue)) { . $foundationLib }
            try { $cfg = Import-AiCostConfiguration -Root $Root } catch { $cfg = $null }
        }
        if (-not (Get-Command 'Invoke-DbM27Calculator' -ErrorAction SilentlyContinue)) { . $calcLib }
        $request = New-DbM27CalculatorRequest `
            -ProviderId $DefaultProviderId -RouteType $RouteType -ModelId $DefaultModelId `
            -ReasoningLevel $ReasoningLevel `
            -InputTokens $InputTokens -OutputTokens $OutputTokens `
            -AttemptCount 1 -ExpectedCorrectionAttempts 0 `
            -CurrencyTarget $TargetCurrency -NowUtc $NowUtc
        $view = Invoke-DbM27Calculator -Configuration $cfg -Request $request -AttemptRecords @($AttemptRecords) -BudgetPolicy $BudgetPolicy
        $est = Get-ContractProperty $view 'Estimate' $null
        $card.CardStatus = 'AVAILABLE'
        $card.Available = $true
        $card.Scenario = $DefaultProviderId + '/' + $DefaultModelId + ' ' + $RouteType + ' ' + $ReasoningLevel
        $card.EstimatedCost = Get-ContractProperty $est 'EstimatedCost' $null
        $card.CostCurrency = [string](Get-ContractProperty $est 'CostCurrency' '')
        $card.EstimateSource = [string](Get-ContractProperty $est 'EstimatedOrActual' 'ESTIMATED')

        # DB-M21 budget summary (informational; disabled/missing policy degrades to a note)
        if ($null -ne $BudgetPolicy) {
            try {
                if (-not (Get-Command 'Test-AiBudget' -ErrorAction SilentlyContinue)) {
                    $budgetLib = Join-Path $Root 'scripts\ai-routing\budget\BudgetEngine.ps1'
                    if (Test-Path -LiteralPath $budgetLib) { . $budgetLib }
                }
                if (Get-Command 'Test-AiBudget' -ErrorAction SilentlyContinue) {
                    $bud = Test-AiBudget -Policy $BudgetPolicy -EvaluationTimestampUtc $NowUtc -Attempts @($AttemptRecords) `
                        -ProposedAttemptCost $card.EstimatedCost -ProposedCostCurrency $card.CostCurrency
                    $card.BudgetDecision = [string](Get-ContractProperty $bud 'Decision' '')
                    $card.BudgetCurrency = [string](Get-ContractProperty $bud 'Currency' '')
                    $card.BudgetNote = 'Budget policy informational only (DB-M21); the estimate above is advisory.'
                } else {
                    $card.BudgetNote = 'Budget engine unavailable; no budget evaluation (informational).'
                }
            } catch {
                $card.BudgetNote = 'Budget policy could not be evaluated: ' + [string]$_.Exception.Message
            }
        } else {
            $card.BudgetNote = 'No budget policy supplied (DB-M21 informational); live config carries no budget file.'
        }

        # DB-M25 cost-authority totals from the records (READ-ONLY)
        $records = Get-DbM30Array $AttemptRecords
        $totalActual = 0.0
        $totalEstimated = 0.0
        if ($records.Count -gt 0) {
            if (-not (Get-Command 'Resolve-DbM25RecordCost' -ErrorAction SilentlyContinue)) {
                $qcLib = Join-Path $Root 'scripts\ai-routing\quality-cost\QualityCost.ps1'
                if (Test-Path -LiteralPath $qcLib) { . $qcLib }
            }
            if (Get-Command 'Resolve-DbM25RecordCost' -ErrorAction SilentlyContinue) {
                foreach ($r in $records) {
                    $c = Resolve-DbM25RecordCost -Record $r -ReportingCurrencyUpper $TargetCurrency.ToUpperInvariant() -AllowEstimatedFallback $true
                    if ([bool]$c.Used) {
                        if ([string]$c.Source -eq 'ACTUAL') { $totalActual += [double]$c.Amount }
                        else { $totalEstimated += [double]$c.Amount }
                    }
                }
            }
        }
        $card.TotalActualCost = $totalActual
        $card.TotalEstimatedCost = $totalEstimated
        $card.AttemptCount = $records.Count
        $card.Note = 'Illustrative estimate (DB-M27) + budget summary (DB-M21) + history cost totals (DB-M25 authority).'
        return $card
    } catch {
        $card.CardStatus = 'NOT_AVAILABLE'
        $card.Note = 'Cost guidance could not be resolved.'
        $card.Error = [string]$_.Exception.Message
        return $card
    }
}

# --- guidance card: DB-M22 provider health -----------------------------------------

function Resolve-DbM30ProviderHealthCard {
    <#
    .SYNOPSIS
    DB-M22 effective provider-health view for the default provider route.
    READ-ONLY; empty evidence renders an honest EMPTY card (no invented health).
    #>
    param(
        [string]$Root,
        [AllowNull()][object[]]$ProviderHealthState,
        [AllowNull()][pscustomobject]$ProviderHealthPolicy,
        [string]$DefaultProviderId,
        [string]$GatewayProviderId,
        [string]$NowUtc
    )
    $card = [pscustomobject]@{
        Key = 'ProviderHealth'
        CardStatus = 'NOT_AVAILABLE'
        Available = $false
        Note = ''
        HealthState = ''
        CircuitState = ''
        RequiresHuman = $false
        FreshEvidenceCount = 0
        Error = ''
    }
    try {
        $evidence = Get-DbM30Array $ProviderHealthState
        if ($evidence.Count -eq 0) {
            $card.CardStatus = 'EMPTY'
            $card.Note = 'No provider-health evidence recorded for ' + $DefaultProviderId + '.'
            return $card
        }
        $healthLib = Join-Path $Root 'scripts\ai-routing\provider-health\ProviderHealthEngine.ps1'
        if (-not (Test-Path -LiteralPath $healthLib)) { $card.Note = 'ProviderHealthEngine.ps1 unavailable.'; return $card }
        if (-not (Get-Command 'Get-EffectiveProviderHealth' -ErrorAction SilentlyContinue)) { . $healthLib }
        $policy = $ProviderHealthPolicy
        if ($null -eq $policy) {
            $polLib = Join-Path $Root 'scripts\ai-routing\provider-health\ProviderHealthPolicy.ps1'
            if (Test-Path -LiteralPath $polLib) { . $polLib }
            if (-not (Get-Command 'Get-DefaultProviderHealthPolicy' -ErrorAction SilentlyContinue)) { throw 'default provider-health policy unavailable' }
            $policy = Get-DefaultProviderHealthPolicy
        }
        $h = Get-EffectiveProviderHealth -Evidence $evidence -Policy $policy -EvaluationTimestampUtc $NowUtc `
            -ProviderId $DefaultProviderId -GatewayProviderId $GatewayProviderId
        $card.CardStatus = 'AVAILABLE'
        $card.Available = $true
        $card.HealthState = [string](Get-ContractProperty $h 'HealthState' '')
        $card.CircuitState = [string](Get-ContractProperty $h 'CircuitState' '')
        $card.RequiresHuman = [bool](Get-ContractProperty $h 'RequiresHuman' $false)
        $card.FreshEvidenceCount = [int](Get-ContractProperty $h 'FreshEvidenceCount' 0)
        $card.Note = 'Effective provider health (DB-M22), read-only.'
        return $card
    } catch {
        $card.CardStatus = 'NOT_AVAILABLE'
        $card.Note = 'Provider-health view could not be resolved.'
        $card.Error = [string]$_.Exception.Message
        return $card
    }
}

# --- guidance card: DB-M26 + DB-M29 history ----------------------------------------

function Resolve-DbM30HistoryCard {
    <#
    .SYNOPSIS
    History card: DB-M26 aggregate view + DB-M29 per-task drilldown, both READ-ONLY
    over the passed attempt records (or the live DB-M17 store when none are
    supplied). An empty store renders the honest empty state -- never invented
    history.
    #>
    param(
        [string]$Root,
        [AllowNull()][object[]]$AttemptRecords,
        [AllowNull()][object[]]$EscalationDecisions,
        [AllowNull()][object[]]$Fingerprints,
        [AllowNull()][object[]]$ProviderHealthState,
        [AllowNull()][pscustomobject]$BudgetPolicy,
        [string]$NodeId,
        [string]$NowUtc,
        [string]$ReportingCurrency
    )
    $card = [pscustomobject]@{
        Key = 'History'
        CardStatus = 'NOT_AVAILABLE'
        Available = $false
        Note = ''
        Count = 0
        Empty = $false
        TaskRowCount = 0
        DashboardAvailable = $false
        HistoryViewAvailable = $false
        Error = ''
    }
    try {
        $records = Get-DbM30Array $AttemptRecords
        if ($records.Count -eq 0) {
            $storeLib = Join-Path $Root 'scripts\ai-routing\AttemptStore.ps1'
            if (Test-Path -LiteralPath $storeLib) {
                if (-not (Get-Command 'Get-AiAttemptsAll' -ErrorAction SilentlyContinue)) { . $storeLib }
                if (Get-Command 'Get-AiAttemptsAll' -ErrorAction SilentlyContinue) {
                    try { $records = @(Get-AiAttemptsAll -Root $Root) } catch { $records = @() }
                }
            }
        }
        $card.Count = $records.Count
        $card.Empty = ($records.Count -eq 0)

        # DB-M26 aggregate (READ-ONLY)
        $dashLib = Join-Path $Root 'scripts\ai-routing\dashboard\DashboardData.ps1'
        if (Test-Path -LiteralPath $dashLib) {
            if (-not (Get-Command 'Get-DbM26DashboardView' -ErrorAction SilentlyContinue)) { . $dashLib }
            if (Get-Command 'Get-DbM26DashboardView' -ErrorAction SilentlyContinue) {
                $dashRequest = New-DbM26DashboardRequest -RequestId 'dbm30-dash' -PresetWindow 'ALL_TIME' -NowUtc $NowUtc -ReportingCurrency $ReportingCurrency
                $dash = Get-DbM26DashboardView -Records $records -Request $dashRequest -NowUtc $NowUtc -BudgetPolicy $BudgetPolicy -ProviderHealthState (Get-DbM30Array $ProviderHealthState)
                $card.DashboardAvailable = ($null -ne $dash)
            }
        }

        # DB-M29 per-task drilldown (READ-ONLY)
        $histLib = Join-Path $Root 'scripts\ai-routing\task-history\HistoryEngine.ps1'
        if (Test-Path -LiteralPath $histLib) {
            if (-not (Get-Command 'Get-DbM29TaskHistoryView' -ErrorAction SilentlyContinue)) { . $histLib }
            if (Get-Command 'Get-DbM29TaskHistoryView' -ErrorAction SilentlyContinue) {
                $histQuery = New-DbM29TaskHistoryQuery -QueryId 'dbm30-hist' -NowUtc $NowUtc -Currency $ReportingCurrency -TaskId $(if ($NodeId) { $NodeId } else { '' })
                $hist = Get-DbM29TaskHistoryView -Records $records -Query $histQuery -EscalationDecisions (Get-DbM30Array $EscalationDecisions) -Fingerprints (Get-DbM30Array $Fingerprints) -ProviderHealth (Get-DbM30Array $ProviderHealthState)
                $card.HistoryViewAvailable = ($null -ne $hist)
                $card.TaskRowCount = [int](Get-ContractProperty $hist 'Count' 0)
            }
        }

        if ($records.Count -eq 0) {
            $card.CardStatus = 'EMPTY'
            $card.Note = 'No attempt history recorded. (DB-M17 attempt store is READ-ONLY; empty today.)'
        } elseif ($card.DashboardAvailable -or $card.HistoryViewAvailable) {
            $card.CardStatus = 'AVAILABLE'
            $card.Available = $true
            $card.Note = 'History: ' + $records.Count + ' attempt record(s); ' + $card.TaskRowCount + ' task row(s) in the per-task drilldown.'
        } else {
            $card.CardStatus = 'NOT_AVAILABLE'
            $card.Note = 'History engines unavailable; count reported only.'
        }
        return $card
    } catch {
        $card.CardStatus = 'NOT_AVAILABLE'
        $card.Note = 'History card could not be resolved.'
        $card.Error = [string]$_.Exception.Message
        return $card
    }
}

# --- orchestrator -------------------------------------------------------------------

function Get-DbM30WorkflowView {
    <#
    .SYNOPSIS
    The DB-M30 orchestrator: load lifecycle evidence, derive the 13 stage tokens,
    designate the current stage, assemble the guidance cards and wrap the result in
    the read-only guard. PURE: artifacts/records/decisions in, SupervisedWorkflowView
    v1 out; writes nothing.
    #>
    param(
        [AllowNull()][string]$StateDir,
        [AllowNull()][string]$EvidenceRoot,
        [AllowNull()][string]$RepositoryRoot,
        [AllowNull()][string]$NowUtc,
        [AllowNull()][object]$Configuration,
        [AllowNull()][pscustomobject]$RoutingPolicy,
        [AllowNull()][pscustomobject]$RoutingRequest,
        [AllowNull()][System.Collections.IDictionary]$RoutingProviderHealth,
        [AllowNull()][object[]]$AttemptRecords,
        [AllowNull()][object[]]$EscalationDecisions,
        [AllowNull()][object[]]$Fingerprints,
        [AllowNull()][object[]]$ProviderHealthState,
        [AllowNull()][pscustomobject]$ProviderHealthPolicy,
        [AllowNull()][pscustomobject]$BudgetPolicy,
        [AllowNull()][hashtable]$TaskCatalog,
        [string]$DefaultProviderId = 'deepseek',
        [string]$DefaultModelId = 'deepseek-v4-flash',
        [string]$DefaultReviewerModelId = 'claude-opus-5',
        [string]$RouteType = 'DIRECT',
        [string]$ReasoningLevel = 'MEDIUM',
        [string]$TargetCurrency = 'INR',
        [Nullable[long]]$InputTokens = 5000,
        [Nullable[long]]$OutputTokens = 1500
    )
    $now = ConvertTo-DbM30Utc $NowUtc
    if ($null -eq $now) { $now = [datetime]::UtcNow }
    $nowStr = $now.ToString('o')

    $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $stateDir = if ($StateDir) { $StateDir } else { Join-Path $root 'state' }
    $evidenceRoot = if ($EvidenceRoot) { $EvidenceRoot } else { Join-Path $root 'logs\tasks' }

    $ev = Resolve-DbM30LifecycleEvidence -StateDir $stateDir -EvidenceRoot $evidenceRoot -Root $root -NowUtc $nowStr
    $stageResult = Resolve-DbM30StageTokens -Ev $ev

    # dependency list for the current task comes from preflight.json (the same
    # source M05 uses for the Task shape)
    $dependencies = @()
    $pf = Read-DbM30JsonFile (Join-Path $stateDir 'preflight.json')
    if ($pf.Present -and $null -ne $pf.Value) { $dependencies = @(Get-ContractProperty $pf.Value 'dependencies' @()) }

    # repository root: from the reservation git baseline (same source as M05), else
    # the caller-provided root. Absent -> DB-M18.1 reports UNVERIFIED (never stale).
    $repositoryRoot = $RepositoryRoot
    if (-not $repositoryRoot) {
        $rs = Read-DbM30JsonFile (Join-Path $stateDir 'reservation.json')
        if ($rs.Present -and $null -ne $rs.Value) {
            $gb = Get-ContractProperty $rs.Value 'gitBaseline' $null
            $repositoryRoot = [string](Get-ContractProperty $gb 'repository' '')
            if (-not $repositoryRoot) { $repositoryRoot = $null }
        }
    }

    $configuration = $Configuration
    if ($null -eq $configuration) {
        $foundationLib = Join-Path $root 'scripts\ai-routing\AiRoutingCostFoundation.ps1'
        if (Test-Path -LiteralPath $foundationLib) {
            try {
                if (-not (Get-Command 'Import-AiCostConfiguration' -ErrorAction SilentlyContinue)) { . $foundationLib }
                $configuration = Import-AiCostConfiguration -Root $root
            } catch { $configuration = $null }
        }
    }

    # --- guidance cards (each fault-isolated) --------------------------------------
    $depCard = Resolve-DbM30DependencyContextCard -Root $root -NodeId $ev.NodeId -ChangeId $ev.ChangeId `
        -TaskName $ev.TaskName -Dependencies $dependencies -TaskCatalog $TaskCatalog `
        -EvidenceRoot $evidenceRoot -RepositoryRoot $repositoryRoot -NowUtc $nowStr

    $routingCard = Resolve-DbM30RoutingCard -Root $root -Configuration $configuration `
        -RoutingPolicy $RoutingPolicy -RoutingRequest $RoutingRequest `
        -RoutingProviderHealth $RoutingProviderHealth -NowUtc $nowStr

    $costCard = Resolve-DbM30CostGuidanceCard -Root $root -Configuration $configuration `
        -AttemptRecords @($AttemptRecords) -BudgetPolicy $BudgetPolicy `
        -DefaultProviderId $DefaultProviderId -DefaultModelId $DefaultModelId `
        -RouteType $RouteType -ReasoningLevel $ReasoningLevel -TargetCurrency $TargetCurrency `
        -NowUtc $nowStr -InputTokens $InputTokens -OutputTokens $OutputTokens

    $healthCard = Resolve-DbM30ProviderHealthCard -Root $root -ProviderHealthState @($ProviderHealthState) `
        -ProviderHealthPolicy $ProviderHealthPolicy -DefaultProviderId $DefaultProviderId `
        -GatewayProviderId '' -NowUtc $nowStr

    $historyCard = Resolve-DbM30HistoryCard -Root $root -AttemptRecords @($AttemptRecords) `
        -EscalationDecisions @($EscalationDecisions) -Fingerprints @($Fingerprints) `
        -ProviderHealthState @($ProviderHealthState) -BudgetPolicy $BudgetPolicy `
        -NodeId $ev.NodeId -NowUtc $nowStr -ReportingCurrency $TargetCurrency

    # --- view assembly -------------------------------------------------------------
    $stateSource = 'FIXTURE'
    $liveStateDir = Join-Path $root 'state'
    if ([System.IO.Path]::GetFullPath($stateDir) -eq [System.IO.Path]::GetFullPath($liveStateDir)) { $stateSource = 'LIVE' }

    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($w in @($ev.Warnings)) { $warnings.Add([string]$w) }

    $view = [pscustomobject]@{
        SchemaVersion = 1
        ViewId = 'DBM30-' + $now.ToString('yyyyMMddHHmmss')
        GeneratedAtUtc = $nowStr
        NowUtc = $nowStr
        StateSource = $stateSource
        StateDir = $stateDir
        EvidenceRoot = $evidenceRoot
        RepositoryRoot = $repositoryRoot
        LifecycleSnapshot = [pscustomobject]@{
            Mode = $ev.LifecycleMode
            TrialMode = $ev.TrialMode
            Status = $ev.LifecycleStatus
            NextAllowedAction = $ev.CurrentTaskNextAllowedAction
            Task = [pscustomobject]@{
                NodeId = $ev.NodeId
                ChangeId = $ev.ChangeId
                Name = $ev.TaskName
                Status = $ev.CurrentTaskStatus
                PreflightVerdict = $ev.CurrentTaskPreflightVerdict
                Implementability = $ev.CurrentTaskImplementability
                WorkbookSha256 = $ev.WorkbookSha256
            }
            Evidence = [pscustomobject]@{
                TaskSelected = [bool]$ev.NodeId
                PreflightClear = $ev.PreflightClear
                PreflightBlocked = $ev.PreflightBlocked
                ReservationDone = $ev.ReservationDone
                HandoffDone = $ev.HandoffDone
                VerificationDone = $ev.VerificationDone
                PackageDone = $ev.PackageDone
                ClaudeDecisionDone = $ev.ClaudeDecisionDone
                ClaudeDecision = $ev.ClaudeDecision
                CorrectionNeeded = $ev.CorrectionNeeded
                CorrectionDone = $ev.CorrectionDone
                TrialMode = $ev.TrialMode
                GitMerged = $ev.GitMerged
                CompletionDone = $ev.CompletionDone
            }
        }
        CurrentStage = [pscustomobject]@{
            StageKey = [string]$stageResult.CurrentStage.StageKey
            Order = [int]$stageResult.CurrentStage.Order
            Label = [string]$stageResult.CurrentStage.Label
            Token = [string]$stageResult.CurrentStage.Token
            Note = [string]$stageResult.CurrentStage.Note
            HumanAction = [string]$stageResult.CurrentStage.HumanAction
        }
        Stages = @($stageResult.Stages)
        Cards = [pscustomobject]@{
            DependencyContext = $depCard
            RoutingRecommendation = $routingCard
            CostGuidance = $costCard
            ProviderHealth = $healthCard
            History = $historyCard
        }
        ReadOnlyGuard = New-DbM30ReadOnlyGuard
        Warnings = @($warnings)
    }
    return $view
}
