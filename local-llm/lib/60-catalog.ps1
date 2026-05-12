# Catalog mutation: addllm/updatellm/removellm and orphan cleanup. Reads/writes
# llm-models.json directly (Save-LocalLLMConfig), then triggers Reload-LocalLLMConfig.

function Save-LocalLLMConfig {
    param([Parameter(Mandatory = $true)][object]$Cfg)

    # Run the validator before writing so addllm/updatellm/removellm can't
    # persist a malformed catalog. Honor the same escape hatch as load-time
    # validation. Skip silently when the validator isn't loaded yet (e.g.
    # during early bootstrap or in test harnesses that hand-roll save calls).
    if ($env:LOCALBOX_SKIP_CATALOG_VALIDATION -ne '1' -and
        ($Cfg -is [System.Collections.IDictionary]) -and
        (Get-Command Test-LocalLLMCatalog -ErrorAction SilentlyContinue)) {
        Test-LocalLLMCatalog -Config $Cfg
    }

    $json = $Cfg | ConvertTo-Json -Depth 32
    $json = [regex]::Replace($json, '(?m)^( {4})+', { param($m) ' ' * ($m.Value.Length / 2) })

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($script:LocalLLMConfigPath, $json, $utf8NoBom)
}

function Add-LocalLLMModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$UrlOrRepo,
        [string]$Key,
        [string[]]$Quants,
        [string]$DefaultQuant,
        [ValidateSet('auto', 'none', 'qwen3coder', 'qwen36', 'qwen36-think')][string]$Parser = 'auto',
        [string]$DisplayName,
        [string]$Description,
        [string]$Root,
        [string]$QuantShortcut,
        [System.Collections.IDictionary]$Contexts,
        [System.Collections.IDictionary]$QuantNotes,
        [System.Collections.IDictionary]$ContextNotes,
        [bool]$LimitTools = $true,
        [ValidateSet('recommended', 'experimental', 'legacy')][string]$Tier = 'experimental',
        [Nullable[bool]]$Strict,
        # llama.cpp customization (all optional; persisted only when set).
        [int]$NGpuLayers,
        [int]$NCpuMoe,
        [Nullable[bool]]$Mlock,
        [Nullable[bool]]$NoMmap,
        [string]$ChatTemplate,
        [string]$KvCacheK,
        [string]$KvCacheV,
        [string[]]$Tags,
        [string[]]$ExtraArgs,
        [Nullable[bool]]$LlamaCppCompatible,
        [switch]$Force
    )

    $repo = Resolve-HuggingFaceRepo $UrlOrRepo
    Write-Host "HuggingFace repo: $repo" -ForegroundColor Cyan

    if ([string]::IsNullOrWhiteSpace($Key)) {
        $Key = (Read-Host "Model key (e.g. q27hauhau)").Trim()

        if ([string]::IsNullOrWhiteSpace($Key)) {
            throw "Model key is required."
        }
    }

    $cfg = Get-Content -Raw -Path $script:LocalLLMConfigPath | ConvertFrom-Json -AsHashtable

    if ($cfg.Models.Contains($Key) -and -not $Force) {
        throw "Model key '$Key' already exists. Use -Force to overwrite."
    }

    Write-Host "Fetching file list from HuggingFace..." -ForegroundColor Cyan
    $hfInfo = Get-HuggingFaceModelInfo -Repo $repo
    $allFiles = @($hfInfo.siblings | ForEach-Object { $_.rfilename })
    $sizesByFile = Get-HuggingFaceFileSizesGB -Info $hfInfo
    $ggufFiles = @(
        $allFiles | Where-Object {
            $_ -match '\.gguf$' -and
            $_ -notmatch '/' -and
            $_ -notmatch '^mmproj-' -and
            $_ -notmatch '\.imatrix\.gguf$'   # imatrix calibration data, not a quant
        }
    )

    if ($ggufFiles.Count -eq 0) {
        throw "No top-level GGUF files found at $repo."
    }

    $codeMap = [ordered]@{}

    foreach ($file in $ggufFiles) {
        $code = Get-HuggingFaceQuantCode -FileName $file

        if ($code) {
            $codeMap[$code] = $file
        }
    }

    if ($codeMap.Count -eq 0) {
        throw "No GGUF files with recognizable quant codes were found."
    }

    if ($Quants -and $Quants.Count -gt 0) {
        $filtered = [ordered]@{}
        $available = @($codeMap.Keys)

        foreach ($q in $Quants) {
            $upper = $q.ToUpperInvariant()
            $found = $available | Where-Object { $_ -ieq $upper } | Select-Object -First 1

            if ($found) {
                $filtered[$found] = $codeMap[$found]
            }
            else {
                Write-Warning "Quant '$upper' not found in repo. Available: $($available -join ', ')"
            }
        }

        if ($filtered.Count -eq 0) {
            throw "None of the requested quants were found. Available: $($available -join ', ')"
        }

        $codeMap = $filtered
    }

    $shortToFile = [ordered]@{}
    $codeToShort = @{}

    foreach ($code in $codeMap.Keys) {
        $short = ConvertTo-LocalLLMQuantKey $code
        $shortToFile[$short] = $codeMap[$code]
        $codeToShort[$code] = $short
    }

    if ([string]::IsNullOrWhiteSpace($DefaultQuant)) {
        $DefaultQuant = @($shortToFile.Keys)[0]
    }
    else {
        $upper = $DefaultQuant.ToUpperInvariant()

        if ($codeToShort.ContainsKey($upper)) {
            $DefaultQuant = $codeToShort[$upper]
        }
        elseif (-not $shortToFile.Contains($DefaultQuant)) {
            throw "DefaultQuant '$DefaultQuant' is not in the selected quants: $(@($shortToFile.Keys) -join ', ')"
        }
    }

    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = $Key }

    if ($Parser -eq 'auto') {
        $Parser = Suggest-LocalLLMParser -Repo $repo
    }

    if ([string]::IsNullOrWhiteSpace($DisplayName)) {
        $DisplayName = Format-LocalLLMDisplayName -Repo $repo
    }

    if (-not $Contexts) {
        $Contexts = Get-LocalLLMDefaultContexts
    }

    # Strict sibling: ask once at import time. The answer is persisted on the
    # entry as `Strict: $true/$false`, so future Ensure-ModelAllAliases calls
    # rebuild the strict alias without re-prompting. Default Yes when the
    # caller doesn't pass -Strict explicitly.
    if ($null -eq $Strict) {
        $answer = (Read-Host "Build a strict-mode sibling alias for this model? [Y/n]").Trim().ToLowerInvariant()
        $Strict = -not ($answer -in @('n', 'no'))
    }

    # Build a quant -> size map for the selected quants (used for QuantSizesGB
    # and as input to the auto-generated QuantNotes below).
    $quantSizesGB = [ordered]@{}
    foreach ($short in $shortToFile.Keys) {
        $file = $shortToFile[$short]
        if ($sizesByFile.Contains($file)) {
            $quantSizesGB[$short] = $sizesByFile[$file]
        }
    }

    # Auto-fill Description from HF (cardData → base_model README → this README)
    # if the caller didn't provide one. Verbose-only so the dashboard stays calm.
    if ([string]::IsNullOrWhiteSpace($Description)) {
        Write-Host "Resolving description from HuggingFace..." -ForegroundColor DarkCyan
        $auto = Resolve-HuggingFaceDescription -Repo $repo
        if (-not [string]::IsNullOrWhiteSpace($auto)) {
            $Description = $auto
            Write-Host "  $Description" -ForegroundColor DarkGray
        } else {
            Write-Host "  (no usable README description found — leaving Description empty)" -ForegroundColor DarkGray
        }
    }

    # Auto-fill generic QuantNotes from the quant code + size when the user
    # didn't pass any. Hand-tuned notes (e.g. "use this for -Ctx 256") stay manual.
    $autoQuantNotes = $null
    if (-not $QuantNotes -or $QuantNotes.Count -eq 0) {
        $autoQuantNotes = [ordered]@{}
        foreach ($code in $codeMap.Keys) {
            $short = $codeToShort[$code]
            $size = if ($quantSizesGB.Contains($short)) { $quantSizesGB[$short] } else { $null }
            $note = New-LocalLLMQuantNoteText -QuantCode $code -SizeGB $size
            if ($note) { $autoQuantNotes[$short] = $note }
        }
    }

    $entry = [ordered]@{
        DisplayName = $DisplayName
        Root        = $Root
        SourceType  = 'gguf'
        Repo        = $repo
        Quants      = $shortToFile
        Quant       = $DefaultQuant
        Parser      = $Parser
        LimitTools  = $LimitTools
        Tier        = $Tier
        Contexts    = $Contexts
        Strict      = [bool]$Strict
    }

    if (-not [string]::IsNullOrWhiteSpace($Description)) {
        $entry.Description = $Description
    }

    if ($quantSizesGB.Count -gt 0) {
        $entry.QuantSizesGB = $quantSizesGB
    }

    if ($QuantNotes -and $QuantNotes.Count -gt 0) {
        $entry.QuantNotes = $QuantNotes
    } elseif ($autoQuantNotes -and $autoQuantNotes.Count -gt 0) {
        $entry.QuantNotes = $autoQuantNotes
    }

    if ($ContextNotes -and $ContextNotes.Count -gt 0) {
        $entry.ContextNotes = $ContextNotes
    }

    # QuantShortcut is deprecated — only kept for legacy-cleanup paths. Set
    # explicitly via -QuantShortcut if you need it; not auto-defaulted.
    if (-not [string]::IsNullOrWhiteSpace($QuantShortcut)) {
        $entry.QuantShortcut = $QuantShortcut
    }

    # llama.cpp opt-in fields. Persist only when the caller passed a value so
    # entries stay tidy and a missing key continues to mean "use the default".
    if ($PSBoundParameters.ContainsKey('NGpuLayers') -and $NGpuLayers -gt 0)              { $entry.NGpuLayers = $NGpuLayers }
    if ($PSBoundParameters.ContainsKey('NCpuMoe')    -and $NCpuMoe    -gt 0)              { $entry.NCpuMoe    = $NCpuMoe }
    if ($PSBoundParameters.ContainsKey('Mlock')      -and $null -ne $Mlock)               { $entry.Mlock      = [bool]$Mlock }
    if ($PSBoundParameters.ContainsKey('NoMmap')     -and $null -ne $NoMmap)              { $entry.NoMmap     = [bool]$NoMmap }
    if (-not [string]::IsNullOrWhiteSpace($ChatTemplate))                                  { $entry.ChatTemplate = $ChatTemplate }
    if (-not [string]::IsNullOrWhiteSpace($KvCacheK))                                      { $entry.KvCacheK   = $KvCacheK }
    if (-not [string]::IsNullOrWhiteSpace($KvCacheV))                                      { $entry.KvCacheV   = $KvCacheV }
    if ($Tags      -and $Tags.Count      -gt 0)                                            { $entry.Tags       = @($Tags) }
    if ($ExtraArgs -and $ExtraArgs.Count -gt 0)                                            { $entry.ExtraArgs  = @($ExtraArgs) }
    if ($PSBoundParameters.ContainsKey('LlamaCppCompatible') -and $null -ne $LlamaCppCompatible) {
        $entry.LlamaCppCompatible = [bool]$LlamaCppCompatible
    }

    # Check for mmproj (multimodal vision module). Prompt the user to download.
    if ($PSBoundParameters.ContainsKey('Mmproj')) {
        $mmprojFile = [string]$Mmproj
        if (-not [string]::IsNullOrWhiteSpace($mmprojFile)) {
            $entry.VisionModule = $mmprojFile
        }
    }
    else {
        $mmprojFiles = Get-HuggingFaceMmprojFiles -Repo $repo
        if ($mmprojFiles.Count -gt 0) {
            $mmprojNames = @($mmprojFiles.Keys) -join ', '
            Write-Host "Vision modules (mmproj.gguf) found: $mmprojNames" -ForegroundColor DarkCyan

            $answer = (Read-Host "Download a vision module? [Y/n]").Trim().ToLowerInvariant()
            if ($answer -notin @('n', 'no')) {
                # Prefer the first available mmproj; fall back to user selection
                $chosen = $mmprojNames[0]
                $chosen = Read-Host "Which one? (default: $chosen)"
                if ([string]::IsNullOrWhiteSpace($chosen)) {
                    $chosen = [string]$mmprojFiles.Keys | Select-Object -First 1
                }

                if ($mmprojFiles.ContainsKey($chosen)) {
                    $entry.VisionModule = $chosen
                    Write-Host "Vision module set to: $chosen" -ForegroundColor DarkGray
                }
            }
        }
    }

    if ($cfg.Models.Contains($Key)) {
        $cfg.Models.Remove($Key)
    }

    $cfg.Models[$Key] = $entry

    Save-LocalLLMConfig -Cfg $cfg

    Write-Host ""
    Write-Host "Added '$Key' to $script:LocalLLMConfigPath" -ForegroundColor Green
    Write-Host "  Display  : $DisplayName" -ForegroundColor DarkGray
    if (-not [string]::IsNullOrWhiteSpace($Description)) {
        Write-Host "  About    : $Description" -ForegroundColor DarkGray
    }
    Write-Host "  Repo     : $repo" -ForegroundColor DarkGray
    Write-Host "  Parser   : $Parser" -ForegroundColor DarkGray
    Write-Host "  Quants   : $(@($shortToFile.Keys) -join ', ')  (default: $DefaultQuant)" -ForegroundColor DarkGray

    $ctxLabels = @($Contexts.Keys | ForEach-Object {
            if ([string]::IsNullOrEmpty($_)) { 'default' } else { $_ }
        })
    Write-Host "  Contexts : $($ctxLabels -join ', ')" -ForegroundColor DarkGray
    if ([bool]$Strict) {
        Write-Host "  Strict   : yes  ('initmodel $Key' will also build $Root-strict)" -ForegroundColor DarkGray
    }
    Write-Host ""

    Reload-LocalLLMConfig

    Write-Host "Run 'initmodel $Key' to download the GGUF and create Ollama aliases." -ForegroundColor Yellow
}

