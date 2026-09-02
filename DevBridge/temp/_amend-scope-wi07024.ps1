# _amend-scope-wi07024.ps1
# Governed Active Change scope amendment for WI-07-0.2.4 / CHG-20260830-017.
# AMENDS the existing Active Changes row 80 (Projects, Files/Globs, Contracts/APIs,
# Notes, Validation Result) and APPENDS exactly one 34-column Activity Log event.
# Uses the same OOXML write mechanism as Reserve-DevelopmentChange.ps1.
# Writes temp -> validates temp -> promotes; reads back the live file after.
# Always exits 0 (DevBridge convention). Read stdout markers AMEND_OUTCOME /
# AMEND_RESULT_PASS.
param(
    [string]$ExpectedPreHash = "93D2620D919789D9C7199C417FF3A9FD5B09DA0464F0D3800DB0748E62772372",
    [string]$ChangeId = "CHG-20260830-017",
    [string]$ActivityId = "ACT-20260830-019",
    [string]$BackupName = "NEXUS_DEVELOPMENT_CONTROL_20260830_184615.xlsx",
    [string]$WorkbookPath = "C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\scripts\Read-DevelopmentControl.ps1"

$script:DevControlWorkbook = $WorkbookPath
$script:WorkbookPath = $WorkbookPath
$xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
$xmlSpace = [System.Xml.Linq.XNamespace]"http://www.w3.org/XML/1998/namespace"

# ---------------------------------------------------------------------------
# Write helpers (same mechanism as Reserve-DevelopmentChange.ps1)
# ---------------------------------------------------------------------------
function Get-ColumnNumber([string]$letters) {
    $n = 0
    foreach ($ch in $letters.ToCharArray()) { $n = $n * 26 + ([int][char]$ch - 64) }
    return $n
}
function Open-SheetDoc([string]$sheetName) {
    $entry = Get-SheetEntryName $sheetName
    $fs = [System.IO.File]::Open($script:WorkbookPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
    $rd = New-Object System.IO.StreamReader($zip.GetEntry($entry).Open())
    $doc = [System.Xml.Linq.XDocument]::Load($rd)
    $rd.Close(); $zip.Dispose(); $fs.Dispose()
    return @{ Doc = $doc; Entry = $entry }
}
function New-Cell([int]$rowNum, [string]$colLetter, [string]$value) {
    $c = New-Object System.Xml.Linq.XElement($xNs + "c")
    $c.SetAttributeValue("r", ($colLetter + $rowNum))
    $c.SetAttributeValue("t", "inlineStr")
    $is = New-Object System.Xml.Linq.XElement($xNs + "is")
    $t = New-Object System.Xml.Linq.XElement($xNs + "t")
    $t.SetAttributeValue($xmlSpace + "space", "preserve")
    $t.Value = $value
    $is.Add($t); $c.Add($is)
    return $c
}
function New-Row([int]$rowNum, [hashtable]$cellMap) {
    $row = New-Object System.Xml.Linq.XElement($xNs + "row")
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
    $dim = $doc.Root.Element($xNs + "dimension")
    if ($dim) { $dim.SetAttributeValue("ref", $newRef) }
}
function Append-SheetRow($doc, $rowEl) {
    $doc.Root.Element($xNs + "sheetData").Add($rowEl)
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
            $out = $newEntry.Open(); $in = $entry.Open()
            if ($newDocs.ContainsKey($name)) {
                $newDocs[$name].Save($out, [System.Xml.Linq.SaveOptions]::DisableFormatting)
            } else { $in.CopyTo($out) }
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
# Set (replace or create) one inlineStr cell on an existing row element.
function Set-CellInline($rowEl, [string]$colLetter, [int]$rowNum, [string]$value) {
    $ref = $colLetter + $rowNum
    $cell = $rowEl.Elements($xNs + "c") | Where-Object { [string]$_.Attribute("r").Value -eq $ref }
    if (-not $cell) {
        $cell = New-Object System.Xml.Linq.XElement($xNs + "c")
        $cell.SetAttributeValue("r", $ref)
        $rowEl.Add($cell)
    }
    $cell.RemoveNodes()
    $cell.SetAttributeValue("t", "inlineStr")
    $is = New-Object System.Xml.Linq.XElement($xNs + "is")
    $t = New-Object System.Xml.Linq.XElement($xNs + "t")
    $t.SetAttributeValue($xmlSpace + "space", "preserve")
    $t.Value = $value
    $is.Add($t); $cell.Add($is)
}
function Get-SheetRowElement($doc, [int]$rowNum) {
    foreach ($row in $doc.Root.Element($xNs + "sheetData").Elements($xNs + "row")) {
        if ([int]$row.Attribute("r").Value -eq $rowNum) { return $row }
    }
    return $null
}
function Get-LastDataRow([string]$sheetName, [int]$headerRow) {
    $rows = Get-SheetRows $sheetName $headerRow 1 300
    $max = $headerRow
    foreach ($r in $rows) { if ($r.Row -gt $max) { $max = $r.Row } }
    return $max
}
function Test-AllSheetsOpen {
    $names = @("Control Center","Master Roadmap","Active Changes","Audit Findings","Session Protocol","Version History","Phase Plan","Architecture Decisions","Open Decisions","Dependencies & Blockers","Tool & Integration Registry","Activity Log","Development Guide","Existing Assets")
    $ok = $true
    foreach ($sn in $names) { try { $null = Open-DocEntry (Get-SheetEntryName $sn) } catch { $ok = $false } }
    return $ok
}

# ---------------------------------------------------------------------------
# PART 1 inline revalidation + PART 14 idempotency guard
# ---------------------------------------------------------------------------
$outcome = "AMEND_FAILED"
$errors = New-Object System.Collections.Generic.List[string]

$preHash = Get-FileSha256 $script:WorkbookPath
if ($preHash -ne $ExpectedPreHash) { $errors.Add("pre-write SHA256 mismatch: got $preHash expected $ExpectedPreHash") }

$liveAC = @(Get-AllActiveChanges | Where-Object { $_.ChangeId -eq $ChangeId })
if ($liveAC.Count -ne 1) { $errors.Add("CHG-017 appears $($liveAC.Count) times (expected exactly once)") }
if ($liveAC.Count -eq 1) {
    $r = $liveAC[0]
    if ($r.Status -notmatch "^Open") { $errors.Add("CHG-017 status not Open: $($r.Status)") }
    if ($r.NodeId -notmatch "WI-07-0.2.4") { $errors.Add("CHG-017 node mismatch: $($r.NodeId)") }
    if ($r.Projects -match "Nexus.Developer.Infrastructure") { $errors.Add("SCOPE_ALREADY_AMENDED: Projects already contains Infrastructure") }
    if ($r.FilesGlobs -match "Nexus.Developer.Infrastructure") { $errors.Add("SCOPE_ALREADY_AMENDED: Files/Globs already contains Infrastructure") }
    if ($r.PreflightVerdict -ne "CLEAR") { $errors.Add("CHG-017 preflight verdict not CLEAR: $($r.PreflightVerdict)") }
}
$existingAct = @(Get-SheetRows "Activity Log" 4 5 300 | Where-Object { (Get-Value "Activity Log" $_ 4 "Activity ID") -eq $ActivityId })
if ($existingAct.Count -gt 0) { $errors.Add("SCOPE_ALREADY_AMENDED: Activity ID $ActivityId already exists ($($existingAct.Count) times)") }

# dependency WI-07-0.2.3 must remain Complete
$roadmap = @(Get-AllRoadmapNodes | Where-Object { $_.NodeId -eq "WI-07-0.2.3" })
if ($roadmap.Count -ne 1 -or $roadmap[0].Status -ne "Complete") { $errors.Add("WI-07-0.2.3 not Complete: $($roadmap[0].Status)") }

if ($errors.Count -gt 0) {
    Write-Output ("AMEND_OUTCOME: {0}" -f (($errors | Select-Object -First 1) -replace ".*SCOPE_ALREADY_AMENDED.*", "SCOPE_ALREADY_AMENDED"))
    Write-Output ("AMEND_MESSAGE: {0}" -f ($errors -join " | "))
    Write-Output "AMEND_RESULT_PASS: False"
    exit 0
}

# ---------------------------------------------------------------------------
# PART 5+7 - amend row 80 + append Activity Log row 56
# ---------------------------------------------------------------------------
$ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$acDoc = Open-SheetDoc "Active Changes"
$alDoc = Open-SheetDoc "Activity Log"
$acNextRow = (Get-LastDataRow "Active Changes" 5)      # existing row count (row 80)
$alNextRow = (Get-LastDataRow "Activity Log" 4) + 1    # 56

$row80 = Get-SheetRowElement $acDoc.Doc 80
if (-not $row80) { Write-Output "AMEND_OUTCOME: AMEND_FAILED"; Write-Output "AMEND_MESSAGE: row 80 not found"; Write-Output "AMEND_RESULT_PASS: False"; exit 0 }

$acRaw80 = @(Get-SheetRows "Active Changes" 5 80 80)
$acRow80obj = $acRaw80[0]
if (-not $acRow80obj) { Write-Output "AMEND_OUTCOME: AMEND_FAILED"; Write-Output "AMEND_MESSAGE: Active Changes row 80 not readable"; Write-Output "AMEND_RESULT_PASS: False"; exit 0 }
$origProjects = (Get-Value "Active Changes" $acRow80obj 5 "Projects")
$origFilesGlobs = (Get-Value "Active Changes" $acRow80obj 5 "Files / Globs")
$origContracts = (Get-Value "Active Changes" $acRow80obj 5 "Contracts / APIs")
$origNotes = (Get-Value "Active Changes" $acRow80obj 5 "Notes")
$origValidation = (Get-Value "Active Changes" $acRow80obj 5 "Validation Result")

$newProjects = "Nexus.Developer.Core | Nexus.Developer.Infrastructure"
$newFilesGlobs = "src/Nexus.Developer.Core/DevelopmentControl/** | src/Nexus.Developer.Infrastructure/DevelopmentControl/ExcelDevelopmentControlStore.cs"
$newContracts = "IDevelopmentControlStore | IDevelopmentControlAtomicWorkUnitRunner"
$newNotes = $origNotes + " | SCOPE-AMENDED 2026-08-31: SCOPE_CHANGE_CLEAR preflight (state/scope-change-preflight.json) approved adding Nexus.Developer.Infrastructure project + single file src/Nexus.Developer.Infrastructure/DevelopmentControl/ExcelDevelopmentControlStore.cs. Original Core-only reservation preserved (DB-M04). Pre-amendment backup $BackupName. Lifecycle unchanged: IMPLEMENTATION BLOCKED / SCOPE CHANGE REQUIRED; next allowed action CONTINUE_DEEPSEEK_IMPLEMENTATION."
$newValidation = $origValidation + "; scope amended 2026-08-31 (SCOPE_CHANGE_CLEAR)"

Set-CellInline $row80 "H" 80 $newProjects
Set-CellInline $row80 "I" 80 $newFilesGlobs
Set-CellInline $row80 "K" 80 $newContracts
Set-CellInline $row80 "Y" 80 $newNotes
Set-CellInline $row80 "AD" 80 $newValidation

$reason = "Governed Active Change scope amendment (SCOPE_CHANGE_CLEAR preflight): the Core concurrency/locking/atomic-work-unit foundation was implemented inside the original Core-only reservation, but repository reality proved that genuine end-to-end atomic multi-operation execution requires one minimal integration entry point in the existing ExcelDevelopmentControlStore adapter. The approved added scope is the minimum Infrastructure delta validated by SCOPE_CHANGE_PREFLIGHT. This is a governed scope discovery, not a failure of the previous work."
$resultText = "Active Changes CHG-20260830-017 (row 80) scope amended: added Nexus.Developer.Infrastructure project + src/Nexus.Developer.Infrastructure/DevelopmentControl/ExcelDevelopmentControlStore.cs (single file). Workbook backup created; Nexus source unmodified; original Core-only reservation preserved."
$evidenceText = "Pre-amendment backup $BackupName; pre-write SHA256 $preHash; added-file baseline SHA256 6160C4FEA3185EC48701D2934C55D354B4780ECEDD7A2B2363D4AC16CE3D9A80; SCOPE_CHANGE_CLEAR; PARALLEL_SCOPE_CHECK PASS."

$alMap = @{
    "A" = $ActivityId; "B" = $ts; "C" = "Agent"
    "E" = "Claude Code (DevBridge)"; "F" = "DevBridge"
    "J" = $ChangeId; "L" = "Active Change Scope Amendment"
    "N" = "WI-07-0.2.4 | M-07-0.2"
    "U" = $reason
    "V" = "Nexus.Developer"
    "W" = $newProjects
    "X" = "feature/wi-07-0.2.4-concurrency-locking-and-atomic-writes (assigned); baseline branch feature/m-08-1-2-ci-pipeline"
    "Y" = "None"; "Z" = $newFilesGlobs
    "AA" = "SCOPE_CHANGE_CLEAR"
    "AB" = $resultText; "AC" = $evidenceText
    "AG" = "Not Reviewed"; "AH" = $ts
}
$rowAL = New-Row $alNextRow $alMap
Append-SheetRow $alDoc.Doc $rowAL
Update-Dimension $acDoc.Doc ("A1:AD{0}" -f $acNextRow)
Update-Dimension $alDoc.Doc ("A1:AH{0}" -f $alNextRow)

# ---------------------------------------------------------------------------
# Write temp -> validate -> promote
# ---------------------------------------------------------------------------
$tempPath = Join-Path (Split-Path $script:WorkbookPath -Parent) ("NEXUS_DEVELOPMENT_CONTROL.tmp{0}.xlsx" -f ([guid]::NewGuid().ToString("N").Substring(0,8)))
Write-WorkbookSheets $script:WorkbookPath $tempPath @{ $acDoc.Entry = $acDoc.Doc; $alDoc.Entry = $alDoc.Doc }

# Validate temp
$script:DevControlWorkbook = $tempPath
$tmpAC = @(Get-AllActiveChanges | Where-Object { $_.ChangeId -eq $ChangeId })
$tmpAL = @(Get-SheetRows "Activity Log" 4 5 300 | Where-Object { (Get-Value "Activity Log" $_ 4 "Activity ID") -eq $ActivityId })
$tmpOpen = Test-AllSheetsOpen
$script:DevControlWorkbook = $script:WorkbookPath

if ($tmpAC.Count -ne 1 -or $tmpAL.Count -ne 1 -or -not $tmpOpen) {
    Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
    Write-Output "AMEND_OUTCOME: AMEND_WRITE_FAILED"
    Write-Output "AMEND_MESSAGE: temp validation failed (ac=$($tmpAC.Count) al=$($tmpAL.Count) sheetsOpen=$tmpOpen). No write performed."
    Write-Output "AMEND_RESULT_PASS: False"
    exit 0
}

# Promote (replace canonical with validated temp) - governed write
[System.IO.File]::Copy($tempPath, $script:WorkbookPath, $true)
Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
$postHash = Get-FileSha256 $script:WorkbookPath
$script:DevControlWorkbook = $script:WorkbookPath

# ---------------------------------------------------------------------------
# PART 10 - read-back verification from disk (fresh)
# ---------------------------------------------------------------------------
$verify = New-Object System.Collections.Generic.List[string]
$liveAC2 = @(Get-AllActiveChanges | Where-Object { $_.ChangeId -eq $ChangeId })
$liveAL2 = @(Get-SheetRows "Activity Log" 4 5 300 | Where-Object { (Get-Value "Activity Log" $_ 4 "Activity ID") -eq $ActivityId })
$origAL = @(Get-SheetRows "Activity Log" 4 5 300 | Where-Object { (Get-Value "Activity Log" $_ 4 "Activity ID") -eq "ACT-20260830-018" })

if ($liveAC2.Count -ne 1) { $verify.Add("CHG-017 appears $($liveAC2.Count) times after write") }
if ($liveAL2.Count -ne 1) { $verify.Add("amendment event appears $($liveAL2.Count) times (expected once)") }
if ($origAL.Count -ne 1) { $verify.Add("original reservation event ACT-20260830-018 lost ($($origAL.Count))") }
if ($liveAC2.Count -eq 1) {
    $r = $liveAC2[0]
    if ($r.NodeId -notmatch "WI-07-0.2.4") { $verify.Add("node changed") }
    if ($r.Projects -notmatch "Nexus.Developer.Core" -or $r.Projects -notmatch "Nexus.Developer.Infrastructure") { $verify.Add("projects missing Core or Infrastructure: $($r.Projects)") }
    if ($r.FilesGlobs -notmatch "src/Nexus.Developer.Core/DevelopmentControl/\*\*") { $verify.Add("original Core glob lost: $($r.FilesGlobs)") }
    if ($r.FilesGlobs -notmatch [regex]::Escape("src/Nexus.Developer.Infrastructure/DevelopmentControl/ExcelDevelopmentControlStore.cs")) { $verify.Add("added file not present in Files/Globs") }
    if ($r.FilesGlobs -match "src/Nexus.Developer.Infrastructure/DevelopmentControl/\*\*") { $verify.Add("unapproved Infrastructure glob appeared") }
    if ($r.Status -notmatch "^Open") { $verify.Add("status not Open after write") }
    if ($r.ChangeId -ne $ChangeId) { $verify.Add("change id changed") }
}
# unrelated changes unchanged: CHG-016 still Completed
$chg016 = @(Get-AllActiveChanges | Where-Object { $_.ChangeId -eq "CHG-20260830-016" })
if ($chg016.Count -ne 1 -or $chg016[0].Status -notmatch "^Completed") { $verify.Add("CHG-016 status changed") }
# mappings valid: Active Changes headers present (normalized keys)
$acHeaders = Get-ColumnLetters (Open-DocEntry (Get-SheetEntryName "Active Changes")) 5 (Get-SheetEntryName "Active Changes")
if (-not $acHeaders.ContainsKey((Normalize-Header "Change ID")) -or -not $acHeaders.ContainsKey((Normalize-Header "Files / Globs"))) { $verify.Add("Active Changes headers invalid") }
# all 14 sheets open
if (-not (Test-AllSheetsOpen)) { $verify.Add("not all 14 sheets open") }

Write-Output "AMEND_OUTCOME: AMEND_DONE"
Write-Output ("AMEND_MESSAGE: row 80 amended; Activity Log row {0} appended" -f $alNextRow)
Write-Output ("AMEND_POSTHASH: " + $postHash)
if ($verify.Count -gt 0) {
    Write-Output ("AMEND_VERIFY_FAILED: {0}" -f ($verify -join " | "))
    Write-Output "AMEND_RESULT_PASS: False"
} else {
    Write-Output "AMEND_VERIFY: PASS"
    Write-Output "AMEND_RESULT_PASS: True"
}
exit 0
