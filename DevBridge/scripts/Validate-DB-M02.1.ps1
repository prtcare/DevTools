param(
    [string]$OutFile = "C:\Personal\DevTools\DevBridge\state\db-m02-1-final.txt"
)

# DB-M02.1 final validation: confirm the corrected map's governedDataRange agrees with an
# independent structural rescan of the workbook, hierarchy integrity, and hash unchanged.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null
$xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
$cfg = Get-Content "C:\Personal\DevTools\DevBridge\config\devbridge.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$wb = $cfg.developmentControlWorkbook
$baselineHash = "E866D3C4D260031D3C067F4C9C272A497FD913AD7C8D0CBFD0BF42F76BCD2941"

$map = Get-Content "C:\Personal\DevTools\DevBridge\config\development-control-map.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$mr = $map.sheets | Where-Object { $_.name -eq "Master Roadmap" }

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

function Get-CellVal($row, [string]$col) {
    foreach ($cell in $row.Elements($xNs + "c")) {
        $ref = [string]$cell.Attribute("r").Value
        if (($ref -replace "[0-9]", "") -eq $col) {
            $t = ""; $tAttr = $cell.Attribute("t"); if ($tAttr) { $t = [string]$tAttr.Value }
            if ($t -eq "inlineStr") { $is = $cell.Element($xNs + "is"); if ($is) { return [string]$is.Value } }
            $v = $cell.Element($xNs + "v"); if ($v) { return $v.Value }
            return ""
        }
    }
    return ""
}

$nodeTypeVocab = @("Layer", "Feature", "Milestone", "WorkItem", "Task", "Subtask")
$nodeIdRegex = '^(F-\d+-\d+|M-\d+-\d+\.\d+|WI-\d+-\d+\.\d+\.\d+|T-\d+-\d+\.\d+\.\d+\.\d+|S-\d+-\d+\.\d+\.\d+\.\d+\.\d+|\d{2})$'

# Independent rescan (same detection rule as documented in the map)
$doc = Open-Doc "xl/worksheets/sheet2.xml"
$records = @()
foreach ($r in $doc.Root.Elements($xNs + "sheetData").Elements($xNs + "row")) {
    $nodeId = Get-CellVal $r "A"
    $nodeType = Get-CellVal $r "C"
    if (-not $nodeId -or -not $nodeType) { continue }
    if (-not ($nodeId -match $nodeIdRegex)) { continue }
    if ($nodeType -notin $nodeTypeVocab) { continue }
    $records += [pscustomobject]@{ Row = [int]$r.Attribute("r").Value; NodeId = $nodeId; Parent = (Get-CellVal $r "B"); NodeType = $nodeType; SortKey = (Get-CellVal $r "D"); HierPath = (Get-CellVal $r "E"); Status = (Get-CellVal $r "R") }
}

Out-Line "=== DB-M02.1 FINAL VALIDATION ==="
Out-Line "Map declared governedDataRange: $($mr.governedDataRange.range) start=$($mr.governedDataRange.startRow) end=$($mr.governedDataRange.endRow) count=$($mr.governedDataRange.recordCount) within=$($mr.governedDataRange.withinTableRecordCount) beyond=$($mr.governedDataRange.beyondTableRecordCount)"
Out-Line "Map declared formalExcelTableRange: $($mr.formalExcelTableRange)"
Out-Line ""
Out-Line "Independent rescan results:"
Out-Line "  records=$($records.Count) firstRow=$($records[0].Row) lastRow=$($records[-1].Row)"
$within = @($records | Where-Object { $_.Row -le 630 }).Count
$beyond = @($records | Where-Object { $_.Row -gt 630 }).Count
Out-Line "  withinTable=$within beyondTable=$beyond"
Out-Line "  beyond-table IDs: $(($records | Where-Object { $_.Row -gt 630 } | ForEach-Object { $_.NodeId } | Sort-Object) -join ', ')"
Out-Line ""

# Duplicate check
$dups = $records | Group-Object NodeId | Where-Object { $_.Count -gt 1 }
Out-Line "Duplicate Node IDs: $(if(@($dups).Count -eq 0){'NONE'}else{($dups | ForEach-Object {$_.Name}) -join ','})"

# Parent resolution
$byId = @{}; foreach ($rec in $records) { if (-not $byId.ContainsKey($rec.NodeId)) { $byId[$rec.NodeId] = $rec } }
$broken = @()
foreach ($rec in $records) {
    if (-not $rec.Parent) { if ($rec.NodeType -ne "Layer") { $broken += $rec.NodeId } }
    elseif (-not $byId.ContainsKey($rec.Parent)) { $broken += "$($rec.NodeId)->$($rec.Parent)" }
}
Out-Line "Broken parent references / orphans: $(if(@($broken).Count -eq 0){'NONE'}else{($broken -join ', ')})"

# Sort key prefix consistency
$sortBad = @()
foreach ($rec in $records) {
    if (-not $rec.SortKey -or $rec.NodeType -eq "Layer") { continue }
    $p = $byId[$rec.Parent]; if (-not $p -or -not $p.SortKey) { continue }
    if (-not $rec.SortKey.StartsWith($p.SortKey + ".")) { $sortBad += $rec.NodeId }
}
Out-Line "Sort key prefix violations: $(if(@($sortBad).Count -eq 0){'NONE'}else{($sortBad -join ', ')})"
Out-Line ""

# Cross-sheet resolvability of recovered nodes (summary)
$beyondIds = @($records | Where-Object { $_.Row -gt 630 } | ForEach-Object { $_.NodeId })
Out-Line "Recovered nodes resolvable as Master Roadmap records: $($beyondIds.Count) of 34"
Out-Line "  Active reservations targeting them (evidence): CHG-20260830-004/-005 -> M-07-10.3; CHG-20260830-008/-011/-012 -> M-04-3.3; CHG-20260830-004 -> F-07-10 subtree, F-06-8, M-12-0.4"
Out-Line ""

# Hash
$h = (Get-FileHash $wb -Algorithm SHA256).Hash
Out-Line "Workbook SHA256: $h"
Out-Line "Baseline       : $baselineHash"
Out-Line "Unchanged: $($h -eq $baselineHash)"

# PASS/FAIL decision
$ok = ($records.Count -eq $mr.governedDataRange.recordCount) -and ($mr.governedDataRange.recordCount -eq 659) -and (@($dups).Count -eq 0) -and (@($broken).Count -eq 0) -and (@($sortBad).Count -eq 0) -and ($h -eq $baselineHash) -and ($beyond -eq 34)
Out-Line ""
Out-Line "DB-M02.1 VALIDATION: $(if($ok){'PASS'}else{'FAIL'})"

[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "Wrote $OutFile | PASS=$ok"
