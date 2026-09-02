# _Probe-DBM06-AppendOnly.ps1 - DB-M06 Part 8: verify Version History + Activity Log are
# APPEND-ONLY. Reads the canonical workbook and a post-mutation COPY (from the harness)
# and checks that every canonical data row is present, unchanged, in the copy (a strict
# prefix) and that the copy only has MORE rows below. READ-ONLY.
param([Parameter(Mandatory=$true)][string]$CopyPath)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null
$xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
$xRel = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/officeDocument/2006/relationships"
$Canonical = "C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx"

function Resolve-CellVal([System.Xml.Linq.XElement]$c) {
    $t = $c.Attribute("t"); $tv = if ($t) { [string]$t.Value } else { "" }
    if ($tv -eq "inlineStr") { $is = $c.Element($xNs + "is"); if ($is) { return [string]$is.Value }; return "" }
    $v = $c.Element($xNs + "v"); if (-not $v) { return "" }
    if ($tv -eq "s") { $i = [int]$v.Value; if ($i -lt $shared.Count) { return $shared[$i] }; return "[?]" }
    return [string]$v.Value
}

function Get-SheetData([string]$path, [string]$sheetName) {
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
        try {
            $script:shared = New-Object System.Collections.Generic.List[string]
            $ss = $zip.GetEntry("xl/sharedStrings.xml")
            if ($ss) { $sr = New-Object System.IO.StreamReader($ss.Open()); $x = [System.Xml.Linq.XDocument]::Load($sr); $sr.Close(); foreach ($si in $x.Root.Elements($xNs + "si")) { $script:shared.Add([string]$si.Value) } }
            $wb = New-Object System.IO.StreamReader($zip.GetEntry("xl/workbook.xml").Open())
            $wbx = [System.Xml.Linq.XDocument]::Load($wb); $wb.Close()
            $target = $null
            foreach ($s in $wbx.Root.Elements($xNs + "sheets").Elements($xNs + "sheet")) { if ([string]$s.Attribute("name").Value -eq $sheetName) { $target = [string]$s.Attribute($xRel + "id").Value; break } }
            $rel = New-Object System.IO.StreamReader($zip.GetEntry("xl/_rels/workbook.xml.rels").Open())
            $relx = [System.Xml.Linq.XDocument]::Load($rel); $rel.Close()
            $p = $null
            foreach ($r in $relx.Root.Elements()) { if ([string]$r.Attribute("Id").Value -eq $target) { $p = [string]$r.Attribute("Target").Value; break } }
            if ($p.StartsWith("/")) { $p = $p.TrimStart("/") } else { $p = "xl/" + $p }
            if (-not $p.ToLower().EndsWith(".xml")) { $p = $p + ".xml" }
            $rd = New-Object System.IO.StreamReader($zip.GetEntry($p).Open())
            $xdoc = [System.Xml.Linq.XDocument]::Load($rd); $rd.Close()
            $rows = @{}
            foreach ($row in $xdoc.Root.Elements($xNs + "sheetData").Elements($xNs + "row")) {
                $rn = [int]$row.Attribute("r").Value
                $cells = @{}
                foreach ($c in $row.Elements($xNs + "c")) {
                    $ra = $c.Attribute("r"); if (-not $ra) { continue }
                    $cells[[string]$ra.Value] = (Resolve-CellVal $c).Trim()
                }
                $rows[$rn] = $cells
            }
            return $rows
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }
}

foreach ($sheetName in @("Version History", "Activity Log")) {
    $canon = Get-SheetData $Canonical $sheetName
    $copy  = Get-SheetData $CopyPath $sheetName
    $canonRows = @($canon.Keys | Sort-Object)
    $copyRows  = @($copy.Keys  | Sort-Object)
    $lastCanon = $canonRows[-1]
    Write-Output "=== $sheetName ==="
    Write-Output ("  canonical rows: {0}  copy rows: {1}" -f $canonRows.Count, $copyRows.Count)
    Write-Output ("  canonical last row: {0}  copy last row: {1}" -f $lastCanon, $copyRows[-1])
    $mismatch = 0; $missing = 0
    foreach ($rn in $canonRows) {
        if (-not $copy.ContainsKey($rn)) { $missing++; if ($missing -le 3) { Write-Output ("    MISSING in copy: row {0}" -f $rn) }; continue }
        $a = $canon[$rn]; $b = $copy[$rn]
        foreach ($key in $a.Keys) {
            $av = if ($a.ContainsKey($key)) { $a[$key] } else { "" }
            $bv = if ($b.ContainsKey($key)) { $b[$key] } else { "<ABSENT>" }
            if (($av -ne "") -and ($av -ne $bv)) {
                $mismatch++; if ($mismatch -le 5) { Write-Output ("    CHANGED row {0} cell {1}: '{2}' -> '{3}'" -f $rn, $key, $av, $bv) }
            }
        }
    }
    $appended = @($copyRows | Where-Object { $_ -gt $lastCanon })
    Write-Output ("  canonical rows missing in copy: {0}" -f $missing)
    Write-Output ("  canonical cell mismatches in copy: {0}" -f $mismatch)
    Write-Output ("  new rows appended after canonical last row: {0}" -f $appended.Count)
    if ($appended.Count -gt 0) { Write-Output ("    appended row numbers: {0}" -f ($appended -join ",")) }
    Write-Output ""
}
Write-Output "=== DONE ==="
