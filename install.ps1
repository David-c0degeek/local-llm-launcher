# Install LocalBox to %USERPROFILE%\.local-llm and %USERPROFILE%\.ollama-proxy.
#
# Modes:
#   .\install.ps1                  copy files (default)
#   .\install.ps1 -Symlink         symlink files (requires admin / developer mode)
#   .\install.ps1 -SetupProfile    only ensure $PROFILE dot-sources the deployed entry point
#   .\install.ps1 -InstallBenchPilot   clone BenchPilot into ~/.local-llm/tools/benchpilot if missing
#   .\install.ps1 -InstallUnshackled   clone Unshackled into ~/.local-llm/tools/unshackled if missing
#   .\install.ps1 -SkipToolPrompts     do not prompt for optional companion checkouts
#   .\install.ps1 -DryRun          preview the actions without changing anything
#
# Multiple flags compose: -Symlink -SetupProfile installs symlinks AND wires up $PROFILE.

param(
    [switch]$Symlink,
    [Alias("Profile")][switch]$SetupProfile,
    [switch]$InstallBenchPilot,
    [switch]$InstallUnshackled,
    [switch]$SkipToolPrompts,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot

if (-not $RepoRoot) {
    $RepoRoot = (Get-Item -LiteralPath ".").FullName
}

$DeployedLocalLLM = Join-Path $HOME ".local-llm"
$DeployedProxy = Join-Path $HOME ".ollama-proxy"
$ManagedToolsRoot = Join-Path $DeployedLocalLLM "tools"
$ManagedBenchPilotRoot = Join-Path $ManagedToolsRoot "benchpilot"
$ManagedUnshackledRoot = Join-Path $ManagedToolsRoot "unshackled"
$ProfileDotSourceLine = ". `"$DeployedLocalLLM\LocalLLMProfile.ps1`""

# -SetupProfile alone (no -Symlink, no -DryRun) means "just wire up $PROFILE, don't touch files".
# Combined with -Symlink or -DryRun, files are still installed/previewed.
$installFiles = -not ($SetupProfile -and -not $Symlink -and -not $DryRun)

function Write-Action {
    param([string]$Verb, [string]$Detail)

    $color = if ($DryRun) { "DarkGray" } else { "Cyan" }
    $prefix = if ($DryRun) { "[dry-run] " } else { "" }
    Write-Host "$prefix$Verb $Detail" -ForegroundColor $color
}

function Ensure-Dir {
    param([string]$Path)

    if (Test-Path $Path) { return }

    Write-Action "create dir" $Path

    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Install-File {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path $Source)) {
        throw "Source missing: $Source"
    }

    if ($Symlink) {
        if (Test-Path $Destination) {
            $existing = Get-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue

            if ($existing -and $existing.LinkType -eq "SymbolicLink" -and $existing.Target -eq $Source) {
                Write-Host "  ok       symlink already current: $Destination" -ForegroundColor DarkGreen
                return
            }

            Write-Action "remove" $Destination
            if (-not $DryRun) { Remove-Item -LiteralPath $Destination -Force }
        }

        Write-Action "symlink" "$Destination -> $Source"

        if (-not $DryRun) {
            try {
                New-Item -ItemType SymbolicLink -Path $Destination -Target $Source -Force | Out-Null
            }
            catch {
                throw "Symlink failed (need admin or developer mode?): $_"
            }
        }
    }
    else {
        if (Test-Path $Destination) {
            $existing = Get-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue

            if ($existing -and $existing.LinkType -eq "SymbolicLink") {
                $sourcePath = (Resolve-Path -LiteralPath $Source).Path
                $targetPath = $existing.Target

                if ($targetPath -is [array]) {
                    $targetPath = $targetPath[0]
                }

                if (-not [string]::IsNullOrWhiteSpace($targetPath) -and (Test-Path -LiteralPath $targetPath)) {
                    $targetPath = (Resolve-Path -LiteralPath $targetPath).Path
                }

                if ($targetPath -eq $sourcePath) {
                    Write-Host "  ok       symlink already points at source: $Destination" -ForegroundColor DarkGreen
                    return
                }

                Write-Action "remove symlink" $Destination
                if (-not $DryRun) { Remove-Item -LiteralPath $Destination -Force }
            }
        }

        Write-Action "copy" "$Source -> $Destination"
        if (-not $DryRun) {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force
        }
    }
}

function Install-Dir-Files {
    param(
        [string]$SourceDir,
        [string]$TargetDir,
        [string[]]$Files
    )

    Ensure-Dir $TargetDir

    foreach ($file in $Files) {
        $src = Join-Path $SourceDir $file
        $dst = Join-Path $TargetDir $file
        Install-File -Source $src -Destination $dst
    }
}

function Ensure-ProfileDotSource {
    $profilePath = $PROFILE.CurrentUserAllHosts

    if (-not (Test-Path $profilePath)) {
        Write-Action "create" $profilePath
        if (-not $DryRun) {
            $profileDir = Split-Path -Parent $profilePath
            if (-not (Test-Path $profileDir)) {
                New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
            }
            New-Item -ItemType File -Force -Path $profilePath | Out-Null
        }
    }

    $existing = if ($DryRun -or -not (Test-Path $profilePath)) {
        ""
    } else {
        Get-Content -Raw -Path $profilePath -ErrorAction SilentlyContinue
    }

    if ($existing -and ($existing -match [regex]::Escape($ProfileDotSourceLine))) {
        Write-Host "  ok       `$PROFILE already sources LocalLLMProfile.ps1 ($profilePath)" -ForegroundColor DarkGreen
        return
    }

    Write-Action "append" "$profilePath  ($ProfileDotSourceLine)"

    if (-not $DryRun) {
        Add-Content -Path $profilePath -Value "`n$ProfileDotSourceLine`n" -Encoding UTF8
    }
}

