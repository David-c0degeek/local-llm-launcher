# =========================
# Local LLM profile engine
# Ollama + Claude Code + Unshackled
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

function Get-LocalLLMSettingsPath {
    if ($env:LOCAL_LLM_SETTINGS) {
        return $env:LOCAL_LLM_SETTINGS
    }

    return Join-Path $script:LLMProfileRoot "settings.json"
}

function Import-LocalLLMSettings {
    # Per-machine overrides: paths, preferences. Sits next to llm-models.json
    # but is gitignored so it never lands in a public repo. Top-level scalars
    # only — Models and CommandAliases stay in the catalog.
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
        throw "Local LLM config not found: $script:LocalLLMConfigPath"
    }

    $cfg = Get-Content -Raw -Path $script:LocalLLMConfigPath | ConvertFrom-Json -AsHashtable

    # Overlay per-machine settings (gitignored). Models/CommandAliases stay
    # in the catalog; everything else can be overridden per-host.
    $settings = Import-LocalLLMSettings

    foreach ($key in @($settings.Keys)) {
        if ($key -in @("Models", "CommandAliases")) { continue }
        $cfg[$key] = $settings[$key]
    }

    $cfg.OllamaAppPath = Expand-LocalLLMPath $cfg.OllamaAppPath
    $cfg.OllamaCommunityRoot = Expand-LocalLLMPath $cfg.OllamaCommunityRoot

    # Migrate the pre-rename field name (FreeCodeRoot → UnshackledRoot) on read.
    if ($cfg.Contains("FreeCodeRoot") -and -not $cfg.Contains("UnshackledRoot")) {
        $cfg.UnshackledRoot = $cfg.FreeCodeRoot
        $cfg.Remove("FreeCodeRoot") | Out-Null
    }

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

# -------------------------
# Description / note helpers
# Optional fields on a model def: Description, QuantNotes (qkey -> string),
# ContextNotes (ctxkey -> string). Always read through these helpers — they
# tolerate missing fields and odd casing.
# -------------------------

function Get-ModelDescription {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def)

    if ($Def.Contains("Description") -and -not [string]::IsNullOrWhiteSpace($Def.Description)) {
        return [string]$Def.Description
    }

    return ""
}

function Get-ModelQuantNote {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$QuantKey
    )

    if (-not $Def.Contains("QuantNotes") -or -not $Def.QuantNotes) { return "" }
    if ([string]::IsNullOrEmpty($QuantKey)) { return "" }

    foreach ($k in $Def.QuantNotes.Keys) {
        if ($k -ieq $QuantKey) { return [string]$Def.QuantNotes[$k] }
    }

    return ""
}

function Get-ModelContextNote {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey
    )

    if (-not $Def.Contains("ContextNotes") -or -not $Def.ContextNotes) { return "" }

    # Empty string is a valid key (the "default" context). Match it literally first.
    foreach ($k in $Def.ContextNotes.Keys) {
        if ($k -eq $ContextKey) { return [string]$Def.ContextNotes[$k] }
    }

    foreach ($k in $Def.ContextNotes.Keys) {
        if ($k -ieq $ContextKey) { return [string]$Def.ContextNotes[$k] }
    }

    return ""
}

$script:LocalLLMVRAMCache = $null

function Get-AutoDetectVRAMGB {
    # Returns the largest GPU's VRAM in GB via nvidia-smi, or $null if nvidia-smi
    # isn't on PATH / fails. Multi-GPU: takes the max (Ollama loads to one card).
    try {
        $cmd = Get-Command nvidia-smi -ErrorAction SilentlyContinue
        if (-not $cmd) { return $null }

        $output = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null

        if ($LASTEXITCODE -ne 0 -or -not $output) { return $null }

        $values = @()
        foreach ($line in @($output)) {
            $trimmed = $line.Trim()
            if ($trimmed -match '^\d+$') { $values += [int]$trimmed }
        }

        if ($values.Count -eq 0) { return $null }

        $maxMb = ($values | Measure-Object -Maximum).Maximum

        if ($maxMb -le 0) { return $null }

        return [int][math]::Round($maxMb / 1024)
    } catch {
        return $null
    }
}

function Get-LocalLLMVRAMInfo {
    # Resolve VRAM in three steps:
    #   1. user-configured via settings.json / catalog (Source = "configured")
    #   2. nvidia-smi auto-detect, cached for the session (Source = "auto")
    #   3. fallback to 24 (Source = "fallback")
    if ($script:Cfg -and $script:Cfg.Contains("VRAMGB")) {
        try {
            $val = [int]$script:Cfg.VRAMGB
            if ($val -gt 0) {
                return @{ GB = $val; Source = "configured" }
            }
        } catch { }
    }

    if ($null -eq $script:LocalLLMVRAMCache) {
        $auto = Get-AutoDetectVRAMGB
        if ($auto) {
            $script:LocalLLMVRAMCache = @{ GB = $auto; Source = "auto" }
        } else {
            $script:LocalLLMVRAMCache = @{ GB = 24; Source = "fallback" }
        }
    }

    return $script:LocalLLMVRAMCache
}

function Get-LocalLLMVRAMGB {
    return (Get-LocalLLMVRAMInfo).GB
}

function Get-Q8KvMaxContext {
    # Largest num_ctx safe to combine with -Q8 (q8_0 KV cache).
    # Override explicitly via settings.json: Set-LocalLLMSetting Q8KvMaxContext 262144
    # Default scales with VRAM: each GB above ~16 GB is worth ~16k extra q8 tokens
    # (rough heuristic across the catalog's MoE coders). Floors at 64k.
    if ($script:Cfg -and $script:Cfg.Contains("Q8KvMaxContext")) {
        try { return [int]$script:Cfg.Q8KvMaxContext } catch { }
    }

    $vramGB = Get-LocalLLMVRAMGB
    $derived = ($vramGB - 16) * 16384

    if ($derived -lt 65536) { return 65536 }

    return [int]$derived
}

function Get-QuantSizeGB {
    # Per-quant numeric size (GB) from the optional QuantSizesGB hashtable on a
    # model def. Returns $null when the catalog hasn't filled it in.
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$QuantKey
    )

    if (-not $Def.Contains("QuantSizesGB") -or -not $Def.QuantSizesGB) { return $null }
    if ([string]::IsNullOrEmpty($QuantKey)) { return $null }

    foreach ($k in $Def.QuantSizesGB.Keys) {
        if ($k -ieq $QuantKey) {
            try { return [double]$Def.QuantSizesGB[$k] } catch { return $null }
        }
    }

    return $null
}

function Get-QuantFitClass {
    # Classify a quant against the host's VRAM budget:
    #   "fits"  — leaves >= 7 GB headroom for KV cache + overhead
    #   "tight" — fits weights but only ~2 GB headroom; fine at short context
    #   "over"  — won't fit fully on one GPU; expect partial offload
    #   ""      — size unknown (no QuantSizesGB entry)
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$QuantKey
    )

    $size = Get-QuantSizeGB -Def $Def -QuantKey $QuantKey
    if ($null -eq $size) { return "" }

    $vramGB = Get-LocalLLMVRAMGB

    if ($size -le ($vramGB - 7)) { return "fits" }
    if ($size -le ($vramGB - 2)) { return "tight" }
    return "over"
}

function Format-QuantFitBadge {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$FitClass)

    switch ($FitClass) {
        "fits"  { return "[fits]" }
        "tight" { return "[tight]" }
        "over"  { return "[over]" }
        default { return "" }
    }
}

function Get-QuantFitBadgeColor {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$FitClass)

    switch ($FitClass) {
        "fits"  { return "Green" }
        "tight" { return "Yellow" }
        "over"  { return "Red" }
        default { return "DarkGray" }
    }
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

