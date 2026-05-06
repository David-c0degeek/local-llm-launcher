# Status / dashboard / per-model detail. Prefers PwshSpectreConsole when
# installed; falls back to plain Write-Host. The fallback path stays usable on
# fresh machines without any module installs.

$script:LocalLLMSpectreState = $null  # $true / $false / $null (unprobed)

function Show-ClaudeTarget {
    Write-Section "Claude"
    Write-Host "Target : $(Get-ClaudeTargetSummary)" -ForegroundColor Yellow
}

function Show-OllamaStatus {
    param([switch]$All)

    Write-Section "Ollama"

    $loaded = Get-OllamaLoadedModels

    if (-not $loaded -or $loaded.Count -eq 0) {
        Write-Host "Loaded models : none"
    }
    else {
        Write-Host "Loaded models :" -ForegroundColor Yellow

        foreach ($item in $loaded) {
            Write-Host "  $($item.Name)  |  ctx $($item.Context)  |  $($item.Processor)  |  $($item.Size)"
        }
    }

    $stale = @(Get-StaleModelAliases)

    if ($stale.Count -gt 0) {
        Write-Host ""
        Write-Host "Stale aliases (this profile would emit a different Modelfile now): $($stale.Count)" -ForegroundColor Yellow
        foreach ($entry in $stale) {
            Write-Host "  $($entry.AliasName)" -ForegroundColor DarkYellow
        }
        Write-Host "  Run 'init -Stale' to rebuild only the stale ones." -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "Configured GGUF quants/files:" -ForegroundColor Yellow

    foreach ($key in (Get-FilteredModelKeys -IncludeAll:$All)) {
        $def = Get-ModelDef -Key $key

        if ($def.ContainsKey("Quants")) {
            Write-Host "  $key -> $($def.Quant) ($($def.Quants[$def.Quant]))"
        }
        elseif ($def.SourceType -eq "gguf") {
            Write-Host "  $key -> $(Get-ModelFileName -Def $def)"
        }
    }
}

function Format-AliasBuiltList {
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][object]$Installed
    )

    $parts = foreach ($name in $Names) {
        if ($Installed -contains $name -or $Installed -contains "${name}:latest") {
            "+$name"
        }
        else {
            "-$name"
        }
    }

    return ($parts -join ', ')
}

# Spectre.Console renderer (soft dependency)
# Tries to import PwshSpectreConsole on first use. If absent, the dashboard
# falls back to the legacy Write-Host renderer and we surface a one-line install
# hint. Set $env:LOCAL_LLM_NO_SPECTRE=1 to disable Spectre even when installed.

function Test-LocalLLMSpectreAvailable {
    if ($env:LOCAL_LLM_NO_SPECTRE -eq '1') { return $false }
    if ($null -ne $script:LocalLLMSpectreState) { return $script:LocalLLMSpectreState }

    if (Get-Module -Name PwshSpectreConsole) {
        $script:LocalLLMSpectreState = $true
        return $true
    }

    $available = Get-Module -ListAvailable -Name PwshSpectreConsole -ErrorAction SilentlyContinue
    if (-not $available) {
        $script:LocalLLMSpectreState = $false
        return $false
    }

    try {
        Import-Module PwshSpectreConsole -ErrorAction Stop -DisableNameChecking | Out-Null
        $script:LocalLLMSpectreState = $true
        return $true
    } catch {
        Write-Verbose "PwshSpectreConsole import failed: $($_.Exception.Message)"
        $script:LocalLLMSpectreState = $false
        return $false
    }
}

function Show-LocalLLMSpectreInstallHint {
    Write-Host ""
    Write-Host "Tip: install PwshSpectreConsole for a nicer dashboard:" -ForegroundColor DarkGray
    Write-Host "       Install-Module PwshSpectreConsole -Scope CurrentUser" -ForegroundColor DarkGray
    Write-Host "     Reload your profile, or run 'reloadllm', and 'info' will switch to the rich UI." -ForegroundColor DarkGray
}

function ConvertTo-LocalLLMSpectreSafe {
    # Spectre markup is `[color]text[/]`. Square brackets in arbitrary text
    # (e.g. tier badges "[recommended]") collide. Escape with `[[` / `]]`.
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ($null -eq $Text) { return "" }
    return ($Text -replace '\[', '[[') -replace '\]', ']]'
}

