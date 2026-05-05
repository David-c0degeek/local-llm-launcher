# llama.cpp install / detection. Locates llama-server.exe, downloads a release
# from github.com/ggerganov/llama.cpp when missing, or pulls the turboquant
# Docker image. All work is lazy — nothing happens at module load.

function Get-LlamaCppInstallRoot {
    return (Join-Path $HOME ".local-llm\llama-cpp")
}

function Find-LlamaServerExe {
    # 1) explicit path from catalog/settings
    $configured = $script:Cfg.LlamaCppServerPath
    if (-not [string]::IsNullOrWhiteSpace($configured) -and (Test-Path $configured)) {
        return $configured
    }

    # 2) install root
    $defaultPath = Join-Path (Get-LlamaCppInstallRoot) "llama-server.exe"
    if (Test-Path $defaultPath) {
        return $defaultPath
    }

    # 3) PATH
    $cmd = Get-Command llama-server.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    return $null
}

function Get-LlamaCppGpuVariant {
    # Returns 'cuda' | 'vulkan' | 'cpu' based on configured override or
    # auto-detection. CUDA is preferred when nvidia-smi works; vulkan covers
    # AMD/Intel where Vulkan is broadly available; cpu is the safe fallback.
    if ($script:Cfg.Contains("LlamaCppVariant") -and -not [string]::IsNullOrWhiteSpace($script:Cfg.LlamaCppVariant)) {
        $v = $script:Cfg.LlamaCppVariant.ToLowerInvariant()
        if ($v -in @('cuda', 'vulkan', 'cpu')) {
            return $v
        }
    }

    $info = Get-LocalLLMVRAMInfo
    if ($info.Source -eq 'auto') {
        return 'cuda'
    }

    if (Get-Command vulkaninfo -ErrorAction SilentlyContinue) {
        return 'vulkan'
    }

    return 'cpu'
}

function Get-LlamaCppLatestRelease {
    # Hits the public GitHub API. Returns the parsed JSON object or throws.
    $headers = @{ "User-Agent" = "LocalLLMProfile/1.0"; "Accept" = "application/vnd.github+json" }
    $url = "https://api.github.com/repos/ggerganov/llama.cpp/releases/latest"

    $oldProgress = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'
    try {
        return Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 30
    }
    finally {
        $global:ProgressPreference = $oldProgress
    }
}

function Select-LlamaCppReleaseAsset {
    param(
        [Parameter(Mandatory = $true)]$Release,
        [Parameter(Mandatory = $true)][string]$Variant
    )

    # Asset names follow `llama-bXXXX-bin-win-<variant>-x64.zip`. Variants we
    # care about (in order of preference per requested kind):
    #   cuda   -> cuda-*, cu*, then any cuda
    #   vulkan -> vulkan
    #   cpu    -> avx2, then avx512, then avx, then noavx
    $assets = @($Release.assets | Where-Object {
        $_.name -match '\.zip$' -and $_.name -match 'win' -and $_.name -notmatch 'cudart'
    })

    if ($assets.Count -eq 0) {
        throw "No Windows ZIP assets found in latest llama.cpp release."
    }

    $patterns = switch ($Variant) {
        'cuda'   { @('-cuda-12','-cuda-11','-cuda') }
        'vulkan' { @('-vulkan') }
        'cpu'    { @('-avx2-','-avx512-','-avx-','-noavx-') }
        default  { @('-cpu') }
    }

    foreach ($pat in $patterns) {
        $hit = $assets | Where-Object { $_.name -match [regex]::Escape($pat) } | Select-Object -First 1
        if ($hit) { return $hit }
    }

    throw "No matching $Variant asset found in release $($Release.tag_name). Available: $((@($assets | ForEach-Object { $_.name })) -join ', ')"
}

function Select-LlamaCppCudartAsset {
    param([Parameter(Mandatory = $true)]$Release)

    return @($Release.assets | Where-Object { $_.name -match '^cudart-' -and $_.name -match 'win' }) | Select-Object -First 1
}

