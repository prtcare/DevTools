# Test-DbM30SupervisedWorkflow.ps1 -- DB-M30 SUPERVISED DEVELOPMENT WORKFLOW INTEGRATION test suite (39 scenarios, A1-I39).
#
# Objective (the brief): integrate the existing DevBridge lifecycle, dependency
# context, AI recommendation, cost information and history systems into ONE
# coherent SUPERVISED operator workflow -- a READ-ONLY guided pipeline where every
# external step (ChatGPT handoff copy, Claude Code / DeepSeek implementation,
# returning the result, Claude review, Git gates, completion) is performed by the
# human operator. DB-M30 is explicitly NOT a fully autonomous development
# platform and never executes a model/provider, never invokes ChatGPT/Claude,
# never creates/approves/merges PRs, never modifies the roadmap.
#
# Test matrix (design section 9):
#   A1-A9   workflow contracts + stage catalog (13 stages, 8-token vocab, order,
#           human actions, command references, array normalization, read-only
#           guard, markers, secret scanner).
#   B10-B18 engine stage derivation across lifecycle positions (no task /
#           preflight done / preflight blocked / reserved / handoff done /
#           verification done / package done / claude decision PASS /
#           correction FIX + verified).
#   C19-C26 guidance cards (dependency context present/absent, routing disabled
#           -> NOT_ENABLED / enabled -> recommendation via synthetic catalogue,
#           cost estimate + budget, provider health no-evidence, history
#           empty-store honest + populated fixture, secret-leak on every HTML
#           emission).
#   D27-D31 non-mutation (no lifecycle-state write, no attempt store write, no
#           config write, workbook byte-identical, Nexus source untouched).
#   R32-R36 regressions (DB-M29, DB-M26, DB-M28, DB-M18.1 child suites; solution
#           build 0 errors / 0 warnings).
#   I37-I39 invariants (workbook hash, Nexus repo status + live honest view,
#           solution build re-assert).
#
# AUTO_EXECUTION_ENABLED = FALSE. Provider/model executed: NO. Paid calls: 0.
# Network calls: 0. The library never writes outside the operator-requested HTML
# artifact; every fixture workspace lives under $env:TEMP.
#
# Exit code: 0 = all scenarios + regressions passed; 1 = any failure.
# Prints "DB-M30 TEST SUMMARY: <passed> passed, <failed> failed".

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Root    = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:NowUtc  = '2026-09-01T08:00:00Z'   # deterministic reference
$script:TempRoot = Join-Path $env:TEMP ('dbm30-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $script:TempRoot | Out-Null

# --- runtime library ----------------------------------------------------------
# WorkflowEngine + WorkflowRender (contracts) are the DB-M30 runtime. The real
# Router.ps1 (DB-M19) and AttemptStore.ps1 (DB-M17) are loaded ONLY so the
# enabled-routing and populated-history fixtures can build deterministic records
# with the REAL New-* builders (the same pattern the DB-M19/M29 harnesses use).
. (Join-Path $PSScriptRoot "WorkflowEngine.ps1")
. (Join-Path $PSScriptRoot "WorkflowRender.ps1")
. (Join-Path $script:Root "scripts\ai-routing\router\Router.ps1")
. (Join-Path $script:Root "scripts\ai-routing\AttemptStore.ps1")

$script:WorkbookPath = 'C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx'

# --- assertion helpers (must return nothing) ----------------------------------

$script:TestCount = 0
$script:TestFails = New-Object System.Collections.Generic.List[string]
$script:ScenarioFails = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:TestCount++
    if (-not $Condition) { $script:TestFails.Add($Message) }
}
function Assert-Null {
    param($Actual, [string]$Message)
    $script:TestCount++
    if ($null -ne $Actual) { $script:TestFails.Add("$Message (expected null, got '$Actual')") }
}
function Assert-NotNull {
    param($Actual, [string]$Message)
    $script:TestCount++
    if ($null -eq $Actual) { $script:TestFails.Add("$Message (expected non-null, got null)") }
}
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    $script:TestCount++
    if ("$Actual" -ne "$Expected") { $script:TestFails.Add("$Message (actual='$Actual' expected='$Expected')") }
}
function Assert-In {
    param($Actual, [AllowNull()][string[]]$Allowed, [string]$Message)
    $script:TestCount++
    if ("$Actual" -notin $Allowed) { $script:TestFails.Add("$Message (actual='$Actual' not in [$($Allowed -join ',')])") }
}
function Assert-Contains {
    param([string]$Text, [string]$Needle, [string]$Message)
    $script:TestCount++
    if ($Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        $script:TestFails.Add("$Message (missing '$Needle')")
    }
}
function Assert-NotContains {
    param([string]$Text, [string]$Needle, [string]$Message)
    $script:TestCount++
    if ($Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $script:TestFails.Add("$Message (unexpected '$Needle' present)")
    }
}

# --- SHA / frozen-file infrastructure ------------------------------------------

function Get-Sha256 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead((Resolve-Path $Path))
    try { $hash = $sha.ComputeHash($stream) } finally { $stream.Dispose() }
    return ([BitConverter]::ToString($hash) -replace '-', '')
}

function Get-NexusGitStatus {
    <#
    .SYNOPSIS
    The Nexus.Developer repo working-tree status (porcelain), captured so D31/I38
    can prove DB-M30 never touches the Nexus source. Read-only.
    #>
    $nexus = 'C:\Personal\Nexus.Developer'
    if (-not (Test-Path -LiteralPath (Join-Path $nexus '.git'))) { return 'NO_GIT_REPO' }
    try { $out = @(& git -C $nexus status --porcelain) } catch { return 'GIT_UNAVAILABLE' }
    return ($out -join "`n")
}

# DB-M30 must leave its own library, the DB-M29/M26/M28/M18.1 owned files and the
# live state/config/workbook byte-identical (READ-ONLY integration).
$script:FrozenFiles = @(
    'scripts\supervised-workflow\WorkflowContracts.ps1',
    'scripts\supervised-workflow\WorkflowEngine.ps1',
    'scripts\supervised-workflow\WorkflowRender.ps1',
    'scripts\supervised-workflow\Show-DbM30SupervisedWorkflow.ps1',
    'scripts\ai-routing\task-history\HistoryContracts.ps1',
    'scripts\ai-routing\task-history\HistoryEngine.ps1',
    'scripts\ai-routing\task-history\HistoryRender.ps1',
    'scripts\ai-routing\dashboard\DashboardContracts.ps1',
    'scripts\ai-routing\dashboard\DashboardData.ps1',
    'scripts\ai-routing\dashboard\DashboardRender.ps1',
    'scripts\ai-routing\model-config\ModelConfigContracts.ps1',
    'scripts\ai-routing\model-config\ModelConfigEngine.ps1',
    'scripts\ai-routing\model-config\ModelConfigRender.ps1',
    'scripts\ai-routing\DependencyLineage.ps1',
    'scripts\ai-routing\Test-DbM181DependencyLineage.ps1'
)
$script:FrozenShasBefore = @{}
foreach ($rel in $script:FrozenFiles) { $script:FrozenShasBefore[$rel] = Get-Sha256 (Join-Path $script:Root $rel) }

# Live config files (D29). DB-M30 never writes these.
$script:ConfigFiles = @(
    'config\providers.json',
    'config\models.json',
    'config\ai-routing.json',
    'config\pricing\pricing-catalogue.json',
    'config\currency\exchange-rates.json',
    'config\cost\cost-calculator.json',
    'config\performance\confidence-bands.json'
)
$script:CfgShasBefore = @{}
foreach ($rel in $script:ConfigFiles) { $script:CfgShasBefore[$rel] = Get-Sha256 (Join-Path $script:Root $rel) }

# Live lifecycle state files (D27).
$script:StateFiles = @(Get-ChildItem (Join-Path $script:Root 'state') -File -Filter *.json -ErrorAction SilentlyContinue)
$script:StateShasBefore = @{}
foreach ($f in $script:StateFiles) { $script:StateShasBefore[$f.FullName] = Get-Sha256 $f.FullName }

$script:AttemptStorePath = Join-Path $script:Root 'state\attempts'
$script:AttemptStorePresentBefore = (Test-Path -LiteralPath $script:AttemptStorePath)

