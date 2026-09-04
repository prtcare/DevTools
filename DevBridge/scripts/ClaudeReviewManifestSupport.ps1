# ClaudeReviewManifestSupport.ps1 - DB-M07 shared dot-sourceable library for the
# CLAUDE REVIEW MANIFEST (Request: Claude is the independent read-only reviewer of
# the ACTUAL Nexus files).
#
# Exposes:
#   Get-CrmSectionMap  <string[]>lines  -> ordered map section-header -> content
#       (parses the governed brief's "===="-delimited sections: GOAL,
#       AUTHORITATIVE ACCEPTANCE CRITERIA, ARCHITECTURE RULES, etc.)
#   Get-CrmManifestId  <nodeId> <changeId> <verifiedAtUtc>
#       -> the deterministic manifest id stamped into every manifest. The id binds
#          the manifest to ONE DB-M06 verification evidence (its verifiedAt), so a
#          re-verified cycle produces a NEW id and the old manifest can never be
#          mistaken for the current one.
#   Test-CrmManifestCurrent  -StateDir <dir> -TasksDir <dir>
#       -> PSCustomObject { Ready, Reason, NodeId, ChangeId, VerifiedAtUtc,
#                           ManifestId, ManifestPath }. The single click-time /
#       record-time gate: reads tasks\CLAUDE_REVIEW_PACKAGE.md FRESH and verifies
#       that it is the CURRENT manifest (identity lines == current task,
#       Manifest ID == deterministic id, current-task dbM07 ready stamp matches,
#       DB-M06 verification PASS belongs to the same node/change). Anything stale
#       or historical is NOT current.
#
# ASCII-only source (PS 5.1 + BOM-safe). No state writes here - read-only helpers.
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Set-DevBridgeStateEntry.ps1")

function Get-CrmManifestId([string]$nodeId, [string]$changeId, [string]$verifiedAtUtc) {
    $v = ([string]$verifiedAtUtc).Trim()
    if (-not $v) { $v = "NO_M06_VERIFIED_AT" }
    return ("DB07-MANIFEST|" + $changeId + "|" + $nodeId + "|" + $v)
}

# Parse a "====" / header / "====" / content ... governed brief into an ordered
# map of section header -> List[string] of content lines (header lines excluded).
# A section starts at an all-'=' run, then an optional heading line, then another
# all-'=' run; content runs until the next all-'=' run. Non-sectioned leading lines
# (before the first header) are ignored.
function Get-CrmSectionMap([string[]]$lines) {
    $map = @{}
    $order = New-Object System.Collections.Generic.List[string]
    if ($null -eq $lines) { return $map }
    $i = 0
    $count = $lines.Count
    while ($i -lt $count) {
        $L = [string]$lines[$i]
        if ($L -and $L -match '^=+$') {
            # look ahead: optional blanks, a heading line, then a closing '=' run
            $j = $i + 1
            while ($j -lt $count -and [string]::IsNullOrWhiteSpace($lines[$j])) { $j++ }
            if ($j -lt $count -and $lines[$j] -notmatch '^=+$') {
                $heading = ([string]$lines[$j]).Trim()
                $k = $j + 1
                while ($k -lt $count -and [string]::IsNullOrWhiteSpace($lines[$k])) { $k++ }
                if ($k -lt $count -and $lines[$k] -match '^=+$') {
                    # real heading block; content begins after the closing separator
                    if (-not $map.ContainsKey($heading)) {
                        $map[$heading] = New-Object System.Collections.Generic.List[string]
                        $order.Add($heading)
                    }
                    $buf = $map[$heading]
                    $m = $k + 1
                    while ($m -lt $count -and $lines[$m] -notmatch '^=+\s*$') {
                        $buf.Add(([string]$lines[$m]).TrimEnd())
                        $m++
                    }
                    $i = $m
                    continue
                }
            }
        }
        $i++
    }
    return $map
}

function Get-CrmSectionText([System.Collections.IDictionary]$map, [string]$heading) {
    if ($map -and $map.Contains($heading)) {
        $list = $map[$heading]
        if ($list -and $list.Count -gt 0) { return (($list) -join "`n").Trim() }
    }
    return ""
}

