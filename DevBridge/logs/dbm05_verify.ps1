# dbm05_verify.ps1 - Independent post-run verification of DB-M05 (task #11).
# Re-derives every DB-M05 invariant from the authoritative workbook, the Nexus git
# repository, DevBridge state and the generated artifacts WITHOUT re-running the
# engine. Exits 0 on PASS, 1 on any failure (backend convention: read stdout markers).
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$root = 'C:\Personal\DevTools\DevBridge'
Set-Location $root
. .\scripts\Read-DevelopmentControl.ps1
$repo = 'C:\Personal\Nexus.Developer'

$fail = New-Object System.Collections.Generic.List[string]
function Check-True([string]$label, [bool]$cond, [string]$detail) {
    if ($cond) { Write-Output ("  [PASS] " + $label) }
    else { $fail.Add($label + ": " + $detail); Write-Output ("  [FAIL] " + $label + " - " + $detail) }
}

$nodeId = 'WI-07-0.2.4'
$changeId = 'CHG-20260830-017'
$expectedHash = '93D2620D919789D9C7199C417FF3A9FD5B09DA0464F0D3800DB0748E62772372'

Write-Output "=== DB-M05 INDEPENDENT VERIFICATION (WI-07-0.2.4 / CHG-20260830-017) ==="

# ---- 1. Workbook integrity ----
$hash = Get-WorkbookSha256
Check-True "workbook hash unchanged since DB-M04" ($hash -eq $expectedHash) ("live=" + $hash)

# ---- 2. Active Changes reservation still valid ----
$ac = @(Get-AllActiveChanges | Where-Object { $_.ChangeId -eq $changeId })
Check-True "CHG-20260830-017 is the single active reservation" ($ac.Count -eq 1 -and $ac[0].Classification -ne "Terminal") ("count=" + $ac.Count)
$row80 = if ($ac.Count -eq 1) { $ac[0] } else { $null }
if ($row80) {
    Check-True "reservation row 80 / node WI-07-0.2.4" ($row80.Row -eq 80 -and ([string]$row80.NodeId).Contains($nodeId)) ("row=" + $row80.Row + " node=" + $row80.NodeId)
    Check-True "reserved scope intact" (([string]$row80.Projects -match 'Nexus.Developer.Core') -and ([string]$row80.FilesGlobs -match 'DevelopmentControl')) ("proj=" + $row80.Projects + " glob=" + $row80.FilesGlobs)
}

# ---- 3. Nexus git state matches DB-M04 baseline ----
$head = (& git -C $repo rev-parse HEAD 2>$null)
$branch = (& git -C $repo branch --show-current 2>$null)
Check-True "git HEAD unchanged (ea39db91...)" ($head -eq 'ea39db910a6e3b00bff880316996a696ae7460dc') ("head=" + $head)
Check-True "git branch unchanged" ($branch -eq 'feature/m-08-1-2-ci-pipeline') ("branch=" + $branch)
$gitLines = @(& git -C $repo status --porcelain=v1 2>$null | ForEach-Object { "$_" })
$unexpectedGit = New-Object System.Collections.Generic.List[string]
$knownPre = @('src/Nexus.Developer.Infrastructure/DevelopmentControl/DevelopmentControlCellCodec.cs',
              'src/Nexus.Developer.Infrastructure/DevelopmentControl/ExcelDevelopmentControlStore.cs',
              'src/Nexus.Developer.Infrastructure/DevelopmentControl/ExcelWorkbookColumnMap.cs')
foreach ($g in $gitLines) {
    if ($g -match 'NEXUS_DEVELOPMENT_CONTROL\.xlsx') { continue }
    $pathPart = (($g -replace '^..\s+', '').Trim())
    $known = $false
    foreach ($kp in $knownPre) { if ($pathPart -ieq $kp) { $known = $true; break } }
    if (-not $known) { $unexpectedGit.Add($g) }
}
Check-True "no Nexus source change beyond DB-M04 baseline" ($unexpectedGit.Count -eq 0) ("unexpected: " + ($unexpectedGit -join "; "))

