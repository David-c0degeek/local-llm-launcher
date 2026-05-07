# Settings + config loading. Top-level scalars in llm-models.json (the catalog)
# can be overlaid by ~/.local-llm/settings.json (gitignored, per-machine).
# Models / CommandAliases stay in the catalog.

function Expand-LocalLLMPath {
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    $expanded = $expanded -replace '\$HOME', [regex]::Escape($HOME)
    return $expanded
}

function Get-LocalLLMSettingsPath {
    if ($env:LOCAL_LLM_SETTINGS) {
        return $env:LOCAL_LLM_SETTINGS
    }

    return Join-Path $script:LLMProfileRoot "settings.json"
}

function Import-LocalLLMSettings {
    $path = Get-LocalLLMSettingsPath

    if (-not (Test-Path $path)) {
        return @{}
    }

    try {
        return (Get-Content -Raw -Path $path | ConvertFrom-Json -AsHashtable)
    }
    catch {
        Write-Warning "Could not parse $path : $($_.Exception.Message). Ignoring."
        return @{}
    }
}

function Import-LocalLLMConfig {
    if (-not (Test-Path $script:LocalLLMConfigPath)) {
        throw "LocalBox config not found: $script:LocalLLMConfigPath"
    }

    $cfg = Get-Content -Raw -Path $script:LocalLLMConfigPath | ConvertFrom-Json -AsHashtable

    $settings = Import-LocalLLMSettings

    foreach ($key in @($settings.Keys)) {
        if ($key -in @("Models", "CommandAliases")) { continue }
        $cfg[$key] = $settings[$key]
    }

    $cfg.OllamaAppPath = Expand-LocalLLMPath $cfg.OllamaAppPath
    $cfg.OllamaCommunityRoot = Expand-LocalLLMPath $cfg.OllamaCommunityRoot

    # llama.cpp backend defaults — added when missing so older catalogs keep working.
    if (-not $cfg.ContainsKey("LlamaCppPort"))                  { $cfg.LlamaCppPort = 8080 }
    if (-not $cfg.ContainsKey("LlamaCppServerPath"))            { $cfg.LlamaCppServerPath = "%USERPROFILE%\\.local-llm\\llama-cpp\\llama-server.exe" }
    if (-not $cfg.ContainsKey("LlamaCppTurboquantRoot"))        { $cfg.LlamaCppTurboquantRoot = "%USERPROFILE%\\.local-llm\\llama-cpp-turboquant" }
    if (-not $cfg.ContainsKey("LlamaCppTurboquantRepo"))        { $cfg.LlamaCppTurboquantRepo = "TheTom/llama-cpp-turboquant" }
    if (-not $cfg.ContainsKey("LlamaCppGgufRoot"))              { $cfg.LlamaCppGgufRoot = "%USERPROFILE%\\.local-llm\\gguf" }
    if (-not $cfg.ContainsKey("LlamaCppDefaultMode"))           { $cfg.LlamaCppDefaultMode = "native" }
    if (-not $cfg.ContainsKey("LlamaCppHealthCheckTimeoutSec")) { $cfg.LlamaCppHealthCheckTimeoutSec = 300 }
    if (-not $cfg.ContainsKey("LlamaCppCoexistOllama"))         { $cfg.LlamaCppCoexistOllama = $false }
    if (-not $cfg.ContainsKey("LlamaCppNCpuMoe"))               { $cfg.LlamaCppNCpuMoe = 35 }
    if (-not $cfg.ContainsKey("LlamaCppMlock"))                 { $cfg.LlamaCppMlock = $true }
    if (-not $cfg.ContainsKey("LlamaCppNoMmap"))                { $cfg.LlamaCppNoMmap = $true }
    if (-not $cfg.ContainsKey("LlamaCppAgentParallel"))         { $cfg.LlamaCppAgentParallel = 1 }
    if (-not $cfg.ContainsKey("LlamaCppAgentCacheReuse"))       { $cfg.LlamaCppAgentCacheReuse = 256 }
    if (-not $cfg.ContainsKey("LocalModelMaxOutputTokens"))     { $cfg.LocalModelMaxOutputTokens = 4096 }
    if (-not $cfg.ContainsKey("BenchPilotRoot"))                { $cfg.BenchPilotRoot = "" }
    if (-not $cfg.ContainsKey("BenchPilotRepoUrl"))             { $cfg.BenchPilotRepoUrl = "https://github.com/David-c0degeek/benchpilot" }
    if (-not $cfg.ContainsKey("BenchPilotMinimumVersion"))      { $cfg.BenchPilotMinimumVersion = "0.1.0" }
    if (-not $cfg.ContainsKey("LocalBoxRoot"))                  { $cfg.LocalBoxRoot = "" }
    if (-not $cfg.ContainsKey("UnshackledRoot"))                { $cfg.UnshackledRoot = "%USERPROFILE%\\.local-llm\\tools\\unshackled" }

    # Drop the obsolete docker-image setting if a stale settings.json or
    # catalog still carries it.
    if ($cfg.ContainsKey("LlamaCppDockerImage")) { $cfg.Remove("LlamaCppDockerImage") | Out-Null }
    if ($cfg.ContainsKey("BenchPilotPreferExternal")) { $cfg.Remove("BenchPilotPreferExternal") | Out-Null }
    if ($cfg.ContainsKey("BenchPilotAllowLegacyFallback")) { $cfg.Remove("BenchPilotAllowLegacyFallback") | Out-Null }

    $cfg.LlamaCppServerPath     = Expand-LocalLLMPath $cfg.LlamaCppServerPath
    $cfg.LlamaCppTurboquantRoot = Expand-LocalLLMPath $cfg.LlamaCppTurboquantRoot
    $cfg.LlamaCppGgufRoot       = Expand-LocalLLMPath $cfg.LlamaCppGgufRoot
    $cfg.BenchPilotRoot         = Expand-LocalLLMPath $cfg.BenchPilotRoot
    $cfg.LocalBoxRoot           = Expand-LocalLLMPath $cfg.LocalBoxRoot

    $cfg.UnshackledRoot = Expand-LocalLLMPath $cfg.UnshackledRoot

    if (-not $cfg.ContainsKey("RequireAdvertisedTools")) {
        $cfg.RequireAdvertisedTools = $true
    }

    if (-not $cfg.ContainsKey("NoThinkProxyPort")) {
        $cfg.NoThinkProxyPort = 11435
    }

    if (-not $cfg.ContainsKey("UnshackledRepoUrl")) {
        $cfg.UnshackledRepoUrl = "https://github.com/David-c0degeek/unshackled"
    }

    return $cfg
}