function Format-LocalLLMSpectreFitCell {
    # Single-quant fit cell for the summary table: short label + colored marker.
    # marker uses Spectre markup; the bracket/square-bracket text is plain.
    param(
        [Parameter(Mandatory = $true)][string]$QuantKey,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$FitClass,
        [switch]$IsDefault
    )

    $star = if ($IsDefault) { '*' } else { ' ' }

    $marker, $color = switch ($FitClass) {
        'fits'  { '+',  'green'  }
        'tight' { '~',  'yellow' }
        'over'  { '!',  'red'    }
        default { '?',  'grey50' }
    }

    return "[$color]$marker[/]$star$QuantKey"
}

function Show-ModelCatalogSpectre {
    param([switch]$All)

    $vramInfo = Get-LocalLLMVRAMInfo
    $sourceLabel = switch ($vramInfo.Source) {
        "configured" { "set in settings.json" }
        "auto"       { "nvidia-smi auto-detect" }
        "fallback"   { "fallback — nvidia-smi unavailable" }
        default      { $vramInfo.Source }
    }

    Write-Host ""
    Format-SpectrePanel -Header "Models" -Color Blue -Data ("VRAM: [yellow]{0} GB[/] ({1})" -f $vramInfo.GB, (ConvertTo-LocalLLMSpectreSafe $sourceLabel)) | Out-Host

    $visibleKeys = @(Get-FilteredModelKeys -IncludeAll:$All)
    $installed = @(Get-OllamaInstalledModelNames)

    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($key in $visibleKeys) {
        $def = Get-ModelDef -Key $key
        $tier = Get-ModelTier -Def $def

        $tierLabel = switch ($tier) {
            'recommended'  { '[green]recommended[/]' }
            'experimental' { '[yellow]experimental[/]' }
            'legacy'       { '[grey50]legacy[/]' }
            default        { ConvertTo-LocalLLMSpectreSafe $tier }
        }

        if ($def.ContainsKey("Quants")) {
            $quantCells = foreach ($qk in $def.Quants.Keys) {
                $fit = Get-QuantFitClass -Def $def -QuantKey $qk
                Format-LocalLLMSpectreFitCell -QuantKey $qk -FitClass $fit -IsDefault:($qk -eq $def.Quant)
            }
            $quants = ($quantCells -join '  ')
            $defaultQuant = "[cyan]$($def.Quant)[/]"
        } else {
            $quants = "[grey50](single file)[/]"
            $defaultQuant = "[grey50]—[/]"
        }

        $contextLabels = @($def.Contexts.Keys | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace($_)) { "default" } else { $_ }
        })
        $contexts = ($contextLabels -join ' · ')

        $aliases = @($def.Contexts.Keys | ForEach-Object { Get-ModelAliasName -Def $def -ContextKey $_ })
        $builtCount = 0
        foreach ($a in $aliases) {
            if ($installed -contains $a -or $installed -contains "${a}:latest") { $builtCount++ }
        }
        $built = "$builtCount/$($aliases.Count)"
        if ($builtCount -eq $aliases.Count) {
            $built = "[green]$built[/]"
        } elseif ($builtCount -eq 0) {
            $built = "[grey50]$built[/]"
        } else {
            $built = "[yellow]$built[/]"
        }

        $rows.Add([pscustomobject]@{
            Key      = "[white]$key[/]"
            Name     = ConvertTo-LocalLLMSpectreSafe $def.DisplayName
            Tier     = $tierLabel
            Default  = $defaultQuant
            Quants   = $quants
            Contexts = ConvertTo-LocalLLMSpectreSafe $contexts
            Built    = $built
        }) | Out-Null
    }

    $rows | Format-SpectreTable -Border Rounded -Color Blue -AllowMarkup -Wrap | Out-Host

    Write-Host ""
    Write-Host "  Quant cells: " -ForegroundColor DarkGray -NoNewline
    Write-Host "+" -ForegroundColor Green -NoNewline; Write-Host " fits  " -ForegroundColor DarkGray -NoNewline
    Write-Host "~" -ForegroundColor Yellow -NoNewline; Write-Host " tight  " -ForegroundColor DarkGray -NoNewline
    Write-Host "!" -ForegroundColor Red -NoNewline; Write-Host " over  " -ForegroundColor DarkGray -NoNewline
    Write-Host "?" -ForegroundColor DarkGray -NoNewline; Write-Host " size unknown   " -ForegroundColor DarkGray -NoNewline
    Write-Host "*name = current default quant" -ForegroundColor DarkGray
    Write-Host "  Built column: aliases-installed / aliases-configured." -ForegroundColor DarkGray

    if (-not $All) {
        $hiddenCount = (@(Get-ModelKeys)).Count - $visibleKeys.Count
        if ($hiddenCount -gt 0) {
            Write-Host ""
            Write-Host "$hiddenCount more model(s) hidden. Run 'info -All' to show experimental + legacy, or 'info <key>' for one." -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "Drill in:" -ForegroundColor White
    Write-Host "  info <key>                     Per-model detail (description, quants, contexts)" -ForegroundColor DarkGray
    Write-Host "Manage:" -ForegroundColor White
    Write-Host "  addllm <hf-url> -Key <key>     Add a model from HuggingFace (auto-fills size + description)" -ForegroundColor DarkGray
    Write-Host "  removellm <key>                Remove a model + its files" -ForegroundColor DarkGray
    Write-Host "  initmodel <key> [-Force]       (Re)build Ollama aliases for a model" -ForegroundColor DarkGray
    Write-Host "  cleanorphans, listorphans, reloadllm, purge, ops, qkill, ostop, llm, llmdocs" -ForegroundColor DarkGray
    Write-Host "  Config: $script:LocalLLMConfigPath" -ForegroundColor DarkGray
}

function Show-ModelDetailSpectre {
    param([Parameter(Mandatory = $true)][string]$Key)

    $def = Get-ModelDef -Key $Key
    $tier = Get-ModelTier -Def $def
    $tierColor = switch ($tier) {
        'recommended'  { 'green' }
        'experimental' { 'yellow' }
        'legacy'       { 'grey50' }
        default        { 'grey70' }
    }

    $description = Get-ModelDescription -Def $def
    $source = if ($def.SourceType -eq 'gguf') { "GGUF · $($def.Repo)" } else { "Remote · $($def.RemoteModel)" }
    $parser = if ($def.Parser) { $def.Parser } else { 'none' }
    $limitTools = if ($def.ContainsKey('LimitTools')) { [bool]$def.LimitTools } else { $true }

    $headerLines = New-Object System.Collections.Generic.List[string]
    if ($description) {
        $headerLines.Add((ConvertTo-LocalLLMSpectreSafe $description)) | Out-Null
        $headerLines.Add('') | Out-Null
    }
    $headerLines.Add(("[grey70]Source[/]    : {0}" -f (ConvertTo-LocalLLMSpectreSafe $source))) | Out-Null
    $headerLines.Add(("[grey70]Parser[/]    : {0}    [grey70]LimitTools[/]: {1}" -f (ConvertTo-LocalLLMSpectreSafe $parser), $limitTools)) | Out-Null

    if ($def.ContainsKey('ParserNote') -and $def.ParserNote) {
        $headerLines.Add(("[grey50]Note[/]      : {0}" -f (ConvertTo-LocalLLMSpectreSafe $def.ParserNote))) | Out-Null
    }

    $panelHeader = ("[white]{0}[/] · [{1}]{2}[/]" -f (ConvertTo-LocalLLMSpectreSafe $def.DisplayName), $tierColor, $tier)
    Write-Host ""
    Format-SpectrePanel -Header $panelHeader -Color $tierColor -Data ($headerLines -join "`n") | Out-Host

    if ($def.ContainsKey('Quants')) {
        $quantRows = foreach ($qk in $def.Quants.Keys) {
            $isDefault = ($qk -eq $def.Quant)
            $fit = Get-QuantFitClass -Def $def -QuantKey $qk
            $fitMark, $fitColor = switch ($fit) {
                'fits'  { 'fits',  'green' }
                'tight' { 'tight', 'yellow' }
                'over'  { 'over',  'red' }
                default { '?',     'grey50' }
            }
            $size = Get-QuantSizeGB -Def $def -QuantKey $qk
            $sizeText = if ($null -eq $size) { '—' } else { "{0:N1} GB" -f $size }
            $note = Get-ModelQuantNote -Def $def -QuantKey $qk
            if (-not $note) { $note = $def.Quants[$qk] }

            [pscustomobject]@{
                ' '    = if ($isDefault) { '[cyan]*[/]' } else { ' ' }
                Quant  = if ($isDefault) { "[cyan]$qk[/]" } else { $qk }
                Fit    = "[$fitColor]$fitMark[/]"
                Size   = $sizeText
                Note   = ConvertTo-LocalLLMSpectreSafe $note
            }
        }

        Write-Host ""
        Write-Host "Quants" -ForegroundColor White
        $quantRows | Format-SpectreTable -Border Rounded -Color $tierColor -AllowMarkup -Wrap | Out-Host
    }

    $ctxRows = foreach ($ck in $def.Contexts.Keys) {
        $label = if ([string]::IsNullOrWhiteSpace($ck)) { 'default' } else { $ck }
        $tokens = Get-ModelContextValue -Def $def -ContextKey $ck
        $note = Get-ModelContextNote -Def $def -ContextKey $ck
        $alias = Get-ModelAliasName -Def $def -ContextKey $ck

        [pscustomobject]@{
            Context = $label
            Alias   = ConvertTo-LocalLLMSpectreSafe $alias
            Tokens  = "{0:N0}" -f [int]$tokens
            Note    = ConvertTo-LocalLLMSpectreSafe $note
        }
    }

    Write-Host ""
    Write-Host "Contexts" -ForegroundColor White
    $ctxRows | Format-SpectreTable -Border Rounded -Color $tierColor -AllowMarkup -Wrap | Out-Host

    $installed = @(Get-OllamaInstalledModelNames)
    $aliases = @($def.Contexts.Keys | ForEach-Object { Get-ModelAliasName -Def $def -ContextKey $_ })
    $built = Format-AliasBuiltList -Names $aliases -Installed $installed
    Write-Host ""
    Write-Host "Built : $built" -ForegroundColor DarkGray

    if ($def.Contains('Tools') -and -not [string]::IsNullOrWhiteSpace($def.Tools)) {
        Write-Host "Tools : $($def.Tools)" -ForegroundColor DarkGray
    }

    $cmdName = Get-ModelShortcutName -Def $def
    $contextLabels = @($def.Contexts.Keys | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_)) { "default" } else { $_ }
    })
    $ctxFlag = if ($contextLabels.Count -gt 1) { "[-Ctx $($contextLabels -join '|')]" } else { '' }
    $usage = "$cmdName $ctxFlag [-Fc] [-Chat] [-Q8]".Trim()
    if ($def.ContainsKey('Quants')) {
        $usage += " [-Quant $((@($def.Quants.Keys)) -join '|')]"
    }
    Write-Host ""
    Write-Host "Usage : $usage" -ForegroundColor White
}

