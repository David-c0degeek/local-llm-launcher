# Catalog access + alias-name conventions. Reload-LocalLLMConfig lives here too
# (it's the public reload; depends on Import-LocalLLMConfig from settings and on
# Register-ModelShortcuts from the shortcuts module). Get-ModelGgufPath calls
# Download-HuggingFaceFile (helpers) and Get-ModelFolder (this file).

function Reload-LocalLLMConfig {
    $script:Cfg = Import-LocalLLMConfig
    $script:NoThinkProxyPort = [int]$script:Cfg.NoThinkProxyPort
    Register-ModelShortcuts
    Write-Host "Reloaded LocalBox config: $script:LocalLLMConfigPath" -ForegroundColor Green
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
    # The folder where this model's GGUF (or downloaded artifacts) live.
    # Default backend is ollama for backwards compatibility — every existing
    # caller assumes the Ollama community root.
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [ValidateSet('ollama', 'llamacpp')][string]$Backend = 'ollama'
    )

    $root = if ($Backend -eq 'llamacpp') {
        $script:Cfg.LlamaCppGgufRoot
    } else {
        $script:Cfg.OllamaCommunityRoot
    }

    $folder = Join-Path $root $Def.Root
    Ensure-Directory $folder
    return $folder
}

function Copy-OllamaGgufToLlamaCpp {
    # When the llama.cpp folder is missing a GGUF that already exists under the
    # Ollama root, hardlink it instead of re-downloading. Same bytes either way;
    # both backends see the same file; deletes from one don't break the other.
    # Returns $true if a link was created.
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [Parameter(Mandatory = $true)][string]$LlamaCppFolder
    )

    $fileName = Get-ModelFileName -Def $Def
    if ([string]::IsNullOrWhiteSpace($fileName)) { return $false }

    $llamaPath = Resolve-HuggingFaceLocalPath -DestinationFolder $LlamaCppFolder -FileName $fileName
    if (Test-Path $llamaPath) { return $false }

    if ([string]::IsNullOrWhiteSpace($script:Cfg.OllamaCommunityRoot)) { return $false }
    $ollamaFolder = Join-Path $script:Cfg.OllamaCommunityRoot $Def.Root
    $ollamaPath = Resolve-HuggingFaceLocalPath -DestinationFolder $ollamaFolder -FileName $fileName
    if (-not (Test-Path $ollamaPath)) { return $false }

    $parent = Split-Path -Parent $llamaPath
    Ensure-Directory $parent

    try {
        New-Item -ItemType HardLink -Path $llamaPath -Target $ollamaPath -ErrorAction Stop | Out-Null
        Write-Host "Hardlinked existing GGUF: $llamaPath -> $ollamaPath" -ForegroundColor DarkGreen
        return $true
    }
    catch {
        # Hardlinks fail across volumes; fall back to a regular copy.
        try {
            Copy-Item -LiteralPath $ollamaPath -Destination $llamaPath -ErrorAction Stop
            Write-Host "Copied existing GGUF (cross-volume): $llamaPath" -ForegroundColor DarkGreen
            return $true
        }
        catch {
            Write-Warning "Could not reuse Ollama GGUF at $ollamaPath : $($_.Exception.Message)"
            return $false
        }
    }
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

    $ContextKey = Resolve-ModelContextKey -Def $Def -ContextKey $ContextKey

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

    $ContextKey = Resolve-ModelContextKey -Def $Def -ContextKey $ContextKey
    return $Def.Contexts[$ContextKey]
}