function Read-JsonHashtable {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return [ordered]@{} }
    try { return (Get-Content -Raw -Path $Path | ConvertFrom-Json -AsHashtable) }
    catch { return [ordered]@{} }
}

function Write-LocalLLMSettings {
    param([System.Collections.IDictionary]$Settings)

    $path = Join-Path $DeployedLocalLLM "settings.json"
    Ensure-Dir $DeployedLocalLLM

    if ($DryRun) {
        Write-Action "write" $path
        return
    }

    $json = $Settings | ConvertTo-Json -Depth 8
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $json, $utf8NoBom)
}

function Set-InstallSetting {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $settingsPath = Join-Path $DeployedLocalLLM "settings.json"
    $settings = Read-JsonHashtable -Path $settingsPath
    $settings[$Key] = $Value
    Write-LocalLLMSettings -Settings $settings
}

function Get-InstallCatalog {
    $deployedCatalog = Join-Path $DeployedLocalLLM "llm-models.json"
    $sourceCatalog = Join-Path $RepoRoot "local-llm\llm-models.json"
    $path = if (Test-Path $deployedCatalog) { $deployedCatalog } else { $sourceCatalog }
    return Read-JsonHashtable -Path $path
}

function Test-BenchPilotCheckout {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
    if (-not (Test-InstallPathRootExists -Path $Root)) { return $false }
    return (Test-Path (Join-Path $Root "src\BenchPilot.psm1"))
}

function Test-UnshackledCheckout {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
    if (-not (Test-InstallPathRootExists -Path $Root)) { return $false }
    return (Test-Path (Join-Path $Root "src\entrypoints\cli.tsx"))
}

function Test-InstallPathRootExists {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    $qualifier = Split-Path -Path $Path -Qualifier
    if (-not $qualifier) { return $true }

    $driveName = $qualifier.TrimEnd(":")
    return [bool](Get-PSDrive -Name $driveName -PSProvider FileSystem -ErrorAction SilentlyContinue)
}

