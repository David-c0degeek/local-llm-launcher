# Install local-llm-launcher to %USERPROFILE%\.local-llm and %USERPROFILE%\.ollama-proxy.
#
# Modes:
#   .\install.ps1                  copy files (default)
#   .\install.ps1 -Symlink         symlink files (requires admin / developer mode)
#   .\install.ps1 -Profile         only ensure $PROFILE dot-sources the deployed entry point
#   .\install.ps1 -DryRun          preview the actions without changing anything
#
# Multiple flags compose: -Symlink -Profile installs symlinks AND wires up $PROFILE.

param(
    [switch]$Symlink,
    [switch]$Profile,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot

if (-not $RepoRoot) {
    $RepoRoot = (Get-Item -LiteralPath ".").FullName
}

$DeployedLocalLLM = Join-Path $HOME ".local-llm"
$DeployedProxy = Join-Path $HOME ".ollama-proxy"
$ProfileDotSourceLine = ". `"$DeployedLocalLLM\LocalLLMProfile.ps1`""

$installFiles = $true

if ($Profile -and -not $Symlink -and -not $PSBoundParameters.ContainsKey("DryRun")) {
    # -Profile alone means "just wire up the profile, don't touch files"
    $installFiles = -not ($PSBoundParameters.Count -eq 1 -and $PSBoundParameters.ContainsKey("Profile"))
}

if (-not ($PSBoundParameters.Keys | Where-Object { $_ -in @("Symlink", "DryRun") })) {
    # No file-mode flag passed, but -Profile alone shouldn't copy files.
    if ($Profile -and $PSBoundParameters.Count -eq 1) {
        $installFiles = $false
    }
}

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
        Write-Host "  ok       \$PROFILE already sources LocalLLMProfile.ps1" -ForegroundColor DarkGreen
        return
    }

    Write-Action "append" "$profilePath  ($ProfileDotSourceLine)"

    if (-not $DryRun) {
        Add-Content -Path $profilePath -Value "`n$ProfileDotSourceLine`n" -Encoding UTF8
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

    Write-Host ""
}

# ---- main ----

Write-Host ""
Write-Host "local-llm-launcher install" -ForegroundColor Cyan
Write-Host "  Repo     : $RepoRoot"
Write-Host "  Mode     : $(if ($Symlink) { 'symlink' } else { 'copy' })$(if ($DryRun) { ' (dry-run)' } else { '' })"
Write-Host ""

if ($installFiles) {
    Install-Dir-Files `
        -SourceDir (Join-Path $RepoRoot "local-llm") `
        -TargetDir $DeployedLocalLLM `
        -Files @("LocalLLMProfile.ps1", "llm-models.json")

    Install-Dir-Files `
        -SourceDir (Join-Path $RepoRoot "ollama-proxy") `
        -TargetDir $DeployedProxy `
        -Files @("no-think-proxy.py", "enforcer-claude.ps1")
}

if ($Profile -or -not $installFiles) {
    Ensure-ProfileDotSource
}

Show-Diagnostics

if (-not $DryRun) {
    Write-Host ""
    Write-Host "Done. Open a fresh PowerShell and run 'init' to build Ollama aliases." -ForegroundColor Green
    Write-Host ""
    Write-Host "Per-machine settings (paths, defaults) belong in ~/.local-llm/settings.json." -ForegroundColor DarkGray
    Write-Host "Use the helper instead of editing JSON:" -ForegroundColor DarkGray
    Write-Host "  Set-LocalLLMSetting UnshackledRoot 'C:\path\to\unshackled'" -ForegroundColor DarkGray
    Write-Host "  Set-LocalLLMSetting Default q36plus" -ForegroundColor DarkGray
}