$script:WorkbookShaBefore = Get-Sha256 $script:WorkbookPath
$script:NexusStatusBefore = Get-NexusGitStatus

# --- fixture helpers -----------------------------------------------------------

function Set-FxJson {
    <#
    .SYNOPSIS
    Write a JSON artifact to a fixture path (UTF-8 no BOM, temp-only).
    #>
    param([string]$Path, [object]$Value)
    $json = $Value | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function New-FxWorkspace {
    <#
    .SYNOPSIS
    Build a deterministic temp state-dir + evidence-root pair. The populated
    workspace models a governed task after M03 preflight CLEAR with one direct
    dependency and a matching reservation (the same durable artifacts the real
    engine reads). -Empty builds a bare workspace (no task selected yet).
    #>
    param([switch]$Empty)
    $state = Join-Path $script:TempRoot ('fxstate-' + [guid]::NewGuid().ToString('N'))
    $evidence = Join-Path $script:TempRoot ('fxevidence-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $state, $evidence | Out-Null
    if (-not $Empty) {
        Set-FxJson (Join-Path $state 'current-task.json') @{
            taskId = $null; nodeId = 'M-07-0.2'; name = 'DB-M30 fixture task'; nodeType = 'Milestone'
            status = 'PREFLIGHTED'; preflightVerdict = 'CLEAR'; implementability = 'IMPLEMENTABLE'
            nextAllowedAction = 'RESERVE'; changeId = 'CHG-M30-FX'
            workbookSha256 = '6D42C3BF6D3307B4B1A45870CE12F41E403DFED412E59F33D7B487E93A83E4F5'
            selectedAt = '2026-08-31T10:00:00Z'
        }
        Set-FxJson (Join-Path $state 'current-lifecycle-state.json') @{
            mode = 'TRIAL'; trialMode = $true; status = 'TRIAL_CYCLE_SAFE_STOP'; generatedAtUtc = '2026-08-31T09:00:00Z'
        }
        Set-FxJson (Join-Path $state 'preflight.json') @{
            nodeId = 'M-07-0.2'; verdict = 'CLEAR'
            dependencies = @(@{ dependencyId = 'M-05-0.1'; state = 'CLEAR' })
        }
        Set-FxJson (Join-Path $state 'reservation.json') @{
            nodeId = 'M-07-0.2'; changeId = 'CHG-M30-FX'
            gitBaseline = @{ branch = 'feature/dbm30-fixture'; scopeFileHashes = @{} }
        }
        New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path $evidence 'M-07-0.2') 'CHG-M30-FX') | Out-Null
    }
    return @{ State = $state; Evidence = $evidence }
}

function New-FxEv {
    <#
    .SYNOPSIS
    A complete evidence-predicate hashtable for Resolve-DbM30StageTokens (B-series).
    Includes every key the resolver reads so Set-StrictMode never throws; TrialMode
    defaults to true (the live governed mode today).
    #>
    param(
        [string]$NodeId = '',
        [string]$PreflightVerdict = '',
        [bool]$PreflightClear = $false,
        [bool]$PreflightBlocked = $false,
        [bool]$PreflightPresent = $false,
        [string]$CurrentTaskNextAllowedAction = '',
        [bool]$ReservationDone = $false,
        [bool]$HandoffDone = $false,
        [bool]$VerificationDone = $false,
        [bool]$VerificationFailed = $false,
        [string]$VerificationPrimaryResult = '',
        [bool]$PackageDone = $false,
        [bool]$ClaudeDecisionDone = $false,
        [string]$ClaudeDecision = '',
        [bool]$CorrectionNeeded = $false,
        [bool]$CorrectionDone = $false,
        [bool]$TrialMode = $true,
        [bool]$GitMerged = $false,
        [bool]$CompletionDone = $false
    )
    return @{
        NodeId = $NodeId; PreflightVerdict = $PreflightVerdict
        PreflightClear = $PreflightClear; PreflightBlocked = $PreflightBlocked
        PreflightPresent = $PreflightPresent
        CurrentTaskNextAllowedAction = $CurrentTaskNextAllowedAction
        ReservationDone = $ReservationDone; HandoffDone = $HandoffDone
        VerificationDone = $VerificationDone; VerificationFailed = $VerificationFailed
        VerificationPrimaryResult = $VerificationPrimaryResult
        PackageDone = $PackageDone; ClaudeDecisionDone = $ClaudeDecisionDone
        ClaudeDecision = $ClaudeDecision; CorrectionNeeded = $CorrectionNeeded
        CorrectionDone = $CorrectionDone; TrialMode = $TrialMode
        GitMerged = $GitMerged; CompletionDone = $CompletionDone
    }
}

function Get-FxToken {
    <#
    .SYNOPSIS
    Read one stage's derived Token from the stage-token result.
    #>
    param($Result, [string]$Key)
    $match = @($Result.Stages) | Where-Object { $_.StageKey -eq $Key } | Select-Object -First 1
    if ($null -eq $match) { return $null }
    return $match.Token
}

# --- DB-M19 synthetic catalogue fixture builders (cloned from Test-DbM19Routing.ps1;
#     the REAL builders, so the enabled-path recommendation is genuine) -----------