function Get-InstallSearchRoots {
    $roots = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($HOME) -and (Test-Path -LiteralPath $HOME)) {
        $roots.Add((Resolve-Path -LiteralPath $HOME).Path) | Out-Null
    }

    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($drive.Root) -or -not (Test-Path -LiteralPath $drive.Root)) { continue }

        $root = (Resolve-Path -LiteralPath $drive.Root).Path
        if ($roots -notcontains $root) {
            $roots.Add($root) | Out-Null
        }
    }

    return @($roots)
}

function Find-CheckoutByMarker {
    param(
        [Parameter(Mandatory = $true)][string]$MarkerRelativePath,
        [Parameter(Mandatory = $true)][scriptblock]$Validator,
        [int]$MaxDepth = 7
    )

    $skipNames = @(
        '$Recycle.Bin',
        '.git',
        '.idea',
        'AppData',
        'node_modules',
        'PerfLogs',
        'Program Files',
        'Program Files (x86)',
        'ProgramData',
        'Recovery',
        'System Volume Information',
        'Windows'
    )

    $queue = New-Object System.Collections.Generic.Queue[object]
    foreach ($root in (Get-InstallSearchRoots)) {
        $queue.Enqueue([pscustomobject]@{ Path = $root; Depth = 0 })
    }

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $path = [string]$current.Path
        $depth = [int]$current.Depth

        $marker = Join-Path $path $MarkerRelativePath
        if (Test-Path -LiteralPath $marker) {
            if (& $Validator $path) {
                return $path
            }
        }

        if ($depth -ge $MaxDepth) { continue }

        try {
            $children = Get-ChildItem -LiteralPath $path -Directory -Force -ErrorAction Stop
        }
        catch {
            continue
        }

        foreach ($child in $children) {
            if ($child.Name -in $skipNames) { continue }
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $queue.Enqueue([pscustomobject]@{ Path = $child.FullName; Depth = ($depth + 1) })
        }
    }

    return $null
}

function Find-BenchPilotInstall {
    $candidates = @()
    if ($env:BENCHPILOT_ROOT) { $candidates += $env:BENCHPILOT_ROOT }

    $settings = Read-JsonHashtable -Path (Join-Path $DeployedLocalLLM "settings.json")
    if ($settings.Contains("BenchPilotRoot")) { $candidates += [string]$settings.BenchPilotRoot }

    $module = Get-Module -ListAvailable -Name BenchPilot -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($module) { return [pscustomobject]@{ Source = "module"; Root = $module.ModuleBase } }

    $candidates += $ManagedBenchPilotRoot

    foreach ($candidate in $candidates) {
        if (Test-BenchPilotCheckout -Root $candidate) {
            return [pscustomobject]@{ Source = "checkout"; Root = $candidate }
        }
    }

    $discovered = Find-CheckoutByMarker -MarkerRelativePath "src\BenchPilot.psm1" -Validator { param($root) Test-BenchPilotCheckout -Root $root }
    if ($discovered) {
        return [pscustomobject]@{ Source = "discovered"; Root = $discovered }
    }

    return $null
}

function Find-UnshackledInstall {
    $settings = Read-JsonHashtable -Path (Join-Path $DeployedLocalLLM "settings.json")
    $catalog = Get-InstallCatalog
    $candidates = @()

    if ($settings.Contains("UnshackledRoot")) { $candidates += [string]$settings.UnshackledRoot }
    if ($catalog.Contains("UnshackledRoot")) { $candidates += [string]$catalog.UnshackledRoot }
    $candidates += $ManagedUnshackledRoot

    foreach ($candidate in $candidates) {
        if (Test-UnshackledCheckout -Root $candidate) {
            return [pscustomobject]@{ Source = "checkout"; Root = $candidate }
        }
    }

    $discovered = Find-CheckoutByMarker -MarkerRelativePath "src\entrypoints\cli.tsx" -Validator { param($root) Test-UnshackledCheckout -Root $root }
    if ($discovered) {
        return [pscustomobject]@{ Source = "discovered"; Root = $discovered }
    }

    return $null
}

