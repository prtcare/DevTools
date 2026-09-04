# Run-Verification.ps1 - DB-M06 governed verification (DB-M12.2 reusable lifecycle
# command for RUN_VERIFICATION).
#
# Runs the configured build/test commands for the CURRENT task. When
# config\devbridge.json leaves defaultBuildCommands/defaultTestCommands empty it
# discovers the reserved project(s) of the current reservation generically
# (package.json build/test scripts via npm, or *.csproj via dotnet; .NET solution
# fallback preserved), then records state\verification.json +
# tasks\VERIFICATION_REPORT.md and, on PASS, transitions current-task.json to
# VERIFIED. On FAIL it records the failure evidence and reports DB06_RESULT_PASS:
# False without forcing any lifecycle transition (the operator re-runs after fixing).
#
# Backend contract: ALWAYS exits 0; outcomes communicated ONLY via stdout markers
# (DB06_*). Fixture mode: DB06_SELFTEST=1 (+ DB06_FAIL=1 to force a failure).
# State/tasks dirs redirect with DB06_STATE_DIR / DB06_TASKS_DIR. M06 never
# modifies the workbook. No work-item identity is hard-coded: everything comes from
# the current task or the one-command input environment.
#
# ASCII-only source (PS 5.1 + BOM-safe).
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Set-DevBridgeStateEntry.ps1")

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:StateDir = Join-Path $script:Root "state"
$script:TasksDir = Join-Path $script:Root "tasks"
$script:CfgPath = Join-Path $script:Root "config\devbridge.json"
if ($env:DB06_STATE_DIR) { $script:StateDir = $env:DB06_STATE_DIR }
if ($env:DB06_TASKS_DIR) { $script:TasksDir = $env:DB06_TASKS_DIR }
$script:CurrentTaskPath = Join-Path $script:StateDir "current-task.json"
$script:NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

function Out-Markers([string]$token, [bool]$pass, [string[]]$evidence) {
    Write-Output ("DB06_OUTCOME: " + $token)
    Write-Output ("DB06_RESULT_PASS: " + $(if ($pass) { "True" } else { "False" }))
    Write-Output ("DB06_RESULT_CODE: " + $token)
    Write-Output "DB06_WORKBOOK_MODIFIED: False"
    Write-Output "DB06_NEXUS_SOURCE_MODIFIED: False"
    Write-Output "DB06_GIT_MODIFIED: False"
    Write-Output "DB06_REQUIRES_HUMAN_ACTION: False"
    Write-Output "DB06_HUMAN_ACTION_TYPE:"
    foreach ($e in $evidence) { Write-Output ("DB06_EVIDENCE: " + $e) }
    exit 0
}

function Invoke-CommandCapture([string]$commandLine, [string]$workingDirectory) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/d /c " + $commandLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($workingDirectory) { $psi.WorkingDirectory = $workingDirectory }
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEnd()
    $se = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return @{ ExitCode = $p.ExitCode; Output = ($so + "`n" + $se) }
}

# Walk up from a repo-relative changed file to the nearest ancestor directory that
# owns a package.json (Node project) or a *.csproj (.NET project). Never above the
# repository root. Returns the manifest directory, or $null when no applicable
# project manifest exists for the changed file.
function Find-ProjectManifestDir([string]$relPath, [string]$repoRootFull) {
    $parts = (($relPath -replace '\\', '/') -split '/')
    $probe = $repoRootFull
    for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
        if ($parts[$i]) { $probe = Join-Path $probe $parts[$i] }
    }
    while ($true) {
        if (Test-Path -LiteralPath (Join-Path $probe "package.json")) { return $probe }
        $cs = Get-ChildItem -LiteralPath $probe -Filter *.csproj -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cs) { return $probe }
        if ($probe -ieq $repoRootFull) { return $null }
        $parent = Split-Path -Parent $probe
        if (-not $parent -or $parent -ieq $probe) { return $null }
        $probe = $parent
    }
}

