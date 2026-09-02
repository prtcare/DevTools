# _Probe-TREASchema.ps1 - READ-ONLY. Dump header rows + last data rows of
# "Tool & Integration Registry" and "Existing Assets" to confirm column-letter maps.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null
$xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
$xRel = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/officeDocument/2006/relationships"
$cfg = Get-Content "C:\Personal\DevTools\DevBridge\config\devbridge.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$wb = $cfg.developmentControlWorkbook

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

        foreach ($sheetName in @("Tool & Integration Registry","Existing Assets")) {
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
            $rd3 = New-Object System.IO.StreamReader($zip.GetEntry($p).Open())
            $doc = [System.Xml.Linq.XDocument]::Load($rd3); $rd3.Close()

            foreach ($row in $doc.Root.Elements($xNs + "sheetData").Elements($xNs + "row")) {
                $rn = [int]$row.Attribute("r").Value
                if ($rn -ne 5 -and $rn -ne 15 -and $rn -lt 0) { }
                if ($rn -eq 5 -or $rn -eq 15) {
                    Write-Output ("--- {0} row {1} ---" -f $sheetName, $rn)
                    foreach ($cell in $row.Elements($xNs + "c")) {
                        $ref = [string]$cell.Attribute("r").Value
                        $tAttr = $cell.Attribute("t"); $t = if ($tAttr) { [string]$tAttr.Value } else { "" }
                        $val = ""
                        if ($t -eq "inlineStr") { $is = $cell.Element($xNs + "is"); if ($is) { $val = [string]$is.Value } }
                        else { $v = $cell.Element($xNs + "v"); if ($v) { if ($t -eq "s") { $idx = [int]$v.Value; if ($idx -ge 0 -and $idx -lt $shared.Count) { $val = $shared[$idx] } } else { $val = [string]$v.Value } } }
                        if ($val -ne "") { Write-Output ("  {0}  value=[{1}]" -f $ref, $val) }
                    }
                }
            }
        }
    } finally { $zip.Dispose() }
} finally { $fs.Dispose() }
