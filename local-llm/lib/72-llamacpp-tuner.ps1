# Per-machine llama.cpp auto-tuner. Searches the perf-only parameter space for
# the highest-throughput launch config without touching anything that could
# change generations (quant, context, KV cache types stay locked unless the
# user explicitly widens). Full tuner uses a server fidelity baseline/final
# check and the llama-bench fast path for coarse perf-only phases when present.

$script:LlamaCppTunerVersion = 3
$script:LlamaCppCoarseMode = 'server'
$script:LlamaCppTrialDriverByPhase = @{}

# Fixed prompt + n_predict so cross-trial / cross-run numbers stay comparable.
# Length: ~280 tokens. Tuned to hit a representative mid-range prefill so
# pp_tps reflects realistic chat usage.
$script:LlamaCppTunerPrompt = @"
You are a senior performance engineer. Explain in detail why
the size of the physical batch (ubatch) matters for prompt-eval
throughput on a CUDA GPU running llama.cpp, and why pushing the
logical batch (batch) too high stops helping. Cover: cache
locality, kernel launch overhead, the cost of host->device
copies, KV-cache fill ordering, and how flash-attention's
fused kernels interact with batch size. Then give a short
checklist a developer can use to pick a good (ubatch, batch)
pair for a 24 GB single-GPU workstation. Keep the response
focused, clear, and around 350 words.
"@

$script:LlamaCppTunerNPredict = 256
$script:LlamaCppTunerPromptProfile = 'short'
$script:LlamaCppTunerBenchPromptTokens = 512

# Failure markers from llama-server / llama-bench stderr/stdout. Match case-insensitively.
$script:LlamaCppFailurePatterns = @(
    'cuda error: out of memory',
    'cudaerror_outofmemory',
    'failed to allocate',
    'ggml_cuda_host_malloc',
    'vulkan.*out of memory',
    'cublasstatus_alloc_failed',
    'cudamalloc.*failed',
    'unable to allocate',
    'failed to lock',
    'mlockall failed'
)

function Get-LlamaCppTunerRoot {
    $root = Join-Path $HOME ".local-llm\tuner"
    Ensure-Directory $root
    return $root
}

function Get-LlamaCppTunerHistoryFile {
    param([Parameter(Mandatory = $true)][string]$Key)
    return Join-Path (Get-LlamaCppTunerRoot) "history-$Key.jsonl"
}

function Get-LlamaCppTunerBestFile {
    param([Parameter(Mandatory = $true)][string]$Key)
    return Join-Path (Get-LlamaCppTunerRoot) "best-$Key.json"
}

function Test-LlamaCppOomMessage {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $lower = $Text.ToLowerInvariant()

    foreach ($pat in $script:LlamaCppFailurePatterns) {
        if ($lower -match $pat) { return $true }
    }

    return $false
}

function Test-LlamaCppFailureMessage {
    param([AllowEmptyString()][string]$Text)
    return (Test-LlamaCppOomMessage -Text $Text)
}

function Get-LlamaCppBuildStamp {
    param([ValidateSet('native','turboquant')][string]$Mode = 'native')

    $root = if ($Mode -eq 'turboquant') { Get-LlamaCppTurboquantInstallRoot } else { Get-LlamaCppInstallRoot }
    $path = Join-Path $root ".build-stamp"
    if (-not (Test-Path $path)) { return '' }

    try { return (Get-Content -Raw -Path $path -ErrorAction Stop).Trim() }
    catch { return '' }
}

function Get-LlamaCppGpuNames {
    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) { return @() }

    try {
        return @(& nvidia-smi --query-gpu=name --format=csv,noheader 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    catch {
        return @()
    }
}

function Read-LlamaCppStderrTail {
    # Returns the last ~16 KB of a file as a string, or '' if missing.
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) { return '' }

    try {
        $size = (Get-Item -LiteralPath $Path).Length
        if ($size -le 0) { return '' }
        $maxBytes = 16384
        $offset = if ($size -gt $maxBytes) { $size - $maxBytes } else { 0 }

        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $stream.Position = $offset
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            return $reader.ReadToEnd()
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        return ''
    }
}

function Resolve-LlamaCppTunerSearchSpace {
    # Derives per-model axis bounds from the catalog. Pure (no I/O).
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def
    )

    # Catalog-resolved baseline values — the tuner sweeps relative to these.
    $baselineNCpuMoe = if ($Def.Contains('NCpuMoe') -and $null -ne $Def.NCpuMoe) {
        try { [int]$Def.NCpuMoe } catch { [int]$script:Cfg.LlamaCppNCpuMoe }
    } else {
        [int]$script:Cfg.LlamaCppNCpuMoe
    }

    $baselineNgl = if ($Def.Contains('NGpuLayers')) { [int]$Def.NGpuLayers } else { 999 }

    $isMoE = $baselineNCpuMoe -gt 0

    # Upper bound for --n-cpu-moe sweep. Catalog can override; otherwise use a
    # generous cap above the baseline (covers Qwen3-MoE / GLM coder variants
    # whose top expert-layer count tops out around 60 today).
    $moeUpper = if ($Def.Contains('MoeExpertLayers') -and $null -ne $Def.MoeExpertLayers) {
        try { [int]$Def.MoeExpertLayers } catch { [Math]::Max(60, $baselineNCpuMoe + 20) }
    } else {
        [Math]::Max(60, $baselineNCpuMoe + 20)
    }

    $skipPhases = @()
    if ($Def.Contains('TunerSkipPhases') -and $Def.TunerSkipPhases) {
        $skipPhases = @($Def.TunerSkipPhases | ForEach-Object { [string]$_ })
    }

    return @{
        IsMoE             = $isMoE
        BaselineNCpuMoe   = $baselineNCpuMoe
        MoeUpper          = $moeUpper
        BaselineNgl       = $baselineNgl
        UbatchCandidates  = @(256, 512, 1024)
        BatchCandidates   = @(512, 1024, 2048)
        SkipPhases        = $skipPhases
    }
}

function Get-LlamaCppTrialPrompt {
    return @{ Prompt = $script:LlamaCppTunerPrompt; NPredict = $script:LlamaCppTunerNPredict }
}

function Set-LlamaCppTunerPromptProfile {
    param([ValidateSet('short','long')][string]$Profile = 'short')

    $script:LlamaCppTunerPromptProfile = $Profile
    if ($Profile -eq 'long') {
        $fixture = Get-LlamaCppPerplexityFixturePath
        $base = if ($fixture -and (Test-Path $fixture)) {
            Get-Content -Raw -Path $fixture
        } else {
            $script:LlamaCppTunerPrompt
        }
        $chunks = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt 80; $i++) { $chunks.Add($base) | Out-Null }
        $script:LlamaCppTunerPrompt = ($chunks -join "`n`n")
        $script:LlamaCppTunerBenchPromptTokens = 16384
        return
    }

    $script:LlamaCppTunerPrompt = @"
You are a senior performance engineer. Explain in detail why
the size of the physical batch (ubatch) matters for prompt-eval
throughput on a CUDA GPU running llama.cpp, and why pushing the
logical batch (batch) too high stops helping. Cover: cache
locality, kernel launch overhead, the cost of host->device
copies, KV-cache fill ordering, and how flash-attention's
fused kernels interact with batch size. Then give a short
checklist a developer can use to pick a good (ubatch, batch)
pair for a 24 GB single-GPU workstation. Keep the response
focused, clear, and around 350 words.
"@
    $script:LlamaCppTunerBenchPromptTokens = 512
}

function Get-LlamaCppMedian {
    param([double[]]$Values)

    if (-not $Values -or $Values.Count -eq 0) { return 0.0 }
    $sorted = @($Values | Sort-Object)
    $n = $sorted.Count
    if ($n % 2 -eq 1) { return [double]$sorted[[Math]::Floor($n / 2)] }
    return ([double]$sorted[($n / 2) - 1] + [double]$sorted[$n / 2]) / 2.0
}

function Copy-LlamaCppOverrides {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Overrides)

    $copy = [ordered]@{}
    foreach ($k in $Overrides.Keys) {
        $copy[$k] = $Overrides[$k]
    }
    return $copy
}

function Join-LlamaCppOverrides {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Base,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Overlay
    )

    $copy = Copy-LlamaCppOverrides -Overrides $Base
    foreach ($k in $Overlay.Keys) {
        $copy[$k] = $Overlay[$k]
    }
    return $copy
}

function Get-LlamaCppContextSizeForBench {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey
    )

    try { return [int](Get-ModelContextValue -Def $Def -ContextKey $ContextKey) }
    catch { return 0 }
}

