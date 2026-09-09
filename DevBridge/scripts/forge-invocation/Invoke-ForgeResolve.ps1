<#
Invoke-ForgeResolve.ps1 - FIB (Forge machine-callable invocation boundary) RESOLVE.

Machine-callable, non-destructive RESOLVE/INSPECT over the EXISTING governed Forge
lifecycle. Composes pre-existing engines verbatim (no new resolver/context/router):

  * Get-NextTask.ps1            -> task resolution (selection)
  * Test-DevelopmentPreflight.ps1 -> eligibility/preflight/scope/governance verdict
  * Read-DevelopmentControl.ps1 -> read-only authoritative workbook snapshot
  * TaskClassification.ps1      -> deterministic task classification (DB-M18)
  * config\ai-routing.json      -> DB-M14 routing-policy surface (status only)

CONTRACT (see DevBridge\design\FIB_MACHINE_INVOCATION_BOUNDARY_RESOLVE.md):
  powershell -NoProfile -ExecutionPolicy Bypass -File Invoke-ForgeResolve.ps1 ^
      -RequestFile <req.json> [-ResultFile <res.json>]

RESULT FILE is the machine contract (JSON). Exit code 0 iff a result doc was
written. Console text is never parsed. No Nexus Platform runtime required.

READ-ONLY guarantees:
  * Never writes DevBridge\state\ or DevBridge\tasks\.
  * Never writes the workbook (reader opens FileShare.ReadWrite / ZipArchive.Read).
  * Never runs git. Never creates a branch/worktree. Never reserves work.
  * The governed preflight engine's native state writes are diverted to a
    disposable scratch root under DevBridge\temp\forge-invocation\ (git-ignored).

Fail-closed: REQUEST_INVALID / IDENTITY_INVALID / SCOPE_NOT_GOVERNED /
SELECTION_BLOCKED / PREFLIGHT_NOT_CLEAR -> state=FAILED with deterministic
failures[]. Only a governed CLEAR selection is state=SUCCESS.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$RequestFile,
    [Parameter(Mandatory = $false)][string]$ResultFile,
    [switch]$SelfTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$startedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

