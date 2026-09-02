# Show-DbM30SupervisedWorkflow.ps1 -- DB-M30 SUPERVISED DEVELOPMENT WORKFLOW terminal guide.
#
# Backend contract: this script ALWAYS exits 0. Outcomes are communicated ONLY via
# stdout markers (DB30_OUTCOME / DB30_*), so a governed harness can read them
# without exit-code ambiguity.
#
# The script is READ-ONLY: it builds the live SupervisedWorkflowView and prints the
# operator's current stage, next human action and guidance-card availability. It
# never advances the lifecycle, never executes a model/provider, never invokes
# ChatGPT/Claude, never creates/approves/merges a PR, never modifies the roadmap,
# and never touches the workbook or Nexus repos.
#
# Usage:
#   powershell -NoProfile -File scripts\supervised-workflow\Show-DbM30SupervisedWorkflow.ps1
#   powershell -NoProfile -File scripts\supervised-workflow\Show-DbM30SupervisedWorkflow.ps1 -OutputHtml logs\db-m30-workflow.html

param(
    [string]$OutputHtml
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:NowUtc = [datetime]::UtcNow.ToString('o')

. (Join-Path $PSScriptRoot "WorkflowEngine.ps1")

# Build the roadmap TaskCatalog best-effort (exactly the M05 integration shape).
# If the workbook read is unavailable the catalog stays empty and the dependency
# context resolves from the preflight dependencies alone (honest degradation).
$script:TaskCatalog = @{}
try {
    $readDevLib = Join-Path $script:Root 'scripts\Read-DevelopmentControl.ps1'
    if (Test-Path -LiteralPath $readDevLib) {
        . $readDevLib
        foreach ($rn in @(Get-AllRoadmapNodes)) {
            if (-not $rn -or -not $rn.NodeId) { continue }
            $depIds = @()
            if ($rn.Dependencies) {
                $depIds = @([string]$rn.Dependencies -split "[\r\n|]" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^(F|M|WI|T|S)-' } | Select-Object -Unique)
            }
            $script:TaskCatalog[[string]$rn.NodeId] = @{ taskId = [string]$rn.NodeId; dependencies = @($depIds | ForEach-Object { @{ dependencyId = $_; state = 'UNKNOWN' } }) }
        }
    }
} catch {
    $script:TaskCatalog = @{}
}

$view = Get-DbM30WorkflowView -NowUtc $script:NowUtc -TaskCatalog $script:TaskCatalog

# --- stdout markers (outcomes only; exit is always 0) ------------------------------
'DB30_OUTCOME: PASS'
'DB30_VIEW_GENERATED'
'DB30_CURRENT_STAGE: ' + $view.CurrentStage.StageKey
'DB30_CURRENT_TOKEN: ' + $view.CurrentStage.Token
'DB30_NEXT_HUMAN_ACTION: ' + $view.CurrentStage.Label
'DB30_TASK_NODE: ' + $view.LifecycleSnapshot.Task.NodeId
'DB30_TASK_CHANGE: ' + $view.LifecycleSnapshot.Task.ChangeId
'DB30_MODE: ' + $view.LifecycleSnapshot.Mode
'DB30_CARD_DEPENDENCY_CONTEXT: ' + $view.Cards.DependencyContext.CardStatus
'DB30_CARD_ROUTING_RECOMMENDATION: ' + $view.Cards.RoutingRecommendation.CardStatus
'DB30_CARD_COST_GUIDANCE: ' + $view.Cards.CostGuidance.CardStatus
'DB30_CARD_PROVIDER_HEALTH: ' + $view.Cards.ProviderHealth.CardStatus
'DB30_CARD_HISTORY: ' + $view.Cards.History.CardStatus
'DB30_WORKBOOK_MODIFIED: False'
'DB30_NEXUS_SOURCE_MODIFIED: False'
'DB30_GIT_MODIFIED: False'
''

# --- human-readable guide (stdout; informational only) -----------------------------
$task = $view.LifecycleSnapshot.Task
'DB-M30 SUPERVISED DEVELOPMENT WORKFLOW GUIDE (READ-ONLY)'
'========================================================'
'Task       : ' + $task.NodeId + ' - ' + $task.Name
'Change     : ' + $task.ChangeId
'Mode       : ' + $view.LifecycleSnapshot.Mode + '   Status: ' + $view.LifecycleSnapshot.Status
'State src  : ' + $view.StateSource + '   Generated: ' + $view.GeneratedAtUtc
''
'CURRENT STAGE: ' + $view.CurrentStage.Label + ' [' + $view.CurrentStage.Token + ']'
'NEXT HUMAN ACTION: ' + $view.CurrentStage.HumanAction
if ($view.CurrentStage.Note) { '  note: ' + $view.CurrentStage.Note }
''
'STAGES:'
foreach ($st in @($view.Stages)) {
    $line = ('  {0,2}  {1,-28} {2,-14} {3}' -f $st.Order, $st.Label, ('[' + $st.Token + ']'), $(if ($st.Note) { $st.Note } else { '' }))
    $line
}
''
'GUIDANCE CARDS:'
'  DependencyContext    : ' + $view.Cards.DependencyContext.CardStatus + $(if ($view.Cards.DependencyContext.Note) { ' - ' + $view.Cards.DependencyContext.Note } else { '' })
'  RoutingRecommendation: ' + $view.Cards.RoutingRecommendation.CardStatus + $(if ($view.Cards.RoutingRecommendation.Note) { ' - ' + $view.Cards.RoutingRecommendation.Note } else { '' })
'  CostGuidance         : ' + $view.Cards.CostGuidance.CardStatus + $(if ($view.Cards.CostGuidance.Note) { ' - ' + $view.Cards.CostGuidance.Note } else { '' })
'  ProviderHealth       : ' + $view.Cards.ProviderHealth.CardStatus + $(if ($view.Cards.ProviderHealth.Note) { ' - ' + $view.Cards.ProviderHealth.Note } else { '' })
'  History              : ' + $view.Cards.History.CardStatus + $(if ($view.Cards.History.Note) { ' - ' + $view.Cards.History.Note } else { '' })
''
foreach ($w in @($view.Warnings)) { 'WARN: ' + $w }
''
'DB30_READONLY: AUTO_EXECUTION_ENABLED=FALSE, workbook modified NO, Nexus source modified NO, git modified NO.'
'DB30_SUPERVISED: every external step (ChatGPT handoff copy, Claude Code / DeepSeek implementation, returning the result, Claude review, Git gates, completion) is performed by the human operator.'

# --- optional HTML artifact (the ONLY write the library performs) -------------------
if ($OutputHtml) {
    . (Join-Path $PSScriptRoot "WorkflowRender.ps1")
    $outPath = if ([System.IO.Path]::IsPathRooted($OutputHtml)) { $OutputHtml } else { Join-Path $script:Root $OutputHtml }
    $written = Export-DbM30WorkflowHtml -View $view -OutputPath $outPath
    'DB30_HTML_ARTIFACT: ' + $written
}

exit 0
