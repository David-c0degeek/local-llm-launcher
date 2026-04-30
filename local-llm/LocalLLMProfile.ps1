# =========================
# Local LLM profile engine
# Ollama + Claude Code + free-code
# Windows / PowerShell only — does not work in WSL/bash.
# CLEAN / DRY / KISS
# =========================

# Usage:
#   1. Keep this file beside llm-models.json.
#   2. Dot-source this file from your PowerShell profile:
#        . "D:\path\LocalLLMProfile.ps1"
#   3. Reload:
#        . $PROFILE
#
# Do not enable top-level StrictMode in a profile.

$script:LLMProfileRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PROFILE }
$script:LocalLLMConfigPath = if ($env:LOCAL_LLM_CONFIG) { $env:LOCAL_LLM_CONFIG } else { Join-Path $script:LLMProfileRoot "llm-models.json" }

function Expand-LocalLLMPath {
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    $expanded = $expanded -replace '\$HOME', [regex]::Escape($HOME)
    return $expanded
}

function Import-LocalLLMConfig {
    if (-not (Test-Path $script:LocalLLMConfigPath)) {
        throw "Local LLM config not found: $script:LocalLLMConfigPath"
    }

    $cfg = Get-Content -Raw -Path $script:LocalLLMConfigPath | ConvertFrom-Json -AsHashtable

    $cfg.OllamaAppPath = Expand-LocalLLMPath $cfg.OllamaAppPath
    $cfg.OllamaCommunityRoot = Expand-LocalLLMPath $cfg.OllamaCommunityRoot
    $cfg.FreeCodeRoot = Expand-LocalLLMPath $cfg.FreeCodeRoot

    if (-not $cfg.ContainsKey("RequireAdvertisedTools")) {
        $cfg.RequireAdvertisedTools = $true
    }

    if (-not $cfg.ContainsKey("NoThinkProxyPort")) {
        $cfg.NoThinkProxyPort = 11435
    }

    return $cfg
}

$script:Cfg = Import-LocalLLMConfig
$script:ClaudeEnvBackup = @{}
$script:NoThinkProxyProcess = $null
$script:NoThinkProxyPort = [int]$script:Cfg.NoThinkProxyPort

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

# -------------------------
# Generic helpers
# -------------------------

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Convert-ToPosixPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return ($Path -replace '\\', '/')
}

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Title)

    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Pause-Menu {
    Read-Host "Press Enter to continue" | Out-Null
}

function Resolve-HuggingFaceLocalPath {
    param(
        [Parameter(Mandatory = $true)][string]$DestinationFolder,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $normalizedFileName = ($FileName -replace '\\', '/')
    $localRelativePath = ($normalizedFileName -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    return Join-Path $DestinationFolder $localRelativePath
}

function Convert-HuggingFaceFileNameToUrlPath {
    param([Parameter(Mandatory = $true)][string]$FileName)

    $normalizedFileName = ($FileName -replace '\\', '/')

    return (($normalizedFileName -split '/') | ForEach-Object {
            [System.Uri]::EscapeDataString($_)
        }) -join '/'
}

function Download-HuggingFaceFile {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$DestinationFolder
    )

    Ensure-Directory $DestinationFolder

    $normalizedFileName = ($FileName -replace '\\', '/')
    $destinationFile = Resolve-HuggingFaceLocalPath -DestinationFolder $DestinationFolder -FileName $normalizedFileName
    $destinationParent = Split-Path -Parent $destinationFile

    Ensure-Directory $destinationParent

    if (Test-Path $destinationFile) {
        Write-Host "Using existing file: $destinationFile" -ForegroundColor Green
        return $destinationFile
    }

    $downloaders = @()

    if (Get-Command uvx -ErrorAction SilentlyContinue) {
        $downloaders += "uvx-hf"
    }

    # hf/huggingface-cli are intentionally disabled because broken local Python
    # environments commonly fail on Windows. uvx or direct download is safer.
    $downloaders += "direct"

    foreach ($downloader in $downloaders) {
        Write-Host "Downloading $normalizedFileName using $downloader..." -ForegroundColor Cyan

        try {
            switch ($downloader) {
                "uvx-hf" {
                    $oldPythonUtf8 = $env:PYTHONUTF8
                    $oldPythonIoEncoding = $env:PYTHONIOENCODING

                    try {
                        $env:PYTHONUTF8 = "1"
                        $env:PYTHONIOENCODING = "utf-8"

                        & uvx hf download $Repo $normalizedFileName --local-dir $DestinationFolder | Out-Host

                        if (Test-Path $destinationFile) {
                            Write-Host "Download completed: $destinationFile" -ForegroundColor Green
                            return $destinationFile
                        }

                        if ($LASTEXITCODE -ne 0) {
                            throw "uvx hf download failed with exit code $LASTEXITCODE"
                        }
                    }
                    finally {
                        if ($null -ne $oldPythonUtf8) {
                            $env:PYTHONUTF8 = $oldPythonUtf8
                        }
                        else {
                            Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue
                        }

                        if ($null -ne $oldPythonIoEncoding) {
                            $env:PYTHONIOENCODING = $oldPythonIoEncoding
                        }
                        else {
                            Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
                        }
                    }
                }

                "direct" {
                    $urlFileName = Convert-HuggingFaceFileNameToUrlPath -FileName $normalizedFileName
                    $url = "https://huggingface.co/$Repo/resolve/main/$urlFileName"
                    $partialFile = "$destinationFile.partial"

                    $existingBytes = 0L

                    if (Test-Path $partialFile) {
                        $existingBytes = (Get-Item $partialFile).Length
                        Write-Host "Resuming from $([math]::Round($existingBytes / 1MB, 1)) MB at $partialFile" -ForegroundColor DarkCyan
                    }

                    Ensure-Directory $destinationParent

                    $oldProgress = $global:ProgressPreference
                    $global:ProgressPreference = 'SilentlyContinue'

                    try {
                        $request = [System.Net.HttpWebRequest]::Create($url)
                        $request.Method = "GET"
                        $request.AllowAutoRedirect = $true
                        $request.UserAgent = "LocalLLMProfile/1.0"

                        if ($existingBytes -gt 0) {
                            $request.AddRange($existingBytes)
                        }

                        $response = $null

                        try {
                            $response = $request.GetResponse()
                        }
                        catch [System.Net.WebException] {
                            # 416 Requested Range Not Satisfiable means the partial is already
                            # the full size; treat that as completion.
                            $errResponse = $_.Exception.Response

                            if ($errResponse -and [int]$errResponse.StatusCode -eq 416) {
                                Write-Host "Server reports already complete; finalizing." -ForegroundColor DarkCyan
                                Move-Item -Path $partialFile -Destination $destinationFile -Force
                                break
                            }

                            throw
                        }

                        try {
                            $appendMode = ($existingBytes -gt 0 -and [int]$response.StatusCode -eq 206)

                            if (-not $appendMode -and (Test-Path $partialFile)) {
                                Remove-Item $partialFile -Force -ErrorAction SilentlyContinue
                            }

                            $fileMode = if ($appendMode) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
                            $output = [System.IO.File]::Open($partialFile, $fileMode, [System.IO.FileAccess]::Write)

                            try {
                                $stream = $response.GetResponseStream()
                                $buffer = New-Object byte[] 1048576
                                $totalRead = $existingBytes
                                $expectedTotal = $existingBytes + [int64]$response.ContentLength
                                $lastReport = Get-Date

                                while ($true) {
                                    $read = $stream.Read($buffer, 0, $buffer.Length)
                                    if ($read -le 0) { break }
                                    $output.Write($buffer, 0, $read)
                                    $totalRead += $read

                                    if (((Get-Date) - $lastReport).TotalSeconds -ge 5) {
                                        $mb = [math]::Round($totalRead / 1MB, 1)
                                        $totalMb = if ($expectedTotal -gt 0) { [math]::Round($expectedTotal / 1MB, 1) } else { "?" }
                                        Write-Host "  ... $mb / $totalMb MB" -ForegroundColor DarkGray
                                        $lastReport = Get-Date
                                    }
                                }
                            }
                            finally {
                                $output.Close()
                            }
                        }
                        finally {
                            if ($response) { $response.Close() }
                        }
                    }
                    finally {
                        $global:ProgressPreference = $oldProgress
                    }

                    if (Test-Path $partialFile) {
                        Move-Item -Path $partialFile -Destination $destinationFile -Force
                    }
                }
            }

            if (Test-Path $destinationFile) {
                Write-Host "Download completed: $destinationFile" -ForegroundColor Green
                return $destinationFile
            }

            Write-Warning "$downloader completed but file was not found: $destinationFile"
        }
        catch {
            Write-Warning "$downloader failed: $($_.Exception.Message)"
            continue
        }
    }

    throw "All download methods failed for $Repo / $normalizedFileName"
}

# -------------------------
# Model catalog helpers
# -------------------------

function Reload-LocalLLMConfig {
    $script:Cfg = Import-LocalLLMConfig
    $script:NoThinkProxyPort = [int]$script:Cfg.NoThinkProxyPort
    Register-ModelShortcuts
    Write-Host "Reloaded local LLM config: $script:LocalLLMConfigPath" -ForegroundColor Green
}

function Get-ModelDef {
    param([Parameter(Mandatory = $true)][string]$Key)

    if ($script:Cfg.Models.ContainsKey($Key)) {
        return $script:Cfg.Models[$Key]
    }

    throw "Unknown model key: $Key"
}

function Get-ModelKeys {
    return @($script:Cfg.Models.Keys)
}

function Get-ModelTier {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def)

    if ($Def.Contains("Tier") -and -not [string]::IsNullOrWhiteSpace($Def.Tier)) {
        return $Def.Tier.ToLowerInvariant()
    }

    return "experimental"
}

function Get-FilteredModelKeys {
    param([switch]$IncludeAll)

    $keys = @(Get-ModelKeys)

    if ($IncludeAll) {
        return $keys
    }

    return @(
        $keys | Where-Object {
            $def = Get-ModelDef -Key $_
            (Get-ModelTier -Def $def) -eq "recommended"
        }
    )
}

function Format-ModelTierBadge {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def)

    switch ((Get-ModelTier -Def $Def)) {
        "recommended"  { return "[recommended]" }
        "experimental" { return "[experimental]" }
        "legacy"       { return "[legacy]" }
        default        { return "[$($Def.Tier)]" }
    }
}

function Get-ModelFolder {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def
    )

    $folder = Join-Path $script:Cfg.OllamaCommunityRoot $Def.Root
    Ensure-Directory $folder
    return $folder
}

