param(
    [string]$WorkbookPath,
    [string]$MapPath
)

# DB-G02 read-only validation helper.
# For each sheet in the DB-M02 map: extract the ACTUAL header row from the workbook XML
# and compare column-by-column against the mapped columns.
# Outputs one line per sheet: [SHEETNAME] rows=header..data columns=mapped/actual status
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null

$xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
$xRel = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/officeDocument/2006/relationships"

if (-not $WorkbookPath) { $WorkbookPath = "C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx" }
if (-not $MapPath) { $MapPath = "C:\Personal\DevTools\DevBridge\config\development-control-map.json" }

$map = Get-Content $MapPath -Raw -Encoding UTF8 | ConvertFrom-Json
$sheetMap = @{}
foreach ($s in $map.sheets) { $sheetMap[$s.name] = $s }

function Get-ColName([int]$n) {
    $name = ""
    while ($n -gt 0) { $n--; $name = [char](65 + ($n % 26)) + $name; $n = [int][math]::Floor($n / 26) }
    return $name
}

$fs = [System.IO.File]::Open($WorkbookPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
try {
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
    try {
        $rd = New-Object System.IO.StreamReader($zip.GetEntry("xl/workbook.xml").Open())
        $wb = [System.Xml.Linq.XDocument]::Load($rd); $rd.Close()
        $sheetRefs = @{}
        foreach ($s in $wb.Root.Elements($xNs + "sheets").Elements($xNs + "sheet")) {
            $sheetRefs[[string]$s.Attribute("name").Value] = [string]$s.Attribute($xRel + "id").Value
        }
        $rd2 = New-Object System.IO.StreamReader($zip.GetEntry("xl/_rels/workbook.xml.rels").Open())
        $rels = [System.Xml.Linq.XDocument]::Load($rd2); $rd2.Close()
        $relMap = @{}
        foreach ($r in $rels.Root.Elements()) { $relMap[[string]$r.Attribute("Id").Value] = [string]$r.Attribute("Target").Value }

        foreach ($s in $map.sheets) {
            $name = $s.name
            $rid = $sheetRefs[$name]
            if (-not $rid) { Write-Output "[$name] SHEET NOT FOUND IN WORKBOOK"; continue }
            $tgt = $relMap[$rid]
            if ($tgt.StartsWith("/")) { $tgt = $tgt.TrimStart("/") } else { $tgt = "xl/" + $tgt }
            if (-not $tgt.ToLower().EndsWith(".xml")) { $tgt = $tgt + ".xml" }
            $ent = $zip.GetEntry($tgt)
            if (-not $ent) { Write-Output "[$name] ENTRY NOT FOUND: $tgt"; continue }
            $rd3 = New-Object System.IO.StreamReader($ent.Open())
            $doc = [System.Xml.Linq.XDocument]::Load($rd3); $rd3.Close()

            $headerRow = $s.headerRow
            $actualHeaders = @{}   # col letter -> header text
            $maxColUsed = 0
            foreach ($row in $doc.Root.Elements($xNs + "sheetData").Elements($xNs + "row")) {
                $rNum = [int]$row.Attribute("r").Value
                foreach ($cell in $row.Elements($xNs + "c")) {
                    $refAttr = $cell.Attribute("r"); if (-not $refAttr) { continue }
                    $ref = [string]$refAttr.Value
                    $colStr = ($ref -replace "[0-9]", "")
                    $colNum = 0
                    foreach ($ch in $colStr.ToCharArray()) { $colNum = $colNum * 26 + ([int][char]$ch - 64) }
                    if ($colNum -gt $maxColUsed) { $maxColUsed = $colNum }
                    if ($null -ne $headerRow -and $rNum -eq $headerRow) {
                        $tAttr = $cell.Attribute("t"); $t = ""; if ($tAttr) { $t = [string]$tAttr.Value }
                        $val = $null
                        if ($t -eq "inlineStr") { $isEl = $cell.Element($xNs + "is"); if ($isEl) { $val = [string]$isEl.Value } }
                        elseif ($t -eq "s") { $vEl = $cell.Element($xNs + "v"); if ($vEl) { $val = "[s:$($vEl.Value)]" } }
                        else { $vEl = $cell.Element($xNs + "v"); if ($vEl) { $val = $vEl.Value } }
                        if ($null -ne $val -and [string]$val -ne "") { $actualHeaders[$colStr] = [string]$val }
                    }
                }
            }

            if ($null -eq $headerRow) {
                Write-Output "[$name] dashboard/no-header (labels only) mappedCols=$(@($s.columns).Count) actualCols=$maxColUsed"
                continue
            }

            # Compare mapped columns against actual header row
            $missing = @(); $unexpected = @(); $ambiguous = @(); $match = 0
            $mappedCols = @{}
            foreach ($c in @($s.columns)) {
                $colKey = (($c.column -split " ")[0])
                $mappedCols[$colKey] = $c.name
            }
            foreach ($kv in $mappedCols.GetEnumerator()) {
                $actual = $actualHeaders[$kv.Key]
                if ($null -eq $actual) { $missing += "$($kv.Key)='$($kv.Value)' (not present in header row)" }
                else {
                    $n1 = ([string]$kv.Value).Trim()
                    $n2 = ([string]$actual).Trim()
                    if ($n1 -eq $n2) { $match++ }
                    else { $ambiguous += "$($kv.Key) mapped='$n1' actual='$n2'" }
                }
            }
            foreach ($kv in $actualHeaders.GetEnumerator()) {
                if (-not $mappedCols.ContainsKey($kv.Key)) { $unexpected += "$($kv.Key)='$($kv.Value)'" }
            }
            Write-Output "[$name] headerRow=$headerRow mapped=$($mappedCols.Count) actual=$($actualHeaders.Count) match=$match missing=$(($missing | Measure-Object).Count) unexpected=$(($unexpected | Measure-Object).Count) ambiguous=$(($ambiguous | Measure-Object).Count)"
            foreach ($m in $missing) { Write-Output "   MISSING  $m" }
            foreach ($a in $ambiguous) { Write-Output "   AMBIGUOUS $a" }
            foreach ($u in $unexpected) { Write-Output "   UNEXPECTED $u" }
        }
    } finally { $zip.Dispose() }
} finally { $fs.Dispose() }
