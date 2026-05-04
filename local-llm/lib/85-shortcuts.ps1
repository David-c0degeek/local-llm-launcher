# Per-model shortcut function generator. For every catalog entry we bind a
# global function (named after the model's Root or ShortName) that takes
# -Ctx / -Q8 / -Fc / -Chat / -Quant flags and dispatches to Invoke-ModelShortcut.

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
