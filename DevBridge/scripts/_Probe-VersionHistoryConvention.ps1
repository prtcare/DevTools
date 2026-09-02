# _Probe-VersionHistoryConvention.ps1 - READ-ONLY: dump Version History rows for the WI-07-0.2.x
# chain plus the most recent appends, resolving shared strings, to learn the exact
# Is Current / Supersedes Version / Record Version convention the canonical workbook uses.
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
        # shared strings
        $shared = New-Object System.Collections.Generic.List[string]
        $ssEntry = $zip.GetEntry("xl/sharedStrings.xml")
        if ($ssEntry) {
            $sr = New-Object System.IO.StreamReader($ssEntry.Open())
            $ssXml = [System.Xml.Linq.XDocument]::Load($sr)
            $sr.Close()
            foreach ($si in $ssXml.Root.Elements($xNs + "si")) {
                $shared.Add([string]$si.Value)
            }
        }

        function Resolve([System.Xml.Linq.XElement]$cell) {
            $tAttr = $cell.Attribute("t")
            $t = if ($tAttr) { [string]$tAttr.Value } else { "" }
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

        # locate Version History sheet
        $wbEntry = $zip.GetEntry("xl/workbook.xml")
        $rd = New-Object System.IO.StreamReader($wbEntry.Open())
        $wbXml = [System.Xml.Linq.XDocument]::Load($rd)
        $rd.Close()
        $sheetTarget = $null
        foreach ($s in $wbXml.Root.Elements($xNs + "sheets").Elements($xNs + "sheet")) {
            if ([string]$s.Attribute("name").Value -eq "Version History") {
                $sheetTarget = [string]$s.Attribute($xRel + "id").Value
                break
            }
        }
        $relsEntry = $zip.GetEntry("xl/_rels/workbook.xml.rels")
        $rd2 = New-Object System.IO.StreamReader($relsEntry.Open())
        $relsXml = [System.Xml.Linq.XDocument]::Load($rd2)
        $rd2.Close()
        $targetPath = $null
        foreach ($rel in $relsXml.Root.Elements()) {
            if ([string]$rel.Attribute("Id").Value -eq $sheetTarget) {
                $targetPath = [string]$rel.Attribute("Target").Value
                break
            }
        }
        if ($targetPath.StartsWith("/")) { $targetPath = $targetPath.TrimStart("/") }
        else { $targetPath = "xl/" + $targetPath }
        if (-not $targetPath.ToLower().EndsWith(".xml")) { $targetPath = $targetPath + ".xml" }

        $entry = $zip.GetEntry($targetPath)
        $rd3 = New-Object System.IO.StreamReader($entry.Open())
        $sheetXml = [System.Xml.Linq.XDocument]::Load($rd3)
        $rd3.Close()

        $rows = $sheetXml.Root.Elements($xNs + "sheetData").Elements($xNs + "row")
        $all = @()
        foreach ($row in $rows) {
            $rNum = [int]$row.Attribute("r").Value
            $cellMap = @{}
            foreach ($cell in $row.Elements($xNs + "c")) {
                $refAttr = $cell.Attribute("r")
                if (-not $refAttr) { continue }
                $ref = [string]$refAttr.Value
                $letter = $ref -replace '\d+$', ''
                $cellMap[$letter] = (Resolve $cell).Trim()
            }
            $nodeId = if ($cellMap.ContainsKey("A")) { $cellMap["A"] } else { "" }
            $all += [pscustomobject]@{
                Row = $rNum
                NodeId = $nodeId
                RecordVersion = if ($cellMap.ContainsKey("AA")) { $cellMap["AA"] } else { "" }
                EffectiveFrom = if ($cellMap.ContainsKey("AB")) { $cellMap["AB"] } else { "" }
                IsCurrent = if ($cellMap.ContainsKey("AC")) { $cellMap["AC"] } else { "" }
                ChangeId = if ($cellMap.ContainsKey("AD")) { $cellMap["AD"] } else { "" }
                Supersedes = if ($cellMap.ContainsKey("AE")) { $cellMap["AE"] } else { "" }
                Name = if ($cellMap.ContainsKey("H")) { $cellMap["H"] } else { "" }
                Status = if ($cellMap.ContainsKey("R")) { $cellMap["R"] } else { "" }
            }
        }

        $targets = @("M-07-0.2", "WI-07-0.2.1", "WI-07-0.2.2", "WI-07-0.2.3", "WI-07-0.2.4", "F-07-0", "07")
        Write-Output "=== Version History rows for the WI-07-0.2 chain ==="
        foreach ($row in $all) {
            if ($targets -contains $row.NodeId) {
                Write-Output ("R{0} node=[{1}] name=[{2}] RV=[{3}] eff=[{4}] cur=[{5}] chg=[{6}] supersedes=[{7}] status=[{8}]" -f `
                    $row.Row, $row.NodeId, $row.Name, $row.RecordVersion, $row.EffectiveFrom, $row.IsCurrent, $row.ChangeId, $row.Supersedes, $row.Status)
            }
        }

        Write-Output ""
        Write-Output "=== Last 12 Version History rows (most recent appends) ==="
        $tail = @($all | Where-Object { $_.NodeId -ne "" } | Select-Object -Last 12)
        foreach ($row in $tail) {
            Write-Output ("R{0} node=[{1}] name=[{2}] RV=[{3}] eff=[{4}] cur=[{5}] chg=[{6}] supersedes=[{7}] status=[{8}]" -f `
                $row.Row, $row.NodeId, $row.Name, $row.RecordVersion, $row.EffectiveFrom, $row.IsCurrent, $row.ChangeId, $row.Supersedes, $row.Status)
        }

        Write-Output ""
        $currentCount = @($all | Where-Object { $_.NodeId -ne "" -and $_.IsCurrent -eq "Yes" }).Count
        $totalRecords = @($all | Where-Object { $_.NodeId -ne "" }).Count
        Write-Output ("Version History totals: {0} records, {1} marked Is Current=Yes" -f $totalRecords, $currentCount)
        $multi = $all | Where-Object { $_.NodeId -ne "" } | Group-Object NodeId | Where-Object { $_.Count -gt 1 }
        Write-Output ("Nodes with >1 record: {0}; sample multi-version nodes:" -f $multi.Count)
        $multi | Select-Object -First 3 | ForEach-Object {
            Write-Output ("  node=[{0}] records={1}" -f $_.Name, $_.Count)
        }
    } finally { $zip.Dispose() }
} finally { $fs.Dispose() }
