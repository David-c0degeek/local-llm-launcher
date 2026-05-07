# Pure argv builder for llama-server. No I/O, no process spawning — accept a
# resolved model def + GGUF path and emit a [string[]] ready to splat.
# Validation lives here too: turbo3/turbo4 KV cache types only work with the
# turboquant Docker image, so we fail early if a native run requests them.

$script:LlamaCppMainlineKvTypes = @('f16', 'bf16', 'f32', 'q8_0', 'q5_1', 'q5_0', 'q4_1', 'q4_0', 'iq4_nl')
$script:LlamaCppTurboKvTypes    = @('turbo3', 'turbo4')

function Test-LlamaCppKvType {
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$Mode
    )

    $type = $Type.ToLowerInvariant()

    if ($type -in $script:LlamaCppMainlineKvTypes) {
        return
    }

    if ($type -in $script:LlamaCppTurboKvTypes) {
        if ($Mode -ne 'turboquant') {
            throw "KV cache type '$type' requires the llama.cpp turboquant fork. Pick a mainline type ($($script:LlamaCppMainlineKvTypes -join ', ')) or switch to llama.cpp turboquant mode."
        }
        return
    }

    throw "Unknown KV cache type '$type'. Mainline: $($script:LlamaCppMainlineKvTypes -join ', '); turbo (turboquant only): $($script:LlamaCppTurboKvTypes -join ', ')."
}

function Get-LlamaCppKvTypes {
    # Resolve the active KV cache types from explicit args, then per-model
    # overrides, then defaults. Returns @{ K; V }.
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [string]$KvK,
        [string]$KvV
    )

    if ([string]::IsNullOrWhiteSpace($KvK)) {
        $KvK = if ($Def.Contains('KvCacheK') -and -not [string]::IsNullOrWhiteSpace($Def.KvCacheK)) { $Def.KvCacheK } else { 'q8_0' }
    }

    if ([string]::IsNullOrWhiteSpace($KvV)) {
        $KvV = if ($Def.Contains('KvCacheV') -and -not [string]::IsNullOrWhiteSpace($Def.KvCacheV)) { $Def.KvCacheV } else { $KvK }
    }

    return @{ K = $KvK; V = $KvV }
}

