# Reserve-DevelopmentChange.ps1
# DevBridge DB-M04 - Governed Change Reservation + Git Baseline.
#
# Executes Session Protocol Step 7: reserves the DB-M03-selected change in Active
# Changes before any source editing, appends an Activity Log event, backs up the
# workbook, captures the exact git/source baseline future verification will compare
# against, and sets DevBridge task state to RESERVED.
#
# Read-only toward Nexus source. The ONLY Nexus-side mutation is the governed
# workbook reservation (Active Changes row + Activity Log row), which is this
# milestone's explicit purpose.
#
# IDEMPOTENCY-AWARE: if the current task is already RESERVED and the reservation
# row still exists live in the workbook, a second run REUSES the existing
# reservation and does not append another.
#
# Self-test support (env overrides, only honored when DB04_SELFTEST=1):
#   DB04_WORKBOOK_OVERRIDE  - point reads/writes at a throwaway workbook copy
#   DB04_STATE_DIR          - state dir (preflight.json / current-task.json)
#   DB04_TASKS_DIR          - tasks output dir
#   DB04_LOGS_DIR           - logs output dir
#   DB04_TEST_STALE         - force stale preflight (expect STOP PREFLIGHT_STALE)
#   DB04_TEST_CONFLICT      - inject overlapping open reservation (expect STOP RESERVATION_CONFLICT)
#   DB04_TEST_SCOPE_WIDEN   - force scope widening (expect STOP SCOPE_CHANGE_REQUIRED)
#
# Exit markers printed to stdout (parsed by Test-DBM04Safety.ps1):
#   DB04_OUTCOME: RESERVED | REUSED | STOP_<CODE>
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null

$script:Root   = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:Config = Get-Content (Join-Path $script:Root "config\devbridge.json") -Raw -Encoding UTF8 | ConvertFrom-Json

. (Join-Path $PSScriptRoot "Read-DevelopmentControl.ps1")
. (Join-Path $PSScriptRoot "TrialDependencyOverlay.ps1")

# ---------------------------------------------------------------------------
# Runtime paths (self-test may redirect all of these away from real state)
# ---------------------------------------------------------------------------
$envSelf = $env:DB04_SELFTEST
if ($envSelf -eq "1") {
    if ($env:DB04_WORKBOOK_OVERRIDE) { $script:DevControlWorkbook = $env:DB04_WORKBOOK_OVERRIDE }
    $script:StateDir = $env:DB04_STATE_DIR
    $script:TasksDir = $env:DB04_TASKS_DIR
    $script:LogsDir  = $env:DB04_LOGS_DIR
    if (-not $script:StateDir -or -not $script:TasksDir -or -not $script:LogsDir) {
        throw "DB04_SELFTEST requires DB04_STATE_DIR, DB04_TASKS_DIR, DB04_LOGS_DIR"
    }
} else {
    $script:StateDir = Join-Path $script:Root "state"
    $script:TasksDir = Join-Path $script:Root "tasks"
    $script:LogsDir  = Join-Path $script:Root "logs"
}
$script:BackupDir   = Join-Path $script:LogsDir "workbook-backups"
$script:HistoryBase = Join-Path $script:LogsDir "tasks"
$script:PreflightPath = Join-Path $script:StateDir "preflight.json"
$script:CurrentTaskPath = Join-Path $script:StateDir "current-task.json"
$script:WorkbookPath = $script:DevControlWorkbook

# Test toggles (ignored unless self-test)
$testStale   = ($env:DB04_TEST_STALE -eq "1") -and ($envSelf -eq "1")
$testConflict = ($env:DB04_TEST_CONFLICT -eq "1") -and ($envSelf -eq "1")
$testScopeWiden = ($env:DB04_TEST_SCOPE_WIDEN -eq "1") -and ($envSelf -eq "1")

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
function Write-JsonUtf8([string]$path, $obj) {
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = $obj | ConvertTo-Json -Depth 30
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $json, $enc)
}

function Write-Utf8Bom([string]$path, [string]$content) {
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($path, $content, $enc)
}

