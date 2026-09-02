# Test-DbM32EssentialSafety.ps1 -- DB-M32 49-scenario test matrix (A1-N4).
#
# DB-M32 ESSENTIAL SAFETY, RECOVERY & OPERATIONAL HARDENING. Every scenario
# runs against a TEMPORARY fixture under %TEMP% -- the live canonical workbook,
# live state, live Git repo and live locks are NEVER touched by this suite.
#
# Backend conventions: ASCII-only, Set-StrictMode -Version Latest, and the
# script ALWAYS exits 0 on a full pass or 1 on any assertion failure (a governed
# harness reads DB32_TEST_* stdout markers, never the exit code alone).
# DB-M32 NEVER performs rollback, never restores a baseline, never deletes a
# writer lock, never writes the workbook, never runs a Git write.

[CmdletBinding()]
param(
    [string]$Scenarios = 'ALL'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $script:here 'RecoveryContracts.ps1')
. (Join-Path $script:here 'RecoveryEngine.ps1')
. (Join-Path $script:here 'RecoveryRender.ps1')

$script:Passed = 0
$script:Failed = 0
$script:Fails = New-Object System.Collections.ArrayList
$script:Now = '2026-09-01T12:00:00Z'
$script:Fixtures = New-Object System.Collections.ArrayList

function Assert-DbM32 {
    param([string]$Id, [bool]$Condition, [string]$Detail)
    if ($Condition) { $script:Passed++ } else { $script:Failed++; [void]$script:Fails.Add("$Id :: $Detail") }
    '{0}|{1}|{2}|{3}' -f 'TEST', $Id, $(if ($Condition) { 'PASS' } else { 'FAIL' }), $Detail
}

# ---- fixture helpers (all under %TEMP%) ----

function New-DbM32Fixture([string]$Name) {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("dbm32-{0}-{1}" -f $Name, ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'state') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'config') | Out-Null
    [void]$script:Fixtures.Add($root)
    return $root
}

function ConvertTo-DbM32Json($Object) {
    if ($Object -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $Object.Keys) { if ($null -ne $Object[$k]) { $h[$k] = ConvertTo-DbM32Json $Object[$k] } }
        return $h
    }
    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
        $out = New-Object System.Collections.ArrayList
        foreach ($item in $Object) { [void]$out.Add((ConvertTo-DbM32Json $item)) }
        return ,@($out.ToArray())
    }
    return $Object
}

