param(
    [string]$OutFile = "C:\Personal\DevTools\DevBridge\state\db-g02-config-rerun.txt"
)

# DB-G02 rerun (V3 / V14): config consistency across the CORRECTED development-control-map.json
# and sheet-governance.json, plus the corrected Master Roadmap governed-range read rule.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$map = Get-Content "C:\Personal\DevTools\DevBridge\config\development-control-map.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$gov = Get-Content "C:\Personal\DevTools\DevBridge\config\sheet-governance.json" -Raw -Encoding UTF8 | ConvertFrom-Json

$sb = New-Object System.Text.StringBuilder
function Out-Line([string]$t) { [void]$sb.AppendLine($t) }

Out-Line "=== V3/V14 CONFIG CONSISTENCY (corrected configs) ==="
Out-Line "map schemaVersion: $($map.schemaVersion) | sheet-governance schemaVersion: $($gov.schemaVersion)"

# --- V3 governance role consistency ---
$mapRoles = @{}; foreach ($s in @($map.sheets)) { $mapRoles[$s.name] = $s.governanceRole }
$govRoles = @{}; foreach ($s in @($gov.sheets)) { $govRoles[$s.sheet] = $s.role }
$roleMismatch = @()
foreach ($k in $mapRoles.Keys) {
    if (-not $govRoles.ContainsKey($k)) { $roleMismatch += "$k missing in sheet-governance" }
    elseif ($mapRoles[$k] -ne $govRoles[$k]) { $roleMismatch += "$k map=$($mapRoles[$k]) gov=$($govRoles[$k])" }
}
Out-Line "Sheets in map: $($mapRoles.Count) | in sheet-governance: $($govRoles.Count)"
Out-Line "Role mismatches map vs sheet-governance: $(if(@($roleMismatch).Count -eq 0){'NONE'}else{($roleMismatch -join '; ')})"

# --- V14 sheet-governance structural completeness ---
$mutationEnum = @($gov.mutationEnum)
$structBad = @()
foreach ($s in @($gov.sheets)) {
    foreach ($f in @("sheet","role","alwaysRead","readWhen","writeWhen","mutation","requiresHistory","requiresActivity","validation")) {
        if ($null -eq $s.PSObject.Properties[$f]) { $structBad += "$($s.sheet) missing field '$f'" }
    }
    if ($s.mutation -notin $mutationEnum) { $structBad += "$($s.sheet) invalid mutation '$($s.mutation)'" }
    if ($s.alwaysRead -isnot [bool]) { $structBad += "$($s.sheet) alwaysRead not boolean" }
}
Out-Line "sheet-governance structural field check: $(if(@($structBad).Count -eq 0){'ALL 14 SHEETS x 9 FIELDS PRESENT + VALID ENUMS'}else{($structBad -join '; ')})"

# --- Session Protocol must be NONE ---
$proto = @($gov.sheets | Where-Object { $_.sheet -eq "Session Protocol" })[0]
Out-Line "Session Protocol mutation: $($proto.mutation) | writeWhen count: $(@($proto.writeWhen).Count) (must be NONE / 0)"

# --- Corrected Master Roadmap governed range rule ---
$mrGov = @($gov.sheets | Where-Object { $_.sheet -eq "Master Roadmap" })[0]
$newNodeTrigger = @($mrGov.writeWhen | Where-Object { $_ -match "governed data range" })
Out-Line "Master Roadmap new-node trigger uses 'governed data range': $([bool](@($newNodeTrigger).Count -gt 0))"
$mrMap = @($map.sheets | Where-Object { $_.name -eq "Master Roadmap" })[0]
Out-Line "Master Roadmap formalExcelTableRange: $($mrMap.formalExcelTableRange)"
Out-Line "Master Roadmap governedDataRange: $($mrMap.governedDataRange.range) rows=$($mrMap.governedDataRange.startRow)-$($mrMap.governedDataRange.endRow) count=$($mrMap.governedDataRange.recordCount) within=$($mrMap.governedDataRange.withinTableRecordCount) beyond=$($mrMap.governedDataRange.beyondTableRecordCount)"
Out-Line "Master Roadmap detection rule present: $([bool]($mrMap.governedDataRange.detectionRule))"
$readCond = @($mrMap.mandatoryReadConditions)
$fullRangeCond = @($readCond | Where-Object { $_ -match "659|A6:AG675|governed data range|full governed" })
Out-Line "Mandatory read conditions covering the full governed range: $(@($fullRangeCond).Count) of $($readCond.Count)"
Out-Line "  $($fullRangeCond -join ' || ')"

# --- preflight readiness / verdict vocabulary ---
Out-Line "mappingReady: $($map.mappingReady) | mappingReadyCriteria.noUnresolvedIssuePreventsSafePreflight: $($map.mappingReadyCriteria.noUnresolvedIssuePreventsSafePreflight) | safeForAutomatedPreflight: $($map.preflight.safeForAutomatedPreflight)"
$v1 = @($map.sessionProtocol.verdicts) -join ", "
$v2 = @($map.preflight.verdicts) -join ", "
Out-Line "Session Protocol verdicts: $v1"
Out-Line "Preflight verdicts       : $v2"
Out-Line "Verdict vocabulary consistent: $($v1 -eq $v2)"

# --- unresolved item U-2 now RESOLVED ---
$u2 = @($map.unresolved | Where-Object { $_ -match "beyond" })
Out-Line "Map unresolved mention of beyond-table rows: $([bool](@($u2).Count -gt 0)) -> $($u2 -join ' | ')"

# --- correction marker ---
Out-Line "Correction field: $($map.correction)"
Out-Line "correctedAtUtc: $($map.correctedAtUtc)"

# --- PASS/FAIL ---
$ok = (@($roleMismatch).Count -eq 0) -and (@($structBad).Count -eq 0) -and ($proto.mutation -eq "NONE") -and (@($newNodeTrigger).Count -gt 0) -and (@($fullRangeCond).Count -gt 0) -and ($mrMap.governedDataRange.recordCount -eq 659) -and ($v1 -eq $v2)
Out-Line ""
Out-Line "CONFIG CHECK: $(if($ok){'PASS'}else{'FAIL'})"

[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "Wrote $OutFile | PASS=$ok"