function Resolve-ModelContextKey {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [AllowEmptyString()][string]$ContextKey
    )

    if ([string]::IsNullOrWhiteSpace($ContextKey)) {
        $ContextKey = ''
    }

    if ($Def.Contexts.Contains($ContextKey)) {
        return $ContextKey
    }

    foreach ($key in $Def.Contexts.Keys) {
        if ([string]$key -ieq $ContextKey) {
            return [string]$key
        }
    }

    $legacyAliases = @{
        'fast' = '32k'
        'deep' = '64k'
        '128'  = '128k'
    }

    $aliasKey = $ContextKey.ToLowerInvariant()
    if ($legacyAliases.ContainsKey($aliasKey)) {
        $target = $legacyAliases[$aliasKey]
        if ($Def.Contexts.Contains($target)) {
            return $target
        }
    }

    $available = @($Def.Contexts.Keys | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_)) { 'default' } else { [string]$_ }
    }) -join ', '
    throw "Unknown context '$ContextKey'. Available: $available"
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

    $ContextKey = Resolve-ModelContextKey -Def $Def -ContextKey $ContextKey

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
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [AllowEmptyString()][string]$ContextKey = ''
    )

    if ([string]::IsNullOrWhiteSpace($ContextKey)) {
        return "$($Def.Root)-strict"
    }

    $baseAliasName = Get-ModelAliasName -Def $Def -ContextKey $ContextKey
    return "$baseAliasName-strict"
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
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [ValidateSet('ollama', 'llamacpp')][string]$Backend = 'ollama'
    )

    $folder = Get-ModelFolder -Key $Key -Def $Def -Backend $Backend
    $fileName = Get-ModelFileName -Def $Def

    # Reuse an existing Ollama GGUF for the llama.cpp path before downloading.
    if ($Backend -eq 'llamacpp') {
        Copy-OllamaGgufToLlamaCpp -Def $Def -LlamaCppFolder $folder | Out-Null
    }

    $ggufPath = Download-HuggingFaceFile -Repo $Def.Repo -FileName $fileName -DestinationFolder $folder

    if ($ggufPath -is [array]) {
        $ggufPath = $ggufPath[-1]
    }

    if (-not ($ggufPath -is [string])) {
        throw "Expected GGUF path to be a string."
    }

    return $ggufPath
}

function Get-ModelVisionModulePath {
    # Resolves the full path to the mmproj.gguf (multimodal vision module) for a model.
    # Downloads on demand if not already present locally. Returns $null when no
    # VisionModule is configured or the file does not exist.
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [ValidateSet('ollama', 'llamacpp')][string]$Backend = 'ollama'
    )

    $mmprojFile = $null
    $autoDetected = $false

    if ($Def.ContainsKey('VisionModule') -and -not [string]::IsNullOrWhiteSpace($Def.VisionModule)) {
        $mmprojFile = [string]$Def.VisionModule
        Write-LaunchLog "VisionModule configured: $mmprojFile" 'VISION'
    } else {
        # Auto-detect: scan for mmproj*.gguf in the model folder
        $folder = Get-ModelFolder -Key $Key -Def $Def -Backend $Backend
        Write-LaunchLog "No VisionModule configured — scanning for mmproj*.gguf in $folder" 'VISION'
        $localMmproj = Get-ChildItem -Path $folder -Filter 'mmproj*.gguf' -File | Select-Object -First 1
        if ($localMmproj) {
            $mmprojFile = $localMmproj.Name
            $autoDetected = $true
            Write-LaunchLog "Auto-detected mmproj: $($localMmproj.Name)" 'VISION'
        } else {
            # Also check Ollama root for llama.cpp backend
            if ($Backend -eq 'llamacpp' -and -not [string]::IsNullOrWhiteSpace($script:Cfg.OllamaCommunityRoot)) {
                $ollamaFolder = Join-Path $script:Cfg.OllamaCommunityRoot $Def.Root
                Write-LaunchLog "Scanning Ollama root for mmproj*.gguf: $ollamaFolder" 'VISION'
                $localMmproj = Get-ChildItem -Path $ollamaFolder -Filter 'mmproj*.gguf' -File | Select-Object -First 1
                if ($localMmproj) {
                    $mmprojFile = $localMmproj.Name
                    $autoDetected = $true
                    Write-LaunchLog "Auto-detected mmproj in Ollama root: $($localMmproj.Name)" 'VISION'
                }
            }
        }
        if (-not $mmprojFile) {
            if ($Def.ContainsKey('Repo') -and -not [string]::IsNullOrWhiteSpace($Def.Repo)) {
                Write-LaunchLog "No local mmproj found, querying HF: $($Def.Repo)" 'VISION'
                $hfFiles = Get-HuggingFaceMmprojFiles -Repo $Def.Repo
                if ($null -eq $hfFiles) {
                    Write-LaunchLog "HF query failed (network/SSL) — skipping HF fallback for $Key" 'WARN'
                } elseif ($hfFiles.Count -gt 0) {
                    $mmprojFile = @($hfFiles.Keys)[0]
                    Write-LaunchLog "Found mmproj on HF: $mmprojFile" 'VISION'
                }
            }
            if (-not $mmprojFile) {
                Write-LaunchLog "No mmproj found locally or on HF for $Key" 'WARN'
                return $null
            }
        }
    }

    $folder = Get-ModelFolder -Key $Key -Def $Def -Backend $Backend

    # For llama.cpp, try to hardlink from Ollama root first.
    if ($Backend -eq 'llamacpp') {
        $llamaPath = Resolve-HuggingFaceLocalPath -DestinationFolder $folder -FileName $mmprojFile
        if (Test-Path $llamaPath) {
            Write-LaunchLog "Found existing mmproj in llama.cpp folder: $llamaPath" 'VISION'
            return $llamaPath
        }

        if (-not [string]::IsNullOrWhiteSpace($script:Cfg.OllamaCommunityRoot)) {
            $ollamaFolder = Join-Path $script:Cfg.OllamaCommunityRoot $Def.Root
            $ollamaPath = Resolve-HuggingFaceLocalPath -DestinationFolder $ollamaFolder -FileName $mmprojFile
            if (Test-Path $ollamaPath) {
                Write-LaunchLog "Found mmproj in Ollama root, linking to llama.cpp: $ollamaPath -> $llamaPath" 'VISION'
                try {
                    New-Item -ItemType HardLink -Path $llamaPath -Target $ollamaPath -ErrorAction Stop | Out-Null
                    Write-Host "Hardlinked existing mmproj: $llamaPath -> $ollamaPath" -ForegroundColor DarkGreen
                    return $llamaPath
                } catch {
                    try {
                        Copy-Item -LiteralPath $ollamaPath -Destination $llamaPath -ErrorAction Stop | Out-Null
                        Write-Host "Copied existing mmproj (cross-volume): $llamaPath" -ForegroundColor DarkGreen
                        return $llamaPath
                    } catch {
                        Write-Warning "Could not reuse Ollama mmproj at $ollamaPath : $($_.Exception.Message)"
                    }
                }
            } else {
                Write-LaunchLog "mmproj not in Ollama root, will download to $folder" 'VISION'
            }
        }
    }

    if ($autoDetected) {
        Write-LaunchLog "Reusing auto-detected mmproj: $mmprojFile" 'VISION'
        $localPath = Resolve-HuggingFaceLocalPath -DestinationFolder $folder -FileName $mmprojFile
        if (Test-Path $localPath) {
            return $localPath
        }
    }

    Write-LaunchLog "Downloading mmproj from HF repo: $($Def.Repo), file: $mmprojFile" 'VISION'
    $mmprojPath = Download-HuggingFaceFile -Repo $Def.Repo -FileName $mmprojFile -DestinationFolder $folder

    if ($mmprojPath -is [array]) {
        $mmprojPath = $mmprojPath[-1]
    }

    if (-not ($mmprojPath -is [string])) {
        throw "Expected mmproj path to be a string."
    }

    Write-LaunchLog "Resolved mmproj path: $mmprojPath" 'VISION'
    return $mmprojPath
}

