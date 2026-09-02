# WorkflowContracts.ps1 -- DB-M30 SUPERVISED DEVELOPMENT WORKFLOW INTEGRATION contracts.
#
# DB-M30 is a READ-ONLY supervised workflow guide for the DevBridge operator. It
# integrates the existing lifecycle, dependency context, AI recommendation, cost
# information and history systems into ONE coherent guided pipeline. It NEVER
# advances the lifecycle, executes a model/provider, invokes ChatGPT / Claude
# Code / Claude, creates/approves/merges PRs, modifies the roadmap, or restores a
# baseline. Every external step belongs to the human operator.
#
# AUTO_EXECUTION_ENABLED = FALSE. No AI/provider/paid/network calls, no writes
# beyond the operator-requested HTML artifact, no secrets stored.
#
# This file is self-contained (no dot-sources) so it is always safe to load.

Set-StrictMode -Version Latest

# --- defensive property reader (self-contained; identical semantics to the DB-M14
# --- Get-ContractProperty shared helper, so loading it here can never conflict) --

function Get-ContractProperty {
    <#
    .SYNOPSIS
    Read a property from a PSCustomObject or IDictionary defensively, returning a
    default when absent or null (JSON deserialization omits null properties).
    Identical semantics to the DB-M14 shared helper.
    #>
    param(
        [AllowNull()][object]$Object,
        [string]$Name,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $Default
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop -and $null -ne $prop.Value) { return $prop.Value }
    return $Default
}

# --- array normalization (PS 5.1: @($null) is a 1-element array, not empty) -------

function Get-DbM30Array {
    <#
    .SYNOPSIS
    Normalize a possibly-null/scalar value into a clean object array with null
    elements removed. PS 5.1 gotcha: @($null) yields an array containing one null;
    this helper guarantees an honest empty array when there is no evidence.
    #>
    param($Value)
    if ($null -eq $Value) { return ,@() }
    $out = New-Object System.Collections.ArrayList
    foreach ($item in @($Value)) { if ($null -ne $item) { [void]$out.Add($item) } }
    return ,@($out.ToArray())
}

# --- stage display vocabulary (reuses the DevBridge.Engine 8-token vocabulary) ---

function Get-DbM30StageVocab {
    <#
    .SYNOPSIS
    The 8 display tokens for a workflow stage (same vocabulary the DevBridge
    StageDisplay engine exposes: NOT_STARTED / READY / CURRENT / PASS / FAIL /
    BLOCKED / HUMAN_ACTION / NOT_APPLICABLE). DB-M30 derives tokens from durable
    lifecycle artifacts -- it never invents a stage state.
    #>
    return @('NOT_STARTED', 'READY', 'CURRENT', 'PASS', 'FAIL', 'BLOCKED', 'HUMAN_ACTION', 'NOT_APPLICABLE')
}

# --- guidance card statuses ---

function Get-DbM30CardStatuses {
    <#
    .SYNOPSIS
    Status vocabulary for guidance cards. AVAILABLE = evidence/guidance present.
    NOT_AVAILABLE = the subsystem could not be resolved (honest degradation).
    NOT_ENABLED = the subsystem is deliberately disabled (e.g. routing policy
    gate). EMPTY = the subsystem is healthy but has no evidence (e.g. an empty
    attempt history store).
    #>
    return @('AVAILABLE', 'NOT_AVAILABLE', 'NOT_ENABLED', 'EMPTY')
}

# --- timestamp helpers (deterministic; NowUtc is injected) ---

