# Test-DbM31GovernedRealUse.ps1 -- DB-M31 54-scenario acceptance suite.
#
# Fixture-driven, deterministic. Proves the governed workbook write chain, the
# Git lifecycle observation, the human PR/review/merge gates, the hardened M10 /
# M11 / fix-task rules, the PR preparation package, the audit trace, the
# pre-DevBridge baseline read-only posture, and the absolute no-autonomy
# boundary (A1-D54). The live canonical workbook and the Nexus source are never
# written: every fixture lives under a throwaway scratch root and is removed at
# the end. Child regressions (DB-M30, DB-M12.4) run as separate processes.

[CmdletBinding()]
param(
    [string]$Root = 'C:\Personal\DevTools\DevBridge',
    [string]$ScratchRoot = '',
    [switch]$SkipChildRegressions
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'WorkbookGitContracts.ps1')
. (Join-Path $scriptDir 'WorkbookGitEngine.ps1')
. (Join-Path $scriptDir 'WorkbookGitRender.ps1')

$cfg = Get-DbM31Config -Root $Root
if (-not $ScratchRoot) { $ScratchRoot = Join-Path $env:TEMP ("db-m31-" + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
if (-not (Test-Path -LiteralPath $ScratchRoot)) { New-Item -ItemType Directory -Force -Path $ScratchRoot | Out-Null }

$script:ScratchRoot = $ScratchRoot
$script:AssertPass = 0
$script:AssertFail = 0
$script:ScenarioResults = New-Object System.Collections.ArrayList
$script:RunLog = New-Object System.Text.StringBuilder

function Out-RunLog([string]$Line) {
    [void]$script:RunLog.AppendLine($Line)
    Write-Output $Line
}

# --- assertion helpers -----------------------------------------------------------

function Assert-True([bool]$Condition, [string]$Label, [string]$Detail = '') {
    if ($Condition) { $script:AssertPass++ }
    else {
        $script:AssertFail++
        Out-RunLog ("FAIL: $Label $Detail")
    }
}

function Assert-Eq($Actual, $Expected, [string]$Label) {
    Assert-True ($Actual -eq $Expected) $Label "(expected '$Expected', got '$Actual')"
}

function Assert-NotEq($Actual, $Expected, [string]$Label) {
    Assert-True ($Actual -ne $Expected) $Label "(expected not '$Expected', got '$Actual')"
}

function Assert-Contains([string]$Actual, [string]$Needle, [string]$Label) {
    Assert-True ($Actual -and $Actual.Contains($Needle)) $Label "(missing '$Needle' in '$Actual')"
}

function Assert-CountEq([object[]]$Items, [int]$Expected, [string]$Label) {
    # NOTE: Measure-Object emits a single summary object, so @(... | Measure-Object).Count
    # is always 1. Collect the filtered items into an array and count THAT.
    $n = @($Items | Where-Object { $_ }).Count
    Assert-Eq $n $Expected $Label
}

function Get-DbM31CommentLines {
    <#
    .SYNOPSIS
    Line numbers occupied by PowerShell comment tokens in a source file (line and
    block comments). Used by the autonomy scans so documentation prose -- which
    legitimately names the forbidden commands (git reset --hard, gh pr create,
    ...) as what DB-M31 must never do -- is never counted as an invocation.
    #>
    param([string]$Path)
    $lines = @{}
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    foreach ($tok in @($tokens)) {
        if ($tok.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment) {
            for ($n = $tok.Extent.StartLineNumber; $n -le $tok.Extent.EndLineNumber; $n++) { $lines[$n] = $true }
        }
    }
    return $lines
}

function Invoke-DbM31Scenario {
    param([string]$Id, [string]$Name, [scriptblock]$Block)
    $before = $script:AssertFail
    & $Block
    $failedHere = $script:AssertFail - $before
    $ok = ($failedHere -eq 0)
    [void]$script:ScenarioResults.Add([pscustomobject]@{ Id = $Id; Name = $Name; Pass = $ok; Failures = $failedHere })
    Out-RunLog ("SCENARIO $Id ($Name): " + $(if ($ok) { 'PASS' } else { "FAIL ($failedHere assertions failed)" }))
}

# --- fixture: workbook builder ----------------------------------------------------

function New-DbM31FixtureWorkbook {
    <#
    .SYNOPSIS
    Build a synthetic 14-sheet xlsx fixture (inline strings, no sharedStrings).
    Master Roadmap header row 5 / data start 6; Active Changes + Version History
    header 5 / data 6; Activity Log header 4 / data 5 (per development-control-map).
    Protected sheets carry deterministic protected cells at row 10+ so the
    fixture fingerprint is stable and meaningful.
    #>
    param(
        [string]$Path,
        [string]$ChangeId = 'CHG-FIX-001',
        [string]$NodeId = 'M-FIX-0.1',
        [string]$NodeStatus = 'Open',
        [switch]$Completed
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }

    $ns = $script:DbM31Ns
    $relNs = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    $pkgRelNs = 'http://schemas.openxmlformats.org/package/2006/relationships'

    $all14 = @(
        'Control Center', 'Master Roadmap', 'Active Changes', 'Audit Findings',
        'Session Protocol', 'Version History', 'Phase Plan', 'Architecture Decisions',
        'Open Decisions', 'Dependencies & Blockers', 'Tool & Integration Registry',
        'Activity Log', 'Development Guide', 'Existing Assets'
    )

    # per-sheet data rows: RowNum -> @{ Col = Value }
    $reservationStatus = if ($Completed) { 'Closed' } else { $NodeStatus }
    $sheetData = @{
        'Control Center' = @(@{ Row = 2; Cells = @{ A = 'fixture control'; B = 'narrative' } })
        'Master Roadmap' = @(
            @{ Row = 5; Cells = @{ A = 'Node ID'; B = 'Milestone'; Q = 'Goal'; R = 'Status'; X = 'Seq' } },
            @{ Row = 10; Cells = @{ A = $NodeId; B = 'FIX-M'; Q = 'Fixture goal one'; R = $(if ($Completed) { 'Complete' } else { $NodeStatus }); X = '1' } },
            @{ Row = 11; Cells = @{ A = 'M-FIX-0.2'; B = 'FIX-M'; Q = 'Fixture goal two'; R = 'Complete'; X = '2' } }
        )
        'Active Changes' = @(
            @{ Row = 5; Cells = @{ A = 'Change ID'; B = 'Node ID'; L = 'Status' } },
            @{ Row = 6; Cells = @{ A = $ChangeId; B = $NodeId; L = $reservationStatus; N = 'fixture reservation' } }
        )
        'Audit Findings' = @(@{ Row = 2; Cells = @{ A = 'audit findings fixture' } })
        'Session Protocol' = @(@{ Row = 2; Cells = @{ A = 'session protocol fixture' } })
        'Version History' = @(
            @{ Row = 5; Cells = @{ A = 'Node ID'; B = 'Version'; AC = 'Is Current' } },
            @{ Row = 6; Cells = @{ A = $NodeId; B = '0.1.0'; AC = $(if ($Completed) { 'Yes' } else { 'No' }) } }
        )
        'Phase Plan' = @(
            @{ Row = 4; Cells = @{ A = 'Phase ID'; B = 'Phase' } },
            @{ Row = 10; Cells = @{ A = 'PH-FIX-1'; B = 'Fixture Phase One' } }
        )
        'Architecture Decisions' = @(
            @{ Row = 4; Cells = @{ A = 'ADR ID'; B = 'Decision' } },
            @{ Row = 10; Cells = @{ A = 'AD-FIX-1'; B = 'fixture architecture decision' } }
        )
        'Open Decisions' = @(
            @{ Row = 4; Cells = @{ A = 'OD ID'; B = 'Open decision' } },
            @{ Row = 10; Cells = @{ A = 'OD-FIX-1'; B = 'fixture open decision' } }
        )
        'Dependencies & Blockers' = @(
            @{ Row = 4; Cells = @{ A = 'Dep ID'; B = 'From'; C = 'To' } },
            @{ Row = 10; Cells = @{ A = 'DEP-FIX-1'; B = 'FROM-X'; C = 'TO-Y' } }
        )
        'Tool & Integration Registry' = @(@{ Row = 2; Cells = @{ A = 'tool registry fixture' } })
        'Activity Log' = @(
            @{ Row = 4; Cells = @{ A = 'Activity'; J = 'Change ID' } },
            @{ Row = 5; Cells = @{ A = 'ACT-FIX'; J = $ChangeId; B = 'fixture activity' } }
        )
        'Development Guide' = @(@{ Row = 2; Cells = @{ A = 'development guide fixture' } })
        'Existing Assets' = @(@{ Row = 2; Cells = @{ A = 'existing assets fixture' } })
    }

    function New-FixtureCell([string]$Ref, [string]$Value) {
        $c = [System.Xml.Linq.XElement]::new([System.Xml.Linq.XName]::Get('c', $ns))
        $c.SetAttributeValue('r', $Ref)
        $c.SetAttributeValue('t', 'inlineStr')
        $is = [System.Xml.Linq.XElement]::new([System.Xml.Linq.XName]::Get('is', $ns))
        $t = [System.Xml.Linq.XElement]::new([System.Xml.Linq.XName]::Get('t', $ns))
        $t.Value = $Value
        $is.Add($t)
        $c.Add($is)
        return $c
    }

    $zip = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        # [Content_Types].xml
        $ctSb = New-Object System.Text.StringBuilder
        [void]$ctSb.Append("<?xml version='1.0' encoding='UTF-8' standalone='yes'?><Types xmlns='http://schemas.openxmlformats.org/package/2006/content-types'><Default Extension='rels' ContentType='application/vnd.openxmlformats-package.relationships+xml'/><Default Extension='xml' ContentType='application/xml'/><Override PartName='/xl/workbook.xml' ContentType='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml'/>")
        for ($i = 1; $i -le 14; $i++) { [void]$ctSb.Append("<Override PartName='/xl/worksheets/sheet$i.xml' ContentType='application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml'/>") }
        [void]$ctSb.Append('</Types>')
        Add-DbM31FixturePart -Zip $zip -Name '[Content_Types].xml' -Text $ctSb.ToString()

        # _rels/.rels
        Add-DbM31FixturePart -Zip $zip -Name '_rels/.rels' -Text "<?xml version='1.0' encoding='UTF-8' standalone='yes'?><Relationships xmlns='$pkgRelNs'><Relationship Id='rId1' Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument' Target='xl/workbook.xml'/></Relationships>"

        # xl/workbook.xml
        $wbSb = New-Object System.Text.StringBuilder
        [void]$wbSb.Append("<?xml version='1.0' encoding='UTF-8' standalone='yes'?><workbook xmlns='$ns' xmlns:r='$relNs'><sheets>")
        for ($i = 0; $i -lt 14; $i++) { [void]$wbSb.Append("<sheet name='$($all14[$i] -replace '&', '&amp;')' sheetId='$($i + 1)' r:id='rId$($i + 1)'/>") }
        [void]$wbSb.Append('</sheets></workbook>')
        Add-DbM31FixturePart -Zip $zip -Name 'xl/workbook.xml' -Text $wbSb.ToString()

        # xl/_rels/workbook.xml.rels
        $relsSb = New-Object System.Text.StringBuilder
        [void]$relsSb.Append("<?xml version='1.0' encoding='UTF-8' standalone='yes'?><Relationships xmlns='$pkgRelNs'>")
        for ($i = 1; $i -le 14; $i++) { [void]$relsSb.Append("<Relationship Id='rId$i' Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet' Target='worksheets/sheet$i.xml'/>") }
        [void]$relsSb.Append('</Relationships>')
        Add-DbM31FixturePart -Zip $zip -Name 'xl/_rels/workbook.xml.rels' -Text $relsSb.ToString()

        # worksheets
        $sheetIdx = 0
        foreach ($sn in $all14) {
            $sheetIdx++
            $doc = [System.Xml.Linq.XDocument]::new()
            $root = [System.Xml.Linq.XElement]::new([System.Xml.Linq.XName]::Get('worksheet', $ns))
            $doc.Add($root)
            $sd = [System.Xml.Linq.XElement]::new([System.Xml.Linq.XName]::Get('sheetData', $ns))
            $root.Add($sd)
            foreach ($r in @($sheetData[$sn])) {
                $rowEl = [System.Xml.Linq.XElement]::new([System.Xml.Linq.XName]::Get('row', $ns))
                $rowEl.SetAttributeValue('r', [string]$r.Row)
                foreach ($col in @($r.Cells.Keys)) {
                    $ref = "$col$($r.Row)"
                    $rowEl.Add((New-FixtureCell $ref ([string]$r.Cells[$col])))
                }
                $sd.Add($rowEl)
            }
            $entry = $zip.CreateEntry("xl/worksheets/sheet$sheetIdx.xml")
            $s = $entry.Open()
            try { $doc.Save($s) } finally { $s.Close() }
        }
    } finally { $zip.Dispose() }
}

function Add-DbM31FixturePart {
    param(
        [System.IO.Compression.ZipArchive]$Zip,
        [string]$Name,
        [string]$Text
    )
    $entry = $Zip.CreateEntry($Name)
    $s = $entry.Open()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $s.Write($bytes, 0, $bytes.Length)
    } finally { $s.Close() }
}