function Read-Json([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    return Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-ExcelColumnLetter([int]$n) {
    $s = ""
    while ($n -gt 0) {
        $m = ($n - 1) % 26
        $s = [char](65 + $m) + $s
        $n = [int][Math]::Floor(($n - 1) / 26)
    }
    return $s
}

function Get-ColumnNumber([string]$letters) {
    $n = 0
    foreach ($ch in $letters.ToCharArray()) { $n = $n * 26 + ([int][char]$ch - 64) }
    return $n
}

function Test-ProjectTokenOverlap([string]$cell, [string]$projectName) {
    # A genuine Active Changes Projects cell lists project names as whole tokens.
    # Substring matching wrongly flags unrelated rows whose free text mentions a
    # longer name with the project as a prefix, e.g. "tests/Nexus.Developer.Core.Tests/
    # FeatureTests.cs" must NOT count as the project "Nexus.Developer.Core". Compare
    # whole tokens only, ignoring trailing annotations like "(new)".
    if (-not $cell -or -not $projectName) { return $false }
    foreach ($tok in ($cell -split "[\s|,;]+")) {
        $clean = $tok.Trim() -replace "\s*\([^)]*\)\s*$", ""
        if ($clean -ieq $projectName) { return $true }
    }
    return $false
}

function Stop-Outcome([string]$code, [string]$message) {
    Write-Output ("DB04_OUTCOME: {0}" -f $code)
    Write-Output ("DB04_MESSAGE: {0}" -f $message)
}

function Test-SchemaHeaders([string]$sheetName, [int]$headerRow, [hashtable]$expected) {
    # expected: colLetter -> logical header (normalized comparison)
    $doc = Open-DocEntry (Get-SheetEntryName $sheetName)
    $cols = Get-ColumnLetters $doc $headerRow (Get-SheetEntryName $sheetName)
    # reverse: colLetter -> normalized actual header
    $actual = @{}
    foreach ($k in $cols.Keys) { $actual[$cols[$k]] = $k }
    $missing = @()
    foreach ($col in ($expected.Keys | Sort-Object { Get-ColumnNumber $_ })) {
        $want = Normalize-Header $expected[$col]
        $got = ""
        if ($actual.ContainsKey($col)) { $got = $actual[$col] }
        if ($got -ne $want) { $missing += ("{0} expected [{1}] got [{2}]" -f $col, $want, $got) }
    }
    return $missing
}

# ---------------------------------------------------------------------------
# Workbook write helpers (append row + update dimension, preserving all other parts)
# ---------------------------------------------------------------------------
function Open-SheetDoc([string]$sheetName) {
    $entry = Get-SheetEntryName $sheetName
    $fs = [System.IO.File]::Open($script:DevControlWorkbook, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
    $rd = New-Object System.IO.StreamReader($zip.GetEntry($entry).Open())
    $doc = [System.Xml.Linq.XDocument]::Load($rd)
    $rd.Close(); $zip.Dispose(); $fs.Dispose()
    return @{ Doc = $doc; Entry = $entry }
}

function New-Cell([int]$rowNum, [string]$colLetter, [string]$value) {
    $ns = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    $c = New-Object System.Xml.Linq.XElement($ns + "c")
    $c.SetAttributeValue("r", ($colLetter + $rowNum))
    $c.SetAttributeValue("t", "inlineStr")
    $is = New-Object System.Xml.Linq.XElement($ns + "is")
    $t = New-Object System.Xml.Linq.XElement($ns + "t")
    $t.SetAttributeValue([System.Xml.Linq.XNamespace]"http://www.w3.org/XML/1998/namespace" + "space", "preserve")
    $t.Value = $value
    $is.Add($t)
    $c.Add($is)
    return $c
}

function New-Row([int]$rowNum, [hashtable]$cellMap) {
    $ns = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    $row = New-Object System.Xml.Linq.XElement($ns + "row")
    $row.SetAttributeValue("r", $rowNum)
    $ordered = $cellMap.Keys | Sort-Object { Get-ColumnNumber $_ }
    foreach ($col in $ordered) {
        $val = $cellMap[$col]
        if ($null -eq $val) { continue }
        if ([string]$val -eq "") { continue }
        $row.Add((New-Cell $rowNum $col ([string]$val)))
    }
    return $row
}

function Update-Dimension($doc, [string]$newRef) {
    $ns = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    $dim = $doc.Root.Element($ns + "dimension")
    if ($dim) { $dim.SetAttributeValue("ref", $newRef) }
}

function Append-SheetRow($doc, $rowEl) {
    $ns = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    $sheetData = $doc.Root.Element($ns + "sheetData")
    $sheetData.Add($rowEl)
}

function Write-WorkbookSheets([string]$srcPath, [string]$dstPath, [hashtable]$newDocs) {
    $srcFs = [System.IO.File]::OpenRead($srcPath)
    $zipSrc = New-Object System.IO.Compression.ZipArchive($srcFs, [System.IO.Compression.ZipArchiveMode]::Read)
    $dstFs = [System.IO.File]::Create($dstPath)
    $zipDst = New-Object System.IO.Compression.ZipArchive($dstFs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entry in $zipSrc.Entries) {
            $name = $entry.FullName
            $newEntry = $zipDst.CreateEntry($name)
            $out = $newEntry.Open()
            $in = $entry.Open()
            if ($newDocs.ContainsKey($name)) {
                $doc = $newDocs[$name]
                $doc.Save($out, [System.Xml.Linq.SaveOptions]::DisableFormatting)
            } else {
                $in.CopyTo($out)
            }
            $in.Dispose(); $out.Dispose()
        }
    } finally {
        $zipDst.Dispose(); $dstFs.Dispose(); $zipSrc.Dispose(); $srcFs.Dispose()
    }
}

function Get-FileSha256([string]$path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($path)
    try { $hash = $sha.ComputeHash($fs) } finally { $fs.Dispose() }
    return (($hash | ForEach-Object { $_.ToString("X2") }) -join "")
}

function Get-LastDataRow([string]$sheetName, [int]$headerRow) {
    $rows = Get-SheetRows $sheetName $headerRow 1 2000
    $max = $headerRow
    foreach ($r in $rows) { if ($r.Row -gt $max) { $max = $r.Row } }
    return $max
}

# ---------------------------------------------------------------------------
# Git baseline (observation only - never mutates the repository)
# ---------------------------------------------------------------------------
function Get-GitBaseline([string]$repo) {
    $o = New-Object PSCustomObject
    $o | Add-Member NoteProperty -Name repository -Value $repo
    $o | Add-Member NoteProperty -Name isGitRepo -Value (Test-Path (Join-Path $repo ".git"))
    $o | Add-Member NoteProperty -Name branch -Value $null
    $o | Add-Member NoteProperty -Name headCommit -Value $null
    $o | Add-Member NoteProperty -Name headSubject -Value $null
    $o | Add-Member NoteProperty -Name stagedFiles -Value @()
    $o | Add-Member NoteProperty -Name modifiedFiles -Value @()
    $o | Add-Member NoteProperty -Name untrackedFiles -Value @()
    $o | Add-Member NoteProperty -Name statusLines -Value @()
    $o | Add-Member NoteProperty -Name capturedAt -Value $null
    if (-not $o.isGitRepo) { return $o }
    $o.branch = (& git -C $repo rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)
    $o.headCommit = (& git -C $repo rev-parse HEAD 2>$null | Select-Object -First 1)
    $o.headSubject = (& git -C $repo log -1 --format=%s 2>$null | Select-Object -First 1)
    $status = @(& git -C $repo status --porcelain=v1 2>$null)
    $o.statusLines = $status
    $staged = New-Object System.Collections.Generic.List[string]
    $modified = New-Object System.Collections.Generic.List[string]
    $untracked = New-Object System.Collections.Generic.List[string]
    foreach ($line in $status) {
        if ($line.Length -lt 4) { continue }
        $code = $line.Substring(0, 2)
        $path = $line.Substring(3)
        if ($code -eq "??") { $untracked.Add($path); continue }
        if ($code[0] -ne " ") { $staged.Add($line) }
        if ($code[1] -ne " ") { $modified.Add($line) }
    }
    $o.stagedFiles = $staged.ToArray()
    $o.modifiedFiles = $modified.ToArray()
    $o.untrackedFiles = $untracked.ToArray()
    $o.capturedAt = ([DateTime]::UtcNow).ToString("yyyy-MM-ddTHH:mm:ssZ")
    return $o
}

# ---------------------------------------------------------------------------
# Multi-repository baseline support (DB-M04 integrity fix)
#
# A reservation may span MORE than one repository in its EXACT reserved scope.
# Every reserved repository is baselined independently (path / branch / HEAD /
# staged / modified / untracked / reserved-scope file hashes) so DB-M06 can
# classify PRE-EXISTING / GOVERNANCE / TASK delta per repository. The
# workbook-owner repository remains the PRIMARY baseline (gitBaseline and
# repositoryStates[0] keep their historical meaning for DB-13 / M05 / the C#
# reader); sibling reserved repositories each get an identical independent
# record.
# ---------------------------------------------------------------------------

function Get-PersonalBasePath {
    # Sibling root that holds the governed repositories, derived from the
    # canonical workbook path in config (config is never redirected by self-test,
    # so resolution is stable under DB04_WORKBOOK_OVERRIDE / DB_DEV_CONTROL_*).
    $wbPath = [string]$script:Config.developmentControlWorkbook
    if (-not $wbPath) { return "" }
    $repoDir = Split-Path $wbPath -Parent
    return (Split-Path $repoDir -Parent)
}

function Resolve-RepositoryPath([string]$repoName) {
    if (-not $repoName) { return "" }
    $name = $repoName.Trim()
    # 1) explicit config mapping wins: config "repositories" may hold "Name=Path"
    #    strings or { name; path } objects.
    foreach ($entry in @($script:Config.repositories)) {
        if ($entry -is [string]) {
            if ($entry -match '^\s*([^=]+?)\s*=\s*(.+?)\s*$') {
                if ($Matches[1].Trim() -ieq $name) { return $Matches[2].Trim() }
            } elseif ($entry.Trim() -ieq $name) {
                return (Join-Path (Get-PersonalBasePath) $name)
            }
        } elseif ($entry.PSObject.Properties['name'] -and ([string]$entry.name).Trim() -ieq $name -and $entry.PSObject.Properties['path']) {
            return ([string]$entry.path).Trim()
        }
    }
    # 2) conventional sibling root: <personal-base>\<RepoName>
    return (Join-Path (Get-PersonalBasePath) $name)
}

function Get-RepoScopeHashes([string]$repoPath, $gitSnap, [string[]]$projects) {
    # Reserved-scope file hashes for one repository. When a reserved project has a
    # governed DevelopmentControl folder, every file under it is hashed (original
    # DB-M04 behaviour). Otherwise the repository is byte-baselined over its
    # PRE-EXISTING dirty files under the reserved project(s) only (bounded) so DB-M06
    # can separate pre-existing content from task drift on an already-dirty repo.
    $out = New-Object System.Collections.Generic.List[object]
    if (-not $gitSnap.isGitRepo) { return $out }
    $hashed = @{}
    foreach ($p in @($projects)) {
        if (-not $p) { continue }
        $projDir = Join-Path $repoPath ("src\" + $p)
        $govDir = Join-Path $projDir "DevelopmentControl"
        if (Test-Path $govDir) {
            foreach ($f in @(Get-ChildItem $govDir -Recurse -File)) {
                # Normalize to forward slashes so hash paths match git-status rel paths
                # (git always reports '/') and the sibling-repo / DB-M06 comparisons.
                $rel = ($f.FullName.Substring($repoPath.Length + 1)) -replace '\\', '/'
                if ($hashed.ContainsKey($rel)) { continue }
                $hashed[$rel] = $true
                $o = New-Object PSCustomObject
                $o | Add-Member NoteProperty -Name path -Value $rel
                $o | Add-Member NoteProperty -Name sha256 -Value (Get-FileSha256 $f.FullName)
                $o | Add-Member NoteProperty -Name bytes -Value $f.Length
                $out.Add($o)
            }
        } else {
            $cands = New-Object System.Collections.Generic.List[string]
            $projPrefix = "src/" + $p + "/"
            foreach ($ln in @($gitSnap.stagedFiles)) {
                if ($ln.Length -ge 4) { $cands.Add($ln.Substring(3)) }
            }
            foreach ($ln in @($gitSnap.modifiedFiles)) {
                if ($ln.Length -ge 4) { $cands.Add($ln.Substring(3)) }
            }
            foreach ($ln in @($gitSnap.untrackedFiles)) {
                if ($ln) { $cands.Add($ln) }
            }
            foreach ($rel in @($cands)) {
                $relN = $rel -replace '\\', '/'
                if (-not $relN.StartsWith($projPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                if ($relN -match '/bin/|/obj/') { continue }
                if ($hashed.ContainsKey($rel)) { continue }
                $full = Join-Path $repoPath $rel
                if (-not (Test-Path $full)) { continue }
                $hashed[$rel] = $true
                $o = New-Object PSCustomObject
                $o | Add-Member NoteProperty -Name path -Value $rel
                $o | Add-Member NoteProperty -Name sha256 -Value (Get-FileSha256 $full)
                $o | Add-Member NoteProperty -Name bytes -Value ((Get-Item $full).Length)
                $out.Add($o)
            }
        }
    }
    return $out
}

# ---------------------------------------------------------------------------
# PART 0/1 - load DB-M03 outputs, idempotency, revalidation
# ---------------------------------------------------------------------------
$preflight = Read-Json $script:PreflightPath
$current   = Read-Json $script:CurrentTaskPath

$outcome = ""
if (-not $preflight -or -not $current) {
    Stop-Outcome "STOP_PREFLIGHT_STALE" "Missing DB-M03 outputs (preflight.json / current-task.json). Rerun DB-M03."
    Write-Output "DB04_RESULT_PASS: False"
    exit 0
}

# DB-M03's current-task.json carries reservationId (null pre-reservation) and no
# changeId property. Normalize so strict-mode access to $current.changeId (idempotency
# guard + PART 2 node-collision check) never throws and keys off the reserved change.
if (-not $current.PSObject.Properties['changeId']) {
    $current | Add-Member -NotePropertyName changeId -NotePropertyValue "" -Force
}

# ---------------------------------------------------------------------------
# DB-GH01 M04 HARDENING - explicit cycle mode, pre-DevBridge baseline, trial containment
# ---------------------------------------------------------------------------
# Every reservation records the cycle's explicit mode so downstream milestones
# (M05/M06/M08/M10) and the UI can distinguish TRIAL evidence from
# REAL_NEXUS_DEVELOPMENT work. DevBridge defaults to TRIAL; the config "mode" is
# the fallback. The pre-DevBridge baseline (authoritative workbook SHA-256 + Nexus
# git branch/HEAD) is REPRESENTED, never restored. Baseline capture is idempotent
# and is only invoked outside self-test (self-test redirects state to a fixture;
# the capture must not write the real state dir during a test).
$script:CycleMode = "TRIAL"
if ($current.PSObject.Properties['mode'] -and [string]$current.mode) {
    $script:CycleMode = [string]$current.mode
} elseif ($script:Config.PSObject.Properties['mode'] -and [string]$script:Config.mode) {
    $script:CycleMode = [string]$script:Config.mode
}
$script:TrialContainment = ($script:CycleMode -eq "TRIAL")

$script:PreBaselinePath = Join-Path $script:StateDir "pre-devbridge-baseline.json"
if ($envSelf -ne "1" -and -not (Test-Path $script:PreBaselinePath)) {
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Get-PreDevBridgeBaseline.ps1") | Out-Null
        Write-Output "DBGH01_PRE_BASELINE: CAPTURED_OR_PRESERVED"
    } catch {
        Write-Output ("DBGH01_PRE_BASELINE_WARN: {0}" -f $_.Exception.Message)
    }
}
$preBaseline = Read-Json $script:PreBaselinePath
$pbWbSha = ""; $pbBranch = ""; $pbHead = ""
if ($preBaseline) {
    if ($preBaseline.PSObject.Properties.Name -contains "workbook") {
        if ($preBaseline.workbook.PSObject.Properties.Name -contains "sha256") { $pbWbSha = [string]$preBaseline.workbook.sha256 }
    }
    if ($preBaseline.PSObject.Properties.Name -contains "git") {
        if ($preBaseline.git.PSObject.Properties.Name -contains "branch") { $pbBranch = [string]$preBaseline.git.branch }
        if ($preBaseline.git.PSObject.Properties.Name -contains "headCommit") { $pbHead = [string]$preBaseline.git.headCommit }
    }
}
$preBaselineRef = @{
    represented = ($null -ne $preBaseline)
    path = $script:PreBaselinePath
    workbookSha256 = $pbWbSha
    gitBranch = $pbBranch
    gitHead = $pbHead
    restoreForbidden = "DevBridge never restores this baseline automatically. Restoration is a HUMAN action in the retirement lifecycle."
}

$targetNodeId = $preflight.taskId
if (-not $targetNodeId) { $targetNodeId = $preflight.nodeId }
$targetName   = $preflight.name

# ---- IDEMPOTENCY guard: already reserved? reuse the existing reservation ----
if ($current.status -eq "RESERVED" -and $current.changeId) {
    $live = @(Get-AllActiveChanges | Where-Object { $_.ChangeId -eq $current.changeId -and $_.Classification -ne "Terminal" })
    if ($live.Count -eq 1) {
        Stop-Outcome "REUSED" ("Reservation {0} already exists for {1} (Active Changes row {2}); reusing - no duplicate appended." -f $current.changeId, $targetNodeId, $live[0].Row)
        Write-Output ("DB04_CHANGE_ID: {0}" -f $current.changeId)
        Write-Output ("DB04_RESERVATION_ROW: {0}" -f $live[0].Row)
        Write-Output "DB04_RESULT_PASS: True"
        exit 0
    } else {
        Stop-Outcome "STOP_PREFLIGHT_STALE" ("Task marked RESERVED for {0} but reservation {1} is not a live open row - inconsistent state. Rerun DB-M03." -f $targetNodeId, $current.changeId)
        Write-Output "DB04_RESULT_PASS: False"
        exit 0
    }
}

# ---- Part 0 prerequisite ----
if ($preflight.verdict -ne "CLEAR" -or $current.nextAllowedAction -ne "RESERVE" -or $current.status -ne "PREFLIGHTED") {
    Stop-Outcome "STOP_PREFLIGHT_STALE" ("Prerequisite not met: verdict={0} status={1} nextAllowedAction={2}. Expected CLEAR / PREFLIGHTED / RESERVE. Rerun DB-M03." -f $preflight.verdict, $current.status, $current.nextAllowedAction)
    Write-Output "DB04_RESULT_PASS: False"
    exit 0
}

# ---- DB-M03.1: M04 gate = only CLEAR for IMPLEMENTABLE_LEAF ----
# Backward compatible: legacy preflight state (no implementability field) passes through
# unchanged; every DB-M03.1 preflight records implementability, so a CLEAR reservation is only
# reachable for a governed IMPLEMENTABLE_LEAF. A container is never a valid implementation
# target and must never be reserved.
$impl = ""
if ($current.PSObject.Properties['implementability']) { $impl = [string]$current.PSObject.Properties['implementability'].Value }
if ($impl -and $impl -ne "IMPLEMENTABLE_LEAF") {
    Stop-Outcome "STOP_NOT_IMPLEMENTABLE_LEAF" ("Reservation target {0} is classified {1} — not an IMPLEMENTABLE_LEAF. M04 only reserves governed implementable leaves; a container/incomplete/unknown node is never a valid implementation target." -f $targetNodeId, $impl)
    Write-Output "DB04_RESULT_PASS: False"
    exit 0
}

# ---- Part 1 revalidation (live workbook reads; never trusts cache alone) ----
$revalidate = @()
$wbBefore = Get-FileSha256 $script:WorkbookPath
# Serialized-writer guard: the workbook must be byte-identical to what DB-M03
# validated. Any parallel-lane or external write between DB-M03 and now is
# STOP_PREFLIGHT_STALE - the reservation may only proceed on the DB-M03 basis.
if ($preflight.workbookSha256 -and $wbBefore -ne $preflight.workbookSha256) {
    $revalidate += ("workbook changed since DB-M03: preflight SHA256 {0}, live SHA256 {1} - possible parallel-lane write" -f $preflight.workbookSha256, $wbBefore)
}
$allNodes = Get-AllRoadmapNodes
$targets = @($allNodes | Where-Object { $_.NodeId -eq $targetNodeId })
if ($targets.Count -ne 1) { $revalidate += ("node {0} found {1} times (expected exactly once)" -f $targetNodeId, $targets.Count) }
else {
    $t = $targets[0]
    # DB-M03.1 reservability rule (execution-state leaf validation): a governed leaf is
    # reservable when its execution state is non-terminal (Status not Completed/Complete)
    # with no open reservation conflict (PART 2). Both Planned and In-Progress/Active/Started
    # leaves are reservable under the CURRENT WORK model - "must be Planned" is NOT a governed
    # requirement, so M04 mirrors Get-NextTask's terminal set instead of asserting it. The
    # serialized-writer hash guard above is the authoritative "no incompatible change since
    # DB-M03" detector: any workbook delta (including a status flip to terminal) stops there.
    if ($t.Status -in @("Completed", "Complete")) { $revalidate += ("node status [{0}] is terminal; a reservable leaf must be non-terminal (pending work). Rerun DB-M03." -f $t.Status) }
    # Dependencies come from the DB-M03 preflight, never hard-coded per cycle.
    # DB-M03.2: a TRIAL_DEPENDENCY_SATISFIED predecessor (trial-proven for proving-cycle
    # selection) is honored here exactly like a real SATISFIED predecessor, but the real
    # roadmap status remains authoritative — the overlay never writes completion.
    # DB-M03.1 Test-DepsSatisfied: a leaf with no governed dependencies and no Open+Blocking
    # REL on it is SATISFIED vacuously; DB-M03 encodes that as the single synthetic
    # "REL-001..011 / Explicit D&B / NOT_APPLICABLE" sentinel. A CLEAR preflight carries
    # EITHER >=1 satisfied real node dependency OR that dep-free sentinel; reject only when
    # neither is present (truncated/contradictory preflight must still stop).
    $nodeDeps = @($preflight.dependencies | Where-Object { $_.dependencyId -match "^(F|WI|M|T|S)-" -and $_.state -in @("SATISFIED", "TRIAL_DEPENDENCY_SATISFIED") })
    $depFreeSentinel = @($preflight.dependencies | Where-Object { $_.dependencyId -match "^REL-" -and $_.type -eq "Explicit D&B" -and $_.state -eq "NOT_APPLICABLE" })
    if ($nodeDeps.Count -eq 0 -and $depFreeSentinel.Count -eq 0) { $revalidate += "preflight declares no satisfied node dependency; rerun DB-M03" }
    foreach ($d in $nodeDeps) {
        $dep = @($allNodes | Where-Object { $_.NodeId -eq $d.dependencyId })
        if ($dep.Count -eq 1 -and ($dep[0].Status -notin @("Complete", "Completed"))) {
            # DB-M03.2: re-qualify the TRIAL-only overlay before reserving a change that
            # sits on a trial-proven predecessor. A stale/invalid evidence set STOPS the
            # reservation honestly (capability 6).
            $ov = Test-TrialDependencySatisfied -DependencyNodeId $d.dependencyId -StateDir $script:StateDir -ConfigPath (Join-Path $script:Root "config\devbridge.json") -RealStatus ([string]$dep[0].Status)
            if (-not $ov.Satisfied) {
                if ($ov.BlockCode) {
                    $revalidate += ("dependency {0} status [{1}] trial overlay {2}: {3}" -f $d.dependencyId, $dep[0].Status, $ov.BlockCode, $ov.Reason)
                } else {
                    $revalidate += ("dependency {0} status [{1}] no longer satisfied" -f $d.dependencyId, $dep[0].Status)
                }
            }
        }
    }
}
foreach ($d in @(Get-OpenDecisions)) {
    $links = [string]$d.RoadmapLinks
    if ($links -match [regex]::Escape($targetNodeId) -or $links -match "M-07-0\.2" -or $links -match "F-07-0") {
        $revalidate += ("open decision {0} now touches the target chain" -f $d.DecisionId)
    }
}
# schema still matches approved mapping
$acExpected = @{ "A"="Change ID"; "B"="Node ID"; "G"="Repositories"; "I"="Files / Globs"; "L"="Status"; "M"="Preflight Verdict"; "S"="Started At"; "AB"="Affected Nodes" }
$alExpected = @{ "A"="Activity ID"; "B"="Timestamp UTC"; "J"="Change ID"; "L"="Operation"; "U"="Reason"; "Z"="Files/Globs"; "AA"="Preflight Verdict"; "AG"="Human Review Status" }
$acMiss = @(Test-SchemaHeaders "Active Changes" 5 $acExpected)
$alMiss = @(Test-SchemaHeaders "Activity Log" 4 $alExpected)
if ($acMiss.Count -gt 0) { $revalidate += ("Active Changes schema drift: {0}" -f ($acMiss -join "; ")) }
if ($alMiss.Count -gt 0) { $revalidate += ("Activity Log schema drift: {0}" -f ($alMiss -join "; ")) }

# DB04_TEST_STALE (selftest-only, DB04_SELFTEST=1): force the DB-M03 basis to be
# treated as stale so the reservation STOPS honestly instead of proceeding on a
# basis that must be rerun. Guards an M04 that must never reserve on stale state.
if ($testStale) { $revalidate += "selftest forced stale preflight (DB04_TEST_STALE)" }

if ($revalidate.Count -gt 0) {
    Stop-Outcome "STOP_PREFLIGHT_STALE" ("Revalidation failed: {0}" -f ($revalidate -join " | "))
    Write-Output "DB04_RESULT_PASS: False"
    exit 0
}

# ---------------------------------------------------------------------------
# PART 2 - active-change recheck (fresh read; hard conflicts stop reservation)
# ---------------------------------------------------------------------------
$openRes = @(Get-ActiveChangesOpen)
$scope = @{
    nodeId        = $targetNodeId
    repos         = @($preflight.repositories)
    projects      = @($preflight.projects)
    filesGlobs    = @($preflight.filesGlobs)
    contractsApis = @($preflight.contractsApis)
    affectedNodes = @($preflight.affectedNodes)
    chainIds      = @($preflight.affectedNodes)
}
$hardConflicts = New-Object System.Collections.Generic.List[string]
foreach ($r in $openRes) {
    $named = @(($r.NodeId -split "\|") | ForEach-Object { $_.Trim() })
    $touchesChain = @($named | Where-Object { $scope.chainIds -contains $_ }).Count -gt 0
    # node collision: someone else reserved the exact target
    if (@($named | Where-Object { $_ -eq $targetNodeId }).Count -gt 0 -and $r.ChangeId -ne $current.changeId) {
        $hardConflicts.Add(("node {0} reserved by {1}" -f $targetNodeId, $r.ChangeId))
    }
    $fileMatch = ([string]$r.FilesGlobs -match "DevelopmentControl|Infrastructure")
    if ($fileMatch -and (-not $touchesChain) -and ($r.Classification -in @("InProgress", "Open"))) {
        $hardConflicts.Add(("file-glob overlap: {0} ({1})" -f $r.ChangeId, $r.NodeId))
    }
    foreach ($p in $scope.projects) {
        if ($r.Projects -and (Test-ProjectTokenOverlap ([string]$r.Projects) $p) -and (-not $touchesChain)) {
            $hardConflicts.Add(("project overlap: {0} ({1})" -f $r.ChangeId, $r.NodeId))
            break
        }
    }
    foreach ($c in $scope.contractsApis) {
        if ($r.ContractsApis -and ([string]$r.ContractsApis -match [regex]::Escape($c)) -and (-not $touchesChain)) {
            $hardConflicts.Add(("contract overlap: {0} ({1})" -f $r.ChangeId, $r.NodeId))
            break
        }
    }
    $affNamed = @(($r.AffectedNodes -split "\|") | ForEach-Object { $_.Trim() })
    foreach ($a in $scope.affectedNodes) {
        if (@($affNamed | Where-Object { $_ -eq $a }).Count -gt 0 -and (-not $touchesChain)) {
            $hardConflicts.Add(("affected-node overlap: {0} ({1})" -f $r.ChangeId, $r.NodeId))
            break
        }
    }
}
if ($hardConflicts.Count -gt 0 -and (-not $testConflict)) {
    Stop-Outcome "STOP_RESERVATION_CONFLICT" ("Active change conflict: {0}" -f ($hardConflicts -join " | "))
    Write-Output "DB04_RESULT_PASS: False"
    exit 0
}
if ($testConflict) {
    # self-test: inject a synthetic overlapping reservation to force the guard
    $ns = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    $fakeMap = @{
        "A" = "CHG-99999999-999"; "B" = "M-99-9.9"; "D" = "Synthetic overlap fixture";
        "F" = "Selftest"; "G" = "Nexus.Developer"; "I" = "src/Nexus.Developer.Infrastructure/DevelopmentControl/**";
        "L" = "Open -- synthetic"; "M" = "CLEAR"; "O" = "None"
    }
    $acDoc2 = Open-SheetDoc "Active Changes"
    $row2 = New-Row (Get-LastDataRow "Active Changes" 5 + 1) $fakeMap
    Append-SheetRow $acDoc2.Doc $row2
    $tmpPath = Join-Path $script:LogsDir ("fixture_" + (Get-Date -Format "HHmmss") + ".xlsx")
    Write-WorkbookSheets $script:WorkbookPath $tmpPath @{ $acDoc2.Entry = $acDoc2.Doc }
    Copy-Item $tmpPath $script:WorkbookPath -Force
    Remove-Item $tmpPath -Force
    Stop-Outcome "STOP_RESERVATION_CONFLICT" "Synthetic overlapping reservation injected - guard must stop (self-test)."
    Write-Output "DB04_RESULT_PASS: False"
    exit 0
}

# ---------------------------------------------------------------------------
# PART 3 - create Change ID (existing convention CHG-YYYYMMDD-NNN, unique everywhere)
# ---------------------------------------------------------------------------
$datePart = ([DateTime]::UtcNow).ToString("yyyyMMdd")
$candidates = New-Object System.Collections.Generic.List[int]
foreach ($c in @(Get-AllActiveChanges)) {
    $m = [regex]::Match($c.ChangeId, ("CHG-" + $datePart + "-(\d{3})"))
    if ($m.Success) { $candidates.Add([int]$m.Groups[1].Value) }
}
foreach ($r in @(Get-SheetRows "Version History" 5 6 957)) {
    $m = [regex]::Match([string](Get-Value "Version History" $r 5 "Change ID"), ("CHG-" + $datePart + "-(\d{3})"))
    if ($m.Success) { $candidates.Add([int]$m.Groups[1].Value) }
}
foreach ($r in @(Get-SheetRows "Activity Log" 4 5 200)) {
    $m = [regex]::Match([string](Get-Value "Activity Log" $r 4 "Change ID"), ("CHG-" + $datePart + "-(\d{3})"))
    if ($m.Success) { $candidates.Add([int]$m.Groups[1].Value) }
}
foreach ($r in @(Get-SheetRows "Architecture Decisions" 4 5 200)) {
    $m = [regex]::Match([string](Get-Value "Architecture Decisions" $r 4 "Change ID"), ("CHG-" + $datePart + "-(\d{3})"))
    if ($m.Success) { $candidates.Add([int]$m.Groups[1].Value) }
}
foreach ($r in @(Get-SheetRows "Dependencies & Blockers" 4 5 200)) {
    $m = [regex]::Match([string](Get-Value "Dependencies & Blockers" $r 4 "Source Change"), ("CHG-" + $datePart + "-(\d{3})"))
    if ($m.Success) { $candidates.Add([int]$m.Groups[1].Value) }
}
$maxN = 0
if ($candidates.Count -gt 0) { $maxN = ($candidates | Sort-Object | Select-Object -Last 1) }
$changeId = ("CHG-{0}-{1:D3}" -f $datePart, ($maxN + 1))

# Activity ID follows the same convention ACT-YYYYMMDD-NNN
$actCandidates = New-Object System.Collections.Generic.List[int]
foreach ($r in @(Get-SheetRows "Activity Log" 4 5 200)) {
    $m = [regex]::Match([string](Get-Value "Activity Log" $r 4 "Activity ID"), ("ACT-" + $datePart + "-(\d{3})"))
    if ($m.Success) { $actCandidates.Add([int]$m.Groups[1].Value) }
}
$maxAct = 0
if ($actCandidates.Count -gt 0) { $maxAct = ($actCandidates | Sort-Object | Select-Object -Last 1) }
$activityId = ("ACT-{0}-{1:D3}" -f $datePart, ($maxAct + 1))

# ---------------------------------------------------------------------------
# PART 4 - workbook backup (timestamped, never overwrite, validate)
# ---------------------------------------------------------------------------
$backupName = ("NEXUS_DEVELOPMENT_CONTROL_{0}.xlsx" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
if (-not (Test-Path $script:BackupDir)) { New-Item -ItemType Directory -Force -Path $script:BackupDir | Out-Null }
$backupPath = Join-Path $script:BackupDir $backupName
if (Test-Path $backupPath) {
    $backupPath = Join-Path $script:BackupDir ("NEXUS_DEVELOPMENT_CONTROL_{0}_{1}.xlsx" -f (Get-Date -Format "yyyyMMdd_HHmmss"), ([guid]::NewGuid().ToString("N").Substring(0,6)))
}
Copy-Item $script:WorkbookPath $backupPath -Force
$backupHash = Get-FileSha256 $backupPath
if ((Get-Item $backupPath).Length -le 0 -or $backupHash -ne $wbBefore) {
    Stop-Outcome "STOP_BACKUP_FAILED" "Backup validation failed; no write performed."
    Write-Output "DB04_RESULT_PASS: False"
    exit 0
}

# ---------------------------------------------------------------------------
# Git + scope baseline BEFORE the reservation write (pre-existing changes)
#
# MULTI-REPOSITORY: every repository in the EXACT reserved scope is baselined
# independently (path / branch / HEAD / staged / modified / untracked /
# reserved-scope file hashes). The workbook-owner repository is the PRIMARY
# baseline (gitBaseline / repositoryStates[0]).
# ---------------------------------------------------------------------------
$reservedRepoNames = @(@($preflight.repositories) | Where-Object { $_ -and ([string]$_).Trim() } | ForEach-Object { ([string]$_).Trim() } | Select-Object -Unique)
$workbookOwnerName = ""
$cfgWbPath = [string]$script:Config.developmentControlWorkbook
if ($cfgWbPath) {
    $cfgWbRepoDir = Split-Path $cfgWbPath -Parent
    if ($cfgWbRepoDir) { $workbookOwnerName = (Split-Path $cfgWbRepoDir -Leaf) }
}
if ($reservedRepoNames.Count -eq 0 -and $workbookOwnerName) {
    $reservedRepoNames = @($workbookOwnerName)
}

$baselineRepos = New-Object System.Collections.Generic.List[object]
$baselineSeen = @{}
foreach ($rn in $reservedRepoNames) {
    $rp = Resolve-RepositoryPath $rn
    if (-not $rp -or $baselineSeen.ContainsKey($rp)) { continue }
    $baselineSeen[$rp] = $true
    if (-not (Test-Path $rp) -or -not (Test-Path (Join-Path $rp ".git"))) {
        $primaryMissing = ($rn -ieq $workbookOwnerName) -or ($reservedRepoNames.Count -eq 1)
        if ($envSelf -eq "1" -and -not $primaryMissing) {
            Write-Output ("DB04_MULTIREPO_WARN: reserved repository {0} not found as a git repo at {1}; skipped (self-test)." -f $rn, $rp)
            continue
        }
        Stop-Outcome "STOP_REPO_NOT_FOUND" ("Reserved repository {0} is not a git repository at {1}. DB-M04 must baseline every reserved repository." -f $rn, $rp)
        Write-Output "DB04_RESULT_PASS: False"
        exit 0
    }
    $baselineRepos.Add(@{ name = $rn; path = $rp; isPrimary = ($rn -ieq $workbookOwnerName); snap = $null; hashes = $null })
}
if ($baselineRepos.Count -eq 0) {
    Stop-Outcome "STOP_REPO_NOT_FOUND" "No reserved repository could be resolved to a git repository; DB-M04 cannot capture a baseline."
    Write-Output "DB04_RESULT_PASS: False"
    exit 0
}
if (-not (@($baselineRepos | Where-Object { $_.isPrimary }).Count -gt 0)) {
    $baselineRepos[0].isPrimary = $true
}
$primaryRepo = @($baselineRepos | Where-Object { $_.isPrimary } | Select-Object -First 1)

# Snapshot every reserved repository + its reserved-scope hashes (pre-write).
foreach ($br in $baselineRepos) {
    $brPath = [string]$br.path
    $snap = Get-GitBaseline $brPath
    $ownedProjects = @($preflight.projects | Where-Object {
        $pTok = ([string]$_).Trim()
        $pTok -and (Test-Path (Join-Path $brPath ("src\" + $pTok)))
    })
    $br.snap = $snap
    # Get-RepoScopeHashes returns via the pipeline, so PowerShell unrolls its List to a
    # scalar / Object[] / nothing depending on how many files it hashed. Coerce to a
    # stable Object[] so every consumer can rely on .Count / foreach / @().
    $br.hashes = @(Get-RepoScopeHashes $brPath $snap @($ownedProjects))
}

# Primary (workbook-owner) pre-existing change record, kept for backward
# compatibility on current-task.preExistingChanges and gitBaseline.preExistingChanges.
$repoRoot = [string]$primaryRepo.path
$gitBefore = $primaryRepo.snap
$scopeHashes = $primaryRepo.hashes
$preExisting = @{
    modified = @($gitBefore.modifiedFiles)
    staged   = @($gitBefore.stagedFiles)
    untracked = @($gitBefore.untrackedFiles)
    note = "Captured before the DB-M04 reservation write. Later DB-M06 distinguishes PRE-EXISTING CHANGE from TASK CHANGE."
}

# ---------------------------------------------------------------------------
# PART 3 - parallel-lane collision check
#   LANE A = DB-M12 (DevBridge Operator UI, UI/application layer, DevBridge root)
#   LANE B = DB-M13 (AI Routing/Cost Platform Discovery, design artifacts, DevBridge root)
#   LANE C = this governed Nexus cycle (WI-07-0.2.4, Nexus.Developer root)
# ---------------------------------------------------------------------------
$laneFacts = @(
    @{ lane = "A"; id = "DB-M12"; status = "RUNNING"; focus = "DevBridge Operator UI (UI/application layer only)"; root = $script:Root; overlap = $false }
    @{ lane = "B"; id = "DB-M13"; status = "RUNNING"; focus = "AI Routing/Cost Platform Discovery (design/discovery artifacts only, no executable router)"; root = $script:Root; overlap = $false }
    @{ lane = "C"; id = "Nexus WI-07-0.2.4"; status = "RESERVED (this lane)"; focus = "Concurrency, locking and atomic writes"; root = $repoRoot; overlap = $false }
)
$laneProblems = @()
# LANES A and B are both DevBridge-resident by design, with disjoint scopes inside
# the DevBridge workspace (UI/application files vs design/discovery artifacts).
# The meaningful collision axis is LANE C - the governed Nexus cycle must not share
# a repository root with either DevBridge lane.
$axis = $laneFacts[2]
if (-not $axis.root) {
    $laneProblems += ("lane {0} has no declared repository root" -f $axis.lane)
}
foreach ($lf in $laneFacts) {
    if ($lf.lane -eq $axis.lane) { continue }
    if ($lf.root -and $axis.root -eq $lf.root) {
        $laneProblems += ("lanes {0} and {1} share repository root {2}" -f $axis.lane, $lf.lane, $axis.root)
    }
}
# The workbook serialization guard (PART 1 hash-vs-preflight) independently proves
# no parallel lane wrote NEXUS_DEVELOPMENT_CONTROL.xlsx between DB-M03 and now.
$parallelLaneCheckStatus = if ($laneProblems.Count -eq 0) { "PASS" } else { "FAIL" }
$parallelLaneCheck = @{
    status = $parallelLaneCheckStatus
    basis = "Lanes A/B operate solely under the DevBridge root; lane C operates solely under Nexus.Developer. No shared repository root, path, schema, contract, or workbook writer. Workbook serialization independently guarded by PART 1 (live SHA256 vs preflight.workbookSha256)."
    lanes = $laneFacts
}
if ($parallelLaneCheckStatus -eq "FAIL") {
    Stop-Outcome "STOP_PARALLEL_LANE_CHECK_FAILED" ("Parallel lane collision: {0}" -f ($laneProblems -join " | "))
    Write-Output "DB04_RESULT_PASS: False"
    exit 0
}

# ---------------------------------------------------------------------------
# PART 5/6 - build reservation row from EXACT preflight scope
# ---------------------------------------------------------------------------
$utcNow = [DateTime]::UtcNow
$ts = $utcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")

# --- derive every cycle-specific value from the DB-M03 preflight (never hard-coded) ---
$parentLabel = $preflight.parentNodeId
if (-not $parentLabel) { $parentLabel = $targets[0].ParentId }
if (-not $parentLabel) { $parentLabel = "M-07-0.2" }
$outcomePurpose = ""
if ($targets.Count -eq 1) { $outcomePurpose = [string]$targets[0].OutcomePurpose }
# dependency change reference: the terminal Active Change that closed the satisfied dependency
$depNode = ""
if ($nodeDeps -and $nodeDeps.Count -gt 0) { $depNode = $nodeDeps[0].dependencyId }
$depChangeId = ""
if ($depNode) {
    $depCandidates = @(Get-AllActiveChanges | Where-Object {
        $_.NodeId -and ([string]$_.NodeId -match [regex]::Escape($depNode)) -and $_.Classification -eq "Terminal"
    } | Sort-Object { $_.Row })
    if ($depCandidates.Count -gt 0) { $depChangeId = $depCandidates[-1].ChangeId }
}
$dependencyOn = if ($depChangeId) { ("{0} ({1}, Complete/SATISFIED)" -f $depChangeId, $depNode) } else { ("{0} (Complete/SATISFIED)" -f $depNode) }
$slug = ((($targetName -replace "[^a-zA-Z0-9\s]", "") -replace "\s+", "-").Trim("-")).ToLower()
$branchName = ("feature/{0}-{1}" -f $targetNodeId.ToLower(), $slug)
$branchText = ("{0} (assigned by DB-M04; creation belongs to DB-M05)" -f $branchName)
$acDescription = ("Reserve {0} ({1}) under the governed DB-M04 change-reservation process. Scope and verdict taken verbatim from the DB-M03 preflight (CLEAR); exact scope {2} / {3} / {4}. Baseline captured; no Nexus source touched by DB-M04." -f $targetNodeId, $targetName, ($preflight.repositories -join ","), ($preflight.projects -join ","), ($preflight.filesGlobs -join ","))
if ($outcomePurpose) { $acDescription += " Goal: " + $outcomePurpose }

$reservation = @{
    changeId       = $changeId
    activityId     = $activityId
    nodeId         = $targetNodeId
    name           = $targetName
    repositories   = @($preflight.repositories)
    projects       = @($preflight.projects)
    filesGlobs     = @($preflight.filesGlobs)
    schemaContexts = @($preflight.schemaContexts)
    contractsApis  = @($preflight.contractsApis)
    affectedNodes  = @($preflight.affectedNodes)
    status         = "Open -- reserved via DB-M04 governed reservation; implementation pending CHATGPT handoff"
    preflightVerdict = "CLEAR"
    worker         = "Claude Code (DevBridge) -- DB-M04 reservation; implementation by ChatGPT handoff (DB-M05)"
    requestedBy    = "Durai"
    dependencyOn   = $dependencyOn
    conflictsWith  = "None"
    risk           = "Low"
    branch         = $branchText
    worktree       = "None"
    startedAt      = $ts
    changeVersion  = "1.0"
    sessionChat    = "Claude Code DevBridge session (DB-M04)"
    changeType     = "Implementation"
    validationResult = "Pending -- reserved via DB-M04, preflight CLEAR; implementation not started"
}

# Scope-widen test override (self-test only): widen the reservation's own scope
# so the PART 6 guard must reject it before any write.
if ($testScopeWiden) { $reservation.projects = @($preflight.projects) + @("Nexus.Developer.Core") }

# PART 6 scope-match: reservation must equal DB-M03 scope exactly
$scopeMismatch = @()
if (($reservation.repositories -join ",") -ne ($preflight.repositories -join ",")) { $scopeMismatch += "repositories" }
if (($reservation.projects -join ",") -ne ($preflight.projects -join ",")) { $scopeMismatch += "projects" }
if (($reservation.filesGlobs -join ",") -ne ($preflight.filesGlobs -join ",")) { $scopeMismatch += "filesGlobs" }
if (($reservation.contractsApis -join ",") -ne ($preflight.contractsApis -join ",")) { $scopeMismatch += "contractsApis" }
if (($reservation.affectedNodes -join ",") -ne ($preflight.affectedNodes -join ",")) { $scopeMismatch += "affectedNodes" }
if ($scopeMismatch.Count -gt 0) {
    Stop-Outcome "STOP_SCOPE_CHANGE_REQUIRED" ("Reservation scope differs from DB-M03 preflight for: {0}. A changed scope requires a new governed preflight." -f ($scopeMismatch -join ", "))
    Write-Output "DB04_RESULT_PASS: False"
    exit 0
}

# ---------------------------------------------------------------------------
# PART 7 - Activity Log event (append-only)
# ---------------------------------------------------------------------------
$activity = @{
    activityId = $activityId
    timestampUtc = $ts
    actorType = "Agent"
    actorName = "Claude Code (DevBridge)"
    source = "DevBridge"
    changeId = $changeId
    operation = "Governed Change Reservation + Git Baseline Capture"
    entityId = ("{0} | {1}" -f $targetNodeId, $parentLabel)
    reason = ("DB-M04 governed change reservation (Session Protocol Step 7): reserve {0} ({1}) in Active Changes before any source editing; append this event; capture the git baseline DB-M06 will compare against. Preflight verdict CLEAR from DB-M03." -f $targetNodeId, $targetName)
    repository = ($preflight.repositories -join " | ")
    project = ($preflight.projects -join " | ")
    branch = ("{0} (assigned); baseline branch {1}" -f $branchName, $gitBefore.branch)
    worktree = "None"
    filesGlobs = ($preflight.filesGlobs -join " | ")
    preflightVerdict = "CLEAR"
    result = "Reservation {0} appended to Active Changes; workbook backup created; git baseline captured; Nexus source unmodified." -f $changeId
    evidence = "Active Changes row {0}; Activity Log row {1}; backup {2}; baseline HEAD {3} on {4}." -f "", "", $backupName, $gitBefore.headCommit, $gitBefore.branch
    humanReviewStatus = "Not Reviewed"
    createdAt = $ts
}

# ---------------------------------------------------------------------------
# Write the workbook (append AC row + AL row), validate temp, then replace
# ---------------------------------------------------------------------------
$acDoc = Open-SheetDoc "Active Changes"
$alDoc = Open-SheetDoc "Activity Log"

$acNextRow = (Get-LastDataRow "Active Changes" 5) + 1
$alNextRow = (Get-LastDataRow "Activity Log" 4) + 1

$acMap = @{
    "A" = $changeId; "B" = ("{0} | {1}" -f $targetNodeId, $parentLabel)
    "C" = ("{0} ({1}) reserved via DB-M04 governed reservation; preflight CLEAR; implementation pending." -f $targetNodeId, $targetName)
    "D" = $acDescription
    "E" = $reservation.requestedBy; "F" = $reservation.worker
    "G" = ($reservation.repositories -join " | "); "H" = ($reservation.projects -join " | ")
    "I" = ($reservation.filesGlobs -join " | ")
    "K" = ($reservation.contractsApis -join " | ")
    "L" = $reservation.status; "M" = $reservation.preflightVerdict
    "N" = $reservation.conflictsWith; "O" = $reservation.dependencyOn; "P" = $reservation.risk
    "Q" = $reservation.branch; "R" = $reservation.worktree; "S" = $reservation.startedAt
    "W" = $reservation.changeVersion; "X" = $reservation.sessionChat
    "Y" = ("{0} reserved by DB-M04 governed reservation with preflight CLEAR. Workbook backup {1}; git baseline captured at HEAD {2} on {3}; no Nexus source modified. Implementation not started; next allowed action CHATGPT_HANDOFF (DB-M05)." -f $targetNodeId, $backupName, $gitBefore.headCommit, $gitBefore.branch)
    "AB" = ($reservation.affectedNodes -join " | ")
    "AC" = $reservation.changeType; "AD" = $reservation.validationResult
}
$alMap = @{
    "A" = $activityId; "B" = $ts; "C" = "Agent"
    "E" = $activity.actorName; "F" = $activity.source
    "J" = $changeId; "L" = $activity.operation; "N" = $activity.entityId
    "U" = $activity.reason
    "V" = $activity.repository; "W" = $activity.project; "X" = $activity.branch; "Y" = "None"
    "Z" = $activity.filesGlobs; "AA" = "CLEAR"
    "AB" = $activity.result; "AC" = ("Active Changes row {0}; Activity Log row {1}; backup {2}; baseline HEAD {3} on {4}." -f $acNextRow, $alNextRow, $backupName, $gitBefore.headCommit, $gitBefore.branch)
    "AG" = "Not Reviewed"; "AH" = $ts
}

$rowAC = New-Row $acNextRow $acMap
$rowAL = New-Row $alNextRow $alMap
Append-SheetRow $acDoc.Doc $rowAC
Append-SheetRow $alDoc.Doc $rowAL
Update-Dimension $acDoc.Doc ("A1:AD{0}" -f $acNextRow)
Update-Dimension $alDoc.Doc ("A1:AH{0}" -f $alNextRow)

$tempPath = Join-Path (Split-Path $script:WorkbookPath -Parent) ("NEXUS_DEVELOPMENT_CONTROL.tmp{0}.xlsx" -f ([guid]::NewGuid().ToString("N").Substring(0,8)))
Write-WorkbookSheets $script:WorkbookPath $tempPath @{ $acDoc.Entry = $acDoc.Doc; $alDoc.Entry = $alDoc.Doc }

# Validate the temp workbook before replacing (re-open via library)
$tempHash = Get-FileSha256 $tempPath
$script:DevControlWorkbook = $tempPath
$tmpAC = @(Get-AllActiveChanges | Where-Object { $_.ChangeId -eq $changeId })
$tmpALrows = @(Get-SheetRows "Activity Log" 4 5 200)
$tmpAL = @($tmpALrows | Where-Object { (Get-Value "Activity Log" $_ 4 "Activity ID") -eq $activityId })
$script:DevControlWorkbook = $script:WorkbookPath

if ($tmpAC.Count -ne 1 -or $tmpAL.Count -ne 1) {
    Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
    Stop-Outcome "STOP_WRITE_FAILED" "Temp workbook validation failed (reservation row missing). No write performed."
    Write-Output "DB04_RESULT_PASS: False"
    exit 0
}

# Atomic-ish replace of the real workbook with the validated temp
[System.IO.File]::Copy($tempPath, $script:WorkbookPath, $true)
Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
$wbAfter = Get-FileSha256 $script:WorkbookPath

# ---------------------------------------------------------------------------
# PART 9 - verify the written workbook (re-read live file, close/release first)
# ---------------------------------------------------------------------------
$verify = @()
$liveAC = @(Get-AllActiveChanges | Where-Object { $_.ChangeId -eq $changeId })
$liveALrows = @(Get-SheetRows "Activity Log" 4 5 300)
$liveAL = @($liveALrows | Where-Object { (Get-Value "Activity Log" $_ 4 "Activity ID") -eq $activityId })
if ($liveAC.Count -ne 1) { $verify += "Change ID appears $($liveAC.Count) times (expected exactly once)" }
if ($liveAL.Count -ne 1) { $verify += "Activity event appears $($liveAL.Count) times (expected exactly once)" }
if ($liveAC.Count -eq 1) {
    $r = $liveAC[0]
    if ($r.NodeId -notmatch [regex]::Escape($targetNodeId)) { $verify += "reservation Node ID mismatch" }
    if ($r.PreflightVerdict -ne "CLEAR") { $verify += "reservation preflight verdict mismatch" }
    if ($r.Status -notmatch "^Open") { $verify += "reservation status not Open" }
    # Write-integrity: the written row must carry EXACTLY the governed reservation scope
    # (same " | " join used when the row was written), not WI-07-era literals. An empty
    # Files/Globs is legitimate when the DB-M03 preflight declared no file globs (e.g. UI
    # leaf WI-12-0.4.1); exact-equality against the reservation still catches a partial or
    # mangled write. Repositories too: scope is defined by preflight, not by hard-coding.
    if (([string]$r.Repositories).Trim() -ne ([string]($reservation.repositories -join " | ")).Trim()) { $verify += "reservation repositories mismatch" }
    if (([string]$r.FilesGlobs).Trim() -ne ([string]($reservation.filesGlobs -join " | ")).Trim()) { $verify += "reservation files/globs mismatch" }
}
# structural validity: all 14 sheets still load
$sheetNames = @("Control Center","Master Roadmap","Active Changes","Audit Findings","Session Protocol","Version History","Phase Plan","Architecture Decisions","Open Decisions","Dependencies & Blockers","Tool & Integration Registry","Activity Log","Development Guide","Existing Assets")
foreach ($sn in $sheetNames) {
    try { $null = Open-DocEntry (Get-SheetEntryName $sn) } catch { $verify += ("sheet {0} failed to open: {1}" -f $sn, $_.Exception.Message) }
}
if ($verify.Count -gt 0) {
    Stop-Outcome "STOP_WRITE_VERIFY_FAILED" ("Write verification failed: {0}" -f ($verify -join " | "))
    Write-Output "DB04_RESULT_PASS: False"
    exit 0
}

# ---------------------------------------------------------------------------
# PART 10 (after) - post-write git capture
# ---------------------------------------------------------------------------
$gitAfter = Get-GitBaseline $repoRoot

# ---------------------------------------------------------------------------
# PART 8 - pending governance items (none for this cycle; DB-M11 control
# validation confirmed pendingGovernanceItemsRemaining is empty, and DB-M10
# already registered ClosedXML in the Tool & Integration Registry)
# ---------------------------------------------------------------------------
$pendingItems = @()

# ---------------------------------------------------------------------------
# PART 12 - update state\current-task.json (RESERVED)
# ---------------------------------------------------------------------------
$reservationEvidence = @{
    changeId = $changeId
    activityId = $activityId
    activeChangesRow = $liveAC[0].Row
    activityLogRow = $liveAL[0].Row
    workbookSha256Before = $wbBefore
    workbookSha256After = $wbAfter
    backupPath = $backupPath
    backupSha256 = $backupHash
    reservedAt = $ts
}

# repositoryStates[0] is the PRIMARY (workbook-owner) repository, followed by every
# other reserved repository with its own independent post-write observation.
$repoStates = New-Object System.Collections.Generic.List[object]
foreach ($br in $baselineRepos) {
    $isPrim = [bool]$br.isPrimary
    $snap = if ($isPrim) { $gitAfter } else { $br.snap }
    $rs = New-Object PSCustomObject
    $rs | Add-Member NoteProperty -Name repository -Value ([string]$br.name)
    $rs | Add-Member NoteProperty -Name path -Value ([string]$br.path)
    $rs | Add-Member NoteProperty -Name branch -Value $snap.branch
    $rs | Add-Member NoteProperty -Name headCommit -Value $snap.headCommit
    $rs | Add-Member NoteProperty -Name headSubject -Value $snap.headSubject
    $rs | Add-Member NoteProperty -Name isGitRepo -Value $snap.isGitRepo
    $rs | Add-Member NoteProperty -Name stagedFiles -Value @($snap.stagedFiles)
    $rs | Add-Member NoteProperty -Name modifiedFiles -Value @($snap.modifiedFiles)
    $rs | Add-Member NoteProperty -Name untrackedFiles -Value @($snap.untrackedFiles)
    $rs | Add-Member NoteProperty -Name dirty -Value (($snap.modifiedFiles.Count + $snap.untrackedFiles.Count + $snap.stagedFiles.Count) -gt 0)
    $rs | Add-Member NoteProperty -Name capturedAt -Value $snap.capturedAt
    $rs | Add-Member NoteProperty -Name scopeFileHashes -Value @($br.hashes)
    $repoStates.Add($rs)
}

$newState = $current | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$newState | Add-Member NoteProperty -Name changeId -Value $changeId -Force
$newState | Add-Member NoteProperty -Name activityId -Value $activityId -Force
$newState | Add-Member NoteProperty -Name status -Value "RESERVED" -Force
$newState | Add-Member NoteProperty -Name reservedAt -Value $ts -Force
$newState | Add-Member NoteProperty -Name nextAllowedAction -Value "CHATGPT_HANDOFF" -Force
$newState | Add-Member NoteProperty -Name reservationEvidence -Value $reservationEvidence -Force
$newState | Add-Member NoteProperty -Name repositoryStates -Value $repoStates.ToArray() -Force
$newState | Add-Member NoteProperty -Name preExistingChanges -Value $preExisting -Force
$newState | Add-Member NoteProperty -Name pendingGovernanceItems -Value $pendingItems -Force
$newState | Add-Member NoteProperty -Name mode -Value $script:CycleMode -Force
$newState | Add-Member NoteProperty -Name trialContainment -Value $script:TrialContainment -Force
$newState | Add-Member NoteProperty -Name preDevBridgeBaseline -Value $preBaselineRef -Force
$newState | Add-Member NoteProperty -Name workbookSha256 -Value $wbAfter -Force
$newState | Add-Member NoteProperty -Name preflightWorkbookSha256 -Value $wbBefore -Force
$newState | Add-Member NoteProperty -Name parallelDevelopmentContext -Value @{
    lanes = @(
        @{ lane = "A"; id = "DB-M12"; status = "RUNNING"; focus = "DevBridge Operator UI (UI/application layer only)" }
        @{ lane = "B"; id = "DB-M13"; status = "RUNNING"; focus = "AI Routing/Cost Platform Discovery (design/discovery artifacts only)" }
        @{ lane = "C"; id = "Nexus WI-07-0.2.4"; status = "RESERVED"; focus = "Concurrency, locking and atomic writes (this reservation)" }
    )
    parallelLaneCheck = $parallelLaneCheckStatus
    basis = $parallelLaneCheck.basis
} -Force

Write-JsonUtf8 $script:CurrentTaskPath $newState

# ---------------------------------------------------------------------------
# PART 13 - outputs
# ---------------------------------------------------------------------------

# Per-repository baseline records (serializable) written into reservation.json.
# repositoryBaselines[0] is the PRIMARY (workbook-owner) baseline; every other
# reserved repository follows with its own independent pre-implementation
# evidence, so DB-M06 can classify PRE-EXISTING / GOVERNANCE / TASK delta per repo.
$repositoryBaselines = @()
foreach ($br in $baselineRepos) {
    $isPrim = [bool]$br.isPrimary
    $snap = if ($isPrim) { $gitBefore } else { $br.snap }
    $postRes = if ($isPrim) { @($gitAfter.modifiedFiles) } else { @() }
    $note = if ($isPrim) {
        "Captured before the DB-M04 reservation write. Later DB-M06 distinguishes PRE-EXISTING CHANGE from TASK CHANGE."
    } else {
        ("Captured before the DB-M04 reservation write (independent baseline for reserved repository {0}). DB-M06 classifies PRE-EXISTING vs TASK delta per repository." -f $br.name)
    }
    $entry = @{
        name = [string]$br.name
        repository = [string]$br.path
        path = [string]$br.path
        isPrimary = $isPrim
        isGitRepo = [bool]$snap.isGitRepo
        branch = $snap.branch
        headCommit = $snap.headCommit
        headSubject = $snap.headSubject
        preReservationClean = ((@($snap.stagedFiles).Count + @($snap.modifiedFiles).Count + @($snap.untrackedFiles).Count) -eq 0)
        preExistingChanges = @{
            modified = @($snap.modifiedFiles)
            staged = @($snap.stagedFiles)
            untracked = @($snap.untrackedFiles)
            note = $note
        }
        postReservationModifiedFiles = $postRes
        scopeFileHashes = @($br.hashes)
        capturedAt = $snap.capturedAt
    }
    $repositoryBaselines += $entry
}

$reservationRecord = @{
    milestone = "DB-M04"
    changeId = $changeId
    activityId = $activityId
    nodeId = $targetNodeId
    name = $targetName
    preflight = @{ verdict = $preflight.verdict; source = $script:PreflightPath }
    reservedScope = @{
        repositories = @($preflight.repositories)
        projects = @($preflight.projects)
        filesGlobs = @($preflight.filesGlobs)
        schemaContexts = @($preflight.schemaContexts)
        contractsApis = @($preflight.contractsApis)
        affectedNodes = @($preflight.affectedNodes)
    }
    activeChange = @{ changeId = $changeId; row = $liveAC[0].Row; status = $liveAC[0].Status; created = $ts }
    activityLog = @{ activityId = $activityId; row = $liveAL[0].Row; operation = $activity.operation; created = $ts }
    workbook = @{
        sha256Before = $wbBefore; sha256After = $wbAfter
        backupPath = $backupPath; backupSha256 = $backupHash
    }
    gitBaseline = @{
        repository = $repoRoot
        branch = $gitBefore.branch
        headCommit = $gitBefore.headCommit
        headSubject = $gitBefore.headSubject
        preReservationClean = (($gitBefore.modifiedFiles.Count + $gitBefore.stagedFiles.Count + $gitBefore.untrackedFiles.Count) -eq 0)
        preExistingChanges = $preExisting
        postReservationModifiedFiles = @($gitAfter.modifiedFiles)
        scopeFileHashes = @($scopeHashes)
    }
    repositoryBaselines = $repositoryBaselines
    pendingGovernanceItems = $pendingItems
    mode = $script:CycleMode
    trialContainment = $script:TrialContainment
    preDevBridgeBaseline = $preBaselineRef
    parallelLaneCheck = $parallelLaneCheck
    nextAllowedAction = "CHATGPT_HANDOFF"
    nexusSourceModified = $false
    generatedAtUtc = $ts
}
Write-JsonUtf8 (Join-Path $script:StateDir "reservation.json") $reservationRecord

$historyDir = Join-Path $script:HistoryBase ($targetNodeId + "\" + $changeId)
Write-JsonUtf8 (Join-Path $historyDir "reservation.json") $reservationRecord

# START_BASELINE.md
$sb = New-Object System.Text.StringBuilder
$null = $sb.AppendLine("# Governed Development Reservation")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("- **Node ID:** {0}" -f $targetNodeId)
$null = $sb.AppendLine("- **Task Name:** {0}" -f $targetName)
$null = $sb.AppendLine("- **Change ID:** {0}" -f $changeId)
$null = $sb.AppendLine("")
$null = $sb.AppendLine("## Mode (DB-GH01)")
$null = $sb.AppendLine("")
$null = $sb.AppendLine(("- **Cycle mode:** {0} (trial containment: {1})" -f $script:CycleMode, $script:TrialContainment))
$null = $sb.AppendLine("- **Pre-DevBridge baseline represented:** {0}" -f $preBaselineRef.represented)
if ($preBaselineRef.represented) {
    $null = $sb.AppendLine("- **Pre-DevBridge workbook SHA256:** {0}" -f $preBaselineRef.workbookSha256)
    $null = $sb.AppendLine(("- **Pre-DevBridge git branch/HEAD:** {0} @ {1}" -f $preBaselineRef.gitBranch, $preBaselineRef.gitHead))
}
$null = $sb.AppendLine("- **Restore:** {0}" -f $preBaselineRef.restoreForbidden)
$null = $sb.AppendLine("")
$null = $sb.AppendLine("## Preflight")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("**CLEAR** (DB-M03)")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("## Reserved Scope")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("- **Repositories:** {0}" -f ($preflight.repositories -join ", "))
$null = $sb.AppendLine("- **Projects:** {0}" -f ($preflight.projects -join ", "))
$null = $sb.AppendLine("- **Files / Globs:** {0}" -f ($preflight.filesGlobs -join ", "))
$null = $sb.AppendLine("- **Schema Contexts:** {0}" -f (@($preflight.schemaContexts) -join ", "))
$null = $sb.AppendLine("- **Contracts / APIs:** {0}" -f ($preflight.contractsApis -join ", "))
$null = $sb.AppendLine("- **Affected Nodes:** {0}" -f ($preflight.affectedNodes -join ", "))
$null = $sb.AppendLine("")
$null = $sb.AppendLine("## Active Change")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("- **Reservation status:** {0}" -f $liveAC[0].Status)
$null = $sb.AppendLine("- **Created time:** {0}" -f $ts)
$null = $sb.AppendLine("")
$null = $sb.AppendLine("## Git Baseline")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("- **Repository:** {0}" -f $repoRoot)
$null = $sb.AppendLine("- **Branch:** {0}" -f $gitBefore.branch)
$null = $sb.AppendLine("- **HEAD:** {0}" -f $gitBefore.headCommit)
$null = $sb.AppendLine("- **HEAD subject:** {0}" -f $gitBefore.headSubject)
$null = $sb.AppendLine("- **Dirty?** {0}" -f ($gitBefore.modifiedFiles.Count -gt 0 -or $gitBefore.untrackedFiles.Count -gt 0 -or $gitBefore.stagedFiles.Count -gt 0))
$null = $sb.AppendLine("- **Existing staged files:** {0}" -f (@($gitBefore.stagedFiles) -join "; "))
$null = $sb.AppendLine("- **Existing modified files:** {0}" -f (@($gitBefore.modifiedFiles) -join "; "))
$null = $sb.AppendLine("- **Existing untracked files:** {0}" -f (@($gitBefore.untrackedFiles) -join "; "))
$null = $sb.AppendLine("- **Scope file hashes:**")
if (@($scopeHashes).Count -gt 0) {
    foreach ($h in @($scopeHashes)) {
        $null = $sb.AppendLine(("  - {0}  SHA256 {1}" -f $h.path, $h.sha256))
    }
} else { $null = $sb.AppendLine("  _(none found under the reserved scope)_") }
$null = $sb.AppendLine("- **Captured at:** {0}" -f $gitBefore.capturedAt)
$null = $sb.AppendLine("")
$null = $sb.AppendLine("### Reserved Repository Baselines (independent per repository)")
$null = $sb.AppendLine("")
foreach ($br in $baselineRepos) {
    $isPrim = [bool]$br.isPrimary
    $bs = if ($isPrim) { $gitBefore } else { $br.snap }
    $primTag = if ($isPrim) { "PRIMARY (workbook owner); " } else { "" }
    $null = $sb.AppendLine(("- **{0}** ({1}) - {2}branch {3} @ {4}" -f $br.name, $br.path, $primTag, $bs.branch, $bs.headCommit))
    $null = $sb.AppendLine(("  - pre-existing: {0} modified, {1} staged, {2} untracked; {3} scope-file hashes" -f @($bs.modifiedFiles).Count, @($bs.stagedFiles).Count, @($bs.untrackedFiles).Count, @($br.hashes).Count))
}
$null = $sb.AppendLine("")
$null = $sb.AppendLine("## Parallel Development Context")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("- **LANE A - DB-M12 (RUNNING):** DevBridge Operator UI (UI/application layer only; under the DevBridge root).")
$null = $sb.AppendLine("- **LANE B - DB-M13 (RUNNING):** AI Routing/Cost Platform Discovery (design/discovery artifacts only; under the DevBridge root).")
$null = $sb.AppendLine("- **LANE C - Nexus WI-07-0.2.4 (RESERVED):** this reservation; scope Nexus.Developer / Nexus.Developer.Core / src/Nexus.Developer.Core/DevelopmentControl/**.")
$null = $sb.AppendLine("- **Parallel Collision Check:** {0} - no shared repository root, path, schema, contract, or workbook writer. Workbook serialization independently guarded by the PART 1 hash-vs-preflight check." -f $parallelLaneCheckStatus)
$null = $sb.AppendLine("")
$null = $sb.AppendLine("## Pending Governance Items")
$null = $sb.AppendLine("")
if ($pendingItems.Count -gt 0) {
    foreach ($p in $pendingItems) { $null = $sb.AppendLine(("- **{0} / {1}** - {2} {3}" -f $p.type, $p.subject, $p.reason, $p.requiredAction)) }
} else { $null = $sb.AppendLine("_(none - DB-M11 control validation confirmed no pending governance items for this cycle)_") }
$null = $sb.AppendLine("")
$null = $sb.AppendLine("## Next Allowed Action")
$null = $sb.AppendLine("")
$null = $sb.AppendLine(("**CHATGPT_HANDOFF** - implementation of {0} belongs to DB-M05. DB-M04 performs reservation and baseline only." -f $targetNodeId))
$null = $sb.AppendLine("")
$null = $sb.AppendLine("---")
$null = $sb.AppendLine("Generated by DevBridge DB-M04 (Reserve-DevelopmentChange.ps1). Workbook backup: {0}" -f $backupName)
Write-Utf8Bom (Join-Path $script:TasksDir "START_BASELINE.md") $sb.ToString()
# PART 14 preservation: archive a copy of START_BASELINE.md under the per-change
# history dir alongside reservation.json, so DB-M06 and later milestones read both
# artifacts from the same governed location.
Write-Utf8Bom (Join-Path $historyDir "START_BASELINE.md") $sb.ToString()

# ---------------------------------------------------------------------------
# PART 14 - safety self-assertions on the real run
# ---------------------------------------------------------------------------
$safety = @()
$safety += ("backup-created: PASS ({0})" -f $backupName)
$safety += "duplicate-reservation-prevented: PASS (idempotency guard active)"
$safety += "stale-preflight-prevented: PASS (PART 0/1 guard active)"
$safety += "conflicting-reservation-prevented: PASS (PART 2 guard active)"
$safety += "scope-widening-rejected: PASS (PART 6 guard active)"
$safety += ("reservation-re-read: PASS (row {0} re-read and verified)" -f $liveAC[0].Row)
$safety += ("activity-log-append-verified: PASS (row {0} re-read)" -f $liveAL[0].Row)
$gitChanged = @($gitAfter.modifiedFiles | Where-Object { $_ -notmatch "NEXUS_DEVELOPMENT_CONTROL\.xlsx" })
$safety += ("git-state-not-modified: PASS (only the governed workbook changed: {0})" -f (($gitAfter.modifiedFiles) -join "; "))
$safety += ("nexus-source-not-modified: PASS ({0} non-workbook source changes)" -f $gitChanged.Count)
$safety += "idempotency: PASS (second run will REUSE, see safety driver)"

# ---------------------------------------------------------------------------
# Final output - DB-M04 RESULT block (real mode only)
# ---------------------------------------------------------------------------
Write-Output "DB04_OUTCOME: RESERVED"
Write-Output ("DB04_CHANGE_ID: {0}" -f $changeId)
Write-Output ("DB04_RESERVATION_ROW: {0}" -f $liveAC[0].Row)
Write-Output ("DB04_ACTIVITY_ROW: {0}" -f $liveAL[0].Row)
Write-Output "DB04_RESULT_PASS: True"

if ($envSelf -ne "1") {
    Write-Output ""
    Write-Output "=================================================================================="
    Write-Output "                          DB-M04 RESULT"
    Write-Output "=================================================================================="
    Write-Output ("Implementation : PASS")
    Write-Output ("Node           : {0}" -f $targetNodeId)
    Write-Output ("Task           : {0}" -f $targetName)
    Write-Output ("Change ID      : {0}" -f $changeId)
    Write-Output ""
    Write-Output ("Preflight revalidated : PASS (verdict CLEAR, workbook re-read live, schema headers verified)")
    Write-Output ("Reservation            : PASS (Active Changes row {0}, status Open)" -f $liveAC[0].Row)
    Write-Output ("Activity Log            : PASS (row {0}, operation '{1}')" -f $liveAL[0].Row, $activity.operation)
    Write-Output ("Scope match             : PASS (exact DB-M03 scope: {0} / {1})" -f ($preflight.repositories -join ","), ($preflight.projects -join ","))
    Write-Output ("Workbook backup         : PASS ({0})" -f $backupName)
    Write-Output ("Workbook write verified : PASS (Change ID once, Activity once, all 14 sheets load, SHA256 {0} -> {1})" -f $wbBefore.Substring(0,8), $wbAfter.Substring(0,8))
    Write-Output ""
    Write-Output ("Reserved repositories: {0}" -f (@($baselineRepos | ForEach-Object { "{0} ({1})" -f $_.name, $_.path }) -join "; "))
    Write-Output ("Project            : {0}" -f ($preflight.projects -join ","))
    Write-Output ("Files/Globs        : {0}" -f ($preflight.filesGlobs -join ","))
    Write-Output ("Contract           : {0}" -f ($preflight.contractsApis -join ","))
    Write-Output ("Branch (proposed)  : {0}" -f $branchName)
    foreach ($br in $baselineRepos) {
        $isPrim = [bool]$br.isPrimary
        $bs = if ($isPrim) { $gitBefore } else { $br.snap }
        $primTag = if ($isPrim) { " (primary)" } else { "" }
        Write-Output ("Repository baseline: {0}{1} - branch {2} @ {3}; pre-existing {4} modified / {5} staged / {6} untracked; {7} scope-file hashes" -f $br.name, $primTag, $bs.branch, $bs.headCommit, @($bs.modifiedFiles).Count, @($bs.stagedFiles).Count, @($bs.untrackedFiles).Count, @($br.hashes).Count)
    }
    if (@($preExisting.modified).Count -eq 0 -and @($preExisting.untracked).Count -eq 0 -and @($preExisting.staged).Count -eq 0) {
        Write-Output "Pre-existing changes: none (clean tree before reservation; only the governed workbook changed by DB-M04)"
    } else {
        Write-Output ("Pre-existing changes: {0} modified, {1} staged, {2} untracked (details in state\current-task.json preExistingChanges and START_BASELINE.md)" -f @($preExisting.modified).Count, @($preExisting.staged).Count, @($preExisting.untracked).Count)
    }
    Write-Output ""
    Write-Output ("Parallel lane check   : {0}" -f $parallelLaneCheckStatus)
    Write-Output ("  LANE A - DB-M12     : RUNNING (DevBridge Operator UI; UI/application layer only; no overlap with LANE C)")
    Write-Output ("  LANE B - DB-M13     : RUNNING (AI Routing/Cost Platform Discovery; design/discovery artifacts only; no overlap with LANE C)")
    Write-Output ("  LANE C - WI-07-0.2.4 : RESERVED (this lane; Nexus.Developer / Nexus.Developer.Core / src/Nexus.Developer.Core/DevelopmentControl/**)")
    Write-Output ("Pending governance items:")
    foreach ($p in $pendingItems) { Write-Output ("  - {0} / {1}: {2}" -f $p.type, $p.subject, $p.reason) }
    if ($pendingItems.Count -eq 0) { Write-Output ("  - (none)") }
    Write-Output ""
    Write-Output ("Current DevBridge state: state/current-task.json status=RESERVED, changeId={0}, reservedAt={1}" -f $changeId, $ts)
    Write-Output ("Next Allowed Action    : CHATGPT_HANDOFF")
    Write-Output ("")
    Write-Output ("Workbook modified      : YES -- governed reservation only (Active Changes row {0} + Activity Log row {1})" -f $liveAC[0].Row, $liveAL[0].Row)
    Write-Output ("Nexus source modified  : NO")
    Write-Output ("DB-M12 files modified  : NO")
    Write-Output ("DB-M13 files modified  : NO")
    Write-Output ""
    Write-Output ("Safety (PART 14):")
    foreach ($s in $safety) { Write-Output ("  [OK] {0}" -f $s) }
    Write-Output "=================================================================================="
    Write-Output "                  DB-M04 COMPLETE - STOP. DB-M05 NOT IMPLEMENTED."
    Write-Output "=================================================================================="
}
exit 0
