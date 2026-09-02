# Get-ProtectedRoadmapFingerprint.ps1
# DevBridge DB-GH01 PROTECTED ROADMAP FINGERPRINT -- deterministic structural
# fingerprint over the PROTECTED roadmap surface (config\roadmap-protection.json).
#
# The fingerprint covers phase/milestone identity, hierarchy, goals/outcomes,
# acceptance criteria, dependencies, sequencing/structure, and architecture
# references. It is explicitly NOT a whole-workbook hash and does NOT include
# execution-state columns (Status, Progress, Owner, Current Evidence, Next
# Action, Notes, Source).
#
# Roles:
#   -Role before   capture the PRE-write fingerprint   -> state\roadmap-fingerprint.json {before:{...}}
#   -Role after    capture the POST-write fingerprint  -> merges {before, after} and the engine guard
#                  (ProtectedRoadmapFingerprintGuard) compares them.
#   -Role single   (default) capture-only evidence     -> {fingerprint:{...}} (guard => NotComparable).
#
# READ-ONLY: never writes the workbook. Backend contract: ALWAYS exits 0;
# outcomes are communicated ONLY via stdout markers.
param(
    [ValidateSet("before","after","single")]
    [string]$Role = "single"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Read-DevelopmentControl.ps1"

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:StateDir = Join-Path $script:Root "state"
$script:CfgPath = Join-Path $script:Root "config\roadmap-protection.json"
$script:FpPath = Join-Path $script:StateDir "roadmap-fingerprint.json"
$script:NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

function Out-FpError([string]$msg) {
    Write-Output ("DBGH01_FINGERPRINT_ERROR: " + $msg)
    Write-Output ("DBGH01_FINGERPRINT: ERROR")
    Write-Output "DBGH01_OUTCOME: FINGERPRINT_ERROR"
    exit 0
}

if (-not (Test-Path $script:CfgPath)) { Out-FpError "roadmap-protection.json not found: $script:CfgPath" }
$script:Cfg = Get-Content $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($script:Cfg.schemaVersion -ne 1) { Out-FpError "roadmap-protection schema version $($script:Cfg.schemaVersion) != 1" }

# Shared strings resolution (t="s" cells index into xl/sharedStrings.xml).
$script:SharedStrings = @()
try {
    $ssDoc = Open-DocEntry "xl/sharedStrings.xml"
    foreach ($si in $ssDoc.Root.Elements($xNs + "si")) {
        $txt = ""
        foreach ($t in $si.Elements($xNs + "t")) { $txt += [string]$t.Value }
        foreach ($r in $si.Elements($xNs + "r")) { $txt += [string]$r.Value }
        $script:SharedStrings += $txt
    }
} catch {
    # No sharedStrings part (workbook uses inline/literal values) -- leave empty.
}

function Get-ProtectedCellVal($row, [string]$col) {
    foreach ($cell in $row.Elements($xNs + "c")) {
        $refAttr = $cell.Attribute("r")
        if (-not $refAttr) { continue }
        $ref = [string]$refAttr.Value
        if (($ref -replace "[0-9]", "") -ne $col) { continue }
        $tAttr = $cell.Attribute("t"); $t = ""
        if ($tAttr) { $t = [string]$tAttr.Value }
        if ($t -eq "inlineStr") { $is = $cell.Element($xNs + "is"); if ($is) { return [string]$is.Value } }
        if ($t -eq "s") {
            $v = $cell.Element($xNs + "v")
            if ($v) {
                $idx = 0; [void][int]::TryParse([string]$v.Value, [ref]$idx)
                if ($idx -ge 0 -and $idx -lt $script:SharedStrings.Count) { return [string]$script:SharedStrings[$idx] }
            }
            return ""
        }
        $fEl = $cell.Element($xNs + "f")
        if ($fEl) { return "" }   # formula cells: no cached value in this workbook
        $v = $cell.Element($xNs + "v"); if ($v) { return [string]$v.Value }
        return ""
    }
    return ""
}

# Authoritative data-start rows from the verified column map (never hard-coded).
$script:MapSheets = @{}
foreach ($ms in ($script:DevControlMap.sheets)) {
    $script:MapSheets[[string]$ms.name] = [int]$ms.dataStartRow
}

# ---- Assemble canonical protected surface ----
$script:Canonical = New-Object System.Text.StringBuilder
$script:Coverage = New-Object System.Collections.Generic.List[string]
$script:CellsRead = 0
$script:ProtectedRowCount = 0
$script:UnprotectedSheetErrors = New-Object System.Collections.Generic.List[string]

foreach ($ps in @($script:Cfg.sheets)) {
    $sheetName = [string]$ps.sheet
    if (-not $script:MapSheets.ContainsKey($sheetName)) {
        $script:UnprotectedSheetErrors.Add("no dataStartRow mapped for sheet '$sheetName'")
        continue
    }
    $dataStart = $script:MapSheets[$sheetName]
    $allCols = @($ps.identityColumns) + @($ps.structureColumns) + @($ps.architectureColumns)
    $allCols = @($allCols | Sort-Object -Unique)
    try { $doc = Open-DocEntry (Get-SheetEntryName $sheetName) } catch {
        $script:UnprotectedSheetErrors.Add("sheet '$sheetName' failed to open: " + $_.Exception.Message)
        continue
    }
    $script:Coverage.Add($sheetName) | Out-Null
    $sheetRowCount = 0
    foreach ($row in $doc.Root.Elements($xNs + "sheetData").Elements($xNs + "row")) {
        $rn = Get-RowNumber $row
        if ($rn -lt $dataStart) { continue }
        $sheetRowCount++
        foreach ($col in $allCols) {
            $v = Get-ProtectedCellVal $row $col
            if ($null -eq $v) { continue }
            $v = ([string]$v).Trim()
            if ($v.Length -eq 0) { continue }
            $script:CellsRead++
            [void]$script:Canonical.Append($sheetName).Append("|").Append($col).Append("|").Append($rn).Append("|").Append($v).Append(";")
        }
    }
    $script:ProtectedRowCount += $sheetRowCount
}

$script:HashInput = $script:Canonical.ToString()
$sha = [System.Security.Cryptography.SHA256]::Create()
$bytes = [System.Text.Encoding]::UTF8.GetBytes($script:HashInput)
$hashHex = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "")

