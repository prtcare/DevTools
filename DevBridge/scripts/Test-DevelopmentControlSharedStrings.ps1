<#
Test-DevelopmentControlSharedStrings.ps1
DevBridge workbook-reader shared-string regression suite (targeted).

WHAT THIS COVERS
  Microsoft Excel re-saves a workbook by storing every text cell as a shared string:
  cell t="s" whose <v> is an integer index into xl/sharedStrings.xml. The governed
  read-only reader (Read-DevelopmentControl.ps1) previously read inline strings only,
  so an Excel-re-saved workbook read every text field (headers included) as empty and
  M03 returned the invalid TASK_SELECTION_AMBIGUOUS artifact. This suite proves the
  reader now resolves BOTH encodings to identical logical values:

    (1)  inline-string reads
    (2)  shared-string reads
    (3)  inline and shared fixtures produce identical logical values (reader parity)
    (4)  Active Changes Status keyword classification works from shared cells
    (5)  Node IDs read from shared cells
    (6)  dependency values read from shared cells
    (7)  Master Roadmap text read from shared cells
    (8)  Active Changes text read from shared cells (rich-text run concatenation)
    (9)  invalid shared-string references raise an explicit parse/validation error
         (out-of-range index, non-integer index, and missing xl/sharedStrings.xml part)
    (10) M03 governed selection is UNCHANGED: a shared-encoded byte-identical copy of
         the pristine baseline yields the SAME TaskSelectionStatus / CurrentWork / Task
         as the inline baseline (SELECTED WI-07-0.2.4, never TASK_SELECTION_AMBIGUOUS).

  Empty cells are exercised (a cell present-but-empty reads "" under both encodings).

SAFETY
  Read-only against the authoritative workbook and Nexus. Every fixture is a throwaway
  copy under logs\selftest\shared-strings. The M03 engine is invoked in child processes
  with DB_DEV_CONTROL_WORKBOOK_OVERRIDE + a fixture state dir, so live state is never
  touched. M04 / M05 are NOT run. No task reservation. No workbook modification.