# ---- 4. State file ----
$ct = Get-Content (Join-Path $root 'state\current-task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Check-True "state=AWAITING_CHATGPT_PROMPT / COPY_TO_CHATGPT" ($ct.status -eq 'AWAITING_CHATGPT_PROMPT' -and $ct.nextAllowedAction -eq 'COPY_TO_CHATGPT') ("status=" + $ct.status + " next=" + $ct.nextAllowedAction)
Check-True "state carries correct identity" ($ct.changeId -eq $changeId -and $ct.nodeId -eq $nodeId) ("change=" + $ct.changeId + " node=" + $ct.nodeId)
Check-True "reservation evidence preserved" ($ct.workbookSha256 -eq $expectedHash -and $ct.preflightWorkbookSha256 -eq '24C8D3AF2210C0F1F61B10FB96019A8AC7C8D8BBC67263F1498C4A11B075297C' -and $ct.reservedAt) ("wb=" + $ct.workbookSha256)
Check-True "handoff fields recorded" ([string]::IsNullOrEmpty([string]$ct.chatgptHandoffGeneratedAt) -eq $false -and [string]::IsNullOrEmpty([string]$ct.chatgptHandoffPath) -eq $false) ("path=" + $ct.chatgptHandoffPath)

# ---- 5. CHATGPT_HANDOFF.md content ----
$handoffPath = Join-Path $root 'tasks\CHATGPT_HANDOFF.md'
$md = [System.IO.File]::ReadAllText($handoffPath)
Check-True "handoff exists & non-empty" ((Test-Path $handoffPath) -and $md.Length -gt 2000) ("len=" + $md.Length)
$need = @('Node ID: WI-07-0.2.4','Change ID: CHG-20260830-017','Acceptance Criteria','Exact Reserved Scope','ADR-003','Scope Transition','Open Decisions','Audit Findings','ALREADY_EXISTS','Parallel Development Context','SCOPE_CHANGE_REQUIRED','IMPLEMENTATION RESULT','Named cross-process mutex','RowVersion optimistic check','temp-write/validate/replace','one proven concurrency test','IDevelopmentControlStore','ExcelDevelopmentControlStore')
foreach ($n in $need) { Check-True ("handoff contains: " + $n) ($md -match [regex]::Escape($n)) "missing" }
$stale = @('do not build them here','This work item''s deliverable','CHG-20260830-016 (this reservation)','WI-07-0.2.3 (this reservation)','Excel persistence adapter | MISSING')
foreach ($s in $stale) { Check-True ("handoff does NOT contain stale text: " + $s) (-not ($md -match [regex]::Escape($s))) "stale text present" }
# scope-transition correctness: 0.2.3 under Infrastructure, 0.2.4 under Core, no reinterpretation
Check-True "scope transition: 0.2.3 Infrastructure / 0.2.4 Core" (($md -match 'Nexus.Developer.Infrastructure') -and ($md -match 'src/Nexus.Developer.Core/DevelopmentControl')) "transition section"
Check-True "quoted SCOPE_CHANGE_REQUIRED instruction" ($md -match 'must STOP and report SCOPE_CHANGE_REQUIRED') "PART 6 quote"

# ---- 6. DEEPSEEK_PROMPT.md placeholder-only ----
$promptPath = Join-Path $root 'tasks\DEEPSEEK_PROMPT.md'
$prompt = [System.IO.File]::ReadAllText($promptPath)
Check-True "prompt placeholder present" ($prompt -match 'Awaiting ChatGPT Prompt' -and $prompt -match 'Task: WI-07-0.2.4' -and $prompt -match 'Change: CHG-20260830-017') "placeholder header"
$implWords = @('RowVersion','mutex','ExcelDevelopmentControlStore','SCOPE_CHANGE_REQUIRED','acceptance criteria','clone')
foreach ($w in $implWords) { Check-True ("prompt has NO implementation content: " + $w) (-not ($prompt -match [regex]::Escape($w))) "implementation text present" }

# ---- 7. History copy identical ----
$histPath = Join-Path $root ('logs\tasks\' + $nodeId + '\' + $changeId + '\CHATGPT_HANDOFF.md')
Check-True "history copy preserved (PART 23)" (Test-Path $histPath) ("missing: " + $histPath)
if (Test-Path $histPath) {
    $h = [System.IO.File]::ReadAllText($histPath)
    Check-True "history copy matches tasks handoff" ($h -eq $md) "content differs"
}

# ---- 8. Lane touch guard (window anchored to this run's governed outputs) ----
# DB-M05 wrote exactly 4 governed outputs. Lane B (DB-M13) is confirmed RUNNING and
# writing under scripts\ai-routing\, design\ai-routing\, config\cost\, config\currency\
# and its own logs\tasks\* dirs - those are observations, not DB-M05 writes.
$anchor = (Get-Item $promptPath).LastWriteTimeUtc.AddSeconds(-10)
$touched = @(Get-ChildItem $root -Recurse -File | Where-Object { $_.LastWriteTimeUtc -ge $anchor })
$governed = @($handoffPath, $promptPath, (Join-Path $root 'state\current-task.json'), $histPath)
$laneZone = 'scripts\\ai-routing\\|design\\ai-routing\\|config\\cost\\|config\\currency\\|logs\\tasks\\|scripts\\New-ChatGptHandoff\.ps1|scripts\\Read-DevelopmentControl\.ps1|logs\\dbm0'
$unexpected = @($touched | Where-Object {
    $f = $_.FullName
    $isOwn = $false
    foreach ($g in $governed) { if ([string]::Equals($f, $g, [System.StringComparison]::OrdinalIgnoreCase)) { $isOwn = $true; break } }
    (-not $isOwn) -and ($f -notmatch $laneZone)
})
Check-True "no DevBridge file outside governed outputs / lane zones touched" ($unexpected.Count -eq 0) $(if ($unexpected.Count -gt 0) { ($unexpected.FullName -join "; ") } else { "(none)" })

# ---- 9. Nexus source files untouched (mtime older than run) ----
$srcFresh = @(Get-ChildItem (Join-Path $repo 'src') -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -ge $anchor -and $_.FullName -notmatch '\\bin\\|\\obj\\' })
$wbFresh = @(Get-Item (Join-Path $repo 'NEXUS_DEVELOPMENT_CONTROL.xlsx') | Where-Object { $_.LastWriteTimeUtc -ge $anchor })
Check-True "no Nexus source file written by this run" ($srcFresh.Count -eq 0) $(if ($srcFresh.Count -gt 0) { ($srcFresh.FullName -join "; ") } else { "(none)" })
Check-True "workbook file not rewritten by this run" ($wbFresh.Count -eq 0) "workbook mtime in window"

# ---- Summary ----
Write-Output ""
Write-Output ("DBM05_VERIFY_RESULT_PASS: " + $(if ($fail.Count -eq 0) { "True" } else { "False" }))
Write-Output ("DBM05_VERIFY_CHECKS: " + "independent checks executed")
if ($fail.Count -gt 0) {
    Write-Output "FAILURES:"
    foreach ($f in $fail) { Write-Output ("  - " + $f) }
    exit 1
}
Write-Output "DBM05_VERIFY_OUTCOME: PASS"
exit 0
