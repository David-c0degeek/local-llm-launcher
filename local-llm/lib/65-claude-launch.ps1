# Claude Code / Unshackled launcher path. Backs up Claude env vars, points
# them at the local Ollama (or the no-think strip proxy), launches the agent,
# restores the env on exit.

$script:ClaudeEnvBackup = @{}
$script:NoThinkProxyProcess = $null

function Get-NoThinkProxyHealth {
    param([Parameter(Mandatory = $true)][int]$Port)

    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 1 -ErrorAction Stop
        $content = [string]$response.Content
        try {
            return ($content | ConvertFrom-Json -AsHashtable)
        }
        catch {
            return @{ status = $content }
        }
    }
    catch {
        return $null
    }
}

function Test-NoThinkProxyTarget {
    param(
        [Parameter(Mandatory = $true)][int]$ListenPort,
        [Parameter(Mandatory = $true)][string]$TargetHost,
        [Parameter(Mandatory = $true)][int]$TargetPort
    )

    $health = Get-NoThinkProxyHealth -Port $ListenPort
    if (-not $health) { return $null }

    $healthHost = if ($health.Contains('target_host')) { [string]$health.target_host } else { '' }
    $healthPort = if ($health.Contains('target_port')) { try { [int]$health.target_port } catch { 0 } } else { 0 }

    if ($healthHost -eq $TargetHost -and $healthPort -eq $TargetPort) {
        return $true
    }

    return $false
}

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
    Write-LaunchLog "Claude env vars restored." 'INFO'
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
        [bool]$KeepThinking = $false,
        [int]$ContextTokens = 0
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
    $maxOutputTokens = if ($script:Cfg.Contains("LocalModelMaxOutputTokens")) {
        try { [int]$script:Cfg.LocalModelMaxOutputTokens } catch { 4096 }
    } else {
        4096
    }
    if ($maxOutputTokens -gt 0) {
        $env:CLAUDE_CODE_MAX_OUTPUT_TOKENS = [string]$maxOutputTokens
    }
    if ($ContextTokens -gt 0) {
        $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = [string]$ContextTokens
        $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = [string]$ContextTokens
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
    # Backend default is Ollama (11434). Pass -TargetPort 8080 (or whatever)
    # to put the proxy in front of llama-server instead. The proxy strips
    # Anthropic thinking-config from requests and <think>...</think> blocks
    # from /v1/messages responses (SSE + non-streaming), which keeps reasoning
    # models from leaking <think> tags into the conversation or breaking
    # consumers that JSON.parse the response body.
    param(
        [int]$TargetPort = 11434,
        [string]$TargetHost = "127.0.0.1"
    )

    $target = "${TargetHost}:${TargetPort}"
    Write-LaunchLog "No-think proxy: target=$target port=$($script:NoThinkProxyPort)" 'PROXY'
    $targetMatches = Test-NoThinkProxyTarget -ListenPort $script:NoThinkProxyPort -TargetHost $TargetHost -TargetPort $TargetPort
    if ($targetMatches -eq $true) {
        Write-LaunchLog "No-think proxy already running for target=$target" 'PROXY'
        return
    }
    if ($targetMatches -eq $false) {
        throw "No-think proxy port $($script:NoThinkProxyPort) is already in use by a proxy for a different or unverifiable target. Stop that process or change NoThinkProxyPort."
    }

    $proxyScript = Join-Path $HOME ".ollama-proxy\no-think-proxy.py"

    if ($script:NoThinkProxyProcess -and -not $script:NoThinkProxyProcess.HasExited) {
        Write-LaunchLog "Reusing existing no-think proxy process (PID=$($script:NoThinkProxyProcess.Id))" 'PROXY'
        return
    }

    Write-LaunchLog "Starting no-think proxy: python $proxyScript $port $target" 'PROXY'

    if (-not (Test-Path $proxyScript)) {
        throw "No-think proxy not found: $proxyScript. Re-run install.ps1 so Claude/Unshackled launches do not point at a dead proxy URL."
    }

    $script:NoThinkProxyProcess = Start-Process python `
        -ArgumentList "`"$proxyScript`"", $script:NoThinkProxyPort, $target `
        -PassThru -WindowStyle Hidden -ErrorAction Stop

    $deadline = (Get-Date).AddSeconds(3)
    $ready = $false

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 150

        $targetMatches = Test-NoThinkProxyTarget -ListenPort $script:NoThinkProxyPort -TargetHost $TargetHost -TargetPort $TargetPort
        if ($targetMatches -eq $true) {
            $ready = $true
            break
        }
    }

    if (-not $ready) {
        Stop-NoThinkProxy
        throw "No-think proxy did not become ready on 127.0.0.1:$($script:NoThinkProxyPort) for target $target."
    }
}

function Stop-NoThinkProxy {
    if ($script:NoThinkProxyProcess -and -not $script:NoThinkProxyProcess.HasExited) {
        $script:NoThinkProxyProcess.Kill() | Out-Null
    }

    $script:NoThinkProxyProcess = $null
}

function Test-ClaudeLocalVisibleResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Model,
        [string]$SystemPrompt,
        [int]$TimeoutSec = 90
    )

    $payload = @{
        model = $Model
        max_tokens = 32
        stream = $false
        messages = @(
            @{
                role = 'user'
                content = 'Are you working? Reply with a short visible acknowledgement.'
            }
        )
    }
    if (-not [string]::IsNullOrWhiteSpace($SystemPrompt)) {
        $payload.system = $SystemPrompt
    }
    $body = $payload | ConvertTo-Json -Depth 8 -Compress

    try {
        $resp = Invoke-RestMethod `
            -Uri "$BaseUrl/v1/messages" `
            -Method Post `
            -Headers @{ 'anthropic-version' = '2023-06-01'; 'x-api-key' = 'local' } `
            -ContentType 'application/json' `
            -Body $body `
            -TimeoutSec $TimeoutSec
    }
    catch {
        return [pscustomobject]@{
            Ok = $false
            Text = ''
            Error = $_.Exception.Message
        }
    }

    $parts = New-Object System.Collections.Generic.List[string]
    if ($resp -and $resp.content) {
        foreach ($block in @($resp.content)) {
            if ($block -is [string]) {
                $parts.Add($block) | Out-Null
                continue
            }
            $prop = $block.PSObject.Properties['text']
            if ($prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
                $parts.Add([string]$prop.Value) | Out-Null
            }
        }
    }

    $text = (($parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join '').Trim()
    $withoutThink = [regex]::Replace($text, '(?is)<think>.*?</think>', '')
    $withoutThink = [regex]::Replace($withoutThink, '(?is)<think>.*$', '').Trim()
    $looksAnswered = -not [string]::IsNullOrWhiteSpace($withoutThink)
    return [pscustomobject]@{
        Ok = $looksAnswered
        Text = $text
        VisibleText = $withoutThink
        Error = $(if ($looksAnswered) { '' } elseif ([string]::IsNullOrWhiteSpace($text)) { 'no response text' } else { 'no visible response text after stripping thinking output' })
    }
}

function Format-ClaudeLocalSmokeFailure {
    param([Parameter(Mandatory = $true)]$Smoke)

    if (-not [string]::IsNullOrWhiteSpace($Smoke.Error)) {
        return [string]$Smoke.Error
    }

    $snippet = if (-not [string]::IsNullOrWhiteSpace($Smoke.VisibleText)) {
        [string]$Smoke.VisibleText
    } elseif (-not [string]::IsNullOrWhiteSpace($Smoke.Text)) {
        [string]$Smoke.Text
    } else {
        ''
    }
    $snippet = ($snippet -replace '\s+', ' ').Trim()
    if ($snippet.Length -gt 160) {
        $snippet = $snippet.Substring(0, 160) + '...'
    }
    if (-not [string]::IsNullOrWhiteSpace($snippet)) {
        return "unexpected smoke response: $snippet"
    }

    return 'no visible response text'
}

function Ensure-UnshackledInstalled {
    # Confirms an Unshackled checkout exists at $script:Cfg.UnshackledRoot.
    # If not, asks before cloning from $script:Cfg.UnshackledRepoUrl.
    $root = $script:Cfg.UnshackledRoot

    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "UnshackledRoot is not set. Run: Set-LocalLLMSetting UnshackledRoot '<path>'"
    }

    $cliPath = try {
        Join-Path $root "src\entrypoints\cli.tsx"
    }
    catch {
        throw "UnshackledRoot is not accessible: $root. Run: Set-LocalLLMSetting UnshackledRoot '<path>'"
    }

    if (Test-Path -LiteralPath $cliPath -PathType Leaf -ErrorAction SilentlyContinue) {
        return
    }

    $qualifier = Split-Path -Qualifier $root
    if (-not [string]::IsNullOrWhiteSpace($qualifier) -and -not (Test-Path -LiteralPath $qualifier -ErrorAction SilentlyContinue)) {
        throw "UnshackledRoot points at an unavailable drive or path: $root. Run: Set-LocalLLMSetting UnshackledRoot '<path>'"
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

function Install-Unshackled {
    [CmdletBinding()]
    param(
        [string]$Destination = (Join-Path $HOME '.local-llm\tools\unshackled'),
        [switch]$Force
    )

    if ((Test-Path -LiteralPath (Join-Path $Destination 'src\entrypoints\cli.tsx')) -and -not $Force) {
        Write-Host "Unshackled already exists: $Destination" -ForegroundColor Green
        Set-LocalLLMSetting UnshackledRoot $Destination
        return $Destination
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git is not on PATH; cannot clone Unshackled."
    }

    $repoUrl = if (-not [string]::IsNullOrWhiteSpace($script:Cfg.UnshackledRepoUrl)) {
        [string]$script:Cfg.UnshackledRepoUrl
    } else {
        'https://github.com/David-c0degeek/unshackled'
    }

    Ensure-Directory (Split-Path -Parent $Destination)
    if (Test-Path -LiteralPath $Destination) {
        throw "Destination already exists: $Destination. Use Update-Unshackled, or remove it and retry."
    }

    & git clone $repoUrl $Destination
    if ($LASTEXITCODE -ne 0) { throw "git clone failed for $repoUrl" }

    Set-LocalLLMSetting UnshackledRoot $Destination
    return $Destination
}

function Update-Unshackled {
    [CmdletBinding()]
    param()

    $root = if (Get-Command Resolve-UnshackledRoot -ErrorAction SilentlyContinue) {
        Resolve-UnshackledRoot
    } else {
        $script:Cfg.UnshackledRoot
    }

    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) {
        throw "Unshackled is not installed. Run Install-Unshackled first."
    }

    $result = Invoke-LocalLLMGitFastForwardUpdate -Name 'Unshackled' -Root $root
    if ($result.Status -in @('failed', 'not-git', 'no-upstream', 'diverged')) {
        throw $result.Reason
    }
    return $result
}

