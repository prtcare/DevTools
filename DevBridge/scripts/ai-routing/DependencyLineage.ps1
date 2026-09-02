# =============================================================================
# DependencyLineage.ps1
# DB-M18.1 -- Dependency Development Lineage & Context Resolver (Lane B, AI Routing)
#
# Reads what each governed dependency ACTUALLY delivered (verified development
# lineage) and reconciles that history against the CURRENT repository, so future
# M05/M07/M09 handoffs and later automatic AI execution receive compact, verified,
# fresh dependency context instead of a flat "C depends on A and B".
#
# HARD CONSTRAINTS (DB-M18.1 brief, preserved):
#   * READ/ANALYZE/CONTEXT ONLY. No roadmap/phase/milestone/sequence/dependency
#     mutation anywhere. Dependency relationships may be READ, never redesigned.
#   * DETERMINISTIC. Zero AI calls, zero paid API calls, zero network calls.
#   * Current repository truth wins for implementation context; historical
#     evidence is preserved alongside it (never overwritten, never edited).
#   * No provider names (DeepSeek/Claude/OpenAI/Gemini) and no model selection
#     anywhere in resolution logic (ADR-005).
#   * DB-M14 / DB-M17 / DB-M18 contracts are READ via dot-source, never modified.
#     DB-M18.1 schema versions live in this library's own registry
#     (Get-DbM181SchemaVersions). AiRoutingContracts.ps1 is NOT modified.
#   * No Set-StrictMode in this library (the test suite sets it), matching the
#     DB-M18 convention. The library must stay strict-mode-safe because it is
#     dot-sourced inside M05/M07/M09 commands which run under Set-StrictMode.
#   * ASCII-only source (PS 5.1 + BOM-safe).
# =============================================================================

. (Join-Path $PSScriptRoot "ContextPackage.ps1")   # DB-M18 + DB-M14 + DB-M17 helpers (READ-ONLY)

# Deterministic canonical JSON is serialized by hand (ConvertTo-DbM181JsonCore).
# JavaScriptSerializer is deliberately avoided: it throws a circular-reference
# error ("PSMethod" / "PSParameterizedProperty") on nested OrderedDictionary,
# which the sorter produces for any object with nested values. No System.Web
# dependency is loaded here.

# Script-level repo/evidence defaults. The library lives at <repo>\scripts\ai-routing\,
# so the repo root is TWO levels above its directory. $PSScriptRoot is populated when
# the library is dot-sourced from an M05/M07/M09 command or the test suite; when it is
# dot-sourced from an interactive console it falls back to the command path.
$script:DbM181LibDir = ''
if ($PSScriptRoot) {
    $script:DbM181LibDir = $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    $script:DbM181LibDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$script:DbM181RepoRoot = ''
if ($script:DbM181LibDir -and (Test-Path -LiteralPath (Join-Path $script:DbM181LibDir '..\..'))) {
    $script:DbM181RepoRoot = (Resolve-Path (Join-Path $script:DbM181LibDir '..\..')).Path
}
$script:DbM181DefaultEvidenceRoot = ''
if ($script:DbM181RepoRoot) { $script:DbM181DefaultEvidenceRoot = Join-Path $script:DbM181RepoRoot 'logs\tasks' }
$script:DbM181NowUtc = ''

# -----------------------------------------------------------------------------
# DB-M18.1 schema version registry (DB-M18.1-owned; DB-M14/DB-M18 registries NOT
# modified). All v1 contracts frozen at DB-M18.1. Incompatible changes require
# v2 contracts with their own schemaVersion + validator.
# -----------------------------------------------------------------------------
function Get-DbM181SchemaVersions {
    return [pscustomobject]@{
        DependencyGraphResolutionVersion   = 1
        DevelopmentLineageVersion          = 1
        RepositoryReconciliationVersion    = 1
        LineageIndexVersion                = 1
        FreshnessReportVersion             = 1
        RelevanceReportVersion             = 1
        DependencyDevelopmentContextVersion = 1
        ContextMetricsVersion              = 1
        M05HandoffReadinessVersion         = 1
        ScopeChangeDecisionVersion         = 1
        DependencyDefectClassificationVersion = 1
        SupersessionRecordVersion          = 1
    }
}

# -----------------------------------------------------------------------------
# Canonical serialization (deterministic JSON + stable hash building blocks)
# -----------------------------------------------------------------------------
function ConvertTo-DbM181Sorted {
    <#
    .SYNOPSIS
    Recursively convert any hashtable/pscustomobject/array/scalar into an ordered
    structure with keys sorted in a canonical order so identical inputs always
    serialize byte-identically regardless of hashtable iteration order.

    .NOTES
    Dictionary-like inputs become OrderedDictionary; arrays stay Object[].
    Comma-wrapped returns preserve empty and single-element arrays through the
    PowerShell pipeline (a bare `return @()` emits nothing; a bare
    `return @('x')` unrolls to the scalar 'x').
    #>
    param([AllowNull()][object]$InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $od = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($key in ($InputObject.Keys | Sort-Object -Culture '')) {
            $od[[string]$key] = ConvertTo-DbM181Sorted -InputObject $InputObject[$key]
        }
        return $od
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $InputObject) { [void]$list.Add((ConvertTo-DbM181Sorted -InputObject $item)) }
        return ,@($list.ToArray())
    }
    if ($InputObject -is [pscustomobject]) {
        $od = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($prop in ($InputObject.PSObject.Properties | Sort-Object Name -Culture '')) {
            $od[$prop.Name] = ConvertTo-DbM181Sorted -InputObject $prop.Value
        }
        return $od
    }
    return $InputObject
}

function ConvertTo-DbM181Json {
    <#
    .SYNOPSIS
    Deterministic canonical JSON (sorted keys, arrays preserved even when
    single-element or empty). Serialized by hand (ConvertTo-DbM181JsonCore)
    because JavaScriptSerializer throws a circular-reference error on nested
    OrderedDictionary, which ConvertTo-DbM181Sorted produces.
    #>
    param([AllowNull()][object]$Object)
    $sorted = ConvertTo-DbM181Sorted -InputObject $Object
    $sb = New-Object System.Text.StringBuilder
    ConvertTo-DbM181JsonCore -Object $sorted -Builder $sb
    return $sb.ToString()
}

function ConvertTo-DbM181JsonCore {
    <#
    .SYNOPSIS
    Recursive JSON writer consuming the sorted structure. Internal helper.
    #>
    param([AllowNull()][object]$Object, [System.Text.StringBuilder]$Builder)
    if ($null -eq $Object) { [void]$Builder.Append('null'); return }
    if ($Object -is [System.Collections.IDictionary]) {
        [void]$Builder.Append('{')
        $first = $true
        foreach ($key in ($Object.Keys | Sort-Object -Culture '')) {
            if (-not $first) { [void]$Builder.Append(',') }
            $first = $false
            [void]$Builder.Append('"')
            [void]$Builder.Append((ConvertTo-DbM181JsonString ([string]$key)))
            [void]$Builder.Append('":')
            ConvertTo-DbM181JsonCore -Object $Object[$key] -Builder $Builder
        }
        [void]$Builder.Append('}')
        return
    }
    if ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [string]) {
        [void]$Builder.Append('[')
        $first = $true
        foreach ($item in $Object) {
            if (-not $first) { [void]$Builder.Append(',') }
            $first = $false
            ConvertTo-DbM181JsonCore -Object $item -Builder $Builder
        }
        [void]$Builder.Append(']')
        return
    }
    if ($Object -is [bool]) { [void]$Builder.Append($(if ($Object) { 'true' } else { 'false' })); return }
    if ($Object -is [string]) {
        [void]$Builder.Append('"')
        [void]$Builder.Append((ConvertTo-DbM181JsonString $Object))
        [void]$Builder.Append('"')
        return
    }
    if (Test-DbM181Numeric -Value $Object) {
        [void]$Builder.Append([Convert]::ToString($Object, [System.Globalization.CultureInfo]::InvariantCulture))
        return
    }
    # Any other scalar (DateTime, Guid, enum, ...) -> quoted invariant string.
    [void]$Builder.Append('"')
    [void]$Builder.Append((ConvertTo-DbM181JsonString ([string]$Object)))
    [void]$Builder.Append('"')
}

function ConvertTo-DbM181JsonString {
    <#
    .SYNOPSIS
    JSON-escape a string value (quotes, backslash, control chars). Internal helper.
    #>
    param([string]$Value)
    $out = New-Object System.Text.StringBuilder
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int]$ch
        if ($code -eq 34) { [void]$out.Append('\"') }
        elseif ($code -eq 92) { [void]$out.Append('\\') }
        elseif ($code -eq 10) { [void]$out.Append('\n') }
        elseif ($code -eq 13) { [void]$out.Append('\r') }
        elseif ($code -eq 9) { [void]$out.Append('\t') }
        elseif ($code -lt 32) { [void]$out.Append(('\u{0:x4}' -f $code)) }
        else { [void]$out.Append($ch) }
    }
    return $out.ToString()
}

function Test-DbM181Numeric {
    <#
    .SYNOPSIS
    True when the value is a numeric .NET type (serialized unquoted). Internal helper.
    #>
    param([AllowNull()][object]$Value)
    return ($Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] `
        -or $Value -is [int] -or $Value -is [uint32] -or $Value -is [long] -or $Value -is [uint64] `
        -or $Value -is [double] -or $Value -is [single] -or $Value -is [decimal])
}

function Get-DbM181CanonicalHash {
    <#
    .SYNOPSIS
    SHA-256 hex over the canonical JSON of an object (deterministic fingerprint).
    #>
    param([AllowNull()][object]$Object)
    $json = ConvertTo-DbM181Json -Object $Object
    return Get-DbM18Sha256Hex $json
}

# -----------------------------------------------------------------------------
# Evidence helpers (read-only)
# -----------------------------------------------------------------------------
function Read-DbM181JsonFile {
    <#
    .SYNOPSIS
    Read a JSON evidence file defensively; missing/unparseable -> $null (never throws).
    #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json)
    } catch { return $null }
}

function Get-DbM181Relative {
    <#
    .SYNOPSIS
    Normalize a path to forward slashes for stable relative keys.
    #>
    param([AllowNull()][string]$Path)
    if (-not $Path) { return $Path }
    return ($Path -replace '\\', '/')
}

function Get-DbM181FileSha256 {
    <#
    .SYNOPSIS
    SHA-256 hex of a file's bytes (read-only); missing file -> $null.
    #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $hash = $sha.ComputeHash($fs)
            return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
        } finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}

function Get-DbM181RepoWalk {
    <#
    .SYNOPSIS
    Read-only recursive walk of a repository root. Returns one record per text
    file: relative Path (forward slashes), Sha256, Bytes. Binary/generated files
    are excluded via the DB-M18 text-file guard.
    #>
    param([string]$Root)
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Root)) { return ,@($out.ToArray()) }
    $base = (Resolve-Path -LiteralPath $Root).Path
    foreach ($file in (Get-ChildItem -LiteralPath $base -Recurse -File -ErrorAction SilentlyContinue)) {
        $rel = $file.FullName.Substring($base.Length).TrimStart('\', '/')
        $rel = Get-DbM181Relative $rel
        if (-not (Test-DbM18IsTextFile $rel)) { continue }
        $h = Get-DbM181FileSha256 $file.FullName
        [void]$out.Add([pscustomobject]@{ Path = $rel; Sha256 = $h; Bytes = $file.Length })
    }
    return ,@($out.ToArray())
}

function Get-DbM181RepoFingerprint {
    <#
    .SYNOPSIS
    Deterministic fingerprint of a repository scope: sorted relative paths + their
    SHA-256 hashes. Any create/modify/delete/rename in the scope changes the hash.
    #>
    param([string]$Root)
    $walk = Get-DbM181RepoWalk $Root
    $lines = New-Object System.Collections.ArrayList
    foreach ($f in ($walk | Sort-Object Path)) {
        [void]$lines.Add($f.Path + '|' + $f.Sha256)
    }
    return Get-DbM18Sha256Hex (($lines -join "`n"))
}

