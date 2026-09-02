# WorkbookGitContracts.ps1 -- DB-M31 GOVERNED REAL-USE WORKBOOK & GIT SUPPORT contracts.
#
# DB-M31 hardens and unifies the governed workbook-write chain and Git lifecycle
# observation so DevBridge can later be used safely in a REAL Nexus cycle while
# keeping absolute roadmap immutability and zero autonomy expansion. It is a
# READ-ONLY, deterministic, supervised guide engine: it NEVER advances the
# lifecycle, NEVER writes the live canonical workbook (the write chain is proven
# exclusively on fixture workbook copies), NEVER executes a model/provider,
# NEVER creates/reviews/merges a PR automatically, NEVER restores a baseline,
# and NEVER runs a destructive git command.
#
# AUTO_EXECUTION_ENABLED = FALSE. No AI/provider/paid/network calls, no writes
# beyond the operator-requested artifact and DB-M31's own evidence under the
# fixture root, no secrets stored.
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

function Get-DbM31Array {
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

# --- writer states (Capability 4 / 17) ---

function Get-DbM31WriterStates {
    <#
    .SYNOPSIS
    The governed workbook writer state vocabulary. IDLE/READY = no writer active;
    WRITING = a writer holds the serialization lock; BUSY = the lock is held by
    another operation; FAILED = a writer step failed and the write was treated as
    failed; STALE = the workbook changed between read and write; DONE = verified.
    #>
    return @('IDLE', 'READY', 'WRITING', 'BUSY', 'FAILED', 'STALE', 'DONE')
}

# --- failure / recovery vocabulary (Capability 17; no silent recovery) ---

function Get-DbM31FailureStates {
    <#
    .SYNOPSIS
    The explicit failure/recovery vocabulary. Every governed operation surfaces
    exactly one of these when it cannot proceed. No code path silently retries,
    silently overwrites, or infers a remote/merge state.
    #>
    return @(
        'WORKBOOK_WRITER_BUSY',
        'STALE_GOVERNANCE_STATE',
        'BACKEND_STATE_MISMATCH',
        'WORKBOOK_READBACK_FAILED',
        'BACKUP_CREATION_FAILED',
        'PROTECTED_ROADMAP_MISMATCH',
        'GIT_STATE_UNKNOWN',
        'PR_STATE_UNKNOWN',
        'MERGE_STATE_UNKNOWN',
        'HUMAN_GIT_ACTION_REQUIRED'
    )
}

# --- human Git gate tokens (Capability 8; reuses the DevBridge GitLifecycle
# --- vocabulary: AWAITING_HUMAN_PR / PR_OPEN / AWAITING_HUMAN_REVIEW /
# --- AWAITING_HUMAN_MERGE / MERGED / READY_FOR_GOVERNED_COMPLETION) ---

function Get-DbM31GitGateTokens {
    return @(
        'AWAITING_HUMAN_PR', 'PR_OPEN', 'AWAITING_HUMAN_REVIEW',
        'AWAITING_HUMAN_MERGE', 'MERGED', 'READY_FOR_GOVERNED_COMPLETION'
    )
}

function Get-DbM31MergeConfirmedStates {
    <#
    .SYNOPSIS
    The ONLY states that count as positive human merge evidence (Capability 9).
    A merge is NEVER inferred from a clean working tree, a branch change, a
    commit existence, or a PR closure alone.
    #>
    return @('MERGED', 'READY_FOR_GOVERNED_COMPLETION')
}

# --- M10 eligibility tokens (Capability 12) ---

function Get-DbM31M10Tokens {
    <#
    .SYNOPSIS
    M10 completion eligibility tokens. TRIAL always short-circuits to
    TRIAL_COMPLETION_NOT_APPLICABLE first. Each REAL prerequisite has its own
    BLOCK token; none may be weakened.
    #>
    return @(
        'TRIAL_COMPLETION_NOT_APPLICABLE',
        'READY_FOR_GOVERNED_COMPLETION',
        'BLOCKED_NOT_REAL_MODE',
        'BLOCKED_NO_DB_M06_VERIFICATION_PASS',
        'BLOCKED_NO_CLAUDE_PASS',
        'BLOCKED_GOVERNANCE_ISSUE',
        'BLOCKED_SCOPE_NOT_APPROVED',
        'BLOCKED_HUMAN_GIT_MERGE_GATE_PENDING',
        'MERGE_STATE_UNKNOWN',
        'BLOCKED_STALE_STATE',
        'ROADMAP_STRUCTURE_WRITE_PROHIBITED',
        'BLOCKED_INELIGIBLE_LIFECYCLE_STATE'
    )
}

# --- trial flow tokens (Capability 10; DB-M12.4) ---

function Get-DbM31TrialFlowTokens {
    return @(
        'TRIAL_CYCLE_SAFE_STOP',
        'CLOSE_TRIAL_CYCLE',
        'TRIAL_CYCLE_CLOSED',
        'TRIAL_COMPLETION_NOT_APPLICABLE'
    )
}

# --- M11 validation tokens (Capability 13) ---

function Get-DbM31M11Tokens {
    return @(
        'M11_VALIDATION_PASS',
        'M11_VALIDATION_FAILED',
        'M11_NOT_APPLICABLE'
    )
}

# --- read-only guard ---

function New-DbM31ReadOnlyGuard {
    <#
    .SYNOPSIS
    Deterministic no-execution guard (DB-M29/M30 pattern). DB-M31 never executes
    an AI model, never makes a paid/network call, never mutates the live
    lifecycle state, the canonical workbook, the routing policy, the attempt
    store or the Nexus repos, never enables routing, never runs a destructive
    git command, never renders/logs a secret.
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

# --- secret-value scanner (DB-M31 variant of the DB-M29/M30 scanner) ---

function Test-DbM31SecretLeak {
    <#
    .SYNOPSIS
    Scan a DB-M31 view object (or any object) for API-key-like VALUES.
    Identifiers, references, hashes, vocabulary values and numeric fields are
    exempt by design; free-text fields (Notes, Reasons, Explanations,
    RecommendedTitle, RecommendedBody, HumanAction, Detail) ARE scanned. Never
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
        'Failed', 'Total', 'DirectDependencyCount', 'DeliveredSummaryCount',
        'EstimatedCost', 'Currency', 'CardStatus', 'Available', 'PrState',
        'MergeConfirmed', 'Prerequisites', 'Parts', 'Source', 'Coverage',
        'ProtectedRows', 'ProtectedCells', 'AutoExecutionEnabled', 'PaidApiCalls',
        'NetworkCalls', 'LifecycleStateModified', 'WorkbookModified',
        'GitModified', 'NexusSourceModified', 'RoutingPolicyModified',
        'AttemptStoreModified', 'BaselineRestored', 'AutomaticPrCreated',
        'AutomaticMergePerformed', 'AutomaticNextTask', 'SecretValuesDisplayed',
        'SecretValuesLogged', 'Commands', 'EvidenceSources', 'Operation',
        'ActorType', 'EntityId', 'Represented', 'RestoreForbidden', 'Config',
        'Plan', 'Operations', 'Ops', 'Scope', 'RecommendedTitle',
        'RecommendedBody', 'ChangedFiles', 'BuildTests', 'M06Result',
        'ClaudeReviewResult', 'Observations', 'DependencyContextSummary',
        'GitBaseline', 'ChangeId', 'Task'
    )
    $patterns = @(
        '^sk-[A-Za-z0-9_-]{8,}$',                 # OpenAI-style
        '^AIza[0-9A-Za-z_-]{10,}$',               # Google-style
        '^gh[pousr]_[A-Za-z0-9]{20,}$',           # GitHub tokens
        '^[A-Za-z0-9+/=_\-]{32,}$',               # generic high-entropy token
        '^-----BEGIN'                             # PEM block
    )
    $leaks = New-Object System.Collections.Generic.List[string]

    function Test-DbM31LeakValue([string]$fieldName, [object]$value) {
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

    function Test-DbM31LeakObject([string]$path, [object]$obj) {
        if ($null -eq $obj) { return }
        if ($obj -is [System.Collections.IDictionary]) {
            foreach ($k in $obj.Keys) {
                $v = $obj[$k]
                $name = if ($path) { "$path.$k" } else { [string]$k }
                if ($v -is [System.Collections.IDictionary] -or $v -is [PSCustomObject]) { Test-DbM31LeakObject $name $v }
                elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
                    foreach ($item in $v) { if ($item -is [System.Collections.IDictionary] -or $item -is [PSCustomObject]) { Test-DbM31LeakObject $name $item } else { Test-DbM31LeakValue ([string]$k) $item } }
                }
                else { Test-DbM31LeakValue ([string]$k) $v }
            }
            return
        }
        if ($obj -is [PSCustomObject]) {
            foreach ($prop in $obj.PSObject.Properties) {
                $name = if ($path) { "$path.$($prop.Name)" } else { $prop.Name }
                $v = $prop.Value
                if ($v -is [System.Collections.IDictionary] -or $v -is [PSCustomObject]) { Test-DbM31LeakObject $name $v }
                elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
                    foreach ($item in $v) { if ($item -is [System.Collections.IDictionary] -or $item -is [PSCustomObject]) { Test-DbM31LeakObject $name $item } else { Test-DbM31LeakValue $prop.Name $item } }
                }
                else { Test-DbM31LeakValue $prop.Name $v }
            }
            return
        }
        Test-DbM31LeakValue 'value' $obj
    }

    Test-DbM31LeakObject '' $Target
    return @{ Leak = ($leaks.Count -gt 0); Fields = @($leaks) }
}