function Get-HuggingFaceModelInfo {
    # One round-trip to /api/models/{repo}?blobs=true. Returns the raw object
    # (siblings carry `size` in bytes, plus cardData / tags / etc.).
    param([Parameter(Mandatory = $true)][string]$Repo)

    $url = "https://huggingface.co/api/models/$Repo`?blobs=true"
    return Invoke-RestMethod -Uri $url -UseBasicParsing
}

function Get-HuggingFaceModelFiles {
    param([Parameter(Mandatory = $true)][string]$Repo)

    $info = Get-HuggingFaceModelInfo -Repo $Repo

    if (-not $info.siblings) {
        return @()
    }

    return @($info.siblings | ForEach-Object { $_.rfilename })
}

function Get-HuggingFaceFileSizesGB {
    # Map of rfilename -> size in GB (1 decimal place). Pulled from siblings[*].size
    # which is bytes when ?blobs=true is set on /api/models/{repo}.
    param([Parameter(Mandatory = $true)]$Info)

    $map = [ordered]@{}

    if (-not $Info.siblings) { return $map }

    foreach ($s in $Info.siblings) {
        $name = $s.rfilename
        if (-not $name) { continue }

        $bytes = 0L
        if ($s.PSObject.Properties.Match('lfs').Count -gt 0 -and $s.lfs -and $s.lfs.size) {
            try { $bytes = [long]$s.lfs.size } catch { }
        }
        if ($bytes -le 0 -and $s.PSObject.Properties.Match('size').Count -gt 0 -and $s.size) {
            try { $bytes = [long]$s.size } catch { }
        }

        if ($bytes -gt 0) {
            # Decimal GB (1e9) to match existing catalog entries and HF's UI.
            # Slightly larger than binary GiB but reads the same as HF README tables.
            $map[$name] = [math]::Round($bytes / 1000000000, 1)
        }
    }

    return $map
}

function Get-HuggingFaceReadme {
    # Raw README.md for a repo. Returns $null on any failure (404, network, ...).
    param([Parameter(Mandatory = $true)][string]$Repo)

    $url = "https://huggingface.co/$Repo/raw/main/README.md"

    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10
        return [string]$resp.Content
    } catch {
        return $null
    }
}

function ConvertFrom-HuggingFaceReadme {
    # Heuristic: pull the first prose paragraph out of a raw HF README.md.
    # Strips frontmatter, HTML comments, headings, badge/image lines, blockquotes,
    # bare URLs, "weighted/imatrix quants of <link>" boilerplate. Falls back to
    # $null if nothing usable remains.
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$Readme)

    if ([string]::IsNullOrWhiteSpace($Readme)) { return $null }

    $text = $Readme

    # Drop YAML frontmatter (--- ... --- at the very top).
    if ($text -match '^\s*---\r?\n') {
        $idx = $text.IndexOf("`n---", 4)
        if ($idx -ge 0) {
            $text = $text.Substring($idx + 4)
        }
    }

    # Strip HTML comments.
    $text = [regex]::Replace($text, '<!--[\s\S]*?-->', '')

    # Strip image lines and bare badge links on their own line.
    $text = [regex]::Replace($text, '(?m)^\s*!\[[^\]]*\]\([^)]*\)\s*$', '')

    $paragraphs = [regex]::Split($text, '\r?\n\s*\r?\n')

    foreach ($p in $paragraphs) {
        $candidate = $p.Trim()
        if (-not $candidate) { continue }
        # Skip headings, fenced code, tables, blockquotes, list-only blocks.
        if ($candidate -match '^(#|```|>|\||---|\* |- |\d+\. )') { continue }
        # Skip lines that are only badges / images / single links.
        if ($candidate -match '^!\[' ) { continue }
        if ($candidate -match '^\[!\[') { continue }
        # Skip mradermacher boilerplate ("weighted/imatrix quants of ...").
        if ($candidate -match '^(weighted/imatrix |static )?quants of\s+https?://') { continue }
        if ($candidate -match '^For a convenient overview') { continue }
        if ($candidate -match '^If you are unsure how to use GGUF') { continue }
        # Need real prose: at least one sentence, not just a URL.
        if ($candidate.Length -lt 30) { continue }
        if ($candidate -match '^\s*https?://\S+\s*$') { continue }

        # Collapse internal whitespace; cap at ~400 chars to keep dashboards readable.
        $candidate = ($candidate -replace '\s+', ' ').Trim()

        # Strip simple inline markdown links: [text](url) -> text
        $candidate = [regex]::Replace($candidate, '\[([^\]]+)\]\([^)]+\)', '$1')
        # Strip emphasis markers.
        $candidate = $candidate -replace '\*{1,3}([^*]+)\*{1,3}', '$1'

        if ($candidate.Length -gt 400) {
            $cut = $candidate.Substring(0, 397)
            $lastDot = $cut.LastIndexOf('. ')
            if ($lastDot -gt 200) { $cut = $cut.Substring(0, $lastDot + 1) }
            $candidate = $cut.TrimEnd() + ($(if ($candidate.Length -gt $cut.Length) { '...' } else { '' }))
        }

        return $candidate
    }

    return $null
}

function Resolve-HuggingFaceDescription {
    # Try to find a usable Description for a repo:
    #   1. cardData.description on this repo (rare for quant repos)
    #   2. README.md of base_model if cardData.base_model is set (mradermacher pattern)
    #   3. README.md of this repo
    # Returns $null if nothing usable.
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [int]$Depth = 0
    )

    if ($Depth -gt 1) { return $null }

    try {
        $info = Get-HuggingFaceModelInfo -Repo $Repo
    } catch {
        return $null
    }

    if ($info.cardData -and $info.cardData.description) {
        $cd = ([string]$info.cardData.description).Trim()
        if ($cd -and $cd.Length -ge 30) { return $cd }
    }

    if ($Depth -eq 0 -and $info.cardData -and $info.cardData.base_model) {
        $base = $info.cardData.base_model
        if ($base -is [array]) { $base = $base[0] }
        $base = [string]$base
        if ($base -match '^[^/\s]+/[^/\s]+$' -and $base -ne $Repo) {
            $fromBase = Resolve-HuggingFaceDescription -Repo $base -Depth ($Depth + 1)
            if ($fromBase) { return $fromBase }
        }
    }

    $readme = Get-HuggingFaceReadme -Repo $Repo
    return (ConvertFrom-HuggingFaceReadme -Readme $readme)
}