# The single current-manifest gate (click time / record time). Read-only.
function Test-CrmManifestCurrent {
    param([string]$StateDir, [string]$TasksDir)
    $out = New-Object PSCustomObject
    $out | Add-Member -NotePropertyName Ready -NotePropertyValue $false -Force
    $out | Add-Member -NotePropertyName Reason -NotePropertyValue "" -Force
    $out | Add-Member -NotePropertyName NodeId -NotePropertyValue "" -Force
    $out | Add-Member -NotePropertyName ChangeId -NotePropertyValue "" -Force
    $out | Add-Member -NotePropertyName VerifiedAtUtc -NotePropertyValue "" -Force
    $out | Add-Member -NotePropertyName ManifestId -NotePropertyValue "" -Force
    $out | Add-Member -NotePropertyName ManifestPath -NotePropertyValue (Join-Path $TasksDir "CLAUDE_REVIEW_PACKAGE.md") -Force

    $ctPath = Join-Path $StateDir "current-task.json"
    $ct = Read-DevBridgeJson $ctPath
    if ($null -eq $ct) { $out.Reason = "no current task"; return $out }
    $nodeId = [string](Get-DevBridgeField $ct "nodeId")
    if (-not $nodeId) { $nodeId = [string](Get-DevBridgeField $ct "taskId") }
    $changeId = [string](Get-DevBridgeField $ct "changeId")
    if (-not $nodeId -or -not $changeId) { $out.Reason = "current task identity incomplete"; return $out }

    # current-task dbM07 ready stamp must exist and belong to THIS task
    $db7 = Get-DevBridgeField $ct "dbM07"
    $ready = $false
    if ($null -ne $db7) {
        $r = [string](Get-DevBridgeField $db7 "ready")
        $ready = ($r -eq "True" -or $r -eq "true")
        $sn = [string](Get-DevBridgeField $db7 "nodeId")
        $sc = [string](Get-DevBridgeField $db7 "changeId")
        if ($ready -and ($sn -ne $nodeId -or $sc -ne $changeId)) { $out.Reason = "dbM07 stamp identity mismatch"; return $out }
    }
    if (-not $ready) { $out.Reason = "no ready dbM07 manifest stamp for the current task"; return $out }

    # DB-M06 verification evidence must PASS for the SAME node/change
    $verif = Read-DevBridgeJson (Join-Path $StateDir "verification.json")
    $verifiedAt = ""
    if ($null -ne $verif) {
        $vn = [string](Get-DevBridgeField $verif "nodeId")
        $vc = [string](Get-DevBridgeField $verif "changeId")
        $vr = [string](Get-DevBridgeField $verif "primaryResult")
        if (($vn -ne $nodeId -or $vc -ne $changeId)) { $out.Reason = "DB-M06 evidence belongs to a different node/change"; return $out }
        if ($vr -notlike "VERIFICATION_PASSED*") { $out.Reason = "DB-M06 is not a PASS"; return $out }
        $verifiedAt = [string](Get-DevBridgeField $verif "verifiedAtUtc")
    }
    if (-not $verifiedAt) { $out.Reason = "no DB-M06 verifiedAt evidence"; return $out }

    # deterministic manifest id binds the manifest to this exact M06 evidence
    $id = Get-CrmManifestId $nodeId $changeId $verifiedAt
    $mdPath = Join-Path $TasksDir "CLAUDE_REVIEW_PACKAGE.md"
    if (-not (Test-Path -LiteralPath $mdPath)) { $out.Reason = "manifest file missing"; return $out }
    $text = [System.IO.File]::ReadAllText($mdPath)
    if (-not $text.Contains("# Claude Review Manifest")) { $out.Reason = "not a Claude review manifest"; return $out }
    if (-not ($text.Contains(("Node: " + $nodeId)) -and $text.Contains(("Change: " + $changeId)))) {
        $out.Reason = "manifest identity mismatch (stale/historical manifest)"; return $out
    }
    if (-not $text.Contains(("Manifest ID: " + $id))) {
        $out.Reason = "manifest id mismatch (not bound to the current DB-M06 evidence)"; return $out
    }

    $out.Ready = $true
    $out.Reason = ""
    $out.NodeId = $nodeId
    $out.ChangeId = $changeId
    $out.VerifiedAtUtc = $verifiedAt
    $out.ManifestId = $id
    return $out
}