function New-TestProvider {
    param([string]$ProviderId, [string]$DisplayName = $ProviderId, [bool]$Enabled = $true,
          [string]$ProviderType = 'DIRECT')
    return New-AiProvider -ProviderId $ProviderId -DisplayName $DisplayName -Enabled $Enabled `
        -Configured $true -ProviderType $ProviderType
}
function New-TestModel {
    param(
        [string]$ModelId, [string]$ProviderId, [string]$UnderlyingModelId, [string]$GatewayProviderId,
        [bool]$Enabled = $true, [string]$LocalOrRemote = 'REMOTE',
        [Nullable[bool]]$SupportsCoding = $true, [Nullable[bool]]$SupportsReasoning = $true,
        [Nullable[bool]]$SupportsVision = $null, [Nullable[bool]]$SupportsToolUse = $null,
        [Nullable[bool]]$SupportsStructuredOutput = $true,
        [long]$ContextWindow = 64000, [long]$MaxOutputTokens = 8192,
        [string[]]$ReasoningLevelsSupported = @('LOW','MEDIUM','HIGH'),
        [string]$RelativeSpeed = 'NORMAL', [string]$ReliabilityClass = 'HIGH'
    )
    return New-AiModel -ModelId $ModelId -ProviderId $ProviderId `
        -UnderlyingModelId $UnderlyingModelId -GatewayProviderId $GatewayProviderId `
        -DisplayName "Model $ModelId" -Enabled $Enabled -LocalOrRemote $LocalOrRemote `
        -SupportsCoding $SupportsCoding -SupportsReasoning $SupportsReasoning `
        -SupportsVision $SupportsVision -SupportsToolUse $SupportsToolUse `
        -SupportsStructuredOutput $SupportsStructuredOutput `
        -ContextWindow $ContextWindow -MaxOutputTokens $MaxOutputTokens `
        -ReasoningLevelsSupported $ReasoningLevelsSupported `
        -RelativeSpeed $RelativeSpeed -ReliabilityClass $ReliabilityClass
}
function New-TestPricingRecord {
    param(
        [string]$PricingRecordId, [string]$ProviderId, [string]$ModelId,
        [string]$ProcessingTier = 'STANDARD', [string]$TimeBand = 'DEFAULT',
        [Nullable[double]]$InputPricePerMillion = 1.0, [Nullable[double]]$CachedInputPricePerMillion = 0.1,
        [Nullable[double]]$OutputPricePerMillion = 3.0, [string]$EffectiveFromUtc = '2026-06-01T00:00:00Z'
    )
    return New-AiPricingRecord -PricingRecordId $PricingRecordId -ProviderId $ProviderId -ModelId $ModelId `
        -Currency 'USD' -EffectiveFromUtc $EffectiveFromUtc -ProcessingTier $ProcessingTier -TimeBand $TimeBand `
        -InputPricePerMillion $InputPricePerMillion -CachedInputPricePerMillion $CachedInputPricePerMillion `
        -OutputPricePerMillion $OutputPricePerMillion -Source 'test-fixture'
}
function New-TestFx {
    param([string]$RateId = 'fx-usd-inr-test', [double]$Rate = 83.5)
    return New-AiExchangeRateRecord -ExchangeRateId $RateId -BaseCurrency 'USD' -QuoteCurrency 'INR' `
        -Rate $Rate -EffectiveAtUtc '2026-06-01T00:00:00Z'
}
function New-TestConfiguration {
    param(
        [AllowNull()][object]$Providers = $null, [AllowNull()][object]$Models = $null,
        [AllowNull()][object]$Pricing = $null, [AllowNull()][object]$ExchangeRates = $null
    )
    if ($null -eq $Providers) { $Providers = @{} }
    if ($null -eq $Models) { $Models = @{} }
    if ($null -eq $Pricing) { $Pricing = @{} }
    if ($null -eq $ExchangeRates) {
        $fx = @{}
        $rate = New-TestFx
        $fx[$rate.ExchangeRateId] = $rate
        $ExchangeRates = $fx
    }
    $costConfig = [pscustomobject]@{ schemaVersion = 1; ReasoningTokenBilling = 'INCLUDED_IN_OUTPUT' }
    return @{
        Routing = $null; Providers = $Providers; Models = $Models; Pricing = $Pricing;
        ExchangeRates = $ExchangeRates; CostConfig = $costConfig
    }
}
function New-StandardCatalogue {
    $providers = @{}
    $providers['prov-a'] = New-TestProvider -ProviderId 'prov-a' -DisplayName 'Provider A'

    $models = @{}
    $models['model-cheap'] = New-TestModel -ModelId 'model-cheap' -ProviderId 'prov-a' `
        -ContextWindow 64000 -MaxOutputTokens 8192 -RelativeSpeed 'FAST' -ReliabilityClass 'HIGH'
    $models['model-expensive'] = New-TestModel -ModelId 'model-expensive' -ProviderId 'prov-a' `
        -ContextWindow 128000 -MaxOutputTokens 16384 -RelativeSpeed 'NORMAL' -ReliabilityClass 'CRITICAL_GRADE'

    $pricing = @{}
    $pCheap = New-TestPricingRecord -PricingRecordId 'pr-cheap' -ProviderId 'prov-a' -ModelId 'model-cheap' `
        -InputPricePerMillion 0.5 -CachedInputPricePerMillion 0.05 -OutputPricePerMillion 1.5
    $pExp = New-TestPricingRecord -PricingRecordId 'pr-exp' -ProviderId 'prov-a' -ModelId 'model-expensive' `
        -InputPricePerMillion 2.0 -CachedInputPricePerMillion 0.2 -OutputPricePerMillion 6.0
    $pricing[$pCheap.PricingRecordId] = $pCheap
    $pricing[$pExp.PricingRecordId] = $pExp

    return New-TestConfiguration -Providers $providers -Models $models -Pricing $pricing
}
function New-TestRequirement {
    param(
        [string]$TaskId = 'T-1',
        [string]$TaskType = 'IMPLEMENTATION',
        [string]$Complexity = 'MEDIUM',
        [string]$Risk = 'LOW',
        [Nullable[bool]]$RequiresCoding = $true,
        [Nullable[bool]]$RequiresReasoning = $true,
        [string]$MinimumReasoningLevel = 'MEDIUM',
        [Nullable[bool]]$RequiresStructuredOutput = $true,
        [Nullable[long]]$RequiredContextTokens = 32000,
        [Nullable[long]]$ExpectedOutputTokens = 2048,
        [string]$RequiredReliability = 'HIGH',
        [string]$ExecutionMode = 'ASSISTED'
    )
    return New-AiCapabilityRequirement -TaskId $TaskId -TaskType $TaskType -Complexity $Complexity -Risk $Risk `
        -RequiresCoding $RequiresCoding -RequiresReasoning $RequiresReasoning `
        -MinimumReasoningLevel $MinimumReasoningLevel -RequiresStructuredOutput $RequiresStructuredOutput `
        -RequiredContextTokens $RequiredContextTokens -ExpectedOutputTokens $ExpectedOutputTokens `
        -RequiredReliability $RequiredReliability -ExecutionMode $ExecutionMode
}
function New-TestRequest {
    param(
        [AllowNull()][object]$Requirement,
        [string]$TaskId = 'T-1',
        [string]$ExecutionMode = 'ASSISTED',
        [Nullable[double]]$MaxAllowedCost,
        [AllowNull()]$RequestTimestampUtc = '2026-08-30T12:00:00Z',
        [double]$CachedInputFraction = 0.0,
        [AllowNull()][object]$ManualOverrideRequest
    )
    if ($null -eq $Requirement) { $Requirement = New-TestRequirement -TaskId $TaskId }
    return New-RoutingRequest -TaskId $TaskId -Requirement $Requirement `
        -ExecutionMode $ExecutionMode -MaxAllowedCost $MaxAllowedCost `
        -RequestTimestampUtc $RequestTimestampUtc -CachedInputFraction $CachedInputFraction `
        -ManualOverrideRequest $ManualOverrideRequest -TargetCurrency 'INR'
}

# --- DB-M17 attempt-record fixture builder (cloned from Test-DbM29TaskHistory.ps1;
#     the REAL constructor, READ-ONLY) -------------------------------------------

function New-Att {
    <#
    .SYNOPSIS
    Build a deterministic synthetic AiAttemptRecord v1 (DB-M17) for one scenario.
    Never writes to disk. ClaudeReviewStatus and FailureFingerprintId are EXTENDED
    fields attached via Add-Member (the DB-M25/M26/M29 pattern); the DB-M17 record
    shape is untouched.
    #>
    param(
        [string]$TaskId, [string]$NodeId, [string]$ChangeId, [string]$AttemptId,
        [string]$ParentAttemptId, [int]$RetryNumber = 0,
        [string]$Result = 'SUCCESS', [string]$VerificationResult = '',
        [string]$FailureCategory, [Nullable[double]]$ActualCost, [Nullable[double]]$EstimatedCost,
        [string]$CostCurrency = 'INR', [string]$ProviderId = 'prov-a', [string]$ModelId = 'model-a',
        [string]$UnderlyingModelId = 'um-a', [string]$GatewayProviderId,
        [string]$ReasoningLevel = 'MEDIUM', [string]$TaskType = 'IMPLEMENTATION',
        [string]$Complexity = 'MEDIUM', [string]$Risk = 'LOW', [string]$ExecutionMode = 'ASSISTED',
        [Nullable[long]]$DurationMs, [Nullable[long]]$InputTokens, [Nullable[long]]$OutputTokens,
        [Nullable[long]]$ContextTokens,
        [string]$StartedAtUtc = '2026-08-31T10:00:00Z', [string]$EndedAtUtc = '2026-08-31T10:00:30Z',
        [string]$EscalatedFromAttemptId, [string]$EscalatedToAttemptId, [string]$EscalationReason,
        [string]$FailureFingerprintId, [string]$ClaudeReviewStatus
    )
    $rec = New-AiAttemptRecord -TaskId $TaskId -NodeId $NodeId -ChangeId $ChangeId -AttemptId $AttemptId `
        -ParentAttemptId $ParentAttemptId -RetryNumber $RetryNumber `
        -Result $Result -VerificationResult $VerificationResult -FailureCategory $FailureCategory `
        -ActualCost $ActualCost -EstimatedCost $EstimatedCost -CostCurrency $CostCurrency `
        -ProviderId $ProviderId -ModelId $ModelId -UnderlyingModelId $UnderlyingModelId `
        -GatewayProviderId $GatewayProviderId -ReasoningLevel $ReasoningLevel -TaskType $TaskType `
        -Complexity $Complexity -Risk $Risk -ExecutionMode $ExecutionMode `
        -DurationMs $DurationMs -InputTokens $InputTokens -OutputTokens $OutputTokens -ContextTokens $ContextTokens `
        -StartedAtUtc $StartedAtUtc -EndedAtUtc $EndedAtUtc `
        -EscalatedFromAttemptId $EscalatedFromAttemptId -EscalatedToAttemptId $EscalatedToAttemptId `
        -EscalationReason $EscalationReason
    if ($FailureFingerprintId) { $rec | Add-Member -NotePropertyName 'FailureFingerprintId' -NotePropertyValue $FailureFingerprintId -Force }
    if ($ClaudeReviewStatus) { $rec | Add-Member -NotePropertyName 'ClaudeReviewStatus' -NotePropertyValue $ClaudeReviewStatus -Force }
    return $rec
}