function Clone-Repo {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$RepoUrl,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git is not on PATH; cannot clone $Name."
    }

    if (Test-Path $Destination) {
        Write-Host "  ok       $Name path already exists: $Destination" -ForegroundColor DarkGreen
        return
    }

    Ensure-Dir (Split-Path -Parent $Destination)
    Write-Action "clone" "$RepoUrl -> $Destination"

    if (-not $DryRun) {
        & git clone $RepoUrl $Destination
        if ($LASTEXITCODE -ne 0) {
            throw "git clone failed for $RepoUrl"
        }
    }
}

function Confirm-InstallTool {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$RepoUrl,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Force
    )

    if ($Force) { return $true }
    if ($DryRun) { return $false }
    if ($SkipToolPrompts) { return $false }

    Write-Host ""
    Write-Host "$Name was not found." -ForegroundColor Yellow
    Write-Host "  Source : $RepoUrl" -ForegroundColor DarkGray
    Write-Host "  Target : $Destination" -ForegroundColor DarkGray
    $answer = (Read-Host "Clone $Name now? [y/N]").Trim().ToLowerInvariant()
    return ($answer -in @("y", "yes"))
}

function Ensure-CompanionTools {
    $catalog = Get-InstallCatalog
    $benchPilotRepo = if ($catalog.Contains("BenchPilotRepoUrl")) { [string]$catalog.BenchPilotRepoUrl } else { "https://github.com/David-c0degeek/benchpilot" }
    $unshackledRepo = if ($catalog.Contains("UnshackledRepoUrl")) { [string]$catalog.UnshackledRepoUrl } else { "https://github.com/David-c0degeek/unshackled" }

    $bp = Find-BenchPilotInstall
    if ($bp) {
        Write-Host "  ok       BenchPilot found ($($bp.Source)): $($bp.Root)" -ForegroundColor DarkGreen
    }
    elseif (Confirm-InstallTool -Name "BenchPilot" -RepoUrl $benchPilotRepo -Destination $ManagedBenchPilotRoot -Force:$InstallBenchPilot) {
        Clone-Repo -Name "BenchPilot" -RepoUrl $benchPilotRepo -Destination $ManagedBenchPilotRoot
        Set-InstallSetting -Key "BenchPilotRoot" -Value $ManagedBenchPilotRoot
    }

    $unshackled = Find-UnshackledInstall
    if ($unshackled) {
        Write-Host "  ok       Unshackled found ($($unshackled.Source)): $($unshackled.Root)" -ForegroundColor DarkGreen
    }
    elseif (Confirm-InstallTool -Name "Unshackled" -RepoUrl $unshackledRepo -Destination $ManagedUnshackledRoot -Force:$InstallUnshackled) {
        Clone-Repo -Name "Unshackled" -RepoUrl $unshackledRepo -Destination $ManagedUnshackledRoot
        Set-InstallSetting -Key "UnshackledRoot" -Value $ManagedUnshackledRoot
    }
}