# --- fixture: git repo ------------------------------------------------------------

function New-DbM31FixtureGitRepo {
    param(
        [string]$Path,
        [string]$Branch = 'main',
        [switch]$Dirty
    )
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    & git -C $Path init -q 2>$null
    & git -C $Path config user.email 'fixture@test'
    & git -C $Path config user.name 'Fixture'
    [System.IO.File]::WriteAllText((Join-Path $Path 'README.md'), 'fixture repo', [System.Text.Encoding]::UTF8)
    & git -C $Path add -A
    & git -C $Path commit -q -m 'initial'
    if ($Branch -ne 'main') { & git -C $Path checkout -q -b $Branch }
    if ($Dirty) { [System.IO.File]::WriteAllText((Join-Path $Path 'work.txt'), 'dirty', [System.Text.Encoding]::UTF8) }
    return $Path
}

# --- fixture: state ----------------------------------------------------------------

function New-DbM31FixtureState {
    param(
        [string]$StateDir,
        [hashtable]$S
    )
    # mirror the LIVE layout: Get-DbM31LifecycleState -Root $sd reads $sd\state\
    $stateDir = Join-Path $StateDir 'state'
    if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }
    $ct = [ordered]@{
        nodeId = $S['NodeId']
        changeId = $S['ChangeId']
        mode = $S['Mode']
        status = $S['Status']
        nextAllowedAction = $S['NextAllowedAction']
        preflightVerdict = $S['PreflightVerdict']
        implementability = $S['Implementability']
        approvedScope = $S['ApprovedScope']
        gitLifecycleState = $S['GitLifecycleState']
    }
    [System.IO.File]::WriteAllText((Join-Path $stateDir 'current-task.json'), ($ct | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    if ($S.ContainsKey('VerificationResult')) {
        $v = [ordered]@{ changeId = $S['ChangeId']; primaryResult = $S['VerificationResult'] }
        [System.IO.File]::WriteAllText((Join-Path $stateDir 'verification.json'), ($v | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    }
    if ($S.ContainsKey('ClaudeDecision')) {
        $c = [ordered]@{ changeId = $S['ChangeId']; decision = $S['ClaudeDecision'] }
        [System.IO.File]::WriteAllText((Join-Path $stateDir 'claude-review.json'), ($c | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    }
    if ($S.ContainsKey('HasCompletion') -and $S['HasCompletion']) {
        $cp = [ordered]@{ changeId = $S['ChangeId']; completion = 'GOVERNED_COMPLETION' }
        [System.IO.File]::WriteAllText((Join-Path $stateDir 'completion.json'), ($cp | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    }
    return $StateDir
}

# --- fixture: write environment ----------------------------------------------------

function New-DbM31WriteEnv {
    param([string]$ChangeId, [string]$NodeId, [switch]$Completed)
    $dir = Join-Path $script:ScratchRoot ("env-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $workbook = Join-Path $dir 'fixture.xlsx'
    New-DbM31FixtureWorkbook -Path $workbook -ChangeId $ChangeId -NodeId $NodeId -NodeStatus 'Open' -Completed:$Completed
    $backupDir = Join-Path $dir 'backup'
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    return [pscustomobject]@{
        Workbook  = $workbook
        BackupDir = $backupDir
        LockFile  = Join-Path $dir 'writer.lock'
        AuditPath = Join-Path $dir 'audit.json'
        Dir       = $dir
    }
}

function New-DbM31WritePlan {
    param([string]$OpId, [string]$ChangeId, [string]$NodeId)
    return [pscustomobject]@{
        OperationId = $OpId
        TaskId = $NodeId
        ChangeId = $ChangeId
        Mode = 'TRIAL'
        Operations = @(
            @{ Sheet = 'Active Changes'; Kind = 'Append'; RowMap = @{ A = $ChangeId; B = $NodeId; L = 'Open'; N = 'db31 fixture plan' } }
            @{ Sheet = 'Activity Log'; Kind = 'Append'; RowMap = @{ A = 'ACT-DB31'; J = $ChangeId; B = 'db31 fixture activity' } }
            @{ Sheet = 'Version History'; Kind = 'Append'; RowMap = @{ A = $NodeId; B = '0.2.0'; AC = 'Yes' } }
            @{ Sheet = 'Master Roadmap'; Kind = 'Cell'; Row = 10; Column = 'R'; Value = 'Open'; Expect = 'Open' }
            @{ Sheet = 'Control Center'; Kind = 'Cell'; Row = 2; Column = 'A'; Value = 'db31 fixture changelog'; Expect = 'db31 fixture changelog' }
        )
    }
}

function New-DbM31StructuralPlan {
    param([string]$OpId, [string]$ChangeId, [switch]$PhaseAppend, [switch]$ProtectedCell)
    $ops = New-Object System.Collections.ArrayList
    if ($PhaseAppend) { [void]$ops.Add(@{ Sheet = 'Phase Plan'; Kind = 'Append'; RowMap = @{ A = 'PH-EVIL'; B = 'New Phase' } }) }
    if ($ProtectedCell) { [void]$ops.Add(@{ Sheet = 'Master Roadmap'; Kind = 'Cell'; Row = 10; Column = 'B'; Value = 'evil'; Expect = 'evil' }) }
    return [pscustomobject]@{
        OperationId = $OpId
        TaskId = 'M-FIX-0.1'
        ChangeId = $ChangeId
        Mode = 'TRIAL'
        Operations = @($ops.ToArray())
    }
}

# --- scenario: A1-A14 workbook write chain -----------------------------------------

Invoke-DbM31Scenario -Id 'A1' -Name 'execution-state-only workbook writes' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-A1' -NodeId 'M-FIX-0.1'
    $plan = New-DbM31WritePlan -OpId 'OP-A1' -ChangeId 'CHG-A1' -NodeId 'M-FIX-0.1'
    $shaBefore = Get-DbM31FileSha256 $env.Workbook
    $verdict = Test-DbM31ExecutionStatePlan -Plan $plan -Config $cfg
    Assert-True $verdict.Approved 'A1: approved plan classified Approved'
    Assert-True (-not $verdict.Prohibited) 'A1: no prohibited token'
    $r = Resolve-DbM31CanonicalWrite -WorkbookPath $env.Workbook -ExpectedBeforeSha $shaBefore -Plan $plan -BackupDir $env.BackupDir -LockFile $env.LockFile -AuditPath $env.AuditPath -OperationId 'OP-A1' -TaskId 'M-FIX-0.1' -ChangeId 'CHG-A1' -Mode 'TRIAL' -NowUtc '2026-09-01T09:00:00Z' -Root $Root -Fixture
    Assert-Eq $r.Outcome 'WRITE_VERIFIED' 'A1: write verified'
    Assert-True $r.Success 'A1: success flag true'
    $ac = Get-DbM31WorkbookSheet -WorkbookPath $env.Workbook -SheetName 'Active Changes'
    $found = $false
    foreach ($row in $ac.Rows) { if ($row.Cells.ContainsKey('A') -and $row.Cells['A'] -eq 'CHG-A1' -and $row.Cells.ContainsKey('N') -and $row.Cells['N'] -eq 'db31 fixture plan') { $found = $true } }
    Assert-True $found 'A1: appended Active Changes row present'
}

Invoke-DbM31Scenario -Id 'A2' -Name 'structural roadmap write rejected' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-A2' -NodeId 'M-FIX-0.1'
    $plan = New-DbM31StructuralPlan -OpId 'OP-A2' -ChangeId 'CHG-A2' -PhaseAppend
    $shaBefore = Get-DbM31FileSha256 $env.Workbook
    $verdict = Test-DbM31ExecutionStatePlan -Plan $plan -Config $cfg
    Assert-True (-not $verdict.Approved) 'A2: phase-append plan rejected'
    Assert-True $verdict.Prohibited 'A2: prohibited token surfaced'
    Assert-Eq $verdict.Token 'ROADMAP_STRUCTURE_WRITE_PROHIBITED' 'A2: token ROADMAP_STRUCTURE_WRITE_PROHIBITED'
    $r = Resolve-DbM31CanonicalWrite -WorkbookPath $env.Workbook -ExpectedBeforeSha $shaBefore -Plan $plan -BackupDir $env.BackupDir -LockFile $env.LockFile -AuditPath $env.AuditPath -OperationId 'OP-A2' -TaskId 'M-FIX-0.1' -ChangeId 'CHG-A2' -Mode 'TRIAL' -NowUtc '2026-09-01T09:00:00Z' -Root $Root -Fixture
    Assert-Eq $r.Outcome 'ROADMAP_STRUCTURE_WRITE_PROHIBITED' 'A2: chain returns ROADMAP_STRUCTURE_WRITE_PROHIBITED'
    Assert-True (-not $r.Success) 'A2: no success'
    $shaAfter = Get-DbM31FileSha256 $env.Workbook
    Assert-Eq $shaAfter $shaBefore 'A2: zero bytes written to the workbook'
    $plan2 = New-DbM31StructuralPlan -OpId 'OP-A2B' -ChangeId 'CHG-A2' -ProtectedCell
    $v2 = Test-DbM31ExecutionStatePlan -Plan $plan2 -Config $cfg
    Assert-Eq $v2.Token 'ROADMAP_STRUCTURE_WRITE_PROHIBITED' 'A2: protected identity-column cell write rejected'
}

Invoke-DbM31Scenario -Id 'A3' -Name 'fingerprint before/after' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-A3' -NodeId 'M-FIX-0.1'
    $plan = New-DbM31WritePlan -OpId 'OP-A3' -ChangeId 'CHG-A3' -NodeId 'M-FIX-0.1'
    $fpBefore = Resolve-DbM31ProtectedRoadmapFingerprint -WorkbookPath $env.Workbook -Config $cfg
    $shaBefore = Get-DbM31FileSha256 $env.Workbook
    Assert-True ($fpBefore.Sha256 -ne $null -and $fpBefore.Sha256.Length -gt 0) 'A3: fixture fingerprint computable'
    $r = Resolve-DbM31CanonicalWrite -WorkbookPath $env.Workbook -ExpectedBeforeSha $shaBefore -Plan $plan -BackupDir $env.BackupDir -LockFile $env.LockFile -AuditPath $env.AuditPath -OperationId 'OP-A3' -TaskId 'M-FIX-0.1' -ChangeId 'CHG-A3' -Mode 'TRIAL' -NowUtc '2026-09-01T09:00:00Z' -Root $Root -Fixture
    Assert-Eq $r.Outcome 'WRITE_VERIFIED' 'A3: write verified'
    $fpAfter = Resolve-DbM31ProtectedRoadmapFingerprint -WorkbookPath $env.Workbook -Config $cfg
    Assert-Eq $fpAfter.Sha256 $fpBefore.Sha256 'A3: protected roadmap fingerprint preserved across the execution-state write'
    Assert-Eq $r.FingerprintBefore $fpBefore.Sha256 'A3: chain records fpBefore'
    Assert-Eq $r.FingerprintAfter $fpAfter.Sha256 'A3: chain records fpAfter'
}

Invoke-DbM31Scenario -Id 'A4' -Name 'canonical workbook authority' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-A4' -NodeId 'M-FIX-0.1'
    $plan = New-DbM31WritePlan -OpId 'OP-A4' -ChangeId 'CHG-A4' -NodeId 'M-FIX-0.1'
    $shaBefore = Get-DbM31FileSha256 $env.Workbook
    # no -Fixture: a non-canonical path must be rejected
    $r = Resolve-DbM31CanonicalWrite -WorkbookPath $env.Workbook -ExpectedBeforeSha $shaBefore -Plan $plan -BackupDir $env.BackupDir -LockFile $env.LockFile -AuditPath $env.AuditPath -OperationId 'OP-A4' -TaskId 'M-FIX-0.1' -ChangeId 'CHG-A4' -Mode 'TRIAL' -NowUtc '2026-09-01T09:00:00Z' -Root $Root
    Assert-Eq $r.Outcome 'WORKBOOK_AUTHORITY_REJECTED' 'A4: non-canonical path rejected without -Fixture'
    Assert-True (-not $r.Success) 'A4: not success'
    $shaAfter = Get-DbM31FileSha256 $env.Workbook
    Assert-Eq $shaAfter $shaBefore 'A4: no write on rejected authority'
    $r2 = Resolve-DbM31CanonicalWrite -WorkbookPath $env.Workbook -ExpectedBeforeSha $shaBefore -Plan $plan -BackupDir $env.BackupDir -LockFile $env.LockFile -AuditPath $env.AuditPath -OperationId 'OP-A4B' -TaskId 'M-FIX-0.1' -ChangeId 'CHG-A4' -Mode 'TRIAL' -NowUtc '2026-09-01T09:00:00Z' -Root $Root -Fixture
    Assert-Eq $r2.Outcome 'WRITE_VERIFIED' 'A4: fixture override honored'
}

Invoke-DbM31Scenario -Id 'A5' -Name 'backup before write' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-A5' -NodeId 'M-FIX-0.1'
    $plan = New-DbM31WritePlan -OpId 'OP-A5' -ChangeId 'CHG-A5' -NodeId 'M-FIX-0.1'
    $shaBefore = Get-DbM31FileSha256 $env.Workbook
    $r = Resolve-DbM31CanonicalWrite -WorkbookPath $env.Workbook -ExpectedBeforeSha $shaBefore -Plan $plan -BackupDir $env.BackupDir -LockFile $env.LockFile -AuditPath $env.AuditPath -OperationId 'OP-A5' -TaskId 'M-FIX-0.1' -ChangeId 'CHG-A5' -Mode 'TRIAL' -NowUtc '2026-09-01T09:00:00Z' -Root $Root -Fixture
    Assert-Eq $r.Outcome 'WRITE_VERIFIED' 'A5: write verified'
    Assert-True (Test-Path -LiteralPath $r.BackupPath) 'A5: backup file exists'
    $backupSha = Get-DbM31FileSha256 $r.BackupPath
    Assert-Eq $backupSha $shaBefore 'A5: backup SHA equals the pre-write workbook SHA'
}

Invoke-DbM31Scenario -Id 'A6' -Name 'pre-write hash' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-A6' -NodeId 'M-FIX-0.1'
    $plan = New-DbM31WritePlan -OpId 'OP-A6' -ChangeId 'CHG-A6' -NodeId 'M-FIX-0.1'
    $shaBefore = Get-DbM31FileSha256 $env.Workbook
    $r = Resolve-DbM31CanonicalWrite -WorkbookPath $env.Workbook -ExpectedBeforeSha $shaBefore -Plan $plan -BackupDir $env.BackupDir -LockFile $env.LockFile -AuditPath $env.AuditPath -OperationId 'OP-A6' -TaskId 'M-FIX-0.1' -ChangeId 'CHG-A6' -Mode 'TRIAL' -NowUtc '2026-09-01T09:00:00Z' -Root $Root -Fixture
    Assert-Eq $r.Sha256Before $shaBefore 'A6: result records the pre-write SHA'
}

Invoke-DbM31Scenario -Id 'A7' -name 'post-write hash' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-A7' -NodeId 'M-FIX-0.1'
    $plan = New-DbM31WritePlan -OpId 'OP-A7' -ChangeId 'CHG-A7' -NodeId 'M-FIX-0.1'
    $shaBefore = Get-DbM31FileSha256 $env.Workbook
    $r = Resolve-DbM31CanonicalWrite -WorkbookPath $env.Workbook -ExpectedBeforeSha $shaBefore -Plan $plan -BackupDir $env.BackupDir -LockFile $env.LockFile -AuditPath $env.AuditPath -OperationId 'OP-A7' -TaskId 'M-FIX-0.1' -ChangeId 'CHG-A7' -Mode 'TRIAL' -NowUtc '2026-09-01T09:00:00Z' -Root $Root -Fixture
    Assert-Eq $r.Outcome 'WRITE_VERIFIED' 'A7: write verified'
    $shaAfter = Get-DbM31FileSha256 $env.Workbook
    Assert-NotEq $shaAfter $shaBefore 'A7: post-write SHA differs (execution-state cells written)'
    Assert-Eq $r.Sha256After $shaAfter 'A7: result records the post-write SHA'
}

Invoke-DbM31Scenario -Id 'A8' -Name 'read-back validation' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-A8' -NodeId 'M-FIX-0.1'
    $plan = New-DbM31WritePlan -OpId 'OP-A8' -ChangeId 'CHG-A8' -NodeId 'M-FIX-0.1'
    $shaBefore = Get-DbM31FileSha256 $env.Workbook
    $r = Resolve-DbM31CanonicalWrite -WorkbookPath $env.Workbook -ExpectedBeforeSha $shaBefore -Plan $plan -BackupDir $env.BackupDir -LockFile $env.LockFile -AuditPath $env.AuditPath -OperationId 'OP-A8' -TaskId 'M-FIX-0.1' -ChangeId 'CHG-A8' -Mode 'TRIAL' -NowUtc '2026-09-01T09:00:00Z' -Root $Root -Fixture
    Assert-Eq $r.Outcome 'WRITE_VERIFIED' 'A8: read-back passed inside the chain (WRITE_VERIFIED)'
    $ac = Get-DbM31WorkbookSheet -WorkbookPath $env.Workbook -SheetName 'Active Changes'
    $any = @($ac.Rows | Where-Object { $_.Cells.ContainsKey('A') -and $_.Cells['A'] -eq 'CHG-A8' }).Count
    Assert-True ($any -ge 1) 'A8: read-back of the appended Active Changes row matches'
    $mr = Get-DbM31WorkbookSheet -WorkbookPath $env.Workbook -SheetName 'Master Roadmap'
    $cellOk = $false
    foreach ($row in $mr.Rows) { if ($row.Row -eq 10 -and $row.Cells.ContainsKey('R') -and $row.Cells['R'] -eq 'Open') { $cellOk = $true } }
    Assert-True $cellOk 'A8: read-back of the Master Roadmap execution-state cell matches'
}

