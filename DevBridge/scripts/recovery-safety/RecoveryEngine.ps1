# RecoveryEngine.ps1 -- DB-M32 observation + classification engine (READ-ONLY).
#
# Stage 1 RECONCILE: build the observed system picture from state/*.json, the
# writer lock, the canonical workbook SHA and read-only git.
# Stage 2 DETECT:    six interrupted-operation rules over observed state.
# Stage 3 CLASSIFY:  seven recovery classifications per lane condition.
# Stage 4 GUIDE:     operator recovery panel (status / last op / expected /
#                    observed / classification / recommended human action).
# Stage 5 REPORT:    diagnostics + DB32_* markers.
#
# DB-M32 writes NOTHING to live state. Its only writes are the caller-supplied
# render/diagnostics paths and the suite's own state/tasks outputs.

Set-StrictMode -Version Latest

# --- JSON reader (defensive; corrupt JSON -> $null, never throws) ---

function Read-DbM32Json {
    <#
    .SYNOPSIS
    Read a JSON file defensively. Returns $null for missing, empty, or corrupt
    JSON so an interrupted write never throws the engine.
    #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

# --- path walker for nested JSON fields ---

function Get-DbM32Nested {
    <#
    .SYNOPSIS
    Walk a dotted path over an object (e.g. 'workbook.sha256After'). Returns
    $null for any missing node.
    #>
    param([AllowNull()][object]$Object, [string]$Path)
    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Path)) { return $null }
    $current = $Object
    foreach ($seg in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.ContainsKey($seg)) { return $null }
            $current = $current[$seg]
        } else {
            $prop = $current.PSObject.Properties[$seg]
            if ($null -eq $prop -or $null -eq $prop.Value) { return $null }
            $current = $prop.Value
        }
    }
    return $current
}

# --- config (defaults + canonical workbook path) ---

function Get-DbM32Config {
    <#
    .SYNOPSIS
    DB-M32 config. The workbook path defaults from config/devbridge.json when
    present, else the known canonical path. READ-ONLY.
    #>
    param([string]$Root)
    $cfg = Read-DbM32Json -Path (Join-Path $Root 'config\devbridge.json')
    $workbook = 'C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx'
    if ($null -ne $cfg) {
        $wb = Get-ContractProperty $cfg 'developmentControlWorkbook' $null
        if ($wb) { $workbook = $wb }
    }
    return [pscustomobject]@{
        Root = $Root
        StateDir = (Join-Path $Root 'state')
        LogsDir = (Join-Path $Root 'logs')
        WorkbookPath = $workbook
        RepositoryRoot = 'C:\Personal\Nexus.Developer'
        LockPath = (Join-Path $Root 'logs\workbook-writer.lock')
    }
}

# --- read-only git invocation ---

function Invoke-DbM32Git {
    <#
    .SYNOPSIS
    Run a read-only git command in the repository. Returns @{ Output; ExitCode;
    Failed }. Only observe commands are ever issued by DB-M32.
    #>
    param([string]$RepositoryPath, [string[]]$Arguments)
    $result = @{ Output = ''; ExitCode = 0; Failed = $false }
    if (-not (Test-Path -LiteralPath $RepositoryPath -PathType Container)) {
        $result.ExitCode = 1; $result.Failed = $true; return $result
    }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'git'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.Arguments = ('-C "{0}" {1}' -f $RepositoryPath, (($Arguments | ForEach-Object { '"' + $_.Replace('"','\"') + '"' }) -join ' '))
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        if (-not $proc.Start()) { $result.Failed = $true; return $result }
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $result.Output = $stdout.Trim()
        $result.ExitCode = $proc.ExitCode
        $result.Failed = ($proc.ExitCode -ne 0)
        if ($stderr) { $result.Stderr = $stderr.Trim() }
        return $result
    } catch {
        $result.Failed = $true; return $result
    }
}

# --- git observation (stage 1; read-only, remote never inferred) ---

function Get-DbM32GitObservation {
    <#
    .SYNOPSIS
    Observe branch, HEAD and working-tree cleanliness via read-only git. PR
    state is ALWAYS UNKNOWN (remote state is never inferred).
    #>
    param([string]$RepositoryPath)
    $branch = Invoke-DbM32Git -RepositoryPath $RepositoryPath -Arguments @('rev-parse','--abbrev-ref','HEAD')
    $head = Invoke-DbM32Git -RepositoryPath $RepositoryPath -Arguments @('rev-parse','HEAD')
    $status = Invoke-DbM32Git -RepositoryPath $RepositoryPath -Arguments @('status','--porcelain')
    $warnings = New-Object System.Collections.ArrayList
    if ($branch.Failed -or $head.Failed) {
        [void]$warnings.Add('git observation unavailable; branch/HEAD unknown (read-only git failed or repository absent).')
    }
    $clean = $null
    if (-not $status.Failed) { $clean = ([string]::IsNullOrWhiteSpace($status.Output)) }
    return [pscustomobject]@{
        Repository = $RepositoryPath
        Branch = if ($branch.Failed) { $null } else { $branch.Output }
        HeadCommit = if ($head.Failed) { $null } else { $head.Output }
        WorkTreeClean = $clean
        PrState = 'UNKNOWN'
        Warning = $warnings
    }
}

# --- writer lock observation (stage 1; NEVER deletes) ---