function Get-ModelFileName {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def)

    if ($Def.ContainsKey("Quants")) {
        return $Def.Quants[$Def.Quant]
    }

    return $Def.File
}

function Get-ModelAliasName {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey
    )

    if ([string]::IsNullOrWhiteSpace($ContextKey)) {
        return $Def.Root
    }

    return "$($Def.Root)$ContextKey"
}

function Get-ModelAliasNames {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def)

    $names = @()

    foreach ($contextKey in $Def.Contexts.Keys) {
        $names += Get-ModelAliasName -Def $Def -ContextKey $contextKey
    }

    return $names
}

function Get-ModelContextValue {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey
    )

    return $Def.Contexts[$ContextKey]
}

function Resolve-ModelQuantKey {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [Parameter(Mandatory = $true)][string]$Quant
    )

    if (-not $Def.ContainsKey("Quants")) {
        throw "This model does not support quant switching."
    }

    foreach ($key in $Def.Quants.Keys) {
        if ($key -ieq $Quant) {
            return $key
        }
    }

    $available = @($Def.Quants.Keys) -join ", "
    throw "Unknown quant '$Quant'. Available: $available"
}

function Get-ModelGgufPath {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def
    )

    $folder = Get-ModelFolder -Key $Key -Def $Def
    $fileName = Get-ModelFileName -Def $Def
    $ggufPath = Download-HuggingFaceFile -Repo $Def.Repo -FileName $fileName -DestinationFolder $folder

    if ($ggufPath -is [array]) {
        $ggufPath = $ggufPath[-1]
    }

    if (-not ($ggufPath -is [string])) {
        throw "Expected GGUF path to be a string."
    }

    return $ggufPath
}

# -------------------------
# Ollama helpers
# -------------------------

function Get-OllamaLoadedModels {
    $lines = & ollama ps 2>$null | Select-Object -Skip 1
    $items = @()

    foreach ($line in $lines) {
        if (-not $line.Trim()) { continue }

        $parts = $line -split '\s{2,}'

        if ($parts.Count -ge 6) {
            $items += [pscustomobject]@{
                Name      = $parts[0]
                Id        = $parts[1]
                Size      = $parts[2]
                Processor = $parts[3]
                Context   = $parts[4]
                Until     = $parts[5]
            }
        }
    }

    return $items
}

function Stop-OllamaModels {
    $loaded = Get-OllamaLoadedModels

    foreach ($item in $loaded) {
        if ($item.Name) {
            & ollama stop $item.Name | Out-Null
        }
    }
}

function Stop-OllamaApp {
    Get-Process -Name "ollama app", "ollama" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
}

function Start-OllamaApp {
    if (Test-Path $script:Cfg.OllamaAppPath) {
        Start-Process -FilePath $script:Cfg.OllamaAppPath | Out-Null
    }
    else {
        Start-Process -FilePath "ollama app.exe" | Out-Null
    }
}

function Wait-Ollama {
    $start = Get-Date
    $deadline = $start.AddSeconds(60)
    $progressShownAt = $null

    do {
        try {
            Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -UseBasicParsing -TimeoutSec 2 | Out-Null

            if ($progressShownAt) {
                Write-Host ""
            }

            return
        }
        catch {
            $elapsed = (Get-Date) - $start

            if ($elapsed.TotalSeconds -ge 5) {
                if (-not $progressShownAt) {
                    Write-Host -NoNewline "Waiting for Ollama" -ForegroundColor DarkGray
                    $progressShownAt = Get-Date
                }
                elseif (((Get-Date) - $progressShownAt).TotalSeconds -ge 2) {
                    Write-Host -NoNewline "." -ForegroundColor DarkGray
                    $progressShownAt = Get-Date
                }
            }

            Start-Sleep -Milliseconds 500
        }
    } while ((Get-Date) -lt $deadline)

    if ($progressShownAt) {
        Write-Host ""
    }

    throw "Ollama did not come up in time (60s)."
}

function Reset-OllamaEnv {
    Remove-Item Env:OLLAMA_CONTEXT_LENGTH -ErrorAction SilentlyContinue
    Remove-Item Env:OLLAMA_FLASH_ATTENTION -ErrorAction SilentlyContinue
    Remove-Item Env:OLLAMA_KEEP_ALIVE -ErrorAction SilentlyContinue
    Remove-Item Env:OLLAMA_KV_CACHE_TYPE -ErrorAction SilentlyContinue
}

function Set-OllamaRuntimeEnv {
    param([switch]$UseQ8)

    $env:OLLAMA_FLASH_ATTENTION = "1"

    $keepAlive = if ($script:Cfg.Contains("KeepAlive") -and -not [string]::IsNullOrWhiteSpace($script:Cfg.KeepAlive)) {
        [string]$script:Cfg.KeepAlive
    } else {
        "-1"
    }

    $env:OLLAMA_KEEP_ALIVE = $keepAlive

    if ($UseQ8) {
        $env:OLLAMA_KV_CACHE_TYPE = "q8_0"
    }
}

