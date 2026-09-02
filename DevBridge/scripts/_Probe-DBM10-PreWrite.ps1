# _Probe-DBM10-PreWrite.ps1 - READ-ONLY. Gathers every convention and before-value needed
# by DB-M10 (Governed Multi-Sheet Completion): Master Roadmap rows for the M-07-0.2 family,
# Architecture Decisions (ADR-003), Development Guide mirror check, Control Center narrative,
# Existing Assets, Tool & Integration Registry, Active Changes row 79, Activity Log tail,
# Version History tail, and last-row bookkeeping for every append target.
# ASCII-only (PS 5.1 + BOM-safe). No workbook modification.
param(
    [string]$OutFile = "C:\Personal\DevTools\DevBridge\state\db-m10-prewrite.txt"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null
$xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
$xRel = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/officeDocument/2006/relationships"
$cfg = Get-Content "C:\Personal\DevTools\DevBridge\config\devbridge.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$wb = $cfg.developmentControlWorkbook

$sb = New-Object System.Text.StringBuilder
function Out-Line([string]$t) { [void]$sb.AppendLine($t) }

function Open-Zip {
    $fs = [System.IO.File]::Open($wb, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
    return @($fs, $zip)
}

function Read-SheetMap {
    $pairs = @{}
    $fs, $zip = Open-Zip
    try {
        $rd = New-Object System.IO.StreamReader($zip.GetEntry("xl/workbook.xml").Open())
        $wbXml = [System.Xml.Linq.XDocument]::Load($rd); $rd.Close()
        foreach ($s in $wbXml.Root.Elements($xNs + "sheets").Elements($xNs + "sheet")) {
            $pairs[[string]$s.Attribute("name").Value] = [string]$s.Attribute($xRel + "id").Value
        }
        $rd2 = New-Object System.IO.StreamReader($zip.GetEntry("xl/_rels/workbook.xml.rels").Open())
        $relsXml = [System.Xml.Linq.XDocument]::Load($rd2); $rd2.Close()
        $targets = @{}
        foreach ($rel in $relsXml.Root.Elements()) {
            $targets[[string]$rel.Attribute("Id").Value] = [string]$rel.Attribute("Target").Value
        }
        $result = @{}
        foreach ($name in $pairs.Keys) {
            $p = $targets[$pairs[$name]]
            if ($p.StartsWith("/")) { $p = $p.TrimStart("/") } else { $p = "xl/" + $p }
            if (-not $p.ToLower().EndsWith(".xml")) { $p = $p + ".xml" }
            $result[$name] = $p
        }
        return $result
    } finally { $zip.Dispose(); $fs.Dispose() }
}

function Get-Shared {
    $fs, $zip = Open-Zip
    try {
        $shared = New-Object System.Collections.Generic.List[string]
        $ssEntry = $zip.GetEntry("xl/sharedStrings.xml")
        if ($ssEntry) {
            $sr = New-Object System.IO.StreamReader($ssEntry.Open())
            $ssXml = [System.Xml.Linq.XDocument]::Load($sr); $sr.Close()
            foreach ($si in $ssXml.Root.Elements($xNs + "si")) { $shared.Add([string]$si.Value) }
        }
        return ,$shared
    } finally { $zip.Dispose(); $fs.Dispose() }
}

function Get-SheetRows([string]$sheetName) {
    $fs, $zip = Open-Zip
    try {
        $shared = Get-Shared
        $map = Read-SheetMap
        $rd = New-Object System.IO.StreamReader($zip.GetEntry($map[$sheetName]).Open())
        $sheetXml = [System.Xml.Linq.XDocument]::Load($rd); $rd.Close()
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($row in $sheetXml.Root.Elements($xNs + "sheetData").Elements($xNs + "row")) {
            $rNum = [int]$row.Attribute("r").Value
            $cellMap = @{}
            foreach ($cell in $row.Elements($xNs + "c")) {
                $refAttr = $cell.Attribute("r"); if (-not $refAttr) { continue }
                $ref = [string]$refAttr.Value
                $letter = $ref -replace '\d+$', ''
                $tAttr = $cell.Attribute("t"); $t = if ($tAttr) { [string]$tAttr.Value } else { "" }
                $val = ""
                if ($t -eq "inlineStr") { $is = $cell.Element($xNs + "is"); if ($is) { $val = [string]$is.Value } }
                else {
                    $v = $cell.Element($xNs + "v"); if ($v) {
                        if ($t -eq "s") { $idx = [int]$v.Value; if ($idx -ge 0 -and $idx -lt $shared.Count) { $val = $shared[$idx] } else { $val = "[missing-shared:$idx]" } }
                        else { $val = [string]$v.Value }
                    }
                }
                $cellMap[$letter] = $val.Trim()
            }
            $rows.Add([pscustomobject]@{ Row = $rNum; Cells = $cellMap })
        }
        return ,$rows
    } finally { $zip.Dispose(); $fs.Dispose() }
}

function Get-Cell($row, [string]$col) {
    if ($row.Cells.ContainsKey($col)) { return $row.Cells[$col] }
    return ""
}

function Dump-Row($row, [string[]]$cols, [string]$label) {
    $parts = @()
    foreach ($c in $cols) { $parts += ("{0}=[{1}]" -f $c, (Get-Cell $row $c)) }
    Out-Line ("  {0} R{1}: {2}" -f $label, $row.Row, ($parts -join " "))
}

$map = Read-SheetMap
Out-Line "=== SHEET TARGETS ==="
foreach ($k in ($map.Keys | Sort-Object)) { Out-Line ("  {0} -> {1}" -f $k, $map[$k]) }

# ---- Master Roadmap ----
$mrCols = @("A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z","AA","AB","AC","AD","AE","AF","AG")
$mrRows = Get-SheetRows "Master Roadmap"
Out-Line ""
Out-Line "=== MASTER ROADMAP: M-07-0.2 family (full A..AG) ==="
foreach ($r in $mrRows) {
    $nid = Get-Cell $r "A"
    if ($nid -in @("M-07-0.2","WI-07-0.2.1","WI-07-0.2.2","WI-07-0.2.3","WI-07-0.2.4","WI-07-0.2.5","F-07-0")) {
        Dump-Row $r $mrCols "MR"
    }
}
$maxMrRow = 0
foreach ($r in $mrRows) { if ((Get-Cell $r "A") -ne "" -and $r.Row -gt $maxMrRow) { $maxMrRow = $r.Row } }
Out-Line ("  Master Roadmap max data row (non-empty A): {0}" -f $maxMrRow)

# ---- Version History ----
$vhCols = @("A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z","AA","AB","AC","AD","AE","AF","AG","AH","AI","AJ")
$vhRows = Get-SheetRows "Version History"
Out-Line ""
Out-Line "=== VERSION HISTORY tail (last 6 data rows, full A..AJ) ==="
$vhData = @($vhRows | Where-Object { (Get-Cell $_ "A") -ne "" })
foreach ($r in ($vhData | Select-Object -Last 6)) { Dump-Row $r $vhCols "VH" }
Out-Line ("  Version History records: {0}; max data row: {1}" -f $vhData.Count, $vhData[$vhData.Count-1].Row)
$m072 = @($vhData | Where-Object { (Get-Cell $_ "A") -eq "M-07-0.2" })
Out-Line ("  M-07-0.2 records in Version History: {0}" -f $m072.Count)

# ---- Active Changes ----
$acCols = @("A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z","AA","AB","AC","AD")
$acRows = Get-SheetRows "Active Changes"
Out-Line ""
Out-Line "=== ACTIVE CHANGES row 79 (CHG-20260830-016, full A..AD) ==="
foreach ($r in $acRows) { if ((Get-Cell $r "A") -eq "CHG-20260830-016") { Dump-Row $r $acCols "AC" } }
$maxAcRow = 0
foreach ($r in $acRows) { if ((Get-Cell $r "A") -ne "" -and $r.Row -gt $maxAcRow) { $maxAcRow = $r.Row } }
Out-Line ("  Active Changes max data row (non-empty A): {0}" -f $maxAcRow)

# ---- Activity Log ----
$alCols = @("A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z","AA","AB","AC","AD","AE","AF","AG","AH")
$alRows = Get-SheetRows "Activity Log"
Out-Line ""
Out-Line "=== ACTIVITY LOG tail (last 2 data rows, full A..AH) ==="
$alData = @($alRows | Where-Object { (Get-Cell $_ "A") -ne "" })
foreach ($r in ($alData | Select-Object -Last 2)) { Dump-Row $r $alCols "AL" }
Out-Line ("  Activity Log records: {0}; max data row: {1}" -f $alData.Count, $alData[$alData.Count-1].Row)

# ---- Architecture Decisions ----
$adrCols = @("A","B","C","D","E","F","G","H","I","J")
$adrRows = Get-SheetRows "Architecture Decisions"
Out-Line ""
Out-Line "=== ARCHITECTURE DECISIONS (all data rows) ==="
foreach ($r in $adrRows) { if ((Get-Cell $r "A") -ne "") { Dump-Row $r $adrCols "ADR" } }

# ---- Open Decisions ----
$odCols = @("A","B","C","D","E","F","G","H","I","J")
$odRows = Get-SheetRows "Open Decisions"
Out-Line ""
Out-Line "=== OPEN DECISIONS (all data rows) ==="
foreach ($r in $odRows) { if ((Get-Cell $r "A") -ne "") { Dump-Row $r $odCols "OD" } }

# ---- Dependencies & Blockers ----
$dbCols = @("A","B","C","D","E","F","G","H","I","J")
$dbRows = Get-SheetRows "Dependencies & Blockers"
Out-Line ""
Out-Line "=== DEPENDENCIES & BLOCKERS (all data rows) ==="
foreach ($r in $dbRows) { if ((Get-Cell $r "A") -ne "") { Dump-Row $r $dbCols "DB" } }

# ---- Audit Findings ----
$afCols = @("A","B","C","D","E","F","G","H","I","J","K","L","M")
$afRows = Get-SheetRows "Audit Findings"
Out-Line ""
Out-Line "=== AUDIT FINDINGS (all data rows, key cols) ==="
foreach ($r in $afRows) { if ((Get-Cell $r "A") -ne "") { Dump-Row $r $afCols "AF" } }

# ---- Phase Plan ----
$ppCols = @("A","B","C","D","E","F","G","H","I")
$ppRows = Get-SheetRows "Phase Plan"
Out-Line ""
Out-Line "=== PHASE PLAN (all data rows) ==="
foreach ($r in $ppRows) { if ((Get-Cell $r "A") -ne "") { Dump-Row $r $ppCols "PP" } }

# ---- Development Guide ----
$dgCols = @("A","B","C","D","E","F","G","H","I","J","K")
$dgRows = Get-SheetRows "Development Guide"
Out-Line ""
Out-Line "=== DEVELOPMENT GUIDE: rows referencing M-07-0.2 or WI-07-0.2.x ==="
$dgFound = $false
foreach ($r in $dgRows) {
    $cid = Get-Cell $r "C"
    if ($cid -match "M-07-0\.2|WI-07-0\.2") { Dump-Row $r $dgCols "DG"; $dgFound = $true }
}
if (-not $dgFound) { Out-Line "  (none found - no Development Guide row mirrors M-07-0.2 / WI-07-0.2.x)" }
$maxDgRow = 0
foreach ($r in $dgRows) { if ((Get-Cell $r "C") -ne "" -and $r.Row -gt $maxDgRow) { $maxDgRow = $r.Row } }
Out-Line ("  Development Guide max data row (non-empty C): {0}" -f $maxDgRow)

# ---- Existing Assets ----
$eaCols = @("A","B","C","D","E","F")
$eaRows = Get-SheetRows "Existing Assets"
Out-Line ""
Out-Line "=== EXISTING ASSETS (all data rows) ==="
foreach ($r in $eaRows) { if ((Get-Cell $r "A") -ne "") { Dump-Row $r $eaCols "EA" } }
$maxEaRow = 0
foreach ($r in $eaRows) { if ((Get-Cell $r "A") -ne "" -and $r.Row -gt $maxEaRow) { $maxEaRow = $r.Row } }
Out-Line ("  Existing Assets max data row (non-empty A): {0}" -f $maxEaRow)

# ---- Tool & Integration Registry ----
$trCols = @("A","B","C","D","E","F","G","H","I","J")
$trRows = Get-SheetRows "Tool & Integration Registry"
Out-Line ""
Out-Line "=== TOOL & INTEGRATION REGISTRY (all data rows) ==="
foreach ($r in $trRows) { if ((Get-Cell $r "A") -ne "") { Dump-Row $r $trCols "TR" } }
$maxTrRow = 0
foreach ($r in $trRows) { if ((Get-Cell $r "A") -ne "" -and $r.Row -gt $maxTrRow) { $maxTrRow = $r.Row } }
Out-Line ("  Tool Registry max data row (non-empty A): {0}" -f $maxTrRow)

# ---- Control Center ----
$ccRows = Get-SheetRows "Control Center"
Out-Line ""
Out-Line "=== CONTROL CENTER A2 changelog narrative ==="
foreach ($r in $ccRows) {
    if ($r.Row -eq 2) {
        $a2 = Get-Cell $r "A"
        Out-Line ("  A2 length={0}" -f $a2.Length)
        Out-Line ("  A2 = {0}" -f $a2)
    }
}
Out-Line ""
Out-Line "=== CONTROL CENTER manual value cells L12..L17 ==="
foreach ($r in $ccRows) {
    if ($r.Row -ge 12 -and $r.Row -le 17) {
        Dump-Row $r @("H","I","J","K","L","M") "CC"
    }
}

[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "Wrote $OutFile"
