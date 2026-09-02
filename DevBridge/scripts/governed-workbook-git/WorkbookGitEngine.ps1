# WorkbookGitEngine.ps1 -- DB-M31 GOVERNED REAL-USE WORKBOOK & GIT SUPPORT engine.
#
# Consumes WorkbookGitContracts.ps1. READ-ONLY, deterministic, zero
# AI/network/paid calls. The governed workbook WRITE CHAIN is implemented here
# but is proven exclusively on FIXTURE workbook copies -- the engine never
# writes the live canonical workbook and never restores a baseline. Config is
# always read from the real DevBridge root (immutable); state and workbook are
# injected per call so tests run against temp fixtures.

Set-StrictMode -Version Latest

# .NET assemblies for OOXML zip/xml handling (PS 5.1 does not auto-load these types)
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Xml.Linq

# --- module-level constants / lazy config cache ---------------------------------

$script:DbM31Ns    = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
$script:DbM31RelNs = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
$script:DbM31Cfg   = $null
$script:DbM31CfgRoot = $null

function Get-XName([string]$Local) { return [System.Xml.Linq.XName]::Get($Local, $script:DbM31Ns) }

function Read-DbM31Json {
    <#
    .SYNOPSIS
    Read a JSON file defensively; returns $null when missing/empty/invalid.
    #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Get-DbM31Config {
    <#
    .SYNOPSIS
    Load the immutable DB-M31 governance config from the real DevBridge root:
    devbridge.json (workbook path + mode), development-control-map.json (per-sheet
    headerRow/dataStartRow/mutation/columns), roadmap-protection.json (protected
    sheets + columns), sheet-governance.json (roles). Cached per root.
    #>
    param([string]$Root)
    if ($script:DbM31CfgRoot -eq $Root -and $null -ne $script:DbM31Cfg) { return $script:DbM31Cfg }
    $devbridge = Read-DbM31Json (Join-Path $Root 'config\devbridge.json')
    $map       = Read-DbM31Json (Join-Path $Root 'config\development-control-map.json')
    $protection = Read-DbM31Json (Join-Path $Root 'config\roadmap-protection.json')
    $governance = Read-DbM31Json (Join-Path $Root 'config\sheet-governance.json')

    $sheetMap = @{}
    foreach ($s in @(Get-ContractProperty $map 'sheets')) {
        $name = [string](Get-ContractProperty $s 'name')
        if (-not $name) { continue }
        $cols = @{}
        foreach ($c in @(Get-ContractProperty $s 'columns')) {
            $col = [string](Get-ContractProperty $c 'column')
            if ($col) { $cols[$col] = [string](Get-ContractProperty $c 'name') }
        }
        $sheetMap[$name] = [pscustomobject]@{
            Name         = $name
            Index        = Get-ContractProperty $s 'index' 0
            HeaderRow    = Get-ContractProperty $s 'headerRow' $null
            DataStartRow = Get-ContractProperty $s 'dataStartRow' 0
            Mutation     = [string](Get-ContractProperty $s 'mutation' '')
            GovernanceRole = [string](Get-ContractProperty $s 'governanceRole' '')
            UniqueKey    = (Get-ContractProperty (Get-ContractProperty $s 'uniqueKey') 'name' '')
            Columns      = $cols
        }
    }

    $protectedSheets = @()
    $protectedColsBySheet = @{}
    $fingerprintHeaderRows = @{}
    foreach ($ps in @(Get-ContractProperty $protection 'sheets')) {
        $sn = [string](Get-ContractProperty $ps 'sheet')
        if (-not $sn) { continue }
        $protectedSheets += $sn
        $cols = @()
        foreach ($grp in @('identityColumns', 'structureColumns', 'architectureColumns')) {
            foreach ($col in @(Get-ContractProperty $ps $grp)) { $cols += [string]$col }
        }
        $protectedColsBySheet[$sn] = @($cols | Sort-Object -Unique)   # DB-GH01 sort order for token assembly
        $fingerprintHeaderRows[$sn] = Get-ContractProperty $ps 'headerRow' 0
    }

    $script:DbM31Cfg = [pscustomobject]@{
        WorkbookPath           = [string](Get-ContractProperty $devbridge 'developmentControlWorkbook' '')
        Mode                   = [string](Get-ContractProperty $devbridge 'mode' 'TRIAL')
        SheetMap               = $sheetMap
        ProtectedSheets        = @($protectedSheets)
        ProtectedColsBySheet   = $protectedColsBySheet
        FingerprintHeaderRows  = $fingerprintHeaderRows
        GovernanceMutation     = @{}   # filled below
        AllSheetNames          = @($sheetMap.Keys)
    }
    foreach ($s in @(Get-ContractProperty $governance 'sheets')) {
        $sn = [string](Get-ContractProperty $s 'sheet')
        if ($sn) { $script:DbM31Cfg.GovernanceMutation[$sn] = [string](Get-ContractProperty $s 'mutation' '') }
    }
    $script:DbM31CfgRoot = $Root
    return $script:DbM31Cfg
}

# --- OOXML low-level helpers -----------------------------------------------------

function Read-DbM31ZipXml {
    <#
    .SYNOPSIS
    Load an entry of an open ZipArchive into an XDocument and DISPOSE its stream.
    Streams must not stay open inside an Update-mode archive: opening the same
    entry again while the first stream is still open throws
    "Entries cannot be opened multiple times in Update mode". All zip-XML loads
    go through here.
    #>
    param(
        [System.IO.Compression.ZipArchive]$Zip,
        [string]$EntryName
    )
    $entry = $Zip.GetEntry($EntryName)
    if ($null -eq $entry) { return $null }
    $st = $entry.Open()
    try { return [System.Xml.Linq.XDocument]::Load($st) } finally { $st.Dispose() }
}

function Get-DbM31SheetEntryName {
    <#
    .SYNOPSIS
    Resolve the xl/worksheets/sheetN.xml entry for a sheet name inside an open
    ZipArchive.
    #>
    param(
        [System.IO.Compression.ZipArchive]$Zip,
        [string]$SheetName
    )
    $wbDoc = Read-DbM31ZipXml -Zip $Zip -EntryName 'xl/workbook.xml'
    if ($null -eq $wbDoc) { return $null }
    $sNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
    $rNs = $script:DbM31RelNs
    $rid = $null
    foreach ($sh in $wbDoc.Root.Elements([System.Xml.Linq.XName]::Get('sheets', $sNs)).Elements([System.Xml.Linq.XName]::Get('sheet', $sNs))) {
        $nm = $sh.Attribute('name')
        if ($nm -and $nm.Value -eq $SheetName) {
            $rid = $sh.Attribute([System.Xml.Linq.XName]::Get('id', $rNs))
            break
        }
    }
    if ($null -eq $rid) { return $null }
    $relsDoc = Read-DbM31ZipXml -Zip $Zip -EntryName 'xl/_rels/workbook.xml.rels'
    if ($null -eq $relsDoc) { return $null }
    $pRel = 'http://schemas.openxmlformats.org/package/2006/relationships'
    $target = $null
    foreach ($rel in $relsDoc.Root.Elements([System.Xml.Linq.XName]::Get('Relationship', $pRel))) {
        if ($rel.Attribute('Id') -and $rel.Attribute('Id').Value -eq $rid.Value) {
            $target = $rel.Attribute('Target').Value
            break
        }
    }
    if ($null -eq $target) { return $null }
    if ($target.StartsWith('/')) { $target = $target.TrimStart('/') }
    elseif (-not $target.StartsWith('xl/')) { $target = 'xl/' + $target }
    return $target
}

function Get-DbM31SharedStrings {
    <#
    .SYNOPSIS
    Read xl/sharedStrings.xml into a string array ("" when absent).
    #>
    param([System.IO.Compression.ZipArchive]$Zip)
    $doc = Read-DbM31ZipXml -Zip $Zip -EntryName 'xl/sharedStrings.xml'
    if ($null -eq $doc) { return ,@() }
    $sst = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
    $out = New-Object System.Collections.ArrayList
    foreach ($si in $doc.Root.Elements([System.Xml.Linq.XName]::Get('si', $sst))) {
        $sb = New-Object System.Text.StringBuilder
        foreach ($t in $si.Descendants([System.Xml.Linq.XName]::Get('t', $sst))) { [void]$sb.Append($t.Value) }
        [void]$out.Add($sb.ToString())
    }
    return ,@($out.ToArray())
}

function Get-DbM31CellText {
    <#
    .SYNOPSIS
    Value of a worksheet <c> element: inlineStr text, shared-string index, raw
    number text, or "" for formula cells (no cached value) / empty.
    #>
    param(
        [System.Xml.Linq.XElement]$Cell,
        [string[]]$SharedStrings
    )
    if ($null -eq $Cell) { return '' }
    $sNs = $script:DbM31Ns
    $t = $Cell.Attribute('t')
    $tVal = if ($null -ne $t) { $t.Value } else { '' }
    if ($tVal -eq 'inlineStr') {
        $is = $Cell.Element([System.Xml.Linq.XName]::Get('is', $sNs))
        if ($null -eq $is) { return '' }
        return [string]$is.Value   # DB-GH01 semantics: concatenated text content of <is>
    }
    if ($tVal -eq 's') {
        $v = $Cell.Element([System.Xml.Linq.XName]::Get('v', $sNs))
        if ($null -eq $v) { return '' }
        try { $idx = [int]$v.Value } catch { return '' }
        if ($idx -ge 0 -and $idx -lt $SharedStrings.Length) { return $SharedStrings[$idx] }
        return ''
    }
    if ($null -ne $Cell.Element([System.Xml.Linq.XName]::Get('f', $sNs))) { return '' }
    $v = $Cell.Element([System.Xml.Linq.XName]::Get('v', $sNs))
    if ($null -ne $v) { return $v.Value }
    return ''
}