function Test-OllamaModelExists {
    param([Parameter(Mandatory = $true)][string]$ModelName)

    & ollama show $ModelName *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-OllamaInstalledModelNames {
    # Single-shot fetch of the installed Ollama model list.
    # Returns short names ("foo:latest" -> "foo") and the raw "name:tag" pair.
    $lines = & ollama list 2>$null | Select-Object -Skip 1
    $names = New-Object System.Collections.Generic.List[string]

    foreach ($line in $lines) {
        if (-not $line.Trim()) { continue }
        $first = ($line -split '\s+', 2)[0]

        if (-not $first) { continue }

        $names.Add($first) | Out-Null

        if ($first -like '*:latest') {
            $names.Add($first.Substring(0, $first.Length - 7)) | Out-Null
        }
    }

    return @($names)
}

function Test-OllamaModelSupportsTools {
    param([Parameter(Mandatory = $true)][string]$ModelName)

    # Prefer the structured /api/show endpoint — it exposes a `capabilities`
    # array we can check exactly. Fall back to a regex on `ollama show` output
    # only if the endpoint isn't reachable (older Ollama, server stopped).
    try {
        $body = @{ name = $ModelName } | ConvertTo-Json -Compress
        $response = Invoke-RestMethod `
            -Uri "http://localhost:11434/api/show" `
            -Method Post `
            -ContentType "application/json" `
            -Body $body `
            -TimeoutSec 5

        if ($response.capabilities) {
            return ($response.capabilities -contains "tools")
        }
    }
    catch {
        # API unreachable; fall through to the text-based fallback.
    }

    $output = & ollama show $ModelName 2>$null

    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    return ($output -match '(?im)\btools\b')
}

function Test-OllamaVersionMinimum {
    param([Parameter(Mandatory = $true)][string]$MinVersion)

    $raw = & ollama --version 2>$null

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not determine Ollama version. Is Ollama installed?"
        return $false
    }

    if ($raw -match '(\d+\.\d+\.\d+)') {
        $current = [version]$Matches[1]
        $minimum = [version]$MinVersion
        return ($current -ge $minimum)
    }

    Write-Warning "Could not parse Ollama version from: $raw"
    return $false
}

function Get-ParserLines {
    param([Parameter(Mandatory = $true)][string]$Parser)

    $lines = New-Object System.Collections.Generic.List[string]

    switch ($Parser) {
        "none" {
        }

        "qwen3coder" {
            $lines.Add("RENDERER qwen3-coder")
            $lines.Add("PARSER qwen3-coder")
            $lines.Add("PARAMETER temperature 0.7")
            $lines.Add("PARAMETER top_k 20")
            $lines.Add("PARAMETER top_p 0.8")
            $lines.Add("PARAMETER repeat_penalty 1.05")
            $lines.Add('PARAMETER stop "<|im_end|>"')
            $lines.Add('PARAMETER stop "<|im_start|>"')
            $lines.Add('PARAMETER stop "<|endoftext|>"')
        }

        "qwen36" {
            # Qwen 3.5 / 3.6 with the qwen3-coder XML tool format (matches training).
            # Non-thinking sampling profile.
            $lines.Add("RENDERER qwen3-coder")
            $lines.Add("PARSER qwen3-coder")
            $lines.Add("PARAMETER temperature 0.7")
            $lines.Add("PARAMETER top_k 20")
            $lines.Add("PARAMETER top_p 0.8")
            $lines.Add("PARAMETER min_p 0")
            $lines.Add("PARAMETER presence_penalty 1.5")
            $lines.Add('PARAMETER stop "<|im_end|>"')
            $lines.Add('PARAMETER stop "<|im_start|>"')
        }

        "qwen36-think" {
            # Same renderer/parser as qwen36, with thinking-style sampling
            # (lower temperature, higher top_p) for thinking-trained variants.
            $lines.Add("RENDERER qwen3-coder")
            $lines.Add("PARSER qwen3-coder")
            $lines.Add("PARAMETER temperature 0.6")
            $lines.Add("PARAMETER top_k 20")
            $lines.Add("PARAMETER top_p 0.95")
            $lines.Add('PARAMETER stop "<|im_end|>"')
            $lines.Add('PARAMETER stop "<|im_start|>"')
        }

        default {
            throw "Unknown parser: $Parser"
        }
    }

    return $lines
}

function Get-ProfileVersion {
    # Hash of the Modelfile lines this profile would emit for a given parser,
    # plus the context length. Detects when an existing alias was built from a
    # different version of *this profile* (so we know to rebuild it). Does NOT
    # detect drift in Ollama's own template handling, in the GGUF blob, or in
    # aliases rebuilt outside our wrapper — only that our emitted Modelfile
    # would now look different.
    param(
        [Parameter(Mandatory = $true)][string]$Parser,
        [Nullable[int]]$NumCtx
    )

    $lines = Get-ParserLines -Parser $Parser
    $payload = ($lines -join "`n") + "`nnum_ctx=$NumCtx"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return ([System.BitConverter]::ToString($hash) -replace '-', '').Substring(0, 12).ToLowerInvariant()
}

function Get-ProfileVersionDir {
    $dir = Join-Path $script:LLMProfileRoot "profile-versions"
    Ensure-Directory $dir
    return $dir
}

function Get-ProfileVersionFile {
    param([Parameter(Mandatory = $true)][string]$ModelName)
    $safe = ($ModelName -replace '[:/\\]', '_')
    return Join-Path (Get-ProfileVersionDir) "$safe.txt"
}

function Save-ProfileVersionStamp {
    param(
        [Parameter(Mandatory = $true)][string]$ModelName,
        [Parameter(Mandatory = $true)][string]$Version
    )
    Set-Content -Path (Get-ProfileVersionFile -ModelName $ModelName) -Value $Version -Encoding UTF8
}

function Get-ProfileVersionStamp {
    param([Parameter(Mandatory = $true)][string]$ModelName)
    $file = Get-ProfileVersionFile -ModelName $ModelName

    if (-not (Test-Path $file)) {
        return $null
    }

    return (Get-Content -Path $file -Raw -ErrorAction SilentlyContinue).Trim()
}

function New-OllamaModelFromSource {
    param(
        [Parameter(Mandatory = $true)][string]$ModelName,
        [Parameter(Mandatory = $true)][string]$FromSource,
        [Parameter(Mandatory = $true)][string]$Parser,
        [Nullable[int]]$NumCtx
    )

    $safeName = ($ModelName -replace '[:/\\]', '_')
    $tmp = Join-Path $env:TEMP "$safeName.Modelfile"

    $content = New-Object System.Collections.Generic.List[string]
    $content.Add("FROM $FromSource")

    foreach ($line in (Get-ParserLines -Parser $Parser)) {
        $content.Add($line)
    }

    if ($null -ne $NumCtx) {
        $content.Add("PARAMETER num_ctx $NumCtx")
    }

    $content | Set-Content -Path $tmp -Encoding UTF8

    & ollama rm $ModelName 2>$null | Out-Null
    & ollama create $ModelName -f $tmp

    $exitCode = $LASTEXITCODE
    Remove-Item $tmp -ErrorAction SilentlyContinue

    if ($exitCode -ne 0) {
        throw "ollama create failed for model '$ModelName'"
    }

    Save-ProfileVersionStamp -ModelName $ModelName -Version (Get-ProfileVersion -Parser $Parser -NumCtx $NumCtx)
}

function Test-ModelAliasFresh {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey
    )

    $def = Get-ModelDef -Key $Key
    $aliasName = Get-ModelAliasName -Def $def -ContextKey $ContextKey

    if (-not (Test-OllamaModelExists -ModelName $aliasName)) {
        return $false
    }

    $stamp = Get-ProfileVersionStamp -ModelName $aliasName

    if (-not $stamp) {
        return $false
    }

    $expected = Get-ProfileVersion -Parser $def.Parser -NumCtx (Get-ModelContextValue -Def $def -ContextKey $ContextKey)
    return ($stamp -eq $expected)
}

function Get-StaleModelAliases {
    $stale = @()

    foreach ($key in (Get-ModelKeys)) {
        $def = Get-ModelDef -Key $key

        foreach ($contextKey in $def.Contexts.Keys) {
            $aliasName = Get-ModelAliasName -Def $def -ContextKey $contextKey

            if (-not (Test-OllamaModelExists -ModelName $aliasName)) { continue }
            if (Test-ModelAliasFresh -Key $key -ContextKey $contextKey) { continue }

            $stale += [pscustomobject]@{
                Key       = $key
                Context   = $contextKey
                AliasName = $aliasName
            }
        }
    }

    return $stale
}

function Ensure-ModelAlias {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [switch]$ForceRebuild
    )

    $def = Get-ModelDef -Key $Key
    $modelName = Get-ModelAliasName -Def $def -ContextKey $ContextKey
    $numCtx = Get-ModelContextValue -Def $def -ContextKey $ContextKey

    if (-not $ForceRebuild -and (Test-OllamaModelExists -ModelName $modelName)) {
        return $modelName
    }

    switch ($def.SourceType) {
        "remote" {
            & ollama pull $def.RemoteModel

            if ($LASTEXITCODE -ne 0) {
                throw "ollama pull failed for '$($def.RemoteModel)'"
            }

            New-OllamaModelFromSource -ModelName $modelName -FromSource $def.RemoteModel -Parser $def.Parser -NumCtx $numCtx
        }

        "gguf" {
            $ggufPath = Get-ModelGgufPath -Key $Key -Def $def
            $posixPath = Convert-ToPosixPath $ggufPath

            New-OllamaModelFromSource -ModelName $modelName -FromSource $posixPath -Parser $def.Parser -NumCtx $numCtx
        }

        default {
            throw "Unknown source type: $($def.SourceType)"
        }
    }

    return $modelName
}

function Ensure-ModelAllAliases {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [switch]$ForceRebuild
    )

    $def = Get-ModelDef -Key $Key

    foreach ($contextKey in $def.Contexts.Keys) {
        Ensure-ModelAlias -Key $Key -ContextKey $contextKey -ForceRebuild:$ForceRebuild | Out-Null
    }
}

function Remove-ModelAliases {
    param([Parameter(Mandatory = $true)][string]$Key)

    $def = Get-ModelDef -Key $Key

    foreach ($name in (Get-ModelAliasNames -Def $def)) {
        & ollama rm $name 2>$null | Out-Null
        $stampFile = Get-ProfileVersionFile -ModelName $name
        Remove-Item -Path $stampFile -Force -ErrorAction SilentlyContinue
    }
}

function Remove-ModelRemotePull {
    param([Parameter(Mandatory = $true)][string]$Key)

    $def = Get-ModelDef -Key $Key

    if ($def.SourceType -eq "remote") {
        & ollama rm $def.RemoteModel 2>$null | Out-Null
    }
}

function Remove-ModelFiles {
    param([Parameter(Mandatory = $true)][string]$Key)

    $def = Get-ModelDef -Key $Key

    if ($def.SourceType -ne "gguf") {
        return
    }

    $folder = Get-ModelFolder -Key $Key -Def $def
    Remove-Item -Recurse -Force $folder -ErrorAction SilentlyContinue
}

function Set-ModelQuant {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Quant
    )

    $def = Get-ModelDef -Key $Key

    if (-not $def.ContainsKey("Quants")) {
        throw "$Key does not support quant switching."
    }

    $resolvedQuant = Resolve-ModelQuantKey -Def $def -Quant $Quant
    $def.Quant = $resolvedQuant

    Remove-ModelAliases -Key $Key

    Write-Host "$Key now set to $resolvedQuant -> $($def.Quants[$resolvedQuant])" -ForegroundColor Green
    Ensure-ModelAllAliases -Key $Key -ForceRebuild
}

# -------------------------
# Add new model from a HuggingFace link
# -------------------------

function Resolve-HuggingFaceRepo {
    param([Parameter(Mandatory = $true)][string]$UrlOrRepo)

    $value = $UrlOrRepo.Trim()
    $value = $value -replace '^https?://(www\.)?huggingface\.co/', ''
    $value = $value -replace '/(tree|blob|resolve)/[^/]+.*$', ''
    $value = $value.TrimEnd('/')

    if ($value -notmatch '^[^/\s]+/[^/\s]+$') {
        throw "Cannot parse HuggingFace repo from: $UrlOrRepo"
    }

    return $value
}

function Get-HuggingFaceModelFiles {
    param([Parameter(Mandatory = $true)][string]$Repo)

    $url = "https://huggingface.co/api/models/$Repo"
    $response = Invoke-RestMethod -Uri $url -UseBasicParsing

    if (-not $response.siblings) {
        return @()
    }

    return @($response.siblings | ForEach-Object { $_.rfilename })
}

function Get-HuggingFaceQuantCode {
    param([Parameter(Mandatory = $true)][string]$FileName)

    $leaf = ($FileName -split '/' | Select-Object -Last 1)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($leaf)

    $patterns = @(
        '(IQ\d_[A-Z]+(?:_[A-Z0-9]+)?)$',
        '(MXFP\d_[A-Z]+)$',
        '(Q\d_K_[A-Z])$',
        '(Q\d_K)$',
        '(Q\d_\d)$',
        '(BF16|F16|F32)$'
    )

    foreach ($pattern in $patterns) {
        if ($name -match $pattern) {
            return $Matches[1]
        }
    }

    return $null
}

function ConvertTo-LocalLLMQuantKey {
    param([Parameter(Mandatory = $true)][string]$QuantCode)

    return ($QuantCode -replace '_', '').ToLowerInvariant()
}

function Suggest-LocalLLMParser {
    param([Parameter(Mandatory = $true)][string]$Repo)

    $name = $Repo.ToLowerInvariant()

    if ($name -match 'coder') {
        return 'qwen3coder'
    }

    if ($name -match 'qwen3\.?[56]') {
        if ($name -match 'thinking|reasoning|opus|sonnet|haiku|claude') {
            return 'qwen36-think'
        }
        return 'qwen36'
    }

    return 'none'
}

function Format-LocalLLMDisplayName {
    param([Parameter(Mandatory = $true)][string]$Repo)

    $tail = ($Repo -split '/')[-1]
    $display = $tail -replace '-', ' '
    $display = $display -replace '(?i)Qwen(\d)', 'Qwen $1'
    return $display
}

function Get-LocalLLMDefaultContexts {
    return [ordered]@{
        ''     = 65536
        'fast' = 32768
        'deep' = 65536
        '128'  = 131072
    }
}

function Save-LocalLLMConfig {
    param([Parameter(Mandatory = $true)][object]$Cfg)

    $json = $Cfg | ConvertTo-Json -Depth 32
    $json = [regex]::Replace($json, '(?m)^( {4})+', { param($m) ' ' * ($m.Value.Length / 2) })

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($script:LocalLLMConfigPath, $json, $utf8NoBom)
}

function Add-LocalLLMModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$UrlOrRepo,
        [string]$Key,
        [string[]]$Quants,
        [string]$DefaultQuant,
        [ValidateSet('auto', 'none', 'qwen3coder', 'qwen36', 'qwen36-think')][string]$Parser = 'auto',
        [string]$DisplayName,
        [string]$Root,
        [string]$QuantShortcut,
        [System.Collections.IDictionary]$Contexts,
        [bool]$LimitTools = $true,
        [ValidateSet('recommended', 'experimental', 'legacy')][string]$Tier = 'experimental',
        [switch]$Force
    )

    $repo = Resolve-HuggingFaceRepo $UrlOrRepo
    Write-Host "HuggingFace repo: $repo" -ForegroundColor Cyan

    if ([string]::IsNullOrWhiteSpace($Key)) {
        $Key = (Read-Host "Model key (e.g. q27hauhau)").Trim()

        if ([string]::IsNullOrWhiteSpace($Key)) {
            throw "Model key is required."
        }
    }

    $cfg = Get-Content -Raw -Path $script:LocalLLMConfigPath | ConvertFrom-Json -AsHashtable

    if ($cfg.Models.Contains($Key) -and -not $Force) {
        throw "Model key '$Key' already exists. Use -Force to overwrite."
    }

    Write-Host "Fetching file list from HuggingFace..." -ForegroundColor Cyan
    $allFiles = @(Get-HuggingFaceModelFiles -Repo $repo)
    $ggufFiles = @(
        $allFiles | Where-Object {
            $_ -match '\.gguf$' -and $_ -notmatch '/' -and $_ -notmatch '^mmproj-'
        }
    )

    if ($ggufFiles.Count -eq 0) {
        throw "No top-level GGUF files found at $repo."
    }

    $codeMap = [ordered]@{}

    foreach ($file in $ggufFiles) {
        $code = Get-HuggingFaceQuantCode -FileName $file

        if ($code) {
            $codeMap[$code] = $file
        }
    }

    if ($codeMap.Count -eq 0) {
        throw "No GGUF files with recognizable quant codes were found."
    }

    if ($Quants -and $Quants.Count -gt 0) {
        $filtered = [ordered]@{}
        $available = @($codeMap.Keys)

        foreach ($q in $Quants) {
            $upper = $q.ToUpperInvariant()
            $found = $available | Where-Object { $_ -ieq $upper } | Select-Object -First 1

            if ($found) {
                $filtered[$found] = $codeMap[$found]
            }
            else {
                Write-Warning "Quant '$upper' not found in repo. Available: $($available -join ', ')"
            }
        }

        if ($filtered.Count -eq 0) {
            throw "None of the requested quants were found. Available: $($available -join ', ')"
        }

        $codeMap = $filtered
    }

    $shortToFile = [ordered]@{}
    $codeToShort = @{}

    foreach ($code in $codeMap.Keys) {
        $short = ConvertTo-LocalLLMQuantKey $code
        $shortToFile[$short] = $codeMap[$code]
        $codeToShort[$code] = $short
    }

    if ([string]::IsNullOrWhiteSpace($DefaultQuant)) {
        $DefaultQuant = @($shortToFile.Keys)[0]
    }
    else {
        $upper = $DefaultQuant.ToUpperInvariant()

        if ($codeToShort.ContainsKey($upper)) {
            $DefaultQuant = $codeToShort[$upper]
        }
        elseif (-not $shortToFile.Contains($DefaultQuant)) {
            throw "DefaultQuant '$DefaultQuant' is not in the selected quants: $(@($shortToFile.Keys) -join ', ')"
        }
    }

    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = $Key }

    if ($Parser -eq 'auto') {
        $Parser = Suggest-LocalLLMParser -Repo $repo
    }

    if ([string]::IsNullOrWhiteSpace($DisplayName)) {
        $DisplayName = Format-LocalLLMDisplayName -Repo $repo
    }

    if (-not $Contexts) {
        $Contexts = Get-LocalLLMDefaultContexts
    }

    $entry = [ordered]@{
        DisplayName = $DisplayName
        Root        = $Root
        SourceType  = 'gguf'
        Repo        = $repo
        Quants      = $shortToFile
        Quant       = $DefaultQuant
        Parser      = $Parser
        LimitTools  = $LimitTools
        Tier        = $Tier
        Contexts    = $Contexts
    }

    # QuantShortcut is deprecated — only kept for legacy-cleanup paths. Set
    # explicitly via -QuantShortcut if you need it; not auto-defaulted.
    if (-not [string]::IsNullOrWhiteSpace($QuantShortcut)) {
        $entry.QuantShortcut = $QuantShortcut
    }

    if ($cfg.Models.Contains($Key)) {
        $cfg.Models.Remove($Key)
    }

    $cfg.Models[$Key] = $entry

    Save-LocalLLMConfig -Cfg $cfg

    Write-Host ""
    Write-Host "Added '$Key' to $script:LocalLLMConfigPath" -ForegroundColor Green
    Write-Host "  Display  : $DisplayName" -ForegroundColor DarkGray
    Write-Host "  Repo     : $repo" -ForegroundColor DarkGray
    Write-Host "  Parser   : $Parser" -ForegroundColor DarkGray
    Write-Host "  Quants   : $(@($shortToFile.Keys) -join ', ')  (default: $DefaultQuant)" -ForegroundColor DarkGray

    $ctxLabels = @($Contexts.Keys | ForEach-Object {
            if ([string]::IsNullOrEmpty($_)) { 'default' } else { $_ }
        })
    Write-Host "  Contexts : $($ctxLabels -join ', ')" -ForegroundColor DarkGray
    Write-Host ""

    Reload-LocalLLMConfig

    Write-Host "Run 'initmodel $Key' to download the GGUF and create Ollama aliases." -ForegroundColor Yellow
}

function addllm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$UrlOrRepo,
        [string]$Key,
        [string[]]$Quants,
        [string]$DefaultQuant,
        [string]$Parser = 'auto',
        [string]$DisplayName,
        [string]$Root,
        [string]$QuantShortcut,
        [bool]$LimitTools = $true,
        [string]$Tier = 'experimental',
        [switch]$Force
    )

    Add-LocalLLMModel @PSBoundParameters
}

# -------------------------
# Remove a model: aliases + JSON entry + (optional) GGUF files
# -------------------------

function Get-RegisteredShortcutNamesForModel {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def)

    $names = New-Object System.Collections.Generic.List[string]
    $suffixes = @("", "q8", "fc", "q8fc", "chat")

    foreach ($base in (Get-ModelAliasNames -Def $Def)) {
        foreach ($suffix in $suffixes) {
            $names.Add("$base$suffix") | Out-Null
        }
    }

    if ($Def.ContainsKey("Quants") -and $Def.ContainsKey("QuantShortcut")) {
        foreach ($quantKey in $Def.Quants.Keys) {
            $names.Add("set$($Def.QuantShortcut)$quantKey") | Out-Null
        }
    }

    return @($names)
}

function Remove-LocalLLMModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Key,
        [switch]$KeepFiles,
        [switch]$Force
    )

    $cfg = Get-Content -Raw -Path $script:LocalLLMConfigPath | ConvertFrom-Json -AsHashtable

    if (-not $cfg.Models.Contains($Key)) {
        throw "Unknown model key: $Key. Known keys: $(@($cfg.Models.Keys) -join ', ')"
    }

    $def = $cfg.Models[$Key]
    $aliasNames = @(Get-ModelAliasNames -Def $def)
    $folder = $null

    if ($def.SourceType -eq 'gguf' -and -not $KeepFiles) {
        $folder = Join-Path $script:Cfg.OllamaCommunityRoot $def.Root
    }

    Write-Host ""
    Write-Host "Will remove '$Key'  ($($def.DisplayName))" -ForegroundColor Yellow
    Write-Host "  Ollama aliases : $($aliasNames -join ', ')"

    if ($def.SourceType -eq 'remote') {
        Write-Host "  Ollama pull    : $($def.RemoteModel)"
    }

    if ($folder) {
        Write-Host "  GGUF folder    : $folder  (will be deleted)"
    }
    elseif ($def.SourceType -eq 'gguf') {
        Write-Host "  GGUF folder    : kept (-KeepFiles)"
    }

    Write-Host "  JSON entry     : Models.$Key"

    $hostedAliases = New-Object System.Collections.Generic.List[string]
    $shortcutNames = Get-RegisteredShortcutNamesForModel -Def $def

    foreach ($alias in @($cfg.CommandAliases.Keys)) {
        $target = $cfg.CommandAliases[$alias]

        if ($shortcutNames -contains $target -or $alias -in $shortcutNames) {
            $hostedAliases.Add($alias) | Out-Null
        }
    }

    if ($hostedAliases.Count -gt 0) {
        Write-Host "  CommandAliases : $($hostedAliases -join ', ')"
    }

    if (-not $Force) {
        Write-Host ""
        $answer = (Read-Host "Type 'yes' to proceed").Trim()

        if ($answer -ne 'yes') {
            Write-Host "Aborted." -ForegroundColor DarkGray
            return
        }
    }

    Stop-OllamaModels
    Remove-ModelAliases -Key $Key
    Remove-ModelRemotePull -Key $Key

    if ($folder -and (Test-Path $folder)) {
        Remove-Item -Recurse -Force $folder -ErrorAction SilentlyContinue
    }

    foreach ($alias in $hostedAliases) {
        $cfg.CommandAliases.Remove($alias)

        $existingAlias = Get-Item -Path "Alias:$alias" -ErrorAction SilentlyContinue
        if ($existingAlias) {
            Remove-Item -Path "Alias:$alias" -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($shortcutName in $shortcutNames) {
        Remove-Item -Path "function:global:$shortcutName" -Force -ErrorAction SilentlyContinue
    }

    $cfg.Models.Remove($Key)

    Save-LocalLLMConfig -Cfg $cfg

    Reload-LocalLLMConfig

    Write-Host ""
    Write-Host "Removed '$Key'." -ForegroundColor Green
}

function removellm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Key,
        [switch]$KeepFiles,
        [switch]$Force
    )

    Remove-LocalLLMModel @PSBoundParameters
}

function rmllm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Key,
        [switch]$KeepFiles,
        [switch]$Force
    )

    Remove-LocalLLMModel @PSBoundParameters
}

# -------------------------
# Orphan Ollama models: present locally but not in llm-models.json
# -------------------------

function Get-AllManagedOllamaNames {
    # Names this profile considers "managed" -- every alias the catalog declares
    # as well as the upstream remote pull (e.g. "devstral-small-2:latest"), with
    # and without ":latest" so matches against `ollama list` succeed both ways.
    $names = New-Object System.Collections.Generic.Hashset[string] ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($key in (Get-ModelKeys)) {
        $def = Get-ModelDef -Key $key

        foreach ($alias in (Get-ModelAliasNames -Def $def)) {
            $names.Add($alias) | Out-Null
            $names.Add("${alias}:latest") | Out-Null
        }

        if ($def.SourceType -eq 'remote' -and $def.RemoteModel) {
            $names.Add($def.RemoteModel) | Out-Null

            if ($def.RemoteModel -notlike '*:*') {
                $names.Add("$($def.RemoteModel):latest") | Out-Null
            }
            elseif ($def.RemoteModel -like '*:latest') {
                $names.Add($def.RemoteModel.Substring(0, $def.RemoteModel.Length - 7)) | Out-Null
            }
        }
    }

    return $names
}

function Find-OrphanOllamaModels {
    [CmdletBinding()]
    param()

    $managed = Get-AllManagedOllamaNames
    $rawList = & ollama list 2>$null | Select-Object -Skip 1
    $orphans = New-Object System.Collections.Generic.List[pscustomobject]

    foreach ($line in $rawList) {
        if (-not $line.Trim()) { continue }

        $parts = $line -split '\s+'
        if ($parts.Count -lt 3) { continue }

        $name = $parts[0]

        if ($managed.Contains($name)) { continue }

        $base = if ($name -like '*:latest') { $name.Substring(0, $name.Length - 7) } else { $name }
        if ($managed.Contains($base)) { continue }

        $orphans.Add([pscustomobject]@{
                Name = $name
                Id   = $parts[1]
                Size = ($parts[2..3] -join ' ')
            }) | Out-Null
    }

    return $orphans
}

function Remove-OrphanOllamaModels {
    [CmdletBinding()]
    param([switch]$Force)

    $orphans = @(Find-OrphanOllamaModels)

    if ($orphans.Count -eq 0) {
        Write-Host "No orphan Ollama models found." -ForegroundColor Green
        return
    }

    Write-Host ""
    Write-Host "Orphan Ollama models (in 'ollama list' but not in llm-models.json):" -ForegroundColor Yellow
    Write-Host ""
    $orphans | Format-Table -AutoSize | Out-String | Write-Host

    if (-not $Force) {
        $answer = (Read-Host "Type 'yes' to remove all $($orphans.Count) orphan model(s)").Trim()

        if ($answer -ne 'yes') {
            Write-Host "Aborted." -ForegroundColor DarkGray
            return
        }
    }

    Stop-OllamaModels

    foreach ($orphan in $orphans) {
        Write-Host "Removing $($orphan.Name)..." -ForegroundColor DarkGray
        & ollama rm $orphan.Name 2>$null | Out-Null
    }

    Write-Host ""
    Write-Host "Removed $($orphans.Count) orphan model(s)." -ForegroundColor Green
}

function cleanorphans {
    [CmdletBinding()]
    param([switch]$Force)

    Remove-OrphanOllamaModels -Force:$Force
}

function listorphans {
    $orphans = @(Find-OrphanOllamaModels)

    if ($orphans.Count -eq 0) {
        Write-Host "No orphan Ollama models." -ForegroundColor Green
        return
    }

    $orphans | Format-Table -AutoSize
}

# -------------------------
# Claude / free-code / proxy helpers
# -------------------------

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

function Invoke-FreeCodeCli {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments)]
        [string[]]$CliArgs
    )

    $root = $script:Cfg.FreeCodeRoot

    if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
        throw "bun is not on PATH."
    }

    $nodeModules = Join-Path $root "node_modules"

    if (-not (Test-Path $nodeModules)) {
        Write-Host "Installing free-code dependencies..." -ForegroundColor Cyan

        & bun install --cwd $root

        if ($LASTEXITCODE -ne 0) {
            throw "bun install failed for free-code"
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
        [switch]$FreeCode,
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
        if ($keepThinking) {
            # Skip the strip proxy and let thinking blocks reach Ollama directly.
            $env:ANTHROPIC_BASE_URL = "http://localhost:11434"
        }
        else {
            $env:ANTHROPIC_BASE_URL = "http://localhost:$($script:NoThinkProxyPort)"
        }

        $env:ANTHROPIC_AUTH_TOKEN = "ollama"
        $env:ANTHROPIC_API_KEY = ""

        $env:ANTHROPIC_MODEL = $Model
        $env:ANTHROPIC_DEFAULT_OPUS_MODEL = $Model
        $env:ANTHROPIC_DEFAULT_SONNET_MODEL = $Model
        $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $Model

        if (-not $keepThinking) {
            $env:CLAUDE_CODE_DISABLE_THINKING = "1"
            $env:MAX_THINKING_TOKENS = "0"
            $env:CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING = "1"
        }

        $env:CLAUDE_CODE_ATTRIBUTION_HEADER = "0"
        $env:DISABLE_PROMPT_CACHING = "1"

        $backendLabel = if ($FreeCode) { "free-code" } else { "claude" }
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

        if ($FreeCode) {
            Invoke-FreeCodeCli @launchArgs
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
        return "Ollama -> $($env:ANTHROPIC_DEFAULT_OPUS_MODEL) @ $($env:ANTHROPIC_BASE_URL)"
    }

    return "Default (Anthropic API)"
}

# -------------------------
# Benchmarks
# -------------------------

function Test-OllamaSpeed {
    [CmdletBinding()]
    param(
        [string]$Model,
        [string]$Prompt = "Write a compact but detailed explanation of why CPU offload slows local LLM inference. About 500 words.",
        [ValidateRange(1, 8192)][int]$NumPredict = 512,
        [ValidateRange(1, 20)][int]$Runs = 1,
        [switch]$ShowResponse
    )

    if ([string]::IsNullOrWhiteSpace($Model)) {
        $loaded = @(Get-OllamaLoadedModels)

        if (-not $loaded -or $loaded.Count -eq 0) {
            throw "No model specified and no Ollama model is currently loaded. Usage: Test-OllamaSpeed q36plus"
        }

        $Model = $loaded[0].Name
    }

    $results = @()

    for ($i = 1; $i -le $Runs; $i++) {
        Write-Host "Benchmarking $Model, run $i/$Runs..." -ForegroundColor Cyan

        $body = @{
            model    = $Model
            messages = @(@{ role = "user"; content = $Prompt })
            stream   = $false
            options  = @{ num_predict = $NumPredict }
        } | ConvertTo-Json -Depth 8

        try {
            $result = Invoke-RestMethod `
                -Uri "http://localhost:11434/api/chat" `
                -Method Post `
                -ContentType "application/json" `
                -Body $body

            $promptTps = if ($result.prompt_eval_duration -gt 0) {
                [math]::Round(($result.prompt_eval_count / $result.prompt_eval_duration) * 1e9, 2)
            }
            else { 0 }

            $outputTps = if ($result.eval_duration -gt 0) {
                [math]::Round(($result.eval_count / $result.eval_duration) * 1e9, 2)
            }
            else { 0 }

            $item = [pscustomobject]@{
                Run                   = $i
                Model                 = $Model
                PromptTokens          = $result.prompt_eval_count
                PromptTokensPerSecond = $promptTps
                OutputTokens          = $result.eval_count
                OutputTokensPerSecond = $outputTps
                TotalSeconds          = [math]::Round($result.total_duration / 1e9, 2)
                LoadSeconds           = [math]::Round($result.load_duration / 1e9, 2)
            }

            $results += $item

            $historyEntry = [ordered]@{
                timestamp             = (Get-Date).ToString("o")
                model                 = $Model
                run                   = $i
                num_predict           = $NumPredict
                prompt_tokens         = [int]$result.prompt_eval_count
                prompt_tokens_per_sec = $promptTps
                output_tokens         = [int]$result.eval_count
                output_tokens_per_sec = $outputTps
                total_seconds         = [math]::Round($result.total_duration / 1e9, 2)
                load_seconds          = [math]::Round($result.load_duration / 1e9, 2)
            }

            $line = ($historyEntry | ConvertTo-Json -Compress -Depth 4)
            Add-Content -Path (Get-LLMBenchHistoryFile) -Value $line -Encoding UTF8

            if ($ShowResponse) {
                Write-Host ""
                Write-Host "Response:" -ForegroundColor Yellow
                Write-Host $result.message.content
                Write-Host ""
            }
        }
        catch {
            $details = $_.Exception.Message

            if ($_.Exception.Response) {
                try {
                    $stream = $_.Exception.Response.GetResponseStream()
                    $reader = [System.IO.StreamReader]::new($stream)
                    $responseBody = $reader.ReadToEnd()

                    if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
                        $details = "$details`n$responseBody"
                    }
                }
                catch {
                }
            }

            throw "Ollama benchmark failed for '$Model': $details"
        }
    }

    $results | Format-Table -AutoSize

    if ($results.Count -gt 1) {
        Write-Host ""
        Write-Host "Average:" -ForegroundColor Yellow

        [pscustomobject]@{
            Model                    = $Model
            Runs                     = $results.Count
            AvgPromptTokensPerSecond = [math]::Round(($results | Measure-Object PromptTokensPerSecond -Average).Average, 2)
            AvgOutputTokensPerSecond = [math]::Round(($results | Measure-Object OutputTokensPerSecond -Average).Average, 2)
            AvgTotalSeconds          = [math]::Round(($results | Measure-Object TotalSeconds -Average).Average, 2)
            AvgLoadSeconds           = [math]::Round(($results | Measure-Object LoadSeconds -Average).Average, 2)
        } | Format-Table -AutoSize
    }
}

