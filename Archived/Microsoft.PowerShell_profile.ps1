function deepcode {
    $env:ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"
    $env:ANTHROPIC_AUTH_TOKEN="sk-575434f2f6ea4c3490aeb2b458a540ec"
    $env:ANTHROPIC_API_KEY=""

    $env:CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY="1"
    $env:CLAUDE_CODE_SKIP_FAST_MODE_ORG_CHECK="1"

    $env:ANTHROPIC_DEFAULT_SONNET_MODEL="deepseek-v4-flash"
    $env:ANTHROPIC_DEFAULT_OPUS_MODEL="deepseek-v4-flash"
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL="deepseek-v4-flash"

    claude
}

function start-dev {
    & "C:\Personal\DevTools\start-dev.ps1"
}