#>
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
Add-Type -AssemblyName System.Xml.Linq | Out-Null

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:Cfg = Get-Content (Join-Path $script:Root "config\devbridge.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$script:RealWorkbook = $script:Cfg.developmentControlWorkbook
$script:SelftestRoot = Join-Path $script:Root "logs\selftest"
if (-not (Test-Path $script:SelftestRoot)) { New-Item -ItemType Directory -Force -Path $script:SelftestRoot | Out-Null }
$script:SsRoot = Join-Path $script:SelftestRoot "shared-strings"
if (Test-Path $script:SsRoot) { Remove-Item $script:SsRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $script:SsRoot | Out-Null

# Shared read-only workbook library (the code under test).
. (Join-Path $PSScriptRoot "Read-DevelopmentControl.ps1")

$script:Pristine = $script:RealWorkbook
$preclosureBackups = @(Get-ChildItem (Join-Path $script:Root "state\backups") -Filter "db-m124-preclosure-*.xlsx" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1)
if ($preclosureBackups.Count -ge 1) {
    $script:Pristine = [string]$preclosureBackups[0].FullName
}

function Get-Hash([string]$p) { return (Get-FileHash $p -Algorithm SHA256).Hash }
$script:RealHashBefore = Get-Hash $script:RealWorkbook
$script:LiveTaskHashBefore = Get-Hash (Join-Path $script:Root "state\current-task.json")

$script:Results = @()
$script:Fails = New-Object System.Collections.Generic.List[string]
function Assert-True([string]$label, [bool]$cond, [string]$detail) {
    $script:Results += [PSCustomObject]@{ Scenario = $label; Pass = $cond; Detail = $detail }
    if (-not $cond) {
        $script:Fails.Add(("{0}: {1}" -f $label, $detail))
        Write-Output ("  [FAIL] {0} - {1}" -f $label, $detail)
    } else {
        Write-Output ("  [PASS] {0}" -f $label)
    }
}

# Redirect the reader at a fixture workbook for the duration of a call.
function Read-From([string]$path, [scriptblock]$body) {
    $prev = $script:DevControlWorkbook
    $script:DevControlWorkbook = $path
    try { return & $body } finally { $script:DevControlWorkbook = $prev }
}

# ---------------------------------------------------------------------------
# Fixture construction
# ---------------------------------------------------------------------------
function Add-ZipTextEntry($zip, [string]$name, [string]$text) {
    $entry = $zip.CreateEntry($name)
    $sw = New-Object System.IO.StreamWriter($entry.Open(), (New-Object System.Text.UTF8Encoding($false)))
    $sw.Write($text)
    $sw.Flush()
    $sw.Dispose()
}

function Escape-Xml([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return "" }
    return [System.Security.SecurityElement]::Escape($s)
}

# Master Roadmap (sheet1) logical rows and Active Changes (sheet2) logical rows.
$script:MASTER_COLS = @('A','B','C','D','E','F','G')
$script:MASTER_HEADERS = @('Node ID','Parent ID','Node Type','Name','Status','Dependencies','Breakdown Complete')
$script:MASTER_ROWS = @(
    @('F-01-0','','Feature','Feature One','Planned','','No'),
    @('M-01-0.1','F-01-0','Milestone','Milestone One','In Progress','','No'),
    @('WI-01-0.1.1','M-01-0.1','WorkItem','Leaf Inline','Planned','M-01-0.1.2','Yes')
)
$script:MASTER_ROWNUMS = @(6,7,8)
$script:ACTIVE_COLS = @('A','B','L')
$script:ACTIVE_HEADERS = @('Change ID','Node ID','Status')
$script:ACTIVE_ROWS = @(
    @('CHG-T-1','WI-01-0.1.1','In Progress - micro shared-string fixture'),
    @('CHG-T-2','M-01-0.1','Completed - micro shared-string fixture')
)
$script:ACTIVE_ROWNUMS = @(6,7)
$script:RICH_VALUE = 'Completed - micro shared-string fixture'
$script:RICH_RUN1 = 'Completed - micro '
$script:RICH_RUN2 = 'shared-string fixture'

# Build the micro fixture workbook. $variant selects the cell encoding:
#   inline  -> every text cell inlineStr (headers + data); no sharedStrings part
#   shared  -> every text cell t="s"; sharedStrings part present; one Status is rich text
#   badidx  -> shared, but Master Roadmap A8's index forced to 5000 (out of range)
#   badstr  -> shared, but Master Roadmap A8's index forced to "abc" (non-integer)
#   nopart  -> shared cell encoding, but the xl/sharedStrings.xml part is OMITTED
function New-Micro([string]$path, [string]$variant) {
    $rich = ($variant -eq 'shared')  # rich text stored on the Active row-7 Status
    $badV = $null
    if ($variant -eq 'badidx') { $badV = '5000' }
    elseif ($variant -eq 'badstr') { $badV = 'abc' }

    # Assign shared indexes over non-empty values in emission order.
    $stList = New-Object System.Collections.Generic.List[string]
    $stMap = @{}
    function Add-Shared([string]$val) {
        if ($val -eq '' -or $val -eq $null) { return $null }
        if ($stMap.ContainsKey($val)) { return $stMap[$val] }
        $stMap[$val] = $stList.Count
        $stList.Add($val)
        return $stList.Count - 1
    }
    foreach ($h in $script:MASTER_HEADERS) { $null = Add-Shared $h }
    for ($i = 0; $i -lt $script:MASTER_ROWS.Count; $i++) { foreach ($v in $script:MASTER_ROWS[$i]) { $null = Add-Shared $v } }
    foreach ($h in $script:ACTIVE_HEADERS) { $null = Add-Shared $h }
    for ($i = 0; $i -lt $script:ACTIVE_ROWS.Count; $i++) { foreach ($v in $script:ACTIVE_ROWS[$i]) { $null = Add-Shared $v } }

    $hasShared = ($variant -ne 'inline')
    # nopart encodes cells as shared strings but omits the xl/sharedStrings.xml part.
    $addSharedPart = ($hasShared -and $variant -ne 'nopart')
    $cellSb = New-Object System.Text.StringBuilder
    function Emit-Cell([string]$variant2, [string]$ref, [string]$value, [string]$vOverride) {
        # Emits a single <c> fragment for $value at $ref. $vOverride (tests only) forces the
        # literal <v> body of a shared cell so out-of-range / non-integer references can be
        # exercised without going through index assignment.
        if ($variant2 -eq 'inline') {
            [void]$cellSb.Append('<c r="' + $ref + '" t="inlineStr"><is><t xml:space="preserve">' + (Escape-Xml $value) + '</t></is></c>')
        } else {
            # shared encoding
            if ($value -eq '' -or $value -eq $null) {
                [void]$cellSb.Append('<c r="' + $ref + '" t="s"><v/></c>')
            } else {
                $idxText = ""
                if ($vOverride -ne $null -and $vOverride -ne "") { $idxText = $vOverride }
                else { $idxText = [string]$stMap[$value] }
                [void]$cellSb.Append('<c r="' + $ref + '" t="s"><v>' + $idxText + '</v></c>')
            }
        }
    }
    function Reset-CellBuffer { [void]$cellSb.Clear() }
    function Take-Cells { $t = $cellSb.ToString(); Reset-CellBuffer; return $t }

    function Build-Sheet([string]$variant2, [string[]]$cols, [string[]]$headers, [array]$rows, [array]$rownums, [string]$forcedA8) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
        [void]$sb.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>')
        # header row
        [void]$sb.Append('<row r="5">')
        for ($c = 0; $c -lt $cols.Count; $c++) { Emit-Cell $variant2 ($cols[$c] + '5') $headers[$c] "" }
        [void]$sb.Append((Take-Cells))
        [void]$sb.Append('</row>')
        # data rows
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $rn = $rownums[$i]
            [void]$sb.Append('<row r="' + $rn + '">')
            for ($c = 0; $c -lt $cols.Count; $c++) {
                $ref = $cols[$c] + $rn
                $val = [string]$rows[$i][$c]
                $override = ""
                if ($forcedA8 -and $ref -eq 'A8') { $override = $forcedA8 }
                Emit-Cell $variant2 $ref $val $override
            }
            [void]$sb.Append((Take-Cells))
            [void]$sb.Append('</row>')
        }
        [void]$sb.Append('</sheetData></worksheet>')
        return $sb.ToString()
    }

    $sheet1 = Build-Sheet $variant $script:MASTER_COLS $script:MASTER_HEADERS $script:MASTER_ROWS $script:MASTER_ROWNUMS $badV
    $sheet2 = Build-Sheet $variant $script:ACTIVE_COLS $script:ACTIVE_HEADERS $script:ACTIVE_ROWS $script:ACTIVE_ROWNUMS $null

    $contentTypes = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
'@
    $relsRoot = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
'@
    $workbookXml = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Master Roadmap" sheetId="1" r:id="rId1"/><sheet name="Active Changes" sheetId="2" r:id="rId2"/></sheets></workbook>
'@
    $workbookRels = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/></Relationships>
'@

    $fs = [System.IO.File]::Create($path)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        Add-ZipTextEntry $zip "[Content_Types].xml" $contentTypes
        Add-ZipTextEntry $zip "_rels/.rels" $relsRoot
        Add-ZipTextEntry $zip "xl/workbook.xml" $workbookXml
        Add-ZipTextEntry $zip "xl/_rels/workbook.xml.rels" $workbookRels
        Add-ZipTextEntry $zip "xl/worksheets/sheet1.xml" $sheet1
        Add-ZipTextEntry $zip "xl/worksheets/sheet2.xml" $sheet2
        if ($addSharedPart) {
            $ssb = New-Object System.Text.StringBuilder
            [void]$ssb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
            [void]$ssb.Append('<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="' + $stList.Count + '" uniqueCount="' + $stList.Count + '">')
            for ($k = 0; $k -lt $stList.Count; $k++) {
                $val = $stList[$k]
                if ($rich -and $val -eq $script:RICH_VALUE) {
                    [void]$ssb.Append('<si><r><t xml:space="preserve">' + (Escape-Xml $script:RICH_RUN1) + '</t></r><r><t xml:space="preserve">' + (Escape-Xml $script:RICH_RUN2) + '</t></r></si>')
                } else {
                    [void]$ssb.Append('<si><t xml:space="preserve">' + (Escape-Xml $val) + '</t></si>')
                }
            }
            [void]$ssb.Append('</sst>')
            Add-ZipTextEntry $zip "xl/sharedStrings.xml" $ssb.ToString()
        }
    } finally {
        $zip.Dispose()
        $fs.Dispose()
    }
    return $path
}