function Get-DbM32WriterLockState {
    <#
    .SYNOPSIS
    Observe logs\workbook-writer.lock. Reports NO_WRITER / ACTIVE_WRITER /
    STALE_WRITER_RECORD / UNKNOWN_WRITER_STATE. DB-M32 NEVER deletes a lock;
    STALE_WRITER_RECORD only triggers a human reclaim recommendation.
    #>
    param([string]$LockPath)
    $state = [pscustomobject]@{ Path = $LockPath; Exists = $false; Pid = $null; AcquiredUtc = $null; Owner = $null; State = 'NO_WRITER' }
    if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) { return $state }
    $state.Exists = $true
    $pidValue = $null; $acquired = $null; $owner = $null
    try {
        $lines = [System.IO.File]::ReadAllLines($LockPath)
        foreach ($line in $lines) {
            if ($line -match '^pid=(\d+)') { $pidValue = [int]$Matches[1] }
            elseif ($line -match '^acquired=(.+)') { $acquired = $Matches[1] }
            elseif ($line -match '^owner=(.+)') { $owner = $Matches[1] }
        }
    } catch {
        $state.State = 'UNKNOWN_WRITER_STATE'
        return $state
    }
    $state.Pid = $pidValue; $state.AcquiredUtc = $acquired; $state.Owner = $owner
    if ($null -eq $pidValue -or $pidValue -le 0) {
        $state.State = 'UNKNOWN_WRITER_STATE'
        return $state
    }
    $alive = $false
    try {
        $p = Get-Process -Id $pidValue -ErrorAction Stop
        $alive = ($null -ne $p)
    } catch { $alive = $false }
    $state.State = if ($alive) { 'ACTIVE_WRITER' } else { 'STALE_WRITER_RECORD' }
    return $state
}

# --- evidence applies (DB-M31 EvidenceApplies semantics) ---

function Test-DbM32EvidenceApplies {
    <#
    .SYNOPSIS
    Evidence applies only when changeId is both empty or matching. Prior-cycle
    evidence with a changeId never applies to a task without one.
    #>
    param([string]$EvidenceChangeId, [string]$TaskChangeId)
    $ec = [string]$EvidenceChangeId; $tc = [string]$TaskChangeId
    if ([string]::IsNullOrWhiteSpace($ec) -and [string]::IsNullOrWhiteSpace($tc)) { return $true }
    if (-not [string]::IsNullOrWhiteSpace($ec) -and -not [string]::IsNullOrWhiteSpace($tc)) { return ($ec -eq $tc) }
    return $false
}

# --- evidence specs (file -> command -> extracted fields) ---

function Get-DbM32EvidenceSpecs {
    return @(
        @{ File='preflight.json'; Command='RUN_PREFLIGHT'; Timestamp=@('selectedAt','generatedAtUtc'); Claimed='status'; BeforeSha='workbookSha256'; AfterSha=$null; Head=$null }
        @{ File='reservation.json'; Command='RESERVE_TASK'; Timestamp=@('generatedAtUtc'); Claimed=$null; BeforeSha='workbook.sha256Before'; AfterSha='workbook.sha256After'; Head='gitBaseline.headCommit' }
        @{ File='verification.json'; Command='RUN_VERIFICATION'; Timestamp=@('generatedAtUtc'); Claimed='stateTransition.status'; BeforeSha='parts.part10.sha256Before'; AfterSha='parts.part10.sha256After'; Head='parts.part2.currentHead' }
        @{ File='claude-review.json'; Command='RECORD_CLAUDE_RESULT'; Timestamp=@('generatedAtUtc'); Claimed=$null; BeforeSha=$null; AfterSha=$null; Head=$null }
        @{ File='completion.json'; Command='RUN_GOVERNED_COMPLETION'; Timestamp=@('completedAtUtc','generatedAtUtc'); Claimed='status'; BeforeSha='workbookSha256Before'; AfterSha='workbookSha256After'; Head='sourceGitEvidence.headCommit' }
        @{ File='trial-closure.json'; Command='CLOSE_TRIAL_CYCLE'; Timestamp=@('closedAtUtc','generatedAtUtc'); Claimed='result'; BeforeSha='preWriteBackupSha256'; AfterSha='postWorkbookSha256'; Head=$null }
        @{ File='git-gate-state.json'; Command='REFRESH_GIT_GATE_STATE'; Timestamp=@('generatedAtUtc'); Claimed=$null; BeforeSha=$null; AfterSha=$null; Head='headCommit' }
        @{ File='current-lifecycle-state.json'; Command='GET_CURRENT_LIFECYCLE_STATE'; Timestamp=@('generatedAtUtc'); Claimed=$null; BeforeSha=$null; AfterSha=$null; Head=$null }
    )
}

# --- claimed / expected end-state vocabulary per command ---

function Get-DbM32ExpectedStateText {
    <#
    .SYNOPSIS
    Human-readable EXPECTED STATE text for the operator panel, per command.
    #>
    param([string]$Command)
    switch ($Command) {
        'RUN_PREFLIGHT'               { return 'current-task.status = PREFLIGHTED with a preflight verdict recorded' }
        'RESERVE_TASK'                { return 'current-task.status = RESERVED and reservation.json present' }
        'CREATE_CHATGPT_HANDOFF'      { return 'handoff document written and current-task.status advanced to AWAITING' }
        'REGISTER_IMPLEMENTATION_RESULT' { return 'implementation result registered on the current task' }
        'RUN_VERIFICATION'            { return 'verification.json present and current-task.status = VERIFIED' }
        'CREATE_CLAUDE_REVIEW_PACKAGE' { return 'Claude review package artifact present and dbM07 evidence recorded' }
        'RECORD_CLAUDE_RESULT'        { return 'claude-review.json present and current-task.status = CLAUDE_REVIEW' }
        'CREATE_CORRECTION_CONTEXT'   { return 'correction context present and dbM09 evidence recorded' }
        'REFRESH_GIT_GATE_STATE'      { return 'git-gate-state.json refreshed with observed branch/HEAD/PR' }
        'RUN_GOVERNED_COMPLETION'     { return 'completion.json present and current-task.status = COMPLETION_WRITTEN' }
        'VALIDATE_WORKBOOK'           { return 'workbook-consistency.json present' }
        'CLOSE_TRIAL_CYCLE'           { return 'trial-closure.json present and current-task.status = TRIAL_CYCLE_CLOSED' }
        default                       { return 'no recovery-relevant state transition defined' }
    }
}

