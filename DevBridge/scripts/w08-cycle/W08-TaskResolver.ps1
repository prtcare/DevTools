# W08-TaskResolver.ps1
# Nexus SP1 P1-WAVE-08 governed cycle - REAL THIN TASK RESOLVER (Forge side).
#
# This is deliberately the SMALLEST real resolver, not a big engine. It answers one
# question for a coordinator: is roadmap node X eligible to be the governed task of a
# Phase-1 wave right now, given the roadmap snapshot and the open Active Changes?
#
# Author  : Nexus SP1 W08 governed worker
# Location: Forge glue worktree (this branch only); Forge main is never modified.
#
# Function
# --------
#   Resolve-W08TaskEligibility
#     -NodeId <string>                 target roadmap node id
#     -Nodes   <object[]>              roadmap nodes (Get-AllRoadmapNodes shape)
#     -ActiveChanges <object[]>        active changes (Get-AllActiveChanges shape)
#     [-PreflightVerdict <string>]     optional DB-M03 preflight verdict ('CLEAR');
#                                      any other value => PREFLIGHT_REJECTED
#     returns  [PSCustomObject] {
#         NodeId, Name, Status, Phase, Gate,
#         Eligibility, Reasons[], BlockingNodeIds[]
#     }
#     Eligibility is EXACTLY one of:
#       ELIGIBLE | DEPENDENCY_BLOCKED | REQUIRED_STATE_BLOCKED | RESERVED |
#       CONFLICTING_CHANGE | PREFLIGHT_REJECTED | GATE_BLOCKED | PHASE_BLOCKED
#
# Self-test
# ---------
#   W08-TaskResolver.ps1 -SelfTest
#   Runs the EIGHT required scenarios on synthetic in-memory nodes/ACs and prints
#   W08_RESOLVER_TEST: <scenario>=PASS/FAIL  (expect 8/8 PASS).

[CmdletBinding()]
param(
    [switch]$SelfTest
)

