# Claude Code / Unshackled launcher path. Backs up Claude env vars, points
# them at the local Ollama (or the no-think strip proxy), launches the agent,
# restores the env on exit.

$script:ClaudeEnvBackup = @{}
$script:NoThinkProxyProcess = $null

function Save-ClaudeEnvBackup {
    $script:ClaudeEnvBackup = @{}

    foreach ($name in $script:ClaudeEnvNames) {
        $script:ClaudeEnvBackup[$name] = (Get-Item "Env:$name" -ErrorAction SilentlyContinue).Value
    }
}

function Restore-ClaudeEnvBackup {
    [CmdletBinding()]
    param()

    foreach ($name in $script:ClaudeEnvNames) {
        if ($script:ClaudeEnvBackup.ContainsKey($name) -and $null -ne $script:ClaudeEnvBackup[$name] -and $script:ClaudeEnvBackup[$name] -ne "") {
            Set-Item "Env:$name" $script:ClaudeEnvBackup[$name]
        }
        else {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        }
    }

    $script:ClaudeEnvBackup = @{}
    Write-Verbose "Claude env vars restored."
}

function Set-ClaudeLocalEnv {
    # Common env-var setup for any local backend (Ollama or llama.cpp). Caller
    # is responsible for Save-ClaudeEnvBackup before and Restore-ClaudeEnvBackup
    # after. -KeepThinking leaves thinking-tokens enabled (skip the no-think
    # toggles); the caller must arrange routing accordingly.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Model,
        [bool]$KeepThinking = $false
    )

    $env:ANTHROPIC_BASE_URL = $BaseUrl
    $env:ANTHROPIC_AUTH_TOKEN = "local"
    $env:ANTHROPIC_API_KEY = ""

    $env:ANTHROPIC_MODEL = $Model
    $env:ANTHROPIC_DEFAULT_OPUS_MODEL = $Model
    $env:ANTHROPIC_DEFAULT_SONNET_MODEL = $Model
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $Model

    if (-not $KeepThinking) {
        $env:CLAUDE_CODE_DISABLE_THINKING = "1"
        $env:MAX_THINKING_TOKENS = "0"
        $env:CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING = "1"
    }

    $env:CLAUDE_CODE_ATTRIBUTION_HEADER = "0"
    $env:DISABLE_PROMPT_CACHING = "1"

    # Local models prefill slowly on big prompts; raise SDK timeout so the
    # client doesn't abort + retry mid-prefill (which restarts the work).
    $env:API_TIMEOUT_MS = "1800000"

    # Drop the auto-memory system-prompt block (and the turn-end extract
    # agent). Saves several KB of input tokens per turn — significant when
    # prefill is the bottleneck.
    $env:CLAUDE_CODE_DISABLE_AUTO_MEMORY = "1"
}

function Start-NoThinkProxy {
    if ($script:NoThinkProxyProcess -and -not $script:NoThinkProxyProcess.HasExited) {
        return
    }

    $proxyScript = Join-Path $HOME ".ollama-proxy\no-think-proxy.py"

    if (-not (Test-Path $proxyScript)) {
        Write-Warning "No-think proxy not found: $proxyScript"
        return
    }

    $script:NoThinkProxyProcess = Start-Process python `
        -ArgumentList "`"$proxyScript`"", $script:NoThinkProxyPort `
        -PassThru -WindowStyle Hidden -ErrorAction Stop

    $deadline = (Get-Date).AddSeconds(3)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 150

        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", $script:NoThinkProxyPort)
            $tcp.Close()
            break
        }
        catch {
        }
    }
}

function Stop-NoThinkProxy {
    if ($script:NoThinkProxyProcess -and -not $script:NoThinkProxyProcess.HasExited) {
        $script:NoThinkProxyProcess.Kill() | Out-Null
    }

    $script:NoThinkProxyProcess = $null
}