function Build-LlamaBenchArgs {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][ValidateSet('native','turboquant')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$ModelArgPath,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Overrides
    )

    $args = New-Object System.Collections.Generic.List[string]
    $args.Add('-m') | Out-Null
    $args.Add($ModelArgPath) | Out-Null

    $ctx = Get-LlamaCppContextSizeForBench -Def $Def -ContextKey $ContextKey
    if ($ctx -gt 0) {
        $args.Add('-c') | Out-Null
        $args.Add([string]$ctx) | Out-Null
    }

    $ngl = if ($Overrides.Contains('NGpuLayers') -and $null -ne $Overrides.NGpuLayers) {
        [int]$Overrides.NGpuLayers
    } elseif ($Def.Contains('NGpuLayers')) {
        [int]$Def.NGpuLayers
    } else { 999 }
    $args.Add('-ngl') | Out-Null
    $args.Add([string]$ngl) | Out-Null

    $ncpuMoe = if ($Overrides.Contains('NCpuMoe') -and $null -ne $Overrides.NCpuMoe) {
        [int]$Overrides.NCpuMoe
    } elseif ($Def.Contains('NCpuMoe') -and $null -ne $Def.NCpuMoe) {
        try { [int]$Def.NCpuMoe } catch { [int]$script:Cfg.LlamaCppNCpuMoe }
    } else { [int]$script:Cfg.LlamaCppNCpuMoe }
    if ($ncpuMoe -gt 0) {
        $args.Add('-ncmoe') | Out-Null
        $args.Add([string]$ncpuMoe) | Out-Null
    }

    if ($Overrides.Contains('UbatchSize') -and $Overrides.UbatchSize) {
        $args.Add('-ub') | Out-Null
        $args.Add([string][int]$Overrides.UbatchSize) | Out-Null
    }
    if ($Overrides.Contains('BatchSize') -and $Overrides.BatchSize) {
        $args.Add('-b') | Out-Null
        $args.Add([string][int]$Overrides.BatchSize) | Out-Null
    }
    if ($Overrides.Contains('Threads') -and $Overrides.Threads) {
        $args.Add('-t') | Out-Null
        $args.Add([string][int]$Overrides.Threads) | Out-Null
    }
    if ($Overrides.Contains('ThreadsBatch') -and $Overrides.ThreadsBatch) {
        $args.Add('-tb') | Out-Null
        $args.Add([string][int]$Overrides.ThreadsBatch) | Out-Null
    }
    if ($Overrides.Contains('FlashAttn') -and $null -ne $Overrides.FlashAttn) {
        $args.Add('-fa') | Out-Null
        $args.Add($(if ([bool]$Overrides.FlashAttn) { '1' } else { '0' })) | Out-Null
    }
    if ($Overrides.Contains('Mlock') -and [bool]$Overrides.Mlock) {
        $args.Add('--mlock') | Out-Null
    }
    if ($Overrides.Contains('NoMmap') -and [bool]$Overrides.NoMmap) {
        $args.Add('--no-mmap') | Out-Null
    }

    if ($Overrides.Contains('KvK') -and $Overrides.KvK) {
        Test-LlamaCppKvType -Type $Overrides.KvK -Mode $Mode
        $args.Add('-ctk') | Out-Null
        $args.Add([string]$Overrides.KvK) | Out-Null
    }
    if ($Overrides.Contains('KvV') -and $Overrides.KvV) {
        Test-LlamaCppKvType -Type $Overrides.KvV -Mode $Mode
        $args.Add('-ctv') | Out-Null
        $args.Add([string]$Overrides.KvV) | Out-Null
    }

    $args.Add('-p') | Out-Null
    $args.Add([string]$script:LlamaCppTunerBenchPromptTokens) | Out-Null
    $args.Add('-n') | Out-Null
    $args.Add('128') | Out-Null
    $args.Add('-o') | Out-Null
    $args.Add('json') | Out-Null

    return @($args)
}

function Read-LlamaBenchJsonRows {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    try {
        $parsed = $Text | ConvertFrom-Json
        if ($parsed -is [array]) { return @($parsed) }
        if ($parsed.data) { return @($parsed.data) }
        if ($parsed.results) { return @($parsed.results) }
        return @($parsed)
    }
    catch {
        $rows = @()
        foreach ($line in ($Text -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $rows += ($line | ConvertFrom-Json) } catch {}
        }
        return @($rows)
    }
}

function Get-LlamaBenchMetricValue {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($name in $Names) {
        $prop = $Row.PSObject.Properties[$name]
        if ($prop -and $null -ne $prop.Value) {
            try { return [double]$prop.Value } catch {}
        }
    }
    return 0.0
}

function Get-LlamaCppPerplexityFixturePath {
    $path = Join-Path (Split-Path -Parent $PSScriptRoot) "data\perplexity-fixture.txt"
    if (Test-Path $path) { return $path }
    return $null
}

function Build-LlamaPerplexityArgs {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][ValidateSet('native','turboquant')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$ModelArgPath,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Overrides,
        [Parameter(Mandatory = $true)][string]$PromptFile
    )

    $args = New-Object System.Collections.Generic.List[string]
    $args.Add('-m') | Out-Null
    $args.Add($ModelArgPath) | Out-Null
    $args.Add('-f') | Out-Null
    $args.Add($PromptFile) | Out-Null

    $ctx = Get-LlamaCppContextSizeForBench -Def $Def -ContextKey $ContextKey
    if ($ctx -gt 0) {
        $args.Add('-c') | Out-Null
        $args.Add([string]$ctx) | Out-Null
    }

    $ngl = if ($Overrides.Contains('NGpuLayers') -and $null -ne $Overrides.NGpuLayers) {
        [int]$Overrides.NGpuLayers
    } elseif ($Def.Contains('NGpuLayers')) {
        [int]$Def.NGpuLayers
    } else { 999 }
    $args.Add('-ngl') | Out-Null
    $args.Add([string]$ngl) | Out-Null

    if ($Overrides.Contains('NCpuMoe') -and $Overrides.NCpuMoe) {
        $args.Add('-ncmoe') | Out-Null
        $args.Add([string][int]$Overrides.NCpuMoe) | Out-Null
    }
    if ($Overrides.Contains('UbatchSize') -and $Overrides.UbatchSize) {
        $args.Add('-ub') | Out-Null
        $args.Add([string][int]$Overrides.UbatchSize) | Out-Null
    }
    if ($Overrides.Contains('BatchSize') -and $Overrides.BatchSize) {
        $args.Add('-b') | Out-Null
        $args.Add([string][int]$Overrides.BatchSize) | Out-Null
    }
    if ($Overrides.Contains('Threads') -and $Overrides.Threads) {
        $args.Add('-t') | Out-Null
        $args.Add([string][int]$Overrides.Threads) | Out-Null
    }
    if ($Overrides.Contains('ThreadsBatch') -and $Overrides.ThreadsBatch) {
        $args.Add('-tb') | Out-Null
        $args.Add([string][int]$Overrides.ThreadsBatch) | Out-Null
    }
    if ($Overrides.Contains('FlashAttn') -and $null -ne $Overrides.FlashAttn) {
        $args.Add('-fa') | Out-Null
        $args.Add($(if ([bool]$Overrides.FlashAttn) { '1' } else { '0' })) | Out-Null
    }
    if ($Overrides.Contains('Mlock') -and [bool]$Overrides.Mlock) {
        $args.Add('--mlock') | Out-Null
    }
    if ($Overrides.Contains('NoMmap') -and [bool]$Overrides.NoMmap) {
        $args.Add('--no-mmap') | Out-Null
    }
    if ($Overrides.Contains('KvK') -and $Overrides.KvK) {
        Test-LlamaCppKvType -Type $Overrides.KvK -Mode $Mode
        $args.Add('-ctk') | Out-Null
        $args.Add([string]$Overrides.KvK) | Out-Null
    }
    if ($Overrides.Contains('KvV') -and $Overrides.KvV) {
        Test-LlamaCppKvType -Type $Overrides.KvV -Mode $Mode
        $args.Add('-ctv') | Out-Null
        $args.Add([string]$Overrides.KvV) | Out-Null
    }

    return @($args)
}

function Invoke-LlamaCppPerplexity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][ValidateSet('native','turboquant')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$ModelArgPath,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Overrides,
        [string]$PromptFile
    )

    if ($Mode -eq 'turboquant') { return $null }
    if ([string]::IsNullOrWhiteSpace($PromptFile)) { $PromptFile = Get-LlamaCppPerplexityFixturePath }
    if ([string]::IsNullOrWhiteSpace($PromptFile) -or -not (Test-Path $PromptFile)) { return $null }

    $exe = $null
    try { $exe = Ensure-LlamaPerplexityExe -NonInteractive } catch { $exe = $null }
    if ([string]::IsNullOrWhiteSpace($exe) -or -not (Test-Path $exe)) { return $null }

    $args = Build-LlamaPerplexityArgs -Def $Def -ContextKey $ContextKey -Mode $Mode -ModelArgPath $ModelArgPath -Overrides $Overrides -PromptFile $PromptFile
    $logDir = Join-Path (Get-LlamaCppTunerRoot) 'logs'
    Ensure-Directory $logDir
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    $stderrPath = Join-Path $logDir "perplexity-$stamp-stderr.log"
    $stdoutPath = Join-Path $logDir "perplexity-$stamp-stdout.log"

    try {
        $proc = Start-Process -FilePath $exe `
            -ArgumentList $args `
            -RedirectStandardError $stderrPath `
            -RedirectStandardOutput $stdoutPath `
            -PassThru -WindowStyle Hidden -Wait -ErrorAction Stop
        if ($proc.ExitCode -ne 0) { return $null }
    }
    catch {
        return $null
    }

    $text = (Read-LlamaCppStderrTail -Path $stdoutPath) + "`n" + (Read-LlamaCppStderrTail -Path $stderrPath)
    $matches = [regex]::Matches($text, '(?i)(?:perplexity|ppl)\s*(?:=|:)\s*([0-9]+(?:\.[0-9]+)?)')
    if ($matches.Count -eq 0) { return $null }

    Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
    return [double]$matches[$matches.Count - 1].Groups[1].Value
}