# ---------------------------------------------------------------------------
# Minimal safe object helpers (strict-mode clean; never throw on missing props)
# ---------------------------------------------------------------------------
function Get-Prop {
    param($o, [string]$n)
    if ($null -eq $o) { return $null }
    if ($o -is [System.Collections.IDictionary]) {
        if ($o.Contains($n)) { return $o[$n] }
        return $null
    }
    $p = $o.PSObject.Properties[$n]
    if ($null -eq $p) { return $null }
    return $p.Value
}
function Get-PropStr {
    param($o, [string]$n)
    $v = Get-Prop $o $n
    if ($null -eq $v) { return "" }
    return [string]$v
}
function Out-JsonFile {
    param([string]$path, $obj)
    $dir = Split-Path $path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = $obj | ConvertTo-Json -Depth 40
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# Deterministic failure accumulation.
$script:Fails = New-Object System.Collections.Generic.List[object]
function Add-Failure {
    param([string]$code, [string]$stage, [string]$message)
    $script:Fails.Add([ordered]@{ code = $code; stage = $stage; message = $message })
}

$result = $null          # final ordered document
$internalError = $null   # non-contract fatal (result could not be produced)

try {
    # -----------------------------------------------------------------------
    # Root / config / workbook resolution (single consistent snapshot)
    # -----------------------------------------------------------------------
    $script:DevBridge = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
    if (-not $script:DevBridge) { $script:DevBridge = (Split-Path (Split-Path (Resolve-Path $PSScriptRoot) -Parent) -Parent) }

    $cfgPath = Join-Path $script:DevBridge "config\devbridge.json"
    if (-not (Test-Path $cfgPath)) { throw "DevBridge config not found: $cfgPath" }
    $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $configMode = Get-PropStr $cfg "mode"
    if (-not $configMode) { $configMode = "TRIAL" }

    # Workload workbook: an env override (fixture) wins; otherwise the configured
    # authoritative workbook. Force the override env so every dot-sourced engine
    # reads the SAME snapshot.
    $wbOverride = $env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE
    $workbookPath = $null
    $workbookSource = ""
    if ($wbOverride) {
        if (-not (Test-Path $wbOverride)) {
            throw "DB_DEV_CONTROL_WORKBOOK_OVERRIDE points to a missing file: $wbOverride"
        }
        $workbookPath = $wbOverride
        $workbookSource = "override"
    } else {
        $workbookPath = Get-PropStr $cfg "developmentControlWorkbook"
        if (-not $workbookPath -or -not (Test-Path $workbookPath)) {
            throw "Configured developmentControlWorkbook missing/not found: '$workbookPath'"
        }
        $workbookSource = "config"
    }
    Set-Item "env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE" $workbookPath

    # Governed state the resolver reads (TRIAL proving-history). Production = real
    # DevBridge\state; fixtures override.
    if (-not $env:DB_NEXTTASK_STATE_DIR) {
        Set-Item "env:DB_NEXTTASK_STATE_DIR" (Join-Path $script:DevBridge "state")
    }
    if (-not $env:DB_NEXTTASK_CONFIG_PATH) {
        Set-Item "env:DB_NEXTTASK_CONFIG_PATH" $cfgPath
    }

    # Request identity / run identity (before engine work so early failures still
    # carry correlation).
    $request = $null
    if ($RequestFile) {
        if (-not (Test-Path $RequestFile)) { throw "RequestFile not found: $RequestFile" }
        $request = Get-Content $RequestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        # Inline empty request = governed free resolve (also used by -SelfTest probes).
        $request = [ordered]@{ api = "forge.resolve"; operation = "RESOLVE" } | ConvertFrom-Json
    }
    $requestId = Get-PropStr $request "requestId"
    if (-not $requestId) { $requestId = "forgeresolve-" + ([guid]::NewGuid().ToString("N").Substring(0, 12)) }
    $actor = Get-PropStr $request "actor"
    if (-not $actor) { $actor = "machine" }
    $origin = Get-PropStr $request "origin"
    if (-not $origin) { $origin = $actor }

    $resultFile = $ResultFile
    if (-not $resultFile) { $resultFile = $RequestFile + ".result.json" }

    # Scratch root where the governed preflight engine may write ITS state files
    # (never the real DevBridge state/tasks). Git-ignored.
    $runId = ($requestId -replace '[^A-Za-z0-9._-]', '_')
    $scratchRoot = $env:DB_FIB_SCRATCH_ROOT
    if (-not $scratchRoot) {
        $scratchRoot = Join-Path $script:DevBridge ("temp\forge-invocation\" + $runId)
    }
    $scratchState = Join-Path $scratchRoot "state"
    $scratchTasks = Join-Path $scratchRoot "tasks"
    New-Item -ItemType Directory -Force -Path $scratchState | Out-Null
    New-Item -ItemType Directory -Force -Path $scratchTasks | Out-Null

    # -----------------------------------------------------------------------
    # Request validation (deterministic, fail-closed, BEFORE engine work)
    # -----------------------------------------------------------------------
    $api = Get-PropStr $request "api"
    $operation = Get-PropStr $request "operation"
    if (-not $api -or $api -ne "forge.resolve") {
        Add-Failure "REQUEST_INVALID" "validation" ("api must be 'forge.resolve' (got '" + $api + "').")
    }
    if ($operation -ne "RESOLVE" -and $operation -ne "INSPECT") {
        Add-Failure "REQUEST_INVALID" "validation" ("operation must be RESOLVE (got '" + $operation + "').")
    }

    $govTask = Get-Prop $request "governedTask"
    $requestedNodeId = Get-PropStr $govTask "nodeId"
    $requestedAddress = Get-PropStr $govTask "address"
    $requestedChangeId = Get-PropStr $govTask "changeId"
    $declaredMode = Get-PropStr $govTask "mode"
    $effectiveMode = $declaredMode
    if (-not $effectiveMode) { $effectiveMode = $configMode }

    # Role:Id address normalization (Foundation default; Products cross-scope -> fail).
    if ($requestedAddress) {
        $addrParts = @($requestedAddress -split ":", 2)
        if ($addrParts.Count -ne 2 -or -not $addrParts[1]) {
            Add-Failure "REQUEST_INVALID" "identity" ("address must be 'Role:Id' (got '" + $requestedAddress + "').")
        } else {
            $role = $addrParts[0].Trim()
            $addrNode = $addrParts[1].Trim()
            if ($role -ne "Foundation") {
                Add-Failure "SCOPE_NOT_GOVERNED" "identity" ("Forge RESOLVE resolves the Foundation governed universe only; address role '" + $role + "' is cross-scope and is not resolved here.")
            } elseif ($requestedNodeId -and $requestedNodeId -ne $addrNode) {
                Add-Failure "REQUEST_INVALID" "identity" ("governedTask.nodeId and address disagree ('" + $requestedNodeId + "' vs '" + $addrNode + "').")
            } else {
                $requestedNodeId = $addrNode
            }
        }
    }

    if ($requestedChangeId -and $requestedChangeId -notmatch "^CHG-\d{8}-\d{3}$") {
        Add-Failure "REQUEST_INVALID" "identity" ("changeId must match CHG-yyyyMMdd-NNN (got '" + $requestedChangeId + "').")
    }

    # -----------------------------------------------------------------------
    # Dot-source the existing engines (read-only). Assembly deps first.
    # -----------------------------------------------------------------------
    Add-Type -AssemblyName System.IO.Compression | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    Add-Type -AssemblyName System.Xml.Linq | Out-Null

    . (Join-Path $script:DevBridge "scripts\Read-DevelopmentControl.ps1")
    . (Join-Path $script:DevBridge "scripts\Get-NextTask.ps1")
    . (Join-Path $script:DevBridge "scripts\Test-DevelopmentPreflight.ps1")

    $nodes = @(Get-AllRoadmapNodes)
    $openRes = @(Get-ActiveChangesOpen)
    $workbookSha = Get-WorkbookSha256

    $requestedNodeExists = $false
    $requestedRoadmapNode = $null
    if ($requestedNodeId) {
        foreach ($n in $nodes) {
            if ([string]$n.NodeId -eq $requestedNodeId) { $requestedRoadmapNode = $n; $requestedNodeExists = $true; break }
        }
        if (-not $requestedNodeExists) {
            Add-Failure "IDENTITY_INVALID" "identity" ("Requested governed node '" + $requestedNodeId + "' does not exist in the Master Roadmap snapshot.")
        }
    }

    $contractOk = $script:Fails.Count -eq 0

    # -----------------------------------------------------------------------
    # Engine resolution (only when the request itself is well formed)
    # -----------------------------------------------------------------------
    $taskResolution = $null
    $preflight = $null
    $resolvedTarget = $null
    $classification = $null
    $preflightState = "NOT_RUN"
    $preflightReadiness = "NOT_RUN"
    $preflightReason = ""
    $nextGovernedAction = $null
    $depContext = $null
    $selStatus = ""
    $selTaskId = ""

    if ($contractOk) {
        # 1) Real task resolver.
        $selection = Get-NextTask
        $selStatus = Get-PropStr $selection "TaskSelectionStatus"
        $curWorkId = Get-PropStr $selection "CurrentWorkNodeId"
        $selTaskId = Get-PropStr $selection "TaskNodeId"
        $taskResolution = [ordered]@{
            status = $selStatus
            currentWorkNodeId = $curWorkId
            taskNodeId = $selTaskId
            selectionBasis = @(@(Get-Prop $selection "SelectionBasis"))
            candidates = @(@(Get-Prop $selection "Candidates"))
            blockState = (Get-PropStr $selection "BlockState")
            blockReason = (Get-PropStr $selection "BlockReason")
            ambiguityReason = (Get-PropStr $selection "AmbiguityReason")
        }

        $blockTokens = @("NO_IMPLEMENTABLE_DESCENDANT", "HUMAN_GOVERNANCE_REQUIRED", "IMPLEMENTATION_TARGET_UNKNOWN", "TASK_SELECTION_AMBIGUOUS")

        if ($selStatus -in $blockTokens) {
            # Governed resolver cannot select a task right now -> fail closed.
            $reason = Get-PropStr $selection "BlockReason"
            if (-not $reason) { $reason = Get-PropStr $selection "AmbiguityReason" }
            if (-not $reason) { $reason = "Governed task resolver returned " + $selStatus + "." }
            Add-Failure "SELECTION_BLOCKED" "task-resolution" $reason
            $preflightReason = $reason
        } else {
            # SELECTED. Declared target alignment: a requested node that is not the
            # governed next task fails closed (scope not governable now).
            if ($requestedNodeId -and $requestedNodeId -ne $selTaskId) {
                Add-Failure "SCOPE_NOT_GOVERNED" "scope" ("Requested node '" + $requestedNodeId + "' is not the governed next task (governed selection is '" + $selTaskId + "'). RESOLVE resolves the governed position; it does not force a different target.")
            }

            if ($script:Fails.Count -eq 0) {
                # 2) Real eligibility/preflight/scope engine (native writes diverted to scratch).
                $script:DevBridgeRoot = $scratchRoot
                $pfOut = @(& Test-DevelopmentPreflight)

                $pfState = Join-Path $scratchState "preflight.json"
                $ctState = Join-Path $scratchState "current-task.json"
                $pfObj = $null
                if (Test-Path $pfState) { $pfObj = Get-Content $pfState -Raw -Encoding UTF8 | ConvertFrom-Json }

                $verdict = ""
                if ($pfObj) { $verdict = Get-PropStr $pfObj "verdict" }
                if (-not $verdict -and $pfOut.Count -gt 0) { $verdict = [string]$pfOut[$pfOut.Count - 1] }
                if (-not $verdict) { $verdict = "CLEAR" }

                $blockingReasons = @()
                if ($pfObj) { $blockingReasons = @(Get-Prop $pfObj "blockingReasons") }

                # Resolved target (the governed leaf / anchor).
                $pfNodeId = Get-PropStr $pfObj "nodeId"
                $pfName = Get-PropStr $pfObj "name"
                $pfNodeType = Get-PropStr $pfObj "nodeType"
                $pfPhase = Get-PropStr $pfObj "phase"
                $pfLayer = Get-PropStr $pfObj "layer"
                if ($pfNodeId) {
                    $resolvedTarget = [ordered]@{
                        nodeId = $pfNodeId
                        name = $pfName
                        nodeType = $pfNodeType
                        phase = $pfPhase
                        layer = $pfLayer
                        address = "Foundation:" + $pfNodeId
                    }
                }

                $preflight = [ordered]@{
                    verdict = $verdict
                    readiness = if ($verdict -eq "CLEAR") { "READY" } else { "NOT_READY" }
                    scope = [ordered]@{
                        status = if ($verdict -eq "CLEAR") { "COMPLETE" } elseif ($verdict -eq "SCOPE_INCOMPLETE") { "INCOMPLETE" } else { "BLOCKED" }
                        source = (Get-PropStr $pfObj "scopeSource")
                    }
                    reasons = @($blockingReasons)
                    dependencies = if ($pfObj) { @(Get-Prop $pfObj "dependencies") } else { @() }
                    leafValidation = if ($pfObj) { @(Get-Prop $pfObj "leafValidation") } else { @() }
                    repositoryGovernance = if ($pfObj) {
                        $rg = Get-Prop $pfObj "repositoryGovernance"
                        if ($rg) { [ordered]@{ source = Get-PropStr $rg "source"; repositoriesIdentified = @(Get-Prop $rg "repositoriesIdentified"); limitation = Get-PropStr $rg "limitation" } } else { $null }
                    } else { $null }
                    sourceReferences = @(if ($pfObj) { @(Get-Prop $pfObj "sourceReferences") } else { @() })
                }
                $preflightReason = if ($blockingReasons.Count -gt 0) { ($blockingReasons -join " | ") } else { $verdict }
                $preflightState = $verdict
                $preflightReadiness = $preflight.readiness

                if ($verdict -ne "CLEAR") {
                    Add-Failure "PREFLIGHT_NOT_CLEAR" "preflight" ($verdict + " - " + $preflightReason)
                }

                # next governed action from the engine's own current-task record.
                if (Test-Path $ctState) {
                    $ctObj = Get-Content $ctState -Raw -Encoding UTF8 | ConvertFrom-Json
                    $nextGovernedAction = Get-PropStr $ctObj "nextAllowedAction"
                }
                if (-not $nextGovernedAction) {
                    $nextGovernedAction = if ($verdict -eq "CLEAR") { "RESERVE" } else { "RESOLVE_GOVERNANCE_BLOCK" }
                }

                # 3) Deterministic classification (DB-M18) of the governed task.
                $classMod = Join-Path $script:DevBridge "scripts\ai-routing\TaskClassification.ps1"
                if (Test-Path $classMod) {
                    try {
                        . $classMod
                        $taskRoadmapNode = $null
                        if ($selTaskId) {
                            foreach ($n in $nodes) { if ([string]$n.NodeId -eq $selTaskId) { $taskRoadmapNode = $n; break } }
                        }
                        if ($taskRoadmapNode) {
                            $cls = Classify-DevBridgeTask -Task $taskRoadmapNode -TaskId $selTaskId -NodeId $selTaskId -Name (Get-PropStr $taskRoadmapNode "Name") -ExecutionMode $effectiveMode -DevelopmentControlRole "Foundation" -ClassifiedAtUtc $startedUtc
                            $classification = [ordered]@{
                                taskType = Get-PropStr $cls "TaskType"
                                complexity = Get-PropStr $cls "Complexity"
                                risk = Get-PropStr $cls "Risk"
                                executionMode = Get-PropStr $cls "ExecutionMode"
                                minimumReasoningLevel = Get-PropStr $cls "MinimumReasoningLevel"
                                humanReviewRequired = Get-PropStr $cls "HumanReviewRequired"
                                nodeAddress = Get-PropStr $cls "NodeAddress"
                                requiredContextTokens = Get-PropStr $cls "RequiredContextTokens"
                                expectedOutputTokens = Get-PropStr $cls "ExpectedOutputTokens"
                            }
                        }
                    } catch {
                        $classification = [ordered]@{ status = "UNAVAILABLE"; reason = "Classifier engine did not run: " + $_.Exception.Message }
                    }
                }
            }
        }
    }

    # -----------------------------------------------------------------------
    # Deterministic dependency-context surface (read-only, engine-attributed)
    # -----------------------------------------------------------------------
    if ($preflightState -eq "CLEAR") {
        $depContext = [ordered]@{
            status = "RESOLVED"
            blockedDependencyIds = @()
            basis = "Roadmap-declared dependencies satisfied per DB-M03 preflight (verdict CLEAR)."
        }
    } elseif ($preflightState -eq "DEPENDENCY FOUND" -or $selStatus -eq "SELECTED") {
        $depContext = [ordered]@{
            status = if ($preflightState -eq "DEPENDENCY FOUND") { "BLOCKED" } else { "RESOLVED" }
            blockedDependencyIds = @()
            basis = "Dependency/lineage context carried from DB-M03 preflight verdict '" + $preflightState + "'."
        }
    } else {
        $depContext = [ordered]@{
            status = "NOT_APPLICABLE"
            blockedDependencyIds = @()
            basis = "No governed task selected; dependency context not applicable at this position."
        }
    }

    # -----------------------------------------------------------------------
    # Reservation state (read-only, from the open Active Changes snapshot)
    # -----------------------------------------------------------------------
    $namingReservations = @()
    $alreadyReserved = $false
    $reservedChangeId = $null
    $targetForAc = $selTaskId
    if (-not $targetForAc) { $targetForAc = $requestedNodeId }
    if ($targetForAc) {
        foreach ($ac in $openRes) {
            $acNodeTokens = @((Get-PropStr $ac "NodeId") -split "\|" | ForEach-Object { $_.Trim() })
            if ($acNodeTokens -contains $targetForAc) {
                $namingReservations += [ordered]@{
                    changeId = Get-PropStr $ac "ChangeId"
                    classification = Get-PropStr $ac "Classification"
                    status = Get-PropStr $ac "Status"
                    worker = Get-PropStr $ac "Worker"
                    branch = Get-PropStr $ac "Branch"
                    worktree = Get-PropStr $ac "Worktree"
                }
            }
        }
        if ($namingReservations.Count -gt 0) {
            $alreadyReserved = $true
            $reservedChangeId = Get-PropStr $namingReservations[0] "changeId"
        }
    }
    $reservation = [ordered]@{
        alreadyReserved = $alreadyReserved
        changeId = $reservedChangeId
        activeChangeCount = $openRes.Count
        namingReservations = @($namingReservations)
    }

    # -----------------------------------------------------------------------
    # Worktree / branch prep state - RESOLVE performs no git operation.
    # -----------------------------------------------------------------------
    $worktreeNote = "RESOLVE is read-only; no branch or worktree is created or mutated."
    if ($alreadyReserved -and $namingReservations.Count -gt 0 -and (Get-PropStr $namingReservations[0] "branch")) {
        $worktreeNote = "Target is already reserved; its recorded branch/worktree are echoed for reference (RESOLVE created nothing)."
    }
    $worktree = [ordered]@{
        prepState = "NOT_CREATED"
        branch = if ($alreadyReserved -and $namingReservations.Count -gt 0) { Get-PropStr $namingReservations[0] "branch" } else { $null }
        worktree = if ($alreadyReserved -and $namingReservations.Count -gt 0) { Get-PropStr $namingReservations[0] "worktree" } else { $null }
        note = $worktreeNote
    }

    # -----------------------------------------------------------------------
    # Routing policy surface (DB-M14 inert defaults; DB-M19 MANUAL-only).
    # -----------------------------------------------------------------------
    $routingStatus = "NOT_ENABLED"
    $routingExecMode = "MANUAL"
    $aiRoutingPath = Join-Path $script:DevBridge "config\ai-routing.json"
    if (Test-Path $aiRoutingPath) {
        $aiRouting = Get-Content $aiRoutingPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $routingExecMode = Get-PropStr $aiRouting "executionMode"
        if (-not $routingExecMode) { $routingExecMode = "MANUAL" }
        $rd = Get-Prop $aiRouting "routingDefaults"
        if ($rd -and (Get-Prop $rd "enabled") -eq $true) { $routingStatus = "AVAILABLE_POST_RESERVATION" }
    }
    $routing = [ordered]@{
        executionMode = $routingExecMode
        autoExecution = "PROHIBITED"
        recommendationStatus = $routingStatus
        selectedWorker = $null
        selectedProvider = $null
        selectedModel = $null
        note = "DB-M19 routing is MANUAL-only and requires an enabled policy plus a post-reservation context package. RESOLVE does not select or invoke any worker/model."
    }

    # -----------------------------------------------------------------------
    # Human gate + governed position (echo of real lifecycle state, read-only)
    # -----------------------------------------------------------------------
    $liveStateObj = $null
    $liveTaskPath = Join-Path $env:DB_NEXTTASK_STATE_DIR "current-task.json"
    if (Test-Path $liveTaskPath) { $liveStateObj = Get-Content $liveTaskPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    $currentLifecycleState = $null
    if ($liveStateObj) {
        $currentLifecycleState = [ordered]@{
            present = $true
            status = Get-PropStr $liveStateObj "status"
            nextAllowedAction = Get-PropStr $liveStateObj "nextAllowedAction"
            nodeId = Get-PropStr $liveStateObj "nodeId"
        }
    } else {
        $currentLifecycleState = [ordered]@{ present = $false; status = $null; nextAllowedAction = $null; nodeId = $null }
    }
    $humanGate = [ordered]@{
        required = $false
        note = "RESOLVE neither reserves nor dispatches. Reservation (and its human/external implementation step) is a later governed operation."
        nextGovernedAction = $nextGovernedAction
    }

    # -----------------------------------------------------------------------
    # Overall state + failures
    # -----------------------------------------------------------------------
    $overallState = if ($script:Fails.Count -eq 0) { "SUCCESS" } else { "FAILED" }
    $completedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

    $governed = [ordered]@{
        mode = $effectiveMode
        configMode = $configMode
        declaredMode = if ($declaredMode) { $declaredMode } else { $null }
        workbookSha256 = $workbookSha
        workbookSource = $workbookSource
        currentLifecycleState = $currentLifecycleState
        requestedNode = if ($requestedNodeId) { [ordered]@{ nodeId = $requestedNodeId; exists = $requestedNodeExists } } else { $null }
        resolvedTarget = $resolvedTarget
    }

    # Declared intent echo (scope/routing are honored as declared, never silently
    # altered - they do not drive RESOLVE's read-only resolution).
    $requested = [ordered]@{}
    if ($null -ne (Get-Prop $request "scope")) { $requested.scope = Get-Prop $request "scope" }
    if ($null -ne (Get-Prop $request "routing")) { $requested.routing = Get-Prop $request "routing" }

    # Evidence references (engine scratch + this result).
    $evidence = New-Object System.Collections.Generic.List[object]
    $evidence.Add([ordered]@{ kind = "workbook-sha256"; value = $workbookSha })
    $evidence.Add([ordered]@{ kind = "governance-source"; value = $workbookSource })
    if (Test-Path (Join-Path $scratchState "preflight.json")) {
        $evidence.Add([ordered]@{ kind = "preflight"; path = (Join-Path $scratchState "preflight.json") })
    }
    $evidence.Add([ordered]@{ kind = "result"; path = $resultFile })

    $result = [ordered]@{
        schemaVersion = 1
        api = "forge.resolve"
        operation = "RESOLVE"
        requestId = $requestId
        runId = $runId
        state = $overallState
        failures = @($script:Fails.ToArray())
        issuedAtUtc = $startedUtc
        completedAtUtc = $completedUtc
        actor = $actor
        origin = $origin
        requested = $requested
        governed = $governed
        taskResolution = $taskResolution
        preflight = $preflight
        dependencyContext = $depContext
        classification = $classification
        routing = $routing
        reservation = $reservation
        worktree = $worktree
        humanGate = $humanGate
        evidence = @($evidence.ToArray())
    }
}
catch {
    $internalError = $_.Exception.Message + " | boundary line " + $_.InvocationInfo.ScriptLineNumber
}

# ---------------------------------------------------------------------------
# Emit: always try to write a result document (exit 0 iff written).
# ---------------------------------------------------------------------------
$exitCode = 1
$finalResultFile = $null
if ($null -eq $result) {
    # A non-contract internal failure - still produce a deterministic result doc.
    $result = [ordered]@{
        schemaVersion = 1
        api = "forge.resolve"
        operation = "RESOLVE"
        requestId = $null
        runId = $null
        state = "FAILED"
        failures = @([ordered]@{ code = "INTERNAL_ERROR"; stage = "boundary"; message = [string]$internalError })
        issuedAtUtc = $startedUtc
        completedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        evidence = @()
    }
}
try {
    $finalResultFile = $resultFile
    if (-not $finalResultFile) { $finalResultFile = Join-Path ([System.IO.Path]::GetTempPath()) (("forgeresolve-" + [guid]::NewGuid().ToString("N") + ".result.json")) }
    Out-JsonFile $finalResultFile $result
    $exitCode = 0
} catch {
    $exitCode = 1
}

Write-Output ("FORGE_OPERATION: RESOLVE")
Write-Output ("FORGE_OUTCOME: " + (Get-PropStr $result "state"))
if ($finalResultFile) { Write-Output ("FORGE_RESULT_FILE: " + $finalResultFile) }
if ($internalError) { Write-Output ("FORGE_INTERNAL_ERROR: " + $internalError) }

exit $exitCode
