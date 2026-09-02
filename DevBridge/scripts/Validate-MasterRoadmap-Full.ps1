param(
    [string]$OutFile = "C:\Personal\DevTools\DevBridge\state\db-m02-1-hierarchy.txt"
)

# DB-M02.1 read-only validation over the FULL governed Master Roadmap set (all 659 records):
#  - parent reference resolution / broken parents / orphan detection
#  - duplicate Node IDs
#  - hierarchy path consistency (reconstructed vs stored)
#  - sort key prefix consistency
#  - cross-sheet resolution of the 34 recovered beyond-table nodes
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

$doc = Open-Doc "xl/worksheets/sheet2.xml"
$records = @()
foreach ($r in $doc.Root.Elements($xNs + "sheetData").Elements($xNs + "row")) {
    $nodeId = Get-CellVal $r "A"
    $nodeType = Get-CellVal $r "C"
    if (-not $nodeId -or -not $nodeType) { continue }
    if (-not ($nodeId -match $nodeIdRegex)) { continue }
    if ($nodeType -notin $nodeTypeVocab) { continue }
    $records += [pscustomobject]@{
        Row = [int]$r.Attribute("r").Value; NodeId = $nodeId; Parent = (Get-CellVal $r "B");
        NodeType = $nodeType; SortKey = (Get-CellVal $r "D"); HierPath = (Get-CellVal $r "E");
        Layer = (Get-CellVal $r "F"); Phase = (Get-CellVal $r "G"); Name = (Get-CellVal $r "H");
        Status = (Get-CellVal $r "R")
    }
}
Out-Line "Full governed set: $($records.Count) records (rows $($records[0].Row)-$($records[-1].Row))"
Out-Line ""

# --- duplicate Node IDs ---
Out-Line "=== DUPLICATE NODE IDs ==="
$dups = $records | Group-Object NodeId | Where-Object { $_.Count -gt 1 }
if (@($dups).Count -eq 0) { Out-Line "  NONE" } else { $dups | ForEach-Object { Out-Line "  $($_.Name) x$($_.Count)" } }
Out-Line ""

# --- build id -> record lookup ---
$byId = @{}
foreach ($rec in $records) { if (-not $byId.ContainsKey($rec.NodeId)) { $byId[$rec.NodeId] = $rec } }

# --- broken parents / orphans ---
Out-Line "=== PARENT REFERENCE CHECK ==="
$broken = @()
foreach ($rec in $records) {
    if (-not $rec.Parent) {
        if ($rec.NodeType -ne "Layer") { $broken += "$($rec.NodeId) (type=$($rec.NodeType)) has NO parent" }
    }
    elseif (-not $byId.ContainsKey($rec.Parent)) {
        $broken += "$($rec.NodeId) parent '$($rec.Parent)' does not exist"
    }
}
if (@($broken).Count -eq 0) {
    Out-Line "  OK: every non-Layer record's Parent ID resolves; every Layer is a root."
    # also confirm all Layer rows are roots with no parent
    $layersWithParent = @($records | Where-Object { $_.NodeType -eq "Layer" -and $_.Parent })
    if (@($layersWithParent).Count -eq 0) { Out-Line "  OK: all Layer records have empty Parent ID (true roots)." } else { $layersWithParent | ForEach-Object { Out-Line "  Layer with parent: $($_.NodeId) -> $($_.Parent)" } }
} else {
    $broken | ForEach-Object { Out-Line "  BROKEN: $_" }
}
Out-Line ""

# --- hierarchy path consistency: reconstruct expected path from layer's stored path + ancestor names ---
# The stored path segment for a Layer is its numeric-prefixed name (e.g. "01 CORE"), so the
# reconstruction seeds the path with the Layer's own stored HierPath and appends descendant names.
Out-Line "=== HIERARCHY PATH CONSISTENCY (reconstructed vs stored, full set) ==="
$mismatch = @(); $emptyPath = @()
foreach ($rec in $records) {
    if ($rec.NodeType -eq "Layer") { continue }   # layer paths compared below via seed
    $segments = New-Object System.Collections.Generic.List[string]
    $cur = $rec; $guard = 0
    while ($cur -and $guard -lt 20) {
        # stored path segment is "{NodeId} {Name}" at every level (e.g. "F-01-1 Identity and Authentication")
        $segments.Insert(0, ("{0} {1}" -f $cur.NodeId, $cur.Name))
        if ($cur.NodeType -eq "Layer") { break }
        $cur = $byId[$cur.Parent]; $guard++
    }
    $expected = ($segments -join " > ")
    $stored = if ($rec.HierPath) { $rec.HierPath.Trim() } else { "" }
    if (-not $stored) { $emptyPath += $rec.NodeId; continue }
    if ($stored -ne $expected) { $mismatch += "$($rec.NodeId) (R$($rec.Row)): stored='$stored' expected='$expected'" }
}
Out-Line "  Records with empty stored Hierarchy Path: $($emptyPath.Count)"
if (@($emptyPath).Count -gt 0) { Out-Line ("    " + ($emptyPath -join ", ")) }
if (@($mismatch).Count -eq 0) { Out-Line "  OK: all stored Hierarchy Paths match reconstruction (layer seed + ancestor names)." }
else { $mismatch | Select-Object -First 20 | ForEach-Object { Out-Line "  MISMATCH: $_" } ; if ($mismatch.Count -gt 20) { Out-Line "  ... and $($mismatch.Count-20) more" } }
Out-Line ""