# ---------------------------------------------------------------------------
# Shared-string re-encoder for whole workbooks (inline -> shared). Used to build a
# byte-identical-logical shared copy of the PRISTINE baseline for the governance
# equivalence check (#10). Every inlineStr cell in every worksheet is converted to
# t="s" against a freshly written xl/sharedStrings.xml; non-string cells are left
# untouched; an already-shared source is refused (never double-encoded).
# ---------------------------------------------------------------------------
function Convert-ToSharedWorkbook([string]$srcPath, [string]$dstPath) {
    $xNs2 = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    $srcFs = [System.IO.File]::OpenRead($srcPath)
    $zipSrc = New-Object System.IO.Compression.ZipArchive($srcFs, [System.IO.Compression.ZipArchiveMode]::Read)
    $dstFs = [System.IO.File]::Create($dstPath)
    $zipDst = New-Object System.IO.Compression.ZipArchive($dstFs, [System.IO.Compression.ZipArchiveMode]::Create)
    $shared = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($e in $zipSrc.Entries) {
            $name = $e.FullName
            if ($name -match '^xl/worksheets/sheet[0-9]+\.xml$') {
                $rd = New-Object System.IO.StreamReader($e.Open())
                $doc = [System.Xml.Linq.XDocument]::Load($rd)
                $rd.Close()
                $sd = $doc.Root.Element($xNs2 + "sheetData")
                if ($sd) {
                    foreach ($cell in @($sd.Descendants($xNs2 + "c"))) {
                        $tAttr = $cell.Attribute("t")
                        if ($null -eq $tAttr) { continue }
                        if ($tAttr.Value -eq "s") { throw "source workbook already uses shared strings: $name" }
                        if ($tAttr.Value -ne "inlineStr") { continue }
                        $is = $cell.Element($xNs2 + "is")
                        $text = ""
                        if ($is) { $text = [string]$is.Value }
                        $shared.Add($text)
                        if ($is) { $is.Remove() }
                        $tAttr.Value = "s"
                        $v = New-Object System.Xml.Linq.XElement($xNs2 + "v")
                        $v.Add([string]($shared.Count - 1))
                        $cell.Add($v)
                    }
                }
                $ne = $zipDst.CreateEntry($name)
                $os = $ne.Open()
                $doc.Save($os, [System.Xml.Linq.SaveOptions]::DisableFormatting)
                $os.Dispose()
            } elseif ($name -eq "xl/sharedStrings.xml") {
                # rebuilt below
            } else {
                $ne = $zipDst.CreateEntry($name)
                $os = $ne.Open(); $in = $e.Open()
                $in.CopyTo($os)
                $in.Dispose(); $os.Dispose()
            }
        }
        $ssb = New-Object System.Text.StringBuilder
        [void]$ssb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
        [void]$ssb.Append('<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="' + $shared.Count + '" uniqueCount="' + $shared.Count + '">')
        for ($k = 0; $k -lt $shared.Count; $k++) {
            [void]$ssb.Append('<si><t xml:space="preserve">' + (Escape-Xml $shared[$k]) + '</t></si>')
        }
        [void]$ssb.Append('</sst>')
        $ne = $zipDst.CreateEntry("xl/sharedStrings.xml")
        $os = $ne.Open()
        $sw = New-Object System.IO.StreamWriter($os, (New-Object System.Text.UTF8Encoding($false)))
        $sw.Write($ssb.ToString())
        $sw.Flush(); $sw.Dispose(); $os.Dispose()
    } finally {
        $zipDst.Dispose(); $dstFs.Dispose()
        $zipSrc.Dispose(); $srcFs.Dispose()
    }
    return $dstPath
}