# --- evidence summaries (extract ONLY the fields the engine needs; raw content
# --- is never embedded in the view so no secret-bearing text can leak) ---

function Get-DbM32EvidenceSummaries {
    <#
    .SYNOPSIS
    Build lightweight summaries for each evidence file. Each summary carries
    ChangeId, timestamp, claimed end state, before/after workbook SHA, recorded
    git head, and whether it applies to the current task.
    #>
    param([string]$StateDir, [string]$TaskChangeId)
    $out = New-Object System.Collections.ArrayList
    foreach ($spec in @(Get-DbM32EvidenceSpecs)) {
        $path = Join-Path $StateDir $spec.File
        $content = Read-DbM32Json -Path $path
        if ($null -eq $content) { continue }
        $changeId = [string](Get-ContractProperty $content 'changeId' '')
        $timestamp = $null
        foreach ($tf in @($spec.Timestamp)) {
            $v = Get-ContractProperty $content $tf $null
            if ($v) { $timestamp = [string]$v; break }
        }
        $claimed = $null
        if ($spec.Claimed) { $claimed = [string](Get-DbM32Nested $content $spec.Claimed) }
        $before = $null
        if ($spec.BeforeSha) { $before = [string](Get-DbM32Nested $content $spec.BeforeSha) }
        $after = $null
        if ($spec.AfterSha) { $after = [string](Get-DbM32Nested $content $spec.AfterSha) }
        $head = $null
        if ($spec.Head) { $head = [string](Get-DbM32Nested $content $spec.Head) }
        [void]$out.Add([pscustomobject]@{
            File = $spec.File
            Command = $spec.Command
            ChangeId = $changeId
            TimestampUtc = $timestamp
            ClaimedEndState = $claimed
            BeforeSha = $before
            AfterSha = $after
            RecordedHead = $head
            Applies = (Test-DbM32EvidenceApplies -EvidenceChangeId $changeId -TaskChangeId $TaskChangeId)
        })
    }
    return ,@($out.ToArray())
}

# --- last operation (stage 1): the most recent evidence record by timestamp ---

function Get-DbM32LastOperation {
    <#
    .SYNOPSIS
    Derive LAST OPERATION from the most recent evidence timestamp. An explicit
    -LastOperation override wins (fixtures direct the panel).
    #>
    param(
        [AllowNull()][object[]]$Evidence,
        [string]$Override
    )
    $chosen = $null
    if ($Override) {
        foreach ($e in @($Evidence)) { if ($e.Command -eq $Override) { $chosen = $e; break } }
    } else {
        $latest = $null
        foreach ($e in @($Evidence)) {
            if (-not $e.TimestampUtc) { continue }
            if ($null -eq $latest) { $latest = $e; continue }
            try {
                if ([datetime]$e.TimestampUtc -gt [datetime]$latest.TimestampUtc) { $latest = $e }
            } catch {}
        }
        $chosen = $latest
    }
    if ($null -eq $chosen) { return $null }
    return [pscustomobject]@{
        Command = $chosen.Command
        TimestampUtc = $chosen.TimestampUtc
        Evidence = $chosen
    }
}

# --- six interrupted-operation detection rules (stage 2) ---

function Test-DbM32ReservationStartedButUnverified {
    <#
    .SYNOPSIS
    R1: reservation evidence present but the current task never left PREFLIGHTED.
    A reservation landed (durable) whose state tail was not recorded.
    #>
    param($View)
    $res = $View.Evidence | Where-Object { $_.Command -eq 'RESERVE_TASK' } | Select-Object -First 1
    if ($null -eq $res) { return $null }
    if (-not $res.Applies) { return $null }
    if ($View.Task.Status -ne 'PREFLIGHTED') { return $null }
    return 'RESERVATION_STARTED_BUT_UNVERIFIED'
}

function Test-DbM32WorkbookWriteStartedButReadbackMissing {
    <#
    .SYNOPSIS
    R2: an applicable pre-write SHA exists, the workbook SHA moved, and no
    applicable evidence records the current SHA as its after-write readback.
    #>
    param($View)
    $hasBefore = @($View.Evidence | Where-Object { $_.Applies -and $_.BeforeSha }).Count -gt 0
    if (-not $hasBefore) { return $null }
    $moved = $false
    foreach ($e in @($View.Evidence | Where-Object { $_.Applies })) {
        if ($e.BeforeSha -and $e.BeforeSha -ne $View.Workbook.Sha256) { $moved = $true }
    }
    if (-not $moved) { return $null }
    $readbackRecorded = $false
    foreach ($e in @($View.Evidence | Where-Object { $_.Applies })) {
        if ($e.AfterSha -and $e.AfterSha -eq $View.Workbook.Sha256) { $readbackRecorded = $true }
    }
    if ($readbackRecorded) { return $null }
    return 'WORKBOOK_WRITE_STARTED_BUT_READBACK_MISSING'
}

function Test-DbM32VerificationStartedButResultMissing {
    <#
    .SYNOPSIS
    R3: the task claims a verification transition but verification.json is absent.
    #>
    param($View)
    if ($View.Evidence | Where-Object { $_.Command -eq 'RUN_VERIFICATION' }) { return $null }
    if ($View.Task.Status -eq 'VERIFIED') { return 'VERIFICATION_STARTED_BUT_RESULT_MISSING' }
    return $null
}