# Generic reserved-repository/project command discovery. When no build/test command
# is configured this asks the read-only Measure-Dbm06ImplementationDelta classifier
# which reserved repositories actually carry a current-task delta (it never assumes
# every repository is a .NET solution and never invents commands), then derives the
# repository-native commands for the changed reserved projects: package.json build/
# test scripts run with npm inside the project directory; *.csproj projects build
# with dotnet. Returns $null (not applicable) when the current task has no usable
# reservation/classifier, otherwise a discovery object { Applicable, Stopped,
# StopToken, StopEvidence, Commands (Command/Directory), Notes, Defects }.
function Invoke-ReservedProjectDiscovery {
    $resPath = Join-Path $script:StateDir "reservation.json"
    $result = @{
        Applicable = $false; Stopped = $false; StopToken = ""; StopEvidence = @()
        Commands = (New-Object System.Collections.Generic.List[object])
        Notes = (New-Object System.Collections.Generic.List[string])
        Defects = (New-Object System.Collections.Generic.List[string])
    }
    if (-not (Test-Path -LiteralPath $resPath)) { return $result }
    # Read via Read-DevBridgeJson (JavaScriptSerializer -> Dictionary[string,object],
    # an IDictionary) so the shared Get-DevBridgeField probes below resolve; a raw
    # ConvertFrom-Json PSCustomObject would not satisfy Get-DevBridgeField's IDictionary
    # cast and every field would read back empty.
    $res = Read-DevBridgeJson $resPath
    if ($null -eq $res) { return $result }
    $baselines = @(Get-DevBridgeField $res "repositoryBaselines")
    $classifier = Join-Path $PSScriptRoot "Measure-Dbm06ImplementationDelta.ps1"
    if ($baselines.Count -eq 0 -or -not (Test-Path -LiteralPath $classifier)) { return $result }

    $result.Applicable = $true
    $changedProjectDirs = New-Object 'System.Collections.Generic.HashSet[string]'
    $noApplicable = New-Object System.Collections.Generic.List[string]

    foreach ($_b in $baselines) {
        $_repoPath = [string](Get-DevBridgeField $_b "path")
        if (-not $_repoPath) { continue }
        $_repoFull = ""
        try { $_repoFull = (Resolve-Path -LiteralPath $_repoPath -ErrorAction Stop).Path } catch { $_repoFull = "" }
        if (-not $_repoFull) { continue }
        $_label = [string](Get-DevBridgeField $_b "name")
        if (-not $_label) { $_label = Split-Path $_repoFull -Leaf }

        $env:DB06D_REPO = $_repoPath
        $env:DB06D_RESERVATION = $resPath
        try {
            $co = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $classifier 2>&1)
        } finally {
            Remove-Item env:DB06D_REPO -ErrorAction SilentlyContinue
            Remove-Item env:DB06D_RESERVATION -ErrorAction SilentlyContinue
        }
        $co = @($co | ForEach-Object { "$_" })
        $joined = ($co -join "`n")
        $outcome = "NO_OUTCOME"
        $om = [regex]::Match($joined, 'DB06D_OUTCOME:\s*(\S+)')
        if ($om.Success) { $outcome = $om.Groups[1].Value }
        $result.Notes.Add($_label + ": delta classification " + $outcome)

        if ($outcome -ne "DELTA_CLASSIFICATION_PASS") {
            $result.Defects.Add($_label + ": delta classification " + $outcome + " (out-of-scope/revert/staged/commit defect; the classifier evidence names the file)")
            continue
        }
        $deltaRels = New-Object System.Collections.Generic.List[string]
        foreach ($_line in $co) {
            if ($_line -notlike 'DB06D_FILE:*') { continue }
            $dm = [regex]::Match($_line, 'DB06D_FILE:\s*([^|]+?)\s*\|\s*([A-Z_]+)')
            if (-not $dm.Success) { continue }
            if ($dm.Groups[2].Value -like '*CURRENT_TASK_DELTA*') { $deltaRels.Add($dm.Groups[1].Value.Trim()) }
        }
        if ($deltaRels.Count -eq 0) {
            $result.Notes.Add($_label + ": no current-task delta; nothing to build/test.")
            continue
        }
        foreach ($_rel in $deltaRels) {
            $md = Find-ProjectManifestDir $_rel $_repoFull
            if ($md) { $null = $changedProjectDirs.Add($md) }
            else { $noApplicable.Add($_label + " (" + $_rel + ")") }
        }
    }

    foreach ($_dir in $changedProjectDirs) {
        $projName = Split-Path $_dir -Leaf
        $pj = Join-Path $_dir "package.json"
        if (Test-Path -LiteralPath $pj) {
            $pkg = Read-DevBridgeJson $pj
            $bs = ""; $ts = ""
            if ($null -ne $pkg) {
                $scripts = Get-DevBridgeField $pkg "scripts"
                if ($null -ne $scripts) {
                    $bsv = Get-DevBridgeField $scripts "build"; if ($bsv) { $bs = [string]$bsv }
                    $tsv = Get-DevBridgeField $scripts "test";  if ($tsv) { $ts = [string]$tsv }
                }
            }
            if ($bs) { $result.Commands.Add(@{ Command = 'npm run build'; Directory = $_dir }); $result.Notes.Add($projName + ": package.json build script -> 'npm run build' (in project dir)") }
            if ($ts) { $result.Commands.Add(@{ Command = 'npm test'; Directory = $_dir });        $result.Notes.Add($projName + ": package.json test script -> 'npm test' (in project dir)") }
            if (-not $bs -and -not $ts) { $noApplicable.Add($projName) }
            continue
        }
        $cs = Get-ChildItem -LiteralPath $_dir -Filter *.csproj -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cs) { $result.Commands.Add(@{ Command = ('dotnet build "' + $cs.FullName + '"'); Directory = "" }); $result.Notes.Add($projName + ": *.csproj project -> dotnet build") }
        else { $noApplicable.Add($projName) }
    }

    foreach ($_na in $noApplicable) {
        $result.Notes.Add($_na + ": changed but no package.json build/test or *.csproj manifest applies; classified NO_APPLICABLE_VERIFICATION_COMMAND.")
    }

    if ($result.Commands.Count -eq 0 -and $result.Defects.Count -eq 0) {
        # Nothing to run (e.g. no reserved repo carries a current-task delta, or the
        # changed project legitimately has no applicable command). Stop with the
        # precise reason instead of failing the lifecycle without explanation.
        $result.Stopped = $true
        $result.StopToken = "STOP_VERIFICATION_ENVIRONMENT_UNAVAILABLE"
        $result.StopEvidence = @("No defaultBuildCommands/defaultTestCommands configured and reserved-project discovery produced no runnable command.", (($result.Notes -join " | ")))
    }
    return $result
}