function Show-ModelCatalog {
    param([switch]$All)

    if (Test-LocalLLMSpectreAvailable) {
        Show-ModelCatalogSpectre -All:$All
        return
    }

    Write-Section "Commands"

    $vramInfo = Get-LocalLLMVRAMInfo
    $sourceLabel = switch ($vramInfo.Source) {
        "configured" { "set in settings.json" }
        "auto"       { "nvidia-smi auto-detect" }
        "fallback"   { "fallback — nvidia-smi unavailable" }
        default      { $vramInfo.Source }
    }
    Write-Host ("VRAM   : {0} GB ({1})" -f $vramInfo.GB, $sourceLabel) -ForegroundColor Yellow
    if ($vramInfo.Source -ne "configured") {
        Write-Host "         Override: Set-LocalLLMSetting VRAMGB <value>" -ForegroundColor DarkGray
    }
    Write-Host ""

    $visibleKeys = @(Get-FilteredModelKeys -IncludeAll:$All)
    $installed = @(Get-OllamaInstalledModelNames)

    foreach ($key in $visibleKeys) {
        $def = Get-ModelDef -Key $key
        $cmdName = Get-ModelShortcutName -Def $def

        $contextKeys = @($def.Contexts.Keys)
        $contextLabels = $contextKeys | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace($_)) { "default" } else { $_ }
        }
        $ctxFlag = if ($contextKeys.Count -gt 1) {
            "[-Ctx $($contextLabels -join '|')]"
        } else {
            ""
        }

        $aliases = $contextKeys | ForEach-Object { Get-ModelAliasName -Def $def -ContextKey $_ }

        $tierBadge = Format-ModelTierBadge -Def $def

        Write-Host "$($def.DisplayName) " -ForegroundColor White -NoNewline
        Write-Host $tierBadge -ForegroundColor DarkYellow

        $description = Get-ModelDescription -Def $def
        if (-not [string]::IsNullOrWhiteSpace($description)) {
            Write-Host "  $description" -ForegroundColor Gray
        }

        $usage = "$cmdName $ctxFlag [-Fc] [-Chat] [-Q8]".Trim()

        if ($def.ContainsKey("Quants")) {
            $quantNames = @($def.Quants.Keys) -join '|'
            $usage += " [-Quant $quantNames]"
        }

        Write-Host "  $usage" -ForegroundColor White
        Write-Host "  Built  : $(Format-AliasBuiltList -Names $aliases -Installed $installed)" -ForegroundColor DarkGray

        if ($def.Contains("Tools") -and -not [string]::IsNullOrWhiteSpace($def.Tools)) {
            Write-Host "  Tools  : $($def.Tools)" -ForegroundColor DarkGray
        }

        if ($def.ContainsKey("Quants")) {
            $hasQuantNotes = $false
            foreach ($qk in $def.Quants.Keys) {
                if (-not [string]::IsNullOrWhiteSpace((Get-ModelQuantNote -Def $def -QuantKey $qk))) {
                    $hasQuantNotes = $true
                    break
                }
            }

            if ($hasQuantNotes) {
                Write-Host "  Quants :" -ForegroundColor DarkGray
                foreach ($qk in $def.Quants.Keys) {
                    $marker = if ($qk -eq $def.Quant) { "*" } else { " " }
                    $note = Get-ModelQuantNote -Def $def -QuantKey $qk
                    $fitClass = Get-QuantFitClass -Def $def -QuantKey $qk
                    $badge = Format-QuantFitBadge -FitClass $fitClass

                    $body = if ([string]::IsNullOrWhiteSpace($note)) { $def.Quants[$qk] } else { $note }
                    $prefix = "    {0} {1,-8} " -f $marker, $qk

                    if ([string]::IsNullOrWhiteSpace($badge)) {
                        Write-Host ("$prefix $body") -ForegroundColor DarkGray
                    } else {
                        Write-Host -NoNewline $prefix -ForegroundColor DarkGray
                        Write-Host -NoNewline (" {0,-7}" -f $badge) -ForegroundColor (Get-QuantFitBadgeColor -FitClass $fitClass)
                        Write-Host (" $body") -ForegroundColor DarkGray
                    }
                }
            }
        }

        $hasCtxNotes = $false
        foreach ($ck in $contextKeys) {
            if (-not [string]::IsNullOrWhiteSpace((Get-ModelContextNote -Def $def -ContextKey $ck))) {
                $hasCtxNotes = $true
                break
            }
        }

        if ($hasCtxNotes) {
            Write-Host "  Ctx    :" -ForegroundColor DarkGray
            foreach ($ck in $contextKeys) {
                $label = if ([string]::IsNullOrWhiteSpace($ck)) { "default" } else { $ck }
                $note = Get-ModelContextNote -Def $def -ContextKey $ck
                if ([string]::IsNullOrWhiteSpace($note)) {
                    $tokens = Get-ModelContextValue -Def $def -ContextKey $ck
                    Write-Host ("    {0,-8}  {1} tokens" -f $label, $tokens) -ForegroundColor DarkGray
                } else {
                    Write-Host ("    {0,-8}  {1}" -f $label, $note) -ForegroundColor DarkGray
                }
            }
        }

        Write-Host ""
    }

    if (-not $All) {
        $hiddenCount = (@(Get-ModelKeys)).Count - $visibleKeys.Count

        if ($hiddenCount -gt 0) {
            Write-Host "$hiddenCount more model(s) hidden. Run 'info -All' to see them, or set Tier in llm-models.json." -ForegroundColor DarkGray
            Write-Host ""
        }
    }

    Write-Host "Built-status legend: +name = Ollama alias exists, -name = not yet built" -ForegroundColor DarkGray
    Write-Host "Quant-fit legend:    [fits] weights + ~7 GB headroom for KV  [tight] weights only  [over] partial offload" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Manage:" -ForegroundColor White
    Write-Host "  addllm <hf-url> -Key <key>     Add a model from HuggingFace" -ForegroundColor DarkGray
    Write-Host "  removellm <key>                Remove a model + its files" -ForegroundColor DarkGray
    Write-Host "  initmodel <key> [-Force]       (Re)build Ollama aliases for a model" -ForegroundColor DarkGray
    Write-Host "  cleanorphans                   List Ollama models not in llm-models.json" -ForegroundColor DarkGray
    Write-Host "  reloadllm, purge, ops, qkill, ostop, llm, llmdocs" -ForegroundColor DarkGray
    Write-Host "  Config: $script:LocalLLMConfigPath" -ForegroundColor DarkGray
}