function Write-DbM32Json {
    param([string]$Path, $Object)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $clean = ConvertTo-DbM32Json $Object
    [System.IO.File]::WriteAllText($Path, ($clean | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
}

function New-DbM32Workbook {
    param([string]$Root, [string]$Content)
    $path = Join-Path $Root 'workbook-fixture.xlsx'
    [System.IO.File]::WriteAllText($path, $Content, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function New-DbM32TaskState {
    param(
        [string]$Root,
        [string]$NodeId = 'M-F1',
        [string]$ChangeId = '',
        [string]$Status = 'PREFLIGHTED',
        [string]$Next = 'RESOLVE_GOVERNANCE_BLOCK',
        [string]$WorkbookSha = ''
    )
    Write-DbM32Json (Join-Path $Root 'state\current-task.json') @{
        nodeId = $NodeId; changeId = $ChangeId; status = $Status; nextAllowedAction = $Next
        preflightVerdict = 'NO_IMPLEMENTABLE_DESCENDANT'; implementability = 'CONTAINER'
        workbookSha256 = $WorkbookSha; selectedAt = '2026-09-01T11:00:00Z'
    }
    Write-DbM32Json (Join-Path $Root 'state\current-lifecycle-state.json') @{
        mode = 'TRIAL'; trialMode = $true; status = $Status; nextAllowedAction = $Next
        generatedAtUtc = '2026-09-01T11:20:00Z'
        evidence = @{ verification = 'VERIFICATION_PASSED'; claudeReview = 'PASS'; completion = 'PRESENT'; fingerprint = 'ABSENT' }
    }
}

# A clean, consistent fixture: preflight recorded at the CURRENT workbook SHA.
function New-DbM32CleanFixture {
    param([string]$ChangeId = '')
    $root = New-DbM32Fixture 'clean'
    $wb = New-DbM32Workbook $root ("CANONICAL " + [guid]::NewGuid().ToString())
    $sha = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId $ChangeId -WorkbookSha $sha
    Write-DbM32Json (Join-Path $root 'state\preflight.json') @{
        changeId = $ChangeId; nodeId = 'M-F1'; status = 'PREFLIGHTED'; verdict = 'NO_IMPLEMENTABLE_DESCENDANT'
        workbookSha256 = $sha; selectedAt = '2026-09-01T11:30:00Z'
    }
    return @{ Root = $root; Workbook = $wb; Sha = $sha }
}

function New-DbM32WriterLock {
    param([string]$Root, [int]$ProcessId, [string]$Owner = 'dbm32-fixture')
    $lockDir = Join-Path $Root 'logs'
    if (-not (Test-Path -LiteralPath $lockDir)) { New-Item -ItemType Directory -Force -Path $lockDir | Out-Null }
    $lock = Join-Path $lockDir 'workbook-writer.lock'
    [System.IO.File]::WriteAllText($lock, "pid=$ProcessId`r`nacquired=2026-09-01T10:00:00Z`r`nowner=$Owner`r`n", (New-Object System.Text.UTF8Encoding($false)))
    return $lock
}

function New-DbM32GitRepo {
    param([string]$Path, [string]$File1, [string]$Content1, [string]$File2, [string]$Content2)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Push-Location $Path
    try {
        git init -q 2>$null
        git config user.email 'dbm32@test.local' 2>$null
        git config user.name 'dbm32' 2>$null
        git checkout -q -b feature/dbm32-fixture 2>$null
        Set-Content -LiteralPath (Join-Path $Path $File1) -Value $Content1 -Encoding UTF8
        git add -A 2>$null
        git commit -q -m 'fixture c1' 2>$null
        $h1 = (git rev-parse HEAD).Trim()
        if ($File2) {
            Set-Content -LiteralPath (Join-Path $Path $File2) -Value $Content2 -Encoding UTF8
            git add -A 2>$null
            git commit -q -m 'fixture c2' 2>$null
            $h2 = (git rev-parse HEAD).Trim()
        } else { $h2 = $h1 }
    } finally { Pop-Location }
    return @{ Path = $Path; Head1 = $h1; Head2 = $h2 }
}

# ---- CLI runner: run Show as a child process and parse DB32_* markers ----

function Invoke-DbM32Cli {
    param([string]$Root, [hashtable]$Extra = @{}, [string]$ExtraRaw = '')
    $args = New-Object System.Collections.ArrayList
    [void]$args.Add('-Root'); [void]$args.Add($Root)
    [void]$args.Add('-StateSource'); [void]$args.Add('FIXTURE')
    [void]$args.Add('-NowUtc'); [void]$args.Add($script:Now)
    foreach ($k in $Extra.Keys) { [void]$args.Add('-' + $k); [void]$args.Add([string]$Extra[$k]) }
    if ($ExtraRaw) { foreach ($t in ($ExtraRaw -split ' ')) { if ($t) { [void]$args.Add($t) } } }
    $quoted = @($args | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:here + '\Show-DbM32EssentialSafety.ps1" ' + $quoted
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $markers = @{}
    $tokens = New-Object System.Collections.ArrayList
    foreach ($line in ($stdout -split "`r?`n")) {
        if ($line -match '^DB32_([A-Z0-9_]+):\s?(.*)$') { $markers[$Matches[1]] = $Matches[2] }
    }
    foreach ($line in ($stdout -split "`r?`n")) {
        if ($line -match '^DB32_INTERRUPTED_OPERATION_TOKEN: (.*)$') { [void]$tokens.Add($Matches[1]) }
    }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Markers = $markers; Tokens = @($tokens); Stdout = $stdout; Stderr = $stderr }
}

# ---- scenario table (comma-separated: every entry is a single hashtable) ----
# The table lives in a FUNCTION body on purpose: under `powershell -File`, a
# multi-line hashtable literal at script top level is string-joined by the
# parser (a known PS 5.1 behavior), collapsing the table into one string. In a
# function body (nested parse context) each entry stays a separate hashtable.

function Get-DbM32ScenarioTable {
    return @(
# === A1-A6: interrupted-operation detection tokens ===
@{ Id = 'A1'; Name = 'RESERVATION_STARTED_BUT_UNVERIFIED detected'; Run = {
    $f = New-DbM32CleanFixture -ChangeId 'CHG-F1'
    Write-DbM32Json (Join-Path $f.Root 'state\reservation.json') @{
        changeId = 'CHG-F1'; task = @{ nodeId = 'M-F1' }
        workbook = @{ sha256Before = $f.Sha; sha256After = $f.Sha }
        generatedAtUtc = '2026-09-01T11:40:00Z'; gitBaseline = @{ headCommit = 'H1' }
    }
    $r = Invoke-DbM32Cli $f.Root @{ WorkbookPath = $f.Workbook; RepositoryPath = (Join-Path $f.Root 'norepo') }
    Assert-DbM32 'A1' ($r.Tokens -contains 'RESERVATION_STARTED_BUT_UNVERIFIED') ("tokens=" + ($r.Tokens -join ','))
    Assert-DbM32 'A1-class' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'READBACK_RECONCILIATION_REQUIRED') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
}},
@{ Id = 'A2'; Name = 'WORKBOOK_WRITE_STARTED_BUT_READBACK_MISSING detected'; Run = {
    $root = New-DbM32Fixture 'a2'
    $wb = New-DbM32Workbook $root ("POST-WRITE-B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\preflight.json') @{
        changeId = 'CHG-F1'; nodeId = 'M-F1'; status = 'PREFLIGHTED'; verdict = 'NO_IMPLEMENTABLE_DESCENDANT'
        workbookSha256 = ('A' * 64); selectedAt = '2026-09-01T11:30:00Z'
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'A2' ($r.Tokens -contains 'WORKBOOK_WRITE_STARTED_BUT_READBACK_MISSING') ("tokens=" + ($r.Tokens -join ','))
    Assert-DbM32 'A2-verdict' ($r.Markers['WORKBOOK_VERDICT'] -eq 'WRITE_STATE_AMBIGUOUS') "verdict=$($r.Markers['WORKBOOK_VERDICT'])"
    Assert-DbM32 'A2-class' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'READBACK_RECONCILIATION_REQUIRED') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
    Assert-DbM32 'A2-unchanged' ((Get-DbM32FileSha256 -Path $wb) -eq $shaB) 'workbook file not modified'
}},
@{ Id = 'A3'; Name = 'VERIFICATION_STARTED_BUT_RESULT_MISSING detected'; Run = {
    $root = New-DbM32Fixture 'a3'
    $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -Status 'VERIFIED' -Next 'CLAUDE_REVIEW' -WorkbookSha $shaB
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'A3' ($r.Tokens -contains 'VERIFICATION_STARTED_BUT_RESULT_MISSING') ("tokens=" + ($r.Tokens -join ','))
    Assert-DbM32 'A3-class' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'SAFE_TO_RETRY') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
    Assert-DbM32 'A3-action' ($r.Markers['RECOMMENDED_ACTION'] -eq 'RE-RUN VERIFICATION') "action=$($r.Markers['RECOMMENDED_ACTION'])"
}},
@{ Id = 'A4'; Name = 'CLAUDE_RESULT_RECORDING_INTERRUPTED detected'; Run = {
    $root = New-DbM32Fixture 'a4'
    $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -Status 'CLAUDE_REVIEW' -Next 'RECORD_CLAUDE_RESULT' -WorkbookSha $shaB
    $probe = Join-Path $root 'logs\tasks\M-F1'
    New-Item -ItemType Directory -Force -Path $probe | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $probe 'REVIEW_PACKET.md'), 'packet body', (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'A4' ($r.Tokens -contains 'CLAUDE_RESULT_RECORDING_INTERRUPTED') ("tokens=" + ($r.Tokens -join ','))
    Assert-DbM32 'A4-class' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'HUMAN_REVIEW_REQUIRED') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
    Assert-DbM32 'A4-action' ($r.Markers['RECOMMENDED_ACTION'] -eq 'RECORD CLAUDE RESULT AGAIN') "action=$($r.Markers['RECOMMENDED_ACTION'])"
}},
@{ Id = 'A5'; Name = 'TRIAL_CLOSURE_STARTED_BUT_UNVERIFIED detected'; Run = {
    $root = New-DbM32Fixture 'a5'
    $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\trial-closure.json') @{
        changeId = 'CHG-F1'; result = 'TRIAL_CYCLE_CLOSED'; closedAtUtc = '2026-09-01T11:50:00Z'
        preWriteBackupSha256 = ('B' * 64); postWorkbookSha256 = $shaB
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'A5' ($r.Tokens -contains 'TRIAL_CLOSURE_STARTED_BUT_UNVERIFIED') ("tokens=" + ($r.Tokens -join ','))
    Assert-DbM32 'A5-class' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'DO_NOT_RETRY') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
}},
@{ Id = 'A6'; Name = 'COMPLETION_STARTED_BUT_UNVERIFIED detected'; Run = {
    $root = New-DbM32Fixture 'a6'
    $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\completion.json') @{
        changeId = 'CHG-F1'; status = 'COMPLETION_WRITTEN'; completedAtUtc = '2026-09-01T11:50:00Z'
        workbookSha256Before = ('B' * 64); workbookSha256After = $shaB
        sourceGitEvidence = @{ headCommit = 'H1' }
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'A6' ($r.Tokens -contains 'COMPLETION_STARTED_BUT_UNVERIFIED') ("tokens=" + ($r.Tokens -join ','))
    Assert-DbM32 'A6-class' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'DO_NOT_RETRY') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
}},
# === B1-B8: recovery classification ===
@{ Id = 'B1'; Name = 'SAFE_TO_RESUME on consistent state'; Run = {
    $f = New-DbM32CleanFixture
    $r = Invoke-DbM32Cli $f.Root @{ WorkbookPath = $f.Workbook; RepositoryPath = (Join-Path $f.Root 'norepo') }
    Assert-DbM32 'B1' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'SAFE_TO_RESUME') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
    Assert-DbM32 'B1-status' ($r.Markers['RECOVERY_STATUS'] -eq 'OK') "status=$($r.Markers['RECOVERY_STATUS'])"
    Assert-DbM32 'B1-tokens' ([int]$r.Markers['TOKEN_COUNT'] -eq 0) "tokens=$($r.Markers['TOKEN_COUNT'])"
}},
@{ Id = 'B2'; Name = 'SAFE_TO_RETRY classification'; Run = {
    $root = New-DbM32Fixture 'b2'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -Status 'VERIFIED' -Next 'CLAUDE_REVIEW' -WorkbookSha $shaB
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'B2' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'SAFE_TO_RETRY') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
}},
@{ Id = 'B3'; Name = 'REFRESH_REQUIRED classification'; Run = {
    $root = New-DbM32Fixture 'b3'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\verification.json') @{
        changeId = 'CHG-F1'; stateTransition = @{ status = 'VERIFIED' }
        parts = @{ part10 = @{ sha256Before = $shaB; sha256After = $shaB } }
        generatedAtUtc = '2026-09-01T11:40:00Z'
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'B3' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'REFRESH_REQUIRED') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
}},
@{ Id = 'B4'; Name = 'READBACK_RECONCILIATION_REQUIRED classification'; Run = {
    $root = New-DbM32Fixture 'b4'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\preflight.json') @{
        changeId = 'CHG-F1'; nodeId = 'M-F1'; status = 'PREFLIGHTED'; verdict = 'NO_IMPLEMENTABLE_DESCENDANT'
        workbookSha256 = ('A' * 64); selectedAt = '2026-09-01T11:30:00Z'
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'B4' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'READBACK_RECONCILIATION_REQUIRED') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
}},
@{ Id = 'B5'; Name = 'HUMAN_REVIEW_REQUIRED classification'; Run = {
    $root = New-DbM32Fixture 'b5'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -Status 'CLAUDE_REVIEW' -Next 'RECORD_CLAUDE_RESULT' -WorkbookSha $shaB
    $probe = Join-Path $root 'logs\tasks\M-F1'; New-Item -ItemType Directory -Force -Path $probe | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $probe 'REVIEW_PACKET.md'), 'packet', (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'B5' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'HUMAN_REVIEW_REQUIRED') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
}},
@{ Id = 'B6'; Name = 'GOVERNANCE_REVIEW_REQUIRED classification'; Run = {
    $root = New-DbM32Fixture 'b6'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -Status 'RESERVED' -Next 'CREATE_CHATGPT_HANDOFF' -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\reservation.json') @{
        changeId = 'CHG-F1'; task = @{ nodeId = 'M-F1' }
        workbook = @{ sha256Before = ('A' * 64); sha256After = $shaB }
        generatedAtUtc = '2026-09-01T11:40:00Z'
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'B6' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'GOVERNANCE_REVIEW_REQUIRED') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
    Assert-DbM32 'B6-action' ($r.Markers['RECOMMENDED_ACTION'] -eq 'HUMAN GOVERNANCE REVIEW') "action=$($r.Markers['RECOMMENDED_ACTION'])"
}},
@{ Id = 'B7'; Name = 'DO_NOT_RETRY classification'; Run = {
    $root = New-DbM32Fixture 'b7'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\completion.json') @{
        changeId = 'CHG-F1'; status = 'COMPLETION_WRITTEN'; completedAtUtc = '2026-09-01T11:50:00Z'
        workbookSha256Before = ('B' * 64); workbookSha256After = $shaB; sourceGitEvidence = @{ headCommit = 'H1' }
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'B7' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'DO_NOT_RETRY') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
}},
@{ Id = 'B8'; Name = 'classification vocabulary = exactly 7 values'; Run = {
    $vocab = @(Get-DbM32Classifications)
    $expected = @('SAFE_TO_RESUME','SAFE_TO_RETRY','REFRESH_REQUIRED','READBACK_RECONCILIATION_REQUIRED','HUMAN_REVIEW_REQUIRED','GOVERNANCE_REVIEW_REQUIRED','DO_NOT_RETRY')
    Assert-DbM32 'B8' ($vocab.Count -eq 7) "count=$($vocab.Count)"
    $missing = @($expected | Where-Object { $_ -notin $vocab })
    Assert-DbM32 'B8-vocab' ($missing.Count -eq 0) "missing=$($missing -join ',')"
}},
# === C1-C5: operation identity ===
@{ Id = 'C1'; Name = 'same-op-retried identity'; Run = {
    $root = New-DbM32Fixture 'c1'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -Status 'VERIFIED' -Next 'CLAUDE_REVIEW' -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\verification.json') @{
        changeId = 'CHG-F1'; stateTransition = @{ status = 'VERIFIED' }
        parts = @{ part10 = @{ sha256Before = $shaB; sha256After = $shaB } }
        generatedAtUtc = '2026-09-01T11:40:00Z'
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'C1' ($r.Markers['OPERATION_IDENTITY'] -eq 'same-op-retried') "identity=$($r.Markers['OPERATION_IDENTITY'])"
    Assert-DbM32 'C1-class' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'SAFE_TO_RESUME') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
    Assert-DbM32 'C1-verdict' ($r.Markers['WORKBOOK_VERDICT'] -eq 'WRITE_CONFIRMED') "verdict=$($r.Markers['WORKBOOK_VERDICT'])"
}},
@{ Id = 'C2'; Name = 'new identity when no evidence exists'; Run = {
    $root = New-DbM32Fixture 'c2'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -WorkbookSha $shaB
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'C2' ($r.Markers['OPERATION_IDENTITY'] -eq 'new') "identity=$($r.Markers['OPERATION_IDENTITY'])"
}},
@{ Id = 'C3'; Name = 'stale identity when recorded SHA disagrees with task'; Run = {
    $root = New-DbM32Fixture 'c3'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -Status 'RESERVED' -Next 'CREATE_CHATGPT_HANDOFF' -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\reservation.json') @{
        changeId = 'CHG-F1'; task = @{ nodeId = 'M-F1' }
        workbook = @{ sha256Before = $shaB; sha256After = ('C' * 64) }
        generatedAtUtc = '2026-09-01T11:40:00Z'
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'C3' ($r.Markers['OPERATION_IDENTITY'] -eq 'stale') "identity=$($r.Markers['OPERATION_IDENTITY'])"
    Assert-DbM32 'C3-class' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'REFRESH_REQUIRED') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
}},
@{ Id = 'C4'; Name = 'wrong-task identity when evidence changeId differs'; Run = {
    $root = New-DbM32Fixture 'c4'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -Status 'VERIFIED' -Next 'CLAUDE_REVIEW' -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\verification.json') @{
        changeId = 'CHG-OTHER'; stateTransition = @{ status = 'VERIFIED' }
        parts = @{ part10 = @{ sha256Before = $shaB; sha256After = $shaB } }
        generatedAtUtc = '2026-09-01T11:40:00Z'
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'C4' ($r.Markers['OPERATION_IDENTITY'] -eq 'wrong-task') "identity=$($r.Markers['OPERATION_IDENTITY'])"
}},
@{ Id = 'C5'; Name = 'completed identity for terminal op that reached end state'; Run = {
    $root = New-DbM32Fixture 'c5'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -Status 'COMPLETION_WRITTEN' -Next 'VALIDATE_WORKBOOK' -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\completion.json') @{
        changeId = 'CHG-F1'; status = 'COMPLETION_WRITTEN'; completedAtUtc = '2026-09-01T11:50:00Z'
        workbookSha256Before = $shaB; workbookSha256After = $shaB; sourceGitEvidence = @{ headCommit = 'H1' }
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'C5' ($r.Markers['OPERATION_IDENTITY'] -eq 'completed') "identity=$($r.Markers['OPERATION_IDENTITY'])"
    Assert-DbM32 'C5-verdict' ($r.Markers['WORKBOOK_VERDICT'] -eq 'WRITE_CONFIRMED') "verdict=$($r.Markers['WORKBOOK_VERDICT'])"
}},
# === D1-D3: workbook recovery verdicts ===
@{ Id = 'D1'; Name = 'WRITE_CONFIRMED verdict'; Run = {
    $root = New-DbM32Fixture 'd1'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -Status 'COMPLETION_WRITTEN' -Next 'VALIDATE_WORKBOOK' -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\completion.json') @{
        changeId = 'CHG-F1'; status = 'COMPLETION_WRITTEN'; completedAtUtc = '2026-09-01T11:50:00Z'
        workbookSha256Before = $shaB; workbookSha256After = $shaB; sourceGitEvidence = @{ headCommit = 'H1' }
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'D1' ($r.Markers['WORKBOOK_VERDICT'] -eq 'WRITE_CONFIRMED') "verdict=$($r.Markers['WORKBOOK_VERDICT'])"
}},
@{ Id = 'D2'; Name = 'WRITE_NOT_APPLIED verdict'; Run = {
    $f = New-DbM32CleanFixture -ChangeId 'CHG-F1'
    Write-DbM32Json (Join-Path $f.Root 'state\reservation.json') @{
        changeId = 'CHG-F1'; task = @{ nodeId = 'M-F1' }
        workbook = @{ sha256Before = $f.Sha; sha256After = ('B' * 64) }
        generatedAtUtc = '2026-09-01T11:40:00Z'
    }
    $r = Invoke-DbM32Cli $f.Root @{ WorkbookPath = $f.Workbook; RepositoryPath = (Join-Path $f.Root 'norepo') }
    Assert-DbM32 'D2' ($r.Markers['WORKBOOK_VERDICT'] -eq 'WRITE_NOT_APPLIED') "verdict=$($r.Markers['WORKBOOK_VERDICT'])"
}},
@{ Id = 'D3'; Name = 'WRITE_STATE_AMBIGUOUS verdict -> no auto overwrite'; Run = {
    $root = New-DbM32Fixture 'd3'; $wb = New-DbM32Workbook $root ("C " + [guid]::NewGuid().ToString())
    $shaC = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -Status 'COMPLETION_WRITTEN' -Next 'VALIDATE_WORKBOOK' -WorkbookSha $shaC
    Write-DbM32Json (Join-Path $root 'state\completion.json') @{
        changeId = 'CHG-OTHER'; status = 'COMPLETION_WRITTEN'; completedAtUtc = '2026-09-01T11:50:00Z'
        workbookSha256Before = ('A' * 64); workbookSha256After = ('B' * 64); sourceGitEvidence = @{ headCommit = 'H1' }
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'D3' ($r.Markers['WORKBOOK_VERDICT'] -eq 'WRITE_STATE_AMBIGUOUS') "verdict=$($r.Markers['WORKBOOK_VERDICT'])"
    Assert-DbM32 'D3-class' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'HUMAN_REVIEW_REQUIRED') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
    Assert-DbM32 'D3-unchanged' ((Get-DbM32FileSha256 -Path $wb) -eq $shaC) 'ambiguous workbook file not modified'
}},
# === E1-E3: writer-lock recovery ===
@{ Id = 'E1'; Name = 'NO_WRITER when no lock file'; Run = {
    $f = New-DbM32CleanFixture
    $r = Invoke-DbM32Cli $f.Root @{ WorkbookPath = $f.Workbook; RepositoryPath = (Join-Path $f.Root 'norepo') }
    Assert-DbM32 'E1' ($r.Markers['WRITER_LOCK'] -eq 'NO_WRITER') "lock=$($r.Markers['WRITER_LOCK'])"
}},
@{ Id = 'E2'; Name = 'STALE_WRITER_RECORD for dead pid, lock never deleted'; Run = {
    $f = New-DbM32CleanFixture
    $lock = New-DbM32WriterLock -Root $f.Root -ProcessId 99999999
    $r = Invoke-DbM32Cli $f.Root @{ WorkbookPath = $f.Workbook; RepositoryPath = (Join-Path $f.Root 'norepo') }
    Assert-DbM32 'E2' ($r.Markers['WRITER_LOCK'] -eq 'STALE_WRITER_RECORD') "lock=$($r.Markers['WRITER_LOCK'])"
    Assert-DbM32 'E2-class' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'HUMAN_REVIEW_REQUIRED') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
    Assert-DbM32 'E2-action' ($r.Markers['RECOMMENDED_ACTION'] -eq 'RECLAIM STALE WRITER LOCK') "action=$($r.Markers['RECOMMENDED_ACTION'])"
    Assert-DbM32 'E2-notdeleted' (Test-Path -LiteralPath $lock -PathType Leaf) 'lock file still present after run'
}},
@{ Id = 'E3'; Name = 'ACTIVE_WRITER for live pid, lock never deleted'; Run = {
    $f = New-DbM32CleanFixture
    $lock = New-DbM32WriterLock -Root $f.Root -ProcessId $PID
    $r = Invoke-DbM32Cli $f.Root @{ WorkbookPath = $f.Workbook; RepositoryPath = (Join-Path $f.Root 'norepo') }
    Assert-DbM32 'E3' ($r.Markers['WRITER_LOCK'] -eq 'ACTIVE_WRITER') "lock=$($r.Markers['WRITER_LOCK'])"
    Assert-DbM32 'E3-action' ($r.Markers['RECOMMENDED_ACTION'] -eq 'NONE REQUIRED') "action=$($r.Markers['RECOMMENDED_ACTION'])"
    Assert-DbM32 'E3-notdeleted' (Test-Path -LiteralPath $lock -PathType Leaf) 'lock file still present after run'
}},
# === F1-F2: git recovery ===
@{ Id = 'F1'; Name = 'git HEAD drift -> REVIEW GIT STATE, remote never inferred'; Run = {
    $root = New-DbM32Fixture 'f1'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\preflight.json') @{
        changeId = ''; nodeId = 'M-F1'; status = 'PREFLIGHTED'; verdict = 'NO_IMPLEMENTABLE_DESCENDANT'
        workbookSha256 = $shaB; selectedAt = '2026-09-01T11:20:00Z'
    }
    $repo = New-DbM32GitRepo -Path (Join-Path $root 'gitrepo') -File1 'a.txt' -Content1 'c1' -File2 'b.txt' -Content2 'c2'
    Write-DbM32Json (Join-Path $root 'state\git-gate-state.json') @{
        changeId = ''; branch = 'feature/dbm32-fixture'; headCommit = $repo.Head1; prState = 'UNKNOWN'
        generatedAtUtc = '2026-09-01T11:50:00Z'
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = $repo.Path }
    Assert-DbM32 'F1' ($r.Markers['GIT_HEAD'] -eq $repo.Head2) "head=$($r.Markers['GIT_HEAD'])"
    Assert-DbM32 'F1-class' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'REFRESH_REQUIRED') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
    Assert-DbM32 'F1-action' ($r.Markers['RECOMMENDED_ACTION'] -eq 'REVIEW GIT STATE') "action=$($r.Markers['RECOMMENDED_ACTION'])"
    Assert-DbM32 'F1-pr' ($r.Markers['GIT_PR_STATE'] -match '^UNKNOWN') "pr=$($r.Markers['GIT_PR_STATE'])"
}},
@{ Id = 'F2'; Name = 'git consistent -> SAFE_TO_RESUME'; Run = {
    $root = New-DbM32Fixture 'f2'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\preflight.json') @{
        changeId = ''; nodeId = 'M-F1'; status = 'PREFLIGHTED'; verdict = 'NO_IMPLEMENTABLE_DESCENDANT'
        workbookSha256 = $shaB; selectedAt = '2026-09-01T11:20:00Z'
    }
    $repo = New-DbM32GitRepo -Path (Join-Path $root 'gitrepo') -File1 'a.txt' -Content1 'c1'
    Write-DbM32Json (Join-Path $root 'state\git-gate-state.json') @{
        changeId = ''; branch = 'feature/dbm32-fixture'; headCommit = $repo.Head1; prState = 'UNKNOWN'
        generatedAtUtc = '2026-09-01T11:50:00Z'
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = $repo.Path }
    Assert-DbM32 'F2' ($r.Markers['GIT_HEAD'] -eq $repo.Head1) "head=$($r.Markers['GIT_HEAD'])"
    Assert-DbM32 'F2-class' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'SAFE_TO_RESUME') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
}},
# === G1-G4: safe retry ===
@{ Id = 'G1'; Name = 'safe command offered RETRY'; Run = {
    $root = New-DbM32Fixture 'g1'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -Status 'VERIFIED' -Next 'CLAUDE_REVIEW' -WorkbookSha $shaB
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'G1' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'SAFE_TO_RETRY') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
    Assert-DbM32 'G1-action' ($r.Markers['RECOMMENDED_ACTION'] -eq 'RE-RUN VERIFICATION') "action=$($r.Markers['RECOMMENDED_ACTION'])"
}},
@{ Id = 'G2'; Name = 'non-catalog command is NOT offered RETRY'; Run = {
    $root = New-DbM32Fixture 'g2'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\preflight.json') @{
        changeId = ''; nodeId = 'M-F1'; status = 'PREFLIGHTED'; verdict = 'NO_IMPLEMENTABLE_DESCENDANT'
        workbookSha256 = $shaB; selectedAt = '2026-09-01T11:20:00Z'
    }
    Write-DbM32Json (Join-Path $root 'state\current-lifecycle-state.json') @{
        mode = 'TRIAL'; trialMode = $true; status = 'PREFLIGHTED'; nextAllowedAction = 'RESOLVE_GOVERNANCE_BLOCK'
        generatedAtUtc = '2026-09-01T11:50:00Z'
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'G2' ($r.Markers['LAST_OPERATION'] -eq 'GET_CURRENT_LIFECYCLE_STATE') "last=$($r.Markers['LAST_OPERATION'])"
    Assert-DbM32 'G2-notretry' ($r.Markers['RECOVERY_CLASSIFICATION'] -ne 'SAFE_TO_RETRY') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
    $view = Get-DbM32ReconciledView -Root $root -StateSource 'FIXTURE' -WorkbookPath $wb -RepositoryPath (Join-Path $root 'norepo') -NowUtc $script:Now
    Assert-DbM32 'G2-incatalog' (-not $view.SafeRetry.InCatalog) "inCatalog=$($view.SafeRetry.InCatalog)"
}},
@{ Id = 'G3'; Name = 'unsafe command is NOT offered RETRY'; Run = {
    $root = New-DbM32Fixture 'g3'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\completion.json') @{
        changeId = 'CHG-F1'; status = 'COMPLETION_WRITTEN'; completedAtUtc = '2026-09-01T11:50:00Z'
        workbookSha256Before = ('B' * 64); workbookSha256After = $shaB; sourceGitEvidence = @{ headCommit = 'H1' }
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'G3' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'DO_NOT_RETRY') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
    $view = Get-DbM32ReconciledView -Root $root -StateSource 'FIXTURE' -WorkbookPath $wb -RepositoryPath (Join-Path $root 'norepo') -NowUtc $script:Now
    Assert-DbM32 'G3-retryhidden' (-not $view.SafeRetry.RetryShown) "retryShown=$($view.SafeRetry.RetryShown)"
}},
@{ Id = 'G4'; Name = 'safe-retry catalog = exactly 12 governed commands'; Run = {
    $catalog = @(Get-DbM32SafeRetryCommands)
    $expected = @('RUN_PREFLIGHT','RESERVE_TASK','CREATE_CHATGPT_HANDOFF','REGISTER_IMPLEMENTATION_RESULT','RUN_VERIFICATION','CREATE_CLAUDE_REVIEW_PACKAGE','RECORD_CLAUDE_RESULT','CREATE_CORRECTION_CONTEXT','REFRESH_GIT_GATE_STATE','RUN_GOVERNED_COMPLETION','VALIDATE_WORKBOOK','CLOSE_TRIAL_CYCLE')
    Assert-DbM32 'G4' ($catalog.Count -eq 12) "count=$($catalog.Count)"
    $missing = @($expected | Where-Object { $_ -notin $catalog })
    Assert-DbM32 'G4-complete' ($missing.Count -eq 0) "missing=$($missing -join ',')"
}},
# === H1-H3: operator recovery panel ===
@{ Id = 'H1'; Name = 'panel renders all six recovery fields'; Run = {
    $f = New-DbM32CleanFixture
    $html = Join-Path $f.Root 'recovery-panel.html'
    $r = Invoke-DbM32Cli $f.Root @{ WorkbookPath = $f.Workbook; RepositoryPath = (Join-Path $f.Root 'norepo'); RenderPath = $html }
    $content = [System.IO.File]::ReadAllText($html)
    $fields = @('SYSTEM RECOVERY STATUS','LAST OPERATION','EXPECTED STATE','OBSERVED STATE','RECOVERY CLASSIFICATION','RECOMMENDED HUMAN ACTION')
    $missing = @($fields | Where-Object { $content -notmatch [regex]::Escape($_) })
    Assert-DbM32 'H1' ($missing.Count -eq 0) "missing=$($missing -join ',')"
    Assert-DbM32 'H1-render' ($r.Markers['RENDER'] -eq 'PASS') "render=$($r.Markers['RENDER'])"
    Assert-DbM32 'H1-notgeneric' ($content -notmatch 'something went wrong') 'no generic failure text'
}},
@{ Id = 'H2'; Name = 'recommended action is specific, never generic'; Run = {
    $root = New-DbM32Fixture 'h2'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\completion.json') @{
        changeId = 'CHG-F1'; status = 'COMPLETION_WRITTEN'; completedAtUtc = '2026-09-01T11:50:00Z'
        workbookSha256Before = ('B' * 64); workbookSha256After = $shaB; sourceGitEvidence = @{ headCommit = 'H1' }
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'H2' ($r.Markers['RECOMMENDED_ACTION'] -eq 'REVIEW WORKBOOK READ-BACK') "action=$($r.Markers['RECOMMENDED_ACTION'])"
}},
@{ Id = 'H3'; Name = 'example actions vocabulary present'; Run = {
    $actions = @(Get-DbM32RecoveryActions)
    $expected = @('REFRESH STATE','RE-RUN VERIFICATION','REVIEW WORKBOOK READ-BACK','RECORD CLAUDE RESULT AGAIN','REVIEW GIT STATE','HUMAN GOVERNANCE REVIEW')
    $missing = @($expected | Where-Object { $_ -notin $actions })
    Assert-DbM32 'H3' ($missing.Count -eq 0) "missing=$($missing -join ',')"
}},
# === I1-I2: backend-state mismatch ===
@{ Id = 'I1'; Name = 'backend-state mismatch preserved -> REFRESH STATE'; Run = {
    $root = New-DbM32Fixture 'i1'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\verification.json') @{
        changeId = 'CHG-F1'; stateTransition = @{ status = 'VERIFIED' }
        parts = @{ part10 = @{ sha256Before = $shaB; sha256After = $shaB } }
        generatedAtUtc = '2026-09-01T11:40:00Z'
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'I1' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'REFRESH_REQUIRED') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
    Assert-DbM32 'I1-action' ($r.Markers['RECOMMENDED_ACTION'] -eq 'REFRESH STATE') "action=$($r.Markers['RECOMMENDED_ACTION'])"
}},
@{ Id = 'I2'; Name = 'BACKEND_STATE_MISMATCH token reported verbatim'; Run = {
    $root = New-DbM32Fixture 'i2'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\verification.json') @{
        changeId = 'CHG-F1'; stateTransition = @{ status = 'VERIFIED' }
        parts = @{ part10 = @{ sha256Before = $shaB; sha256After = $shaB } }
        generatedAtUtc = '2026-09-01T11:40:00Z'
    }
    $view = Get-DbM32ReconciledView -Root $root -StateSource 'FIXTURE' -WorkbookPath $wb -RepositoryPath (Join-Path $root 'norepo') -NowUtc $script:Now
    Assert-DbM32 'I2' $view.BackendMismatch.Present 'mismatch present'
    Assert-DbM32 'I2-token' ($view.BackendMismatch.Token -eq 'BACKEND_STATE_MISMATCH') "token=$($view.BackendMismatch.Token)"
    Assert-DbM32 'I2-fields' ($view.BackendMismatch.ExpectedResultState -eq 'VERIFIED' -and $view.BackendMismatch.ActualResultState -eq 'PREFLIGHTED') "expected=$($view.BackendMismatch.ExpectedResultState) actual=$($view.BackendMismatch.ActualResultState)"
}},
# === J1: stale governance ===
@{ Id = 'J1'; Name = 'STALE_GOVERNANCE_STATE preserved, no silent overwrite'; Run = {
    $root = New-DbM32Fixture 'j1'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -Status 'RESERVED' -Next 'CREATE_CHATGPT_HANDOFF' -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\reservation.json') @{
        changeId = 'CHG-F1'; task = @{ nodeId = 'M-F1' }
        workbook = @{ sha256Before = ('A' * 64); sha256After = $shaB }
        generatedAtUtc = '2026-09-01T11:40:00Z'
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'J1' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'GOVERNANCE_REVIEW_REQUIRED') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
    Assert-DbM32 'J1-action' ($r.Markers['RECOMMENDED_ACTION'] -eq 'HUMAN GOVERNANCE REVIEW') "action=$($r.Markers['RECOMMENDED_ACTION'])"
    Assert-DbM32 'J1-unchanged' ((Get-DbM32FileSha256 -Path $wb) -eq $shaB) 'workbook file not overwritten'
}},
# === K1: diagnostics/logging ===
@{ Id = 'K1'; Name = 'essential diagnostics written with 12 fields, no secret'; Run = {
    $f = New-DbM32CleanFixture
    $diag = Join-Path $f.Root 'diagnostics.txt'
    $r = Invoke-DbM32Cli $f.Root @{ WorkbookPath = $f.Workbook; RepositoryPath = (Join-Path $f.Root 'norepo'); DiagnosticsPath = $diag }
    Assert-DbM32 'K1-write' ($r.Markers['DIAGNOSTICS_WRITE'] -eq 'PASS') "write=$($r.Markers['DIAGNOSTICS_WRITE'])"
    $lines = [System.IO.File]::ReadAllLines($diag)
    Assert-DbM32 'K1-count' ($lines.Count -ge 12) "lines=$($lines.Count)"
    $joined = ($lines -join '`n')
    foreach ($key in @('TimestampUtc=','OperationId=','Task=','Change=','Mode=','ExpectedLifecycle=','ObservedLifecycle=','Result=','FailureCategory=','RecoveryClassification=','WorkbookSha=','GitHead=')) {
        Assert-DbM32 'K1-field' ($joined -match [regex]::Escape($key)) "missing=$key"
    }
    $leakScan = Test-DbM32SecretLeak -Target $joined
    Assert-DbM32 'K1-nosecret' (-not $leakScan.Leak) 'diagnostics contain no secret-like value'
}},
# === L1-L3: secret redaction ===
@{ Id = 'L1'; Name = 'provider secrets never rendered or logged'; Run = {
    $root = New-DbM32Fixture 'l1'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\preflight.json') @{
        changeId = ''; nodeId = 'M-F1'; status = 'PREFLIGHTED'; verdict = 'NO_IMPLEMENTABLE_DESCENDANT'
        workbookSha256 = $shaB; selectedAt = '2026-09-01T11:30:00Z'
    }
    Write-DbM32Json (Join-Path $root 'config\providers.json') @{
        providers = @(
            @{ ProviderId = 'openai'; Enabled = $false; Configured = $false; SecretReference = 'sk-SECRETFAKE1234567890ABCDEF' }
            @{ ProviderId = 'google'; Enabled = $false; Configured = $false; SecretReference = 'AIzaSECRETFAKE1234567890ABCDEF' }
        )
    }
    Write-DbM32Json (Join-Path $root 'config\ai-routing.json') @{ executionMode = 'MANUAL'; routingDefaults = @{ enabled = $false } }
    $html = Join-Path $root 'panel.html'
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo'); RenderPath = $html }
    Assert-DbM32 'L1-secretscan' ($r.Markers['SECRET_SCAN'] -eq 'PASS') "secret_scan=$($r.Markers['SECRET_SCAN'])"
    Assert-DbM32 'L1-stdout' (($r.Stdout -notmatch 'sk-SECRETFAKE') -and ($r.Stdout -notmatch 'AIzaSECRETFAKE')) 'no secret in stdout'
    $content = [System.IO.File]::ReadAllText($html)
    Assert-DbM32 'L1-html' (($content -notmatch 'sk-SECRETFAKE') -and ($content -notmatch 'AIzaSECRETFAKE')) 'no secret in HTML'
    Assert-DbM32 'L1-configured' ($content -match 'NOT_CONFIGURED') 'provider shown as NOT_CONFIGURED'
    $rows = Get-DbM32ConfigRedacted -Root $root
    $hasSecretProp = $false
    foreach ($row in @($rows)) { if ($row.PSObject.Properties['SecretReference']) { $hasSecretProp = $true } }
    Assert-DbM32 'L1-noprop' (-not $hasSecretProp) 'config rows expose no SecretReference property'
}},
@{ Id = 'L2'; Name = 'secret-like value in state -> SECRET_SCAN FAIL, still exit 0'; Run = {
    $root = New-DbM32Fixture 'l2'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\preflight.json') @{
        changeId = ''; nodeId = 'M-F1'; status = 'PREFLIGHTED'; verdict = 'NO_IMPLEMENTABLE_DESCENDANT'
        workbookSha256 = $shaB; selectedAt = '2026-09-01T11:30:00Z'
    }
    Write-DbM32Json (Join-Path $root 'state\pre-devbridge-baseline.json') @{
        representOnly = 'sk-SECRETFAKE1234567890ABCDEF'
        workbook = @{ sha256 = ('D' * 64) }
        git = @{ headCommit = ('E' * 40) }
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'L2' ($r.Markers['SECRET_SCAN'] -eq 'FAIL') "secret_scan=$($r.Markers['SECRET_SCAN'])"
    Assert-DbM32 'L2-result' ($r.Markers['RESULT_PASS'] -eq 'False') "result_pass=$($r.Markers['RESULT_PASS'])"
    Assert-DbM32 'L2-exit' ($r.Exit -eq 0) "exit=$($r.Exit)"
}},
@{ Id = 'L3'; Name = 'hex SHA / recorded values exempt from secret scan'; Run = {
    $view = [pscustomobject]@{
        BeforeSha = ('AB' * 32); AfterSha = ('CD' * 32); RecordedHead = ('EF' * 20)
        WorkbookSha256 = ('11' * 32); Task = [pscustomobject]@{ NodeId = 'M-F1'; ChangeId = 'CHG-F1' }
        Note = 'plain free text, no secret'
    }
    $scan = Test-DbM32SecretLeak -Target $view
    Assert-DbM32 'L3' (-not $scan.Leak) "leak=$($scan.Leak)"
    $view2 = [pscustomobject]@{ Note = ('AB' * 32) }
    $scan2 = Test-DbM32SecretLeak -Target $view2
    Assert-DbM32 'L3-catch' $scan2.Leak 'high-entropy value in a free-text field IS caught'
}},
# === M1-M4: crash / restart fixtures ===
@{ Id = 'M1'; Name = 'restart with stale writer lock -> guidance only, no deletion'; Run = {
    $f = New-DbM32CleanFixture
    $lock = New-DbM32WriterLock -Root $f.Root -ProcessId 99999999
    $r = Invoke-DbM32Cli $f.Root @{ WorkbookPath = $f.Workbook; RepositoryPath = (Join-Path $f.Root 'norepo') }
    Assert-DbM32 'M1' ($r.Markers['WRITER_LOCK'] -eq 'STALE_WRITER_RECORD') "lock=$($r.Markers['WRITER_LOCK'])"
    Assert-DbM32 'M1-action' ($r.Markers['RECOMMENDED_ACTION'] -eq 'RECLAIM STALE WRITER LOCK') "action=$($r.Markers['RECOMMENDED_ACTION'])"
    Assert-DbM32 'M1-notdeleted' (Test-Path -LiteralPath $lock -PathType Leaf) 'lock file still present after run'
}},
@{ Id = 'M2'; Name = 'externally-changed workbook -> readback reconciliation, file untouched'; Run = {
    $root = New-DbM32Fixture 'm2'; $wb = New-DbM32Workbook $root ("EXTERNAL-B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -ChangeId 'CHG-F1' -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\preflight.json') @{
        changeId = 'CHG-F1'; nodeId = 'M-F1'; status = 'PREFLIGHTED'; verdict = 'NO_IMPLEMENTABLE_DESCENDANT'
        workbookSha256 = ('A' * 64); selectedAt = '2026-09-01T11:30:00Z'
    }
    $before = (Get-Item -LiteralPath $wb).LastWriteTimeUtc
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = (Join-Path $root 'norepo') }
    Assert-DbM32 'M2' ($r.Tokens -contains 'WORKBOOK_WRITE_STARTED_BUT_READBACK_MISSING') ("tokens=" + ($r.Tokens -join ','))
    Assert-DbM32 'M2-class' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'READBACK_RECONCILIATION_REQUIRED') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
    Assert-DbM32 'M2-unchanged' ((Get-DbM32FileSha256 -Path $wb) -eq $shaB) 'externally-changed workbook left as-is'
}},
@{ Id = 'M3'; Name = 'restart with changed git HEAD -> drift reported, git untouched'; Run = {
    $root = New-DbM32Fixture 'm3'; $wb = New-DbM32Workbook $root ("B " + [guid]::NewGuid().ToString())
    $shaB = Get-DbM32FileSha256 -Path $wb
    New-DbM32TaskState -Root $root -WorkbookSha $shaB
    Write-DbM32Json (Join-Path $root 'state\preflight.json') @{
        changeId = ''; nodeId = 'M-F1'; status = 'PREFLIGHTED'; verdict = 'NO_IMPLEMENTABLE_DESCENDANT'
        workbookSha256 = $shaB; selectedAt = '2026-09-01T11:20:00Z'
    }
    $repo = New-DbM32GitRepo -Path (Join-Path $root 'gitrepo') -File1 'a.txt' -Content1 'c1' -File2 'b.txt' -Content2 'c2'
    Write-DbM32Json (Join-Path $root 'state\git-gate-state.json') @{
        changeId = ''; branch = 'feature/dbm32-fixture'; headCommit = $repo.Head1; prState = 'UNKNOWN'
        generatedAtUtc = '2026-09-01T11:50:00Z'
    }
    $r = Invoke-DbM32Cli $root @{ WorkbookPath = $wb; RepositoryPath = $repo.Path }
    Assert-DbM32 'M3' ($r.Markers['RECOVERY_CLASSIFICATION'] -eq 'REFRESH_REQUIRED') "class=$($r.Markers['RECOVERY_CLASSIFICATION'])"
    Assert-DbM32 'M3-gitmodified' ($r.Markers['GIT_MODIFIED'] -eq 'False') "git_modified=$($r.Markers['GIT_MODIFIED'])"
}},
@{ Id = 'M4'; Name = 'clean restart twice -> stable OK/SAFE_TO_RESUME'; Run = {
    $f = New-DbM32CleanFixture
    $r1 = Invoke-DbM32Cli $f.Root @{ WorkbookPath = $f.Workbook; RepositoryPath = (Join-Path $f.Root 'norepo') }
    $r2 = Invoke-DbM32Cli $f.Root @{ WorkbookPath = $f.Workbook; RepositoryPath = (Join-Path $f.Root 'norepo') }
    Assert-DbM32 'M4-1' ($r1.Markers['RECOVERY_STATUS'] -eq 'OK' -and $r1.Markers['RECOVERY_CLASSIFICATION'] -eq 'SAFE_TO_RESUME' -and $r1.Exit -eq 0) "run1 status=$($r1.Markers['RECOVERY_STATUS']) class=$($r1.Markers['RECOVERY_CLASSIFICATION'])"
    Assert-DbM32 'M4-2' ($r2.Markers['RECOVERY_STATUS'] -eq 'OK' -and $r2.Markers['RECOVERY_CLASSIFICATION'] -eq 'SAFE_TO_RESUME' -and $r2.Exit -eq 0) "run2 status=$($r2.Markers['RECOVERY_STATUS']) class=$($r2.Markers['RECOVERY_CLASSIFICATION'])"
}},
# === N1-N4: no rollback / no autonomy / always exit 0 ===
@{ Id = 'N1'; Name = 'no destructive-rollback capability in DB-M32 code or CLI'; Run = {
    $guard = Test-DbM32ForbiddenCommand
    Assert-DbM32 'N1-catches' ((Test-DbM32ForbiddenCommand 'git reset --hard HEAD') -and (Test-DbM32ForbiddenCommand 'git clean -fd') -and (Test-DbM32ForbiddenCommand 'gh pr merge 1 --admin') -and (Test-DbM32ForbiddenCommand 'Remove-Item logs\workbook-writer.lock')) 'destructive commands are caught by the guard'
    Assert-DbM32 'N1-benign' ((-not (Test-DbM32ForbiddenCommand 'git status')) -and (-not (Test-DbM32ForbiddenCommand 'git rev-parse HEAD')) -and (-not (Test-DbM32ForbiddenCommand 'Get-DbM32FileSha256'))) 'benign commands pass the guard'
    foreach ($file in @('RecoveryEngine.ps1','RecoveryRender.ps1','Show-DbM32EssentialSafety.ps1')) {
        $content = [System.IO.File]::ReadAllText((Join-Path $script:here $file))
        Assert-DbM32 'N1-scan' (-not (Test-DbM32ForbiddenCommand $content)) "$file contains no forbidden invocation"
    }
    $root = New-DbM32Fixture 'n1'
    $r = Invoke-DbM32Cli $root @{ RepositoryPath = 'git reset --hard HEAD' }
    Assert-DbM32 'N1-cli' ($r.Markers['FORBIDDEN_COMMAND'] -eq 'FAIL') "forbidden=$($r.Markers['FORBIDDEN_COMMAND'])"
    Assert-DbM32 'N1-cli-exit' ($r.Exit -eq 0) "exit=$($r.Exit)"
}},
@{ Id = 'N2'; Name = 'pre-DevBridge baseline stays read-only'; Run = {
    $f = New-DbM32CleanFixture
    $baseline = Join-Path $f.Root 'state\pre-devbridge-baseline.json'
    Write-DbM32Json $baseline @{
        representOnly = 'NO RESTORE FUNCTION EXISTS. Baseline is read-only reference until DB-M34 acceptance and an explicit human decision.'
        workbook = @{ sha256 = ('F5' * 32) }
        git = @{ headCommit = ('EE' * 20) }
    }
    $before = [System.IO.File]::ReadAllText($baseline)
    $r = Invoke-DbM32Cli $f.Root @{ WorkbookPath = $f.Workbook; RepositoryPath = (Join-Path $f.Root 'norepo') }
    Assert-DbM32 'N2' ($r.Markers['AUTOMATIC_BASELINE_RESTORE'] -eq 'NO') "baseline_restore=$($r.Markers['AUTOMATIC_BASELINE_RESTORE'])"
    $after = [System.IO.File]::ReadAllText($baseline)
    Assert-DbM32 'N2-unchanged' ($after -eq $before) 'baseline file byte-identical after run'
}},
@{ Id = 'N3'; Name = 'no autonomy expansion (all NO markers)'; Run = {
    $f = New-DbM32CleanFixture
    $r = Invoke-DbM32Cli $f.Root @{ WorkbookPath = $f.Workbook; RepositoryPath = (Join-Path $f.Root 'norepo') }
    $noMarkers = @('AUTO_EXECUTION_ENABLED','AUTOMATIC_ROLLBACK_CAPABILITY','DESTRUCTIVE_GIT_RECOVERY','AUTOMATIC_PR_CREATED','AUTOMATIC_MERGE_PERFORMED','AUTOMATIC_NEXT_TASK','AUTONOMOUS_DEVELOPMENT_CYCLE','AUTONOMOUS_PARALLEL_SCHEDULER')
    $bad = @($noMarkers | Where-Object { $r.Markers[$_] -notin @('False','NO') })
    Assert-DbM32 'N3' ($bad.Count -eq 0) "non-NO markers=$($bad -join ',')"
    Assert-DbM32 'N3-guard' ($r.Markers['AUTO_EXECUTION_ENABLED'] -eq 'False') "auto_exec=$($r.Markers['AUTO_EXECUTION_ENABLED'])"
}},
@{ Id = 'N4'; Name = 'CLI always exits 0 (pass, secret-fail, forbidden)'; Run = {
    $f = New-DbM32CleanFixture
    $r1 = Invoke-DbM32Cli $f.Root @{ WorkbookPath = $f.Workbook; RepositoryPath = (Join-Path $f.Root 'norepo') }
    Assert-DbM32 'N4-clean' ($r1.Exit -eq 0) "exit=$($r1.Exit)"
    $root2 = New-DbM32Fixture 'n4b'; $wb2 = New-DbM32Workbook $root2 ("B " + [guid]::NewGuid().ToString())
    $sha2 = Get-DbM32FileSha256 -Path $wb2
    New-DbM32TaskState -Root $root2 -WorkbookSha $sha2
    Write-DbM32Json (Join-Path $root2 'state\pre-devbridge-baseline.json') @{ representOnly = 'sk-SECRETFAKE1234567890ABCDEF' }
    $r2 = Invoke-DbM32Cli $root2 @{ WorkbookPath = $wb2; RepositoryPath = (Join-Path $root2 'norepo') }
    Assert-DbM32 'N4-secret' ($r2.Exit -eq 0) "exit=$($r2.Exit)"
    $root3 = New-DbM32Fixture 'n4c'
    $r3 = Invoke-DbM32Cli $root3 @{ RepositoryPath = 'git clean -fd' }
    Assert-DbM32 'N4-forbidden' ($r3.Exit -eq 0) "exit=$($r3.Exit)"
}}
    )
}
$script:ScenarioTable = @(Get-DbM32ScenarioTable)