function Test-DbM32ClaudeResultRecordingInterrupted {
    <#
    .SYNOPSIS
    R4: claude-review.json absent, no dbM08 evidence recorded, and a Claude
    review package artifact exists under the current task's logs/tasks tree.
    #>
    param($View, [string]$Root)
    if ($View.Evidence | Where-Object { $_.Command -eq 'RECORD_CLAUDE_RESULT' }) { return $null }
    if ($View.Task.DbM08Evidence) { return $null }
    $probe = Join-Path $Root ("logs\tasks\{0}" -f $View.Task.NodeId)
    $found = $false
    if (Test-Path -LiteralPath $probe -PathType Container) {
        foreach ($name in @('REVIEW_PACKET.md','CLAUDE_REVIEW_RESULT.md','REVIEW_PACKAGE.md')) {
            if (Test-Path -LiteralPath (Join-Path $probe $name) -PathType Leaf) { $found = $true }
        }
    }
    if (-not $found) { return $null }
    return 'CLAUDE_RESULT_RECORDING_INTERRUPTED'
}

function Test-DbM32TrialClosureStartedButUnverified {
    <#
    .SYNOPSIS
    R5: trial-closure evidence present and applies, but the current task never
    reached TRIAL_CYCLE_CLOSED.
    #>
    param($View)
    $tc = $View.Evidence | Where-Object { $_.Command -eq 'CLOSE_TRIAL_CYCLE' } | Select-Object -First 1
    if ($null -eq $tc) { return $null }
    if (-not $tc.Applies) { return $null }
    if ($View.Task.Status -eq 'TRIAL_CYCLE_CLOSED') { return $null }
    return 'TRIAL_CLOSURE_STARTED_BUT_UNVERIFIED'
}

function Test-DbM32CompletionStartedButUnverified {
    <#
    .SYNOPSIS
    R6: completion evidence present and applies, but the current task never
    reached COMPLETION_WRITTEN.
    #>
    param($View)
    $co = $View.Evidence | Where-Object { $_.Command -eq 'RUN_GOVERNED_COMPLETION' } | Select-Object -First 1
    if ($null -eq $co) { return $null }
    if (-not $co.Applies) { return $null }
    if ($View.Task.Status -eq 'COMPLETION_WRITTEN') { return $null }
    return 'COMPLETION_STARTED_BUT_UNVERIFIED'
}

function Get-DbM32DetectedTokens {
    <#
    .SYNOPSIS
    Run all six detection rules; return the fired token list (deterministic
    order, no inference).
    #>
    param($View, [string]$Root)
    $tokens = New-Object System.Collections.ArrayList
    foreach ($rule in @(
        (Test-DbM32ReservationStartedButUnverified -View $View),
        (Test-DbM32WorkbookWriteStartedButReadbackMissing -View $View),
        (Test-DbM32VerificationStartedButResultMissing -View $View),
        (Test-DbM32ClaudeResultRecordingInterrupted -View $View -Root $Root),
        (Test-DbM32TrialClosureStartedButUnverified -View $View),
        (Test-DbM32CompletionStartedButUnverified -View $View)
    )) {
        if ($rule) { [void]$tokens.Add($rule) }
    }
    return ,@($tokens.ToArray())
}

# --- workbook recovery verdict (stage 3) ---

function Get-DbM32WorkbookVerdict {
    <#
    .SYNOPSIS
    WRITE_CONFIRMED when the observed SHA is a recorded after-write SHA;
    WRITE_NOT_APPLIED when it matches a recorded pre-write SHA; WRITE_STATE_AMBIGUOUS
    when it matches neither; UNKNOWN when no workbook SHA could be observed.
    #>
    param([string]$ObservedSha, $View)
    if (-not $ObservedSha) { return 'UNKNOWN' }
    $applies = @($View.Evidence | Where-Object { $_.Applies })
    foreach ($e in $applies) { if ($e.AfterSha -and $e.AfterSha -eq $ObservedSha) { return 'WRITE_CONFIRMED' } }
    foreach ($e in $applies) { if ($e.BeforeSha -and $e.BeforeSha -eq $ObservedSha) { return 'WRITE_NOT_APPLIED' } }
    return 'WRITE_STATE_AMBIGUOUS'
}

# --- operation identity (stage 2/3) ---

function Get-DbM32OperationIdentity {
    <#
    .SYNOPSIS
    Classify the last operation: same-op-retried / new / stale / wrong-task /
    completed. 'completed' is reserved for terminal ops that reached their
    terminal state.
    #>
    param($View)
    $last = $View.LastOperation
    if ($null -eq $last) { return 'new' }
    $evidence = $last.Evidence
    if ($null -eq $evidence) {
        if ($View.Workbook.Verdict -eq 'WRITE_CONFIRMED') { return 'same-op-retried' }
        return 'new'
    }
    # A lifecycle snapshot is the current state, not an operation; no operation
    # has been recorded when it is the only (most recent) evidence.
    if ($evidence.Command -eq 'GET_CURRENT_LIFECYCLE_STATE') { return 'new' }
    if (-not $evidence.Applies) {
        if ($evidence.ChangeId -and $View.Task.ChangeId) { return 'wrong-task' }
        return 'stale'
    }
    $claimed = $evidence.ClaimedEndState
    $reached = ($claimed -and $View.Task.Status -eq $claimed)
    if ($reached -and $last.Command -in @('RUN_GOVERNED_COMPLETION','CLOSE_TRIAL_CYCLE')) { return 'completed' }
    if ($reached) { return 'same-op-retried' }
    $shaRef = $evidence.AfterSha; if (-not $shaRef) { $shaRef = $evidence.BeforeSha }
    if ($shaRef -and $View.Task.WorkbookSha256 -and $shaRef -ne $View.Task.WorkbookSha256) { return 'stale' }
    return 'same-op-retried'
}