function Build-LlamaServerArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][ValidateSet('native', 'turboquant')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$ModelArgPath,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$Parallel,
        [int]$CacheReuse,
        [string]$KvK,
        [string]$KvV,
        [int]$NGpuLayers,
        [int]$NCpuMoe,
        [Nullable[bool]]$Mlock,
        [Nullable[bool]]$NoMmap,
        [int]$UbatchSize,
        [int]$BatchSize,
        [int]$Threads,
        [int]$ThreadsBatch,
        [Nullable[bool]]$FlashAttn,
        [ValidateSet('none', 'layer', 'row')][string]$SplitMode,
        [string]$ChatTemplate,
        [string]$ThinkingPolicy,
        [switch]$Strict,
        [string[]]$ExtraArgs
    )

    $argList = New-Object System.Collections.Generic.List[string]

    # Model file path. In docker mode the dispatcher passes the in-container
    # path (e.g. /models/foo.gguf); native passes the host path.
    $argList.Add('-m')          | Out-Null
    $argList.Add($ModelArgPath) | Out-Null

    # Context window. Catalog stores per-context-alias num_ctx values; default
    # to the largest declared context if the alias key is missing.
    $numCtx = $null
    if ($Def.Contains('Contexts') -and $Def.Contexts.Contains($ContextKey)) {
        $numCtx = [int]$Def.Contexts[$ContextKey]
    } else {
        $values = @()
        foreach ($v in $Def.Contexts.Values) { try { $values += [int]$v } catch {} }
        if ($values.Count -gt 0) { $numCtx = ($values | Measure-Object -Maximum).Maximum }
    }

    if ($numCtx -and $numCtx -gt 0) {
        $argList.Add('-c')              | Out-Null
        $argList.Add([string]$numCtx)   | Out-Null
    }

    $argList.Add('--host')        | Out-Null
    $argList.Add('127.0.0.1')     | Out-Null
    $argList.Add('--port')        | Out-Null
    $argList.Add([string]$Port)   | Out-Null

    # Agent launches are usually one interactive session, not a shared server.
    # Keeping a single slot improves cache locality and avoids side requests
    # competing with the main turn. Cache reuse lets llama-server shift cached
    # prefixes across repeated Claude/Unshackled prompts.
    if ($PSBoundParameters.ContainsKey('Parallel') -and $Parallel -gt 0) {
        $argList.Add('--parallel')     | Out-Null
        $argList.Add([string]$Parallel) | Out-Null
    }
    if ($PSBoundParameters.ContainsKey('CacheReuse') -and $CacheReuse -gt 0) {
        $argList.Add('--cache-reuse')      | Out-Null
        $argList.Add([string]$CacheReuse)  | Out-Null
    }

    # GPU layer count: per-call > per-model > default 999 (offload all).
    if (-not $PSBoundParameters.ContainsKey('NGpuLayers') -or $NGpuLayers -le 0) {
        $NGpuLayers = if ($Def.Contains('NGpuLayers')) { [int]$Def.NGpuLayers } else { 999 }
    }
    $argList.Add('-ngl')                  | Out-Null
    $argList.Add([string]$NGpuLayers)     | Out-Null

    # MoE CPU offload (Qwen3 MoE etc.). Per-call > per-model > $script:Cfg.LlamaCppNCpuMoe.
    if (-not $PSBoundParameters.ContainsKey('NCpuMoe')) {
        $NCpuMoe = if ($Def.Contains('NCpuMoe') -and $null -ne $Def.NCpuMoe) {
            try { [int]$Def.NCpuMoe } catch { [int]$script:Cfg.LlamaCppNCpuMoe }
        } else { [int]$script:Cfg.LlamaCppNCpuMoe }
    }
    if ($NCpuMoe -gt 0) {
        $argList.Add('--n-cpu-moe')         | Out-Null
        $argList.Add([string]$NCpuMoe)      | Out-Null
    }

    # mlock / no-mmap. Per-call > per-model > $script:Cfg.LlamaCppMlock / LlamaCppNoMmap.
    if ($null -eq $Mlock) {
        $Mlock = if ($Def.Contains('Mlock')) { [bool]$Def.Mlock } else { [bool]$script:Cfg.LlamaCppMlock }
    }
    if ($Mlock) { $argList.Add('--mlock') | Out-Null }

    if ($null -eq $NoMmap) {
        $NoMmap = if ($Def.Contains('NoMmap')) { [bool]$Def.NoMmap } else { [bool]$script:Cfg.LlamaCppNoMmap }
    }
    if ($NoMmap) { $argList.Add('--no-mmap') | Out-Null }

    # Batching. Emitted only when explicitly set. ub <= b is a hard llama-server
    # invariant; we don't enforce it here (tuner's responsibility).
    if ($PSBoundParameters.ContainsKey('UbatchSize') -and $UbatchSize -gt 0) {
        $argList.Add('--ubatch-size')      | Out-Null
        $argList.Add([string]$UbatchSize)  | Out-Null
    }
    if ($PSBoundParameters.ContainsKey('BatchSize') -and $BatchSize -gt 0) {
        $argList.Add('--batch-size')       | Out-Null
        $argList.Add([string]$BatchSize)   | Out-Null
    }

    # Thread pools. Only meaningful when CPU is doing work (MoE offload, dense
    # CPU-only). The tuner gates emission on $NCpuMoe > 0.
    if ($PSBoundParameters.ContainsKey('Threads') -and $Threads -gt 0) {
        $argList.Add('--threads')          | Out-Null
        $argList.Add([string]$Threads)     | Out-Null
    }
    if ($PSBoundParameters.ContainsKey('ThreadsBatch') -and $ThreadsBatch -gt 0) {
        $argList.Add('--threads-batch')    | Out-Null
        $argList.Add([string]$ThreadsBatch) | Out-Null
    }

    # Flash attention. Emitted only when caller passes a value — leaving the
    # llama-server default ("auto" since b6020) intact otherwise.
    if ($PSBoundParameters.ContainsKey('FlashAttn') -and $null -ne $FlashAttn) {
        $argList.Add('--flash-attn')                       | Out-Null
        $argList.Add($(if ($FlashAttn) { 'on' } else { 'off' })) | Out-Null
    }

    # Multi-GPU split mode. Emitted only when caller passes a value.
    if ($PSBoundParameters.ContainsKey('SplitMode') -and -not [string]::IsNullOrWhiteSpace($SplitMode)) {
        $argList.Add('--split-mode')   | Out-Null
        $argList.Add($SplitMode)       | Out-Null
    }

    # KV cache types (validated against mode).
    $kv = Get-LlamaCppKvTypes -Def $Def -KvK $KvK -KvV $KvV
    Test-LlamaCppKvType -Type $kv.K -Mode $Mode
    Test-LlamaCppKvType -Type $kv.V -Mode $Mode
    $argList.Add('--cache-type-k')   | Out-Null
    $argList.Add($kv.K)              | Out-Null
    $argList.Add('--cache-type-v')   | Out-Null
    $argList.Add($kv.V)              | Out-Null

    # Chat template — per-model override, else parser-based mapping.
    if ([string]::IsNullOrWhiteSpace($ChatTemplate) -and $Def.Contains('ChatTemplate') -and -not [string]::IsNullOrWhiteSpace($Def.ChatTemplate)) {
        $ChatTemplate = [string]$Def.ChatTemplate
    }

    $parser = if ($Def.Contains('Parser') -and -not [string]::IsNullOrWhiteSpace($Def.Parser)) { [string]$Def.Parser } else { 'none' }

    foreach ($a in (Resolve-LlamaCppChatTemplate -Parser $parser -Override $ChatTemplate)) {
        $argList.Add($a) | Out-Null
    }

    # Reasoning routing.
    if ([string]::IsNullOrWhiteSpace($ThinkingPolicy)) {
        $ThinkingPolicy = if ($Def.Contains('ThinkingPolicy') -and -not [string]::IsNullOrWhiteSpace($Def.ThinkingPolicy)) { [string]$Def.ThinkingPolicy } else { 'strip' }
    }
    foreach ($a in (Get-LlamaCppReasoningArgs -ThinkingPolicy $ThinkingPolicy -Parser $parser)) {
        $argList.Add($a) | Out-Null
    }

    # Sampling: parser values first, then strict overlay (overrides), then any
    # explicit ExtraArgs from the catalog/caller (wins last).
    foreach ($a in (ConvertFrom-OllamaParameter -Lines (Get-ParserLines $parser))) {
        $argList.Add($a) | Out-Null
    }

    if ($Strict) {
        foreach ($a in (Get-LlamaCppStrictSamplerArgs)) {
            $argList.Add($a) | Out-Null
        }
    }

    # Per-model ExtraArgs first, then per-call ExtraArgs (call wins because it
    # appears last on the CLI).
    if ($Def.Contains('ExtraArgs') -and $Def.ExtraArgs) {
        foreach ($a in @($Def.ExtraArgs)) { $argList.Add([string]$a) | Out-Null }
    }
    if ($ExtraArgs) {
        foreach ($a in $ExtraArgs) { $argList.Add([string]$a) | Out-Null }
    }

    return @($argList)
}
