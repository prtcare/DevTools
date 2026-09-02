param(
    [string]$OutFile = "C:\Personal\DevTools\DevBridge\state\db-g02-evidence2.txt"
)

# DB-G02 read-only evidence extraction (part 2): Session Protocol (V4) and
# Architecture Decisions / Open Decisions / Audit Findings / Tool Registry /
# Development Guide / Existing Assets samples (V9-V13).
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null
$xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
$cfg = Get-Content "C:\Personal\DevTools\DevBridge\config\devbridge.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$wb = $cfg.developmentControlWorkbook

$sb = New-Object System.Text.StringBuilder
function Out-Line([string]$t) { [void]$sb.AppendLine($t) }

function Open-Doc([string]$entryName) {
    $fs = [System.IO.File]::Open($wb, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
    $rd = New-Object System.IO.StreamReader($zip.GetEntry($entryName).Open())
    $doc = [System.Xml.Linq.XDocument]::Load($rd)
    $rd.Close(); $zip.Dispose(); $fs.Dispose()
    return $doc
}

function Get-RowValues($row) {
    # returns ordered list of "col=value" for non-empty cells
    $vals = @()
    foreach ($cell in $row.Elements($xNs + "c")) {
        $refAttr = $cell.Attribute("r"); if (-not $refAttr) { continue }
        $ref = [string]$refAttr.Value
        $t = ""; $tAttr = $cell.Attribute("t"); if ($tAttr) { $t = [string]$tAttr.Value }
        $val = $null
        if ($t -eq "inlineStr") { $is = $cell.Element($xNs + "is"); if ($is) { $val = [string]$is.Value } }
        else { $v = $cell.Element($xNs + "v"); if ($v) { $val = $v.Value } }
        if ($null -ne $val -and ([string]$val).Trim() -ne "") {
            $s = [string]$val; if ($s.Length -gt 90) { $s = $s.Substring(0, 90) + "..." }
            $vals += "$ref=$s"
        }
    }
    return $vals
}

function Dump-Sheet([string]$entry, [string]$label, [int]$headerRow, [int]$firstDataRow, [int]$lastRow, [int]$maxRows) {
    $doc = Open-Doc $entry
    Out-Line "=== $label ==="
    $rows = @($doc.Root.Elements($xNs + "sheetData").Elements($xNs + "row"))
    foreach ($r in $rows) {
        $rn = [int]$r.Attribute("r").Value
        if ($rn -lt $headerRow) { continue }
        if ($rn -gt $lastRow) { continue }
        if ($rn -ge $firstDataRow -and $rn -gt ($firstDataRow + $maxRows - 1)) { continue }
        $vals = Get-RowValues $r
        if (@($vals).Count -eq 0) { continue }
        Out-Line ("  R{0}: {1}" -f $rn, ($vals -join " | "))
    }
    Out-Line ""
}

Dump-Sheet "xl/worksheets/sheet5.xml" "SESSION PROTOCOL (sheet5)" 1 6 60 55
Dump-Sheet "xl/worksheets/sheet8.xml" "ARCHITECTURE DECISIONS (sheet8)" 4 5 30 12
Dump-Sheet "xl/worksheets/sheet9.xml" "OPEN DECISIONS (sheet9)" 4 5 30 12
Dump-Sheet "xl/worksheets/sheet4.xml" "AUDIT FINDINGS (sheet4)" 5 6 30 10
Dump-Sheet "xl/worksheets/sheet11.xml" "TOOL & INTEGRATION REGISTRY (sheet11)" 4 5 30 10
Dump-Sheet "xl/worksheets/sheet13.xml" "DEVELOPMENT GUIDE (sheet13)" 4 5 30 8
Dump-Sheet "xl/worksheets/sheet14.xml" "EXISTING ASSETS (sheet14)" 4 5 30 8

[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "Wrote $OutFile ($($sb.Length) chars)"