# --- backend-state mismatch (stage 3; preserved, never hidden) ---

function Test-DbM32BackendStateMismatch {
    <#
    .SYNOPSIS
    When the last op's evidence claims a resulting state and the current task has
    NOT reached it (and the evidence applies), the backend claimed success but the
    expected transition is absent -> BACKEND_STATE_MISMATCH is preserved.
    #>
    param($View)
    $last = $View.LastOperation
    if ($null -eq $last -or $null -eq $last.Evidence) { return $null }
    $ev = $last.Evidence
    if (-not $ev.Applies) { return $null }
    $claimed = $ev.ClaimedEndState
    if (-not $claimed) { return $null }
    if ($View.Task.Status -eq $claimed) { return $null }
    return [pscustomobject]@{ Present = $true; Token = 'BACKEND_STATE_MISMATCH'; ExpectedResultState = $claimed; ActualResultState = $View.Task.Status }
}

# --- stale governance (stage 3; operator decides, no silent overwrite) ---

function Get-DbM32StaleGovernance {
    <#
    .SYNOPSIS
    When an applicable governance/preflight record expected a different workbook
    SHA than is now observed, STALE_GOVERNANCE_STATE is reported verbatim.
    #>
    param($View)
    foreach ($e in @($View.Evidence | Where-Object { $_.Applies })) {
        if ($e.BeforeSha -and $e.BeforeSha -ne $View.Workbook.Sha256) {
            return [pscustomobject]@{ Present = $true; Token = 'STALE_GOVERNANCE_STATE'; ExpectedBeforeSha = $e.BeforeSha; ObservedSha = $View.Workbook.Sha256; Source = $e.File }
        }
    }
    return [pscustomobject]@{ Present = $false; Token = $null; ExpectedBeforeSha = $null; ObservedSha = $View.Workbook.Sha256; Source = $null }
}

# --- git drift (stage 3; read-only comparison, remote never inferred) ---

function Get-DbM32GitDrift {
    <#
    .SYNOPSIS
    Compare the observed HEAD against the most recent applicable recorded HEAD.
    Returns @{ Drift; Recorded; Observed }.
    #>
    param($View)
    $recorded = $null
    $source = $null
    foreach ($e in @($View.Evidence | Where-Object { $_.Applies -and $_.RecordedHead })) {
        if (-not $recorded) { $recorded = $e.RecordedHead; $source = $e.File }
    }
    if (-not $recorded -or -not $View.Git.HeadCommit) {
        return [pscustomobject]@{ Drift = $false; Recorded = $recorded; Observed = $View.Git.HeadCommit; Source = $source }
    }
    return [pscustomobject]@{ Drift = ($recorded -ne $View.Git.HeadCommit); Recorded = $recorded; Observed = $View.Git.HeadCommit; Source = $source }
}

# --- recommended action per command for the safe-retry path ---

function Get-DbM32RetryAction {
    param([string]$Command)
    switch ($Command) {
        'RUN_VERIFICATION'        { return 'RE-RUN VERIFICATION' }
        'RECORD_CLAUDE_RESULT'    { return 'RECORD CLAUDE RESULT AGAIN' }
        'REFRESH_GIT_GATE_STATE'  { return 'REVIEW GIT STATE' }
        default                   { return 'REFRESH STATE' }
    }
}

# --- recovery classification (stage 3, precedence table) ---