# ---- run the requested scenarios ----

$filter = if ($Scenarios -ne 'ALL') { @($Scenarios -split ',') } else { $null }
foreach ($s in $script:ScenarioTable) {
    if ($filter -and ($s.Id -notin $filter)) { continue }
    'SCENARIO|{0}|{1}' -f $s.Id, $s.Name
    try { & $s.Run } catch {
        $script:Failed++
        [void]$script:Fails.Add("$($s.Id) :: harness exception: $($_.Exception.Message)")
        'TEST|{0}|FAIL|harness exception: {1}' -f $s.Id, $_.Exception.Message
    }
}

# ---- summary ----

$total = $script:Passed + $script:Failed
$scenRan = @($script:ScenarioTable | Where-Object { -not $filter -or ($_.Id -in $filter) }).Count
"DB32_TEST_SCENARIOS_RUN: $scenRan"
"DB32_TEST_SCENARIOS_TOTAL: $($script:ScenarioTable.Count)"
"DB32_TEST_ASSERTIONS_PASSED: $($script:Passed)"
"DB32_TEST_ASSERTIONS_FAILED: $($script:Failed)"
if ($script:Failed -gt 0) {
    foreach ($f in $script:Fails) { "DB32_TEST_FAILURE: $f" }
    "DB32_TEST_OUTCOME: FAIL"
    exit 1
}
'DB32_TEST_OUTCOME: PASS'
exit 0
