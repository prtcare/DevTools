# _Dbg-Full.ps1 — diagnostic: dump full preflight record sections. Not a deliverable.
$ErrorActionPreference = "Stop"
$j = Get-Content "C:\Personal\DevTools\DevBridge\state\preflight.json" -Raw | ConvertFrom-Json

Write-Output "===== identity ====="
Write-Output ("taskId={0} name={1} type={2} phase={3} parent={4}" -f $j.taskId, $j.name, $j.nodeType, $j.phase, $j.parentNodeId)
Write-Output ("currentWork={0} feature={1} status={2} selectedAt={3}" -f $j.currentWorkNodeId, $j.featureNodeId, $j.status, $j.selectedAt)
Write-Output ("selectionReason: {0}" -f $j.selectionReason)

Write-Output "===== dependencies ====="
foreach ($d in $j.dependencies) { Write-Output ("  {0} [{1}] {2} :: {3}" -f $d.dependencyId, $d.state, $d.status, $d.detail) }

Write-Output "===== architectureDecisions ====="
foreach ($a in $j.architectureDecisions) { Write-Output ("  {0} [{1}] conflict={2} :: {3}" -f $a.adrId, $a.relation, $a.conflict, $a.detail) }

Write-Output "===== openDecisions ====="
foreach ($d in $j.openDecisions) { Write-Output ("  {0} blocking={1} neededBefore='{2}' :: {3}" -f $d.decisionId, $d.blocking, $d.neededBefore, $d.detail) }

Write-Output "===== auditFindings ====="
foreach ($f in $j.auditFindings) { Write-Output ("  {0} [{1}] sev={2} status={3} due={4} :: {5}" -f $f.findingId, $f.classification, $f.severity, $f.status, $f.dueGate, $f.detail) }

Write-Output "===== existingAssets ====="
foreach ($a in $j.existingAssets) { Write-Output ("  {0} [{1}] state={2} :: {3}" -f $a.asset, $a.classification, $a.state, $a.detail) }

Write-Output "===== toolIntegration ====="
Write-Output ("  newToolApprovalRequested={0}" -f $j.toolIntegration.newToolApprovalRequested)
Write-Output ("  phase1RequiredTools: {0}" -f ($j.toolIntegration.phase1RequiredTools -join "; "))
foreach ($o in $j.toolIntegration.observations) { Write-Output ("  obs: {0}" -f $o) }

Write-Output "===== repositoryGovernance ====="
Write-Output ("  complete={0} source={1}" -f $j.repositoryGovernance.complete, $j.repositoryGovernance.source)
Write-Output ("  repos: {0}" -f ($j.repositoryGovernance.repositoriesIdentified -join "; "))
Write-Output ("  limitation: {0}" -f $j.repositoryGovernance.limitation)

Write-Output "===== risk/parallel ====="
Write-Output ("  risk={0} parallelSafe={1}" -f $j.risk, $j.parallelSafe)
Write-Output "===== sourceReferences ====="
foreach ($s in $j.sourceReferences) { Write-Output ("  - {0}" -f $s) }
Write-Output ("workbookSha256: {0}" -f $j.workbookSha256)
Write-Output ("scopeEvidence count: {0}" -f $j.scopeEvidence.Count)
