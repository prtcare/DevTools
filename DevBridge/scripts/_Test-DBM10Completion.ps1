# _Test-DBM10Completion.ps1 - DB-M10 Part 24: 12 local tests (NO paid AI calls).
# Read-only. Verifies the governed completion write on the authoritative workbook
# and the DevBridge state. Exit 0 all pass; exit 1 any fail.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null
$xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
$xRel = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/officeDocument/2006/relationships"
$cfg = Get-Content "C:\Personal\DevTools\DevBridge\config\devbridge.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$wb = $cfg.developmentControlWorkbook
$results = New-Object System.Collections.Generic.List[string]
$fail = 0

function T([string]$name, [bool]$ok) {
    if ($ok) { $results.Add("PASS  $name") } else { $results.Add("FAIL  $name"); $script:fail++ }
}

# DB-GH01 preamble: the historical governed completion (CHG-20260830-016) is
# evidence to be PRESERVED, and re-running M10 must now be BLOCKED by the DB-GH01
# structural write guard. DevBridge runs in TRIAL mode, so the gate must report
# TRIAL_COMPLETION_NOT_APPLICABLE and never permit a second completion write.
$eligOut = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Test-DBM10CompletionEligibility.ps1") 2>&1)
$eligOut = @($eligOut | ForEach-Object { "$_" })
$eligTokenLine = $eligOut | Select-String -Pattern '^DBGH01_M10_TOKEN:' | Select-Object -First 1
$eligToken = if ($eligTokenLine) { $eligTokenLine.Line -replace '^DBGH01_M10_TOKEN:\s*', '' } else { "NO_TOKEN" }
T "GH1 M10 gate blocks re-completion in TRIAL (TRIAL_COMPLETION_NOT_APPLICABLE)" ($eligToken -eq "TRIAL_COMPLETION_NOT_APPLICABLE")