function Invoke-LlamaCppTrialServer {
    # Runs one configured llama-server, posts a fixed completion, and returns
    # a BenchTrial hashtable. Caller is responsible for stop/cleanup of any
    # prior session — we Stop-LlamaServer at the start defensively.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][ValidateSet('native', 'turboquant')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$ModelArgPath,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Overrides,
        [Parameter(Mandatory = $true)][string]$Phase,
        [int]$Runs = 1,
        [int]$WaitTimeoutSec
    )

    if (-not $WaitTimeoutSec -or $WaitTimeoutSec -le 0) {
        $WaitTimeoutSec = if ($script:Cfg.Contains('LlamaCppHealthCheckTimeoutSec')) {
            [int]$script:Cfg.LlamaCppHealthCheckTimeoutSec
        } else { 120 }
    }

    Stop-LlamaServer -Quiet

    $defaultPort = if ($script:Cfg.Contains('LlamaCppPort')) { [int]$script:Cfg.LlamaCppPort } else { 8080 }
    $port = Find-LlamaCppFreePort -StartPort $defaultPort

    # Build args — splat known tunable overrides and let Build-LlamaServerArgs
    # fill defaults from the catalog for everything else.
    $buildParams = @{
        Def          = $Def
        ContextKey   = $ContextKey
        Mode         = $Mode
        ModelArgPath = $ModelArgPath
        Port         = $port
    }
    foreach ($k in @('KvK','KvV','NGpuLayers','NCpuMoe','UbatchSize','BatchSize','Threads','ThreadsBatch','Mlock','NoMmap','FlashAttn','SplitMode')) {
        if ($Overrides.Contains($k) -and $null -ne $Overrides[$k]) {
            $buildParams[$k] = $Overrides[$k]
        }
    }

    $serverArgs = Build-LlamaServerArgs @buildParams

    $serverPath = if ($Mode -eq 'turboquant') {
        Ensure-LlamaServerTurboquant -NonInteractive
    } else {
        Ensure-LlamaServerNative -NonInteractive
    }

    $logDir = Join-Path (Get-LlamaCppTunerRoot) 'logs'
    Ensure-Directory $logDir
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    $stderrPath = Join-Path $logDir "trial-$stamp-stderr.log"
    $stdoutPath = Join-Path $logDir "trial-$stamp-stdout.log"

    $proc = $null
    $oom = $false
    $startupOk = $false
    $errorText = $null
    $samples = @()

    try {
        $proc = Start-Process -FilePath $serverPath `
            -ArgumentList $serverArgs `
            -RedirectStandardError $stderrPath `
            -RedirectStandardOutput $stdoutPath `
            -PassThru -WindowStyle Hidden -ErrorAction Stop

        Set-CurrentBackendSession -Session @{
            Backend  = 'llamacpp'
            Mode     = $Mode
            Port     = $port
            BaseUrl  = "http://localhost:$port"
            Model    = $Def.Root
            GgufPath = $ModelArgPath
            Pid      = $proc.Id
        }

        try {
            Wait-LlamaServer -Port $port -TimeoutSec $WaitTimeoutSec
            $startupOk = $true
        }
        catch {
            $errorText = $_.Exception.Message
            $tail = (Read-LlamaCppStderrTail -Path $stderrPath) + "`n" + (Read-LlamaCppStderrTail -Path $stdoutPath)
            if (Test-LlamaCppOomMessage -Text $tail) { $oom = $true }
        }

        if ($startupOk) {
            $body = @{
                prompt       = $script:LlamaCppTunerPrompt
                n_predict    = $script:LlamaCppTunerNPredict
                stream       = $false
                cache_prompt = $false
                temperature  = 0
            } | ConvertTo-Json -Depth 4 -Compress

            for ($i = 1; $i -le [Math]::Max(1, $Runs); $i++) {
                try {
                    $resp = Invoke-RestMethod `
                        -Uri "http://127.0.0.1:$port/completion" `
                        -Method Post `
                        -ContentType 'application/json' `
                        -Body $body `
                        -TimeoutSec 1800
                }
                catch {
                    $errorText = $_.Exception.Message
                    $tail = (Read-LlamaCppStderrTail -Path $stderrPath) + "`n" + (Read-LlamaCppStderrTail -Path $stdoutPath)
                    if (Test-LlamaCppOomMessage -Text $tail) { $oom = $true }
                    break
                }

                $pp = 0.0
                $tg = 0.0
                if ($resp -and $resp.timings) {
                    if ($resp.timings.prompt_per_second)    { $pp = [double]$resp.timings.prompt_per_second }
                    if ($resp.timings.predicted_per_second) { $tg = [double]$resp.timings.predicted_per_second }
                }

                $samples += [pscustomobject]@{ pp_tps = $pp; tg_tps = $tg }
            }
        }
    }
    finally {
        Stop-LlamaServer -Quiet
        # Best-effort log retention: keep stderr only on failure (so OOM
        # diagnoses survive) and toss it on success to avoid disk bloat.
        if ($startupOk -and -not $oom) {
            Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        }
    }

    $ppValues = @($samples | ForEach-Object { $_.pp_tps })
    $tgValues = @($samples | ForEach-Object { $_.tg_tps })

    $ppMedian = Get-LlamaCppMedian -Values $ppValues
    $tgMedian = Get-LlamaCppMedian -Values $tgValues

    $variance = 0.0
    if ($tgValues.Count -ge 2) {
        $maxTg = ($tgValues | Measure-Object -Maximum).Maximum
        $minTg = ($tgValues | Measure-Object -Minimum).Minimum
        if ($maxTg -gt 0) { $variance = [double](($maxTg - $minTg) / $maxTg) }
    }

    return @{
        ts         = (Get-Date).ToString('o')
        phase      = $Phase
        overrides  = $Overrides
        args       = $serverArgs
        oom        = $oom
        startup_ok = $startupOk
        runs       = $samples.Count
        pp_tps     = [math]::Round($ppMedian, 2)
        tg_tps     = [math]::Round($tgMedian, 2)
        variance   = [math]::Round($variance, 3)
        port       = $port
        error      = $errorText
        log_path   = if ($startupOk -and -not $oom) { $null } else { $stderrPath }
    }
}

function Invoke-LlamaCppTrialBench {
    # Runs one configured llama-bench process and returns the same trial shape
    # as Invoke-LlamaCppTrialServer. Mainline only; turboquant falls back to server.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][ValidateSet('native', 'turboquant')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$ModelArgPath,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Overrides,
        [Parameter(Mandatory = $true)][string]$Phase,
        [int]$Runs = 1,
        [int]$WaitTimeoutSec
    )

    if ($Mode -eq 'turboquant') {
        return (Invoke-LlamaCppTrialServer @PSBoundParameters)
    }

    $benchPath = $null
    try { $benchPath = Ensure-LlamaBenchExe -NonInteractive } catch { $benchPath = $null }
    if ([string]::IsNullOrWhiteSpace($benchPath) -or -not (Test-Path $benchPath)) {
        return (Invoke-LlamaCppTrialServer @PSBoundParameters)
    }

    $benchArgs = Build-LlamaBenchArgs `
        -Def $Def `
        -ContextKey $ContextKey `
        -Mode $Mode `
        -ModelArgPath $ModelArgPath `
        -Overrides $Overrides

    $logDir = Join-Path (Get-LlamaCppTunerRoot) 'logs'
    Ensure-Directory $logDir
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    $stderrPath = Join-Path $logDir "trial-$stamp-bench-stderr.log"
    $stdoutPath = Join-Path $logDir "trial-$stamp-bench-stdout.log"

    $exitCode = $null
    $errorText = $null
    $oom = $false
    $ppValues = @()
    $tgValues = @()

    try {
        $proc = Start-Process -FilePath $benchPath `
            -ArgumentList $benchArgs `
            -RedirectStandardError $stderrPath `
            -RedirectStandardOutput $stdoutPath `
            -PassThru -WindowStyle Hidden -Wait -ErrorAction Stop
        $exitCode = $proc.ExitCode
    }
    catch {
        $errorText = $_.Exception.Message
    }

    $stdout = Read-LlamaCppStderrTail -Path $stdoutPath
    $stderr = Read-LlamaCppStderrTail -Path $stderrPath
    $rows = @(Read-LlamaBenchJsonRows -Text $stdout)

    foreach ($row in $rows) {
        $ppValues += (Get-LlamaBenchMetricValue -Row $row -Names @('pp_avg_ts','pp512','prompt_per_second','prompt_tps','pp_tps'))
        $tgValues += (Get-LlamaBenchMetricValue -Row $row -Names @('tg_avg_ts','tg128','predicted_per_second','generation_tps','tg_tps'))
    }

    if ($exitCode -ne 0 -or $rows.Count -eq 0) {
        $errorText = if ($errorText) { $errorText } else { "llama-bench exited with code $exitCode" }
        if (Test-LlamaCppFailureMessage -Text ($stderr + "`n" + $stdout)) { $oom = $true }
    }

    $startupOk = ($exitCode -eq 0 -and $rows.Count -gt 0)

    if ($startupOk -and -not $oom) {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
    }

    return @{
        ts         = (Get-Date).ToString('o')
        phase      = $Phase
        overrides  = $Overrides
        args       = $benchArgs
        oom        = $oom
        startup_ok = $startupOk
        runs       = $rows.Count
        pp_tps     = [math]::Round((Get-LlamaCppMedian -Values $ppValues), 2)
        tg_tps     = [math]::Round((Get-LlamaCppMedian -Values $tgValues), 2)
        variance   = 0.0
        port       = $null
        error      = $errorText
        log_path   = if ($startupOk -and -not $oom) { $null } else { $stderrPath }
    }
}

function Get-LlamaCppTrialScore {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Trial,
        [ValidateSet('gen', 'prompt', 'both')][string]$Optimize = 'gen'
    )

    if ($Trial.oom -or -not $Trial.startup_ok) { return 0.0 }

    switch ($Optimize) {
        'gen'    { return [double]$Trial.tg_tps }
        'prompt' { return [double]$Trial.pp_tps }
        'both'   {
            # Geometric mean — symmetric, penalizes lopsided wins.
            $pp = [double]$Trial.pp_tps
            $tg = [double]$Trial.tg_tps
            if ($pp -le 0 -or $tg -le 0) { return 0.0 }
            return [math]::Sqrt($pp * $tg)
        }
    }
}

function Append-LlamaCppTunerHistory {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Trial
    )

    $path = Get-LlamaCppTunerHistoryFile -Key $Key
    $line = ($Trial | ConvertTo-Json -Compress -Depth 6)
    Add-Content -Path $path -Value $line -Encoding UTF8
}

function Format-LlamaCppOverrides {
    # One-line pretty form for trial tables. Hides nulls.
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Overrides)

    $parts = @()
    foreach ($k in @('NGpuLayers','NCpuMoe','UbatchSize','BatchSize','Threads','FlashAttn','Mlock','NoMmap','KvK','KvV')) {
        if ($Overrides.Contains($k) -and $null -ne $Overrides[$k]) {
            $parts += "$k=$($Overrides[$k])"
        }
    }

    return ($parts -join ' ')
}

