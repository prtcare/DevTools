# ============================================
# NEXUS DEEPCODE LAUNCHER
# ============================================

# --------------------------------------------
# 1. Load central Nexus secrets
# --------------------------------------------
. "C:\Personal\UserSecrets\Load-Secrets.ps1"


# --------------------------------------------
# 2. DeepSeek configuration
# --------------------------------------------
$env:ANTHROPIC_BASE_URL = "https://api.deepseek.com/anthropic"

$env:ANTHROPIC_AUTH_TOKEN = $env:DEEPSEEK_API_KEY
$env:ANTHROPIC_API_KEY    = $env:DEEPSEEK_API_KEY

$env:CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = "1"
$env:CLAUDE_CODE_SKIP_FAST_MODE_ORG_CHECK = "1"

$env:ANTHROPIC_DEFAULT_SONNET_MODEL = "deepseek-v4-flash"
$env:ANTHROPIC_DEFAULT_OPUS_MODEL   = "deepseek-v4-flash"
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL  = "deepseek-v4-flash"


# --------------------------------------------
# 3. IMPORTANT:
#    Stop Claude Code changing terminal title
# --------------------------------------------
$env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE = "1"


# --------------------------------------------
# 4. Check API key
# --------------------------------------------
if ([string]::IsNullOrWhiteSpace($env:DEEPSEEK_API_KEY)) {
    Write-Host ""
    Write-Host "ERROR: DEEPSEEK_API_KEY not found."
    Write-Host ""
    exit 1
}


# --------------------------------------------
# 5. Detect current repository/folder
# --------------------------------------------
$repoName = Split-Path -Leaf (Get-Location)

if ([string]::IsNullOrWhiteSpace($repoName)) {
    $repoName = "Nexus"
}


# --------------------------------------------
# 6. Build terminal title
# --------------------------------------------
$desiredTitle = "$repoName - DeepCode"


# --------------------------------------------
# 7. Set terminal title
# --------------------------------------------
$Host.UI.RawUI.WindowTitle = $desiredTitle


# --------------------------------------------
# 8. Launcher information
# --------------------------------------------
Write-Host ""
Write-Host "========================================"
Write-Host "           NEXUS DEEPCODE"
Write-Host "========================================"
Write-Host ""
Write-Host "Provider : DeepSeek"
Write-Host "Model    : deepseek-v4-flash"
Write-Host "Project  : $repoName"
Write-Host "Folder   : $PWD"
Write-Host "Title    : $desiredTitle"
Write-Host ""


# --------------------------------------------
# 9. Launch Claude Code
# --------------------------------------------
claude