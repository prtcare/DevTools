# RecoveryRender.ps1 -- DB-M32 operator recovery panel HTML renderer.
#
# Consumes RecoveryContracts.ps1 + RecoveryEngine.ps1. Self-contained HTML
# (UTF-8, no BOM, written ONLY via WriteAllText when the operator requests the
# artifact). Presents SYSTEM RECOVERY STATUS / LAST OPERATION / EXPECTED STATE /
# OBSERVED STATE / RECOVERY CLASSIFICATION / RECOMMENDED HUMAN ACTION -- never a
# generic "something went wrong". The rendered page is a guide: it performs no
# recovery action, no Git action, no workbook write, no lock change.

Set-StrictMode -Version Latest

function ConvertTo-DbM32Html {
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

function Export-DbM32EssentialSafetyHtml {
    <#
    .SYNOPSIS
    Render the operator recovery panel. Deterministic given a view. Writes the
    HTML via WriteAllText (UTF-8, no BOM) ONLY to the operator-requested path; no
    other write exists in the renderer.
    #>
    param(
        [AllowNull()][object]$View,
        [string]$OutputPath
    )
    if ($null -eq $View) { $View = [pscustomobject]@{ Error = 'No view supplied' } }
    if (-not $OutputPath) { throw 'OutputPath is required for the HTML artifact' }
    $dir = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $leak = Test-DbM32SecretLeak -Target $View
    if ($leak.Leak) { throw 'Render blocked: secret-like value present in the view; nothing rendered.' }

    $status = [string]$View.RecoveryStatus
    $class = [string]$View.Classification.Classification
    $action = [string]$View.Classification.RecommendedAction
    $detail = [string]$View.Classification.Detail
    $last = $View.LastOperation
    $tokenList = if ($View.Tokens.Count -gt 0) { ($View.Tokens -join ', ') } else { 'NONE' }

    $badgeClass = switch ($status) {
        'OK' { 'ok' }
        'STALE' { 'stale' }
        'AMBIGUOUS' { 'ambiguous' }
        default { 'attention' }
    }

    # ---- pre-escape every interpolated value into simple variables ----------
    $eViewId = ConvertTo-DbM32Html $View.ViewId
    $eNow = ConvertTo-DbM32Html $View.GeneratedAtUtc
    $eLastCommand = ConvertTo-DbM32Html $(if ($last) { $last.Command } else { 'NONE' })
    $eLastStamp = ConvertTo-DbM32Html $(if ($last) { $last.TimestampUtc } else { '' })
    $eExpected = ConvertTo-DbM32Html $View.ExpectedStateText
    $eObserved = ConvertTo-DbM32Html $View.ObservedStateText
    $eDetail = ConvertTo-DbM32Html $detail
    $eVerdict = ConvertTo-DbM32Html $View.Workbook.Verdict
    $eLock = ConvertTo-DbM32Html $View.Lock.State
    $eIdentity = ConvertTo-DbM32Html $View.Identity

    # ---- config rows (redacted: enabled / configured booleans only) ----------
    $configRows = ''
    foreach ($r in @($View.Config)) {
        $enabled = if ($r.Enabled) { 'ENABLED' } else { 'DISABLED' }
        $configured = if ($r.Configured) { 'CONFIGURED' } else { 'NOT_CONFIGURED' }
        $configRows += "<tr><td>$($r.Kind)</td><td>$(ConvertTo-DbM32Html $r.Id)</td><td>$enabled</td><td>$configured</td></tr>"
    }

    # ---- diagnostics rows ----------
    $diagRows = ''
    foreach ($d in @($View.Diagnostics)) {
        $diagRows += "<tr><td>$($d.Key)</td><td>$(ConvertTo-DbM32Html $d.Value)</td></tr>"
    }

    # ---- warnings ----------
    $warnBlock = ''
    if ($View.Warnings.Count -gt 0) {
        $warnList = ''
        foreach ($w in @($View.Warnings)) { $warnList += "<li>$(ConvertTo-DbM32Html $w)</li>" }
        $warnBlock = "<div class='warn'><strong>Warnings:</strong><ul>$warnList</ul></div>"
    }

    $html = @"
<title>DB-M32 Operator Recovery Panel</title>
<style>
body{font-family:'Segoe UI',system-ui,sans-serif;margin:0;background:#f5f6f8;color:#1c2733;line-height:1.45}
.wrap{max-width:1080px;margin:0 auto;padding:28px 24px}
h1{font-size:20px;margin:0 0 4px}
h2{font-size:15px;margin:28px 0 8px;color:#33465c}
.sub{color:#5c6b7a;font-size:13px;margin-bottom:18px}
.badge{display:inline-block;padding:4px 12px;border-radius:12px;font-weight:600;font-size:13px;color:#fff}
.badge.ok{background:#1f8a4c}.badge.stale{background:#b5700a}.badge.ambiguous{background:#9a3b9a}.badge.attention{background:#c0392b}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:12px;margin-top:16px}
.card{background:#fff;border:1px solid #dfe5ec;border-radius:8px;padding:14px 16px;box-shadow:0 1px 2px rgba(0,0,0,.04)}
.card h3{margin:0 0 6px;font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:#6a7a8c}
.card .val{font-size:14px;font-weight:600;word-break:break-word}
.classif{background:#fff;border:1px solid #dfe5ec;border-radius:8px;padding:16px;margin-top:12px}
.classif .big{font-size:18px;font-weight:700}
.action{color:#b0392b;font-weight:600}
.warn{background:#fff6e8;border:1px solid #f0d9b0;border-radius:8px;padding:10px 14px;margin-top:12px;font-size:13px}
table{width:100%;border-collapse:collapse;margin-top:8px;background:#fff}
th,td{border:1px solid #e2e8f0;padding:6px 10px;text-align:left;font-size:13px}
th{background:#eef2f6;color:#33465c}
.foot{color:#6a7a8c;font-size:12px;margin-top:24px}
</style>
<div class='wrap'>
  <h1>DB-M32 Operator Recovery Panel</h1>
  <div class='sub'>ESSENTIAL SAFETY, RECOVERY &amp; OPERATIONAL HARDENING &mdash; view $eViewId &mdash; $eNow</div>
  <span class='badge $badgeClass'>SYSTEM RECOVERY STATUS: $status</span>

  <div class='cards'>
    <div class='card'><h3>LAST OPERATION</h3><div class='val'>$eLastCommand</div><div style='font-size:12px;color:#6a7a8c'>$eLastStamp</div></div>
    <div class='card'><h3>EXPECTED STATE</h3><div class='val'>$eExpected</div></div>
    <div class='card'><h3>OBSERVED STATE</h3><div class='val'>$eObserved</div></div>
  </div>

  <div class='classif'>
    <div class='sub' style='margin-bottom:4px'>RECOVERY CLASSIFICATION</div>
    <div class='big'>$class</div>
    <div style='margin-top:6px'>RECOMMENDED HUMAN ACTION: <span class='action'>$action</span></div>
    <div style='margin-top:6px;font-size:13px;color:#33465c'>$eDetail</div>
    <div style='margin-top:6px;font-size:13px;color:#6a7a8c'>Interrupted-operation tokens: $tokenList &mdash; Workbook verdict: $eVerdict &mdash; Writer lock: $eLock &mdash; Operation identity: $eIdentity</div>
  </div>

  $warnBlock

  <h2>Diagnostics (essential logging)</h2>
  <table><tr><th>Field</th><th>Value</th></tr>$diagRows</table>

  <h2>Provider / routing configuration (secret-redacted)</h2>
  <table><tr><th>Kind</th><th>Id</th><th>Enabled</th><th>Configured</th></tr>$configRows</table>

  <div class='foot'>DevBridge DB-M32 is a READ-ONLY observation, classification &amp; guidance engine. It never rolls back,
  never restores a baseline, never deletes a writer lock, never writes the workbook, and never infers remote Git state.
  Recovery PREPARES GUIDANCE only; the human decides and acts. AUTO_EXECUTION_ENABLED = False.</div>
</div>
"@

    [System.IO.File]::WriteAllText($OutputPath, $html, (New-Object System.Text.UTF8Encoding($false)))
    return $true
}
