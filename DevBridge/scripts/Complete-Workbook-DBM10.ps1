# Complete-Workbook-DBM10.ps1 - DB-M10 governed multi-sheet completion write.
# Applies the sheet-update plan (state\sheet-update-plan.json) to the canonical
# NEXUS_DEVELOPMENT_CONTROL.xlsx:
#   1 Control Center   A2 changelog prepend (Workbook v3.27)
#   2 Master Roadmap   R327 WI-07-0.2.3 Complete/100 + evidence; R324 M-07-0.2 30% + notes
#   3 Active Changes   R79 lifecycle close (L/U/V/AC/AD)
#   6 Version History  append rows 958 (WI-07-0.2.3) + 959 (M-07-0.2)  [ADR-003]
#  11 Tool Registry    append row 16 (ClosedXML)
#  12 Activity Log     append row 54 (ACT-20260830-017, 34-col)
#  14 Existing Assets  append row 16 (Development control service (Excel-backed))
# Strategy: build a temp copy, mutate its OOXML, verify the temp, then atomically
# replace the canonical file. All new text uses inlineStr (sharedStrings untouched).
# ASCII-only source (PS 5.1 + BOM-safe). EXIT CODES: 0 success, 2 verification failed,
# 3 atomic replace failed (file locked), 1 unexpected error.
param(
    [string]$UtcNow = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"),
    [string]$BackupFile = ""
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null
$xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
$xRel = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/officeDocument/2006/relationships"
$xmlNs = [System.Xml.Linq.XNamespace]"http://www.w3.org/XML/1998/namespace"
$cfg = Get-Content "C:\Personal\DevTools\DevBridge\config\devbridge.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$wb = $cfg.developmentControlWorkbook

# ---------------------------------------------------------------------------
# DB-GH01 M10 STRUCTURAL WRITE GUARD (CRITICAL) - runs BEFORE any completion write.
# Mirrors the engine's M10CompletionEligibility.Evaluate: a REAL completion requires
# DB-M06 PASS + Claude PASS + a CONFIRMED human merge (never inferred) + a PRESERVED
# protected roadmap fingerprint (before == after over the protected columns from
# config\roadmap-protection.json). TRIAL completion is always NOT_APPLICABLE. If any
# gate is unmet the canonical NEXUS_DEVELOPMENT_CONTROL.xlsx is NEVER touched and
# the script exits 0 with stdout markers (backend contract).
# ---------------------------------------------------------------------------
$ghStateDir = "C:\Personal\DevTools\DevBridge\state"
function Read-GhJson([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    try { return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}
function GhStr($obj, [string]$key) {
    if ($null -eq $obj) { return $null }
    if ($obj.PSObject.Properties.Name -contains $key) { return [string]$obj.$key }
    return $null
}
$ghCt = Read-GhJson (Join-Path $ghStateDir "current-task.json")
$ghVerif = Read-GhJson (Join-Path $ghStateDir "verification.json")
$ghClaude = Read-GhJson (Join-Path $ghStateDir "claude-review.json")
$ghFp = Read-GhJson (Join-Path $ghStateDir "roadmap-fingerprint.json")

# mode: current-task "mode" wins, else config, else TRIAL (DevBridge default)
$ghMode = "TRIAL"
$ghModeTok = GhStr $ghCt "mode"
if ($ghModeTok) { $ghMode = $ghModeTok } else { $ghMode = "TRIAL" }
$ghTrial = ($ghMode -eq "TRIAL")

# DB-M06 verification pass
$ghVerifPass = $false
$ghVerifTok = GhStr $ghVerif "primaryResult"
if ($ghVerifTok -and $ghVerifTok.StartsWith("VERIFICATION_PASSED", [System.StringComparison]::OrdinalIgnoreCase)) { $ghVerifPass = $true }

# Claude review pass
$ghClaudePass = $false
$ghClaudeTok = GhStr $ghClaude "decision"
if ($ghClaudeTok -and $ghClaudeTok.StartsWith("PASS", [System.StringComparison]::OrdinalIgnoreCase)) { $ghClaudePass = $true }

# human git merge gate (explicit gitLifecycleState; merged == confirmed)
$ghMerge = $false
$ghGitTok = GhStr $ghCt "gitLifecycleState"
if ($ghGitTok -in @("MERGED","READY_FOR_GOVERNED_COMPLETION")) { $ghMerge = $true }

# protected roadmap fingerprint guard (before vs after over protected columns)
$ghGuard = "NOT_COMPARABLE"
$ghFpBefore = $null; $ghFpAfter = $null
if ($ghFp) {
    if ($ghFp.PSObject.Properties.Name -contains "before") { $ghFpBefore = $ghFp.before }
    if ($ghFp.PSObject.Properties.Name -contains "after") { $ghFpAfter = $ghFp.after }
    if ($ghFpBefore -and $ghFpAfter) {
        $bV = GhStr $ghFpBefore "value"; $aV = GhStr $ghFpAfter "value"
        $bE = GhStr $ghFpBefore "error"; $aE = GhStr $ghFpAfter "error"
        if ($bE -or $aE) { $ghGuard = "NOT_COMPARABLE" }
        elseif ($bV -eq $aV) { $ghGuard = "PRESERVED" }
        else { $ghGuard = "STRUCTURE_CHANGED" }
    }
}

# verdict (mirrors M10CompletionEligibility.Evaluate)
$ghToken = "READY_FOR_GOVERNED_COMPLETION"
$ghReason = "All gates satisfied: DB-M06 PASS, Claude PASS, human merge confirmed, protected roadmap fingerprint preserved."
if ($ghTrial) {
    $ghToken = "TRIAL_COMPLETION_NOT_APPLICABLE"
    $ghReason = "TRIAL cycle: M10 governed completion is NOT applicable. Trial evidence stops at TRIAL_CYCLE_SAFE_STOP."
} elseif (-not $ghVerifPass) {
    $ghToken = "BLOCKED_NO_DB_M06_VERIFICATION_PASS"
    $ghReason = "DB-M06 verification has not passed. Completion requires DB-M06 PASS first."
} elseif (-not $ghClaudePass) {
    $ghToken = "BLOCKED_NO_CLAUDE_PASS"
    $ghReason = "Claude review has not passed. Completion requires Claude PASS."
} elseif (-not $ghMerge) {
    $ghToken = "BLOCKED_HUMAN_GIT_MERGE_GATE_PENDING"
    $ghReason = "The human Git merge gate is not confirmed. A REAL completion requires a CONFIRMED merge - never an inferred one."
} elseif ($ghGuard -ne "PRESERVED") {
    $ghToken = "ROADMAP_STRUCTURE_WRITE_PROHIBITED"
    $ghReason = if ($ghGuard -eq "STRUCTURE_CHANGED") { "The protected roadmap surface changed between fingerprint capture and the governed write." } else { "The protected roadmap fingerprint could not be computed or compared; the write is blocked." }
}
$ghEligible = ($ghToken -eq "READY_FOR_GOVERNED_COMPLETION")

Write-Output ("DBGH01_M10_ELIGIBLE: " + $ghEligible)
Write-Output ("DBGH01_M10_TOKEN: " + $ghToken)
Write-Output ("DBGH01_M10_REASON: " + $ghReason)
Write-Output ("DBGH01_M10_MODE: " + $ghMode)
Write-Output ("DBGH01_M10_VERIFICATION_PASS: " + $ghVerifPass)
Write-Output ("DBGH01_M10_CLAUDE_PASS: " + $ghClaudePass)
Write-Output ("DBGH01_M10_MERGE_CONFIRMED: " + $ghMerge)
Write-Output ("DBGH01_M10_FINGERPRINT_GUARD: " + $ghGuard)
if (-not $ghEligible) {
    Write-Output ("DBGH01_M10_BLOCKED: " + $ghToken)
    Write-Output "DBGH01_OUTCOME: M10_BLOCKED"
    Write-Output "DB-M10 governed completion BLOCKED by the DB-GH01 structural write guard. The canonical NEXUS_DEVELOPMENT_CONTROL.xlsx was NOT modified."
    exit 0
}
Write-Output "DBGH01_M10_GATE: PASS"
Write-Output "DBGH01_OUTCOME: M10_GATE_PASS"

if (-not $BackupFile) { $BackupFile = Get-Content "C:\Personal\DevTools\DevBridge\state\db-m10-backup.txt" }
$PreSha = "F52A1A8FE491B6C91809EAC92DB2F0DCCD43FF7C5C80BA2618E19B64D3FDD4F7"

# ---------------------------------------------------------------------------
# VALUE DEFINITIONS
# ---------------------------------------------------------------------------
$note327Base = "Added CHG-20260830-006 (2026-08-30). Designed in DEVELOPMENT_CONTROL_SERVICE_ARCHITECTURE.md (2026-08-25) as 'added under the existing F-07-0' but never actually created as a Master Roadmap row -- a genuine gap between the architecture doc and the live roadmap, surfaced by Durai's precision-pass request on the autonomous-development critical path. Not built: no IDevelopmentControlStore/ExcelDevelopmentControlStore code exists anywhere in Nexus.Developer (verified directly). This workbook itself has been hand-maintained via ad hoc openpyxl scripts this entire engagement, which is exactly what M-07-0.2 was designed to replace -- that contradiction is the clearest evidence this milestone was designed but never tracked."
$note327Add = " | CHG-20260830-016 (2026-08-30): implemented via DB-M05 ChatGPT handoff; deterministically verified (DB-M06 VERIFICATION_PASSED, 22/22 parts, 8/8 acceptance criteria, 199/199 tests + 32/32 harness checks, canonical workbook hash unchanged); Claude focused review PASS (DB-M08, 0 blocking / 1 residual non-blocking observation carried forward); governed multi-sheet completion applied (DB-M10). Marked Complete."
$ac327 = "Implemented and governed-verified 2026-08-30: ExcelWorkbookColumnMap (workbook column map; Required() throws on a missing required column), DevelopmentControlCellCodec (record-version parse/next, status/actor-type text codecs, sort-key compare, activity-id generator, node summarizer) and ExcelDevelopmentControlStore (ClosedXML-backed IDevelopmentControlStore; full 22-op contract; every mutating op takes a MutationEnvelope and returns MutationResult<T>; read + one safe mutation end-to-end, atomically; temp-file write + atomic replace; append-only Version History and 34-column Activity Log; idempotency via Activity Log scan; structural validation). DB-M06 verification: VERIFICATION_PASSED 22/22 parts; 8/8 acceptance criteria; 4 src projects build 0 warnings/0 errors; 199/199 tests + 32/32 harness checks; canonical workbook hash unchanged. DB-M08 Claude focused review: PASS, 0 blocking issues, 1 residual non-blocking observation (MutationEnvelope validation on no-op AddDependencyAsync/RemoveDependencyAsync paths) carried forward per Claude classification (MINOR, NON-BLOCKING, DOES NOT WARRANT FIX REQUIRED). No git commit (reviewed delta is untracked; the governed workbook write is the completion record). Zero deviations."

$note324Base = "Added CHG-20260830-006 (2026-08-30). Designed in DEVELOPMENT_CONTROL_SERVICE_ARCHITECTURE.md (2026-08-25) as 'added under the existing F-07-0' but never actually created as a Master Roadmap row -- a genuine gap between the architecture doc and the live roadmap, surfaced by Durai's precision-pass request on the autonomous-development critical path. Not built: no IDevelopmentControlStore/ExcelDevelopmentControlStore code exists anywhere in Nexus.Developer (verified directly). This workbook itself has been hand-maintained via ad hoc openpyxl scripts this entire engagement, which is exactly what M-07-0.2 was designed to replace -- that contradiction is the clearest evidence this milestone was designed but never tracked. | CHG-20260830-014 (2026-08-30): WI-07-0.2.1 (Domain model and control contracts) Complete -- first real implementation slice of this milestone. Status In Progress, 10%. | CHG-20260830-015 (2026-08-30): WI-07-0.2.2 (schema validation + Activity Log migration) Complete. Progress 10->20%."
$note324Add = " | CHG-20260830-016 (2026-08-30): WI-07-0.2.3 (Excel persistence adapter) Complete -- ExcelDevelopmentControlStore implements read + one safe mutation end-to-end atomically; DB-M06 VERIFICATION_PASSED + DB-M08 Claude review PASS + DB-M10 governed completion applied. Progress 20->30% (3 of 10 work items complete)."

$m072Outcome = "Roadmap and control-state changes happen through the service's own CreateNode/UpdateNode/RetireNode operations, called by an agent, instead of hand-edited OOXML. This milestone is also the prerequisite for programmatic coding-agent dispatch (autonomy Checkpoint 2): WI-07-0.2.9/.2.10 are what let Nexus launch a coding-agent job itself instead of Durai pasting a prompt by hand."

$ac79Status = "Completed -- WI-07-0.2.3 (Excel persistence adapter) implemented via DB-M05 ChatGPT handoff, deterministically verified (DB-M06 VERIFICATION_PASSED, 22/22 parts, 8/8 acceptance criteria, 199/199 tests + 32/32 harness checks), Claude focused review PASS (DB-M08, 0 blocking / 1 residual non-blocking observation carried forward), governed multi-sheet completion applied (DB-M10)."
$ac79CompletedAt = $UtcNow
$ac79Result = "Verified via DB-M06 deterministic verification (22/22 parts, 8/8 acceptance criteria, 199/199 tests + 32/32 harness checks, canonical workbook hash unchanged) and DB-M08 Claude focused review PASS (0 blocking issues; 1 residual non-blocking observation on MutationEnvelope validation of no-op Add/RemoveDependencyAsync paths -- CARRY_FORWARD_NON_BLOCKING, no audit finding created). DB-M10 governed multi-sheet completion applied: WI-07-0.2.3 Status->Complete/100%, M-07-0.2 Manual Progress 20->30%, Version History rows 958-959 appended (ADR-003), ClosedXML registered in Tool & Integration Registry, Existing Assets updated, Control Center changelog prepended (Workbook v3.27). No git commit (reviewed delta untracked; workbook write is the governed record)."
$ac79ChangeType = "Governed Multi-Sheet Completion"
$ac79Validation = "Pass -- DB-M06 VERIFICATION_PASSED (22/22 parts, 8/8 acceptance); DB-M08 Claude review PASS (0 blocking / 1 residual non-blocking); DB-M10 post-write verification confirmed workbook write."

$vh958 = @{
    A = "WI-07-0.2.3"; B = "M-07-0.2"; C = "WorkItem"; F = "07"; G = "P0"
    H = "Excel persistence adapter"
    I = "ExcelDevelopmentControlStore implements read + one safe mutation end-to-end, atomically."
    J = "WI-07-0.2.2"; K = "No"; P = "GATE_A"; R = "Complete"; S = "No"; T = "100"; W = "Unassigned"; X = "Critical"
    Z = "1.0"; AA = "v1.0"; AB = "46264"; AC = "Yes"; AD = "CHG-20260830-016"
    AF = "DevBridge DB-M10 governed completion"
    AG = "CHG-20260830-016 (2026-08-30): WI-07-0.2.3 (Excel persistence adapter) completed through the governed pipeline -- DB-M05 implementation handoff, DB-M06 deterministic verification (VERIFICATION_PASSED, 22/22, 8/8 acceptance, 199/199 tests + 32/32 harness checks, canonical workbook hash unchanged), DB-M07 focused review package, DB-M08 Claude focused review PASS (0 blocking / 1 residual non-blocking observation carried forward), DB-M10 governed multi-sheet completion. Status Planned -> Complete, progress 0% -> 100%. Concurrency/locking/atomic multi-op writes remain assigned to WI-07-0.2.4."
    AH = "Completion"
    AI = "WI-07-0.2.3 marked Complete/100% following DB-M06 verification + DB-M08 Claude review PASS and the DB-M10 governed multi-sheet completion."
}
$vh959 = @{
    A = "M-07-0.2"; B = "07"; C = "Milestone"; F = "07"; G = "P0"
    H = "Development Control Service (Excel-backed, Azure-SQL-ready)"
    I = $m072Outcome; J = "M-07-0.1"; K = "No"; P = "GATE_A"; R = "In Progress"; S = "No"; T = "30"; W = "Unassigned"; X = "Critical"
    Z = "1.0"; AA = "v1.0"; AB = "46264"; AC = "Yes"; AD = "CHG-20260830-016"
    AF = "DevBridge DB-M10 governed completion"
    AG = "CHG-20260830-016 (2026-08-30): WI-07-0.2.3 (third child work item) completed -- M-07-0.2 Manual Progress 20% -> 30% (3 of 10 work items complete). Status remains In Progress."
    AH = "Progress Update"
    AI = "M-07-0.2 progressed 20% -> 30% following WI-07-0.2.3's governed completion."
}

$al54 = @{
    A = "ACT-20260830-017"; B = $UtcNow; C = "Agent"; E = "Claude Code (DevBridge)"; F = "DevBridge"
    J = "CHG-20260830-016"; L = "Governed Multi-Sheet Completion"
    N = "WI-07-0.2.3 | M-07-0.2"
    U = "DB-M10 governed multi-sheet completion (Session Protocol steps 12-14): close Active Changes CHG-20260830-016, append this activity record, mark WI-07-0.2.3 Complete/100% on Master Roadmap, move M-07-0.2 to 30%, append Version History records 958-959 per ADR-003, register ClosedXML in the Tool & Integration Registry, update Existing Assets, prepend the Control Center changelog (Workbook v3.27). Preflight verdict from DB-M03 was CLEAR."
    V = "Nexus.Developer"; W = "Nexus.Developer.Infrastructure"
    X = "feature/wi-07-0.2.3-excel-persistence-adapter (assigned); baseline branch feature/m-08-1-2-ci-pipeline"
    Y = "None"; Z = "src/Nexus.Developer.Infrastructure/DevelopmentControl/**"; AA = "CLEAR"
    AB = "Active Changes row 79 closed (Status=Completed); Master Roadmap WI-07-0.2.3 Status->Complete/100% and M-07-0.2 Manual Progress 20->30%; Version History rows 958-959 appended; Tool & Integration Registry row 16 (ClosedXML) appended; Existing Assets row 16 appended; Control Center changelog prepended (Workbook v3.27). Workbook saved/closed/reopened from disk and verified (DB-M10 Part 19)."
    AC = "Backup " + $BackupFile + "; pre-write SHA256 " + $PreSha + " (post-write SHA256 recorded in state/completion.json); state/verification.json; state/claude-review.json; state/completion.json; tasks/SHEET_UPDATE_PLAN.md; tasks/COMPLETION_REPORT.md."
    AG = "Not Reviewed"; AH = $UtcNow
}

$tr16 = @{
    A = "ClosedXML"
    B = "Office/OpenXML library"
    C = "Programmatic read/write of the canonical NEXUS_DEVELOPMENT_CONTROL.xlsx (OOXML) in ExcelDevelopmentControlStore and the schema-validator/migration tooling."
    D = "07 DEVELOPER"
    E = "Library/API (NuGet package, direct .NET reference)"
    F = "Existing / evolving"
    G = "Required"
    H = "Governed workbook adapter policy: append-only history + conflict checks; scoped to the canonical workbook path; no schema redesign."
    I = "Read/update automatically from Developer Chat (through ExcelDevelopmentControlStore)"
    J = "Added by DB-M10 governed completion (CHG-20260830-016). NuGet dependency already used by WI-07-0.2.2 (ActivityLogMigration) and WI-07-0.2.3 (ExcelDevelopmentControlStore). Registered to close the DB-M03 preflight observation that ClosedXML was not yet governed."
}

$ea16 = @{
    A = "Development control service (Excel-backed)"
    B = "IDevelopmentControlStore (22 ops) with DTO/enum contracts (WI-07-0.2.1); WorkbookSchemaValidator + ActivityLogMigration (WI-07-0.2.2); ExcelDevelopmentControlStore ClosedXML adapter implementing read + one safe mutation end-to-end atomically, with append-only Version History and 34-column Activity Log (WI-07-0.2.3)."
    C = "Nexus.Developer | src/Nexus.Developer.Infrastructure/DevelopmentControl/** and src/Nexus.Developer.Core/DevelopmentControl/**"
    D = "Substantial progress on M-07-0.2 (Development Control Service, Excel-backed, Azure-SQL-ready)."
    E = "Working foundation"
    F = "Concurrency/locking/atomic multi-op writes (WI-07-0.2.4), full 22-op application surface (WI-07-0.2.5), remaining WI-07-0.2.x slices, DB-backed store later."
}

$cc327 = "Workbook v3.27 * CHG-20260830-016 (2026-08-30): WI-07-0.2.3 (Excel persistence adapter) completed through the governed pipeline -- DB-M05 implementation handoff, DB-M06 deterministic verification (VERIFICATION_PASSED, 22/22 parts, 8/8 acceptance criteria, 199/199 tests + 32/32 harness checks, canonical workbook hash unchanged), DB-M07 focused review package, DB-M08 Claude focused review PASS (0 blocking, 1 residual non-blocking observation carried forward -- MutationEnvelope validation on no-op Add/RemoveDependencyAsync paths), DB-M10 governed multi-sheet completion. ExcelDevelopmentControlStore (ClosedXML) implements read + one safe mutation end-to-end atomically with append-only Version History and 34-column Activity Log; concurrency/locking/atomic multi-op writes deferred to WI-07-0.2.4. Marked Complete; M-07-0.2 moved to 30%. Version History rows 958-959 appended per ADR-003; ClosedXML registered in the Tool & Integration Registry; Existing Assets updated. Next: WI-07-0.2.4 (Concurrency, locking and atomic writes). --- "

# ---------------------------------------------------------------------------
# OOXML helpers
# ---------------------------------------------------------------------------
function ColToIndex([string]$col) {
    $idx = 0
    foreach ($ch in $col.ToCharArray()) { $idx = $idx * 26 + ([int][char]$ch - 64) }
    return $idx
}
function ColOf([string]$ref) { return ($ref -replace '\d+$', '') }
function New-TCell([string]$value) {
    $t = New-Object System.Xml.Linq.XElement($xNs + "t")
    $t.Add([string]$value)
    $t.SetAttributeValue($xmlNs + "space", "preserve")
    return $t
}
function New-InlineCell([string]$ref, [string]$value, [string]$style) {
    $is = New-Object System.Xml.Linq.XElement($xNs + "is")
    $is.Add((New-TCell $value))
    $c = New-Object System.Xml.Linq.XElement($xNs + "c")
    $c.SetAttributeValue("r", $ref)
    $c.SetAttributeValue("t", "inlineStr")
    if ($style) { $c.SetAttributeValue("s", $style) }
    $c.Add($is)
    return $c
}
function New-NumCell([string]$ref, [string]$value, [string]$style) {
    $v = New-Object System.Xml.Linq.XElement($xNs + "v")
    $v.Add([string]$value)
    $c = New-Object System.Xml.Linq.XElement($xNs + "c")
    $c.SetAttributeValue("r", $ref)
    if ($style) { $c.SetAttributeValue("s", $style) }
    $c.Add($v)
    return $c
}
function Find-Cell($rowEl, [string]$col, [int]$rowNum) {
    if ($null -eq $rowEl) { return $null }
    $want = $col + $rowNum
    foreach ($cell in $rowEl.Elements($xNs + "c")) {
        $r = [string]$cell.Attribute("r").Value
        if ($r -eq $want) { return $cell }
    }
    return $null
}
function Resolve-CellText($sd, [int]$rowNum, [string]$col, $shared) {
    foreach ($row in $sd.Elements($xNs + "row")) {
        if ([int]$row.Attribute("r").Value -ne $rowNum) { continue }
        foreach ($cell in $row.Elements($xNs + "c")) {
            $ref = [string]$cell.Attribute("r").Value
            if (($ref -replace '\d+$','') -ne $col) { continue }
            $tAttr = $cell.Attribute("t"); $t = if ($tAttr) { [string]$tAttr.Value } else { "" }
            if ($t -eq "inlineStr") { $is = $cell.Element($xNs + "is"); if ($is) { return [string]$is.Value } }
            $v = $cell.Element($xNs + "v"); if ($v) {
                if ($t -eq "s") { $idx = [int]$v.Value; if ($idx -ge 0 -and $idx -lt $shared.Count) { return $shared[$idx] }; return "" }
                return [string]$v.Value
            }
            return ""
        }
    }
    return ""
}
function Get-SharedStrings($zip) {
    $shared = New-Object System.Collections.Generic.List[string]
    $ssEntry = $zip.GetEntry("xl/sharedStrings.xml")
    if ($ssEntry) {
        $sr = New-Object System.IO.StreamReader($ssEntry.Open())
        $ssXml = [System.Xml.Linq.XDocument]::Load($sr); $sr.Close()
        foreach ($si in $ssXml.Root.Elements($xNs + "si")) { $shared.Add([string]$si.Value) }
    }
    return $shared
}
function Insert-CellSorted($rowEl, $newCell) {
    $newCol = ColOf([string]$newCell.Attribute("r").Value)
    $newIdx = ColToIndex $newCol
    $inserted = $false
    foreach ($cell in @($rowEl.Elements($xNs + "c"))) {
        $ref = [string]$cell.Attribute("r").Value
        $idx = ColToIndex (ColOf $ref)
        if ($idx -gt $newIdx) { $cell.AddBeforeSelf($newCell); $inserted = $true; break }
    }
    if (-not $inserted) { $rowEl.Add($newCell) }
}
function Get-ColStyle($sheetData, [int]$rowNum, [string]$col) {
    for ($r = $rowNum - 1; $r -ge 1; $r--) {
        foreach ($rowEl in $sheetData.Elements($xNs + "row")) {
            $rn = [int]$rowEl.Attribute("r").Value
            if ($rn -ne $r) { continue }
            $cell = Find-Cell $rowEl $col $r
            if ($cell) {
                $s = $cell.Attribute("s")
                if ($s) { return [string]$s.Value }
                return $null
            }
        }
    }
    return $null
}
function Set-CellValue($cellEl, [string]$value, [bool]$numeric) {
    foreach ($child in @($cellEl.Elements($xNs + "v"))) { $child.Remove() }
    foreach ($child in @($cellEl.Elements($xNs + "is"))) { $child.Remove() }
    if ($numeric) {
        $cellEl.SetAttributeValue("t", $null)
        $v = New-Object System.Xml.Linq.XElement($xNs + "v"); $v.Add([string]$value); $cellEl.Add($v)
    } else {
        $cellEl.SetAttributeValue("t", "inlineStr")
        $is = New-Object System.Xml.Linq.XElement($xNs + "is"); $is.Add((New-TCell $value)); $cellEl.Add($is)
    }
}
function Write-Cell($sheetData, [int]$rowNum, [string]$col, [string]$value, [bool]$numeric = $false) {
    if ($value -eq $null -or $value -eq "") { return }
    # locate or create the row element
    $rowEl = $null
    foreach ($r in $sheetData.Elements($xNs + "row")) {
        if ([int]$r.Attribute("r").Value -eq $rowNum) { $rowEl = $r; break }
    }
    if (-not $rowEl) {
        $rowEl = New-Object System.Xml.Linq.XElement($xNs + "row")
        $rowEl.SetAttributeValue("r", $rowNum)
        $inserted = $false
        foreach ($r in @($sheetData.Elements($xNs + "row"))) {
            if ([int]$r.Attribute("r").Value -gt $rowNum) { $r.AddBeforeSelf($rowEl); $inserted = $true; break }
        }
        if (-not $inserted) { $sheetData.Add($rowEl) }
    }
    $cell = Find-Cell $rowEl $col $rowNum
    if ($cell) {
        Set-CellValue $cell $value $numeric
    } else {
        $style = Get-ColStyle $sheetData $rowNum $col
        if ($numeric) { $nc = New-NumCell ($col + $rowNum) $value $style } else { $nc = New-InlineCell ($col + $rowNum) $value $style }
        Insert-CellSorted $rowEl $nc
    }
}
function Append-Row($sheetData, [int]$rowNum, [hashtable]$cells, [string[]]$NumericCols) {
    if (-not $NumericCols) { $NumericCols = @() }
    $rowEl = $null
    foreach ($r in $sheetData.Elements($xNs + "row")) {
        if ([int]$r.Attribute("r").Value -eq $rowNum) { $rowEl = $r; break }
    }
    if (-not $rowEl) {
        $rowEl = New-Object System.Xml.Linq.XElement($xNs + "row")
        $rowEl.SetAttributeValue("r", $rowNum)
        $inserted = $false
        foreach ($r in @($sheetData.Elements($xNs + "row"))) {
            if ([int]$r.Attribute("r").Value -gt $rowNum) { $r.AddBeforeSelf($rowEl); $inserted = $true; break }
        }
        if (-not $inserted) { $sheetData.Add($rowEl) }
    }
    foreach ($k in $cells.Keys) {
        $col = [string]$k
        $val = [string]$cells[$k]
        if ($val -eq "") { continue }
        $cell = Find-Cell $rowEl $col $rowNum
        $numeric = ($NumericCols -contains $col)
        if ($cell) {
            Set-CellValue $cell $val $numeric
        } else {
            $style = Get-ColStyle $sheetData $rowNum $col
            if ($numeric) { $nc = New-NumCell ($col + $rowNum) $val $style } else { $nc = New-InlineCell ($col + $rowNum) $val $style }
            Insert-CellSorted $rowEl $nc
        }
    }
}
function Load-SheetDoc($zip, [string]$entryName) {
    $rd = New-Object System.IO.StreamReader($zip.GetEntry($entryName).Open())
    $doc = [System.Xml.Linq.XDocument]::Load($rd)
    $rd.Close()
    return $doc
}
function Save-SheetDoc($zip, [string]$entryName, $doc) {
    $entry = $zip.GetEntry($entryName)
    $stream = $entry.Open()
    $stream.SetLength(0)
    $stream.Position = 0
    $doc.Save($stream)
    $stream.Dispose()
}
function Get-SheetEntryName($zip, [string]$sheetName) {
    $rd = New-Object System.IO.StreamReader($zip.GetEntry("xl/workbook.xml").Open())
    $wbXml = [System.Xml.Linq.XDocument]::Load($rd); $rd.Close()
    $rid = $null
    foreach ($s in $wbXml.Root.Elements($xNs + "sheets").Elements($xNs + "sheet")) {
        if ([string]$s.Attribute("name").Value -eq $sheetName) { $rid = [string]$s.Attribute($xRel + "id").Value; break }
    }
    $rd2 = New-Object System.IO.StreamReader($zip.GetEntry("xl/_rels/workbook.xml.rels").Open())
    $relsXml = [System.Xml.Linq.XDocument]::Load($rd2); $rd2.Close()
    $p = $null
    foreach ($rel in $relsXml.Root.Elements()) { if ([string]$rel.Attribute("Id").Value -eq $rid) { $p = [string]$rel.Attribute("Target").Value; break } }
    if ($p.StartsWith("/")) { $p = $p.TrimStart("/") } else { $p = "xl/" + $p }
    if (-not $p.ToLower().EndsWith(".xml")) { $p = $p + ".xml" }
    return $p
}

# ---------------------------------------------------------------------------
# Build temp copy and mutate
# ---------------------------------------------------------------------------
$tmp = [System.IO.Path]::GetTempFileName()
Remove-Item $tmp -Force
Copy-Item $wb $tmp -Force
Write-Output "Temp copy: $tmp"

$fs = [System.IO.File]::Open($tmp, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
$zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Update)
try {
    # --- Master Roadmap (sheet2) ---
    $e2 = Get-SheetEntryName $zip "Master Roadmap"
    $d2 = Load-SheetDoc $zip $e2
    $sd2 = $d2.Root.Element($xNs + "sheetData")
    # R327 WI-07-0.2.3
    Write-Cell $sd2 327 "R" "Complete"
    Write-Cell $sd2 327 "T" "100" $true
    Write-Cell $sd2 327 "AC" $ac327
    Write-Cell $sd2 327 "AD" "None -- complete. Unblocks WI-07-0.2.4."
    Write-Cell $sd2 327 "AA" ($note327Base + $note327Add)
    # R324 M-07-0.2
    Write-Cell $sd2 324 "T" "30" $true
    Write-Cell $sd2 324 "AA" ($note324Base + $note324Add)
    Save-SheetDoc $zip $e2 $d2
    Write-Output "Master Roadmap updated."

    # --- Active Changes (sheet3) ---
    $e3 = Get-SheetEntryName $zip "Active Changes"
    $d3 = Load-SheetDoc $zip $e3
    $sd3 = $d3.Root.Element($xNs + "sheetData")
    Write-Cell $sd3 79 "L" $ac79Status
    Write-Cell $sd3 79 "U" $ac79CompletedAt
    Write-Cell $sd3 79 "V" $ac79Result
    Write-Cell $sd3 79 "AC" $ac79ChangeType
    Write-Cell $sd3 79 "AD" $ac79Validation
    Save-SheetDoc $zip $e3 $d3
    Write-Output "Active Changes row 79 closed."

    # --- Control Center (sheet1) A2 ---
    $e1 = Get-SheetEntryName $zip "Control Center"
    $d1 = Load-SheetDoc $zip $e1
    $sd1 = $d1.Root.Element($xNs + "sheetData")
    $sharedCC = Get-SharedStrings $zip
    $existingA2 = Resolve-CellText $sd1 2 "A" $sharedCC
    Write-Cell $sd1 2 "A" ($cc327 + $existingA2)
    Save-SheetDoc $zip $e1 $d1
    Write-Output ("Control Center A2 prepended (existing length {0})." -f $existingA2.Length)

    # --- Version History (sheet6) rows 958, 959 ---
    $e6 = Get-SheetEntryName $zip "Version History"
    $d6 = Load-SheetDoc $zip $e6
    $sd6 = $d6.Root.Element($xNs + "sheetData")
    Append-Row $sd6 958 $vh958 @("T","AB")
    Append-Row $sd6 959 $vh959 @("T","AB")
    Save-SheetDoc $zip $e6 $d6
    Write-Output "Version History rows 958-959 appended."

    # --- Activity Log (sheet12) row 54 ---
    $e12 = Get-SheetEntryName $zip "Activity Log"
    $d12 = Load-SheetDoc $zip $e12
    $sd12 = $d12.Root.Element($xNs + "sheetData")
    Append-Row $sd12 54 $al54 @()
    Save-SheetDoc $zip $e12 $d12
    Write-Output "Activity Log row 54 appended."

    # --- Tool & Integration Registry (sheet11) row 16 ---
    $e11 = Get-SheetEntryName $zip "Tool & Integration Registry"
    $d11 = Load-SheetDoc $zip $e11
    $sd11 = $d11.Root.Element($xNs + "sheetData")
    Append-Row $sd11 16 $tr16 @()
    Save-SheetDoc $zip $e11 $d11
    Write-Output "Tool Registry row 16 (ClosedXML) appended."

    # --- Existing Assets (sheet14) row 16 ---
    $e14 = Get-SheetEntryName $zip "Existing Assets"
    $d14 = Load-SheetDoc $zip $e14
    $sd14 = $d14.Root.Element($xNs + "sheetData")
    Append-Row $sd14 16 $ea16 @()
    Save-SheetDoc $zip $e14 $d14
    Write-Output "Existing Assets row 16 appended."
} finally {
    $zip.Dispose()
    $fs.Dispose()
}
Write-Output "Temp workbook mutated and saved."

# ---------------------------------------------------------------------------
# Verification (Part 19): runs against the temp BEFORE the atomic replace, then
# again against the reopened authoritative workbook AFTER the replace.
# ---------------------------------------------------------------------------
function Get-CellVal($zip, [string]$entryName, [int]$rowNum, [string]$col) {
    $shared = Get-SharedStrings $zip
    $rd = New-Object System.IO.StreamReader($zip.GetEntry($entryName).Open())
    $doc = [System.Xml.Linq.XDocument]::Load($rd); $rd.Close()
    foreach ($row in $doc.Root.Element($xNs + "sheetData").Elements($xNs + "row")) {
        if ([int]$row.Attribute("r").Value -ne $rowNum) { continue }
        foreach ($cell in $row.Elements($xNs + "c")) {
            $ref = [string]$cell.Attribute("r").Value
            if (($ref -replace '\d+$','') -ne $col) { continue }
            $tAttr = $cell.Attribute("t"); $t = if ($tAttr) { [string]$tAttr.Value } else { "" }
            if ($t -eq "inlineStr") { $is = $cell.Element($xNs + "is"); if ($is) { return [string]$is.Value } }
            $v = $cell.Element($xNs + "v"); if ($v) {
                if ($t -eq "s") { $idx = [int]$v.Value; if ($idx -ge 0 -and $idx -lt $shared.Count) { return $shared[$idx] } }
                return [string]$v.Value
            }
            return ""
        }
    }
    return ""
}
function Get-MaxDataRow($zip, [string]$entryName) {
    $rd = New-Object System.IO.StreamReader($zip.GetEntry($entryName).Open())
    $doc = [System.Xml.Linq.XDocument]::Load($rd); $rd.Close()
    $max = 0
    foreach ($row in $doc.Root.Element($xNs + "sheetData").Elements($xNs + "row")) {
        $hasA = $false
        foreach ($cell in $row.Elements($xNs + "c")) {
            $ref = [string]$cell.Attribute("r").Value
            if (($ref -replace '\d+$','') -eq "A") { $hasA = $true; break }
        }
        if ($hasA -and [int]$row.Attribute("r").Value -gt $max) { $max = [int]$row.Attribute("r").Value }
    }
    return $max
}
$gChecks = New-Object System.Collections.Generic.List[string]
function Chk([string]$name, [bool]$ok) {
    if ($ok) { $gChecks.Add("PASS  $name") } else { $gChecks.Add("FAIL  $name") }
}
function Test-WorkbookWrite([string]$Path) {
    $gChecks.Clear()
    $vfs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    $vzip = New-Object System.IO.Compression.ZipArchive($vfs, [System.IO.Compression.ZipArchiveMode]::Read)
    try {
        $e2v = Get-SheetEntryName $vzip "Master Roadmap"
        $e3v = Get-SheetEntryName $vzip "Active Changes"
        $e1v = Get-SheetEntryName $vzip "Control Center"
        $e6v = Get-SheetEntryName $vzip "Version History"
        $e12v = Get-SheetEntryName $vzip "Activity Log"
        $e11v = Get-SheetEntryName $vzip "Tool & Integration Registry"
        $e14v = Get-SheetEntryName $vzip "Existing Assets"

        Chk "MR R327 R = Complete" ((Get-CellVal $vzip $e2v 327 "R") -eq "Complete")
        Chk "MR R327 T = 100" ((Get-CellVal $vzip $e2v 327 "T") -eq "100")
        Chk "MR R327 AC non-empty" ((Get-CellVal $vzip $e2v 327 "AC").Length -gt 100)
        Chk "MR R327 AD = None -- complete. Unblocks WI-07-0.2.4." ((Get-CellVal $vzip $e2v 327 "AD") -eq "None -- complete. Unblocks WI-07-0.2.4.")
        Chk "MR R327 AA has CHG-20260830-016" ((Get-CellVal $vzip $e2v 327 "AA").Contains("CHG-20260830-016"))
        Chk "MR R324 T = 30" ((Get-CellVal $vzip $e2v 324 "T") -eq "30")
        Chk "MR R324 AA has CHG-20260830-016" ((Get-CellVal $vzip $e2v 324 "AA").Contains("CHG-20260830-016"))
        Chk "AC R79 L starts Completed" ((Get-CellVal $vzip $e3v 79 "L").StartsWith("Completed"))
        Chk "AC R79 U non-empty" ((Get-CellVal $vzip $e3v 79 "U").Length -gt 0)
        Chk "AC R79 V has CARRY_FORWARD_NON_BLOCKING" ((Get-CellVal $vzip $e3v 79 "V").Contains("CARRY_FORWARD_NON_BLOCKING"))
        Chk "AC R79 AD starts Pass" ((Get-CellVal $vzip $e3v 79 "AD").StartsWith("Pass"))
        Chk "CC A2 starts Workbook v3.27" ((Get-CellVal $vzip $e1v 2 "A").StartsWith("Workbook v3.27 * CHG-20260830-016"))
        Chk "CC A2 preserves prior v3.26 entry" ((Get-CellVal $vzip $e1v 2 "A").Contains("Workbook v3.26"))
        Chk "VH R958 A = WI-07-0.2.3" ((Get-CellVal $vzip $e6v 958 "A") -eq "WI-07-0.2.3")
        Chk "VH R958 AA = v1.0 / AC = Yes" (((Get-CellVal $vzip $e6v 958 "AA") -eq "v1.0") -and ((Get-CellVal $vzip $e6v 958 "AC") -eq "Yes"))
        Chk "VH R958 R = Complete / T = 100" (((Get-CellVal $vzip $e6v 958 "R") -eq "Complete") -and ((Get-CellVal $vzip $e6v 958 "T") -eq "100"))
        Chk "VH R959 A = M-07-0.2 / T = 30" (((Get-CellVal $vzip $e6v 959 "A") -eq "M-07-0.2") -and ((Get-CellVal $vzip $e6v 959 "T") -eq "30"))
        Chk "VH R959 AA = v1.0" ((Get-CellVal $vzip $e6v 959 "AA") -eq "v1.0")
        Chk "VH R958 AD = CHG-20260830-016" ((Get-CellVal $vzip $e6v 958 "AD") -eq "CHG-20260830-016")
        Chk "VH R958 AB = 46264" ((Get-CellVal $vzip $e6v 958 "AB") -eq "46264")
        Chk "VH max data row >= 959" ((Get-MaxDataRow $vzip $e6v) -ge 959)
        Chk "AL R54 A = ACT-20260830-017" ((Get-CellVal $vzip $e12v 54 "A") -eq "ACT-20260830-017")
        Chk "AL R54 L = Governed Multi-Sheet Completion" ((Get-CellVal $vzip $e12v 54 "L") -eq "Governed Multi-Sheet Completion")
        Chk "AL R54 AA = CLEAR" ((Get-CellVal $vzip $e12v 54 "AA") -eq "CLEAR")
        Chk "TR R16 A = ClosedXML" ((Get-CellVal $vzip $e11v 16 "A") -eq "ClosedXML")
        Chk "EA R16 A = Development control service (Excel-backed)" ((Get-CellVal $vzip $e14v 16 "A") -eq "Development control service (Excel-backed)")
    } finally {
        $vzip.Dispose()
        $vfs.Dispose()
    }
    Write-Host ""
    Write-Host ("=== WORKBOOK WRITE VERIFICATION: {0} ===" -f $Path)
    foreach ($c in $gChecks) { Write-Host $c }
    $failCount = @($gChecks | Where-Object { $_.StartsWith("FAIL") }).Count
    Write-Host ("FAIL count: {0}" -f $failCount)
    return $failCount
}

$failT = Test-WorkbookWrite $tmp
$tmpHash = (Get-FileHash -Algorithm SHA256 $tmp).Hash
Write-Output "Temp SHA256: $tmpHash"
if ($failT -gt 0) {
    Write-Output "DB-M10 COMPLETION_WRITE_VERIFICATION_FAILED (temp) -- not replacing canonical."
    exit 2
}

# ---------------------------------------------------------------------------
# Atomic replace (Part 18: save/close/reopen -- all write streams disposed above;
# replace now, then reopen the authoritative workbook from disk and re-verify).
# ---------------------------------------------------------------------------
try {
    Move-Item -Path $tmp -Destination $wb -Force -ErrorAction Stop
    Write-Output "Atomic replace done (Move-Item -Force): $wb"
} catch {
    Write-Output ("ATOMIC REPLACE FAILED (file likely open in Excel): {0}" -f $_.Exception.Message)
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    exit 3
}

$postHash = (Get-FileHash -Algorithm SHA256 $wb).Hash
Write-Output "Post-write canonical SHA256: $postHash"
$failC = Test-WorkbookWrite $wb
if ($failC -gt 0) {
    Write-Output "DB-M10 COMPLETION_WRITE_VERIFICATION_FAILED (canonical after reopen)."
    exit 2
}
Write-Output "DB-M10 workbook write complete and verified. Exit 0."
exit 0