function Get-DbM181LineageFingerprint {
    <#
    .SYNOPSIS
    Deterministic fingerprint over a lineage set (canonical JSON of each record).
    #>
    param([AllowNull()][object[]]$LineageSet)
    $lines = New-Object System.Collections.ArrayList
    foreach ($l in @($LineageSet)) {
        [void]$lines.Add((ConvertTo-DbM181Json $l))
    }
    return Get-DbM18Sha256Hex (($lines -join "`n"))
}

function Get-DbM181Now {
    if ([string]::IsNullOrEmpty($script:DbM181NowUtc)) {
        return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    return $script:DbM181NowUtc
}

function Set-DbM181NowUtc {
    <#
    .SYNOPSIS
    Test hook: pin a fixed timestamp so determinism tests can compare two runs
    byte-for-byte. Not used in production paths.
    #>
    param([string]$NowUtc)
    $script:DbM181NowUtc = $NowUtc
}

function Get-DbM181IsNodeDependency {
    <#
    .SYNOPSIS
    True when a dependency id names a governed roadmap node (F/M/WI/T/S prefix).
    Non-node references (e.g. REL-001..011 explicit D&B) are preserved but never
    expanded transitively.
    #>
    param([AllowNull()][string]$DependencyId)
    if (-not $DependencyId) { return $false }
    return ($DependencyId -match '^(F|M|WI|T|S)-')
}

function Get-DbM181IsPreservedReference {
    param([AllowNull()][string]$DependencyId)
    if (-not $DependencyId) { return $false }
    return ($DependencyId -match '^REL-')
}

function Get-DbM181GuardedText {
    <#
    .SYNOPSIS
    Redact secret-like free text before it is emitted into any packaged markdown/
    context. Reuses the DB-M18 secret guard; non-secret text passes through.
    #>
    param([AllowNull()][string]$Text, [string]$Kind = 'section')
    if (-not $Text) { return $Text }
    if (Test-DbM18SecretText $Text) { return Get-DbM18RedactionMarker $Kind }
    return $Text
}

# -----------------------------------------------------------------------------
# Capability 1 -- dependency graph resolution (deterministic)
# -----------------------------------------------------------------------------
function Resolve-DependencyGraph {
    <#
    .SYNOPSIS
    Resolve the current task's direct + transitive dependency graph from its
    governed dependencies array and an optional TaskCatalog (nodeId -> task shape).
    Deterministic detection of cycles, missing nodes, invalid references, blocked
    dependencies and duplicate paths. READ-ONLY; never redesigns a relationship.
    #>
    param(
        [AllowNull()][object]$Task,
        [AllowNull()][hashtable]$TaskCatalog,
        [string]$NowUtc = ''
    )
    $now = if ($NowUtc) { $NowUtc } else { Get-DbM181Now }
    $taskId = [string](Get-ContractProperty $Task 'taskId' '')
    $nodeId = Get-DbM18First @((Get-ContractProperty $Task 'nodeId' $null), $taskId, '')
    $changeId = [string](Get-ContractProperty $Task 'changeId' '')

    $deps = Get-DbM18ArrayValue $Task 'dependencies'
    if ($deps.Count -eq 0) { $deps = Get-DbM18ArrayValue $Task 'Dependencies' }

    $direct = New-Object System.Collections.ArrayList
    $state = [ordered]@{
        Visited   = @{}
        Stack     = New-Object System.Collections.ArrayList
        Transitive = New-Object System.Collections.ArrayList
        Missing   = New-Object System.Collections.ArrayList
        Invalid   = New-Object System.Collections.ArrayList
        Blocked   = New-Object System.Collections.ArrayList
        Cycles    = New-Object System.Collections.ArrayList
        Duplicate = New-Object System.Collections.ArrayList
        Edges     = 0
        Catalog   = @{ }
    }
    if ($TaskCatalog) { $state.Catalog = $TaskCatalog }
    if ($nodeId) { [void]$state.Stack.Add([string]$nodeId) }

    function Resolve-DbM181Node {
        param(
            [string]$Id,
            [int]$Depth,
            [AllowNull()][object[]]$Path,
            [hashtable]$S,
            [bool]$RecordAsTransitive
        )
        if (-not $Id) { return }
        $id = $Id.Trim()
        if ($S.Stack.Contains($id)) {
            $idx = $S.Stack.IndexOf($id)
            $cycle = @()
            for ($i = $idx; $i -lt $S.Stack.Count; $i++) { $cycle += [string]$S.Stack[$i] }
            $cycle += $id
            [void]$S.Cycles.Add([pscustomobject]@{ Nodes = @($cycle) })
            return
        }
        if ($S.Visited.ContainsKey($id)) {
            [void]$S.Duplicate.Add([pscustomobject]@{ DependencyId = $id; Path = ($Path -join '->') })
            return
        }
        $S.Visited[$id] = $Depth
        if ($RecordAsTransitive) {
            [void]$S.Transitive.Add([pscustomobject]@{ DependencyId = $id; Depth = $Depth; Path = ($Path -join '->') })
        }
        $depTask = $null
        if ($S.Catalog.ContainsKey($id)) { $depTask = $S.Catalog[$id] }
        if ($null -eq $depTask) {
            [void]$S.Missing.Add([pscustomobject]@{ DependencyId = $id; Reason = 'No catalog/evidence record for referenced node' })
            return
        }
        $S.Edges = $S.Edges + 1
        $depDeps = Get-DbM18ArrayValue $depTask 'dependencies'
        if ($depDeps.Count -eq 0) { $depDeps = Get-DbM18ArrayValue $depTask 'Dependencies' }
        if ($depDeps.Count -eq 0) { return }
        [void]$S.Stack.Add($id)
        foreach ($dd in @($depDeps)) {
            $did = Get-DbM18First @((Get-ContractProperty $dd 'dependencyId' $null), (Get-ContractProperty $dd 'id' $null), '')
            if (-not $did) { continue }
            if (-not (Get-DbM181IsNodeDependency $did)) { continue }
            $didState = [string](Get-ContractProperty $dd 'state' '')
            if ($didState -in @('BLOCKED', 'IN_PROGRESS')) {
                [void]$S.Blocked.Add([pscustomobject]@{ DependencyId = $did.Trim(); Reason = ("dependency state '" + $didState + "'") })
            }
            Resolve-DbM181Node -Id $did -Depth ($Depth + 1) -Path ($Path + $did.Trim()) -S $S -RecordAsTransitive $true
        }
        [void]$S.Stack.RemoveAt($S.Stack.Count - 1)
    }

    foreach ($d in @($deps)) {
        $id = Get-DbM18First @((Get-ContractProperty $d 'dependencyId' $null), (Get-ContractProperty $d 'id' $null), (Get-ContractProperty $d 'DependencyId' $null), '')
        $type = Get-DbM18First @((Get-ContractProperty $d 'type' $null), (Get-ContractProperty $d 'Type' $null), 'Textual (node Dependencies)')
        $dstate = Get-DbM18First @((Get-ContractProperty $d 'state' $null), (Get-ContractProperty $d 'State' $null), '')
        $dstatus = Get-DbM18First @((Get-ContractProperty $d 'status' $null), (Get-ContractProperty $d 'Status' $null), '')
        $detail = Get-DbM18First @((Get-ContractProperty $d 'detail' $null), (Get-ContractProperty $d 'Detail' $null), '')
        if (-not $id) {
            [void]$state.Invalid.Add([pscustomobject]@{ Reference = '<empty>'; Reason = 'dependencyId is empty' })
            continue
        }
        $id = $id.Trim()
        [void]$direct.Add([pscustomobject]@{
            DependencyId = $id; Type = [string]$type; State = [string]$dstate; Status = [string]$dstatus; Detail = [string]$detail
        })
        if (-not (Get-DbM181IsNodeDependency $id) -and -not (Get-DbM181IsPreservedReference $id)) {
            [void]$state.Invalid.Add([pscustomobject]@{ Reference = $id; Reason = 'Reference does not match the governed node pattern and is not a preserved D&B reference' })
            continue
        }
        if (-not (Get-DbM181IsNodeDependency $id)) { continue }
        $ds = [string]$dstate
        if ($ds -in @('BLOCKED', 'IN_PROGRESS')) {
            [void]$state.Blocked.Add([pscustomobject]@{ DependencyId = $id; Reason = ("dependency state '" + $ds + "'") })
        }
        Resolve-DbM181Node -Id $id -Depth 1 -Path @($id) -S $state -RecordAsTransitive $false
    }
    if ($nodeId) { [void]$state.Stack.RemoveAt($state.Stack.Count - 1) }

    return [pscustomobject]@{
        SchemaVersion            = 1
        GraphId                  = 'GRAPH-' + $taskId
        TaskId                   = $taskId
        NodeId                   = [string]$nodeId
        ChangeId                 = $changeId
        DirectDependencies       = @($direct.ToArray())
        TransitiveDependencies   = @($state.Transitive.ToArray())
        CycleDetected            = ($state.Cycles.Count -gt 0)
        Cycles                   = @($state.Cycles.ToArray())
        MissingDependencies      = @($state.Missing.ToArray())
        InvalidReferences        = @($state.Invalid.ToArray())
        BlockedDependencies      = @($state.Blocked.ToArray())
        DuplicatePaths           = @($state.Duplicate.ToArray())
        ResolvedCount            = $state.Visited.Count
        EdgeCount                = $state.Edges
        GraphEvidence            = 'WORKBOOK (preflight dependencies) + TaskCatalog'
        ResolvedAtUtc            = $now
        Provenance               = @('WORKBOOK')
    }
}

# -----------------------------------------------------------------------------
# Capability 2 -- development lineage collection (per dependent task)
# -----------------------------------------------------------------------------
function Get-DbM181TaskLineage {
    <#
    .SYNOPSIS
    Collect the verified development lineage of ONE governed task from its evidence
    directory (logs/tasks/<TaskId>/<ChangeId>/) plus governed identity. Returns a
    DevelopmentLineage v1 record. Absent evidence stays empty and lowers
    Confidence -- history is never invented.
    #>
    param([string]$TaskId, [string]$EvidenceRoot = $script:DbM181DefaultEvidenceRoot)
    $lineage = [ordered]@{
        SchemaVersion          = 1
        TaskId                 = $TaskId
        NodeId                 = $TaskId
        ChangeIds              = @()
        OriginalPurpose        = ''
        AcceptanceCriteria     = ''
        CompletionState        = 'Planned'
        VerificationState      = 'NONE'
        FilesCreated           = @()
        FilesModified          = @()
        PreservedFiles         = @()
        FileHashes             = @{}
        ContractsCreated       = @()
        ContractsChanged       = @()
        ClassesServicesCreated = @()
        SchemaChanges          = @()
        ConfigChanges          = @()
        TestsAdded             = @()
        Projects               = @()
        Globs                  = @()
        ContractsApi           = @()
        SchemaContexts         = @()
        AuthorizedGlobs        = @()
        ImplementationEvidence = @()
        M06Evidence            = $null
        ClaudeReviewOutcome    = $null
        BlockingFindings       = @()
        NonBlockingObservations = @()
        KnownLimitations       = @()
        ScopeAmendments        = @()
        SupersededBy           = @()
        CorrectionAttempts     = @()
        FixTasks               = @()
        LaterModifiers         = @()
        Provenance             = @('WORKBOOK')
        Confidence             = 'INFERRED'
    }
    if (-not $TaskId -or -not (Test-Path -LiteralPath $EvidenceRoot)) { return [pscustomobject]$lineage }

    $taskDir = Join-Path $EvidenceRoot $TaskId
    if (-not (Test-Path -LiteralPath $taskDir)) { return [pscustomobject]$lineage }

    $changeDirs = @(Get-ChildItem -LiteralPath $taskDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
    $createdHash = @{}
    $modifiedHash = @{}
    $preserved = New-Object System.Collections.ArrayList
    $superseded = New-Object System.Collections.ArrayList
    $scopeAmendments = New-Object System.Collections.ArrayList
    $blocking = New-Object System.Collections.ArrayList
    $observations = New-Object System.Collections.ArrayList
    $evidenceRefs = New-Object System.Collections.ArrayList
    $correctionAttempts = New-Object System.Collections.ArrayList
    $claudeOutcome = $null
    $m06 = $null
    $hasChangedFiles = $false
    $hasVerification = $false
    $anyBuildFail = $false
    $anyTestFail = $false
    $verifPassed = $true
    $implementationState = ''
    $decision = ''
    $trialMode = $false

    foreach ($cd in $changeDirs) {
        $changeId = $cd.Name
        $dir = $cd.FullName

        # reservation.json -- governed identity + reserved scope
        $res = Read-DbM181JsonFile (Join-Path $dir 'reservation.json')
        if ($null -ne $res) {
            $name = [string](Get-ContractProperty $res 'name' '')
            if ($name) { $lineage.OriginalPurpose = $name; $lineage.AcceptanceCriteria = $name }
            $rc = Get-ContractProperty $res 'reservedScope' $null
            if ($null -ne $rc) {
                $lineage.Projects = Get-DbM18ArrayValue $rc 'projects'
                $lineage.Globs = Get-DbM18ArrayValue $rc 'filesGlobs'
                $lineage.ContractsApi = Get-DbM18ArrayValue $rc 'contractsApis'
                $lineage.SchemaContexts = Get-DbM18ArrayValue $rc 'schemaContexts'
            }
            $lineage.ChangeIds += @($changeId)
            $lineage.NodeId = Get-DbM18First @((Get-ContractProperty $res 'nodeId' $null), $TaskId)
            [void]$evidenceRefs.Add([pscustomobject]@{ Kind = 'reservation'; Path = ('logs/tasks/' + $TaskId + '/' + $changeId + '/reservation.json'); Provenance = 'WORKBOOK' })
        } else {
            $lineage.ChangeIds += @($changeId)
        }

        # changed-files.json -- the M06 authoritative file delta. Two evidence
        # shapes exist across governed history: deltaAttribution[] (CHG-017+) and
        # inventory[] (CHG-016 and earlier). Both are read; neither is invented.
        $cf = Read-DbM181JsonFile (Join-Path $dir 'changed-files.json')
        if ($null -ne $cf) {
            $hasChangedFiles = $true
            [void]$evidenceRefs.Add([pscustomobject]@{ Kind = 'changed-files'; Path = ('logs/tasks/' + $TaskId + '/' + $changeId + '/changed-files.json'); Provenance = 'M06' })
            $attribution = Get-DbM18ArrayValue $cf 'deltaAttribution'
            $inventory = Get-DbM18ArrayValue $cf 'inventory'
            if ($attribution.Count -gt 0) {
                foreach ($e in @($attribution)) {
                    $kind = [string](Get-ContractProperty $e 'kind' '')
                    $note = [string](Get-ContractProperty $e 'note' '')
                    $path = [string](Get-ContractProperty $e 'path' '')
                    if (-not $path -and $kind -eq 'B_preserved_unchanged') {
                        $preservedPaths = Get-DbM18ArrayValue $e 'paths'
                        foreach ($p in $preservedPaths) {
                            $pp = Get-DbM181Relative ([string]$p)
                            if ($pp -and -not $preserved.Contains($pp)) { [void]$preserved.Add($pp) }
                        }
                        continue
                    }
                    if (-not $path) { continue }
                    $path = Get-DbM181Relative $path
                    if ($kind -eq 'C_continuation_delta_created') {
                        if (-not $createdHash.ContainsKey($path)) { $createdHash[$path] = $TaskId }
                        $sha = [string](Get-ContractProperty $e 'sha256' '')
                        if ($sha) { $lineage.FileHashes[$path] = $sha }
                    } elseif ($kind -eq 'C_continuation_delta_modified') {
                        if (-not $modifiedHash.ContainsKey($path)) { $modifiedHash[$path] = $TaskId }
                        $sha = [string](Get-ContractProperty $e 'currentSha256' '')
                        if ($sha) { $lineage.FileHashes[$path] = $sha }
                        $baseline = [string](Get-ContractProperty $e 'baselineB' '')
                        if ($baseline -and -not $sha) { $lineage.FileHashes[$path] = $baseline }
                    }
                    if ($kind -eq 'C_continuation_delta_created' -and $note -match '(?i)(replaces|supersedes|replaced by)\s+([A-Za-z0-9_./\\-]+)\.([a-z0-9]+)') {
                        $orig = Get-DbM181Relative ($Matches[2] + '.' + $Matches[3])
                        [void]$superseded.Add([pscustomobject]@{ OriginalPath = $orig; NewPath = $path; TaskId = $TaskId; ChangeId = $changeId })
                    }
                }
            } elseif ($inventory.Count -gt 0) {
                foreach ($e in @($inventory)) {
                    $state = [string](Get-ContractProperty $e 'state' '')
                    $cls = [string](Get-ContractProperty $e 'classification' '')
                    $path = Get-DbM181Relative ([string](Get-ContractProperty $e 'path' ''))
                    if (-not $path) { continue }
                    if ($cls -ne 'IMPLEMENTATION_CHANGE_IN_SCOPE') { continue }
                    $sha = [string](Get-ContractProperty $e 'sha256' '')
                    if ($state -in @('new-untracked', 'created', 'added', 'added-staged')) {
                        if (-not $createdHash.ContainsKey($path)) { $createdHash[$path] = $TaskId }
                        if ($sha) { $lineage.FileHashes[$path] = $sha }
                    } elseif ($state -eq 'modified') {
                        if (-not $modifiedHash.ContainsKey($path)) { $modifiedHash[$path] = $TaskId }
                        if ($sha) { $lineage.FileHashes[$path] = $sha }
                    }
                }
                $preExistingFiles = Get-DbM18ArrayValue $cf 'preExistingScopeFilesUnchanged'
                foreach ($p in $preExistingFiles) {
                    $pp = Get-DbM181Relative ([string](Get-ContractProperty $p 'path' ''))
                    if ($pp -and -not $preserved.Contains($pp)) { [void]$preserved.Add($pp) }
                }
            }
            $sc = Get-ContractProperty $cf 'scopeCheck' $null
            if ($null -ne $sc) { $lineage.AuthorizedGlobs = Get-DbM18ArrayValue $sc 'authorizedGlobs' }
        }

        # scope-amendment.json -- approved scope growth + prior-cycle ownership
        $sa = Read-DbM181JsonFile (Join-Path $dir 'scope-amendment.json')
        if ($null -ne $sa) {
            $amended = [pscustomobject]@{
                ScopeAmended  = [bool](Get-ContractProperty $sa 'scopeAmended' $false)
                AddedProjects = Get-DbM18ArrayValue $sa 'addedProjects'
                AddedFiles    = Get-DbM18ArrayValue $sa 'addedFiles'
                PriorOwners   = New-Object System.Collections.ArrayList
                Provenance    = 'LATER_WORK_ITEM'
            }
            $baselineHashes = Get-DbM18ArrayValue $sa 'addedFileBaselineHashes'
            foreach ($f in $baselineHashes) {
                $p = Get-DbM181Relative ([string](Get-ContractProperty $f 'path' ''))
                $owner = [string](Get-ContractProperty $f 'priorCycleOwner' '')
                $sha = [string](Get-ContractProperty $f 'sha256' '')
                if ($p) {
                    if (-not $createdHash.ContainsKey($p)) { $createdHash[$p] = $TaskId }
                    if ($sha) { $lineage.FileHashes[$p] = $sha }
                    if ($owner) { [void]$amended.PriorOwners.Add([pscustomobject]@{ Path = $p; PriorOwner = $owner }) }
                }
            }
            [void]$scopeAmendments.Add($amended)
        }

        # build-result.json / test-result.json -- M06 deterministic verification
        $build = Read-DbM181JsonFile (Join-Path $dir 'build-result.json')
        $test = Read-DbM181JsonFile (Join-Path $dir 'test-result.json')
        $acc = Read-DbM181JsonFile (Join-Path $dir 'acceptance-matrix.json')
        if ($null -ne $build -or $null -ne $test -or $null -ne $acc) {
            $hasVerification = $true
            $m06 = [ordered]@{ Build = $null; Test = $null; Acceptance = $null; Provenance = 'M06' }
            if ($null -ne $build) {
                $br = Get-ContractProperty $build 'result' $null
                if ($null -eq $br) { $br = Get-ContractProperty $build 'overall' $null }
                $warnings = [int](Get-ContractProperty $br 'warnings' -1)
                $errors = [int](Get-ContractProperty $br 'errors' -1)
                if ($null -eq $br) {
                    # per-project fallback (older shape): all projects buildSucceeded
                    $projs = Get-DbM18ArrayValue $build 'projects'
                    $succeeded = ($projs.Count -gt 0)
                    $warnings = 0
                    $errors = 0
                    foreach ($pj in $projs) {
                        $b = [bool](Get-ContractProperty $pj 'buildSucceeded' $false)
                        $warnings += [int](Get-ContractProperty $pj 'warnings' 0)
                        $errors += [int](Get-ContractProperty $pj 'errors' 0)
                        if (-not $b) { $succeeded = $false }
                    }
                } else {
                    $succeeded = [bool](Get-ContractProperty $br 'succeeded' $false)
                }
                $m06.Build = [pscustomobject]@{ Succeeded = $succeeded; Warnings = $warnings; Errors = $errors; Command = [string](Get-ContractProperty $build 'command' '') }
                if (-not $succeeded) { $anyBuildFail = $true }
            }
            if ($null -ne $test) {
                $tr = Get-ContractProperty $test 'result' $null
                if ($null -eq $tr) { $tr = Get-ContractProperty $test 'testRun' $null }
                $passed = [long](Get-ContractProperty $tr 'passed' 0)
                $failed = [long](Get-ContractProperty $tr 'failed' 0)
                $total = [long](Get-ContractProperty $tr 'total' 0)
                $m06.Test = [pscustomobject]@{ Passed = $passed; Failed = $failed; Total = $total }
                if ($failed -gt 0) { $anyTestFail = $true; $verifPassed = $false }
                if ($total -eq 0) { $verifPassed = $false }
            }
            if ($null -ne $acc) {
                $ar = Get-ContractProperty $acc 'result' $null
                if ($null -eq $ar) { $ar = Get-ContractProperty $acc 'summary' $null }
                if ($null -ne $ar -and $ar -isnot [string]) {
                    $m06.Acceptance = [pscustomobject]@{
                        Total  = [long](Get-ContractProperty $ar 'total' 0)
                        Passed = [long](Get-ContractProperty $ar 'passed' 0)
                        Failed = [long](Get-ContractProperty $ar 'failed' 0)
                    }
                } else {
                    $criteria = Get-DbM18ArrayValue $acc 'criteria'
                    $m06.Acceptance = [pscustomobject]@{
                        Total     = [long]$criteria.Count
                        Passed    = $(if ([bool](Get-ContractProperty $acc 'allPassed' $false)) { [long]$criteria.Count } else { [long]0 })
                        Failed    = [long]0
                        AllPassed = [bool](Get-ContractProperty $acc 'allPassed' $false)
                        Result    = [string](Get-ContractProperty $acc 'result' '')
                    }
                }
            }
            [void]$evidenceRefs.Add([pscustomobject]@{ Kind = 'm06'; Path = ('logs/tasks/' + $TaskId + '/' + $changeId + '/build-result.json'); Provenance = 'M06' })
        }

        # claude-decision.json -- M08 Claude review outcome
        $cd2 = Read-DbM181JsonFile (Join-Path $dir 'claude-decision.json')
        if ($null -ne $cd2) {
            $decision = [string](Get-ContractProperty $cd2 'decision' '')
            $implementationState = [string](Get-ContractProperty $cd2 'implementationState' '')
            $trialMode = [bool](Get-ContractProperty $cd2 'trialMode' $false)
            $claudeOutcome = [pscustomobject]@{
                Decision           = $decision
                ImplementationState = $implementationState
                DbM06Result        = [string](Get-ContractProperty $cd2 'dbM06Result' '')
                TrialMode          = $trialMode
                ReviewedAtUtc      = [string](Get-ContractProperty $cd2 'reviewTimestampUtc' (Get-ContractProperty $cd2 'recordedAtUtc' ''))
                Provenance         = 'CLAUDE_REVIEW'
            }
            $blockingFindings = Get-DbM18ArrayValue $cd2 'blockingFindings'
            $nonBlockingObs = Get-DbM18ArrayValue $cd2 'nonBlockingObservations'
            foreach ($f in $blockingFindings) { [void]$blocking.Add($f) }
            foreach ($o in $nonBlockingObs) {
                [void]$observations.Add([pscustomobject]@{
                    Id = [string](Get-ContractProperty $o 'id' ''); Title = [string](Get-ContractProperty $o 'title' ''); Detail = [string](Get-ContractProperty $o 'detail' '')
                })
            }
            [void]$evidenceRefs.Add([pscustomobject]@{ Kind = 'claude-review'; Path = ('logs/tasks/' + $TaskId + '/' + $changeId + '/claude-decision.json'); Provenance = 'CLAUDE_REVIEW' })
        }
        if (Test-Path -LiteralPath (Join-Path $dir 'CLAUDE_REVIEW_RESULT.md')) {
            [void]$evidenceRefs.Add([pscustomobject]@{ Kind = 'claude-review-result'; Path = ('logs/tasks/' + $TaskId + '/' + $changeId + '/CLAUDE_REVIEW_RESULT.md'); Provenance = 'CLAUDE_REVIEW' })
        }
        if (Test-Path -LiteralPath (Join-Path $dir 'completion.json')) {
            [void]$evidenceRefs.Add([pscustomobject]@{ Kind = 'completion'; Path = ('logs/tasks/' + $TaskId + '/' + $changeId + '/completion.json'); Provenance = 'STATE_RESULT' })
        }
    }

    $lineage.FilesCreated = @(($createdHash.Keys | Sort-Object))
    $lineage.FilesModified = @(($modifiedHash.Keys | Sort-Object))
    $lineage.PreservedFiles = @($preserved.ToArray())
    $lineage.SupersededBy = @($superseded.ToArray())
    $lineage.ScopeAmendments = @($scopeAmendments.ToArray())
    $lineage.BlockingFindings = @($blocking.ToArray())
    $lineage.NonBlockingObservations = @($observations.ToArray())
    $lineage.ImplementationEvidence = @($evidenceRefs.ToArray())
    $lineage.M06Evidence = $m06
    $lineage.ClaudeReviewOutcome = $claudeOutcome

    # Derive component/contract/test/config/schema sets from the authoritative file delta
    $contracts = New-Object System.Collections.ArrayList
    $contractsChanged = New-Object System.Collections.ArrayList
    $classes = New-Object System.Collections.ArrayList
    $schema = New-Object System.Collections.ArrayList
    $config = New-Object System.Collections.ArrayList
    $tests = New-Object System.Collections.ArrayList
    foreach ($p in @($lineage.FilesCreated)) {
        $base = [System.IO.Path]::GetFileName($p)
        $isContract = ($p -match '/Contracts/' -or $base -match '^I[A-Z][A-Za-z0-9]*\.cs$' -or $base -match 'Contract' -or $p -match '/Abstractions/')
        if ($base -match '\.(cs|fs|vb)$') {
            if ($isContract) { [void]$contracts.Add($p) }
            else { [void]$classes.Add($base) }
        }
        if ($p -match '(?i)(schema|/migrations/)' -or $base -match '\.sql$') { [void]$schema.Add($p) }
        if ($base -match '(?i)^appsettings.*\.json$' -or $base -match '\.config$' -or $p -match '/Config/') { [void]$config.Add($p) }
        if ($p -match '(?i)/tests?/' -or $base -match '\.Tests\.') { [void]$tests.Add($p) }
    }
    foreach ($p in @($lineage.FilesModified)) {
        $base = [System.IO.Path]::GetFileName($p)
        $isContract = ($p -match '/Contracts/' -or $base -match '^I[A-Z][A-Za-z0-9]*\.cs$' -or $base -match 'Contract' -or $p -match '/Abstractions/')
        if ($isContract) { [void]$contractsChanged.Add($p) }
    }
    $lineage.ContractsCreated = @($contracts.ToArray())
    $lineage.ContractsChanged = @($contractsChanged.ToArray())
    $lineage.ClassesServicesCreated = @($classes.ToArray())
    $lineage.SchemaChanges = @($schema.ToArray())
    $lineage.ConfigChanges = @($config.ToArray())
    $lineage.TestsAdded = @($tests.ToArray())

    # Verification + completion state (deterministic)
    if ($anyBuildFail -or $anyTestFail) { $lineage.VerificationState = 'VERIFICATION_FAILED' }
    elseif ($hasVerification -and $verifPassed) { $lineage.VerificationState = 'VERIFICATION_PASSED' }
    elseif ($hasVerification) { $lineage.VerificationState = 'PENDING' }
    if ($decision -eq 'FIX') { $lineage.CompletionState = 'In Progress' }
    elseif ($implementationState -eq 'TRIAL_ONLY_UNMERGED') { $lineage.CompletionState = 'TRIAL_CYCLE_CLOSED' }
    elseif ($decision -eq 'PASS') { $lineage.CompletionState = 'Completed' }
    elseif ($hasChangedFiles -and $lineage.VerificationState -eq 'VERIFICATION_PASSED') { $lineage.CompletionState = 'Completed' }
    elseif ($hasChangedFiles -or $hasVerification) { $lineage.CompletionState = 'In Progress' }

    # Confidence
    if ($hasChangedFiles -and $hasVerification) { $lineage.Confidence = 'FULL' }
    elseif ($hasChangedFiles -or $lineage.ChangeIds.Count -gt 0) { $lineage.Confidence = 'PARTIAL' }
    else { $lineage.Confidence = 'INFERRED' }

    $lineage.LaterModifiers = @($lineage.FilesModified)
    return [pscustomobject]$lineage
}

function Build-DependencyLineageSet {
    <#
    .SYNOPSIS
    Collect DevelopmentLineage v1 records for a set of dependency task ids from the
    evidence root. Returns a sorted array (by TaskId) of lineage records.
    #>
    param([AllowNull()][object[]]$TaskIds, [string]$EvidenceRoot = $script:DbM181DefaultEvidenceRoot)
    $set = New-Object System.Collections.ArrayList
    foreach ($id in @($TaskIds)) {
        if (-not $id) { continue }
        [void]$set.Add((Get-DbM181TaskLineage -TaskId ([string]$id).Trim() -EvidenceRoot $EvidenceRoot))
    }
    return ,@($set.ToArray())
}

function Get-DbM181LineageMap {
    <#
    .SYNOPSIS
    Convenience map TaskId -> lineage record.
    #>
    param([AllowNull()][object[]]$LineageSet)
    $map = @{}
    foreach ($l in @($LineageSet)) {
        $map[[string]$l.TaskId] = $l
    }
    return $map
}

# -----------------------------------------------------------------------------
# Capability 3 -- current repository reconciliation (read-only)
# -----------------------------------------------------------------------------
function Reconcile-LineageRepository {
    <#
    .SYNOPSIS
    Reconcile every historical asset in the lineage set against a READ-ONLY walk of
    the current repository. Statuses: CURRENT | MODIFIED_LATER | SUPERSEDED |
    RENAMED_OR_MOVED | MISSING | HISTORICAL_ONLY | UNKNOWN. Current repository
    truth wins for implementation context; historical evidence is preserved.
    #>
    param(
        [AllowNull()][object[]]$LineageSet,
        [string]$RepositoryRoot,
        [string]$NowUtc = ''
    )
    $now = if ($NowUtc) { $NowUtc } else { Get-DbM181Now }
    $currentWalk = Get-DbM181RepoWalk $RepositoryRoot
    $currentByPath = @{}
    foreach ($f in $currentWalk) { $currentByPath[$f.Path.ToLowerInvariant()] = $f }

    $historical = @{}
    foreach ($l in @($LineageSet)) {
        foreach ($p in @($l.FilesCreated)) { if ($p) { $k = ([string]$p).ToLowerInvariant(); if (-not $historical.ContainsKey($k)) { $historical[$k] = [pscustomobject]@{ Path = $p; Task = [string]$l.TaskId; Kind = 'created'; Hash = $null; Later = New-Object System.Collections.ArrayList } } } }
        foreach ($p in @($l.FilesModified)) {
            if ($p) {
                $k = ([string]$p).ToLowerInvariant()
                if ($historical.ContainsKey($k)) { [void]$historical[$k].Later.Add([string]$l.TaskId) }
                else { $historical[$k] = [pscustomobject]@{ Path = $p; Task = [string]$l.TaskId; Kind = 'modified'; Hash = $null; Later = New-Object System.Collections.ArrayList } }
            }
        }
        foreach ($kv in $l.FileHashes.GetEnumerator()) {
            $k = ([string]$kv.Key).ToLowerInvariant()
            if ($historical.ContainsKey($k)) { $historical[$k].Hash = [string]$kv.Value }
        }
    }

    # supersession map: original path -> { NewPath, TaskId, ChangeId }
    $supersedeMap = @{}
    foreach ($l in @($LineageSet)) {
        foreach ($s in @($l.SupersededBy)) {
            $orig = ([string]$s.OriginalPath).ToLowerInvariant()
            if (-not $supersedeMap.ContainsKey($orig)) { $supersedeMap[$orig] = [pscustomobject]@{ NewPath = [string]$s.NewPath; TaskId = [string]$s.TaskId; ChangeId = [string]$s.ChangeId } }
        }
    }

    $entries = New-Object System.Collections.ArrayList
    foreach ($key in ($historical.Keys | Sort-Object)) {
        $h = $historical[$key]
        $rel = [string]$h.Path
        $lower = $rel.ToLowerInvariant()
        $status = 'UNKNOWN'
        $currentPath = $null
        $currentSha = $null
        $histSha = $null
        $reason = ''
        if (-not (Test-DbM18IsTextFile $rel)) {
            $status = 'HISTORICAL_ONLY'
            $reason = 'Non-text artifact; repository scan is text-file scoped.'
        } elseif ($currentByPath.ContainsKey($lower)) {
            $cur = $currentByPath[$lower]
            $currentPath = $cur.Path
            $currentSha = $cur.Sha256
            $histSha = [string]$h.Hash
            if ($histSha -and $currentSha -eq $histSha) { $status = 'CURRENT' }
            elseif ($histSha -and $currentSha -ne $histSha) { $status = 'MODIFIED_LATER' }
            else { $status = 'CURRENT' }
        } elseif ($supersedeMap.ContainsKey($lower)) {
            $sp = $supersedeMap[$lower]
            $status = 'SUPERSEDED'
            $currentPath = $sp.NewPath
            $reason = ('Superseded by ' + $sp.TaskId + ' (' + $sp.ChangeId + ') -> ' + $sp.NewPath)
        } else {
            # rename/move candidate: same basename under a different directory
            $base = [System.IO.Path]::GetFileName($rel)
            $candidate = $null
            foreach ($cur in $currentWalk) {
                if ($cur.Path.ToLowerInvariant() -eq $lower) { continue }
                if ([System.IO.Path]::GetFileName($cur.Path) -eq $base) { $candidate = $cur.Path; break }
            }
            if ($candidate) { $status = 'RENAMED_OR_MOVED'; $currentPath = $candidate; $reason = ('Likely renamed/moved to ' + $candidate) }
            else { $status = 'MISSING'; $reason = 'Not present in the current repository.' }
        }
        [void]$entries.Add([pscustomobject]@{
            HistoricalPath  = $rel
            HistoricalTask  = [string]$h.Task
            HistoricalKind  = [string]$h.Kind
            HistoricalSha256 = $histSha
            CurrentPath     = $currentPath
            CurrentSha256   = $currentSha
            LaterModifiers  = @($h.Later)
            Status          = $status
            Reason          = $reason
            Evidence        = 'CURRENT_REPOSITORY (read-only scan) + lineage evidence'
        })
    }

    return [pscustomobject]@{
        SchemaVersion   = 1
        ReconciledAtUtc = $now
        RepositoryRoot  = $RepositoryRoot
        Entries         = @($entries.ToArray())
        Provenance      = @('CURRENT_REPOSITORY')
    }
}

# -----------------------------------------------------------------------------
# Capability 4 -- lineage index
# -----------------------------------------------------------------------------
function New-LineageIndex {
    <#
    .SYNOPSIS
    Build the lineage index: asset -> original creator, later modifiers, contract
    creator, fix tasks, verified chain, current implementation, reconciliation
    status; plus a source fingerprint for freshness testing.
    #>
    param(
        [AllowNull()][object[]]$LineageSet,
        [AllowNull()][object]$Reconciliation,
        [string]$NowUtc = ''
    )
    $now = if ($NowUtc) { $NowUtc } else { Get-DbM181Now }
    $asset = @{}
    foreach ($l in @($LineageSet)) {
        foreach ($p in @($l.FilesCreated)) {
            if (-not $p) { continue }
            $k = ([string]$p).ToLowerInvariant()
            if (-not $asset.ContainsKey($k)) {
                $asset[$k] = [ordered]@{
                    AssetPath = [string]$p
                    OriginallyCreatedBy = [pscustomobject]@{ TaskId = [string]$l.TaskId; ChangeIds = @($l.ChangeIds); Provenance = [string]$l.Provenance }
                    LaterModifiedBy = New-Object System.Collections.ArrayList
                    ContractCreatedBy = $null
                    FixTasks = New-Object System.Collections.ArrayList
                    VerifiedChain = @([string]$l.TaskId)
                    ReconciliationStatus = ''
                }
            }
        }
        foreach ($c in @($l.ContractsCreated)) {
            $k = ([string]$c).ToLowerInvariant()
            if ($asset.ContainsKey($k)) { $asset[$k].ContractCreatedBy = [string]$l.TaskId }
        }
        foreach ($f in @($l.FixTasks)) {
            foreach ($key in $asset.Keys) { [void]$asset[$key].FixTasks.Add([string]$f) }
        }
    }
    foreach ($l in @($LineageSet)) {
        foreach ($p in @($l.FilesModified)) {
            if (-not $p) { continue }
            $k = ([string]$p).ToLowerInvariant()
            if ($asset.ContainsKey($k)) { [void]$asset[$k].LaterModifiedBy.Add([string]$l.TaskId) }
        }
    }
    $reconStatus = @{}
    if ($null -ne $Reconciliation) {
        foreach ($e in @($Reconciliation.Entries)) {
            $reconStatus[([string]$e.HistoricalPath).ToLowerInvariant()] = [string]$e.Status
        }
    }
    $entries = New-Object System.Collections.ArrayList
    foreach ($key in ($asset.Keys | Sort-Object)) {
        $a = $asset[$key]
        $a.ReconciliationStatus = if ($reconStatus.ContainsKey($key)) { $reconStatus[$key] } else { 'UNKNOWN' }
        [void]$entries.Add([pscustomobject]@{
            AssetPath            = [string]$a.AssetPath
            OriginallyCreatedBy  = $a.OriginallyCreatedBy
            LaterModifiedBy      = @($a.LaterModifiedBy.ToArray())
            ContractCreatedBy    = [string]$a.ContractCreatedBy
            FixTasks             = @($a.FixTasks.ToArray())
            VerifiedChain        = @($a.VerifiedChain)
            ReconciliationStatus = [string]$a.ReconciliationStatus
        })
    }
    $repoFp = ''
    if ($null -ne $Reconciliation) { $repoFp = Get-DbM181RepoFingerprint $Reconciliation.RepositoryRoot }
    $lineageFp = Get-DbM181LineageFingerprint $LineageSet
    $depIds = @()
    foreach ($l in @($LineageSet)) { $depIds += [string]$l.TaskId }
    $depSetFp = Get-DbM18Sha256Hex (($depIds | Sort-Object) -join '|')

    return [pscustomobject]@{
        SchemaVersion        = 1
        IndexId              = 'LINEAGE-INDEX'
        BuiltAtUtc           = $now
        SourceFingerprint    = Get-DbM18Sha256Hex ($repoFp + '|' + $lineageFp + '|' + $depSetFp)
        RepositoryFingerprint = $repoFp
        LineageFingerprint   = $lineageFp
        DependencySetFingerprint = $depSetFp
        Entries              = @($entries.ToArray())
        Provenance           = @('M06', 'CLAUDE_REVIEW', 'CURRENT_REPOSITORY', 'LATER_WORK_ITEM')
    }
}

# -----------------------------------------------------------------------------
# Capability 5 -- context freshness
# -----------------------------------------------------------------------------
function Test-LineageFreshness {
    <#
    .SYNOPSIS
    Compare the index's fingerprints against a fresh repository walk and a freshly
    collected lineage set. Any mismatch => DEPENDENCY_CONTEXT_STALE with explicit
    reasons; otherwise FRESH. Stale context is never consumed silently.
    #>
    param(
        [AllowNull()][object]$Index,
        [string]$RepositoryRoot,
        [AllowNull()][object[]]$LineageSet,
        [string]$NowUtc = ''
    )
    $now = if ($NowUtc) { $NowUtc } else { Get-DbM181Now }
    $reasons = New-Object System.Collections.ArrayList
    $repoFp = Get-DbM181RepoFingerprint $RepositoryRoot
    if ($repoFp -ne [string]$Index.RepositoryFingerprint) {
        [void]$reasons.Add('Repository fingerprint changed: a lineage file was created, modified, removed, renamed or its content changed.')
    }
    $lineageFp = Get-DbM181LineageFingerprint $LineageSet
    if ($lineageFp -ne [string]$Index.LineageFingerprint) {
        [void]$reasons.Add('Lineage evidence fingerprint changed: an evidence file was created, modified or removed.')
    }
    $depIds = @()
    foreach ($l in @($LineageSet)) { $depIds += [string]$l.TaskId }
    $depSetFp = Get-DbM18Sha256Hex (($depIds | Sort-Object) -join '|')
    if ($depSetFp -ne [string]$Index.DependencySetFingerprint) {
        [void]$reasons.Add('Dependency set changed: the set of dependency task ids differs from the indexed set.')
    }
    $status = if ($reasons.Count -gt 0) { 'DEPENDENCY_CONTEXT_STALE' } else { 'FRESH' }
    return [pscustomobject]@{
        SchemaVersion           = 1
        TaskId                  = ''
        FreshnessStatus         = $status
        StaleReasons            = @($reasons.ToArray())
        CurrentRepositoryFingerprint = $repoFp
        IndexedFingerprint      = [string]$Index.SourceFingerprint
        RebuildRequired         = ($reasons.Count -gt 0)
        TestedAtUtc             = $now
        Provenance              = @('CURRENT_REPOSITORY')
    }
}

# -----------------------------------------------------------------------------
# Capability 6 -- relevance filter (deterministic)
# -----------------------------------------------------------------------------
function Get-DbM181Relevance {
    <#
    .SYNOPSIS
    Score each dependency in the resolved graph RELEVANT | SUPPORTING |
    NOT_RELEVANT | UNKNOWN_RELEVANCE based on evidence-based signal overlap with
    the current task's scope. Default context includes RELEVANT + SUPPORTING only.
    #>
    param(
        [AllowNull()][object]$Graph,
        [AllowNull()][object[]]$LineageSet,
        [AllowNull()][object]$Task
    )
    $lineageMap = Get-DbM181LineageMap $LineageSet

    $globs = Get-DbM18ArrayValue $Task 'filesGlobs'
    if ($globs.Count -eq 0) { $rs = Get-ContractProperty $Task 'reservedScope' $null; $globs = Get-DbM18ArrayValue $rs 'filesGlobs' }
    $projects = Get-DbM18ArrayValue $Task 'projects'
    if ($projects.Count -eq 0) { $rs = Get-ContractProperty $Task 'reservedScope' $null; $projects = Get-DbM18ArrayValue $rs 'projects' }
    $contracts = Get-DbM18ArrayValue $Task 'contractsApis'
    if ($contracts.Count -eq 0) { $rs = Get-ContractProperty $Task 'reservedScope' $null; $contracts = Get-DbM18ArrayValue $rs 'contractsApis' }
    $schemaCtx = Get-DbM18ArrayValue $Task 'schemaContexts'
    if ($schemaCtx.Count -eq 0) { $rs = Get-ContractProperty $Task 'reservedScope' $null; $schemaCtx = Get-DbM18ArrayValue $rs 'schemaContexts' }
    $goalText = [string](Get-ContractProperty $Task 'goal' '')
    $ac = Get-DbM18ArrayValue $Task 'acceptanceCriteria'
    $acText = ''
    foreach ($a in $ac) { $acText += ' ' + [string]$a }

    $deps = New-Object System.Collections.ArrayList
    foreach ($d in @($Graph.DirectDependencies)) { [void]$deps.Add([pscustomobject]@{ DependencyId = [string]$d.DependencyId; Depth = 1 }) }
    foreach ($d in @($Graph.TransitiveDependencies)) { [void]$deps.Add([pscustomobject]@{ DependencyId = [string]$d.DependencyId; Depth = [int]$d.Depth }) }

    $rel = New-Object System.Collections.ArrayList
    foreach ($d in @($deps)) {
        $id = [string]$d.DependencyId
        if (-not (Get-DbM181IsNodeDependency $id)) {
            [void]$rel.Add([pscustomobject]@{ DependencyId = $id; Relevance = 'UNKNOWN_RELEVANCE'; Reason = 'Non-node reference; no lineage evidence expected.' })
            continue
        }
        if (-not $lineageMap.ContainsKey($id)) {
            [void]$rel.Add([pscustomobject]@{ DependencyId = $id; Relevance = 'UNKNOWN_RELEVANCE'; Reason = 'No lineage evidence recorded for this dependency.' })
            continue
        }
        $l = $lineageMap[$id]
        $scopeOverlap = $false
        foreach ($p in @($l.FilesCreated) + @($l.FilesModified)) {
            if (Test-DbM18FileInScope -Path $p -Globs $globs) { $scopeOverlap = $true; break }
        }
        $projectOverlap = $false
        foreach ($pp in @($l.Projects)) {
            foreach ($tp in $projects) { if ([string]$pp -eq [string]$tp) { $projectOverlap = $true; break } }
            if ($projectOverlap) { break }
        }
        $contractOverlap = $false
        foreach ($c in @($l.ContractsCreated) + @($l.ContractsChanged)) {
            $cb = [System.IO.Path]::GetFileName([string]$c)
            foreach ($tc in $contracts) {
                if ($cb -eq [string]$tc -or [string]$c -like ('*' + [string]$tc + '*')) { $contractOverlap = $true; break }
            }
            if ($contractOverlap) { break }
        }
        $schemaOverlap = $false
        foreach ($s in @($l.SchemaChanges)) {
            foreach ($ts in $schemaCtx) { if ([string]$s -like ('*' + [string]$ts + '*')) { $schemaOverlap = $true; break } }
            if ($schemaOverlap) { break }
        }
        $configOverlap = ($l.ConfigChanges.Count -gt 0)
        $symbolOverlap = $false
        foreach ($cls in @($l.ClassesServicesCreated)) {
            $clsBase = [System.IO.Path]::GetFileName([string]$cls)
            $hay = $goalText + ' ' + $acText
            if ($hay -and $hay.ToLowerInvariant().Contains([string]$clsBase.ToLowerInvariant())) { $symbolOverlap = $true; break }
        }

        $signal = ''
        if ($scopeOverlap) { $signal = 'scope-path overlap' }
        elseif ($projectOverlap) { $signal = 'project overlap' }
        elseif ($contractOverlap) { $signal = 'contract overlap' }
        elseif ($schemaOverlap) { $signal = 'schema-object overlap' }
        elseif ($configOverlap) { $signal = 'configuration overlap' }
        if ($signal) {
            [void]$rel.Add([pscustomobject]@{ DependencyId = $id; Relevance = 'RELEVANT'; Reason = $signal })
        } elseif ($symbolOverlap -or $d.Depth -le 2) {
            [void]$rel.Add([pscustomobject]@{ DependencyId = $id; Relevance = 'SUPPORTING'; Reason = ($(if ($symbolOverlap) { 'symbol/class overlap with current goal' } else { 'transitive proximity (depth <= 2)' })) })
        } else {
            [void]$rel.Add([pscustomobject]@{ DependencyId = $id; Relevance = 'NOT_RELEVANT'; Reason = 'No evidence-based signal of overlap with the current task scope.' })
        }
    }

    $omitted = New-Object System.Collections.ArrayList
    foreach ($r in @($rel.ToArray())) {
        if ($r.Relevance -in @('NOT_RELEVANT', 'UNKNOWN_RELEVANCE')) {
            [void]$omitted.Add([pscustomobject]@{ DependencyId = [string]$r.DependencyId; Relevance = [string]$r.Relevance; Reason = [string]$r.Reason })
        }
    }
    return [pscustomobject]@{
        SchemaVersion        = 1
        TaskId               = [string](Get-ContractProperty $Task 'taskId' '')
        Relevance            = @($rel.ToArray())
        OmittedDependencyReferences = @($omitted.ToArray())
        Provenance           = @('CURRENT_REPOSITORY', 'M06', 'WORKBOOK')
    }
}

# -----------------------------------------------------------------------------
# Capability 7 + 14 -- dependency development context package + token control
# -----------------------------------------------------------------------------
function Build-DependencyDevelopmentContext {
    <#
    .SYNOPSIS
    Assemble the compact DependencyDevelopmentContext v1 for the current task from
    the graph, lineage set, reconciliation, relevance report and freshness report.
    Includes ContextMetrics (candidate vs filtered size, token estimate, omission
    reasons). READ-ONLY assembly; secrets guarded.
    #>
    param(
        [AllowNull()][object]$Task,
        [AllowNull()][object]$Graph,
        [AllowNull()][object[]]$LineageSet,
        [AllowNull()][object]$Reconciliation,
        [AllowNull()][object]$Relevance,
        [AllowNull()][object]$Freshness,
        [string]$NowUtc = ''
    )
    $now = if ($NowUtc) { $NowUtc } else { Get-DbM181Now }
    $lineageMap = Get-DbM181LineageMap $LineageSet
    $relByDep = @{}
    $relReasons = @{}
    if ($null -ne $Relevance) {
        foreach ($r in @($Relevance.Relevance)) { $relByDep[[string]$r.DependencyId] = [string]$r.Relevance; $relReasons[[string]$r.DependencyId] = [string]$r.Reason }
    }
    $reconByPath = @{}
    if ($null -ne $Reconciliation) {
        foreach ($e in @($Reconciliation.Entries)) { $reconByPath[([string]$e.HistoricalPath).ToLowerInvariant()] = $e }
    }
    $freshStatus = 'FRESH'
    $freshReasons = @()
    if ($null -ne $Freshness) { $freshStatus = [string]$Freshness.FreshnessStatus; $freshReasons = @($Freshness.StaleReasons) }
    $provenance = @{}
    foreach ($pv in @(Get-ContractProperty $Graph 'Provenance' @())) { if ($pv) { $provenance[$pv] = $true } }
    foreach ($pv in @(Get-ContractProperty $Reconciliation 'Provenance' @())) { if ($pv) { $provenance[$pv] = $true } }
    foreach ($pv in @(Get-ContractProperty $Relevance 'Provenance' @())) { if ($pv) { $provenance[$pv] = $true } }
    foreach ($pv in @(Get-ContractProperty $Freshness 'Provenance' @())) { if ($pv) { $provenance[$pv] = $true } }

    $allDepIds = New-Object System.Collections.ArrayList
    foreach ($d in @($Graph.DirectDependencies)) { if (-not $allDepIds.Contains([string]$d.DependencyId)) { [void]$allDepIds.Add([string]$d.DependencyId) } }
    foreach ($d in @($Graph.TransitiveDependencies)) { if (-not $allDepIds.Contains([string]$d.DependencyId)) { [void]$allDepIds.Add([string]$d.DependencyId) } }

    $delivered = New-Object System.Collections.ArrayList
    $candidateLines = New-Object System.Collections.ArrayList
    $includedLines = New-Object System.Collections.ArrayList
    $reusePoints = New-Object System.Collections.ArrayList
    $extensionPoints = New-Object System.Collections.ArrayList
    $collisionPoints = New-Object System.Collections.ArrayList
    $omissionReasons = New-Object System.Collections.ArrayList
    $includedCount = 0
    $knownLimitations = New-Object System.Collections.ArrayList
    $observations = New-Object System.Collections.ArrayList
    $superseded = New-Object System.Collections.ArrayList

    foreach ($id in @($allDepIds.ToArray())) {
        $isRelevant = ($relByDep[$id] -in @('RELEVANT', 'SUPPORTING'))
        $omitted = (-not $isRelevant)
        if ($omitted -and $relReasons.ContainsKey($id)) { [void]$omissionReasons.Add(($id + ': ' + $relReasons[$id])) }
        if ($isRelevant) { $includedCount = $includedCount + 1 }

        if ($lineageMap.ContainsKey($id)) {
            $l = $lineageMap[$id]
            $summary = [pscustomobject]@{
                DependencyId        = $id
                Purpose             = [string]$l.OriginalPurpose
                CompletionState     = [string]$l.CompletionState
                VerificationState   = [string]$l.VerificationState
                ClaudeDecision      = $(if ($null -ne $l.ClaudeReviewOutcome) { [string]$l.ClaudeReviewOutcome.Decision } else { '' })
                FilesCount          = (@($l.FilesCreated).Count + @($l.FilesModified).Count)
                ContractsCreated    = @($l.ContractsCreated)
                ClassesServicesCreated = @($l.ClassesServicesCreated)
                TestsAdded          = @($l.TestsAdded)
                KnownLimitations    = @($l.KnownLimitations)
                Confidence          = [string]$l.Confidence
                Relevance           = [string]$relByDep[$id]
                Provenance          = @($l.Provenance)
            }
            [void]$delivered.Add($summary)
            foreach ($pv in @($l.Provenance)) { $provenance[$pv] = $true }
            foreach ($e in @($l.ImplementationEvidence)) { if ($e.Provenance) { $provenance[[string]$e.Provenance] = $true } }
            if ($null -ne $l.ClaudeReviewOutcome -and $l.ClaudeReviewOutcome.Provenance) { $provenance[[string]$l.ClaudeReviewOutcome.Provenance] = $true }
            foreach ($sa in @($l.ScopeAmendments)) { foreach ($spv in @($sa.Provenance)) { if ($spv) { $provenance[$spv] = $true } } }
            $line = $id + ': ' + (Get-DbM181GuardedText ([string]$l.OriginalPurpose)) + ' | ' + [string]$l.CompletionState + ' | ' + [string]$l.VerificationState + ' | ' + [string]$l.Confidence
            if ($null -ne $l.ClaudeReviewOutcome) { $line += ' | claude=' + [string]$l.ClaudeReviewOutcome.Decision }
            [void]$candidateLines.Add($line)
            if ($isRelevant) { [void]$includedLines.Add($line) }

            # reuse / extension / collision points (evidence-based)
            if ($l.VerificationState -eq 'VERIFICATION_PASSED' -and $l.ContractsCreated.Count -gt 0) {
                foreach ($c in @($l.ContractsCreated)) { [void]$reusePoints.Add(('Reuse ' + $c + ' (verified, ' + $id + ')')) }
            }
            if ($l.CompletionState -eq 'Completed' -and $l.ClassesServicesCreated.Count -gt 0) {
                foreach ($cls in @($l.ClassesServicesCreated)) { [void]$extensionPoints.Add(('Extend ' + $cls + ' via new in-scope work (owned by completed ' + $id + ')')) }
            }
            if (@($l.LaterModifiers).Count -gt 0 -and $l.FilesModified.Count -gt 0) {
                foreach ($m in @($l.FilesModified)) { [void]$collisionPoints.Add(('Collision risk on ' + $m + ' (later modified)')) }
            }
            foreach ($k in @($l.KnownLimitations)) { [void]$knownLimitations.Add($k) }
            if ($null -ne $l.ClaudeReviewOutcome) {
                foreach ($o in @($l.NonBlockingObservations)) { [void]$observations.Add(($id + ': ' + [string]$o.Title)) }
            }
        } else {
            $line = $id + ': (no lineage evidence)'
            [void]$candidateLines.Add($line)
            if ($isRelevant) { [void]$includedLines.Add($line) }
        }
    }

    # current files + contracts with reconciliation status (relevant deps only)
    $currentFiles = New-Object System.Collections.ArrayList
    $currentContracts = New-Object System.Collections.ArrayList
    foreach ($d in @($delivered.ToArray())) {
        $id = [string]$d.DependencyId
        if ($relByDep[$id] -notin @('RELEVANT', 'SUPPORTING')) { continue }
        foreach ($p in @($d.ContractsCreated)) {
            $k = ([string]$p).ToLowerInvariant()
            $st = 'UNKNOWN'
            if ($reconByPath.ContainsKey($k)) { $st = [string]$reconByPath[$k].Status }
            [void]$currentContracts.Add([pscustomobject]@{ Contract = [string]$p; CreatedBy = $id; Status = $st })
        }
    }
    foreach ($d in @($delivered.ToArray())) {
        $id = [string]$d.DependencyId
        if ($relByDep[$id] -notin @('RELEVANT', 'SUPPORTING')) { continue }
        foreach ($p in @($d.ClassesServicesCreated)) {
            [void]$currentFiles.Add([pscustomobject]@{ File = [string]$p; CreatedBy = $id; Status = 'derived' })
        }
    }
    if ($null -ne $Reconciliation) {
        foreach ($e in @($Reconciliation.Entries)) {
            $histTask = [string]$e.HistoricalTask
            if ($relByDep[$histTask] -notin @('RELEVANT', 'SUPPORTING')) { continue }
            if ($e.Status -eq 'SUPERSEDED') { [void]$superseded.Add([pscustomobject]@{ Original = [string]$e.HistoricalPath; Current = [string]$e.CurrentPath; Reason = [string]$e.Reason }) }
            $cl = [pscustomobject]@{ File = [string]$e.HistoricalPath; CreatedBy = $histTask; Status = [string]$e.Status; CurrentPath = [string]$e.CurrentPath }
            [void]$currentFiles.Add($cl)
            [void]$candidateLines.Add(('file ' + $e.HistoricalPath + ' [' + $e.Status + ']'))
            if ($relByDep[$histTask] -in @('RELEVANT', 'SUPPORTING')) { [void]$includedLines.Add(('file ' + $e.HistoricalPath + ' [' + $e.Status + ']')) }
        }
    }

    $candSize = 0L
    foreach ($cl in @($candidateLines.ToArray())) { $candSize += [long]([string]$cl).Length }
    $filtSize = 0L
    foreach ($il in @($includedLines.ToArray())) { $filtSize += [long]([string]$il).Length }
    $filteredPayload = ($includedLines.ToArray() -join "`n")
    if (Test-DbM18SecretText $filteredPayload) { $filteredPayload = Get-DbM18RedactionMarker 'section' }

    $metrics = [pscustomobject]@{
        SchemaVersion             = 1
        CandidateContextSize      = $candSize
        FilteredContextSize       = $filtSize
        EstimatedTokens           = Get-EstimatedTokenCount $filteredPayload
        DependencyCount           = $allDepIds.Count
        IncludedDependencyCount   = $includedCount
        OmittedDependencyCount    = ($allDepIds.Count - $includedCount)
        OmissionReasons           = @($omissionReasons.ToArray())
    }

    $taskId = [string](Get-ContractProperty $Task 'taskId' '')
    $nodeId = Get-DbM18First @((Get-ContractProperty $Task 'nodeId' $null), $taskId, '')
    return [pscustomobject]@{
        SchemaVersion          = 1
        ContextId              = 'DDC-' + $taskId
        CurrentTask            = [pscustomobject]@{ TaskId = $taskId; NodeId = [string]$nodeId; ChangeId = [string](Get-ContractProperty $Task 'changeId' ''); Name = [string](Get-ContractProperty $Task 'name' '') }
        DirectDependencies     = @($Graph.DirectDependencies)
        RelevantTransitiveDependencies = @($Graph.TransitiveDependencies)
        DeliveredSummary       = @($delivered.ToArray())
        CurrentFiles           = @($currentFiles.ToArray())
        CurrentContracts       = @($currentContracts.ToArray())
        RelevantClassesServices = @($currentFiles.ToArray())
        RelevantSchemaConfig   = @()
        TestsEvidence          = @()
        LaterChanges           = @()
        Fixes                  = @()
        SupersededComponents   = @($superseded.ToArray())
        CurrentRepositoryTruth = [pscustomobject]@{ Status = $freshStatus; Reasons = $freshReasons }
        KnownLimitations       = @($knownLimitations.ToArray())
        ClaudeObservations     = @($observations.ToArray())
        ReusePoints            = @($reusePoints.ToArray())
        ExtensionPoints        = @($extensionPoints.ToArray())
        CollisionPoints        = @($collisionPoints.ToArray())
        Provenance             = @($provenance.Keys | Sort-Object)
        Confidence             = $(if ($allDepIds.Count -eq 0) { 'FULL' } else { 'PARTIAL' })
        FreshnessStatus        = $freshStatus
        ContextMetrics         = $metrics
        PackageHash            = Get-DbM181CanonicalHash $metrics
        GeneratedAtUtc         = $now
    }
}

function Get-DbM181DependencyContextSummary {
    <#
    .SYNOPSIS
    Compact, JSON-serializable summary of the dependency development context plus
    a rendered markdown form. UI-discoverable (like Get-ContextPackageSummary).
    #>
    param(
        [AllowNull()][object]$Context,
        [switch]$AsMarkdown
    )
    $m = $Context.ContextMetrics
    $summary = [pscustomobject]@{
        ContextId              = [string]$Context.ContextId
        TaskId                 = [string]$Context.CurrentTask.TaskId
        FreshnessStatus        = [string]$Context.FreshnessStatus
        DependencyCount        = [long]$m.DependencyCount
        IncludedDependencyCount = [long]$m.IncludedDependencyCount
        OmittedDependencyCount = [long]$m.OmittedDependencyCount
        OmissionReasons        = @($m.OmissionReasons)
        CandidateContextSize   = [long]$m.CandidateContextSize
        FilteredContextSize    = [long]$m.FilteredContextSize
        EstimatedTokens        = [long]$m.EstimatedTokens
        PackageHash            = [string]$Context.PackageHash
    }
    if ($AsMarkdown) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('### Dependency Development Context (DB-M18.1)')
        [void]$sb.AppendLine(('- Freshness: ' + [string]$Context.FreshnessStatus))
        [void]$sb.AppendLine(('- Dependencies: ' + $m.DependencyCount + ' (included ' + $m.IncludedDependencyCount + ', omitted ' + $m.OmittedDependencyCount + ')'))
        [void]$sb.AppendLine(('- Context size: ' + $m.FilteredContextSize + ' chars (candidate ' + $m.CandidateContextSize + ') - estimated tokens ' + $m.EstimatedTokens + ' (chars/4, labeled)'))
        foreach ($d in @($Context.DeliveredSummary)) {
            [void]$sb.AppendLine(('- ' + $d.DependencyId + ': ' + (Get-DbM181GuardedText ([string]$d.Purpose)) + ' | ' + $d.CompletionState + ' | ' + $d.VerificationState))
        }
        return $sb.ToString().TrimEnd()
    }
    return $summary
}

# -----------------------------------------------------------------------------
# Capability 16 -- one-shot orchestration (M05/M07/M09 integration contract)
# -----------------------------------------------------------------------------
function Get-DbM181TaskDependencyContext {
    <#
    .SYNOPSIS
    One-shot orchestration for the M05/M07/M09 integration hooks (and any future
    caller): resolve the dependency graph, collect per-dependency development
    lineage, reconcile against the current repository, build the lineage index,
    test freshness, score relevance and assemble the Dependency Development
    Context. Returns a bundle { Graph, LineageSet, Reconciliation, Index,
    Freshness, Relevance, Context }.

    .NOTES
    READ-ONLY and deterministic. RepositoryRoot is optional: when absent or
    unreadable, reconciliation is skipped and freshness is 'UNVERIFIED' (never
    falsely STALE, so an unavailable repository cannot block a governed handoff).
    Soft failures degrade to the UNVERIFIED freshness fallback rather than
    throwing. TaskCatalog is a nodeId -> task shape map (see Resolve-DependencyGraph).
    #>
    param(
        [AllowNull()][object]$Task,
        [AllowNull()][hashtable]$TaskCatalog,
        [string]$EvidenceRoot = $script:DbM181DefaultEvidenceRoot,
        [AllowNull()][string]$RepositoryRoot,
        [string]$NowUtc = ''
    )
    $now = if ($NowUtc) { $NowUtc } else { Get-DbM181Now }
    $graph = Resolve-DependencyGraph -Task $Task -TaskCatalog $TaskCatalog -NowUtc $now

    $ids = New-Object System.Collections.ArrayList
    foreach ($d in @($graph.DirectDependencies)) { if (-not $ids.Contains([string]$d.DependencyId)) { [void]$ids.Add([string]$d.DependencyId) } }
    foreach ($d in @($graph.TransitiveDependencies)) { if (-not $ids.Contains([string]$d.DependencyId)) { [void]$ids.Add([string]$d.DependencyId) } }
    $lineageSet = Build-DependencyLineageSet -TaskIds @($ids.ToArray()) -EvidenceRoot $EvidenceRoot

    $recon = $null
    $index = $null
    $fresh = $null
    $repoOk = $false
    if ($RepositoryRoot) { $repoOk = Test-Path -LiteralPath $RepositoryRoot }
    if ($repoOk) {
        try {
            $recon = Reconcile-LineageRepository -LineageSet $lineageSet -RepositoryRoot $RepositoryRoot -NowUtc $now
            $index = New-LineageIndex -LineageSet $lineageSet -Reconciliation $recon -NowUtc $now
            $fresh = Test-LineageFreshness -Index $index -RepositoryRoot $RepositoryRoot -LineageSet $lineageSet -NowUtc $now
        } catch {
            $recon = $null; $index = $null; $fresh = $null; $repoOk = $false
        }
    }
    if ($null -eq $fresh) {
        $fresh = [pscustomobject]@{
            SchemaVersion = 1; TaskId = [string](Get-ContractProperty $Task 'taskId' '')
            FreshnessStatus = 'UNVERIFIED'
            StaleReasons = @('Repository root unavailable; freshness untested. Stale context is not assumed.')
            RebuildRequired = $false; TestedAtUtc = $now; Provenance = @('CURRENT_REPOSITORY')
        }
    }

    $rel = Get-DbM181Relevance -Graph $graph -LineageSet $lineageSet -Task $Task
    $context = Build-DependencyDevelopmentContext -Task $Task -Graph $graph -LineageSet $lineageSet `
        -Reconciliation $recon -Relevance $rel -Freshness $fresh -NowUtc $now

    return [pscustomobject]@{
        Graph = $graph; LineageSet = $lineageSet; Reconciliation = $recon; Index = $index
        Freshness = $fresh; Relevance = $rel; Context = $context
    }
}

# -----------------------------------------------------------------------------
# Capability 8 -- M05 handoff integration (lineage section + readiness gate)
# -----------------------------------------------------------------------------
function Get-DbM181HandoffLineageSection {
    <#
    .SYNOPSIS
    Markdown section for New-ChatGptHandoff.ps1's Dependencies area. Emits a
    compact lineage block, or a one-line "no lineage evidence" note. Never alters
    existing handoff sections.
    #>
    param(
        [AllowNull()][object]$Task,
        [AllowNull()][object]$Context
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('## Dependency Development Lineage (DB-M18.1)')
    $delivered = @($Context.DeliveredSummary)
    if ($delivered.Count -eq 0) {
        [void]$sb.AppendLine('- No lineage evidence recorded for this task''s dependencies. Dependencies are governed references only.')
        return $sb.ToString().TrimEnd()
    }
    foreach ($d in $delivered) {
        [void]$sb.AppendLine(('- ' + $d.DependencyId + ': ' + (Get-DbM181GuardedText ([string]$d.Purpose)) + ' | ' + $d.CompletionState + ' | ' + $d.VerificationState + ' | confidence ' + $d.Confidence))
    }
    $f = [string]$Context.FreshnessStatus
    [void]$sb.AppendLine(('- Context freshness: ' + $f))
    return $sb.ToString().TrimEnd()
}

function Test-DbM181HandoffReadiness {
    <#
    .SYNOPSIS
    M05 readiness gate: a required-but-unresolved or stale dependency lineage yields
    CHATGPT_HANDOFF_NOT_READY. A leaf task (no node dependencies) is NOT_REQUIRED
    and never falsely blocked. Never removes mandatory zero-context M05 sections.
    #>
    param(
        [AllowNull()][object]$Task,
        [AllowNull()][object]$Context,
        [AllowNull()][object]$Graph,
        [string]$NowUtc = ''
    )
    $now = if ($NowUtc) { $NowUtc } else { Get-DbM181Now }
    $taskId = [string](Get-ContractProperty $Task 'taskId' '')
    $nodeDeps = New-Object System.Collections.ArrayList
    foreach ($d in @($Graph.DirectDependencies)) {
        if (Get-DbM181IsNodeDependency ([string]$d.DependencyId)) { [void]$nodeDeps.Add([string]$d.DependencyId) }
    }
    if ($nodeDeps.Count -eq 0) {
        return [pscustomobject]@{
            SchemaVersion = 1; TaskId = $taskId; LineageStatus = 'NOT_REQUIRED'; Ready = $true
            HandoffToken = 'CHATGPT_HANDOFF_READY'; Reason = 'No node dependencies require lineage context.'; TestedAtUtc = $now
        }
    }
    $unresolved = New-Object System.Collections.ArrayList
    foreach ($id in @($nodeDeps.ToArray())) {
        $found = $false
        foreach ($d in @($Context.DeliveredSummary)) { if ([string]$d.DependencyId -eq $id) { $found = $true; break } }
        if (-not $found) { [void]$unresolved.Add($id) }
    }
    if ($unresolved.Count -gt 0) {
        return [pscustomobject]@{
            SchemaVersion = 1; TaskId = $taskId; LineageStatus = 'UNRESOLVED'; Ready = $false
            HandoffToken = 'CHATGPT_HANDOFF_NOT_READY'; Reason = ('Lineage unresolved for: ' + ($unresolved.ToArray() -join ', ')); TestedAtUtc = $now
        }
    }
    if ([string]$Context.FreshnessStatus -eq 'DEPENDENCY_CONTEXT_STALE') {
        return [pscustomobject]@{
            SchemaVersion = 1; TaskId = $taskId; LineageStatus = 'STALE'; Ready = $false
            HandoffToken = 'CHATGPT_HANDOFF_NOT_READY'; Reason = 'Dependency context is stale; rebuild before handoff.'; TestedAtUtc = $now
        }
    }
    return [pscustomobject]@{
        SchemaVersion = 1; TaskId = $taskId; LineageStatus = 'READY'; Ready = $true
        HandoffToken = 'CHATGPT_HANDOFF_READY'; Reason = 'Required dependency lineage resolved and fresh.'; TestedAtUtc = $now
    }
}

# -----------------------------------------------------------------------------
# Capability 9 -- M07 review package integration
# -----------------------------------------------------------------------------
function Get-DbM181ClaudeDependencyContext {
    <#
    .SYNOPSIS
    Compact dependency-context block for the M07 Claude review package: relevant
    dependencies only (Claude is not flooded with irrelevant history).
    #>
    param(
        [AllowNull()][object]$Task,
        [AllowNull()][object]$Context
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('## Dependency Development Context (DB-M18.1)')
    $delivered = @($Context.DeliveredSummary)
    if ($delivered.Count -eq 0) {
        [void]$sb.AppendLine('No lineage evidence recorded (relevant dependencies only). Dependencies are governed references.')
        return $sb.ToString().TrimEnd()
    }
    $relevant = @($delivered | Where-Object { $_.Relevance -eq '' -or $_.Relevance -in @('RELEVANT', 'SUPPORTING') })
    [void]$sb.AppendLine('Relevant dependencies: ' + $relevant.Count)
    foreach ($d in $relevant) {
        $contracts = @($d.ContractsCreated).Count
        [void]$sb.AppendLine(('- ' + $d.DependencyId + ': ' + (Get-DbM181GuardedText ([string]$d.Purpose)) + '; verified ' + $d.VerificationState + '; contracts ' + $contracts + '; claude ' + $d.ClaudeDecision))
    }
    foreach ($c in @($Context.SupersededComponents)) {
        [void]$sb.AppendLine(('- SUPERSEDED: ' + $c.Original + ' -> ' + $c.Current))
    }
    return $sb.ToString().TrimEnd()
}

# -----------------------------------------------------------------------------
# Capability 10 -- M09 correction context integration
# -----------------------------------------------------------------------------
function Get-DbM181CorrectionDependencyContext {
    <#
    .SYNOPSIS
    Focused dependency-context block for the M09 fix context: affected component,
    original creator, later modifiers, current repository implementation, and the
    correction routing for dependency-owned work.
    #>
    param(
        [AllowNull()][object]$Task,
        [AllowNull()][object]$Context,
        [AllowNull()][string]$AffectedFile
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('### Dependency Context (DB-M18.1)')
    if (-not $AffectedFile) { $AffectedFile = [string](Get-ContractProperty $Task 'goal' '') }
    [void]$sb.AppendLine(('- Affected scope: ' + (Get-DbM181GuardedText ([string]$AffectedFile))))
    $creator = ''
    foreach ($f in @($Context.CurrentFiles)) {
        if ([string]$f.File -eq $AffectedFile) {
            $creator = [string]$f.CreatedBy
            [void]$sb.AppendLine(('- File status: ' + $f.Status + ' (created by ' + $f.CreatedBy + ')'))
            break
        }
    }
    if (-not $creator) {
        [void]$sb.AppendLine('- File not in dependency lineage; governed scope check applies (SCOPE_CHANGE_REQUIRED if outside reserved scope).')
    } else {
        [void]$sb.AppendLine('- Correction routing: CORRECT_CURRENT_ATTEMPT (in-attempt) / NEW_FIX_TASK_REQUIRED (post-completion) / HUMAN_GOVERNANCE_REQUIRED (unrepresentable).')
    }
    return $sb.ToString().TrimEnd()
}

# -----------------------------------------------------------------------------
# Capability 11 -- scope-change handling
# -----------------------------------------------------------------------------
function Test-DbM181ScopeChange {
    <#
    .SYNOPSIS
    Decide whether a proposed modification to a file stays inside the current
    task's governed scope. Outside scope => SCOPE_CHANGE_REQUIRED (never added
    silently); inside => CONTINUE. Dependency-owned files are named when known.
    #>
    param(
        [AllowNull()][object]$Task,
        [string]$FilePath,
        [AllowNull()][object]$Context
    )
    $taskId = [string](Get-ContractProperty $Task 'taskId' '')
    $globs = Get-DbM18ArrayValue $Task 'filesGlobs'
    if ($globs.Count -eq 0) { $rs = Get-ContractProperty $Task 'reservedScope' $null; $globs = Get-DbM18ArrayValue $rs 'filesGlobs' }
    $repos = Get-DbM18ArrayValue $Task 'repositories'
    if ($repos.Count -eq 0) { $rs = Get-ContractProperty $Task 'reservedScope' $null; $repos = Get-DbM18ArrayValue $rs 'repositories' }

    $inScope = (Test-DbM18FileInScope -Path $FilePath -Globs $globs)
    if (-not $inScope) {
        # a file inside any governed repository but outside the reserved globs is
        # still a scope change; dependency ownership is reported when known.
        $owner = ''
        $creator = ''
        foreach ($f in @($Context.CurrentFiles)) {
            if ([string]$f.File -eq $FilePath) { $owner = [string]$f.CreatedBy; $creator = [string]$f.CreatedBy; break }
        }
        return [pscustomobject]@{
            SchemaVersion = 1; TaskId = $taskId; FilePath = $FilePath; InGovernedScope = $false
            Decision = 'SCOPE_CHANGE_REQUIRED'; CurrentOwner = $owner; OriginalCreator = $creator
            Reason = 'File is outside the reserved scope of this task; a governed scope amendment is required before modification.'
        }
    }
    return [pscustomobject]@{
        SchemaVersion = 1; TaskId = $taskId; FilePath = $FilePath; InGovernedScope = $true
        Decision = 'CONTINUE'; CurrentOwner = $taskId; OriginalCreator = $taskId
        Reason = 'File is inside the reserved scope; modification continues under the existing change.'
    }
}

# -----------------------------------------------------------------------------
# Capability 12 -- dependency-defect classification
# -----------------------------------------------------------------------------
function Classify-DbM181DependencyDefect {
    <#
    .SYNOPSIS
    Classify a defect/change against a dependency. Normal reuse/extensions are NOT
    defects. Genuine defects preserve original history and route to
    CORRECT_CURRENT_ATTEMPT / NEW_FIX_TASK_REQUIRED / HUMAN_GOVERNANCE_REQUIRED.
    Original history is always preserved (never reopened).
    #>
    param(
        [AllowNull()][object]$Task,
        [AllowNull()][object]$Context,
        [string]$DependencyId,
        [string]$DefectNature = 'EXTENSION',
        [bool]$DependencyActive = $false,
        [bool]$Unrepresentable = $false,
        [string]$AffectedFile = ''
    )
    $taskId = [string](Get-ContractProperty $Task 'taskId' '')
    $inGraph = $false
    if ($null -ne $Context) {
        foreach ($d in @($Context.DeliveredSummary)) { if ([string]$d.DependencyId -eq $DependencyId) { $inGraph = $true; break } }
    }
    if (-not $inGraph) {
        throw [System.ArgumentException] ('DependencyId ''{0}'' is not part of this task''s resolved dependency set.' -f $DependencyId)
    }
    $isCurrentTask = ($DependencyId -eq $taskId)
    switch ($DefectNature.ToLowerInvariant()) {
        'reuse' {
            return [pscustomobject]@{
                SchemaVersion = 1; DependencyId = $DependencyId
                Classification = 'NORMAL_DEPENDENCY_REUSE'; Routing = 'CORRECT_CURRENT_ATTEMPT'
                PreservedOriginalHistory = $true; Reason = 'Dependency is reused as-is; no defect.'
            }
        }
        'extension' {
            $routing = if ($isCurrentTask -or $DependencyActive) { 'CORRECT_CURRENT_ATTEMPT' } else { 'NEW_FIX_TASK_REQUIRED' }
            return [pscustomobject]@{
                SchemaVersion = 1; DependencyId = $DependencyId
                Classification = 'NORMAL_DEPENDENCY_EXTENSION'; Routing = $routing
                PreservedOriginalHistory = $true; Reason = 'Extension of dependency behavior under the existing structure.'
            }
        }
        'scope_expansion' {
            $routing = if ($isCurrentTask -or $DependencyActive) { 'CORRECT_CURRENT_ATTEMPT' } else { 'NEW_FIX_TASK_REQUIRED' }
            return [pscustomobject]@{
                SchemaVersion = 1; DependencyId = $DependencyId
                Classification = 'DEPENDENCY_SCOPE_EXPANSION_REQUIRED'; Routing = $routing
                PreservedOriginalHistory = $true; Reason = 'Work requires files outside the dependency''s governed scope.'
            }
        }
        'defect' {
            if ($isCurrentTask -or $DependencyActive) { $routing = 'CORRECT_CURRENT_ATTEMPT' }
            elseif ($Unrepresentable) { $routing = 'HUMAN_GOVERNANCE_REQUIRED' }
            else { $routing = 'NEW_FIX_TASK_REQUIRED' }
            return [pscustomobject]@{
                SchemaVersion = 1; DependencyId = $DependencyId
                Classification = 'DEPENDENCY_DEFECT_FOUND'; Routing = $routing
                PreservedOriginalHistory = $true; Reason = 'Genuine defect in dependency behavior; original history preserved.'
            }
        }
        default {
            throw [System.ArgumentException] ('Unsupported DefectNature ''{0}''.' -f $DefectNature)
        }
    }
}

# -----------------------------------------------------------------------------
# Capability 13 -- supersession
# -----------------------------------------------------------------------------
function Get-DbM181Supersession {
    <#
    .SYNOPSIS
    Return the supersession record for an asset (original implementation -> current
    implementation), e.g. PaymentService.cs -> PaymentOrchestrator.cs. $null when
    no supersession is recorded.
    #>
    param(
        [AllowNull()][object[]]$LineageSet,
        [string]$AssetPath,
        [AllowNull()][object]$Reconciliation
    )
    $asset = Get-DbM181Relative $AssetPath
    $found = $null
    foreach ($l in @($LineageSet)) {
        foreach ($s in @($l.SupersededBy)) {
            if ((Get-DbM181Relative ([string]$s.OriginalPath)) -eq $asset) {
                $found = [pscustomobject]@{
                    SchemaVersion          = 1
                    OriginalImplementation = $asset
                    SupersededBy           = [pscustomobject]@{ TaskId = [string]$s.TaskId; ChangeId = [string]$s.ChangeId; Path = [string]$s.NewPath }
                    CurrentImplementation  = [string]$s.NewPath
                    Instruction            = 'Do not build against the superseded original; use the current implementation.'
                    Provenance             = @('LATER_WORK_ITEM')
                }
                break
            }
        }
        if ($found) { break }
    }
    if ($found) { return $found }
    # fallback: reconciliation SUPERSEDED entry
    if ($null -ne $Reconciliation) {
        foreach ($e in @($Reconciliation.Entries)) {
            if ((Get-DbM181Relative ([string]$e.HistoricalPath)) -eq $asset -and [string]$e.Status -eq 'SUPERSEDED') {
                return [pscustomobject]@{
                    SchemaVersion          = 1
                    OriginalImplementation = $asset
                    SupersededBy           = $null
                    CurrentImplementation  = [string]$e.CurrentPath
                    Instruction            = 'Do not build against the superseded original; use the current implementation.'
                    Provenance             = @('CURRENT_REPOSITORY')
                }
            }
        }
    }
    return $null
}

# -----------------------------------------------------------------------------
# Capability 15 -- provenance
# -----------------------------------------------------------------------------
function Get-DbM181ProvenanceVocabulary {
    <#
    .SYNOPSIS
    The full provenance vocabulary: WORKBOOK | IMPLEMENTATION_REPORT | M06 |
    CLAUDE_REVIEW | GIT | CURRENT_REPOSITORY | FIX_TASK | LATER_WORK_ITEM |
    STATE_RESULT | TRIAL_PROVING. Used by every lineage statement.
    #>
    return @('WORKBOOK', 'IMPLEMENTATION_REPORT', 'M06', 'CLAUDE_REVIEW', 'GIT', 'CURRENT_REPOSITORY', 'FIX_TASK', 'LATER_WORK_ITEM', 'STATE_RESULT', 'TRIAL_PROVING')
}

# -----------------------------------------------------------------------------
# End of DB-M18.1 DependencyLineage.ps1
# -----------------------------------------------------------------------------