# --- regression suites (child processes; read-only over the DB-M30 scope) ---------

$script:RegressionResults = New-Object System.Collections.Generic.List[object]
$script:ExternalDrift = New-Object System.Collections.Generic.List[string]

function Invoke-RegressionSuite {
    <#
    .SYNOPSIS
    Run a frozen dependency suite as a CHILD process (read-only over the DB-M30
    scope) and parse its outcome. Child suites use varied summary formats, so the
    parser accepts: 'TEST SUMMARY: N passed, M failed' (LAST match),
    'N assertions, N failed/failures', 'PASSED: N' + 'FAILED: N',
    'N checks, A passed, B failed', then falls back to PASS:/FAIL: line counts.
    #>
    param([string]$Name, [string]$Path)
    $full = Join-Path $script:Root $Path
    $log = Join-Path $script:TempRoot ("reg-" + $Name + '.log')
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $full > $log 2>&1
    $exit = $LASTEXITCODE
    $text = if (Test-Path $log) { [System.IO.File]::ReadAllText($log) } else { '' }
    $passed = -1
    $failed = -1
    $all = [regex]::Matches($text, 'TEST SUMMARY:\s*(\d+)\s+passed,\s*(\d+)\s+failed')
    if ($all.Count -gt 0) { $last = $all[$all.Count - 1]; $passed = [int]$last.Groups[1].Value; $failed = [int]$last.Groups[2].Value }
    if ($passed -lt 0) {
        $all = [regex]::Matches($text, '(\d+)\s+assertions?,\s*(\d+)\s+(?:failed|failures)')
        if ($all.Count -gt 0) { $last = $all[$all.Count - 1]; $passed = [int]$last.Groups[1].Value; $failed = [int]$last.Groups[2].Value }
    }
    if ($passed -lt 0) {
        $mPass = [regex]::Match($text, '(?m)^PASSED:\s*(\d+)\s*$')
        $mFail = [regex]::Match($text, '(?m)^FAILED:\s*(\d+)\s*$')
        if ($mPass.Success) { $passed = [int]$mPass.Groups[1].Value; $failed = if ($mFail.Success) { [int]$mFail.Groups[1].Value } else { 0 } }
    }
    if ($passed -lt 0) {
        $all = [regex]::Matches($text, '(\d+)\s+checks?,\s*(\d+)\s+passed,\s*(\d+)\s+failed')
        if ($all.Count -gt 0) { $last = $all[$all.Count - 1]; $passed = [int]$last.Groups[2].Value; $failed = [int]$last.Groups[3].Value }
    }
    if ($passed -lt 0) {
        $passed = ([regex]::Matches($text, '(?m)^\s*(PASS:|\[PASS\])')).Count
        $failed = ([regex]::Matches($text, '(?m)^\s*(FAIL:|\[FAIL\])')).Count
    }
    return @{ Name = $Name; Passed = $passed; Failed = $failed; ExitCode = $exit; Log = $text }
}

# --- scenarios -------------------------------------------------------------------

# A1 stage catalog has exactly 13 stages
function Test-A1-StageCatalog {
    $cat = @(Get-DbM30StageCatalog)
    Assert-Equal $cat.Count 13 'A1: catalog has 13 stages'
}

# A2 the 8-token display vocabulary (the DevBridge.Engine vocabulary)
function Test-A2-Vocab {
    $vocab = @(Get-DbM30StageVocab)
    Assert-Equal $vocab.Count 8 'A2: 8-token vocabulary'
    Assert-Equal ($vocab -join ',') 'NOT_STARTED,READY,CURRENT,PASS,FAIL,BLOCKED,HUMAN_ACTION,NOT_APPLICABLE' 'A2: vocabulary order'
}

# A3 the four guidance-card statuses
function Test-A3-CardStatuses {
    $st = @(Get-DbM30CardStatuses)
    Assert-Equal $st.Count 4 'A3: 4 card statuses'
    Assert-True ('AVAILABLE' -in $st -and 'NOT_AVAILABLE' -in $st -and 'NOT_ENABLED' -in $st -and 'EMPTY' -in $st) 'A3: all four statuses present'
}

# A4 catalog keys unique and orders strictly 1..13
function Test-A4-CatalogOrder {
    $cat = @(Get-DbM30StageCatalog)
    $keys = @($cat | ForEach-Object { [string]$_.StageKey })
    Assert-Equal (@($keys | Sort-Object -Unique).Count) 13 'A4: stage keys unique'
    $orders = @($cat | ForEach-Object { [int]$_.Order })
    Assert-Equal ($orders -join ',') ((1..13) -join ',') 'A4: orders are 1..13 sequential'
}

# A5 every stage has a human action + evidence sources; every command resolves
function Test-A5-CatalogFields {
    foreach ($s in @(Get-DbM30StageCatalog)) {
        Assert-True (-not [string]::IsNullOrWhiteSpace($s.Label)) "A5: stage $($s.StageKey) has a label"
        Assert-True (-not [string]::IsNullOrWhiteSpace($s.HumanAction)) "A5: stage $($s.StageKey) has a human action"
        Assert-True (@($s.EvidenceSources).Count -gt 0) "A5: stage $($s.StageKey) has evidence sources"
        foreach ($cmd in @($s.Commands)) {
            Assert-True (Test-Path -LiteralPath (Join-Path $script:Root $cmd)) "A5: command resolves: $cmd"
        }
    }
}

# A6 array normalization (PS 5.1 @($null) is a 1-element array -- never invented evidence)
function Test-A6-ArrayNormalization {
    $n1 = Get-DbM30Array $null
    Assert-Equal $n1.Count 0 'A6: null -> empty array'
    $n2 = Get-DbM30Array @()
    Assert-Equal $n2.Count 0 'A6: empty -> empty array'
    $n3 = Get-DbM30Array 'x'
    Assert-Equal $n3.Count 1 'A6: scalar -> 1 element'
    $n4 = Get-DbM30Array @(1,2,3)
    Assert-Equal $n4.Count 3 'A6: list preserved'
    Assert-Equal $n4[1] 2 'A6: list order preserved'
    $n5 = Get-DbM30Array @(1,$null,3)
    Assert-Equal $n5.Count 2 'A6: null elements filtered'
    Assert-Equal $n5[0] 1 'A6: filtered list head'
}

# A7 read-only guard: no auto execution, no paid/network calls, nothing modified
function Test-A7-ReadOnlyGuard {
    $g = New-DbM30ReadOnlyGuard
    Assert-Equal $g.AutoExecutionEnabled $false 'A7: auto execution disabled'
    Assert-Equal $g.PaidApiCalls 0 'A7: paid calls 0'
    Assert-Equal $g.NetworkCalls 0 'A7: network calls 0'
    foreach ($f in @('LifecycleStateModified','RoutingPolicyModified','AttemptStoreModified','EscalationDecisionsModified','BudgetPolicyModified','FingerprintsModified','WorkbookModified','NexusSourceModified','SecretValuesDisplayed','SecretValuesLogged')) {
        Assert-Equal $g.$f 'NO' "A7: $f = NO"
    }
}

# A8 backend markers (exit is always 0; outcomes only via stdout markers)
function Test-A8-Markers {
    $m = @(Out-DbM30Markers)
    Assert-True ('DB30_OUTCOME: PASS' -in $m) 'A8: outcome marker present'
    Assert-True ('DB30_RESULT_PASS' -in $m) 'A8: result-pass marker present'
    Assert-True ('DB30_WORKBOOK_MODIFIED: False' -in $m) 'A8: workbook marker present'
    Assert-True ('DB30_NEXUS_SOURCE_MODIFIED: False' -in $m) 'A8: nexus marker present'
    Assert-True ('DB30_GIT_MODIFIED: False' -in $m) 'A8: git marker present'
}