function addllm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$UrlOrRepo,
        [string]$Key,
        [string[]]$Quants,
        [string]$DefaultQuant,
        [string]$Parser = 'auto',
        [string]$DisplayName,
        [string]$Description,
        [string]$Root,
        [string]$QuantShortcut,
        [System.Collections.IDictionary]$QuantNotes,
        [System.Collections.IDictionary]$ContextNotes,
        [bool]$LimitTools = $true,
        [string]$Tier = 'experimental',
        [Nullable[bool]]$Strict,
        [int]$NGpuLayers,
        [int]$NCpuMoe,
        [Nullable[bool]]$Mlock,
        [Nullable[bool]]$NoMmap,
        [string]$ChatTemplate,
        [string]$KvCacheK,
        [string]$KvCacheV,
        [string[]]$Tags,
        [string[]]$ExtraArgs,
        [Nullable[bool]]$LlamaCppCompatible,
        [string]$Mmproj,
        [switch]$Force
    )

    Add-LocalLLMModel @PSBoundParameters
}

function Update-LocalLLMModelQuants {
    # Backfills missing quants on an existing GGUF model entry by re-fetching
    # the HF repo and adding any quant codes not already in the entry. Existing
    # Quants/QuantSizesGB/QuantNotes entries are preserved verbatim — only new
    # keys are added. Auto-generates a baseline note for new quants when the
    # entry already has a QuantNotes hashtable.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Key,
        [switch]$DryRun
    )

    $cfg = Get-Content -Raw -Path $script:LocalLLMConfigPath | ConvertFrom-Json -AsHashtable

    if (-not $cfg.Models.Contains($Key)) {
        throw "Model key '$Key' not found in $script:LocalLLMConfigPath."
    }

    $entry = $cfg.Models[$Key]

    if ($entry.SourceType -ne 'gguf') {
        throw "Model '$Key' is SourceType=$($entry.SourceType); only gguf models have quants."
    }
    if (-not $entry.ContainsKey('Repo') -or [string]::IsNullOrWhiteSpace($entry.Repo)) {
        throw "Model '$Key' has no Repo; cannot fetch HF metadata."
    }
    if (-not $entry.ContainsKey('Quants')) {
        throw "Model '$Key' has no Quants section. Use 'addllm' instead."
    }

    $repo = $entry.Repo
    Write-Host "Fetching HF metadata for $repo..." -ForegroundColor Cyan
    $hfInfo = Get-HuggingFaceModelInfo -Repo $repo
    $allFiles = @($hfInfo.siblings | ForEach-Object { $_.rfilename })
    $sizesByFile = Get-HuggingFaceFileSizesGB -Info $hfInfo
    $ggufFiles = @(
        $allFiles | Where-Object {
            $_ -match '\.gguf$' -and
            $_ -notmatch '/' -and
            $_ -notmatch '^mmproj-' -and
            $_ -notmatch '\.imatrix\.gguf$'
        }
    )

    if ($ggufFiles.Count -eq 0) {
        throw "No top-level GGUF files found at $repo."
    }

    $existingShortKeys = @($entry.Quants.Keys)
    $existingFiles = @($entry.Quants.Values)
    $addedCount = 0

    foreach ($file in $ggufFiles) {
        if ($existingFiles -contains $file) { continue }

        $code = Get-HuggingFaceQuantCode -FileName $file
        if (-not $code) { continue }

        $short = ConvertTo-LocalLLMQuantKey $code
        if ($existingShortKeys -contains $short) { continue }

        $size = if ($sizesByFile.Contains($file)) { $sizesByFile[$file] } else { $null }
        $note = New-LocalLLMQuantNoteText -QuantCode $code -SizeGB $size

        $sizeStr = if ($null -eq $size) { '?' } else { ('{0:N1}' -f $size) }
        Write-Host ("  + {0,-8} {1,6} GB  {2}" -f $short, $sizeStr, $file) -ForegroundColor Green

        if ($DryRun) {
            $addedCount++
            continue
        }

        $entry.Quants[$short] = $file

        if ($null -ne $size) {
            if (-not $entry.ContainsKey('QuantSizesGB')) {
                $entry.QuantSizesGB = [ordered]@{}
            }
            $entry.QuantSizesGB[$short] = $size
        }

        if ($entry.ContainsKey('QuantNotes') -and -not [string]::IsNullOrWhiteSpace($note)) {
            if (-not $entry.QuantNotes.Contains($short)) {
                $entry.QuantNotes[$short] = $note
            }
        }

        $addedCount++
    }

    if ($addedCount -eq 0) {
        Write-Host "  (no new quants — entry already has every recognized GGUF in $repo)" -ForegroundColor DarkGray
    }

    # Also check for mmproj files on updatellm.
    $mmprojFiles = Get-HuggingFaceMmprojFiles -Repo $repo
    if ($mmprojFiles.Count -gt 0) {
        if (-not $entry.ContainsKey('VisionModule')) {
            $mmprojNames = @($mmprojFiles.Keys) -join ', '
            Write-Host "Vision modules (mmproj.gguf) found: $mmprojNames" -ForegroundColor DarkCyan

            $answer = (Read-Host "Download a vision module? [Y/n]").Trim().ToLowerInvariant()
            if ($answer -notin @('n', 'no')) {
                $chosen = Read-Host "Which one? (default: $($mmprojFiles.Keys | Select-Object -First 1))"
                if ([string]::IsNullOrWhiteSpace($chosen)) {
                    $chosen = [string]$mmprojFiles.Keys | Select-Object -First 1
                }
                if ($mmprojFiles.ContainsKey($chosen)) {
                    $entry.VisionModule = $chosen
                    Write-Host "Vision module set to: $chosen" -ForegroundColor DarkGray
                }
            }
        }
        else {
            Write-Host "Vision module already configured: $($entry.VisionModule)" -ForegroundColor DarkGray
        }
    }

    if ($DryRun) {
        Write-Host ""
        Write-Host "Dry-run: would add $addedCount quant(s) to '$Key'. Re-run without -DryRun to write." -ForegroundColor Yellow
        return
    }

    Save-LocalLLMConfig -Cfg $cfg

    Write-Host ""
    Write-Host "Added $addedCount quant(s) to '$Key' in $script:LocalLLMConfigPath." -ForegroundColor Green
    Reload-LocalLLMConfig

    Write-Host "Run 'initmodel $Key' to download the new quants on demand (only when you launch a context that needs them)." -ForegroundColor Yellow
}

