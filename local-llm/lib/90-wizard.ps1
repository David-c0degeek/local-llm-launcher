# Interactive wizard. Two implementations: a classic Read-Host one and a
# Spectre.Console one. Start-LLMWizard picks at runtime based on whether
# PwshSpectreConsole is available (and LOCAL_LLM_NO_SPECTRE is not set).

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
    # Returns an integer index (>= 0) for a numbered selection, -1 for ZeroLabel,
    # or the matching letter (as a string) when a LetterChoices entry is picked.
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)][scriptblock]$Label,
        [string]$ZeroLabel = "Back",
        [hashtable]$LetterChoices = @{}
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
            [pscustomobject]@{ Key = "fc"; Label = "Unshackled"; Description = "Local agent via Unshackled" },
            [pscustomobject]@{ Key = "findbest"; Label = "Find best settings"; Description = "Auto-tune for this machine" },
            [pscustomobject]@{ Key = "setup"; Label = "Download GGUF only"; Description = "Resolve and cache the GGUF without launching" }
        )
    } else {
        @(
            [pscustomobject]@{ Key = "claude"; Label = "Claude Code"; Description = "Local model behind Claude Code" },
            [pscustomobject]@{ Key = "fc"; Label = "Unshackled"; Description = "Local agent via Unshackled" },
            [pscustomobject]@{ Key = "chat"; Label = "Ollama chat"; Description = "Plain ollama run" },
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

function Read-LLMQ8Toggle {
    # Returns $true (q8 on), $false (q8 off), or $null (back).
    while ($true) {
        Write-Host ""
        $answer = (Read-Host "Use q8 KV cache? [y/N/b=back]").Trim().ToLowerInvariant()

        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -in @("n", "no")) { return $false }
        if ($answer -in @("y", "yes")) { return $true }
        if ($answer -in @("b", "back")) { return $null }

        Write-Host "Answer y, n, or b." -ForegroundColor Red
    }
}

function Read-LLMStrictToggle {
    # Returns $true (strict on), $false (strict off), or $null (back).
    # Only meaningful when the selected model has Strict: true in the catalog;
    # the wizard gates this prompt on Get-ModelStrictEnabled.
    while ($true) {
        Write-Host ""
        Write-Host "Strict mode launches the <root>-strict alias (overlay system prompt + tightened sampling)." -ForegroundColor DarkGray
        Write-Host "Strict pins to the model's strict-base context, so context selection is skipped." -ForegroundColor DarkGray
        $answer = (Read-Host "Use strict mode? [y/N/b=back]").Trim().ToLowerInvariant()

        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -in @("n", "no")) { return $false }
        if ($answer -in @("y", "yes")) { return $true }
        if ($answer -in @("b", "back")) { return $null }

        Write-Host "Answer y, n, or b." -ForegroundColor Red
    }
}

function Read-LLMYesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [bool]$DefaultYes = $false
    )

    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    while ($true) {
        $answer = (Read-Host "$Prompt $suffix").Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes }
        if ($answer -in @("y", "yes")) { return $true }
        if ($answer -in @("n", "no"))  { return $false }
        Write-Host "Answer y or n." -ForegroundColor Red
    }
}

