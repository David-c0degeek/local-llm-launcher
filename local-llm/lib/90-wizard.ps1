# Interactive wizard. Two implementations: a native selectable console one and
# a Spectre.Console one. Start-LLMWizard prefers Spectre when available; set
# LOCAL_LLM_NO_SPECTRE=1 or use llmc to force the native picker.

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
    # Returns an integer index (>= 0) for a selected item, -1 for ZeroLabel,
    # or the matching letter (as a string) when a LetterChoices entry is picked.
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)][scriptblock]$Label,
        [string]$ZeroLabel = "Back",
        [hashtable]$LetterChoices = @{}
    )

    if (-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) {
        return (Read-LLMChoiceIndexNative -Title $Title -Items $Items -Label $Label -ZeroLabel $ZeroLabel -LetterChoices $LetterChoices)
    }

    while ($true) {
        Write-Section $Title

        for ($i = 0; $i -lt $Items.Count; $i++) {
            $num = $i + 1
            $labelText = & $Label $Items[$i] $i
            Write-Host ("{0,3}  {1}" -f $num, $labelText)
        }

        Write-Host ""
        Write-Host ("  0  {0}" -f $ZeroLabel) -ForegroundColor Yellow
        foreach ($letter in @($LetterChoices.Keys | Sort-Object)) {
            Write-Host ("  {0}  {1}" -f $letter, $LetterChoices[$letter]) -ForegroundColor Yellow
        }
        Write-Host ""

        $choice = (Read-Host "Choose").Trim().ToLowerInvariant()

        if ($choice -eq "0") {
            return -1
        }

        if ($LetterChoices.ContainsKey($choice)) {
            return $choice
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

    # Fresh-catalog escape hatch: addllm tags new models 'experimental' by
    # default, so a brand-new install has zero recommended models. Falling
    # through to -All here is friendlier than dead-ending.
    if ($keys.Count -eq 0 -and -not $All) {
        $keys = @(Get-FilteredModelKeys -IncludeAll)
        if ($keys.Count -gt 0) {
            return (Select-LLMModelKey -All)
        }
    }

    if ($keys.Count -eq 0) {
        Write-Host "No models configured. Use 'addllm <hf-url> -Key <key>' to add one." -ForegroundColor Yellow
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
        $strictBadge = if (Get-ModelStrictEnabled -Def $def) { " [strict]" } else { "" }
        $head = "$key  ->  $($def.DisplayName)$quant | contexts: $contexts$strictBadge"

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
    # Returns: a quant key (chosen), '__keep__' (keep current), or $null (back).
    param([Parameter(Mandatory = $true)][string]$ModelKey)

    $def = Get-ModelDef -Key $ModelKey

    if (-not $def.ContainsKey("Quants")) {
        return '__keep__'
    }

    $quantKeys = @($def.Quants.Keys)

    $result = Read-LLMChoiceIndex `
        -Title "Select quant for $ModelKey" `
        -Items $quantKeys `
        -ZeroLabel "Back" `
        -LetterChoices @{ 'k' = "Keep current: $($def.Quant)" } `
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

    if ($result -is [string] -and $result -eq 'k') { return '__keep__' }
    if ($result -is [int] -and $result -lt 0)      { return $null }

    return $quantKeys[$result]
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
    param([string]$Backend = 'ollama')

    $actions = if ($Backend -eq 'llamacpp') {
        @(
            [pscustomobject]@{ Key = "claude"; Label = "Claude Code"; Description = "Local model behind Claude Code" },
            [pscustomobject]@{ Key = "codex"; Label = "Codex"; Description = "Local model behind OpenAI Codex" },
            [pscustomobject]@{ Key = "unshackled"; Label = "Unshackled"; Description = "Local agent via Unshackled" },
            [pscustomobject]@{ Key = "setdefault"; Label = "Set llmdefault"; Description = "Save this model/profile/target as llmdefault" },
            [pscustomobject]@{ Key = "findbest"; Label = "Find best settings"; Description = "Auto-tune for this machine" },
            [pscustomobject]@{ Key = "resetbest"; Label = "Delete best settings"; Description = "Reset saved AutoBest config" },
            [pscustomobject]@{ Key = "setup"; Label = "Download GGUF only"; Description = "Resolve and cache the GGUF without launching" }
        )
    } else {
        @(
            [pscustomobject]@{ Key = "claude"; Label = "Claude Code"; Description = "Local model behind Claude Code" },
            [pscustomobject]@{ Key = "codex"; Label = "Codex"; Description = "Local model behind OpenAI Codex" },
            [pscustomobject]@{ Key = "unshackled"; Label = "Unshackled"; Description = "Local agent via Unshackled" },
            [pscustomobject]@{ Key = "chat"; Label = "Ollama chat"; Description = "Plain ollama run" },
            [pscustomobject]@{ Key = "setdefault"; Label = "Set llmdefault"; Description = "Save this model/profile/target as llmdefault" },
            [pscustomobject]@{ Key = "benchmark"; Label = "Benchmark"; Description = "Run ospeed for selected alias" },
            [pscustomobject]@{ Key = "setup"; Label = "Setup/create alias only"; Description = "Download/create selected alias" },
            [pscustomobject]@{ Key = "show"; Label = "Show ollama model info"; Description = "Run ollama show" }
        )
    }

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

function Select-LLMDefaultTarget {
    param([string]$Backend = 'ollama')

    $targets = if ($Backend -eq 'llamacpp') {
        @(
            [pscustomobject]@{ Key = "claude"; Label = "Claude Code"; Description = "Local model behind Claude Code" },
            [pscustomobject]@{ Key = "codex"; Label = "Codex"; Description = "Local model behind OpenAI Codex" },
            [pscustomobject]@{ Key = "unshackled"; Label = "Unshackled"; Description = "Local agent via Unshackled" }
        )
    } else {
        @(
            [pscustomobject]@{ Key = "claude"; Label = "Claude Code"; Description = "Local model behind Claude Code" },
            [pscustomobject]@{ Key = "codex"; Label = "Codex"; Description = "Local model behind OpenAI Codex" },
            [pscustomobject]@{ Key = "unshackled"; Label = "Unshackled"; Description = "Local agent via Unshackled" },
            [pscustomobject]@{ Key = "chat"; Label = "Ollama chat"; Description = "Plain ollama run" }
        )
    }

    $idx = Read-LLMChoiceIndex `
        -Title "llmdefault target" `
        -Items $targets `
        -ZeroLabel "Back" `
        -Label {
        param($target, $i)
        return "$($target.Label)  -  $($target.Description)"
    }

    if ($idx -lt 0) { return $null }
    return $targets[$idx].Key
}

function Select-LLMBackend {
    # Returns one of 'ollama', 'llamacpp-native', 'llamacpp-turboquant', or $null (back).
    # For models that aren't llama.cpp-eligible, this auto-returns 'ollama'.
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def)

    if (-not (Test-LlamaCppEligible -Def $Def)) {
        return 'ollama'
    }

    $items = @(
        [pscustomobject]@{ Key = 'ollama';              Label = 'Ollama (default)';                       Description = 'Existing alias-based path' },
        [pscustomobject]@{ Key = 'llamacpp-native';     Label = 'llama.cpp native';                       Description = 'Upstream llama-server.exe (mainline KV types)' },
        [pscustomobject]@{ Key = 'llamacpp-turboquant'; Label = 'llama.cpp turboquant (turbo3/turbo4 KV)'; Description = 'Fork binary; supports turbo KV cache types' }
    )

    $idx = Read-LLMChoiceIndex `
        -Title "Select backend" `
        -Items $items `
        -ZeroLabel "Back" `
        -Label {
        param($item, $i)
        return "$($item.Label)  -  $($item.Description)"
    }

    if ($idx -lt 0) { return $null }
    return $items[$idx].Key
}

function Get-LlamaCppKvCacheChoices {
    param([Parameter(Mandatory = $true)][string]$Mode)

    $base = @('q8_0', 'f16', 'q5_1', 'q5_0', 'q4_1', 'q4_0', 'iq4_nl', 'bf16', 'f32')
    if ($Mode -eq 'turboquant') {
        return @('turbo4', 'turbo3') + $base
    }
    return $base
}

function Select-LLMKvCache {
    # Returns @{ K; V } or $null (back).
    param([Parameter(Mandatory = $true)][string]$Mode)

    $choices = Get-LlamaCppKvCacheChoices -Mode $Mode

    $idx = Read-LLMChoiceIndex `
        -Title ("Select KV cache type ($Mode)") `
        -Items $choices `
        -ZeroLabel "Back" `
        -Label {
        param($t, $i)
        $note = switch ($t) {
            'q8_0'    { 'q8_0 — default; fast and memory-efficient' }
            'f16'     { 'f16 — full quality, ~2x KV memory of q8_0' }
            'q5_1'    { 'q5_1 — slightly smaller than q8_0' }
            'q5_0'    { 'q5_0 — smaller still' }
            'q4_1'    { 'q4_1 — aggressive; quality risk on long context' }
            'q4_0'    { 'q4_0 — most aggressive mainline' }
            'iq4_nl'  { 'iq4_nl — newer 4-bit non-linear' }
            'bf16'    { 'bf16 — full precision (where supported)' }
            'f32'     { 'f32 — pristine; rarely needed' }
            'turbo3'  { 'turbo3 — turboquant fork only (docker)' }
            'turbo4'  { 'turbo4 — turboquant fork only (docker), most aggressive' }
            default   { $t }
        }
        return "$t  -  $note"
    }

    if ($idx -lt 0) { return $null }

    $picked = $choices[$idx]
    return @{ K = $picked; V = $picked }
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

function Read-LLMVisionToggle {
    # Returns $true (vision on), $false (vision off), or $null (back).
    $items = @(
        [pscustomobject]@{ Key = $false; Label = 'No';  Description = 'Launch without vision support' },
        [pscustomobject]@{ Key = $true;  Label = 'Yes'; Description = 'Load multimodal module (mmproj.gguf) for vision' }
    )

    $idx = Read-LLMChoiceIndex `
        -Title "Use vision (multimodal)?" `
        -Items $items `
        -ZeroLabel "Back" `
        -Label {
            param($item, $i)
            "$($item.Label)  -  $($item.Description)"
        }

    if ($idx -lt 0) {
        return $null
    }

    return [bool]$items[$idx].Key
}

function Read-LLMQ8Toggle {
    # Returns $true (q8 on), $false (q8 off), or $null (back).
    $items = @(
        [pscustomobject]@{ Key = $false; Label = 'No';  Description = 'Default KV cache behavior' },
        [pscustomobject]@{ Key = $true;  Label = 'Yes'; Description = 'Use q8_0 KV cache for this launch' }
    )

    $idx = Read-LLMChoiceIndex `
        -Title "Use q8 KV cache?" `
        -Items $items `
        -ZeroLabel "Back" `
        -Label {
            param($item, $i)
            "$($item.Label)  -  $($item.Description)"
        }

    if ($idx -lt 0) {
        return $null
    }

    return [bool]$items[$idx].Key
}

function Read-LLMStrictToggle {
    # Returns $true (strict on), $false (strict off), or $null (back).
    # Only meaningful when the selected model has Strict: true in the catalog;
    # the wizard gates this prompt on Get-ModelStrictEnabled.
    $items = @(
        [pscustomobject]@{ Key = $false; Label = 'No';  Description = 'Use the base alias and continue to context selection' },
        [pscustomobject]@{ Key = $true;  Label = 'Yes'; Description = 'Use the strict alias; pins context and skips context selection' }
    )

    $idx = Read-LLMChoiceIndex `
        -Title "Use strict mode?" `
        -Items $items `
        -ZeroLabel "Back" `
        -Label {
            param($item, $i)
            "$($item.Label)  -  $($item.Description)"
        }

    if ($idx -lt 0) {
        return $null
    }

    return [bool]$items[$idx].Key
}

function Read-LLMYesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [bool]$DefaultYes = $false
    )

    $items = if ($DefaultYes) {
        @(
            [pscustomobject]@{ Key = $true;  Label = 'Yes'; Description = 'Default' },
            [pscustomobject]@{ Key = $false; Label = 'No';  Description = '' }
        )
    } else {
        @(
            [pscustomobject]@{ Key = $false; Label = 'No';  Description = 'Default' },
            [pscustomobject]@{ Key = $true;  Label = 'Yes'; Description = '' }
        )
    }

    $idx = Read-LLMChoiceIndex `
        -Title $Prompt `
        -Items $items `
        -ZeroLabel $(if ($DefaultYes) { "Default: Yes" } else { "Default: No" }) `
        -Label {
            param($item, $i)
            if ([string]::IsNullOrWhiteSpace($item.Description)) {
                return $item.Label
            }
            return "$($item.Label)  -  $($item.Description)"
        }

    if ($idx -lt 0) {
        return $DefaultYes
    }

    return [bool]$items[$idx].Key
}

function Read-LLMTuneDepth {
    $items = @(
        [pscustomobject]@{ Key = 'normal'; Label = 'Normal'; Description = 'Default tuner pass, budget 100' },
        [pscustomobject]@{ Key = 'deep';   Label = 'Deep';   Description = 'Normal pass plus finer local refinement, budget 100 unless overridden' }
    )

    $idx = Read-LLMChoiceIndex `
        -Title "Tune depth" `
        -Items $items `
        -ZeroLabel "Back" `
        -Label {
            param($item, $i)
            "$($item.Label)  -  $($item.Description)"
        }

    if ($idx -lt 0) { return $null }
    return [string]$items[$idx].Key
}

function Read-LLMTuneBudget {
    $items = @(
        [pscustomobject]@{ Key = '100';    Label = '100';    Description = 'Default — standard for all models' },
        [pscustomobject]@{ Key = '150';    Label = '150';    Description = 'Extended — MoE with moderate option set' },
        [pscustomobject]@{ Key = '200';    Label = '200';    Description = 'High — MoE with wide option set' },
        [pscustomobject]@{ Key = 'custom'; Label = 'Custom'; Description = 'Enter a custom value' }
    )

    $idx = Read-LLMChoiceIndex `
        -Title "Budget (max benchmarks per run)" `
        -Items $items `
        -ZeroLabel "Back" `
        -Label { param($item, $i) "$($item.Label)  -  $($item.Description)" }

    if ($idx -lt 0) { return $null }
    if ($items[$idx].Key -eq 'custom') {
        $raw = Read-Host "Budget (integer, e.g. 120)"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        if ($raw -match '^\d+$' -and [int]$raw -gt 0) { return [int]$raw }
        Write-Warning "Invalid value '$raw'. Using default 100."
        return 100
    }
    return [int]$items[$idx].Key
}

function Read-LLMTuneOptimize {
    $items = @(
        [pscustomobject]@{ Key = 'coding-agent'; Label = 'Coding agent'; Description = 'Long-prompt end-to-end latency for Claude Code/Unshackled' },
        [pscustomobject]@{ Key = 'both';   Label = 'Balanced';   Description = 'Prompt/prefill and generation throughput' },
        [pscustomobject]@{ Key = 'prompt'; Label = 'Prefill';    Description = 'Prioritize first-token latency on large prompts' },
        [pscustomobject]@{ Key = 'gen';    Label = 'Generation'; Description = 'Prioritize tokens/sec after generation starts' }
    )

    $idx = Read-LLMChoiceIndex `
        -Title "Tune goal" `
        -Items $items `
        -ZeroLabel "Back" `
        -Label {
            param($item, $i)
            "$($item.Label)  -  $($item.Description)"
        }

    if ($idx -lt 0) { return $null }
    return [string]$items[$idx].Key
}

function Read-LLMTuneKvVariation {
    param([Parameter(Mandatory = $true)][string]$Mode)

    $items = @(
        [pscustomobject]@{ Key = 'no';  Label = 'No';    Description = 'Keep current KV type only' },
        [pscustomobject]@{ Key = 'yes'; Label = 'Yes';   Description = 'Widen within the quality class' }
    )
    if ($Mode -eq 'turboquant') {
        $items += [pscustomobject]@{ Key = 'turbo-only'; Label = 'Turbo'; Description = 'Test turbo3 and turbo4 only' }
    }

    $idx = Read-LLMChoiceIndex `
        -Title "Allow KV cache variation?" `
        -Items $items `
        -ZeroLabel "Back" `
        -Label {
            param($item, $i)
            "$($item.Label)  -  $($item.Description)"
        }

    if ($idx -lt 0) { return $null }
    return [string]$items[$idx].Key
}

function Read-LLMTuneNCpuMoeRange {
    param(
        [Parameter(Mandatory = $true)][string]$ModelKey,
        [AllowEmptyString()][string]$ContextKey = ''
    )

    $topValues = @()
    if (Get-Command Get-BenchPilotTopNCpuMoeValues -ErrorAction SilentlyContinue) {
        $topValues = @(Get-BenchPilotTopNCpuMoeValues -Key $ModelKey -ContextKey $ContextKey -TopN 5)
    }

    $parseRange = {
        param([string]$input)
        $trimmed = $input.Trim()
        if ($trimmed -match '^(\d+)-(\d+):(\d+)$') {
            $start = [int]$Matches[1]; $end = [int]$Matches[2]; $step = [int]$Matches[3]
            if ($step -lt 1) { $step = 1 }
            $vals = @()
            for ($v = $start; $v -le $end; $v += $step) { $vals += $v }
            return @($vals | Select-Object -Unique)
        }
        return $null
    }

    if ($topValues.Count -gt 0) {
        $topStr = (($topValues | Sort-Object | ForEach-Object { [string]$_ }) -join ', ')
        $minVal = ($topValues | Measure-Object -Minimum).Minimum
        $maxVal = ($topValues | Measure-Object -Maximum).Maximum
        $items = @(
            [pscustomobject]@{ Key = 'step1';   Label = 'Yes — step=1';  Description = "Test NCpuMoe $minVal..$maxVal in steps of 1  (previous best: $topStr)" },
            [pscustomobject]@{ Key = 'default'; Label = 'No — defaults'; Description = 'Use auto-generated candidate range' },
            [pscustomobject]@{ Key = 'custom';  Label = 'Custom';        Description = 'Enter own range  (format: start-end:step, e.g. 15-40:2)' }
        )
        $idx = Read-LLMChoiceIndex `
            -Title "Refine NCpuMoe around previous best?" `
            -Items $items -ZeroLabel "Back" `
            -Label { param($item, $i) "$($item.Label)  -  $($item.Description)" }

        if ($idx -lt 0) { return $null }
        $choice = $items[$idx].Key

        if ($choice -eq 'step1') {
            return @([int]$minVal..[int]$maxVal)
        }
        if ($choice -eq 'custom') {
            $raw = Read-Host "NCpuMoe range (start-end:step, e.g. 20-40:1)"
            if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
            $parsed = & $parseRange $raw
            if ($parsed -and $parsed.Count -gt 0) { return $parsed }
            Write-Warning "Could not parse '$raw' as start-end:step range. Using defaults."
            return $null
        }
        return $null
    }

    # No history: offer defaults or custom entry
    $items = @(
        [pscustomobject]@{ Key = 'default'; Label = 'Use defaults'; Description = 'Auto-generate NCpuMoe candidates from model catalog' },
        [pscustomobject]@{ Key = 'custom';  Label = 'Custom range'; Description = 'Enter your own range  (format: start-end:step, e.g. 15-40:2)' }
    )
    $idx = Read-LLMChoiceIndex `
        -Title "NCpuMoe expert offload range" `
        -Items $items -ZeroLabel "Back" `
        -Label { param($item, $i) "$($item.Label)  -  $($item.Description)" }

    if ($idx -lt 0) { return $null }
    if ($items[$idx].Key -eq 'custom') {
        $raw = Read-Host "NCpuMoe range (start-end:step, e.g. 20-40:1)"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $parsed = & $parseRange $raw
        if ($parsed -and $parsed.Count -gt 0) { return $parsed }
        Write-Warning "Could not parse '$raw' as start-end:step range. Using defaults."
    }
    return $null
}

function Read-LLMTuneProfile {
    $items = @(
        [pscustomobject]@{ Key = 'pure';     Label = 'Pure';   Description = 'Fastest measured LLM throughput' },
        [pscustomobject]@{ Key = 'balanced'; Label = 'Usable'; Description = 'Prefer throughput with workstation headroom' },
        [pscustomobject]@{ Key = 'both';     Label = 'Both';   Description = 'Run and save pure plus usable profiles' }
    )

    $idx = Read-LLMChoiceIndex `
        -Title "Selection profile" `
        -Items $items `
        -ZeroLabel "Back" `
        -Label {
            param($item, $i)
            "$($item.Label)  -  $($item.Description)"
        }

    if ($idx -lt 0) { return $null }
    return [string]$items[$idx].Key
}

function Invoke-LlamaCppTunerWizardFlow {
    param(
        [Parameter(Mandatory = $true)][string]$ModelKey,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][ValidateSet('native','turboquant')][string]$Mode,
        [switch]$UseSpectrePrompts
    )

    $depth = if ($UseSpectrePrompts) {
        Read-LLMTuneDepthSpectre
    } else {
        Read-LLMTuneDepth
    }
    if ([string]::IsNullOrWhiteSpace($depth)) { return }
    $useDeep = $depth -eq 'deep'

    $budget = 100
    if ($useDeep) {
        $budget = if ($UseSpectrePrompts) {
            Read-LLMTuneBudgetSpectre
        } else {
            Read-LLMTuneBudget
        }
        if ($null -eq $budget) { return }
    }

    $optimize = if ($UseSpectrePrompts) {
        Read-LLMTuneOptimizeSpectre
    } else {
        Read-LLMTuneOptimize
    }
    if ([string]::IsNullOrWhiteSpace($optimize)) { return }

    $selectionProfile = if ($UseSpectrePrompts) {
        Read-LLMTuneProfileSpectre
    } else {
        Read-LLMTuneProfile
    }
    if ([string]::IsNullOrWhiteSpace($selectionProfile)) { return }

    $allowKv = if ($UseSpectrePrompts) {
        Read-LLMTuneKvVariationSpectre -Mode $Mode
    } else {
        Read-LLMTuneKvVariation -Mode $Mode
    }
    if ([string]::IsNullOrWhiteSpace($allowKv)) { return }

    $allowedKvTypes = switch ($allowKv) {
        'yes'        { if ($Mode -eq 'turboquant') { @('q8_0', 'f16', 'turbo3', 'turbo4') } else { @('q8_0', 'f16') } }
        'turbo-only' { @('turbo3', 'turbo4') }
        default      { $null }
    }

    $def = Get-ModelDef -Key $ModelKey
    $quant = if ($def.Contains('Quant')) { [string]$def.Quant } else { '' }

    $ncpuMoeCandidates = $null
    $isMoE = $def.Contains('NCpuMoe') -and $null -ne $def.NCpuMoe
    if ($isMoE -and -not $UseSpectrePrompts) {
        $ncpuMoeCandidates = Read-LLMTuneNCpuMoeRange -ModelKey $ModelKey -ContextKey $ContextKey
    }

    $findParams = @{
        Key            = $ModelKey
        ContextKey     = $ContextKey
        Mode           = $Mode
        Quant          = $quant
        AllowedKvTypes = $allowedKvTypes
        Deep           = $useDeep
        Budget         = $budget
        Optimize       = $optimize
        Profile        = $selectionProfile
        NoSave         = $true
    }
    if ($ncpuMoeCandidates -and $ncpuMoeCandidates.Count -gt 0) {
        $findParams.NCpuMoeCandidates = [int[]]$ncpuMoeCandidates
    }
    $result = Find-BestLlamaCppConfig @findParams
    $results = @($result | Where-Object { $_ })

    Write-Host ""
    $resultTitle = if ($results.Count -eq 1) { "Best tuner result:" } else { "Best tuner results:" }
    Write-Host $resultTitle -ForegroundColor Green
    foreach ($item in $results) {
        $profileLabel = if ($item.Profile) { [string]$item.Profile } else { 'pure' }
        Write-Host ("  [{0}] score     : {1:N2} ({2})" -f $profileLabel, $item.Score, $item.ScoreUnit) -ForegroundColor Green
        Write-Host ("  [{0}] overrides : {1}" -f $profileLabel, (Format-LlamaCppOverrides -Overrides $item.Overrides)) -ForegroundColor DarkGray
    }
    Write-Host ""

    $reportResults = @($results | Where-Object { $_.report_path })
    if ($reportResults.Count -gt 0) {
        $reportPrompt = if ($reportResults.Count -eq 1) { "Open BenchPilot report?" } else { "Open BenchPilot reports?" }
        $openReport = if ($UseSpectrePrompts) {
            Read-LLMYesNoSpectre -Message $reportPrompt -DefaultYes
        } else {
            Read-LLMYesNo -Prompt $reportPrompt -DefaultYes:$true
        }
        if ($openReport) {
            foreach ($item in $reportResults) {
                if (Test-Path -LiteralPath $item.report_path) {
                    Invoke-Item -LiteralPath $item.report_path
                }
            }
        }
    }

    $saveAnswer = if ($UseSpectrePrompts) {
        Read-LLMYesNoSpectre -Message "Save as the default for this machine?" -DefaultYes
    } else {
        Read-LLMYesNo -Prompt "Save as the default for this machine?" -DefaultYes:$true
    }
    if ($saveAnswer) {
        foreach ($item in $results) {
            $itemProfile = if ($item.Profile) { [string]$item.Profile } else { 'pure' }
            if ($item.source -eq 'benchpilot' -and (Get-Command Export-BenchPilotLauncherProfile -ErrorAction SilentlyContinue)) {
                $saveParams = @{
                    Key               = $ModelKey
                    ContextKey        = $ContextKey
                    Mode              = $Mode
                    Quant             = $item.Quant
                    VramGB            = $item.VramGB
                    PromptLength      = $item.PromptLength
                    Overrides         = $item.Overrides
                    Args              = @($item.Args)
                    Score             = $item.Score
                    ScoreUnit         = $item.ScoreUnit
                    TrialCount        = $item.TrialCount
                    Profile           = $itemProfile
                    NativeProfilePath = $item.native_profile_path
                    ReportPath        = $item.report_path
                }
                if (-not [string]::IsNullOrWhiteSpace($item.SearchStrategy)) { $saveParams.SearchStrategy = $item.SearchStrategy }
                if ($null -ne $item.BeamWidth) { $saveParams.BeamWidth = $item.BeamWidth }
                if ($null -ne $item.PureScore) { $saveParams.PureScore = $item.PureScore }
                if ($null -ne $item.Telemetry) { $saveParams.Telemetry = $item.Telemetry }
                if ($null -ne $item.ScoreBreakdown) { $saveParams.ScoreBreakdown = $item.ScoreBreakdown }

                $saved = Export-BenchPilotLauncherProfile @saveParams
            } else {
                $saveParams = @{
                    Key            = $ModelKey
                    ContextKey     = $ContextKey
                    Mode           = $Mode
                    Quant          = $item.Quant
                    VramGB         = $item.VramGB
                    PromptLength   = $item.PromptLength
                    BestArgs       = $item.Args
                    BestOverrides  = $item.Overrides
                    Score          = $item.Score
                    ScoreUnit      = $item.ScoreUnit
                    TrialCount     = $item.TrialCount
                    Profile        = $itemProfile
                }
                if (-not [string]::IsNullOrWhiteSpace($item.SearchStrategy)) { $saveParams.SearchStrategy = $item.SearchStrategy }
                if ($null -ne $item.BeamWidth) { $saveParams.BeamWidth = $item.BeamWidth }
                if ($null -ne $item.PureScore) { $saveParams.PureScore = $item.PureScore }
                if ($item.Telemetry -is [System.Collections.IDictionary]) { $saveParams.Telemetry = $item.Telemetry }
                if ($item.ScoreBreakdown -is [System.Collections.IDictionary]) { $saveParams.ScoreBreakdown = $item.ScoreBreakdown }

                $saved = Save-BestLlamaCppConfig @saveParams
            }
            Write-Host "Saved best -> $saved" -ForegroundColor DarkGray
        }
    }

    $launchAnswer = if ($UseSpectrePrompts) {
        Read-LLMYesNoSpectre -Message "Launch immediately with the new config?" -DefaultYes
    } else {
        Read-LLMYesNo -Prompt "Launch immediately with the new config?" -DefaultYes:$true
    }
    if ($launchAnswer) {
        if (-not $saveAnswer) {
            Write-Warning "Launch skipped: launching with the new config requires saving it first."
            return
        }

        $launchAction = if ($UseSpectrePrompts) {
            Select-LlamaCppPostTuneLaunchActionSpectre
        } else {
            Select-LlamaCppPostTuneLaunchAction
        }
        if ([string]::IsNullOrWhiteSpace($launchAction)) { return }
        $launchProfile = if ($selectionProfile -eq 'pure') {
            'pure'
        } elseif ($selectionProfile -eq 'balanced') {
            'balanced'
        } elseif ($UseSpectrePrompts) {
            Select-LlamaCppPostTuneProfileSpectre -Results $results
        } else {
            Select-LlamaCppPostTuneProfile -Results $results
        }
        if ([string]::IsNullOrWhiteSpace($launchProfile)) { return }

        $launchArgs = @{
            Key             = $ModelKey
            ContextKey      = $ContextKey
            Mode            = $Mode
            AutoBest        = $true
            AutoBestProfile = $launchProfile
        }
        if ($launchAction -eq 'unshackled') {
            $launchArgs.Unshackled = $true
        }
        if ($launchAction -eq 'codex') {
            $launchArgs.Codex = $true
        }

        Start-ClaudeWithLlamaCppModel @launchArgs
    }
}

function Read-LLMChoiceIndexNative {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)][scriptblock]$Label,
        [string]$ZeroLabel = "Back",
        [hashtable]$LetterChoices = @{}
    )

    $options = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $options.Add([pscustomobject]@{
            Kind = 'item'
            Key = $i
            Shortcut = [string]($i + 1)
            Text = [string](& $Label $Items[$i] $i)
        }) | Out-Null
    }

    $options.Add([pscustomobject]@{
        Kind = 'zero'
        Key = -1
        Shortcut = '0'
        Text = $ZeroLabel
    }) | Out-Null

    foreach ($letter in @($LetterChoices.Keys | Sort-Object)) {
        $options.Add([pscustomobject]@{
            Kind = 'letter'
            Key = [string]$letter
            Shortcut = [string]$letter
            Text = [string]$LetterChoices[$letter]
        }) | Out-Null
    }

    $selected = 0
    $typed = ''
    $message = ''

    while ($true) {
        Clear-Host
        Write-Section $Title
        Write-Host "Use Up/Down, Enter to select, 0 for $ZeroLabel. Number and letter shortcuts work too." -ForegroundColor DarkGray
        if (-not [string]::IsNullOrWhiteSpace($typed)) {
            Write-Host "Typed: $typed" -ForegroundColor DarkGray
        }
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            Write-Host $message -ForegroundColor Yellow
        }
        Write-Host ""

        for ($i = 0; $i -lt $options.Count; $i++) {
            $option = $options[$i]
            $lines = @(([string]$option.Text) -split "`r?`n")
            if ($lines.Count -eq 0) { $lines = @('') }

            $prefix = if ($i -eq $selected) { '>' } else { ' ' }
            $shortcut = $option.Shortcut
            $color = if ($i -eq $selected) { 'Cyan' } elseif ($option.Kind -eq 'item') { 'Gray' } else { 'Yellow' }

            Write-Host ("{0} {1,3}  {2}" -f $prefix, $shortcut, $lines[0]) -ForegroundColor $color
            for ($lineIndex = 1; $lineIndex -lt $lines.Count; $lineIndex++) {
                Write-Host ("       {0}" -f $lines[$lineIndex]) -ForegroundColor DarkGray
            }
        }

        $keyInfo = [Console]::ReadKey($true)
        $message = ''

        switch ($keyInfo.Key) {
            'UpArrow' {
                $selected--
                if ($selected -lt 0) { $selected = $options.Count - 1 }
                $typed = ''
                continue
            }
            'DownArrow' {
                $selected++
                if ($selected -ge $options.Count) { $selected = 0 }
                $typed = ''
                continue
            }
            'Home' {
                $selected = 0
                $typed = ''
                continue
            }
            'End' {
                $selected = $options.Count - 1
                $typed = ''
                continue
            }
            'Enter' {
                $picked = $options[$selected]
                if ($picked.Kind -eq 'item') { return [int]$picked.Key }
                if ($picked.Kind -eq 'zero') { return -1 }
                return [string]$picked.Key
            }
            'Escape' {
                return -1
            }
            'Backspace' {
                if ($typed.Length -gt 0) {
                    $typed = $typed.Substring(0, $typed.Length - 1)
                }
                continue
            }
        }

        $char = [string]$keyInfo.KeyChar
        if ([string]::IsNullOrEmpty($char) -or [char]::IsControl($keyInfo.KeyChar)) {
            continue
        }

        $lower = $char.ToLowerInvariant()
        if ($LetterChoices.ContainsKey($lower)) {
            return $lower
        }

        if ($char -eq '0') {
            return -1
        }

        if ($char -match '^\d$') {
            $typed += $char
            $matches = @($options | Where-Object { $_.Shortcut -like "$typed*" })
            if ($matches.Count -eq 1 -and $matches[0].Shortcut -eq $typed) {
                $picked = $matches[0]
                if ($picked.Kind -eq 'item') { return [int]$picked.Key }
                if ($picked.Kind -eq 'zero') { return -1 }
                return [string]$picked.Key
            }

            $exactIndex = -1
            for ($i = 0; $i -lt $options.Count; $i++) {
                if ($options[$i].Shortcut -eq $typed) {
                    $exactIndex = $i
                    break
                }
            }
            if ($exactIndex -ge 0) {
                $selected = $exactIndex
                continue
            }

            if ($matches.Count -gt 0) {
                for ($i = 0; $i -lt $options.Count; $i++) {
                    if ($options[$i].Shortcut -like "$typed*") {
                        $selected = $i
                        break
                    }
                }
                continue
            }

            $typed = $char
            $message = "No matching selection."
            continue
        }

        $message = "Use arrows, Enter, 0, or a listed shortcut."
    }
}

function Invoke-LlamaCppBestResetWizardFlow {
    param(
        [Parameter(Mandatory = $true)][string]$ModelKey,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][ValidateSet('native','turboquant')][string]$Mode,
        [switch]$UseSpectrePrompts
    )

    $def = Get-ModelDef -Key $ModelKey
    $quant = if ($def.Contains('Quant')) { [string]$def.Quant } else { '' }
    $ctxLabel = if ([string]::IsNullOrWhiteSpace($ContextKey)) { 'default' } else { $ContextKey }
    Write-Host ""
    Write-Host "Delete saved AutoBest settings for:" -ForegroundColor Yellow
    Write-Host "  model   : $ModelKey" -ForegroundColor DarkGray
    Write-Host "  quant   : $quant" -ForegroundColor DarkGray
    Write-Host "  context : $ctxLabel" -ForegroundColor DarkGray
    Write-Host "  mode    : $Mode" -ForegroundColor DarkGray
    Write-Host ""

    $confirm = if ($UseSpectrePrompts) {
        Read-LLMYesNoSpectre -Message "Delete matching saved best settings?"
    } else {
        Read-LLMYesNo -Prompt "Delete matching saved best settings?" -DefaultYes:$false
    }
    if (-not $confirm) { return }

    $result = Remove-LlamaCppBestConfig -Key $ModelKey -ContextKey $ContextKey -Mode $Mode -Quant $quant -AllPromptLengths
    if ($result.Removed -gt 0) {
        Write-Host "Deleted $($result.Removed) saved best setting(s)." -ForegroundColor Green
        if ($result.DeletedFile) {
            Write-Host "Removed $($result.Path)" -ForegroundColor DarkGray
        } else {
            Write-Host "$($result.Remaining) saved setting(s) remain in $($result.Path)" -ForegroundColor DarkGray
        }
        if ($result.PSObject.Properties['RemovedBenchPilotProfiles'] -and @($result.RemovedBenchPilotProfiles).Count -gt 0) {
            Write-Host "Removed $(@($result.RemovedBenchPilotProfiles).Count) BenchPilot native profile reference(s)." -ForegroundColor DarkGray
        }
    } else {
        Write-Host "No matching saved best settings found." -ForegroundColor DarkGray
    }
}

function Test-LlamaCppWizardAutoBestAvailable {
    param(
        [Parameter(Mandatory = $true)][string]$ModelKey,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][ValidateSet('native','turboquant')][string]$Mode
    )

    try {
        $preferred = Get-PreferredLlamaCppBestConfig -Key $ModelKey -ContextKey $ContextKey -Mode $Mode
        $entry = if ($preferred) { $preferred.Entry } else { $null }
        return [bool]($entry -and $entry.overrides)
    }
    catch {
        return $false
    }
}

function Get-LlamaCppWizardAutoBestChoices {
    param(
        [Parameter(Mandatory = $true)][string]$ModelKey,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][ValidateSet('native','turboquant')][string]$Mode
    )

    $choices = @()
    foreach ($profileName in @('balanced', 'pure')) {
        try {
            $preferred = Get-PreferredLlamaCppBestConfig -Key $ModelKey -ContextKey $ContextKey -Mode $Mode -Profile $profileName
            if (-not $preferred -or -not $preferred.Entry -or -not $preferred.Entry.overrides) { continue }
            $entry = $preferred.Entry
            $score = if ($entry.score) {
                "profile=$profileName/$($preferred.PromptLength) score=$($entry.score) $($entry.scoreUnit)"
            } else {
                "profile=$profileName/$($preferred.PromptLength)"
            }
            $label = if ($profileName -eq 'balanced') { 'Use balanced' } else { 'Use pure' }
            $description = if ($profileName -eq 'balanced') {
                "Apply saved balanced AutoBest settings ($score)"
            } else {
                "Apply saved pure AutoBest settings ($score)"
            }
            $choices += [pscustomobject]@{
                Key = "best:$profileName"
                Label = $label
                Description = $description
                Profile = $profileName
            }
        }
        catch {}
    }

    return @($choices)
}

function Select-LlamaCppLaunchSettingsMode {
    param(
        [Parameter(Mandatory = $true)][string]$ModelKey,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][ValidateSet('native','turboquant')][string]$Mode
    )

    $bestChoices = @(Get-LlamaCppWizardAutoBestChoices -ModelKey $ModelKey -ContextKey $ContextKey -Mode $Mode)
    if ($bestChoices.Count -eq 0) {
        return 'manual'
    }

    $items = @($bestChoices)
    if ($bestChoices.Count -gt 1) {
        $items += [pscustomobject]@{ Key = 'best:auto'; Label = 'Use AutoBest'; Description = 'Prefer balanced, then pure automatically'; Profile = 'auto' }
    }
    $items += [pscustomobject]@{ Key = 'manual'; Label = 'Manual settings'; Description = 'Pick KV cache and launch settings now'; Profile = '' }

    $idx = Read-LLMChoiceIndex `
        -Title "Launch settings" `
        -Items $items `
        -ZeroLabel "Back" `
        -Label {
            param($item, $i)
            "$($item.Label)  -  $($item.Description)"
        }

    if ($idx -lt 0) { return $null }
    return [string]$items[$idx].Key
}

function Select-LlamaCppPostTuneLaunchAction {
    $items = @(
        [pscustomobject]@{ Key = 'claude'; Label = 'Claude Code'; Description = 'Local model behind Claude Code' },
        [pscustomobject]@{ Key = 'codex'; Label = 'Codex'; Description = 'Local model behind OpenAI Codex' },
        [pscustomobject]@{ Key = 'unshackled'; Label = 'Unshackled';   Description = 'Local agent via Unshackled' }
    )

    $idx = Read-LLMChoiceIndex `
        -Title "Launch target" `
        -Items $items `
        -ZeroLabel "Cancel" `
        -Label {
            param($item, $i)
            "$($item.Label)  -  $($item.Description)"
        }

    if ($idx -lt 0) { return $null }
    return [string]$items[$idx].Key
}

function Select-LlamaCppPostTuneProfile {
    param([Parameter(Mandatory = $true)][object[]]$Results)

    $items = @($Results | Where-Object { $_ } | ForEach-Object {
        $profileName = if ($_.Profile) { [string]$_.Profile } else { 'pure' }
        [pscustomobject]@{
            Key = $profileName
            Label = if ($profileName -eq 'balanced') { 'Balanced' } else { 'Pure' }
            Description = "score=$($_.Score) $($_.ScoreUnit)"
        }
    })
    if ($items.Count -le 1) {
        return $(if ($items.Count -eq 1) { [string]$items[0].Key } else { 'auto' })
    }

    $idx = Read-LLMChoiceIndex `
        -Title "Launch profile" `
        -Items $items `
        -ZeroLabel "Back" `
        -Label {
            param($item, $i)
            "$($item.Label)  -  $($item.Description)"
        }

    if ($idx -lt 0) { return $null }
    return [string]$items[$idx].Key
}

function Invoke-LLMSelection {
    param(
        [Parameter(Mandatory = $true)][string]$ModelKey,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$Backend = 'ollama',
        [string]$LlamaCppMode,
        [string]$KvCacheK,
        [string]$KvCacheV,
        [switch]$UseQ8,
        [switch]$Strict,
        [switch]$UseVision,
        [switch]$UseAutoBest,
        [ValidateSet('auto','pure','balanced','short','long')][string]$AutoBestProfile = 'auto',
        [switch]$UseSpectrePrompts,
        [switch]$DryRun
    )

  if ($Backend -eq 'llamacpp') {
        $def = Get-ModelDef -Key $ModelKey

        switch ($Action) {
            "claude" {
                Invoke-Backend -Action launch-claude -Backend llamacpp `
                    -Key $ModelKey -ContextKey $ContextKey `
                    -LlamaCppMode $LlamaCppMode -KvCacheK $KvCacheK -KvCacheV $KvCacheV `
                    -LimitTools:([bool]$def.LimitTools) -Strict:$Strict -UseVision:$UseVision -AutoBest:$UseAutoBest -AutoBestProfile $AutoBestProfile -DryRun:$DryRun
            }

            "codex" {
                Start-ClaudeWithLlamaCppModel `
                    -Key $ModelKey -ContextKey $ContextKey -Mode $LlamaCppMode `
                    -KvCacheK $KvCacheK -KvCacheV $KvCacheV `
                    -LimitTools:([bool]$def.LimitTools) -Strict:$Strict -UseVision:$UseVision -AutoBest:$UseAutoBest -AutoBestProfile $AutoBestProfile -Codex -DryRun:$DryRun
            }

            "unshackled" {
                Invoke-Backend -Action launch-claude -Backend llamacpp `
                    -Key $ModelKey -ContextKey $ContextKey `
                    -LlamaCppMode $LlamaCppMode -KvCacheK $KvCacheK -KvCacheV $KvCacheV `
                    -LimitTools:([bool]$def.LimitTools) -Unshackled -Strict:$Strict -UseVision:$UseVision -AutoBest:$UseAutoBest -AutoBestProfile $AutoBestProfile -DryRun:$DryRun
            }

            "setup" {
                # Strict has no effect on the GGUF path — same file regardless.
                $path = Get-ModelGgufPath -Key $ModelKey -Def $def -Backend llamacpp
                Write-Host "GGUF cached at: $path" -ForegroundColor Green
            }

            "findbest" {
                Invoke-LlamaCppTunerWizardFlow -ModelKey $ModelKey -ContextKey $ContextKey -Mode $LlamaCppMode -UseSpectrePrompts:$UseSpectrePrompts
            }

            "resetbest" {
                Invoke-LlamaCppBestResetWizardFlow -ModelKey $ModelKey -ContextKey $ContextKey -Mode $LlamaCppMode -UseSpectrePrompts:$UseSpectrePrompts
            }

            default {
                throw "Action '$Action' is not supported on the llama.cpp backend."
            }
        }
        return
    }

    # Ollama backend.
    switch ($Action) {
        "chat" {
            Invoke-ModelShortcut -Key $ModelKey -ContextKey $ContextKey -Chat -UseQ8:$UseQ8 -Strict:$Strict -DryRun:$DryRun -UseVision:$UseVision
        }

        "unshackled" {
            Invoke-ModelShortcut -Key $ModelKey -ContextKey $ContextKey -Unshackled -UseQ8:$UseQ8 -Strict:$Strict -DryRun:$DryRun -UseVision:$UseVision
        }

        "codex" {
            Invoke-ModelShortcut -Key $ModelKey -ContextKey $ContextKey -Codex -UseQ8:$UseQ8 -Strict:$Strict -DryRun:$DryRun -UseVision:$UseVision
        }

        "claude" {
            Invoke-ModelShortcut -Key $ModelKey -ContextKey $ContextKey -UseQ8:$UseQ8 -Strict:$Strict -DryRun:$DryRun -UseVision:$UseVision
        }

        "benchmark" {
            $defBenchmark = Get-ModelDef -Key $ModelKey
            $visionBM = if ($UseVision) { Get-ModelVisionModulePath -Key $ModelKey -Def $defBenchmark -Backend ollama } else { '' }
            $modelName = if ($Strict) { Ensure-ModelStrictAlias -Key $ModelKey } else { Ensure-ModelAlias -Key $ModelKey -ContextKey $ContextKey -VisionModulePath $(if ($visionBM) { $visionBM } else { '' }) }
            Test-OllamaSpeed -Model $modelName -Runs 3
        }

        "setup" {
            $defSetup = Get-ModelDef -Key $ModelKey
            $visionSetup = if ($UseVision) { Get-ModelVisionModulePath -Key $ModelKey -Def $defSetup -Backend ollama } else { '' }
            $modelName = if ($Strict) { Ensure-ModelStrictAlias -Key $ModelKey -ForceRebuild } else { Ensure-ModelAlias -Key $ModelKey -ContextKey $ContextKey -ForceRebuild -VisionModulePath $(if ($visionSetup) { $visionSetup } else { '' }) }
            Write-Host "Created/rebuilt alias: $modelName" -ForegroundColor Green
        }

        "show" {
            $defShow = Get-ModelDef -Key $ModelKey
            $visionShow = if ($UseVision) { Get-ModelVisionModulePath -Key $ModelKey -Def $defShow -Backend ollama } else { '' }
            $modelName = if ($Strict) { Ensure-ModelStrictAlias -Key $ModelKey } else { Ensure-ModelAlias -Key $ModelKey -ContextKey $ContextKey -VisionModulePath $(if ($visionShow) { $visionShow } else { '' }) }
            & ollama show $modelName
        }

        default {
            throw "Unknown action: $Action"
        }
    }
}