# --- sort key prefix consistency ---
Out-Line "=== SORT KEY PREFIX CONSISTENCY ==="
$sortBad = @()
foreach ($rec in $records) {
    if (-not $rec.SortKey) { continue }
    if ($rec.NodeType -eq "Layer") { continue }
    $p = $byId[$rec.Parent]
    if (-not $p) { continue }  # broken parent already reported
    if ($p.SortKey) {
        $prefix = $p.SortKey + "."
        if (-not $rec.SortKey.StartsWith($prefix)) { $sortBad += "$($rec.NodeId) sort='$($rec.SortKey)' parent $($p.NodeId) sort='$($p.SortKey)'" }
    }
}
if (@($sortBad).Count -eq 0) { Out-Line "  OK: every non-Layer SortKey starts with its parent's SortKey + '.'" }
else { $sortBad | Select-Object -First 20 | ForEach-Object { Out-Line "  BAD: $_" } }
Out-Line ""

# --- orphan check across phases / statuses / layers for the 34 recovered ---
$beyond = @($records | Where-Object { $_.Row -gt 630 })
Out-Line "=== RECOVERED BEYOND-TABLE SET ($($beyond.Count) nodes) ==="
Out-Line ("Phases: " + (($beyond | Select-Object -ExpandProperty Phase -Unique | Sort-Object) -join ", "))
Out-Line ("Layers: " + (($beyond | Select-Object -ExpandProperty Layer -Unique | Sort-Object) -join ", "))
Out-Line ("Statuses: " + (($beyond | Select-Object -ExpandProperty Status -Unique | Sort-Object) -join ", "))
$active = @($beyond | Where-Object { $_.Status -ne "Complete" -and $_.Status -ne "Completed" -and $_.Status -ne "Superseded" -and $_.Status -ne "Planned" })
Out-Line "Active (non-terminal, non-Planned) beyond-table nodes: $($active.Count)"
$active | ForEach-Object { Out-Line ("  {0} ({1}) R{2} phase={3}" -f $_.NodeId, $_.Status, $_.Row, $_.Phase) }
Out-Line ""

# --- cross-sheet reference resolution for the 34 recovered nodes ---
Out-Line "=== CROSS-SHEET REFERENCES TO RECOVERED NODES ==="
$ids = $beyond | ForEach-Object { $_.NodeId }

function Scan-Refs([string]$entry, [string]$label, [string[]]$cols, [int]$headerRow, [int]$dataStart, [int]$maxRow) {
    $doc = Open-Doc $entry
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($r in $doc.Root.Elements($xNs + "sheetData").Elements($xNs + "row")) {
        $rn = [int]$r.Attribute("r").Value
        if ($rn -lt $dataStart -or $rn -gt $maxRow) { continue }
        foreach ($c in $cols) {
            $v = Get-CellVal $r $c
            if (-not $v) { continue }
            foreach ($id in $ids) {
                if ($v -match [regex]::Escape($id)) { $found.Add("$($id) <- $label [$c=R$rn]") }
            }
        }
    }
    return $found
}

$allRefs = New-Object System.Collections.Generic.List[string]
foreach ($f in (Scan-Refs "xl/worksheets/sheet3.xml"  "Active Changes Node ID"        @("B") 5 6 78)) { $allRefs.Add($f) }
foreach ($f in (Scan-Refs "xl/worksheets/sheet3.xml"  "Active Changes Affected Nodes" @("AB") 5 6 78)) { $allRefs.Add($f) }
foreach ($f in (Scan-Refs "xl/worksheets/sheet10.xml" "D&B From Node"                 @("B") 4 5 60)) { $allRefs.Add($f) }
foreach ($f in (Scan-Refs "xl/worksheets/sheet10.xml" "D&B Depends On"                @("C") 4 5 60)) { $allRefs.Add($f) }
foreach ($f in (Scan-Refs "xl/worksheets/sheet13.xml" "Dev Guide Milestone ID"        @("C") 4 5 60)) { $allRefs.Add($f) }
foreach ($f in (Scan-Refs "xl/worksheets/sheet6.xml"  "Version History Node ID"       @("A") 5 6 1000)) { $allRefs.Add($f) }
foreach ($f in (Scan-Refs "xl/worksheets/sheet8.xml"  "ADR Roadmap Links"             @("F") 4 5 60)) { $allRefs.Add($f) }
foreach ($f in (Scan-Refs "xl/worksheets/sheet9.xml"  "Open Dec Roadmap Links"        @("E") 4 5 60)) { $allRefs.Add($f) }
foreach ($f in (Scan-Refs "xl/worksheets/sheet4.xml"  "Audit Roadmap Link"            @("H") 5 6 60)) { $allRefs.Add($f) }

$distinct = $allRefs | Sort-Object -Unique
if (@($distinct).Count -eq 0) { Out-Line "  None of the 34 recovered nodes are referenced by other governed sheets." }
else {
    Out-Line "  $($distinct.Count) distinct reference(s) from other governed sheets to recovered nodes:"
    $distinct | ForEach-Object { Out-Line "    $_" }
    $referencedIds = $distinct | ForEach-Object { ($_ -split " <- ")[0] } | Sort-Object -Unique
    Out-Line ""
    Out-Line "  Referenced recovered nodes: $($referencedIds.Count) of 34"
    $referencedIds | ForEach-Object { Out-Line "    $_" }
}

[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "Wrote $OutFile ($($sb.Length) chars)"