function Get-UnshackledExtraArgs {
    # Merges the -ExtraUnshackledArgs param with $env:UNSHACKLED_EXTRA_ARGS.
    # Env-var splitting is whitespace-only — sufficient for flags like `-D` or
    # `-D --debug-file=path`. For values containing spaces, pass via param.
    param([string[]]$Param)

    $extras = @()
    if ($env:UNSHACKLED_EXTRA_ARGS) {
        $extras += ($env:UNSHACKLED_EXTRA_ARGS -split '\s+' | Where-Object { $_ })
    }
    if ($Param) { $extras += $Param }
    return ,$extras
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

function ConvertTo-CodexTomlString {
    param([AllowEmptyString()][string]$Value)

    $escaped = ([string]$Value) -replace '\\', '\\' -replace '"', '\"'
    return '"' + $escaped + '"'
}

function Get-CodexCommonArgs {
    $args = @()

    if ($script:Cfg.Contains("CodexEnableSearch") -and [bool]$script:Cfg.CodexEnableSearch) {
        $args += '--search'
    }

    $bypass = if ($script:Cfg.Contains("CodexBypassApprovalsAndSandbox")) {
        [bool]$script:Cfg.CodexBypassApprovalsAndSandbox
    } else {
        $true
    }
    if ($bypass) {
        $args += '--dangerously-bypass-approvals-and-sandbox'
    }

    return $args
}

function Start-CodexCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [string]$BaseUrl,
        [int]$ContextTokens,
        [int]$MaxOutputTokens
    )

    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
        throw "codex is not on PATH. Install with: npm install -g @openai/codex"
    }

    $args = @()

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        $args += @('--oss', '--local-provider', 'ollama')
    } else {
        $providerId = 'localbox_llamacpp'
        $idleMs = if ($script:Cfg.Contains("CodexStreamIdleTimeoutMs")) {
            try { [int]$script:Cfg.CodexStreamIdleTimeoutMs } catch { 10000000 }
        } else {
            10000000
        }

        $args += @(
            '-c', ('model_provider={0}' -f (ConvertTo-CodexTomlString $providerId)),
            '-c', ('model_providers.{0}.name={1}' -f $providerId, (ConvertTo-CodexTomlString 'LocalBox llama.cpp')),
            '-c', ('model_providers.{0}.base_url={1}' -f $providerId, (ConvertTo-CodexTomlString $BaseUrl)),
            '-c', ('model_providers.{0}.wire_api="responses"' -f $providerId),
            '-c', ('model_providers.{0}.stream_idle_timeout_ms={1}' -f $providerId, $idleMs)
        )
    }

    if ($ContextTokens -gt 0) {
        $args += @('-c', "model_context_window=$ContextTokens")
    }
    if ($MaxOutputTokens -gt 0) {
        $args += @('-c', "model_max_output_tokens=$MaxOutputTokens")
    }

    $args += @('--model', $Model)
    $args += @(Get-CodexCommonArgs)

    Write-Host ""
    Write-Host "Launching codex with $Model..." -ForegroundColor Cyan
    if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
        Write-Host "  Base URL : $BaseUrl" -ForegroundColor DarkGray
    } else {
        Write-Host "  Provider : Ollama local provider" -ForegroundColor DarkGray
    }
    Write-Host "  Model    : $Model" -ForegroundColor DarkGray
    Write-Host ""

    & codex @args
}