function ospeed {
    param(
        [string]$Model,
        [int]$Runs = 1,
        [int]$NumPredict = 512
    )

    Test-OllamaSpeed -Model $Model -Runs $Runs -NumPredict $NumPredict
}

function Get-LLMBenchHistoryFile {
    return Join-Path $script:LLMProfileRoot "bench-history.jsonl"
}

function Read-LLMBenchHistoryEntries {
    $historyFile = Get-LLMBenchHistoryFile

    if (-not (Test-Path $historyFile)) {
        return @()
    }

    $lines = Get-Content -Path $historyFile -Encoding UTF8

    $entries = foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { ConvertFrom-Json $line } catch { continue }
    }

    return @($entries)
}

function Show-LLMBenchHistory {
    [CmdletBinding()]
    param(
        [string]$Model,
        [int]$Last = 20
    )

    $entries = @(Read-LLMBenchHistoryEntries)

    if ($entries.Count -eq 0) {
        Write-Host "No benchmark history yet. Run 'ospeed <model>' to record." -ForegroundColor DarkGray
        return
    }

    if ($Model) {
        $entries = @($entries | Where-Object { $_.model -eq $Model })
    }

    $entries = @($entries | Select-Object -Last $Last)

    if ($entries.Count -eq 0) {
        Write-Host "No matching entries." -ForegroundColor DarkGray
        return
    }

    $entries | Select-Object timestamp, model, output_tokens_per_sec, prompt_tokens_per_sec, total_seconds | Format-Table -AutoSize
}

