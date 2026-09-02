# WorkflowRender.ps1 -- DB-M30 SUPERVISED DEVELOPMENT WORKFLOW INTEGRATION renderer.
#
# Renders the SupervisedWorkflowView v1 as a self-contained HTML workflow console
# (inline CSS, embedded JSON, no external resources). The ONLY disk write in the
# DB-M30 library is Export-DbM30WorkflowHtml's UTF-8 no-BOM WriteAllText of the
# operator-requested artifact (the same pattern as DB-M27/M28/M29).
#
# READ-ONLY: the console only GUIDES the operator. AUTO_EXECUTION_ENABLED = FALSE.

. (Join-Path $PSScriptRoot "WorkflowContracts.ps1")

function ConvertTo-DbM30HtmlSafeText {
    <#
    .SYNOPSIS
    HTML-encode free text for embedding (null -> '').
    #>
    param($Value)
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    $s = $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
    return $s
}

function ConvertTo-DbM30Html {
    <#
    .SYNOPSIS
    Render the workflow console HTML from the SupervisedWorkflowView v1.
    #>
    param(
        [AllowNull()][object]$View,
        [string]$Title = 'DevBridge Supervised Development Workflow'
    )
    if ($null -eq $View) { throw 'ConvertTo-DbM30Html: View is required' }

    $tokenClass = @{
        'NOT_STARTED' = 'tok ns'; 'READY' = 'tok ready'; 'CURRENT' = 'tok current'
        'PASS' = 'tok pass'; 'FAIL' = 'tok fail'; 'BLOCKED' = 'tok blocked'
        'HUMAN_ACTION' = 'tok human'; 'NOT_APPLICABLE' = 'tok na'
    }
    $ls = $View.LifecycleSnapshot
    $task = $ls.Task
    $cur = $View.CurrentStage
    $cards = $View.Cards
    $guard = $View.ReadOnlyGuard

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en">')
    [void]$sb.AppendLine('<head>')
    [void]$sb.AppendLine('<meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.AppendLine('<title>' + (ConvertTo-DbM30HtmlSafeText $Title) + '</title>')
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine('  body { font-family: "Segoe UI", Arial, sans-serif; margin: 0; background: #f4f6f8; color: #1c2733; }')
    [void]$sb.AppendLine('  .wrap { max-width: 1080px; margin: 0 auto; padding: 24px 16px 48px; }')
    [void]$sb.AppendLine('  h1 { font-size: 22px; margin: 0 0 2px; }')
    [void]$sb.AppendLine('  .sub { color: #5a6b7b; font-size: 13px; margin-bottom: 18px; }')
    [void]$sb.AppendLine('  .banner { background: #eef4ff; border: 1px solid #c4d5f5; border-left: 6px solid #2456a6; border-radius: 6px; padding: 12px 16px; margin-bottom: 20px; }')
    [void]$sb.AppendLine('  .banner .lbl { font-size: 11px; text-transform: uppercase; letter-spacing: .06em; color: #2456a6; }')
    [void]$sb.AppendLine('  .banner .big { font-size: 18px; font-weight: 600; margin: 2px 0; }')
    [void]$sb.AppendLine('  .banner .act { color: #3a4a5a; font-size: 14px; }')
    [void]$sb.AppendLine('  .meta { font-size: 12px; color: #5a6b7b; margin-bottom: 18px; line-height: 1.7; }')
    [void]$sb.AppendLine('  .meta b { color: #2a3b4c; }')
    [void]$sb.AppendLine('  .cols { display: flex; gap: 18px; flex-wrap: wrap; }')
    [void]$sb.AppendLine('  .col { flex: 1 1 460px; min-width: 320px; }')
    [void]$sb.AppendLine('  .card { background: #fff; border: 1px solid #dde4ec; border-radius: 8px; padding: 14px 16px; margin-bottom: 16px; }')
    [void]$sb.AppendLine('  .card h2 { font-size: 14px; margin: 0 0 10px; border-bottom: 1px solid #eef1f5; padding-bottom: 6px; }')
    [void]$sb.AppendLine('  table.stages { width: 100%; border-collapse: collapse; }')
    [void]$sb.AppendLine('  table.stages th, table.stages td { text-align: left; padding: 7px 8px; font-size: 12.5px; border-bottom: 1px solid #eef1f5; vertical-align: top; }')
    [void]$sb.AppendLine('  table.stages th { color: #5a6b7b; font-weight: 600; text-transform: uppercase; font-size: 11px; }')
    [void]$sb.AppendLine('  .tok { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px; font-weight: 600; white-space: nowrap; }')
    [void]$sb.AppendLine('  .tok.ns { background: #eceff2; color: #5a6b7b; }')
    [void]$sb.AppendLine('  .tok.ready { background: #e8f2ff; color: #2456a6; }')
    [void]$sb.AppendLine('  .tok.current { background: #fff4d6; color: #8a6d00; }')
    [void]$sb.AppendLine('  .tok.pass { background: #e3f5e8; color: #176b3a; }')
    [void]$sb.AppendLine('  .tok.fail { background: #fde4e4; color: #a12d2d; }')
    [void]$sb.AppendLine('  .tok.blocked { background: #f7e3dc; color: #9a4a24; }')
    [void]$sb.AppendLine('  .tok.human { background: #e9e7fb; color: #4a3fae; }')
    [void]$sb.AppendLine('  .tok.na { background: #eceff2; color: #8b98a5; }')
    [void]$sb.AppendLine('  .row-note { color: #5a6b7b; font-size: 11.5px; margin-top: 3px; }')
    [void]$sb.AppendLine('  .cmd { font-family: Consolas, monospace; font-size: 11.5px; color: #2456a6; }')
    [void]$sb.AppendLine('  .guide { font-size: 12.5px; line-height: 1.6; margin: 2px 0; }')
    [void]$sb.AppendLine('  .guide b { color: #2a3b4c; }')
    [void]$sb.AppendLine('  .avail { font-weight: 600; }')
    [void]$sb.AppendLine('  .status-AVAILABLE { color: #176b3a; } .status-NOT_AVAILABLE { color: #a12d2d; } .status-NOT_ENABLED { color: #8a6d00; } .status-EMPTY { color: #5a6b7b; }')
    [void]$sb.AppendLine('  .kv { font-size: 12.5px; margin: 2px 0; } .kv b { color: #2a3b4c; }')
    [void]$sb.AppendLine('  .guard { font-size: 11.5px; color: #5a6b7b; border-top: 1px solid #dde4ec; margin-top: 20px; padding-top: 10px; }')
    [void]$sb.AppendLine('  .warn { background: #fff8ec; border: 1px solid #f0dfb4; border-radius: 6px; padding: 10px 14px; font-size: 12.5px; margin-bottom: 16px; }')
    [void]$sb.AppendLine('  pre.json { background: #0f1722; color: #d7e3f0; font-size: 11px; border-radius: 8px; padding: 14px; overflow-x: auto; white-space: pre-wrap; word-break: break-word; }')
    [void]$sb.AppendLine('</style>')
    [void]$sb.AppendLine('</head>')
    [void]$sb.AppendLine('<body><div class="wrap">')

    [void]$sb.AppendLine('<h1>' + (ConvertTo-DbM30HtmlSafeText $Title) + '</h1>')
    [void]$sb.AppendLine('<div class="sub">DB-M30 Supervised Workflow Guide - READ-ONLY guidance for the human operator. Nothing is executed automatically.</div>')

    # current-stage banner
    $bannerClass = switch ($cur.Token) {
        'BLOCKED' { 'banner blocked' }
        'FAIL' { 'banner fail' }
        'HUMAN_ACTION' { 'banner human' }
        default { 'banner' }
    }
    [void]$sb.AppendLine('<div class="' + $bannerClass + '">')
    [void]$sb.AppendLine('<div class="lbl">Current stage - ' + (ConvertTo-DbM30HtmlSafeText $cur.StageKey) + ' [' + (ConvertTo-DbM30HtmlSafeText $cur.Token) + ']</div>')
    [void]$sb.AppendLine('<div class="big">' + (ConvertTo-DbM30HtmlSafeText $cur.Label) + '</div>')
    [void]$sb.AppendLine('<div class="act">' + (ConvertTo-DbM30HtmlSafeText $cur.HumanAction) + '</div>')
    if ($cur.Note) { [void]$sb.AppendLine('<div class="row-note">' + (ConvertTo-DbM30HtmlSafeText $cur.Note) + '</div>') }
    [void]$sb.AppendLine('</div>')

    # meta
    [void]$sb.AppendLine('<div class="meta">')
    [void]$sb.AppendLine('<b>Task:</b> ' + (ConvertTo-DbM30HtmlSafeText $task.NodeId) + ' - ' + (ConvertTo-DbM30HtmlSafeText $task.Name) + ' &nbsp;|&nbsp; <b>Change:</b> ' + (ConvertTo-DbM30HtmlSafeText $task.ChangeId) + ' &nbsp;|&nbsp; <b>Mode:</b> ' + (ConvertTo-DbM30HtmlSafeText $ls.Mode) + ' &nbsp;|&nbsp; <b>Status:</b> ' + (ConvertTo-DbM30HtmlSafeText $ls.Status) + ' &nbsp;|&nbsp; <b>Next:</b> ' + (ConvertTo-DbM30HtmlSafeText $ls.NextAllowedAction))
    [void]$sb.AppendLine('<br><b>State source:</b> ' + (ConvertTo-DbM30HtmlSafeText $View.StateSource) + ' &nbsp;|&nbsp; <b>Generated:</b> ' + (ConvertTo-DbM30HtmlSafeText $View.GeneratedAtUtc) + ' &nbsp;|&nbsp; <b>Workbook SHA256:</b> ' + (ConvertTo-DbM30HtmlSafeText $task.WorkbookSha256))
    [void]$sb.AppendLine('</div>')

    if (@($View.Warnings).Count -gt 0) {
        [void]$sb.AppendLine('<div class="warn"><b>Warnings:</b><br>')
        foreach ($w in @($View.Warnings)) { [void]$sb.AppendLine('&bull; ' + (ConvertTo-DbM30HtmlSafeText $w) + '<br>') }
        [void]$sb.AppendLine('</div>')
    }

    [void]$sb.AppendLine('<div class="cols">')
    [void]$sb.AppendLine('<div class="col">')

    # stages checklist
    [void]$sb.AppendLine('<div class="card"><h2>Supervised Workflow Pipeline (13 stages)</h2>')
    [void]$sb.AppendLine('<table class="stages"><tr><th>#</th><th>Stage</th><th>State</th><th>Operator action / command</th></tr>')
    foreach ($st in @($View.Stages)) {
        $cls = if ($tokenClass.ContainsKey([string]$st.Token)) { $tokenClass[[string]$st.Token] } else { 'tok ns' }
        $cmd = (@($st.Commands) -join '  ')
        $cmdCell = if ($cmd) { '<span class="cmd">' + (ConvertTo-DbM30HtmlSafeText $cmd) + '</span>' } else { '' }
        [void]$sb.AppendLine('<tr><td>' + [int]$st.Order + '</td>')
        [void]$sb.AppendLine('<td><b>' + (ConvertTo-DbM30HtmlSafeText $st.Label) + '</b>' + $(if ($st.Note) { '<div class="row-note">' + (ConvertTo-DbM30HtmlSafeText $st.Note) + '</div>' } else { '' }) + '</td>')
        [void]$sb.AppendLine('<td><span class="' + $cls + '">' + (ConvertTo-DbM30HtmlSafeText $st.Token) + '</span></td>')
        [void]$sb.AppendLine('<td>' + $cmdCell + ' ' + (ConvertTo-DbM30HtmlSafeText $st.HumanAction) + '</td></tr>')
    }
    [void]$sb.AppendLine('</table></div>')

    [void]$sb.AppendLine('</div><div class="col">')

    # guidance cards
    $cardDefs = @(
        @{ Name = 'DependencyContext'; Title = 'Dependency Development Context (DB-M18.1)' },
        @{ Name = 'RoutingRecommendation'; Title = 'AI Routing Recommendation (DB-M19, dry-run)' },
        @{ Name = 'CostGuidance'; Title = 'Cost & Budget Guidance (DB-M27/M21/M25)' },
        @{ Name = 'ProviderHealth'; Title = 'Provider Health (DB-M22)' },
        @{ Name = 'History'; Title = 'Task History (DB-M26/M29)' }
    )
    foreach ($cd in $cardDefs) {
        $c = Get-ContractProperty $cards $cd.Name $null
        $st = [string](Get-ContractProperty $c 'CardStatus' 'NOT_AVAILABLE')
        [void]$sb.AppendLine('<div class="card"><h2>' + $cd.Title + ' &nbsp;<span class="avail status-' + $st + '">[' + $st + ']</span></h2>')
        switch ($cd.Name) {
            'DependencyContext' {
                [void]$sb.AppendLine('<div class="kv"><b>Freshness:</b> ' + (ConvertTo-DbM30HtmlSafeText (Get-ContractProperty $c 'FreshnessStatus' '')) + '</div>')
                [void]$sb.AppendLine('<div class="kv"><b>Direct dependencies:</b> ' + [int](Get-ContractProperty $c 'DirectDependencyCount' 0) + ' &nbsp;|&nbsp; <b>Delivered lineage:</b> ' + [int](Get-ContractProperty $c 'DeliveredSummaryCount' 0) + '</div>')
                [void]$sb.AppendLine('<div class="kv"><b>Reuse / extension / collision:</b> ' + [int](Get-ContractProperty $c 'ReusePointCount' 0) + ' / ' + [int](Get-ContractProperty $c 'ExtensionPointCount' 0) + ' / ' + [int](Get-ContractProperty $c 'CollisionPointCount' 0) + '</div>')
                [void]$sb.AppendLine('<div class="kv"><b>Context:</b> ' + (ConvertTo-DbM30HtmlSafeText (Get-ContractProperty $c 'ContextId' '')) + ' &nbsp;|&nbsp; <b>Package hash:</b> ' + (ConvertTo-DbM30HtmlSafeText (Get-ContractProperty $c 'PackageHash' '')) + '</div>')
            }
            'RoutingRecommendation' {
                [void]$sb.AppendLine('<div class="kv"><b>Policy:</b> ' + (ConvertTo-DbM30HtmlSafeText (Get-ContractProperty $c 'PolicyId' '')) + ' &nbsp;|&nbsp; <b>Enabled:</b> ' + [bool](Get-ContractProperty $c 'PolicyEnabled' $false) + '</div>')
                [void]$sb.AppendLine('<div class="kv"><b>Status:</b> ' + (ConvertTo-DbM30HtmlSafeText (Get-ContractProperty $c 'RecommendationStatus' '')) + ' &nbsp;|&nbsp; <b>Winner:</b> ' + (ConvertTo-DbM30HtmlSafeText (Get-ContractProperty $c 'WinnerProviderId' '')) + '/' + (ConvertTo-DbM30HtmlSafeText (Get-ContractProperty $c 'WinnerModelId' '')) + ' ' + (ConvertTo-DbM30HtmlSafeText (Get-ContractProperty $c 'WinnerReasoningLevel' '')) + '</div>')
                [void]$sb.AppendLine('<div class="kv"><b>Eligible / rejected:</b> ' + [int](Get-ContractProperty $c 'EligibleCandidateCount' 0) + ' / ' + [int](Get-ContractProperty $c 'RejectedCandidateCount' 0) + '</div>')
            }
            'CostGuidance' {
                $est = Get-ContractProperty $c 'EstimatedCost' $null
                [void]$sb.AppendLine('<div class="kv"><b>Scenario:</b> ' + (ConvertTo-DbM30HtmlSafeText (Get-ContractProperty $c 'Scenario' '')) + '</div>')
                [void]$sb.AppendLine('<div class="kv"><b>Estimated cost:</b> ' + $(if ($null -ne $est) { [string]$est } else { '-' }) + ' ' + (ConvertTo-DbM30HtmlSafeText (Get-ContractProperty $c 'CostCurrency' '')) + ' [' + (ConvertTo-DbM30HtmlSafeText (Get-ContractProperty $c 'EstimateSource' 'ESTIMATED')) + ']</div>')
                [void]$sb.AppendLine('<div class="kv"><b>Budget:</b> ' + (ConvertTo-DbM30HtmlSafeText (Get-ContractProperty $c 'BudgetDecision' '')) + ' ' + (ConvertTo-DbM30HtmlSafeText (Get-ContractProperty $c 'BudgetCurrency' '')) + '</div>')
                [void]$sb.AppendLine('<div class="kv"><b>History totals (DB-M25):</b> actual ' + ([double](Get-ContractProperty $c 'TotalActualCost' 0)).ToString('0.00') + ' + estimated ' + ([double](Get-ContractProperty $c 'TotalEstimatedCost' 0)).ToString('0.00') + ' over ' + [int](Get-ContractProperty $c 'AttemptCount' 0) + ' attempt(s)</div>')
            }
            'ProviderHealth' {
                [void]$sb.AppendLine('<div class="kv"><b>Health:</b> ' + (ConvertTo-DbM30HtmlSafeText (Get-ContractProperty $c 'HealthState' '')) + ' &nbsp;|&nbsp; <b>Circuit:</b> ' + (ConvertTo-DbM30HtmlSafeText (Get-ContractProperty $c 'CircuitState' '')) + ' &nbsp;|&nbsp; <b>Requires human:</b> ' + [bool](Get-ContractProperty $c 'RequiresHuman' $false) + '</div>')
                [void]$sb.AppendLine('<div class="kv"><b>Fresh evidence:</b> ' + [int](Get-ContractProperty $c 'FreshEvidenceCount' 0) + '</div>')
            }
            'History' {
                [void]$sb.AppendLine('<div class="kv"><b>Attempt records:</b> ' + [int](Get-ContractProperty $c 'Count' 0) + ' &nbsp;|&nbsp; <b>Empty:</b> ' + [bool](Get-ContractProperty $c 'Empty' $false) + ' &nbsp;|&nbsp; <b>Task rows:</b> ' + [int](Get-ContractProperty $c 'TaskRowCount' 0) + '</div>')
                [void]$sb.AppendLine('<div class="kv"><b>Dashboard view:</b> ' + [bool](Get-ContractProperty $c 'DashboardAvailable' $false) + ' &nbsp;|&nbsp; <b>History view:</b> ' + [bool](Get-ContractProperty $c 'HistoryViewAvailable' $false) + '</div>')
            }
        }
        [void]$sb.AppendLine('<div class="guide">' + (ConvertTo-DbM30HtmlSafeText (Get-ContractProperty $c 'Note' '')) + '</div>')
        [void]$sb.AppendLine('</div>')
    }

    [void]$sb.AppendLine('</div></div>')

    # guard footer
    [void]$sb.AppendLine('<div class="guard">')
    [void]$sb.AppendLine('<b>Read-only guard (DB-M30):</b> AutoExecutionEnabled=' + [bool]$guard.AutoExecutionEnabled + ' &nbsp; PaidApiCalls=' + [int]$guard.PaidApiCalls + ' &nbsp; NetworkCalls=' + [int]$guard.NetworkCalls + ' &nbsp; LifecycleStateModified=' + (ConvertTo-DbM30HtmlSafeText $guard.LifecycleStateModified) + ' &nbsp; RoutingPolicyModified=' + (ConvertTo-DbM30HtmlSafeText $guard.RoutingPolicyModified) + ' &nbsp; WorkbookModified=' + (ConvertTo-DbM30HtmlSafeText $guard.WorkbookModified) + ' &nbsp; NexusSourceModified=' + (ConvertTo-DbM30HtmlSafeText $guard.NexusSourceModified))
    [void]$sb.AppendLine('</div>')

    # embedded view JSON (display only, HTML-encoded)
    $json = $View | ConvertTo-Json -Depth 12
    $json = $json.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
    [void]$sb.AppendLine('<h2 style="font-size:14px;margin:22px 0 6px;">SupervisedWorkflowView v1 (embedded JSON)</h2>')
    [void]$sb.AppendLine('<pre class="json">' + $json + '</pre>')

    [void]$sb.AppendLine('</div></body></html>')
    return $sb.ToString()
}

function Export-DbM30WorkflowHtml {
    <#
    .SYNOPSIS
    Render the workflow console and write the operator-requested HTML artifact.
    The library itself performs no other writes. Returns the output path.
    #>
    param(
        [AllowNull()][object]$View,
        [string]$OutputPath,
        [string]$Title = 'DevBridge Supervised Development Workflow'
    )
    if (-not $OutputPath) { throw 'Export-DbM30WorkflowHtml: OutputPath is required' }
    $html = ConvertTo-DbM30Html -View $View -Title $Title
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputPath, $html, $utf8NoBom)
    return (Get-Item $OutputPath).FullName
}