# ---------------------------------------------------------------------------
# Test fixtures
# ---------------------------------------------------------------------------
$fixtureDir = Join-Path $script:SsRoot "workbooks"
New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null
$microInline = New-Micro (Join-Path $fixtureDir "micro-inline.xlsx") "inline"
$microShared  = New-Micro (Join-Path $fixtureDir "micro-shared.xlsx") "shared"
$microBadIdx  = New-Micro (Join-Path $fixtureDir "micro-badidx.xlsx") "badidx"
$microBadStr  = New-Micro (Join-Path $fixtureDir "micro-badstr.xlsx") "badstr"
$microNoPart  = New-Micro (Join-Path $fixtureDir "micro-nopart.xlsx") "nopart"

$inlineBaseline = Join-Path $fixtureDir "baseline-inline.xlsx"
Copy-Item $script:Pristine $inlineBaseline -Force
$sharedBaseline = Convert-ToSharedWorkbook $inlineBaseline (Join-Path $fixtureDir "baseline-shared.xlsx")

Write-Output ("shared-strings fixtures: micro({0}/{1}/{2}/{3}/{4} bytes), baseline inline->shared ({5} bytes)" -f (Get-Item $microInline).Length, (Get-Item $microShared).Length, (Get-Item $microBadIdx).Length, (Get-Item $microBadStr).Length, (Get-Item $microNoPart).Length, (Get-Item $sharedBaseline).Length)