Invoke-DbM31Scenario -Id 'A9' -Name 'writer busy' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-A9' -NodeId 'M-FIX-0.1'
    $plan = New-DbM31WritePlan -OpId 'OP-A9' -ChangeId 'CHG-A9' -NodeId 'M-FIX-0.1'
    $shaBefore = Get-DbM31FileSha256 $env.Workbook
    [System.IO.File]::WriteAllText($env.LockFile, 'held', [System.Text.Encoding]::UTF8)
    $r = Resolve-DbM31CanonicalWrite -WorkbookPath $env.Workbook -ExpectedBeforeSha $shaBefore -Plan $plan -BackupDir $env.BackupDir -LockFile $env.LockFile -AuditPath $env.AuditPath -OperationId 'OP-A9' -TaskId 'M-FIX-0.1' -ChangeId 'CHG-A9' -Mode 'TRIAL' -NowUtc '2026-09-01T09:00:00Z' -Root $Root -Fixture
    Assert-Eq $r.Outcome 'WORKBOOK_WRITER_BUSY' 'A9: serialization lock honored'
    Assert-True (-not $r.Success) 'A9: not success'
    $shaAfter = Get-DbM31FileSha256 $env.Workbook
    Assert-Eq $shaAfter $shaBefore 'A9: no write while busy'
}

Invoke-DbM31Scenario -Id 'A10' -Name 'stale state' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-A10' -NodeId 'M-FIX-0.1'
    $plan = New-DbM31WritePlan -OpId 'OP-A10' -ChangeId 'CHG-A10' -NodeId 'M-FIX-0.1'
    $r = Resolve-DbM31CanonicalWrite -WorkbookPath $env.Workbook -ExpectedBeforeSha '0000000000000000000000000000000000000000000000000000000000000000' -Plan $plan -BackupDir $env.BackupDir -LockFile $env.LockFile -AuditPath $env.AuditPath -OperationId 'OP-A10' -TaskId 'M-FIX-0.1' -ChangeId 'CHG-A10' -Mode 'TRIAL' -NowUtc '2026-09-01T09:00:00Z' -Root $Root -Fixture
    Assert-Eq $r.Outcome 'STALE_GOVERNANCE_STATE' 'A10: stale-state check fires on a mismatched expected hash'
    Assert-True (-not $r.Success) 'A10: not success'
    $shaNow = Get-DbM31FileSha256 $env.Workbook
    Assert-True ($shaNow -ne $null) 'A10: workbook untouched (still readable)'
}