function Test-ModelVisionModuleAvailable {
    # Checks whether the mmproj.gguf for a model exists locally, and if not,
    # whether it is available on HuggingFace. Returns a hashtable with:
    #   Local        : $true/$false  (file exists in the model folder or Ollama root)
    #   AvailableOnHF: $true/$false  (mmproj file listed on the HF repo)
    #   Filename     : ''            (the mmproj filename, when known)
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [ValidateSet('ollama', 'llamacpp')][string]$Backend = 'ollama'
    )

    $result = @{
        Local           = $false
        AvailableOnHF   = $false
        Filename        = ''
    }

    # Determine which mmproj filename to look for. If VisionModule is configured, use that;
    # otherwise scan HF for any available mmproj files.
    $mmprojFile = if ($Def.ContainsKey('VisionModule') -and -not [string]::IsNullOrWhiteSpace($def.VisionModule)) {
        Write-LaunchLog "[vision/test] VisionModule configured: $($def.VisionModule)"  'VISION'
        [string]$Def.VisionModule
    } else {
        Write-LaunchLog "[vision/test] No VisionModule configured, will auto-detect"  'VISION'
        ''
    }

    if ($mmprojFile) {
        $result.Filename = $mmprojFile
    }
    $folder = Get-ModelFolder -Key $Key -Def $Def -Backend $Backend
    Write-LaunchLog "[vision/test] Checking local mmproj for $Key (backend=$Backend, folder=$folder)"  'VISION'

    # Check llama.cpp folder first.
    if ($Backend -eq 'llamacpp') {
        if ($mmprojFile) {
            $llamaPath = Resolve-HuggingFaceLocalPath -DestinationFolder $folder -FileName $mmprojFile
            Write-LaunchLog "[vision/test]  llama.cpp: checking $($llamaPath) ..."  'VISION'
            if (Test-Path $llamaPath) {
                Write-LaunchLog "[vision/test]  Found in llama.cpp folder"  'VISION'
                $result.Local = $true
                return $result
            }
        } else {
            # No VisionModule configured — scan for any mmproj files locally
            $localMmproj = Get-ChildItem -Path $folder -Filter 'mmproj*.gguf' -File | Select-Object -First 1
            if ($localMmproj) {
                Write-LaunchLog "[vision/test]  Auto-detected $($localMmproj.Name) in llama.cpp folder"  'VISION'
                $result.Local = $true
                $result.Filename = $localMmproj.Name
                return $result
            }
        }

        # Also check Ollama root as fallback.
        if (-not [string]::IsNullOrWhiteSpace($script:Cfg.OllamaCommunityRoot)) {
            $ollamaFolder = Join-Path $script:Cfg.OllamaCommunityRoot $Def.Root
            if ($mmprojFile) {
                $ollamaPath = Resolve-HuggingFaceLocalPath -DestinationFolder $ollamaFolder -FileName $mmprojFile
                Write-LaunchLog "[vision/test]  Ollama root: checking $($ollamaPath) ..."  'VISION'
                if (Test-Path $ollamaPath) {
                    Write-LaunchLog "[vision/test]  Found in Ollama root"
                    $result.Local = $true
                    return $result
                }
            } else {
                $localMmproj = Get-ChildItem -Path $ollamaFolder -Filter 'mmproj*.gguf' -File | Select-Object -First 1
                if ($localMmproj) {
                    Write-LaunchLog "[vision/test]  Auto-detected $($localMmproj.Name) in Ollama root"  'VISION'
                    $result.Local = $true
                    $result.Filename = $localMmproj.Name
                    return $result
                }
            }
        }
    }

    # Check Ollama root for ollama backend.
    if ($Backend -eq 'ollama') {
        $ollamaFolder = Join-Path $script:Cfg.OllamaCommunityRoot $Def.Root
        if ($mmprojFile) {
            $ollamaPath = Resolve-HuggingFaceLocalPath -DestinationFolder $ollamaFolder -FileName $mmprojFile
            Write-LaunchLog "[vision/test]  Ollama: checking $($ollamaPath) ..."  'VISION'
            if (Test-Path $ollamaPath) {
                Write-LaunchLog "[vision/test]  Found in Ollama folder"  'VISION'
                $result.Local = $true
                return $result
            }
        } else {
            $localMmproj = Get-ChildItem -Path $ollamaFolder -Filter 'mmproj*.gguf' -File | Select-Object -First 1
            if ($localMmproj) {
                Write-LaunchLog "[vision/test]  Auto-detected $($localMmproj.Name) in Ollama root"  'VISION'
                $result.Local = $true
                $result.Filename = $localMmproj.Name
                return $result
            }
        }
    }

    Write-LaunchLog "[vision/test] No local mmproj found for $Key, checking HuggingFace..."  'VISION'

    # Not local — check HF for availability.
    if ($Def.ContainsKey('Repo') -and -not [string]::IsNullOrWhiteSpace($Def.Repo)) {
        $mmprojFiles = Get-HuggingFaceMmprojFiles -Repo $Def.Repo
        if ($null -eq $mmprojFiles) {
            Write-LaunchLog "[vision/test] HF check skipped for $Key (network/SSL error)" 'WARN'
        } elseif ($mmprojFiles.Count -gt 0) {
            Write-LaunchLog "[vision/test] HF has $($mmprojFiles.Count) mmproj file(s): $($mmprojFiles.Keys -join ', ')"  'VISION'
            $result.AvailableOnHF = $true
            # If no specific VisionModule configured, pick the first available mmproj
            if (-not $mmprojFile) {
                $mmprojFile = @($mmprojFiles.Keys)[0]
                $result.Filename = $mmprojFile
            } elseif ($mmprojFiles.ContainsKey($mmprojFile)) {
                $result.AvailableOnHF = $true
            }
        } else {
            Write-LaunchLog "[vision/test] No mmproj files on HF for $($Def.Repo)"  'VISION'
        }
    }

    Write-LaunchLog "[vision/test] Result for ${Key}: Local=$($result.Local), HF=$($result.AvailableOnHF), File='$($result.Filename)'"  'VISION'
    return $result
}