$ct = Read-DevBridgeJson $script:CurrentTaskPath
if ($null -eq $ct) { Out-Markers "STOP_NO_CURRENT_TASK" $false @("No current-task.json; run DB-M03 preflight first.") }

$nodeId = [string](Get-DevBridgeField $ct "nodeId")
$changeId = [string](Get-DevBridgeField $ct "changeId")
$taskName = [string](Get-DevBridgeField $ct "name")
if (-not $nodeId) { $nodeId = [string](Get-DevBridgeField $ct "taskId") }

$mode = Get-DevBridgeMode $ct $script:CfgPath
if ($env:DB_COMMAND_INPUT_MODE) { $mode = $env:DB_COMMAND_INPUT_MODE }
$trial = ($mode -eq "TRIAL")

# ---- build/test commands: explicit config override first, then generic
# reserved-repository/project discovery, then the legacy DevBridge-root .sln
# fallback ----
$buildCommands = @(); $testCommands = @()
if (Test-Path $script:CfgPath) {
    $cfg = Get-Content $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.defaultBuildCommands) { $buildCommands = @($cfg.defaultBuildCommands) }
    if ($cfg.defaultTestCommands) { $testCommands = @($cfg.defaultTestCommands) }
}
$selftest = ($env:DB06_SELFTEST -eq "1")
$discovery = $null
if (-not $selftest -and $buildCommands.Count -eq 0 -and $testCommands.Count -eq 0) {
    $discovery = Invoke-ReservedProjectDiscovery
    if ($null -eq $discovery -or -not $discovery.Applicable) {
        # No usable reservation/classifier on disk: keep the legacy solution fallback.
        $sln = Get-ChildItem -Path $script:Root -Filter *.sln* -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($sln) { $buildCommands = @('dotnet build "' + $sln.FullName + '"') }
        else { Out-Markers "STOP_VERIFICATION_ENVIRONMENT_UNAVAILABLE" $false @("No defaultBuildCommands/defaultTestCommands configured and no solution found to auto-discover.") }
    } elseif ($discovery.Stopped) {
        Out-Markers $discovery.StopToken $false @($discovery.StopEvidence)
    }
}

