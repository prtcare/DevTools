# DB-M04 PART 2 probe (post-fix) - verify token matching fixes the false positive
$ErrorActionPreference = 'Stop'
$script:Root = 'C:\Personal\DevTools\DevBridge'
Set-Location $script:Root
. .\scripts\Read-DevelopmentControl.ps1

function Test-ProjectTokenOverlap([string]$cell, [string]$projectName) {
    if (-not $cell -or -not $projectName) { return $false }
    foreach ($tok in ($cell -split "[\s|,;]+")) {
        $clean = $tok.Trim() -replace "\s*\([^)]*\)\s*$", ""
        if ($clean -ieq $projectName) { return $true }
    }
    return $false
}

Write-Output "=== UNIT CHECKS ==="
$cases = @(
    @{ cell = "Nexus.Developer.Core | Nexus.Developer.Infrastructure"; p = "Nexus.Developer.Core"; expect = $true  },
    @{ cell = "tests/Nexus.Developer.Core.Tests/FeatureTests.cs (new)"; p = "Nexus.Developer.Core"; expect = $false },
    @{ cell = "src/Nexus.Developer.Core/DevelopmentControl/** (new)";     p = "Nexus.Developer.Core"; expect = $false },
    @{ cell = "Nexus.Developer.Core";                                     p = "Nexus.Developer.Core"; expect = $true  },
    @{ cell = "Nexus.Developer.Core.Tests";                               p = "Nexus.Developer.Core"; expect = $false },
    @{ cell = "Nexus.Developer.Core (new)";                               p = "Nexus.Developer.Core"; expect = $true  }
)
foreach ($c in $cases) {
    $got = Test-ProjectTokenOverlap $c.cell $c.p
    $pass = if ($got -eq $c.expect) { "PASS" } else { "FAIL" }
    Write-Output ("{0}: cell='{1}' p='{2}' got={3} expect={4}" -f $pass, $c.cell, $c.p, $got, $c.expect)
}

Write-Output ""
Write-Output "=== LIVE SCAN (PART 2 replica for WI-07-0.2.4) ==="
$scope = @{
    nodeId = 'WI-07-0.2.4'
    projects = @('Nexus.Developer.Core')
    filesGlobs = @('src/Nexus.Developer.Core/DevelopmentControl/**')
    contractsApis = @('IDevelopmentControlStore')
    affectedNodes = @('F-07-0','M-07-0.2','WI-07-0.2.1','WI-07-0.2.10','WI-07-0.2.2','WI-07-0.2.3','WI-07-0.2.4','WI-07-0.2.5','WI-07-0.2.6','WI-07-0.2.7','WI-07-0.2.8','WI-07-0.2.9')
}
$chainIds = $scope.affectedNodes
$openRes = @(Get-ActiveChangesOpen)
$conflicts = New-Object System.Collections.Generic.List[string]
foreach ($r in $openRes) {
    $named = @(($r.NodeId -split "\|") | ForEach-Object { $_.Trim() })
    $touchesChain = @($named | Where-Object { $chainIds -contains $_ }).Count -gt 0
    if (@($named | Where-Object { $_ -eq $scope.nodeId }).Count -gt 0) {
        $conflicts.Add(("node {0} reserved by {1}" -f $scope.nodeId, $r.ChangeId))
    }
    $fileMatch = ([string]$r.FilesGlobs -match "DevelopmentControl|Infrastructure")
    if ($fileMatch -and (-not $touchesChain) -and ($r.Classification -in @("InProgress", "Open"))) {
        $conflicts.Add(("file-glob overlap: {0} ({1})" -f $r.ChangeId, $r.NodeId))
    }
    foreach ($p in $scope.projects) {
        if ($r.Projects -and (Test-ProjectTokenOverlap ([string]$r.Projects) $p) -and (-not $touchesChain)) {
            $conflicts.Add(("project overlap: {0} ({1})" -f $r.ChangeId, $r.NodeId))
            break
        }
    }
    foreach ($c in $scope.contractsApis) {
        if ($r.ContractsApis -and ([string]$r.ContractsApis -match [regex]::Escape($c)) -and (-not $touchesChain)) {
            $conflicts.Add(("contract overlap: {0} ({1})" -f $r.ChangeId, $r.NodeId))
            break
        }
    }
    $affNamed = @(($r.AffectedNodes -split "\|") | ForEach-Object { $_.Trim() })
    foreach ($a in $scope.affectedNodes) {
        if (@($affNamed | Where-Object { $_ -eq $a }).Count -gt 0 -and (-not $touchesChain)) {
            $conflicts.Add(("affected-node overlap: {0} ({1})" -f $r.ChangeId, $r.NodeId))
            break
        }
    }
}
Write-Output ("OPEN reservations scanned: {0}" -f $openRes.Count)
if ($conflicts.Count -eq 0) {
    Write-Output "CONFLICT SCAN: NO HARD CONFLICTS - PART 2 PASS"
} else {
    Write-Output "CONFLICTS FOUND:"
    $conflicts | ForEach-Object { Write-Output ("  " + $_) }
}
Write-Output "PROBE DONE"
exit 0