function Get-DbM32RecoveryClassification {
    <#
    .SYNOPSIS
    Deterministic classification with a recommended human action and a specific
    detail string. Never a generic "something went wrong".
    #>
    param($View)
    $lock = $View.Lock.State
    $tokens = $View.Tokens
    $verdict = $View.Workbook.Verdict
    $identity = $View.Identity
    $mismatch = $View.BackendMismatch
    $stale = $View.StaleGovernance
    $drift = $View.GitDrift
    $catalog = @(Get-DbM32SafeRetryCommands)
    $inCatalog = $View.LastOperation -and ($View.LastOperation.Command -in $catalog)

    $out = [pscustomobject]@{ Classification = 'SAFE_TO_RESUME'; RecommendedAction = 'NONE REQUIRED'; Detail = 'System consistent; no recovery action required.' }

    if ($lock -ne 'NO_WRITER') {
        if ($lock -eq 'ACTIVE_WRITER') {
            $out.Classification = 'HUMAN_REVIEW_REQUIRED'
            $out.RecommendedAction = 'NONE REQUIRED'
            $out.Detail = "A DevBridge writer holds the lock and its pid ($($View.Lock.Pid)) is alive. Wait for it to finish; do NOT retry the write and do NOT delete the lock."
        } else {
            $out.Classification = 'HUMAN_REVIEW_REQUIRED'
            $out.RecommendedAction = 'RECLAIM STALE WRITER LOCK'
            $out.Detail = "Lock exists (pid $($View.Lock.Pid)) but is not alive. Verify no DevBridge writer is running; if none, reclaim the stale lock per the DB-M12.3 gate dead-pid rules. DB-M32 does NOT delete locks."
        }
        return $out
    }

    # Terminal-write tokens are more specific than a generic backend-state
    # mismatch (a completion/closure tail-missing state must never be retried).
    if ($tokens -contains 'COMPLETION_STARTED_BUT_UNVERIFIED' -or $tokens -contains 'TRIAL_CLOSURE_STARTED_BUT_UNVERIFIED') {
        $out.Classification = 'DO_NOT_RETRY'
        $out.RecommendedAction = 'REVIEW WORKBOOK READ-BACK'
        $out.Detail = "Terminal write evidence exists but the state tail is missing ($($tokens -join ', ')). Re-running can double-write or is blocked; do NOT retry. Review the workbook read-back first."
        return $out
    }

    if ($mismatch.Present) {
        $out.Classification = 'REFRESH_REQUIRED'
        $out.RecommendedAction = 'REFRESH STATE'
        $out.Detail = "Backend claimed success but expected transition '$($mismatch.ExpectedResultState)' is absent (observed '$($mismatch.ActualResultState)'). BACKEND_STATE_MISMATCH preserved; refresh state to re-check."
        return $out
    }

    if ($tokens -contains 'RESERVATION_STARTED_BUT_UNVERIFIED' -or $tokens -contains 'WORKBOOK_WRITE_STARTED_BUT_READBACK_MISSING') {
        $out.Classification = 'READBACK_RECONCILIATION_REQUIRED'
        $out.RecommendedAction = 'REVIEW WORKBOOK READ-BACK'
        $out.Detail = "A write started but its read-back evidence is missing ($($tokens -join ', ')). Reconcile against the workbook read-back before proceeding."
        return $out
    }

    if ($stale.Present) {
        $out.Classification = 'GOVERNANCE_REVIEW_REQUIRED'
        $out.RecommendedAction = 'HUMAN GOVERNANCE REVIEW'
        $out.Detail = "STALE_GOVERNANCE_STATE: recorded expected SHA '$($stale.ExpectedBeforeSha)' differs from observed '$($stale.ObservedSha)'. Operator decides; no silent overwrite."
        return $out
    }

    if ($tokens -contains 'VERIFICATION_STARTED_BUT_RESULT_MISSING') {
        $out.Classification = 'SAFE_TO_RETRY'
        $out.RecommendedAction = 'RE-RUN VERIFICATION'
        $out.Detail = 'Verification result evidence is missing and the task claims a verification transition. Re-running RUN_VERIFICATION is safe (overwrite-only).'
        return $out
    }

    if ($tokens -contains 'CLAUDE_RESULT_RECORDING_INTERRUPTED') {
        $out.Classification = 'HUMAN_REVIEW_REQUIRED'
        $out.RecommendedAction = 'RECORD CLAUDE RESULT AGAIN'
        $out.Detail = 'A Claude review package exists but claude-review.json and the dbM08 evidence field are absent. The REUSED guard is not recovery-safe here; record the Claude result again after human review.'
        return $out
    }

    if ($verdict -eq 'WRITE_STATE_AMBIGUOUS') {
        $out.Classification = 'HUMAN_REVIEW_REQUIRED'
        $out.RecommendedAction = 'REVIEW WORKBOOK READ-BACK'
        $out.Detail = "Workbook SHA '$($View.Workbook.Sha256)' matches neither a recorded before nor after SHA. WRITE_STATE_AMBIGUOUS; NO auto overwrite. Human review required."
        return $out
    }

    if ($identity -eq 'wrong-task') {
        $out.Classification = 'HUMAN_REVIEW_REQUIRED'
        $out.RecommendedAction = 'HUMAN GOVERNANCE REVIEW'
        $out.Detail = 'The last operation evidence belongs to a different changeId than the current task. Verify the correct task context before proceeding.'
        return $out
    }

    if ($identity -eq 'stale') {
        $out.Classification = 'REFRESH_REQUIRED'
        $out.RecommendedAction = 'REFRESH STATE'
        $out.Detail = 'The last operation evidence is stale relative to the observed state. Refresh state before proceeding.'
        return $out
    }

    if ($drift.Drift) {
        $out.Classification = 'REFRESH_REQUIRED'
        $out.RecommendedAction = 'REVIEW GIT STATE'
        $out.Detail = "Git HEAD drifted: recorded '$($drift.Recorded)' vs observed '$($drift.Observed)'. Refresh Git gate state. Remote PR state stays UNKNOWN; never inferred."
        return $out
    }

    if ($inCatalog -and $identity -in @('new','same-op-retried')) {
        $claimed = if ($View.LastOperation.Evidence) { $View.LastOperation.Evidence.ClaimedEndState } else { $null }
        if ($identity -eq 'same-op-retried' -and $claimed -and $View.Task.Status -eq $claimed) {
            $out.Classification = 'SAFE_TO_RESUME'
            $out.RecommendedAction = 'NONE REQUIRED'
            $out.Detail = "Last operation ($($View.LastOperation.Command)) reached its expected end state; system consistent. Resume the current workflow."
        } elseif ($View.LastOperation.Command -eq 'REFRESH_GIT_GATE_STATE' -and -not $drift.Drift) {
            $out.Classification = 'SAFE_TO_RESUME'
            $out.RecommendedAction = 'NONE REQUIRED'
            $out.Detail = 'Git gate state is current: the recorded branch/HEAD still match the observed repository. Resume the current workflow.'
        } else {
            $out.Classification = 'SAFE_TO_RETRY'
            $out.RecommendedAction = (Get-DbM32RetryAction -Command $View.LastOperation.Command)
            $out.Detail = "Re-running $($View.LastOperation.Command) is safe (idempotent / overwrite-only)."
        }
        return $out
    }

    $out.Classification = 'SAFE_TO_RESUME'
    $out.RecommendedAction = 'NONE REQUIRED'
    $out.Detail = 'System consistent; no recovery action required.'
    return $out
}

# --- recovery status (stage 4) ---

