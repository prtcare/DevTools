# WorkbookGitRender.ps1 -- DB-M31 human-action HTML renderer.
#
# Consumes WorkbookGitContracts.ps1 + WorkbookGitEngine.ps1. Self-contained HTML
# (UTF-8, no BOM, written ONLY via WriteAllText when the operator requests the
# artifact). Presents the five DISTINCT human actions -- CREATE PR / REVIEW PR /
# MERGE PR / RUN COMPLETION / RUN WORKBOOK VALIDATION -- of which only the last
# two invoke a governed backend. The rendered page is a guide: it performs no
# Git action, no workbook write, no autonomous step.

Set-StrictMode -Version Latest

function ConvertTo-DbM31Html {
    <#
    .SYNOPSIS
    Escape text for safe HTML embedding.
    #>
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    $s = $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
    return $s
}

function Resolve-DbM31HumanActionEntry {
    <#
    .SYNOPSIS
    Map the five distinct actions onto state/buttons. Only RUN COMPLETION and RUN
    WORKBOOK VALIDATION invoke a backend; the three PR actions are human-only.
    #>
    param([AllowNull()][object]$View)
    $rows = New-Object System.Collections.ArrayList
    foreach ($a in @($View.Actions)) {
        $enabled = $true
        $note = $a.Detail
        if ($a.Action -eq 'RUN COMPLETION') {
            if ($View.M10.Token -eq 'TRIAL_COMPLETION_NOT_APPLICABLE') { $enabled = $false; $note = 'TRIAL cycle: M10 completion is NOT applicable (TRIAL_COMPLETION_NOT_APPLICABLE).' }
            elseif (-not $View.M10.Eligible) { $enabled = $false; $note = "M10 blocked: $($View.M10.Token) -- $($View.M10.Reason)" }
            else { $note = "M10 eligible ($($View.M10.Token)): the governed completion backend may be invoked." }
        }
        if ($a.Action -eq 'RUN WORKBOOK VALIDATION') {
            $note = 'Runs the M11 post-completion validation (14-sheet consistency, coherence, closures, protected roadmap).'
        }
        if ($a.Action -match 'PR') {
            $gate = $View.GitGate.GateState
            if ($a.Action -eq 'CREATE PR' -and $gate -notmatch 'AWAITING_HUMAN_PR|PR_STATE_UNKNOWN') { $enabled = $false; $note = "Git gate is '$gate'; a PR package is only prepared while awaiting human PR." }
            if ($a.Action -eq 'REVIEW PR' -and $gate -notmatch 'PR_OPEN|AWAITING_HUMAN_REVIEW') { $enabled = $false; $note = "Git gate is '$gate'; review is only relevant while a PR is open." }
            if ($a.Action -eq 'MERGE PR' -and $gate -notmatch 'AWAITING_HUMAN_MERGE|PR_OPEN|AWAITING_HUMAN_REVIEW') { $enabled = $false; $note = "Git gate is '$gate'; merge is only relevant after review." }
        }
        [void]$rows.Add([pscustomobject]@{ Action = $a.Action; Backend = $a.Backend; Human = $a.Human; Enabled = $enabled; Note = $note })
    }
    return @($rows.ToArray())
}

