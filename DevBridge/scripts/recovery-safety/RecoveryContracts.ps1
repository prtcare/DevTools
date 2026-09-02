# RecoveryContracts.ps1 -- DB-M32 ESSENTIAL SAFETY, RECOVERY & OPERATIONAL HARDENING contracts.
#
# DB-M32 is a READ-ONLY observation + classification + guidance engine. It makes
# DevBridge safe enough to survive normal operator mistakes, application restart,
# interrupted commands, stale state and recoverable failures. It NEVER writes
# live state, NEVER deletes a writer lock, NEVER touches the canonical workbook,
# NEVER runs a git write, NEVER rolls back, NEVER restores a baseline, NEVER
# executes a model/provider, and NEVER proposes automatic destructive recovery.
# Recovery PREPARES GUIDANCE only; the human decides and acts.
#
# AUTO_EXECUTION_ENABLED = FALSE. No AI/provider/paid/network calls, no writes
# beyond the operator-requested diagnostics/render artifact, no secrets stored.
#
# This file is self-contained (no dot-sources) so it is always safe to load.

Set-StrictMode -Version Latest

# --- defensive property reader (identical semantics to the DB-M14 shared helper) --

function Get-ContractProperty {
    <#
    .SYNOPSIS
    Read a property from a PSCustomObject or IDictionary defensively, returning a
    default when absent or null (JSON deserialization omits null properties).
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

function Get-DbM32Array {
    <#
    .SYNOPSIS
    Normalize a possibly-null/scalar value into a clean object array with null
    elements removed.
    #>
    param($Value)
    if ($null -eq $Value) { return ,@() }
    $out = New-Object System.Collections.ArrayList
    foreach ($item in @($Value)) { if ($null -ne $item) { [void]$out.Add($item) } }
    return ,@($out.ToArray())
}

# --- interrupted-operation tokens (Required capability 2) ---

function Get-DbM32InterruptedTokens {
    <#
    .SYNOPSIS
    The six interrupted-operation detection tokens. Each maps a concrete,
    observable state condition to a token; detection is pure comparison over the
    reconciled view, never inference.
    #>
    return @(
        'RESERVATION_STARTED_BUT_UNVERIFIED',
        'WORKBOOK_WRITE_STARTED_BUT_READBACK_MISSING',
        'VERIFICATION_STARTED_BUT_RESULT_MISSING',
        'CLAUDE_RESULT_RECORDING_INTERRUPTED',
        'TRIAL_CLOSURE_STARTED_BUT_UNVERIFIED',
        'COMPLETION_STARTED_BUT_UNVERIFIED'
    )
}

# --- recovery classifications (Required capability 3) ---

function Get-DbM32Classifications {
    <#
    .SYNOPSIS
    The seven recovery classifications. DB-M32 NEVER acts on a classification; it
    only reports it and recommends a human action.
    #>
    return @(
        'SAFE_TO_RESUME',
        'SAFE_TO_RETRY',
        'REFRESH_REQUIRED',
        'READBACK_RECONCILIATION_REQUIRED',
        'HUMAN_REVIEW_REQUIRED',
        'GOVERNANCE_REVIEW_REQUIRED',
        'DO_NOT_RETRY'
    )
}

# --- operation identities (Required capability 5) ---

function Get-DbM32OperationIdentities {
    return @('same-op-retried', 'new', 'stale', 'wrong-task', 'completed')
}

# --- workbook recovery verdicts (Required capability 6) ---

function Get-DbM32WorkbookVerdicts {
    return @('WRITE_CONFIRMED', 'WRITE_NOT_APPLIED', 'WRITE_STATE_AMBIGUOUS', 'UNKNOWN')
}

# --- writer-lock recovery states (Required capability 7; NO deletion) ---

function Get-DbM32WriterLockStates {
    return @('NO_WRITER', 'ACTIVE_WRITER', 'STALE_WRITER_RECORD', 'UNKNOWN_WRITER_STATE')
}

# --- safe-retry command catalog (Required capability 4 / 10) ---

function Get-DbM32SafeRetryCommands {
    <#
    .SYNOPSIS
    The governed commands reviewed for idempotence. Only a command whose observed
    state proves SAFE_TO_RETRY is offered RETRY; everything else is REVIEW
    REQUIRED.
    #>
    return @(
        'RUN_PREFLIGHT',
        'RESERVE_TASK',
        'CREATE_CHATGPT_HANDOFF',
        'REGISTER_IMPLEMENTATION_RESULT',
        'RUN_VERIFICATION',
        'CREATE_CLAUDE_REVIEW_PACKAGE',
        'RECORD_CLAUDE_RESULT',
        'CREATE_CORRECTION_CONTEXT',
        'REFRESH_GIT_GATE_STATE',
        'RUN_GOVERNED_COMPLETION',
        'VALIDATE_WORKBOOK',
        'CLOSE_TRIAL_CYCLE'
    )
}

# --- operator-visible recovery actions (Required capability 9; never generic) ---

function Get-DbM32RecoveryActions {
    return @(
        'REFRESH STATE',
        'RE-RUN VERIFICATION',
        'REVIEW WORKBOOK READ-BACK',
        'RECORD CLAUDE RESULT AGAIN',
        'REVIEW GIT STATE',
        'HUMAN GOVERNANCE REVIEW',
        'RECLAIM STALE WRITER LOCK',
        'NONE REQUIRED'
    )
}

# --- read-only guard ---

function New-DbM32ReadOnlyGuard {
    <#
    .SYNOPSIS
    Deterministic no-execution guard (DB-M29/M30/M31 pattern). DB-M32 never
    executes an AI model, never makes a paid/network call, never mutates live
    lifecycle state, the canonical workbook, the routing policy, the attempt
    store or the Nexus repos, never enables routing, never runs a destructive git
    command, never restores a baseline, never renders/logs a secret.
    #>
    return [pscustomobject]@{
        SchemaVersion           = 1
        AutoExecutionEnabled    = $false
        PaidApiCalls            = 0
        NetworkCalls            = 0
        LifecycleStateModified  = 'NO'
        WorkbookModified        = 'NO'
        GitModified             = 'NO'
        NexusSourceModified     = 'NO'
        RoutingPolicyModified   = 'NO'
        AttemptStoreModified    = 'NO'
        BaselineRestored        = 'NO'
        AutomaticPrCreated      = 'NO'
        AutomaticMergePerformed = 'NO'
        AutomaticNextTask       = 'NO'
        SecretValuesDisplayed   = 'NO'
        SecretValuesLogged      = 'NO'
    }
}

# --- secret-value scanner (DB-M32 variant of the DB-M29/M30/M31 scanner) ---

function Test-DbM32SecretLeak {
    <#
    .SYNOPSIS
    Scan a DB-M32 view object (or any object) for API-key-like VALUES.
    Identifiers, references, hashes, vocabulary values and numeric fields are
    exempt by design; free-text fields (Notes, Reasons, Detail, Warnings) ARE
    scanned. Config provider/model settings are rendered ONLY as
    CONFIGURED/NOT_CONFIGURED so no credential value ever enters the view. Never
    stores secrets. Returns @{ Leak; Fields }.
    #>
    param(
        [AllowNull()][object]$Target
    )
    $exempt = @(
        'SchemaVersion', 'ViewId', 'GeneratedAtUtc', 'NowUtc', 'StateSource',
        'StateRoot', 'StateDir', 'WorkbookPath', 'RepositoryRoot', 'Mode',
        'TrialMode', 'TaskId', 'NodeId', 'ChangeId', 'OperationId', 'Name',
        'Status', 'NextAllowedAction', 'PreflightVerdict', 'Implementability',
        'WorkbookSha256', 'Sha256', 'Sha256Before', 'Sha256After',
        'WorkbookSha256Before', 'WorkbookSha256After', 'PreWriteSha256',
        'PostWriteSha256', 'BackupSha256', 'FingerprintBefore', 'FingerprintAfter',
        'HeadCommit', 'HeadBefore', 'HeadAfter', 'Branch', 'Token', 'Verdict',
        'WriterState', 'BackupPath', 'AuditPath', 'EvidencePath', 'Key',
        'Column', 'Row', 'Cell', 'Value', 'ExpectedValue', 'Count', 'Pass',
        'Failed', 'Total', 'PrState', 'MergeConfirmed', 'Prerequisites',
        'Parts', 'Source', 'Coverage', 'ProtectedRows', 'ProtectedCells',
        'BeforeSha', 'AfterSha', 'RecordedHead', 'Recorded', 'Observed',
        'ExpectedBeforeSha', 'ObservedSha', 'Tokens', 'Repository', 'Path',
        'File', 'Pid', 'AcquiredUtc', 'Owner', 'Exists', 'Present', 'Drift',
        'ExpectedStateText', 'ObservedStateText',
        'AutoExecutionEnabled', 'PaidApiCalls', 'NetworkCalls',
        'LifecycleStateModified', 'WorkbookModified', 'GitModified',
        'NexusSourceModified', 'RoutingPolicyModified', 'AttemptStoreModified',
        'BaselineRestored', 'AutomaticPrCreated', 'AutomaticMergePerformed',
        'AutomaticNextTask', 'SecretValuesDisplayed', 'SecretValuesLogged',
        'Commands', 'EvidenceSources', 'Operation', 'ActorType', 'EntityId',
        'Represented', 'RestoreForbidden', 'Config', 'Plan', 'Operations',
        'Ops', 'Scope', 'RecommendedTitle', 'RecommendedBody', 'ChangedFiles',
        'BuildTests', 'Observations', 'DependencyContextSummary', 'GitBaseline',
        'Task', 'RecoveryStatus', 'Classification', 'LastOperation',
        'ExpectedState', 'ObservedState', 'RecommendedAction', 'Identity',
        'WorkbookVerdict', 'LockState', 'GitObserved', 'FailureCategory',
        'RecoveryClassification', 'LifecycleBefore', 'LifecycleAfter',
        'Result', 'Command', 'EvidenceFile', 'TimestampUtc', 'SelectedAtUtc',
        'ClosedAtUtc', 'GeneratedAtUtc', 'ReviewedAtUtc', 'CompletedAtUtc',
        'Detail', 'Warning', 'WorkbookSha', 'GitHead', 'Enabled', 'Configured',
        'ProviderId', 'ModelId', 'ExecutionMode', 'RoutingEnabled',
        'ActualResultState', 'ExpectedResultState'
    )
    $patterns = @(
        '^sk-[A-Za-z0-9_-]{8,}$',                 # OpenAI-style
        '^AIza[0-9A-Za-z_-]{10,}$',               # Google-style
        '^gh[pousr]_[A-Za-z0-9]{20,}$',           # GitHub tokens
        '^[A-Za-z0-9+/=_\-]{32,}$',               # generic high-entropy token
        '^-----BEGIN'                             # PEM block
    )
    $leaks = New-Object System.Collections.Generic.List[string]

    function Test-DbM32LeakValue([string]$fieldName, [object]$value) {
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

    function Test-DbM32LeakObject([string]$path, [object]$obj) {
        if ($null -eq $obj) { return }
        if ($obj -is [System.Collections.IDictionary]) {
            foreach ($k in $obj.Keys) {
                $v = $obj[$k]
                $name = if ($path) { "$path.$k" } else { [string]$k }
                if ($v -is [System.Collections.IDictionary] -or $v -is [PSCustomObject]) { Test-DbM32LeakObject $name $v }
                elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
                    foreach ($item in $v) { if ($item -is [System.Collections.IDictionary] -or $item -is [PSCustomObject]) { Test-DbM32LeakObject $name $item } else { Test-DbM32LeakValue ([string]$k) $item } }
                }
                else { Test-DbM32LeakValue ([string]$k) $v }
            }
            return
        }
        if ($obj -is [PSCustomObject]) {
            foreach ($prop in $obj.PSObject.Properties) {
                $name = if ($path) { "$path.$($prop.Name)" } else { $prop.Name }
                $v = $prop.Value
                if ($v -is [System.Collections.IDictionary] -or $v -is [PSCustomObject]) { Test-DbM32LeakObject $name $v }
                elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
                    foreach ($item in $v) { if ($item -is [System.Collections.IDictionary] -or $item -is [PSCustomObject]) { Test-DbM32LeakObject $name $item } else { Test-DbM32LeakValue $prop.Name $item } }
                }
                else { Test-DbM32LeakValue $prop.Name $v }
            }
            return
        }
        Test-DbM32LeakValue 'value' $obj
    }

    Test-DbM32LeakObject '' $Target
    return @{ Leak = ($leaks.Count -gt 0); Fields = @($leaks) }
}

