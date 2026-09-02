# _probe-amend-rows.ps1 — READ-ONLY diagnostic: dump exact cells of Active Changes
# header row + CHG-017 row, and Activity Log header row + last 3 data rows.
# Uses the same OOXML reader as the DevBridge scripts. Never modifies the workbook.
param(
    [string]$Workbook = "C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null
$xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
$xRel = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/officeDocument/2006/relationships"

function Get-SheetPath([string]$wbPath, [string]$sheetName) {
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
            return @{ path = $p; shared = $shared }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }
}

function Dump-Rows([string]$wbPath, [string]$sheetName, [int[]]$rows) {
    $info = Get-SheetPath $wbPath $sheetName
    $shared = $info.shared
    $fs = [System.IO.File]::Open($wbPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
        try {
            $rd3 = New-Object System.IO.StreamReader($zip.GetEntry($info.path).Open())
            $doc = [System.Xml.Linq.XDocument]::Load($rd3); $rd3.Close()
            Write-Output ("=== {0} ===" -f $sheetName)
            foreach ($row in $doc.Root.Elements($xNs + "sheetData").Elements($xNs + "row")) {
                $rn = [int]$row.Attribute("r").Value
                if ($rows -notcontains $rn) { continue }
                Write-Output ("--- row {0} ---" -f $rn)
                foreach ($cell in $row.Elements($xNs + "c")) {
                    $ref = [string]$cell.Attribute("r").Value
                    $tAttr = $cell.Attribute("t"); $t = if ($tAttr) { [string]$tAttr.Value } else { "" }
                    $val = ""
                    if ($t -eq "inlineStr") { $is = $cell.Element($xNs + "is"); if ($is) { $val = [string]$is.Value } }
                    else { $v = $cell.Element($xNs + "v"); if ($v) { if ($t -eq "s") { $idx = [int]$v.Value; if ($idx -ge 0 -and $idx -lt $shared.Count) { $val = $shared[$idx] } } else { $val = [string]$v.Value } } }
                    if ($val -ne "" -or $rn -eq 1) { Write-Output ("  {0,-3} [{1}]" -f $ref, $val) }
                }
            }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }
}

# Active Changes: header row 5, CHG-017 row 80
Dump-Rows $Workbook "Active Changes" @(5,80)
# Activity Log: header row 4, last rows
Dump-Rows $Workbook "Activity Log" @(4,53,54,55)
Write-Output "PROBE_DONE"
