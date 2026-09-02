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
        $rd = New-Object System.IO.StreamReader($zip.GetEntry("xl/workbook.xml").Open())
        $wbXml = [System.Xml.Linq.XDocument]::Load($rd); $rd.Close()
        $target = $null
        foreach ($s in $wbXml.Root.Elements($xNs + "sheets").Elements($xNs + "sheet")) {
            if ([string]$s.Attribute("name").Value -eq "Activity Log") { $target = [string]$s.Attribute($xRel + "id").Value; break }
        }
        $rd2 = New-Object System.IO.StreamReader($zip.GetEntry("xl/_rels/workbook.xml.rels").Open())
        $relsXml = [System.Xml.Linq.XDocument]::Load($rd2); $rd2.Close()
        $p = $null
        foreach ($rel in $relsXml.Root.Elements()) { if ([string]$rel.Attribute("Id").Value -eq $target) { $p = [string]$rel.Attribute("Target").Value; break } }
        if ($p.StartsWith("/")) { $p = $p.TrimStart("/") } else { $p = "xl/" + $p }
        if (-not $p.ToLower().EndsWith(".xml")) { $p = $p + ".xml" }
        $rd3 = New-Object System.IO.StreamReader($zip.GetEntry($p).Open())
        $al = [System.Xml.Linq.XDocument]::Load($rd3); $rd3.Close()
        $rows = @($al.Root.Elements($xNs + "sheetData").Elements($xNs + "row"))
        $maxRow = 0; $blankActor = 0; $withActor = 0
        foreach ($row in $rows) {
            $rNum = [int]$row.Attribute("r").Value
            if ($rNum -lt 5) { continue }
            $cVal = ""
            foreach ($cell in $row.Elements($xNs + "c")) {
                $refAttr = $cell.Attribute("r"); if (-not $refAttr) { continue }
                $ref = [string]$refAttr.Value
                if ($ref -match "^A\d+$") {
                    $aVal = (Resolve $cell).Trim()
                    if ($aVal -ne "" -and $rNum -gt $maxRow) { $maxRow = $rNum }
                }
                if ($ref -match "^C\d+$") { $cVal = (Resolve $cell).Trim() }
            }
            if ($cVal -eq "") { $blankActor++ } else { $withActor++ }
        }
        Write-Output ("Activity Log: last data row with non-empty A = {0}; data rows with blank ActorType(C) = {1}; with ActorType = {2}" -f $maxRow, $blankActor, $withActor)
    } finally { $zip.Dispose() }
} finally { $fs.Dispose() }