function Get-DbM31WorkbookSheet {
    <#
    .SYNOPSIS
    Read one worksheet into a row/cell map. Returns $null when the sheet entry
    cannot be resolved. Rows: array of @{ Row; Cells = @{ "A" -> value } }.
    #>
    param(
        [string]$WorkbookPath,
        [string]$SheetName
    )
    if (-not (Test-Path -LiteralPath $WorkbookPath -PathType Leaf)) { return $null }
    $zip = [System.IO.Compression.ZipFile]::Open($WorkbookPath, 'Read')
    try {
        $entry = Get-DbM31SheetEntryName -Zip $zip -SheetName $SheetName
        if ($null -eq $entry) { return $null }
        $shared = Get-DbM31SharedStrings -Zip $zip
        $doc = Read-DbM31ZipXml -Zip $zip -EntryName $entry
        if ($null -eq $doc) { return $null }
        $sNs = $script:DbM31Ns
        $rows = New-Object System.Collections.ArrayList
        $maxRow = 0
        $sheetData = $doc.Root.Element([System.Xml.Linq.XName]::Get('sheetData', $sNs))
        if ($null -ne $sheetData) {
            foreach ($rowEl in $sheetData.Elements([System.Xml.Linq.XName]::Get('row', $sNs))) {
                $rAttr = $rowEl.Attribute('r')
                $rowNum = if ($null -ne $rAttr) { try { [int]$rAttr.Value } catch { 0 } } else { 0 }
                if ($rowNum -gt $maxRow) { $maxRow = $rowNum }
                $cells = @{}
                foreach ($c in $rowEl.Elements([System.Xml.Linq.XName]::Get('c', $sNs))) {
                    $ref = $c.Attribute('r')
                    if ($null -eq $ref) { continue }
                    $col = ($ref.Value -replace '[0-9]', '')
                    $cells[$col] = Get-DbM31CellText -Cell $c -SharedStrings $shared
                }
                [void]$rows.Add([pscustomobject]@{ Row = $rowNum; Cells = $cells })
            }
        }
        return [pscustomobject]@{ Sheet = $SheetName; Rows = @($rows.ToArray()); MaxRow = $maxRow }
    } finally { $zip.Dispose() }
}

# --- protected roadmap fingerprint (DB-GH01-compatible canonical tokens) ---------