function Start-ClaudeWithOllamaModel {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [string]$Tools,
        [ValidateSet("strip", "keep")][string]$ThinkingPolicy = "strip",
        [Nullable[bool]]$IncludeInlineToolSchemas,
        [switch]$UseQ8,
        [switch]$LimitTools,
        [switch]$Unshackled,
        [switch]$Codex,
        [switch]$SkipToolCheck,
        [string[]]$ExtraUnshackledArgs,
        [switch]$DryRun
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

    if ($DryRun) {
        $keepThinking = ($ThinkingPolicy -eq 'keep')
        $baseUrl = if ($keepThinking) {
            'http://localhost:11434'
        } else {
            "http://localhost:$($script:NoThinkProxyPort)"
        }

        $systemPrompt = Get-LocalModelSystemPrompt -IncludeInlineToolSchemas:$IncludeInlineToolSchemas

        $launchArgs = if ($LimitTools) {
            @('--dangerously-skip-permissions', '--tools', $Tools, '--append-system-prompt', $systemPrompt)
        }
        else {
            @('--dangerously-skip-permissions', '--append-system-prompt', $systemPrompt)
        }

        $title = if ($Codex) {
            'codex via Ollama'
        } elseif ($Unshackled) {
            'unshackled via Ollama'
        } else {
            'claude via Ollama'
        }

        $env = if ($Codex) {
            [ordered]@{}
        } else {
            Get-LocalLLMClaudeEnvSnapshot -BaseUrl $baseUrl -Model $Model -KeepThinking $keepThinking -AuthToken 'ollama'
        }

        $launchExe = if ($Unshackled) { 'unshackled' } elseif ($Codex) { 'codex' } else { 'claude' }
        $launchExeArgs = if ($Codex) {
            @()
        } elseif ($Unshackled) {
            @($launchArgs)
        } else {
            @('--model', $Model) + $launchArgs
        }

        $thinkingLabel = if ($keepThinking) {
            'kept (direct to Ollama)'
        } else {
            "stripped via no-think-proxy:$($script:NoThinkProxyPort)"
        }

        $toolsLabel = if ($LimitTools) { "limited ($Tools)" } else { 'all' }
        $kvNote = "Ollama backend would restart with OLLAMA_KV_CACHE_TYPE=$(if ($UseQ8) { 'q8_0' } else { 'default' })"

        $plan = @{
            Title       = $title
            Backend     = 'ollama'
            Model       = $Model
            BaseUrl     = $baseUrl
            HealthCheck = 'http://localhost:11434/api/tags'
            Tools       = $toolsLabel
            Thinking    = $thinkingLabel
            Env         = $env
            LaunchExe   = $launchExe
            LaunchArgs  = $launchExeArgs
            Notes       = @($kvNote)
        }

        Show-LocalLLMLaunchPlan -Plan $plan
        return
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

    if ($Codex) {
        Start-CodexCli -Model $Model
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
        Write-Host "Launching ${$backendLabel} with $Model via Ollama..." -ForegroundColor Cyan
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
            $extras = Get-UnshackledExtraArgs -Param $ExtraUnshackledArgs
            Invoke-UnshackledCli @launchArgs @extras
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
        [switch]$UseQ8,
        [switch]$DryRun
    )

    if ($DryRun) {
        $kvNote = "Ollama backend would restart with OLLAMA_KV_CACHE_TYPE=$(if ($UseQ8) { 'q8_0' } else { 'default' })"
        $plan = @{
            Title      = 'ollama chat (REPL)'
            Backend    = 'ollama'
            Model      = $Model
            BaseUrl    = 'http://localhost:11434'
            LaunchExe  = 'ollama'
            LaunchArgs = @('run', $Model)
            Notes      = @($kvNote)
        }
        Show-LocalLLMLaunchPlan -Plan $plan
        return
    }

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
        [switch]$Unshackled,
        [switch]$Codex,
        [switch]$Strict,
        [switch]$UseVision,
        [switch]$AutoBest,
        [switch]$AutoBestStrict,
        [ValidateSet('auto','pure','balanced','short','long')][string]$AutoBestProfile = 'auto',
        [string[]]$ExtraArgs,
        [string[]]$ExtraUnshackledArgs,
        [switch]$DryRun
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
    if (-not $DryRun -and -not $coexist) {
        Stop-OllamaModels
        Stop-OllamaApp
    }

    # Stop any prior llama-server we own.
    if (-not $DryRun) {
        Stop-LlamaServer -Quiet
    }

    # Resolve GGUF. Real launch downloads on demand and reuses an Ollama copy
    # when available; DryRun only inspects the expected path so we don't pull
    # gigabytes for a preview.
    $dryRunGgufNote = $null
    if ($DryRun) {
        $folder = Join-Path $script:Cfg.LlamaCppGgufRoot $def.Root
        $fileName = Get-ModelFileName -Def $def
        $ggufPath = Resolve-HuggingFaceLocalPath -DestinationFolder $folder -FileName $fileName
        if (-not (Test-Path -LiteralPath $ggufPath)) {
            $dryRunGgufNote = "GGUF not present locally; a real launch would download from $($def.Repo)/$fileName"
        }
    }
    else {
        $ggufPath = Get-ModelGgufPath -Key $Key -Def $def -Backend llamacpp
    }

    # Pick a free port from the configured default.
    $defaultPort = if ($script:Cfg.Contains('LlamaCppPort')) { [int]$script:Cfg.LlamaCppPort } else { 8080 }
    $port = Find-LlamaCppFreePort -StartPort $defaultPort

    # Both modes are native processes — same path semantics.
    $modelArgPath = $ggufPath

    $thinkingPolicy = if ($def.Contains('ThinkingPolicy') -and -not [string]::IsNullOrWhiteSpace($def.ThinkingPolicy)) { [string]$def.ThinkingPolicy } else { 'strip' }
    $agentParallel = if ($script:Cfg.Contains('LlamaCppAgentParallel')) {
        try { [int]$script:Cfg.LlamaCppAgentParallel } catch { 1 }
    } else {
        1
    }
    $agentCacheReuse = if ($script:Cfg.Contains('LlamaCppAgentCacheReuse')) {
        try { [int]$script:Cfg.LlamaCppAgentCacheReuse } catch { 256 }
    } else {
        256
    }

    # Resolve vision module (mmproj) on demand when user opts in; always log availability.
    $visionModulePath = if ($UseVision) {
        Write-LaunchLog "Resolving vision module for llama.cpp launch (model=$($def.Root))" 'VISION'
        $result = Get-ModelVisionModulePath -Key $Key -Def $def -Backend llamacpp
        if ($result) {
            Write-LaunchLog "Vision module resolved: $([System.IO.Path]::GetFileName($result))" 'VISION'
        } else {
            Write-LaunchLog "No vision module found for $Key" 'WARN'
        }
        $result
    } else {
        $avail = Test-ModelVisionModuleAvailable -Key $Key -Def $def -Backend llamacpp
        if ($avail.Local) {
            Write-LaunchLog "Vision available locally ($($avail.Filename)) — not loaded (no -UseVision)" 'VISION'
        } elseif ($avail.AvailableOnHF) {
            Write-LaunchLog "Vision available on HuggingFace ($($avail.Filename)) — not loaded (no -UseVision)" 'VISION'
        } else {
            Write-LaunchLog "No vision module available for $Key (llama.cpp)" 'VISION'
        }
        ''
    }

    if ($UseVision -and $visionModulePath) {
        Write-Host "Vision: loaded mmproj $([System.IO.Path]::GetFileName($visionModulePath))" -ForegroundColor DarkCyan
    } elseif ($UseVision) {
        Write-Warning "Vision requested but no mmproj found for $Key"
    }

    $buildParams = @{
        Def              = $def
        ContextKey       = $ContextKey
        Mode             = $Mode
        ModelArgPath     = $modelArgPath
        Port             = $port
        ThinkingPolicy   = $thinkingPolicy
        VisionModulePath = $(if ($visionModulePath) { $visionModulePath } else { '' })
    }
    if ($agentParallel -gt 0) { $buildParams.Parallel = $agentParallel }
    if ($agentCacheReuse -gt 0) { $buildParams.CacheReuse = $agentCacheReuse }

    if (-not [string]::IsNullOrWhiteSpace($KvCacheK)) { $buildParams.KvK = $KvCacheK }
    if (-not [string]::IsNullOrWhiteSpace($KvCacheV)) { $buildParams.KvV = $KvCacheV }
    if ($Strict)    { $buildParams.Strict = $true }
    if ($ExtraArgs) { $buildParams.ExtraArgs = $ExtraArgs }

    # -AutoBest splats saved tuner overrides into Build-LlamaServerArgs.
    # Caller-supplied args (KvCacheK/KvCacheV/ExtraArgs above) take precedence
    # because they were set before this block — we only fill in keys that
    # haven't already been bound.
    $autoBestLoadedProfile = $null
    if ($AutoBest) {
        $bestEntry = $null
        $selectionProfile = if ($AutoBestProfile -in @('pure', 'balanced')) { $AutoBestProfile } else { 'auto' }
        $promptProfileOverride = if ($AutoBestProfile -in @('short', 'long')) { $AutoBestProfile } else { $null }
        $loadedProfile = $AutoBestProfile
        if ($promptProfileOverride) {
            $bestEntry = Get-BestLlamaCppConfig -Key $Key -ContextKey $ContextKey -Mode $Mode -PromptLength $promptProfileOverride -Profile pure
            $loadedProfile = "pure/$promptProfileOverride"
        } else {
            $preferred = Get-PreferredLlamaCppBestConfig -Key $Key -ContextKey $ContextKey -Mode $Mode -Profile $selectionProfile
            if ($preferred) {
                $bestEntry = $preferred.Entry
                $loadedProfile = "$($preferred.Profile)/$($preferred.PromptLength)"
            }
        }
        if ($bestEntry -and $bestEntry.overrides) {
            $autoBestLoadedProfile = $loadedProfile
            Write-Host "AutoBest: loaded saved tuner config (profile=$loadedProfile, score=$($bestEntry.score) $($bestEntry.scoreUnit), trials=$($bestEntry.trial_count))." -ForegroundColor Cyan
            if ([string]$bestEntry.scoreUnit -match '^(gen|tg)_') {
                Write-Warning "AutoBest: this is a generation-only profile. Re-run: findbest $Key -ContextKey $ContextKey -Mode $Mode"
            }
            $staleReasons = @(Test-LlamaCppBestConfigStale -Entry $bestEntry -Mode $Mode)
            if ($staleReasons.Count -gt 0) {
                $msg = "AutoBest: hardware/build changed since last tune - saved config may be stale. Re-run: findbest $Key -ContextKey $ContextKey -Mode $Mode"
                if ($AutoBestStrict) { throw $msg }
                Write-Warning $msg
                foreach ($reason in $staleReasons) {
                    Write-Warning "AutoBest: $reason"
                }
            }
            $tunable = @('KvK','KvV','NGpuLayers','NCpuMoe','UbatchSize','BatchSize','Threads','ThreadsBatch','Mlock','NoMmap','FlashAttn','SplitMode','SwaFull','CachePrompt','CacheReuse')
            foreach ($k in $tunable) {
                if ($buildParams.ContainsKey($k)) { continue }
                $val = $null
                if ($bestEntry.overrides -is [System.Collections.IDictionary]) {
                    if ($bestEntry.overrides.Contains($k)) { $val = $bestEntry.overrides[$k] }
                } else {
                    $prop = $bestEntry.overrides.PSObject.Properties[$k]
                    if ($prop) { $val = $prop.Value }
                }
                if ($null -ne $val) { $buildParams[$k] = $val }
            }
        } elseif ($bestEntry) {
            Write-Warning "AutoBest: matched saved entry has no 'overrides' field (older tuner version?). Skipping."
        } else {
            $currentVram = Get-LocalLLMVRAMGB
            $quant = if ($def.Contains('Quant')) { [string]$def.Quant } else { '' }
            $profilesToCheck = if ($promptProfileOverride) { @($promptProfileOverride) } else { @('long', 'short') }
            $selectionProfilesToCheck = if ($selectionProfile -eq 'auto') { @('balanced', 'pure') } else { @($selectionProfile) }
            $candidates = @()
            foreach ($selectionName in $selectionProfilesToCheck) {
                foreach ($profileName in $profilesToCheck) {
                    $candidates += @(Get-LlamaCppBestConfigCandidates -Key $Key -ContextKey $ContextKey -Mode $Mode -PromptLength $profileName -Quant $quant -Profile $selectionName)
                }
            }
            foreach ($candidate in $candidates) {
                if ($candidate.vramGB -and [Math]::Abs([int]$candidate.vramGB - [int]$currentVram) -gt 1) {
                    Write-Warning "AutoBest: saved config VRAM was $($candidate.vramGB)GB, current detected VRAM is ${currentVram}GB."
                    break
                }
            }
            $profileHint = if ($promptProfileOverride) { $promptProfileOverride } else { 'long' }
            Write-Warning "AutoBest: no saved config matches (key=$Key contextKey=$ContextKey mode=$Mode autoBestProfile=$AutoBestProfile vram=${currentVram}GB). Run: findbest $Key -ContextKey $ContextKey -Mode $Mode -PromptLengths $profileHint"
        }
    }

    $serverArgs = Build-LlamaServerArgs @buildParams

    # Resolve the server binary based on mode (upstream vs turboquant fork).
    # DryRun must not trigger an install — Find-* returns $null if absent.
    $dryRunServerNote = $null
    if ($DryRun) {
        $serverPath = if ($Mode -eq 'turboquant') {
            try { Find-TurboquantServerExe } catch { $null }
        } else {
            Find-LlamaServerExe
        }
        if (-not $serverPath) {
            $serverPath = '<not installed>'
            $dryRunServerNote = "llama-server ($Mode) is not installed; a real launch would install it first"
        }
    }
    else {
        $serverPath = if ($Mode -eq 'turboquant') {
            Ensure-LlamaServerTurboquant
        } else {
            Ensure-LlamaServerNative
        }
    }

    if ($DryRun) {
        $thinking = if ($thinkingPolicy -eq 'keep') {
            'kept (direct to llama-server)'
        } else {
            "stripped via no-think-proxy:$($script:NoThinkProxyPort)"
        }

        $baseUrl = if ($thinkingPolicy -eq 'keep') {
            "http://localhost:$port"
        } else {
            "http://localhost:$($script:NoThinkProxyPort)"
        }

        $systemPrompt = Get-LocalModelSystemPrompt -IncludeInlineToolSchemas:$IncludeInlineToolSchemas

        $launchArgs = if ($LimitTools) {
            @('--dangerously-skip-permissions', '--tools', $Tools, '--append-system-prompt', $systemPrompt)
        }
        else {
            @('--dangerously-skip-permissions', '--append-system-prompt', $systemPrompt)
        }

        $title = if ($Codex) {
            "codex via llama.cpp ($Mode)"
        } elseif ($Unshackled) {
            "unshackled via llama.cpp ($Mode)"
        } else {
            "claude via llama.cpp ($Mode)"
        }

        $env = if ($Codex) {
            [ordered]@{}
        } else {
            Get-LocalLLMClaudeEnvSnapshot -BaseUrl $baseUrl -Model $def.Root -KeepThinking:($thinkingPolicy -eq 'keep')
        }

        $launchExe = if ($Unshackled) { 'unshackled' } elseif ($Codex) { 'codex' } else { 'claude' }
        $launchExeArgs = if ($Codex) {
            @()
        } elseif ($Unshackled) {
            @($launchArgs)
        } else {
            @('--model', $def.Root) + $launchArgs
        }

        $contextTokens = Get-ModelContextValue -Def $def -ContextKey $ContextKey
        $quantLabel    = if ($def.Contains('Quant')) { [string]$def.Quant } else { $null }
        $parserLabel   = if ($def.Contains('Parser') -and -not [string]::IsNullOrWhiteSpace([string]$def.Parser)) { [string]$def.Parser } else { 'none' }
        $vramSize      = if ($quantLabel) { Get-QuantSizeGB -Def $def -QuantKey $quantLabel } else { $null }
        $vramInfo      = Get-LocalLLMVRAMInfo
        $fit           = if ($quantLabel) { Get-QuantFitClass -Def $def -QuantKey $quantLabel } else { '' }
        $toolsLabel    = if ($LimitTools) { "limited ($Tools)" } else { 'all' }
        $healthTimeout = if ($script:Cfg.Contains('LlamaCppHealthCheckTimeoutSec')) { [int]$script:Cfg.LlamaCppHealthCheckTimeoutSec } else { 300 }

        $notes = @()
        if ($dryRunGgufNote)   { $notes += $dryRunGgufNote }
        if ($dryRunServerNote) { $notes += $dryRunServerNote }
        if ($AutoBest -and -not [string]::IsNullOrWhiteSpace($autoBestLoadedProfile)) {
            $notes += "AutoBest: loaded saved tuner profile=$autoBestLoadedProfile (overrides applied to argv)"
        }

        $plan = @{
            Title            = $title
            Backend          = 'llamacpp'
            Mode             = $Mode
            Key              = $Key
            Model            = $def.Root
            ContextKey       = $ContextKey
            ContextTokens    = $contextTokens
            Quant            = $quantLabel
            Parser           = $parserLabel
            GgufPath         = $ggufPath
            ServerPath       = $serverPath
            ServerArgs       = $serverArgs
            Port             = $port
            BaseUrl          = $baseUrl
            HealthCheck      = "http://127.0.0.1:$port/v1/models"
            HealthTimeoutSec = $healthTimeout
            Tools            = $toolsLabel
            Thinking         = $thinking
            VramNeeded       = $vramSize
            VramAvailable    = $vramInfo.GB
            VramSource       = $vramInfo.Source
            FitClass         = $fit
            Env              = $env
            LaunchExe        = $launchExe
            LaunchArgs       = $launchExeArgs
            Notes            = $notes
        }

        Show-LocalLLMLaunchPlan -Plan $plan
        return
    }

    $logPaths = New-LlamaServerLogPaths

    Write-Host ""
    Write-Host "Starting llama-server for $($def.Root) via llama.cpp ($Mode)..." -ForegroundColor Cyan
    Write-Host "  Server   : $serverPath" -ForegroundColor DarkGray
    Write-Host "  GGUF     : $ggufPath" -ForegroundColor DarkGray
    if ($VisionModulePath) {
        Write-Host "  Vision   : $([System.IO.Path]::GetFileName($VisionModulePath))" -ForegroundColor DarkCyan
    }
    Write-Host "  Port     : $port" -ForegroundColor DarkGray
    Write-Host "  Logs     : $($logPaths.Out)" -ForegroundColor DarkGray
    Write-Host "             $($logPaths.Err)" -ForegroundColor DarkGray

    Write-LaunchLog "llama-server: path=$serverPath port=$port gguf=$ggufPath mode=$Mode" 'SERVER'

    $proc = Start-LlamaServerNative -ServerPath $serverPath -ServerArgs $serverArgs -OutLogPath $logPaths.Out -ErrLogPath $logPaths.Err

    $session = @{
        Backend  = 'llamacpp'
        Mode     = $Mode
        Port     = $port
        BaseUrl  = "http://localhost:$port"
        Model    = $def.Root
        GgufPath = $ggufPath
        Pid      = $proc.Id
        OutLog   = $logPaths.Out
        ErrLog   = $logPaths.Err
    }

    Set-CurrentBackendSession -Session $session

    try {
        Wait-LlamaServer -Port $port -Process $proc -OutLogPath $logPaths.Out -ErrLogPath $logPaths.Err
    }
    catch {
        Stop-LlamaServer -Quiet
        throw
    }

    $contextTokens = Get-ModelContextValue -Def $def -ContextKey $ContextKey

    if ($Codex) {
        try {
            $maxOutputTokens = if ($script:Cfg.Contains("LocalModelMaxOutputTokens")) {
                try { [int]$script:Cfg.LocalModelMaxOutputTokens } catch { 0 }
            } else {
                0
            }

            Write-Host ""
            Write-Host "Launching codex with $($def.Root) via llama.cpp ($Mode)..." -ForegroundColor Cyan
            Write-Host "  Base URL : http://localhost:$port/v1" -ForegroundColor DarkGray
            Write-Host "  Model    : $($def.Root)" -ForegroundColor DarkGray
            Write-Host "  GGUF     : $ggufPath" -ForegroundColor DarkGray
            if ($VisionModulePath) {
                Write-Host "  Vision   : $([System.IO.Path]::GetFileName($VisionModulePath))" -ForegroundColor DarkCyan
            }
            Write-Host "  Port     : $port" -ForegroundColor DarkGray
            Write-Host "  Strict   : $([bool]$Strict)" -ForegroundColor DarkGray
            Write-Host ""

            Start-CodexCli -Model $def.Root -BaseUrl "http://localhost:$port/v1" -ContextTokens $contextTokens -MaxOutputTokens $maxOutputTokens
        }
        finally {
            Stop-LlamaServer
        }
        return
    }

    Save-ClaudeEnvBackup

    try {
    # Front llama-server with no-think-proxy unless the model opts to keep
    # thinking. The proxy strips <think>...</think> from /v1/messages
    # responses, which both reasoning-Qwen variants and Heretic merges leak
    # into the assistant text and break Unshackled's session-title parser.
    $useNoThinkProxy = ($thinkingPolicy -ne 'keep')

    if ($useNoThinkProxy) {
        Start-NoThinkProxy -TargetPort $port
        $effectiveBaseUrl = "http://localhost:$($script:NoThinkProxyPort)"
    }
    else {
        $effectiveBaseUrl = "http://localhost:$port"
    }

    $systemPrompt = Get-LocalModelSystemPrompt -IncludeInlineToolSchemas:$IncludeInlineToolSchemas

    if ($AutoBest -and -not [string]::IsNullOrWhiteSpace($autoBestLoadedProfile)) {
        $smoke = Test-ClaudeLocalVisibleResponse -BaseUrl $effectiveBaseUrl -Model $def.Root -SystemPrompt $systemPrompt
        if (-not $smoke.Ok -and $useNoThinkProxy) {
            Write-Warning "AutoBest: launch smoke through no-think proxy produced no visible text; trying direct llama-server routing for this session."
            $directBaseUrl = "http://localhost:$port"
            $directSmoke = Test-ClaudeLocalVisibleResponse -BaseUrl $directBaseUrl -Model $def.Root -SystemPrompt $systemPrompt
            if ($directSmoke.Ok) {
                $effectiveBaseUrl = $directBaseUrl
            } else {
                $detail = Format-ClaudeLocalSmokeFailure -Smoke $directSmoke
                throw "AutoBest: saved profile failed launch smoke through proxy and direct llama-server route ($detail). Re-run tuning or launch without -AutoBest."
            }
        } elseif (-not $smoke.Ok) {
            $detail = Format-ClaudeLocalSmokeFailure -Smoke $smoke
            throw "AutoBest: saved profile failed launch smoke ($detail). Re-run tuning or launch without -AutoBest."
        }
    }

        Set-ClaudeLocalEnv -BaseUrl $effectiveBaseUrl -Model $def.Root -KeepThinking:($thinkingPolicy -eq 'keep') -ContextTokens $contextTokens

        $backendLabel = if ($Unshackled) { "unshackled" } else { "claude" }
        $toolsLabel = if ($LimitTools) { "limited" } else { "all" }
        $thinkingLabel = if ($thinkingPolicy -eq 'keep') {
            "kept (direct to llama-server)"
        } elseif ($effectiveBaseUrl -eq "http://localhost:$($script:NoThinkProxyPort)") {
            "stripped via no-think-proxy:$($script:NoThinkProxyPort)"
        } else {
            "disabled; direct route after proxy smoke fallback"
        }

        Write-Host ""
        Write-Host "Launching $backendLabel with $($def.Root) via llama.cpp ($Mode)..." -ForegroundColor Cyan
        Write-Host "  Base URL : $effectiveBaseUrl" -ForegroundColor DarkGray
        Write-Host "  Model    : $($def.Root)" -ForegroundColor DarkGray
        Write-Host "  GGUF     : $ggufPath" -ForegroundColor DarkGray
        if ($VisionModulePath) {
            Write-Host "  Vision   : $([System.IO.Path]::GetFileName($VisionModulePath))" -ForegroundColor DarkCyan
        }
        Write-Host "  Port     : $port" -ForegroundColor DarkGray
        $agentSlotsLabel = if ($agentParallel -gt 0) { [string]$agentParallel } else { 'auto' }
        $agentCacheReuseLabel = if ($agentCacheReuse -gt 0) { [string]$agentCacheReuse } else { 'default' }
        Write-Host "  Agent    : slots=$agentSlotsLabel cache-reuse=$agentCacheReuseLabel" -ForegroundColor DarkGray
        Write-Host "  Thinking : $thinkingLabel" -ForegroundColor DarkGray
        Write-Host "  Tools    : $toolsLabel" -ForegroundColor DarkGray
        Write-Host "  Strict   : $([bool]$Strict)" -ForegroundColor DarkGray
        Write-Host ""

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

        Write-LaunchLog "Launching ${$backendLabel}: model=$($def.Root) base=$effectiveBaseUrl unshackled=$Unshackled" 'LAUNCH'

        if ($Unshackled) {
            $extras = Get-UnshackledExtraArgs -Param $ExtraUnshackledArgs
            Invoke-UnshackledCli @launchArgs @extras
        }
        else {
            & claude --model $def.Root @launchArgs
        }
    }
    finally {
        Restore-ClaudeEnvBackup

        if ($useNoThinkProxy) {
            Stop-NoThinkProxy
        }

        Stop-LlamaServer
    }
}