function Show-LlamaCppTrialRow {
    param(
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Trial,
        [double]$Score
    )

    $status = if ($Trial.oom) { 'OOM' } elseif (-not $Trial.startup_ok) { 'FAIL' } else { 'OK' }
    $color = switch ($status) {
        'OOM'  { 'Red' }
        'FAIL' { 'Yellow' }
        default { 'Green' }
    }

    $line = ('  [{0,2}] {1,-4} pp={2,7:N2} tg={3,7:N2}  score={4,7:N2}  phase={5,-12} {6}' -f `
        $Index, $status, $Trial.pp_tps, $Trial.tg_tps, $Score, $Trial.phase, (Format-LlamaCppOverrides -Overrides $Trial.overrides))
    Write-Host $line -ForegroundColor $color
}

function Invoke-LlamaCppTunerTrial {
    # Single-trial wrapper that handles bookkeeping (history, table row, score).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][ValidateSet('native','turboquant')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$ModelArgPath,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Overrides,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][int]$Runs,
        [ValidateSet('server','bench')][string]$Driver = 'server',
        [ValidateSet('gen','prompt','both')][string]$Optimize = 'gen'
    )

    if ($Driver -eq 'bench') {
        $trial = Invoke-LlamaCppTrialBench `
            -Def $Def `
            -ContextKey $ContextKey `
            -Mode $Mode `
            -ModelArgPath $ModelArgPath `
            -Overrides $Overrides `
            -Phase $Phase `
            -Runs $Runs
    } else {
        $trial = Invoke-LlamaCppTrialServer `
            -Def $Def `
            -ContextKey $ContextKey `
            -Mode $Mode `
            -ModelArgPath $ModelArgPath `
            -Overrides $Overrides `
            -Phase $Phase `
            -Runs $Runs
    }

    $score = Get-LlamaCppTrialScore -Trial $trial -Optimize $Optimize
    $trial.score = [math]::Round([double]$score, 2)
    $trial.score_unit = "${Optimize}_tps_median"
    $trial.tuner_version = $script:LlamaCppTunerVersion
    $trial.driver = $Driver
    $script:LlamaCppTrialDriverByPhase[$Phase] = $Driver

    Append-LlamaCppTunerHistory -Key $Key -Trial $trial
    Show-LlamaCppTrialRow -Index $Index -Trial $trial -Score $score

    return $trial
}

function Test-LlamaCppMonotonicityOom {
    # Phase-2 pruning: once we OOM at a given (NCpuMoe / NGpuLayers) value,
    # any value that uses MORE VRAM is guaranteed to OOM too. NCpuMoe smaller
    # and NGpuLayers larger both increase VRAM use.
    param(
        [Parameter(Mandatory = $true)][hashtable]$Candidate,
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[hashtable]]$History
    )

    foreach ($t in $History) {
        if (-not $t.oom) { continue }
        $tov = $t.overrides

        if ($Candidate.Contains('NCpuMoe') -and $tov.Contains('NCpuMoe')) {
            if ([int]$Candidate.NCpuMoe -lt [int]$tov.NCpuMoe) { return $true }
        }
        if ($Candidate.Contains('NGpuLayers') -and $tov.Contains('NGpuLayers')) {
            if ([int]$Candidate.NGpuLayers -gt [int]$tov.NGpuLayers) { return $true }
        }
    }

    return $false
}

function Save-LlamaCppBestConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$Quant,
        [Parameter(Mandatory = $true)][int]$VramGB,
        [ValidateSet('short','long')][string]$PromptLength = 'short',
        [Parameter(Mandatory = $true)][string[]]$BestArgs,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$BestOverrides,
        [Parameter(Mandatory = $true)][double]$Score,
        [string]$ScoreUnit = 'tg_tps_median',
        [int]$TrialCount = 0
    )

    $path = Get-LlamaCppTunerBestFile -Key $Key

    $existing = if (Test-Path $path) {
        try { Get-Content -Raw -Path $path | ConvertFrom-Json -AsHashtable } catch { $null }
    } else { $null }

    if (-not $existing -or -not $existing.Contains('schema')) {
        $existing = [ordered]@{
            schema  = 1
            key     = $Key
            vramGB  = $VramGB
            entries = @()
        }
    }

    $entries = @($existing.entries | Where-Object {
        $entryPromptLength = if ($_.prompt_length) { [string]$_.prompt_length } else { 'short' }
        $_.quant -ne $Quant -or
        $_.contextKey -ne $ContextKey -or
        $_.mode -ne $Mode -or
        [int]$_.vramGB -ne $VramGB -or
        $entryPromptLength -ne $PromptLength
    })

    $newEntry = [ordered]@{
        quant         = $Quant
        contextKey    = $ContextKey
        mode          = $Mode
        vramGB        = $VramGB
        prompt_length = $PromptLength
        score         = [math]::Round($Score, 2)
        scoreUnit     = $ScoreUnit
        args          = @($BestArgs)
        overrides     = $BestOverrides
        measured_at   = (Get-Date).ToString('o')
        tuner_version = $script:LlamaCppTunerVersion
        trial_count   = $TrialCount
        gpu_names     = @(Get-LlamaCppGpuNames)
        llamacpp_build = (Get-LlamaCppBuildStamp -Mode $Mode)
    }

    $entries += $newEntry

    $existing.vramGB  = $VramGB
    $existing.key     = $Key
    $existing.schema  = 1
    $existing.entries = $entries

    $json = $existing | ConvertTo-Json -Depth 8
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $json, $utf8NoBom)

    return $path
}

function Get-BestLlamaCppConfig {
    # Loads a saved best-config entry matching (key, quant, contextKey, mode, vramGB±1).
    # Returns $null on miss. The launcher uses this for -AutoBest.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][string]$Mode,
        [ValidateSet('short','long')][string]$PromptLength = 'short',
        [string]$Quant,
        [int]$VramGB
    )

    $path = Get-LlamaCppTunerBestFile -Key $Key
    if (-not (Test-Path $path)) { return $null }

    $data = $null
    try { $data = Get-Content -Raw -Path $path | ConvertFrom-Json -AsHashtable }
    catch { return $null }

    if (-not $data -or -not $data.Contains('entries')) { return $null }
    if ([int]($data.tuner_version) -gt 0 -and [int]$data.tuner_version -ne $script:LlamaCppTunerVersion) {
        return $null
    }

    if (-not $VramGB) { $VramGB = Get-LocalLLMVRAMGB }

    if ([string]::IsNullOrWhiteSpace($Quant)) {
        $def = Get-ModelDef -Key $Key
        if ($def.Contains('Quant')) { $Quant = [string]$def.Quant }
    }

    foreach ($entry in $data.entries) {
        if ($entry.contextKey -ne $ContextKey) { continue }
        if ($entry.mode       -ne $Mode)       { continue }
        $entryPromptLength = if ($entry.prompt_length) { [string]$entry.prompt_length } else { 'short' }
        if ($entryPromptLength -ne $PromptLength) { continue }
        if ($Quant -and $entry.quant -ne $Quant) { continue }
        $delta = [Math]::Abs([int]$entry.vramGB - [int]$VramGB)
        if ($delta -gt 1) { continue }
        if ($entry.tuner_version -and [int]$entry.tuner_version -ne $script:LlamaCppTunerVersion) { continue }
        return $entry
    }

    return $null
}

function Get-LlamaCppBestConfigCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][string]$Mode,
        [ValidateSet('short','long')][string]$PromptLength = 'short',
        [string]$Quant
    )

    $path = Get-LlamaCppTunerBestFile -Key $Key
    if (-not (Test-Path $path)) { return @() }

    try { $data = Get-Content -Raw -Path $path | ConvertFrom-Json }
    catch { return @() }

    if (-not $data -or -not $data.entries) { return @() }
    return @($data.entries | Where-Object {
        $_.contextKey -eq $ContextKey -and
        $_.mode -eq $Mode -and
        ($(if ($_.prompt_length) { [string]$_.prompt_length } else { 'short' }) -eq $PromptLength) -and
        ([string]::IsNullOrWhiteSpace($Quant) -or $_.quant -eq $Quant)
    })
}

function Remove-LlamaCppBestConfig {
    # Deletes saved best-config entries for the current local target. Used by
    # the wizard's reset action before re-tuning.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][string]$Mode,
        [string]$Quant,
        [int]$VramGB,
        [ValidateSet('short','long')][string]$PromptLength,
        [switch]$AllPromptLengths
    )

    if (-not $VramGB) { $VramGB = Get-LocalLLMVRAMGB }
    if ([string]::IsNullOrWhiteSpace($Quant)) {
        $def = Get-ModelDef -Key $Key
        if ($def.Contains('Quant')) { $Quant = [string]$def.Quant }
    }

    $path = Get-LlamaCppTunerBestFile -Key $Key
    if (-not (Test-Path $path)) {
        return [pscustomobject]@{ Path = $path; Removed = 0; Remaining = 0; DeletedFile = $false }
    }

    $data = $null
    try { $data = Get-Content -Raw -Path $path | ConvertFrom-Json -AsHashtable }
    catch {
        throw "Could not read saved best settings from $path. $($_.Exception.Message)"
    }

    if (-not $data -or -not $data.Contains('entries')) {
        return [pscustomobject]@{ Path = $path; Removed = 0; Remaining = 0; DeletedFile = $false }
    }

    $kept = @()
    $removed = 0
    foreach ($entry in @($data.entries)) {
        $entryPromptLength = if ($entry.prompt_length) { [string]$entry.prompt_length } else { 'short' }
        $vramMatches = $entry.vramGB -and ([Math]::Abs([int]$entry.vramGB - [int]$VramGB) -le 1)
        $promptMatches = if ($AllPromptLengths -or [string]::IsNullOrWhiteSpace($PromptLength)) {
            $true
        } else {
            $entryPromptLength -eq $PromptLength
        }

        $matches = (
            $entry.contextKey -eq $ContextKey -and
            $entry.mode -eq $Mode -and
            $vramMatches -and
            $promptMatches -and
            ([string]::IsNullOrWhiteSpace($Quant) -or $entry.quant -eq $Quant)
        )

        if ($matches) {
            $removed++
        } else {
            $kept += $entry
        }
    }

    if ($removed -le 0) {
        return [pscustomobject]@{ Path = $path; Removed = 0; Remaining = @($data.entries).Count; DeletedFile = $false }
    }

    if ($kept.Count -eq 0) {
        Remove-Item -LiteralPath $path -Force
        return [pscustomobject]@{ Path = $path; Removed = $removed; Remaining = 0; DeletedFile = $true }
    }

    $data.entries = $kept
    $json = $data | ConvertTo-Json -Depth 8
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $json, $utf8NoBom)

    return [pscustomobject]@{ Path = $path; Removed = $removed; Remaining = $kept.Count; DeletedFile = $false }
}

function Test-LlamaCppBestConfigStale {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [ValidateSet('native','turboquant')][string]$Mode = 'native'
    )

    $reasons = @()

    $savedGpus = @($Entry.gpu_names | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $currentGpus = @(Get-LlamaCppGpuNames)
    if ($savedGpus.Count -gt 0 -and $currentGpus.Count -gt 0) {
        if (($savedGpus -join '|') -ne ($currentGpus -join '|')) {
            $reasons += "GPU changed: saved='$($savedGpus -join ', ')' current='$($currentGpus -join ', ')'"
        }
    }

    $savedBuild = [string]$Entry.llamacpp_build
    $currentBuild = Get-LlamaCppBuildStamp -Mode $Mode
    if (-not [string]::IsNullOrWhiteSpace($savedBuild) -and -not [string]::IsNullOrWhiteSpace($currentBuild) -and $savedBuild -ne $currentBuild) {
        $reasons += "llama.cpp build changed"
    }

    return @($reasons)
}

function Save-BestLlamaCppConfig {
    # Public alias around Save-LlamaCppBestConfig with the same signature.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$Quant,
        [Parameter(Mandatory = $true)][int]$VramGB,
        [ValidateSet('short','long')][string]$PromptLength = 'short',
        [Parameter(Mandatory = $true)][string[]]$BestArgs,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$BestOverrides,
        [Parameter(Mandatory = $true)][double]$Score,
        [string]$ScoreUnit = 'tg_tps_median',
        [int]$TrialCount = 0
    )
    return Save-LlamaCppBestConfig @PSBoundParameters
}

function Find-BestLlamaCppConfigLegacy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [ValidateSet('native','turboquant')][string]$Mode = 'native',
        [string[]]$AllowedKvTypes,
        [int]$Budget = 30,
        [ValidateSet('gen','prompt','both')][string]$Optimize = 'gen',
        [int]$Runs = 1,
        [switch]$Quick,
        [switch]$Deep,
        [switch]$Aggressive,
        [switch]$AggressiveKv,
        [switch]$AllowKvQualityRegression,
        [ValidateSet('short','long')][string[]]$PromptLengths = @('short'),
        [switch]$NoSave
    )

    if ($Quick -and $Deep) {
        throw "-Quick and -Deep are mutually exclusive. Use -Quick for a bounded coarse pass, or -Deep for the wider refinement pass."
    }
    if ($Deep -and -not $PSBoundParameters.ContainsKey('Budget')) {
        $Budget = 60
        $PSBoundParameters['Budget'] = $Budget
    }

    if ($PromptLengths.Count -gt 1) {
        $results = @()
        foreach ($profile in $PromptLengths) {
            $childParams = @{}
            foreach ($k in $PSBoundParameters.Keys) { $childParams[$k] = $PSBoundParameters[$k] }
            $childParams['PromptLengths'] = @($profile)
            $results += (Find-BestLlamaCppConfigLegacy @childParams)
        }
        return @($results)
    }

    $promptProfile = if ($PromptLengths -and $PromptLengths.Count -gt 0) { [string]$PromptLengths[0] } else { 'short' }
    Set-LlamaCppTunerPromptProfile -Profile $promptProfile

    $def = Get-ModelDef -Key $Key
    if ($def.SourceType -ne 'gguf') {
        throw "Tuner only supports SourceType=gguf models. '$Key' is $($def.SourceType)."
    }

    # Multi-GPU bail (v1 = single-GPU).
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        $gpuLines = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
        $gpuCount = @($gpuLines | Where-Object { $_.Trim() -match '^\d+' }).Count
        if ($gpuCount -gt 1) {
            throw "Multi-GPU tuner not supported in v1 ($gpuCount GPUs detected). Force single-GPU via CUDA_VISIBLE_DEVICES."
        }
    }

    # Resolve KV cache types. AllowedKvTypes defaults to the user's current type.
    $kv = Get-LlamaCppKvTypes -Def $def
    if (-not $AllowedKvTypes -or $AllowedKvTypes.Count -eq 0) {
        $AllowedKvTypes = @($kv.K)
    }
    foreach ($t in $AllowedKvTypes) {
        Test-LlamaCppKvType -Type $t -Mode $Mode
    }

    # Stop competing GPU processes before we start measuring.
    Stop-OllamaModels
    Stop-OllamaApp
    Stop-LlamaServer -Quiet
    $script:LlamaCppTrialDriverByPhase = @{}

    # Resolve GGUF path once (downloads on demand). Used for every trial.
    $ggufPath = Get-ModelGgufPath -Key $Key -Def $def -Backend llamacpp

    $benchAvailable = $false
    if ($Mode -eq 'native') {
        try { $benchPath = Ensure-LlamaBenchExe -NonInteractive } catch { $benchPath = $null }
        $benchAvailable = -not [string]::IsNullOrWhiteSpace($benchPath)
    }
    $script:LlamaCppCoarseMode = if ($benchAvailable) { 'bench' } else { 'server' }

    $space = Resolve-LlamaCppTunerSearchSpace -Def $def
    $vramGB = Get-LocalLLMVRAMGB
    $quant = if ($def.Contains('Quant')) { [string]$def.Quant } else { '' }

    $history = New-Object System.Collections.Generic.List[hashtable]
    $trialIndex = 0
    $best = $null  # @{ overrides; trial; score }

    $startedAt = Get-Date
    Write-Host ""
    Write-Host "=== llama.cpp tuner: $Key  (ctx=$ContextKey, mode=$Mode, quant=$quant, vram=${vramGB}GB, prompt=$promptProfile) ===" -ForegroundColor Cyan
    Write-Host "  budget=$Budget  optimize=$Optimize  runs/trial=$Runs  isMoE=$($space.IsMoE)  coarse=$script:LlamaCppCoarseMode" -ForegroundColor DarkGray
    if ($space.SkipPhases.Count -gt 0) {
        Write-Host "  catalog skip-phases: $($space.SkipPhases -join ', ')" -ForegroundColor DarkGray
    }
    Write-Host ""

    function Should-RunPhase($name) {
        if ($name -in $space.SkipPhases) { return $false }
        if ($Quick -and $name -notin @('baseline','moe_or_ngl','batching')) { return $false }
        return $true
    }

    function Get-PhaseDriver($name) {
        if (-not $benchAvailable) { return 'server' }
        if ($name -in @('moe','ngl','batching','flash','mmap','threads')) { return 'bench' }
        return 'server'
    }

    # ----- Phase 1: baseline -----
    $baselineOverrides = [ordered]@{
        KvK = $kv.K
        KvV = $kv.V
    }

    $trialIndex++
    $baselineTrial = Invoke-LlamaCppTunerTrial `
        -Key $Key -Def $def -ContextKey $ContextKey -Mode $Mode -ModelArgPath $ggufPath `
        -Overrides $baselineOverrides -Phase 'baseline' -Index $trialIndex -Runs $Runs -Driver server -Optimize $Optimize
    $history.Add($baselineTrial) | Out-Null

    if (-not $baselineTrial.startup_ok -or $baselineTrial.oom) {
        # If catalog defaults already OOM, the only path forward is to push more
        # onto CPU (MoE) before bailing. Otherwise the model literally won't run
        # at this quality on this box.
        if (-not $space.IsMoE) {
            throw "Baseline trial failed and model is not MoE — cannot recover. Check $($baselineTrial.log_path) for details."
        }
        Write-Host "  baseline OOM — phase 2 will push more experts to CPU." -ForegroundColor Yellow
    } else {
        $best = @{ overrides = $baselineOverrides; trial = $baselineTrial; score = [double]$baselineTrial.score }
    }

    # ----- Phase 2: VRAM-fit calibration (MoE: sweep n-cpu-moe; dense: sweep -ngl) -----
    if ($trialIndex -lt $Budget -and (Should-RunPhase 'moe_or_ngl')) {
        if ($space.IsMoE) {
            # Build candidate ladder. For MoE we want the SMALLEST --n-cpu-moe
            # that fits (more layers on GPU = faster). Sweep down from baseline,
            # then up to the cap if baseline OOMed.
            $baseN = [int]$space.BaselineNCpuMoe
            $candidatesDown = @()
            for ($n = [Math]::Max(0, $baseN - 5); $n -ge 0; $n -= 5) { $candidatesDown += $n }
            $candidatesUp   = @()
            for ($n = $baseN + 5; $n -le $space.MoeUpper; $n += 5) { $candidatesUp += $n }

            $direction = if ($baselineTrial.oom -or -not $baselineTrial.startup_ok) { 'up' } else { 'down' }
            $ladder = if ($direction -eq 'up') { $candidatesUp } else { $candidatesDown }

            foreach ($n in $ladder) {
                if ($trialIndex -ge $Budget) { break }

                $cand = [ordered]@{
                    KvK     = $kv.K
                    KvV     = $kv.V
                    NCpuMoe = $n
                }

                if (Test-LlamaCppMonotonicityOom -Candidate $cand -History $history) {
                    Write-Host "  -- skip NCpuMoe=$n (pruned by OOM monotonicity)" -ForegroundColor DarkGray
                    continue
                }

                $trialIndex++
                $t = Invoke-LlamaCppTunerTrial `
                    -Key $Key -Def $def -ContextKey $ContextKey -Mode $Mode -ModelArgPath $ggufPath `
                    -Overrides $cand -Phase 'moe' -Index $trialIndex -Runs $Runs -Driver (Get-PhaseDriver 'moe') -Optimize $Optimize
                $history.Add($t) | Out-Null

                if ($t.startup_ok -and -not $t.oom) {
                    if (-not $best -or $t.score -gt $best.score) {
                        $best = @{ overrides = $cand; trial = $t; score = [double]$t.score }
                    }
                } elseif ($direction -eq 'down') {
                    # Stepping further down increases VRAM use → guaranteed OOM. Stop.
                    Write-Host "  -- stop down-sweep at NCpuMoe=$n (OOM)." -ForegroundColor DarkGray
                    break
                }
            }
        } else {
            # Dense path. Only meaningful when baseline OOMed; otherwise -ngl is
            # already at 999 and there's nothing useful to try above.
            if ($baselineTrial.oom -or -not $baselineTrial.startup_ok) {
                $baseNgl = [int]$space.BaselineNgl
                if ($baseNgl -le 0) { $baseNgl = 999 }
                # Bisect: try halving the layers until it fits.
                $candidates = @()
                $cur = [int][Math]::Floor($baseNgl / 2)
                while ($cur -gt 0 -and $candidates.Count -lt 6) { $candidates += $cur; $cur = [int][Math]::Floor($cur / 2) }

                foreach ($ngl in $candidates) {
                    if ($trialIndex -ge $Budget) { break }
                    $cand = [ordered]@{ KvK = $kv.K; KvV = $kv.V; NGpuLayers = $ngl }
                    if (Test-LlamaCppMonotonicityOom -Candidate $cand -History $history) {
                        Write-Host "  -- skip NGpuLayers=$ngl (pruned by OOM monotonicity)" -ForegroundColor DarkGray
                        continue
                    }
                    $trialIndex++
                    $t = Invoke-LlamaCppTunerTrial `
                        -Key $Key -Def $def -ContextKey $ContextKey -Mode $Mode -ModelArgPath $ggufPath `
                        -Overrides $cand -Phase 'ngl' -Index $trialIndex -Runs $Runs -Driver (Get-PhaseDriver 'ngl') -Optimize $Optimize
                    $history.Add($t) | Out-Null
                    if ($t.startup_ok -and -not $t.oom) {
                        if (-not $best -or $t.score -gt $best.score) {
                            $best = @{ overrides = $cand; trial = $t; score = [double]$t.score }
                        }
                        # First fit found; further reductions cost throughput.
                        break
                    }
                }
            }
        }
    }

    if (-not $best) {
        throw "Tuner found no surviving config after $trialIndex trials. Inspect $((Get-LlamaCppTunerHistoryFile -Key $Key)) for details."
    }

    # ----- Phase 3: batching (ub, b) joint sweep -----
    if ($trialIndex -lt $Budget -and (Should-RunPhase 'batching')) {
        $pairs = @()
        foreach ($ub in $space.UbatchCandidates) {
            foreach ($b in $space.BatchCandidates) {
                if ($b -lt $ub) { continue }
                $pairs += @{ Ub = $ub; B = $b }
            }
        }

        foreach ($pair in $pairs) {
            if ($trialIndex -ge $Budget) { break }

            $cand = [ordered]@{}
            foreach ($k in $best.overrides.Keys) { $cand[$k] = $best.overrides[$k] }
            $cand.UbatchSize = [int]$pair.Ub
            $cand.BatchSize  = [int]$pair.B

            if (Test-LlamaCppMonotonicityOom -Candidate $cand -History $history) {
                Write-Host "  -- skip ub=$($pair.Ub) b=$($pair.B) (pruned)" -ForegroundColor DarkGray
                continue
            }

            $trialIndex++
            $t = Invoke-LlamaCppTunerTrial `
                -Key $Key -Def $def -ContextKey $ContextKey -Mode $Mode -ModelArgPath $ggufPath `
                -Overrides $cand -Phase 'batching' -Index $trialIndex -Runs $Runs -Driver (Get-PhaseDriver 'batching') -Optimize $Optimize
            $history.Add($t) | Out-Null

            if ($t.startup_ok -and -not $t.oom -and $t.score -gt $best.score) {
                $best = @{ overrides = $cand; trial = $t; score = [double]$t.score }
            }
        }
    }

    # ----- Phase 4: flash-attn on/off -----
    if ($trialIndex -lt $Budget -and (Should-RunPhase 'flash')) {
        foreach ($flashValue in @($true, $false)) {
            if ($trialIndex -ge $Budget) { break }

            $cand = Join-LlamaCppOverrides -Base $best.overrides -Overlay @{ FlashAttn = $flashValue }
            if (Test-LlamaCppMonotonicityOom -Candidate $cand -History $history) {
                Write-Host "  -- skip flash=$flashValue (pruned)" -ForegroundColor DarkGray
                continue
            }

            $trialIndex++
            $t = Invoke-LlamaCppTunerTrial `
                -Key $Key -Def $def -ContextKey $ContextKey -Mode $Mode -ModelArgPath $ggufPath `
                -Overrides $cand -Phase 'flash' -Index $trialIndex -Runs $Runs -Driver (Get-PhaseDriver 'flash') -Optimize $Optimize
            $history.Add($t) | Out-Null

            if ($t.startup_ok -and -not $t.oom -and $t.score -gt $best.score) {
                $best = @{ overrides = $cand; trial = $t; score = [double]$t.score }
            }
        }
    }

    # ----- Phase 5: mlock / no-mmap -----
    if ($trialIndex -lt $Budget -and (Should-RunPhase 'mmap')) {
        $combos = @(
            @{ Mlock = $true;  NoMmap = $true  },
            @{ Mlock = $false; NoMmap = $false }
        )
        if ($Aggressive) {
            $combos += @(
                @{ Mlock = $true;  NoMmap = $false },
                @{ Mlock = $false; NoMmap = $true  }
            )
        }

        foreach ($combo in $combos) {
            if ($trialIndex -ge $Budget) { break }

            $cand = Join-LlamaCppOverrides -Base $best.overrides -Overlay $combo
            if (Test-LlamaCppMonotonicityOom -Candidate $cand -History $history) {
                Write-Host "  -- skip mlock=$($combo.Mlock) no-mmap=$($combo.NoMmap) (pruned)" -ForegroundColor DarkGray
                continue
            }

            $trialIndex++
            $t = Invoke-LlamaCppTunerTrial `
                -Key $Key -Def $def -ContextKey $ContextKey -Mode $Mode -ModelArgPath $ggufPath `
                -Overrides $cand -Phase 'mmap' -Index $trialIndex -Runs $Runs -Driver (Get-PhaseDriver 'mmap') -Optimize $Optimize
            $history.Add($t) | Out-Null

            if ($t.startup_ok -and -not $t.oom -and $t.score -gt $best.score) {
                $best = @{ overrides = $cand; trial = $t; score = [double]$t.score }
            }
        }
    }

    # ----- Phase 6: threads (CPU-offload models only) -----
    if ($trialIndex -lt $Budget -and (Should-RunPhase 'threads')) {
        $currentNCpuMoe = if ($best.overrides.Contains('NCpuMoe')) { [int]$best.overrides.NCpuMoe } elseif ($space.IsMoE) { [int]$space.BaselineNCpuMoe } else { 0 }
        $currentNgl = if ($best.overrides.Contains('NGpuLayers')) { [int]$best.overrides.NGpuLayers } else { [int]$space.BaselineNgl }
        if ($currentNgl -le 0) { $currentNgl = 999 }
        $shouldTuneThreads = ($currentNCpuMoe -gt 0) -or ((-not $space.IsMoE) -and $currentNgl -lt 999)

        if ($shouldTuneThreads) {
            try {
                $logicalCores = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
            }
            catch {
                $logicalCores = [Environment]::ProcessorCount
            }

            $threadCandidates = @(
                [int][Math]::Max(1, [Math]::Floor($logicalCores / 2)),
                [int][Math]::Max(1, [Math]::Floor($logicalCores * 3 / 4)),
                [int][Math]::Max(1, $logicalCores)
            ) | Select-Object -Unique

            $remaining = [Math]::Max(0, $Budget - $trialIndex)
            if ($threadCandidates.Count -gt $remaining -and $threadCandidates.Count -eq 3) {
                $threadCandidates = @($threadCandidates[0], $threadCandidates[2])
            }

            foreach ($threads in $threadCandidates) {
                if ($trialIndex -ge $Budget) { break }

                $cand = Join-LlamaCppOverrides -Base $best.overrides -Overlay @{ Threads = $threads; ThreadsBatch = $threads }
                if (Test-LlamaCppMonotonicityOom -Candidate $cand -History $history) {
                    Write-Host "  -- skip threads=$threads (pruned)" -ForegroundColor DarkGray
                    continue
                }

                $trialIndex++
                $t = Invoke-LlamaCppTunerTrial `
                    -Key $Key -Def $def -ContextKey $ContextKey -Mode $Mode -ModelArgPath $ggufPath `
                    -Overrides $cand -Phase 'threads' -Index $trialIndex -Runs $Runs -Driver (Get-PhaseDriver 'threads') -Optimize $Optimize
                $history.Add($t) | Out-Null

                if ($t.startup_ok -and -not $t.oom -and $t.score -gt $best.score) {
                    $best = @{ overrides = $cand; trial = $t; score = [double]$t.score }
                }
            }
        } else {
            Write-Host "  -- skip threads (no CPU offload in winning config)" -ForegroundColor DarkGray
        }
    }

    # ----- Phase 7: KV cache types -----
    if ($trialIndex -lt $Budget -and (Should-RunPhase 'kv') -and $AllowedKvTypes.Count -gt 1) {
        $preKvBest = $best
        $kvPairs = @()
        foreach ($t in $AllowedKvTypes) {
            Test-LlamaCppKvType -Type $t -Mode $Mode
            $kvPairs += @{ K = $t; V = $t }
        }
        if (-not $AggressiveKv) {
            $turbo3 = @($AllowedKvTypes | Where-Object { ([string]$_).ToLowerInvariant() -eq 'turbo3' } | Select-Object -First 1)
            $turbo4 = @($AllowedKvTypes | Where-Object { ([string]$_).ToLowerInvariant() -eq 'turbo4' } | Select-Object -First 1)
            if ($turbo3.Count -gt 0 -and $turbo4.Count -gt 0) {
                # turbo3/turbo4 are non-linear cache encodings; K/V asymmetry can matter.
                $kvPairs += @{ K = [string]$turbo3[0]; V = [string]$turbo4[0] }
                $kvPairs += @{ K = [string]$turbo4[0]; V = [string]$turbo3[0] }
            }
        } else {
            foreach ($kType in $AllowedKvTypes) {
                foreach ($vType in $AllowedKvTypes) {
                    if ($kType -eq $vType) { continue }
                    Test-LlamaCppKvType -Type $kType -Mode $Mode
                    Test-LlamaCppKvType -Type $vType -Mode $Mode
                    $kvPairs += @{ K = $kType; V = $vType }
                }
            }
        }

        foreach ($pair in $kvPairs) {
            if ($trialIndex -ge $Budget) { break }

            $cand = Join-LlamaCppOverrides -Base $best.overrides -Overlay @{ KvK = $pair.K; KvV = $pair.V }
            if (Test-LlamaCppMonotonicityOom -Candidate $cand -History $history) {
                Write-Host "  -- skip kv K=$($pair.K) V=$($pair.V) (pruned)" -ForegroundColor DarkGray
                continue
            }

            $trialIndex++
            $t = Invoke-LlamaCppTunerTrial `
                -Key $Key -Def $def -ContextKey $ContextKey -Mode $Mode -ModelArgPath $ggufPath `
                -Overrides $cand -Phase 'kv' -Index $trialIndex -Runs $Runs -Driver server -Optimize $Optimize
            $history.Add($t) | Out-Null

            if ($t.startup_ok -and -not $t.oom -and $t.score -gt $best.score) {
                $best = @{ overrides = $cand; trial = $t; score = [double]$t.score }
            }
        }

        $bestKvK = if ($best.overrides.Contains('KvK')) { [string]$best.overrides.KvK } else { [string]$kv.K }
        $bestKvV = if ($best.overrides.Contains('KvV')) { [string]$best.overrides.KvV } else { [string]$kv.V }
        $kvChanged = ($bestKvK -ne [string]$kv.K) -or ($bestKvV -ne [string]$kv.V)
        if ($kvChanged -and -not $AllowKvQualityRegression) {
            Write-Host "  -- checking KV quality with llama-perplexity..." -ForegroundColor DarkGray
            $baselineKv = Join-LlamaCppOverrides -Base $best.overrides -Overlay @{ KvK = $kv.K; KvV = $kv.V }
            $baselinePpl = Invoke-LlamaCppPerplexity -Def $def -ContextKey $ContextKey -Mode $Mode -ModelArgPath $ggufPath -Overrides $baselineKv
            $candidatePpl = Invoke-LlamaCppPerplexity -Def $def -ContextKey $ContextKey -Mode $Mode -ModelArgPath $ggufPath -Overrides $best.overrides

            if ($null -ne $baselinePpl -and $null -ne $candidatePpl -and $baselinePpl -gt 0) {
                $delta = ([double]$candidatePpl - [double]$baselinePpl) / [double]$baselinePpl
                Write-Host ("  -- KV perplexity baseline={0:N4} candidate={1:N4} delta={2:P2}" -f $baselinePpl, $candidatePpl, $delta) -ForegroundColor DarkGray
                if ($delta -gt 0.01) {
                    Write-Warning ("KV cache variation increased perplexity by {0:P2}; keeping baseline KV pair. Re-run with -AllowKvQualityRegression to accept the faster KV setting." -f $delta)
                    $best = $preKvBest
                }
            } else {
                Write-Warning "KV quality check unavailable; llama-perplexity did not return comparable perplexity values."
            }
        }
    }

    # ----- Phase 8: deep local refinement -----
    if ($Deep -and $trialIndex -lt $Budget) {
        Write-Host "  -- deep pass: refining offload, batch, flash, and CPU threads" -ForegroundColor DarkGray

        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        function Add-SeenOverride($ov) {
            if (-not $ov) { return }
            $parts = @()
            foreach ($k in @('KvK','KvV','NGpuLayers','NCpuMoe','UbatchSize','BatchSize','Threads','ThreadsBatch','Mlock','NoMmap','FlashAttn')) {
                if ($ov.Contains($k) -and $null -ne $ov[$k]) { $parts += "$k=$($ov[$k])" }
            }
            [void]$seen.Add(($parts -join ';'))
        }
        foreach ($h in $history) { Add-SeenOverride $h.overrides }

        function Invoke-DeepCandidate($cand, [string]$phaseName, [string]$driverName) {
            if ($trialIndex -ge $Budget) { return }
            $parts = @()
            foreach ($k in @('KvK','KvV','NGpuLayers','NCpuMoe','UbatchSize','BatchSize','Threads','ThreadsBatch','Mlock','NoMmap','FlashAttn')) {
                if ($cand.Contains($k) -and $null -ne $cand[$k]) { $parts += "$k=$($cand[$k])" }
            }
            $sig = $parts -join ';'
            if ($seen.Contains($sig)) { return }
            [void]$seen.Add($sig)

            if (Test-LlamaCppMonotonicityOom -Candidate $cand -History $history) {
                Write-Host "  -- skip $phaseName $(Format-LlamaCppOverrides -Overrides $cand) (pruned)" -ForegroundColor DarkGray
                return
            }

            $nextIndex = $trialIndex + 1
            $t = Invoke-LlamaCppTunerTrial `
                -Key $Key -Def $def -ContextKey $ContextKey -Mode $Mode -ModelArgPath $ggufPath `
                -Overrides $cand -Phase $phaseName -Index $nextIndex -Runs $Runs -Driver $driverName -Optimize $Optimize
            Set-Variable -Name trialIndex -Value $nextIndex -Scope 1
            $history.Add($t) | Out-Null

            if ($t.startup_ok -and -not $t.oom -and $t.score -gt $best.score) {
                Set-Variable -Name best -Value @{ overrides = $cand; trial = $t; score = [double]$t.score } -Scope 1
            }
        }

        if ($trialIndex -lt $Budget) {
            if ($space.IsMoE) {
                $current = if ($best.overrides.Contains('NCpuMoe')) { [int]$best.overrides.NCpuMoe } else { [int]$space.BaselineNCpuMoe }
                $moeCandidates = foreach ($delta in @(-1, 1, -2, 2, -3, 3, -4, 4, -5, 5)) {
                    $n = $current + $delta
                    if ($n -ge 0 -and $n -le [int]$space.MoeUpper) { $n }
                }
                foreach ($n in @($moeCandidates | Select-Object -Unique)) {
                    if ($trialIndex -ge $Budget) { break }
                    $cand = Join-LlamaCppOverrides -Base $best.overrides -Overlay @{ NCpuMoe = $n }
                    Invoke-DeepCandidate $cand 'deep_moe' (Get-PhaseDriver 'moe')
                }
            } else {
                $current = if ($best.overrides.Contains('NGpuLayers')) { [int]$best.overrides.NGpuLayers } else { [int]$space.BaselineNgl }
                if ($current -le 0) { $current = 999 }
                if ($current -lt 999) {
                    $nglCandidates = foreach ($delta in @(64, 32, 16, 8, 4, -4, -8, -16, -32)) {
                        $n = $current + $delta
                        if ($n -gt 0 -and $n -le 999) { $n }
                    }
                    foreach ($ngl in @($nglCandidates | Select-Object -Unique)) {
                        if ($trialIndex -ge $Budget) { break }
                        $cand = Join-LlamaCppOverrides -Base $best.overrides -Overlay @{ NGpuLayers = $ngl }
                        Invoke-DeepCandidate $cand 'deep_ngl' (Get-PhaseDriver 'ngl')
                    }
                }
            }
        }

        if ($trialIndex -lt $Budget) {
            $currentUb = if ($best.overrides.Contains('UbatchSize') -and $best.overrides.UbatchSize) { [int]$best.overrides.UbatchSize } else { 512 }
            $currentB  = if ($best.overrides.Contains('BatchSize')  -and $best.overrides.BatchSize)  { [int]$best.overrides.BatchSize }  else { 1024 }
            $ubCandidates = @(
                128, 256, 512, 1024, 2048,
                [int]($currentUb / 2), [int]($currentUb + 256), [int]($currentUb * 2)
            ) | Where-Object { $_ -ge 64 -and $_ -le 2048 } | Select-Object -Unique
            $bCandidates = @(
                512, 1024, 2048, 4096,
                [int]($currentB / 2), [int]($currentB + 512), [int]($currentB * 2)
            ) | Where-Object { $_ -ge 128 -and $_ -le 4096 } | Select-Object -Unique

            $pairs = foreach ($ub in $ubCandidates) {
                foreach ($b in $bCandidates) {
                    if ($b -ge $ub) {
                        [pscustomobject]@{
                            Ub   = [int]$ub
                            B    = [int]$b
                            Cost = [Math]::Abs([int]$ub - $currentUb) + [Math]::Abs([int]$b - $currentB)
                        }
                    }
                }
            }
            foreach ($pair in @($pairs | Sort-Object Cost, Ub, B)) {
                if ($trialIndex -ge $Budget) { break }
                $cand = Join-LlamaCppOverrides -Base $best.overrides -Overlay @{
                    UbatchSize = [int]$pair.Ub
                    BatchSize  = [int]$pair.B
                }
                Invoke-DeepCandidate $cand 'deep_batching' (Get-PhaseDriver 'batching')
            }
        }

        if ($trialIndex -lt $Budget) {
            foreach ($flashValue in @($true, $false)) {
                if ($trialIndex -ge $Budget) { break }
                $cand = Join-LlamaCppOverrides -Base $best.overrides -Overlay @{ FlashAttn = $flashValue }
                Invoke-DeepCandidate $cand 'deep_flash' (Get-PhaseDriver 'flash')
            }
        }

        if ($trialIndex -lt $Budget) {
            $currentNCpuMoe = if ($best.overrides.Contains('NCpuMoe')) { [int]$best.overrides.NCpuMoe } elseif ($space.IsMoE) { [int]$space.BaselineNCpuMoe } else { 0 }
            $currentNgl = if ($best.overrides.Contains('NGpuLayers')) { [int]$best.overrides.NGpuLayers } else { [int]$space.BaselineNgl }
            if ($currentNgl -le 0) { $currentNgl = 999 }
            $shouldTuneThreads = ($currentNCpuMoe -gt 0) -or ((-not $space.IsMoE) -and $currentNgl -lt 999)
            if ($shouldTuneThreads) {
                try { $logicalCores = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors }
                catch { $logicalCores = [Environment]::ProcessorCount }
                $threadCandidates = @(
                    1,
                    [int][Math]::Max(1, [Math]::Floor($logicalCores / 4)),
                    [int][Math]::Max(1, [Math]::Floor($logicalCores / 2)),
                    [int][Math]::Max(1, [Math]::Floor($logicalCores * 3 / 4)),
                    [int]$logicalCores
                ) | Select-Object -Unique
                foreach ($threads in $threadCandidates) {
                    if ($trialIndex -ge $Budget) { break }
                    $cand = Join-LlamaCppOverrides -Base $best.overrides -Overlay @{
                        Threads      = [int]$threads
                        ThreadsBatch = [int]$threads
                    }
                    Invoke-DeepCandidate $cand 'deep_threads' (Get-PhaseDriver 'threads')
                }
            }
        }
    }

    # ----- Phase 9: final verification -----
    if ($script:LlamaCppCoarseMode -ne 'server') {
        $trialIndex++
        $verified = Invoke-LlamaCppTunerTrial `
            -Key $Key -Def $def -ContextKey $ContextKey -Mode $Mode -ModelArgPath $ggufPath `
            -Overrides $best.overrides -Phase 'verify' -Index $trialIndex -Runs $Runs -Driver server -Optimize $Optimize

        if ($verified.startup_ok -and -not $verified.oom) {
            $verifiedScore = [double]$verified.score
            if ($best.score -gt 0 -and $verifiedScore -lt (0.9 * [double]$best.score)) {
                $pct = [math]::Round(100.0 * $verifiedScore / [double]$best.score, 1)
                Write-Warning "Verification regressed ($pct%) vs coarse sweep - recording verified score."
            }
            $best.trial = $verified
            $best.score = $verifiedScore
        } else {
            Write-Warning "Final verification failed; keeping coarse winner but review $($verified.log_path)."
        }
    }

    $elapsed = (Get-Date) - $startedAt

    Write-Host ""
    Write-Host "=== Best ===" -ForegroundColor Green
    Write-Host ("  score      : {0:N2}  ({1})" -f $best.score, ("${Optimize}_tps_median")) -ForegroundColor Green
    Write-Host ("  pp / tg    : {0:N2} / {1:N2} tok/s" -f $best.trial.pp_tps, $best.trial.tg_tps) -ForegroundColor DarkGray
    Write-Host ("  overrides  : {0}" -f (Format-LlamaCppOverrides -Overrides $best.overrides)) -ForegroundColor DarkGray
    Write-Host ("  argv       : {0}" -f ($best.trial.args -join ' ')) -ForegroundColor DarkGray
    Write-Host ("  trials     : {0}  elapsed: {1:N0}s" -f $trialIndex, $elapsed.TotalSeconds) -ForegroundColor DarkGray
    Write-Host ""

    if (-not $NoSave) {
        $savedPath = Save-LlamaCppBestConfig `
            -Key $Key -ContextKey $ContextKey -Mode $Mode -Quant $quant -VramGB $vramGB `
            -PromptLength $promptProfile `
            -BestArgs $best.trial.args -BestOverrides $best.overrides `
            -Score $best.score -ScoreUnit "${Optimize}_tps_median" -TrialCount $trialIndex
        Write-Host "Saved best -> $savedPath" -ForegroundColor DarkGray
    }

    return @{
        Score        = $best.score
        ScoreUnit    = "${Optimize}_tps_median"
        Overrides    = $best.overrides
        Args         = @($best.trial.args)
        Trial        = $best.trial
        TrialCount   = $trialIndex
        ElapsedSec   = [int]$elapsed.TotalSeconds
        VramGB       = $vramGB
        ContextKey   = $ContextKey
        Mode         = $Mode
        Quant        = $quant
        PromptLength = $promptProfile
    }
}

function Find-BestLlamaCppConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [ValidateSet('native','turboquant')][string]$Mode = 'native',
        [string[]]$AllowedKvTypes,
        [int]$Budget = 30,
        [ValidateSet('gen','prompt','both')][string]$Optimize = 'gen',
        [int]$Runs = 1,
        [switch]$Quick,
        [switch]$Deep,
        [switch]$Aggressive,
        [switch]$AggressiveKv,
        [switch]$AllowKvQualityRegression,
        [ValidateSet('short','long')][string[]]$PromptLengths = @('short'),
        [switch]$NoSave
    )

    $preferBenchPilot = $true
    if ($script:Cfg -and $script:Cfg.ContainsKey('BenchPilotPreferExternal')) {
        $preferBenchPilot = [bool]$script:Cfg.BenchPilotPreferExternal
    }

    $allowLegacyFallback = $true
    if ($script:Cfg -and $script:Cfg.ContainsKey('BenchPilotAllowLegacyFallback')) {
        $allowLegacyFallback = [bool]$script:Cfg.BenchPilotAllowLegacyFallback
    }

    if ($preferBenchPilot -and (Get-Command Test-BenchPilotIntegrationAvailable -ErrorAction SilentlyContinue)) {
        $bpStatus = Test-BenchPilotIntegrationAvailable -Quiet
        if ($bpStatus.Available) {
            try {
                Write-Host "findbest: using BenchPilot ($($bpStatus.Version), $($bpStatus.Source))." -ForegroundColor Cyan
                return Invoke-BenchPilotLauncherFindBest @PSBoundParameters
            }
            catch {
                $trialsStarted = $false
                if ($_.Exception -and $_.Exception.Data -and $_.Exception.Data.Contains('BenchPilotTrialsStarted')) {
                    try { $trialsStarted = [bool]$_.Exception.Data['BenchPilotTrialsStarted'] } catch { $trialsStarted = $false }
                }

                if ($trialsStarted -or -not $allowLegacyFallback) {
                    throw
                }

                Write-Warning "BenchPilot findbest failed before trials started: $($_.Exception.Message)"
                Write-Warning "Falling back to the legacy launcher tuner."
            }
        }
        elseif (-not $allowLegacyFallback) {
            throw "BenchPilot is not available and BenchPilotAllowLegacyFallback is false. Reason: $($bpStatus.Reason)"
        }
    }
    elseif (-not $allowLegacyFallback) {
        throw "BenchPilot integration is disabled or unavailable and BenchPilotAllowLegacyFallback is false."
    }

    return Find-BestLlamaCppConfigLegacy @PSBoundParameters
}

function Read-LlamaCppTunerHistoryEntries {
    param([Parameter(Mandatory = $true)][string]$Key)

    $path = Get-LlamaCppTunerHistoryFile -Key $Key
    if (-not (Test-Path $path)) { return @() }

    $lines = Get-Content -Path $path -Encoding UTF8
    $entries = foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { ConvertFrom-Json $line } catch { continue }
    }
    return @($entries)
}

function Show-LlamaCppTunerHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [int]$Last = 50
    )

    $entries = @(Read-LlamaCppTunerHistoryEntries -Key $Key)

    if ($entries.Count -eq 0) {
        Write-Host "No tuner history for $Key. Run 'findbest $Key -ContextKey ...' first." -ForegroundColor DarkGray
        return
    }

    $entries = @($entries | Select-Object -Last $Last)

    $entries | ForEach-Object {
        $ov = if ($_.overrides) { ($_.overrides.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' ' } else { '' }
        [pscustomobject]@{
            ts       = $_.ts
            phase    = $_.phase
            oom      = [bool]$_.oom
            startup  = [bool]$_.startup_ok
            pp_tps   = $_.pp_tps
            tg_tps   = $_.tg_tps
            score    = $_.score
            override = $ov
        }
    } | Format-Table -AutoSize
}

function findbest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [ValidateSet('native','turboquant')][string]$Mode = 'native',
        [string[]]$AllowedKvTypes,
        [int]$Budget = 30,
        [ValidateSet('gen','prompt','both')][string]$Optimize = 'gen',
        [int]$Runs = 1,
        [switch]$Quick,
        [switch]$Deep,
        [switch]$Aggressive,
        [switch]$AggressiveKv,
        [switch]$AllowKvQualityRegression,
        [ValidateSet('short','long')][string[]]$PromptLengths = @('short'),
        [switch]$NoSave
    )
    Find-BestLlamaCppConfig @PSBoundParameters
}

function tunellm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [ValidateSet('native','turboquant')][string]$Mode = 'native',
        [string[]]$AllowedKvTypes,
        [int]$Budget = 30,
        [ValidateSet('gen','prompt','both')][string]$Optimize = 'gen',
        [int]$Runs = 1,
        [switch]$Quick,
        [switch]$Deep,
        [switch]$Aggressive,
        [switch]$AggressiveKv,
        [switch]$AllowKvQualityRegression,
        [ValidateSet('short','long')][string[]]$PromptLengths = @('short'),
        [switch]$NoSave
    )
    Find-BestLlamaCppConfig @PSBoundParameters
}
