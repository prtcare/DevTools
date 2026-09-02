param(
    [Parameter(Mandatory = $true)][string]$Sheet,
    [int]$MaxRows = 500
)

# Read-only probe: dumps non-empty cells of one worksheet as "R{n}: A1=val | B2=val ..."
Set-StrictMode -Version Latest
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
        $wbEntry = $zip.GetEntry("xl/workbook.xml")
        $reader = New-Object System.IO.StreamReader($wbEntry.Open())
        $wbXml = [System.Xml.Linq.XDocument]::Load($reader)
        $reader.Close()

        $sheetTarget = $null
        foreach ($s in $wbXml.Root.Elements($xNs + "sheets").Elements($xNs + "sheet")) {
            if ([string]$s.Attribute("name").Value -eq $Sheet) {
                $sheetTarget = [string]$s.Attribute($xRel + "id").Value
                break
            }
        }
        if (-not $sheetTarget) { Write-Output "SHEET NOT FOUND: $Sheet"; return }

        $relsEntry = $zip.GetEntry("xl/_rels/workbook.xml.rels")
        $reader2 = New-Object System.IO.StreamReader($relsEntry.Open())
        $relsXml = [System.Xml.Linq.XDocument]::Load($reader2)
        $reader2.Close()
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
        if (-not $entry) { Write-Output "ENTRY NOT FOUND: $targetPath"; return }
        $reader3 = New-Object System.IO.StreamReader($entry.Open())
        $sheetXml = [System.Xml.Linq.XDocument]::Load($reader3)
        $reader3.Close()

        Write-Output "=== $Sheet (target=$targetPath) ==="
        $rows = $sheetXml.Root.Elements($xNs + "sheetData").Elements($xNs + "row")
        foreach ($row in $rows) {
            $rNum = [int]$row.Attribute("r").Value
            if ($rNum -gt $MaxRows) { break }
            $out = ""
            foreach ($cell in $row.Elements($xNs + "c")) {
                $refAttr = $cell.Attribute("r"); $ref = ""
                if ($refAttr) { $ref = [string]$refAttr.Value }
                $tAttr = $cell.Attribute("t"); $t = ""
                if ($tAttr) { $t = [string]$tAttr.Value }
                $val = $null
                try {
                    if ($t -eq "inlineStr") {
                        $isEl = $cell.Element($xNs + "is")
                        if ($isEl) { $val = [string]$isEl.Value }
                    } elseif ($t -eq "s") {
                        $vEl2 = $cell.Element($xNs + "v")
                        if ($vEl2) { $val = "[sharedString:" + $vEl2.Value + "]" }
                    } else {
                        $vEl = $cell.Element($xNs + "v")
                        $fEl = $cell.Element($xNs + "f")
                        if ($fEl) {
                            if ($vEl) { $val = "=FORMULA(cached:" + $vEl.Value + ") " + $fEl.Value }
                            else { $val = "=FORMULA(nocache) " + $fEl.Value }
                        } elseif ($vEl) {
                            $val = $vEl.Value
                        }
                    }
                } catch {
                    $val = "<?ERR:" + $_.Exception.Message + ">"
                }
                if ($null -ne $val -and [string]$val -ne "") {
                    if ($out) { $out += "  |  " }
                    $out += "$ref=" + [string]$val
                }
            }
            if ($out) { Write-Output "R${rNum}: $out" }
        }
    } finally { $zip.Dispose() }
} finally { $fs.Dispose() }