function Trim-LLMBenchHistory {
    [CmdletBinding()]
    param(
        [int]$OlderThanDays = 90,
        [switch]$DryRun
    )

    $historyFile = Get-LLMBenchHistoryFile

    if (-not (Test-Path $historyFile)) {
        Write-Host "No benchmark history file." -ForegroundColor DarkGray
        return
    }

    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $entries = @(Read-LLMBenchHistoryEntries)
    $kept = @()
    $dropped = 0

    foreach ($entry in $entries) {
        $ts = $null
        if ([DateTime]::TryParse($entry.timestamp, [ref]$ts) -and $ts -lt $cutoff) {
            $dropped++
            continue
        }
        $kept += $entry
    }

    if ($dropped -eq 0) {
        Write-Host "Nothing to trim. $($entries.Count) entries, none older than $OlderThanDays days." -ForegroundColor Green
        return
    }

    if ($DryRun) {
        Write-Host "[dry-run] Would drop $dropped entries older than $OlderThanDays days, keep $($kept.Count)." -ForegroundColor Cyan
        return
    }

    $tmp = "$historyFile.tmp"
    if (Test-Path $tmp) { Remove-Item $tmp -Force }

    foreach ($entry in $kept) {
        Add-Content -Path $tmp -Value ($entry | ConvertTo-Json -Compress -Depth 4) -Encoding UTF8
    }

    Move-Item -Path $tmp -Destination $historyFile -Force
    Write-Host "Dropped $dropped entries, kept $($kept.Count)." -ForegroundColor Green
}