function Set-LocalLLMSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Key,
        [Parameter(Position = 1)][AllowNull()][AllowEmptyString()][object]$Value
    )

    if ($Key -in @("Models", "CommandAliases")) {
        throw "'$Key' belongs in llm-models.json (the catalog), not settings.json. Edit the catalog directly."
    }

    $path = Get-LocalLLMSettingsPath

    $settings = if (Test-Path $path) {
        try {
            Get-Content -Raw -Path $path | ConvertFrom-Json -AsHashtable
        } catch {
            [ordered]@{}
        }
    } else {
        [ordered]@{}
    }

    if ($null -eq $Value -or $Value -eq "") {
        if ($settings.Contains($Key)) {
            $settings.Remove($Key) | Out-Null
            Write-Host "Unset $Key in $path" -ForegroundColor Yellow
        }
    }
    else {
        $settings[$Key] = $Value
        Write-Host "Set $Key = $Value in $path" -ForegroundColor Green
    }

    if ($settings.Count -eq 0 -and (Test-Path $path)) {
        Remove-Item -Path $path -Force
    }
    else {
        $json = $settings | ConvertTo-Json -Depth 8
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($path, $json, $utf8NoBom)
    }

    Reload-LocalLLMConfig
}

# Env vars touched when launching Claude Code against a local backend.
# Listed once so Save-/Restore-ClaudeEnvBackup stay in sync.
$script:ClaudeEnvNames = @(
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "CLAUDE_CODE_DISABLE_THINKING",
    "MAX_THINKING_TOKENS",
    "CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS",
    "CLAUDE_CODE_ATTRIBUTION_HEADER",
    "DISABLE_PROMPT_CACHING"
)

$script:LocalModelToolUseRules = @"
TOOL USE RULES (follow strictly):
1. Before EVERY Edit call, use Read on that file first to get the current exact content. Never guess or recall content from memory.
2. Edit requires BOTH old_string AND new_string always. To delete content, set new_string to "". Never omit new_string.
3. If Edit fails with old_string not found: immediately use Read to get the real current content, then retry with the exact string from the Read result.
4. After any Bash/Write/Edit that modifies a file, do not assume you know the new content — use Read if you need to reference it again.
"@

$script:LocalModelDeferredToolSchemas = @"
DEFERRED TOOL SCHEMAS (exact — do not guess, use these parameter names and types):

AskUserQuestion: { questions: [ { question: string, header: string (max 12 chars), options: [ { label: string, description: string } ] (2-4 items), multiSelect: boolean } ] (1-4 questions) }
WebFetch: { url: string (required), prompt: string (required) }
WebSearch: { query: string (required), allowed_domains?: string[], blocked_domains?: string[] }
TaskCreate: { subject: string (required), description: string (required), activeForm?: string }
TaskUpdate: { taskId: string (required), status?: "pending"|"in_progress"|"completed"|"deleted", subject?: string, description?: string, addBlocks?: string[], addBlockedBy?: string[] }
TaskList: {}
TaskGet: { taskId: string (required) }
TaskStop: { task_id: string (required) }
ToolSearch: { query: string (required) }
"@

function Get-LocalModelSystemPrompt {
    # No persona — local models already self-identify via their GGUF template.
    # Just return universal tool-use guidance, optionally with inline schemas
    # for the deferred Claude Code tools (helpful when --tools is restricted
    # and the model can't reach for ToolSearch as easily).
    param([switch]$IncludeInlineToolSchemas)

    $parts = @($script:LocalModelToolUseRules)

    if ($IncludeInlineToolSchemas) {
        $parts += $script:LocalModelDeferredToolSchemas
    }

    return ($parts -join "`n`n")
}