# ---------------------------------------------------------------------------
# Snapshot of reader-visible domain state (used for parity assertions).
# ---------------------------------------------------------------------------
function Get-ReaderSnapshot([string]$wb) {
    return Read-From $wb {
        $nodes = @(Get-AllRoadmapNodes | Sort-Object NodeId | ForEach-Object {
            [ordered]@{ id = $_.NodeId; pid = $_.ParentId; nt = $_.NodeType; name = $_.Name; status = $_.Status; deps = $_.Dependencies; bc = $_.BreakdownComplete }
        })
        $ac = @(Get-AllActiveChanges | Sort-Object ChangeId | ForEach-Object {
            [ordered]@{ cid = $_.ChangeId; nid = $_.NodeId; status = $_.Status; cls = $_.Classification }
        })
        return [ordered]@{ nodes = $nodes; ac = $ac }
    } | ConvertTo-Json -Depth 6 -Compress
}

Write-Output "== properties =="

# --- (1) inline reads --------------------------------------------------------
$nodeById = Read-From $microInline { Get-RoadmapNodeById "WI-01-0.1.1" }
Assert-True "P1 inline cell text reads back" `
    ($nodeById -and $nodeById.Name -eq "Leaf Inline" -and $nodeById.NodeType -eq "WorkItem" -and $nodeById.Status -eq "Planned") `
    ("got Name='$(if ($nodeById) { $nodeById.Name } else { '<null>' })' NodeType='$(if ($nodeById) { $nodeById.NodeType } else { '<null>' })' Status='$(if ($nodeById) { $nodeById.Status } else { '<null>' })'")

# --- (2) shared reads --------------------------------------------------------
$nodeShared = Read-From $microShared { Get-RoadmapNodeById "WI-01-0.1.1" }
Assert-True "P2 shared-string cell text reads back" `
    ($nodeShared -and $nodeShared.Name -eq "Leaf Inline" -and $nodeShared.NodeType -eq "WorkItem" -and $nodeShared.Status -eq "Planned") `
    ("got Name='$(if ($nodeShared) { $nodeShared.Name } else { '<null>' })' NodeType='$(if ($nodeShared) { $nodeShared.NodeType } else { '<null>' })' Status='$(if ($nodeShared) { $nodeShared.Status } else { '<null>' })'")