function obench { Show-LLMBenchHistory @args }

# -------------------------
# Info / docs
# -------------------------

function Show-ClaudeTarget {
    Write-Section "Claude"
    Write-Host "Target : $(Get-ClaudeTargetSummary)" -ForegroundColor Yellow
}

function Show-OllamaStatus {
    param([switch]$All)

    Write-Section "Ollama"

    $loaded = Get-OllamaLoadedModels

    if (-not $loaded -or $loaded.Count -eq 0) {
        Write-Host "Loaded models : none"
    }
    else {
        Write-Host "Loaded models :" -ForegroundColor Yellow

        foreach ($item in $loaded) {
            Write-Host "  $($item.Name)  |  ctx $($item.Context)  |  $($item.Processor)  |  $($item.Size)"
        }
    }

    $stale = @(Get-StaleModelAliases)

    if ($stale.Count -gt 0) {
        Write-Host ""
        Write-Host "Stale aliases (this profile would emit a different Modelfile now): $($stale.Count)" -ForegroundColor Yellow
        foreach ($entry in $stale) {
            Write-Host "  $($entry.AliasName)" -ForegroundColor DarkYellow
        }
        Write-Host "  Run 'init -Stale' to rebuild only the stale ones." -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "Configured GGUF quants/files:" -ForegroundColor Yellow

    foreach ($key in (Get-FilteredModelKeys -IncludeAll:$All)) {
        $def = Get-ModelDef -Key $key

        if ($def.ContainsKey("Quants")) {
            Write-Host "  $key -> $($def.Quant) ($($def.Quants[$def.Quant]))"
        }
        elseif ($def.SourceType -eq "gguf") {
            Write-Host "  $key -> $(Get-ModelFileName -Def $def)"
        }
    }
}

function Format-AliasBuiltList {
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][object]$Installed
    )

    $parts = foreach ($name in $Names) {
        if ($Installed -contains $name -or $Installed -contains "${name}:latest") {
            "+$name"
        }
        else {
            "-$name"
        }
    }

    return ($parts -join ', ')
}

function Show-ModelCatalog {
    param([switch]$All)

    Write-Section "Commands"

    $visibleKeys = @(Get-FilteredModelKeys -IncludeAll:$All)
    $installed = @(Get-OllamaInstalledModelNames)

    foreach ($key in $visibleKeys) {
        $def = Get-ModelDef -Key $key
        $cmdName = Get-ModelShortcutName -Def $def

        $contextKeys = @($def.Contexts.Keys)
        $contextLabels = $contextKeys | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace($_)) { "default" } else { $_ }
        }
        $ctxFlag = if ($contextKeys.Count -gt 1) {
            "[-Ctx $($contextLabels -join '|')]"
        } else {
            ""
        }

        $aliases = $contextKeys | ForEach-Object { Get-ModelAliasName -Def $def -ContextKey $_ }

        $tierBadge = Format-ModelTierBadge -Def $def

        Write-Host "$($def.DisplayName) " -ForegroundColor White -NoNewline
        Write-Host $tierBadge -ForegroundColor DarkYellow

        $usage = "$cmdName $ctxFlag [-Fc] [-Chat] [-Q8]".Trim()

        if ($def.ContainsKey("Quants")) {
            $quantNames = @($def.Quants.Keys) -join '|'
            $usage += " [-Quant $quantNames]"
        }

        Write-Host "  $usage" -ForegroundColor White
        Write-Host "  Built  : $(Format-AliasBuiltList -Names $aliases -Installed $installed)" -ForegroundColor DarkGray

        if ($def.Contains("Tools") -and -not [string]::IsNullOrWhiteSpace($def.Tools)) {
            Write-Host "  Tools  : $($def.Tools)" -ForegroundColor DarkGray
        }

        Write-Host ""
    }

    if (-not $All) {
        $hiddenCount = (@(Get-ModelKeys)).Count - $visibleKeys.Count

        if ($hiddenCount -gt 0) {
            Write-Host "$hiddenCount more model(s) hidden. Run 'info -All' to see them, or set Tier in llm-models.json." -ForegroundColor DarkGray
            Write-Host ""
        }
    }

    Write-Host "Built-status legend: +name = Ollama alias exists, -name = not yet built" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Manage:" -ForegroundColor White
    Write-Host "  addllm <hf-url> -Key <key>     Add a model from HuggingFace" -ForegroundColor DarkGray
    Write-Host "  removellm <key>                Remove a model + its files" -ForegroundColor DarkGray
    Write-Host "  initmodel <key> [-Force]       (Re)build Ollama aliases for a model" -ForegroundColor DarkGray
    Write-Host "  cleanorphans                   List Ollama models not in llm-models.json" -ForegroundColor DarkGray
    Write-Host "  reloadllm, purge, ops, qkill, ostop, llm, llmdocs" -ForegroundColor DarkGray
    Write-Host "  Config: $script:LocalLLMConfigPath" -ForegroundColor DarkGray
}

function Show-LLMProfileInfo {
    param([switch]$All)

    Clear-Host
    Write-Host "Local LLM dashboard" -ForegroundColor Green

    Show-ClaudeTarget
    Show-OllamaStatus -All:$All
    Show-ModelCatalog -All:$All

    Write-Host ""
}

function info {
    [CmdletBinding()]
    param([switch]$All)
    Show-LLMProfileInfo -All:$All
}

function llminfo {
    [CmdletBinding()]
    param([switch]$All)
    Show-LLMProfileInfo -All:$All
}

function llmdocs { Show-LLMQuickReference }
function docs { Show-LLMQuickReference }
function llmhelp { Show-LLMQuickReference }
function reloadllm { Reload-LocalLLMConfig }

# -------------------------
# Setup / teardown
# -------------------------

function Initialize-LocalLLM {
    [CmdletBinding()]
    param(
        [string[]]$Keys,
        [switch]$Force,
        [switch]$All,
        [switch]$Stale
    )

    Write-Host ""
    Write-Host "=== Local LLM Setup ===" -ForegroundColor Green
    Write-Host ""

    if (-not (Test-OllamaVersionMinimum -MinVersion $script:Cfg.MinOllamaVersion)) {
        $raw = & ollama --version 2>$null
        Write-Host "ERROR: Ollama >= $($script:Cfg.MinOllamaVersion) required (got: $raw)" -ForegroundColor Red
        Write-Host "Update: winget upgrade Ollama.Ollama" -ForegroundColor Yellow
        return
    }

    if ($Stale) {
        $staleEntries = @(Get-StaleModelAliases)

        if ($staleEntries.Count -eq 0) {
            Write-Host "No stale aliases." -ForegroundColor Green
            return
        }

        Write-Host "Rebuilding $($staleEntries.Count) stale alias(es)..." -ForegroundColor Cyan

        foreach ($entry in $staleEntries) {
            Write-Host "  rebuilding: $($entry.AliasName)" -ForegroundColor DarkGray
            Ensure-ModelAlias -Key $entry.Key -ContextKey $entry.Context -ForceRebuild | Out-Null
        }

        Write-Host ""
        Write-Host "Done." -ForegroundColor Green
        return
    }

    if (-not $Keys -or $Keys.Count -eq 0) {
        $Keys = Get-FilteredModelKeys -IncludeAll:$All
    }

    if ($Keys.Count -eq 0) {
        Write-Host "No models to set up." -ForegroundColor Yellow
        return
    }

    $step = 1
    $total = $Keys.Count

    foreach ($key in $Keys) {
        $def = Get-ModelDef -Key $key
        Write-Host ("Step {0}/{1}: Setting up {2}..." -f $step, $total, $def.DisplayName) -ForegroundColor Cyan
        Ensure-ModelAllAliases -Key $key -ForceRebuild:$Force
        $step++
    }

    Write-Host ""
    Write-Host "Setup complete. Run 'info' to verify." -ForegroundColor Green
    Write-Host ""
}

function Initialize-LocalLLMModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Keys,
        [switch]$Force
    )

    Initialize-LocalLLM -Keys $Keys -Force:$Force
}

function Remove-AllLocalLLM {
    param([switch]$DeleteFiles)

    Write-Host ""

    if ($DeleteFiles) {
        Write-Host "=== Full Purge (models + GGUF files) ===" -ForegroundColor Red
    }
    else {
        Write-Host "=== Cleanup (models only) ===" -ForegroundColor Yellow
    }

    Write-Host ""

    Stop-OllamaModels
    Stop-OllamaApp
    Reset-OllamaEnv

    foreach ($key in (Get-ModelKeys)) {
        Remove-ModelAliases -Key $key
        Remove-ModelRemotePull -Key $key

        if ($DeleteFiles) {
            Remove-ModelFiles -Key $key
        }
    }

    Start-OllamaApp
    Wait-Ollama

    Write-Host ""
    Write-Host "Done." -ForegroundColor Green
    Write-Host ""
}

function Teardown-Ollama {
    param([switch]$DeleteFiles)

    Stop-OllamaModels
    Stop-OllamaApp
    Reset-OllamaEnv

    if ($DeleteFiles) {
        foreach ($key in (Get-ModelKeys)) {
            Remove-ModelAliases -Key $key
            Remove-ModelRemotePull -Key $key
            Remove-ModelFiles -Key $key
        }
    }

    Start-OllamaApp
    Wait-Ollama
}

function init {
    [CmdletBinding()]
    param([switch]$Force, [switch]$All, [switch]$Stale)
    Initialize-LocalLLM -Force:$Force -All:$All -Stale:$Stale
}

