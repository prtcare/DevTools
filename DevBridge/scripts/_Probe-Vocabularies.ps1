# _Probe-Vocabularies.ps1 - READ-ONLY: distinct values of the governed vocabularies the
# store must round-trip: Master Roadmap Status (R) and Node Type (C), Activity Log Actor
# Type (C), Preflight Verdict (M in Active Changes), Active Changes Status (L).
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null
$xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
$xRel = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/officeDocument/2006/relationships"
$wbPath = "C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx"

$fs = [System.IO.File]::Open($wbPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
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
        function Resolve([System.Xml.Linq.XElement]$cell) {
            $tAttr = $cell.Attribute("t"); $t = if ($tAttr) { [string]$tAttr.Value } else { "" }
            if ($t -eq "inlineStr") { $isEl = $cell.Element($xNs + "is"); if ($isEl) { return [string]$isEl.Value }; return "" }
            $vEl = $cell.Element($xNs + "v"); if (-not $vEl) { return "" }
            if ($t -eq "s") { $idx = [int]$vEl.Value; if ($idx -ge 0 -and $idx -lt $shared.Count) { return $shared[$idx] }; return "[missing-shared:$idx]" }
            return [string]$vEl.Value
        }
        function Get-SheetXml([string]$name) {
            $rd = New-Object System.IO.StreamReader($zip.GetEntry("xl/workbook.xml").Open())
            $wbXml = [System.Xml.Linq.XDocument]::Load($rd); $rd.Close()
            $target = $null
            foreach ($s in $wbXml.Root.Elements($xNs + "sheets").Elements($xNs + "sheet")) {
                if ([string]$s.Attribute("name").Value -eq $name) { $target = [string]$s.Attribute($xRel + "id").Value; break }
            }
            $rd2 = New-Object System.IO.StreamReader($zip.GetEntry("xl/_rels/workbook.xml.rels").Open())
            $relsXml = [System.Xml.Linq.XDocument]::Load($rd2); $rd2.Close()
            $p = $null
            foreach ($rel in $relsXml.Root.Elements()) {
                if ([string]$rel.Attribute("Id").Value -eq $target) { $p = [string]$rel.Attribute("Target").Value; break }
            }
            if ($p.StartsWith("/")) { $p = $p.TrimStart("/") } else { $p = "xl/" + $p }
            if (-not $p.ToLower().EndsWith(".xml")) { $p = $p + ".xml" }
            $rd3 = New-Object System.IO.StreamReader($zip.GetEntry($p).Open())
            $xml = [System.Xml.Linq.XDocument]::Load($rd3); $rd3.Close()
            return $xml
        }
        function ColValue($xml, [int]$rowNum, [string]$col) {
            $rows = $xml.Root.Elements($xNs + "sheetData").Elements($xNs + "row")
            foreach ($row in $rows) {
                if ([int]$row.Attribute("r").Value -ne $rowNum) { continue }
                foreach ($cell in $row.Elements($xNs + "c")) {
                    $refAttr = $cell.Attribute("r"); if (-not $refAttr) { continue }
                    if (([string]$refAttr.Value) -match "^$col") { return (Resolve $cell).Trim() }
                }
            }
            return ""
        }
        function Distinct($xml, [int]$startRow, [string]$col, [string]$label) {
            $set = New-Object System.Collections.Generic.HashSet[string]
            foreach ($row in $xml.Root.Elements($xNs + "sheetData").Elements($xNs + "row")) {
                $rNum = [int]$row.Attribute("r").Value
                if ($rNum -lt $startRow) { continue }
                foreach ($cell in $row.Elements($xNs + "c")) {
                    $refAttr = $cell.Attribute("r"); if (-not $refAttr) { continue }
                    if (([string]$refAttr.Value) -match "^$col\d+$") {
                        $v = (Resolve $cell).Trim()
                        if ($v -ne "") { [void]$set.Add($v) }
                        break
                    }
                }
            }
            Write-Output ("{0}: {1}" -f $label, ($set -join " | "))
        }
        $mr = Get-SheetXml "Master Roadmap"
        $ac = Get-SheetXml "Active Changes"
        $al = Get-SheetXml "Activity Log"
        Distinct $mr 6 "C" "Master Roadmap Node Type"
        Distinct $mr 6 "R" "Master Roadmap Status"
        Distinct $al 5 "C" "Activity Log Actor Type"
        Distinct $ac 6 "M" "Active Changes Preflight Verdict"
        Distinct $ac 6 "L" "Active Changes Status"
        Write-Output ("Control Center A2 (changelog head): " + ((ColValue (Get-SheetXml 'Control Center') 2 'A').Substring(0, [Math]::Min(160, (ColValue (Get-SheetXml 'Control Center') 2 'A').Length))))
    } finally { $zip.Dispose() }
} finally { $fs.Dispose() }
