# Copy-ClaudeReviewManifest.ps1 - DB-M07 COPY FOR CLAUDE backend.
#
# The governed implementation of the operator's "Copy for Claude" action in the
# NEW review model (Claude is the independent read-only reviewer of the ACTUAL
# Nexus files). At CLICK TIME it reads tasks\CLAUDE_REVIEW_PACKAGE.md FRESH and
# re-verifies - one final time - that it is the CURRENT CLAUDE REVIEW MANIFEST
# (identity lines + deterministic Manifest ID bound to the current DB-M06
# evidence + current-task dbM07 ready stamp) via Test-CrmManifestCurrent. It NEVER
# copies a stale historical packet (a leftover REVIEW_PACKET.md from a previous
# cycle is never the source).
#
# On success the current manifest text is placed on the clipboard (visible
# confirmation "COPIED FOR CLAUDE") and DB07_OUTCOME: CLAUDE_MANIFEST_COPIED is
# emitted. On any mismatch nothing is copied and DB07_OUTCOME:
# CLAUDE_REVIEW_PACKAGE_NOT_READY (DB07_RESULT_PASS: False) is emitted.
#
# Read-only: never writes the workbook, current-task state, or any repository.
# Test seam: DB07_COPY_TARGET_FILE=<path> writes the copied text to that file
# instead of the OS clipboard (so self-tests assert exact bytes without touching
# the user's clipboard). Without it the text goes to the real clipboard.
#
# Backend contract: ALWAYS exits 0; outcomes ONLY via stdout markers (DB07_*).
# State/tasks dirs redirect with DB07_STATE_DIR / DB07_TASKS_DIR.
#
# ASCII-only source (PS 5.1 + BOM-safe).
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ClaudeReviewManifestSupport.ps1")

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:StateDir = Join-Path $script:Root "state"
$script:TasksDir = Join-Path $script:Root "tasks"
if ($env:DB07_STATE_DIR) { $script:StateDir = $env:DB07_STATE_DIR }
if ($env:DB07_TASKS_DIR) { $script:TasksDir = $env:DB07_TASKS_DIR }

function Out-Markers([string]$token, [bool]$pass, [string[]]$evidence) {
    Write-Output ("DB07_OUTCOME: " + $token)
    Write-Output ("DB07_RESULT_PASS: " + $(if ($pass) { "True" } else { "False" }))
    Write-Output ("DB07_RESULT_CODE: " + $token)
    Write-Output "DB07_WORKBOOK_MODIFIED: False"
    Write-Output "DB07_NEXUS_SOURCE_MODIFIED: False"
    Write-Output "DB07_GIT_MODIFIED: False"
    Write-Output "DB07_REQUIRES_HUMAN_ACTION: False"
    Write-Output "DB07_HUMAN_ACTION_TYPE:"
    foreach ($e in $evidence) { Write-Output ("DB07_EVIDENCE: " + $e) }
    exit 0
}

$manifestPath = Join-Path $script:TasksDir "CLAUDE_REVIEW_PACKAGE.md"
$cur = Test-CrmManifestCurrent -StateDir $script:StateDir -TasksDir $script:TasksDir
if (-not $cur.Ready) {
    Out-Markers "CLAUDE_REVIEW_PACKAGE_NOT_READY" $false @("COPY FOR CLAUDE refused: " + $cur.Reason + ". A stale/historical packet is never copied.")
}

$text = [System.IO.File]::ReadAllText($cur.ManifestPath)

if ($env:DB07_COPY_TARGET_FILE) {
    [System.IO.File]::WriteAllText([string]$env:DB07_COPY_TARGET_FILE, $text, (New-Object System.Text.UTF8Encoding($false)))
} else {
    try { Set-Clipboard -Value $text -ErrorAction Stop } catch {
        # Clipboard is an STA-bound resource on some hosts; retry through an STA
        # child before giving up so the governed copy still succeeds.
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
            $null = & powershell.exe -NoProfile -STA -Command ("Set-Clipboard -Value ([System.IO.File]::ReadAllText('" + $tmp + "'))")
            if ($LASTEXITCODE -ne 0) { throw "Set-Clipboard failed in child process (exit " + $LASTEXITCODE + ")." }
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Output "COPIED FOR CLAUDE"
Out-Markers "CLAUDE_MANIFEST_COPIED" $true @("tasks/CLAUDE_REVIEW_PACKAGE.md")