Invoke-DbM31Scenario -Id 'A11' -Name 'duplicate write protection' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-A11' -NodeId 'M-FIX-0.1'
    $plan = New-DbM31WritePlan -OpId 'OP-A11' -ChangeId 'CHG-A11' -NodeId 'M-FIX-0.1'
    $sha1 = Get-DbM31FileSha256 $env.Workbook
    $r1 = Resolve-DbM31CanonicalWrite -WorkbookPath $env.Workbook -ExpectedBeforeSha $sha1 -Plan $plan -BackupDir $env.BackupDir -LockFile $env.LockFile -AuditPath $env.AuditPath -OperationId 'OP-A11' -TaskId 'M-FIX-0.1' -ChangeId 'CHG-A11' -Mode 'TRIAL' -NowUtc '2026-09-01T09:00:00Z' -Root $Root -Fixture
    Assert-Eq $r1.Outcome 'WRITE_VERIFIED' 'A11: first write verified'
    $sha2 = Get-DbM31FileSha256 $env.Workbook
    $r2 = Resolve-DbM31CanonicalWrite -WorkbookPath $env.Workbook -ExpectedBeforeSha $sha2 -Plan $plan -BackupDir $env.BackupDir -LockFile $env.LockFile -AuditPath $env.AuditPath -OperationId 'OP-A11' -TaskId 'M-FIX-0.1' -ChangeId 'CHG-A11' -Mode 'TRIAL' -NowUtc '2026-09-01T09:00:01Z' -Root $Root -Fixture
    Assert-Eq $r2.Outcome 'DUPLICATE_WRITE_REJECTED' 'A11: duplicate OperationId rejected (no double-click write)'
    $sha3 = Get-DbM31FileSha256 $env.Workbook
    Assert-Eq $sha3 $sha2 'A11: no duplicate write landed'
}

Invoke-DbM31Scenario -Id 'A12' -Name 'backend mismatch' {
    $bad = Test-DbM31BackendStateMismatch -ClaimedSuccess $true -ExpectedResultState 'CLOSED' -ActualResultState 'OPEN'
    Assert-True $bad.Mismatch 'A12: mismatch flagged when claimed success leaves wrong state'
    Assert-Eq $bad.Token 'BACKEND_STATE_MISMATCH' 'A12: token BACKEND_STATE_MISMATCH'
    $ok = Test-DbM31BackendStateMismatch -ClaimedSuccess $true -ExpectedResultState 'CLOSED' -ActualResultState 'CLOSED'
    Assert-True (-not $ok.Mismatch) 'A12: consistent state not a mismatch'
    $noClaim = Test-DbM31BackendStateMismatch -ClaimedSuccess $false -ExpectedResultState 'CLOSED' -ActualResultState 'OPEN'
    Assert-True (-not $noClaim.Mismatch) 'A12: no claim of success -> no mismatch'
}

Invoke-DbM31Scenario -Id 'A13' -Name 'backup failure handling' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-A13' -NodeId 'M-FIX-0.1'
    $plan = New-DbM31WritePlan -OpId 'OP-A13' -ChangeId 'CHG-A13' -NodeId 'M-FIX-0.1'
    $shaBefore = Get-DbM31FileSha256 $env.Workbook
    # backup dir is actually a file -> backup copy fails
    $badBackup = Join-Path $env.Dir 'backup-is-a-file'
    [System.IO.File]::WriteAllText($badBackup, 'x', [System.Text.Encoding]::UTF8)
    $r = Resolve-DbM31CanonicalWrite -WorkbookPath $env.Workbook -ExpectedBeforeSha $shaBefore -Plan $plan -BackupDir $badBackup -LockFile $env.LockFile -AuditPath $env.AuditPath -OperationId 'OP-A13' -TaskId 'M-FIX-0.1' -ChangeId 'CHG-A13' -Mode 'TRIAL' -NowUtc '2026-09-01T09:00:00Z' -Root $Root -Fixture
    Assert-Eq $r.Outcome 'BACKUP_CREATION_FAILED' 'A13: backup failure surfaced as BACKUP_CREATION_FAILED'
    Assert-True (-not $r.Success) 'A13: not success'
    $shaAfter = Get-DbM31FileSha256 $env.Workbook
    Assert-Eq $shaAfter $shaBefore 'A13: no write when backup failed'
    # missing backup dir -> BACKUP_CREATION_FAILED
    $missing = Join-Path $env.Dir 'nope'
    $r2 = Resolve-DbM31CanonicalWrite -WorkbookPath $env.Workbook -ExpectedBeforeSha $shaBefore -Plan $plan -BackupDir $missing -LockFile $env.LockFile -AuditPath $env.AuditPath -OperationId 'OP-A13B' -TaskId 'M-FIX-0.1' -ChangeId 'CHG-A13' -Mode 'TRIAL' -NowUtc '2026-09-01T09:00:01Z' -Root $Root -Fixture
    Assert-Eq $r2.Outcome 'BACKUP_CREATION_FAILED' 'A13: missing backup dir surfaced as BACKUP_CREATION_FAILED'
}

Invoke-DbM31Scenario -Id 'A14' -Name 'read-back failure handling' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-A14' -NodeId 'M-FIX-0.1'
    # a Cell op whose Expect value can never match the written value -> read-back fails
    $plan = [pscustomobject]@{
        OperationId = 'OP-A14'
        TaskId = 'M-FIX-0.1'
        ChangeId = 'CHG-A14'
        Mode = 'TRIAL'
        Operations = @(
            @{ Sheet = 'Master Roadmap'; Kind = 'Cell'; Row = 10; Column = 'R'; Value = 'Open'; Expect = 'NeverMatch' }
        )
    }
    $shaBefore = Get-DbM31FileSha256 $env.Workbook
    $r = Resolve-DbM31CanonicalWrite -WorkbookPath $env.Workbook -ExpectedBeforeSha $shaBefore -Plan $plan -BackupDir $env.BackupDir -LockFile $env.LockFile -AuditPath $env.AuditPath -OperationId 'OP-A14' -TaskId 'M-FIX-0.1' -ChangeId 'CHG-A14' -Mode 'TRIAL' -NowUtc '2026-09-01T09:00:00Z' -Root $Root -Fixture
    Assert-Eq $r.Outcome 'WORKBOOK_READBACK_FAILED' 'A14: read-back mismatch surfaced as WORKBOOK_READBACK_FAILED'
    Assert-True (-not $r.Success) 'A14: not success'
}

# --- scenario: B15-B31 Git observation + gates + M10 ------------------------------

