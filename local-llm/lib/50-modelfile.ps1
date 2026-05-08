# Modelfile creation + alias lifecycle. Knows how to materialize one Ollama
# alias from a model def: pull a remote model or fetch a GGUF, write a temp
# Modelfile, run `ollama create`, and stamp the version.

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

function New-OllamaStrictAlias {
    # Strict sibling: derives from <base>:latest and overlays sampling +
    # SYSTEM. The base's RENDERER/PARSER/template are inherited via FROM, so
    # this works for any model family without per-parser branching here.
    param(
        [Parameter(Mandatory = $true)][string]$BaseAliasName,
        [Parameter(Mandatory = $true)][string]$StrictAliasName,
        [Nullable[int]]$NumCtx
    )

    $safeName = ($StrictAliasName -replace '[:/\\]', '_')
    $tmp = Join-Path $env:TEMP "$safeName.Modelfile"

    $content = New-Object System.Collections.Generic.List[string]
    $content.Add("FROM ${BaseAliasName}:latest")

    foreach ($line in (Get-StrictModelfileLines)) {
        $content.Add($line)
    }

    if ($null -ne $NumCtx) {
        $content.Add("PARAMETER num_ctx $NumCtx")
    }

    $content | Set-Content -Path $tmp -Encoding UTF8

    & ollama rm $StrictAliasName 2>$null | Out-Null
    & ollama create $StrictAliasName -f $tmp

    $exitCode = $LASTEXITCODE
    Remove-Item $tmp -ErrorAction SilentlyContinue

    if ($exitCode -ne 0) {
        throw "ollama create failed for strict alias '$StrictAliasName'"
    }

    Save-ProfileVersionStamp -ModelName $StrictAliasName -Version (Get-StrictProfileVersion -NumCtx $NumCtx)
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

function Test-StrictAliasFresh {
    param(
        [Parameter(Mandatory = $true)][string]$StrictAliasName,
        [Nullable[int]]$NumCtx
    )

    if (-not (Test-OllamaModelExists -ModelName $StrictAliasName)) {
        return $false
    }

    $stamp = Get-ProfileVersionStamp -ModelName $StrictAliasName

    if (-not $stamp) {
        return $false
    }

    $expected = Get-StrictProfileVersion -NumCtx $NumCtx
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
                Kind      = 'base'
            }
        }

        if (Get-ModelStrictEnabled -Def $def) {
            $strictName = Get-ModelStrictAliasName -Def $def

            if (Test-OllamaModelExists -ModelName $strictName) {
                $strictCtxKey = Get-ModelStrictBaseContextKey -Def $def
                $strictNumCtx = Get-ModelContextValue -Def $def -ContextKey $strictCtxKey

                if (-not (Test-StrictAliasFresh -StrictAliasName $strictName -NumCtx $strictNumCtx)) {
                    $stale += [pscustomobject]@{
                        Key       = $key
                        Context   = $strictCtxKey
                        AliasName = $strictName
                        Kind      = 'strict'
                    }
                }
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

function Ensure-ModelStrictAlias {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [switch]$ForceRebuild
    )

    $def = Get-ModelDef -Key $Key
    $strictName = Get-ModelStrictAliasName -Def $def
    $baseCtxKey = Get-ModelStrictBaseContextKey -Def $def
    $baseName = Get-ModelAliasName -Def $def -ContextKey $baseCtxKey
    $numCtx = Get-ModelContextValue -Def $def -ContextKey $baseCtxKey

    if (-not $ForceRebuild -and (Test-StrictAliasFresh -StrictAliasName $strictName -NumCtx $numCtx)) {
        return $strictName
    }

    # The strict sibling derives FROM the base alias. Make sure the base
    # exists first; build it if missing (Ensure-ModelAlias is idempotent).
    Ensure-ModelAlias -Key $Key -ContextKey $baseCtxKey | Out-Null

    New-OllamaStrictAlias -BaseAliasName $baseName -StrictAliasName $strictName -NumCtx $numCtx
    return $strictName
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

    if (Get-ModelStrictEnabled -Def $def) {
        Ensure-ModelStrictAlias -Key $Key -ForceRebuild:$ForceRebuild | Out-Null
    }
}

function Remove-ModelAliases {
    param([Parameter(Mandatory = $true)][string]$Key)

    $def = Get-ModelDef -Key $Key

    $names = New-Object System.Collections.Generic.HashSet[string]
    foreach ($name in (Get-ModelAliasNames -Def $def)) {
        $names.Add($name) | Out-Null
    }
    foreach ($legacyContextKey in @('fast', 'deep', '128')) {
        $names.Add("$($def.Root)$legacyContextKey") | Out-Null
    }

    foreach ($name in $names) {
        & ollama rm $name 2>$null | Out-Null
        $stampFile = Get-ProfileVersionFile -ModelName $name
        Remove-Item -Path $stampFile -Force -ErrorAction SilentlyContinue
    }

    # Strict sibling — remove unconditionally, even if Strict is currently
    # disabled, so leftovers from a previous build don't linger after the
    # user toggles Strict off.
    $strictName = Get-ModelStrictAliasName -Def $def
    & ollama rm $strictName 2>$null | Out-Null
    Remove-Item -Path (Get-ProfileVersionFile -ModelName $strictName) -Force -ErrorAction SilentlyContinue
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