function updatellm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Key,
        [switch]$DryRun
    )

    Update-LocalLLMModelQuants @PSBoundParameters
}

function Get-RegisteredShortcutNamesForModel {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def)

    $names = New-Object System.Collections.Generic.List[string]
    $suffixes = @("", "q8", "chat")

    foreach ($base in (Get-ModelAliasNames -Def $Def)) {
        foreach ($suffix in $suffixes) {
            $names.Add("$base$suffix") | Out-Null
        }
    }

    if ($Def.ContainsKey("Quants") -and $Def.ContainsKey("QuantShortcut")) {
        foreach ($quantKey in $Def.Quants.Keys) {
            $names.Add("set$($Def.QuantShortcut)$quantKey") | Out-Null
        }
    }

    return @($names)
}

function Remove-LocalLLMModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Key,
        [switch]$KeepFiles,
        [switch]$Force
    )

    $cfg = Get-Content -Raw -Path $script:LocalLLMConfigPath | ConvertFrom-Json -AsHashtable

    if (-not $cfg.Models.Contains($Key)) {
        throw "Unknown model key: $Key. Known keys: $(@($cfg.Models.Keys) -join ', ')"
    }

    $def = $cfg.Models[$Key]
    $aliasNames = @(Get-ModelAliasNames -Def $def)
    $folder = $null

    if ($def.SourceType -eq 'gguf' -and -not $KeepFiles) {
        $folder = Join-Path $script:Cfg.OllamaCommunityRoot $def.Root
    }

    Write-Host ""
    Write-Host "Will remove '$Key'  ($($def.DisplayName))" -ForegroundColor Yellow
    Write-Host "  Ollama aliases : $($aliasNames -join ', ')"

    if ($def.SourceType -eq 'remote') {
        Write-Host "  Ollama pull    : $($def.RemoteModel)"
    }

    if ($folder) {
        Write-Host "  GGUF folder    : $folder  (will be deleted)"
    }
    elseif ($def.SourceType -eq 'gguf') {
        Write-Host "  GGUF folder    : kept (-KeepFiles)"
    }

    Write-Host "  JSON entry     : Models.$Key"

    $hostedAliases = New-Object System.Collections.Generic.List[string]
    $shortcutNames = Get-RegisteredShortcutNamesForModel -Def $def

    foreach ($alias in @($cfg.CommandAliases.Keys)) {
        $target = $cfg.CommandAliases[$alias]

        if ($shortcutNames -contains $target -or $alias -in $shortcutNames) {
            $hostedAliases.Add($alias) | Out-Null
        }
    }

    if ($hostedAliases.Count -gt 0) {
        Write-Host "  CommandAliases : $($hostedAliases -join ', ')"
    }

    if (-not $Force) {
        Write-Host ""
        $answer = (Read-Host "Type 'yes' to proceed").Trim()

        if ($answer -ne 'yes') {
            Write-Host "Aborted." -ForegroundColor DarkGray
            return
        }
    }

    Stop-OllamaModels
    Remove-ModelAliases -Key $Key
    Remove-ModelRemotePull -Key $Key

    if ($folder -and (Test-Path $folder)) {
        Remove-Item -Recurse -Force $folder -ErrorAction SilentlyContinue
    }

    foreach ($alias in $hostedAliases) {
        $cfg.CommandAliases.Remove($alias)

        $existingAlias = Get-Item -Path "Alias:$alias" -ErrorAction SilentlyContinue
        if ($existingAlias) {
            Remove-Item -Path "Alias:$alias" -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($shortcutName in $shortcutNames) {
        Remove-Item -Path "function:global:$shortcutName" -Force -ErrorAction SilentlyContinue
    }

    $cfg.Models.Remove($Key)

    Save-LocalLLMConfig -Cfg $cfg

    Reload-LocalLLMConfig

    Write-Host ""
    Write-Host "Removed '$Key'." -ForegroundColor Green
}

function removellm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Key,
        [switch]$KeepFiles,
        [switch]$Force
    )

    Remove-LocalLLMModel @PSBoundParameters
}