function initmodel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Keys,
        [switch]$Force
    )
    Initialize-LocalLLMModel -Keys $Keys -Force:$Force
}

function purge { Remove-AllLocalLLM -DeleteFiles }
function ostop { Teardown-Ollama }
function qkill { Stop-OllamaModels }
function ops { & ollama ps }

# -------------------------
# Generic launcher
# -------------------------

function Invoke-ModelShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [switch]$UseQ8,
        [switch]$FreeCode,
        [switch]$Chat
    )

    $def = Get-ModelDef -Key $Key
    $modelName = Ensure-ModelAlias -Key $Key -ContextKey $ContextKey

    if ($Chat) {
        Start-OllamaChat -Model $modelName -UseQ8:$UseQ8
        return
    }

    $toolsList = if ($def.Contains("Tools") -and -not [string]::IsNullOrWhiteSpace($def.Tools)) {
        $def.Tools
    } else {
        $script:Cfg.LocalModelTools
    }

    $thinkingPolicy = if ($def.Contains("ThinkingPolicy") -and -not [string]::IsNullOrWhiteSpace($def.ThinkingPolicy)) {
        $def.ThinkingPolicy
    } else {
        "strip"
    }

    $startArgs = @{
        Model          = $modelName
        Tools          = $toolsList
        ThinkingPolicy = $thinkingPolicy
        UseQ8          = $UseQ8
        LimitTools     = [bool]$def.LimitTools
        FreeCode       = $FreeCode
    }

    if ($def.Contains("IncludeInlineToolSchemas")) {
        $startArgs.IncludeInlineToolSchemas = [bool]$def.IncludeInlineToolSchemas
    }

    Start-ClaudeWithOllamaModel @startArgs
}

# -------------------------
# Dynamic shortcut registration
# -------------------------

function Register-ShortcutFunction {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    Set-Item -Path ("function:global:{0}" -f $Name) -Value $ScriptBlock -Force
}

function Get-ModelShortcutName {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def)

    if ($Def.Contains("ShortName") -and -not [string]::IsNullOrWhiteSpace($Def.ShortName)) {
        return $Def.ShortName
    }

    return $Def.Root
}

function Unregister-AllModelShortcuts {
    # Idempotent cleanup: remove any function we may have registered earlier
    # (with the old multi-suffix scheme or the new single-function scheme).
    foreach ($key in (Get-ModelKeys)) {
        $def = Get-ModelDef -Key $key

        $names = New-Object System.Collections.Generic.HashSet[string]
        $names.Add((Get-ModelShortcutName -Def $def)) | Out-Null

        foreach ($contextKey in $def.Contexts.Keys) {
            $base = Get-ModelAliasName -Def $def -ContextKey $contextKey
            foreach ($suffix in @("", "fc", "chat", "q8", "q8fc")) {
                $names.Add("$base$suffix") | Out-Null
            }
        }

        if ($def.ContainsKey("Quants") -and $def.Contains("QuantShortcut")) {
            foreach ($quantKey in $def.Quants.Keys) {
                $names.Add("set$($def.QuantShortcut)$quantKey") | Out-Null
            }
        }

        foreach ($name in $names) {
            Remove-Item -Path "function:global:$name" -Force -ErrorAction SilentlyContinue
            Remove-Item -Path "alias:$name" -Force -ErrorAction SilentlyContinue
        }
    }
}

function Register-ModelShortcuts {
    Unregister-AllModelShortcuts

    foreach ($key in (Get-ModelKeys)) {
        $def = Get-ModelDef -Key $key
        $name = Get-ModelShortcutName -Def $def
        $k = $key

        Register-ShortcutFunction -Name $name -ScriptBlock ({
                [CmdletBinding()]
                param(
                    [string]$Ctx = "",
                    [string]$Quant,
                    [Alias("Fc")][switch]$FreeCode,
                    [switch]$Chat,
                    [switch]$Q8
                )

                if ($Quant) {
                    Set-ModelQuant -Key $k -Quant $Quant
                    return
                }

                Invoke-ModelShortcut -Key $k -ContextKey $Ctx -UseQ8:$Q8 -FreeCode:$FreeCode -Chat:$Chat
            }.GetNewClosure())
    }

    # Manual aliases from JSON (rarely needed under the flag-based scheme,
    # kept as an escape hatch).
    if ($script:Cfg.CommandAliases) {
        foreach ($alias in @($script:Cfg.CommandAliases.Keys)) {
            $target = $script:Cfg.CommandAliases[$alias]

            if ($alias -ne $target) {
                Set-Alias -Name $alias -Value $target -Scope Global -Force
            }
        }
    }
}

Register-ModelShortcuts

function Resolve-ModelKeyByAnyName {
    # Accepts a model key, ShortName, or Root and returns the canonical key.
    # Returns $null if no match.
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($script:Cfg.Models.Contains($Name)) {
        return $Name
    }

    foreach ($key in (Get-ModelKeys)) {
        $def = Get-ModelDef -Key $key

        if ($def.Contains("ShortName") -and $def.ShortName -eq $Name) {
            return $key
        }

        if ($def.Root -eq $Name) {
            return $key
        }
    }

    return $null
}

function Find-WorkspaceDefaultModelKey {
    # Walk up from $PWD looking for a .llm-default file. First match wins.
    # Stops at filesystem root. Returns $null if nothing found.
    # File contents may be a key, ShortName, or Root.
    $dir = (Get-Location).Path

    while (-not [string]::IsNullOrWhiteSpace($dir)) {
        $marker = Join-Path $dir ".llm-default"

        if (Test-Path $marker) {
            $value = (Get-Content -Raw -Path $marker -ErrorAction SilentlyContinue).Trim()

            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $resolved = Resolve-ModelKeyByAnyName -Name $value

                if ($resolved) {
                    return $resolved
                }

                Write-Warning "$marker references unknown model '$value'; ignoring."
                return $null
            }
        }

        $parent = Split-Path -Parent $dir

        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) {
            break
        }

        $dir = $parent
    }

    return $null
}

function Get-DefaultModelKey {
    $workspace = Find-WorkspaceDefaultModelKey

    if ($workspace) {
        return $workspace
    }

    if ($script:Cfg.Contains("Default") -and -not [string]::IsNullOrWhiteSpace($script:Cfg.Default)) {
        return $script:Cfg.Default
    }

    $recommended = @(Get-FilteredModelKeys)

    if ($recommended.Count -gt 0) {
        return $recommended[0]
    }

    throw "No default model: create a .llm-default file in this workspace, set 'Default' in llm-models.json, or add a recommended model."
}

function llmdefault     { Invoke-ModelShortcut -Key (Get-DefaultModelKey) -ContextKey "" }
function llmdefaultfc   { Invoke-ModelShortcut -Key (Get-DefaultModelKey) -ContextKey "" -FreeCode }
function llmdefaultchat { Invoke-ModelShortcut -Key (Get-DefaultModelKey) -ContextKey "" -Chat }

# Enforcer — use local backend wrapper.
$env:ENFORCER_CLAUDE_CMD = "pwsh -NoProfile -File $HOME\.ollama-proxy\enforcer-claude.ps1"

# -------------------------
# Hierarchical dynamic UI
# -------------------------
# This overrides the old flat llmmenu with a guided model -> quant -> context -> action flow.
# The generated short commands still exist, but the menu is now much easier to use.

function Format-LLMContextLabel {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey
    )

    $aliasName = Get-ModelAliasName -Def $Def -ContextKey $ContextKey
    $ctx = Get-ModelContextValue -Def $Def -ContextKey $ContextKey

    if ([string]::IsNullOrWhiteSpace($ContextKey)) {
        return "$aliasName  ($ctx tokens, default)"
    }

    return "$aliasName  ($ctx tokens, $ContextKey)"
}

function Read-LLMChoiceIndex {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)][scriptblock]$Label,
        [string]$ZeroLabel = "Back"
    )

    while ($true) {
        Write-Section $Title

        for ($i = 0; $i -lt $Items.Count; $i++) {
            $num = $i + 1
            $labelText = & $Label $Items[$i] $i
            Write-Host ("{0,3}  {1}" -f $num, $labelText)
        }

        Write-Host ""
        Write-Host ("  0  {0}" -f $ZeroLabel) -ForegroundColor Yellow
        Write-Host ""

        $choice = (Read-Host "Choose").Trim()

        if ($choice -eq "0") {
            return -1
        }

        if (-not ($choice -match '^\d+$')) {
            Write-Host "Invalid selection." -ForegroundColor Red
            continue
        }

        $index = [int]$choice - 1

        if ($index -lt 0 -or $index -ge $Items.Count) {
            Write-Host "Selection out of range." -ForegroundColor Red
            continue
        }

        return $index
    }
}

function Select-LLMModelKey {
    param([switch]$All)

    $keys = @(Get-FilteredModelKeys -IncludeAll:$All)

    if ($keys.Count -eq 0) {
        Write-Host "No models match the current filter." -ForegroundColor Yellow
        return $null
    }

    $idx = Read-LLMChoiceIndex `
        -Title $(if ($All) { "Select model (all tiers)" } else { "Select model (recommended)" }) `
        -Items $keys `
        -ZeroLabel $(if ($All) { "Cancel" } else { "Show all tiers / cancel" }) `
        -Label {
        param($key, $i)
        $def = Get-ModelDef -Key $key
        $quant = if ($def.ContainsKey("Quants")) { " | quant: $($def.Quant)" } else { "" }
        $contexts = ($def.Contexts.Keys | ForEach-Object {
                if ([string]::IsNullOrWhiteSpace($_)) { "default" } else { $_ }
            }) -join ", "
        return "$key  ->  $($def.DisplayName)$quant | contexts: $contexts"
    }

    if ($idx -lt 0) {
        return $null
    }

    return $keys[$idx]
}

function Select-LLMQuantKey {
    param([Parameter(Mandatory = $true)][string]$ModelKey)

    $def = Get-ModelDef -Key $ModelKey

    if (-not $def.ContainsKey("Quants")) {
        return $null
    }

    $quantKeys = @($def.Quants.Keys)

    $idx = Read-LLMChoiceIndex `
        -Title "Select quant for $ModelKey" `
        -Items $quantKeys `
        -ZeroLabel "Keep current: $($def.Quant)" `
        -Label {
        param($quantKey, $i)
        $current = if ($quantKey -eq $def.Quant) { "  [current]" } else { "" }
        return "$quantKey  ->  $($def.Quants[$quantKey])$current"
    }

    if ($idx -lt 0) {
        return $def.Quant
    }

    return $quantKeys[$idx]
}

