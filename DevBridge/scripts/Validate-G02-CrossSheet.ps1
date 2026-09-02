param(
    [string]$OutFile = "C:\Personal\DevTools\DevBridge\state\db-g02-crosssheet-rerun.txt"
)

# DB-G02 rerun (V6): cross-sheet reference resolution against the FULL governed Master Roadmap
# universe (659 RoadmapNode records, corrected by DB-M02.1). For each reference column, every
# non-empty value is resolved against the node set; node-ID tokens are extracted from free text.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null
$xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
$cfg = Get-Content "C:\Personal\DevTools\DevBridge\config\devbridge.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$wb = $cfg.developmentControlWorkbook

$nodeIdRegex = '(F-\d+-\d+|M-\d+-\d+\.\d+|WI-\d+-\d+\.\d+\.\d+|T-\d+-\d+\.\d+\.\d+\.\d+|S-\d+-\d+\.\d+\.\d+\.\d+\.\d+)'
$layerRegex = '^(0\d)$'

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

# ---- Build the full governed node set (structural scan, DB-M02.1 detection rule) ----
$nodeTypeVocab = @("Layer", "Feature", "Milestone", "WorkItem", "Task", "Subtask")
$roadmapRegex = '^(F-\d+-\d+|M-\d+-\d+\.\d+|WI-\d+-\d+\.\d+\.\d+|T-\d+-\d+\.\d+\.\d+\.\d+|S-\d+-\d+\.\d+\.\d+\.\d+\.\d+|\d{2})$'
$doc = Open-Doc "xl/worksheets/sheet2.xml"
$nodes = @{}
$nodeList = @()
$beyondCount = 0
foreach ($r in $doc.Root.Elements($xNs + "sheetData").Elements($xNs + "row")) {
    $id = Get-CellVal $r "A"; $typ = Get-CellVal $r "C"
    if (-not $id -or -not $typ) { continue }
    if (-not ($id -match $roadmapRegex)) { continue }
    if ($typ -notin $nodeTypeVocab) { continue }
    if (-not $nodes.ContainsKey($id)) { $nodes[$id] = $true; $nodeList += $id }
    if ([int]$r.Attribute("r").Value -gt 630) { $beyondCount++ }
}
Out-Line "Full governed node universe: $($nodeList.Count) RoadmapNode records (DB-M02.1 governedDataRange)"

# ---- Resolve a single value against the node set ----
function Test-Value([string]$val) {
    # exact match (single ID or layer code)
    if ($nodes.ContainsKey($val.Trim())) { return $true }
    # extract node-ID tokens and layer tokens from free text / multi-ID cells
    $tokens = @()
    foreach ($m in [regex]::Matches($val, $nodeIdRegex)) { $tokens += $m.Value }
    foreach ($m in [regex]::Matches($val, $layerRegex)) { $tokens += $m.Value }
    if (@($tokens).Count -eq 0) { return $false }
    foreach ($tk in $tokens) { if (-not $nodes.ContainsKey($tk)) { return $false } }
    return $true
}

function Resolve-Field([string]$entry, [string]$label, [string]$headerText, [int]$headerRow, [int]$dataStart, [int]$dataEnd) {
    $d = Open-Doc $entry
    # find column letter for headerText
    $colLetter = ""
    foreach ($row in $d.Root.Elements($xNs + "sheetData").Elements($xNs + "row")) {
        if ([int]$row.Attribute("r").Value -ne $headerRow) { continue }
        foreach ($cell in $row.Elements($xNs + "c")) {
            $ref = [string]$cell.Attribute("r").Value
            $t = ""; $tAttr = $cell.Attribute("t"); if ($tAttr) { $t = [string]$tAttr.Value }
            $v = $null
            if ($t -eq "inlineStr") { $is = $cell.Element($xNs + "is"); if ($is) { $v = [string]$is.Value } }
            else { $ve = $cell.Element($xNs + "v"); if ($ve) { $v = $ve.Value } }
            if ($null -ne $v -and ([string]$v).Trim() -eq $headerText) { $colLetter = ($ref -replace "[0-9]", ""); break }
        }
        if ($colLetter) { break }
    }
    if (-not $colLetter) { Out-Line "${label}: HEADER '$headerText' NOT FOUND (row $headerRow)"; return }
    $total = 0; $resolved = 0; $unresolved = New-Object System.Collections.Generic.List[string]
    foreach ($row in $d.Root.Elements($xNs + "sheetData").Elements($xNs + "row")) {
        $rn = [int]$row.Attribute("r").Value
        if ($rn -lt $dataStart -or $rn -gt $dataEnd) { continue }
        $v = Get-CellVal $row $colLetter
        if (-not $v) { continue }
        $total++
        if (Test-Value $v) { $resolved++ } else { $unresolved.Add("R${rn}: $v") }
    }
    $pct = if ($total -gt 0) { [math]::Round(100.0 * $resolved / $total, 1) } else { 100.0 }
    Out-Line "${label}: $resolved / $total ($pct%)  [col $colLetter]"
    if (@($unresolved).Count -gt 0) { $unresolved | Select-Object -First 8 | ForEach-Object { Out-Line "    unresolved: $_" } ; if ($unresolved.Count -gt 8) { Out-Line "    ... and $($unresolved.Count-8) more" } }
}

Out-Line ""
Out-Line "=== CROSS-SHEET RESOLUTION VS FULL 659-NODE UNIVERSE ==="

# Master Roadmap internal
Resolve-Field "xl/worksheets/sheet2.xml"  "Master Roadmap Parent ID     " "Parent ID" 5 6 675
Resolve-Field "xl/worksheets/sheet2.xml"  "Master Roadmap Dependencies  " "Dependencies" 5 6 675

# Active Changes
Resolve-Field "xl/worksheets/sheet3.xml"  "Active Changes Node ID       " "Node ID" 5 6 78
Resolve-Field "xl/worksheets/sheet3.xml"  "Active Changes Affected Nodes" "Affected Nodes" 5 6 78

# Version History
Resolve-Field "xl/worksheets/sheet6.xml"  "Version History Node ID      " "Node ID" 5 6 1000
Resolve-Field "xl/worksheets/sheet6.xml"  "Version History Parent ID    " "Parent ID" 5 6 1000

# Development Guide
Resolve-Field "xl/worksheets/sheet13.xml" "Dev Guide Milestone ID       " "Milestone ID" 4 5 60

# Dependencies & Blockers
Resolve-Field "xl/worksheets/sheet10.xml" "D&B From Node                " "From Node" 4 5 60
Resolve-Field "xl/worksheets/sheet10.xml" "D&B Depends On / Blocks      " "Depends On / Blocks" 4 5 60

# Architecture Decisions
Resolve-Field "xl/worksheets/sheet8.xml"  "ADR Roadmap Links            " "Roadmap Links" 4 5 60

# Open Decisions
Resolve-Field "xl/worksheets/sheet9.xml"  "Open Dec Roadmap Links       " "Roadmap Links" 4 5 60
Resolve-Field "xl/worksheets/sheet9.xml"  "Open Dec Resolution / ADR    " "Resolution / ADR" 4 5 60

# Audit Findings
Resolve-Field "xl/worksheets/sheet4.xml"  "Audit Roadmap Link           " "Roadmap Link" 5 6 60

# Phase Plan
Resolve-Field "xl/worksheets/sheet7.xml"  "Phase Plan Roadmap Link      " "Roadmap Link" 4 5 60

# Recovered-node resolution
Out-Line ""
Out-Line "Recovered beyond-table nodes now in the governed universe and resolvable: $beyondCount of 34"

[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "Wrote $OutFile"
