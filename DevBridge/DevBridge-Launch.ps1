# DevBridge-Launch.ps1 - permanent self-refreshing local launcher for DevBridge.
#
# The desktop shortcut launches THIS script instead of DevBridge.exe. The launcher
# guarantees the published DevBridge binary represents the CURRENT COMMITTED DevBridge
# source before it is launched:
#
#   SHORTCUT -> LAUNCHER -> resolve git HEAD of the outer DevTools repository
#                          -> compare with the gitHead stamped in
#                             publish\win-x64\devbridge-build.json
#                          -> SAME  -> launch the existing published DevBridge.exe
#                                     (no build, no delay)
#                          -> DIFFER -> refuse if tracked uncommitted DevBridge SOURCE
#                                       changes exist (DEVBRIDGE_UNCOMMITTED_SOURCE)
#                                     -> gracefully stop any running DevBridge.exe
#                                     -> dotnet publish Release win-x64 self-contained
#                                        into a staging folder, then atomically swap it
#                                        into publish\win-x64 (a failed build NEVER
#                                        replaces or launches a partial binary)
#                                     -> stamp devbridge-build.json with the current HEAD
#                                     -> launch the freshly published DevBridge.exe
#
# Generated runtime/state/log/build files never count as source changes. Only tracked
# changes under <repo>/DevBridge/src OUTSIDE bin/ obj/ publish/ block an auto-republish.
#
# An explicit developer override allows publishing despite uncommitted source changes:
#   -AllowUncommitted            (command line)   or   DEVBRIDGE_ALLOW_UNCOMMITTED=1 (env)
#
# Outcomes are reported on stdout as DEVBRIDGE_* markers. When the machine has an
# interactive desktop, UPDATE_FAILED / UNCOMMITTED_SOURCE also raise a message box so a
# hidden-window shortcut launch is never silent. Selftest (sandbox git repo, no real
# publish, no Nexus/workbook/lifecycle touch):
#   powershell.exe -NoProfile -File .\DevBridge-Launch.ps1 -SelfTest
#
# ASCII-only source (PS 5.1 + BOM-safe).
param(
    [switch]$SelfTest,
    [switch]$AllowUncommitted
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------ script state
$script:LauncherDir          = $PSScriptRoot
$script:ThisScriptPath       = $PSCommandPath
$script:GitRoot              = ''
$script:SrcRel               = ''
$script:PublishDir           = ''
$script:ExePath              = ''
$script:MetadataPath         = ''
$script:Csproj               = ''
$script:GitHeadCurrent       = ''
$script:PublishedHeadBefore  = ''
$script:AllowUncommitted     = ($AllowUncommitted -or $env:DEVBRIDGE_ALLOW_UNCOMMITTED -eq '1')
$script:LaunchRecording      = $false
$script:LaunchCallCount      = 0
$script:LaunchedExe          = ''
$script:PublishStubMode      = $false
$script:PublishStubFails     = $false
$script:PublishCallCount     = 0
$script:SimRunning           = $false
$script:StaleStopCount       = 0
$script:Outcome              = ''
$script:OutcomeDetail        = @()
$script:SelftestPass         = 0
$script:SelftestFail         = 0
$script:SelftestExitCode     = 0

# ------------------------------------------------------------------ small helpers
function Get-RelativePath {
    # Returns path of $targetDir relative to $baseDir using '/', or '' when equal.
    param([string]$baseDir, [string]$targetDir)
    $bb = @($baseDir.TrimEnd('\', '/') -split '\\|/')
    $tt = @($targetDir.TrimEnd('\', '/') -split '\\|/')
    $i = 0
    while ($i -lt $bb.Count -and $i -lt $tt.Count -and $bb[$i] -ieq $tt[$i]) { $i++ }
    $parts = New-Object System.Collections.Generic.List[string]
    for ($j = $i; $j -lt $bb.Count; $j++) { $parts.Add('..') }
    for ($j = $i; $j -lt $tt.Count; $j++) { $parts.Add($tt[$j]) }
    return ($parts -join '/')
}

function Get-JsonField {
    param($obj, [string]$name)
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function ConvertTo-AbsPath([string]$path) {
    return [System.IO.Path]::GetFullPath($path)
}

# ------------------------------------------------------------------ git / source
function Initialize-Context {
    # Resolve the git repository that CONTAINS the launcher (the outer DevTools repo)
    # and derive the DevBridge src pathspec relative to its root.
    $o = @(& git -C $script:LauncherDir rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -eq 0 -and $o.Count -gt 0) {
        $script:GitRoot = (ConvertTo-AbsPath ($o[0].Trim()))
    }
    if (-not $script:GitRoot) {
        # Fallback: walk up from the launcher looking for a .git entry.
        $dir = $script:LauncherDir
        while ($dir) {
            if (Test-Path -LiteralPath (Join-Path $dir '.git')) { $script:GitRoot = $dir; break }
            $parent = [System.IO.Path]::GetDirectoryName($dir)
            if (-not $parent -or $parent -eq $dir) { break }
            $dir = $parent
        }
    }
    if (-not $script:GitRoot) {
        throw 'Cannot resolve the git repository that contains the launcher.'
    }
    $rel = Get-RelativePath -baseDir $script:GitRoot -targetDir $script:LauncherDir
    if ($rel -eq '') { $script:SrcRel = 'src' } else { $script:SrcRel = ($rel.TrimEnd('/') + '/src') }
    $script:PublishDir   = Join-Path $script:LauncherDir 'publish\win-x64'
    $script:ExePath      = Join-Path $script:PublishDir 'DevBridge.exe'
    $script:MetadataPath = Join-Path $script:PublishDir 'devbridge-build.json'
    $script:Csproj       = Join-Path $script:LauncherDir 'src\DevBridge.UI\DevBridge.UI.csproj'
}

function Get-CurrentHead {
    $o = @(& git -C $script:GitRoot rev-parse 'HEAD' 2>$null)
    if ($LASTEXITCODE -ne 0) { return '' }
    return ($o | Select-Object -Last 1).Trim()
}

function Get-UncommittedSource {
    # Tracked changes under the DevBridge src pathspec EXCLUDING generated bin/obj/
    # publish/ artifacts (tracked bin/obj noise must never count as a source change).
    $lines = @(& git -C $script:GitRoot status --porcelain -- $script:SrcRel 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'git status failed while inspecting DevBridge source.' }
    $bad = New-Object System.Collections.Generic.List[string]
    foreach ($_l in $lines) {
        if ([string]::IsNullOrWhiteSpace([string]$_l)) { continue }
        $line = [string]$_l
        if ($line.Length -lt 4) { continue }
        $path = $line.Substring(3).Trim()
        if ($path -match '(^|/)bin/|(^|/)obj/|(^|/)publish/') { continue }
        $bad.Add($path)
    }
    return @($bad)
}

# ------------------------------------------------------------------ metadata
function Write-BuildMetadata {
    param([string]$dir, [string]$head)
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $meta = [ordered]@{
        gitHead       = $head
        builtUtc      = ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
        configuration = 'Release'
        runtime       = 'win-x64'
    }
    $json = ($meta | ConvertTo-Json -Compress)
    $path = Join-Path $dir 'devbridge-build.json'
    $tmp  = $path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Read-BuildMetadata {
    param([string]$dir)
    $path = Join-Path $dir 'devbridge-build.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($path)
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

# ------------------------------------------------------------------ processes
function Get-DevBridgeProcesses {
    if ($script:SimRunning) {
        return @([pscustomobject]@{ Name = 'DevBridge'; Id = -1; Path = $script:ExePath })
    }
    $all = @(Get-Process -Name 'DevBridge' -ErrorAction SilentlyContinue)
    $out = @()
    foreach ($p in $all) {
        $path = ''
        try { $path = $p.Path } catch { $path = '' }
        if ($path) {
            if ($path -ieq $script:ExePath) { $out += $p }
        } else {
            # Name matches and path is unreadable; treat as the DevBridge console.
            $out += $p
        }
    }
    return $out
}

function Stop-DevBridgeProcesses {
    # Only the DevBridge console process is ever touched. A graceful close is
    # requested first; force-stop is the fallback. Never touches Claude Code,
    # DeepSeek, VS Code, PowerShell, Nexus apps, or any unrelated process.
    $handledSim = $false
    $first = Get-DevBridgeProcesses
    foreach ($p in $first) {
        if ($p.Id -le 0) { $handledSim = $true; continue }
        try { $null = $p.CloseMainWindow() } catch { }
    }
    Start-Sleep -Milliseconds 400
    $second = Get-DevBridgeProcesses
    foreach ($p in $second) {
        if ($p.Id -le 0) { $handledSim = $true; continue }
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
    }
    if ($handledSim) { $script:SimRunning = $false }
    $script:StaleStopCount++
    Start-Sleep -Milliseconds 300
}

# ------------------------------------------------------------------ publish + launch
function Invoke-Publish {
    # Returns $true on success. On ANY failure the previous publish folder is left
    # untouched (a partial/ambiguous binary is never made launchable).
    $script:PublishCallCount++
    if ($script:PublishStubMode) {
        if ($script:PublishStubFails) { return $false }
        if (-not (Test-Path -LiteralPath $script:PublishDir)) {
            New-Item -ItemType Directory -Force -Path $script:PublishDir | Out-Null
        }
        if (-not (Test-Path -LiteralPath $script:ExePath)) {
            [System.IO.File]::WriteAllText($script:ExePath, 'stub-exe', (New-Object System.Text.UTF8Encoding($false)))
        }
        Write-BuildMetadata -dir $script:PublishDir -head $script:GitHeadCurrent
        return $true
    }

    # Real path: publish into a staging folder, verify, stamp, then swap.
    $parent  = Split-Path -Parent $script:PublishDir
    $staging = Join-Path $parent '.staging-win-x64'
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    $pout = @(& dotnet publish $script:Csproj -c Release -r win-x64 --self-contained true -o $staging 2>&1)
    $code = $LASTEXITCODE
    if ($code -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $staging 'DevBridge.exe'))) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }
    Write-BuildMetadata -dir $staging -head $script:GitHeadCurrent
    try {
        $existed = Test-Path -LiteralPath $script:PublishDir
        $oldName = '.previous-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')
        if ($existed) {
            Rename-Item -LiteralPath $script:PublishDir -NewName $oldName
            Remove-Item -LiteralPath (Join-Path $parent $oldName) -Recurse -Force -ErrorAction SilentlyContinue
        }
        Rename-Item -LiteralPath $staging -NewName (Split-Path -Leaf $script:PublishDir)
    } catch {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }
    return $true
}

function Start-DevBridge {
    $script:LaunchCallCount++
    if ($script:LaunchRecording) {
        $script:LaunchedExe = $script:ExePath
        return
    }
    if (-not (Test-Path -LiteralPath $script:ExePath)) {
        throw 'Published DevBridge.exe not found after launch decision.'
    }
    Start-Process -FilePath $script:ExePath -WorkingDirectory $script:LauncherDir | Out-Null
    $script:LaunchedExe = $script:ExePath
}

# ------------------------------------------------------------------ launcher core
function Invoke-LauncherCore {
    $script:LaunchedExe = ''
    $head = Get-CurrentHead
    if (-not $head) {
        $script:Outcome       = 'UPDATE_FAILED'
        $script:OutcomeDetail = @('Cannot determine the current committed git HEAD (git unavailable or not a repository). The published binary state is unknown, so nothing was launched.')
        return
    }
    $script:GitHeadCurrent = $head

    $meta          = Read-BuildMetadata -dir $script:PublishDir
    $publishedHead = Get-JsonField $meta 'gitHead'
    $script:PublishedHeadBefore = $publishedHead
    $exePresent    = Test-Path -LiteralPath $script:ExePath

    if ($publishedHead -ine $head -or -not $exePresent) {
        # A publish is required to bring the binary to the current committed source.
        $dirty = @(Get-UncommittedSource)
        if ($dirty.Count -gt 0 -and -not $script:AllowUncommitted) {
            $script:Outcome       = 'UNCOMMITTED_SOURCE'
            $detail = New-Object System.Collections.Generic.List[string]
            $detail.Add('Tracked uncommitted DevBridge SOURCE changes exist under ' + $script:SrcRel + '; auto-republish refused (committed source is the source of truth). Commit or discard the changes, then launch again, or re-run with -AllowUncommitted / DEVBRIDGE_ALLOW_UNCOMMITTED=1 to publish the committed HEAD explicitly (your uncommitted edits are NOT built).')
            foreach ($d in $dirty) { $detail.Add('  changed: ' + $d) }
            $script:OutcomeDetail = @($detail.ToArray())
            return
        }
        $running = @(Get-DevBridgeProcesses)
        if ($running.Count -gt 0) { Stop-DevBridgeProcesses }
        $ok = Invoke-Publish
        if (-not $ok) {
            $script:Outcome       = 'UPDATE_FAILED'
            $script:OutcomeDetail = @('Build/publish failed. The previous published binary was left untouched and was NOT launched. Review the build output above (or run dotnet publish manually) and launch again.')
            return
        }
        $script:Outcome = 'REPUBLISHED'
        Start-DevBridge
    } else {
        # Published HEAD already equals the current committed HEAD: launch immediately.
        $running = @(Get-DevBridgeProcesses)
        if ($running.Count -gt 0) {
            $script:Outcome       = 'CURRENT_ALREADY_RUNNING'
            $script:OutcomeDetail = @('The published binary is current and a DevBridge instance is already running; no second instance was started.')
            return
        }
        $script:Outcome = 'CURRENT_NO_BUILD'
        Start-DevBridge
    }
}

# ------------------------------------------------------------------ reporting
function Out-Markers {
    $skipped = ($script:Outcome -eq 'CURRENT_NO_BUILD' -or $script:Outcome -eq 'CURRENT_ALREADY_RUNNING')
    Write-Output ('DEVBRIDGE_OUTCOME: ' + $script:Outcome)
    Write-Output ('DEVBRIDGE_GIT_ROOT: ' + $script:GitRoot)
    Write-Output ('DEVBRIDGE_GIT_HEAD: ' + $script:GitHeadCurrent)
    Write-Output ('DEVBRIDGE_SOURCE_REL: ' + $script:SrcRel)
    Write-Output ('DEVBRIDGE_PUBLISH_DIR: ' + $script:PublishDir)
    Write-Output ('DEVBRIDGE_EXE: ' + $script:ExePath)
    Write-Output ('DEVBRIDGE_METADATA: ' + $script:MetadataPath)
    Write-Output ('DEVBRIDGE_PUBLISHED_HEAD: ' + $script:PublishedHeadBefore)
    Write-Output ('DEVBRIDGE_SKIPPED_BUILD: ' + $skipped)
    Write-Output ('DEVBRIDGE_UNCOMMITTED_SOURCE: ' + ($script:Outcome -eq 'UNCOMMITTED_SOURCE'))
    Write-Output ('DEVBRIDGE_UPDATE_FAILED: ' + ($script:Outcome -eq 'UPDATE_FAILED'))
    Write-Output ('DEVBRIDGE_LAUNCHED: ' + (-not [string]::IsNullOrEmpty($script:LaunchedExe)))
    Write-Output ('DEVBRIDGE_LAUNCHED_EXE: ' + $script:LaunchedExe)
    foreach ($d in $script:OutcomeDetail) { Write-Output ('DEVBRIDGE_DETAIL: ' + $d) }
}

function Show-Alert([string]$title, [string]$msg) {
    if ($SelfTest) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show($msg, $title, 'OK', 'Exclamation') | Out-Null
    } catch { }
}

# ================================================================ SELF-TEST
function New-SelfTestSandbox {
    $root = Join-Path $env:TEMP ('devbridge-launch-selftest-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'DevBridge\src\DevBridge.UI') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'DevBridge\publish\win-x64') | Out-Null
    $o = @(& git -C $root init -q 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'sandbox git init failed' }
    & git -C $root config user.email 'selftest@localhost' 2>$null
    & git -C $root config user.name 'selftest' 2>$null
    return $root
}

function Write-SandboxFile {
    param([string]$root, [string]$rel, [string]$content)
    $abs = Join-Path $root ($rel -replace '/', '\')
    $d = Split-Path -Parent $abs
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [System.IO.File]::WriteAllText($abs, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-SandboxGit {
    param([string]$root, [string[]]$gitArgs)
    $o = @(& git -C $root @gitArgs 2>$null)
    if ($LASTEXITCODE -ne 0) { throw ('sandbox git ' + ($gitArgs -join ' ') + ' failed') }
    return $o
}

function Get-SandboxHead([string]$root) {
    $o = Invoke-SandboxGit -root $root -gitArgs @('rev-parse', 'HEAD')
    return ($o | Select-Object -Last 1).Trim()
}

function Reset-SelftestContext {
    # Point every script-scope location at the sandbox and arm launch recording +
    # publish stub so scenarios never touch the real repo, a real build, or the desktop.
    param([string]$root)
    $script:GitRoot         = $root
    $script:LauncherDir     = Join-Path $root 'DevBridge'
    $script:SrcRel          = 'DevBridge/src'
    $script:PublishDir      = Join-Path $script:LauncherDir 'publish\win-x64'
    $script:ExePath         = Join-Path $script:PublishDir 'DevBridge.exe'
    $script:MetadataPath    = Join-Path $script:PublishDir 'devbridge-build.json'
    $script:GitHeadCurrent  = ''
    $script:PublishedHeadBefore = ''
    $script:LaunchRecording = $true
    $script:LaunchCallCount = 0
    $script:LaunchedExe     = ''
    $script:PublishStubMode = $true
    $script:PublishStubFails = $false
    $script:PublishCallCount = 0
    $script:SimRunning      = $false
    $script:StaleStopCount  = 0
    $script:Outcome         = ''
    $script:OutcomeDetail   = @()
}

function Test-SelfTestScenario {
    param([string]$label, [scriptblock]$body)
    Write-Output ("SCENARIO: " + $label)
    try {
        $pass = & $body
    } catch {
        Write-Output ('FAIL: ' + $label + ' threw: ' + $_.Exception.Message)
        $script:SelftestFail++
        return
    }
    if ($pass) {
        Write-Output ('PASS: ' + $label)
        $script:SelftestPass++
    } else {
        Write-Output ('FAIL: ' + $label)
        $script:SelftestFail++
    }
}

function Assert-True {
    param([bool]$cond, [string]$what)
    if (-not $cond) { throw ('assertion failed: ' + $what) }
}

function Invoke-LauncherSelfTest {
    Write-Output 'DEVBRIDGE LAUNCHER SELF-TEST (sandbox git repo; no real publish; no Nexus/workbook/lifecycle touch)'

    # --- S1: published HEAD == git HEAD -> no build, existing current EXE launches ---
    Test-SelfTestScenario -label 'S1 same-HEAD skips build and launches current exe' -body {
        $r = New-SelfTestSandbox
        try {
            Write-SandboxFile -root $r -rel 'DevBridge/src/Sample.cs' -content 'v1'
            Invoke-SandboxGit -root $r -gitArgs @('add', '-A') | Out-Null
            Invoke-SandboxGit -root $r -gitArgs @('commit', '-m', 'c1') | Out-Null
            $h1 = Get-SandboxHead $r
            Reset-SelftestContext $r
            Write-BuildMetadata -dir $script:PublishDir -head $h1
            [System.IO.File]::WriteAllText($script:ExePath, 'exe1', (New-Object System.Text.UTF8Encoding($false)))
            Invoke-LauncherCore
            Assert-True ($script:Outcome -eq 'CURRENT_NO_BUILD') ('outcome CURRENT_NO_BUILD, got ' + $script:Outcome)
            Assert-True ($script:PublishCallCount -eq 0) 'no publish ran'
            Assert-True ($script:LaunchedExe -ieq $script:ExePath) 'current exe was launched'
            Assert-True ($script:PublishedHeadBefore -eq $h1) 'published head read'
            return $true
        } finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # --- S1b: same HEAD but already running -> no second instance ---
    Test-SelfTestScenario -label 'S1b same-HEAD already-running starts no duplicate' -body {
        $r = New-SelfTestSandbox
        try {
            Write-SandboxFile -root $r -rel 'DevBridge/src/Sample.cs' -content 'v1'
            Invoke-SandboxGit -root $r -gitArgs @('add', '-A') | Out-Null
            Invoke-SandboxGit -root $r -gitArgs @('commit', '-m', 'c1') | Out-Null
            $h1 = Get-SandboxHead $r
            Reset-SelftestContext $r
            Write-BuildMetadata -dir $script:PublishDir -head $h1
            [System.IO.File]::WriteAllText($script:ExePath, 'exe1', (New-Object System.Text.UTF8Encoding($false)))
            $script:SimRunning = $true
            Invoke-LauncherCore
            Assert-True ($script:Outcome -eq 'CURRENT_ALREADY_RUNNING') ('outcome CURRENT_ALREADY_RUNNING, got ' + $script:Outcome)
            Assert-True ($script:LaunchCallCount -eq 0) 'no duplicate launch'
            return $true
        } finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # --- S2: published HEAD behind -> build/publish, metadata updated, fresh exe ---
    Test-SelfTestScenario -label 'S2 behind-HEAD republishes and launches fresh exe' -body {
        $r = New-SelfTestSandbox
        try {
            Write-SandboxFile -root $r -rel 'DevBridge/src/Sample.cs' -content 'v1'
            Invoke-SandboxGit -root $r -gitArgs @('add', '-A') | Out-Null
            Invoke-SandboxGit -root $r -gitArgs @('commit', '-m', 'c1') | Out-Null
            $h1 = Get-SandboxHead $r
            Write-SandboxFile -root $r -rel 'DevBridge/src/Sample.cs' -content 'v2'
            Invoke-SandboxGit -root $r -gitArgs @('add', '-A') | Out-Null
            Invoke-SandboxGit -root $r -gitArgs @('commit', '-m', 'c2') | Out-Null
            $h2 = Get-SandboxHead $r
            Reset-SelftestContext $r
            Write-BuildMetadata -dir $script:PublishDir -head $h1
            [System.IO.File]::WriteAllText($script:ExePath, 'exe1', (New-Object System.Text.UTF8Encoding($false)))
            Invoke-LauncherCore
            Assert-True ($script:Outcome -eq 'REPUBLISHED') ('outcome REPUBLISHED, got ' + $script:Outcome)
            Assert-True ($script:PublishCallCount -eq 1) 'exactly one publish'
            $meta = Read-BuildMetadata -dir $script:PublishDir
            Assert-True ((Get-JsonField $meta 'gitHead') -eq $h2) 'metadata gitHead updated to current HEAD'
            Assert-True ($script:LaunchedExe -ieq $script:ExePath) 'fresh exe launched'
            return $true
        } finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # --- S3: build failure -> old binary intact + not launched, metadata not advanced ---
    Test-SelfTestScenario -label 'S3 build-failure never launches partial binary' -body {
        $r = New-SelfTestSandbox
        try {
            Write-SandboxFile -root $r -rel 'DevBridge/src/Sample.cs' -content 'v1'
            Invoke-SandboxGit -root $r -gitArgs @('add', '-A') | Out-Null
            Invoke-SandboxGit -root $r -gitArgs @('commit', '-m', 'c1') | Out-Null
            $h1 = Get-SandboxHead $r
            Write-SandboxFile -root $r -rel 'DevBridge/src/Sample.cs' -content 'v2'
            Invoke-SandboxGit -root $r -gitArgs @('add', '-A') | Out-Null
            Invoke-SandboxGit -root $r -gitArgs @('commit', '-m', 'c2') | Out-Null
            $h2 = Get-SandboxHead $r
            Reset-SelftestContext $r
            Write-BuildMetadata -dir $script:PublishDir -head $h1
            [System.IO.File]::WriteAllText($script:ExePath, 'OLDEXE', (New-Object System.Text.UTF8Encoding($false)))
            $script:PublishStubFails = $true
            Invoke-LauncherCore
            Assert-True ($script:Outcome -eq 'UPDATE_FAILED') ('outcome UPDATE_FAILED, got ' + $script:Outcome)
            $stillOld = [System.IO.File]::ReadAllText($script:ExePath)
            Assert-True ($stillOld -eq 'OLDEXE') 'old binary untouched'
            $meta = Read-BuildMetadata -dir $script:PublishDir
            Assert-True ((Get-JsonField $meta 'gitHead') -eq $h1) 'metadata not advanced past h1'
            Assert-True ($script:LaunchedExe -eq '') 'nothing launched on failure'
            return $true
        } finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # --- S4: uncommitted SOURCE -> DEVBRIDGE_UNCOMMITTED_SOURCE, no auto-publish; override works ---
    Test-SelfTestScenario -label 'S4 uncommitted-source blocks auto-publish (override allowed)' -body {
        $r = New-SelfTestSandbox
        try {
            Write-SandboxFile -root $r -rel 'DevBridge/src/Sample.cs' -content 'v1'
            Invoke-SandboxGit -root $r -gitArgs @('add', '-A') | Out-Null
            Invoke-SandboxGit -root $r -gitArgs @('commit', '-m', 'c1') | Out-Null
            $h1 = Get-SandboxHead $r
            Write-SandboxFile -root $r -rel 'DevBridge/src/Sample.cs' -content 'v2'
            Invoke-SandboxGit -root $r -gitArgs @('add', '-A') | Out-Null
            Invoke-SandboxGit -root $r -gitArgs @('commit', '-m', 'c2') | Out-Null
            $h2 = Get-SandboxHead $r
            Write-SandboxFile -root $r -rel 'DevBridge/src/Sample.cs' -content 'v3-uncommitted'  # WIP
            Reset-SelftestContext $r
            Write-BuildMetadata -dir $script:PublishDir -head $h1
            [System.IO.File]::WriteAllText($script:ExePath, 'exe1', (New-Object System.Text.UTF8Encoding($false)))
            $script:AllowUncommitted = $false
            Invoke-LauncherCore
            Assert-True ($script:Outcome -eq 'UNCOMMITTED_SOURCE') ('outcome UNCOMMITTED_SOURCE, got ' + $script:Outcome)
            Assert-True ($script:PublishCallCount -eq 0) 'no auto-publish while uncommitted source exists'
            $meta = Read-BuildMetadata -dir $script:PublishDir
            Assert-True ((Get-JsonField $meta 'gitHead') -eq $h1) 'metadata still h1'
            # explicit developer override publishes the committed HEAD
            $script:AllowUncommitted = $true
            $script:Outcome = ''
            Invoke-LauncherCore
            Assert-True ($script:Outcome -eq 'REPUBLISHED') ('override republished, got ' + $script:Outcome)
            $meta2 = Read-BuildMetadata -dir $script:PublishDir
            Assert-True ((Get-JsonField $meta2 'gitHead') -eq $h2) 'override stamped committed HEAD h2'
            return $true
        } finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # --- S5: runtime/log/state/bin-obj noise only -> does NOT block republish ---
    Test-SelfTestScenario -label 'S5 generated noise never blocks republish' -body {
        $r = New-SelfTestSandbox
        try {
            Write-SandboxFile -root $r -rel 'DevBridge/src/Sample.cs' -content 'v1'
            Write-SandboxFile -root $r -rel 'DevBridge/src/DevBridge.UI/bin/Debug/noise.dll' -content 'n1'   # tracked generated artifact
            Invoke-SandboxGit -root $r -gitArgs @('add', '-A') | Out-Null
            Invoke-SandboxGit -root $r -gitArgs @('commit', '-m', 'c1') | Out-Null
            $h1 = Get-SandboxHead $r
            Write-SandboxFile -root $r -rel 'DevBridge/src/Sample.cs' -content 'v2'
            Invoke-SandboxGit -root $r -gitArgs @('add', '-A') | Out-Null
            Invoke-SandboxGit -root $r -gitArgs @('commit', '-m', 'c2') | Out-Null
            $h2 = Get-SandboxHead $r
            # noise only: dirty tracked bin artifact + untracked state/log/temp files
            Write-SandboxFile -root $r -rel 'DevBridge/src/DevBridge.UI/bin/Debug/noise.dll' -content 'n2'
            Write-SandboxFile -root $r -rel 'DevBridge/logs/run.log' -content 'x'
            Write-SandboxFile -root $r -rel 'DevBridge/state/current-task.json' -content '{}'
            Write-SandboxFile -root $r -rel 'DevBridge/temp/t.txt' -content 'y'
            Reset-SelftestContext $r
            Write-BuildMetadata -dir $script:PublishDir -head $h1
            [System.IO.File]::WriteAllText($script:ExePath, 'exe1', (New-Object System.Text.UTF8Encoding($false)))
            Invoke-LauncherCore
            Assert-True ($script:Outcome -eq 'REPUBLISHED') ('noise did not block; outcome ' + $script:Outcome)
            Assert-True ($script:PublishCallCount -eq 1) 'publish ran despite noise'
            return $true
        } finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # --- S6: stale running DevBridge -> safely stopped, exactly one fresh instance ---
    Test-SelfTestScenario -label 'S6 running instance replaced safely (single fresh launch)' -body {
        $r = New-SelfTestSandbox
        try {
            Write-SandboxFile -root $r -rel 'DevBridge/src/Sample.cs' -content 'v1'
            Invoke-SandboxGit -root $r -gitArgs @('add', '-A') | Out-Null
            Invoke-SandboxGit -root $r -gitArgs @('commit', '-m', 'c1') | Out-Null
            $h1 = Get-SandboxHead $r
            Write-SandboxFile -root $r -rel 'DevBridge/src/Sample.cs' -content 'v2'
            Invoke-SandboxGit -root $r -gitArgs @('add', '-A') | Out-Null
            Invoke-SandboxGit -root $r -gitArgs @('commit', '-m', 'c2') | Out-Null
            $h2 = Get-SandboxHead $r
            Reset-SelftestContext $r
            Write-BuildMetadata -dir $script:PublishDir -head $h1
            [System.IO.File]::WriteAllText($script:ExePath, 'exe1', (New-Object System.Text.UTF8Encoding($false)))
            $script:SimRunning = $true   # a stale DevBridge is "running"
            Invoke-LauncherCore
            Assert-True ($script:Outcome -eq 'REPUBLISHED') ('outcome REPUBLISHED, got ' + $script:Outcome)
            Assert-True (-not $script:SimRunning) 'stale process was stopped before swap'
            Assert-True ($script:StaleStopCount -ge 1) 'stop routine invoked'
            Assert-True ($script:LaunchCallCount -eq 1) 'exactly one fresh instance launched'
            $meta = Read-BuildMetadata -dir $script:PublishDir
            Assert-True ((Get-JsonField $meta 'gitHead') -eq $h2) 'metadata advanced to h2'
            return $true
        } finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # --- S7 sandbox: shortcut-bootstrap relationship is a recovery check; here we
    #      verify the launcher is invoked as a bootstrap (i.e. -File points here). ---
    Test-SelfTestScenario -label 'S7 launcher is a self-contained bootstrap entrypoint' -body {
        $self = [System.IO.Path]::GetFullPath($script:ThisScriptPath)
        Assert-True ([System.IO.File]::Exists($self)) 'launcher file exists'
        Assert-True ($self -like '*DevBridge-Launch.ps1') 'launcher is the bootstrap file'
        return $true
    }

    Write-Output ('SELFTEST PASS: ' + $script:SelftestPass)
    Write-Output ('SELFTEST FAIL: ' + $script:SelftestFail)
    if ($script:SelftestFail -gt 0) {
        Write-Output 'SELFTEST RESULT: FAIL'
        $script:SelftestExitCode = 1
    } else {
        Write-Output 'SELFTEST RESULT: PASS'
        $script:SelftestExitCode = 0
    }
}

# ================================================================ ENTRY
if ($SelfTest) {
    Invoke-LauncherSelfTest
    exit $script:SelftestExitCode
}

try {
    Initialize-Context
    Invoke-LauncherCore
} catch {
    $script:Outcome       = 'UPDATE_FAILED'
    $script:OutcomeDetail = @(('Launcher error: ' + $_.Exception.Message))
}

Out-Markers

if ($script:Outcome -eq 'UPDATE_FAILED' -or $script:Outcome -eq 'UNCOMMITTED_SOURCE') {
    $title = 'DevBridge'
    if ($script:Outcome -eq 'UNCOMMITTED_SOURCE') {
        Show-Alert -title $title -msg ('DevBridge auto-refresh refused: uncommitted DevBridge source changes exist.' + [Environment]::NewLine + [Environment]::NewLine + 'Commit or discard them, then launch again. To publish the committed HEAD anyway use: DevBridge-Launch.ps1 -AllowUncommitted')
    } else {
        Show-Alert -title $title -msg ('DevBridge auto-refresh failed. The existing published binary was left untouched and was not launched.' + [Environment]::NewLine + [Environment]::NewLine + 'See the launcher output for diagnostics.')
    }
}

exit 0