# Quant code -> (family label, quality tier text). Hand-curated from the
# llama.cpp / mradermacher quant table. Used by New-LocalLLMQuantNoteText to
# generate baseline QuantNotes when the user doesn't supply their own.
$script:LocalLLMQuantSemantics = @{
    'IQ1_S'    = @('1-bit imatrix',          'for the desperate')
    'IQ1_M'    = @('1-bit imatrix',          'mostly desperate')
    'IQ2_XXS'  = @('2-bit imatrix',          'very low quality')
    'IQ2_XS'   = @('2-bit imatrix',          'very low quality')
    'IQ2_S'    = @('2-bit imatrix',          'low quality')
    'IQ2_M'    = @('2-bit imatrix',          'low quality, long-context only')
    'Q2_K_S'   = @('2-bit k-quant small',    'very low quality')
    'Q2_K'     = @('2-bit k-quant',          'IQ3_XXS often better')
    'IQ3_XXS'  = @('3-bit imatrix',          'lower quality')
    'IQ3_XS'   = @('3-bit imatrix',          'lower quality')
    'Q3_K_S'   = @('3-bit k-quant small',    'IQ3_XS often better')
    'IQ3_S'    = @('3-bit imatrix',          'beats Q3_K*')
    'IQ3_M'    = @('3-bit imatrix',          'good 3-bit baseline')
    'Q3_K_M'   = @('3-bit k-quant medium',   'IQ3_S often better')
    'Q3_K_L'   = @('3-bit k-quant large',    'IQ3_M often better')
    'IQ4_XS'   = @('4-bit imatrix',          'good 4-bit, smallest 4-bit option')
    'IQ4_NL'   = @('4-bit imatrix non-linear','good 4-bit baseline')
    'Q4_0'     = @('4-bit legacy',           'fast, low quality')
    'Q4_1'     = @('4-bit legacy',           '')
    'Q4_K_S'   = @('4-bit k-quant small',    'optimal size/speed/quality')
    'Q4_K_M'   = @('4-bit k-quant medium',   'fast, recommended sweet spot')
    'Q4_K_P'   = @('4-bit k-quant',          'similar to Q4_K_M')
    'MXFP4'    = @('4-bit MoE-aware',        'similar to IQ4_NL')
    'MXFP4_MOE'= @('4-bit MoE-aware',        'similar to IQ4_NL')
    'Q5_K_S'   = @('5-bit k-quant small',    'noticeable quality bump')
    'Q5_K_M'   = @('5-bit k-quant medium',   'noticeable quality bump')
    'Q6_K'     = @('6-bit k-quant',          'high quality')
    'Q6_K_P'   = @('6-bit k-quant',          'high quality')
    'Q8_0'     = @('8-bit',                  'highest practical quality')
    'BF16'     = @('bfloat16 full precision','expect partial offload')
    'F16'      = @('float16 full precision', 'expect partial offload')
    'F32'      = @('float32 full precision', 'almost certainly partial offload')
}