function Select-LLMContextKey {
    param([Parameter(Mandatory = $true)][string]$ModelKey)

    $def = Get-ModelDef -Key $ModelKey
    $contextKeys = @($def.Contexts.Keys)

    $idx = Read-LLMChoiceIndex `
        -Title "Select context for $ModelKey" `
        -Items $contextKeys `
        -ZeroLabel "Back" `
        -Label {
        param($contextKey, $i)
        return (Format-LLMContextLabel -Def $def -ContextKey $contextKey)
    }

    if ($idx -lt 0) {
        return $null
    }

    return $contextKeys[$idx]
}

function Select-LLMAction {
    $actions = @(
        [pscustomobject]@{ Key = "claude"; Label = "Claude Code"; Description = "Local model behind Claude Code" },
        [pscustomobject]@{ Key = "fc"; Label = "free-code"; Description = "Local agent via free-code" },
        [pscustomobject]@{ Key = "chat"; Label = "Ollama chat"; Description = "Plain ollama run" },
        [pscustomobject]@{ Key = "benchmark"; Label = "Benchmark"; Description = "Run ospeed for selected alias" },
        [pscustomobject]@{ Key = "setup"; Label = "Setup/create alias only"; Description = "Download/create selected alias" },
        [pscustomobject]@{ Key = "show"; Label = "Show ollama model info"; Description = "Run ollama show" }
    )

    $idx = Read-LLMChoiceIndex `
        -Title "Select action" `
        -Items $actions `
        -ZeroLabel "Back" `
        -Label {
        param($action, $i)
        return "$($action.Label)  -  $($action.Description)"
    }

    if ($idx -lt 0) {
        return $null
    }

    return $actions[$idx].Key
}

function Set-ModelQuantForSelectedLaunch {
    param(
        [Parameter(Mandatory = $true)][string]$ModelKey,
        [Parameter(Mandatory = $true)][string]$QuantKey
    )

    $def = Get-ModelDef -Key $ModelKey

    if (-not $def.ContainsKey("Quants")) {
        return
    }

    if ($def.Quant -eq $QuantKey) {
        return
    }

    $resolvedQuant = Resolve-ModelQuantKey -Def $def -Quant $QuantKey
    $def.Quant = $resolvedQuant

    # Important: aliases point at a specific GGUF through their Modelfile.
    # When switching quant, remove existing aliases so the selected alias is rebuilt correctly.
    Remove-ModelAliases -Key $ModelKey

    Write-Host "$ModelKey session quant set to $resolvedQuant -> $($def.Quants[$resolvedQuant])" -ForegroundColor Green
}

function Read-LLMQ8Toggle {
    while ($true) {
        Write-Host ""
        $answer = (Read-Host "Use q8 KV cache? [y/N]").Trim().ToLowerInvariant()

        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -in @("n", "no")) { return $false }
        if ($answer -in @("y", "yes")) { return $true }

        Write-Host "Answer y or n." -ForegroundColor Red
    }
}

function Invoke-LLMSelection {
    param(
        [Parameter(Mandatory = $true)][string]$ModelKey,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][string]$Action,
        [switch]$UseQ8
    )

    switch ($Action) {
        "chat" {
            Invoke-ModelShortcut -Key $ModelKey -ContextKey $ContextKey -Chat -UseQ8:$UseQ8
        }

        "fc" {
            Invoke-ModelShortcut -Key $ModelKey -ContextKey $ContextKey -FreeCode -UseQ8:$UseQ8
        }

        "claude" {
            Invoke-ModelShortcut -Key $ModelKey -ContextKey $ContextKey -UseQ8:$UseQ8
        }

        "benchmark" {
            $modelName = Ensure-ModelAlias -Key $ModelKey -ContextKey $ContextKey
            Test-OllamaSpeed -Model $modelName -Runs 3
        }

        "setup" {
            $modelName = Ensure-ModelAlias -Key $ModelKey -ContextKey $ContextKey -ForceRebuild
            Write-Host "Created/rebuilt alias: $modelName" -ForegroundColor Green
        }

        "show" {
            $modelName = Ensure-ModelAlias -Key $ModelKey -ContextKey $ContextKey
            & ollama show $modelName
        }

        default {
            throw "Unknown action: $Action"
        }
    }
}

function Start-LLMWizard {
    while ($true) {
        Clear-Host
        Write-Host "Local LLM launcher" -ForegroundColor Green
        Write-Host "Config: $script:LocalLLMConfigPath" -ForegroundColor DarkGray

        $modelKey = Select-LLMModelKey

        if ([string]::IsNullOrWhiteSpace($modelKey)) {
            return
        }

        $def = Get-ModelDef -Key $modelKey

        if ($def.ContainsKey("Quants")) {
            $quantKey = Select-LLMQuantKey -ModelKey $modelKey
            Set-ModelQuantForSelectedLaunch -ModelKey $modelKey -QuantKey $quantKey
        }

        $contextKey = Select-LLMContextKey -ModelKey $modelKey

        if ($null -eq $contextKey) {
            continue
        }

        $action = Select-LLMAction

        if ([string]::IsNullOrWhiteSpace($action)) {
            continue
        }

        $useQ8 = $false
        if ($action -in @("chat", "fc", "claude")) {
            $useQ8 = Read-LLMQ8Toggle
        }

        try {
            Invoke-LLMSelection -ModelKey $modelKey -ContextKey $contextKey -Action $action -UseQ8:$useQ8
        }
        catch {
            Write-Host "Command failed." -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor DarkGray
            Pause-Menu
        }
    }
}

function Show-LLMDynamicModelSummary {
    Write-Section "Configured models (by tier)"

    $tierOrder = @("recommended", "experimental", "legacy")
    $byTier = @{}

    foreach ($tier in $tierOrder) {
        $byTier[$tier] = New-Object System.Collections.Generic.List[string]
    }

    foreach ($key in (Get-ModelKeys)) {
        $def = Get-ModelDef -Key $key
        $tier = Get-ModelTier -Def $def

        if (-not $byTier.ContainsKey($tier)) {
            $byTier[$tier] = New-Object System.Collections.Generic.List[string]
            $tierOrder += $tier
        }

        $byTier[$tier].Add($key) | Out-Null
    }

    foreach ($tier in $tierOrder) {
        if ($byTier[$tier].Count -eq 0) { continue }

        Write-Host ""
        Write-Host ("[{0}]" -f $tier) -ForegroundColor DarkYellow

        foreach ($key in $byTier[$tier]) {
            $def = Get-ModelDef -Key $key
            $source = if ($def.SourceType -eq "gguf") { "GGUF: $($def.Repo)" } else { "Remote: $($def.RemoteModel)" }
            $contexts = @($def.Contexts.Keys | ForEach-Object {
                    $aliasName = Get-ModelAliasName -Def $def -ContextKey $_
                    $ctx = Get-ModelContextValue -Def $def -ContextKey $_
                    "$aliasName=$ctx"
                }) -join ", "

            Write-Host "$key" -ForegroundColor White
            Write-Host "  Name     : $($def.DisplayName)"
            Write-Host "  Source   : $source"
            Write-Host "  Contexts : $contexts"

            if ($def.ContainsKey("Quants")) {
                $quantList = @($def.Quants.Keys | ForEach-Object {
                        if ($_ -eq $def.Quant) { "$_ [current]" } else { $_ }
                    }) -join ", "
                Write-Host "  Quants   : $quantList"
                $shortcutName = Get-ModelShortcutName -Def $def
                Write-Host "  Switch   : $shortcutName -Quant <quant>"
            }

            Write-Host ""
        }
    }
}

function Show-LLMQuickReference {
    Write-Section "Quick Reference"

    Write-Host @'
One function per model — flags select what to do.
  qcoder -Ctx fast -Fc          Code agent (Qwen3-Coder, 32k, free-code)
  q36p -Ctx fast -Fc            General Qwen 3.6 agent (32k, free-code)
  dev -Ctx fast                 Smaller / faster (Devstral 24B, 32k)
  q36p -Ctx 128 -Fc             Big context (Qwen 3.6 Plus, 128k)
  q36p -Chat                    Raw ollama chat, no Claude Code
  q36p -Q8                      Use q8 KV cache for higher quality
  q36p -Quant q6kp              Switch the GGUF quant (rebuilds aliases)
  llmdefault                    Launch the configured Default model
  llm                           Guided wizard

Flags
  -Ctx <name>     One of the model's contexts (e.g. fast, deep, 128). Omit for default.
  -Fc             Use free-code instead of Claude Code.
  -Chat           Run plain ollama chat (skips Claude Code entirely).
  -Q8             Set OLLAMA_KV_CACHE_TYPE=q8_0 for this launch.
  -Quant <name>   Switch the model's selected quant (no launch). GGUF models only.

Manage
  info                  Dashboard, recommended models only
  info -All             Dashboard with experimental + legacy
  reloadllm             Reload llm-models.json and regenerate commands
  ops, qkill, ostop     Ollama: list / stop loaded / restart
  init                  Setup all recommended models
  init -All             Setup every configured model
  init -Force           Rebuild all aliases
  init -Stale           Rebuild only aliases whose parser stamp is missing/stale
  initmodel <key> [-Force]
  listorphans           Show Ollama models not present in llm-models.json
  cleanorphans          Remove orphan Ollama models (confirms first)
  purge                 Remove every configured alias and every GGUF file
  obench [-Model name]  Show benchmark history (~/.local-llm/bench-history.jsonl)

Add or remove a model
  addllm <hf-url-or-repo> -Key <key>
  addllm <hf-url-or-repo> -Key <key> -Quants Q4_K_P,IQ4_XS -DefaultQuant Q4_K_P -Tier recommended
  initmodel <key>
  removellm <key> [-KeepFiles] [-Force]

Tiers
  recommended    Daily drivers, known to work. Shown by default.
  experimental   Works but uncensored / abliterated / niche; hidden by default.
  legacy         Kept for comparison; hidden by default.

Benchmark
  qkill ; q36p -Ctx fast -Chat ; ospeed q36plusfast -Runs 3
  qkill ; qcoder -Ctx fast -Chat ; ospeed qcoder30fast -Runs 3

Notes
  Thinking: q36opus47abl uses ThinkingPolicy=keep, which routes it directly at
            Ollama (port 11434) and leaves Claude Code's thinking env vars unset.
            All other models go through the strip proxy on 11435.
'@

    Show-LLMDynamicModelSummary
}

function llm { Start-LLMWizard }
function llmmenu { Start-LLMWizard }