# ---- run (or fixture-drive) the verification ----
$log = New-Object System.Collections.Generic.List[string]
$resultPass = $true
if ($selftest) {
    $fail = ($env:DB06_FAIL -eq "1")
    $log.Add("(selftest) verification fixture: " + $(if ($fail) { "forced FAIL" } else { "forced PASS" }))
    $resultPass = -not $fail
} else {
    # Normalized command plan: each entry carries its working directory so Node
    # commands run inside the reserved project while configured/.NET commands run
    # wherever they already did.
    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($_c in $buildCommands) { $plan.Add(@{ Command = [string]$_c; Directory = "" }) }
    foreach ($_c in $testCommands)  { $plan.Add(@{ Command = [string]$_c; Directory = "" }) }
    if ($null -ne $discovery -and $discovery.Applicable) {
        foreach ($_n in $discovery.Notes)   { $log.Add("(discovery) " + $_n) }
        foreach ($_d in $discovery.Defects) { $log.Add("(discovery defect) " + $_d); $resultPass = $false }
        foreach ($_e in $discovery.Commands) { $plan.Add($_e) }
    }
    if ($plan.Count -eq 0 -and $resultPass) {
        Out-Markers "STOP_VERIFICATION_ENVIRONMENT_UNAVAILABLE" $false @("No defaultBuildCommands/defaultTestCommands configured and reserved-project discovery produced no runnable command.", (($log -join " | ")))
    }
    foreach ($_entry in $plan) {
        $dirNote = ""
        if ($_entry.Directory) { $dirNote = "(in " + $_entry.Directory + ") " }
        $log.Add("> " + $dirNote + $_entry.Command)
        $r = Invoke-CommandCapture $_entry.Command $_entry.Directory
        $log.Add($r.Output)
        if ($r.ExitCode -ne 0) { $resultPass = $false }
    }
}

$primaryResult = $(if ($resultPass) { "VERIFICATION_PASSED" } else { "VERIFICATION_FAILED" })
$verification = [ordered]@{
    milestone     = "DB-M06"
    nodeId        = $nodeId
    changeId      = $changeId
    name          = $taskName
    primaryResult = $primaryResult
    verifiedAtUtc = $script:NowUtc
    mode          = $mode
    trialMode     = $trial
    commands      = @($log.ToArray())
    evidence      = @("state/verification.json", "tasks/VERIFICATION_REPORT.md")
}
Write-DevBridgeJson (Join-Path $script:StateDir "verification.json") $verification

$report = "# DB-M06 Verification Report`n`nNode: " + $nodeId + "`nChange: " + $changeId + "`nResult: " + $primaryResult + "`nVerified (utc): " + $script:NowUtc + "`nMode: " + $mode + "`n`nCommands and output:`n`n" + ($log -join "`n")
[System.IO.File]::WriteAllText((Join-Path $script:TasksDir "VERIFICATION_REPORT.md"), $report, (New-Object System.Text.UTF8Encoding($false)))

$db6 = [ordered]@{
    result        = $(if ($resultPass) { "VERIFICATION_PASS" } else { "VERIFICATION_FAIL" })
    nodeId        = $nodeId
    changeId      = $changeId
    mode          = $mode
    trialMode     = $trial
    primaryResult = $primaryResult
    verifiedAtUtc = $script:NowUtc
    evidence      = @("state/verification.json", "tasks/VERIFICATION_REPORT.md")
}

if ($resultPass) {
    Set-DevBridgeStateEntry $script:CurrentTaskPath @{ status = "VERIFIED"; nextAllowedAction = "CLAUDE_REVIEW"; dbM06 = $db6 }
    Out-Markers "VERIFICATION_PASSED" $true @("state/verification.json", "tasks/VERIFICATION_REPORT.md")
} else {
    # Record the failure evidence; do NOT force a lifecycle transition.
    Set-DevBridgeStateEntry $script:CurrentTaskPath @{ dbM06 = $db6 }
    Out-Markers "VERIFICATION_FAILED" $false @("state/verification.json", "tasks/VERIFICATION_REPORT.md")
}
