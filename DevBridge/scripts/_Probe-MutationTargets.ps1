# _Probe-MutationTargets.ps1 - READ-ONLY: dump specific rows/cells the WI-07-0.2.3 store
# must read and write: Master Roadmap row 327 (WI-07-0.2.3), Active Changes rows 77-79,
# Activity Log last rows, and the Master Roadmap header. Resolves inlineStr + shared strings.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null
$xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
$xRel = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/officeDocument/2006/relationships"
$wbPath = "C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx"

function Get-ColName([int]$n) {
    $name = ""
    while ($n -gt 0) {
        $n--
        $name = [char](65 + ($n % 26)) + $name
        $n = [int][math]::Floor($n / 26)
    }
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
            $ssXml = [System.Xml.Linq.XDocument]::Load($sr)
            $sr.Close()
            foreach ($si in $ssXml.Root.Elements($xNs + "si")) { $shared.Add([string]$si.Value) }
        }
        function Resolve([System.Xml.Linq.XElement]$cell) {
            $tAttr = $cell.Attribute("t"); $t = if ($tAttr) { [string]$tAttr.Value } else { "" }
            if ($t -eq "inlineStr") {
                $isEl = $cell.Element($xNs + "is")
                if ($isEl) { return [string]$isEl.Value }
                return ""
            }
            $vEl = $cell.Element($xNs + "v")
            if (-not $vEl) { return "" }
            if ($t -eq "s") {
                $idx = [int]$vEl.Value
                if ($idx -ge 0 -and $idx -lt $shared.Count) { return $shared[$idx] }
                return "[missing-shared:$idx]"
            }
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

        function Dump-Rows([string]$sheetName, [int[]]$wantedRows, [int]$colCount) {
            $xml = Get-SheetXml $sheetName
            Write-Output ""
            Write-Output "=== $sheetName : requested rows ==="
            $seen = 0
            foreach ($row in $xml.Root.Elements($xNs + "sheetData").Elements($xNs + "row")) {
                $rNum = [int]$row.Attribute("r").Value
                if ($wantedRows -contains $rNum) {
                    $cells = @{}
                    foreach ($cell in $row.Elements($xNs + "c")) {
                        $refAttr = $cell.Attribute("r")
                        if (-not $refAttr) { continue }
                        $ref = [string]$refAttr.Value
                        $cells[$ref] = (Resolve $cell).Trim()
                    }
                    $parts = @()
                    for ($c = 1; $c -le $colCount; $c++) {
                        $key = (Get-ColName $c) + $rNum
                        $val = if ($cells.ContainsKey($key)) { $cells[$key] } else { "" }
                        $parts += ((Get-ColName $c) + "=[" + $val + "]")
                    }
                    Write-Output ("R{0}: {1}" -f $rNum, ($parts -join " "))
                    $seen++
                }
                if ($seen -ge $wantedRows.Count -and $rNum -gt ($wantedRows | Measure-Object -Maximum).Maximum) { break }
            }
        }

        function Dump-LastRows([string]$sheetName, [int]$count, [int]$colCount) {
            $xml = Get-SheetXml $sheetName
            $rows = @($xml.Root.Elements($xNs + "sheetData").Elements($xNs + "row"))
            $lastN = @($rows | Select-Object -Last $count)
            Write-Output ""
            Write-Output "=== $sheetName : last $count rows ==="
            foreach ($row in $lastN) {
                $rNum = [int]$row.Attribute("r").Value
                $cells = @{}
                foreach ($cell in $row.Elements($xNs + "c")) {
                    $refAttr = $cell.Attribute("r")
                    if (-not $refAttr) { continue }
                    $ref = [string]$refAttr.Value
                    $cells[$ref] = (Resolve $cell).Trim()
                }
                $parts = @()
                for ($c = 1; $c -le $colCount; $c++) {
                    $key = (Get-ColName $c) + $rNum
                    $val = if ($cells.ContainsKey($key)) { $cells[$key] } else { "" }
                    if ($val -ne "") { $parts += ((Get-ColName $c) + "=" + $val) }
                }
                if ($parts.Count -gt 0) { Write-Output ("R{0}: {1}" -f $rNum, ($parts -join " | ")) }
            }
        }

        Dump-Rows "Master Roadmap" @(327) 33
        Dump-Rows "Active Changes" @(77, 78, 79) 30
        Dump-LastRows "Activity Log" 4 34
        Dump-LastRows "Version History" 3 36
    } finally { $zip.Dispose() }
} finally { $fs.Dispose() }
