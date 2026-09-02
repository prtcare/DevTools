$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
. "C:\Personal\DevTools\DevBridge\scripts\Set-DevBridgeStateEntry.ps1"
. "C:\Personal\DevTools\DevBridge\scripts\Read-DevelopmentControl.ps1"
$xNs = [System.Xml.Linq.XNamespace]"http://schemas.openxmlformats.org/spreadsheetml/2006/main"
$Root = "C:\Personal\DevTools\DevBridge"
function Write-Cell($sd, [int]$rn, [string]$col, [string]$value) {
  if ($value -eq "") { return }
  $rowEl = $null
  foreach ($r in $sd.Elements($xNs + "row")) { if ([int]$r.Attribute("r").Value -eq $rn) { $rowEl = $r; break } }
  if (-not $rowEl) { $rowEl = New-Object System.Xml.Linq.XElement($xNs + "row"); $rowEl.SetAttributeValue("r", $rn); $sd.Add($rowEl) }
  $cell = $null
  foreach ($c in $rowEl.Elements($xNs + "c")) { if (([string]$c.Attribute("r").Value) -eq ($col + $rn)) { $cell = $c; break } }
  if ($cell) {
    foreach ($child in @($cell.Elements($xNs + "v"))) { $child.Remove() }
    foreach ($child in @($cell.Elements($xNs + "is"))) { $child.Remove() }
    $cell.SetAttributeValue("t", "inlineStr")
    $is = New-Object System.Xml.Linq.XElement($xNs + "is")
    $t = New-Object System.Xml.Linq.XElement($xNs + "t"); $t.Add([string]$value); $is.Add($t)
    $cell.Add($is)
  } else {
    $c = New-Object System.Xml.Linq.XElement($xNs + "c"); $c.SetAttributeValue("r", ($col + $rn)); $c.SetAttributeValue("t", "inlineStr")
    $is = New-Object System.Xml.Linq.XElement($xNs + "is")
    $t = New-Object System.Xml.Linq.XElement($xNs + "t"); $t.Add([string]$value); $is.Add($t)
    $c.Add($is); $rowEl.Add($c)
  }
}
$outDir = Join-Path $Root "logs\selftest\_repro_s4b"
if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
$stateDir = Join-Path $outDir "state"; $tasksDir = Join-Path $outDir "tasks"
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null
$wbCopy = Join-Path $outDir "workbook.xlsx"
Copy-Item "C:\Personal\DevTools\DevBridge\state\backups\db-m124-preclosure-20260831152502.xlsx" $wbCopy -Force
$backupDir = Join-Path $stateDir "backups"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$backup = [string](Join-Path $backupDir "pre-reservation.xlsx")
Copy-Item $wbCopy $backup -Force
$backupSha = [string](Get-FileHash $backup -Algorithm SHA256).Hash
$cur = [ordered]@{
  nodeId = "WI-07-0.2.4"; taskId = "WI-07-0.2.4"; name = "DB-M12.4 fixture s4"
  nodeType = "WorkItem"; phase = "P0"; layer = "App"; changeId = "CHG-20260830-017"
  status = "CLAUDE_REVIEW_PASSED_TRIAL"; nextAllowedAction = "TRIAL_CYCLE_SAFE_STOP"; selectedAt = "2026-08-31T00:00:00Z"
  mode = "TRIAL"
  dbM08 = [ordered]@{ implementationState = "TRIAL_ONLY_UNMERGED"; m10Run = $false; trialMode = $true }
  dbM06 = [ordered]@{ implementationState = "TRIAL_ONLY_UNMERGED"; trialMode = $true }
  gitLifecycleState = "NOT_APPLICABLE"
  reservationEvidence = [ordered]@{ backupPath = $backup; backupSha256 = $backupSha }
}
Write-DevBridgeJson (Join-Path $stateDir "current-task.json") $cur | Out-Null
# drift the roadmap node to In Progress (as S4 does)
$prev = $script:DevControlWorkbook
$script:DevControlWorkbook = $wbCopy
$node = Get-RoadmapNodeById "WI-07-0.2.4"
$rowNum = [int]$node.Row
$mrMap = @($script:DevControlMap.sheets | Where-Object { $_.name -eq "Master Roadmap" })[0]
$statusCol = Get-ColumnForSheet "Master Roadmap" ([int]$mrMap.headerRow) "Status"
$script:DevControlWorkbook = $prev
$fs = [System.IO.File]::Open($wbCopy, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
$zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Update)
try {
  $entry = (Get-SheetEntryName "Master Roadmap")
  $rd = New-Object System.IO.StreamReader($zip.GetEntry($entry).Open())
  $doc = [System.Xml.Linq.XDocument]::Load($rd); $rd.Close()
  $sd = $doc.Root.Element($xNs + "sheetData")
  Write-Cell $sd $rowNum $statusCol "In Progress"
  $e = $zip.GetEntry($entry); $s = $e.Open(); $s.SetLength(0); $s.Position = 0; $doc.Save($s); $s.Dispose()
} finally { $zip.Dispose(); $fs.Dispose() }
Write-Output "drifted row=$rowNum col=$statusCol status=In Progress"
$env:DB24_STATE_DIR = $stateDir
$env:DB24_TASKS_DIR = $tasksDir
$env:DB24_WORKBOOK_OVERRIDE = $wbCopy
$oldEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Close-TrialCycle.ps1") 2>&1)
$ErrorActionPreference = $oldEAP
$out | ForEach-Object { "$_" }
Write-Output "=== EXIT: $LASTEXITCODE ==="
