param(
    [string]$OutFile = "C:\Personal\DevTools\DevBridge\state\db-m02-1-range.txt"
)

# DB-M02.1 read-only probe: determine the ACTUAL governed Master Roadmap range by scanning
# every row in the sheet and classifying structurally valid RoadmapNode records.
# Structural validity: col A (Node ID) non-empty AND matches RoadmapNode pattern AND
# col C (Node Type) in {Layer, Feature, Milestone, WorkItem, Task, Subtask}.
# Rows with content but no valid Node ID are reported as non-record / malformed.
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

$doc = Open-Doc "xl/worksheets/sheet2.xml"
$sheetData = $doc.Root.Element($xNs + "sheetData")

# dimension (used range as recorded by the workbook)
$dim = $doc.Root.Element($xNs + "dimension")
Out-Line "dimension(ref) = $([string]$dim.Attribute('ref').Value)"

# Scan every row. Collect per-row: Node ID (A), Parent ID (B), Node Type (C),
# Sort Key (D), Hierarchy Path (E), Phase (G), Status (R), and the set of columns used.
$rows = @($sheetData.Elements($xNs + "row"))
$records = New-Object System.Collections.Generic.List[object]
$nonRecords = New-Object System.Collections.Generic.List[object]

$nodeTypeVocab = @("Layer", "Feature", "Milestone", "WorkItem", "Task", "Subtask")

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

function Get-UsedCols($row) {
    $cols = @()
    foreach ($cell in $row.Elements($xNs + "c")) {
        $ref = [string]$cell.Attribute("r").Value
        if ($ref) { $cols += ($ref -replace "[0-9]", "") }
    }
    return ($cols | Sort-Object -Unique)
}

# RoadmapNode pattern: Layer \d\d | F-..-.. | M-..-... | WI-..-... | T-..-... | S-..-...
$nodeIdRegex = '^(F-\d+-\d+|M-\d+-\d+\.\d+|WI-\d+-\d+\.\d+\.\d+|T-\d+-\d+\.\d+\.\d+\.\d+|S-\d+-\d+\.\d+\.\d+\.\d+\.\d+|\d{2})$'

foreach ($r in $rows) {
    $rn = [int]$r.Attribute("r").Value
    $nodeId = Get-CellVal $r "A"
    $nodeType = Get-CellVal $r "C"
    $used = Get-UsedCols $r
    if (@($used).Count -eq 0) { continue }  # truly empty row
    $rec = [pscustomobject]@{
        Row = $rn; NodeId = $nodeId; Parent = (Get-CellVal $r "B"); NodeType = $nodeType;
        SortKey = (Get-CellVal $r "D"); HierPath = (Get-CellVal $r "E"); Phase = (Get-CellVal $r "G");
        Status = (Get-CellVal $r "R"); UsedCols = ($used -join ",")
    }
    $isValid = $false
    if ($nodeId -and $nodeType -and ($nodeId -match $nodeIdRegex) -and $nodeType -in $nodeTypeVocab) { $isValid = $true }
    if ($isValid) { $records.Add($rec) } else { $nonRecords.Add($rec) }
}

Out-Line ""
Out-Line "=== STRUCTURALLY VALID RoadmapNode records: $($records.Count) ==="
$first = ($records | Sort-Object Row | Select-Object -First 1)
$last = ($records | Sort-Object Row | Select-Object -Last 1)
Out-Line "First record: row $($first.Row) node=$($first.NodeId) type=$($first.NodeType)"
Out-Line "Last  record: row $($last.Row) node=$($last.NodeId) type=$($last.NodeType)"

# Excel table boundary (from xl/tables/table1.xml)
$fs = [System.IO.File]::Open($wb, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
$zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
$tblDoc = [System.Xml.Linq.XDocument]::Load((New-Object System.IO.StreamReader($zip.GetEntry("xl/tables/table1.xml").Open())))
$tableRef = [string]$tblDoc.Root.Attribute("ref").Value
$zip.Dispose(); $fs.Dispose()
Out-Line "Formal Excel table (MasterRoadmapTable) ref = $tableRef"

# split records by table membership
$inTable = @($records | Where-Object { $_.Row -le 630 })
$beyond  = @($records | Where-Object { $_.Row -gt 630 })
Out-Line "Records within  table range (rows <= 630): $($inTable.Count)"
Out-Line "Records BEYOND  table range (rows  > 630): $($beyond.Count)   <-- previously omitted from governed set"

Out-Line ""
Out-Line "=== BEYOND-TABLE RECORDS (recovered set) ==="
foreach ($rec in ($beyond | Sort-Object Row)) {
    $hp = $rec.HierPath; if ($hp.Length -gt 70) { $hp = $hp.Substring(0, 70) + "..." }
    Out-Line ("  R{0} {1} | parent={2} | type={3} | sort={4} | phase={5} | status={6} | path={7}" -f $rec.Row, $rec.NodeId, $rec.Parent, $rec.NodeType, $rec.SortKey, $rec.Phase, $rec.Status, $hp)
}

Out-Line ""
Out-Line "=== NON-RECORD / MALFORMED / PARTIAL rows (content but not a valid node record) ==="
$shown = 0
foreach ($rec in ($nonRecords | Sort-Object Row)) {
    if ($shown -lt 30) {
        $s = $rec.NodeId; if ($s.Length -gt 40) { $s = $s.Substring(0, 40) + "..." }
        Out-Line ("  R{0} A='{1}' C='{2}' cols=[{3}]" -f $rec.Row, $s, $rec.NodeType, $rec.UsedCols)
        $shown++
    }
}
if ($nonRecords.Count -gt $shown) { Out-Line ("  ... and {0} more" -f ($nonRecords.Count - $shown)) }
Out-Line "Non-record rows with content: $($nonRecords.Count)"

# Duplicate Node ID check across full governed set
Out-Line ""
Out-Line "=== DUPLICATE NODE IDs in full governed set ==="
$dups = $records | Group-Object NodeId | Where-Object { $_.Count -gt 1 }
if (@($dups).Count -eq 0) { Out-Line "  NONE" } else { $dups | ForEach-Object { Out-Line "  $($_.Name): rows $((($_.Group | ForEach-Object { $_.Row }) -join ','))" } }

[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "Wrote $OutFile ($($sb.Length) chars) | valid records=$($records.Count) beyond-table=$($beyond.Count)"
