# Test-DBM06Discovery.ps1
# Targeted regression for the DB-M06 reserved-repository/project command
# discovery (Run-Verification.ps1). Before the fix DB-M06 only understood a
# single global defaultBuildCommands/defaultTestCommands config plus a
# DevBridge-root *.sln fallback, so a reserved Node/Vite project under a .NET
# repository could never be verified (STOP_VERIFICATION_ENVIRONMENT_UNAVAILABLE).
#
# The fix adds a generic discovery step: when config leaves the command lists
# empty, DB-M06 asks the read-only Measure-Dbm06ImplementationDelta classifier
# which reserved repositories carry a current-task delta, then derives
# repository-native commands for the changed projects - package.json build/test
# scripts via npm in the project directory, or *.csproj via dotnet - never
# assuming every repository is a .NET solution and never inventing commands.
#
# This test runs the REAL Run-Verification.ps1 engine (non-selftest) against
# throwaway git repositories and throwaway state/tasks dirs and asserts the eight
# verification-discovery requirements:
#   1. a reserved .NET project (csproj) still discovers and builds
#   2. a reserved Node/React package.json repository is discovered
#   3. the build command is discovered from package.json scripts
#   4. the test command is discovered from package.json ONLY where present
#   5. a missing/no-applicable command is classified explicitly
#   6. multi-repository reservations discover independent per-repo commands
#   7. the genuine environment STOP still occurs when nothing runnable exists
#   8. no live Nexus repository / DevBridge state / workbook is mutated
#
# The DB-M06 engine reports its outcome only through DB06_* stdout markers; its
# per-command log goes to tasks\VERIFICATION_REPORT.md, so command-content
# assertions read that file while outcome/result assertions read stdout.
#
# ASCII-only. Run: powershell -File scripts\Test-DBM06Discovery.ps1
param()
$ErrorActionPreference = "Stop"