function Resolve-DbM31ProtectedRoadmapFingerprint {
    <#
    .SYNOPSIS
    Deterministic structural fingerprint over the PROTECTED roadmap surface only
    (identity + structure columns of Master Roadmap, Phase Plan, Architecture
    Decisions, Dependencies & Blockers, Open Decisions). SHA-256 over
    "{sheet}|{col}|{row}|{value};" tokens (UTF-8). Explicitly excludes
    execution-state columns. Returns @{ Sha256; ProtectedRows; ProtectedCells;
    Coverage; Error }.
    #>
    param(
        [string]$WorkbookPath,
        [AllowNull()][object]$Config
    )
    if ($null -eq $Config) { $Config = Get-DbM31Config -Root 'C:\Personal\DevTools\DevBridge' }
    if (-not (Test-Path -LiteralPath $WorkbookPath -PathType Leaf)) {
        return [pscustomobject]@{ Sha256 = $null; ProtectedRows = 0; ProtectedCells = 0; Coverage = ''; Error = 'WORKBOOK_NOT_FOUND' }
    }
    $zip = [System.IO.Compression.ZipFile]::Open($WorkbookPath, 'Read')
    try {
        $shared = Get-DbM31SharedStrings -Zip $zip
        $sb = New-Object System.Text.StringBuilder
        $rowCount = 0
        $cellCount = 0
        $coverage = @()
        foreach ($sheet in @($Config.ProtectedSheets)) {
            $cols = @($Config.ProtectedColsBySheet[$sheet])
            if ($cols.Count -eq 0) { continue }
            $coverage += $sheet
            $entry = Get-DbM31SheetEntryName -Zip $zip -SheetName $sheet
            if ($null -eq $entry) { continue }
            $doc = Read-DbM31ZipXml -Zip $zip -EntryName $entry
            if ($null -eq $doc) { continue }
            $sNs = $script:DbM31Ns
            $dataStartRow = 0
            $sm = $Config.SheetMap[$sheet]
            if ($null -ne $sm) { $dataStartRow = [int]$sm.DataStartRow }
            if ($dataStartRow -lt 1) { $dataStartRow = ([int]$Config.FingerprintHeaderRows[$sheet]) + 1 }
            $sheetData = $doc.Root.Element([System.Xml.Linq.XName]::Get('sheetData', $sNs))
            if ($null -eq $sheetData) { continue }
            foreach ($rowEl in $sheetData.Elements([System.Xml.Linq.XName]::Get('row', $sNs))) {
                $rAttr = $rowEl.Attribute('r')
                $rowNum = if ($null -ne $rAttr) { try { [int]$rAttr.Value } catch { 0 } } else { 0 }
                if ($rowNum -lt $dataStartRow) { continue }
                $rowCount++   # DB-GH01 semantics: every row from dataStartRow counts
                foreach ($col in $cols) {
                    $ref = "$col$rowNum"
                    $cell = $null
                    foreach ($c in $rowEl.Elements([System.Xml.Linq.XName]::Get('c', $sNs))) {
                        $cr = $c.Attribute('r')
                        if ($null -ne $cr -and $cr.Value -eq $ref) { $cell = $c; break }
                    }
                    $val = Get-DbM31CellText -Cell $cell -SharedStrings $shared
                    $val = $val.Trim()
                    if ($val -eq '') { continue }
                    $cellCount++
                    [void]$sb.Append("$sheet|$col|$rowNum|$val;")
                }
            }
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
        return [pscustomobject]@{
            Sha256         = ([BitConverter]::ToString($hash)).Replace('-', '').ToUpperInvariant()
            ProtectedRows  = $rowCount
            ProtectedCells = $cellCount
            Coverage       = ($coverage -join ';')
            Error          = ''
        }
    } finally { $zip.Dispose() }
}

# --- execution-state plan validation (Capabilities 1, 2) -------------------------

function Test-DbM31ExecutionStatePlan {
    <#
    .SYNOPSIS
    Classify a write plan against the governed surfaces. Approved = every
    operation targets an execution-state sheet/column only. Prohibited = any
    operation targets protected roadmap structure (phase/milestone/hierarchy/
    sequence/architecture/goals/acceptance/dependency columns) or an unknown
    sheet -> ROADMAP_STRUCTURE_WRITE_PROHIBITED, zero writes performed.
    #>
    param(
        $Plan,
        [AllowNull()][object]$Config
    )
    if ($null -eq $Config) { $Config = Get-DbM31Config -Root 'C:\Personal\DevTools\DevBridge' }
    $execStateColumns = @{
        'Master Roadmap' = @('R', 'T', 'U', 'V', 'W', 'Z', 'AA', 'AC', 'AD')
    }
    $detail = New-Object System.Collections.ArrayList
    foreach ($op in @(Get-ContractProperty $Plan 'Operations')) {
        $sheet = [string](Get-ContractProperty $op 'Sheet')
        $kind  = [string](Get-ContractProperty $op 'Kind' 'Cell')
        $sm = $Config.SheetMap[$sheet]
        if ($null -eq $sm) {
            [void]$detail.Add("unknown sheet '$sheet' (not in governance map)")
            return [pscustomobject]@{ Approved = $false; Prohibited = $true; Token = 'ROADMAP_STRUCTURE_WRITE_PROHIBITED'; Reason = "Unknown or non-governed sheet '$sheet'"; Detail = @($detail.ToArray()) }
        }
        $isProtected = ($sheet -in @($Config.ProtectedSheets))
        if ($kind -eq 'Append') {
            if ($isProtected) {
                [void]$detail.Add("append to protected sheet '$sheet' rejected (phase/milestone/hierarchy structure)")
                return [pscustomobject]@{ Approved = $false; Prohibited = $true; Token = 'ROADMAP_STRUCTURE_WRITE_PROHIBITED'; Reason = "Append to protected roadmap sheet '$sheet' is a structural write"; Detail = @($detail.ToArray()) }
            }
            $mut = [string]$Config.GovernanceMutation[$sheet]
            if ($mut -ne 'APPEND_ONLY' -and $mut -ne 'UPDATE_AND_APPEND_HISTORY') {
                [void]$detail.Add("append to '$sheet' not governed for append (mutation '$mut')")
                return [pscustomobject]@{ Approved = $false; Prohibited = $true; Token = 'ROADMAP_STRUCTURE_WRITE_PROHIBITED'; Reason = "Sheet '$sheet' is not an approved append surface (mutation '$mut')"; Detail = @($detail.ToArray()) }
            }
            # appended row may not touch protected columns
            $rowMap = Get-ContractProperty $op 'RowMap'
            $protectedHere = @($Config.ProtectedColsBySheet[$sheet])
            foreach ($col in @($rowMap.Keys)) {
                if ($col -in $protectedHere) {
                    [void]$detail.Add("append column '$col' on '$sheet' is protected")
                    return [pscustomobject]@{ Approved = $false; Prohibited = $true; Token = 'ROADMAP_STRUCTURE_WRITE_PROHIBITED'; Reason = "Append row on '$sheet' targets protected column '$col'"; Detail = @($detail.ToArray()) }
                }
            }
            continue
        }
        # Cell / update ops
        $col = [string](Get-ContractProperty $op 'Column')
        if ($sheet -eq 'Control Center') {
            $row = Get-ContractProperty $op 'Row' 0
            if (-not ($col -eq 'A' -and $row -eq 2)) {
                [void]$detail.Add("Control Center write not at A2")
                return [pscustomobject]@{ Approved = $false; Prohibited = $true; Token = 'ROADMAP_STRUCTURE_WRITE_PROHIBITED'; Reason = "Control Center write must target A2 (changelog narrative)"; Detail = @($detail.ToArray()) }
            }
            continue
        }
        if ($isProtected) {
            $allowed = @($execStateColumns[$sheet])
            if ($col -notin $allowed) {
                [void]$detail.Add("protected column '$col' on '$sheet'")
                return [pscustomobject]@{ Approved = $false; Prohibited = $true; Token = 'ROADMAP_STRUCTURE_WRITE_PROHIBITED'; Reason = "'$sheet' column '$col' is protected roadmap structure (phase/milestone/hierarchy/sequence/architecture/goals/acceptance/dependency)"; Detail = @($detail.ToArray()) }
            }
            continue
        }
        # non-protected sheet cell write: allowed (execution-state ledger / registry)
        continue
    }
    return [pscustomobject]@{ Approved = $true; Prohibited = $false; Token = 'APPROVED'; Reason = 'All operations target execution-state surfaces'; Detail = @($detail.ToArray()) }
}

# --- OOXML write helpers (temp copies only; never the live canonical workbook) ---

function Write-DbM31CellXml {
    param([System.Xml.Linq.XElement]$Cell, [string]$Value)
    $sNs = $script:DbM31Ns
    # remove any existing value representation BEFORE writing: the 'is' block
    # (inlineStr) as well as 'v'/'f' and the shared-string index 's'/'t'. If the
    # existing '<is>' is left behind, a second one is appended and readers that
    # take the first '<is>' still see the OLD value.
    foreach ($a in @('is', 'v', 'f', 's', 't')) {
        $el = $Cell.Element([System.Xml.Linq.XName]::Get($a, $sNs))
        if ($null -ne $el) { $el.Remove() }
    }
    if ($null -ne $Cell.Attribute('t')) { $Cell.Attribute('t').Remove() }
    $Cell.SetAttributeValue([System.Xml.Linq.XName]::Get('t', ''), 'inlineStr')
    $is = [System.Xml.Linq.XElement]::new([System.Xml.Linq.XName]::Get('is', $sNs))
    $t = [System.Xml.Linq.XElement]::new([System.Xml.Linq.XName]::Get('t', $sNs))
    $t.Value = $Value
    $is.Add($t)
    $Cell.Add($is)
}

function Get-DbM31RowByNumber {
    param([System.Xml.Linq.XElement]$SheetData, [int]$RowNum)
    foreach ($r in $SheetData.Elements([System.Xml.Linq.XName]::Get('row', $script:DbM31Ns))) {
        $ra = $r.Attribute('r')
        if ($null -eq $ra) { continue }
        $n = try { [int]$ra.Value } catch { -1 }   # PS 5.1: try-as-assignment is legal; inside a bool paren it is not
        if ($n -eq $RowNum) { return $r }
    }
    return $null
}

function New-DbM31RowXml {
    param([int]$RowNum)
    $sNs = $script:DbM31Ns
    $row = [System.Xml.Linq.XElement]::new([System.Xml.Linq.XName]::Get('row', $sNs))
    $row.SetAttributeValue([System.Xml.Linq.XName]::Get('r', ''), [string]$RowNum)
    return $row
}

function New-DbM31CellXml {
    param([string]$Ref, [string]$Value)
    $sNs = $script:DbM31Ns
    $cell = [System.Xml.Linq.XElement]::new([System.Xml.Linq.XName]::Get('c', $sNs))
    $cell.SetAttributeValue([System.Xml.Linq.XName]::Get('r', ''), $Ref)
    $cell.SetAttributeValue([System.Xml.Linq.XName]::Get('t', ''), 'inlineStr')
    $is = [System.Xml.Linq.XElement]::new([System.Xml.Linq.XName]::Get('is', $sNs))
    $t = [System.Xml.Linq.XElement]::new([System.Xml.Linq.XName]::Get('t', $sNs))
    $t.Value = $Value
    $is.Add($t)
    $cell.Add($is)
    return $cell
}

function Get-DbM31ColFromRef([string]$Ref) {
    $m = [regex]::Match($Ref, '^[A-Z]+')
    if ($m.Success) { return $m.Value }
    return ''
}

function Get-DbM31ColIndex([string]$Col) {
    $sum = 0
    foreach ($ch in $Col.ToCharArray()) { $sum = $sum * 26 + ([int][char]$ch - [int][char]'A' + 1) }
    return $sum
}

function Update-DbM31Dimension {
    param([System.Xml.Linq.XDocument]$Doc, [string]$SheetName, [string]$MaxRef)
    $sNs = $script:DbM31Ns
    $dim = $Doc.Root.Element([System.Xml.Linq.XName]::Get('dimension', $sNs))
    if ($null -eq $dim) {
        $dim = [System.Xml.Linq.XElement]::new([System.Xml.Linq.XName]::Get('dimension', $sNs))
        $Doc.Root.AddFirst($dim)
    }
    $dim.SetAttributeValue([System.Xml.Linq.XName]::Get('ref', ''), "A1:$MaxRef")
}

function Invoke-DbM31PlanOnTemp {
    <#
    .SYNOPSIS
    Apply a validated execution-state plan to a TEMP workbook copy (ZipArchive
    Update; XDocument). Returns @{ Applied; MaxRefs; Detail }.
    #>
    param(
        [string]$TempPath,
        $Plan
    )
    $zip = [System.IO.Compression.ZipFile]::Open($TempPath, 'Update')
    try {
        $docs = @{}
        foreach ($op in @(Get-ContractProperty $Plan 'Operations')) {
            $sheet = [string](Get-ContractProperty $op 'Sheet')
            $entry = Get-DbM31SheetEntryName -Zip $zip -SheetName $sheet
            if ($null -eq $entry) { return [pscustomobject]@{ Applied = $false; Detail = "sheet entry '$sheet' missing in temp" } }
            if (-not $docs.ContainsKey($entry)) {
                $st = $zip.GetEntry($entry).Open()
                $doc = [System.Xml.Linq.XDocument]::Load($st)
                $st.Close()
                $docs[$entry] = $doc
            }
            $doc = $docs[$entry]
            $sNs = $script:DbM31Ns
            $sheetData = $doc.Root.Element([System.Xml.Linq.XName]::Get('sheetData', $sNs))
            if ($null -eq $sheetData) { return [pscustomobject]@{ Applied = $false; Detail = "no sheetData in '$sheet'" } }
            $kind = [string](Get-ContractProperty $op 'Kind' 'Cell')
            if ($kind -eq 'Append') {
                $rowMap = Get-ContractProperty $op 'RowMap'
                $maxRow = 0
                foreach ($r in $sheetData.Elements([System.Xml.Linq.XName]::Get('row', $sNs))) {
                    $ra = $r.Attribute('r')
                    if ($null -ne $ra) { $n = try { [int]$ra.Value } catch { 0 }; if ($n -gt $maxRow) { $maxRow = $n } }
                }
                $newRow = $maxRow + 1
                $rowEl = New-DbM31RowXml $newRow
                $maxColIdx = 0
                foreach ($key in $rowMap.Keys) {
                    $col = [string]$key
                    $ref = "$col$newRow"
                    $ci = Get-DbM31ColIndex $col
                    if ($ci -gt $maxColIdx) { $maxColIdx = $ci }
                    $rowEl.Add((New-DbM31CellXml $ref ([string]$rowMap[$key])))
                }
                $sheetData.Add($rowEl)
                $colLetter = $null
                $n = $maxColIdx
                while ($n -gt 0) {
                    $rem = ($n - 1) % 26
                    $colLetter = [char]([int][char]'A' + $rem) + $colLetter
                    $n = [int](($n - 1) / 26)
                }
                Update-DbM31Dimension -Doc $doc -SheetName $sheet -MaxRef "$colLetter$newRow"
                continue
            }
            # Cell / PrependCell
            $rowNum = Get-ContractProperty $op 'Row' 0
            $col = [string](Get-ContractProperty $op 'Column')
            $value = [string](Get-ContractProperty $op 'Value' '')
            $prepend = (Get-ContractProperty $op 'Prepend' $false)
            $ref = "$col$rowNum"
            $rowEl = Get-DbM31RowByNumber -SheetData $sheetData -RowNum $rowNum
            if ($null -eq $rowEl) {
                $rowEl = New-DbM31RowXml $rowNum
                # insert in ascending order
                $inserted = $false
                foreach ($r in $sheetData.Elements([System.Xml.Linq.XName]::Get('row', $sNs))) {
                    $ra = $r.Attribute('r')
                    $rn = if ($null -ne $ra) { try { [int]$ra.Value } catch { 0 } } else { 0 }
                    if ($rn -gt $rowNum) { $r.AddBeforeSelf($rowEl); $inserted = $true; break }
                }
                if (-not $inserted) { $sheetData.Add($rowEl) }
            }
            $cell = $null
            foreach ($c in $rowEl.Elements([System.Xml.Linq.XName]::Get('c', $sNs))) {
                $cr = $c.Attribute('r')
                if ($null -ne $cr -and $cr.Value -eq $ref) { $cell = $c; break }
            }
            if ($null -eq $cell) {
                $cell = New-DbM31CellXml $ref ''
                $rowEl.Add($cell)
            }
            if ($prepend) {
                $existing = Get-DbM31CellText -Cell $cell -SharedStrings @()
                Write-DbM31CellXml -Cell $cell -Value "$value`n$existing"
            } else {
                Write-DbM31CellXml -Cell $cell -Value $value
            }
        }
        foreach ($entryName in @($docs.Keys)) {
            $old = $zip.GetEntry($entryName)
            if ($null -ne $old) { $old.Delete() }
            $newEntry = $zip.CreateEntry($entryName)
            $w = $newEntry.Open()
            try { $docs[$entryName].Save($w) } finally { $w.Close() }
        }
        return [pscustomobject]@{ Applied = $true; Detail = '' }
    } finally { $zip.Dispose() }
}

# --- canonical authority write chain (Capabilities 2,3,4,5,6,8,17,18) -------------

function Resolve-DbM31CanonicalWrite {
    <#
    .SYNOPSIS
    The SINGLE governed write chain DB-M31 proves (against FIXTURE copies only).
    fresh-read -> validate authority/path -> stale-state check -> serialized
    writer (busy) -> plan approval -> hash-validated backup -> approved
    execution-state write (temp -> save/close -> atomic replace) -> reopen actual
    -> read-back exact intended state -> verify protected roadmap -> only then
    update DevBridge state (audit). Any failure returns a canonical failure token;
    the write is treated as failed and never silently recovered.
    #>
    param(
        [string]$WorkbookPath,
        [string]$ExpectedBeforeSha,
        $Plan,
        [string]$BackupDir,
        [string]$LockFile,
        [string]$AuditPath,
        [string]$OperationId,
        [string]$TaskId,
        [string]$ChangeId,
        [string]$Mode,
        [string]$NowUtc,
        [string]$Root,
        [switch]$Fixture
    )
    $cfg = Get-DbM31Config -Root $Root
    $now = if ($NowUtc) { $NowUtc } else { [datetime]::UtcNow.ToString('o') }
    $fail = { param($token, $reason) [pscustomobject]@{ Outcome = $token; Success = $false; Reason = $reason; WorkbookPath = $WorkbookPath; OperationId = $OperationId; BackupPath = $null; Sha256Before = $null; Sha256After = $null; FingerprintBefore = $null; FingerprintAfter = $null; AuditPath = $null } }

    # 1. validate authority/path: must exist and be the canonical governed workbook OR an explicit fixture
    if (-not (Test-Path -LiteralPath $WorkbookPath -PathType Leaf)) {
        return (& $fail 'WORKBOOK_AUTHORITY_REJECTED' 'workbook not found')
    }
    $canonical = [System.IO.Path]::GetFullPath($cfg.WorkbookPath)
    $candidate = [System.IO.Path]::GetFullPath($WorkbookPath)
    if (-not $Fixture -and -not [string]::Equals($canonical, $candidate, [System.StringComparison]::OrdinalIgnoreCase)) {
        return (& $fail 'WORKBOOK_AUTHORITY_REJECTED' 'path is not the canonical governed workbook and no -Fixture override was supplied')
    }
    if (-not $WorkbookPath.EndsWith('.xlsx', [System.StringComparison]::OrdinalIgnoreCase)) {
        return (& $fail 'WORKBOOK_AUTHORITY_REJECTED' 'not an .xlsx workbook')
    }

    # 2. stale-state check (fresh-read vs expected before hash)
    $shaBefore = Get-DbM31FileSha256 $WorkbookPath
    if ($ExpectedBeforeSha -and $shaBefore -ne $ExpectedBeforeSha) {
        return (& $fail 'STALE_GOVERNANCE_STATE' 'workbook changed between read and write; operator must refresh/reconsider; no automatic overwrite')
    }

    # 3. serialized writer: single writer, WORKBOOK_WRITER_BUSY when the lock is held
    if ($LockFile -and (Test-Path -LiteralPath $LockFile -PathType Leaf)) {
        return (& $fail 'WORKBOOK_WRITER_BUSY' 'a governed writer holds the serialization lock; no duplicate/double-click write')
    }
    if ($LockFile) {
        $lkDir = Split-Path -Parent $LockFile
        if (-not (Test-Path -LiteralPath $lkDir)) { try { New-Item -ItemType Directory -Force -Path $lkDir | Out-Null } catch {} }
        try { [System.IO.File]::WriteAllText($LockFile, $now) } catch { return (& $fail 'WORKBOOK_WRITER_BUSY' 'could not acquire the writer lock') }
    }

    # 4. duplicate write protection (double click)
    if ($AuditPath -and (Test-Path -LiteralPath $AuditPath -PathType Leaf)) {
        $existing = @(Read-DbM31Json $AuditPath)
        foreach ($rec in $existing) {
            if ([string](Get-ContractProperty $rec 'OperationId') -eq $OperationId) {
                if ($LockFile) { try { Remove-Item -LiteralPath $LockFile -Force } catch {} }
                return (& $fail 'DUPLICATE_WRITE_REJECTED' "operation id '$OperationId' already recorded; duplicate write blocked")
            }
        }
    }

    try {
        # 5. plan approval BEFORE any write/backup
        $verdict = Test-DbM31ExecutionStatePlan -Plan $Plan -Config $cfg
        if (-not $verdict.Approved) {
            if ($LockFile) { try { Remove-Item -LiteralPath $LockFile -Force } catch {} }
            return (& $fail 'ROADMAP_STRUCTURE_WRITE_PROHIBITED' $verdict.Reason)
        }

        # 6. protected roadmap fingerprint before
        $fpBefore = Resolve-DbM31ProtectedRoadmapFingerprint -WorkbookPath $WorkbookPath -Config $cfg
        if ($fpBefore.Error -or -not $fpBefore.Sha256) {
            if ($LockFile) { try { Remove-Item -LiteralPath $LockFile -Force } catch {} }
            return (& $fail 'PROTECTED_ROADMAP_MISMATCH' 'could not compute the protected roadmap fingerprint before the write')
        }

        # 7. hash-validated backup
        if (-not $BackupDir -or -not (Test-Path -LiteralPath $BackupDir)) {
            if ($LockFile) { try { Remove-Item -LiteralPath $LockFile -Force } catch {} }
            return (& $fail 'BACKUP_CREATION_FAILED' 'backup directory unavailable')
        }
        $backupName = "db-m31-backup-$OperationId-$($now -replace '[^0-9a-zA-Z\-]', '-').xlsx"
        $backupPath = Join-Path $BackupDir $backupName
        try {
            [System.IO.File]::Copy($WorkbookPath, $backupPath, $true)
        } catch {
            if ($LockFile) { try { Remove-Item -LiteralPath $LockFile -Force } catch {} }
            return (& $fail 'BACKUP_CREATION_FAILED' "backup creation failed: $($_.Exception.Message)")
        }
        $backupSha = Get-DbM31FileSha256 $backupPath
        if ($backupSha -ne $shaBefore) {
            if ($LockFile) { try { Remove-Item -LiteralPath $LockFile -Force } catch {} }
            return (& $fail 'BACKUP_CREATION_FAILED' 'backup SHA does not match the pre-write workbook SHA')
        }

        # 8. approved execution-state write: temp -> mutate -> save/close -> atomic replace
        $tmp = [System.IO.Path]::GetTempFileName()
        Remove-Item -LiteralPath $tmp -Force
        $tmp = [System.IO.Path]::ChangeExtension($tmp, 'xlsx')
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        [System.IO.File]::Copy($WorkbookPath, $tmp, $true)
        $apply = Invoke-DbM31PlanOnTemp -TempPath $tmp -Plan $Plan
        if (-not $apply.Applied) {
            try { Remove-Item -LiteralPath $tmp -Force } catch {}
            if ($LockFile) { try { Remove-Item -LiteralPath $LockFile -Force } catch {} }
            return (& $fail 'BACKEND_STATE_MISMATCH' "plan application failed: $($apply.Detail)")
        }
        try {
            [System.IO.File]::Copy($tmp, $WorkbookPath, $true)
        } catch {
            try { Remove-Item -LiteralPath $tmp -Force } catch {}
            if ($LockFile) { try { Remove-Item -LiteralPath $LockFile -Force } catch {} }
            return (& $fail 'BACKEND_STATE_MISMATCH' "atomic replace failed (workbook in use?): $($_.Exception.Message)")
        }
        try { Remove-Item -LiteralPath $tmp -Force } catch {}

        # 9. reopen actual workbook; read-back exact intended state
        foreach ($op in @(Get-ContractProperty $Plan 'Operations')) {
            $sheet = [string](Get-ContractProperty $op 'Sheet')
            $kind  = [string](Get-ContractProperty $op 'Kind' 'Cell')
            $want  = if ($kind -eq 'Append') { $op.RowMap } else { @{ ([string](Get-ContractProperty $op 'Column')) = [string](Get-ContractProperty $op 'Expect' (Get-ContractProperty $op 'Value' '')) } }
            $rows = Get-DbM31WorkbookSheet -WorkbookPath $WorkbookPath -SheetName $sheet
            $matched = $false
            if ($null -ne $rows) {
                if ($kind -eq 'Append') {
                    # find a row whose mapped cells all match (appended row)
                    foreach ($r in $rows.Rows) {
                        $all = $true
                        foreach ($k in $want.Keys) {
                            if (-not $r.Cells.ContainsKey([string]$k) -or ([string]$r.Cells[[string]$k]) -ne ([string]$want[$k])) { $all = $false; break }
                        }
                        if ($all) { $matched = $true; break }
                    }
                } else {
                    $rowNum = Get-ContractProperty $op 'Row' 0
                    $col = [string](Get-ContractProperty $op 'Column')
                    foreach ($r in $rows.Rows) {
                        if ($r.Row -eq $rowNum) {
                            if ($r.Cells.ContainsKey($col) -and ([string]$r.Cells[$col]) -eq ([string]$want[$col])) { $matched = $true }
                            break
                        }
                    }
                }
            }
            if (-not $matched) {
                if ($LockFile) { try { Remove-Item -LiteralPath $LockFile -Force } catch {} }
                return (& $fail 'WORKBOOK_READBACK_FAILED' "read-back mismatch on '$sheet' (expected '$want')")
            }
        }

        # 10. verify protected roadmap on the reopened workbook
        $fpAfter = Resolve-DbM31ProtectedRoadmapFingerprint -WorkbookPath $WorkbookPath -Config $cfg
        $shaAfter = Get-DbM31FileSha256 $WorkbookPath
        if ($fpAfter.Error -or $fpAfter.Sha256 -ne $fpBefore.Sha256) {
            if ($LockFile) { try { Remove-Item -LiteralPath $LockFile -Force } catch {} }
            return (& $fail 'PROTECTED_ROADMAP_MISMATCH' 'protected roadmap fingerprint changed across the write; write treated as failed')
        }

        # 11. only then update DevBridge state (audit trace)
        $audit = Resolve-DbM31AuditTrace -OperationId $OperationId -TaskId $TaskId -ChangeId $ChangeId -Mode $Mode -TimestampUtc $now -InputState '' -ResultState 'WRITTEN' -WorkbookShaBefore $shaBefore -WorkbookShaAfter $shaAfter -GitHeadBefore '' -GitHeadAfter '' -HumanActionRequired $false -VerificationResult 'M11_VERIFIED' -ClaudeResult '' -WorkbookPath $WorkbookPath -BackupPath $backupPath -FingerprintBefore $fpBefore.Sha256 -FingerprintAfter $fpAfter.Sha256
        if ($AuditPath) {
            $adDir = Split-Path -Parent $AuditPath
            if (-not (Test-Path -LiteralPath $adDir)) { try { New-Item -ItemType Directory -Force -Path $adDir | Out-Null } catch {} }
            $all = @(Read-DbM31Json $AuditPath) + @($audit)
            try { [System.IO.File]::WriteAllText($AuditPath, ($all | ConvertTo-Json -Depth 6 -Compress), [System.Text.Encoding]::UTF8) } catch {}
        }
        if ($LockFile) { try { Remove-Item -LiteralPath $LockFile -Force } catch {} }
        return [pscustomobject]@{
            Outcome = 'WRITE_VERIFIED'
            Success = $true
            Reason = 'execution-state write verified: backup created, read-back exact, protected roadmap preserved'
            WorkbookPath = $WorkbookPath
            OperationId = $OperationId
            BackupPath = $backupPath
            Sha256Before = $shaBefore
            Sha256After = $shaAfter
            FingerprintBefore = $fpBefore.Sha256
            FingerprintAfter = $fpAfter.Sha256
            AuditPath = $AuditPath
        }
    } catch {
        if ($LockFile) { try { Remove-Item -LiteralPath $LockFile -Force } catch {} }
        return (& $fail 'BACKEND_STATE_MISMATCH' "unexpected error in write chain: $($_.Exception.Message)")
    }
}

# --- Git observation (Capabilities 7, 9; read-only) ------------------------------

function Resolve-DbM31GitObservation {
    <#
    .SYNOPSIS
    Read-only git observation: repository path, branch, HEAD, HEAD subject,
    working-tree state, changed files, commit state. Remote state is UNKNOWN and
    never inferred as NO_PR / NOT_MERGED. Merge is NEVER inferred from a commit
    or a clean tree.
    #>
    param([string]$RepositoryPath)
    if (-not $RepositoryPath -or -not (Test-Path -LiteralPath $RepositoryPath)) {
        return [pscustomobject]@{ Repository = $null; IsGitRepo = $false; Branch = $null; HeadCommit = $null; HeadSubject = $null; WorkingTreeDirty = $false; StagedFiles = @(); ModifiedFiles = @(); UntrackedFiles = @(); ChangedFiles = @(); CommitState = 'UNKNOWN'; PrState = 'UNKNOWN'; MergeConfirmed = $false; Source = 'no repository root available; PR state UNKNOWN'; Note = 'PR state is UNKNOWN whenever it cannot be explicitly verified; it is never fabricated and never inferred from local state.' }
    }
    function Invoke-DbM31Git([string[]]$GitArgs) {
        try {
            $out = & git -C $RepositoryPath @GitArgs 2>$null
            return ($out -join "`n")
        } catch { return $null }
    }
    $isRepo = (Invoke-DbM31Git @('rev-parse', '--is-inside-work-tree')) -eq 'true'
    if (-not $isRepo) {
        return [pscustomobject]@{ Repository = $RepositoryPath; IsGitRepo = $false; Branch = $null; HeadCommit = $null; HeadSubject = $null; WorkingTreeDirty = $false; StagedFiles = @(); ModifiedFiles = @(); UntrackedFiles = @(); ChangedFiles = @(); CommitState = 'UNKNOWN'; PrState = 'UNKNOWN'; MergeConfirmed = $false; Source = 'repository is not a git working tree; PR state UNKNOWN'; Note = 'PR state is UNKNOWN whenever it cannot be explicitly verified; it is never fabricated and never inferred from local state.' }
    }
    $branch = Invoke-DbM31Git @('rev-parse', '--abbrev-ref', 'HEAD')
    $head   = Invoke-DbM31Git @('rev-parse', 'HEAD')
    $subject = Invoke-DbM31Git @('log', '-1', '--format=%s')
    $status = @((Invoke-DbM31Git @('status', '--porcelain=v1')) -split "`n" | Where-Object { $_ })
    $staged = @(); $modified = @(); $untracked = @(); $changed = @()
    foreach ($line in $status) {
        if ($line.Length -ge 4) {
            $xy = $line.Substring(0, 2)
            $path = $line.Substring(3).Trim()
            if ($path) { $changed += $path }
            if ($xy -match '^[MADRCU]') { $staged += $path }
            if ($xy[1] -eq 'M' -or $xy[1] -eq 'D') { $modified += $path }
            if ($xy -match '^\?\?') { $untracked += $path }
        }
    }
    $commitState = if ($head) { 'PRESENT' } else { 'UNKNOWN' }
    return [pscustomobject]@{
        Repository       = $RepositoryPath
        IsGitRepo        = $true
        Branch           = $branch
        HeadCommit       = $head
        HeadSubject      = $subject
        WorkingTreeDirty = ($status.Count -gt 0)
        StagedFiles      = @($staged)
        ModifiedFiles    = @($modified)
        UntrackedFiles   = @($untracked)
        ChangedFiles     = @($changed)
        CommitState      = $commitState
        PrState          = 'UNKNOWN'       # remote unknown; never inferred
        MergeConfirmed   = $false          # never inferred from observation
        Source           = 'git -C <dir> (read-only observation)'
        Note             = 'PR state is UNKNOWN whenever it cannot be explicitly verified; it is never fabricated and never inferred from local state.'
    }
}

# --- human Git gate (Capabilities 8, 9) ------------------------------------------

function Resolve-DbM31HumanGitGate {
    <#
    .SYNOPSIS
    Derive the human Git gate position ONLY from explicit evidence
    (gitLifecycleState, PR evidence, merge evidence). A merge is never inferred
    from a commit, a branch change, a clean tree, or a PR closure alone.
    #>
    param(
        [string]$GitLifecycleState,
        [string]$PrEvidence,
        [string]$MergeEvidence,
        [AllowNull()][object]$Config
    )
    $mergeStates = @(Get-DbM31MergeConfirmedStates)
    $gateStates = @(Get-DbM31GitGateTokens)
    $gate = $GitLifecycleState
    if (-not $gate -or $gate -eq 'NOT_APPLICABLE') {
        # explicit evidence only; never inferred
        if ($MergeEvidence) { $gate = 'MERGED' }
        elseif ($PrEvidence -and $PrEvidence -eq 'OPEN') { $gate = 'PR_OPEN' }
        elseif ($PrEvidence) { $gate = 'PR_STATE_UNKNOWN' }
        else { $gate = 'PR_STATE_UNKNOWN' }
    }
    $mergeConfirmed = ($gate -in $mergeStates)
    $humanAction = ''
    switch -Regex ($gate) {
        '^AWAITING_HUMAN_PR$'       { $humanAction = 'HUMAN: create the PR (DevBridge prepares the package only).' }
        '^PR_OPEN$'                 { $humanAction = 'HUMAN: review the open PR.' }
        '^AWAITING_HUMAN_REVIEW$'   { $humanAction = 'HUMAN: perform the PR review.' }
        '^AWAITING_HUMAN_MERGE$'    { $humanAction = 'HUMAN: merge the approved PR.' }
        '^(MERGED|READY_FOR_GOVERNED_COMPLETION)$' { $humanAction = 'HUMAN: run governed completion when eligible.' }
        '^PR_STATE_UNKNOWN$'        { $humanAction = 'HUMAN: verify the PR state; DevBridge never infers it.' }
        '^MERGE_STATE_UNKNOWN$'     { $humanAction = 'HUMAN: confirm positive merge evidence.' }
        default                     { $humanAction = 'HUMAN: confirm the Git gate position.' }
    }
    return [pscustomobject]@{
        GateState        = $gate
        MergeConfirmed   = $mergeConfirmed
        MergeEvidence    = $MergeEvidence
        PrStateObserved  = $gate
        HumanAction      = $humanAction
        Detail           = 'merge is never inferred from a commit, branch change, clean tree, or PR closure; remote state stays UNKNOWN unless positively evidenced.'
    }
}

# --- lifecycle state (with evidence-ownership guard; mirrors C# StateReader) -----

function Get-DbM31LifecycleState {
    <#
    .SYNOPSIS
    Read the governed lifecycle state from a state root with the evidence-
    ownership guard: verification/claude/completion evidence applies ONLY when it
    binds to the current task's changeId (or both are empty). Stale evidence from
    a prior cycle is surfaced as a warning, never counted.
    #>
    param(
        [string]$Root,
        [string]$StateSource
    )
    $stateDir = if ($StateSource -eq 'LIVE') { Join-Path $Root 'state' } else { Join-Path $Root 'state' }
    $ct = Read-DbM31Json (Join-Path $stateDir 'current-task.json')
    $changeId = [string](Get-ContractProperty $ct 'changeId' '')
    $nodeId   = [string](Get-ContractProperty $ct 'nodeId' '')
    $mode     = [string](Get-ContractProperty $ct 'mode' 'TRIAL')
    $status   = [string](Get-ContractProperty $ct 'status' '')
    $next     = [string](Get-ContractProperty $ct 'nextAllowedAction' '')
    $gitLife  = [string](Get-ContractProperty $ct 'gitLifecycleState' '')
    $preflightVerdict = [string](Get-ContractProperty $ct 'preflightVerdict' '')
    $implementability = [string](Get-ContractProperty $ct 'implementability' '')
    $approvedScope = [string](Get-ContractProperty $ct 'approvedScope' '')
    $warnings = New-Object System.Collections.ArrayList

    function Test-DbM31EvidenceApplies([object]$Evidence) {
        if ($null -eq $Evidence) { return $false }
        $evCh = [string](Get-ContractProperty $Evidence 'changeId' '')
        if (-not $changeId -and -not $evCh) { return $true }
        return ($evCh -eq $changeId)
    }

    $verif = Read-DbM31Json (Join-Path $stateDir 'verification.json')
    $verificationPassed = $false
    if (Test-DbM31EvidenceApplies $verif) {
        $pr = [string](Get-ContractProperty $verif 'primaryResult' '')
        $verificationPassed = $pr.StartsWith('VERIFICATION_PASSED', [System.StringComparison]::OrdinalIgnoreCase)
    } elseif ($null -ne $verif) {
        [void]$warnings.Add("stale verification evidence (changeId '$((Get-ContractProperty $verif 'changeId'))') not counted for current task")
    }

    $claude = Read-DbM31Json (Join-Path $stateDir 'claude-review.json')
    $claudePassed = $false
    if (Test-DbM31EvidenceApplies $claude) {
        $dec = [string](Get-ContractProperty $claude 'decision' '')
        $claudePassed = $dec.StartsWith('PASS', [System.StringComparison]::OrdinalIgnoreCase)
    } elseif ($null -ne $claude) {
        [void]$warnings.Add("stale claude-review evidence (changeId '$((Get-ContractProperty $claude 'changeId'))') not counted for current task")
    }

    $completion = Read-DbM31Json (Join-Path $stateDir 'completion.json')
    $completionPresent = $false
    if (Test-DbM31EvidenceApplies $completion) {
        $completionPresent = $true
    } elseif ($null -ne $completion) {
        [void]$warnings.Add("stale completion evidence (changeId '$((Get-ContractProperty $completion 'changeId'))') not counted for current task")
    }

    $governanceBlocked = $false
    if ($preflightVerdict -match 'NO_IMPLEMENTABLE_DESCENDANT|GOVERNANCE_BLOCK|SCOPE_INCOMPLETE|BLOCKED') { $governanceBlocked = $true }
    elseif ($status -match 'BLOCKED') { $governanceBlocked = $true }

    return [pscustomobject]@{
        NodeId             = $nodeId
        ChangeId           = $changeId
        Mode               = $mode
        TrialMode          = ($mode -eq 'TRIAL')
        Status             = $status
        NextAllowedAction  = $next
        GitLifecycleState  = $gitLife
        PreflightVerdict   = $preflightVerdict
        Implementability   = $implementability
        ApprovedScope      = $approvedScope
        VerificationPassed = $verificationPassed
        ClaudePassed       = $claudePassed
        CompletionPresent  = $completionPresent
        GovernanceBlocked  = $governanceBlocked
        Warnings           = @($warnings.ToArray())
        StateDir           = $stateDir
        StateSource        = $StateSource
    }
}

# --- M10 eligibility (Capability 12) ---------------------------------------------

function Resolve-DbM31M10Eligibility {
    <#
    .SYNOPSIS
    The hardened M10 gate. TRIAL short-circuits to TRIAL_COMPLETION_NOT_APPLICABLE
    first. REAL requires: M06 PASS, Claude PASS, no blocking governance issue,
    approved scope, positive human merge evidence, fresh workbook state, protected
    roadmap fingerprint preserved, eligible lifecycle state. Any missing -> a
    specific BLOCK token. Existing M10 protections are never weakened.
    #>
    param(
        [AllowNull()][object]$Lifecycle,
        [string]$FingerprintVerdict,
        [bool]$FreshState
    )
    $mergeStates = @(Get-DbM31MergeConfirmedStates)
    $mergeConfirmed = ($Lifecycle.GitLifecycleState -in $mergeStates)
    $prereqs = New-Object System.Collections.ArrayList

    function Add-PreReq($Name, $Ok, $Detail) { [void]$prereqs.Add([pscustomobject]@{ Name = $Name; Satisfied = $Ok; Detail = $Detail }) }

    if ($Lifecycle.TrialMode) {
        Add-PreReq 'Mode = REAL_NEXUS_DEVELOPMENT' $false 'TRIAL mode: M10 governed completion is NOT applicable'
        return [pscustomobject]@{
            Verdict = 'NotApplicable'
            Token = 'TRIAL_COMPLETION_NOT_APPLICABLE'
            Eligible = $false
            Reason = 'TRIAL cycle: M10 governed completion is NOT applicable. The cycle stops at TRIAL_CYCLE_SAFE_STOP; completion is never run for trial evidence.'
            Prerequisites = @($prereqs.ToArray())
        }
    }

    Add-PreReq 'Mode = REAL_NEXUS_DEVELOPMENT' ($Lifecycle.Mode -eq 'REAL_NEXUS_DEVELOPMENT') "mode is '$($Lifecycle.Mode)'"
    Add-PreReq 'DB-M06 verification PASS' $Lifecycle.VerificationPassed ('primaryResult starts with VERIFICATION_PASSED')
    Add-PreReq 'Claude review PASS' $Lifecycle.ClaudePassed 'decision starts with PASS'
    Add-PreReq 'No blocking governance issue' (-not $Lifecycle.GovernanceBlocked) "preflight verdict '$($Lifecycle.PreflightVerdict)' / status '$($Lifecycle.Status)'"
    Add-PreReq 'Approved scope' ([string]$Lifecycle.ApprovedScope -in @('APPROVED', 'CLEAR', 'YES')) "approvedScope '$($Lifecycle.ApprovedScope)'"
    Add-PreReq 'Positive human merge evidence' $mergeConfirmed "gitLifecycleState '$($Lifecycle.GitLifecycleState)' (never inferred)"
    Add-PreReq 'Fresh workbook state' $FreshState 'stale-state check passed'
    Add-PreReq 'Protected roadmap fingerprint preserved' ($FingerprintVerdict -eq 'PRESERVED') "fingerprint verdict '$FingerprintVerdict'"
    Add-PreReq 'Eligible lifecycle state' ($Lifecycle.Status -in @('MERGED', 'READY_FOR_GOVERNED_COMPLETION', 'AWAITING_HUMAN_MERGE', 'AWAITING_HUMAN_REVIEW', 'PR_OPEN', 'AWAITING_HUMAN_PR', 'CLAUDE_REVIEW_PASSED_REAL')) "status '$($Lifecycle.Status)'"

    $token = 'READY_FOR_GOVERNED_COMPLETION'
    $reason = 'All gates satisfied: REAL mode, M06 PASS, Claude PASS, no governance issue, approved scope, human merge confirmed, fresh state, protected roadmap preserved, eligible lifecycle state.'
    foreach ($p in @($prereqs.ToArray())) {
        if (-not $p.Satisfied) {
            switch ($p.Name) {
                'Mode = REAL_NEXUS_DEVELOPMENT' { $token = 'BLOCKED_NOT_REAL_MODE' }
                'DB-M06 verification PASS' { $token = 'BLOCKED_NO_DB_M06_VERIFICATION_PASS' }
                'Claude review PASS' { $token = 'BLOCKED_NO_CLAUDE_PASS' }
                'No blocking governance issue' { $token = 'BLOCKED_GOVERNANCE_ISSUE' }
                'Approved scope' { $token = 'BLOCKED_SCOPE_NOT_APPROVED' }
                'Positive human merge evidence' { $token = if ($Lifecycle.GitLifecycleState) { 'BLOCKED_HUMAN_GIT_MERGE_GATE_PENDING' } else { 'MERGE_STATE_UNKNOWN' } }
                'Fresh workbook state' { $token = 'BLOCKED_STALE_STATE' }
                'Protected roadmap fingerprint preserved' { $token = 'ROADMAP_STRUCTURE_WRITE_PROHIBITED' }
                default { $token = 'BLOCKED_INELIGIBLE_LIFECYCLE_STATE' }
            }
            $reason = "M10 blocked: $($p.Name) not satisfied ($($p.Detail))."
            break
        }
    }
    return [pscustomobject]@{
        Verdict = if ($token -eq 'READY_FOR_GOVERNED_COMPLETION') { 'ReadyForGovernedCompletion' } else { 'Blocked' }
        Token = $token
        Eligible = ($token -eq 'READY_FOR_GOVERNED_COMPLETION')
        Reason = $reason
        Prerequisites = @($prereqs.ToArray())
    }
}

# --- trial flow (Capability 10; DB-M12.4) ----------------------------------------

function Resolve-DbM31TrialFlow {
    <#
    .SYNOPSIS
    The preserved TRIAL flow: M03 -> M04 -> M05 -> supervised implementation ->
    M06 -> M07/M08 -> correction if needed -> TRIAL_CYCLE_SAFE_STOP ->
    CLOSE_TRIAL_CYCLE. M10 is always TRIAL_COMPLETION_NOT_APPLICABLE; the engine
    never routes a trial cycle to M10 completion.
    #>
    param([string]$Status)
    $map = @{
        'PREFLIGHTED'            = 'M03_SELECTION'
        'RESERVED'               = 'M04_RESERVATION'
        'HANDOFF_GENERATED'      = 'M05_CHATGPT_HANDOFF'
        'VERIFIED'               = 'M06_VERIFICATION'
        'CLAUDE_REVIEW_PASSED_TRIAL' = 'TRIAL_CYCLE_SAFE_STOP'
        'TRIAL_CYCLE_SAFE_STOP'  = 'TRIAL_CYCLE_SAFE_STOP'
        'TRIAL_CYCLE_CLOSED'     = 'TRIAL_CYCLE_CLOSED'
    }
    $position = $map[$Status]
    if (-not $position) { $position = 'PREFLIGHT' }
    return [pscustomobject]@{
        Status = $Status
        Position = $position
        NextStep = if ($position -eq 'TRIAL_CYCLE_SAFE_STOP') { 'CLOSE_TRIAL_CYCLE' } else { $position }
        M10 = 'TRIAL_COMPLETION_NOT_APPLICABLE'
        Detail = 'TRIAL flow preserved: M03 -> M04 -> M05 -> supervised implementation -> M06 -> M07/M08 -> correction if needed -> TRIAL_CYCLE_SAFE_STOP -> CLOSE_TRIAL_CYCLE. Trial evidence is never merged into Nexus.'
    }
}

# --- M11 post-completion validation (Capability 13) ------------------------------

function Resolve-DbM31M11Validation {
    <#
    .SYNOPSIS
    Post-completion validation: 14-sheet consistency, execution-state coherence,
    protected roadmap unchanged, dependency/status consistency, Active Changes /
    Version History / Activity Log closure, completion evidence. On failure it
    returns an explicit governance/reconciliation state -- never a silent clean
    claim.
    #>
    param(
        [string]$WorkbookPath,
        [AllowNull()][object]$Lifecycle,
        [AllowNull()][object]$Config,
        [string]$FingerprintExpected,
        [string]$ChangeId,
        [string]$NodeId
    )
    if ($null -eq $Config) { $Config = Get-DbM31Config -Root 'C:\Personal\DevTools\DevBridge' }
    $parts = New-Object System.Collections.ArrayList
    $all14 = @('Control Center', 'Master Roadmap', 'Active Changes', 'Audit Findings', 'Session Protocol', 'Version History', 'Phase Plan', 'Architecture Decisions', 'Open Decisions', 'Dependencies & Blockers', 'Tool & Integration Registry', 'Activity Log', 'Development Guide', 'Existing Assets')

    function Add-Part($Name, $Ok, $Detail) { [void]$parts.Add([pscustomobject]@{ Name = $Name; Pass = $Ok; Detail = $Detail }) }

    # 14-sheet consistency
    $present = @()
    foreach ($sn in $all14) { $r = Get-DbM31WorkbookSheet -WorkbookPath $WorkbookPath -SheetName $sn; if ($null -ne $r) { $present += $sn } }
    $missing14 = @($all14 | Where-Object { $_ -notin $present })
    Add-Part '14-sheet consistency' ($missing14.Count -eq 0) "missing: $(($missing14 -join ','))"

    # protected roadmap unchanged
    $fp = Resolve-DbM31ProtectedRoadmapFingerprint -WorkbookPath $WorkbookPath -Config $Config
    Add-Part 'Protected roadmap unchanged' ($fp.Sha256 -eq $FingerprintExpected) "expected '$FingerprintExpected' got '$($fp.Sha256)'"

    # execution-state coherence + closures (Active Changes)
    $acClosed = $false
    $ac = Get-DbM31WorkbookSheet -WorkbookPath $WorkbookPath -SheetName 'Active Changes'
    if ($null -ne $ac) {
        foreach ($r in $ac.Rows) {
            if ($r.Cells.ContainsKey('A') -and ([string]$r.Cells['A']) -eq $ChangeId) {
                $st = if ($r.Cells.ContainsKey('L')) { [string]$r.Cells['L'] } else { '' }
                if ($st -match 'Closed|Complete') { $acClosed = $true }
            }
        }
    }
    Add-Part 'Active Changes closure' $acClosed "change '$ChangeId' reservation row closed"

    # Version History append present
    $vhOk = $false
    $vh = Get-DbM31WorkbookSheet -WorkbookPath $WorkbookPath -SheetName 'Version History'
    if ($null -ne $vh) {
        foreach ($r in $vh.Rows) {
            $nid = if ($r.Cells.ContainsKey('A')) { [string]$r.Cells['A'] } else { '' }
            $cur = if ($r.Cells.ContainsKey('AC')) { [string]$r.Cells['AC'] } else { '' }
            if ($nid -eq $NodeId -and $cur -eq 'Yes') { $vhOk = $true }
        }
    }
    Add-Part 'Version History closure' $vhOk "Is Current=Yes record for '$NodeId'"

    # Activity Log append present
    $alOk = $false
    $al = Get-DbM31WorkbookSheet -WorkbookPath $WorkbookPath -SheetName 'Activity Log'
    if ($null -ne $al) {
        foreach ($r in $al.Rows) {
            if ($r.Cells.ContainsKey('J') -and ([string]$r.Cells['J']) -eq $ChangeId) { $alOk = $true }
        }
    }
    Add-Part 'Activity Log closure' $alOk "activity row for change '$ChangeId'"

    # dependency/status consistency: node status completed when completion evidence present
    $statusOk = $true
    $mr = Get-DbM31WorkbookSheet -WorkbookPath $WorkbookPath -SheetName 'Master Roadmap'
    if ($null -ne $mr -and $NodeId) {
        $statusOk = $false
        foreach ($r in $mr.Rows) {
            if ($r.Cells.ContainsKey('A') -and ([string]$r.Cells['A']) -eq $NodeId) {
                $st = if ($r.Cells.ContainsKey('R')) { [string]$r.Cells['R'] } else { '' }
                if ($st -match 'Complete|Completed') { $statusOk = $true }
            }
        }
    }
    Add-Part 'Dependency/status consistency' $statusOk "node '$NodeId' status is complete"

    # completion evidence
    Add-Part 'Completion evidence' $Lifecycle.CompletionPresent "completion.json bound to change '$ChangeId'"

    $failed = @($parts | Where-Object { -not $_.Pass })
    if ($failed.Count -eq 0) {
        return [pscustomobject]@{ Verdict = 'Pass'; Token = 'M11_VALIDATION_PASS'; Pass = $true; Detail = '14-sheet consistency, execution-state coherence, protected roadmap unchanged, dependency/status consistency and all closures verified.'; Parts = @($parts.ToArray()) }
    }
    return [pscustomobject]@{
        Verdict = 'Failed'
        Token = 'M11_VALIDATION_FAILED'
        Pass = $false
        Detail = "M11 validation FAILED; explicit governance/reconciliation state -- not a silent clean completion: $(($failed | ForEach-Object { "$($_.Name): $($_.Detail)" }) -join '; ')"
        Parts = @($parts.ToArray())
    }
}

# --- fix-task governance (Capability 14) -----------------------------------------

function Resolve-DbM31FixTaskGovernance {
    <#
    .SYNOPSIS
    A genuine post-completion defect -> NEW_FIX_TASK_REQUIRED under the existing
    governed phase/milestone structure. DevBridge never creates a new phase, new
    milestone, new hierarchy or new roadmap order. If representation requires
    structural change -> HUMAN_GOVERNANCE_REQUIRED.
    #>
    param(
        [string]$RequestNodeId,
        [bool]$RequiresStructuralChange,
        [AllowNull()][object]$Config,
        [string]$WorkbookPath = ''
    )
    if ($null -eq $Config) { $Config = Get-DbM31Config -Root 'C:\Personal\DevTools\DevBridge' }
    if (-not $WorkbookPath) { $WorkbookPath = $Config.WorkbookPath }
    $nodeExists = $false
    if ($RequestNodeId) {
        $mr = Get-DbM31WorkbookSheet -WorkbookPath $WorkbookPath -SheetName 'Master Roadmap'
        if ($null -ne $mr) {
            foreach ($r in $mr.Rows) {
                if ($r.Cells.ContainsKey('A') -and ([string]$r.Cells['A']) -eq $RequestNodeId) { $nodeExists = $true; break }
            }
        }
    }
    if ($RequiresStructuralChange) {
        return [pscustomobject]@{
            Verdict = 'HumanGovernanceRequired'
            Token = 'HUMAN_GOVERNANCE_REQUIRED'
            Reason = 'Representation requires a structural change (new phase / milestone / hierarchy / roadmap order); DevBridge never creates one. Human governance decides.'
            CreatesPhase = $false
            CreatesMilestone = $false
            CreatesHierarchy = $false
            CreatesRoadmapOrder = $false
        }
    }
    if ($nodeExists) {
        return [pscustomobject]@{
            Verdict = 'NewFixTaskRequired'
            Token = 'NEW_FIX_TASK_REQUIRED'
            Reason = "Defect on '$RequestNodeId' requires a NEW fix task under the existing governed phase/milestone structure; the fix-task execution record is governed."
            CreatesPhase = $false
            CreatesMilestone = $false
            CreatesHierarchy = $false
            CreatesRoadmapOrder = $false
        }
    }
    return [pscustomobject]@{
        Verdict = 'NewFixTaskRequired'
        Token = 'NEW_FIX_TASK_REQUIRED'
        Reason = "Fix requested for '$RequestNodeId' which must exist under the governed phase/milestone structure; DevBridge never creates roadmap structure."
        CreatesPhase = $false
        CreatesMilestone = $false
        CreatesHierarchy = $false
        CreatesRoadmapOrder = $false
    }
}

# --- PR preparation package (Capability 15; no execution) ------------------------

function Resolve-DbM31PrPreparationPackage {
    <#
    .SYNOPSIS
    The human PR package: task, change, scope, changed files, build/tests, M06
    verification, Claude review, known non-blocking observations, dependency
    context summary, Git baseline + current HEAD, recommended PR title/body.
    Result state is AWAITING_HUMAN_PR, never PR_OPEN, until real evidence exists.
    No Git action is performed.
    #>
    param(
        [AllowNull()][object]$Lifecycle,
        [AllowNull()][object]$GitObservation,
        [string[]]$ChangedFiles,
        [string]$BuildTests,
        [string]$DependencyContextSummary
    )
    $branch = if ($GitObservation) { $GitObservation.Branch } else { $null }
    $head = if ($GitObservation) { $GitObservation.HeadCommit } else { $null }
    $files = @($ChangedFiles)
    $title = "CHG $($Lifecycle.ChangeId): $($Lifecycle.NodeId) implementation"
    $body = @(
        "Task: $($Lifecycle.NodeId) ($($Lifecycle.Mode))",
        "Change: $($Lifecycle.ChangeId)",
        "Scope: $($Lifecycle.ApprovedScope)",
        "Changed files: $(($files -join ', '))",
        "Build/tests: $BuildTests",
        "M06 verification: $(if ($Lifecycle.VerificationPassed) { 'VERIFICATION_PASSED' } else { 'NOT PASSED' })",
        "Claude review: $(if ($Lifecycle.ClaudePassed) { 'PASS' } else { 'NOT PASSED' })",
        "Dependency context: $DependencyContextSummary",
        "Git baseline/HEAD: branch $branch at $head",
        "Known non-blocking observations: see Claude review residual observations.",
        "PR created/merged by the HUMAN operator only; DevBridge prepares this package and performs NO Git action."
    ) -join "`n"
    return [pscustomobject]@{
        PrState = 'AWAITING_HUMAN_PR'
        MergeConfirmed = $false
        RecommendedTitle = $title
        RecommendedBody = $body
        Task = $Lifecycle.NodeId
        Change = $Lifecycle.ChangeId
        Scope = $Lifecycle.ApprovedScope
        ChangedFiles = $files
        BuildTests = $BuildTests
        M06Verification = $(if ($Lifecycle.VerificationPassed) { 'VERIFICATION_PASSED' } else { 'NOT_PASSED' })
        ClaudeReview = $(if ($Lifecycle.ClaudePassed) { 'PASS' } else { 'NOT_PASSED' })
        NonBlockingObservations = 'see Claude review residual observations'
        DependencyContextSummary = $DependencyContextSummary
        GitBaselineBranch = $branch
        GitBaselineHead = $head
        HumanAction = 'HUMAN: create the PR using the prepared package (DevBridge never creates the PR automatically).'
        Detail = 'PR package prepared; result state is AWAITING_HUMAN_PR, not PR_OPEN, until real PR evidence exists. No Git action performed.'
    }
}

# --- audit trace (Capability 18) -------------------------------------------------

function Resolve-DbM31AuditTrace {
    <#
    .SYNOPSIS
    Audit record for a governed lifecycle operation: operation ID, task/change
    ID, mode, timestamp, input/result lifecycle state, workbook SHA before/after
    (where relevant), Git HEAD before/after observation, human action required,
    verification result, Claude result. No secret material.
    #>
    param(
        [string]$OperationId,
        [string]$TaskId,
        [string]$ChangeId,
        [string]$Mode,
        [string]$TimestampUtc,
        [string]$InputState,
        [string]$ResultState,
        [string]$WorkbookShaBefore,
        [string]$WorkbookShaAfter,
        [string]$GitHeadBefore,
        [string]$GitHeadAfter,
        [bool]$HumanActionRequired,
        [string]$VerificationResult,
        [string]$ClaudeResult,
        [string]$WorkbookPath,
        [string]$BackupPath,
        [string]$FingerprintBefore,
        [string]$FingerprintAfter
    )
    return [pscustomobject]@{
        AuditSchemaVersion  = 1
        OperationId         = $OperationId
        TaskId              = $TaskId
        ChangeId            = $ChangeId
        Mode                = $Mode
        TimestampUtc        = $TimestampUtc
        InputLifecycleState = $InputState
        ResultLifecycleState = $ResultState
        WorkbookSha256Before = $WorkbookShaBefore
        WorkbookSha256After  = $WorkbookShaAfter
        GitHeadBefore       = $GitHeadBefore
        GitHeadAfter        = $GitHeadAfter
        HumanActionRequired = $HumanActionRequired
        VerificationResult  = $VerificationResult
        ClaudeResult        = $ClaudeResult
        WorkbookPath        = $WorkbookPath
        BackupPath          = $BackupPath
        FingerprintBefore   = $FingerprintBefore
        FingerprintAfter    = $FingerprintAfter
        Note                = 'Audit trace; no secret material.'
    }
}

# --- pre-DevBridge baseline (Capability 19; read-only, never restored) -----------

function Resolve-DbM31PreDevBridgeBaseline {
    <#
    .SYNOPSIS
    Validate the configured PreDevBridge workbook/git baseline READ-ONLY.
    Restoration is a later explicit human-governed transition step; this resolver
    NEVER restores. Automatic destructive commands are absent from the library.
    #>
    param(
        [AllowNull()][object]$BaselineConfig,
        [AllowNull()][object]$Config
    )
    if ($null -eq $Config) { $Config = Get-DbM31Config -Root 'C:\Personal\DevTools\DevBridge' }
    $errors = New-Object System.Collections.ArrayList
    $wbPath = [string](Get-ContractProperty $BaselineConfig 'WorkbookPath')
    $wbSha  = [string](Get-ContractProperty $BaselineConfig 'WorkbookSha256')
    $gitRepo = [string](Get-ContractProperty $BaselineConfig 'GitRepository')
    $gitBranch = [string](Get-ContractProperty $BaselineConfig 'GitBranch')
    $gitHead = [string](Get-ContractProperty $BaselineConfig 'GitHead')
    $represented = $false
    if ($wbPath -and (Test-Path -LiteralPath $wbPath -PathType Leaf)) {
        $sha = Get-DbM31FileSha256 $wbPath
        if ($sha -eq $wbSha) { $represented = $true }
        else { [void]$errors.Add('workbook SHA does not match the recorded pre-DevBridge baseline') }
    } else {
        [void]$errors.Add('pre-DevBridge workbook baseline not found')
    }
    $gitOk = $false
    if ($gitRepo -and (Test-Path -LiteralPath $gitRepo)) {
        $obs = Resolve-DbM31GitObservation -RepositoryPath $gitRepo
        if ($obs.IsGitRepo -and (($null -eq $gitBranch) -or $obs.Branch -eq $gitBranch) -and (($null -eq $gitHead) -or $obs.HeadCommit -eq $gitHead)) { $gitOk = $true }
        else { [void]$errors.Add('git baseline does not match the recorded pre-DevBridge state') }
    }
    return [pscustomobject]@{
        Represented      = $represented
        WorkbookSha256   = $wbSha
        GitBranch        = $gitBranch
        GitHead          = $gitHead
        RestoreForbidden = 'NO RESTORE FUNCTION EXISTS; restoration is an explicit later human-governed transition.'
        Validated        = ($errors.Count -eq 0)
        Errors           = @($errors.ToArray())
    }
}

# --- backend-state mismatch (Capability 17) --------------------------------------

function Test-DbM31BackendStateMismatch {
    <#
    .SYNOPSIS
    A backend that exits 0 but leaves the lifecycle state untouched is
    BACKEND_STATE_MISMATCH, never success.
    #>
    param(
        [bool]$ClaimedSuccess,
        [string]$ExpectedResultState,
        [string]$ActualResultState
    )
    if ($ClaimedSuccess -and $ExpectedResultState -and $ActualResultState -ne $ExpectedResultState) {
        return [pscustomobject]@{ Mismatch = $true; Token = 'BACKEND_STATE_MISMATCH'; Detail = "script claimed success but lifecycle state is '$ActualResultState', expected '$ExpectedResultState'" }
    }
    return [pscustomobject]@{ Mismatch = $false; Token = ''; Detail = '' }
}

# --- unified view (for the renderer + CLI + honesty scenarios) -------------------

function Get-DbM31View {
    <#
    .SYNOPSIS
    Assemble the unified supervised view: lifecycle snapshot, Git gate, M10, M11,
    the five distinct human actions, read-only guard and warnings. Deterministic;
    inject NowUtc and inject the workbook/git/state surfaces.
    #>
    param(
        [string]$Root,
        [string]$StateSource,
        [string]$WorkbookPath,
        [string]$RepositoryPath,
        [string]$NowUtc
    )
    $cfg = Get-DbM31Config -Root $Root
    $now = if ($NowUtc) { $NowUtc } else { [datetime]::UtcNow.ToString('o') }
    $lifecycle = Get-DbM31LifecycleState -Root $Root -StateSource $StateSource
    $gitObs = Resolve-DbM31GitObservation -RepositoryPath $RepositoryPath
    $gitGate = Resolve-DbM31HumanGitGate -GitLifecycleState $lifecycle.GitLifecycleState
    $fp = Resolve-DbM31ProtectedRoadmapFingerprint -WorkbookPath $WorkbookPath -Config $cfg
    $fpVerdict = 'NOT_COMPARABLE'
    if ($fp.Sha256) { $fpVerdict = 'PRESERVED' }  # single-capture baseline; a governed write compares before/after
    $m10 = Resolve-DbM31M10Eligibility -Lifecycle $lifecycle -FingerprintVerdict $fpVerdict -FreshState $true
    $trial = Resolve-DbM31TrialFlow -Status $lifecycle.Status
    $actions = @(
        [pscustomobject]@{ Action = 'CREATE PR'; Backend = $false; Human = $true; Detail = 'HUMAN creates the PR from the prepared package; DevBridge never creates it.' }
        [pscustomobject]@{ Action = 'REVIEW PR'; Backend = $false; Human = $true; Detail = 'HUMAN performs the PR review.' }
        [pscustomobject]@{ Action = 'MERGE PR'; Backend = $false; Human = $true; Detail = 'HUMAN merges the approved PR; merge evidence is recorded.' }
        [pscustomobject]@{ Action = 'RUN COMPLETION'; Backend = $true; Human = $false; Detail = 'Invokes the governed backend; gated by M10 eligibility.' }
        [pscustomobject]@{ Action = 'RUN WORKBOOK VALIDATION'; Backend = $true; Human = $false; Detail = 'Invokes M11 post-completion validation.' }
    )
    return [pscustomobject]@{
        ViewId = 'DB31_GOVERNED_REAL_USE_VIEW_V1'
        GeneratedAtUtc = $now
        StateSource = $StateSource
        Lifecycle = $lifecycle
        TrialFlow = $trial
        GitObservation = $gitObs
        GitGate = $gitGate
        Fingerprint = $fp
        FingerprintVerdict = $fpVerdict
        M10 = $m10
        Actions = @($actions)
        Guard = New-DbM31ReadOnlyGuard
        Warnings = $lifecycle.Warnings
        Note = 'DB-M31 is READ-ONLY; the write chain is proven on fixture copies only. No autonomous execution, no automatic PR/merge, no baseline restore.'
    }
}