function Invoke-LlamaCppTunerWizardFlow {
    param(
        [Parameter(Mandatory = $true)][string]$ModelKey,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][ValidateSet('native','turboquant')][string]$Mode,
        [switch]$UseSpectrePrompts
    )

    $allowKv = if ($UseSpectrePrompts) {
        Read-LLMTuneKvVariationSpectre
    } else {
        Write-Host ""
        Write-Host "Widens the search to other types in your quality class." -ForegroundColor DarkGray
        Read-LLMYesNo -Prompt "Allow KV cache variation?" -DefaultYes:$false
    }

    $allowedKvTypes = $null
    if ($allowKv) {
        $allowedKvTypes = if ($Mode -eq 'turboquant') {
            @('q8_0', 'f16', 'turbo3', 'turbo4')
        } else {
            @('q8_0', 'f16')
        }
    }

    $result = Find-BestLlamaCppConfig -Key $ModelKey -ContextKey $ContextKey -Mode $Mode -AllowedKvTypes $allowedKvTypes -NoSave

    Write-Host ""
    Write-Host "Best tuner result:" -ForegroundColor Green
    Write-Host ("  score     : {0:N2} ({1})" -f $result.Score, $result.ScoreUnit) -ForegroundColor Green
    Write-Host ("  overrides : {0}" -f (Format-LlamaCppOverrides -Overrides $result.Overrides)) -ForegroundColor DarkGray
    Write-Host ""

    $saveAnswer = if ($UseSpectrePrompts) {
        Read-LLMYesNoSpectre -Message "Save as the default for this machine?" -DefaultYes
    } else {
        Read-LLMYesNo -Prompt "Save as the default for this machine?" -DefaultYes:$true
    }
    if ($saveAnswer) {
        $saved = Save-BestLlamaCppConfig -Key $ModelKey -ContextKey $ContextKey -Mode $Mode `
            -Quant $result.Quant -VramGB $result.VramGB `
            -PromptLength $result.PromptLength `
            -BestArgs $result.Args -BestOverrides $result.Overrides `
            -Score $result.Score -ScoreUnit $result.ScoreUnit `
            -TrialCount $result.TrialCount
        Write-Host "Saved best -> $saved" -ForegroundColor DarkGray
    }

    $launchAnswer = if ($UseSpectrePrompts) {
        Read-LLMYesNoSpectre -Message "Launch immediately with the new config?" -DefaultYes
    } else {
        Read-LLMYesNo -Prompt "Launch immediately with the new config?" -DefaultYes:$true
    }
    if ($launchAnswer) {
        Start-ClaudeWithLlamaCppModel -Key $ModelKey -ContextKey $ContextKey -Mode $Mode -AutoBest
    }
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
        [switch]$UseSpectrePrompts
    )

    if ($Backend -eq 'llamacpp') {
        $def = Get-ModelDef -Key $ModelKey

        switch ($Action) {
            "claude" {
                Invoke-Backend -Action launch-claude -Backend llamacpp `
                    -Key $ModelKey -ContextKey $ContextKey `
                    -LlamaCppMode $LlamaCppMode -KvCacheK $KvCacheK -KvCacheV $KvCacheV `
                    -LimitTools:([bool]$def.LimitTools) -Strict:$Strict
            }

            "fc" {
                Invoke-Backend -Action launch-claude -Backend llamacpp `
                    -Key $ModelKey -ContextKey $ContextKey `
                    -LlamaCppMode $LlamaCppMode -KvCacheK $KvCacheK -KvCacheV $KvCacheV `
                    -LimitTools:([bool]$def.LimitTools) -Unshackled -Strict:$Strict
            }

            "setup" {
                # Strict has no effect on the GGUF path — same file regardless.
                $path = Get-ModelGgufPath -Key $ModelKey -Def $def -Backend llamacpp
                Write-Host "GGUF cached at: $path" -ForegroundColor Green
            }

            "findbest" {
                Invoke-LlamaCppTunerWizardFlow -ModelKey $ModelKey -ContextKey $ContextKey -Mode $LlamaCppMode -UseSpectrePrompts:$UseSpectrePrompts
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
            Invoke-ModelShortcut -Key $ModelKey -ContextKey $ContextKey -Chat -UseQ8:$UseQ8 -Strict:$Strict
        }

        "fc" {
            Invoke-ModelShortcut -Key $ModelKey -ContextKey $ContextKey -Unshackled -UseQ8:$UseQ8 -Strict:$Strict
        }

        "claude" {
            Invoke-ModelShortcut -Key $ModelKey -ContextKey $ContextKey -UseQ8:$UseQ8 -Strict:$Strict
        }

        "benchmark" {
            $modelName = if ($Strict) { Ensure-ModelStrictAlias -Key $ModelKey } else { Ensure-ModelAlias -Key $ModelKey -ContextKey $ContextKey }
            Test-OllamaSpeed -Model $modelName -Runs 3
        }

        "setup" {
            $modelName = if ($Strict) { Ensure-ModelStrictAlias -Key $ModelKey -ForceRebuild } else { Ensure-ModelAlias -Key $ModelKey -ContextKey $ContextKey -ForceRebuild }
            Write-Host "Created/rebuilt alias: $modelName" -ForegroundColor Green
        }

        "show" {
            $modelName = if ($Strict) { Ensure-ModelStrictAlias -Key $ModelKey } else { Ensure-ModelAlias -Key $ModelKey -ContextKey $ContextKey }
            & ollama show $modelName
        }

        default {
            throw "Unknown action: $Action"
        }
    }
}

function Start-LLMWizardClassic {
    $modelKey     = $null
    $contextKey   = $null
    $action       = $null
    $useQ8        = $false
    $useStrict    = $false
    $backend      = 'ollama'
    $llamaCppMode = $null
    $kvK          = $null
    $kvV          = $null
    $step         = 'model'

    while ($true) {
        switch ($step) {
            'model' {
                Clear-Host
                Write-Host "Local LLM launcher" -ForegroundColor Green
                Write-Host "Config: $script:LocalLLMConfigPath" -ForegroundColor DarkGray

                $modelKey = Select-LLMModelKey
                if ([string]::IsNullOrWhiteSpace($modelKey)) { return }

                $useStrict = $false
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
                if ($action -in @("chat", "fc", "claude")) {
                    $step = if ($backend -eq 'llamacpp') { 'kvcache' } else { 'q8' }
                } else {
                    $step = 'launch'
                }
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
                $step = 'launch'
            }

            'launch' {
                try {
                    Invoke-LLMSelection -ModelKey $modelKey -ContextKey $contextKey -Action $action `
                        -Backend $backend -LlamaCppMode $llamaCppMode `
                        -KvCacheK $kvK -KvCacheV $kvV -UseQ8:$useQ8 -Strict:$useStrict
                }
                catch {
                    Write-Host "Command failed." -ForegroundColor Red
                    Write-Host $_.Exception.Message -ForegroundColor DarkGray
                    Pause-Menu
                }
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
    Format-SpectrePanel -Header "Local LLM launcher" -Color Green -Data ("[grey50]Config:[/] {0}" -f (ConvertTo-LocalLLMSpectreSafe $script:LocalLLMConfigPath)) | Out-Host
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
            "Unshackled   -  Local agent via Unshackled"     = 'fc'
            "Find best settings - Auto-tune for this machine" = 'findbest'
            "Setup only   -  Download GGUF without launching" = 'setup'
            "[[Back]]"                                       = '__back__'
        }
    } else {
        [ordered]@{
            "Claude Code  -  Local model behind Claude Code" = 'claude'
            "Unshackled   -  Local agent via Unshackled"     = 'fc'
            "Ollama chat  -  Plain ollama run"               = 'chat'
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
    $choices = [ordered]@{
        'No  -  keep current KV type only'       = $false
        'Yes -  widen within the quality class'  = $true
    }
    $chosen = Read-SpectreSelection -Message "Allow KV cache variation? Widens the search to other types in your quality class." -Choices @($choices.Keys) -PageSize 4
    if ($null -eq $chosen) { return $false }
    return [bool]$choices[$chosen]
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
    $modelKey     = $null
    $contextKey   = $null
    $action       = $null
    $useQ8        = $false
    $useStrict    = $false
    $backend      = 'ollama'
    $llamaCppMode = $null
    $kvK          = $null
    $kvV          = $null
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
                $step = 'quant'
            }

            'quant' {
                $def = Get-ModelDef -Key $modelKey
                if (-not $def.ContainsKey("Quants")) { $step = 'backend'; break }

                $quantKey = Invoke-LLMWizardStep -Context "select-quant ($modelKey)" -Action {
                    Select-LLMQuantKeySpectre -ModelKey $modelKey
                }
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
                }
                if ($null -eq $picked) {
                    $step = if ($def.ContainsKey("Quants")) { 'quant' } else { 'model' }
                    break
                }
                switch ($picked) {
                    'ollama'              { $backend = 'ollama';   $llamaCppMode = $null }
                    'llamacpp-native'     { $backend = 'llamacpp'; $llamaCppMode = 'native' }
                    'llamacpp-turboquant' { $backend = 'llamacpp'; $llamaCppMode = 'turboquant' }
                }
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
                if ($action -in @("chat", "fc", "claude")) {
                    $step = if ($backend -eq 'llamacpp') { 'kvcache' } else { 'q8' }
                } else {
                    $step = 'launch'
                }
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
                $step = 'launch'
            }

            'launch' {
                try {
                    Invoke-LLMSelection -ModelKey $modelKey -ContextKey $contextKey -Action $action `
                        -Backend $backend -LlamaCppMode $llamaCppMode `
                        -KvCacheK $kvK -KvCacheV $kvV -UseQ8:$useQ8 -Strict:$useStrict -UseSpectrePrompts
                }
                catch {
                    Save-LocalLLMWizardError -ErrorRecord $_ -Context "invoke ($modelKey/$contextKey/$action/$backend/strict=$useStrict)"
                    Pause-Menu
                }
                $step = 'model'
            }
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