function New-LocalLLMQuantNoteText {
    # Generic baseline note for a quant when the user doesn't supply -QuantNotes.
    # Format: "<CODE> · <family> · ~<size> GB · <tier note>"
    # Any missing field is omitted. Returns "" if nothing useful is known.
    param(
        [Parameter(Mandatory = $true)][string]$QuantCode,
        [AllowNull()][object]$SizeGB
    )

    $upper = $QuantCode.ToUpperInvariant()
    $family = $null
    $tier = $null

    if ($script:LocalLLMQuantSemantics.ContainsKey($upper)) {
        $entry = $script:LocalLLMQuantSemantics[$upper]
        $family = $entry[0]
        $tier = $entry[1]
    }

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add($upper) | Out-Null
    if ($family) { $parts.Add($family) | Out-Null }
    if ($null -ne $SizeGB -and $SizeGB -gt 0) {
        $parts.Add("~$([math]::Round([double]$SizeGB, 1)) GB") | Out-Null
    }
    if ($tier) { $parts.Add($tier) | Out-Null }

    return ($parts -join ' · ')
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
        [string]$Description,
        [string]$Root,
        [string]$QuantShortcut,
        [System.Collections.IDictionary]$Contexts,
        [System.Collections.IDictionary]$QuantNotes,
        [System.Collections.IDictionary]$ContextNotes,
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
    $hfInfo = Get-HuggingFaceModelInfo -Repo $repo
    $allFiles = @($hfInfo.siblings | ForEach-Object { $_.rfilename })
    $sizesByFile = Get-HuggingFaceFileSizesGB -Info $hfInfo
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

    # Build a quant -> size map for the selected quants (used for QuantSizesGB
    # and as input to the auto-generated QuantNotes below).
    $quantSizesGB = [ordered]@{}
    foreach ($short in $shortToFile.Keys) {
        $file = $shortToFile[$short]
        if ($sizesByFile.Contains($file)) {
            $quantSizesGB[$short] = $sizesByFile[$file]
        }
    }

    # Auto-fill Description from HF (cardData → base_model README → this README)
    # if the caller didn't provide one. Verbose-only so the dashboard stays calm.
    if ([string]::IsNullOrWhiteSpace($Description)) {
        Write-Host "Resolving description from HuggingFace..." -ForegroundColor DarkCyan
        $auto = Resolve-HuggingFaceDescription -Repo $repo
        if (-not [string]::IsNullOrWhiteSpace($auto)) {
            $Description = $auto
            Write-Host "  $Description" -ForegroundColor DarkGray
        } else {
            Write-Host "  (no usable README description found — leaving Description empty)" -ForegroundColor DarkGray
        }
    }

    # Auto-fill generic QuantNotes from the quant code + size when the user
    # didn't pass any. Hand-tuned notes (e.g. "use this for -Ctx 256") stay manual.
    $autoQuantNotes = $null
    if (-not $QuantNotes -or $QuantNotes.Count -eq 0) {
        $autoQuantNotes = [ordered]@{}
        foreach ($code in $codeMap.Keys) {
            $short = $codeToShort[$code]
            $size = if ($quantSizesGB.Contains($short)) { $quantSizesGB[$short] } else { $null }
            $note = New-LocalLLMQuantNoteText -QuantCode $code -SizeGB $size
            if ($note) { $autoQuantNotes[$short] = $note }
        }
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

    if (-not [string]::IsNullOrWhiteSpace($Description)) {
        $entry.Description = $Description
    }

    if ($quantSizesGB.Count -gt 0) {
        $entry.QuantSizesGB = $quantSizesGB
    }

    if ($QuantNotes -and $QuantNotes.Count -gt 0) {
        $entry.QuantNotes = $QuantNotes
    } elseif ($autoQuantNotes -and $autoQuantNotes.Count -gt 0) {
        $entry.QuantNotes = $autoQuantNotes
    }

    if ($ContextNotes -and $ContextNotes.Count -gt 0) {
        $entry.ContextNotes = $ContextNotes
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
    if (-not [string]::IsNullOrWhiteSpace($Description)) {
        Write-Host "  About    : $Description" -ForegroundColor DarkGray
    }
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
        [string]$Description,
        [string]$Root,
        [string]$QuantShortcut,
        [System.Collections.IDictionary]$QuantNotes,
        [System.Collections.IDictionary]$ContextNotes,
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
# Claude / Unshackled / proxy helpers
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

        # Local models prefill slowly on big prompts; raise SDK timeout so the
        # client doesn't abort + retry mid-prefill (which restarts the work).
        $env:API_TIMEOUT_MS = "1800000"

        # Drop the auto-memory system-prompt block (and the turn-end extract
        # agent). Saves several KB of input tokens per turn — significant when
        # prefill is the bottleneck.
        $env:CLAUDE_CODE_DISABLE_AUTO_MEMORY = "1"

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

# -------------------------
# Spectre.Console renderer (soft dependency)
# Tries to import PwshSpectreConsole on first use. If absent, the dashboard
# falls back to the legacy Write-Host renderer and we surface a one-line install
# hint. Set $env:LOCAL_LLM_NO_SPECTRE=1 to disable Spectre even when installed.
# -------------------------

$script:LocalLLMSpectreState = $null  # $true / $false / $null (unprobed)

function Test-LocalLLMSpectreAvailable {
    if ($env:LOCAL_LLM_NO_SPECTRE -eq '1') { return $false }
    if ($null -ne $script:LocalLLMSpectreState) { return $script:LocalLLMSpectreState }

    if (Get-Module -Name PwshSpectreConsole) {
        $script:LocalLLMSpectreState = $true
        return $true
    }

    $available = Get-Module -ListAvailable -Name PwshSpectreConsole -ErrorAction SilentlyContinue
    if (-not $available) {
        $script:LocalLLMSpectreState = $false
        return $false
    }

    try {
        Import-Module PwshSpectreConsole -ErrorAction Stop -DisableNameChecking | Out-Null
        $script:LocalLLMSpectreState = $true
        return $true
    } catch {
        Write-Verbose "PwshSpectreConsole import failed: $($_.Exception.Message)"
        $script:LocalLLMSpectreState = $false
        return $false
    }
}

function Show-LocalLLMSpectreInstallHint {
    Write-Host ""
    Write-Host "Tip: install PwshSpectreConsole for a nicer dashboard:" -ForegroundColor DarkGray
    Write-Host "       Install-Module PwshSpectreConsole -Scope CurrentUser" -ForegroundColor DarkGray
    Write-Host "     Reload your profile, or run 'reloadllm', and 'info' will switch to the rich UI." -ForegroundColor DarkGray
}

function ConvertTo-LocalLLMSpectreSafe {
    # Spectre markup is `[color]text[/]`. Square brackets in arbitrary text
    # (e.g. tier badges "[recommended]") collide. Escape with `[[` / `]]`.
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ($null -eq $Text) { return "" }
    return ($Text -replace '\[', '[[') -replace '\]', ']]'
}

function Format-LocalLLMSpectreFitCell {
    # Single-quant fit cell for the summary table: short label + colored marker.
    # marker uses Spectre markup; the bracket/square-bracket text is plain.
    param(
        [Parameter(Mandatory = $true)][string]$QuantKey,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$FitClass,
        [switch]$IsDefault
    )

    $star = if ($IsDefault) { '*' } else { ' ' }

    $marker, $color = switch ($FitClass) {
        'fits'  { '+',  'green'  }
        'tight' { '~',  'yellow' }
        'over'  { '!',  'red'    }
        default { '?',  'grey50' }
    }

    return "[$color]$marker[/]$star$QuantKey"
}

function Show-ModelCatalogSpectre {
    param([switch]$All)

    $vramInfo = Get-LocalLLMVRAMInfo
    $sourceLabel = switch ($vramInfo.Source) {
        "configured" { "set in settings.json" }
        "auto"       { "nvidia-smi auto-detect" }
        "fallback"   { "fallback — nvidia-smi unavailable" }
        default      { $vramInfo.Source }
    }

    Write-Host ""
    Format-SpectrePanel -Header "Models" -Color Blue -Data ("VRAM: [yellow]{0} GB[/] ({1})" -f $vramInfo.GB, (ConvertTo-LocalLLMSpectreSafe $sourceLabel)) | Out-Host

    $visibleKeys = @(Get-FilteredModelKeys -IncludeAll:$All)
    $installed = @(Get-OllamaInstalledModelNames)

    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($key in $visibleKeys) {
        $def = Get-ModelDef -Key $key
        $tier = Get-ModelTier -Def $def

        $tierLabel = switch ($tier) {
            'recommended'  { '[green]recommended[/]' }
            'experimental' { '[yellow]experimental[/]' }
            'legacy'       { '[grey50]legacy[/]' }
            default        { ConvertTo-LocalLLMSpectreSafe $tier }
        }

        if ($def.ContainsKey("Quants")) {
            $quantCells = foreach ($qk in $def.Quants.Keys) {
                $fit = Get-QuantFitClass -Def $def -QuantKey $qk
                Format-LocalLLMSpectreFitCell -QuantKey $qk -FitClass $fit -IsDefault:($qk -eq $def.Quant)
            }
            $quants = ($quantCells -join '  ')
            $defaultQuant = "[cyan]$($def.Quant)[/]"
        } else {
            $quants = "[grey50](single file)[/]"
            $defaultQuant = "[grey50]—[/]"
        }

        $contextLabels = @($def.Contexts.Keys | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace($_)) { "default" } else { $_ }
        })
        $contexts = ($contextLabels -join ' · ')

        $aliases = @($def.Contexts.Keys | ForEach-Object { Get-ModelAliasName -Def $def -ContextKey $_ })
        $builtCount = 0
        foreach ($a in $aliases) {
            if ($installed -contains $a -or $installed -contains "${a}:latest") { $builtCount++ }
        }
        $built = "$builtCount/$($aliases.Count)"
        if ($builtCount -eq $aliases.Count) {
            $built = "[green]$built[/]"
        } elseif ($builtCount -eq 0) {
            $built = "[grey50]$built[/]"
        } else {
            $built = "[yellow]$built[/]"
        }

        $rows.Add([pscustomobject]@{
            Key      = "[white]$key[/]"
            Name     = ConvertTo-LocalLLMSpectreSafe $def.DisplayName
            Tier     = $tierLabel
            Default  = $defaultQuant
            Quants   = $quants
            Contexts = ConvertTo-LocalLLMSpectreSafe $contexts
            Built    = $built
        }) | Out-Null
    }

    $rows | Format-SpectreTable -Border Rounded -Color Blue -AllowMarkup -Wrap | Out-Host

    Write-Host ""
    Write-Host "  Quant cells: " -ForegroundColor DarkGray -NoNewline
    Write-Host "+" -ForegroundColor Green -NoNewline; Write-Host " fits  " -ForegroundColor DarkGray -NoNewline
    Write-Host "~" -ForegroundColor Yellow -NoNewline; Write-Host " tight  " -ForegroundColor DarkGray -NoNewline
    Write-Host "!" -ForegroundColor Red -NoNewline; Write-Host " over  " -ForegroundColor DarkGray -NoNewline
    Write-Host "?" -ForegroundColor DarkGray -NoNewline; Write-Host " size unknown   " -ForegroundColor DarkGray -NoNewline
    Write-Host "*name = current default quant" -ForegroundColor DarkGray
    Write-Host "  Built column: aliases-installed / aliases-configured." -ForegroundColor DarkGray

    if (-not $All) {
        $hiddenCount = (@(Get-ModelKeys)).Count - $visibleKeys.Count
        if ($hiddenCount -gt 0) {
            Write-Host ""
            Write-Host "$hiddenCount more model(s) hidden. Run 'info -All' to show experimental + legacy, or 'info <key>' for one." -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "Drill in:" -ForegroundColor White
    Write-Host "  info <key>                     Per-model detail (description, quants, contexts)" -ForegroundColor DarkGray
    Write-Host "Manage:" -ForegroundColor White
    Write-Host "  addllm <hf-url> -Key <key>     Add a model from HuggingFace (auto-fills size + description)" -ForegroundColor DarkGray
    Write-Host "  removellm <key>                Remove a model + its files" -ForegroundColor DarkGray
    Write-Host "  initmodel <key> [-Force]       (Re)build Ollama aliases for a model" -ForegroundColor DarkGray
    Write-Host "  cleanorphans, listorphans, reloadllm, purge, ops, qkill, ostop, llm, llmdocs" -ForegroundColor DarkGray
    Write-Host "  Config: $script:LocalLLMConfigPath" -ForegroundColor DarkGray
}

function Show-ModelDetailSpectre {
    param([Parameter(Mandatory = $true)][string]$Key)

    $def = Get-ModelDef -Key $Key
    $tier = Get-ModelTier -Def $def
    $tierColor = switch ($tier) {
        'recommended'  { 'green' }
        'experimental' { 'yellow' }
        'legacy'       { 'grey50' }
        default        { 'grey70' }
    }

    $description = Get-ModelDescription -Def $def
    $source = if ($def.SourceType -eq 'gguf') { "GGUF · $($def.Repo)" } else { "Remote · $($def.RemoteModel)" }
    $parser = if ($def.Parser) { $def.Parser } else { 'none' }
    $limitTools = if ($def.ContainsKey('LimitTools')) { [bool]$def.LimitTools } else { $true }

    $headerLines = New-Object System.Collections.Generic.List[string]
    if ($description) {
        $headerLines.Add((ConvertTo-LocalLLMSpectreSafe $description)) | Out-Null
        $headerLines.Add('') | Out-Null
    }
    $headerLines.Add(("[grey70]Source[/]    : {0}" -f (ConvertTo-LocalLLMSpectreSafe $source))) | Out-Null
    $headerLines.Add(("[grey70]Parser[/]    : {0}    [grey70]LimitTools[/]: {1}" -f (ConvertTo-LocalLLMSpectreSafe $parser), $limitTools)) | Out-Null

    if ($def.ContainsKey('ParserNote') -and $def.ParserNote) {
        $headerLines.Add(("[grey50]Note[/]      : {0}" -f (ConvertTo-LocalLLMSpectreSafe $def.ParserNote))) | Out-Null
    }

    $panelHeader = ("[white]{0}[/] · [{1}]{2}[/]" -f (ConvertTo-LocalLLMSpectreSafe $def.DisplayName), $tierColor, $tier)
    Write-Host ""
    Format-SpectrePanel -Header $panelHeader -Color $tierColor -Data ($headerLines -join "`n") | Out-Host

    if ($def.ContainsKey('Quants')) {
        $quantRows = foreach ($qk in $def.Quants.Keys) {
            $isDefault = ($qk -eq $def.Quant)
            $fit = Get-QuantFitClass -Def $def -QuantKey $qk
            $fitMark, $fitColor = switch ($fit) {
                'fits'  { 'fits',  'green' }
                'tight' { 'tight', 'yellow' }
                'over'  { 'over',  'red' }
                default { '?',     'grey50' }
            }
            $size = Get-QuantSizeGB -Def $def -QuantKey $qk
            $sizeText = if ($null -eq $size) { '—' } else { "{0:N1} GB" -f $size }
            $note = Get-ModelQuantNote -Def $def -QuantKey $qk
            if (-not $note) { $note = $def.Quants[$qk] }

            [pscustomobject]@{
                ' '    = if ($isDefault) { '[cyan]*[/]' } else { ' ' }
                Quant  = if ($isDefault) { "[cyan]$qk[/]" } else { $qk }
                Fit    = "[$fitColor]$fitMark[/]"
                Size   = $sizeText
                Note   = ConvertTo-LocalLLMSpectreSafe $note
            }
        }

        Write-Host ""
        Write-Host "Quants" -ForegroundColor White
        $quantRows | Format-SpectreTable -Border Rounded -Color $tierColor -AllowMarkup -Wrap | Out-Host
    }

    $ctxRows = foreach ($ck in $def.Contexts.Keys) {
        $label = if ([string]::IsNullOrWhiteSpace($ck)) { 'default' } else { $ck }
        $tokens = Get-ModelContextValue -Def $def -ContextKey $ck
        $note = Get-ModelContextNote -Def $def -ContextKey $ck
        $alias = Get-ModelAliasName -Def $def -ContextKey $ck

        [pscustomobject]@{
            Context = $label
            Alias   = ConvertTo-LocalLLMSpectreSafe $alias
            Tokens  = "{0:N0}" -f [int]$tokens
            Note    = ConvertTo-LocalLLMSpectreSafe $note
        }
    }

    Write-Host ""
    Write-Host "Contexts" -ForegroundColor White
    $ctxRows | Format-SpectreTable -Border Rounded -Color $tierColor -AllowMarkup -Wrap | Out-Host

    $installed = @(Get-OllamaInstalledModelNames)
    $aliases = @($def.Contexts.Keys | ForEach-Object { Get-ModelAliasName -Def $def -ContextKey $_ })
    $built = Format-AliasBuiltList -Names $aliases -Installed $installed
    Write-Host ""
    Write-Host "Built : $built" -ForegroundColor DarkGray

    if ($def.Contains('Tools') -and -not [string]::IsNullOrWhiteSpace($def.Tools)) {
        Write-Host "Tools : $($def.Tools)" -ForegroundColor DarkGray
    }

    $cmdName = Get-ModelShortcutName -Def $def
    $contextLabels = @($def.Contexts.Keys | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_)) { "default" } else { $_ }
    })
    $ctxFlag = if ($contextLabels.Count -gt 1) { "[-Ctx $($contextLabels -join '|')]" } else { '' }
    $usage = "$cmdName $ctxFlag [-Fc] [-Chat] [-Q8]".Trim()
    if ($def.ContainsKey('Quants')) {
        $usage += " [-Quant $((@($def.Quants.Keys)) -join '|')]"
    }
    Write-Host ""
    Write-Host "Usage : $usage" -ForegroundColor White
}