function Start-LLMWizardClassic {
    [CmdletBinding()]
    param(
        [switch]$UseVision
    )

    $modelKey     = $null
    $contextKey   = $null
    $action       = $null
    $useQ8        = $false
    $useStrict    = $false
    $useVisionFlag = [bool]$UseVision
    $backend      = 'ollama'
    $llamaCppMode = $null
    $kvK          = $null
    $kvV          = $null
    $useAutoBest  = $false
    $autoBestProfile = 'auto'
    $saveAsDefault = $false
    $step         = 'model'

    while ($true) {
        switch ($step) {
            'model' {
                Clear-Host
                Write-Host "LocalBox" -ForegroundColor Green
                Write-Host "Config: $script:LocalLLMConfigPath" -ForegroundColor DarkGray

                $modelKey = Select-LLMModelKey
                if ([string]::IsNullOrWhiteSpace($modelKey)) { return }

                $useStrict = $false
                $useAutoBest = $false
                $autoBestProfile = 'auto'
                $saveAsDefault = $false
                $useVisionFlag = $false
                $step = 'quant'
            }

            'quant' {
                $def = Get-ModelDef -Key $modelKey
                if (-not $def.ContainsKey("Quants")) { $step = 'backend'; break }

                $quantKey = Select-LLMQuantKey -ModelKey $modelKey
                if ($null -eq $quantKey)        { $step = 'model';   break }   # back
                if ($quantKey -eq '__keep__')   { $step = 'backend'; break }
                Set-ModelQuantForSelectedLaunch -ModelKey $modelKey -QuantKey $quantKey
                $step = 'backend'
            }

            'backend' {
                $def = Get-ModelDef -Key $modelKey
                $picked = Select-LLMBackend -Def $def
                if ($null -eq $picked) {
                    $step = if ($def.ContainsKey("Quants")) { 'quant' } else { 'model' }
                    break
                }
                switch ($picked) {
                    'ollama'              { $backend = 'ollama';   $llamaCppMode = $null }
                    'llamacpp-native'     { $backend = 'llamacpp'; $llamaCppMode = 'native' }
                    'llamacpp-turboquant' { $backend = 'llamacpp'; $llamaCppMode = 'turboquant' }
                }

                # Check if this model has vision support: configured VisionModule, local mmproj file, or HF available.
                $visionAvail = Test-ModelVisionModuleAvailable -Key $modelKey -Def $def -Backend $backend
                $hasVision = $visionAvail.Local -or $visionAvail.AvailableOnHF
                if (-not $hasVision) {
                    $step = if (Get-ModelStrictEnabled -Def $def) { 'strict' } else { 'context' }
                } elseif ($useVisionFlag) {
                    # Pre-set by -UseVision flag; skip vision prompt.
                    $step = if (Get-ModelStrictEnabled -Def $def) { 'strict' } else { 'context' }
                } else {
                    $step = 'vision'
                }
            }

            'vision' {
                # Re-check availability after potential download from previous step
                if (-not $visionAvail) {
                    $visionAvail = Test-ModelVisionModuleAvailable -Key $modelKey -Def $def -Backend $backend
                }
                if (-not $visionAvail.Local -and $visionAvail.AvailableOnHF) {
                    Write-Host "Downloading vision module '$($visionAvail.Filename)' from HuggingFace..." -ForegroundColor Yellow
                    try {
                        $visionFolder = Get-ModelFolder -Key $modelKey -Def $def -Backend $backend
                        Download-HuggingFaceFile -Repo $def.Repo -FileName $visionAvail.Filename -DestinationFolder $visionFolder | Out-Null
                        Write-Host "Downloaded '$($visionAvail.Filename)'." -ForegroundColor Green
                        $visionAvail.Local = $true
                    } catch {
                        Write-Warning "Failed to download vision module: $_"
                    }
                }
                $useVision = Read-LLMVisionToggle
                if ($null -eq $useVision) { $step = 'backend'; break }   # back
                $useVisionFlag = [bool]$useVision
                $step = if (Get-ModelStrictEnabled -Def $def) { 'strict' } else { 'context' }
            }

            'strict' {
                $strict = Read-LLMStrictToggle
                if ($null -eq $strict) { $step = 'backend'; break }   # back
                $useStrict = [bool]$strict

                if ($useStrict) {
                    # Strict pins context to Get-ModelStrictBaseContextKey via the
                    # alias build; the empty contextKey is correct here because the
                    # shortcut layer rejects -Strict + -Ctx together.
                    $contextKey = ""
                    $step = 'action'
                } else {
                    $step = 'context'
                }
            }

            'context' {
                $contextKey = Select-LLMContextKey -ModelKey $modelKey
                if ($null -eq $contextKey) {
                    $def = Get-ModelDef -Key $modelKey
                    $step = if (Get-ModelStrictEnabled -Def $def) { 'strict' } else { 'backend' }
                    break
                }
                $step = 'action'
            }

            'action' {
                $action = Select-LLMAction -Backend $backend
                if ([string]::IsNullOrWhiteSpace($action)) {
                    $step = if ($useStrict) { 'strict' } else { 'context' }
                    break
                }

                if ($action -eq "setdefault") {
                    $target = Select-LLMDefaultTarget -Backend $backend
                    if ([string]::IsNullOrWhiteSpace($target)) {
                        $step = 'action'
                        break
                    }
                    $action = $target
                    $saveAsDefault = $true
                } else {
                    $saveAsDefault = $false
                }

                if ($action -in @("chat", "unshackled", "claude", "codex")) {
                    if ($backend -eq 'llamacpp') {
                        $step = if (Test-LlamaCppWizardAutoBestAvailable -ModelKey $modelKey -ContextKey $contextKey -Mode $llamaCppMode) { 'llamacppsettings' } else { 'kvcache' }
                    } else {
                        $step = 'q8'
                    }
                } else {
                    $useAutoBest = $false
                    $autoBestProfile = 'auto'
                    $step = 'launch'
                }
            }

            'llamacppsettings' {
                $modeChoice = Select-LlamaCppLaunchSettingsMode -ModelKey $modelKey -ContextKey $contextKey -Mode $llamaCppMode
                if ($null -eq $modeChoice) { $step = 'action'; break }
                if ($modeChoice -like 'best:*') {
                    $kvK = $null
                    $kvV = $null
                    $useAutoBest = $true
                    $autoBestProfile = [string]($modeChoice -replace '^best:', '')
                    if ([string]::IsNullOrWhiteSpace($autoBestProfile)) { $autoBestProfile = 'auto' }
                    $step = 'launch'
                    break
                }

                $useAutoBest = $false
                $autoBestProfile = 'auto'
                $step = 'kvcache'
            }

            'q8' {
                $q8 = Read-LLMQ8Toggle
                if ($null -eq $q8) { $step = 'action'; break }   # back
                $useQ8 = [bool]$q8
                $step = 'launch'
            }

            'kvcache' {
                $picked = Select-LLMKvCache -Mode $llamaCppMode
                if ($null -eq $picked) { $step = 'action'; break }
                $kvK = $picked.K
                $kvV = $picked.V
                $useAutoBest = $false
                $autoBestProfile = 'auto'
                $step = 'launch'
            }

            'launch' {
                try {
                    if ($saveAsDefault) {
                        Save-LLMDefaultLaunch -ModelKey $modelKey -ContextKey $contextKey -Action $action `
                            -Backend $backend -LlamaCppMode $llamaCppMode `
                            -KvCacheK $kvK -KvCacheV $kvV -UseQ8:$useQ8 -Strict:$useStrict `
                            -UseAutoBest:$useAutoBest -AutoBestProfile $autoBestProfile
                        Pause-Menu
                    } else {
                        Invoke-LLMSelection -ModelKey $modelKey -ContextKey $contextKey -Action $action `
                            -Backend $backend -LlamaCppMode $llamaCppMode `
                            -KvCacheK $kvK -KvCacheV $kvV -UseQ8:$useQ8 -Strict:$useStrict -UseVision:$useVisionFlag -UseAutoBest:$useAutoBest -AutoBestProfile $autoBestProfile
                    }
                }
                catch {
                    Write-Host "Command failed." -ForegroundColor Red
                    Write-Host $_.Exception.Message -ForegroundColor DarkGray
                    Pause-Menu
                }
                $saveAsDefault = $false
                $step = 'model'
            }
        }
    }
}

# Spectre wizard
# Mirrors Start-LLMWizardClassic but uses PwshSpectreConsole's selection prompts.
# Gated on Test-LocalLLMSpectreAvailable (same env switch as the dashboard:
# $env:LOCAL_LLM_NO_SPECTRE=1 forces the classic wizard even when Spectre is installed).

function Show-LLMWizardHeaderSpectre {
    Format-SpectrePanel -Header "LocalBox" -Color Green -Data ("[grey50]Config:[/] {0}" -f (ConvertTo-LocalLLMSpectreSafe $script:LocalLLMConfigPath)) | Out-Host
}

function Select-LLMModelKeySpectre {
    param([switch]$All)

    $keys = @(Get-FilteredModelKeys -IncludeAll:$All)

    # Same fresh-catalog fallback as the classic wizard: skip straight to
    # all-tiers when no recommended model exists yet.
    if ($keys.Count -eq 0 -and -not $All) {
        $keys = @(Get-FilteredModelKeys -IncludeAll)
        if ($keys.Count -gt 0) {
            return (Select-LLMModelKeySpectre -All)
        }
    }

    if ($keys.Count -eq 0) {
        Write-Host "No models configured. Use 'addllm <hf-url> -Key <key>' to add one." -ForegroundColor Yellow
        return $null
    }

    Show-ModelCatalogSpectre -All:$All

    $labelMap = [ordered]@{}
    foreach ($key in $keys) {
        $def = Get-ModelDef -Key $key
        $strictBadge = if (Get-ModelStrictEnabled -Def $def) { '  [grey50][[strict]][/]' } else { '' }
        $label = "{0}  ·  {1}{2}" -f (ConvertTo-LocalLLMSpectreSafe $key), (ConvertTo-LocalLLMSpectreSafe $def.DisplayName), $strictBadge
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
    # Returns: a quant key (chosen), '__keep__' (keep current), or $null (back).
    param([Parameter(Mandatory = $true)][string]$ModelKey)

    $def = Get-ModelDef -Key $ModelKey
    if (-not $def.ContainsKey("Quants")) { return '__keep__' }

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
    $labelMap["[[Back]]"] = '__back__'

    $modelKeySafe = ConvertTo-LocalLLMSpectreSafe $ModelKey
    $chosen = Read-SpectreSelection -Message "Select quant for $modelKeySafe" -Choices @($labelMap.Keys) -PageSize 12
    if ($null -eq $chosen) { return $null }
    $value = $labelMap[$chosen]

    if ($value -eq '__back__') { return $null }
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
    param([string]$Backend = 'ollama')

    $labelMap = if ($Backend -eq 'llamacpp') {
        [ordered]@{
            "Claude Code  -  Local model behind Claude Code" = 'claude'
            "Codex       -  Local model behind OpenAI Codex"  = 'codex'
            "Unshackled   -  Local agent via Unshackled"     = 'unshackled'
            "Set llmdefault - Save this model/profile/target" = 'setdefault'
            "Find best settings - Auto-tune for this machine" = 'findbest'
            "Delete best settings - Reset saved AutoBest config" = 'resetbest'
            "Setup only   -  Download GGUF without launching" = 'setup'
            "[[Back]]"                                       = '__back__'
        }
    } else {
        [ordered]@{
            "Claude Code  -  Local model behind Claude Code" = 'claude'
            "Codex       -  Local model behind OpenAI Codex"  = 'codex'
            "Unshackled   -  Local agent via Unshackled"     = 'unshackled'
            "Ollama chat  -  Plain ollama run"               = 'chat'
            "Set llmdefault - Save this model/profile/target" = 'setdefault'
            "Benchmark    -  Run ospeed for selected alias"  = 'benchmark'
            "Setup only   -  (Re)build alias"                = 'setup'
            "Show         -  Run ollama show"                = 'show'
            "[[Back]]"                                       = '__back__'
        }
    }

    $chosen = Read-SpectreSelection -Message "Select action" -Choices @($labelMap.Keys) -PageSize 10
    if ($null -eq $chosen) { return $null }
    $value = $labelMap[$chosen]

    if ($value -eq '__back__') { return $null }
    return $value
}

function Select-LLMDefaultTargetSpectre {
    param([string]$Backend = 'ollama')

    $labelMap = if ($Backend -eq 'llamacpp') {
        [ordered]@{
            "Claude Code  -  Local model behind Claude Code" = 'claude'
            "Codex       -  Local model behind OpenAI Codex"  = 'codex'
            "Unshackled   -  Local agent via Unshackled"     = 'unshackled'
            "[[Back]]"                                      = '__back__'
        }
    } else {
        [ordered]@{
            "Claude Code  -  Local model behind Claude Code" = 'claude'
            "Codex       -  Local model behind OpenAI Codex"  = 'codex'
            "Unshackled   -  Local agent via Unshackled"     = 'unshackled'
            "Ollama chat  -  Plain ollama run"               = 'chat'
            "[[Back]]"                                      = '__back__'
        }
    }

    $chosen = Read-SpectreSelection -Message "llmdefault target" -Choices @($labelMap.Keys) -PageSize 7
    if ($null -eq $chosen) { return $null }
    $value = $labelMap[$chosen]

    if ($value -eq '__back__') { return $null }
    return $value
}

function Select-LlamaCppLaunchSettingsModeSpectre {
    param(
        [Parameter(Mandatory = $true)][string]$ModelKey,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][ValidateSet('native','turboquant')][string]$Mode
    )

    $bestChoices = @(Get-LlamaCppWizardAutoBestChoices -ModelKey $ModelKey -ContextKey $ContextKey -Mode $Mode)
    if ($bestChoices.Count -eq 0) {
        return 'manual'
    }

    $choices = [ordered]@{}
    foreach ($item in $bestChoices) {
        $label = ConvertTo-LocalLLMSpectreSafe ("{0,-13} -  {1}" -f $item.Label, $item.Description)
        $choices[$label] = $item.Key
    }
    if ($bestChoices.Count -gt 1) {
        $choices["Use AutoBest  -  Prefer balanced, then pure automatically"] = 'best:auto'
    }
    $choices["Manual settings -  Pick KV cache and launch settings now"] = 'manual'
    $choices["[[Back]]"] = '__back__'

    $chosen = Read-SpectreSelection -Message "Launch settings" -Choices @($choices.Keys) -PageSize 5
    if ($null -eq $chosen) { return $null }
    if ($chosen -eq '[[Back]]') { return $null }
    return [string]$choices[$chosen]
}

function Select-LlamaCppPostTuneLaunchActionSpectre {
    $choices = [ordered]@{
        "Claude Code  -  Local model behind Claude Code" = 'claude'
        "Codex       -  Local model behind OpenAI Codex"  = 'codex'
        "Unshackled   -  Local agent via Unshackled"     = 'unshackled'
        "[[Cancel]]"                                    = '__cancel__'
    }

    $chosen = Read-SpectreSelection -Message "Launch target" -Choices @($choices.Keys) -PageSize 5
    if ($null -eq $chosen) { return $null }
    if ($chosen -eq '[[Cancel]]') { return $null }
    return [string]$choices[$chosen]
}

function Select-LlamaCppPostTuneProfileSpectre {
    param([Parameter(Mandatory = $true)][object[]]$Results)

    $items = @($Results | Where-Object { $_ })
    if ($items.Count -le 1) {
        if ($items.Count -eq 1) {
            return $(if ($items[0].Profile) { [string]$items[0].Profile } else { 'pure' })
        }
        return 'auto'
    }

    $choices = [ordered]@{}
    foreach ($item in $items) {
        $profileName = if ($item.Profile) { [string]$item.Profile } else { 'pure' }
        $label = if ($profileName -eq 'balanced') { 'Balanced' } else { 'Pure' }
        $choices[(ConvertTo-LocalLLMSpectreSafe ("{0,-8} -  score={1} {2}" -f $label, $item.Score, $item.ScoreUnit))] = $profileName
    }
    $choices["[[Cancel]]"] = '__cancel__'

    $chosen = Read-SpectreSelection -Message "Launch profile" -Choices @($choices.Keys) -PageSize 5
    if ($null -eq $chosen) { return $null }
    if ($choices[$chosen] -eq '__cancel__') { return $null }
    return [string]$choices[$chosen]
}

function Select-LLMBackendSpectre {
    # Returns 'ollama', 'llamacpp-native', 'llamacpp-turboquant', or $null (back).
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def)

    if (-not (Test-LlamaCppEligible -Def $Def)) {
        return 'ollama'
    }

    $labelMap = [ordered]@{
        "Ollama (default)                       -  Existing alias-based path"             = 'ollama'
        "llama.cpp native                       -  Upstream binary (mainline KV)"         = 'llamacpp-native'
        "llama.cpp turboquant (turbo3/turbo4 KV) -  Fork binary supporting turbo KV"      = 'llamacpp-turboquant'
        "[[Back]]"                                                                        = '__back__'
    }

    $chosen = Read-SpectreSelection -Message "Select backend" -Choices @($labelMap.Keys) -PageSize 6
    if ($null -eq $chosen) { return $null }
    $value = $labelMap[$chosen]

    if ($value -eq '__back__') { return $null }
    return $value
}

function Select-LLMKvCacheSpectre {
    # Returns @{ K; V } or $null (back).
    param([Parameter(Mandatory = $true)][string]$Mode)

    $choices = Get-LlamaCppKvCacheChoices -Mode $Mode

    $labelMap = [ordered]@{}
    foreach ($t in $choices) {
        $note = switch ($t) {
            'q8_0'   { 'q8_0   -  default; fast and memory-efficient' }
            'f16'    { 'f16    -  full quality, ~2x KV memory of q8_0' }
            'q5_1'   { 'q5_1   -  slightly smaller than q8_0' }
            'q5_0'   { 'q5_0   -  smaller still' }
            'q4_1'   { 'q4_1   -  aggressive; quality risk on long context' }
            'q4_0'   { 'q4_0   -  most aggressive mainline' }
            'iq4_nl' { 'iq4_nl -  newer 4-bit non-linear' }
            'bf16'   { 'bf16   -  full precision (where supported)' }
            'f32'    { 'f32    -  pristine; rarely needed' }
            'turbo3' { 'turbo3 -  turboquant fork only (docker)' }
            'turbo4' { 'turbo4 -  turboquant fork only (docker), most aggressive' }
            default  { $t }
        }
        $labelMap[$note] = $t
    }
    $labelMap["[[Back]]"] = '__back__'

    $chosen = Read-SpectreSelection -Message "Select KV cache type ($Mode)" -Choices @($labelMap.Keys) -PageSize 12
    if ($null -eq $chosen) { return $null }
    $value = $labelMap[$chosen]

    if ($value -eq '__back__') { return $null }
    return @{ K = $value; V = $value }
}

function Read-LLMVisionToggleSpectre {
    # Returns $true (vision on), $false (vision off), or $null (back).
    $choices = [ordered]@{
        'No   -  launch without vision support'            = $false
        'Yes  -  load multimodal module (mmproj.gguf)'     = $true
        '[[Back]]'                                         = '__back__'
    }
    $chosen = Read-SpectreSelection -Message "Use vision (multimodal)?" -Choices @($choices.Keys) -PageSize 5
    if ($null -eq $chosen) { return $null }
    if ($chosen -eq '[[Back]]') { return $null }
    return [bool]$choices[$chosen]
}

function Read-LLMQ8ToggleSpectre {
    # Returns $true (q8 on), $false (q8 off), or $null (back).
    # Important: check the label string for back BEFORE looking up the boolean
    # value. PowerShell's `-eq` coerces the right operand to the left's type;
    # `$true -eq '__back__'` evaluates to $true (non-empty string -> $true),
    # so a value-side back check would falsely fire on the Yes branch.
    $choices = [ordered]@{
        'No  -  default'    = $false
        'Yes -  q8 KV cache' = $true
        '[[Back]]'          = '__back__'
    }
    $chosen = Read-SpectreSelection -Message "Use q8 KV cache?" -Choices @($choices.Keys) -PageSize 5
    if ($null -eq $chosen) { return $null }
    if ($chosen -eq '[[Back]]') { return $null }
    return [bool]$choices[$chosen]
}

function Read-LLMStrictToggleSpectre {
    # Returns $true (strict on), $false (strict off), or $null (back).
    # See Read-LLMQ8ToggleSpectre for why the back check is on $chosen, not
    # on the looked-up value.
    $choices = [ordered]@{
        'No  -  base alias, normal context selection'                 = $false
        'Yes -  <root>-strict alias (overlay prompt, pinned context)' = $true
        '[[Back]]'                                                    = '__back__'
    }
    $chosen = Read-SpectreSelection -Message "Use strict mode? (skips context selection when on)" -Choices @($choices.Keys) -PageSize 5
    if ($null -eq $chosen) { return $null }
    if ($chosen -eq '[[Back]]') { return $null }
    return [bool]$choices[$chosen]
}

function Read-LLMYesNoSpectre {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [switch]$DefaultYes
    )

    $choices = if ($DefaultYes) {
        [ordered]@{
            'Yes' = $true
            'No'  = $false
        }
    } else {
        [ordered]@{
            'No'  = $false
            'Yes' = $true
        }
    }

    $chosen = Read-SpectreSelection -Message $Message -Choices @($choices.Keys) -PageSize 4
    if ($null -eq $chosen) { return [bool]$DefaultYes }
    return [bool]$choices[$chosen]
}

function Read-LLMTuneKvVariationSpectre {
    param([Parameter(Mandatory = $true)][string]$Mode)

    $choices = [ordered]@{
        'No    -  keep current KV type only'      = 'no'
        'Yes   -  widen within the quality class' = 'yes'
    }
    if ($Mode -eq 'turboquant') {
        $choices['Turbo -  test turbo3 and turbo4 only'] = 'turbo-only'
    }
    $chosen = Read-SpectreSelection -Message "Allow KV cache variation? Widens the search to other types in your quality class." -Choices @($choices.Keys) -PageSize 4
    if ($null -eq $chosen) { return 'no' }
    return [string]$choices[$chosen]
}

function Read-LLMTuneDepthSpectre {
    $choices = [ordered]@{
        'Normal - default tuner pass'                 = 'normal'
        'Deep   - add finer local refinement'         = 'deep'
        '[[Back]]'                                    = '__back__'
    }
    $chosen = Read-SpectreSelection -Message "Tune depth" -Choices @($choices.Keys) -PageSize 5
    if ($null -eq $chosen) { return $null }
    if ($chosen -eq '[[Back]]') { return $null }
    return [string]$choices[$chosen]
}

function Read-LLMTuneBudgetSpectre {
    $choices = [ordered]@{
        '100    -  default, standard for all models'     = 100
        '150    -  extended, MoE with moderate option set' = 150
        '200    -  high, MoE with wide option set'       = 200
        'Custom -  enter a custom value'                 = 'custom'
        '[[Back]]'                                       = '__back__'
    }
    $chosen = Read-SpectreSelection -Message "Budget (max benchmarks per run)" -Choices @($choices.Keys) -PageSize 6
    if ($null -eq $chosen) { return 100 }
    if ($chosen -eq '[[Back]]') { return $null }
    $val = $choices[$chosen]
    if ($val -eq 'custom') {
        $raw = Read-Host "Budget (integer, e.g. 120)"
        if ($raw -match '^\d+$' -and [int]$raw -gt 0) { return [int]$raw }
        Write-Warning "Invalid value. Using default 100."
        return 100
    }
    return [int]$val
}

function Read-LLMTuneOptimizeSpectre {
    $choices = [ordered]@{
        'Coding agent - long-prompt end-to-end latency'                = 'coding-agent'
        'Balanced   - prompt/prefill and generation throughput'       = 'both'
        'Prefill    - prioritize first-token latency on large prompts' = 'prompt'
        'Generation - prioritize tokens/sec after generation starts'   = 'gen'
        '[[Back]]'                                                     = '__back__'
    }
    $chosen = Read-SpectreSelection -Message "Tune goal" -Choices @($choices.Keys) -PageSize 7
    if ($null -eq $chosen) { return $null }
    if ($chosen -eq '[[Back]]') { return $null }
    return [string]$choices[$chosen]
}

function Read-LLMTuneProfileSpectre {
    $choices = [ordered]@{
        'Pure   - fastest measured LLM throughput'      = 'pure'
        'Usable - keep workstation headroom'            = 'balanced'
        'Both   - run and save pure plus usable'        = 'both'
        '[[Back]]'                                      = '__back__'
    }
    $chosen = Read-SpectreSelection -Message "Selection profile" -Choices @($choices.Keys) -PageSize 6
    if ($null -eq $chosen) { return $null }
    if ($chosen -eq '[[Back]]') { return $null }
    return [string]$choices[$chosen]
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
        [object]$Default = $null,
        [int]$RetryDelayMs = 0,
        [switch]$RetryOnceOnNull
    )

    $attempts = if ($RetryOnceOnNull) { 2 } else { 1 }
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        if ($attempt -gt 1 -and $RetryDelayMs -gt 0) {
            Start-Sleep -Milliseconds $RetryDelayMs
        }

        $started = Get-Date
        try {
            $result = & $Action
            $elapsedMs = [int](((Get-Date) - $started).TotalMilliseconds)
            $fastNull = ($null -eq $result -and $RetryOnceOnNull -and $RetryDelayMs -gt 0 -and $elapsedMs -lt $RetryDelayMs)
            if ($null -ne $result -or -not $fastNull -or $attempt -ge $attempts) {
                return $result
            }
        }
        catch {
            Save-LocalLLMWizardError -ErrorRecord $_ -Context $Context
            if ($RetryOnceOnNull -and $attempt -lt $attempts) {
                if ($RetryDelayMs -gt 0) { Start-Sleep -Milliseconds $RetryDelayMs }
                continue
            }
            Pause-Menu
            return $Default
        }
    }

    return $Default
}

function Get-LLMSpectrePromptCooldownMs {
    $raw = $env:LOCAL_LLM_SPECTRE_PROMPT_COOLDOWN_MS
    if ([string]::IsNullOrWhiteSpace($raw)) { return 500 }

    try {
        $value = [int]$raw
        if ($value -lt 0) { return 0 }
        if ($value -gt 5000) { return 5000 }
        return $value
    }
    catch {
        return 500
    }
}

function Invoke-LLMSpectreTransitionCooldown {
    param([string]$Message = 'Preparing next menu')

    $ms = Get-LLMSpectrePromptCooldownMs
    if ($ms -le 0) { return }

    Write-Host ("{0}..." -f $Message) -ForegroundColor DarkGray
    Start-Sleep -Milliseconds $ms
}

function Start-LLMWizardSpectre {
    [CmdletBinding()]
    param(
        [switch]$UseVision
    )

    $modelKey     = $null
    $contextKey   = $null
    $action       = $null
    $useQ8        = $false
    $useStrict    = $false
    $useVisionFlag = [bool]$UseVision
    $backend      = 'ollama'
    $llamaCppMode = $null
    $kvK          = $null
    $kvV          = $null
    $useAutoBest  = $false
    $autoBestProfile = 'auto'
    $saveAsDefault = $false
    $step         = 'model'

    while ($true) {
        switch ($step) {
            'model' {
                Clear-Host
                Show-LLMWizardHeaderSpectre

                $modelKey = Invoke-LLMWizardStep -Context 'select-model' -Action {
                    Select-LLMModelKeySpectre
                }
                if ([string]::IsNullOrWhiteSpace($modelKey)) { return }

                $useStrict = $false
                $useAutoBest = $false
                $autoBestProfile = 'auto'
                $saveAsDefault = $false
                Invoke-LLMSpectreTransitionCooldown -Message 'Model selected'
                $step = 'quant'
            }

            'quant' {
                $def = Get-ModelDef -Key $modelKey
                if (-not $def.ContainsKey("Quants")) { $step = 'backend'; break }

                $quantKey = Invoke-LLMWizardStep -Context "select-quant ($modelKey)" -Action {
                    Select-LLMQuantKeySpectre -ModelKey $modelKey
                } -RetryOnceOnNull -RetryDelayMs (Get-LLMSpectrePromptCooldownMs)
                if ($null -eq $quantKey)      { $step = 'model';   break }   # back
                if ($quantKey -eq '__keep__') { $step = 'backend'; break }
                try {
                    Set-ModelQuantForSelectedLaunch -ModelKey $modelKey -QuantKey $quantKey
                }
                catch {
                    Save-LocalLLMWizardError -ErrorRecord $_ -Context "set-quant ($modelKey -> $quantKey)"
                    Pause-Menu
                    $step = 'quant'
                    break
                }
                $step = 'backend'
            }

            'backend' {
                $def = Get-ModelDef -Key $modelKey
                $picked = Invoke-LLMWizardStep -Context "select-backend ($modelKey)" -Action {
                    Select-LLMBackendSpectre -Def $def
                } -RetryOnceOnNull -RetryDelayMs (Get-LLMSpectrePromptCooldownMs)
                if ($null -eq $picked) {
                    $step = if ($def.ContainsKey("Quants")) { 'quant' } else { 'model' }
                    break
                }
                switch ($picked) {
                    'ollama'              { $backend = 'ollama';   $llamaCppMode = $null }
                    'llamacpp-native'     { $backend = 'llamacpp'; $llamaCppMode = 'native' }
                    'llamacpp-turboquant' { $backend = 'llamacpp'; $llamaCppMode = 'turboquant' }
                }
                # Check if this model has vision support: configured VisionModule, local mmproj file, or HF available.
                $visionAvail = Test-ModelVisionModuleAvailable -Key $modelKey -Def $def -Backend $backend
                $hasVision = $visionAvail.Local -or $visionAvail.AvailableOnHF
                if (-not $hasVision) {
                    $step = if (Get-ModelStrictEnabled -Def $def) { 'strict' } else { 'context' }
                } elseif ($useVisionFlag) {
                    # Pre-set by -UseVision flag; skip vision prompt.
                    $step = if (Get-ModelStrictEnabled -Def $def) { 'strict' } else { 'context' }
                } else {
                    $step = 'vision'
                }
            }

            'vision' {
                # Re-check availability after potential download from previous step
                if (-not $visionAvail) {
                    $visionAvail = Test-ModelVisionModuleAvailable -Key $modelKey -Def $def -Backend $backend
                }
                if (-not $visionAvail.Local -and $visionAvail.AvailableOnHF) {
                    Write-Host "Downloading vision module '$($visionAvail.Filename)' from HuggingFace..." -ForegroundColor Yellow
                    try {
                        $visionFolder = Get-ModelFolder -Key $modelKey -Def $def -Backend $backend
                        Download-HuggingFaceFile -Repo $def.Repo -FileName $visionAvail.Filename -DestinationFolder $visionFolder | Out-Null
                        Write-Host "Downloaded '$($visionAvail.Filename)'." -ForegroundColor Green
                        $visionAvail.Local = $true
                    } catch {
                        Write-Warning "Failed to download vision module: $_"
                    }
                }
                $capturedBackend = $backend
                $useVision = Invoke-LLMWizardStep -Context 'vision-toggle' -Default $null -Action {
                    Read-LLMVisionToggleSpectre
                }
                if ($null -eq $useVision) { $step = 'backend'; break }
                $useVisionFlag = [bool]$useVision
                $step = if (Get-ModelStrictEnabled -Def $def) { 'strict' } else { 'context' }
            }

            'strict' {
                $strict = Invoke-LLMWizardStep -Context "strict-toggle ($modelKey)" -Default $null -Action {
                    Read-LLMStrictToggleSpectre
                }
                if ($null -eq $strict) { $step = 'backend'; break }
                $useStrict = [bool]$strict

                if ($useStrict) {
                    $contextKey = ""
                    $step = 'action'
                } else {
                    $step = 'context'
                }
            }

            'context' {
                $contextKey = Invoke-LLMWizardStep -Context "select-context ($modelKey)" -Action {
                    Select-LLMContextKeySpectre -ModelKey $modelKey
                }
                if ($null -eq $contextKey) {
                    $def = Get-ModelDef -Key $modelKey
                    $step = if (Get-ModelStrictEnabled -Def $def) { 'strict' } else { 'backend' }
                    break
                }
                $step = 'action'
            }

            'action' {
                $captured = $backend
                $action = Invoke-LLMWizardStep -Context 'select-action' -Action {
                    Select-LLMActionSpectre -Backend $captured
                }
                if ([string]::IsNullOrWhiteSpace($action)) {
                    $step = if ($useStrict) { 'strict' } else { 'context' }
                    break
                }

                if ($action -eq "setdefault") {
                    $capturedBackend = $backend
                    $target = Invoke-LLMWizardStep -Context 'llmdefault-target' -Action {
                        Select-LLMDefaultTargetSpectre -Backend $capturedBackend
                    }
                    if ([string]::IsNullOrWhiteSpace($target)) {
                        $step = 'action'
                        break
                    }
                    $action = $target
                    $saveAsDefault = $true
                } else {
                    $saveAsDefault = $false
                }

                if ($action -in @("chat", "unshackled", "claude", "codex")) {
                    if ($backend -eq 'llamacpp') {
                        $step = if (Test-LlamaCppWizardAutoBestAvailable -ModelKey $modelKey -ContextKey $contextKey -Mode $llamaCppMode) { 'llamacppsettings' } else { 'kvcache' }
                    } else {
                        $step = 'q8'
                    }
                } else {
                    $useAutoBest = $false
                    $autoBestProfile = 'auto'
                    $step = 'launch'
                }
            }

            'llamacppsettings' {
                $capturedModel = $modelKey
                $capturedContext = $contextKey
                $capturedMode = $llamaCppMode
                $modeChoice = Invoke-LLMWizardStep -Context "llamacpp-settings ($modelKey/$contextKey/$llamaCppMode)" -Default $null -Action {
                    Select-LlamaCppLaunchSettingsModeSpectre -ModelKey $capturedModel -ContextKey $capturedContext -Mode $capturedMode
                }
                if ($null -eq $modeChoice) { $step = 'action'; break }
                if ($modeChoice -like 'best:*') {
                    $kvK = $null
                    $kvV = $null
                    $useAutoBest = $true
                    $autoBestProfile = [string]($modeChoice -replace '^best:', '')
                    if ([string]::IsNullOrWhiteSpace($autoBestProfile)) { $autoBestProfile = 'auto' }
                    $step = 'launch'
                    break
                }

                $useAutoBest = $false
                $autoBestProfile = 'auto'
                $step = 'kvcache'
            }

            'q8' {
                $q8 = Invoke-LLMWizardStep -Context 'q8-toggle' -Default $null -Action {
                    Read-LLMQ8ToggleSpectre
                }
                if ($null -eq $q8) { $step = 'action'; break }   # back
                $useQ8 = [bool]$q8
                $step = 'launch'
            }

            'kvcache' {
                $captured = $llamaCppMode
                $picked = Invoke-LLMWizardStep -Context "kvcache ($llamaCppMode)" -Default $null -Action {
                    Select-LLMKvCacheSpectre -Mode $captured
                }
                if ($null -eq $picked) { $step = 'action'; break }
                $kvK = $picked.K
                $kvV = $picked.V
                $useAutoBest = $false
                $autoBestProfile = 'auto'
                $step = 'launch'
            }

            'launch' {
                try {
                    if ($saveAsDefault) {
                        Save-LLMDefaultLaunch -ModelKey $modelKey -ContextKey $contextKey -Action $action `
                            -Backend $backend -LlamaCppMode $llamaCppMode `
                            -KvCacheK $kvK -KvCacheV $kvV -UseQ8:$useQ8 -Strict:$useStrict `
                            -UseAutoBest:$useAutoBest -AutoBestProfile $autoBestProfile
                        Pause-Menu
                    } else {
                        Invoke-LLMSelection -ModelKey $modelKey -ContextKey $contextKey -Action $action `
                            -Backend $backend -LlamaCppMode $llamaCppMode `
                            -KvCacheK $kvK -KvCacheV $kvV -UseQ8:$useQ8 -Strict:$useStrict -UseVision:$useVisionFlag -UseAutoBest:$useAutoBest -AutoBestProfile $autoBestProfile -UseSpectrePrompts
                    }
                }
                catch {
                    Save-LocalLLMWizardError -ErrorRecord $_ -Context "invoke ($modelKey/$contextKey/$action/$backend/strict=$useStrict)"
                    Pause-Menu
                }
                $saveAsDefault = $false
                $step = 'model'
            }
        }
    }
}

