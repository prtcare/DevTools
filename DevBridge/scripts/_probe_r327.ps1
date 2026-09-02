$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Read-DevelopmentControl.ps1"
$node = Get-RoadmapNodeById "WI-07-0.2.3"
Write-Output ("row={0}" -f $node.Row)
Write-Output ("OutcomePurpose='{0}'" -f $node.OutcomePurpose)
Write-Output ("SimpleGoal='{0}'" -f $node.SimpleGoal)
Write-Output ("CurrentEvidence='{0}'" -f $node.CurrentEvidence)
Write-Output ("AcceptanceCriteria='{0}'" -f $node.AcceptanceCriteria)
Write-Output ("Notes='{0}'" -f $node.Notes)
Write-Output ("Source='{0}'" -f $node.Source)
$cols = $node.Columns
Write-Output ("Columns resolved: SimpleGoal->{0}, OutcomePurpose->{1}" -f $cols["SimpleGoal"], $cols["OutcomePurpose"])