function Export-DbM31GovernedRealUseHtml {
    <#
    .SYNOPSIS
    Render the supervised human-action page. Deterministic given a view. Writes
    the HTML via WriteAllText (UTF-8, no BOM) ONLY to the operator-requested
    path; no other write exists in the renderer.
    #>
    param(
        [AllowNull()][object]$View,
        [string]$OutputPath
    )
    if ($null -eq $View) { $View = [pscustomobject]@{ Error = 'No view supplied' } }
    if (-not $OutputPath) { throw 'OutputPath is required for the HTML artifact' }
    $dir = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $leak = Test-DbM31SecretLeak -Target $View
    if ($leak.Leak) { throw 'Render blocked: secret-like value present in the view; nothing rendered.' }

    $lc = $View.Lifecycle
    $gt = $View.GitGate
    $m10 = $View.M10
    $guard = $View.Guard
    $rows = Resolve-DbM31HumanActionEntry -View $View
    $trial = $View.TrialFlow

    $actionRows = ''
    foreach ($r in @($rows)) {
        $badge = if ($r.Human) { 'HUMAN' } else { 'BACKEND' }
        $state = if ($r.Enabled) { 'action-ready' } else { 'action-blocked' }
        $actionRows += "<div class='action-row $state'><div class='action-left'><span class='chip chip-$($r.Action.Split(' ')[0].ToLowerInvariant())'>$($r.Action)</span><span class='chip'>$badge</span></div><div class='action-note'>$($r.Note)</div></div>"
    }

    $warnings = ''
    if ($View.Warnings.Count -gt 0) {
        $warnings = "<div class='warn'><strong>Warnings (evidence ownership):</strong><ul>"
        foreach ($w in @($View.Warnings)) { $warnings += "<li>$($w)</li>" }
        $warnings += '</ul></div>'
    }

    $prereqHtml = ''
    foreach ($p in @($m10.Prerequisites)) {
        $mark = if ($p.Satisfied) { '&#10003;' } else { '&#10007;' }
        $cls = if ($p.Satisfied) { 'ok' } else { 'no' }
        $prereqHtml += "<li class='$cls'><span class='mark'>$mark</span><span>$($p.Name)</span><span class='detail'>$($p.Detail)</span></li>"
    }

    $partsHtml = ''
    if ($View.M11Parts) { foreach ($pt in @($View.M11Parts)) { $mk = if ($pt.Pass) { '&#10003;' } else { '&#10007;' }; $partsHtml += "<li class='$(if($pt.Pass){'ok'}else{'no'})'><span class='mark'>$mk</span><span>$($pt.Name)</span><span class='detail'>$($pt.Detail)</span></li>" } }

    $gitObs = $View.GitObservation
    $fp = $View.Fingerprint

    $html = @"
<!DOCTYPE html>
<html lang='en'>
<head>
<meta charset='utf-8'>
<title>DB-M31 Governed Real-Use (Workbook &amp; Git)</title>
<style>
  :root { color-scheme: light dark; --bg:#f6f5f2; --card:#fff; --ink:#1c1c1c; --mut:#6b6b6b; --line:#e4e1da; --ok:#1d7a3f; --no:#b3261e; --accent:#2b5bb5; --chip:#ecebe6; }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--ink); font:14px/1.5 "Segoe UI", system-ui, sans-serif; }
  main { max-width: 980px; margin: 0 auto; padding: 24px 20px 60px; }
  h1 { font-size: 22px; margin: 0 0 4px; } .sub { color: var(--mut); margin-bottom: 18px; }
  .card { background: var(--card); border:1px solid var(--line); border-radius: 10px; padding: 16px 18px; margin-bottom: 16px; }
  h2 { font-size: 15px; margin: 0 0 10px; text-transform: uppercase; letter-spacing: .04em; color: var(--mut); }
  table { border-collapse: collapse; width: 100%; } th,td { text-align:left; padding: 6px 8px; border-bottom: 1px solid var(--line); vertical-align: top; }
  th { color: var(--mut); font-weight: 600; font-size: 12px; }
  .chip { display:inline-block; background:var(--chip); border-radius: 999px; padding: 2px 10px; font-size: 12px; font-weight:600; margin-right: 6px; }
  .chip-create-pr { color:#fff; background:#8a5a00; } .chip-review-pr { color:#fff; background:#2b5bb5; }
  .chip-merge-pr { color:#fff; background:#1d7a3f; } .chip-run { color:#fff; background:#5b3fa8; }
  .action-row { display:flex; gap:14px; align-items:center; padding: 10px 4px; border-bottom:1px solid var(--line); }
  .action-row:last-child { border-bottom:0; }
  .action-left { min-width: 200px; } .action-note { color:var(--mut); }
  .action-blocked .action-note { color: var(--no); }
  .warn { background:#fff6e5; border:1px solid #e6c98a; color:#5a4300; border-radius:8px; padding:10px 14px; margin-bottom:16px; }
  .warn ul { margin:6px 0 0 18px; }
  ul.prereq, ul.parts { list-style:none; margin:0; padding:0; }
  ul.prereq li, ul.parts li { display:flex; gap:10px; align-items:baseline; padding:5px 0; border-bottom:1px dashed var(--line); }
  ul.prereq li:last-child, ul.parts li:last-child { border-bottom:0; }
  .mark { width:18px; font-weight:700; } li.ok .mark { color:var(--ok); } li.no .mark { color:var(--no); }
  .detail { color:var(--mut); font-size:12px; margin-left:auto; text-align:right; max-width:55%; }
  .kv { font-family:Consolas, monospace; font-size:12.5px; background:var(--chip); border-radius:6px; padding:2px 7px; }
  .note { color: var(--mut); font-size: 12.5px; }
  .mono { font-family:Consolas, monospace; }
</style>
</head>
<body>
<main>
  <h1>DB-M31 Governed Real-Use</h1>
  <div class='sub'>Workbook &amp; Git support for supervised real Nexus use &mdash; READ-ONLY guide. <span class='kv'>$($View.ViewId)</span></div>

  <div class='card'>
    <h2>Mode &amp; lifecycle snapshot</h2>
    <table>
      <tr><th>Mode</th><td class='kv'>$($lc.Mode)</td><th>State source</th><td class='kv'>$($View.StateSource)</td></tr>
      <tr><th>Task node</th><td class='kv'>$($lc.NodeId)</td><th>Change ID</th><td class='kv'>$($lc.ChangeId)</td></tr>
      <tr><th>Status</th><td class='kv'>$($lc.Status)</td><th>Next allowed action</th><td class='kv'>$($lc.NextAllowedAction)</td></tr>
      <tr><th>Trial flow position</th><td class='kv'>$($trial.Position)</td><th>Trial M10</th><td class='kv'>$($trial.M10)</td></tr>
      <tr><th>M06 verification</th><td>$(if($lc.VerificationPassed){'VERIFICATION_PASSED'}else{'NOT PASSED'})</td><th>Claude review</th><td>$(if($lc.ClaudePassed){'PASS'}else{'NOT PASSED'})</td></tr>
      <tr><th>Git lifecycle state</th><td class='kv'>$($lc.GitLifecycleState)</td><th>Governance blocked</th><td>$(if($lc.GovernanceBlocked){'YES'}else{'NO'})</td></tr>
    </table>
    $warnings
  </div>

  <div class='card'>
    <h2>Human Git gate (explicit evidence only)</h2>
    <table>
      <tr><th>Gate state</th><td class='kv'>$($gt.GateState)</td><th>Merge confirmed</th><td>$(if($gt.MergeConfirmed){'YES -- positive merge evidence'}else{'NO -- never inferred'})</td></tr>
      <tr><th>Human action</th><td colspan='3'>$($gt.HumanAction)</td></tr>
      <tr><th>Git observation</th><td colspan='3' class='mono'>repo=$(if($gitObs.Repository){$gitObs.Repository}else{'none'}) branch=$(if($gitObs.Branch){$gitObs.Branch}else{'unknown'}) head=$(if($gitObs.HeadCommit){$gitObs.HeadCommit}else{'unknown'}) dirty=$(if($gitObs.WorkingTreeDirty){'yes'}else{'no'})</td></tr>
      <tr><th>Remote PR state</th><td class='kv'>UNKNOWN</td><th>Merge evidence</th><td class='kv'>$(if($gt.MergeEvidence){$gt.MergeEvidence}else{'none -- MERGE_STATE_UNKNOWN until positively evidenced'})</td></tr>
    </table>
    <div class='note'>$($gt.Detail)</div>
  </div>

  <div class='card'>
    <h2>M10 governed completion gate</h2>
    <div><span class='kv'>$($m10.Token)</span> <span class='note'>$($m10.Reason)</span></div>
    <ul class='prereq'>$prereqHtml</ul>
  </div>

  <div class='card'>
    <h2>Human actions</h2>
    <div class='note' style='margin-bottom:8px'>CREATE PR / REVIEW PR / MERGE PR are HUMAN-only actions (DevBridge prepares evidence; it never performs a Git action). RUN COMPLETION and RUN WORKBOOK VALIDATION are the only backend actions.</div>
    $actionRows
  </div>

  <div class='card'>
    <h2>Protected roadmap fingerprint</h2>
    <table>
      <tr><th>Fingerprint</th><td class='kv'>$(if($fp.Sha256){$fp.Sha256}else{'NOT_COMPARABLE'})</td><th>Verdict</th><td class='kv'>$($View.FingerprintVerdict)</td></tr>
      <tr><th>Protected rows</th><td>$($fp.ProtectedRows)</td><th>Protected cells</th><td>$($fp.ProtectedCells)</td></tr>
      <tr><th>Coverage</th><td colspan='3' class='mono'>$($fp.Coverage)</td></tr>
    </table>
    <div class='note'>Fingerprint = SHA-256 over protected identity+structure cells only; execution-state columns excluded. ROADMAP_STRUCTURE_WRITE_PROHIBITED blocks any write touching protected structure.</div>
  </div>

  <div class='card'>
    <h2>M11 post-completion validation</h2>
    $(if($View.M11){ if($View.M11.Pass){"<div class='note'><span class='kv'>M11_VALIDATION_PASS</span> $($View.M11.Detail)</div>"} else {"<div class='note' style='color:var(--no)'><span class='kv'>M11_VALIDATION_FAILED</span> $($View.M11.Detail)</div>"} }else{'<div class=note>Not applicable until completion evidence exists.</div>'})
    $(if($partsHtml){ "<ul class='parts'>$partsHtml</ul>" })
  </div>

  <div class='card'>
    <h2>Read-only guard</h2>
    <table>
      <tr><th>Auto execution</th><td class='kv'>$($guard.AutoExecutionEnabled)</td><th>Paid / network calls</th><td class='kv'>$($guard.PaidApiCalls) / $($guard.NetworkCalls)</td></tr>
      <tr><th>Workbook modified</th><td>$($guard.WorkbookModified)</td><th>Git modified</th><td>$($guard.GitModified)</td></tr>
      <tr><th>Automatic PR</th><td>$($guard.AutomaticPrCreated)</td><th>Automatic merge</th><td>$($guard.AutomaticMergePerformed)</td></tr>
      <tr><th>Baseline restored</th><td>$($guard.BaselineRestored)</td><th>Automatic next task</th><td>$($guard.AutomaticNextTask)</td></tr>
    </table>
    <div class='note'>$($View.Note)</div>
  </div>
</main>
</body>
</html>
"@

    [System.IO.File]::WriteAllText($OutputPath, $html, (New-Object System.Text.UTF8Encoding($false)))
    return $OutputPath
}
