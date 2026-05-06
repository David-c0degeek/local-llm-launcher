# BenchPilot discovery/import bridge. The launcher owns launch-time AutoBest
# loading; BenchPilot owns benchmark execution and compatible profile export.

function Resolve-BenchPilotModulePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) { return $null }

    $expanded = Expand-LocalLLMPath $Root
    if (Test-Path -LiteralPath $expanded -PathType Leaf) {
        $leaf = Split-Path -Leaf $expanded
        if ($leaf -in @('BenchPilot.psm1', 'BenchPilot.psd1')) {
            return (Resolve-Path -LiteralPath $expanded).Path
        }
    }

    $candidates = @(
        (Join-Path $expanded 'src\BenchPilot.psm1'),
        (Join-Path $expanded 'BenchPilot.psd1'),
        (Join-Path $expanded 'BenchPilot.psm1')
    )

    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    return $null
}

function Resolve-BenchPilotRoot {
    [CmdletBinding()]
    param()

    $candidates = New-Object System.Collections.Generic.List[object]

    if (-not [string]::IsNullOrWhiteSpace($env:BENCHPILOT_ROOT)) {
        $candidates.Add([pscustomobject]@{ Source = 'env:BENCHPILOT_ROOT'; Root = $env:BENCHPILOT_ROOT; ModulePath = $null }) | Out-Null
    }

    if ($script:Cfg -and $script:Cfg.ContainsKey('BenchPilotRoot') -and -not [string]::IsNullOrWhiteSpace($script:Cfg.BenchPilotRoot)) {
        $candidates.Add([pscustomobject]@{ Source = 'setting:BenchPilotRoot'; Root = $script:Cfg.BenchPilotRoot; ModulePath = $null }) | Out-Null
    }

    $module = Get-Module -ListAvailable -Name BenchPilot -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if ($module) {
        $candidates.Add([pscustomobject]@{ Source = 'module:BenchPilot'; Root = $module.ModuleBase; ModulePath = $module.Path }) | Out-Null
    }

    $managed = Join-Path $HOME '.local-llm\tools\benchpilot'
    $candidates.Add([pscustomobject]@{ Source = 'managed'; Root = $managed; ModulePath = $null }) | Out-Null
    $candidates.Add([pscustomobject]@{ Source = 'dev'; Root = 'D:\repos\benchpilot'; ModulePath = $null }) | Out-Null

    foreach ($candidate in $candidates) {
        $modulePath = if ($candidate.ModulePath) { $candidate.ModulePath } else { Resolve-BenchPilotModulePath -Root $candidate.Root }
        if ($modulePath -and (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            $root = if ($candidate.Root) { Expand-LocalLLMPath $candidate.Root } else { Split-Path -Parent $modulePath }
            return [pscustomobject]@{
                Source = $candidate.Source
                Root = $root
                ModulePath = $modulePath
            }
        }
    }

    return $null
}

function Import-BenchPilotModule {
    [CmdletBinding()]
    param([string]$Root)

    $resolved = if ([string]::IsNullOrWhiteSpace($Root)) {
        Resolve-BenchPilotRoot
    } else {
        $modulePath = Resolve-BenchPilotModulePath -Root $Root
        if (-not $modulePath) { throw "BenchPilot module not found under $Root" }
        [pscustomobject]@{ Source = 'explicit'; Root = (Expand-LocalLLMPath $Root); ModulePath = $modulePath }
    }

    if (-not $resolved) {
        throw "BenchPilot was not found. Set BENCHPILOT_ROOT, setllm BenchPilotRoot <path>, install the BenchPilot module, or clone to ~/.local-llm/tools/benchpilot."
    }

    Import-Module $resolved.ModulePath -Force -ErrorAction Stop | Out-Null
    return $resolved
}

function Test-BenchPilotIntegrationAvailable {
    [CmdletBinding()]
    param([switch]$Quiet)

    $minimum = if ($script:Cfg -and $script:Cfg.ContainsKey('BenchPilotMinimumVersion')) {
        [string]$script:Cfg.BenchPilotMinimumVersion
    } else {
        '0.1.0'
    }

    $result = [ordered]@{
        Available = $false
        Found = $false
        Source = ''
        Root = ''
        ModulePath = ''
        Version = ''
        ApiVersion = 0
        LauncherExportVersion = 0
        MinimumVersion = $minimum
        Reason = ''
    }

    try {
        $resolved = Import-BenchPilotModule
        $result.Found = $true
        $result.Source = $resolved.Source
        $result.Root = $resolved.Root
        $result.ModulePath = $resolved.ModulePath

        if (-not (Get-Command Get-BenchPilotVersion -ErrorAction SilentlyContinue)) {
            $result.Reason = 'BenchPilot module imported, but Get-BenchPilotVersion is missing.'
            return [pscustomobject]$result
        }

        $version = Get-BenchPilotVersion
        $result.Version = [string]$version.version
        $result.ApiVersion = [int]$version.api_version
        $result.LauncherExportVersion = [int]$version.launcher_export_version

        $versionOk = $true
        try {
            $versionOk = ([version]$result.Version -ge [version]$minimum)
        }
        catch {
            $versionOk = $false
        }

        if (-not $versionOk) {
            $result.Reason = "BenchPilot $($result.Version) is below required $minimum."
            return [pscustomobject]$result
        }
        if ($result.ApiVersion -lt 1) {
            $result.Reason = "BenchPilot API version $($result.ApiVersion) is below required 1."
            return [pscustomobject]$result
        }
        if ($result.LauncherExportVersion -lt 1) {
            $result.Reason = "BenchPilot launcher export version $($result.LauncherExportVersion) is below required 1."
            return [pscustomobject]$result
        }

        $result.Available = $true
        $result.Reason = 'OK'
        return [pscustomobject]$result
    }
    catch {
        $result.Reason = $_.Exception.Message
        if (-not $Quiet) {
            Write-Verbose $result.Reason
        }
        return [pscustomobject]$result
    }
}

function Invoke-BenchPilotLauncherFindBest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [ValidateSet('native','turboquant')][string]$Mode = 'native',
        [string[]]$AllowedKvTypes,
        [int]$Budget = 30,
        [ValidateSet('gen','prompt','both')][string]$Optimize = 'gen',
        [int]$Runs = 1,
        [switch]$Quick,
        [switch]$Deep,
        [switch]$Aggressive,
        [switch]$AggressiveKv,
        [switch]$AllowKvQualityRegression,
        [ValidateSet('short','long')][string[]]$PromptLengths = @('short'),
        [switch]$NoSave
    )

    Import-BenchPilotModule | Out-Null
    if (-not (Get-Command Find-BenchPilotBestConfig -ErrorAction SilentlyContinue)) {
        throw "BenchPilot is available, but Find-BenchPilotBestConfig is not implemented by this version."
    }

    Find-BenchPilotBestConfig `
        -Target LocalBox `
        -Runtime llamacpp `
        -Key $Key `
        -ContextKey $ContextKey `
        -Mode $Mode `
        -PromptLengths $PromptLengths `
        -AllowedKvTypes $AllowedKvTypes `
        -Optimize $Optimize `
        -Budget $Budget `
        -Runs $Runs `
        -Quick:$Quick `
        -Deep:$Deep `
        -Aggressive:$Aggressive `
        -AggressiveKv:$AggressiveKv `
        -AllowKvQualityRegression:$AllowKvQualityRegression `
        -NoSave:$NoSave `
        -LauncherRoot $script:LLMProfileRoot
}

function Get-BenchPilotLauncherBestConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][string]$Mode,
        [ValidateSet('short','long')][string]$PromptLength = 'short',
        [string]$Quant
    )

    Import-BenchPilotModule | Out-Null
    if (-not (Get-Command Get-BenchPilotBestConfig -ErrorAction SilentlyContinue)) {
        throw "BenchPilot is available, but Get-BenchPilotBestConfig is not implemented by this version."
    }

    Get-BenchPilotBestConfig -Target LocalBox -Runtime llamacpp -Key $Key -ContextKey $ContextKey -Mode $Mode -PromptLength $PromptLength -Quant $Quant
}

function Get-BenchPilotLauncherBestConfigCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][string]$Mode,
        [ValidateSet('short','long')][string]$PromptLength = 'short',
        [string]$Quant
    )

    Import-BenchPilotModule | Out-Null
    if (-not (Get-Command Get-BenchPilotBestConfigCandidates -ErrorAction SilentlyContinue)) {
        throw "BenchPilot is available, but Get-BenchPilotBestConfigCandidates is not implemented by this version."
    }

    Get-BenchPilotBestConfigCandidates -Target LocalBox -Runtime llamacpp -Key $Key -ContextKey $ContextKey -Mode $Mode -PromptLength $PromptLength -Quant $Quant
}

function Show-BenchPilotLauncherHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [int]$Last = 50
    )

    Import-BenchPilotModule | Out-Null
    if (-not (Get-Command Show-BenchPilotHistory -ErrorAction SilentlyContinue)) {
        throw "BenchPilot is available, but Show-BenchPilotHistory is not implemented by this version."
    }

    Show-BenchPilotHistory -Target LocalBox -Runtime llamacpp -Key $Key -Last $Last
}

function Show-BenchPilotLauncherStatus {
    [CmdletBinding()]
    param([switch]$Quiet)

    $status = Test-BenchPilotIntegrationAvailable -Quiet

    if (-not $Quiet) {
        Write-Section "BenchPilot"
    }

    if ($status.Available) {
        Write-Host "BenchPilot : available $($status.Version) ($($status.Source))" -ForegroundColor Green
        Write-Host "Root       : $($status.Root)" -ForegroundColor DarkGray
        Write-Host "API/export : $($status.ApiVersion) / $($status.LauncherExportVersion)" -ForegroundColor DarkGray
        return $status
    }

    if ($status.Found) {
        Write-Host "BenchPilot : found but unavailable" -ForegroundColor Yellow
        Write-Host "Reason     : $($status.Reason)" -ForegroundColor DarkYellow
        Write-Host "Root       : $($status.Root)" -ForegroundColor DarkGray
    }
    else {
        Write-Host "BenchPilot : not found" -ForegroundColor DarkGray
        Write-Host "Fallback   : legacy tuner $($(if ($script:Cfg.BenchPilotAllowLegacyFallback) { 'enabled' } else { 'disabled' }))" -ForegroundColor DarkGray
        Write-Host "Configure  : setllm BenchPilotRoot D:\repos\benchpilot" -ForegroundColor DarkGray
    }

    return $status
}

function bpstatus {
    [CmdletBinding()]
    param()

    Show-BenchPilotLauncherStatus | Out-Null
}