# --- file SHA-256 ---

function Get-DbM31FileSha256 {
    <#
    .SYNOPSIS
    SHA-256 of a file (UTF-8 bytes as-is). Used for the pre/post-write workbook
    hashes and backup verification (Capability 6).
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

# --- forbidden destructive / autonomy command scan (Capabilities 19, 20, 44-48) ---

function Test-DbM31ForbiddenCommand {
    <#
    .SYNOPSIS
    Return $true when a command string contains a prohibited destructive or
    autonomy command: git reset --hard / git clean / automatic workbook
    overwrite / git push / git merge / git commit / git rebase / gh pr create /
    gh pr merge / gh pr review / auto-execution of a provider. DB-M31 must
    contain ZERO such invocations.
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
        'gh\s+pr\s+create',
        'gh\s+pr\s+merge',
        'gh\s+pr\s+review',
        'gh\s+api\s+.*\/(pulls|merges)',
        '(?i)workbook\s+overwrite\b',
        '(?i)auto.?exec(ute|ution)'
    )
    foreach ($p in $patterns) { if ($Command -match $p) { return $true } }
    return $false
}

# --- backend markers ---

function Out-DbM31Markers {
    <#
    .SYNOPSIS
    Backend contract markers (DB-M28/M30 pattern). The calling script ALWAYS
    exits 0; outcomes are communicated ONLY via stdout markers so a governed
    harness can read them without exit-code ambiguity.
    #>
    'DB31_OUTCOME: PASS'
    'DB31_RESULT_PASS'
    'DB31_WORKBOOK_MODIFIED: False'
    'DB31_GIT_MODIFIED: False'
    'DB31_NEXUS_SOURCE_MODIFIED: False'
    'DB31_AUTO_EXECUTION_ENABLED: False'
    'DB31_REQUIRES_HUMAN_ACTION: False'
    return $true
}