# --- (3) identical logical values, inline vs shared --------------------------
$snapInline = Get-ReaderSnapshot $microInline
$snapShared = Get-ReaderSnapshot $microShared
Assert-True "P3 inline and shared fixtures expose identical logical values" ($snapInline -eq $snapShared) `
    ("inline != shared: " + $(if ($snapInline.Length -gt 400) { $snapInline.Substring(0,400) } else { $snapInline }) + " VS " + $(if ($snapShared.Length -gt 400) { $snapShared.Substring(0,400) } else { $snapShared }))

# --- (4) Active Changes Status classification from shared cells --------------
$acRows = @(Read-From $microShared { @(Get-AllActiveChanges) })
$acRow6 = @($acRows | Where-Object { $_.ChangeId -eq "CHG-T-1" })[0]
$acRow7 = @($acRows | Where-Object { $_.ChangeId -eq "CHG-T-2" })[0]
$openRows = @(Read-From $microShared { @(Get-ActiveChangesOpen) })
Assert-True "P4 shared Status keyword classifies InProgress (row CHG-T-1) and Terminal (row CHG-T-2); open list excludes terminal" `
    ($acRow6.Status -like "In Progress*" -and $acRow6.Classification -eq "InProgress" -and $acRow7.Status -like "Completed*" -and $acRow7.Classification -eq "Terminal" -and $openRows.Count -eq 1 -and $openRows[0].ChangeId -eq "CHG-T-1") `
    ("CHG-T-1: '$($acRow6.Status)'/'$($acRow6.Classification)'; CHG-T-2: '$($acRow7.Status)'/'$($acRow7.Classification)'; open count=$($openRows.Count)")

# --- (5) Node IDs from shared cells ------------------------------------------
$nMs = Read-From $microShared { Get-RoadmapNodeById "M-01-0.1" }
$nF = Read-From $microShared { Get-RoadmapNodeById "F-01-0" }
Assert-True "P5 Node IDs read from shared cells (roadmap + Active Changes Node ID)" `
    ($nodeShared -ne $null -and $nMs -and $nMs.NodeType -eq "Milestone" -and $nF -and $nF.NodeType -eq "Feature" -and $acRow6.NodeId -eq "WI-01-0.1.1" -and $acRow7.NodeId -eq "M-01-0.1") `
    ("got WI='$($nodeShared.NodeId)' M='$(if($nMs){$nMs.NodeId}else{'<null>'})' F='$(if($nF){$nF.NodeId}else{'<null>'})' ac6='$($acRow6.NodeId)' ac7='$($acRow7.NodeId)'")

# --- (6) dependency values from shared cells ---------------------------------
$nDep = Read-From $microShared { Get-RoadmapNodeById "WI-01-0.1.1" }
$nDepEmpty = Read-From $microShared { Get-RoadmapNodeById "M-01-0.1" }
Assert-True "P6 Dependencies field reads from shared cells (value + empty both encodings agree)" `
    ($nDep.Dependencies -eq "M-01-0.1.2" -and $nDepEmpty.Dependencies -eq "" -and (Read-From $microInline { (Get-RoadmapNodeById "WI-01-0.1.1").Dependencies }) -eq "M-01-0.1.2") `
    ("WI deps='$($nDep.Dependencies)' M empty-deps='$($nDepEmpty.Dependencies)'")

# --- (7) Master Roadmap text from shared cells -------------------------------
Assert-True "P7 Master Roadmap text (Status/Name/Breakdown) reads from shared cells" `
    ($nMs.Status -eq "In Progress" -and $nMs.Name -eq "Milestone One" -and $nDep.BreakdownComplete -eq "Yes") `
    ("M status='$($nMs.Status)' name='$($nMs.Name)' BC(leaf)='$($nDep.BreakdownComplete)'")

# --- (8) Active Changes text from shared cells (rich-text run concat) --------
Assert-True "P8 Active Changes text (rich-text shared item) reads as concatenated runs" `
    ($acRow7.Status -eq $script:RICH_VALUE -and $acRow6.Status -eq "In Progress - micro shared-string fixture") `
    ("CHG-T-2 Status='$($acRow7.Status)' ; CHG-T-1 Status='$($acRow6.Status)'")

# --- (9) invalid shared-string references fail explicitly --------------------
function Get-ThrownMessage([string]$wb, [scriptblock]$read) {
    try { $null = Read-From $wb $read; return $null }
    catch { return $_.Exception.Message }
}
$mIdx = Get-ThrownMessage $microBadIdx { @(Get-AllRoadmapNodes) }
$mStr = Get-ThrownMessage $microBadStr { @(Get-AllRoadmapNodes) }
$mNoPart = Get-ThrownMessage $microNoPart { @(Get-AllRoadmapNodes) }
Assert-True "P9a out-of-range shared index raises an explicit validation error naming the cell" `
    ($mIdx -and $mIdx -match "shared-string index" -and $mIdx -match "out of range" -and $mIdx -match "A8") ("message: $mIdx")
Assert-True "P9b non-integer shared index raises an explicit parse error" `
    ($mStr -and $mStr -match "non-integer") ("message: $mStr")
Assert-True "P9c shared cell with no xl/sharedStrings.xml part raises an explicit validation error" `
    ($mNoPart -and $mNoPart -match "no xl/sharedStrings.xml part") ("message: $mNoPart")