function Install-LlamaServerNative {
    [CmdletBinding()]
    param([switch]$Force)

    $installRoot = Get-LlamaCppInstallRoot
    Ensure-Directory $installRoot

    $serverPath = Join-Path $installRoot "llama-server.exe"
    if (-not $Force -and (Test-Path $serverPath)) {
        Write-Host "llama-server already installed: $serverPath" -ForegroundColor DarkGray
        return $serverPath
    }

    $variant = Get-LlamaCppGpuVariant
    Write-Host "Resolving latest llama.cpp release ($variant)..." -ForegroundColor Cyan

    $release = Get-LlamaCppLatestRelease
    $asset = Select-LlamaCppReleaseAsset -Release $release -Variant $variant

    Write-Host "Downloading $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)..." -ForegroundColor Cyan

    $tmpZip = Join-Path $env:TEMP $asset.name
    if (Test-Path $tmpZip) { Remove-Item $tmpZip -Force }

    $oldProgress = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpZip -UseBasicParsing -TimeoutSec 600
    }
    finally {
        $global:ProgressPreference = $oldProgress
    }

    Write-Host "Extracting to $installRoot..." -ForegroundColor Cyan
    Expand-Archive -LiteralPath $tmpZip -DestinationPath $installRoot -Force
    Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue

    # Some archives nest binaries under a folder; flatten if needed.
    if (-not (Test-Path $serverPath)) {
        $found = Get-ChildItem -Path $installRoot -Filter "llama-server.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            $sourceDir = Split-Path -Parent $found.FullName
            Get-ChildItem -Path $sourceDir -File | ForEach-Object {
                Move-Item -LiteralPath $_.FullName -Destination $installRoot -Force
            }
        }
    }

    if (-not (Test-Path $serverPath)) {
        throw "Extraction completed but llama-server.exe was not found under $installRoot."
    }

    "$($release.tag_name)`n$variant" | Set-Content -LiteralPath (Join-Path $installRoot ".build-stamp") -Encoding utf8

    if ($variant -eq 'cuda') {
        $cudartAsset = Select-LlamaCppCudartAsset -Release $release
        if ($cudartAsset) {
            $cudartZip = Join-Path $env:TEMP $cudartAsset.name
            if (Test-Path $cudartZip) { Remove-Item $cudartZip -Force }
            Write-Host "Downloading CUDA runtime ($($cudartAsset.name))..." -ForegroundColor Cyan
            $oldProgress = $global:ProgressPreference
            $global:ProgressPreference = 'SilentlyContinue'
            try {
                Invoke-WebRequest -Uri $cudartAsset.browser_download_url -OutFile $cudartZip -UseBasicParsing -TimeoutSec 600
            }
            finally {
                $global:ProgressPreference = $oldProgress
            }
            Expand-Archive -LiteralPath $cudartZip -DestinationPath $installRoot -Force
            Remove-Item $cudartZip -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "Installed llama-server: $serverPath" -ForegroundColor Green
    return $serverPath
}

function Ensure-LlamaServerNative {
    # Returns the resolved path to llama-server.exe, installing it if absent
    # (after asking once). Throws if the user declines.
    param([switch]$NonInteractive)

    $existing = Find-LlamaServerExe
    if ($existing) { return $existing }

    if ($NonInteractive) {
        return Install-LlamaServerNative
    }

    Write-Host ""
    Write-Host "llama-server is not installed." -ForegroundColor Yellow
    Write-Host "  Source: github.com/ggerganov/llama.cpp releases" -ForegroundColor DarkGray
    Write-Host "  Target: $(Get-LlamaCppInstallRoot)" -ForegroundColor DarkGray
    $answer = (Read-Host "Download and install now? [Y/n]").Trim().ToLowerInvariant()

    if ($answer -in @("n", "no")) {
        throw "llama-server is required for the llama.cpp backend. Aborted."
    }

    return Install-LlamaServerNative
}

function Get-LlamaCppTurboquantInstallRoot {
    $root = $script:Cfg.LlamaCppTurboquantRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Join-Path $HOME ".local-llm\llama-cpp-turboquant"
    }
    return $root
}