function rmllm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Key,
        [switch]$KeepFiles,
        [switch]$Force
    )

    Remove-LocalLLMModel @PSBoundParameters
}

# Orphan Ollama models: present locally but not in llm-models.json.

function Get-AllManagedOllamaNames {
    # Names this profile considers "managed" -- every alias the catalog declares
    # as well as the upstream remote pull (e.g. "devstral-small-2:latest"), with
    # and without ":latest" so matches against `ollama list` succeed both ways.
    $names = New-Object System.Collections.Generic.Hashset[string] ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($key in (Get-ModelKeys)) {
        $def = Get-ModelDef -Key $key

        foreach ($alias in (Get-ModelAliasNames -Def $def)) {
            $names.Add($alias) | Out-Null
            $names.Add("${alias}:latest") | Out-Null
        }

        # Strict siblings — managed regardless of the current Strict flag, so
        # leftovers from a previous build don't get classified as orphans
        # before the next 'init -Force' or 'removellm' rebuilds the entry.
        foreach ($contextKey in $def.Contexts.Keys) {
            $strictName = Get-ModelStrictAliasName -Def $def -ContextKey $contextKey
            $names.Add($strictName) | Out-Null
            $names.Add("${strictName}:latest") | Out-Null
        }

        if ($def.SourceType -eq 'remote' -and $def.RemoteModel) {
            $names.Add($def.RemoteModel) | Out-Null

            if ($def.RemoteModel -notlike '*:*') {
                $names.Add("$($def.RemoteModel):latest") | Out-Null
            }
            elseif ($def.RemoteModel -like '*:latest') {
                $names.Add($def.RemoteModel.Substring(0, $def.RemoteModel.Length - 7)) | Out-Null
            }
        }
    }

    return $names
}