function Show-ModelCatalog {
    param([switch]$All)

    if (Test-LocalLLMSpectreAvailable) {
        Show-ModelCatalogSpectre -All:$All
        return
    }

    Write-Section "Commands"

    $vramInfo = Get-LocalLLMVRAMInfo
    $sourceLabel = switch ($vramInfo.Source) {
        "configured" { "set in settings.json" }
        "auto"       { "nvidia-smi auto-detect" }
        "fallback"   { "fallback — nvidia-smi unavailable" }
        default      { $vramInfo.Source }
    }
    Write-Host ("VRAM   : {0} GB ({1})" -f $vramInfo.GB, $sourceLabel) -ForegroundColor Yellow
    if ($vramInfo.Source -ne "configured") {
        Write-Host "         Override: Set-LocalLLMSetting VRAMGB <value>" -ForegroundColor DarkGray
    }
    Write-Host ""

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

        $description = Get-ModelDescription -Def $def
        if (-not [string]::IsNullOrWhiteSpace($description)) {
            Write-Host "  $description" -ForegroundColor Gray
        }

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

        if ($def.ContainsKey("Quants")) {
            $hasQuantNotes = $false
            foreach ($qk in $def.Quants.Keys) {
                if (-not [string]::IsNullOrWhiteSpace((Get-ModelQuantNote -Def $def -QuantKey $qk))) {
                    $hasQuantNotes = $true
                    break
                }
            }

            if ($hasQuantNotes) {
                Write-Host "  Quants :" -ForegroundColor DarkGray
                foreach ($qk in $def.Quants.Keys) {
                    $marker = if ($qk -eq $def.Quant) { "*" } else { " " }
                    $note = Get-ModelQuantNote -Def $def -QuantKey $qk
                    $fitClass = Get-QuantFitClass -Def $def -QuantKey $qk
                    $badge = Format-QuantFitBadge -FitClass $fitClass

                    $body = if ([string]::IsNullOrWhiteSpace($note)) { $def.Quants[$qk] } else { $note }
                    $prefix = "    {0} {1,-8} " -f $marker, $qk

                    if ([string]::IsNullOrWhiteSpace($badge)) {
                        Write-Host ("$prefix $body") -ForegroundColor DarkGray
                    } else {
                        Write-Host -NoNewline $prefix -ForegroundColor DarkGray
                        Write-Host -NoNewline (" {0,-7}" -f $badge) -ForegroundColor (Get-QuantFitBadgeColor -FitClass $fitClass)
                        Write-Host (" $body") -ForegroundColor DarkGray
                    }
                }
            }
        }

        $hasCtxNotes = $false
        foreach ($ck in $contextKeys) {
            if (-not [string]::IsNullOrWhiteSpace((Get-ModelContextNote -Def $def -ContextKey $ck))) {
                $hasCtxNotes = $true
                break
            }
        }

        if ($hasCtxNotes) {
            Write-Host "  Ctx    :" -ForegroundColor DarkGray
            foreach ($ck in $contextKeys) {
                $label = if ([string]::IsNullOrWhiteSpace($ck)) { "default" } else { $ck }
                $note = Get-ModelContextNote -Def $def -ContextKey $ck
                if ([string]::IsNullOrWhiteSpace($note)) {
                    $tokens = Get-ModelContextValue -Def $def -ContextKey $ck
                    Write-Host ("    {0,-8}  {1} tokens" -f $label, $tokens) -ForegroundColor DarkGray
                } else {
                    Write-Host ("    {0,-8}  {1}" -f $label, $note) -ForegroundColor DarkGray
                }
            }
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
    Write-Host "Quant-fit legend:    [fits] weights + ~7 GB headroom for KV  [tight] weights only  [over] partial offload" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Manage:" -ForegroundColor White
    Write-Host "  addllm <hf-url> -Key <key>     Add a model from HuggingFace" -ForegroundColor DarkGray
    Write-Host "  removellm <key>                Remove a model + its files" -ForegroundColor DarkGray
    Write-Host "  initmodel <key> [-Force]       (Re)build Ollama aliases for a model" -ForegroundColor DarkGray
    Write-Host "  cleanorphans                   List Ollama models not in llm-models.json" -ForegroundColor DarkGray
    Write-Host "  reloadllm, purge, ops, qkill, ostop, llm, llmdocs" -ForegroundColor DarkGray
    Write-Host "  Config: $script:LocalLLMConfigPath" -ForegroundColor DarkGray
}

function Show-ModelDetailFallback {
    # Per-model detail without Spectre. Mirrors Show-ModelDetailSpectre's fields.
    param([Parameter(Mandatory = $true)][string]$Key)

    $def = Get-ModelDef -Key $Key
    $tier = Get-ModelTier -Def $def
    $tierBadge = Format-ModelTierBadge -Def $def

    Write-Host ""
    Write-Host "$($def.DisplayName) " -ForegroundColor White -NoNewline
    Write-Host $tierBadge -ForegroundColor DarkYellow

    $description = Get-ModelDescription -Def $def
    if ($description) {
        Write-Host "  $description" -ForegroundColor Gray
    }

    $source = if ($def.SourceType -eq 'gguf') { "GGUF · $($def.Repo)" } else { "Remote · $($def.RemoteModel)" }
    Write-Host "  Source : $source" -ForegroundColor DarkGray
    Write-Host "  Parser : $($def.Parser)    LimitTools: $([bool]$def.LimitTools)" -ForegroundColor DarkGray

    if ($def.ContainsKey('ParserNote') -and $def.ParserNote) {
        Write-Host "  Note   : $($def.ParserNote)" -ForegroundColor DarkGray
    }

    if ($def.ContainsKey("Quants")) {
        Write-Host "  Quants :" -ForegroundColor White
        foreach ($qk in $def.Quants.Keys) {
            $marker = if ($qk -eq $def.Quant) { "*" } else { " " }
            $fit = Get-QuantFitClass -Def $def -QuantKey $qk
            $badge = Format-QuantFitBadge -FitClass $fit
            $size = Get-QuantSizeGB -Def $def -QuantKey $qk
            $sizeText = if ($null -eq $size) { '' } else { "{0,5:N1} GB" -f $size }
            $note = Get-ModelQuantNote -Def $def -QuantKey $qk
            if (-not $note) { $note = $def.Quants[$qk] }

            Write-Host -NoNewline ("    {0} {1,-8} " -f $marker, $qk)
            if ($badge) {
                Write-Host -NoNewline (" {0,-7}" -f $badge) -ForegroundColor (Get-QuantFitBadgeColor -FitClass $fit)
            }
            Write-Host -NoNewline (" {0,9} " -f $sizeText) -ForegroundColor DarkGray
            Write-Host $note -ForegroundColor DarkGray
        }
    }

    Write-Host "  Ctx    :" -ForegroundColor White
    foreach ($ck in $def.Contexts.Keys) {
        $label = if ([string]::IsNullOrWhiteSpace($ck)) { "default" } else { $ck }
        $tokens = Get-ModelContextValue -Def $def -ContextKey $ck
        $alias = Get-ModelAliasName -Def $def -ContextKey $ck
        $note = Get-ModelContextNote -Def $def -ContextKey $ck
        if ($note) {
            Write-Host ("    {0,-8}  {1,-22}  {2}" -f $label, $alias, $note) -ForegroundColor DarkGray
        } else {
            Write-Host ("    {0,-8}  {1,-22}  {2,7} tokens" -f $label, $alias, $tokens) -ForegroundColor DarkGray
        }
    }

    $installed = @(Get-OllamaInstalledModelNames)
    $aliases = @($def.Contexts.Keys | ForEach-Object { Get-ModelAliasName -Def $def -ContextKey $_ })
    Write-Host "  Built  : $(Format-AliasBuiltList -Names $aliases -Installed $installed)" -ForegroundColor DarkGray

    if ($def.Contains('Tools') -and -not [string]::IsNullOrWhiteSpace($def.Tools)) {
        Write-Host "  Tools  : $($def.Tools)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Show-LLMProfileInfo {
    param([switch]$All)

    Clear-Host
    Write-Host "Local LLM dashboard" -ForegroundColor Green

    Show-ClaudeTarget
    Show-OllamaStatus -All:$All
    Show-ModelCatalog -All:$All

    if (-not (Test-LocalLLMSpectreAvailable)) {
        Show-LocalLLMSpectreInstallHint
    }

    Write-Host ""
}

function info {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Key,
        [switch]$All
    )

    if ($Key) {
        $resolved = Resolve-ModelKeyByAnyName -Name $Key
        if (-not $resolved) {
            Write-Host "Unknown model: $Key" -ForegroundColor Red
            Write-Host "Known keys: $((@(Get-ModelKeys)) -join ', ')" -ForegroundColor DarkGray
            return
        }

        if (Test-LocalLLMSpectreAvailable) {
            Show-ModelDetailSpectre -Key $resolved
        } else {
            Show-ModelDetailFallback -Key $resolved
            Show-LocalLLMSpectreInstallHint
        }
        return
    }

    Show-LLMProfileInfo -All:$All
}

function llminfo {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Key,
        [switch]$All
    )

    if ($Key) {
        info -Key $Key
        return
    }

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
        [Alias("FreeCode", "Fc")][switch]$Unshackled,
        [switch]$Chat
    )

    $def = Get-ModelDef -Key $Key

    if ($UseQ8) {
        $numCtx = Get-ModelContextValue -Def $def -ContextKey $ContextKey
        $maxQ8 = Get-Q8KvMaxContext

        if ($numCtx -gt $maxQ8) {
            $ctxLabel = if ([string]::IsNullOrWhiteSpace($ContextKey)) { "default" } else { $ContextKey }
            $vramInfo = Get-LocalLLMVRAMInfo
            throw ("Refusing -Q8 with -Ctx $ctxLabel ($numCtx tokens). " +
                   "q8_0 KV cache at this length exceeds the ceiling for this host ($($vramInfo.GB) GB VRAM, $($vramInfo.Source); Q8KvMaxContext=$maxQ8). " +
                   "Drop -Q8 (q4_0 KV is the default), pick a smaller -Ctx, or raise the ceiling: Set-LocalLLMSetting Q8KvMaxContext <tokens>")
        }
    }

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
        Unshackled     = $Unshackled
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
                    [Alias("Fc", "FreeCode")][switch]$Unshackled,
                    [switch]$Chat,
                    [switch]$Q8
                )

                if ($Quant) {
                    Set-ModelQuant -Key $k -Quant $Quant
                    return
                }

                Invoke-ModelShortcut -Key $k -ContextKey $Ctx -UseQ8:$Q8 -Unshackled:$Unshackled -Chat:$Chat
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
function llmdefaultfc   { Invoke-ModelShortcut -Key (Get-DefaultModelKey) -ContextKey "" -Unshackled }
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

    $head = if ([string]::IsNullOrWhiteSpace($ContextKey)) {
        "$aliasName  ($ctx tokens, default)"
    } else {
        "$aliasName  ($ctx tokens, $ContextKey)"
    }

    $note = Get-ModelContextNote -Def $Def -ContextKey $ContextKey
    if ([string]::IsNullOrWhiteSpace($note)) {
        return $head
    }

    return "$head`n      $note"
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
        $head = "$key  ->  $($def.DisplayName)$quant | contexts: $contexts"

        $description = Get-ModelDescription -Def $def
        if ([string]::IsNullOrWhiteSpace($description)) {
            return $head
        }

        return "$head`n      $description"
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
        $note = Get-ModelQuantNote -Def $def -QuantKey $quantKey
        $badge = Format-QuantFitBadge -FitClass (Get-QuantFitClass -Def $def -QuantKey $quantKey)
        $badgeStr = if ($badge) { " $badge" } else { "" }
        $head = "$quantKey$badgeStr  ->  $($def.Quants[$quantKey])$current"

        if ([string]::IsNullOrWhiteSpace($note)) {
            return $head
        }

        return "$head`n      $note"
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
        [pscustomobject]@{ Key = "fc"; Label = "Unshackled"; Description = "Local agent via Unshackled" },
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
            Invoke-ModelShortcut -Key $ModelKey -ContextKey $ContextKey -Unshackled -UseQ8:$UseQ8
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

