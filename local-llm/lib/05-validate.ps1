# Catalog validator. Walks every model entry and collects field-level errors
# so a stale or hand-edited llm-models.json fails at load time with a single
# readable message — not at the call site of whatever function later trips
# over the missing/typo'd field.

# Known parser names (mirrors the switch in lib/40-parsers.ps1). Keep in sync
# when adding a parser there.
$script:LocalLLMValidParsers = @('none', 'qwen3coder', 'qwen36', 'qwen36-think')
$script:LocalLLMValidTiers   = @('recommended', 'experimental', 'legacy')
$script:LocalLLMValidSourceTypes = @('gguf', 'remote')
$script:LocalLLMValidThinkingPolicies = @('strip', 'keep')

function Add-LocalLLMValidationError {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IList]$Errors,
        [Parameter(Mandatory = $true)][string]$ModelKey,
        [Parameter(Mandatory = $true)][string]$Field,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $Errors.Add(("Models.{0}.{1}: {2}" -f $ModelKey, $Field, $Message)) | Out-Null
}

function Test-LocalLLMIsPositiveInt {
    param($Value)

    if ($null -eq $Value) { return $false }

    try {
        $n = [long]$Value
        return ($n -gt 0)
    }
    catch {
        return $false
    }
}

function Test-LocalLLMModelEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [Parameter(Mandatory = $true)][System.Collections.IList]$Errors
    )

    # SourceType: required and limited to the known set.
    $sourceType = if ($Def.Contains('SourceType')) { [string]$Def.SourceType } else { $null }
    if ([string]::IsNullOrWhiteSpace($sourceType)) {
        Add-LocalLLMValidationError -Errors $Errors -ModelKey $Key -Field 'SourceType' -Message "is required (one of: $($script:LocalLLMValidSourceTypes -join ', '))"
    }
    elseif ($sourceType -notin $script:LocalLLMValidSourceTypes) {
        Add-LocalLLMValidationError -Errors $Errors -ModelKey $Key -Field 'SourceType' -Message "must be one of $($script:LocalLLMValidSourceTypes -join ', '); got '$sourceType'"
    }

    # Root: required (drives alias names + folder names).
    if (-not $Def.Contains('Root') -or [string]::IsNullOrWhiteSpace([string]$Def.Root)) {
        Add-LocalLLMValidationError -Errors $Errors -ModelKey $Key -Field 'Root' -Message 'is required'
    }

    # Source-type-specific fields.
    if ($sourceType -eq 'gguf') {
        if (-not $Def.Contains('Repo') -or [string]::IsNullOrWhiteSpace([string]$Def.Repo)) {
            Add-LocalLLMValidationError -Errors $Errors -ModelKey $Key -Field 'Repo' -Message "is required for SourceType=gguf (e.g. 'mradermacher/foo-i1-GGUF')"
        }

        # A gguf model either has a Quants map (+ Quant pointer) or a single File field.
        $hasQuants = $Def.Contains('Quants') -and $Def.Quants
        $hasFile   = $Def.Contains('File') -and -not [string]::IsNullOrWhiteSpace([string]$Def.File)

        if (-not $hasQuants -and -not $hasFile) {
            Add-LocalLLMValidationError -Errors $Errors -ModelKey $Key -Field '(Quants|File)' -Message 'a gguf model must define either a Quants map or a single File'
        }

        if ($hasQuants) {
            $quantKeys = @($Def.Quants.Keys)

            if (-not $Def.Contains('Quant') -or [string]::IsNullOrWhiteSpace([string]$Def.Quant)) {
                Add-LocalLLMValidationError -Errors $Errors -ModelKey $Key -Field 'Quant' -Message 'is required when Quants is set (selects the default quant)'
            }
            elseif (-not ($Def.Quants.Contains([string]$Def.Quant))) {
                Add-LocalLLMValidationError -Errors $Errors -ModelKey $Key -Field 'Quant' -Message ("'{0}' is not a key in Quants ({1})" -f $Def.Quant, ($quantKeys -join ', '))
            }

            foreach ($side in @('QuantSizesGB', 'QuantNotes')) {
                if (-not $Def.Contains($side) -or -not $Def.$side) { continue }
                foreach ($k in @($Def.$side.Keys)) {
                    if ($quantKeys -notcontains [string]$k) {
                        Add-LocalLLMValidationError -Errors $Errors -ModelKey $Key -Field "$side.$k" -Message "references quant key '$k' not present in Quants"
                    }
                }
            }

            if ($Def.Contains('QuantSizesGB') -and $Def.QuantSizesGB) {
                foreach ($k in @($Def.QuantSizesGB.Keys)) {
                    $v = $Def.QuantSizesGB[$k]
                    $isNumber = $false
                    try { [void][double]$v; $isNumber = $true } catch {}
                    if (-not $isNumber -or [double]$v -le 0) {
                        Add-LocalLLMValidationError -Errors $Errors -ModelKey $Key -Field "QuantSizesGB.$k" -Message "must be a positive number; got '$v'"
                    }
                }
            }
        }
    }
    elseif ($sourceType -eq 'remote') {
        if (-not $Def.Contains('RemoteModel') -or [string]::IsNullOrWhiteSpace([string]$Def.RemoteModel)) {
            Add-LocalLLMValidationError -Errors $Errors -ModelKey $Key -Field 'RemoteModel' -Message "is required for SourceType=remote (e.g. 'qwen3:30b')"
        }
    }

    # Parser: required, one of the known set. (Some legacy entries omit it;
    # 'none' is allowed but the field must still resolve to a known parser.)
    if ($Def.Contains('Parser')) {
        $parser = [string]$Def.Parser
        if (-not [string]::IsNullOrWhiteSpace($parser) -and $parser -notin $script:LocalLLMValidParsers) {
            Add-LocalLLMValidationError -Errors $Errors -ModelKey $Key -Field 'Parser' -Message "must be one of $($script:LocalLLMValidParsers -join ', '); got '$parser'"
        }
    }

    # Tier: optional, but when set must be a known value.
    if ($Def.Contains('Tier')) {
        $tier = [string]$Def.Tier
        if (-not [string]::IsNullOrWhiteSpace($tier) -and $tier -notin $script:LocalLLMValidTiers) {
            Add-LocalLLMValidationError -Errors $Errors -ModelKey $Key -Field 'Tier' -Message "must be one of $($script:LocalLLMValidTiers -join ', '); got '$tier'"
        }
    }

    # ThinkingPolicy: optional, but when set must be a known value.
    if ($Def.Contains('ThinkingPolicy')) {
        $tp = [string]$Def.ThinkingPolicy
        if (-not [string]::IsNullOrWhiteSpace($tp) -and $tp -notin $script:LocalLLMValidThinkingPolicies) {
            Add-LocalLLMValidationError -Errors $Errors -ModelKey $Key -Field 'ThinkingPolicy' -Message "must be one of $($script:LocalLLMValidThinkingPolicies -join ', '); got '$tp'"
        }
    }

    # Contexts: required (every shortcut launch resolves a context). Values
    # must be positive integers (num_ctx).
    if (-not $Def.Contains('Contexts') -or -not $Def.Contexts) {
        Add-LocalLLMValidationError -Errors $Errors -ModelKey $Key -Field 'Contexts' -Message "is required (map of context-key -> num_ctx)"
    }
    else {
        foreach ($ck in @($Def.Contexts.Keys)) {
            $v = $Def.Contexts[$ck]
            if (-not (Test-LocalLLMIsPositiveInt $v)) {
                $label = if ([string]::IsNullOrWhiteSpace($ck)) { '(default)' } else { $ck }
                Add-LocalLLMValidationError -Errors $Errors -ModelKey $Key -Field "Contexts.$label" -Message "must be a positive integer (num_ctx); got '$v'"
            }
        }
    }

    # Optional llama.cpp integer fields — typed when present.
    foreach ($intField in @('NGpuLayers', 'NCpuMoe')) {
        if (-not $Def.Contains($intField)) { continue }
        $v = $Def.$intField
        if ($null -eq $v) { continue }
        $isInt = $false
        try { [void][int]$v; $isInt = $true } catch {}
        if (-not $isInt) {
            Add-LocalLLMValidationError -Errors $Errors -ModelKey $Key -Field $intField -Message "must be an integer when set; got '$v'"
        }
    }

    foreach ($kvField in @('KvCacheK', 'KvCacheV')) {
        if (-not $Def.Contains($kvField)) { continue }
        $v = [string]$Def.$kvField
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        # The mainline + turboquant types live in lib/41-llamacpp-args.ps1; reuse
        # both lists. Either type is allowed at validation time (turboquant is
        # mode-checked at launch time, not catalog-load time).
        $allKvTypes = @($script:LlamaCppMainlineKvTypes) + @($script:LlamaCppTurboKvTypes)
        if ($v.ToLowerInvariant() -notin $allKvTypes) {
            Add-LocalLLMValidationError -Errors $Errors -ModelKey $Key -Field $kvField -Message "unknown KV cache type '$v'; expected one of $($allKvTypes -join ', ')"
        }
    }
}

function Test-LocalLLMCatalog {
    # Validate every model entry in the merged config. Throws a single
    # exception with every error listed, or returns silently on success.
    # Callers can pass -PassThru to receive the @() of error strings instead.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config,
        [switch]$PassThru
    )

    $errors = New-Object System.Collections.Generic.List[string]

    if (-not $Config.Contains('Models') -or -not $Config.Models) {
        $errors.Add("Models: missing or empty — at least one model must be defined") | Out-Null
    }
    else {
        $models = $Config.Models
        foreach ($key in @($models.Keys)) {
            $def = $models[$key]
            if ($def -isnot [System.Collections.IDictionary]) {
                $errors.Add(("Models.{0}: must be a hashtable/object; got {1}" -f $key, $def.GetType().Name)) | Out-Null
                continue
            }
            Test-LocalLLMModelEntry -Key $key -Def $def -Errors $errors
        }
    }

    if ($PassThru) {
        return ,@($errors)
    }

    if ($errors.Count -gt 0) {
        $body = ($errors | ForEach-Object { "  - $_" }) -join "`n"
        throw "Catalog validation failed ($($errors.Count) error(s)):`n$body"
    }
}
