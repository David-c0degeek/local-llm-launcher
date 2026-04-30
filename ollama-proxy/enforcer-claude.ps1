# Enforcer wrapper — points claude at the local Ollama backend through the
# no-think proxy. Runs with `pwsh -NoProfile`, so it must be self-contained:
# - reads the default model key from llm-models.json
# - starts the no-think proxy on 11435 if it isn't already up
# - sets ANTHROPIC env vars and invokes claude

$ErrorActionPreference = "Stop"

$ConfigPath = if ($env:LOCAL_LLM_CONFIG) {
    $env:LOCAL_LLM_CONFIG
} else {
    Join-Path $HOME ".local-llm\llm-models.json"
}

if (-not (Test-Path $ConfigPath)) {
    Write-Error "enforcer-claude: config not found at $ConfigPath"
    exit 1
}

$cfg = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

$DefaultKey = if ($env:ENFORCER_MODEL) { $env:ENFORCER_MODEL }
              elseif ($cfg.Default)    { $cfg.Default }
              else                     { 'qcoder30' }

if (-not $cfg.Models.$DefaultKey) {
    Write-Error "enforcer-claude: model key '$DefaultKey' not found in $ConfigPath"
    exit 1
}

# Resolve the alias name (Root + default ContextKey "").
$ModelAlias = $cfg.Models.$DefaultKey.Root

$ProxyPort = if ($cfg.NoThinkProxyPort) { [int]$cfg.NoThinkProxyPort } else { 11435 }
$ProxyScript = Join-Path $HOME ".ollama-proxy\no-think-proxy.py"

function Test-ProxyAlive {
    param([int]$Port)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect("127.0.0.1", $Port)
        $tcp.Close()
        return $true
    } catch {
        return $false
    }
}

$ProxyProc = $null

if (-not (Test-ProxyAlive -Port $ProxyPort)) {
    if (-not (Test-Path $ProxyScript)) {
        Write-Error "enforcer-claude: no-think proxy script not found: $ProxyScript"
        exit 1
    }

    $ProxyProc = Start-Process python `
        -ArgumentList "`"$ProxyScript`"", $ProxyPort `
        -PassThru -WindowStyle Hidden -ErrorAction Stop

    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline -and -not (Test-ProxyAlive -Port $ProxyPort)) {
        Start-Sleep -Milliseconds 150
    }

    if (-not (Test-ProxyAlive -Port $ProxyPort)) {
        Write-Error "enforcer-claude: proxy did not come up on port $ProxyPort"
        exit 1
    }
}

$varNames = @(
    "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY",
    "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "CLAUDE_CODE_DISABLE_THINKING", "MAX_THINKING_TOKENS",
    "CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING", "CLAUDE_CODE_ATTRIBUTION_HEADER",
    "DISABLE_PROMPT_CACHING"
)
$savedVars = @{}
foreach ($v in $varNames) {
    $savedVars[$v] = [System.Environment]::GetEnvironmentVariable($v)
}

try {
    $env:ANTHROPIC_BASE_URL                = "http://localhost:$ProxyPort"
    $env:ANTHROPIC_AUTH_TOKEN              = "ollama"
    $env:ANTHROPIC_API_KEY                 = ""
    $env:ANTHROPIC_DEFAULT_OPUS_MODEL      = $ModelAlias
    $env:ANTHROPIC_DEFAULT_SONNET_MODEL    = $ModelAlias
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL     = $ModelAlias
    $env:CLAUDE_CODE_DISABLE_THINKING      = "1"
    $env:MAX_THINKING_TOKENS               = "0"
    $env:CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING = "1"
    $env:CLAUDE_CODE_ATTRIBUTION_HEADER    = "0"
    $env:DISABLE_PROMPT_CACHING            = "1"

    & claude @args
} finally {
    foreach ($v in $varNames) {
        if ($null -eq $savedVars[$v]) {
            Remove-Item -Path "Env:\$v" -ErrorAction SilentlyContinue
        } else {
            Set-Item -Path "Env:\$v" -Value $savedVars[$v]
        }
    }

    if ($ProxyProc -and -not $ProxyProc.HasExited) {
        # We started this proxy; tear it down on exit.
        try { $ProxyProc.Kill() | Out-Null } catch { }
    }
}