function Get-DbM32RecoveryStatus {
    param($View)
    if ($View.Workbook.Verdict -eq 'WRITE_STATE_AMBIGUOUS') { return 'AMBIGUOUS' }
    if ($View.BackendMismatch.Present -or $View.StaleGovernance.Present -or $View.GitDrift.Drift -or $View.Identity -eq 'stale') { return 'STALE' }
    if ($View.Tokens.Count -gt 0) { return 'ATTENTION REQUIRED' }
    return 'OK'
}

# --- config redaction (stage 1): CONFIGURED / NOT_CONFIGURED only ---

function Get-DbM32ConfigRedacted {
    <#
    .SYNOPSIS
    Render provider/model settings as booleans only. Secret references are never
    rendered or logged; a provider is CONFIGURED/NOT_CONFIGURED only.
    #>
    param([string]$Root)
    $rows = New-Object System.Collections.ArrayList
    $providers = Read-DbM32Json -Path (Join-Path $Root 'config\providers.json')
    foreach ($p in @(Get-DbM32Array (Get-ContractProperty $providers 'providers' $null))) {
        [void]$rows.Add([pscustomobject]@{
            Kind = 'PROVIDER'
            Id = [string](Get-ContractProperty $p 'ProviderId' 'unknown')
            Enabled = (Get-ContractProperty $p 'Enabled' $false)
            Configured = (Get-ContractProperty $p 'Configured' $false)
        })
    }
    $routing = Read-DbM32Json -Path (Join-Path $Root 'config\ai-routing.json')
    if ($null -ne $routing) {
        $defaults = Get-ContractProperty $routing 'routingDefaults' $null
        [void]$rows.Add([pscustomobject]@{
            Kind = 'ROUTING'
            Id = 'ai-routing'
            Enabled = (Get-ContractProperty $defaults 'enabled' $false)
            Configured = (Get-ContractProperty $routing 'executionMode' 'MANUAL' -eq 'MANUAL')
        })
    }
    return ,@($rows.ToArray())
}

# --- baseline (represent-only) ---

function Get-DbM32BaselineInfo {
    param([string]$StateDir)
    $b = Read-DbM32Json -Path (Join-Path $StateDir 'pre-devbridge-baseline.json')
    if ($null -eq $b) { return $null }
    return [pscustomobject]@{
        RepresentOnly = [string](Get-ContractProperty $b 'representOnly' 'NO RESTORE FUNCTION EXISTS.')
        WorkbookSha256 = [string](Get-DbM32Nested $b 'workbook.sha256')
        GitHead = [string](Get-DbM32Nested $b 'git.headCommit')
    }
}

# --- diagnostics (stage 5; secret-scanned before emission) ---

function Get-DbM32Diagnostics {
    <#
    .SYNOPSIS
    The essential diagnostic record: timestamp, operation ID, task/change, mode,
    expected vs observed lifecycle, result, failure category, recovery
    classification, workbook SHA, git HEAD. No secret material.
    #>
    param($View)
    $last = $View.LastOperation
    $rows = @(
        [pscustomobject]@{ Key = 'TimestampUtc'; Value = $View.GeneratedAtUtc }
        [pscustomobject]@{ Key = 'OperationId'; Value = $(if ($last -and $last.Evidence) { $last.Evidence.File } else { 'N/A' }) }
        [pscustomobject]@{ Key = 'Task'; Value = $View.Task.NodeId }
        [pscustomobject]@{ Key = 'Change'; Value = $(if ($View.Task.ChangeId) { $View.Task.ChangeId } else { '(none)' }) }
        [pscustomobject]@{ Key = 'Mode'; Value = $View.Lifecycle.Mode }
        [pscustomobject]@{ Key = 'ExpectedLifecycle'; Value = $(if ($last -and $last.Evidence -and $last.Evidence.ClaimedEndState) { $last.Evidence.ClaimedEndState } else { $View.Lifecycle.Status }) }
        [pscustomobject]@{ Key = 'ObservedLifecycle'; Value = $View.Lifecycle.Status }
        [pscustomobject]@{ Key = 'Result'; Value = $(if ($last) { $last.Command } else { 'NONE' }) }
        [pscustomobject]@{ Key = 'FailureCategory'; Value = $(if ($View.Tokens.Count -gt 0) { $View.Tokens -join ',' } else { 'NONE' }) }
        [pscustomobject]@{ Key = 'RecoveryClassification'; Value = $View.Classification.Classification }
        [pscustomobject]@{ Key = 'WorkbookSha'; Value = $(if ($View.Workbook.Sha256) { $View.Workbook.Sha256 } else { 'UNOBSERVED' }) }
        [pscustomobject]@{ Key = 'GitHead'; Value = $(if ($View.Git.HeadCommit) { $View.Git.HeadCommit } else { 'UNOBSERVED' }) }
    )
    return ,@($rows)
}

# --- the reconciled view (stage 1 -> 5 assembly) ---

