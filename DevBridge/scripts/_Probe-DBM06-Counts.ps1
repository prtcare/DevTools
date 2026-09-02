$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Read-DevelopmentControl.ps1"
# Independent count: replicate the store's control-state counts directly from the sheets.
$all = @(Get-AllRoadmapNodes)
# live nodes = nodes whose status is not a terminal status (Superseded/Cancelled/Obsolete) -> IsDeleted=false
$terminal = @("Superseded","Cancelled","Obsolete")
$live = @($all | Where-Object { ($_.Status -notin $terminal) -and ($_.NodeId -ne "") })
$milestones = @($live | Where-Object { $_.NodeType -eq "Milestone" })
$workitems  = @($live | Where-Object { $_.NodeType -eq "WorkItem" })
$blocked    = @($live | Where-Object { $_.Status -eq "Blocked" })
$openChanges = @(Get-ActiveChangesOpen)
# open audit findings: status not Resolved/Closed/Cancelled
$findings = @(Get-AllAuditFindings)
$openFindings = @($findings | Where-Object { $_.Status -notmatch "^(Resolved|Closed|Cancelled)" })
Write-Output "INDEPENDENT CONTROL-STATE COUNTS (from workbook, read-only):"
Write-Output ("  live nodes:   {0}" -f $live.Count)
Write-Output ("  milestones:   {0}" -f $milestones.Count)
Write-Output ("  workitems:    {0}" -f $workitems.Count)
Write-Output ("  blocked:      {0}" -f $blocked.Count)
Write-Output ("  activeChange: {0}" -f $openChanges.Count)
Write-Output ("  openAudit:    {0}" -f $openFindings.Count)
Write-Output ""
Write-Output "STORE-REPORTED (harness): 636 / 166 / 138 / 0 / 19 / 18"