function Start-LLMWizardClassic {
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

# Spectre wizard
# Mirrors Start-LLMWizardClassic but uses PwshSpectreConsole's selection prompts.
# Gated on Test-LocalLLMSpectreAvailable (same env switch as the dashboard:
# $env:LOCAL_LLM_NO_SPECTRE=1 forces the classic wizard even when Spectre is installed).

function Show-LLMWizardHeaderSpectre {
    Format-SpectrePanel -Header "Local LLM launcher" -Color Green -Data ("[grey50]Config:[/] {0}" -f (ConvertTo-LocalLLMSpectreSafe $script:LocalLLMConfigPath)) | Out-Host
}

function Select-LLMModelKeySpectre {
    param([switch]$All)

    $keys = @(Get-FilteredModelKeys -IncludeAll:$All)
    if ($keys.Count -eq 0) {
        Write-Host "No models match the current filter." -ForegroundColor Yellow
        return $null
    }

    Show-ModelCatalogSpectre -All:$All

    $labelMap = [ordered]@{}
    foreach ($key in $keys) {
        $def = Get-ModelDef -Key $key
        $label = "{0}  ·  {1}" -f (ConvertTo-LocalLLMSpectreSafe $key), (ConvertTo-LocalLLMSpectreSafe $def.DisplayName)
        $labelMap[$label] = $key
    }
    if (-not $All) { $labelMap["[[Show all tiers]]"] = '__all__' }
    $labelMap["[[Cancel]]"] = '__cancel__'

    $chosen = Read-SpectreSelection -Message "Select model" -Choices @($labelMap.Keys) -PageSize 18
    if ($null -eq $chosen) { return $null }
    $value = $labelMap[$chosen]

    if ($value -eq '__cancel__') { return $null }
    if ($value -eq '__all__')    { return (Select-LLMModelKeySpectre -All) }
    return $value
}

function Select-LLMQuantKeySpectre {
    param([Parameter(Mandatory = $true)][string]$ModelKey)

    $def = Get-ModelDef -Key $ModelKey
    if (-not $def.ContainsKey("Quants")) { return $null }

    $labelMap = [ordered]@{}
    foreach ($qk in $def.Quants.Keys) {
        $fit = Get-QuantFitClass -Def $def -QuantKey $qk
        $fitTag = switch ($fit) {
            'fits'  { '[green]fits[/]' }
            'tight' { '[yellow]tight[/]' }
            'over'  { '[red]over[/]' }
            default { '[grey50]?[/]' }
        }
        $size = Get-QuantSizeGB -Def $def -QuantKey $qk
        $sizeStr = if ($null -eq $size) { '' } else { (' {0:N1}GB' -f $size) }
        $current = if ($qk -eq $def.Quant) { ' *' } else { '' }
        $note = Get-ModelQuantNote -Def $def -QuantKey $qk
        $noteSuffix = if ([string]::IsNullOrWhiteSpace($note)) { '' } else { " · " + (ConvertTo-LocalLLMSpectreSafe $note) }
        $qkSafe = ConvertTo-LocalLLMSpectreSafe $qk
        $label = "$qkSafe$current $fitTag$sizeStr$noteSuffix"
        $labelMap[$label] = $qk
    }
    $defQuantSafe = ConvertTo-LocalLLMSpectreSafe $def.Quant
    $labelMap["[[Keep current: $defQuantSafe]]"] = '__keep__'

    $modelKeySafe = ConvertTo-LocalLLMSpectreSafe $ModelKey
    $chosen = Read-SpectreSelection -Message "Select quant for $modelKeySafe" -Choices @($labelMap.Keys) -PageSize 12
    if ($null -eq $chosen) { return $def.Quant }
    $value = $labelMap[$chosen]

    if ($value -eq '__keep__') { return $def.Quant }
    return $value
}

function Select-LLMContextKeySpectre {
    param([Parameter(Mandatory = $true)][string]$ModelKey)

    $def = Get-ModelDef -Key $ModelKey

    $labelMap = [ordered]@{}
    foreach ($ck in $def.Contexts.Keys) {
        $aliasName = ConvertTo-LocalLLMSpectreSafe (Get-ModelAliasName -Def $def -ContextKey $ck)
        $tokens = Get-ModelContextValue -Def $def -ContextKey $ck
        $ctxLabel = if ([string]::IsNullOrWhiteSpace($ck)) { 'default' } else { $ck }
        $ctxLabelSafe = ConvertTo-LocalLLMSpectreSafe $ctxLabel
        $head = "$aliasName  ($tokens tokens, $ctxLabelSafe)"
        $note = Get-ModelContextNote -Def $def -ContextKey $ck
        $label = if ([string]::IsNullOrWhiteSpace($note)) { $head } else { "$head · " + (ConvertTo-LocalLLMSpectreSafe $note) }
        $labelMap[$label] = $ck
    }
    $labelMap["[[Back]]"] = '__back__'

    $modelKeySafe = ConvertTo-LocalLLMSpectreSafe $ModelKey
    $chosen = Read-SpectreSelection -Message "Select context for $modelKeySafe" -Choices @($labelMap.Keys) -PageSize 12
    if ($null -eq $chosen) { return $null }
    $value = $labelMap[$chosen]

    if ($value -eq '__back__') { return $null }
    return $value
}

function Select-LLMActionSpectre {
    $labelMap = [ordered]@{
        "Claude Code  -  Local model behind Claude Code" = 'claude'
        "Unshackled   -  Local agent via Unshackled"     = 'fc'
        "Ollama chat  -  Plain ollama run"               = 'chat'
        "Benchmark    -  Run ospeed for selected alias"  = 'benchmark'
        "Setup only   -  (Re)build alias"                = 'setup'
        "Show         -  Run ollama show"                = 'show'
        "[[Back]]"                                       = '__back__'
    }

    $chosen = Read-SpectreSelection -Message "Select action" -Choices @($labelMap.Keys) -PageSize 10
    if ($null -eq $chosen) { return $null }
    $value = $labelMap[$chosen]

    if ($value -eq '__back__') { return $null }
    return $value
}

function Read-LLMQ8ToggleSpectre {
    return [bool](Read-SpectreConfirm -Message "Use q8 KV cache?" -DefaultAnswer 'n')
}

function Get-LocalLLMErrorLogPath {
    $dir = Join-Path $HOME ".local-llm"
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    return (Join-Path $dir "wizard-errors.log")
}

function Save-LocalLLMWizardError {
    # Captures a full exception record so the Spectre live-display can't scroll it off
    # screen. Writes to ~/.local-llm/wizard-errors.log AND prints a high-contrast block.
    param(
        [Parameter(Mandatory = $true)]$ErrorRecord,
        [string]$Context = "wizard"
    )

    $logPath = Get-LocalLLMErrorLogPath
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $ex = $ErrorRecord.Exception
    $inner = if ($ex.InnerException) { $ex.InnerException.ToString() } else { "" }

    $block = @(
        "=== [$stamp] $Context ===",
        "Type:    $($ex.GetType().FullName)",
        "Message: $($ex.Message)",
        "InvocationInfo:",
        ($ErrorRecord.InvocationInfo.PositionMessage),
        "ScriptStackTrace:",
        ($ErrorRecord.ScriptStackTrace),
        "Inner:",
        $inner,
        "----",
        ""
    ) -join "`n"

    try { Add-Content -LiteralPath $logPath -Value $block -ErrorAction Stop } catch { }

    Write-Host ""
    Write-Host "=== ERROR captured ($Context) ===" -ForegroundColor Red
    Write-Host $ex.Message -ForegroundColor Yellow
    Write-Host $ErrorRecord.InvocationInfo.PositionMessage -ForegroundColor DarkGray
    Write-Host "Logged to $logPath" -ForegroundColor DarkGray
    Write-Host ""
}

function Invoke-LLMWizardStep {
    # Single-shot try/catch wrapper for one Spectre prompt. On error, logs the full record,
    # pauses so the user can read the screen, and returns $null instead of throwing further.
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Context,
        [object]$Default = $null
    )

    try {
        return (& $Action)
    }
    catch {
        Save-LocalLLMWizardError -ErrorRecord $_ -Context $Context
        Pause-Menu
        return $Default
    }
}

