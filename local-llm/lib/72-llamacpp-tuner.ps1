# Per-machine llama.cpp auto-tuner. Searches the perf-only parameter space for
# the highest-throughput launch config without touching anything that could
# change generations (quant, context, KV cache types stay locked unless the
# user explicitly widens). T1 ships baseline + MoE/ngl + batching only;
# flash-attn / mlock / threads / KV phases land in T2.

$script:LlamaCppTunerVersion = 1

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

# OOM markers from llama-server stderr / stdout. Match case-insensitively.
$script:LlamaCppOomPatterns = @(
    'cuda error: out of memory',
    'cudaerror_outofmemory',
    'failed to allocate',
    'ggml_cuda_host_malloc',
    'vulkan.*out of memory',
    'cublasstatus_alloc_failed',
    'cudamalloc.*failed',
    'unable to allocate'
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

    foreach ($pat in $script:LlamaCppOomPatterns) {
        if ($lower -match $pat) { return $true }
    }

    return $false
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

    function Get-Median([double[]]$arr) {
        if (-not $arr -or $arr.Count -eq 0) { return 0.0 }
        $sorted = @($arr | Sort-Object)
        $n = $sorted.Count
        if ($n % 2 -eq 1) { return [double]$sorted[[Math]::Floor($n / 2)] }
        return ([double]$sorted[($n / 2) - 1] + [double]$sorted[$n / 2]) / 2.0
    }

    $ppMedian = Get-Median $ppValues
    $tgMedian = Get-Median $tgValues

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
        [ValidateSet('gen','prompt','both')][string]$Optimize = 'gen'
    )

    $trial = Invoke-LlamaCppTrialServer `
        -Def $Def `
        -ContextKey $ContextKey `
        -Mode $Mode `
        -ModelArgPath $ModelArgPath `
        -Overrides $Overrides `
        -Phase $Phase `
        -Runs $Runs

    $score = Get-LlamaCppTrialScore -Trial $trial -Optimize $Optimize
    $trial.score = [math]::Round([double]$score, 2)
    $trial.score_unit = "${Optimize}_tps_median"
    $trial.tuner_version = $script:LlamaCppTunerVersion

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
        $_.quant -ne $Quant -or
        $_.contextKey -ne $ContextKey -or
        $_.mode -ne $Mode -or
        [int]$_.vramGB -ne $VramGB
    })

    $newEntry = [ordered]@{
        quant         = $Quant
        contextKey    = $ContextKey
        mode          = $Mode
        vramGB        = $VramGB
        score         = [math]::Round($Score, 2)
        scoreUnit     = $ScoreUnit
        args          = @($BestArgs)
        overrides     = $BestOverrides
        measured_at   = (Get-Date).ToString('o')
        tuner_version = $script:LlamaCppTunerVersion
        trial_count   = $TrialCount
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
        if ($Quant -and $entry.quant -ne $Quant) { continue }
        $delta = [Math]::Abs([int]$entry.vramGB - [int]$VramGB)
        if ($delta -gt 1) { continue }
        if ($entry.tuner_version -and [int]$entry.tuner_version -ne $script:LlamaCppTunerVersion) { continue }
        return $entry
    }

    return $null
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
        [Parameter(Mandatory = $true)][string[]]$BestArgs,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$BestOverrides,
        [Parameter(Mandatory = $true)][double]$Score,
        [string]$ScoreUnit = 'tg_tps_median',
        [int]$TrialCount = 0
    )
    return Save-LlamaCppBestConfig @PSBoundParameters
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
        [switch]$Aggressive,
        [switch]$NoSave
    )

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

    # Resolve GGUF path once (downloads on demand). Used for every trial.
    $ggufPath = Get-ModelGgufPath -Key $Key -Def $def -Backend llamacpp

    $space = Resolve-LlamaCppTunerSearchSpace -Def $def
    $vramGB = Get-LocalLLMVRAMGB
    $quant = if ($def.Contains('Quant')) { [string]$def.Quant } else { '' }

    $history = New-Object System.Collections.Generic.List[hashtable]
    $trialIndex = 0
    $best = $null  # @{ overrides; trial; score }

    $startedAt = Get-Date
    Write-Host ""
    Write-Host "=== llama.cpp tuner: $Key  (ctx=$ContextKey, mode=$Mode, quant=$quant, vram=${vramGB}GB) ===" -ForegroundColor Cyan
    Write-Host "  budget=$Budget  optimize=$Optimize  runs/trial=$Runs  isMoE=$($space.IsMoE)" -ForegroundColor DarkGray
    if ($space.SkipPhases.Count -gt 0) {
        Write-Host "  catalog skip-phases: $($space.SkipPhases -join ', ')" -ForegroundColor DarkGray
    }
    Write-Host ""

    function Should-RunPhase($name) {
        if ($name -in $space.SkipPhases) { return $false }
        if ($Quick -and $name -notin @('baseline','moe_or_ngl','batching')) { return $false }
        return $true
    }

    # ----- Phase 1: baseline -----
    $baselineOverrides = [ordered]@{
        KvK = $kv.K
        KvV = $kv.V
    }

    $trialIndex++
    $baselineTrial = Invoke-LlamaCppTunerTrial `
        -Key $Key -Def $def -ContextKey $ContextKey -Mode $Mode -ModelArgPath $ggufPath `
        -Overrides $baselineOverrides -Phase 'baseline' -Index $trialIndex -Runs $Runs -Optimize $Optimize
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
                    -Overrides $cand -Phase 'moe' -Index $trialIndex -Runs $Runs -Optimize $Optimize
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
                        -Overrides $cand -Phase 'ngl' -Index $trialIndex -Runs $Runs -Optimize $Optimize
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
                -Overrides $cand -Phase 'batching' -Index $trialIndex -Runs $Runs -Optimize $Optimize
            $history.Add($t) | Out-Null

            if ($t.startup_ok -and -not $t.oom -and $t.score -gt $best.score) {
                $best = @{ overrides = $cand; trial = $t; score = [double]$t.score }
            }
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
    }
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
        [switch]$Aggressive,
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
        [switch]$Aggressive,
        [switch]$NoSave
    )
    Find-BestLlamaCppConfig @PSBoundParameters
}