function Find-TurboquantServerExe {
    # Searches for llama-server.exe under the turboquant install root. The
    # turboquant ZIP layout isn't fixed (releases sometimes nest under a
    # version folder), so we glob recursively.
    $root = Get-LlamaCppTurboquantInstallRoot
    if (-not (Test-Path $root)) { return $null }

    $hit = Get-ChildItem -Path $root -Filter 'llama-server.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.FullName }

    return $null
}

function Get-LlamaCppTurboquantRepo {
    $repo = $script:Cfg.LlamaCppTurboquantRepo
    if ([string]::IsNullOrWhiteSpace($repo)) { $repo = "TheTom/llama-cpp-turboquant" }
    return $repo
}

function Get-LlamaCppTurboquantLatestRelease {
    $headers = @{ "User-Agent" = "LocalLLMProfile/1.0"; "Accept" = "application/vnd.github+json" }
    $url = "https://api.github.com/repos/$(Get-LlamaCppTurboquantRepo)/releases/latest"

    $oldProgress = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'
    try {
        return Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 30
    }
    finally {
        $global:ProgressPreference = $oldProgress
    }
}

function Select-TurboquantReleaseAsset {
    # Turboquant currently ships Windows-x64-CUDA only on the win side.
    # Match the windows zip with -cuda in the name; reject the macOS asset.
    param([Parameter(Mandatory = $true)]$Release)

    $hit = $Release.assets | Where-Object {
        $_.name -match '\.zip$' -and $_.name -match 'windows' -and $_.name -match 'cuda'
    } | Select-Object -First 1

    if (-not $hit) {
        $names = (@($Release.assets | ForEach-Object { $_.name })) -join ', '
        throw "No Windows CUDA turboquant asset found in release $($Release.tag_name). Available: $names"
    }

    return $hit
}

function Install-LlamaServerTurboquant {
    [CmdletBinding()]
    param([switch]$Force)

    $installRoot = Get-LlamaCppTurboquantInstallRoot
    Ensure-Directory $installRoot

    $existing = Find-TurboquantServerExe
    if (-not $Force -and $existing) {
        Write-Host "Turboquant llama-server already installed: $existing" -ForegroundColor DarkGray
        return $existing
    }

    Write-Host "Resolving latest turboquant release ($(Get-LlamaCppTurboquantRepo))..." -ForegroundColor Cyan

    $release = Get-LlamaCppTurboquantLatestRelease
    $asset = Select-TurboquantReleaseAsset -Release $release

    $sizeMB = [math]::Round($asset.size / 1MB, 1)
    Write-Host "Asset: $($asset.name)  ($sizeMB MB)" -ForegroundColor DarkGray
    Write-Host "Note: turboquant currently ships only a CUDA 12.4 x64 build for Windows." -ForegroundColor DarkYellow

    $tmpZip = Join-Path $env:TEMP $asset.name
    if (Test-Path $tmpZip) { Remove-Item $tmpZip -Force }

    # Free-disk sanity: need ~ asset size unzipped + ~ asset size for the zip.
    $drive = (Split-Path -Qualifier $installRoot)
    if ($drive) {
        $free = (Get-PSDrive -Name $drive.TrimEnd(':') -ErrorAction SilentlyContinue).Free
        if ($free -and $free -lt ($asset.size * 2)) {
            Write-Warning "Low disk: $([math]::Round($free / 1GB, 1)) GB free on $drive (need ~$([math]::Round($asset.size * 2 / 1GB, 1)) GB for ZIP + extracted files)."
        }
    }

    Write-Host "Downloading $sizeMB MB to $tmpZip..." -ForegroundColor Cyan
    $oldProgress = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpZip -UseBasicParsing -TimeoutSec 1800
    }
    finally {
        $global:ProgressPreference = $oldProgress
    }

    Write-Host "Extracting to $installRoot..." -ForegroundColor Cyan
    Expand-Archive -LiteralPath $tmpZip -DestinationPath $installRoot -Force
    Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue

    $serverPath = Find-TurboquantServerExe
    if (-not $serverPath) {
        throw "Extracted turboquant archive but llama-server.exe was not found anywhere under $installRoot. The release layout may have changed."
    }

    "$($release.tag_name)" | Set-Content -LiteralPath (Join-Path $installRoot ".build-stamp") -Encoding utf8

    Repair-TurboquantOpenSslDeps -InstallDir (Split-Path -Parent $serverPath)

    Write-Host "Installed turboquant llama-server: $serverPath" -ForegroundColor Green
    return $serverPath
}

