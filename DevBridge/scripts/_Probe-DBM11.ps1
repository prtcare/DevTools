# _Probe-DBM11.ps1 - READ-ONLY. Full extraction of the authoritative workbook for
# DB-M11 cross-sheet consistency validation. Dumps to state\db-m11-extraction.txt.
# ASCII-only. Never writes the workbook.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null
$xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
$xRel = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/officeDocument/2006/relationships"
$cfg = Get-Content "C:\Personal\DevTools\DevBridge\config\devbridge.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$wb = $cfg.developmentControlWorkbook
$OutFile = "C:\Personal\DevTools\DevBridge\state\db-m11-extraction.txt"

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

        # ---- SHEET LIST (Part 1) ----
        $rd = New-Object System.IO.StreamReader($zip.GetEntry("xl/workbook.xml").Open())
        $wbXml = [System.Xml.Linq.XDocument]::Load($rd); $rd.Close()
        $sheetNames = New-Object System.Collections.Generic.List[string]
        $sheetRids = @{}
        foreach ($s in $wbXml.Root.Elements($xNs + "sheets").Elements($xNs + "sheet")) {
            $n = [string]$s.Attribute("name").Value
            $sheetNames.Add($n); $sheetRids[$n] = [string]$s.Attribute($xRel + "id").Value
        }
        Out-Line ("SHEETS (count={0})" -f $sheetNames.Count)
        for ($i = 0; $i -lt $sheetNames.Count; $i++) { Out-Line ("  [{0}] {1}" -f ($i + 1), $sheetNames[$i]) }
        $dupNames = $sheetNames | Group-Object | Where-Object { $_.Count -gt 1 }
        Out-Line ("DUPLICATE_SHEET_NAMES: {0}" -f $(if ($dupNames) { ($dupNames | ForEach-Object { $_.Name }) -join "," } else { "NONE" }))

        # rels map
        $rd2 = New-Object System.IO.StreamReader($zip.GetEntry("xl/_rels/workbook.xml.rels").Open())
        $relsXml = [System.Xml.Linq.XDocument]::Load($rd2); $rd2.Close()
        $rels = @{}
        foreach ($rel in $relsXml.Root.Elements()) { $rels[[string]$rel.Attribute("Id").Value] = [string]$rel.Attribute("Target").Value }

        function Get-SheetEntry([string]$name) {
            $rid = $sheetRids[$name]
            $p = $rels[$rid]
            if ($p.StartsWith("/")) { $p = $p.TrimStart("/") } else { $p = "xl/" + $p }
            if (-not $p.ToLower().EndsWith(".xml")) { $p = $p + ".xml" }
            return $p
        }
        function Get-CellMap($entry) {
            # returns ordered list of @{rn; cells{col->val}}
            $rdx = New-Object System.IO.StreamReader($zip.GetEntry($entry).Open())
            $doc = [System.Xml.Linq.XDocument]::Load($rdx); $rdx.Close()
            $rows = New-Object System.Collections.Generic.List[object]
            foreach ($row in $doc.Root.Element($xNs + "sheetData").Elements($xNs + "row")) {
                $rn = [int]$row.Attribute("r").Value
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
                $rows.Add([pscustomobject]@{ rn = $rn; m = $m })
            }
            return $rows
        }

        # ---- MASTER ROADMAP (Part 2/3/15/16/17) ----
        $eMR = Get-SheetEntry "Master Roadmap"
        $mrRows = Get-CellMap $eMR
        Out-Line ""
        Out-Line ("MASTER ROADMAP rows={0}" -f $mrRows.Count)
        Out-Line "MR M-07 CHAIN rows 324-327 (A..AD selected):"
        foreach ($r in $mrRows) {
            if ($r.rn -lt 324 -or $r.rn -gt 327) { continue }
            $m = $r.m
            $sel = @("A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z","AA","AB","AC","AD")
            Out-Line ("  row {0}: A=[{1}] B=[{2}] C=[{3}] J=[{4}] P=[{5}] R=[{6}] T=[{7}] U=[{8}] V=[{9}] Z=[{10}] AA=[{11}] AC=[{12}] AD=[{13}]" -f $r.rn,
                $m["A"], $m["B"], $m["C"], $m["J"], $m["P"], $m["R"], $m["T"], $m["U"], $m["V"], $m["Z"],
                $(if ($m["AA"]) { $m["AA"].Substring(0, [Math]::Min(120, $m["AA"].Length)) } else { "" }),
                $(if ($m["AC"]) { $m["AC"].Substring(0, [Math]::Min(120, $m["AC"].Length)) } else { "" }),
                $(if ($m["AD"]) { $m["AD"].Substring(0, [Math]::Min(120, $m["AD"].Length)) } else { "" }))
        }
        # Hierarchy scan (Part 16)
        $allNodeIds = @{}; $dupes = @()
        $milestoneIds = New-Object System.Collections.Generic.HashSet[string]
        $workItemParents = @()
        foreach ($r in $mrRows) {
            $m = $r.m
            $nid = $m["A"]; $typ = $m["C"]; $par = $m["B"]
            if ($nid) {
                if ($allNodeIds.ContainsKey($nid)) { $dupes += $nid }
                else { $allNodeIds[$nid] = $r.rn }
                if ($typ -eq "Milestone") { [void]$milestoneIds.Add($nid) }
                if ($typ -eq "WorkItem") { $workItemParents += [pscustomobject]@{ id = $nid; parent = $par; row = $r.rn } }
            }
        }
        Out-Line ""
        Out-Line ("MR NODE ID count={0} dupes={1}" -f $allNodeIds.Count, $(if ($dupes.Count -gt 0) { $dupes -join "," } else { "NONE" }))
        $orphans = @()
        foreach ($w in $workItemParents) { if (-not $milestoneIds.Contains($w.parent)) { $orphans += ($w.id + "->" + $w.parent) } }
        Out-Line ("MR WORK ITEM count={0} orphan parent refs={1}" -f $workItemParents.Count, $(if ($orphans.Count -gt 0) { $orphans -join ", " } else { "NONE" }))
        # status distribution + count of children of M-07-0.2
        $m072Children = @()
        foreach ($r in $mrRows) {
            $m = $r.m
            if ($m["B"] -eq "M-07-0.2") { $m072Children += [pscustomobject]@{ id = $m["A"]; status = $m["R"]; T = $m["T"] } }
        }
        Out-Line ("M-07-0.2 children (B=M-07-0.2): count={0}" -f $m072Children.Count)
        foreach ($c in ($m072Children | Sort-Object id)) { Out-Line ("   {0} status=[{1}] T=[{2}]" -f $c.id, $c.status, $c.T) }

        # ---- ACTIVE CHANGES (Part 2/4/17) ----
        $eAC = Get-SheetEntry "Active Changes"
        $acRows = Get-CellMap $eAC
        Out-Line ""
        Out-Line ("ACTIVE CHANGES rows={0}" -f $acRows.Count)
        foreach ($r in $acRows) {
            $m = $r.m
            $cid = $m["A"]
            if ($r.rn -lt 75) { continue }   # focus on recent rows + all open
            $s = $m["L"]
            $cls = "Open"; $s2 = ($s -replace "^\s*", ""); if ($s2 -match "^(Completed|Cancelled)") { $cls = "Terminal" }
            Out-Line ("  row {0}: A=[{1}] C=[{2}] L=[{3}] U=[{4}] W=[{5}] AC=[{6}] AD=[{7}] -> classify={8}" -f $r.rn, $cid, $m["C"], $s, $m["U"], $m["W"], $m["AC"], $m["AD"], $cls)
        }
        # classification counts
        $openCount = 0; $termCount = 0
        foreach ($r in $acRows) {
            $m = $r.m; $s = $m["L"]; $s2 = ($s -replace "^\s*", "")
            if ($s2 -match "^(Completed|Cancelled)") { $termCount++ } else { if ($m["A"]) { $openCount++ } }
        }
        Out-Line ("AC classified: open={0} terminal={1}" -f $openCount, $termCount)

        # ---- ACTIVITY LOG (Part 2/5/18/19) ----
        $eAL = Get-SheetEntry "Activity Log"
        $alRows = Get-CellMap $eAL
        Out-Line ""
        Out-Line ("ACTIVITY LOG rows={0} maxRow={1}" -f $alRows.Count, ($alRows | ForEach-Object { $_.rn } | Measure-Object -Maximum).Maximum)
        foreach ($r in $alRows) {
            if ($r.rn -lt 50) { continue }
            $m = $r.m
            Out-Line ("  row {0}: A=[{1}] B=[{2}] E=[{3}] J=[{4}] L=[{5}] N=[{6}] AA=[{7}] AG=[{8}]" -f $r.rn, $m["A"], $m["B"], $m["E"], $m["J"], $m["L"], $m["N"], $m["AA"], $m["AG"])
        }
        $alIds = @{}; $alDupes = @()
        foreach ($r in $alRows) { $id = $r.m["A"]; if ($id) { if ($alIds.ContainsKey($id)) { $alDupes += $id } else { $alIds[$id] = $r.rn } } }
        Out-Line ("AL ACT-ID unique check: dupes={0}" -f $(if ($alDupes.Count -gt 0) { $alDupes -join "," } else { "NONE" }))

        # ---- VERSION HISTORY (Part 3/17/19) ----
        $eVH = Get-SheetEntry "Version History"
        $vhRows = Get-CellMap $eVH
        Out-Line ""
        Out-Line ("VERSION HISTORY rows={0} maxRow={1}" -f $vhRows.Count, ($vhRows | ForEach-Object { $_.rn } | Measure-Object -Maximum).Maximum)
        foreach ($r in $vhRows) {
            if ($r.rn -lt 954) { continue }
            $m = $r.m
            Out-Line ("  row {0}: A=[{1}] R=[{2}] T=[{3}] Z=[{4}] AA=[{5}] AB=[{6}] AC=[{7}] AD=[{8}] AE=[{9}] AH=[{10}]" -f $r.rn, $m["A"], $m["R"], $m["T"], $m["Z"], $m["AA"], $m["AB"], $m["AC"], $m["AD"], $m["AE"], $m["AH"])
        }
        # M-07 chain VH records
        Out-Line "VH records for WI-07-0.2.3 and M-07-0.2:"
        foreach ($r in $vhRows) {
            $m = $r.m
            if ($m["A"] -eq "WI-07-0.2.3" -or $m["A"] -eq "M-07-0.2") {
                Out-Line ("   row {0}: A=[{1}] R=[{2}] T=[{3}] AA=[{4}] AB=[{5}] AC(IsCurrent)=[{6}] AD=[{7}] AE=[{8}]" -f $r.rn, $m["A"], $m["R"], $m["T"], $m["AA"], $m["AB"], $m["AC"], $m["AD"], $m["AE"])
            }
        }

        # ---- AUDIT FINDINGS (Part 11) ----
        $eAF = Get-SheetEntry "Audit Findings"
        $afRows = Get-CellMap $eAF
        Out-Line ""
        Out-Line ("AUDIT FINDINGS rows={0}" -f $afRows.Count)
        foreach ($r in $afRows) {
            if ($r.rn -lt 6) { continue }
            $m = $r.m
            $afid = $m["A"]
            if ($afid -eq "AF-010" -or $afid -eq "AF-010") { Out-Line ("   AF-010 row {0}: A=[{1}] B=[{2}] C=[{3}] D=[{4}] E=[{5}] F=[{6}]" -f $r.rn, $afid, $m["B"], $m["C"], $m["D"], $m["E"], $m["F"]) }
        }
        # count findings, check for CHG-016 / MutationEnvelope references
        $findMutf = $false; $findChg = $false
        foreach ($r in $afRows) {
            foreach ($k in $r.m.Keys) {
                $v = $r.m[$k]
                if ($v) { if ($v.Contains("MutationEnvelope")) { $findMutf = $true }; if ($v.Contains("CHG-20260830-016")) { $findChg = $true } }
            }
        }
        Out-Line ("Audit Findings reference CHG-20260830-016: {0} | MutationEnvelope: {1}" -f $findChg, $findMutf)

        # ---- SESSION PROTOCOL (Part 1) ----
        $eSP = Get-SheetEntry "Session Protocol"
        $spRows = Get-CellMap $eSP
        Out-Line ""
        Out-Line ("SESSION PROTOCOL rows={0} A1=[{1}]" -f $spRows.Count, $(if (($spRows | Where-Object { $_.rn -eq 1 }).m["A"]) { ($spRows | Where-Object { $_.rn -eq 1 }).m["A"] } else { "" }))

        # ---- PHASE PLAN (Part 8) ----
        $ePP = Get-SheetEntry "Phase Plan"
        $ppRows = Get-CellMap $ePP
        $ppRefs = @()
        foreach ($r in $ppRows) {
            $found = $false
            foreach ($k in $r.m.Keys) { if ($r.m[$k] -and $r.m[$k].Contains("M-07-0.2")) { $found = $true } }
            if ($found) { $ppRefs += $r.rn }
        }
        Out-Line ""
        Out-Line ("PHASE PLAN rows={0} rowsReferencingM-07-0.2={1}" -f $ppRows.Count, $(if ($ppRefs.Count -gt 0) { $ppRefs -join "," } else { "NONE" }))

        # ---- ARCHITECTURE DECISIONS (Part 9) ----
        $eADR = Get-SheetEntry "Architecture Decisions"
        $adrRows = Get-CellMap $eADR
        Out-Line ""
        Out-Line ("ARCHITECTURE DECISIONS rows={0}" -f $adrRows.Count)
        foreach ($r in $adrRows) {
            if ($r.rn -lt 6) { continue }
            $m = $r.m
            $adrId = $m["A"]
            if ($adrId -eq "ADR-003" -or $adrId -eq "ADR-005" -or $adrId -eq "ADR-001" -or $adrId -eq "ADR-002") {
                Out-Line ("   {0} row {1}: A=[{2}] B=[{3}] C=[{4}] D=[{5}] E=[{6}]" -f $adrId, $r.rn, $adrId, $m["B"], $m["C"], $m["D"], $m["E"])
            }
        }

        # ---- OPEN DECISIONS (Part 10) ----
        $eOD = Get-SheetEntry "Open Decisions"
        $odRows = Get-CellMap $eOD
        Out-Line ""
        Out-Line ("OPEN DECISIONS rows={0}" -f $odRows.Count)
        foreach ($r in $odRows) {
            if ($r.rn -lt 6) { continue }
            $m = $r.m
            $odId = $m["A"]
            $chgRef = ($m["A"] + " " + $m["B"] + " " + $m["C"] + " " + $m["D"] + " " + $m["E"])
            $flag = if ($chgRef.Contains("WI-07-0.2.3") -or $chgRef.Contains("M-07-0.2") -or $chgRef.Contains("CHG-20260830-016")) { " <-- references completed work" } else { "" }
            Out-Line ("   row {0}: A=[{1}] B=[{2}] C=[{3}] D=[{4}] E=[{5}]{6}" -f $r.rn, $odId, $m["B"], $m["C"], $m["D"], $m["E"], $flag)
        }

        # ---- DEPENDENCIES & BLOCKERS (Part 6) ----
        $eDB = Get-SheetEntry "Dependencies & Blockers"
        $dbRows = Get-CellMap $eDB
        Out-Line ""
        Out-Line ("DEPENDENCIES & BLOCKERS rows={0}" -f $dbRows.Count)
        foreach ($r in $dbRows) {
            if ($r.rn -lt 6) { continue }
            $m = $r.m
            $blob = ($m.Values -join " | ")
            $flag = if ($blob.Contains("WI-07-0.2.3") -or $blob.Contains("M-07-0.2")) { " <-- references M-07 chain" } else { "" }
            Out-Line ("   row {0}: [{1}]{2}" -f $r.rn, $blob.Substring(0, [Math]::Min(200, $blob.Length)), $flag)
        }

        # ---- TOOL & INTEGRATION REGISTRY (Part 12) ----
        $eTR = Get-SheetEntry "Tool & Integration Registry"
        $trRows = Get-CellMap $eTR
        Out-Line ""
        Out-Line ("TOOL & INTEGRATION REGISTRY rows={0}" -f $trRows.Count)
        $trCxml = @()
        foreach ($r in $trRows) {
            $m = $r.m
            if ($m["A"] -eq "ClosedXML") { $trCxml += $r.rn }
            if ($r.rn -ge 15 -and $r.rn -le 16) {
                Out-Line ("   row {0}: A=[{1}] B=[{2}] D=[{3}] E=[{4}] F=[{5}] G=[{6}] J=[{7}]" -f $r.rn, $m["A"], $m["B"], $m["D"], $m["E"], $m["F"], $m["G"], $(if ($m["J"]) { $m["J"].Substring(0, [Math]::Min(150, $m["J"].Length)) } else { "" }))
            }
        }
        Out-Line ("Tool Registry ClosedXML rows: {0}" -f $(if ($trCxml.Count -gt 0) { $trCxml -join "," } else { "NONE" }))

        # ---- EXISTING ASSETS (Part 13) ----
        $eEA = Get-SheetEntry "Existing Assets"
        $eaRows = Get-CellMap $eEA
        Out-Line ""
        Out-Line ("EXISTING ASSETS rows={0}" -f $eaRows.Count)
        $eaDevCtrl = @()
        foreach ($r in $eaRows) {
            $m = $r.m
            if ($m["A"] -eq "Development control service (Excel-backed)") { $eaDevCtrl += $r.rn }
            if ($r.rn -ge 15 -and $r.rn -le 16) {
                Out-Line ("   row {0}: A=[{1}] B=[{2}] C=[{3}] D=[{4}] E=[{5}] F=[{6}]" -f $r.rn, $m["A"], $(if ($m["B"]) { $m["B"].Substring(0, [Math]::Min(200, $m["B"].Length)) } else { "" }), $m["C"], $m["D"], $m["E"], $m["F"])
            }
        }
        Out-Line ("Existing Assets 'Development control service' rows: {0}" -f $(if ($eaDevCtrl.Count -gt 0) { $eaDevCtrl -join "," } else { "NONE" }))

        # ---- DEVELOPMENT GUIDE (Part 7) ----
        $eDG = Get-SheetEntry "Development Guide"
        $dgRows = Get-CellMap $eDG
        Out-Line ""
        Out-Line ("DEVELOPMENT GUIDE rows={0} maxRow={1}" -f $dgRows.Count, ($dgRows | ForEach-Object { $_.rn } | Measure-Object -Maximum).Maximum)
        $dgM07 = @()
        foreach ($r in $dgRows) {
            $blob = ($r.m.Values -join " ")
            if ($blob.Contains("M-07-0.2") -or $blob.Contains("Development Control Service") -or $blob.Contains("Excel-backed")) { $dgM07 += $r.rn }
        }
        Out-Line ("Development Guide rows matching M-07/DevControl: {0}" -f $(if ($dgM07.Count -gt 0) { $dgM07 -join "," } else { "NONE" }))

        # ---- CONTROL CENTER (Part 14) ----
        $eCC = Get-SheetEntry "Control Center"
        $ccRows = Get-CellMap $eCC
        $a2 = ($ccRows | Where-Object { $_.rn -eq 2 }).m["A"]
        Out-Line ""
        Out-Line ("CONTROL CENTER A2 len={0}" -f $a2.Length)
        Out-Line ("  A2 head: {0}" -f $a2.Substring(0, [Math]::Min(600, $a2.Length)))

    } finally { $zip.Dispose() }
} finally { $fs.Dispose() }

[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "Wrote $OutFile ($($sb.Length) chars)"