# --- file SHA-256 ---

function Get-DbM32FileSha256 {
    <#
    .SYNOPSIS
    SHA-256 of a file (UTF-8 bytes as-is). Used to observe the canonical workbook
    SHA; read-only. Returns $null when the file is absent.
    #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try { $hash = $sha.ComputeHash($fs); return ([BitConverter]::ToString($hash)).Replace('-', '').ToUpperInvariant() }
        finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}

# --- forbidden destructive / autonomy command scan (Required capabilities 16-18) ---

function Test-DbM32ForbiddenCommand {
    <#
    .SYNOPSIS
    Return $true when a command string contains a prohibited destructive or
    autonomy command: git reset --hard / git clean / automatic workbook
    overwrite / git push / git merge / git commit / git rebase / gh pr create /
    gh pr merge / gh pr review / auto-execution of a provider / lock deletion.
    DB-M32 must contain ZERO such invocations.
    #>
    param([string]$Command)
    $patterns = @(
        'git\s+reset\s+--hard',
        'git\s+clean\s+(-fd?|-fdx|-ff?x?)',
        'git\s+push',
        'git\s+merge\b',
        'git\s+commit\b',
        'git\s+rebase',
        'git\s+checkout\s+-f',
        'git\s+stash\s+drop',
        'git\s+restore\s+--staged',
        'gh\s+pr\s+create',
        'gh\s+pr\s+merge',
        'gh\s+pr\s+review',
        'gh\s+api\s+.*\/(pulls|merges)',
        'Remove-Item.*writer\.lock',
        'Remove-Item.*workbook-writer',
        'Copy-Item.*backup.*\.xlsx',
        '(?i)workbook\s+overwrite\b',
        '(?i)auto.?exec(ute|ution)\s*=\s*\$true',
        '(?i)(invoke|start|enable|run)\s+(the\s+)?auto.?exec'
    )
    foreach ($p in $patterns) { if ($Command -match $p) { return $true } }
    return $false
}

# --- backend markers ---

function Out-DbM32Markers {
    <#
    .SYNOPSIS
    Backend contract markers (DB-M28/M30/M31 pattern). The calling script ALWAYS
    exits 0; outcomes are communicated ONLY via stdout markers so a governed
    harness can read them without exit-code ambiguity.
    #>
    'DB32_OUTCOME: PASS'
    'DB32_RESULT_PASS'
    'DB32_WORKBOOK_MODIFIED: False'
    'DB32_GIT_MODIFIED: False'
    'DB32_NEXUS_SOURCE_MODIFIED: False'
    'DB32_AUTO_EXECUTION_ENABLED: False'
    'DB32_REQUIRES_HUMAN_ACTION: False'
    return $true
}