$script:Root   = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:Engine = Join-Path $PSScriptRoot "Run-Verification.ps1"
$script:Cfg    = Get-Content (Join-Path $script:Root "config\devbridge.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$script:RealWorkbook = [string]$script:Cfg.developmentControlWorkbook

$script:PassCount = 0
$script:FailCount = 0

function Check([string]$label, [bool]$ok, [string]$detail) {
    if ($ok) { $script:PassCount++; Write-Output ("PASS  " + $label + " - " + $detail) }
    else     { $script:FailCount++; Write-Output ("FAIL  " + $label + " - " + $detail) }
}

function Get-FxHead([string]$dir) {
    $ho = @(& git -C $dir rev-parse HEAD 2>$null)
    if ($ho.Count -ge 1 -and $ho[0]) { return ([string]$ho[0]).Trim() }
    return ""
}

function New-FxRepo([string]$path) {
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    & git -C $path init -q
    if ($LASTEXITCODE -ne 0) { throw "git init failed: $path" }
    & git -C $path config user.name  "DevBridge Fixture" | Out-Null
    & git -C $path config user.email "dbm06disc@fixture.local" | Out-Null
    & git -C $path config core.autocrlf false | Out-Null
    return $path
}

function Write-FxFile([string]$dir, [string]$rel, [string]$content) {
    $full = Join-Path $dir ($rel -replace '/', '\')
    $parent = Split-Path -Parent $full
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [IO.File]::WriteAllText($full, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function Commit-FxAll([string]$dir, [string]$msg) {
    & git -C $dir add -A
    if ($LASTEXITCODE -ne 0) { throw "git add failed: $msg" }
    & git -C $dir commit -q -m $msg
    if ($LASTEXITCODE -ne 0) { throw "git commit failed: $msg" }
}

# New disposable fixture root with state/ + tasks/ for a DB-M06 run.
function New-FxFixture([string]$tag) {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("dbm06disc_" + $tag + "_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Force -Path (Join-Path $root "state"), (Join-Path $root "tasks") | Out-Null
    return @{ root = $root; stateDir = Join-Path $root "state"; tasksDir = Join-Path $root "tasks" }
}

function Write-FxCurrentTask([string]$stateDir) {
    $o = [ordered]@{
        nodeId = "N-01-0.1"; taskId = "N-01-0.1"; name = "DB-M06 discovery fixture"
        nodeType = "WorkItem"; phase = "P0"; layer = "App"; changeId = "CHG-DISC-0001"
        status = "AWAITING_CHATGPT_PROMPT"; nextAllowedAction = "COPY_TO_CHATGPT"
        selectedAt = "2026-09-04T00:00:00Z"; mode = "TRIAL"
    }
    ($o | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $stateDir "current-task.json") -Encoding UTF8
}

function Write-FxReservation([string]$changeId, [string[]]$projects, [array]$baselines, [string]$outFile) {
    $bs = @()
    foreach ($b in $baselines) {
        $bs += [ordered]@{
            name = $b.name; path = $b.path; isPrimary = [bool]$b.isPrimary; branch = "main"
            headCommit = $b.head; preReservationClean = $true
            preExistingChanges = [ordered]@{ modified = @(); staged = @(); untracked = @() }
            scopeFileHashes = @()
        }
    }
    $o = [ordered]@{ changeId = $changeId; mode = "TRIAL"; reservedScope = [ordered]@{ projects = @($projects) }; repositoryBaselines = $bs }
    ($o | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $outFile -Encoding UTF8
}

function Invoke-FxEngine([string]$stateDir, [string]$tasksDir) {
    Set-Item Env:\DB06_STATE_DIR $stateDir
    Set-Item Env:\DB06_TASKS_DIR $tasksDir
    Remove-Item Env:\DB06_SELFTEST, Env:\DB06_FAIL -ErrorAction SilentlyContinue
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $out = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:Engine 2>&1)
    $ErrorActionPreference = $oldEap
    $out = @($out | ForEach-Object { "$_" })
    Remove-Item Env:\DB06_STATE_DIR, Env:\DB06_TASKS_DIR -ErrorAction SilentlyContinue
    return ($out -join "`n")
}

function Get-FxReport([string]$tasksDir) {
    $p = Join-Path $tasksDir "VERIFICATION_REPORT.md"
    if (Test-Path -LiteralPath $p) { return (Get-Content -LiteralPath $p -Raw) }
    return ""
}

function Get-FxOutcome([string]$joined) {
    $m = [regex]::Match($joined, 'DB06_OUTCOME:\s*(\S+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return "NO_OUTCOME"
}

# ---------------------------------------------------------------------------
# Baseline capture for the "no live mutation" invariant (test point 8).
# ---------------------------------------------------------------------------
function Snap-Git([string]$repo) {
    $p = @(& git -C $repo status --porcelain=v1 2>$null | Sort-Object)
    return ((($p -join "`n")) + "`nHEAD=" + (Get-FxHead $repo))
}
function Snap-Hash([string]$p) {
    if (Test-Path -LiteralPath $p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
    return "MISSING"
}
$script:DevRepo = "C:\Personal\Nexus.Developer"
$script:ExpRepo = "C:\Personal\Nexus.Experience"
$script:hasDev = Test-Path -LiteralPath $script:DevRepo
$script:hasExp = Test-Path -LiteralPath $script:ExpRepo
$snapDev = $(if ($script:hasDev) { Snap-Git $script:DevRepo } else { "" })
$snapExp = $(if ($script:hasExp) { Snap-Git $script:ExpRepo } else { "" })
$snapCt = Snap-Hash (Join-Path $script:Root "state\current-task.json")
$snapRes = Snap-Hash (Join-Path $script:Root "state\reservation.json")
$snapWb = Snap-Hash $script:RealWorkbook

$preCondBad = (@($script:Cfg.defaultBuildCommands).Count -gt 0 -or @($script:Cfg.defaultTestCommands).Count -gt 0)
if ($preCondBad) {
    Check "precondition: config leaves defaultBuildCommands/defaultTestCommands empty" $false "config carries configured commands; discovery scenarios cannot run"
} else {
Write-Output "== DB-M06 reserved-project discovery regression =="

$fxCsproj = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
</Project>
'@
$fxPkgBuildAndTest = @'
{
  "name": "node-full-fixture",
  "private": true,
  "version": "1.0.0",
  "scripts": {
    "build": "node -e \"process.exit(0)\"",
    "test": "node -e \"process.exit(0)\""
  }
}
'@
$fxPkgBuildOnly = @'
{
  "name": "node-buildonly-fixture",
  "private": true,
  "version": "1.0.0",
  "scripts": {
    "build": "node -e \"process.exit(0)\""
  }
}
'@

# ---------------------------------------------------------------- scenario 1
# Test point 1: a reserved .NET project (csproj) is discovered and builds.
$tag = "S01_dotnet_csproj"
$f = New-FxFixture $tag
$repo = New-FxRepo (Join-Path $f.root "repo")
Write-FxFile $repo "src/DotNetLib/DotNetLib.csproj" $fxCsproj
Write-FxFile $repo "src/DotNetLib/Probe.cs" "namespace DotNetLib; public sealed class Probe { public static int V => 1; }`n"
Commit-FxAll $repo "baseline"
$head = Get-FxHead $repo
Write-FxCurrentTask $f.stateDir
Write-FxReservation "CHG-DISC-0001" @("DotNetLib") @(@{ name = "DotNetLib"; path = $repo; head = $head; isPrimary = $true }) (Join-Path $f.stateDir "reservation.json")
Write-FxFile $repo "src/DotNetLib/task-delta.txt" "current task delta`n"
$out1 = Invoke-FxEngine $f.stateDir $f.tasksDir
$rep1 = Get-FxReport $f.tasksDir
Write-Output ("--- scenario 1 (" + $tag + ") outcome: " + (Get-FxOutcome $out1))
Check "S1 outcome VERIFICATION_PASSED" ((Get-FxOutcome $out1) -eq "VERIFICATION_PASSED") ("got " + (Get-FxOutcome $out1))
Check "S1 DB06_RESULT_PASS True" ($out1 -match 'DB06_RESULT_PASS: True') "dotnet build must succeed"
Check "S1 .NET project discovered via dotnet build" ($rep1 -match 'dotnet build "C:') "no dotnet-build discovery for the csproj"
Check "S1 reserved csproj named in the build command" ($rep1 -match 'DotNetLib\.csproj') "csproj not referenced"
Check "S1 report written" ($rep1.Length -gt 0) "VERIFICATION_REPORT.md missing or empty"

# ---------------------------------------------------------------- scenario 2
# Test points 2, 3, 4-present: Node/React package.json repository discovered and
# its real build + test scripts run in the project directory.
$tag = "S02_node_build_and_test"
$f = New-FxFixture $tag
$repo = New-FxRepo (Join-Path $f.root "repo")
$projDir = Join-Path $repo "src\NodeApp"
Write-FxFile $repo "src/NodeApp/package.json" $fxPkgBuildAndTest
Write-FxFile $repo "src/NodeApp/index.ts" "export {}`n"
Commit-FxAll $repo "baseline"
$head = Get-FxHead $repo
Write-FxCurrentTask $f.stateDir
Write-FxReservation "CHG-DISC-0002" @("NodeApp") @(@{ name = "NodeApp"; path = $repo; head = $head; isPrimary = $true }) (Join-Path $f.stateDir "reservation.json")
Write-FxFile $repo "src/NodeApp/task-delta.tsx" "export const Delta = 1;`n"
$out2 = Invoke-FxEngine $f.stateDir $f.tasksDir
$rep2 = Get-FxReport $f.tasksDir
Write-Output ("--- scenario 2 (" + $tag + ") outcome: " + (Get-FxOutcome $out2))
Check "S2 outcome VERIFICATION_PASSED" ((Get-FxOutcome $out2) -eq "VERIFICATION_PASSED") ("got " + (Get-FxOutcome $out2))
Check "S2 Node/React package.json repository discovered" ($rep2 -match "package.json build script") "discovery note missing"
Check "S2 build command discovered from package.json" ($rep2 -match 'npm run build') "npm run build missing"
Check "S2 test command discovered from package.json" ($rep2 -match 'npm test') "npm test missing"
Check "S2 npm commands run in the reserved project directory" ($rep2 -match [regex]::Escape(("(in " + $projDir + ") npm run build"))) ("working-dir marker missing for " + $projDir)
Check "S2 DB06_RESULT_PASS True" ($out2 -match 'DB06_RESULT_PASS: True') "npm build/test must succeed"

# ---------------------------------------------------------------- scenario 3
# Test points 4-absent and 5: a Node project with NO test script runs no test;
# a changed reserved project with no package.json build/test and no *.csproj is
# classified NO_APPLICABLE_VERIFICATION_COMMAND while the runnable repo verifies.
$tag = "S03_no_test_and_no_manifest"
$f = New-FxFixture $tag
$repoBuild = New-FxRepo (Join-Path $f.root "repoNode")
Write-FxFile $repoBuild "src/NodeBuild/package.json" $fxPkgBuildOnly
Write-FxFile $repoBuild "src/NodeBuild/index.ts" "export {}`n"
Commit-FxAll $repoBuild "baseline"
$repoDoc = New-FxRepo (Join-Path $f.root "repoDoc")
Write-FxFile $repoDoc "src/DocsOnly/README.md" "no manifest here`n"
Commit-FxAll $repoDoc "baseline"
Write-FxCurrentTask $f.stateDir
Write-FxReservation "CHG-DISC-0003" @("NodeBuild", "DocsOnly") @(
    @{ name = "NodeBuild"; path = $repoBuild; head = (Get-FxHead $repoBuild); isPrimary = $true },
    @{ name = "DocsOnly";  path = $repoDoc;  head = (Get-FxHead $repoDoc);  isPrimary = $false }
) (Join-Path $f.stateDir "reservation.json")
Write-FxFile $repoBuild "src/NodeBuild/task-delta.txt" "delta`n"
Write-FxFile $repoDoc "src/DocsOnly/task-delta.txt" "delta`n"
$out3 = Invoke-FxEngine $f.stateDir $f.tasksDir
$rep3 = Get-FxReport $f.tasksDir
Write-Output ("--- scenario 3 (" + $tag + ") outcome: " + (Get-FxOutcome $out3))
Check "S3 outcome VERIFICATION_PASSED" ((Get-FxOutcome $out3) -eq "VERIFICATION_PASSED") ("got " + (Get-FxOutcome $out3))
Check "S3 build command still discovered" ($rep3 -match 'npm run build') "npm run build missing"
Check "S3 no test command invented when package.json has no test script" (-not ($rep3 -match 'npm test')) "npm test present but no test script exists"
Check "S3 no-applicable project classified explicitly" ($rep3 -match 'NO_APPLICABLE_VERIFICATION_COMMAND') "explicit no-applicable note missing"
Check "S3 multi-repo notes name both reserved repositories" ($rep3 -match 'NodeBuild' -and $rep3 -match 'DocsOnly') "repo labels missing from discovery notes"

# ---------------------------------------------------------------- scenario 4
# Test point 6: multi-repository reservation discovers INDEPENDENT commands for
# each changed reserved repository in one run (.NET + Node).
$tag = "S04_multi_repo_independent"
$f = New-FxFixture $tag
$repoNet = New-FxRepo (Join-Path $f.root "repoNet")
Write-FxFile $repoNet "src/DotNetLib2/DotNetLib2.csproj" $fxCsproj
Write-FxFile $repoNet "src/DotNetLib2/Probe.cs" "namespace DotNetLib2; public sealed class Probe { public static int V => 2; }`n"
Commit-FxAll $repoNet "baseline"
$repoNode = New-FxRepo (Join-Path $f.root "repoNode")
Write-FxFile $repoNode "src/NodeFull/package.json" $fxPkgBuildAndTest
Write-FxFile $repoNode "src/NodeFull/index.ts" "export {}`n"
Commit-FxAll $repoNode "baseline"
Write-FxCurrentTask $f.stateDir
Write-FxReservation "CHG-DISC-0004" @("DotNetLib2", "NodeFull") @(
    @{ name = "DotNetLib2"; path = $repoNet;  head = (Get-FxHead $repoNet);  isPrimary = $true },
    @{ name = "NodeFull";   path = $repoNode; head = (Get-FxHead $repoNode); isPrimary = $false }
) (Join-Path $f.stateDir "reservation.json")
Write-FxFile $repoNet "src/DotNetLib2/task-delta.txt" "delta`n"
Write-FxFile $repoNode "src/NodeFull/task-delta.txt" "delta`n"
$out4 = Invoke-FxEngine $f.stateDir $f.tasksDir
$rep4 = Get-FxReport $f.tasksDir
Write-Output ("--- scenario 4 (" + $tag + ") outcome: " + (Get-FxOutcome $out4))
Check "S4 outcome VERIFICATION_PASSED" ((Get-FxOutcome $out4) -eq "VERIFICATION_PASSED") ("got " + (Get-FxOutcome $out4))
Check "S4 .NET repo command independent" ($rep4 -match 'DotNetLib2\.csproj') "dotnet build for the .NET repo missing"
Check "S4 Node repo build command independent" ($rep4 -match 'npm run build') "npm build missing"
Check "S4 Node repo test command independent" ($rep4 -match 'npm test') "npm test missing"
Check "S4 both reserved repos discovered in one run" ($rep4 -match 'DotNetLib2' -and $rep4 -match 'NodeFull') "both repo notes missing"

# ---------------------------------------------------------------- scenario 5
# Test point 7: when the only changed reserved project has no applicable
# build/test command, DB-M06 still STOPs cleanly with the precise reason
# (no silent fail, no invented command, no lifecycle transition).
$tag = "S05_stop_unsupported"
$f = New-FxFixture $tag
$repo = New-FxRepo (Join-Path $f.root "repo")
Write-FxFile $repo "src/DataOnly/README.md" "no build or test can apply here`n"
Commit-FxAll $repo "baseline"
Write-FxCurrentTask $f.stateDir
Write-FxReservation "CHG-DISC-0005" @("DataOnly") @(@{ name = "DataOnly"; path = $repo; head = (Get-FxHead $repo); isPrimary = $true }) (Join-Path $f.stateDir "reservation.json")
Write-FxFile $repo "src/DataOnly/task-delta.txt" "delta`n"
$out5 = Invoke-FxEngine $f.stateDir $f.tasksDir
Write-Output ("--- scenario 5 (" + $tag + ") outcome: " + (Get-FxOutcome $out5))
Check "S5 outcome STOP_VERIFICATION_ENVIRONMENT_UNAVAILABLE" ((Get-FxOutcome $out5) -eq "STOP_VERIFICATION_ENVIRONMENT_UNAVAILABLE") ("got " + (Get-FxOutcome $out5))
Check "S5 DB06_RESULT_PASS False" ($out5 -match 'DB06_RESULT_PASS: False') "stop must not be reported as pass"
Check "S5 no-applicable classified explicitly" ($out5 -match 'NO_APPLICABLE_VERIFICATION_COMMAND') "explicit classification missing"
Check "S5 no invented command runs" (-not ($out5 -match 'npm run|dotnet build')) "a command was invented for an unsupported repo"
Check "S5 current-task not transitioned on STOP" ((Get-Content (Join-Path $f.stateDir "current-task.json") -Raw) -match '"status":\s*"AWAITING_CHATGPT_PROMPT"') "status changed on a STOP"

# ---------------------------------------------------------------- invariant
# Test point 8: the whole suite must not mutate the live reserved repositories,
# DevBridge state, or the governance workbook.
Write-Output "--- invariant: no live mutation ---"
if ($script:hasDev) { Check "I1 Nexus.Developer git state unchanged" ((Snap-Git $script:DevRepo) -eq $snapDev) "Nexus.Developer porcelain/HEAD changed" }
if ($script:hasExp) { Check "I2 Nexus.Experience git state unchanged" ((Snap-Git $script:ExpRepo) -eq $snapExp) "Nexus.Experience porcelain/HEAD changed" }
Check "I3 live current-task.json unchanged" ((Snap-Hash (Join-Path $script:Root "state\current-task.json")) -eq $snapCt) "live current-task.json changed"
Check "I4 live reservation.json unchanged" ((Snap-Hash (Join-Path $script:Root "state\reservation.json")) -eq $snapRes) "live reservation.json changed"
Check "I5 live workbook unchanged" ((Snap-Hash $script:RealWorkbook) -eq $snapWb) "workbook changed"
}

Write-Output ""
Write-Output ("DBM06DISCOVERY_PASS: " + $script:PassCount + " assertions")
Write-Output ("DBM06DISCOVERY_FAIL: " + $script:FailCount)
Write-Output ("DBM06DISCOVERY_RESULT: " + $(if ($script:FailCount -eq 0) { "PASS" } else { "FAIL" }))
if ($script:FailCount -gt 0) { exit 1 }
exit 0