function Show-ModelDetailFallback {
    # Per-model detail without Spectre. Mirrors Show-ModelDetailSpectre's fields.
    param([Parameter(Mandatory = $true)][string]$Key)

    $def = Get-ModelDef -Key $Key
    $tier = Get-ModelTier -Def $def
    $tierBadge = Format-ModelTierBadge -Def $def

    Write-Host ""
    Write-Host "$($def.DisplayName) " -ForegroundColor White -NoNewline
    Write-Host $tierBadge -ForegroundColor DarkYellow

    $description = Get-ModelDescription -Def $def
    if ($description) {
        Write-Host "  $description" -ForegroundColor Gray
    }

    $source = if ($def.SourceType -eq 'gguf') { "GGUF · $($def.Repo)" } else { "Remote · $($def.RemoteModel)" }
    Write-Host "  Source : $source" -ForegroundColor DarkGray
    Write-Host "  Parser : $($def.Parser)    LimitTools: $([bool]$def.LimitTools)" -ForegroundColor DarkGray

    if ($def.ContainsKey('ParserNote') -and $def.ParserNote) {
        Write-Host "  Note   : $($def.ParserNote)" -ForegroundColor DarkGray
    }

    if ($def.ContainsKey("Quants")) {
        Write-Host "  Quants :" -ForegroundColor White
        foreach ($qk in $def.Quants.Keys) {
            $marker = if ($qk -eq $def.Quant) { "*" } else { " " }
            $fit = Get-QuantFitClass -Def $def -QuantKey $qk
            $badge = Format-QuantFitBadge -FitClass $fit
            $size = Get-QuantSizeGB -Def $def -QuantKey $qk
            $sizeText = if ($null -eq $size) { '' } else { "{0,5:N1} GB" -f $size }
            $note = Get-ModelQuantNote -Def $def -QuantKey $qk
            if (-not $note) { $note = $def.Quants[$qk] }

            Write-Host -NoNewline ("    {0} {1,-8} " -f $marker, $qk)
            if ($badge) {
                Write-Host -NoNewline (" {0,-7}" -f $badge) -ForegroundColor (Get-QuantFitBadgeColor -FitClass $fit)
            }
            Write-Host -NoNewline (" {0,9} " -f $sizeText) -ForegroundColor DarkGray
            Write-Host $note -ForegroundColor DarkGray
        }
    }

    Write-Host "  Ctx    :" -ForegroundColor White
    foreach ($ck in $def.Contexts.Keys) {
        $label = if ([string]::IsNullOrWhiteSpace($ck)) { "default" } else { $ck }
        $tokens = Get-ModelContextValue -Def $def -ContextKey $ck
        $alias = Get-ModelAliasName -Def $def -ContextKey $ck
        $note = Get-ModelContextNote -Def $def -ContextKey $ck
        if ($note) {
            Write-Host ("    {0,-8}  {1,-22}  {2}" -f $label, $alias, $note) -ForegroundColor DarkGray
        } else {
            Write-Host ("    {0,-8}  {1,-22}  {2,7} tokens" -f $label, $alias, $tokens) -ForegroundColor DarkGray
        }
    }

    $installed = @(Get-OllamaInstalledModelNames)
    $aliases = @($def.Contexts.Keys | ForEach-Object { Get-ModelAliasName -Def $def -ContextKey $_ })
    Write-Host "  Built  : $(Format-AliasBuiltList -Names $aliases -Installed $installed)" -ForegroundColor DarkGray

    if ($def.Contains('Tools') -and -not [string]::IsNullOrWhiteSpace($def.Tools)) {
        Write-Host "  Tools  : $($def.Tools)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Show-LLMProfileInfo {
    param([switch]$All)

    Clear-Host
    Write-Host "Local LLM dashboard" -ForegroundColor Green

    Show-ClaudeTarget
    Show-OllamaStatus -All:$All
    Show-ModelCatalog -All:$All

    if (-not (Test-LocalLLMSpectreAvailable)) {
        Show-LocalLLMSpectreInstallHint
    }

    Write-Host ""
}

function info {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Key,
        [switch]$All
    )

    if ($Key) {
        $resolved = Resolve-ModelKeyByAnyName -Name $Key
        if (-not $resolved) {
            Write-Host "Unknown model: $Key" -ForegroundColor Red
            Write-Host "Known keys: $((@(Get-ModelKeys)) -join ', ')" -ForegroundColor DarkGray
            return
        }

        if (Test-LocalLLMSpectreAvailable) {
            Show-ModelDetailSpectre -Key $resolved
        } else {
            Show-ModelDetailFallback -Key $resolved
            Show-LocalLLMSpectreInstallHint
        }
        return
    }

    Show-LLMProfileInfo -All:$All
}