function Get-DbM32ReconciledView {
    <#
    .SYNOPSIS
    Assemble the full read-only view: task, lifecycle, evidence summaries, last
    operation, detection tokens, workbook verdict, lock, git, identities,
    mismatch/stale/drift, classification, panel fields, config (redacted),
    baseline, diagnostics. Writes nothing.
    #>
    param(
        [string]$Root,
        [string]$StateSource,
        [string]$WorkbookPath,
        [string]$RepositoryPath,
        [string]$NowUtc,
        [string]$LastOperationOverride = ''
    )
    if (-not $NowUtc) { $NowUtc = (Get-Date).ToUniversalTime().ToString('o') }
    $cfg = Get-DbM32Config -Root $Root
    if (-not $WorkbookPath) { $WorkbookPath = $cfg.WorkbookPath }
    if (-not $RepositoryPath) { $RepositoryPath = $cfg.RepositoryRoot }

    $taskRaw = Read-DbM32Json -Path (Join-Path $cfg.StateDir 'current-task.json')
    $task = [pscustomobject]@{
        NodeId = [string](Get-ContractProperty $taskRaw 'nodeId' '(unknown)')
        ChangeId = [string](Get-ContractProperty $taskRaw 'changeId' '')
        Status = [string](Get-ContractProperty $taskRaw 'status' '')
        NextAllowedAction = [string](Get-ContractProperty $taskRaw 'nextAllowedAction' '')
        PreflightVerdict = [string](Get-ContractProperty $taskRaw 'preflightVerdict' '')
        Implementability = [string](Get-ContractProperty $taskRaw 'implementability' '')
        WorkbookSha256 = [string](Get-ContractProperty $taskRaw 'workbookSha256' '')
        DbM08Evidence = [bool](Get-ContractProperty $taskRaw 'dbM08' $false)
        SelectedAtUtc = [string](Get-ContractProperty $taskRaw 'selectedAt' '')
    }

    $snap = Read-DbM32Json -Path (Join-Path $cfg.StateDir 'current-lifecycle-state.json')
    $lifecycle = [pscustomobject]@{
        Mode = [string](Get-ContractProperty $snap 'mode' $(if ($null -eq $snap) { '' } else { 'TRIAL' }))
        TrialMode = (Get-ContractProperty $snap 'trialMode' $true)
        Status = [string](Get-ContractProperty $snap 'status' $task.Status)
        NextAllowedAction = [string](Get-ContractProperty $snap 'nextAllowedAction' $task.NextAllowedAction)
    }

    $evidence = Get-DbM32EvidenceSummaries -StateDir $cfg.StateDir -TaskChangeId $task.ChangeId
    $lastOp = Get-DbM32LastOperation -Evidence $evidence -Override $LastOperationOverride

    $workbookSha = Get-DbM32FileSha256 -Path $WorkbookPath
    $git = Get-DbM32GitObservation -RepositoryPath $RepositoryPath
    $lock = Get-DbM32WriterLockState -LockPath $cfg.LockPath

    $base = [pscustomobject]@{
        Root = $Root; StateDir = $cfg.StateDir; WorkbookPath = $WorkbookPath; RepositoryRoot = $RepositoryPath
        ViewId = "DB32-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
        GeneratedAtUtc = $NowUtc; StateSource = $StateSource; NowUtc = $NowUtc
        Task = $task; Lifecycle = $lifecycle
        Evidence = $evidence; LastOperation = $lastOp
        Workbook = [pscustomobject]@{ Path = $WorkbookPath; Sha256 = $workbookSha; Verdict = 'UNKNOWN' }
        Lock = $lock
        Git = $git
        Guard = New-DbM32ReadOnlyGuard
        Config = (Get-DbM32ConfigRedacted -Root $Root)
        Baseline = (Get-DbM32BaselineInfo -StateDir $cfg.StateDir)
    }

    # workbook verdict needs the evidence; bind it after evidence is set
    $base.Workbook.Verdict = Get-DbM32WorkbookVerdict -ObservedSha $workbookSha -View $base

    # tokens / identities / mismatch / stale / drift
    $tokens = Get-DbM32DetectedTokens -View $base -Root $Root
    $identity = Get-DbM32OperationIdentity -View $base
    $mismatch = Test-DbM32BackendStateMismatch -View $base
    if ($null -eq $mismatch) { $mismatch = [pscustomobject]@{ Present = $false; Token = $null; ExpectedResultState = $null; ActualResultState = $null } }
    $staleGov = Get-DbM32StaleGovernance -View $base
    $drift = Get-DbM32GitDrift -View $base

    # attach the derived properties via Add-Member (strict mode forbids assignment)
    $base | Add-Member -NotePropertyName 'Tokens' -NotePropertyValue $tokens -Force
    $base | Add-Member -NotePropertyName 'Identity' -NotePropertyValue $identity -Force
    $base | Add-Member -NotePropertyName 'BackendMismatch' -NotePropertyValue $mismatch -Force
    $base | Add-Member -NotePropertyName 'StaleGovernance' -NotePropertyValue $staleGov -Force
    $base | Add-Member -NotePropertyName 'GitDrift' -NotePropertyValue $drift -Force
    $base | Add-Member -NotePropertyName 'Classification' -NotePropertyValue (Get-DbM32RecoveryClassification -View $base) -Force
    $base | Add-Member -NotePropertyName 'RecoveryStatus' -NotePropertyValue (Get-DbM32RecoveryStatus -View $base) -Force
    $base | Add-Member -NotePropertyName 'SafeRetry' -NotePropertyValue ([pscustomobject]@{
        InCatalog = ($lastOp -and ($lastOp.Command -in @(Get-DbM32SafeRetryCommands)))
        RetryShown = ($base.Classification.Classification -in @('SAFE_TO_RETRY','SAFE_TO_RESUME'))
    }) -Force
    $base | Add-Member -NotePropertyName 'Diagnostics' -NotePropertyValue (Get-DbM32Diagnostics -View $base) -Force
    $base | Add-Member -NotePropertyName 'Warnings' -NotePropertyValue $git.Warning -Force
    $base | Add-Member -NotePropertyName 'ExpectedStateText' -NotePropertyValue $(if ($lastOp) { Get-DbM32ExpectedStateText -Command $lastOp.Command } else { 'No last operation identified' }) -Force
    $base | Add-Member -NotePropertyName 'ObservedStateText' -NotePropertyValue "current-task.status=$($task.Status); nextAllowedAction=$($task.NextAllowedAction); workbookSha=$($workbookSha); identity=$identity" -Force

    return $base
}