function Resolve-W08TaskEligibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$NodeId,
        [Parameter(Mandatory = $true)]$Nodes,
        [Parameter(Mandatory = $true)]$ActiveChanges,
        [string]$PreflightVerdict = "CLEAR"
    )

    $eligibleStatuses = @("Planned", "In Progress", "Implemented - Verify")
    $terminalStatusRegex = "^(Complete|Completed|Cancelled|Superseded)"

    $reasons = New-Object System.Collections.Generic.List[string]
    $blockers = New-Object System.Collections.Generic.List[string]

    $node = $null
    foreach ($n in @($Nodes)) { if ([string]$n.NodeId -eq $NodeId) { $node = $n; break } }
    if ($null -eq $node) {
        $reasons.Add("node '$NodeId' not found in the roadmap snapshot")
        return [PSCustomObject]@{
            NodeId = $NodeId; Name = ""; Status = ""; Phase = ""; Gate = ""
            Eligibility = "REQUIRED_STATE_BLOCKED"
            Reasons = @($reasons); BlockingNodeIds = @()
        }
    }

    # ---- 1. required (execution) state ----
    $st = ([string]$node.Status).Trim()
    if ($st -match $terminalStatusRegex) {
        $reasons.Add("node status '$st' is terminal (Complete/Completed/Cancelled/Superseded); open work required")
        return [PSCustomObject]@{
            NodeId = $NodeId; Name = $node.Name; Status = $st; Phase = $node.Phase; Gate = $node.Gate
            Eligibility = "REQUIRED_STATE_BLOCKED"
            Reasons = @($reasons); BlockingNodeIds = @()
        }
    }
    if ($eligibleStatuses -notcontains $st) {
        $reasons.Add("node status '$st' is not a recognized open/eligible status")
        return [PSCustomObject]@{
            NodeId = $NodeId; Name = $node.Name; Status = $st; Phase = $node.Phase; Gate = $node.Gate
            Eligibility = "REQUIRED_STATE_BLOCKED"
            Reasons = @($reasons); BlockingNodeIds = @()
        }
    }

    # ---- 2. preflight verdict (optional caller-provided DB-M03 signal) ----
    if ([string]$PreflightVerdict -ne "CLEAR") {
        $reasons.Add("DB-M03 preflight verdict is '$PreflightVerdict', not CLEAR")
        return [PSCustomObject]@{
            NodeId = $NodeId; Name = $node.Name; Status = $st; Phase = $node.Phase; Gate = $node.Gate
            Eligibility = "PREFLIGHT_REJECTED"
            Reasons = @($reasons); BlockingNodeIds = @()
        }
    }

    # ---- 3. gate / phase (Phase-1 wave allowance) ----
    $gate = ([string]$node.Gate).Trim()
    $phase = ([string]$node.Phase).Trim()
    if ($gate -ne "GATE_A") {
        $reasons.Add("node gate '$gate' is not GATE_A (only GATE_A nodes are Phase-1 wave targets)")
        return [PSCustomObject]@{
            NodeId = $NodeId; Name = $node.Name; Status = $st; Phase = $phase; Gate = $gate
            Eligibility = "GATE_BLOCKED"
            Reasons = @($reasons); BlockingNodeIds = @()
        }
    }
    if ($phase -notin @("P0", "P1", "P2")) {
        $reasons.Add("node phase '$phase' is not P0/P1/P2 (Phase-1 wave allowance)")
        return [PSCustomObject]@{
            NodeId = $NodeId; Name = $node.Name; Status = $st; Phase = $phase; Gate = $gate
            Eligibility = "PHASE_BLOCKED"
            Reasons = @($reasons); BlockingNodeIds = @()
        }
    }

    # ---- 4. dependencies (from the roadmap Dependencies column) ----
    $depText = [string]$node.Dependencies
    $depTokens = @($depText -split "[\s,;|]+" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $unblocked = $true
    foreach ($tok in $depTokens) {
        $depNode = $null
        foreach ($n in @($Nodes)) { if ([string]$n.NodeId -eq $tok) { $depNode = $n; break } }
        if ($null -eq $depNode) { continue }   # token not a roadmap node => ignore (not an actionable dep)
        $depStatus = ([string]$depNode.Status).Trim()
        if ($depStatus -notin @("Complete", "Completed")) {
            $unblocked = $false
            if (-not $blockers.Contains($tok)) { $blockers.Add($tok) }
        }
    }
    if (-not $unblocked) {
        $reasons.Add("dependency/dependencies not terminal-complete: " + ($blockers -join ", "))
        return [PSCustomObject]@{
            NodeId = $NodeId; Name = $node.Name; Status = $st; Phase = $phase; Gate = $gate
            Eligibility = "DEPENDENCY_BLOCKED"
            Reasons = @($reasons); BlockingNodeIds = @($blockers)
        }
    }

    # ---- 5. reservations / conflicts (open = non-terminal Active Changes) ----
    $open = @($ActiveChanges | Where-Object {
        $cls = [string]$_.Classification
        if ($cls -eq "Terminal") { return $false }
        if ($cls -eq "InProgress" -or $cls -eq "Open" -or $cls -eq "Blocked") { return $true }
        return $true   # default: any non-'Terminal' Classification is open
    })
    foreach ($ac in $open) {
        $acNodes = @(([string]$ac.NodeId) -split "\|" | ForEach-Object { $_.Trim() })
        foreach ($acn in $acNodes) {
            if ($acn -eq $NodeId) {
                $reasons.Add("open Active Change $($ac.ChangeId) already reserves the exact node $NodeId")
                return [PSCustomObject]@{
                    NodeId = $NodeId; Name = $node.Name; Status = $st; Phase = $phase; Gate = $gate
                    Eligibility = "RESERVED"
                    Reasons = @($reasons); BlockingNodeIds = @($ac.ChangeId)
                }
            }
        }
    }
    # CONFLICTING_CHANGE (conservative): an open Active Change that (a) overlaps the same
    # Layer/area prefix on its Node ID AND (b) has a REAL whole-token overlap on Projects or
    # Files/Globs with the target node. Exact node collision is already handled above as
    # RESERVED; anything else must clear a high bar so we do NOT over-flag.
    $nodeProjects = @(([string]$node.Projects) -split "[\s,;|]+" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $nodeGlobs = @(([string]$node.FilesGlobs) -split "[\s,;|]+" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($ac in $open) {
        $acNode = ([string]$ac.NodeId).Trim()
        $areaPrefix = ""
        if ($NodeId -match "^(WI|M|F|T|S)-[\d\.]+") { $areaPrefix = $Matches[0] -replace "-\d+$", "" }
        $sameArea = ($areaPrefix -and $acNode.StartsWith($areaPrefix, [System.StringComparison]::OrdinalIgnoreCase))
        if (-not $sameArea) { continue }
        $overlap = $false
        $acProjects = @(([string]$ac.Projects) -split "[\s,|;]+" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $acGlobs = @(([string]$ac.FilesGlobs) -split "[\s,|;]+" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        foreach ($p in $nodeProjects) { if ($acProjects -contains $p) { $overlap = $true; break } }
        if (-not $overlap) {
            foreach ($g in $nodeGlobs) { if ($acGlobs -contains $g) { $overlap = $true; break } }
        }
        if ($overlap) {
            $reasons.Add("open Active Change $($ac.ChangeId) ($acNode) overlaps the same area '$areaPrefix' with a real project/glob token")
            return [PSCustomObject]@{
                NodeId = $NodeId; Name = $node.Name; Status = $st; Phase = $phase; Gate = $gate
                Eligibility = "CONFLICTING_CHANGE"
                Reasons = @($reasons); BlockingNodeIds = @($ac.ChangeId)
            }
        }
    }

    # ---- 6. ELIGIBLE ----
    return [PSCustomObject]@{
        NodeId = $NodeId; Name = $node.Name; Status = $st; Phase = $phase; Gate = $gate
        Eligibility = "ELIGIBLE"
        Reasons = @($reasons); BlockingNodeIds = @($blockers)
    }
}

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
function Test-W08Resolver {
    param()

    function New-Node([string]$id, [string]$status, [string]$phase, [string]$gate, [string]$deps, [string]$projects = "", [string]$globs = "") {
        [PSCustomObject]@{ NodeId = $id; Name = "Node $id"; Status = $status; Phase = $phase;
            Gate = $gate; Dependencies = $deps; Projects = $projects; FilesGlobs = $globs; Layer = "07" }
    }
    function New-Ac([string]$changeId, [string]$nodeId, [string]$classification, [string]$projects = "", [string]$globs = "") {
        [PSCustomObject]@{ ChangeId = $changeId; NodeId = $nodeId; Classification = $classification;
            Status = "Open -- synthetic"; Projects = $projects; FilesGlobs = $globs }
    }

    $failures = New-Object System.Collections.Generic.List[string]
    function Check([string]$scenario, [bool]$ok, [string]$detail) {
        $tag = if ($ok) { "PASS" } else { "FAIL" }
        Write-Output ("W08_RESOLVER_TEST: {0}={1}  {2}" -f $scenario, $tag, $detail)
        if (-not $ok) { $failures.Add($scenario) }
    }

    # 1. single eligible
    $n1 = @(New-Node "WI-08-1.1" "Planned" "P0" "GATE_A" "WI-08-1.0")
    $n1 += New-Node "WI-08-1.0" "Complete" "P0" "GATE_A" ""
    $r1 = Resolve-W08TaskEligibility -NodeId "WI-08-1.1" -Nodes $n1 -ActiveChanges @()
    Check "single-eligible" ($r1.Eligibility -eq "ELIGIBLE") ("got " + $r1.Eligibility)

    # 2. dependency blocked
    $n2 = @(New-Node "WI-08-2.1" "Planned" "P0" "GATE_A" "WI-08-2.0")
    $n2 += New-Node "WI-08-2.0" "Planned" "P0" "GATE_A" ""
    $r2 = Resolve-W08TaskEligibility -NodeId "WI-08-2.1" -Nodes $n2 -ActiveChanges @()
    Check "dependency-blocked" ($r2.Eligibility -eq "DEPENDENCY_BLOCKED" -and $r2.BlockingNodeIds -contains "WI-08-2.0") ("got " + $r2.Eligibility + " / blockers " + ($r2.BlockingNodeIds -join ","))

    # 3. required state blocked
    $n3 = @(New-Node "WI-08-3.1" "Complete" "P0" "GATE_A" "")
    $r3 = Resolve-W08TaskEligibility -NodeId "WI-08-3.1" -Nodes $n3 -ActiveChanges @()
    Check "required-state-blocked" ($r3.Eligibility -eq "REQUIRED_STATE_BLOCKED") ("got " + $r3.Eligibility)

    # 4. reservation conflict (exact node reserved)
    $n4 = @(New-Node "WI-08-4.1" "Planned" "P0" "GATE_A" "")
    $ac4 = @(New-Ac "CHG-20260909-004" "WI-08-4.1" "Open")
    $r4 = Resolve-W08TaskEligibility -NodeId "WI-08-4.1" -Nodes $n4 -ActiveChanges $ac4
    Check "reservation-conflict" ($r4.Eligibility -eq "RESERVED") ("got " + $r4.Eligibility)

    # 5. preflight rejected
    $n5 = @(New-Node "WI-08-5.1" "Planned" "P0" "GATE_A" "")
    $r5 = Resolve-W08TaskEligibility -NodeId "WI-08-5.1" -Nodes $n5 -ActiveChanges @() -PreflightVerdict "REJECTED"
    Check "preflight-rejected" ($r5.Eligibility -eq "PREFLIGHT_REJECTED") ("got " + $r5.Eligibility)

    # 6. phase-gate blocked (sub-cases gate + phase)
    $n6g = @(New-Node "WI-08-6.1" "Planned" "P0" "GATE_B" "")
    $r6g = Resolve-W08TaskEligibility -NodeId "WI-08-6.1" -Nodes $n6g -ActiveChanges @()
    $n6p = @(New-Node "WI-08-6.2" "Planned" "P5" "GATE_A" "")
    $r6p = Resolve-W08TaskEligibility -NodeId "WI-08-6.2" -Nodes $n6p -ActiveChanges @()
    Check "phase-gate-blocked" ($r6g.Eligibility -eq "GATE_BLOCKED" -and $r6p.Eligibility -eq "PHASE_BLOCKED") ("gate got " + $r6g.Eligibility + " / phase got " + $r6p.Eligibility)

    # 7. multiple eligible (driver scan finds an ordered list of eligible nodes)
    $n7 = @(
        (New-Node "WI-08-7.1" "Planned" "P0" "GATE_A" ""),
        (New-Node "WI-08-7.2" "Planned" "P0" "GATE_A" ""),
        (New-Node "WI-08-7.3" "Complete" "P0" "GATE_A" "")
    )
    $eligible7 = @($n7 | ForEach-Object {
        $rr = Resolve-W08TaskEligibility -NodeId $_.NodeId -Nodes $n7 -ActiveChanges @()
        if ($rr.Eligibility -eq "ELIGIBLE") { $_.NodeId }
    })
    Check "multiple-eligible" ($eligible7.Count -eq 2) ("expected 2 eligible, got " + $eligible7.Count + " [" + ($eligible7 -join ",") + "]")

    # 8. nothing eligible (8.1 terminal; 8.2 dependency-blocked on 8.0; 8.0 reserved)
    $n8 = @(
        (New-Node "WI-08-8.1" "Complete" "P0" "GATE_A" ""),
        (New-Node "WI-08-8.2" "Planned" "P0" "GATE_A" "WI-08-8.0"),
        (New-Node "WI-08-8.0" "Planned" "P0" "GATE_A" "")
    )
    $ac8 = @(New-Ac "CHG-20260909-008" "WI-08-8.0" "Open")
    $eligible8 = @($n8 | ForEach-Object {
        $rr = Resolve-W08TaskEligibility -NodeId $_.NodeId -Nodes $n8 -ActiveChanges $ac8
        if ($rr.Eligibility -eq "ELIGIBLE") { $_.NodeId }
    })
    Check "nothing-eligible" ($eligible8.Count -eq 0) ("expected 0 eligible, got " + $eligible8.Count)

    Write-Output ""
    if ($failures.Count -eq 0) {
        Write-Output "W08_RESOLVER_SUMMARY: 8/8 PASS"
    } else {
        Write-Output ("W08_RESOLVER_SUMMARY: " + (8 - $failures.Count) + "/8 PASS; FAILED: " + ($failures -join ","))
    }
}

if ($SelfTest -or $env:W08_SELFTEST -eq "1") {
    Test-W08Resolver
}
