# DB-M04 post-run independent verification (task #8)
$ErrorActionPreference = 'Stop'
Set-Location 'C:\Personal\DevTools\DevBridge'
. .\scripts\Read-DevelopmentControl.ps1

$root = 'C:\Personal\DevTools\DevBridge'
$repo = 'C:\Personal\Nexus.Developer'

Write-Output "=== 1. WORKBOOK HASH ==="
Write-Output ('live=' + (Get-FileHash (Join-Path $repo 'NEXUS_DEVELOPMENT_CONTROL.xlsx') -Algorithm SHA256).Hash)
Write-Output ('expect post-write 93D2620D919789D9C7199C417FF3A9FD5B09DA0464F0D3800DB0748E62772372')

Write-Output ""
Write-Output "=== 2. ACTIVITY LOG ROW ACT-20260830-018 ==="
$map = Get-Content (Join-Path $root 'config\development-control-map.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$al = $map.sheets | Where-Object { $_.name -eq 'Activity Log' } | Select-Object -First 1
if (-not $al) { throw 'Activity Log sheet not found in map' }
$rows = Get-SheetRows 'Activity Log' ([int]$al.headerRow) ([int]$al.dataStartRow) 60
Write-Output ('sheet rows read: ' + $rows.Count)
$actRow = @($rows | Where-Object { (Get-Value 'Activity Log' $_ ([int]$al.headerRow) 'Activity ID') -eq 'ACT-20260830-018' })
Write-Output ('ACT-20260830-018 rows found: ' + $actRow.Count)
if ($actRow.Count -eq 1) {
    $names = @('Activity ID','Timestamp UTC','Operation','Entity Type','Entity ID','Parent ID','Reason','Repository','Project','Branch','Files/Globs','Preflight Verdict','Result','Evidence','Error Code','Human Review Status')
    foreach ($n in $names) {
        $v = Get-Value 'Activity Log' $actRow[0] ([int]$al.headerRow) $n
        Write-Output ('  {0} = {1}' -f $n, $v)
    }
}

Write-Output ""
Write-Output "=== 3. STATE FILES ==="
$ct = Get-Content (Join-Path $root 'state\current-task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Output ('current-task: taskId={0} status={1} changeId={2} reservedAt={3}' -f $ct.taskId, $ct.status, $ct.changeId, $ct.reservedAt)
Write-Output ('  nextAllowedAction={0}' -f $ct.nextAllowedAction)
Write-Output ('  preExistingChanges.modified={0} untracked={1}' -f $ct.preExistingChanges.modified, $ct.preExistingChanges.untracked)
$laneC = $ct.parallelDevelopmentContext.lanes | Where-Object { $_.lane -eq 'C' }
Write-Output ('  laneC: {0} - {1}' -f $laneC.id, $laneC.status)
Write-Output ('  parallelLaneCheck={0}' -f $ct.parallelDevelopmentContext.parallelLaneCheck)
Write-Output ('  repositoryStates HEAD={0} branch={1} dirty={2}' -f $ct.repositoryStates.headCommit, $ct.repositoryStates.branch, $ct.repositoryStates.dirty)
Write-Output ('  scopeFileHashes count={0}' -f @($ct.repositoryStates.scopeFileHashes).Count)

$rv = Get-Content (Join-Path $root 'logs\tasks\WI-07-0.2.4\CHG-20260830-017\reservation.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Output ('reservation.json: changeId={0} nodeId={1} activeChangeRow={2} activeChangeStatus={3}' -f $rv.changeId, $rv.nodeId, $rv.activeChange.row, $rv.activeChange.status)
Write-Output ('  project={0} filesGlobs={1} contract={2} repo={3}' -f ($rv.reservedScope.projects -join ','), ($rv.reservedScope.filesGlobs -join ','), ($rv.reservedScope.contractsApis -join ','), ($rv.reservedScope.repositories -join ','))
Write-Output ('  nexusSourceModified={0} parallelLaneCheck={1} nextAllowedAction={2}' -f $rv.nexusSourceModified, $rv.parallelLaneCheck.status, $rv.nextAllowedAction)
Write-Output ('  gitBaseline HEAD={0} branch={1} preReservationClean={2}' -f $rv.gitBaseline.headCommit, $rv.gitBaseline.branch, $rv.gitBaseline.preReservationClean)
Write-Output ('  workbook before={0} after={1}' -f $rv.workbook.sha256Before, $rv.workbook.sha256After)

Write-Output ""
Write-Output "=== 4. START_BASELINE.md ==="
$sb = Get-Content (Join-Path $root 'logs\tasks\WI-07-0.2.4\CHG-20260830-017\START_BASELINE.md') -Raw -Encoding UTF8
$hasParallel = $sb -match '## Parallel Development Context'
$hasLaneC = $sb -match 'LANE C'
$hasCollision = $sb -match 'Parallel Collision Check:\*{0,2}\s*PASS'
Write-Output ('Parallel Development Context section: {0}' -f $(if ($hasParallel) { 'PRESENT' } else { 'MISSING' }))
Write-Output ('LANE C line: {0}' -f $(if ($hasLaneC) { 'PRESENT' } else { 'MISSING' }))
Write-Output ('Collision check PASS: {0}' -f $(if ($hasCollision) { 'PRESENT' } else { 'MISSING' }))
Write-Output '  --- baseline file listing ---'
Get-ChildItem (Join-Path $root 'logs\tasks\WI-07-0.2.4\CHG-20260830-017') -Recurse -File | ForEach-Object { Write-Output ('  ' + $_.FullName.Substring($root.Length + 1)) }
$archived = Join-Path $root 'logs\tasks\WI-07-0.2.4\CHG-20260830-017\START_BASELINE.md'
Write-Output ('archived START_BASELINE.md: {0}' -f $(if (Test-Path $archived) { 'PRESENT' } else { 'MISSING' }))

Write-Output ""
Write-Output "=== 5. BACKUP ==="
$bk = Get-ChildItem (Join-Path $root 'logs\workbook-backups') -File -Filter 'NEXUS_DEVELOPMENT_CONTROL_20260830_225830.xlsx' -ErrorAction SilentlyContinue
if ($bk) { Write-Output ('backup exists: {0} ({1} bytes)' -f $bk.Name, $bk.Length) } else { Write-Output 'BACKUP MISSING' }

Write-Output ""
Write-Output "=== 6. NEXUS GIT STATE ==="
& git -C $repo status --porcelain=v1
Write-Output "---"
Write-Output ('HEAD=' + (& git -C $repo rev-parse HEAD))
Write-Output ('branch=' + (& git -C $repo branch --show-current))

Write-Output ""
Write-Output "=== 7. PARALLEL LANE FILE TOUCH GUARD ==="
# LANE A = DevBridge UI/application layer; LANE B = DevBridge design/discovery.
# Confirm DB-M04 wrote nothing outside the governed workbook + its own state/tasks/logs.
$devBridgeNonGoverned = @(Get-ChildItem $root -Recurse -File | Where-Object {
    $_.FullName -notmatch 'logs\\(workbook-backups|tasks|selftest|dbm04_)' -and
    $_.LastWriteTimeUtc -ge [datetime]'2026-08-30T17:27:00Z' -and
    $_.FullName -notmatch 'state\\(preflight.json|current-task.json)' })
Write-Output ('DevBridge files written by this run (expected: none beyond engine/scripts edit + state + logs): ' + $devBridgeNonGoverned.Count)
$devBridgeNonGoverned | ForEach-Object { Write-Output ('  ' + $_.FullName.Substring($root.Length + 1) + ' @ ' + $_.LastWriteTimeUtc.ToString('o')) }

Write-Output ""
Write-Output "VERIFY DONE"