$fpObj = [ordered]@{
    value          = $hashHex
    sheetCoverage  = ($script:Coverage -join ";")
    configSource   = "config\roadmap-protection.json"
    computedAtUtc  = $script:NowUtc
    algorithm      = "SHA-256"
    protectedRows  = $script:ProtectedRowCount
    protectedCells = $script:CellsRead
    error          = $(if ($script:UnprotectedSheetErrors.Count -gt 0) { ($script:UnprotectedSheetErrors -join "; ") } else { $null })
}

# ---- Merge into state\roadmap-fingerprint.json per role ----
$script:Existing = [ordered]@{}
if (Test-Path $script:FpPath) {
    $existingRaw = Get-Content $script:FpPath -Raw -Encoding UTF8
    if ($existingRaw) {
        $parsed = $existingRaw | ConvertFrom-Json
        if ($parsed.PSObject.Properties.Name -contains "before") { $script:Existing["before"] = $parsed.before }
        if ($parsed.PSObject.Properties.Name -contains "after")  { $script:Existing["after"]  = $parsed.after }
    }
}

$script:Out = [ordered]@{}
if ($Role -eq "before") {
    $script:Existing["before"] = $fpObj
    $script:Out["before"] = $fpObj
    if ($script:Existing.Contains("after")) { $script:Out["after"] = $script:Existing["after"] }
} elseif ($Role -eq "after") {
    if (-not $script:Existing.Contains("before")) { Out-FpError "no 'before' capture found; -Role after requires a prior -Role before capture" }
    $script:Existing["after"] = $fpObj
    $script:Out["before"] = $script:Existing["before"]
    $script:Out["after"] = $fpObj
} else {
    $script:Out["fingerprint"] = $fpObj
}
$script:Out["updatedAtUtc"] = $script:NowUtc

[System.IO.File]::WriteAllText($script:FpPath, ($script:Out | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

# ---- Stdout markers (only channel of truth; always exit 0) ----
Write-Output ("DBGH01_FINGERPRINT: " + $hashHex)
Write-Output ("DBGH01_FINGERPRINT_COVERAGE: " + ($script:Coverage -join ";"))
Write-Output ("DBGH01_FINGERPRINT_ROWS: " + $script:ProtectedRowCount)
Write-Output ("DBGH01_FINGERPRINT_CELLS: " + $script:CellsRead)
Write-Output ("DBGH01_FINGERPRINT_ROLE: " + $Role)
if ($script:UnprotectedSheetErrors.Count -gt 0) {
    Write-Output ("DBGH01_FINGERPRINT_ERROR: " + ($script:UnprotectedSheetErrors -join "; "))
}
Write-Output "DBGH01_OUTCOME: FINGERPRINT_CAPTURED"
Write-Output ("DBGH01_STATE_FILE: " + $script:FpPath)
exit 0