# A9 secret scanner: clean object clean; bare token value detected; hash exempt
function Test-A9-SecretLeak {
    $clean = @{ Explanation = 'No secret here'; Note = 'guidance note'; PackageHash = '9F86D081884C7D659A2FEAA0C55AD015A3BF4F1B2B0B822CD15D6C15B0F00A08' }
    $r1 = Test-DbM30SecretLeak $clean
    Assert-True (-not $r1.Leak) 'A9: clean object no leak'
    $leaky = @{ Note = 'sk-testsecret1234567890'; HumanAction = 'copy the handoff' }
    $r2 = Test-DbM30SecretLeak $leaky
    Assert-True $r2.Leak 'A9: injected sk- token detected'
    $hashOnly = @{ PackageHash = '9F86D081884C7D659A2FEAA0C55AD015A3BF4F1B2B0B822CD15D6C15B0F00A08' }
    $r3 = Test-DbM30SecretLeak $hashOnly
    Assert-True (-not $r3.Leak) 'A9: hash in exempt field is not a leak'
}

# B10 no task selected -> governed task READY, nothing else actionable
function Test-B10-NoTask {
    $ev = New-FxEv
    $r = Resolve-DbM30StageTokens -Ev $ev
    Assert-Equal $r.CurrentStage.StageKey 'GOVERNED_TASK' 'B10: current stage GOVERNED_TASK'
    Assert-Equal $r.CurrentStage.Token 'READY' 'B10: governed task READY'
    Assert-Equal (Get-FxToken $r 'M03_SELECTION') 'NOT_STARTED' 'B10: M03 NOT_STARTED'
    Assert-Equal (Get-FxToken $r 'GOVERNED_COMPLETION') 'NOT_APPLICABLE' 'B10: completion NOT_APPLICABLE in trial'
}

# B11 task selected + preflight CLEAR -> M03 PASS, reservation READY
function Test-B11-PreflightClear {
    $ev = New-FxEv -NodeId 'M-07-0.2' -PreflightPresent $true -PreflightClear $true -PreflightVerdict 'CLEAR'
    $r = Resolve-DbM30StageTokens -Ev $ev
    Assert-Equal $r.CurrentStage.StageKey 'M04_RESERVATION' 'B11: current stage M04'
    Assert-Equal $r.CurrentStage.Token 'READY' 'B11: M04 READY'
    Assert-Equal (Get-FxToken $r 'M03_SELECTION') 'PASS' 'B11: M03 PASS'
    Assert-Equal (Get-FxToken $r 'DEPENDENCY_CONTEXT') 'PASS' 'B11: dependency context PASS'
}

# B12 task selected + preflight BLOCKED -> M03 BLOCKED with governance note
function Test-B12-PreflightBlocked {
    $ev = New-FxEv -NodeId 'M-07-0.2' -PreflightPresent $true -PreflightBlocked $true `
        -PreflightVerdict 'RESOLVE_GOVERNANCE_BLOCK' -CurrentTaskNextAllowedAction 'RESOLVE_GOVERNANCE_BLOCK'
    $r = Resolve-DbM30StageTokens -Ev $ev
    Assert-Equal $r.CurrentStage.StageKey 'M03_SELECTION' 'B12: current stage M03'
    Assert-Equal $r.CurrentStage.Token 'BLOCKED' 'B12: M03 BLOCKED'
    Assert-Contains $r.CurrentStage.Note 'RESOLVE_GOVERNANCE_BLOCK' 'B12: governance note names the block'
    Assert-Equal (Get-FxToken $r 'DEPENDENCY_CONTEXT') 'BLOCKED' 'B12: dependency context BLOCKED'
    Assert-Equal (Get-FxToken $r 'M04_RESERVATION') 'NOT_STARTED' 'B12: M04 NOT_STARTED while blocked'
}

# B13 reserved -> M04 PASS, M05 READY, guidance READY
function Test-B13-Reserved {
    $ev = New-FxEv -NodeId 'M-07-0.2' -PreflightPresent $true -PreflightClear $true -PreflightVerdict 'CLEAR' -ReservationDone $true
    $r = Resolve-DbM30StageTokens -Ev $ev
    Assert-Equal $r.CurrentStage.StageKey 'M05_CHATGPT_HANDOFF' 'B13: current stage M05'
    Assert-Equal $r.CurrentStage.Token 'READY' 'B13: M05 READY'
    Assert-Equal (Get-FxToken $r 'M04_RESERVATION') 'PASS' 'B13: M04 PASS'
    Assert-Equal (Get-FxToken $r 'AI_RECOMMENDATION_COST') 'READY' 'B13: guidance READY'
}

# B14 handoff done -> M05 PASS, external implementation HUMAN_ACTION
function Test-B14-HandoffDone {
    $ev = New-FxEv -NodeId 'M-07-0.2' -PreflightClear $true -ReservationDone $true -HandoffDone $true
    $r = Resolve-DbM30StageTokens -Ev $ev
    Assert-Equal $r.CurrentStage.StageKey 'EXTERNAL_IMPLEMENTATION' 'B14: current stage external implementation'
    Assert-Equal $r.CurrentStage.Token 'HUMAN_ACTION' 'B14: external implementation HUMAN_ACTION'
    Assert-Equal (Get-FxToken $r 'M05_CHATGPT_HANDOFF') 'PASS' 'B14: M05 PASS'
    Assert-Equal (Get-FxToken $r 'M06_VERIFICATION') 'READY' 'B14: M06 READY'
}

# B15 verification done -> external PASS, M06 PASS, M07 READY
function Test-B15-VerificationDone {
    $ev = New-FxEv -NodeId 'M-07-0.2' -PreflightClear $true -ReservationDone $true -HandoffDone $true `
        -VerificationDone $true -VerificationPrimaryResult 'VERIFICATION_PASSED'
    $r = Resolve-DbM30StageTokens -Ev $ev
    Assert-Equal $r.CurrentStage.StageKey 'M07_REVIEW_PACKAGE' 'B15: current stage M07'
    Assert-Equal $r.CurrentStage.Token 'READY' 'B15: M07 READY'
    Assert-Equal (Get-FxToken $r 'M06_VERIFICATION') 'PASS' 'B15: M06 PASS'
    Assert-Equal (Get-FxToken $r 'EXTERNAL_IMPLEMENTATION') 'PASS' 'B15: external PASS'
}

