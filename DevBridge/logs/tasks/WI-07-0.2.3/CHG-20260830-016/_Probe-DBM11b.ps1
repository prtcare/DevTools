# _Probe-DBM11b.ps1 - READ-ONLY follow-up probe for DB-M11.
# ASCII-only. Never writes the workbook. Appends to state\db-m11-extraction.txt.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null
$xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
$xRel = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/officeDocument/2006/relationships"
$cfg = Get-Content "C:\Personal\DevTools\DevBridge\config\devbridge.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$wb = $cfg.developmentControlWorkbook

$sb = New-Object System.Text.StringBuilder
function Out-Line([string]$t) { [void]$sb.AppendLine($t) }

$fs = [System.IO.File]::Open($wb, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
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
        $sheetNames = New-Object System.Collections.Generic.List[string]
        $sheetRids = @{}
        foreach ($s in $wbXml.Root.Elements($xNs + "sheets").Elements($xNs + "sheet")) {
            $sheetNames.Add([string]$s.Attribute("name").Value)
            $sheetRids[[string]$s.Attribute("name").Value] = [string]$s.Attribute($xRel + "id").Value
        }
        $rd2 = New-Object System.IO.StreamReader($zip.GetEntry("xl/_rels/workbook.xml.rels").Open())
        $relsXml = [System.Xml.Linq.XDocument]::Load($rd2); $rd2.Close()
        $rels = @{}
        foreach ($rel in $relsXml.Root.Elements()) { $rels[[string]$rel.Attribute("Id").Value] = [string]$rel.Attribute("Target").Value }
        function Get-SheetEntry([string]$name) {
            $p = $rels[$sheetRids[$name]]
            if ($p.StartsWith("/")) { $p = $p.TrimStart("/") } else { $p = "xl/" + $p }
            if (-not $p.ToLower().EndsWith(".xml")) { $p = $p + ".xml" }
            return $p
        }
        function Get-AllRows($entry) {
            $rdx = New-Object System.IO.StreamReader($zip.GetEntry($entry).Open())
            $doc = [System.Xml.Linq.XDocument]::Load($rdx); $rdx.Close()
            $rnList = New-Object System.Collections.Generic.List[int]
            $map = @{}
            foreach ($row in $doc.Root.Element($xNs + "sheetData").Elements($xNs + "row")) {
                $rn = [int]$row.Attribute("r").Value
                $rnList.Add($rn)
                $m = @{}
                foreach ($cell in $row.Elements($xNs + "c")) {
                    $ref = [string]$cell.Attribute("r").Value
                    $col = $ref -replace '\d+$', ''
                    $tAttr = $cell.Attribute("t"); $t = if ($tAttr) { [string]$tAttr.Value } else { "" }
                    $val = ""
                    if ($t -eq "inlineStr") { $is = $cell.Element($xNs + "is"); if ($is) { $val = [string]$is.Value } }
                    else { $v = $cell.Element($xNs + "v"); if ($v) { if ($t -eq "s") { $idx = [int]$v.Value; if ($idx -ge 0 -and $idx -lt $shared.Count) { $val = $shared[$idx] } } else { $val = [string]$v.Value } } }
                    $m[$col] = $val
                }
                $map[$rn] = $m
            }
            return [pscustomobject]@{ rnList = $rnList; map = $map }
        }
        function Get-Gaps([string]$label, [int[]]$rnList) {
            $expected = 1..$rnList[-1]
            $missing = @($expected | Where-Object { $rnList -notcontains $_ })
            Out-Line ("{0}: rowElements={1} minRow={2} maxRow={3} missingRows=[{4}]" -f $label, $rnList.Count, $rnList[0], $rnList[-1], $(if ($missing.Count -gt 0) { ($missing | ForEach-Object { "$_"; }) -join "," } else { "NONE" }))
        }

        # ---- ROW SEQUENCES (Part 1 / 3 / 19) ----
        $sheetsToScan = @("Master Roadmap", "Active Changes", "Activity Log", "Version History", "Audit Findings", "Tool & Integration Registry", "Existing Assets", "Open Decisions", "Dependencies & Blockers", "Architecture Decisions", "Phase Plan", "Development Guide", "Control Center", "Session Protocol")
        foreach ($sn in $sheetsToScan) {
            $all = Get-AllRows (Get-SheetEntry $sn)
            Get-Gaps $sn $all.rnList
        }

        # ---- MR D/E sort/hierarchy columns + row 675 + M-07-0.1 + WI-07-0.2.4 (Part 16 / 6 / 15) ----
        $mr = Get-AllRows (Get-SheetEntry "Master Roadmap")
        Out-Line ""
        Out-Line "MR hierarchy columns D/E for M-07 chain and beyond-table rows:"
        foreach ($rn in @(324, 325, 326, 327, 675)) {
            if ($mr.map.ContainsKey($rn)) {
                $m = $mr.map[$rn]
                Out-Line ("  row {0}: A=[{1}] B=[{2}] C=[{3}] D=[{4}] E=[{5}] F=[{6}] G=[{7}]" -f $rn, $m["A"], $m["B"], $m["C"], $m["D"], $m["E"], $m["F"], $m["G"])
            } else { Out-Line ("  row {0}: ABSENT" -f $rn) }
        }
        # sort-key uniqueness across whole MR (column D)
        $dVals = @{}
        $dDupes = @()
        foreach ($rn in $mr.rnList) {
            $m = $mr.map[$rn]; $d = $m["D"]
            if ($d) { if ($dVals.ContainsKey($d)) { if (-not ($dDupes -contains $d)) { $dDupes += $d } } else { $dVals[$d] = $rn } }
        }
        Out-Line ("MR column D (sort key) unique values={0} dupes=[{1}]" -f $dVals.Count, $(if ($dDupes.Count -gt 0) { ($dDupes | Select-Object -First 10) -join "," } else { "NONE" }))
        # parent status check for M-07 chain
        foreach ($rn in @(324)) { if ($mr.map.ContainsKey($rn)) { $m = $mr.map[$rn]; Out-Line ("M-07-0.2 dependency J=[{0}]" -f $m["J"]) } }
        foreach ($rn in $mr.rnList) { $m = $mr.map[$rn]; if ($m["A"] -eq "M-07-0.1") { Out-Line ("M-07-0.1 row {0}: R=[{1}] T=[{2}] J=[{3}]" -f $rn, $m["R"], $m["T"], $m["J"]) } }
        foreach ($rn in $mr.rnList) { $m = $mr.map[$rn]; if ($m["A"] -eq "WI-07-0.2.4") { Out-Line ("WI-07-0.2.4 row {0}: R=[{1}] T=[{2}] J=[{3}] P=[{4}]" -f $rn, $m["R"], $m["T"], $m["J"], $m["P"]) } }

        # ---- AC row inventory (Part 4) ----
        $ac = Get-AllRows (Get-SheetEntry "Active Changes")
        Out-Line ""
        Out-Line "AC row inventory (rn -> ChangeID / Status-lead):"
        foreach ($rn in $ac.rnList) {
            $m = $ac.map[$rn]; $cid = $m["A"]; $st = $m["L"]
            if ($cid) { Out-Line ("  row {0}: A=[{1}] L-lead=[{2}]" -f $rn, $cid, $(if ($st) { $st.Substring(0, [Math]::Min(24, $st.Length)) } else { "" })) }
        }
        # CHG-016 occurrences across AC
        $chg016rows = @($ac.rnList | Where-Object { $ac.map[$_]["A"] -eq "CHG-20260830-016" })
        Out-Line ("AC rows with ChangeID CHG-20260830-016: [{0}]" -f $(if ($chg016rows.Count -gt 0) { $chg016rows -join "," } else { "NONE" }))

        # ---- VH global Is-Current uniqueness (Part 3) ----
        $vh = Get-AllRows (Get-SheetEntry "Version History")
        Out-Line ""
        $vhCurrentYes = @{}
        $multiYes = @()
        foreach ($rn in $vh.rnList) {
            $m = $vh.map[$rn]; $nid = $m["A"]
            if ($nid -and $m["AC"] -eq "Yes") {
                if ($vhCurrentYes.ContainsKey($nid)) { if (-not ($multiYes -contains $nid)) { $multiYes += $nid } } else { $vhCurrentYes[$nid] = $rn }
            }
        }
        Out-Line ("VH nodes with Is Current=Yes: count={0} nodes-with-multiple-Yes=[{1}]" -f $vhCurrentYes.Count, $(if ($multiYes.Count -gt 0) { $multiYes -join "," } else { "NONE" }))
        # VH record-version duplicates for same node (AE supersedes integrity sample)
        $vhVersionDupes = @{}
        foreach ($rn in $vh.rnList) {
            $m = $vh.map[$rn]; $nid = $m["A"]; $aa = $m["AA"]
            if ($nid -and $aa) { $k = "$nid|$aa"; if ($vhVersionDupes.ContainsKey($k)) { $vhVersionDupes[$k] += ",$rn" } else { $vhVersionDupes[$k] = "$rn" } }
        }
        $badVer = @($vhVersionDupes.Keys | Where-Object { $vhVersionDupes[$_] -match ',' })
        Out-Line ("VH duplicate (node,record-version) pairs: {0}" -f $(if ($badVer.Count -gt 0) { ($badVer | ForEach-Object { "$_ (rows $($vhVersionDupes[$_]))" }) -join " | " } else { "NONE" }))

        # ---- AF-010 full (Part 11) ----
        $af = Get-AllRows (Get-SheetEntry "Audit Findings")
        Out-Line ""
        foreach ($rn in $af.rnList) {
            $m = $af.map[$rn]
            if ($m["A"] -eq "AF-010") {
                $cols = @("A","B","C","D","E","F","G","H")
                $line = ($cols | ForEach-Object { "$_=[$($m[$_])]" }) -join " "
                Out-Line ("AF-010 row {0}: {1}" -f $rn, $line)
            }
        }
        # Audit Finding ID uniqueness
        $afIds = @{}; $afDupes = @()
        foreach ($rn in $af.rnList) { $id = $af.map[$rn]["A"]; if ($id -and $id -match '^AF-\d') { if ($afIds.ContainsKey($id)) { $afDupes += $id } else { $afIds[$id] = $rn } } }
        Out-Line ("Audit Finding IDs count={0} dupes=[{1}]" -f $afIds.Count, $(if ($afDupes.Count -gt 0) { $afDupes -join "," } else { "NONE" }))

        # ---- AL result/evidence cols for rows 53/54 (Part 5) ----
        $al = Get-AllRows (Get-SheetEntry "Activity Log")
        Out-Line ""
        foreach ($rn in @(53, 54)) {
            if ($al.map.ContainsKey($rn)) {
                $m = $al.map[$rn]
                Out-Line ("AL row {0}: A=[{1}] B=[{2}] J=[{3}] N=[{4}] P=[{5}] AA=[{6}] AB=[{7}] AC-evidence=[{8}] AG=[{9}]" -f $rn, $m["A"], $m["B"], $m["J"], $m["N"], $m["P"], $m["AA"], $m["AB"], $(if ($m["AC"]) { $m["AC"].Substring(0, [Math]::Min(160, $m["AC"].Length)) } else { "" }), $m["AG"])
            }
        }

        # ---- Development Guide headers / what it mirrors (Part 7) ----
        $dg = Get-AllRows (Get-SheetEntry "Development Guide")
        Out-Line ""
        foreach ($rn in @(1, 2, 3, 4, 5, 6)) {
            if ($dg.map.ContainsKey($rn)) { $m = $dg.map[$rn]; $line = ($m.Keys | Sort-Object | ForEach-Object { "$_=[$($m[$_])]" }) -join " "; Out-Line ("DG row {0}: {1}" -f $rn, $line.Substring(0, [Math]::Min(300, $line.Length))) }
        }
    } finally { $zip.Dispose() }
} finally { $fs.Dispose() }

[System.IO.File]::AppendAllText("C:\Personal\DevTools\DevBridge\state\db-m11-extraction.txt", $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "Appended $($sb.Length) chars to state\db-m11-extraction.txt"
