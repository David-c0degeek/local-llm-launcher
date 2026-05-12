# Backend dispatcher. Single entry point that routes per-action calls to the
# Ollama or llama.cpp branch. Exists so the wizard, per-model shortcuts, and
# entry-point commands can stay backend-agnostic.

function Resolve-LlamaCppMode {
    # Falls back to LlamaCppDefaultMode from settings when -Mode is unspecified.
    param([string]$Mode)

    if (-not [string]::IsNullOrWhiteSpace($Mode)) {
        return $Mode.ToLowerInvariant()
    }

    $cfgMode = if ($script:Cfg.Contains('LlamaCppDefaultMode') -and -not [string]::IsNullOrWhiteSpace($script:Cfg.LlamaCppDefaultMode)) {
        [string]$script:Cfg.LlamaCppDefaultMode
    } else {
        'native'
    }

    return $cfgMode.ToLowerInvariant()
}

function Test-LlamaCppCompatible {
    # Models can opt out of llama.cpp via LlamaCppCompatible: false. Default $true.
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def)

    if ($Def.Contains('LlamaCppCompatible')) {
        return [bool]$Def.LlamaCppCompatible
    }

    return $true
}

function Test-LlamaCppEligible {
    # Combines source-type + per-model opt-out. Only `gguf` source-type models
    # can run on llama.cpp; `remote` (ollama-pull-only) cannot.
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def)

    if ($Def.SourceType -ne 'gguf') { return $false }
    return (Test-LlamaCppCompatible -Def $Def)
}

function Invoke-Backend {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('launch-claude', 'launch-chat', 'stop', 'status')][string]$Action,
        [Parameter(Mandatory = $true)][ValidateSet('ollama', 'llamacpp')][string]$Backend,
        [string]$Key,
        [AllowEmptyString()][string]$ContextKey = '',
        [ValidateSet('native', 'turboquant')][string]$LlamaCppMode,
        [string]$KvCacheK,
        [string]$KvCacheV,
        [switch]$UseQ8,
        [switch]$LimitTools,
        [switch]$Unshackled,
        [switch]$Codex,
        [switch]$Strict,
        [switch]$UseVision,
        [switch]$AutoBest,
        [ValidateSet('auto','pure','balanced','short','long')][string]$AutoBestProfile = 'auto',
        [string[]]$ExtraArgs,
        [string[]]$ExtraUnshackledArgs,
        [switch]$DryRun
    )

    if ($Action -eq 'stop') {
        switch ($Backend) {
            'ollama'   { Stop-OllamaModels; Stop-OllamaApp; Reset-OllamaEnv }
            'llamacpp' { Stop-LlamaServer }
        }
        return
    }

    if ($Action -eq 'status') {
        switch ($Backend) {
            'ollama'   { & ollama ps }
            'llamacpp' { Get-LlamaServerStatus }
        }
        return
    }

    if ([string]::IsNullOrWhiteSpace($Key)) {
        throw "Invoke-Backend $Action requires -Key."
    }

    if ($Backend -eq 'llamacpp') {
        $def = Get-ModelDef -Key $Key
        if (-not (Test-LlamaCppEligible -Def $def)) {
            throw "Model '$Key' (SourceType=$($def.SourceType)) is not eligible for the llama.cpp backend. Use -Backend ollama or pick a SourceType=gguf model."
        }
    }

    switch ($Action) {
        'launch-claude' {
            switch ($Backend) {
                'ollama' {
                    Invoke-ModelShortcut -Key $Key -ContextKey $ContextKey -UseQ8:$UseQ8 -Unshackled:$Unshackled -Codex:$Codex -Strict:$Strict -UseVision:$UseVision -ExtraUnshackledArgs $ExtraUnshackledArgs -DryRun:$DryRun
                }
                'llamacpp' {
                    $mode = Resolve-LlamaCppMode -Mode $LlamaCppMode
                    Start-ClaudeWithLlamaCppModel `
                        -Key $Key `
                        -ContextKey $ContextKey `
                        -Mode $mode `
                        -KvCacheK $KvCacheK `
                        -KvCacheV $KvCacheV `
                        -LimitTools:$LimitTools `
                        -Unshackled:$Unshackled `
                        -Codex:$Codex `
                        -Strict:$Strict `
                        -UseVision:$UseVision `
                        -AutoBest:$AutoBest `
                        -AutoBestProfile $AutoBestProfile `
                        -ExtraArgs $ExtraArgs `
                        -ExtraUnshackledArgs $ExtraUnshackledArgs `
                        -DryRun:$DryRun
                }
            }
        }

        'launch-chat' {
            switch ($Backend) {
                'ollama' {
                    Invoke-ModelShortcut -Key $Key -ContextKey $ContextKey -Chat -UseQ8:$UseQ8 -DryRun:$DryRun
                }
                'llamacpp' {
                    throw "llama.cpp doesn't have a built-in chat REPL. Run launch-claude and point Claude Code at the running server, or open the llama-server web UI."
                }
            }
        }
    }
}