function Find-OrphanOllamaModels {
    [CmdletBinding()]
    param()

    $managed = Get-AllManagedOllamaNames
    $rawList = & ollama list 2>$null | Select-Object -Skip 1
    $orphans = New-Object System.Collections.Generic.List[pscustomobject]

    foreach ($line in $rawList) {
        if (-not $line.Trim()) { continue }

        $parts = $line -split '\s+'
        if ($parts.Count -lt 3) { continue }

        $name = $parts[0]

        if ($managed.Contains($name)) { continue }

        $base = if ($name -like '*:latest') { $name.Substring(0, $name.Length - 7) } else { $name }
        if ($managed.Contains($base)) { continue }

        $orphans.Add([pscustomobject]@{
                Name = $name
                Id   = $parts[1]
                Size = ($parts[2..3] -join ' ')
            }) | Out-Null
    }

    return $orphans
}

function Remove-OrphanOllamaModels {
    [CmdletBinding()]
    param([switch]$Force)

    $orphans = @(Find-OrphanOllamaModels)

    if ($orphans.Count -eq 0) {
        Write-Host "No orphan Ollama models found." -ForegroundColor Green
        return
    }

    Write-Host ""
    Write-Host "Orphan Ollama models (in 'ollama list' but not in llm-models.json):" -ForegroundColor Yellow
    Write-Host ""
    $orphans | Format-Table -AutoSize | Out-String | Write-Host

    if (-not $Force) {
        $answer = (Read-Host "Type 'yes' to remove all $($orphans.Count) orphan model(s)").Trim()

        if ($answer -ne 'yes') {
            Write-Host "Aborted." -ForegroundColor DarkGray
            return
        }
    }

    Stop-OllamaModels

    foreach ($orphan in $orphans) {
        Write-Host "Removing $($orphan.Name)..." -ForegroundColor DarkGray
        & ollama rm $orphan.Name 2>$null | Out-Null
    }

    Write-Host ""
    Write-Host "Removed $($orphans.Count) orphan model(s)." -ForegroundColor Green
}

function cleanorphans {
    [CmdletBinding()]
    param([switch]$Force)

    Remove-OrphanOllamaModels -Force:$Force
}

function listorphans {
    $orphans = @(Find-OrphanOllamaModels)

    if ($orphans.Count -eq 0) {
        Write-Host "No orphan Ollama models." -ForegroundColor Green
        return
    }

    $orphans | Format-Table -AutoSize
}
