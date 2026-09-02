# _Probe-DBM10-CompletedRows.ps1 - READ-ONLY. Dump the completed sibling Active Changes
# rows (CHG-20260830-013/014/015) in full A..AD to learn the exact close convention:
# Status (L), Completed At (U), Result / Evidence (V), Change Version (W), Change Type (AC),
# Validation Result (AD). ASCII-only.
param(
    [string]$OutFile = "C:\Personal\DevTools\DevBridge\state\db-m10-completed-rows.txt"
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

$fs = [System.IO.File]::Open($wb, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
try {
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
    try {
        $shared = New-Object System.Collections.Generic.List[string]
        $ssEntry = $zip.GetEntry("xl/sharedStrings.xml")
        if ($ssEntry) {
            $sr = New-Object System.IO.StreamReader($ssEntry.Open())
            $ssXml = [System.Xml.Linq.XDocument]::Load($sr); $sr.Close()
            foreach ($si in $ssXml.Root.Elements($xNs + "si")) { $shared.Add([string]$si.Value) }
        }
        $rd = New-Object System.IO.StreamReader($zip.GetEntry("xl/workbook.xml").Open())
        $wbXml = [System.Xml.Linq.XDocument]::Load($rd); $rd.Close()
        $target = $null
        foreach ($s in $wbXml.Root.Elements($xNs + "sheets").Elements($xNs + "sheet")) {
            if ([string]$s.Attribute("name").Value -eq "Active Changes") { $target = [string]$s.Attribute($xRel + "id").Value; break }
        }
        $rd2 = New-Object System.IO.StreamReader($zip.GetEntry("xl/_rels/workbook.xml.rels").Open())
        $relsXml = [System.Xml.Linq.XDocument]::Load($rd2); $rd2.Close()
        $p = $null
        foreach ($rel in $relsXml.Root.Elements()) { if ([string]$rel.Attribute("Id").Value -eq $target) { $p = [string]$rel.Attribute("Target").Value; break } }
        if ($p.StartsWith("/")) { $p = $p.TrimStart("/") } else { $p = "xl/" + $p }
        if (-not $p.ToLower().EndsWith(".xml")) { $p = $p + ".xml" }
        $rd3 = New-Object System.IO.StreamReader($zip.GetEntry($p).Open())
        $ac = [System.Xml.Linq.XDocument]::Load($rd3); $rd3.Close()

        $wanted = @("CHG-20260830-013","CHG-20260830-014","CHG-20260830-015")
        $cols = @("A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z","AA","AB","AC","AD")
        foreach ($row in $ac.Root.Elements($xNs + "sheetData").Elements($xNs + "row")) {
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
                        if ($t -eq "s") { $idx = [int]$v.Value; if ($idx -ge 0 -and $idx -lt $shared.Count) { $val = $shared[$idx] } }
                        else { $val = [string]$v.Value }
                    }
                }
                $cellMap[$letter] = $val.Trim()
            }
            $cid = if ($cellMap.ContainsKey("A")) { $cellMap["A"] } else { "" }
            if ($wanted -contains $cid) {
                Out-Line ("--- {0} (row {1}) ---" -f $cid, ([int]$row.Attribute("r").Value))
                foreach ($c in $cols) {
                    $v = if ($cellMap.ContainsKey($c)) { $cellMap[$c] } else { "" }
                    if ($v -ne "") { Out-Line ("  {0} = {1}" -f $c, $v) }
                }
                Out-Line ""
            }
        }
    } finally { $zip.Dispose() }
} finally { $fs.Dispose() }

[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "Wrote $OutFile"
