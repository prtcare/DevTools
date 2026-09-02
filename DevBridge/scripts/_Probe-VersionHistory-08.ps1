# _Probe-VersionHistory-08.ps1 - READ-ONLY: dump every Version History record for the
# Layer-08 nodes (08 / F-08-1 / M-08-1.1 / WI-08-1.1.1) to see how Is Current is actually
# marked on actively-developed nodes.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null
$xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
$xRel = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/officeDocument/2006/relationships"
$wbPath = "C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx"

function Get-ColName([int]$n) {
    $name = ""
    while ($n -gt 0) { $n--; $name = [char](65 + ($n % 26)) + $name; $n = [int][math]::Floor($n / 26) }
    return $name
}

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
            if ([string]$s.Attribute("name").Value -eq "Version History") { $target = [string]$s.Attribute($xRel + "id").Value; break }
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

        $wanted = @("08", "F-08-1", "M-08-1.1", "WI-08-1.1.1", "M-07-0.2")
        Write-Output "Version History rows for Layer-08 + M-07-0.2 (A=NodeID, Z=Baseline, AA=RecordVer, AB=EffectiveFrom, AC=IsCurrent, AD=ChangeID, AE=Supersedes):"
        foreach ($row in $xml.Root.Elements($xNs + "sheetData").Elements($xNs + "row")) {
            $rNum = [int]$row.Attribute("r").Value
            if ($rNum -lt 6) { continue }
            $cells = @{}
            foreach ($cell in $row.Elements($xNs + "c")) {
                $refAttr = $cell.Attribute("r"); if (-not $refAttr) { continue }
                $cells[[string]$refAttr.Value] = (Resolve $cell).Trim()
            }
            $nodeId = if ($cells.ContainsKey("A$rNum")) { $cells["A$rNum"] } else { "" }
            if ($wanted -contains $nodeId) {
                $parts = @()
                foreach ($col in @("A","Z","AA","AB","AC","AD","AE")) {
                    $key = $col + $rNum
                    $val = if ($cells.ContainsKey($key)) { $cells[$key] } else { "[blank]" }
                    $parts += ($col + "=[" + $val + "]")
                }
                Write-Output ("R{0} {1}: {2}" -f $rNum, $nodeId, ($parts -join " "))
            }
        }
    } finally { $zip.Dispose() }
} finally { $fs.Dispose() }