function Open-Zip($path) {
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
    return @($zip, $fs)
}
function Get-SheetEntry($zip, [string]$sheetName) {
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
function Get-CellVal($zip, $entry, [int]$rowNum, [string]$col) {
    $shared = New-Object System.Collections.Generic.List[string]
    $ssEntry = $zip.GetEntry("xl/sharedStrings.xml")
    if ($ssEntry) {
        $sr = New-Object System.IO.StreamReader($ssEntry.Open())
        $ssXml = [System.Xml.Linq.XDocument]::Load($sr); $sr.Close()
        foreach ($si in $ssXml.Root.Elements($xNs + "si")) { $shared.Add([string]$si.Value) }
    }
    $rd = New-Object System.IO.StreamReader($zip.GetEntry($entry).Open())
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
function Find-AuditFinding($zip, $entry, [string]$needle) {
    $shared = New-Object System.Collections.Generic.List[string]
    $ssEntry = $zip.GetEntry("xl/sharedStrings.xml")
    if ($ssEntry) {
        $sr = New-Object System.IO.StreamReader($ssEntry.Open())
        $ssXml = [System.Xml.Linq.XDocument]::Load($sr); $sr.Close()
        foreach ($si in $ssXml.Root.Elements($xNs + "si")) { $shared.Add([string]$si.Value) }
    }
    $rd = New-Object System.IO.StreamReader($zip.GetEntry($entry).Open())
    $doc = [System.Xml.Linq.XDocument]::Load($rd); $rd.Close()
    foreach ($row in $doc.Root.Element($xNs + "sheetData").Elements($xNs + "row")) {
        foreach ($cell in $row.Elements($xNs + "c")) {
            $tAttr = $cell.Attribute("t"); $t = if ($tAttr) { [string]$tAttr.Value } else { "" }
            $val = ""
            if ($t -eq "inlineStr") { $is = $cell.Element($xNs + "is"); if ($is) { $val = [string]$is.Value } }
            else { $v = $cell.Element($xNs + "v"); if ($v) { if ($t -eq "s") { $idx = [int]$v.Value; if ($idx -ge 0 -and $idx -lt $shared.Count) { $val = $shared[$idx] } } else { $val = [string]$v.Value } } }
            if ($val -and $val.Contains($needle)) { return $true }
        }
    }
    return $false
}

$pre = "F52A1A8FE491B6C91809EAC92DB2F0DCCD43FF7C5C80BA2618E19B64D3FDD4F7"
$post = (Get-FileHash -Algorithm SHA256 $wb).Hash

$ctx = Open-Zip $wb
$zip = $ctx[0]; $fs = $ctx[1]
try {
    $eMR = Get-SheetEntry $zip "Master Roadmap"
    $eAC = Get-SheetEntry $zip "Active Changes"
    $eCC = Get-SheetEntry $zip "Control Center"
    $eVH = Get-SheetEntry $zip "Version History"
    $eAL = Get-SheetEntry $zip "Activity Log"
    $eTR = Get-SheetEntry $zip "Tool & Integration Registry"
    $eEA = Get-SheetEntry $zip "Existing Assets"
    $eAF = Get-SheetEntry $zip "Audit Findings"

    # T1 hash changed
    T "T1 Workbook SHA256 changed pre->post (pre F52A1A8F.., post $($post.Substring(0,8))..)" ($post -ne $pre)
    # T2 AC row 79 terminal
    T "T2 Active Changes row 79 Status starts 'Completed' (Terminal)" ((Get-CellVal $zip $eAC 79 "L").StartsWith("Completed"))
    # T3 MR R327
    T "T3 Master Roadmap R327 Status=Complete and Manual Progress=100" (((Get-CellVal $zip $eMR 327 "R") -eq "Complete") -and ((Get-CellVal $zip $eMR 327 "T") -eq "100"))
    # T4 MR R324
    T "T4 Master Roadmap R324 Manual Progress=30" ((Get-CellVal $zip $eMR 324 "T") -eq "30")
    # T5 VH 958/959
    $vh958ok = (((Get-CellVal $zip $eVH 958 "A") -eq "WI-07-0.2.3") -and ((Get-CellVal $zip $eVH 958 "AA") -eq "v1.0") -and ((Get-CellVal $zip $eVH 958 "AC") -eq "Yes") -and ((Get-CellVal $zip $eVH 958 "AB") -eq "46264") -and ((Get-CellVal $zip $eVH 958 "AD") -eq "CHG-20260830-016"))
    $vh959ok = (((Get-CellVal $zip $eVH 959 "A") -eq "M-07-0.2") -and ((Get-CellVal $zip $eVH 959 "AA") -eq "v1.0") -and ((Get-CellVal $zip $eVH 959 "AC") -eq "Yes") -and ((Get-CellVal $zip $eVH 959 "AB") -eq "46264") -and ((Get-CellVal $zip $eVH 959 "AD") -eq "CHG-20260830-016"))
    T "T5 Version History rows 958/959 (AA=v1.0, AC=Yes, AB=46264, AD=CHG-20260830-016)" ($vh958ok -and $vh959ok)
    # T6 AL row 54
    $al54ok = (((Get-CellVal $zip $eAL 54 "A") -eq "ACT-20260830-017") -and ((Get-CellVal $zip $eAL 54 "L") -eq "Governed Multi-Sheet Completion") -and ((Get-CellVal $zip $eAL 54 "J") -eq "CHG-20260830-016") -and ((Get-CellVal $zip $eAL 54 "AA") -eq "CLEAR"))
    T "T6 Activity Log row 54 ACT-20260830-017 / Operation / Change ID / Preflight CLEAR" $al54ok
    # T7 TR row 16
    T "T7 Tool & Integration Registry row 16 = ClosedXML" ((Get-CellVal $zip $eTR 16 "A") -eq "ClosedXML")
    # T8 EA row 16
    T "T8 Existing Assets row 16 = Development control service (Excel-backed)" ((Get-CellVal $zip $eEA 16 "A") -eq "Development control service (Excel-backed)")
    # T9 CC A2
    $a2 = Get-CellVal $zip $eCC 2 "A"
    T "T9 Control Center A2 starts Workbook v3.27 and preserves v3.26 entry" ($a2.StartsWith("Workbook v3.27 * CHG-20260830-016") -and $a2.Contains("Workbook v3.26"))
    # T10 Audit Findings unchanged
    T "T10 Audit Findings has no new record for the residual (no MutationEnvelope / CHG-20260830-016 reference)" ((-not (Find-AuditFinding $zip $eAF "MutationEnvelope")) -and (-not (Find-AuditFinding $zip $eAF "CHG-20260830-016")))
} finally {
    $zip.Dispose(); $fs.Dispose()
}

# T11 state
$ct = Get-Content "C:\Personal\DevTools\DevBridge\state\current-task.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$cj = Get-Content "C:\Personal\DevTools\DevBridge\state\completion.json" -Raw -Encoding UTF8 | ConvertFrom-Json
T "T11 state/current-task.json status=COMPLETION_WRITTEN, nextAllowedAction=WORKBOOK_CONSISTENCY_VALIDATION" (($ct.status -eq "COMPLETION_WRITTEN") -and ($ct.nextAllowedAction -eq "WORKBOOK_CONSISTENCY_VALIDATION"))
T "T11b state/completion.json exists with workbookHashAfter matching live workbook" ($cj.workbookSha256After -eq $post)

# T12 idempotency detection (re-entry would return COMPLETION_ALREADY_WRITTEN)
$ctx2 = Open-Zip $wb
$zip2 = $ctx2[0]; $fs2 = $ctx2[1]
try {
    $eMR2 = Get-SheetEntry $zip2 "Master Roadmap"
    $eVH2 = Get-SheetEntry $zip2 "Version History"
    $already = (($ct.status -eq "COMPLETION_WRITTEN") -and ((Get-CellVal $zip2 $eMR2 327 "R") -eq "Complete") -and ((Get-CellVal $zip2 $eVH2 958 "A") -eq "WI-07-0.2.3"))
    T "T12 Idempotency: re-entry detects COMPLETION_ALREADY_WRITTEN" $already
} finally {
    $zip2.Dispose(); $fs2.Dispose()
}

foreach ($r in $results) { Write-Host $r }
Write-Host ("FAIL count: {0}" -f $fail)
if ($fail -gt 0) { exit 1 }
Write-Host ("DB-M10 Part 24 tests: ALL {0} PASS. Exit 0." -f $results.Count)
exit 0