# B16 package done -> M07 PASS, Claude decision HUMAN_ACTION
function Test-B16-PackageDone {
    $ev = New-FxEv -NodeId 'M-07-0.2' -PreflightClear $true -ReservationDone $true -HandoffDone $true `
        -VerificationDone $true -VerificationPrimaryResult 'VERIFICATION_PASSED' -PackageDone $true
    $r = Resolve-DbM30StageTokens -Ev $ev
    Assert-Equal $r.CurrentStage.StageKey 'M08_CLAUDE_DECISION' 'B16: current stage M08'
    Assert-Equal $r.CurrentStage.Token 'HUMAN_ACTION' 'B16: M08 HUMAN_ACTION'
    Assert-Equal (Get-FxToken $r 'M07_REVIEW_PACKAGE') 'PASS' 'B16: M07 PASS'
}

# B17 claude decision PASS (trial) -> M08 PASS; git + completion NOT_APPLICABLE
function Test-B17-ClaudeDecisionPass {
    $ev = New-FxEv -NodeId 'M-07-0.2' -PreflightClear $true -ReservationDone $true -HandoffDone $true `
        -VerificationDone $true -VerificationPrimaryResult 'VERIFICATION_PASSED' -PackageDone $true `
        -ClaudeDecisionDone $true -ClaudeDecision 'PASS'
    $r = Resolve-DbM30StageTokens -Ev $ev
    Assert-Equal (Get-FxToken $r 'M08_CLAUDE_DECISION') 'PASS' 'B17: M08 PASS'
    Assert-Equal (Get-FxToken $r 'CORRECTION_LOOP') 'NOT_APPLICABLE' 'B17: correction NOT_APPLICABLE'
    Assert-Equal (Get-FxToken $r 'HUMAN_GIT_GATE') 'NOT_APPLICABLE' 'B17: human git gate NOT_APPLICABLE (trial)'
    Assert-Equal (Get-FxToken $r 'GOVERNED_COMPLETION') 'NOT_APPLICABLE' 'B17: governed completion NOT_APPLICABLE (trial)'
    Assert-Equal $r.CurrentStage.StageKey 'GOVERNED_COMPLETION' 'B17: terminal current stage'
    Assert-Equal $r.CurrentStage.Token 'NOT_APPLICABLE' 'B17: terminal token NOT_APPLICABLE'
}

# B18 claude decision FIX -> correction HUMAN_ACTION; corrected -> PASS
function Test-B18-CorrectionFix {
    $ev1 = New-FxEv -NodeId 'M-07-0.2' -PreflightClear $true -ReservationDone $true -HandoffDone $true `
        -VerificationDone $true -VerificationPrimaryResult 'VERIFICATION_PASSED' -PackageDone $true `
        -ClaudeDecisionDone $true -ClaudeDecision 'FIX' -CorrectionNeeded $true
    $r1 = Resolve-DbM30StageTokens -Ev $ev1
    Assert-Equal $r1.CurrentStage.StageKey 'CORRECTION_LOOP' 'B18a: current stage correction loop'
    Assert-Equal $r1.CurrentStage.Token 'HUMAN_ACTION' 'B18a: correction HUMAN_ACTION'

    $ev2 = New-FxEv -NodeId 'M-07-0.2' -PreflightClear $true -ReservationDone $true -HandoffDone $true `
        -VerificationDone $true -VerificationPrimaryResult 'VERIFICATION_PASSED' -PackageDone $true `
        -ClaudeDecisionDone $true -ClaudeDecision 'FIX' -CorrectionNeeded $true -CorrectionDone $true
    $r2 = Resolve-DbM30StageTokens -Ev $ev2
    Assert-Equal (Get-FxToken $r2 'CORRECTION_LOOP') 'PASS' 'B18b: correction PASS when verified'
    Assert-Equal $r2.CurrentStage.StageKey 'GOVERNED_COMPLETION' 'B18b: terminal after correction'
}

# C19 dependency-context card AVAILABLE when a governed task is selected
function Test-C19-DependencyContextPresent {
    $fx = New-FxWorkspace
    $cat = @{
        'M-07-0.2' = @{ taskId = 'M-07-0.2'; dependencies = @(@{ dependencyId = 'M-05-0.1'; state = 'UNKNOWN' }) }
        'M-05-0.1' = @{ taskId = 'M-05-0.1'; dependencies = @() }
    }
    $view = Get-DbM30WorkflowView -StateDir $fx.State -EvidenceRoot $fx.Evidence -TaskCatalog $cat -NowUtc $script:NowUtc
    Assert-Equal $view.StateSource 'FIXTURE' 'C19: fixture state source recognized'
    $c = $view.Cards.DependencyContext
    Assert-Equal $c.CardStatus 'AVAILABLE' 'C19: dependency card AVAILABLE'
    Assert-True $c.Available 'C19: dependency card available flag'
    Assert-Equal $c.DirectDependencyCount 1 'C19: one direct dependency'
    Assert-True (-not [string]::IsNullOrWhiteSpace($c.FreshnessStatus)) 'C19: freshness reported'
    $leak = Test-DbM30SecretLeak $view
    Assert-True (-not $leak.Leak) 'C19: view has no secret leak'
}

# C20 dependency-context card NOT_AVAILABLE when no task is selected
function Test-C20-DependencyContextAbsent {
    $fx = New-FxWorkspace -Empty
    $view = Get-DbM30WorkflowView -StateDir $fx.State -EvidenceRoot $fx.Evidence -TaskCatalog @{} -NowUtc $script:NowUtc
    $c = $view.Cards.DependencyContext
    Assert-Equal $c.CardStatus 'NOT_AVAILABLE' 'C20: dependency card NOT_AVAILABLE when no task'
    Assert-Contains $c.Note 'No current task' 'C20: honest note'
    Assert-Equal $view.CurrentStage.StageKey 'GOVERNED_TASK' 'C20: current stage governed task'
}

# C21 routing card truthfully NOT_ENABLED while the live gate is closed
function Test-C21-RoutingDisabled {
    $card = Resolve-DbM30RoutingCard -Root $script:Root -NowUtc $script:NowUtc
    Assert-Equal $card.CardStatus 'NOT_ENABLED' 'C21: routing gate closed -> NOT_ENABLED'
    Assert-Equal $card.PolicyEnabled $false 'C21: policy not enabled'
    Assert-Contains $card.Note 'routingDefaults.enabled' 'C21: note names the gate'
}

# C22 routing card enabled path (synthetic catalogue + real router) -> recommendation
function Test-C22-RoutingEnabled {
    $fxRoot = Join-Path $script:TempRoot ('fxroute-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path (Join-Path $fxRoot 'config'), (Join-Path $fxRoot 'scripts\ai-routing\router') | Out-Null
    Set-FxJson (Join-Path $fxRoot 'config\ai-routing.json') @{ routingDefaults = @{ enabled = $true } }
    # placeholder: the REAL Router.ps1 is preloaded by the harness, so the card's
    # lazy-load check (Test-Path) passes and its Get-Command check skips the dot-source.
    [System.IO.File]::WriteAllText((Join-Path $fxRoot 'scripts\ai-routing\router\Router.ps1'),
        '# fixture placeholder; real Router.ps1 is preloaded by the DB-M30 harness',
        (New-Object System.Text.UTF8Encoding($false)))

    $config = New-StandardCatalogue
    $policy = Get-DefaultRoutingPolicy
    $request = New-TestRequest -TaskId 'T-M30'
    $health = @{ 'prov-a' = 'AVAILABLE' }
    $card = Resolve-DbM30RoutingCard -Root $fxRoot -Configuration $config -RoutingPolicy $policy `
        -RoutingRequest $request -RoutingProviderHealth $health -NowUtc $script:NowUtc
    Assert-Equal $card.CardStatus 'AVAILABLE' 'C22: routing enabled path -> AVAILABLE'
    Assert-True $card.Available 'C22: available flag'
    Assert-Equal $card.WinnerProviderId 'prov-a' 'C22: winner provider prov-a'
    Assert-True (-not [string]::IsNullOrWhiteSpace($card.WinnerModelId)) 'C22: winner model present'
    Assert-True ($card.EligibleCandidateCount -ge 1) 'C22: at least one eligible candidate'
    Assert-True ($card.WinnerEligible) 'C22: winner flagged eligible'
    $leak = Test-DbM30SecretLeak $card
    Assert-True (-not $leak.Leak) 'C22: routing card no secret leak'
}

# C23 cost-guidance card AVAILABLE with a real estimate + informational budget
function Test-C23-CostGuidance {
    $card = Resolve-DbM30CostGuidanceCard -Root $script:Root `
        -DefaultProviderId 'deepseek' -DefaultModelId 'deepseek-v4-flash' -RouteType 'DIRECT' -ReasoningLevel 'MEDIUM' `
        -TargetCurrency 'INR' -NowUtc $script:NowUtc -InputTokens 5000 -OutputTokens 1500
    Assert-Equal $card.CardStatus 'AVAILABLE' 'C23: cost card AVAILABLE'
    Assert-True $card.Available 'C23: available flag'
    Assert-NotNull $card.EstimatedCost 'C23: estimate present'
    Assert-In $card.EstimateSource @('ESTIMATED','ACTUAL') 'C23: estimate source in vocab'
    Assert-Equal $card.AttemptCount 0 'C23: no attempts supplied'
    Assert-Contains $card.BudgetNote 'budget' 'C23: budget informational note'
    $leak = Test-DbM30SecretLeak $card
    Assert-True (-not $leak.Leak) 'C23: cost card no secret leak'
}

# C24 provider-health card honest EMPTY when no evidence exists
function Test-C24-ProviderHealthEmpty {
    $card = Resolve-DbM30ProviderHealthCard -Root $script:Root -ProviderHealthState @() -DefaultProviderId 'deepseek' -NowUtc $script:NowUtc
    Assert-Equal $card.CardStatus 'EMPTY' 'C24: health card EMPTY'
    Assert-True (-not $card.Available) 'C24: not available when empty'
    Assert-Contains $card.Note 'No provider-health evidence' 'C24: honest empty note'
}