function Start-LLMWizardSpectre {
    while ($true) {
        Clear-Host
        Show-LLMWizardHeaderSpectre

        $modelKey = Invoke-LLMWizardStep -Context 'select-model' -Action {
            Select-LLMModelKeySpectre
        }

        if ([string]::IsNullOrWhiteSpace($modelKey)) {
            return
        }

        $def = Get-ModelDef -Key $modelKey

        if ($def.ContainsKey("Quants")) {
            $quantKey = Invoke-LLMWizardStep -Context "select-quant ($modelKey)" -Action {
                Select-LLMQuantKeySpectre -ModelKey $modelKey
            }
            if ($null -ne $quantKey) {
                try {
                    Set-ModelQuantForSelectedLaunch -ModelKey $modelKey -QuantKey $quantKey
                }
                catch {
                    Save-LocalLLMWizardError -ErrorRecord $_ -Context "set-quant ($modelKey -> $quantKey)"
                    Pause-Menu
                    continue
                }
            }
        }

        $contextKey = Invoke-LLMWizardStep -Context "select-context ($modelKey)" -Action {
            Select-LLMContextKeySpectre -ModelKey $modelKey
        }

        if ($null -eq $contextKey) {
            continue
        }

        $action = Invoke-LLMWizardStep -Context 'select-action' -Action {
            Select-LLMActionSpectre
        }

        if ([string]::IsNullOrWhiteSpace($action)) {
            continue
        }

        $useQ8 = $false
        if ($action -in @("chat", "fc", "claude")) {
            $useQ8 = Invoke-LLMWizardStep -Context 'q8-toggle' -Default $false -Action {
                Read-LLMQ8ToggleSpectre
            }
        }

        try {
            Invoke-LLMSelection -ModelKey $modelKey -ContextKey $contextKey -Action $action -UseQ8:$useQ8
        }
        catch {
            Save-LocalLLMWizardError -ErrorRecord $_ -Context "invoke ($modelKey/$contextKey/$action)"
            Pause-Menu
        }
    }
}