function Show-Diagnostics {
    Write-Host ""
    Write-Host "=== Diagnostics ===" -ForegroundColor Cyan

    $ollama = Get-Command ollama -ErrorAction SilentlyContinue
    if ($ollama) {
        $ver = (& ollama --version 2>$null) -join ' '
        Write-Host "ollama   : ok  ($ver)" -ForegroundColor Green
    }
    else {
        Write-Host "ollama   : MISSING — install from https://ollama.com or 'winget install Ollama.Ollama'" -ForegroundColor Yellow
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        $ver = & python --version 2>&1
        Write-Host "python   : ok  ($ver)" -ForegroundColor Green
    }
    else {
        Write-Host "python   : MISSING — required for the no-think proxy" -ForegroundColor Yellow
    }

    $bun = Get-Command bun -ErrorAction SilentlyContinue
    if ($bun) {
        $ver = & bun --version 2>&1
        Write-Host "bun      : ok  ($ver)  (only needed for Unshackled launches)" -ForegroundColor Green
    }
    else {
        Write-Host "bun      : missing (only needed for Unshackled launches)" -ForegroundColor DarkGray
    }

    $spectre = Get-Module -ListAvailable -Name PwshSpectreConsole -ErrorAction SilentlyContinue
    if ($spectre) {
        $ver = ($spectre | Sort-Object Version -Descending | Select-Object -First 1).Version
        Write-Host "spectre  : ok  ($ver)  (rich 'info' dashboard)" -ForegroundColor Green
    }
    else {
        Write-Host "spectre  : missing — 'info' falls back to plain text. Install with:" -ForegroundColor DarkGray
        Write-Host "             Install-Module PwshSpectreConsole -Scope CurrentUser" -ForegroundColor DarkGray
    }

    $benchPilot = Find-BenchPilotInstall
    if ($benchPilot) {
        Write-Host "benchpilot: ok  ($($benchPilot.Root))" -ForegroundColor Green
    }
    else {
        Write-Host "benchpilot: missing — installer can clone https://github.com/David-c0degeek/benchpilot into ~/.local-llm/tools/benchpilot" -ForegroundColor Yellow
    }

    $unshackled = Find-UnshackledInstall
    if ($unshackled) {
        Write-Host "unshackled: ok  ($($unshackled.Root))" -ForegroundColor Green
    }
    else {
        Write-Host "unshackled: missing — installer can clone https://github.com/David-c0degeek/unshackled into ~/.local-llm/tools/unshackled" -ForegroundColor Yellow
    }

    Write-Host ""
}

# ---- main ----

Write-Host ""
Write-Host "LocalBox install" -ForegroundColor Cyan
Write-Host "  Repo     : $RepoRoot"
Write-Host "  Mode     : $(if ($Symlink) { 'symlink' } else { 'copy' })$(if ($DryRun) { ' (dry-run)' } else { '' })"
Write-Host ""

if ($installFiles) {
    Set-InstallSetting -Key "LocalBoxRoot" -Value $RepoRoot

    Install-Dir-Files `
        -SourceDir (Join-Path $RepoRoot "local-llm") `
        -TargetDir $DeployedLocalLLM `
        -Files @("LocalLLMProfile.ps1", "llm-models.json", "defaults.json")

    # lib/ is the modular code tree dot-sourced by LocalLLMProfile.ps1.
    # Install every *.ps1 in there, mirroring the source order so a fresh
    # install matches what runs from the repo.
    $libSource = Join-Path $RepoRoot "local-llm\lib"
    if (Test-Path $libSource) {
        $libFiles = @(Get-ChildItem -Path $libSource -Filter '*.ps1' | Sort-Object Name | ForEach-Object { $_.Name })
        if ($libFiles.Count -gt 0) {
            Install-Dir-Files `
                -SourceDir $libSource `
                -TargetDir (Join-Path $DeployedLocalLLM "lib") `
                -Files $libFiles
        }
    }

    Install-Dir-Files `
        -SourceDir (Join-Path $RepoRoot "ollama-proxy") `
        -TargetDir $DeployedProxy `
        -Files @("no-think-proxy.py", "enforcer-claude.ps1")
}

if ($SetupProfile -or -not $installFiles) {
    Ensure-ProfileDotSource
}

Ensure-CompanionTools
Show-Diagnostics

if (-not $DryRun) {
    Write-Host ""
    Write-Host "Done. Open a fresh PowerShell and run 'init' to build Ollama aliases." -ForegroundColor Green
    Write-Host ""
    Write-Host "Per-machine settings (paths, defaults) belong in ~/.local-llm/settings.json." -ForegroundColor DarkGray
    Write-Host "Use the helper instead of editing JSON:" -ForegroundColor DarkGray
    Write-Host "  Set-LocalLLMSetting UnshackledRoot '<path-to-unshackled>'" -ForegroundColor DarkGray
    Write-Host "  Set-LocalLLMSetting BenchPilotRoot '<path-to-benchpilot>'" -ForegroundColor DarkGray
    Write-Host "  Set-LocalLLMSetting Default q36plus" -ForegroundColor DarkGray
}