# C25 history card honest empty state + empty-console HTML emission (no secrets)
function Test-C25-HistoryEmpty {
    $card = Resolve-DbM30HistoryCard -Root $script:Root -AttemptRecords @() -NodeId '' -NowUtc $script:NowUtc -ReportingCurrency 'INR'
    Assert-Equal $card.CardStatus 'EMPTY' 'C25: history card EMPTY'
    Assert-True $card.Empty 'C25: empty flag'
    Assert-Equal $card.Count 0 'C25: count 0'

    $fx = New-FxWorkspace -Empty
    $view = Get-DbM30WorkflowView -StateDir $fx.State -EvidenceRoot $fx.Evidence -TaskCatalog @{} -NowUtc $script:NowUtc
    $html = ConvertTo-DbM30Html -View $view
    Assert-True ($html.Length -gt 3000) 'C25: HTML substantial'
    Assert-Contains $html '<!DOCTYPE html>' 'C25: doctype present'
    Assert-Contains $html 'DevBridge Supervised Development Workflow' 'C25: page title present'
    Assert-Contains $html 'AutoExecutionEnabled=False' 'C25: read-only guard footer present'
    Assert-Contains $html '13 stages' 'C25: pipeline table header present'
    $leak = Test-DbM30SecretLeak $view
    Assert-True (-not $leak.Leak) 'C25: empty view no secret leak'
    $leakH = Test-DbM30SecretLeak $html
    Assert-True (-not $leakH.Leak) 'C25: rendered HTML no secret leak'

    $tmp = Join-Path $script:TempRoot 'dbm30-c25.html'
    $written = Export-DbM30WorkflowHtml -View $view -OutputPath $tmp
    Assert-NotNull $written 'C25: export returns a path'
    Assert-True ((Test-Path $tmp) -and ((Get-Item $tmp).Length -gt 3000)) 'C25: exported artifact written'
    $bytes = [System.IO.File]::ReadAllBytes($tmp)
    Assert-True ($bytes.Length -ge 3 -and -not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'C25: export is UTF-8 without BOM'
    $leakE = Test-DbM30SecretLeak ([System.IO.File]::ReadAllText($tmp))
    Assert-True (-not $leakE.Leak) 'C25: exported HTML no secret leak'
}

# C26 history card populated fixture -> AVAILABLE drilldown + populated HTML
function Test-C26-HistoryPopulated {
    $recs = @(
        (New-Att -TaskId 'T-M30' -NodeId 'N-M30' -ChangeId 'CHG-M30' -AttemptId 'ATT-M30-1' -RetryNumber 0 `
            -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -UnderlyingModelId 'deepseek-v4-flash' `
            -Result 'FAILED' -FailureCategory 'MODEL_QUALITY' `
            -ActualCost 1.25 -EstimatedCost 1.25 `
            -StartedAtUtc '2026-08-31T10:00:00Z' -EndedAtUtc '2026-08-31T10:00:20Z' -DurationMs 20000 -InputTokens 4000 -OutputTokens 1200),
        (New-Att -TaskId 'T-M30' -NodeId 'N-M30' -ChangeId 'CHG-M30' -AttemptId 'ATT-M30-2' -RetryNumber 1 `
            -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' -UnderlyingModelId 'deepseek-v4-flash' `
            -Result 'SUCCESS' -VerificationResult 'VERIFIED' `
            -ActualCost 3 -EstimatedCost 3 `
            -StartedAtUtc '2026-08-31T10:01:00Z' -EndedAtUtc '2026-08-31T10:01:40Z' -DurationMs 40000 -InputTokens 6000 -OutputTokens 2000)
    )
    $card = Resolve-DbM30HistoryCard -Root $script:Root -AttemptRecords $recs -NodeId 'T-M30' -NowUtc $script:NowUtc -ReportingCurrency 'INR'
    Assert-Equal $card.CardStatus 'AVAILABLE' 'C26: history card AVAILABLE'
    Assert-True $card.Available 'C26: available flag'
    Assert-Equal $card.Count 2 'C26: two records'
    Assert-True (-not $card.Empty) 'C26: not empty'
    Assert-True ($card.TaskRowCount -ge 1) 'C26: task rows rendered'
    Assert-True $card.DashboardAvailable 'C26: dashboard view available'
    Assert-True $card.HistoryViewAvailable 'C26: history drilldown available'

    $fx = New-FxWorkspace -Empty
    $view = Get-DbM30WorkflowView -StateDir $fx.State -EvidenceRoot $fx.Evidence -TaskCatalog @{} `
        -AttemptRecords $recs -NowUtc $script:NowUtc
    $html = ConvertTo-DbM30Html -View $view
    Assert-True ($html.Length -gt 3000) 'C26: HTML substantial'
    Assert-Contains $html 'AVAILABLE' 'C26: history status AVAILABLE in HTML'
    $leak = Test-DbM30SecretLeak $view
    Assert-True (-not $leak.Leak) 'C26: populated view no secret leak'
    $leakH = Test-DbM30SecretLeak $html
    Assert-True (-not $leakH.Leak) 'C26: populated HTML no secret leak'
}

# D27 lifecycle state byte-identical across the run
function Test-D27-LifecycleStateUnmodified {
    Assert-True ($script:StateFiles.Count -gt 0) 'D27: lifecycle state files enumerated'
    foreach ($f in $script:StateFiles) {
        $now = Get-Sha256 $f.FullName
        Assert-True ($now -eq $script:StateShasBefore[$f.FullName]) "D27: lifecycle state unchanged: $($f.Name)"
    }
}

# D28 attempt store untouched (absent today; presence must not change)
function Test-D28-AttemptStoreUnmodified {
    Assert-True (-not $script:AttemptStorePresentBefore) 'D28: live attempt store was absent before the run'
    Assert-Equal (Test-Path -LiteralPath $script:AttemptStorePath) $script:AttemptStorePresentBefore 'D28: attempt store presence unchanged'
}

# D29 routing/config files byte-identical
function Test-D29-ConfigUnmodified {
    foreach ($rel in $script:ConfigFiles) {
        Assert-NotNull $script:CfgShasBefore[$rel] "D29: config reachable: $rel"
        $now = Get-Sha256 (Join-Path $script:Root $rel)
        Assert-True ($now -eq $script:CfgShasBefore[$rel]) "D29: config unchanged: $rel"
    }
}

# D30 canonical workbook byte-identical
function Test-D30-WorkbookByteIdentical {
    $now = Get-Sha256 $script:WorkbookPath
    Assert-True ($now -eq $script:WorkbookShaBefore) 'D30: workbook byte-identical'
    Assert-Contains $now '6D42C3BF' 'D30: workbook SHA matches the live post-DB-M12.4 state'
    foreach ($rel in $script:FrozenFiles | Select-Object -First 4) {
        $text = Get-Content (Join-Path $script:Root $rel) -Raw
        Assert-NotContains $text 'NEXUS_DEVELOPMENT_CONTROL.xlsx' "D30: no workbook path in library ($rel)"
    }
}

# D31 Nexus source untouched (git status unchanged)
function Test-D31-NexusSourceUnmodified {
    $now = Get-NexusGitStatus
    Assert-True ($now -eq $script:NexusStatusBefore) 'D31: Nexus repo status unchanged'
    Assert-True ($now -ne 'GIT_UNAVAILABLE') 'D31: Nexus git status readable'
}

# R32 regression: DB-M29 suite green + frozen files byte-identical
function Test-R32-DbM29Regression {
    $r = Invoke-RegressionSuite -Name 'DBM29' -Path 'scripts\ai-routing\task-history\Test-DbM29TaskHistory.ps1'
    $script:RegressionResults.Add($r)
    Assert-True ($r.ExitCode -eq 0) "R32: DBM29 exit 0 (got $($r.ExitCode))"
    Assert-True ($r.Passed -gt 0) "R32: DBM29 assertions ran (got $($r.Passed))"
    Assert-True ($r.Failed -eq 0) "R32: DBM29 0 failures (got $($r.Failed))"
}

# R33 regression: DB-M26 suite preserves its known external S41 drift
function Test-R33-DbM26Regression {
    $r = Invoke-RegressionSuite -Name 'DBM26' -Path 'scripts\ai-routing\dashboard\Test-DbM26Dashboard.ps1'
    $script:RegressionResults.Add($r)
    Assert-Equal $r.Passed 381 'R33: DBM26 still 381 passed'
    Assert-Equal $r.Failed 1 'R33: DBM26 still exactly 1 failed (external S41)'
    Assert-Contains $r.Log 'S41' 'R33: the single failure is S41'
    Assert-Contains $r.Log 'F520060C' 'R33: S41 names the recorded authority hash'
    $script:ExternalDrift.Add('M26 S41 workbook-authority drift (suite records F520060C; live workbook is 6D42C3BF after DB-M12.4 closure)')
}

# R34 regression: DB-M28 model-config suite green
function Test-R34-DbM28Regression {
    $r = Invoke-RegressionSuite -Name 'DBM28' -Path 'scripts\ai-routing\model-config\Test-DbM28ModelConfig.ps1'
    $script:RegressionResults.Add($r)
    Assert-True ($r.ExitCode -eq 0) "R34: DBM28 exit 0 (got $($r.ExitCode))"
    Assert-True ($r.Passed -gt 0) "R34: DBM28 assertions ran (got $($r.Passed))"
    Assert-True ($r.Failed -eq 0) "R34: DBM28 0 failures (got $($r.Failed))"
}

# R35 regression: DB-M18.1 suite preserves its known external R45 drift
function Test-R35-DbM181Regression {
    $r = Invoke-RegressionSuite -Name 'DBM181' -Path 'scripts\ai-routing\Test-DbM181DependencyLineage.ps1'
    $script:RegressionResults.Add($r)
    Assert-True ($r.Passed -gt 0) "R35: DBM18.1 assertions ran (got $($r.Passed))"
    Assert-Equal $r.Failed 1 'R35: DBM18.1 still exactly 1 failed (external R45)'
    Assert-Contains $r.Log 'R45' 'R35: the single failure is R45'
    $script:ExternalDrift.Add('DB-M18.1 R45 external drift (child DB-M18 regression exits non-zero)')
}

# R36 solution build 0 errors / 0 warnings (result cached for I39)
function Test-R36-Build {
    $sln = Join-Path $script:Root 'src\DevBridge.slnx'
    Assert-True (Test-Path $sln) 'R36: solution present'
    if (-not (Test-Path $sln)) { return }
    $log = Join-Path $script:TempRoot 'dbm30-build.log'
    & dotnet build $sln --nologo > $log 2>&1
    $exit = $LASTEXITCODE
    $text = if (Test-Path $log) { [System.IO.File]::ReadAllText($log) } else { '' }
    $script:BuildResult = @{ Exit = $exit; Text = $text }
    Assert-True ($exit -eq 0) "R36: dotnet build exit 0 (got $exit)"
    $errTokens = ([regex]::Matches($text, 'error\s+CS\d+')).Count
    Assert-True ($errTokens -eq 0) "R36: build has 0 error CS tokens (got $errTokens)"
    Assert-Contains $text '0 Error' 'R36: build summary shows 0 errors'
    $warnTokens = ([regex]::Matches($text, 'warning\s+CS\d+')).Count
    Assert-True ($warnTokens -eq 0) "R36: build has 0 warning CS tokens (got $warnTokens)"
}

# I37 workbook-hash invariant + frozen files byte-identical (after all regressions)
function Test-I37-WorkbookHashInvariant {
    $sha = Get-Sha256 $script:WorkbookPath
    Assert-Contains $sha '6D42C3BF6D3307B4B1A45870CE12F41E403DFED412E59F33D7B487E93A83E4F5' 'I37: workbook hash matches the recorded live hash'
    foreach ($rel in $script:FrozenFiles) {
        Assert-NotNull $script:FrozenShasBefore[$rel] "I37: frozen file reachable: $rel"
        $after = Get-Sha256 (Join-Path $script:Root $rel)
        Assert-True ($after -eq $script:FrozenShasBefore[$rel]) "I37: frozen file unchanged: $rel"
    }
}

# I38 Nexus repo status unchanged + the live view is honest over Nexus state
function Test-I38-NexusStatusAndLiveView {
    $now = Get-NexusGitStatus
    Assert-True ($now -eq $script:NexusStatusBefore) 'I38: Nexus repo status unchanged'

    $view = Get-DbM30WorkflowView -NowUtc $script:NowUtc
    Assert-Equal $view.StateSource 'LIVE' 'I38: live view reads the live state dir'
    Assert-Equal $view.LifecycleSnapshot.Task.NodeId 'M-07-0.2' 'I38: live current task node'
    Assert-Equal $view.CurrentStage.StageKey 'M03_SELECTION' 'I38: live current stage M03'
    Assert-Equal $view.CurrentStage.Token 'BLOCKED' 'I38: live current token BLOCKED'
    Assert-Contains $view.CurrentStage.Note 'governance' 'I38: governance note present'
    Assert-Equal $view.Cards.RoutingRecommendation.CardStatus 'NOT_ENABLED' 'I38: live routing NOT_ENABLED'
    Assert-Equal $view.Cards.DependencyContext.CardStatus 'AVAILABLE' 'I38: live dependency context AVAILABLE'
    Assert-Equal $view.Cards.ProviderHealth.CardStatus 'EMPTY' 'I38: live provider health EMPTY'
    Assert-Equal $view.Cards.History.CardStatus 'EMPTY' 'I38: live history EMPTY (honest empty store)'
    Assert-Equal $view.ReadOnlyGuard.AutoExecutionEnabled $false 'I38: live view auto execution disabled'
    $leak = Test-DbM30SecretLeak $view
    Assert-True (-not $leak.Leak) 'I38: live view no secret leak'
}

# I39 solution build re-assert (result cached by R36)
function Test-I39-BuildReassert {
    Assert-NotNull $script:BuildResult 'I39: build result cached from R36'
    if ($null -eq $script:BuildResult) { return }
    Assert-True ($script:BuildResult.Exit -eq 0) 'I39: solution build exit 0'
    Assert-Contains $script:BuildResult.Text '0 Error' 'I39: build summary 0 errors'
}

# --- scenario registry + runner -----------------------------------------------------

$script:Scenarios = @(
    'Test-A1-StageCatalog', 'Test-A2-Vocab', 'Test-A3-CardStatuses', 'Test-A4-CatalogOrder',
    'Test-A5-CatalogFields', 'Test-A6-ArrayNormalization', 'Test-A7-ReadOnlyGuard',
    'Test-A8-Markers', 'Test-A9-SecretLeak',
    'Test-B10-NoTask', 'Test-B11-PreflightClear', 'Test-B12-PreflightBlocked',
    'Test-B13-Reserved', 'Test-B14-HandoffDone', 'Test-B15-VerificationDone',
    'Test-B16-PackageDone', 'Test-B17-ClaudeDecisionPass', 'Test-B18-CorrectionFix',
    'Test-C19-DependencyContextPresent', 'Test-C20-DependencyContextAbsent',
    'Test-C21-RoutingDisabled', 'Test-C22-RoutingEnabled', 'Test-C23-CostGuidance',
    'Test-C24-ProviderHealthEmpty', 'Test-C25-HistoryEmpty', 'Test-C26-HistoryPopulated',
    'Test-D27-LifecycleStateUnmodified', 'Test-D28-AttemptStoreUnmodified',
    'Test-D29-ConfigUnmodified', 'Test-D30-WorkbookByteIdentical',
    'Test-D31-NexusSourceUnmodified',
    'Test-R32-DbM29Regression', 'Test-R33-DbM26Regression', 'Test-R34-DbM28Regression',
    'Test-R35-DbM181Regression', 'Test-R36-Build',
    'Test-I37-WorkbookHashInvariant', 'Test-I38-NexusStatusAndLiveView', 'Test-I39-BuildReassert'
)

foreach ($scenario in $script:Scenarios) {
    try { & $scenario } catch { $script:ScenarioFails.Add("${scenario} threw: $($_.Exception.Message)") }
}

$script:Passed = $script:TestCount - $script:TestFails.Count
Write-Host "DB-M30 TEST SUMMARY: $($script:Passed) passed, $($script:TestFails.Count) failed"
Write-Host "DB-M30 SCENARIOS: $($script:Scenarios.Count) scenarios"
foreach ($r in $script:RegressionResults) {
    Write-Host ("DB-M30 REGRESSION {0}: {1} passed, {2} failed, exit {3}" -f $r.Name, $r.Passed, $r.Failed, $r.ExitCode)
}
foreach ($d in $script:ExternalDrift) { Write-Host "DB-M30 EXTERNAL DRIFT: $d" }
foreach ($f in $script:TestFails) { Write-Host "  FAIL: $f" }
foreach ($f in $script:ScenarioFails) { Write-Host "  SCENARIO FAIL: $f" }

if ($script:TestFails.Count -eq 0 -and $script:ScenarioFails.Count -eq 0) {
    Write-Host 'DB-M30: ALL PASS'
    exit 0
}
exit 1