function Get-LocalLLMLaunchLogPath {
    $dir = Join-Path $HOME ".local-llm"
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    return (Join-Path $dir "launch.log")
}

function Write-LaunchLog {
    # Appends a timestamped line to ~/.local-llm/launch.log for debugging
    # launch flows (vision, proxy, llama-server, claude). Follow with:
    #   Get-Content -Tail 50 -Wait (Join-Path $HOME '.local-llm' 'launch.log')
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'VISION', 'PROXY', 'SERVER', 'LAUNCH')][string]$Level = 'INFO'
    )

    $logPath = Get-LocalLLMLaunchLogPath
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$stamp] [$Level] $Message"

    try {
        Add-Content -LiteralPath $logPath -Value $line -ErrorAction Stop
    } catch {
        Write-Verbose "Failed to write launch log: $_"
    }
}

function llmlog {
    # Print the tail of ~/.local-llm/launch.log (launch debug trace).
    param([int]$Lines = 80)

    $logPath = Get-LocalLLMLaunchLogPath
    if (-not (Test-Path $logPath)) {
        Write-Host "No launch log yet ($logPath does not exist)." -ForegroundColor DarkGray
        return
    }

    Write-Host "Tail of $logPath (last $Lines lines):" -ForegroundColor Cyan
    Get-Content -LiteralPath $logPath -Tail $Lines
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

function Test-LocalLLMWizardSpectreEnabled {
    return (Test-LocalLLMSpectreAvailable)
}

function Start-LLMWizardSpectreExplicit {
    if (Test-LocalLLMSpectreAvailable) {
        Start-LLMWizardSpectre
        return
    }

    Write-Host "PwshSpectreConsole is unavailable or disabled; using the native picker." -ForegroundColor Yellow
    Start-LLMWizardClassic
}

function Start-LLMWizard {
    [CmdletBinding()]
    param(
        [switch]$UseVision
    )

    if (Test-LocalLLMWizardSpectreEnabled) {
        Start-LLMWizardSpectre -UseVision:$UseVision
        return
    }

    Start-LLMWizardClassic -UseVision:$UseVision
}