# --- (10) M03 governance unchanged on a shared-encoded baseline --------------
Write-Output "== governance equivalence (M03 engine on inline vs shared baseline) =="
function Invoke-NextTaskEngine([string]$wbCopy, [string]$tag) {
    $stateDir = Join-Path $script:SsRoot ("engine-" + $tag)
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    Set-Item "env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE" $wbCopy
    Set-Item "env:DB_NEXTTASK_STATE_DIR" $stateDir
    Set-Item "env:DB_NEXTTASK_CONFIG_PATH" (Join-Path $script:Root "config\devbridge.json")
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Get-NextTask.ps1") 2>&1)
    } finally {
        $ErrorActionPreference = $oldEAP
    }
    foreach ($k in @("DB_DEV_CONTROL_WORKBOOK_OVERRIDE","DB_NEXTTASK_STATE_DIR","DB_NEXTTASK_CONFIG_PATH")) { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue }
    $out = @($out | ForEach-Object { "$_" })
    $res = [ordered]@{ status = ""; currentWork = ""; task = ""; blockState = ""; exitCode = $LASTEXITCODE; output = ($out -join "`n") }
    $sl = $out | Select-String -Pattern '^TaskSelectionStatus\s*:\s*' | Select-Object -First 1
    if ($sl) { $res.status = ($sl.Line -replace '^TaskSelectionStatus\s*:\s*', '').Trim() }
    $cl = $out | Select-String -Pattern '^CurrentWork\s*:\s*' | Select-Object -First 1
    if ($cl) { $res.currentWork = ($cl.Line -replace '^CurrentWork\s*:\s*', '').Trim() }
    $tl = $out | Select-String -Pattern '^Task\s*:\s*([A-Z0-9.-]+)' | Select-Object -First 1
    if ($tl) { $res.task = $tl.Matches[0].Groups[1].Value }
    $bl = $out | Select-String -Pattern '^BlockState\s*:\s*' | Select-Object -First 1
    if ($bl) { $res.blockState = ($bl.Line -replace '^BlockState\s*:\s*', '').Trim() }
    return $res
}
$resInline = Invoke-NextTaskEngine $inlineBaseline "inline"
$resShared = Invoke-NextTaskEngine $sharedBaseline "shared"

Assert-True "P10 M03 engine parses the pristine baseline to SELECTED WI-07-0.2.4 (inline)" `
    ($resInline.status -eq "SELECTED" -and $resInline.currentWork -eq "M-07-0.2" -and $resInline.task -eq "WI-07-0.2.4") `
    ("inline engine -> status='$($resInline.status)' cw='$($resInline.currentWork)' task='$($resInline.task)' exit=$($resInline.exitCode)")
Assert-True "P10 M03 engine produces the SAME governed selection on the shared-encoded baseline (never TASK_SELECTION_AMBIGUOUS)" `
    ($resShared.status -eq $resInline.status -and $resShared.status -eq "SELECTED" -and $resShared.currentWork -eq $resInline.currentWork -and $resShared.task -eq $resInline.task) `
    ("shared engine -> status='$($resShared.status)' cw='$($resShared.currentWork)' task='$($resShared.task)' exit=$($resShared.exitCode)")

# ---- invariants over the real workbook + live evidence ----------------------
Write-Output "== invariants =="
$realHashAfter = Get-Hash $script:RealWorkbook
Assert-True "I1 authoritative workbook untouched by suite" ($realHashAfter -eq $script:RealHashBefore) "authoritative workbook hash changed"
$liveTaskHashAfter = Get-Hash (Join-Path $script:Root "state\current-task.json")
Assert-True "I3 live state current-task.json untouched" ($liveTaskHashAfter -eq $script:LiveTaskHashBefore) "live current-task.json changed"

# --- summary ------------------------------------------------------------------
Write-Output ""
$failCount = $script:Fails.Count
Write-Output ("DB-SHARED-STRINGS SAFETY SUMMARY: {0} checks, {1} passed, {2} failed" -f $script:Results.Count, ($script:Results.Count - $failCount), $failCount)
if ($failCount -gt 0) {
    Write-Output "FAILURES:"
    foreach ($f in $script:Fails) { Write-Output ("  - " + $f) }
    exit 1
}
Write-Output "DB-SHARED-STRINGS SUITE: PASS"
exit 0