function ConvertTo-DbM30Utc {
    <#
    .SYNOPSIS
    Parse a UTC timestamp string into a DateTime, or $null when absent/invalid.
    #>
    param($Value)
    if ($null -eq $Value -or ([string]$Value).Trim() -eq '') { return $null }
    try { return [datetime]::ParseExact([string]$Value, 'o', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { return $null }
}

function Get-DbM30Now {
    <#
    .SYNOPSIS
    Current UTC instant (used only when the caller does not inject NowUtc).
    #>
    return [datetime]::UtcNow.ToString('o')
}

# --- the 13-stage supervised workflow catalog ---

function Get-DbM30StageCatalog {
    <#
    .SYNOPSIS
    The 13-stage supervised workflow catalog (ordered). Each stage carries the
    operator's human action, the lifecycle commands the operator runs (stages
    that are lifecycle commands), and the durable evidence sources that mark it
    DONE. The engine derives each stage's display token from those evidence
    sources -- never from invented state.
    #>
    return @(
        [pscustomobject]@{
            StageKey       = 'GOVERNED_TASK'
            Order          = 1
            Label          = 'Governed Task'
            HumanAction    = 'Select the governed task from the workbook (human chooses the work item to advance).'
            Commands       = @()
            EvidenceSources = @('state/current-task.json has a nodeId')
        }
        [pscustomobject]@{
            StageKey       = 'M03_SELECTION'
            Order          = 2
            Label          = 'M03 Task Selection & Preflight'
            HumanAction    = 'Run preflight to select the next implementable task; resolve a governance block if preflight reports one.'
            Commands       = @('scripts\Test-DevelopmentPreflight.ps1')
            EvidenceSources = @('state/preflight.json present', 'current-task.status in PREFLIGHTED/RESERVED/...')
        }
        [pscustomobject]@{
            StageKey       = 'DEPENDENCY_CONTEXT'
            Order          = 3
            Label          = 'Dependency Development Context'
            HumanAction    = 'Review the auto-resolved dependency lineage context (DB-M18.1) before reserving or handing off.'
            Commands       = @()
            EvidenceSources = @('DB-M18.1 context resolved for the current task (informational; PASS once M03 is done)')
        }
        [pscustomobject]@{
            StageKey       = 'M04_RESERVATION'
            Order          = 4
            Label          = 'M04 Reservation'
            HumanAction    = 'Run reserve to reserve the change against the governed task.'
            Commands       = @('scripts\Reserve-DevelopmentChange.ps1')
            EvidenceSources = @('state/reservation.json present', 'a changeId on the current task')
        }
        [pscustomobject]@{
            StageKey       = 'M05_CHATGPT_HANDOFF'
            Order          = 5
            Label          = 'M05 ChatGPT Handoff'
            HumanAction    = 'Run handoff generation; the handoff carries the DB-M18.1 dependency context and trial-proven dependency truth.'
            Commands       = @('scripts\New-ChatGptHandoff.ps1')
            EvidenceSources = @('logs/tasks/<node>/<change>/CHATGPT_HANDOFF.md present')
        }
        [pscustomobject]@{
            StageKey       = 'AI_RECOMMENDATION_COST'
            Order          = 6
            Label          = 'AI Recommendation & Cost Guidance'
            HumanAction    = 'Review the dry-run routing recommendation and the cost/budget/history guidance cards before implementing externally.'
            Commands       = @()
            EvidenceSources = @('guidance cards consumed (informational; PASS once M05 is done)')
        }
        [pscustomobject]@{
            StageKey       = 'EXTERNAL_IMPLEMENTATION'
            Order          = 7
            Label          = 'External Implementation (supervised)'
            HumanAction    = 'HUMAN: copy the handoff to ChatGPT; copy ChatGPT''s implementation prompt to Claude Code / DeepSeek; run the implementation externally; return the result.'
            Commands       = @()
            EvidenceSources = @('M06 verification evidence present (the human-returned result is verified deterministically)')
        }
        [pscustomobject]@{
            StageKey       = 'M06_VERIFICATION'
            Order          = 8
            Label          = 'M06 Deterministic Verification'
            HumanAction    = 'Run deterministic verification over the returned implementation result.'
            Commands       = @('scripts\Run-Verification.ps1', 'scripts\Verify-Task.ps1')
            EvidenceSources = @('state/verification.json present', 'logs/tasks/<node>/<change>/VERIFICATION_RESULT.md present')
        }
        [pscustomobject]@{
            StageKey       = 'M07_REVIEW_PACKAGE'
            Order          = 9
            Label          = 'M07 Claude Review Package'
            HumanAction    = 'Run review-package generation; the package distinguishes real status from trial-proven state.'
            Commands       = @('scripts\New-ClaudeReviewPackage.ps1')
            EvidenceSources = @('logs/tasks/<node>/<change>/CLAUDE_REVIEW_PACKAGE.md present')
        }
        [pscustomobject]@{
            StageKey       = 'M08_CLAUDE_DECISION'
            Order          = 10
            Label          = 'M08 Claude Decision'
            HumanAction    = 'HUMAN: send the review package to Claude; record Claude''s decision.'
            Commands       = @('scripts\Set-ClaudeReviewResult.ps1')
            EvidenceSources = @('state/claude-review.json present', 'logs/tasks/<node>/<change>/CLAUDE_DECISION_RESULT.md present')
        }
        [pscustomobject]@{
            StageKey       = 'CORRECTION_LOOP'
            Order          = 11
            Label          = 'Correction Loop'
            HumanAction    = 'If Claude requested fixes, run the correction context, fix externally, re-run M06 and M07; otherwise not required.'
            Commands       = @('scripts\New-CorrectionContext.ps1')
            EvidenceSources = @('NOT_APPLICABLE unless the Claude decision is FIX', 'PASS when the correction is verified')
        }
        [pscustomobject]@{
            StageKey       = 'HUMAN_GIT_GATE'
            Order          = 12
            Label          = 'Human Git Gate'
            HumanAction    = 'HUMAN Git gates and merge (REAL mode only; NOT_APPLICABLE in TRIAL mode -- trial evidence is never merged into Nexus).'
            Commands       = @('scripts\Get-GitGateState.ps1')
            EvidenceSources = @('NOT_APPLICABLE in TRIAL mode', 'PASS once the merge is confirmed in REAL mode')
        }
        [pscustomobject]@{
            StageKey       = 'GOVERNED_COMPLETION'
            Order          = 13
            Label          = 'Governed Completion'
            HumanAction    = 'Run governed completion. TRIAL mode: the governed trial-cycle closure path (DB-M12.4) replaces real completion -- the trial cycle closes with evidence preserved and real roadmap status untouched.'
            Commands       = @('scripts\Complete-GovernedCycle.ps1', 'scripts\Complete-Task.ps1')
            EvidenceSources = @('NOT_APPLICABLE in TRIAL mode', 'PASS once completion evidence appears')
        }
    )
}

# --- read-only guard ---

function New-DbM30ReadOnlyGuard {
    <#
    .SYNOPSIS
    Deterministic no-execution guard (DB-M29 pattern). DB-M30 never executes an
    AI model, never makes a paid/network call, never mutates the lifecycle state,
    the attempt store, escalation decisions, budget policy or fingerprints, never
    enables routing, never renders/logs a secret, never touches the workbook or
    the Nexus repos.
    #>
    return [pscustomobject]@{
        SchemaVersion                = 1
        AutoExecutionEnabled         = $false
        PaidApiCalls                 = 0
        NetworkCalls                 = 0
        LifecycleStateModified       = 'NO'
        RoutingPolicyModified        = 'NO'
        AttemptStoreModified         = 'NO'
        EscalationDecisionsModified  = 'NO'
        BudgetPolicyModified         = 'NO'
        FingerprintsModified         = 'NO'
        WorkbookModified             = 'NO'
        NexusSourceModified          = 'NO'
        SecretValuesDisplayed        = 'NO'
        SecretValuesLogged           = 'NO'
    }
}

# --- secret-value scanner (DB-M30 variant of the DB-M29 scanner) ---

function Test-DbM30SecretLeak {
    <#
    .SYNOPSIS
    Scan a DB-M30 view object (or any object) for API-key-like VALUES.
    Identifiers, references, hashes, vocabulary values and numeric cost fields
    are exempt by design; free-text fields (Explanation, Warnings, Notes,
    RecommendationReason, Reason, HumanAction, Note) ARE scanned. Never stores
    secrets. Returns @{ Leak; Fields }.
    #>
    param(
        [AllowNull()][object]$Target
    )
    $exempt = @(
        'SchemaVersion', 'ViewId', 'StageKey', 'Order', 'Label', 'Token',
        'GeneratedAtUtc', 'NowUtc', 'StateSource', 'StateDir', 'EvidenceRoot',
        'RepositoryRoot', 'Mode', 'TrialMode', 'TaskId', 'NodeId', 'ChangeId',
        'Name', 'Status', 'NextAllowedAction', 'PreflightVerdict',
        'Implementability', 'WorkbookSha256', 'Key', 'Status',
        'FreshnessStatus', 'DirectDependencyCount', 'DeliveredSummaryCount',
        'ReusePointCount', 'ExtensionPointCount', 'CollisionPointCount',
        'ContextMetrics', 'PackageHash', 'ContextId', 'ContextVersion',
        'ContextTimestampUtc', 'PolicyId', 'PolicyName', 'Enabled',
        'WinnerProviderId', 'WinnerModelId', 'WinnerReasoningLevel', 'RouteType',
        'ReasoningLevel', 'TargetCurrency', 'EstimatedCost', 'Currency',
        'EstimateSource', 'BudgetDecision', 'HealthState', 'CircuitState',
        'Count', 'Empty', 'AutoExecutionEnabled', 'PaidApiCalls', 'NetworkCalls',
        'LifecycleStateModified', 'RoutingPolicyModified', 'AttemptStoreModified',
        'EscalationDecisionsModified', 'BudgetPolicyModified',
        'FingerprintsModified', 'WorkbookModified', 'NexusSourceModified',
        'SecretValuesDisplayed', 'SecretValuesLogged', 'Commands',
        'EvidenceSources', 'DependencyId', 'DependencyCount',
        'ProviderId', 'ModelId', 'WinnerEligible', 'EligibleCandidateCount',
        'RejectedCandidateCount', 'RecommendationStatus', 'TaskRows',
        'SummaryCards', 'CostBreakdown', 'ChainView', 'AttemptHistory',
        'VerifiedSuccessView', 'RequiresHuman', 'GatewayProviderId',
        'UnderlyingModelId', 'Available', 'CardStatus',
        'Configuration', 'Request', 'Records'
    )
    $patterns = @(
        '^sk-[A-Za-z0-9_-]{8,}$',                 # OpenAI-style
        '^AIza[0-9A-Za-z_-]{10,}$',               # Google-style
        '^gh[pousr]_[A-Za-z0-9]{20,}$',           # GitHub tokens
        '^[A-Za-z0-9+/=_\-]{32,}$',               # generic high-entropy token
        '^-----BEGIN'                             # PEM block
    )
    $leaks = New-Object System.Collections.Generic.List[string]

    function Test-DbM30LeakValue([string]$fieldName, [object]$value) {
        if ($null -eq $value) { return }
        if ($fieldName -in $exempt) { return }
        $s = [string]$value
        if ($s.Length -lt 8) { return }
        foreach ($p in $patterns) {
            if ($s -match $p) { $leaks.Add("$fieldName = <redacted> matches $p"); return }
        }
        if ($s -match '(?i)(api[_-]?key|secret|password|token)\s*[=:]\s*\S') {
            $leaks.Add("$fieldName contains inline credential assignment")
        }
    }

    function Test-DbM30LeakObject([string]$path, [object]$obj) {
        if ($null -eq $obj) { return }
        if ($obj -is [System.Collections.IDictionary]) {
            foreach ($k in $obj.Keys) {
                $v = $obj[$k]
                $name = if ($path) { "$path.$k" } else { [string]$k }
                if ($v -is [System.Collections.IDictionary] -or $v -is [PSCustomObject]) { Test-DbM30LeakObject $name $v }
                elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
                    foreach ($item in $v) { if ($item -is [System.Collections.IDictionary] -or $item -is [PSCustomObject]) { Test-DbM30LeakObject $name $item } else { Test-DbM30LeakValue ([string]$k) $item } }
                }
                else { Test-DbM30LeakValue ([string]$k) $v }
            }
            return
        }
        if ($obj -is [PSCustomObject]) {
            foreach ($prop in $obj.PSObject.Properties) {
                $name = if ($path) { "$path.$($prop.Name)" } else { $prop.Name }
                $v = $prop.Value
                if ($v -is [System.Collections.IDictionary] -or $v -is [PSCustomObject]) { Test-DbM30LeakObject $name $v }
                elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
                    foreach ($item in $v) { if ($item -is [System.Collections.IDictionary] -or $item -is [PSCustomObject]) { Test-DbM30LeakObject $name $item } else { Test-DbM30LeakValue $prop.Name $item } }
                }
                else { Test-DbM30LeakValue $prop.Name $v }
            }
            return
        }
        Test-DbM30LeakValue 'value' $obj
    }

    Test-DbM30LeakObject '' $Target
    return @{ Leak = ($leaks.Count -gt 0); Fields = @($leaks) }
}

# --- backend markers ---

function Out-DbM30Markers {
    <#
    .SYNOPSIS
    Backend contract markers (DB-M28 pattern). The calling script ALWAYS exits 0;
    outcomes are communicated ONLY via stdout markers so a governed harness can
    read them without exit-code ambiguity.
    #>
    'DB30_OUTCOME: PASS'
    'DB30_RESULT_PASS'
    'DB30_WORKBOOK_MODIFIED: False'
    'DB30_NEXUS_SOURCE_MODIFIED: False'
    'DB30_GIT_MODIFIED: False'
    return $true
}
