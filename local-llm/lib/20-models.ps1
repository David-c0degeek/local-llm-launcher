# Catalog access + alias-name conventions. Reload-LocalLLMConfig lives here too
# (it's the public reload; depends on Import-LocalLLMConfig from settings and on
# Register-ModelShortcuts from the shortcuts module). Get-ModelGgufPath calls
# Download-HuggingFaceFile (helpers) and Get-ModelFolder (this file).

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

# Optional fields on a model def: Description, QuantNotes (qkey -> string),
# ContextNotes (ctxkey -> string). Always read through these helpers — they
# tolerate missing fields and odd casing.

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

# Strict-sibling helpers. A model with `Strict: $true` in the catalog gets an
# extra Ollama alias built `FROM <root>:latest` with the strict overlay
# applied. The alias is named `<root>-strict` and uses the model's default
# context (or the first context when there is no `""` entry).

function Get-ModelStrictEnabled {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def)

    if ($Def.Contains("Strict")) {
        return [bool]$Def.Strict
    }

    return $false
}

function Get-ModelStrictAliasName {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def)

    return "$($Def.Root)-strict"
}

function Get-ModelStrictBaseContextKey {
    # Pick which context the strict sibling derives from. Convention:
    # the empty-string ("") context is the default and almost always present
    # (Get-LocalLLMDefaultContexts returns it first). Fall back to the first
    # context key if a custom catalog dropped the default.
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def)

    if ($Def.Contexts.Contains('')) {
        return ''
    }

    return @($Def.Contexts.Keys)[0]
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