function Ensure-UnshackledInstalled {
    # Confirms an Unshackled checkout exists at $script:Cfg.UnshackledRoot.
    # If not, asks before cloning from $script:Cfg.UnshackledRepoUrl.
    $root = $script:Cfg.UnshackledRoot

    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "UnshackledRoot is not set. Run: Set-LocalLLMSetting UnshackledRoot '<path>'"
    }

    $cliPath = Join-Path $root "src\entrypoints\cli.tsx"

    if (Test-Path $cliPath) {
        return
    }

    $repoUrl = if (-not [string]::IsNullOrWhiteSpace($script:Cfg.UnshackledRepoUrl)) {
        $script:Cfg.UnshackledRepoUrl
    } else {
        "https://github.com/David-c0degeek/unshackled"
    }

    Write-Host ""
    Write-Host "Unshackled not found at $root" -ForegroundColor Yellow
    Write-Host "  Source: $repoUrl" -ForegroundColor DarkGray
    $answer = (Read-Host "Clone it now? [y/N]").Trim().ToLowerInvariant()

    if ($answer -notin @("y", "yes")) {
        throw "Unshackled is not installed at $root. Aborting. Override with: Set-LocalLLMSetting UnshackledRoot '<path>'"
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git is not on PATH; cannot clone Unshackled."
    }

    $parent = Split-Path -Parent $root

    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory $parent
    }

    Write-Host "Cloning $repoUrl -> $root" -ForegroundColor Cyan
    & git clone $repoUrl $root

    if ($LASTEXITCODE -ne 0) {
        throw "git clone failed for $repoUrl"
    }

    if (-not (Test-Path $cliPath)) {
        throw "Cloned but $cliPath is missing — wrong repo URL? Check Set-LocalLLMSetting UnshackledRepoUrl."
    }
}

function Invoke-UnshackledCli {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments)]
        [string[]]$CliArgs
    )

    Ensure-UnshackledInstalled

    $root = $script:Cfg.UnshackledRoot

    if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
        throw "bun is not on PATH."
    }

    $nodeModules = Join-Path $root "node_modules"

    if (-not (Test-Path $nodeModules)) {
        Write-Host "Installing Unshackled dependencies..." -ForegroundColor Cyan

        & bun install --cwd $root

        if ($LASTEXITCODE -ne 0) {
            throw "bun install failed for Unshackled"
        }
    }

    & bun (Join-Path $root "src\entrypoints\cli.tsx") @CliArgs
}

