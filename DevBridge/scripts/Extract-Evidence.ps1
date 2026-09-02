param(
    [string]$OutFile = "C:\Personal\DevTools\DevBridge\state\db-g02-evidence.txt"
)

# DB-G02 read-only evidence extraction: Active Changes status classification and
# Dependencies & Blockers full dump. Writes to $OutFile. Never modifies the workbook.
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

function Get-ColVal($row, [string]$col) {
    foreach ($cell in $row.Elements($xNs + "c")) {
        $ref = [string]$cell.Attribute("r").Value
        if (($ref -replace "[0-9]", "") -eq $col) {
            $t = ""
            $tAttr = $cell.Attribute("t"); if ($tAttr) { $t = [string]$tAttr.Value }
            if ($t -eq "inlineStr") { $is = $cell.Element($xNs + "is"); if ($is) { return [string]$is.Value } }
            $v = $cell.Element($xNs + "v"); if ($v) { return $v.Value }
            return ""
        }
    }
    return ""
}

# ---- Active Changes classification ----
$doc = Open-Doc "xl/worksheets/sheet3.xml"
$rows = @($doc.Root.Elements($xNs + "sheetData").Elements($xNs + "row") | Where-Object { $rn = [int]$_.Attribute("r").Value; $rn -ge 6 -and $rn -le 78 })
Out-Line "=== ACTIVE CHANGES (sheet3) rows 6-78 : $($rows.Count) rows ==="
$classified = @()
foreach ($r in $rows) {
    $id = Get-ColVal $r "A"
    if (-not $id) { continue }
    $st = Get-ColVal $r "L"
    $lc = $st.ToLower()
    $cls = "Open"
    if ($lc.StartsWith("completed") -or $lc.StartsWith("cancelled") -or $lc.StartsWith("complete ")) { $cls = "Terminal" }
    elseif ($lc.StartsWith("blocked")) { $cls = "Blocked" }
    elseif ($lc.StartsWith("in progress")) { $cls = "InProgress" }
    $classified += [pscustomobject]@{
        ID = $id; Node = (Get-ColVal $r "B"); Class = $cls; Status = $st; Worker = (Get-ColVal $r "F");
        Verdict = (Get-ColVal $r "M"); Branch = (Get-ColVal $r "Q"); Affected = (Get-ColVal $r "AB")
    }
}
Out-Line "Classification by leading keyword:"
$classified | Group-Object Class | ForEach-Object { Out-Line "  $($_.Name): $($_.Count)" }
Out-Line ""
Out-Line "Open / InProgress / Blocked reservations (NOT terminal):"
$classified | Where-Object { $_.Class -ne "Terminal" } | ForEach-Object {
    Out-Line "  $($_.ID) node=$($_.Node) class=$($_.Class) verdict=$($_.Verdict) worker=$($_.Worker) branch=$($_.Branch) affected=$($_.Affected)"
}
Out-Line ""
Out-Line "Terminal examples (first 6):"
$classified | Where-Object { $_.Class -eq "Terminal" } | Select-Object -First 6 | ForEach-Object {
    $short = $_.Status; if ($short.Length -gt 70) { $short = $short.Substring(0, 70) + "..." }
    Out-Line "  $($_.ID) node=$($_.Node) status=$short"
}
Out-Line ""
Out-Line "Preflight verdict vocabulary observed:"
($classified | Select-Object -ExpandProperty Verdict | Where-Object { $_ } | Sort-Object -Unique) | ForEach-Object { Out-Line "  $_" }
Out-Line ""

# ---- Dependencies & Blockers full dump ----
$doc = Open-Doc "xl/worksheets/sheet10.xml"
$rows = @($doc.Root.Elements($xNs + "sheetData").Elements($xNs + "row") | Where-Object { $rn = [int]$_.Attribute("r").Value; $rn -ge 5 -and $rn -le 15 })
Out-Line "=== DEPENDENCIES & BLOCKERS (sheet10) rows 5-15 ==="
foreach ($r in $rows) {
    $rid = Get-ColVal $r "A"
    if (-not $rid) { continue }
    Out-Line "  $rid | from=$(Get-ColVal $r "B") | depsOn=$(Get-ColVal $r "C") | type=$(Get-ColVal $r "D") | blocking=$(Get-ColVal $r "E") | status=$(Get-ColVal $r "F") | reason=$(Get-ColVal $r "G") | owner=$(Get-ColVal $r "H") | change=$(Get-ColVal $r "I")"
}
Out-Line ""

# ---- Master Roadmap textual Dependencies for nodes that appear in Dependencies & Blockers ----
$doc = Open-Doc "xl/worksheets/sheet2.xml"
$rows = @($doc.Root.Elements($xNs + "sheetData").Elements($xNs + "row") | Where-Object { $rn = [int]$_.Attribute("r").Value; $rn -ge 6 })
$nodes = @{}
foreach ($r in $rows) {
    $id = Get-ColVal $r "A"
    if (-not $id) { continue }
    $nodes[$id] = [pscustomobject]@{ Node = $id; TextDep = (Get-ColVal $r "J"); Status = (Get-ColVal $r "R") }
}
Out-Line "=== TEXTUAL Dependencies (Master Roadmap col J) for Dependencies & Blockers participant nodes ==="
foreach ($p in @("F-06-7", "F-07-6", "M-02-1.2", "M-01-1.1", "M-07-1.2", "F-07-2", "F-07-5")) {
    if ($nodes.ContainsKey($p)) { Out-Line "  $p  textDep='$($nodes[$p].TextDep)'  status=$($nodes[$p].Status)" }
    else { Out-Line "  $p  (not found in Master Roadmap sample)" }
}

[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "Wrote $OutFile ($($sb.Length) chars)"
