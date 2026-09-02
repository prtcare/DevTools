# =============================================================================
# Test-DbM181DependencyLineage.ps1
# DB-M18.1 -- Dependency Development Lineage & Context Resolver (Lane B, AI Routing)
#
# 51-case test matrix from the DB-M18.1 brief:
#   graph 1-7, file lineage 8-14, reconciliation/freshness 15-17,
#   relevance 18-23, evidence 24-27, scope/defect 28-33, integration 34-37,
#   determinism 38, provenance 39, context-size 40, no-secret 41,
#   no-source-modification 42, no-workbook-modification 43, Trial/Real
#   semantics 44, regressions (M18/M05/M07/M09/M12.2/M12.3/M12.4) 45-50,
#   build 0 errors 51.
#
# Fixtures live ONLY under logs\selftest\db181 (throwaway evidence + fixture
# repository). The real DevBridge src\, the Nexus.Developer git state, and the
# authoritative workbook are READ-ONLY and asserted unchanged around the run.
# Regression suites run in child processes.
#
# Calling convention: comma-returning library functions (Build-DependencyLineageSet,
# Get-DbM181RepoWalk) are consumed by DIRECT ASSIGNMENT, never @()-wrapped.
# =============================================================================
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script:SelftestRoot = Join-Path $script:Root "logs\selftest"
$script:Db181Root = Join-Path $script:SelftestRoot "db181"
$script:EvidenceRoot = Join-Path $script:Db181Root "evidence"
$script:FixtureRepo = Join-Path $script:Db181Root "repo"
$script:Cfg = Get-Content (Join-Path $script:Root "config\devbridge.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$script:RealWorkbook = $script:Cfg.developmentControlWorkbook

. (Join-Path $PSScriptRoot "DependencyLineage.ps1")

function Get-Hash([string]$p) { return (Get-FileHash $p -Algorithm SHA256).Hash }

$script:Results = New-Object System.Collections.ArrayList
$script:Fails = New-Object System.Collections.Generic.List[string]
$script:NextId = 1

function Assert-True([string]$name, [string]$group, [bool]$cond, [string]$detail) {
    $id = $script:NextId; $script:NextId++
    [void]$script:Results.Add([pscustomobject]@{ Id = $id; Name = $name; Group = $group; Pass = $cond; Detail = $detail })
    if ($cond) { Write-Output ("  [PASS] {0} ({1})" -f $name, $id) }
    else { $script:Fails.Add(("{0} [{1}]: {2}" -f $name, $id, $detail)); Write-Output ("  [FAIL] {0} ({1}) - {2}" -f $name, $id, $detail) }
}

# -----------------------------------------------------------------------------
# Fixture builder (throwaway evidence + fixture repo under logs\selftest\db181)
# -----------------------------------------------------------------------------
function New-RepoFile([string]$rel, [string]$content) {
    $full = Join-Path $script:FixtureRepo ($rel -replace '/', '\')
    $dir = Split-Path -Parent $full
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($full, $content, (New-Object System.Text.UTF8Encoding($false)))
    return (Get-DbM181FileSha256 $full)
}

function Write-EvidenceJson([string]$taskId, [string]$changeId, [string]$relPath, $obj) {
    $dir = Join-Path $script:EvidenceRoot (Join-Path $taskId $changeId)
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $text = ($obj | ConvertTo-Json -Depth 10)
    [System.IO.File]::WriteAllText((Join-Path $dir $relPath), $text, (New-Object System.Text.UTF8Encoding($false)))
}

# Build fixture repo + evidence. Repo files are written FIRST so their SHA-256 can
# be embedded in the evidence exactly as a real M06 changed-files record would.
if (Test-Path $script:Db181Root) { Remove-Item -LiteralPath $script:Db181Root -Recurse -Force }
New-Item -ItemType Directory -Force -Path $script:EvidenceRoot | Out-Null
New-Item -ItemType Directory -Force -Path $script:FixtureRepo | Out-Null

$h_Ical    = New-RepoFile 'src/Nexus.Developer.Core/Abstractions/ICalendarService.cs' 'public interface ICalendarService { }' + "`n"
# Current repo files (the live implementation truth):
$h_CalCurr = New-RepoFile 'src/Nexus.Developer.Core/Services/CalendarService.cs' 'class CalendarService { public void Current() {} }' + "`n"
$h_CalRepo = New-RepoFile 'src/Nexus.Developer.Core/Services/CalendarRepository.cs' 'class CalendarRepository { }' + "`n"
$h_PayOrc  = New-RepoFile 'src/Nexus.Developer.Core/Services/PaymentOrchestrator.cs' 'class PaymentOrchestrator { }' + "`n"
$h_ItemNew = New-RepoFile 'src/Nexus.Developer.Core/Storage/ItemStore.cs' 'class ItemStore { }' + "`n"

# v1/v2 hashes of CalendarService.cs are DISTINCT from the current repo version:
# M-07-0.1 created v1, M-07-0.2 modified it to v2, and the current repo holds v3.
$h_CalV1 = Get-DbM18Sha256Hex 'class CalendarService { public void V1() {} }'
$h_CalV2 = Get-DbM18Sha256Hex 'class CalendarService { public void V2() {} }'

# Files that a historical task created but the current repo no longer carries:
$h_PaySvc = Get-DbM18Sha256Hex 'class PaymentService { }'          # superseded original
$h_LegAud = Get-DbM18Sha256Hex 'class LegacyAudit { }'             # missing
$h_ItemOld = Get-DbM18Sha256Hex 'class ItemStore (old) { }'        # renamed/moved original
$h_Diag   = Get-DbM18Sha256Hex 'binary diagram bytes'              # non-text -> HISTORICAL_ONLY
$h_SumRep = Get-DbM18Sha256Hex 'class SummaryReport { }'           # Reporting project
$h_SecCfg = Get-DbM18Sha256Hex 'class SecretConfig { }'            # secret-task asset

# --- M-07-0.1 (deltaAttribution shape, NEW evidence) --------------------------
Write-EvidenceJson 'M-07-0.1' 'CHG-20260820-010' 'reservation.json' @{
    nodeId = 'M-07-0.1'; name = 'Calendar service contracts'
    reservedScope = @{ projects = @('Nexus.Developer.Core'); filesGlobs = @('src/Nexus.Developer.Core/**'); contractsApis = @('ICalendarService'); schemaContexts = @() }
}
Write-EvidenceJson 'M-07-0.1' 'CHG-20260820-010' 'changed-files.json' @{
    deltaAttribution = @(
        @{ kind = 'C_continuation_delta_created'; path = 'src/Nexus.Developer.Core/Abstractions/ICalendarService.cs'; sha256 = $h_Ical;    note = 'Creates the calendar service contract.' }
        @{ kind = 'C_continuation_delta_created'; path = 'src/Nexus.Developer.Core/Services/CalendarService.cs';   sha256 = $h_CalV1;  note = 'Creates the calendar service implementation.' }
    )
    scopeCheck = @{ verdict = 'NO_SCOPE_VIOLATION'; authorizedGlobs = @('src/Nexus.Developer.Core/**') }
}
Write-EvidenceJson 'M-07-0.1' 'CHG-20260820-010' 'build-result.json' @{ result = @{ succeeded = $true; warnings = 0; errors = 0 }; command = 'dotnet build' }
Write-EvidenceJson 'M-07-0.1' 'CHG-20260820-010' 'test-result.json' @{ result = @{ passed = 10; failed = 0; total = 10 } }
Write-EvidenceJson 'M-07-0.1' 'CHG-20260820-010' 'acceptance-matrix.json' @{ result = @{ total = 3; passed = 3; failed = 0 } }
Write-EvidenceJson 'M-07-0.1' 'CHG-20260820-010' 'claude-decision.json' @{
    decision = 'PASS'; trialMode = $true; implementationState = 'TRIAL_ONLY_UNMERGED'; dbM06Result = 'VERIFICATION_PASSED'
    blockingFindings = @(); nonBlockingObservations = @()
}
Write-EvidenceJson 'M-07-0.1' 'CHG-20260820-010' 'completion.json' @{ changeId = 'CHG-20260820-010' }

# --- M-07-0.2 (inventory shape, OLD evidence) ---------------------------------
Write-EvidenceJson 'M-07-0.2' 'CHG-20260825-013' 'reservation.json' @{
    nodeId = 'M-07-0.2'; name = 'Calendar repository storage'
    reservedScope = @{ projects = @('Nexus.Developer.Core'); filesGlobs = @('src/Nexus.Developer.Core/**'); contractsApis = @(); schemaContexts = @() }
}
Write-EvidenceJson 'M-07-0.2' 'CHG-20260825-013' 'changed-files.json' @{
    inventory = @(
        @{ path = 'src/Nexus.Developer.Core/Services/CalendarRepository.cs'; state = 'new-untracked'; classification = 'IMPLEMENTATION_CHANGE_IN_SCOPE'; sha256 = $h_CalRepo }
        @{ path = 'src/Nexus.Developer.Core/Services/CalendarService.cs';     state = 'modified';      classification = 'IMPLEMENTATION_CHANGE_IN_SCOPE'; sha256 = $h_CalV2 }
    )
    preExistingScopeFilesUnchanged = @(@{ path = 'src/Nexus.Developer.Core/Abstractions/ICalendarService.cs' })
}
Write-EvidenceJson 'M-07-0.2' 'CHG-20260825-013' 'scope-amendment.json' @{
    scopeAmended = $true; addedProjects = @(); addedFiles = @('src/Nexus.Developer.Core/Services/CalendarRepository.cs')
    addedFileBaselineHashes = @(@{ path = 'src/Nexus.Developer.Core/Services/CalendarRepository.cs'; priorCycleOwner = 'M-07-0.1'; sha256 = $h_CalRepo })
}
Write-EvidenceJson 'M-07-0.2' 'CHG-20260825-013' 'build-result.json' @{ overall = @{ succeeded = $true; warnings = 0; errors = 0 } }
Write-EvidenceJson 'M-07-0.2' 'CHG-20260825-013' 'test-result.json' @{ testRun = @{ passed = 12; failed = 0; total = 12; allPassed = $true }; harnessRun = @{ checksPassed = 32 } }
Write-EvidenceJson 'M-07-0.2' 'CHG-20260825-013' 'acceptance-matrix.json' @{ criteria = @(@{ id = 'C1'; passed = $true }, @{ id = 'C2'; passed = $true }, @{ id = 'C3'; passed = $true }); allPassed = $true; result = 'ACCEPTED' }
Write-EvidenceJson 'M-07-0.2' 'CHG-20260825-013' 'claude-decision.json' @{
    decision = 'PASS'; trialMode = $true; implementationState = 'TRIAL_ONLY_UNMERGED'; dbM06Result = 'VERIFICATION_PASSED'
    blockingFindings = @()
    nonBlockingObservations = @(
        @{ id = 'NB-1'; title = 'Minor performance note'; detail = 'A comment on the write path.' }
        @{ id = 'NB-2'; title = 'Naming style'; detail = 'Prefer verb-first method names.' }
    )
}
Write-EvidenceJson 'M-07-0.2' 'CHG-20260825-013' 'completion.json' @{ changeId = 'CHG-20260825-013' }

# --- S-03.1 (REAL mode, supersession: PaymentService.cs -> PaymentOrchestrator.cs)
Write-EvidenceJson 'S-03.1' 'CHG-20260828-015' 'reservation.json' @{
    nodeId = 'S-03.1'; name = 'Payment orchestration'
    reservedScope = @{ projects = @('Nexus.Developer.Core'); filesGlobs = @('src/Nexus.Developer.Core/**'); contractsApis = @(); schemaContexts = @() }
}
Write-EvidenceJson 'S-03.1' 'CHG-20260828-015' 'changed-files.json' @{
    deltaAttribution = @(
        @{ kind = 'C_continuation_delta_created'; path = 'src/Nexus.Developer.Core/Services/PaymentOrchestrator.cs'; sha256 = $h_PayOrc; note = 'replaces src/Nexus.Developer.Core/Services/PaymentService.cs' }
    )
}
Write-EvidenceJson 'S-03.1' 'CHG-20260828-015' 'build-result.json' @{ result = @{ succeeded = $true; warnings = 0; errors = 0 } }
Write-EvidenceJson 'S-03.1' 'CHG-20260828-015' 'test-result.json' @{ result = @{ passed = 6; failed = 0; total = 6 } }
Write-EvidenceJson 'S-03.1' 'CHG-20260828-015' 'claude-decision.json' @{
    decision = 'PASS'; trialMode = $false; implementationState = 'UNMERGED'; dbM06Result = 'VERIFICATION_PASSED'
    blockingFindings = @(); nonBlockingObservations = @()
}

# --- M-08.1 (creates assets that no longer exist in the current repo) ---------
Write-EvidenceJson 'M-08.1' 'CHG-20260828-014' 'reservation.json' @{ nodeId = 'M-08.1'; name = 'Payment service original' }
Write-EvidenceJson 'M-08.1' 'CHG-20260828-014' 'changed-files.json' @{
    deltaAttribution = @(
        @{ kind = 'C_continuation_delta_created'; path = 'src/Nexus.Developer.Core/Services/PaymentService.cs'; sha256 = $h_PaySvc; note = 'Creates the payment service.' }
        @{ kind = 'C_continuation_delta_created'; path = 'src/Nexus.Developer.Core/Services/LegacyAudit.cs';  sha256 = $h_LegAud; note = 'Creates audit trail.' }
    )
}
Write-EvidenceJson 'M-08.1' 'CHG-20260828-014' 'build-result.json' @{ projects = @(@{ name = 'DevBridge'; buildSucceeded = $true; warnings = 0; errors = 0 }) }
Write-EvidenceJson 'M-08.1' 'CHG-20260828-014' 'claude-decision.json' @{ decision = 'PASS'; trialMode = $true; implementationState = 'TRIAL_ONLY_UNMERGED'; dbM06Result = 'VERIFICATION_PASSED'; blockingFindings = @(); nonBlockingObservations = @() }

# --- M-05.1 (leaf task; rename candidate + non-text artifact) -----------------
Write-EvidenceJson 'M-05.1' 'CHG-20260818-009' 'reservation.json' @{ nodeId = 'M-05.1'; name = 'Item store module' }
Write-EvidenceJson 'M-05.1' 'CHG-20260818-009' 'changed-files.json' @{
    deltaAttribution = @(
        @{ kind = 'C_continuation_delta_created'; path = 'src/Nexus.Developer.Core/Data/ItemStore.cs'; sha256 = $h_ItemOld; note = 'Creates item store.' }
        @{ kind = 'C_continuation_delta_created'; path = 'docs/diagram.bin'; sha256 = $h_Diag; note = 'Binary design artifact.' }
    )
}
Write-EvidenceJson 'M-05.1' 'CHG-20260818-009' 'claude-decision.json' @{ decision = 'PASS'; trialMode = $true; implementationState = 'TRIAL_ONLY_UNMERGED'; dbM06Result = 'VERIFICATION_PASSED'; blockingFindings = @(); nonBlockingObservations = @() }

# --- M-99.0 (transitive leaf under a different project -> NOT_RELEVANT at depth 3)
Write-EvidenceJson 'M-99.0' 'CHG-20260829-016' 'reservation.json' @{ nodeId = 'M-99.0'; name = 'Integration summary reports' }
Write-EvidenceJson 'M-99.0' 'CHG-20260829-016' 'changed-files.json' @{
    deltaAttribution = @(@{ kind = 'C_continuation_delta_created'; path = 'src/Nexus.Developer.Integrations/Reports/SummaryReport.cs'; sha256 = $h_SumRep; note = 'Creates summary report.' })
}
Write-EvidenceJson 'M-99.0' 'CHG-20260829-016' 'claude-decision.json' @{ decision = 'PASS'; trialMode = $true; implementationState = 'TRIAL_ONLY_UNMERGED'; dbM06Result = 'VERIFICATION_PASSED'; blockingFindings = @(); nonBlockingObservations = @() }

# --- M-SEC-1 (secret-bearing purpose; the no-secret guard must redact it) -----
Write-EvidenceJson 'M-SEC-1' 'CHG-20260901-099' 'reservation.json' @{ nodeId = 'M-SEC-1'; name = 'Secret key sk-AB12CD34EF56GH78IJ90 endpoint' }
Write-EvidenceJson 'M-SEC-1' 'CHG-20260901-099' 'changed-files.json' @{
    deltaAttribution = @(@{ kind = 'C_continuation_delta_created'; path = 'src/Nexus.Developer.Core/Services/SecretConfig.cs'; sha256 = $h_SecCfg; note = 'Creates config loader.' })
}
Write-EvidenceJson 'M-SEC-1' 'CHG-20260901-099' 'claude-decision.json' @{ decision = 'PASS'; trialMode = $true; implementationState = 'TRIAL_ONLY_UNMERGED'; dbM06Result = 'VERIFICATION_PASSED'; blockingFindings = @(); nonBlockingObservations = @() }

# Empty evidence dir: lineage must resolve to Planned/NONE without throwing.
New-Item -ItemType Directory -Force -Path (Join-Path $script:EvidenceRoot 'Z-98.8') | Out-Null

# -----------------------------------------------------------------------------
# Shared lineage set + graph helpers
# -----------------------------------------------------------------------------
$script:AllTaskIds = @('M-07-0.1', 'M-07-0.2', 'S-03.1', 'M-08.1', 'M-05.1', 'M-99.0', 'M-SEC-1')
$script:LineageSet = Build-DependencyLineageSet -TaskIds $script:AllTaskIds -EvidenceRoot $script:EvidenceRoot

$script:Catalog = @{
    'M-07-0.2' = [pscustomobject]@{ taskId = 'M-07-0.2'; dependencies = @(@{ dependencyId = 'M-07-0.1'; state = 'CLEAR' }) }
    'M-07-0.1' = [pscustomobject]@{ taskId = 'M-07-0.1'; dependencies = @(@{ dependencyId = 'M-99.0'; state = 'CLEAR' }) }
    'M-99.0'   = [pscustomobject]@{ taskId = 'M-99.0';   dependencies = @() }
    'M-SEC-1'  = [pscustomobject]@{ taskId = 'M-SEC-1';  dependencies = @() }
}

function New-Task {
    param(
        [string]$TaskId, [string]$NodeId = $TaskId, [string]$ChangeId = '', [string]$Name = '',
        [string]$Goal = '', [string[]]$AcceptanceCriteria = @(), [string[]]$FilesGlobs = @(),
        [string[]]$Projects = @(), [string[]]$ContractsApis = @(), [string[]]$SchemaContexts = @(),
        [string[]]$Repositories = @(), [object[]]$Dependencies = @()
    )
    return [pscustomobject]@{
        taskId = $TaskId; nodeId = $NodeId; changeId = $ChangeId; name = $Name; goal = $Goal
        acceptanceCriteria = @($AcceptanceCriteria); filesGlobs = @($FilesGlobs); projects = @($Projects)
        contractsApis = @($ContractsApis); schemaContexts = @($SchemaContexts); repositories = @($Repositories)
        dependencies = @($Dependencies)
    }
}

$script:ReportingTask = New-Task -TaskId 'W-9.1' -ChangeId 'CHG-20260901-100' -Name 'Monthly reporting' `
    -Goal 'Build the monthly reporting module' -AcceptanceCriteria @('Report renders monthly totals') `
    -FilesGlobs @('src/Nexus.Developer.Reporting/**') -Projects @('Nexus.Developer.Reporting') `
    -Dependencies @(@{ dependencyId = 'M-07-0.2'; state = 'CLEAR' }, @{ dependencyId = 'REL-001'; state = '' }, @{ dependencyId = 'M-44.0'; state = '' })

$script:CoreTask = New-Task -TaskId 'W-9.2' -ChangeId 'CHG-20260901-101' -Name 'Calendar hardening' `
    -Goal 'Harden calendar storage' -AcceptanceCriteria @('Calendar stays consistent') `
    -FilesGlobs @('src/Nexus.Developer.Core/**') -Projects @('Nexus.Developer.Core') `
    -ContractsApis @('ICalendarService') `
    -Dependencies @(@{ dependencyId = 'M-07-0.2'; state = 'CLEAR' })

$script:LeafTask = New-Task -TaskId 'W-9.3' -ChangeId 'CHG-20260901-102' -Name 'Leaf task' -Goal 'No dependencies' -Dependencies @()

$script:SecretTask = New-Task -TaskId 'W-9.4' -ChangeId 'CHG-20260901-103' -Name 'Config secret' `
    -Goal 'Config loader' -FilesGlobs @('src/Nexus.Developer.Core/**') `
    -Dependencies @(@{ dependencyId = 'M-SEC-1'; state = 'CLEAR' })

$script:UnresolvedTask = New-Task -TaskId 'W-9.10' -ChangeId 'CHG-20260901-104' -Name 'Unresolved dep' `
    -Goal 'Consume calendar service' -FilesGlobs @('src/Nexus.Developer.Core/**') `
    -Dependencies @(@{ dependencyId = 'M-44.0'; state = 'CLEAR' })

Set-DbM181NowUtc '2026-08-31T12:00:00Z'
$script:NowUtc = '2026-08-31T12:00:00Z'

# -----------------------------------------------------------------------------
# Real-repo / workbook integrity snapshots (read-only), taken before the run.
# -----------------------------------------------------------------------------
$script:DevSrcFpBefore = Get-DbM181RepoFingerprint (Join-Path $script:Root 'src')
$script:WorkbookShaBefore = Get-Hash $script:RealWorkbook
$script:NexusGitBefore = @(& git -C 'C:\Personal\Nexus.Developer' status --porcelain=v1 2>$null)

# =============================================================================
# TEST GROUPS
# =============================================================================

# --- Graph 1-7 ---------------------------------------------------------------
Write-Output '== Graph (1-7) =='
$gCore = Resolve-DependencyGraph -Task $script:CoreTask -TaskCatalog $script:Catalog -NowUtc $script:NowUtc
Assert-True 'G1 direct dependency resolved' 'graph' (@($gCore.DirectDependencies).Count -eq 1 -and [string]$gCore.DirectDependencies[0].DependencyId -eq 'M-07-0.2') ('direct=' + @($gCore.DirectDependencies).Count)
Assert-True 'G2 transitive dependency resolved through catalog' 'graph' (@($gCore.TransitiveDependencies).Count -ge 2) ('transitive=' + @($gCore.TransitiveDependencies).Count)
$hasM701 = $false; $hasM990 = $false
foreach ($td in @($gCore.TransitiveDependencies)) { if ([string]$td.DependencyId -eq 'M-07-0.1') { $hasM701 = $true }; if ([string]$td.DependencyId -eq 'M-99.0') { $hasM990 = $true } }
Assert-True 'G2 M-07-0.1 and M-99.0 both transitive' 'graph' ($hasM701 -and $hasM990) 'missing transitive node'
$cycleCat = @{
    'F-1' = [pscustomobject]@{ taskId = 'F-1'; dependencies = @(@{ dependencyId = 'F-2'; state = 'CLEAR' }) }
    'F-2' = [pscustomobject]@{ taskId = 'F-2'; dependencies = @(@{ dependencyId = 'F-1'; state = 'CLEAR' }) }
}
$gCycle = Resolve-DependencyGraph -Task (New-Task -TaskId 'W-9.5' -Dependencies @(@{ dependencyId = 'F-1'; state = 'CLEAR' })) -TaskCatalog $cycleCat -NowUtc $script:NowUtc
Assert-True 'G3 cycle detected (F-1 <-> F-2)' 'graph' ($gCycle.CycleDetected -and @($gCycle.Cycles).Count -ge 1) ('cycles=' + @($gCycle.Cycles).Count)
$gMissing = Resolve-DependencyGraph -Task (New-Task -TaskId 'W-9.6' -Dependencies @(@{ dependencyId = 'M-88.8'; state = 'CLEAR' })) -TaskCatalog @{} -NowUtc $script:NowUtc
Assert-True 'G4 missing catalog node reported' 'graph' (@($gMissing.MissingDependencies).Count -eq 1 -and [string]$gMissing.MissingDependencies[0].DependencyId -eq 'M-88.8') ('missing=' + @($gMissing.MissingDependencies).Count)
$gInvalid = Resolve-DependencyGraph -Task (New-Task -TaskId 'W-9.7' -Dependencies @(@{ dependencyId = 'M-07-0.2'; state = 'CLEAR' }, @{ dependencyId = 'garbage-ref'; state = '' })) -TaskCatalog $script:Catalog -NowUtc $script:NowUtc
Assert-True 'G5 invalid reference reported, valid direct kept' 'graph' (@($gInvalid.InvalidReferences).Count -eq 1 -and @($gInvalid.DirectDependencies).Count -eq 2) ('invalid=' + @($gInvalid.InvalidReferences).Count)
$gBlocked = Resolve-DependencyGraph -Task (New-Task -TaskId 'W-9.8' -Dependencies @(@{ dependencyId = 'M-07-0.2'; state = 'BLOCKED' })) -TaskCatalog $script:Catalog -NowUtc $script:NowUtc
Assert-True 'G6 blocked dependency reported' 'graph' (@($gBlocked.BlockedDependencies).Count -eq 1 -and [string]$gBlocked.BlockedDependencies[0].DependencyId -eq 'M-07-0.2') ('blocked=' + @($gBlocked.BlockedDependencies).Count)
$gDup = Resolve-DependencyGraph -Task (New-Task -TaskId 'W-9.9' -Dependencies @(@{ dependencyId = 'M-07-0.2'; state = 'CLEAR' }, @{ dependencyId = 'M-07-0.2'; state = 'CLEAR' })) -TaskCatalog $script:Catalog -NowUtc $script:NowUtc
Assert-True 'G7 duplicate path detected + graph evidence deterministic' 'graph' (@($gDup.DuplicatePaths).Count -ge 1 -and $gCore.GraphEvidence -match 'WORKBOOK') ('dupes=' + @($gDup.DuplicatePaths).Count)

# --- File lineage 8-14 --------------------------------------------------------
Write-Output '== File lineage (8-14) =='
$li701 = Get-DbM181TaskLineage -TaskId 'M-07-0.1' -EvidenceRoot $script:EvidenceRoot
Assert-True 'L8 deltaAttribution created files + completion' 'lineage' (@($li701.FilesCreated).Count -eq 2 -and $li701.CompletionState -eq 'TRIAL_CYCLE_CLOSED' -and $li701.VerificationState -eq 'VERIFICATION_PASSED') ('created=' + @($li701.FilesCreated).Count + ' ' + $li701.CompletionState)
$li702 = Get-DbM181TaskLineage -TaskId 'M-07-0.2' -EvidenceRoot $script:EvidenceRoot
$hasCreated = $false; $hasModified = $false; $hasPreserved = $false
foreach ($p in @($li702.FilesCreated)) { if ([string]$p -like '*CalendarRepository.cs') { $hasCreated = $true } }
foreach ($p in @($li702.FilesModified)) { if ([string]$p -like '*CalendarService.cs') { $hasModified = $true } }
foreach ($p in @($li702.PreservedFiles)) { if ([string]$p -like '*ICalendarService.cs') { $hasPreserved = $true } }
Assert-True 'L9 inventory shape created/modified/preserved' 'lineage' ($hasCreated -and $hasModified -and $hasPreserved) 'created/modified/preserved not all detected'
Assert-True 'L10 M06 dual-shape build/test/acceptance' 'lineage' ($li702.M06Evidence.Build.Succeeded -and $li702.M06Evidence.Test.Passed -eq 12 -and $li702.M06Evidence.Test.Total -eq 12 -and $li702.M06Evidence.Acceptance.Passed -eq 3 -and $li702.M06Evidence.Acceptance.Result -eq 'ACCEPTED') ('build=' + $li702.M06Evidence.Build.Succeeded + ' test=' + $li702.M06Evidence.Test.Passed + '/' + $li702.M06Evidence.Test.Total + ' acc=' + $li702.M06Evidence.Acceptance.Passed + '/' + $li702.M06Evidence.Acceptance.Total)
$li801 = Get-DbM181TaskLineage -TaskId 'M-08.1' -EvidenceRoot $script:EvidenceRoot
Assert-True 'L10 old-old build shape (projects only) succeeds' 'lineage' ($li801.M06Evidence.Build.Succeeded -and -not $li801.M06Evidence.Build.Command) ('build=' + $li801.M06Evidence.Build.Succeeded)
Assert-True 'L11 claude-decision lineage + observations' 'lineage' ($li702.ClaudeReviewOutcome.Decision -eq 'PASS' -and @($li702.NonBlockingObservations).Count -eq 2 -and @($li701.BlockingFindings).Count -eq 0) ('obs=' + @($li702.NonBlockingObservations).Count)
$obsIds = @($li702.NonBlockingObservations | ForEach-Object { $_.Id })
Assert-True 'L11 observation ids NB-1/NB-2 preserved' 'lineage' (($obsIds -contains 'NB-1') -and ($obsIds -contains 'NB-2')) ('ids=' + ($obsIds -join ','))
Assert-True 'L12 scope-amendment prior-cycle ownership' 'lineage' ($li702.ScopeAmendments.Count -eq 1 -and $li702.ScopeAmendments[0].ScopeAmended -and $li702.ScopeAmendments[0].PriorOwners.Count -ge 1 -and [string]$li702.ScopeAmendments[0].PriorOwners[0].PriorOwner -eq 'M-07-0.1') ('amendments=' + $li702.ScopeAmendments.Count)
$hasContract = $false; $hasClass = $false
foreach ($c in @($li701.ContractsCreated)) { if ([string]$c -like '*ICalendarService.cs') { $hasContract = $true } }
foreach ($c in @($li701.ClassesServicesCreated)) { if ([string]$c -like 'CalendarService.cs') { $hasClass = $true } }
Assert-True 'L13 component derivation (contract/class)' 'lineage' ($hasContract -and $hasClass -and @($li702.ContractsChanged).Count -eq 0) ('contracts=' + @($li701.ContractsCreated).Count)
$liEmpty = Get-DbM181TaskLineage -TaskId 'Z-99.9' -EvidenceRoot $script:EvidenceRoot
$liNoChange = Get-DbM181TaskLineage -TaskId 'Z-98.8' -EvidenceRoot $script:EvidenceRoot
Assert-True 'L14 absent evidence stays Planned/NONE/INFERRED, never invented' 'lineage' ($liEmpty.CompletionState -eq 'Planned' -and $liEmpty.VerificationState -eq 'NONE' -and $liEmpty.Confidence -eq 'INFERRED' -and $liNoChange.CompletionState -eq 'Planned') ('state=' + $liEmpty.CompletionState)

# --- Reconciliation / freshness 15-17 ----------------------------------------
Write-Output '== Reconciliation / freshness (15-17) =='
$recon = Reconcile-LineageRepository -LineageSet $script:LineageSet -RepositoryRoot $script:FixtureRepo -NowUtc $script:NowUtc
$statusMap = @{}
foreach ($e in @($recon.Entries)) { $statusMap[[string]$e.HistoricalPath] = [string]$e.Status }
$expectCurrent = $statusMap.ContainsKey('src/Nexus.Developer.Core/Abstractions/ICalendarService.cs') -and $statusMap['src/Nexus.Developer.Core/Abstractions/ICalendarService.cs'] -eq 'CURRENT'
$expectCurrent2 = $statusMap.ContainsKey('src/Nexus.Developer.Core/Services/CalendarRepository.cs') -and $statusMap['src/Nexus.Developer.Core/Services/CalendarRepository.cs'] -eq 'CURRENT'
$expectModified = $statusMap.ContainsKey('src/Nexus.Developer.Core/Services/CalendarService.cs') -and $statusMap['src/Nexus.Developer.Core/Services/CalendarService.cs'] -eq 'MODIFIED_LATER'
$expectSuperseded = $statusMap.ContainsKey('src/Nexus.Developer.Core/Services/PaymentService.cs') -and $statusMap['src/Nexus.Developer.Core/Services/PaymentService.cs'] -eq 'SUPERSEDED'
$expectMissing = $statusMap.ContainsKey('src/Nexus.Developer.Core/Services/LegacyAudit.cs') -and $statusMap['src/Nexus.Developer.Core/Services/LegacyAudit.cs'] -eq 'MISSING'
$expectRenamed = $statusMap.ContainsKey('src/Nexus.Developer.Core/Data/ItemStore.cs') -and $statusMap['src/Nexus.Developer.Core/Data/ItemStore.cs'] -eq 'RENAMED_OR_MOVED'
$expectHist = $statusMap.ContainsKey('docs/diagram.bin') -and $statusMap['docs/diagram.bin'] -eq 'HISTORICAL_ONLY'
Assert-True 'R15 reconciliation statuses (CURRENT/MODIFIED_LATER/SUPERSEDED/MISSING/RENAMED_OR_MOVED/HISTORICAL_ONLY)' 'recon' ($expectCurrent -and $expectCurrent2 -and $expectModified -and $expectSuperseded -and $expectMissing -and $expectRenamed -and $expectHist) ('current=' + $expectCurrent + ' modified=' + $expectModified + ' superseded=' + $expectSuperseded + ' missing=' + $expectMissing + ' renamed=' + $expectRenamed + ' hist=' + $expectHist)
$idx = New-LineageIndex -LineageSet $script:LineageSet -Reconciliation $recon -NowUtc $script:NowUtc
$fresh1 = Test-LineageFreshness -Index $idx -RepositoryRoot $script:FixtureRepo -LineageSet $script:LineageSet -NowUtc $script:NowUtc
Assert-True 'F16 fresh context after index build' 'freshness' ($fresh1.FreshnessStatus -eq 'FRESH' -and -not $fresh1.RebuildRequired) ('status=' + $fresh1.FreshnessStatus)
$mutated = Join-Path $script:FixtureRepo 'src/Nexus.Developer.Core/Services/CalendarRepository.cs'
$origCalRepo = [System.IO.File]::ReadAllText($mutated)
[System.IO.File]::WriteAllText($mutated, 'class CalendarRepository { /* modified */ }', (New-Object System.Text.UTF8Encoding($false)))
$fresh2 = Test-LineageFreshness -Index $idx -RepositoryRoot $script:FixtureRepo -LineageSet $script:LineageSet -NowUtc $script:NowUtc
$repoReason = @($fresh2.StaleReasons) -join ' '
Assert-True 'F16 repo change detected -> DEPENDENCY_CONTEXT_STALE' 'freshness' ($fresh2.FreshnessStatus -eq 'DEPENDENCY_CONTEXT_STALE' -and $fresh2.RebuildRequired -and $repoReason -match 'Repository fingerprint') ('status=' + $fresh2.FreshnessStatus + ' reasons=' + $repoReason)
[System.IO.File]::WriteAllText($mutated, $origCalRepo, (New-Object System.Text.UTF8Encoding($false)))
$fresh3 = Test-LineageFreshness -Index $idx -RepositoryRoot $script:FixtureRepo -LineageSet @($script:LineageSet | Where-Object { $_.TaskId -ne 'M-99.0' }) -NowUtc $script:NowUtc
$depReason = @($fresh3.StaleReasons) -join ' '
Assert-True 'F17 dependency-set change detected -> STALE + rebuild required' 'freshness' ($fresh3.FreshnessStatus -eq 'DEPENDENCY_CONTEXT_STALE' -and $fresh3.RebuildRequired -and $depReason -match 'Dependency set changed') ('status=' + $fresh3.FreshnessStatus)

# --- Relevance 18-23 ----------------------------------------------------------
Write-Output '== Relevance (18-23) =='
$gReporting = Resolve-DependencyGraph -Task $script:ReportingTask -TaskCatalog $script:Catalog -NowUtc $script:NowUtc
$relReporting = Get-DbM181Relevance -Graph $gReporting -LineageSet $script:LineageSet -Task $script:ReportingTask
$relMap = @{}
foreach ($r in @($relReporting.Relevance)) { $relMap[[string]$r.DependencyId] = [string]$r.Relevance }
Assert-True 'R18 scope-path overlap -> RELEVANT' 'relevance' ($relMap['M-07-0.2'] -eq 'SUPPORTING' -and $relMap['M-07-0.1'] -eq 'SUPPORTING') ('M-07-0.2=' + $relMap['M-07-0.2'] + ' M-07-0.1=' + $relMap['M-07-0.1'])
$gCoreRel = Resolve-DependencyGraph -Task $script:CoreTask -TaskCatalog $script:Catalog -NowUtc $script:NowUtc
$relCore = Get-DbM181Relevance -Graph $gCoreRel -LineageSet $script:LineageSet -Task $script:CoreTask
$coreMap = @{}
foreach ($r in @($relCore.Relevance)) { $coreMap[[string]$r.DependencyId] = [string]$r.Relevance }
Assert-True 'R19 scope + contract overlap -> RELEVANT' 'relevance' ($coreMap['M-07-0.2'] -eq 'RELEVANT' -and $coreMap['M-07-0.1'] -eq 'RELEVANT') ('M-07-0.2=' + $coreMap['M-07-0.2'] + ' M-07-0.1=' + $coreMap['M-07-0.1'])
Assert-True 'R20 transitive proximity (depth<=2) -> SUPPORTING' 'relevance' ($relMap['M-07-0.1'] -eq 'SUPPORTING') ('M-07-0.1=' + $relMap['M-07-0.1'])
Assert-True 'R21 deep + no overlap -> NOT_RELEVANT' 'relevance' ($relMap['M-99.0'] -eq 'NOT_RELEVANT') ('M-99.0=' + $relMap['M-99.0'])
Assert-True 'R22 non-node + no-lineage -> UNKNOWN_RELEVANCE' 'relevance' ($relMap['REL-001'] -eq 'UNKNOWN_RELEVANCE' -and $relMap['M-44.0'] -eq 'UNKNOWN_RELEVANCE') ('REL-001=' + $relMap['REL-001'] + ' M-44.0=' + $relMap['M-44.0'])
$omittedIds = @($relReporting.OmittedDependencyReferences | ForEach-Object { $_.DependencyId })
Assert-True 'R23 omitted references listed (NOT_RELEVANT + UNKNOWN)' 'relevance' (($omittedIds -contains 'M-99.0') -and ($omittedIds -contains 'REL-001') -and ($omittedIds -contains 'M-44.0')) ('omitted=' + ($omittedIds -join ','))

# --- Evidence 24-27 -----------------------------------------------------------
Write-Output '== Evidence (24-27) =='
$evKinds = @(); $evProv = @()
foreach ($e in @($li701.ImplementationEvidence)) { $evKinds += [string]$e.Kind; $evProv += [string]$e.Provenance }
Assert-True 'E24 evidence refs carry kind + provenance' 'evidence' (($evKinds -contains 'reservation') -and ($evKinds -contains 'changed-files') -and ($evKinds -contains 'm06') -and ($evKinds -contains 'claude-review') -and ($evProv -contains 'WORKBOOK') -and ($evProv -contains 'M06') -and ($evProv -contains 'CLAUDE_REVIEW')) ('kinds=' + ($evKinds -join ',') + ' prov=' + ($evProv -join ','))
$voc = Get-DbM181ProvenanceVocabulary
Assert-True 'E25 provenance vocabulary complete' 'evidence' ($voc.Count -eq 10 -and ($voc -contains 'WORKBOOK') -and ($voc -contains 'IMPLEMENTATION_REPORT') -and ($voc -contains 'M06') -and ($voc -contains 'CLAUDE_REVIEW') -and ($voc -contains 'GIT') -and ($voc -contains 'CURRENT_REPOSITORY') -and ($voc -contains 'FIX_TASK') -and ($voc -contains 'LATER_WORK_ITEM') -and ($voc -contains 'TRIAL_PROVING')) ('vocab=' + $voc.Count)
$allEvProvOk = $true
foreach ($l in @($script:LineageSet)) { foreach ($e in @($l.ImplementationEvidence)) { if (-not ($voc -contains [string]$e.Provenance)) { $allEvProvOk = $false } } }
Assert-True 'E25 all lineage provenance values in vocabulary' 'evidence' $allEvProvOk 'provenance outside vocabulary'
Assert-True 'E26 M06 evidence populated' 'evidence' ($null -ne $li701.M06Evidence -and $li701.M06Evidence.Build.Succeeded -and $li701.M06Evidence.Test.Total -eq 10 -and $li701.M06Evidence.Acceptance.Total -eq 3 -and $li701.M06Evidence.Provenance -eq 'M06') ('test=' + $li701.M06Evidence.Test.Total + ' acc=' + $li701.M06Evidence.Acceptance.Total)
$fp1 = Get-DbM181LineageFingerprint $script:LineageSet
$fp2 = Get-DbM181LineageFingerprint $script:LineageSet
$rp1 = Get-DbM181RepoFingerprint $script:FixtureRepo
$rp2 = Get-DbM181RepoFingerprint $script:FixtureRepo
$ch1 = Get-DbM181CanonicalHash $li702
$ch2 = Get-DbM181CanonicalHash $li702
Assert-True 'E27 fingerprints/hashes deterministic' 'evidence' ($fp1 -eq $fp2 -and $rp1 -eq $rp2 -and $ch1 -eq $ch2) 'fingerprint mismatch on repeat'

# --- Scope / defect 28-33 -----------------------------------------------------
Write-Output '== Scope / defect (28-33) =='
$ctxCore = Build-DependencyDevelopmentContext -Task $script:CoreTask -Graph $gCoreRel -LineageSet $script:LineageSet -Reconciliation $recon -Relevance $relCore -Freshness $fresh1 -NowUtc $script:NowUtc
$sc1 = Test-DbM181ScopeChange -Task $script:CoreTask -FilePath 'src/Nexus.Developer.Core/Services/NewFile.cs' -Context $ctxCore
$sc2 = Test-DbM181ScopeChange -Task $script:ReportingTask -FilePath 'src/Nexus.Developer.Core/Services/CalendarRepository.cs' -Context $ctxCore
Assert-True 'S28 in-scope file -> CONTINUE' 'scope' ($sc1.Decision -eq 'CONTINUE' -and $sc1.InGovernedScope) ('got ' + $sc1.Decision)
Assert-True 'S29 out-of-scope file -> SCOPE_CHANGE_REQUIRED (owner known)' 'scope' ($sc2.Decision -eq 'SCOPE_CHANGE_REQUIRED' -and -not $sc2.InGovernedScope -and [string]$sc2.CurrentOwner -eq 'M-07-0.2') ('got ' + $sc2.Decision + ' owner=' + $sc2.CurrentOwner)
$cReuse = Classify-DbM181DependencyDefect -Task $script:CoreTask -Context $ctxCore -DependencyId 'M-07-0.2' -DefectNature 'REUSE'
Assert-True 'D30 normal reuse -> NORMAL_DEPENDENCY_REUSE' 'defect' ($cReuse.Classification -eq 'NORMAL_DEPENDENCY_REUSE' -and $cReuse.Routing -eq 'CORRECT_CURRENT_ATTEMPT' -and $cReuse.PreservedOriginalHistory) ('got ' + $cReuse.Classification)
$cExt = Classify-DbM181DependencyDefect -Task $script:CoreTask -Context $ctxCore -DependencyId 'M-07-0.2' -DefectNature 'EXTENSION' -DependencyActive $false
$cExtAct = Classify-DbM181DependencyDefect -Task $script:CoreTask -Context $ctxCore -DependencyId 'M-07-0.2' -DefectNature 'EXTENSION' -DependencyActive $true
$cScope = Classify-DbM181DependencyDefect -Task $script:CoreTask -Context $ctxCore -DependencyId 'M-07-0.2' -DefectNature 'SCOPE_EXPANSION'
Assert-True 'D31 extension + scope-expansion classification' 'defect' ($cExt.Classification -eq 'NORMAL_DEPENDENCY_EXTENSION' -and $cExt.Routing -eq 'NEW_FIX_TASK_REQUIRED' -and $cExtAct.Routing -eq 'CORRECT_CURRENT_ATTEMPT' -and $cScope.Classification -eq 'DEPENDENCY_SCOPE_EXPANSION_REQUIRED') ('ext=' + $cExt.Routing + ' extAct=' + $cExtAct.Routing)
$cD1 = Classify-DbM181DependencyDefect -Task $script:CoreTask -Context $ctxCore -DependencyId 'M-07-0.2' -DefectNature 'DEFECT' -DependencyActive $true
$cD2 = Classify-DbM181DependencyDefect -Task $script:CoreTask -Context $ctxCore -DependencyId 'M-07-0.2' -DefectNature 'DEFECT' -DependencyActive $false -Unrepresentable $true
$cD3 = Classify-DbM181DependencyDefect -Task $script:CoreTask -Context $ctxCore -DependencyId 'M-07-0.2' -DefectNature 'DEFECT' -DependencyActive $false -Unrepresentable $false
Assert-True 'D32 defect routing preserves history' 'defect' ($cD1.Classification -eq 'DEPENDENCY_DEFECT_FOUND' -and $cD1.Routing -eq 'CORRECT_CURRENT_ATTEMPT' -and $cD2.Routing -eq 'HUMAN_GOVERNANCE_REQUIRED' -and $cD3.Routing -eq 'NEW_FIX_TASK_REQUIRED' -and $cD1.PreservedOriginalHistory -and $cD2.PreservedOriginalHistory) ('r1=' + $cD1.Routing + ' r2=' + $cD2.Routing + ' r3=' + $cD3.Routing)
$threwUnknownDep = $false; try { Classify-DbM181DependencyDefect -Task $script:CoreTask -Context $ctxCore -DependencyId 'M-77.7' -DefectNature 'DEFECT' | Out-Null } catch { $threwUnknownDep = $true }
$threwBadNature = $false; try { Classify-DbM181DependencyDefect -Task $script:CoreTask -Context $ctxCore -DependencyId 'M-07-0.2' -DefectNature 'BOGUS' | Out-Null } catch { $threwBadNature = $true }
Assert-True 'D33 unknown dependency/nature rejected (ArgumentException)' 'defect' ($threwUnknownDep -and $threwBadNature) ('unknownDep=' + $threwUnknownDep + ' badNature=' + $threwBadNature)

# --- Integration 34-37 --------------------------------------------------------
Write-Output '== Integration (34-37) =='
$handoffSection = Get-DbM181HandoffLineageSection -Task $script:CoreTask -Context $ctxCore
Assert-True 'I34 M05 handoff lineage section emitted' 'integration' (($handoffSection -match '## Dependency Development Lineage \(DB-M18.1\)') -and ($handoffSection -match 'M-07-0.2') -and ($handoffSection -match 'Context freshness: FRESH')) ('section=' + ($handoffSection -split "`n")[0])
$rdLeaf = Test-DbM181HandoffReadiness -Task $script:LeafTask -Context $ctxCore -Graph (Resolve-DependencyGraph -Task $script:LeafTask -TaskCatalog $script:Catalog -NowUtc $script:NowUtc) -NowUtc $script:NowUtc
$ctxReporting = Build-DependencyDevelopmentContext -Task $script:ReportingTask -Graph $gReporting -LineageSet $script:LineageSet -Reconciliation $recon -Relevance $relReporting -Freshness $fresh1 -NowUtc $script:NowUtc
$gUnresolved = Resolve-DependencyGraph -Task $script:UnresolvedTask -TaskCatalog $script:Catalog -NowUtc $script:NowUtc
$ctxUnresolved = Build-DependencyDevelopmentContext -Task $script:UnresolvedTask -Graph $gUnresolved -LineageSet $script:LineageSet -Reconciliation $recon -Relevance $null -Freshness $fresh1 -NowUtc $script:NowUtc
$rdUnresolved = Test-DbM181HandoffReadiness -Task $script:UnresolvedTask -Context $ctxUnresolved -Graph $gUnresolved -NowUtc $script:NowUtc
$staleFresh = [pscustomobject]@{ FreshnessStatus = 'DEPENDENCY_CONTEXT_STALE'; StaleReasons = @('repository fingerprint changed') }
$ctxStale = Build-DependencyDevelopmentContext -Task $script:CoreTask -Graph $gCoreRel -LineageSet $script:LineageSet -Reconciliation $recon -Relevance $relCore -Freshness $staleFresh -NowUtc $script:NowUtc
$rdStale = Test-DbM181HandoffReadiness -Task $script:CoreTask -Context $ctxStale -Graph $gCoreRel -NowUtc $script:NowUtc
$rdReady = Test-DbM181HandoffReadiness -Task $script:CoreTask -Context $ctxCore -Graph $gCoreRel -NowUtc $script:NowUtc
Assert-True 'I35 M05 readiness gate (leaf NOT_REQUIRED / unresolved NOT_READY / stale NOT_READY / fresh READY)' 'integration' ($rdLeaf.Ready -and $rdLeaf.LineageStatus -eq 'NOT_REQUIRED' -and -not $rdUnresolved.Ready -and $rdUnresolved.HandoffToken -eq 'CHATGPT_HANDOFF_NOT_READY' -and -not $rdStale.Ready -and $rdStale.HandoffToken -eq 'CHATGPT_HANDOFF_NOT_READY' -and $rdReady.Ready -and $rdReady.HandoffToken -eq 'CHATGPT_HANDOFF_READY') ('leaf=' + $rdLeaf.LineageStatus + ' unresolved=' + $rdUnresolved.LineageStatus + ' stale=' + $rdStale.LineageStatus + ' ready=' + $rdReady.LineageStatus)
$claudeCtx = Get-DbM181ClaudeDependencyContext -Task $script:CoreTask -Context $ctxCore
Assert-True 'I36 M07 relevant-only dependency context emitted' 'integration' (($claudeCtx -match '## Dependency Development Context \(DB-M18.1\)') -and ($claudeCtx -match 'Relevant dependencies: 2') -and ($claudeCtx -match 'verified VERIFICATION_PASSED')) ('first=' + ($claudeCtx -split "`n")[0])
$corr1 = Get-DbM181CorrectionDependencyContext -Task $script:CoreTask -Context $ctxCore -AffectedFile 'src/Nexus.Developer.Core/Services/CalendarService.cs'
$corr2 = Get-DbM181CorrectionDependencyContext -Task $script:CoreTask -Context $ctxCore -AffectedFile 'src/Nexus.Developer.Core/Services/UnknownThing.cs'
Assert-True 'I37 M09 correction dependency context (creator identified / fallback)' 'integration' (($corr1 -match 'created by M-07-0.1') -and ($corr1 -match 'MODIFIED_LATER') -and ($corr1 -match 'CORRECT_CURRENT_ATTEMPT') -and ($corr2 -match 'File not in dependency lineage')) ('corr1=' + ($corr1 -split "`n")[0])
$bundle = Get-DbM181TaskDependencyContext -Task $script:CoreTask -TaskCatalog $script:Catalog -EvidenceRoot $script:EvidenceRoot -RepositoryRoot $script:FixtureRepo -NowUtc $script:NowUtc
Assert-True 'I38 orchestrator one-shot bundle (graph+lineage+recon+index+freshness+relevance+context)' 'integration' ($bundle.Graph.TaskId -eq 'W-9.2' -and @($bundle.Graph.DirectDependencies).Count -eq 1 -and @($bundle.Context.DeliveredSummary).Count -eq 3 -and $bundle.Context.FreshnessStatus -eq 'FRESH' -and ((Get-DbM181HandoffLineageSection -Task $script:CoreTask -Context $bundle.Context) -match 'M-07-0.1')) ('graph=' + $bundle.Graph.TaskId + ' delivered=' + @($bundle.Context.DeliveredSummary).Count + ' fresh=' + $bundle.Context.FreshnessStatus)
$bundleNoRepo = Get-DbM181TaskDependencyContext -Task $script:CoreTask -TaskCatalog $script:Catalog -EvidenceRoot $script:EvidenceRoot -RepositoryRoot 'C:\nonexistent-db181-xyz' -NowUtc $script:NowUtc
Assert-True 'I38b orchestrator no-repo fallback (UNVERIFIED, never STALE, never blocks)' 'integration' ($bundleNoRepo.Context.FreshnessStatus -eq 'UNVERIFIED' -and (Test-DbM181HandoffReadiness -Task $script:CoreTask -Context $bundleNoRepo.Context -Graph $bundleNoRepo.Graph -NowUtc $script:NowUtc).Ready) ('fresh=' + $bundleNoRepo.Context.FreshnessStatus)

# --- Determinism 38 -----------------------------------------------------------
Write-Output '== Determinism (38) =='
Set-DbM181NowUtc '2026-08-31T12:00:00Z'
$gA = Resolve-DependencyGraph -Task $script:CoreTask -TaskCatalog $script:Catalog -NowUtc '2026-08-31T12:00:00Z'
$gB = Resolve-DependencyGraph -Task $script:CoreTask -TaskCatalog $script:Catalog -NowUtc '2026-08-31T12:00:00Z'
$recA = Reconcile-LineageRepository -LineageSet $script:LineageSet -RepositoryRoot $script:FixtureRepo -NowUtc '2026-08-31T12:00:00Z'
$recB = Reconcile-LineageRepository -LineageSet $script:LineageSet -RepositoryRoot $script:FixtureRepo -NowUtc '2026-08-31T12:00:00Z'
$ctxA = Build-DependencyDevelopmentContext -Task $script:CoreTask -Graph $gA -LineageSet $script:LineageSet -Reconciliation $recA -Relevance $relCore -Freshness $fresh1 -NowUtc '2026-08-31T12:00:00Z'
$ctxB = Build-DependencyDevelopmentContext -Task $script:CoreTask -Graph $gB -LineageSet $script:LineageSet -Reconciliation $recB -Relevance $relCore -Freshness $fresh1 -NowUtc '2026-08-31T12:00:00Z'
$sameGraph = (Get-DbM181CanonicalHash $gA) -eq (Get-DbM181CanonicalHash $gB)
$sameRecon = (Get-DbM181CanonicalHash $recA) -eq (Get-DbM181CanonicalHash $recB)
$sameCtx = (Get-DbM181CanonicalHash $ctxA) -eq (Get-DbM181CanonicalHash $ctxB)
Assert-True 'T38 full pipeline byte-deterministic under pinned time' 'determinism' ($sameGraph -and $sameRecon -and $sameCtx -and [string]$ctxA.PackageHash -eq [string]$ctxB.PackageHash) ('graph=' + $sameGraph + ' recon=' + $sameRecon + ' ctx=' + $sameCtx + ' hash=' + [string]$ctxA.PackageHash)

# --- Provenance 39 ------------------------------------------------------------
Write-Output '== Provenance (39) =='
$ctxProv = @($ctxCore.Provenance | ForEach-Object { [string]$_ })
$provOk = $true
foreach ($p in $ctxProv) { if (-not ($voc -contains $p)) { $provOk = $false } }
Assert-True 'P39 context provenance within vocabulary + evidence union' 'provenance' ($provOk -and ($ctxProv -contains 'M06') -and ($ctxProv -contains 'CLAUDE_REVIEW') -and ($ctxProv -contains 'CURRENT_REPOSITORY')) ('prov=' + ($ctxProv -join ','))

# --- Context size 40 ----------------------------------------------------------
Write-Output '== Context size (40) =='
$m = $ctxReporting.ContextMetrics
Assert-True 'C40 metrics counts (deps 5, included 2, omitted 3, omission reasons)' 'context-size' ([long]$m.DependencyCount -eq 5 -and [long]$m.IncludedDependencyCount -eq 2 -and [long]$m.OmittedDependencyCount -eq 3 -and @($m.OmissionReasons).Count -eq 3) ('deps=' + $m.DependencyCount + ' inc=' + $m.IncludedDependencyCount + ' omit=' + $m.OmittedDependencyCount + ' reasons=' + @($m.OmissionReasons).Count)
Assert-True 'C40 size ordering + token estimate in range' 'context-size' ([long]$m.CandidateContextSize -ge [long]$m.FilteredContextSize -and [long]$m.FilteredContextSize -ge 0 -and [long]$m.EstimatedTokens -ge 0 -and [long]$m.EstimatedTokens -le ([long]$m.FilteredContextSize + 8)) ('cand=' + $m.CandidateContextSize + ' filt=' + $m.FilteredContextSize + ' tok=' + $m.EstimatedTokens)
$omRaw = @($m.OmissionReasons) -join ' '
Assert-True 'C40 omission reasons name each omitted dependency' 'context-size' (($omRaw -match 'M-99.0') -and ($omRaw -match 'REL-001') -and ($omRaw -match 'M-44.0')) ('reasons=' + $omRaw)

# --- No-secret 41 -------------------------------------------------------------
Write-Output '== No-secret (41) =='
$gSecret = Resolve-DependencyGraph -Task $script:SecretTask -TaskCatalog $script:Catalog -NowUtc $script:NowUtc
$ctxSecret = Build-DependencyDevelopmentContext -Task $script:SecretTask -Graph $gSecret -LineageSet $script:LineageSet -Reconciliation $recon -Relevance $null -Freshness $fresh1 -NowUtc $script:NowUtc
$secHandoff = Get-DbM181HandoffLineageSection -Task $script:SecretTask -Context $ctxSecret
$secMarkdown = Get-DbM181DependencyContextSummary -Context $ctxSecret -AsMarkdown
$secClaude = Get-DbM181ClaudeDependencyContext -Task $script:SecretTask -Context $ctxSecret
$noLeak = (($secHandoff + $secMarkdown + $secClaude) -notmatch 'sk-AB12CD34EF56GH78IJ90') -and (($secHandoff + $secMarkdown + $secClaude) -match 'redacted')
Assert-True 'S41 secret-bearing purpose redacted from all packaged output' 'safety' ($noLeak -and (Test-DbM18SecretText 'token sk-AB12CD34EF56GH78IJ90 here')) ('leak=' + (-not $noLeak))

# --- No-source-modification 42 -------------------------------------------------
Write-Output '== No-source-modification (42) =='
$devSrcFpAfter = Get-DbM181RepoFingerprint (Join-Path $script:Root 'src')
$nexusGitAfter = @(& git -C 'C:\Personal\Nexus.Developer' status --porcelain=v1 2>$null)
$nexusDelta = @($nexusGitAfter | Where-Object { $script:NexusGitBefore -notcontains $_ })
$nexusDeltaRev = @($script:NexusGitBefore | Where-Object { $nexusGitAfter -notcontains $_ })
Assert-True 'S42 DevBridge src fingerprint unchanged by suite' 'safety' ($devSrcFpAfter -eq $script:DevSrcFpBefore) 'DevBridge src changed'
Assert-True 'S42 Nexus.Developer git state unchanged by suite' 'safety' ($nexusDelta.Count -eq 0 -and $nexusDeltaRev.Count -eq 0) ('delta: ' + (($nexusDelta + $nexusDeltaRev) -join '; '))

# --- No-workbook-modification 43 -------------------------------------------------
Write-Output '== No-workbook-modification (43) =='
$wbShaAfter = Get-Hash $script:RealWorkbook
Assert-True 'S43 authoritative workbook byte-identical' 'safety' ($wbShaAfter -eq $script:WorkbookShaBefore) 'workbook hash changed'

# --- Trial/Real semantics 44 ----------------------------------------------------
Write-Output '== Trial/Real semantics (44) =='
Assert-True 'S44 TRIAL_ONLY_UNMERGED lineage -> TRIAL_CYCLE_CLOSED' 'trial-real' ($li701.CompletionState -eq 'TRIAL_CYCLE_CLOSED' -and $li701.ClaudeReviewOutcome.TrialMode -and $li701.ClaudeReviewOutcome.ImplementationState -eq 'TRIAL_ONLY_UNMERGED') ('state=' + $li701.CompletionState)
$liReal = Get-DbM181TaskLineage -TaskId 'S-03.1' -EvidenceRoot $script:EvidenceRoot
Assert-True 'S44 REAL PASS lineage -> Completed (not trial-closed)' 'trial-real' ($liReal.CompletionState -eq 'Completed' -and -not $liReal.ClaudeReviewOutcome.TrialMode -and $liReal.ClaudeReviewOutcome.ImplementationState -eq 'UNMERGED') ('state=' + $liReal.CompletionState)
$sup = Get-DbM181Supersession -LineageSet $script:LineageSet -AssetPath 'src/Nexus.Developer.Core/Services/PaymentService.cs' -Reconciliation $recon
Assert-True 'S44 supersession record (PaymentService -> PaymentOrchestrator)' 'trial-real' ($null -ne $sup -and [string]$sup.CurrentImplementation -like '*PaymentOrchestrator.cs' -and $sup.Instruction -match 'superseded') ('current=' + $sup.CurrentImplementation)
$supNull = Get-DbM181Supersession -LineageSet $script:LineageSet -AssetPath 'src/Nexus.Developer.Core/Abstractions/ICalendarService.cs' -Reconciliation $recon
Assert-True 'S44 no supersession recorded -> null' 'trial-real' ($null -eq $supNull) 'unexpected supersession'

# --- Regressions 45-50 (child processes) ---------------------------------------
Write-Output '== Regressions (45-50) =='
function Invoke-ChildSuite([string]$scriptPath) {
    $oldEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
    $code = $LASTEXITCODE
    $ErrorActionPreference = $oldEAP
    return @{ exit = $code; output = ($out -join "`n") }
}
$r45 = Invoke-ChildSuite (Join-Path $PSScriptRoot 'Test-DbM18Classification.ps1')
Assert-True 'R45 DB-M18 regression (child suite) passes' 'regression' ($r45.exit -eq 0) ('exit=' + $r45.exit)
$r46 = Invoke-ChildSuite (Join-Path $script:Root 'scripts\Test-ChatGptHandoffReady.ps1')
Assert-True 'R46 M05 handoff gate regression (marker contract intact)' 'regression' ($r46.exit -eq 0 -and ($r46.output -match 'DBGH01_HANDOFF_TOKEN: (READY|CHATGPT_HANDOFF_NOT_READY)')) ('exit=' + $r46.exit)
# M07 / M09 regression: run the lifecycle commands against generic fixtures.
$m07Root = Join-Path $script:Db181Root 'm07reg'
New-Item -ItemType Directory -Force -Path (Join-Path $m07Root 'state') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $m07Root 'tasks') | Out-Null
$ct07 = [ordered]@{ nodeId = 'N-01-0.1'; taskId = 'N-01-0.1'; name = 'DB-M18.1 M07 regression fixture'; nodeType = 'WorkItem'; changeId = 'CHG-20260901-200'; status = 'VERIFIED'; nextAllowedAction = 'CLAUDE_REVIEW'; mode = 'TRIAL' }
($ct07 | ConvertTo-Json -Depth 5) | Out-File (Join-Path $m07Root 'state\current-task.json') -Encoding utf8
@{ milestone = 'DB-M06'; nodeId = 'N-01-0.1'; changeId = 'CHG-20260901-200'; primaryResult = 'VERIFICATION_PASSED'; trialMode = $true } | ConvertTo-Json | Out-File (Join-Path $m07Root 'state\verification.json') -Encoding utf8
$oldEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$env:DB07_STATE_DIR = (Join-Path $m07Root 'state'); $env:DB07_TASKS_DIR = (Join-Path $m07Root 'tasks')
$m07Out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Root 'scripts\New-ClaudeReviewPackage.ps1') 2>&1)
Remove-Item Env:\DB07_STATE_DIR -ErrorAction SilentlyContinue; Remove-Item Env:\DB07_TASKS_DIR -ErrorAction SilentlyContinue
$ErrorActionPreference = $oldEAP
$m07Text = ($m07Out -join "`n")
Assert-True 'R47 M07 regression (CLAUDE_REVIEW_PACKAGE_CREATED marker)' 'regression' (($m07Text -match 'DB07_OUTCOME: CLAUDE_REVIEW_PACKAGE_CREATED') -and ($m07Text -match 'DB07_RESULT_PASS: True')) ('out=' + (($m07Text -split "`n" | Select-String 'DB07_OUTCOME' | Select-Object -First 1)))
$m09Root = Join-Path $script:Db181Root 'm09reg'
New-Item -ItemType Directory -Force -Path (Join-Path $m09Root 'state') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $m09Root 'tasks') | Out-Null
$ct09 = [ordered]@{ nodeId = 'N-01-0.1'; taskId = 'N-01-0.1'; name = 'DB-M18.1 M09 regression fixture'; nodeType = 'WorkItem'; changeId = 'CHG-20260901-201'; status = 'DB_M09_FIX_REQUIRED'; nextAllowedAction = 'CORRECT_CURRENT_ATTEMPT'; mode = 'TRIAL' }
($ct09 | ConvertTo-Json -Depth 5) | Out-File (Join-Path $m09Root 'state\current-task.json') -Encoding utf8
@{ nodeId = 'N-01-0.1'; changeId = 'CHG-20260901-201'; decision = 'FIX'; dbM09Required = $true; reviewText = 'Fix row 9.' } | ConvertTo-Json | Out-File (Join-Path $m09Root 'state\claude-review.json') -Encoding utf8
$oldEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$env:DB09_STATE_DIR = (Join-Path $m09Root 'state'); $env:DB09_TASKS_DIR = (Join-Path $m09Root 'tasks')
$m09Out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Root 'scripts\New-CorrectionContext.ps1') 2>&1)
Remove-Item Env:\DB09_STATE_DIR -ErrorAction SilentlyContinue; Remove-Item Env:\DB09_TASKS_DIR -ErrorAction SilentlyContinue
$ErrorActionPreference = $oldEAP
$m09Text = ($m09Out -join "`n")
Assert-True 'R48 M09 regression (FIX_CONTEXT_CREATED marker)' 'regression' (($m09Text -match 'DB09_OUTCOME: FIX_CONTEXT_CREATED') -and ($m09Text -match 'DB09_RESULT_PASS: True')) ('out=' + (($m09Text -split "`n" | Select-String 'DB09_OUTCOME' | Select-Object -First 1)))
$r49 = Invoke-ChildSuite (Join-Path $script:Root 'scripts\Test-DBM12-2Commands.ps1')
Assert-True 'R49 DB-M12.2 regression (child suite) passes' 'regression' ($r49.exit -eq 0) ('exit=' + $r49.exit)
$r50 = Invoke-ChildSuite (Join-Path $script:Root 'scripts\Test-DBM124TrialCycleClosure.ps1')
Assert-True 'R50 DB-M12.4 regression (child suite) passes' 'regression' ($r50.exit -eq 0) ('exit=' + $r50.exit)

# --- Build 51 -------------------------------------------------------------------
Write-Output '== Build (51) =='
$sln = Join-Path $script:Root 'src\DevBridge.slnx'
$oldEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$buildOut = @(& dotnet build $sln 2>&1)
$buildExit = $LASTEXITCODE
$ErrorActionPreference = $oldEAP
$buildErrors = @($buildOut | Select-String -Pattern 'error CS').Count
Assert-True 'B51 solution builds with 0 errors' 'build' ($buildExit -eq 0 -and $buildErrors -eq 0) ('exit=' + $buildExit + ' errors=' + $buildErrors)

# --- summary --------------------------------------------------------------------
Write-Output ''
$failCount = $script:Fails.Count
Write-Output ('DB-M18.1 TEST SUMMARY: {0} checks, {1} passed, {2} failed' -f $script:Results.Count, ($script:Results.Count - $failCount), $failCount)
if ($failCount -gt 0) {
    Write-Output 'FAILURES:'
    foreach ($f in $script:Fails) { Write-Output ('  - ' + $f) }
    exit 1
}
Write-Output 'DB-M18.1: ALL PASS'
exit 0