function llminfo {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Key,
        [switch]$All
    )

    if ($Key) {
        info -Key $Key
        return
    }

    Show-LLMProfileInfo -All:$All
}

function llmdocs { Show-LLMQuickReference }
function docs { Show-LLMQuickReference }
function llmhelp { Show-LLMQuickReference }

function Show-LLMDynamicModelSummary {
    Write-Section "Configured models (by tier)"

    $tierOrder = @("recommended", "experimental", "legacy")
    $byTier = @{}

    foreach ($tier in $tierOrder) {
        $byTier[$tier] = New-Object System.Collections.Generic.List[string]
    }

    foreach ($key in (Get-ModelKeys)) {
        $def = Get-ModelDef -Key $key
        $tier = Get-ModelTier -Def $def

        if (-not $byTier.ContainsKey($tier)) {
            $byTier[$tier] = New-Object System.Collections.Generic.List[string]
            $tierOrder += $tier
        }

        $byTier[$tier].Add($key) | Out-Null
    }

    foreach ($tier in $tierOrder) {
        if ($byTier[$tier].Count -eq 0) { continue }

        Write-Host ""
        Write-Host ("[{0}]" -f $tier) -ForegroundColor DarkYellow

        foreach ($key in $byTier[$tier]) {
            $def = Get-ModelDef -Key $key
            $source = if ($def.SourceType -eq "gguf") { "GGUF: $($def.Repo)" } else { "Remote: $($def.RemoteModel)" }
            $contexts = @($def.Contexts.Keys | ForEach-Object {
                    $aliasName = Get-ModelAliasName -Def $def -ContextKey $_
                    $ctx = Get-ModelContextValue -Def $def -ContextKey $_
                    "$aliasName=$ctx"
                }) -join ", "

            Write-Host "$key" -ForegroundColor White
            Write-Host "  Name     : $($def.DisplayName)"

            $description = Get-ModelDescription -Def $def
            if (-not [string]::IsNullOrWhiteSpace($description)) {
                Write-Host "  About    : $description" -ForegroundColor Gray
            }

            Write-Host "  Source   : $source"
            Write-Host "  Contexts : $contexts"

            if ($def.ContainsKey("Quants")) {
                $quantList = @($def.Quants.Keys | ForEach-Object {
                        if ($_ -eq $def.Quant) { "$_ [current]" } else { $_ }
                    }) -join ", "
                Write-Host "  Quants   : $quantList"
                $shortcutName = Get-ModelShortcutName -Def $def
                Write-Host "  Switch   : $shortcutName -Quant <quant>"
            }

            Write-Host ""
        }
    }
}