function llmlogerr {
    # Print the tail of ~/.local-llm/wizard-errors.log so a captured trace is easy to grab.
    param([int]$Lines = 80)

    $logPath = Get-LocalLLMErrorLogPath
    if (-not (Test-Path $logPath)) {
        Write-Host "No errors logged yet ($logPath does not exist)." -ForegroundColor DarkGray
        return
    }

    Write-Host "Tail of $logPath (last $Lines lines):" -ForegroundColor Cyan
    Get-Content -LiteralPath $logPath -Tail $Lines
}

function llmlogerrclear {
    $logPath = Get-LocalLLMErrorLogPath
    if (Test-Path $logPath) {
        Remove-Item -LiteralPath $logPath -Force
        Write-Host "Cleared $logPath" -ForegroundColor Green
    }
}

function Start-LLMWizard {
    if (Test-LocalLLMSpectreAvailable) {
        Start-LLMWizardSpectre
        return
    }

    Start-LLMWizardClassic
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

            $description = Get-ModelDescription -Def $def
            if (-not [string]::IsNullOrWhiteSpace($description)) {
                Write-Host "  About    : $description" -ForegroundColor Gray
            }

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

    $q8Max = Get-Q8KvMaxContext
    $q8MaxLabel = if ($q8Max -ge 1024) { "{0}k" -f [int]($q8Max / 1024) } else { "$q8Max" }

    Write-Host @"
One function per model — flags select what to do.
  qcoder -Ctx fast -Fc          Code agent (Qwen3-Coder, 32k, Unshackled)
  q36p -Ctx fast -Fc            General Qwen 3.6 agent (32k, Unshackled)
  dev -Ctx fast                 Smaller / faster (Devstral 24B, 32k)
  q36p -Ctx 128 -Fc             Big context (Qwen 3.6 Plus, 128k)
  qcoder -Ctx 256 -Quant iq4xs  256k coder context (4090 ceiling — no -Q8)
  q36p -Chat                    Raw ollama chat, no Claude Code
  q36p -Q8                      Use q8 KV cache for higher quality
  q36p -Quant q6kp              Switch the GGUF quant (rebuilds aliases)
  llmdefault                    Launch the configured Default model
  llm                           Guided wizard (rich UI if PwshSpectreConsole is installed)

Flags
  -Ctx <name>     One of the model's contexts (e.g. fast, deep, 128, 256). Omit for default.
  -Fc             Use Unshackled instead of Claude Code (alias for -Unshackled).
  -Chat           Run plain ollama chat (skips Claude Code entirely).
  -Q8             Set OLLAMA_KV_CACHE_TYPE=q8_0 for this launch.
                  Refused above $q8MaxLabel tokens — q8 KV at long context OOMs a 24GB card.
                  Override the threshold with: Set-LocalLLMSetting Q8KvMaxContext 262144
  -Quant <name>   Switch the model's selected quant (no launch). GGUF models only.

Tradeoffs / sizes
  Per-quant and per-context tradeoffs (file size, KV pressure, when to pick what)
  are shown inline by 'info' and the 'llm' wizard. Set them in llm-models.json
  as Description, QuantNotes, and ContextNotes fields.

Manage
  info                  Dashboard, recommended models only (rich UI if PwshSpectreConsole is installed)
  info -All             Dashboard with experimental + legacy
  info <key>            Per-model detail: description, quants table (with fit + size), contexts table
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
  addllm <hf-url-or-repo> -Key <key> -Description '...' -QuantNotes @{q4='~17 GB'} -ContextNotes @{'128'='131k'}
  initmodel <key>
  removellm <key> [-KeepFiles] [-Force]

  Auto-fill on add: Description (from base_model README), QuantSizesGB (from HF blob sizes),
  and a baseline QuantNotes per quant. Override any field by passing -Description / -QuantNotes etc.

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
"@

    Show-LLMDynamicModelSummary
}

function llm { Start-LLMWizard }
function llmmenu { Start-LLMWizard }
function llmc { Start-LLMWizardClassic }