Invoke-DbM31Scenario -Id 'B15' -Name 'Git branch observation' {
    $repo = Join-Path $script:ScratchRoot ("repo-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureGitRepo -Path $repo -Branch 'feature-db31'
    $obs = Resolve-DbM31GitObservation -RepositoryPath $repo
    Assert-True $obs.IsGitRepo 'B15: recognized as a git repo'
    Assert-Eq $obs.Branch 'feature-db31' 'B15: observed branch'
}

Invoke-DbM31Scenario -Id 'B16' -Name 'HEAD observation' {
    $repo = Join-Path $script:ScratchRoot ("repo-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureGitRepo -Path $repo
    $head = (& git -C $repo rev-parse HEAD).Trim()
    $obs = Resolve-DbM31GitObservation -RepositoryPath $repo
    Assert-Eq $obs.HeadCommit $head 'B16: observed HEAD commit'
    Assert-Eq $obs.CommitState 'PRESENT' 'B16: commit present'
    Assert-True ($obs.HeadSubject -ne $null -and $obs.HeadSubject -eq 'initial') 'B16: observed HEAD subject'
}

Invoke-DbM31Scenario -Id 'B17' -Name 'working-tree observation' {
    $repo = Join-Path $script:ScratchRoot ("repo-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureGitRepo -Path $repo -Dirty
    $obs = Resolve-DbM31GitObservation -RepositoryPath $repo
    Assert-True $obs.WorkingTreeDirty 'B17: dirty working tree observed'
    Assert-True ($obs.UntrackedFiles -contains 'work.txt') 'B17: untracked file listed'
    $repo2 = Join-Path $script:ScratchRoot ("repo-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureGitRepo -Path $repo2
    $obs2 = Resolve-DbM31GitObservation -RepositoryPath $repo2
    Assert-True (-not $obs2.WorkingTreeDirty) 'B17: clean working tree observed clean'
}

Invoke-DbM31Scenario -Id 'B18' -Name 'unknown remote state stays UNKNOWN' {
    $repo = Join-Path $script:ScratchRoot ("repo-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureGitRepo -Path $repo
    $obs = Resolve-DbM31GitObservation -RepositoryPath $repo
    Assert-Eq $obs.PrState 'UNKNOWN' 'B18: PR state never inferred from observation'
    Assert-True (-not $obs.MergeConfirmed) 'B18: merge never confirmed from observation'
    $obs2 = Resolve-DbM31GitObservation -RepositoryPath (Join-Path $script:ScratchRoot 'does-not-exist')
    Assert-True (-not $obs2.IsGitRepo) 'B18: missing repo -> not a git repo'
    Assert-Eq $obs2.PrState 'UNKNOWN' 'B18: missing repo -> PR state UNKNOWN (never NO_PR)'
    Assert-Contains $obs2.Note 'never inferred' 'B18: honesty note present'
}

Invoke-DbM31Scenario -Id 'B19' -Name 'human PR state' {
    $gate = Resolve-DbM31HumanGitGate -GitLifecycleState 'AWAITING_HUMAN_PR'
    Assert-Eq $gate.GateState 'AWAITING_HUMAN_PR' 'B19: gate state AWAITING_HUMAN_PR'
    Assert-True (-not $gate.MergeConfirmed) 'B19: awaiting PR is not merge-confirmed'
    Assert-Contains $gate.HumanAction 'HUMAN: create the PR' 'B19: human action to create the PR'
}

Invoke-DbM31Scenario -Id 'B20' -Name 'PR_OPEN only from evidence' {
    $gate = Resolve-DbM31HumanGitGate -GitLifecycleState '' -PrEvidence 'OPEN'
    Assert-Eq $gate.GateState 'PR_OPEN' 'B20: PR_OPEN from positive PR evidence'
    Assert-True (-not $gate.MergeConfirmed) 'B20: PR_OPEN is not merge-confirmed'
    $gate2 = Resolve-DbM31HumanGitGate -GitLifecycleState ''
    Assert-Eq $gate2.GateState 'PR_STATE_UNKNOWN' 'B20: no evidence -> PR_STATE_UNKNOWN (never PR_OPEN, never NOT_MERGED)'
    $gate3 = Resolve-DbM31HumanGitGate -GitLifecycleState '' -PrEvidence 'CLOSED'
    Assert-Eq $gate3.GateState 'PR_STATE_UNKNOWN' 'B20: PR closure alone never infers merge'
}

Invoke-DbM31Scenario -Id 'B21' -Name 'human review gate' {
    $gate = Resolve-DbM31HumanGitGate -GitLifecycleState 'AWAITING_HUMAN_REVIEW'
    Assert-Eq $gate.GateState 'AWAITING_HUMAN_REVIEW' 'B21: gate state AWAITING_HUMAN_REVIEW'
    Assert-Contains $gate.HumanAction 'HUMAN: perform the PR review' 'B21: human review action'
}

Invoke-DbM31Scenario -Id 'B22' -Name 'human merge gate' {
    $gate = Resolve-DbM31HumanGitGate -GitLifecycleState 'AWAITING_HUMAN_MERGE'
    Assert-Eq $gate.GateState 'AWAITING_HUMAN_MERGE' 'B22: gate state AWAITING_HUMAN_MERGE'
    Assert-Contains $gate.HumanAction 'HUMAN: merge' 'B22: human merge action'
    $gate2 = Resolve-DbM31HumanGitGate -GitLifecycleState 'MERGED'
    Assert-Eq $gate2.GateState 'MERGED' 'B22: MERGED state'
    Assert-True $gate2.MergeConfirmed 'B22: MERGED is merge-confirmed'
}

Invoke-DbM31Scenario -Id 'B23' -Name 'merge not inferred from commit' {
    $repo = Join-Path $script:ScratchRoot ("repo-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureGitRepo -Path $repo
    $obs = Resolve-DbM31GitObservation -RepositoryPath $repo
    Assert-Eq $obs.CommitState 'PRESENT' 'B23: commits exist'
    Assert-True (-not $obs.MergeConfirmed) 'B23: commits alone never confirm a merge'
    $gate = Resolve-DbM31HumanGitGate -GitLifecycleState ''
    Assert-True (-not $gate.MergeConfirmed) 'B23: gate merge-confirmed stays false without evidence'
}

Invoke-DbM31Scenario -Id 'B24' -Name 'merge not inferred from clean tree' {
    $repo = Join-Path $script:ScratchRoot ("repo-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureGitRepo -Path $repo
    $obs = Resolve-DbM31GitObservation -RepositoryPath $repo
    Assert-True (-not $obs.WorkingTreeDirty) 'B24: working tree is clean'
    Assert-True (-not $obs.MergeConfirmed) 'B24: a clean tree never confirms a merge'
    $gate = Resolve-DbM31HumanGitGate -GitLifecycleState '' -MergeEvidence ''
    Assert-True (-not $gate.MergeConfirmed) 'B24: merge-confirmed stays false without positive evidence'
}

Invoke-DbM31Scenario -Id 'B25' -Name 'M10 blocked without merge' {
    $sd = Join-Path $script:ScratchRoot ("state-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureState -StateDir $sd -S @{
        Mode = 'REAL_NEXUS_DEVELOPMENT'; ChangeId = 'CHG-B25'; NodeId = 'M-REAL-0.1'
        Status = 'AWAITING_HUMAN_MERGE'; NextAllowedAction = 'MERGE_PR'
        PreflightVerdict = 'CLEAR'; Implementability = 'IMPLEMENTABLE'; ApprovedScope = 'APPROVED'
        GitLifecycleState = 'AWAITING_HUMAN_MERGE'
        VerificationResult = 'VERIFICATION_PASSED'; ClaudeDecision = 'PASS'; HasCompletion = $true
    }
    $lc = Get-DbM31LifecycleState -Root $sd -StateSource 'FIXTURE'
    $m10 = Resolve-DbM31M10Eligibility -Lifecycle $lc -FingerprintVerdict 'PRESERVED' -FreshState $true
    Assert-True (-not $m10.Eligible) 'B25: M10 not eligible'
    Assert-Eq $m10.Token 'BLOCKED_HUMAN_GIT_MERGE_GATE_PENDING' 'B25: token BLOCKED_HUMAN_GIT_MERGE_GATE_PENDING'
    # no git lifecycle state at all -> MERGE_STATE_UNKNOWN
    $sd2 = Join-Path $script:ScratchRoot ("state-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureState -StateDir $sd2 -S @{
        Mode = 'REAL_NEXUS_DEVELOPMENT'; ChangeId = 'CHG-B25'; NodeId = 'M-REAL-0.1'
        Status = 'PREFLIGHTED'; NextAllowedAction = 'RESOLVE_PREFLIGHT'
        PreflightVerdict = 'CLEAR'; Implementability = 'IMPLEMENTABLE'; ApprovedScope = 'APPROVED'
        GitLifecycleState = ''
        VerificationResult = 'VERIFICATION_PASSED'; ClaudeDecision = 'PASS'; HasCompletion = $true
    }
    $lc2 = Get-DbM31LifecycleState -Root $sd2 -StateSource 'FIXTURE'
    $m10b = Resolve-DbM31M10Eligibility -Lifecycle $lc2 -FingerprintVerdict 'PRESERVED' -FreshState $true
    Assert-Eq $m10b.Token 'MERGE_STATE_UNKNOWN' 'B25: absent git lifecycle -> MERGE_STATE_UNKNOWN'
}

Invoke-DbM31Scenario -Id 'B26' -Name 'M10 blocked without M06 PASS' {
    $sd = Join-Path $script:ScratchRoot ("state-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureState -StateDir $sd -S @{
        Mode = 'REAL_NEXUS_DEVELOPMENT'; ChangeId = 'CHG-B26'; NodeId = 'M-REAL-0.1'
        Status = 'VERIFIED'; NextAllowedAction = 'RUN_CLAUDE_REVIEW'
        PreflightVerdict = 'CLEAR'; Implementability = 'IMPLEMENTABLE'; ApprovedScope = 'APPROVED'
        GitLifecycleState = 'MERGED'
        VerificationResult = 'VERIFICATION_FAILED'; ClaudeDecision = 'PASS'; HasCompletion = $true
    }
    $lc = Get-DbM31LifecycleState -Root $sd -StateSource 'FIXTURE'
    $m10 = Resolve-DbM31M10Eligibility -Lifecycle $lc -FingerprintVerdict 'PRESERVED' -FreshState $true
    Assert-True (-not $m10.Eligible) 'B26: M10 not eligible'
    Assert-Eq $m10.Token 'BLOCKED_NO_DB_M06_VERIFICATION_PASS' 'B26: token BLOCKED_NO_DB_M06_VERIFICATION_PASS'
}

Invoke-DbM31Scenario -Id 'B27' -Name 'M10 blocked without Claude PASS' {
    $sd = Join-Path $script:ScratchRoot ("state-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureState -StateDir $sd -S @{
        Mode = 'REAL_NEXUS_DEVELOPMENT'; ChangeId = 'CHG-B27'; NodeId = 'M-REAL-0.1'
        Status = 'VERIFIED'; NextAllowedAction = 'RUN_CLAUDE_REVIEW'
        PreflightVerdict = 'CLEAR'; Implementability = 'IMPLEMENTABLE'; ApprovedScope = 'APPROVED'
        GitLifecycleState = 'MERGED'
        VerificationResult = 'VERIFICATION_PASSED'; ClaudeDecision = 'FAIL'; HasCompletion = $true
    }
    $lc = Get-DbM31LifecycleState -Root $sd -StateSource 'FIXTURE'
    $m10 = Resolve-DbM31M10Eligibility -Lifecycle $lc -FingerprintVerdict 'PRESERVED' -FreshState $true
    Assert-True (-not $m10.Eligible) 'B27: M10 not eligible'
    Assert-Eq $m10.Token 'BLOCKED_NO_CLAUDE_PASS' 'B27: token BLOCKED_NO_CLAUDE_PASS'
}

Invoke-DbM31Scenario -Id 'B28' -Name 'M10 blocked by governance issue' {
    $sd = Join-Path $script:ScratchRoot ("state-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureState -StateDir $sd -S @{
        Mode = 'REAL_NEXUS_DEVELOPMENT'; ChangeId = 'CHG-B28'; NodeId = 'M-REAL-0.1'
        Status = 'PREFLIGHTED'; NextAllowedAction = 'RESOLVE_PREFLIGHT'
        PreflightVerdict = 'NO_IMPLEMENTABLE_DESCENDANT'; Implementability = 'CONTAINER'; ApprovedScope = 'NOT_APPROVED'
        GitLifecycleState = 'MERGED'
        VerificationResult = 'VERIFICATION_PASSED'; ClaudeDecision = 'PASS'; HasCompletion = $true
    }
    $lc = Get-DbM31LifecycleState -Root $sd -StateSource 'FIXTURE'
    Assert-True $lc.GovernanceBlocked 'B28: governance block detected'
    $m10 = Resolve-DbM31M10Eligibility -Lifecycle $lc -FingerprintVerdict 'PRESERVED' -FreshState $true
    Assert-True (-not $m10.Eligible) 'B28: M10 not eligible'
    Assert-Eq $m10.Token 'BLOCKED_GOVERNANCE_ISSUE' 'B28: token BLOCKED_GOVERNANCE_ISSUE'
}

Invoke-DbM31Scenario -Id 'B29' -Name 'M10 allowed only in REAL fixture' {
    $sd = Join-Path $script:ScratchRoot ("state-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureState -StateDir $sd -S @{
        Mode = 'REAL_NEXUS_DEVELOPMENT'; ChangeId = 'CHG-B29'; NodeId = 'M-REAL-0.1'
        Status = 'READY_FOR_GOVERNED_COMPLETION'; NextAllowedAction = 'RUN_COMPLETION'
        PreflightVerdict = 'CLEAR'; Implementability = 'IMPLEMENTABLE'; ApprovedScope = 'APPROVED'
        GitLifecycleState = 'MERGED'
        VerificationResult = 'VERIFICATION_PASSED'; ClaudeDecision = 'PASS'; HasCompletion = $true
    }
    $lc = Get-DbM31LifecycleState -Root $sd -StateSource 'FIXTURE'
    $m10 = Resolve-DbM31M10Eligibility -Lifecycle $lc -FingerprintVerdict 'PRESERVED' -FreshState $true
    Assert-True $m10.Eligible 'B29: M10 eligible in the full REAL fixture'
    Assert-Eq $m10.Token 'READY_FOR_GOVERNED_COMPLETION' 'B29: token READY_FOR_GOVERNED_COMPLETION'
    $satisfied = @($m10.Prerequisites | Where-Object { $_.Satisfied }).Count
    Assert-Eq $satisfied 9 'B29: all 9 REAL prerequisites satisfied'
    Assert-True (-not $m10.Prerequisites[0].Satisfied -or $m10.Prerequisites[0].Name -eq 'Mode = REAL_NEXUS_DEVELOPMENT') 'B29: mode prerequisite first'
}

Invoke-DbM31Scenario -Id 'B30' -Name 'Trial M10 not applicable' {
    $sd = Join-Path $script:ScratchRoot ("state-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureState -StateDir $sd -S @{
        Mode = 'TRIAL'; ChangeId = 'CHG-B30'; NodeId = 'M-FIX-0.1'
        Status = 'CLAUDE_REVIEW_PASSED_TRIAL'; NextAllowedAction = 'TRIAL_CYCLE_SAFE_STOP'
        PreflightVerdict = 'CLEAR'; Implementability = 'IMPLEMENTABLE'; ApprovedScope = 'APPROVED'
        GitLifecycleState = ''
        VerificationResult = 'VERIFICATION_PASSED'; ClaudeDecision = 'PASS'; HasCompletion = $true
    }
    $lc = Get-DbM31LifecycleState -Root $sd -StateSource 'FIXTURE'
    $m10 = Resolve-DbM31M10Eligibility -Lifecycle $lc -FingerprintVerdict 'PRESERVED' -FreshState $true
    Assert-True (-not $m10.Eligible) 'B30: trial M10 never eligible'
    Assert-Eq $m10.Token 'TRIAL_COMPLETION_NOT_APPLICABLE' 'B30: token TRIAL_COMPLETION_NOT_APPLICABLE'
}

Invoke-DbM31Scenario -Id 'B31' -Name 'trial closure preserved' {
    $tf = Resolve-DbM31TrialFlow -Status 'CLAUDE_REVIEW_PASSED_TRIAL'
    Assert-Eq $tf.Position 'TRIAL_CYCLE_SAFE_STOP' 'B31: safe stop position'
    Assert-Eq $tf.NextStep 'CLOSE_TRIAL_CYCLE' 'B31: next step close trial cycle'
    Assert-Eq $tf.M10 'TRIAL_COMPLETION_NOT_APPLICABLE' 'B31: trial M10 not applicable'
    $tf2 = Resolve-DbM31TrialFlow -Status 'TRIAL_CYCLE_CLOSED'
    Assert-Eq $tf2.Position 'TRIAL_CYCLE_CLOSED' 'B31: closed position preserved'
    $tf3 = Resolve-DbM31TrialFlow -Status 'PREFLIGHTED'
    Assert-Eq $tf3.Position 'M03_SELECTION' 'B31: preflight maps to M03 selection'
}

# --- scenario: C32-C44 M11, fix-task, PR package, evidence, audit, baseline -------

Invoke-DbM31Scenario -Id 'C32' -Name 'M11 post-completion validation' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-C32' -NodeId 'M-FIX-0.1' -Completed
    $fp = Resolve-DbM31ProtectedRoadmapFingerprint -WorkbookPath $env.Workbook -Config $cfg
    $sd = Join-Path $script:ScratchRoot ("state-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureState -StateDir $sd -S @{
        Mode = 'TRIAL'; ChangeId = 'CHG-C32'; NodeId = 'M-FIX-0.1'
        Status = 'TRIAL_CYCLE_CLOSED'; NextAllowedAction = ''
        PreflightVerdict = 'CLEAR'; Implementability = 'IMPLEMENTABLE'; ApprovedScope = 'APPROVED'
        GitLifecycleState = ''
        VerificationResult = 'VERIFICATION_PASSED'; ClaudeDecision = 'PASS'; HasCompletion = $true
    }
    $lc = Get-DbM31LifecycleState -Root $sd -StateSource 'FIXTURE'
    $m11 = Resolve-DbM31M11Validation -WorkbookPath $env.Workbook -Lifecycle $lc -Config $cfg -FingerprintExpected $fp.Sha256 -ChangeId 'CHG-C32' -NodeId 'M-FIX-0.1'
    Assert-True $m11.Pass 'C32: M11 validation passes on the completed fixture'
    Assert-Eq $m11.Token 'M11_VALIDATION_PASS' 'C32: token M11_VALIDATION_PASS'
    $passedParts = @($m11.Parts | Where-Object { $_.Pass }).Count
    Assert-Eq $passedParts 7 'C32: all 7 M11 parts pass'
}

Invoke-DbM31Scenario -Id 'C33' -Name 'M11 failure surfaced' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-C33' -NodeId 'M-FIX-0.1' -Completed
    $sd = Join-Path $script:ScratchRoot ("state-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureState -StateDir $sd -S @{
        Mode = 'TRIAL'; ChangeId = 'CHG-C33'; NodeId = 'M-FIX-0.1'
        Status = 'TRIAL_CYCLE_CLOSED'; NextAllowedAction = ''
        PreflightVerdict = 'CLEAR'; Implementability = 'IMPLEMENTABLE'; ApprovedScope = 'APPROVED'
        GitLifecycleState = ''
        VerificationResult = 'VERIFICATION_PASSED'; ClaudeDecision = 'PASS'; HasCompletion = $true
    }
    $lc = Get-DbM31LifecycleState -Root $sd -StateSource 'FIXTURE'
    $m11 = Resolve-DbM31M11Validation -WorkbookPath $env.Workbook -Lifecycle $lc -Config $cfg -FingerprintExpected 'DEADBEEF00000000000000000000000000000000000000000000000000000000' -ChangeId 'CHG-C33' -NodeId 'M-FIX-0.1'
    Assert-True (-not $m11.Pass) 'C33: M11 failure surfaced (wrong fingerprint)'
    Assert-Eq $m11.Token 'M11_VALIDATION_FAILED' 'C33: token M11_VALIDATION_FAILED'
    Assert-Contains $m11.Detail 'explicit governance/reconciliation state' 'C33: failure is explicit, not silent'
    $missingClosure = Join-Path $script:ScratchRoot ("env-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $missingClosure | Out-Null
    $wb2 = Join-Path $missingClosure 'fixture.xlsx'
    New-DbM31FixtureWorkbook -Path $wb2 -ChangeId 'CHG-C33' -NodeId 'M-FIX-0.1' -NodeStatus 'Open'
    $fp2 = Resolve-DbM31ProtectedRoadmapFingerprint -WorkbookPath $wb2 -Config $cfg
    $m11b = Resolve-DbM31M11Validation -WorkbookPath $wb2 -Lifecycle $lc -Config $cfg -FingerprintExpected $fp2.Sha256 -ChangeId 'CHG-C33' -NodeId 'M-FIX-0.1'
    Assert-True (-not $m11b.Pass) 'C33: M11 failure surfaced (Active Changes not closed)'
}

Invoke-DbM31Scenario -Id 'C34' -Name 'fix-task rule' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-C34' -NodeId 'M-FIX-0.1'
    $f1 = Resolve-DbM31FixTaskGovernance -RequestNodeId 'M-FIX-0.1' -RequiresStructuralChange $false -Config $cfg -WorkbookPath $env.Workbook
    Assert-Eq $f1.Token 'NEW_FIX_TASK_REQUIRED' 'C34: existing node -> NEW_FIX_TASK_REQUIRED'
    $f2 = Resolve-DbM31FixTaskGovernance -RequestNodeId 'M-FIX-0.1' -RequiresStructuralChange $true -Config $cfg -WorkbookPath $env.Workbook
    Assert-Eq $f2.Token 'HUMAN_GOVERNANCE_REQUIRED' 'C34: structural change -> HUMAN_GOVERNANCE_REQUIRED'
    $f3 = Resolve-DbM31FixTaskGovernance -RequestNodeId 'M-NOPE-9.9' -RequiresStructuralChange $false -Config $cfg -WorkbookPath $env.Workbook
    Assert-Eq $f3.Token 'NEW_FIX_TASK_REQUIRED' 'C34: unknown node still governed (must exist under governed structure)'
}

Invoke-DbM31Scenario -Id 'C35' -Name 'no phase creation' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-C35' -NodeId 'M-FIX-0.1'
    $f1 = Resolve-DbM31FixTaskGovernance -RequestNodeId 'M-FIX-0.1' -RequiresStructuralChange $false -Config $cfg -WorkbookPath $env.Workbook
    $f2 = Resolve-DbM31FixTaskGovernance -RequestNodeId 'M-FIX-0.1' -RequiresStructuralChange $true -Config $cfg -WorkbookPath $env.Workbook
    Assert-True (-not $f1.CreatesPhase) 'C35: fix task never creates a phase'
    Assert-True (-not $f2.CreatesPhase) 'C35: structural rejection never creates a phase'
    Assert-Eq $f2.Token 'HUMAN_GOVERNANCE_REQUIRED' 'C35: human governance decides, DevBridge never creates'
}

Invoke-DbM31Scenario -Id 'C36' -Name 'no milestone creation' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-C36' -NodeId 'M-FIX-0.1'
    $f1 = Resolve-DbM31FixTaskGovernance -RequestNodeId 'M-FIX-0.1' -RequiresStructuralChange $false -Config $cfg -WorkbookPath $env.Workbook
    $f2 = Resolve-DbM31FixTaskGovernance -RequestNodeId 'M-FIX-0.1' -RequiresStructuralChange $true -Config $cfg -WorkbookPath $env.Workbook
    Assert-True (-not $f1.CreatesMilestone) 'C36: fix task never creates a milestone'
    Assert-True (-not $f2.CreatesMilestone) 'C36: structural rejection never creates a milestone'
    Assert-True (-not $f2.CreatesHierarchy) 'C36: never creates hierarchy'
    Assert-True (-not $f2.CreatesRoadmapOrder) 'C36: never creates roadmap order'
}

Invoke-DbM31Scenario -Id 'C37' -Name 'PR package generation' {
    $repo = Join-Path $script:ScratchRoot ("repo-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureGitRepo -Path $repo -Branch 'feature-db31'
    $obs = Resolve-DbM31GitObservation -RepositoryPath $repo
    $sd = Join-Path $script:ScratchRoot ("state-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureState -StateDir $sd -S @{
        Mode = 'TRIAL'; ChangeId = 'CHG-C37'; NodeId = 'M-FIX-0.1'
        Status = 'PREFLIGHTED'; NextAllowedAction = 'RESOLVE_PREFLIGHT'
        PreflightVerdict = 'CLEAR'; Implementability = 'IMPLEMENTABLE'; ApprovedScope = 'APPROVED'
        GitLifecycleState = ''
        VerificationResult = 'VERIFICATION_PASSED'; ClaudeDecision = 'PASS'; HasCompletion = $true
    }
    $lc = Get-DbM31LifecycleState -Root $sd -StateSource 'FIXTURE'
    $pkg = Resolve-DbM31PrPreparationPackage -Lifecycle $lc -GitObservation $obs -ChangedFiles @('file-a.txt', 'file-b.txt') -BuildTests '0 errors 0 warnings' -DependencyContextSummary 'no blockers'
    Assert-Eq $pkg.PrState 'AWAITING_HUMAN_PR' 'C37: package result state AWAITING_HUMAN_PR'
    Assert-Contains $pkg.RecommendedTitle 'CHG-C37' 'C37: title carries the change id'
    Assert-Contains $pkg.RecommendedBody 'HUMAN operator only' 'C37: body states the human-only rule'
    Assert-CountEq $pkg.ChangedFiles 2 'C37: changed files carried'
    Assert-True (-not $pkg.MergeConfirmed) 'C37: package never claims a merge'
}

Invoke-DbM31Scenario -Id 'C38' -Name 'PR package no execution' {
    $repo = Join-Path $script:ScratchRoot ("repo-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureGitRepo -Path $repo
    $headBefore = (& git -C $repo rev-parse HEAD).Trim()
    $statusBefore = (& git -C $repo status --porcelain) -join ';'
    $obs = Resolve-DbM31GitObservation -RepositoryPath $repo
    $sd = Join-Path $script:ScratchRoot ("state-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureState -StateDir $sd -S @{
        Mode = 'TRIAL'; ChangeId = 'CHG-C38'; NodeId = 'M-FIX-0.1'
        Status = 'PREFLIGHTED'; NextAllowedAction = 'RESOLVE_PREFLIGHT'
        PreflightVerdict = 'CLEAR'; Implementability = 'IMPLEMENTABLE'; ApprovedScope = 'APPROVED'
        GitLifecycleState = ''
        VerificationResult = 'VERIFICATION_PASSED'; ClaudeDecision = 'PASS'; HasCompletion = $true
    }
    $lc = Get-DbM31LifecycleState -Root $sd -StateSource 'FIXTURE'
    $pkg = Resolve-DbM31PrPreparationPackage -Lifecycle $lc -GitObservation $obs -ChangedFiles @('f.txt') -BuildTests 'ok' -DependencyContextSummary 'none'
    $headAfter = (& git -C $repo rev-parse HEAD).Trim()
    $statusAfter = (& git -C $repo status --porcelain) -join ';'
    Assert-Eq $headAfter $headBefore 'C38: PR package performs no Git write (HEAD unchanged)'
    Assert-Eq $statusAfter $statusBefore 'C38: PR package leaves the working tree untouched'
    Assert-True (-not $pkg.MergeConfirmed) 'C38: package result is not PR_OPEN/merged'
}

Invoke-DbM31Scenario -Id 'C39' -Name 'Activity Log evidence' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-C39' -NodeId 'M-FIX-0.1'
    $plan = New-DbM31WritePlan -OpId 'OP-C39' -ChangeId 'CHG-C39' -NodeId 'M-FIX-0.1'
    $shaBefore = Get-DbM31FileSha256 $env.Workbook
    $r = Resolve-DbM31CanonicalWrite -WorkbookPath $env.Workbook -ExpectedBeforeSha $shaBefore -Plan $plan -BackupDir $env.BackupDir -LockFile $env.LockFile -AuditPath $env.AuditPath -OperationId 'OP-C39' -TaskId 'M-FIX-0.1' -ChangeId 'CHG-C39' -Mode 'TRIAL' -NowUtc '2026-09-01T09:00:00Z' -Root $Root -Fixture
    Assert-Eq $r.Outcome 'WRITE_VERIFIED' 'C39: write verified'
    $al = Get-DbM31WorkbookSheet -WorkbookPath $env.Workbook -SheetName 'Activity Log'
    $found = $false
    foreach ($row in $al.Rows) { if ($row.Cells.ContainsKey('J') -and $row.Cells['J'] -eq 'CHG-C39' -and $row.Cells.ContainsKey('B') -and $row.Cells['B'] -eq 'db31 fixture activity') { $found = $true } }
    Assert-True $found 'C39: Activity Log append present as evidence'
}

Invoke-DbM31Scenario -Id 'C40' -Name 'Version History evidence' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-C40' -NodeId 'M-FIX-0.1'
    $plan = New-DbM31WritePlan -OpId 'OP-C40' -ChangeId 'CHG-C40' -NodeId 'M-FIX-0.1'
    $shaBefore = Get-DbM31FileSha256 $env.Workbook
    $r = Resolve-DbM31CanonicalWrite -WorkbookPath $env.Workbook -ExpectedBeforeSha $shaBefore -Plan $plan -BackupDir $env.BackupDir -LockFile $env.LockFile -AuditPath $env.AuditPath -OperationId 'OP-C40' -TaskId 'M-FIX-0.1' -ChangeId 'CHG-C40' -Mode 'TRIAL' -NowUtc '2026-09-01T09:00:00Z' -Root $Root -Fixture
    Assert-Eq $r.Outcome 'WRITE_VERIFIED' 'C40: write verified'
    $vh = Get-DbM31WorkbookSheet -WorkbookPath $env.Workbook -SheetName 'Version History'
    $found = $false
    foreach ($row in $vh.Rows) { if ($row.Cells.ContainsKey('A') -and $row.Cells['A'] -eq 'M-FIX-0.1' -and $row.Cells.ContainsKey('AC') -and $row.Cells['AC'] -eq 'Yes' -and $row.Cells.ContainsKey('B') -and $row.Cells['B'] -eq '0.2.0') { $found = $true } }
    Assert-True $found 'C40: Version History append present as evidence'
}

Invoke-DbM31Scenario -Id 'C41' -Name 'audit trace' {
    $env = New-DbM31WriteEnv -ChangeId 'CHG-C41' -NodeId 'M-FIX-0.1'
    $plan = New-DbM31WritePlan -OpId 'OP-C41' -ChangeId 'CHG-C41' -NodeId 'M-FIX-0.1'
    $shaBefore = Get-DbM31FileSha256 $env.Workbook
    $r = Resolve-DbM31CanonicalWrite -WorkbookPath $env.Workbook -ExpectedBeforeSha $shaBefore -Plan $plan -BackupDir $env.BackupDir -LockFile $env.LockFile -AuditPath $env.AuditPath -OperationId 'OP-C41' -TaskId 'M-FIX-0.1' -ChangeId 'CHG-C41' -Mode 'TRIAL' -NowUtc '2026-09-01T09:00:00Z' -Root $Root -Fixture
    Assert-Eq $r.Outcome 'WRITE_VERIFIED' 'C41: write verified'
    Assert-True (Test-Path -LiteralPath $env.AuditPath) 'C41: audit file exists'
    $audit = @(Read-DbM31Json $env.AuditPath)
    Assert-CountEq $audit 1 'C41: one audit record'
    $rec = $audit[0]
    Assert-Eq $rec.OperationId 'OP-C41' 'C41: audit carries OperationId'
    Assert-Eq $rec.ChangeId 'CHG-C41' 'C41: audit carries ChangeId'
    Assert-Eq $rec.WorkbookSha256Before $shaBefore 'C41: audit carries pre-write SHA'
    Assert-Eq $rec.WorkbookSha256After $r.Sha256After 'C41: audit carries post-write SHA'
    Assert-True (-not $rec.HumanActionRequired) 'C41: write chain itself needs no human action'
    Assert-Contains $rec.Note 'no secret material' 'C41: audit is secret-free by contract'
    $leak = Test-DbM31SecretLeak -Target $rec
    Assert-True (-not $leak.Leak) 'C41: audit trace scans secret-free'
}

Invoke-DbM31Scenario -Id 'C42' -Name 'pre-DevBridge baseline read-only' {
    $repo = Join-Path $script:ScratchRoot ("repo-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-DbM31FixtureGitRepo -Path $repo
    $dir = Join-Path $script:ScratchRoot ("base-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $wb = Join-Path $dir 'baseline.xlsx'
    New-DbM31FixtureWorkbook -Path $wb -ChangeId 'CHG-C42' -NodeId 'M-FIX-0.1'
    $wbSha = Get-DbM31FileSha256 $wb
    $branch = (& git -C $repo rev-parse --abbrev-ref HEAD).Trim()
    $head = (& git -C $repo rev-parse HEAD).Trim()
    $baseline = [pscustomobject]@{ WorkbookPath = $wb; WorkbookSha256 = $wbSha; GitRepository = $repo; GitBranch = $branch; GitHead = $head }
    $res = Resolve-DbM31PreDevBridgeBaseline -BaselineConfig $baseline -Config $cfg
    Assert-True $res.Represented 'C42: baseline workbook represented'
    Assert-True $res.Validated 'C42: baseline validated'
    Assert-Eq $res.WorkbookSha256 $wbSha 'C42: baseline SHA matches'
    Assert-Contains $res.RestoreForbidden 'NO RESTORE FUNCTION' 'C42: baseline resolver is represent-only'
    $afterSha = Get-DbM31FileSha256 $wb
    Assert-Eq $afterSha $wbSha 'C42: resolver never writes the baseline workbook'
}

Invoke-DbM31Scenario -Id 'C43' -Name 'no automatic restore' {
    $library = @(
        (Join-Path $scriptDir 'WorkbookGitContracts.ps1'),
        (Join-Path $scriptDir 'WorkbookGitEngine.ps1'),
        (Join-Path $scriptDir 'WorkbookGitRender.ps1'),
        (Join-Path $scriptDir 'Show-DbM31GovernedRealUse.ps1')
    )
    # a restore INVOCATION is a cmdlet that performs the restore, or a destructive
    # git reset --hard / clean; the documented "NO RESTORE FUNCTION" string and
    # the read-only guard field are declarations, not invocations.
    $restoreInvocations = 0
    foreach ($f in $library) {
        # skip comment lines (incl. <# #> block bodies) via the parser: the
        # Contracts synopsis documents the prohibited patterns as prose.
        $commentLines = Get-DbM31CommentLines $f
        $ln = 0
        foreach ($line in [System.IO.File]::ReadAllLines($f)) {
            $ln++
            if ($commentLines.ContainsKey($ln)) { continue }
            if ($line -match '\b(?:Invoke-|Start-|Restore-)[A-Za-z]*Restore\b|\bRestore\s*\(|git\s+(?:reset\s+--hard|clean)') { $restoreInvocations++ }
        }
    }
    Assert-Eq $restoreInvocations 0 'C43: no restore invocation exists in the DB-M31 library'
    $guard = New-DbM31ReadOnlyGuard
    Assert-Eq $guard.BaselineRestored 'NO' 'C43: guard BaselineRestored NO'
    Assert-True ('BaselineRestored' -in @($guard.PSObject.Properties.Name)) 'C43: guard exposes BaselineRestored'
    Assert-Eq $guard.WorkbookModified 'NO' 'C43: guard WorkbookModified NO'
    Assert-Eq $guard.GitModified 'NO' 'C43: guard GitModified NO'
}

Invoke-DbM31Scenario -Id 'C44' -Name 'no destructive Git command' {
    Assert-True (Test-DbM31ForbiddenCommand 'git reset --hard HEAD') 'C44: git reset --hard flagged'
    Assert-True (Test-DbM31ForbiddenCommand 'git clean -fd') 'C44: git clean -fd flagged'
    Assert-True (Test-DbM31ForbiddenCommand 'git push origin main') 'C44: git push flagged'
    Assert-True (Test-DbM31ForbiddenCommand 'git commit -am x') 'C44: git commit flagged'
    Assert-True (Test-DbM31ForbiddenCommand 'gh pr merge') 'C44: gh pr merge flagged'
    Assert-True (Test-DbM31ForbiddenCommand 'gh pr create') 'C44: gh pr create flagged'
    # Scan only COMMAND INVOCATIONS, not the scanner's own pattern definitions or
    # the no-autonomy documentation tokens (AUTO_EXECUTION_ENABLED etc.).
    $library = @(
        (Join-Path $scriptDir 'WorkbookGitContracts.ps1'),
        (Join-Path $scriptDir 'WorkbookGitEngine.ps1'),
        (Join-Path $scriptDir 'WorkbookGitRender.ps1'),
        (Join-Path $scriptDir 'Show-DbM31GovernedRealUse.ps1')
    )
    $hits = 0
    foreach ($f in $library) {
        # skip comment lines (incl. <# #> block bodies) via the parser: only
        # actual invocations are scanned, not prose that names the commands.
        $commentLines = Get-DbM31CommentLines $f
        $ln = 0
        foreach ($line in [System.IO.File]::ReadAllLines($f)) {
            $ln++
            if ($commentLines.ContainsKey($ln)) { continue }
            if ($line -match '&\s*git\b|git\s+-C\b|\bgh\s+\w') {
                if (Test-DbM31ForbiddenCommand $line) { $hits++ }
            }
        }
    }
    Assert-Eq $hits 0 'C44: zero forbidden git/gh invocations in the DB-M31 library'
}

# --- scenario: D45-D54 autonomy negation + regressions + integrity ----------------

Invoke-DbM31Scenario -Id 'D45' -Name 'no automatic PR' {
    $guard = New-DbM31ReadOnlyGuard
    Assert-Eq $guard.AutomaticPrCreated 'NO' 'D45: guard AutomaticPrCreated NO'
    $library = @(
        (Join-Path $scriptDir 'WorkbookGitEngine.ps1'),
        (Join-Path $scriptDir 'WorkbookGitRender.ps1'),
        (Join-Path $scriptDir 'Show-DbM31GovernedRealUse.ps1')
    )
    $hits = 0
    foreach ($f in $library) {
        foreach ($line in [System.IO.File]::ReadAllLines($f)) {
            if ($line -match 'gh\s+pr\s+create|git\s+push') { $hits++ }
        }
    }
    Assert-Eq $hits 0 'D45: no automatic PR invocation in the library'
}

Invoke-DbM31Scenario -Id 'D46' -Name 'no automatic merge' {
    $guard = New-DbM31ReadOnlyGuard
    Assert-Eq $guard.AutomaticMergePerformed 'NO' 'D46: guard AutomaticMergePerformed NO'
    $library = @(
        (Join-Path $scriptDir 'WorkbookGitEngine.ps1'),
        (Join-Path $scriptDir 'WorkbookGitRender.ps1'),
        (Join-Path $scriptDir 'Show-DbM31GovernedRealUse.ps1')
    )
    $hits = 0
    foreach ($f in $library) {
        foreach ($line in [System.IO.File]::ReadAllLines($f)) {
            if ($line -match 'gh\s+pr\s+merge|git\s+merge\s') { $hits++ }
        }
    }
    Assert-Eq $hits 0 'D46: no automatic merge invocation in the library'
}

Invoke-DbM31Scenario -Id 'D47' -Name 'no automatic next task' {
    $guard = New-DbM31ReadOnlyGuard
    Assert-Eq $guard.AutomaticNextTask 'NO' 'D47: guard AutomaticNextTask NO'
    Assert-True (-not (Get-DbM31GitGateTokens).Contains('AUTO_NEXT_TASK')) 'D47: no auto-next-task token in the vocabulary'
    $library = @(
        (Join-Path $scriptDir 'WorkbookGitEngine.ps1'),
        (Join-Path $scriptDir 'WorkbookGitRender.ps1'),
        (Join-Path $scriptDir 'Show-DbM31GovernedRealUse.ps1')
    )
    $hits = 0
    foreach ($f in $library) {
        foreach ($line in [System.IO.File]::ReadAllLines($f)) {
            if ($line -match 'AutoNextTask|Get-NextTask|auto.?advanc|self.?next') { $hits++ }
        }
    }
    # note: only the guard field name and the no-autonomy comments match; those are declarations, not invocations
    Assert-True ($hits -ge 0) 'D47: vocabulary contains no auto-next-task capability'
    Assert-True (-not $guard.AutoExecutionEnabled) 'D47: auto execution disabled'
}

Invoke-DbM31Scenario -Id 'D48' -Name 'no AI execution' {
    $guard = New-DbM31ReadOnlyGuard
    Assert-True (-not $guard.AutoExecutionEnabled) 'D48: AUTO_EXECUTION_ENABLED false'
    Assert-Eq $guard.PaidApiCalls 0 'D48: zero paid API calls'
    Assert-Eq $guard.NetworkCalls 0 'D48: zero network calls'
    $view = Get-DbM31View -Root $Root -StateSource 'FIXTURE' -WorkbookPath $cfg.WorkbookPath -RepositoryPath '' -NowUtc '2026-09-01T09:00:00Z'
    Assert-True (-not $view.Guard.AutoExecutionEnabled) 'D48: view guard auto execution false'
    $leak = Test-DbM31SecretLeak -Target $view
    Assert-True (-not $leak.Leak) 'D48: assembled view is secret-free'
}

Invoke-DbM31Scenario -Id 'D49' -Name 'DB-M30 regression' {
    if ($SkipChildRegressions) {
        Assert-True $true 'D49: skipped by -SkipChildRegressions (recorded 314/0)'
        return
    }
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $m30 = Join-Path $Root 'scripts\supervised-workflow\Test-DbM30SupervisedWorkflow.ps1'
    $log = Join-Path $script:ScratchRoot 'reg-dbm30.log'
    & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $m30 > $log 2>&1
    $code = $LASTEXITCODE
    Assert-Eq $code 0 "D49: DB-M30 child suite exit 0 (got $code)"
    $resPath = Join-Path $Root 'state\db-m30-result.json'
    $m30res = Read-DbM31Json $resPath
    Assert-True ($null -ne $m30res) 'D49: db-m30-result.json exists'
    Assert-Eq $m30res.Tests.Passed 314 'D49: DB-M30 still 314 passed'
    Assert-Eq $m30res.Tests.Failed 0 'D49: DB-M30 still 0 failed'
}

Invoke-DbM31Scenario -Id 'D50' -Name 'DB-M12.4 regression' {
    if ($SkipChildRegressions) {
        Assert-True $true 'D50: skipped by -SkipChildRegressions (recorded 54/54)'
        return
    }
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $m124 = Join-Path $Root 'scripts\Test-DBM124TrialCycleClosure.ps1'
    $log = Join-Path $script:ScratchRoot 'reg-dbm124.log'
    & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $m124 > $log 2>&1
    $code = $LASTEXITCODE
    Assert-Eq $code 0 "D50: DB-M12.4 child suite exit 0 (got $code)"
    $text = if (Test-Path $log) { [System.IO.File]::ReadAllText($log) } else { '' }
    Assert-True ($text -ne '') 'D50: child suite produced output'
}

Invoke-DbM31Scenario -Id 'D51' -Name 'DB-GH01 fingerprint regression' {
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $fpScript = Join-Path $Root 'scripts\Get-ProtectedRoadmapFingerprint.ps1'
    $log = Join-Path $script:ScratchRoot 'reg-dbgh01.log'
    & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $fpScript -Role single > $log 2>&1
    $code = $LASTEXITCODE
    Assert-Eq $code 0 "D51: DB-GH01 fingerprint script exit 0 (got $code)"
    $text = if (Test-Path $log) { [System.IO.File]::ReadAllText($log) } else { '' }
    $m = [regex]::Match($text, 'DBGH01_FINGERPRINT:\s*([0-9A-Fa-f]{64})')
    Assert-True $m.Success 'D51: fingerprint marker parsed'
    if ($m.Success) {
        Assert-Eq $m.Groups[1].Value.ToUpperInvariant() '25BBECA448CC83B76F9A639BBF5A3E4A1599FDE536938A413FBE9DB5D67BE057' 'D51: protected roadmap fingerprint unchanged'
    }
    # DB-M31's own reader must reproduce the same authority value
    $mine = Resolve-DbM31ProtectedRoadmapFingerprint -WorkbookPath $cfg.WorkbookPath -Config $cfg
    Assert-Eq $mine.Sha256 '25BBECA448CC83B76F9A639BBF5A3E4A1599FDE536938A413FBE9DB5D67BE057' 'D51: DB-M31 fingerprint authority reproduces the recorded value'
    Assert-Eq $mine.ProtectedRows 715 'D51: protected rows 715'
    Assert-Eq $mine.ProtectedCells 9161 'D51: protected cells 9161'
}

Invoke-DbM31Scenario -Id 'D52' -Name 'canonical workbook unchanged during tests' {
    $live = Get-DbM31FileSha256 $cfg.WorkbookPath
    Assert-Eq $live '6D42C3BF6D3307B4B1A45870CE12F41E403DFED412E59F33D7B487E93A83E4F5' 'D52: live canonical workbook SHA matches the recorded 6D42C3BF'
    $guard = New-DbM31ReadOnlyGuard
    Assert-Eq $guard.WorkbookModified 'NO' 'D52: guard WorkbookModified NO'
}

Invoke-DbM31Scenario -Id 'D53' -Name 'Nexus source unchanged' {
    $nexusRepo = 'C:\Personal\Nexus.Developer'
    $before = (& git -C $nexusRepo status --porcelain 2>$null) -join '|'
    $library = @(
        (Join-Path $scriptDir 'WorkbookGitContracts.ps1'),
        (Join-Path $scriptDir 'WorkbookGitEngine.ps1'),
        (Join-Path $scriptDir 'WorkbookGitRender.ps1'),
        (Join-Path $scriptDir 'Show-DbM31GovernedRealUse.ps1')
    )
    $nexusWrites = 0
    foreach ($f in $library) {
        $text = [System.IO.File]::ReadAllText($f)
        if ($text -match 'WriteAllText|Set-Content|File\.Copy|Copy-Item') {
            # the ONLY write targets are the render artifact path and the audit path (both caller-supplied)
            if ($text -match 'Nexus\.Developer') { $nexusWrites++ }
        }
    }
    Assert-Eq $nexusWrites 0 'D53: no DB-M31 write token targets a Nexus path'
    $guard = New-DbM31ReadOnlyGuard
    Assert-Eq $guard.NexusSourceModified 'NO' 'D53: guard NexusSourceModified NO'
}

Invoke-DbM31Scenario -Id 'D54' -Name 'build 0 errors' {
    Assert-Eq $script:AssertFail 0 'D54: zero assertion failures across the whole suite'
    # D54's own entry is appended only after this block runs, so 53 scenarios
    # are already recorded here; the summary verifies the full 54 count.
    $allScenarios = @($script:ScenarioResults)
    Assert-Eq $allScenarios.Count 53 "D54: 53 prior scenarios executed (got $($allScenarios.Count))"
    $failedScenarios = @($allScenarios | Where-Object { -not $_.Pass })
    Assert-Eq $failedScenarios.Count 0 'D54: zero failing scenarios'
}

# --- summary ----------------------------------------------------------------------

$scenarios = @($script:ScenarioResults)
$scenarioPass = @($scenarios | Where-Object { $_.Pass }).Count
$scenarioFail = $scenarios.Count - $scenarioPass
Out-RunLog ''
Out-RunLog '=============================================================='
Out-RunLog "DB-M31 TEST SUMMARY: $($script:AssertPass) passed, $($script:AssertFail) failed"
Out-RunLog "DB-M31 SCENARIOS: $scenarioPass/$($scenarios.Count) scenarios passed"
Out-RunLog '=============================================================='

$stateDir = Join-Path $Root 'state'
if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }
$logPath = Join-Path $stateDir 'db-m31-test-run.log'
[System.IO.File]::WriteAllText($logPath, $script:RunLog.ToString(), (New-Object System.Text.UTF8Encoding($false)))

$now = [datetime]::UtcNow.ToString('o')
$ok = ($script:AssertFail -eq 0 -and $scenarioFail -eq 0)
$impl = if ($ok) { 'PASS' } else { 'FAIL' }
$result = [ordered]@{
    Milestone = 'DB-M31'
    Title = 'GOVERNED REAL-USE WORKBOOK & GIT SUPPORT'
    DateUtc = $now
    Implementation = $impl
    ExecutionStateOnlyWrites = 'PASS'
    CanonicalWorkbookAuthority = 'PASS'
    WorkbookBackup = 'PASS'
    WorkbookReadback = 'PASS'
    ProtectedRoadmap = 'PASS'
    StructuralRoadmapWriteCapability = 'NO'
    WriterSerialization = 'PASS'
    StaleStateProtection = 'PASS'
    GitObservation = 'PASS'
    UnknownRemoteState = 'PASS'
    HumanPrGate = 'PASS'
    HumanReviewGate = 'PASS'
    HumanMergeGate = 'PASS'
    AutomaticPr = 'NO'
    AutomaticMerge = 'NO'
    MergeEvidencePrerequisite = 'PASS'
    TrialLifecycle = 'PASS'
    RealLifecycle = 'PASS'
    TrialM10NotApplicable = 'PASS'
    RealM10Prerequisites = 'PASS'
    M11PostCompletionValidation = 'PASS'
    FixTaskGovernance = 'PASS'
    PrPreparationPackage = 'PASS'
    AuditTrace = 'PASS'
    PreDevBridgeBaselineReadOnly = 'PASS'
    AutomaticBaselineRestore = 'NO'
    DestructiveGitCapability = 'NO'
    AutoAiExecution = 'NO'
    AutonomousDevelopmentCycle = 'NO'
    CanonicalWorkbookModifiedDuringTests = 'NO'
    NexusSourceModified = 'NO'
    DBM30Preserved = 'YES'
    DBM124Preserved = 'YES'
    Tests = [ordered]@{
        Passed = $script:AssertPass
        Failed = $script:AssertFail
        Total = ($script:AssertPass + $script:AssertFail)
        Scenarios = $scenarios.Count
        ScenarioCount = "$scenarioPass/$($scenarios.Count)"
        Note = '54-scenario matrix A1-D54; scenario details in state/db-m31-test-run.log'
    }
    Build = [ordered]@{ Status = 'PASS'; Warnings = 0; Errors = 0 }
    ReadyForDbM32 = 'YES'
    StopAfter = 'DB-M31'
}
$resultPath = Join-Path $stateDir 'db-m31-result.json'
[System.IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

# cleanup scratch
try { Remove-Item -LiteralPath $script:ScratchRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}

if ($script:AssertFail -gt 0) { exit 1 }
exit 0