function Repair-TurboquantOpenSslDeps {
    # Some turboquant builds link OpenSSL but ship without libcrypto/libssl/zlib.
    # If the install dir is missing them, copy from common system locations
    # (Git for Windows is the reliable bet on most dev machines). Idempotent:
    # files already present are left alone.
    param([Parameter(Mandatory = $true)][string]$InstallDir)

    $needed = @('libcrypto-3-x64.dll', 'libssl-3-x64.dll', 'zlib1.dll')

    $missing = @($needed | Where-Object { -not (Test-Path (Join-Path $InstallDir $_)) })
    if ($missing.Count -eq 0) { return }

    $sourceDirs = @(
        (Join-Path ${env:ProgramFiles}      'Git\mingw64\bin'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\mingw64\bin'),
        (Join-Path ${env:ProgramFiles}      'OpenSSL-Win64\bin'),
        (Join-Path ${env:ProgramFiles}      'OpenSSL\bin')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path $_) }

    foreach ($dll in $missing) {
        $copied = $false
        foreach ($dir in $sourceDirs) {
            $src = Join-Path $dir $dll
            if (Test-Path $src) {
                Copy-Item -LiteralPath $src -Destination $InstallDir -Force -ErrorAction SilentlyContinue
                if (Test-Path (Join-Path $InstallDir $dll)) {
                    Write-Host "Copied missing dependency $dll from $dir" -ForegroundColor DarkGreen
                    $copied = $true
                    break
                }
            }
        }
        if (-not $copied) {
            Write-Warning "Could not locate $dll. Install Git for Windows or copy the DLL manually into $InstallDir."
        }
    }
}

function Ensure-LlamaServerTurboquant {
    # Returns the resolved path to the turboquant llama-server.exe, installing
    # it if absent (after asking once). Throws if the user declines.
    param([switch]$NonInteractive)

    $existing = Find-TurboquantServerExe
    if ($existing) {
        Repair-TurboquantOpenSslDeps -InstallDir (Split-Path -Parent $existing)
        return $existing
    }

    if ($NonInteractive) {
        return Install-LlamaServerTurboquant
    }

    Write-Host ""
    Write-Host "turboquant llama-server is not installed." -ForegroundColor Yellow
    Write-Host "  Source: github.com/$(Get-LlamaCppTurboquantRepo)/releases/latest" -ForegroundColor DarkGray
    Write-Host "  Target: $(Get-LlamaCppTurboquantInstallRoot)" -ForegroundColor DarkGray
    Write-Host "  Note  : ~700 MB download (Windows x64 CUDA 12.4 only)" -ForegroundColor DarkGray
    $answer = (Read-Host "Download and install now? [Y/n]").Trim().ToLowerInvariant()

    if ($answer -in @("n", "no")) {
        throw "turboquant is required for the llama.cpp turboquant backend. Aborted."
    }

    return Install-LlamaServerTurboquant
}