function Start-ClaudeWithOllamaModel {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [string]$Tools,
        [ValidateSet("strip", "keep")][string]$ThinkingPolicy = "strip",
        [Nullable[bool]]$IncludeInlineToolSchemas,
        [switch]$UseQ8,
        [switch]$LimitTools,
        [Alias("FreeCode", "Fc")][switch]$Unshackled,
        [switch]$SkipToolCheck
    )

    if ([string]::IsNullOrWhiteSpace($Tools)) {
        $Tools = $script:Cfg.LocalModelTools
    }

    # IncludeInlineToolSchemas controls prompt content (separate concern from
    # LimitTools, which controls the --tools CLI flag). Default to LimitTools'
    # value: limited-tool models benefit from inline schemas (smaller curated
    # set, fewer ToolSearch roundtrips); full-tool launches let the model use
    # ToolSearch normally.
    if ($null -eq $IncludeInlineToolSchemas) {
        $IncludeInlineToolSchemas = [bool]$LimitTools
    }

    Stop-OllamaModels
    Stop-OllamaApp
    Reset-OllamaEnv
    Set-OllamaRuntimeEnv -UseQ8:$UseQ8
    Start-OllamaApp
    Wait-Ollama

    if (-not (Test-OllamaVersionMinimum -MinVersion $script:Cfg.MinOllamaVersion)) {
        $raw = & ollama --version 2>$null

        Write-Host ""
        Write-Host "ERROR: Ollama version < $($script:Cfg.MinOllamaVersion)." -ForegroundColor Red
        Write-Host "Installed: $raw" -ForegroundColor Red
        Write-Host "Update with: winget upgrade Ollama.Ollama" -ForegroundColor Yellow
        Write-Host ""

        return
    }

    if ($script:Cfg.RequireAdvertisedTools -and -not $SkipToolCheck -and -not (Test-OllamaModelSupportsTools -ModelName $Model)) {
        Write-Host ""
        Write-Host "ERROR: $Model does not advertise tool support." -ForegroundColor Red
        Write-Host "Run: ollama show $Model" -ForegroundColor Yellow
        Write-Host "Temporary bypass: Start-ClaudeWithOllamaModel -Model $Model -SkipToolCheck" -ForegroundColor Yellow
        Write-Host "Or set RequireAdvertisedTools=false in llm-models.json." -ForegroundColor Yellow
        Write-Host ""

        return
    }

    $keepThinking = ($ThinkingPolicy -eq "keep")

    if (-not $keepThinking) {
        Start-NoThinkProxy
    }

    Save-ClaudeEnvBackup

    try {
        $baseUrl = if ($keepThinking) {
            # Skip the strip proxy and let thinking blocks reach Ollama directly.
            "http://localhost:11434"
        } else {
            "http://localhost:$($script:NoThinkProxyPort)"
        }

        Set-ClaudeLocalEnv -BaseUrl $baseUrl -Model $Model -KeepThinking $keepThinking
        $env:ANTHROPIC_AUTH_TOKEN = "ollama"

        $backendLabel = if ($Unshackled) { "unshackled" } else { "claude" }
        $toolsLabel = if ($LimitTools) { "limited" } else { "all" }
        $thinkingLabel = if ($keepThinking) { "kept (direct to Ollama)" } else { "disabled" }

        Write-Host ""
        Write-Host "Launching $backendLabel with $Model via Ollama..." -ForegroundColor Cyan
        Write-Host "  Base URL : $($env:ANTHROPIC_BASE_URL)" -ForegroundColor DarkGray
        Write-Host "  Model    : $Model" -ForegroundColor DarkGray
        Write-Host "  Thinking : $thinkingLabel" -ForegroundColor DarkGray
        Write-Host "  Tools    : $toolsLabel" -ForegroundColor DarkGray
        Write-Host ""

        $systemPrompt = Get-LocalModelSystemPrompt -IncludeInlineToolSchemas:$IncludeInlineToolSchemas

        $launchArgs = if ($LimitTools) {
            @(
                '--dangerously-skip-permissions',
                '--tools',
                $Tools,
                '--append-system-prompt',
                $systemPrompt
            )
        }
        else {
            @(
                '--dangerously-skip-permissions',
                '--append-system-prompt',
                $systemPrompt
            )
        }

        if ($Unshackled) {
            Invoke-UnshackledCli @launchArgs
        }
        else {
            & claude --model $Model @launchArgs
        }
    }
    finally {
        Restore-ClaudeEnvBackup

        if (-not $keepThinking) {
            Stop-NoThinkProxy
        }
    }
}

function Start-OllamaChat {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [switch]$UseQ8
    )

    Stop-OllamaModels
    Stop-OllamaApp
    Reset-OllamaEnv
    Set-OllamaRuntimeEnv -UseQ8:$UseQ8
    Start-OllamaApp
    Wait-Ollama

    Write-Host "Launching ollama run with $Model..." -ForegroundColor Cyan
    & ollama run $Model
}

function Get-ClaudeTargetSummary {
    if ($env:ANTHROPIC_DEFAULT_OPUS_MODEL) {
        return "Local -> $($env:ANTHROPIC_DEFAULT_OPUS_MODEL) @ $($env:ANTHROPIC_BASE_URL)"
    }

    return "Default (Anthropic API)"
}

function Start-ClaudeWithLlamaCppModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][ValidateSet('native', 'turboquant')][string]$Mode,
        [string]$KvCacheK,
        [string]$KvCacheV,
        [string]$Tools,
        [Nullable[bool]]$IncludeInlineToolSchemas,
        [switch]$LimitTools,
        [Alias("FreeCode", "Fc")][switch]$Unshackled,
        [switch]$Strict,
        [string[]]$ExtraArgs
    )

    $def = Get-ModelDef -Key $Key

    if ($def.SourceType -ne 'gguf') {
        throw "Model '$Key' has SourceType=$($def.SourceType); llama.cpp only supports gguf-source models."
    }

    if ([string]::IsNullOrWhiteSpace($Tools)) {
        $Tools = $script:Cfg.LocalModelTools
    }

    if ($null -eq $IncludeInlineToolSchemas) {
        $IncludeInlineToolSchemas = [bool]$LimitTools
    }

    # Avoid double-loading on a single GPU unless the user opted into coexistence.
    $coexist = if ($script:Cfg.Contains('LlamaCppCoexistOllama')) { [bool]$script:Cfg.LlamaCppCoexistOllama } else { $false }
    if (-not $coexist) {
        Stop-OllamaModels
        Stop-OllamaApp
    }

    # Stop any prior llama-server we own.
    Stop-LlamaServer -Quiet

    # Resolve GGUF (downloads on demand; reuses Ollama copy when available).
    $ggufPath = Get-ModelGgufPath -Key $Key -Def $def -Backend llamacpp

    # Pick a free port from the configured default.
    $defaultPort = if ($script:Cfg.Contains('LlamaCppPort')) { [int]$script:Cfg.LlamaCppPort } else { 8080 }
    $port = Find-LlamaCppFreePort -StartPort $defaultPort

    # Both modes are native processes — same path semantics.
    $modelArgPath = $ggufPath

    $thinkingPolicy = if ($def.Contains('ThinkingPolicy') -and -not [string]::IsNullOrWhiteSpace($def.ThinkingPolicy)) { [string]$def.ThinkingPolicy } else { 'strip' }

    $serverArgs = Build-LlamaServerArgs `
        -Def $def `
        -ContextKey $ContextKey `
        -Mode $Mode `
        -ModelArgPath $modelArgPath `
        -Port $port `
        -KvK $KvCacheK `
        -KvV $KvCacheV `
        -ThinkingPolicy $thinkingPolicy `
        -Strict:$Strict `
        -ExtraArgs $ExtraArgs

    # Resolve the server binary based on mode (upstream vs turboquant fork).
    $serverPath = if ($Mode -eq 'turboquant') {
        Ensure-LlamaServerTurboquant
    } else {
        Ensure-LlamaServerNative
    }

    $proc = Start-LlamaServerNative -ServerPath $serverPath -ServerArgs $serverArgs

    $session = @{
        Backend  = 'llamacpp'
        Mode     = $Mode
        Port     = $port
        BaseUrl  = "http://localhost:$port"
        Model    = $def.Root
        GgufPath = $ggufPath
        Pid      = $proc.Id
    }

    Set-CurrentBackendSession -Session $session

    try {
        Wait-LlamaServer -Port $port
    }
    catch {
        Stop-LlamaServer -Quiet
        throw
    }

    Save-ClaudeEnvBackup

    try {
        Set-ClaudeLocalEnv -BaseUrl "http://localhost:$port" -Model $def.Root -KeepThinking $false

        $backendLabel = if ($Unshackled) { "unshackled" } else { "claude" }
        $toolsLabel = if ($LimitTools) { "limited" } else { "all" }

        Write-Host ""
        Write-Host "Launching $backendLabel with $($def.Root) via llama.cpp ($Mode)..." -ForegroundColor Cyan
        Write-Host "  Base URL : $($session.BaseUrl)" -ForegroundColor DarkGray
        Write-Host "  Model    : $($def.Root)" -ForegroundColor DarkGray
        Write-Host "  GGUF     : $ggufPath" -ForegroundColor DarkGray
        Write-Host "  Port     : $port" -ForegroundColor DarkGray
        Write-Host "  Tools    : $toolsLabel" -ForegroundColor DarkGray
        Write-Host "  Strict   : $([bool]$Strict)" -ForegroundColor DarkGray
        Write-Host ""

        $systemPrompt = Get-LocalModelSystemPrompt -IncludeInlineToolSchemas:$IncludeInlineToolSchemas

        $launchArgs = if ($LimitTools) {
            @(
                '--dangerously-skip-permissions',
                '--tools',
                $Tools,
                '--append-system-prompt',
                $systemPrompt
            )
        }
        else {
            @(
                '--dangerously-skip-permissions',
                '--append-system-prompt',
                $systemPrompt
            )
        }

        if ($Unshackled) {
            Invoke-UnshackledCli @launchArgs
        }
        else {
            & claude --model $def.Root @launchArgs
        }
    }
    finally {
        Restore-ClaudeEnvBackup
        Stop-LlamaServer
    }
}
