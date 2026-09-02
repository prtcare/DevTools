# Test-ChatGptHandoffReady.ps1
# DevBridge DB-GH01 ChatGptHandoffValidation v1 gate -- READ-ONLY. Validates that
# tasks\CHATGPT_HANDOFF.md carries the 14 mandatory governance checks. If any is
# missing the handoff is CHATGPT_HANDOFF_NOT_READY and COPY_TO_CHATGPT must not
# be exposed until corrected.
#
# Backend contract: ALWAYS exits 0; outcomes communicated ONLY via stdout markers.
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:TasksDir = Join-Path $script:Root "tasks"
$script:HandoffPath = Join-Path $script:TasksDir "CHATGPT_HANDOFF.md"

# Same marker rules as the engine's ChatGptHandoffValidation (14 checks).
$script:Rules = @(
    @{ name = "TemporaryBoundaryPresent";      markers = @("TEMPORARY","external scaffolding","retire") }
    @{ name = "ModePresent";                   markers = @("TRIAL","REAL_NEXUS_DEVELOPMENT") }
    @{ name = "ArchitectureRulesPresent";      markers = @("architecture","NOT Nexus","no architecture") }
    @{ name = "DesignPhilosophyPresent";       markers = @("scaffolding","Nexus Phase 1/2","retire") }
    @{ name = "RoadmapProtectionPresent";      markers = @("roadmap","immutable","no structural") }
    @{ name = "WorkbookAuthorityPresent";      markers = @("NEXUS_DEVELOPMENT_CONTROL.xlsx","authoritative") }
    @{ name = "GitHumanGatePresent";           markers = @("human","PR","merge","gate") }
    @{ name = "ClaudeGatePresent";             markers = @("DB-M08","Claude") }
    @{ name = "TaskIdentityPresent";           markers = @("task","change","node") }
    @{ name = "ExactScopePresent";             markers = @("scope","exact") }
    @{ name = "ForbiddenActionsPresent";       markers = @("forbidden","must not","prohibited") }
    @{ name = "AcceptanceCriteriaPresent";     markers = @("acceptance","criteria") }
    @{ name = "VerificationPresent";           markers = @("DB-M06","verification") }
    @{ name = "OutputContractPresent";         markers = @("report","output","DeepSeek") }
)

if (-not (Test-Path $script:HandoffPath)) {
    Write-Output "DBGH01_HANDOFF_READY: False"
    Write-Output "DBGH01_HANDOFF_MISSING: HANDOFF_FILE_ABSENT"
    Write-Output "DBGH01_HANDOFF_TOKEN: CHATGPT_HANDOFF_NOT_READY"
    Write-Output "DBGH01_OUTCOME: CHATGPT_HANDOFF_NOT_READY"
    exit 0
}

$script:Hay = [System.IO.File]::ReadAllText($script:HandoffPath)
$script:Present = New-Object System.Collections.Generic.List[string]
$script:Missing = New-Object System.Collections.Generic.List[string]
foreach ($r in $script:Rules) {
    $hit = $false
    foreach ($m in $r.markers) {
        if ($script:Hay.IndexOf($m, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true; break }
    }
    if ($hit) { $script:Present.Add($r.name) | Out-Null } else { $script:Missing.Add($r.name) | Out-Null }
}

$script:Ready = ($script:Missing.Count -eq 0)
Write-Output ("DBGH01_HANDOFF_READY: " + $script:Ready)
Write-Output ("DBGH01_HANDOFF_PRESENT: " + ($script:Present -join ";"))
Write-Output ("DBGH01_HANDOFF_MISSING: " + $(if ($script:Missing.Count -gt 0) { ($script:Missing -join ";") } else { "(none)" }))
if ($script:Ready) {
    Write-Output "DBGH01_HANDOFF_TOKEN: READY"
    Write-Output "DBGH01_OUTCOME: CHATGPT_HANDOFF_READY"
} else {
    Write-Output "DBGH01_HANDOFF_TOKEN: CHATGPT_HANDOFF_NOT_READY"
    Write-Output "DBGH01_OUTCOME: CHATGPT_HANDOFF_NOT_READY"
}
exit 0