function Show-LLMQuickReference {
    Write-Section "Quick Reference"

    $q8Max = Get-Q8KvMaxContext
    $q8MaxLabel = if ($q8Max -ge 1024) { "{0}k" -f [int]($q8Max / 1024) } else { "$q8Max" }

    Write-Host @"
One function per model — flags select what to do.
  qcoder -Ctx fast -Fc          Code agent (Qwen3-Coder, 32k, Unshackled)
  q36p -Ctx fast -Fc            General Qwen 3.6 agent (32k, Unshackled)
  dev -Ctx fast                 Smaller / faster (Devstral 24B, 32k)
  q36p -Ctx 128 -Fc             Big context (Qwen 3.6 Plus, 128k)
  qcoder -Ctx 256 -Quant iq4xs  256k coder context (4090 ceiling — no -Q8)
  q36p -Chat                    Raw ollama chat, no Claude Code
  q36p -Q8                      Use q8 KV cache for higher quality
  q36p -Quant q6kp              Switch the GGUF quant (rebuilds aliases)
  llmdefault                    Launch the configured Default model
  llm                           Guided wizard (rich UI if PwshSpectreConsole is installed)

Flags
  -Ctx <name>     One of the model's contexts (e.g. fast, deep, 128, 256). Omit for default.
  -Fc             Use Unshackled instead of Claude Code (alias for -Unshackled).
  -Chat           Run plain ollama chat (skips Claude Code entirely).
  -Q8             Set OLLAMA_KV_CACHE_TYPE=q8_0 for this launch.
                  Refused above $q8MaxLabel tokens — q8 KV at long context OOMs a 24GB card.
                  Override the threshold with: Set-LocalLLMSetting Q8KvMaxContext 262144
  -Quant <name>   Switch the model's selected quant (no launch). GGUF models only.

Tradeoffs / sizes
  Per-quant and per-context tradeoffs (file size, KV pressure, when to pick what)
  are shown inline by 'info' and the 'llm' wizard. Set them in llm-models.json
  as Description, QuantNotes, and ContextNotes fields.

Manage
  info                  Dashboard, recommended models only (rich UI if PwshSpectreConsole is installed)
  info -All             Dashboard with experimental + legacy
  info <key>            Per-model detail: description, quants table (with fit + size), contexts table
  reloadllm             Reload llm-models.json and regenerate commands
  ops, qkill, ostop     Ollama: list / stop loaded / restart
  init                  Setup all recommended models
  init -All             Setup every configured model
  init -Force           Rebuild all aliases
  init -Stale           Rebuild only aliases whose parser stamp is missing/stale
  initmodel <key> [-Force]
  listorphans           Show Ollama models not present in llm-models.json
  cleanorphans          Remove orphan Ollama models (confirms first)
  purge                 Remove every configured alias and every GGUF file
  obench [-Model name]  Show benchmark history (~/.local-llm/bench-history.jsonl)
  findbest <key> -ContextKey <ctx> [-Mode native|turboquant] [-Quick|-Deep] [-Budget 30]
                        Auto-tune llama.cpp launch flags for this box (writes
                        ~/.local-llm/tuner/best-<key>.json). Use with
                        Start-ClaudeWithLlamaCppModel -AutoBest later.
                        The wizard also exposes Find best settings and
                        Delete best settings for llama.cpp models.

Add or remove a model
  addllm <hf-url-or-repo> -Key <key>
  addllm <hf-url-or-repo> -Key <key> -Quants Q4_K_P,IQ4_XS -DefaultQuant Q4_K_P -Tier recommended
  addllm <hf-url-or-repo> -Key <key> -Description '...' -QuantNotes @{q4='~17 GB'} -ContextNotes @{'128'='131k'}
  initmodel <key>
  removellm <key> [-KeepFiles] [-Force]

  Auto-fill on add: Description (from base_model README), QuantSizesGB (from HF blob sizes),
  and a baseline QuantNotes per quant. Override any field by passing -Description / -QuantNotes etc.

Tiers
  recommended    Daily drivers, known to work. Shown by default.
  experimental   Works but uncensored / abliterated / niche; hidden by default.
  legacy         Kept for comparison; hidden by default.

Benchmark
  qkill ; q36p -Ctx fast -Chat ; ospeed q36plusfast -Runs 3
  qkill ; qcoder -Ctx fast -Chat ; ospeed qcoder30fast -Runs 3

Notes
  Thinking: q36opus47abl uses ThinkingPolicy=keep, which routes it directly at
            Ollama (port 11434) and leaves Claude Code's thinking env vars unset.
            All other models go through the strip proxy on 11435.
"@

    Show-LLMDynamicModelSummary
}
