# BenchPilot discovery/import bridge. The launcher owns launch-time AutoBest
# loading; BenchPilot owns benchmark execution and compatible profile export.

function Resolve-BenchPilotModulePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) { return $null }

    $expanded = Expand-LocalLLMPath $Root
    if (-not (Test-Path -LiteralPath $expanded -ErrorAction SilentlyContinue)) { return $null }

    if (Test-Path -LiteralPath $expanded -PathType Leaf -ErrorAction SilentlyContinue) {
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
        if (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue) {
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
            Write-LaunchLog "BenchPilot check failed: $($result.Reason)" 'WARN'
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
        [string]$Quant,
        [string[]]$AllowedKvTypes,
        [int]$Budget = 60,
        [ValidateSet('gen','prompt','both','coding-agent')][string]$Optimize = 'coding-agent',
        [int]$Runs = 3,
        [switch]$Quick,
        [switch]$Deep,
        [switch]$Aggressive,
        [switch]$AggressiveKv,
        [switch]$AllowKvQualityRegression,
        [ValidateSet('short','long')][string[]]$PromptLengths = @(),
        [ValidateSet('pure','balanced','both')][string]$Profile = 'pure',
        [ValidateSet('greedy','beam')][string]$SearchStrategy,
        [int]$BeamWidth = 1,
        [int[]]$NCpuMoeCandidates,
        [switch]$NoSave
    )

    Import-BenchPilotModule | Out-Null
    if (-not (Get-Command Find-BenchPilotBestConfig -ErrorAction SilentlyContinue)) {
        throw "BenchPilot is available, but Find-BenchPilotBestConfig is not implemented by this version."
    }

    if (-not $PromptLengths -or $PromptLengths.Count -eq 0) {
        $PromptLengths = if ($Optimize -eq 'coding-agent') { @('long') } else { @('short') }
    }

    $params = @{
        Target = 'LocalBox'
        Runtime = 'llamacpp'
        Key = $Key
        ContextKey = $ContextKey
        Mode = $Mode
        Quant = $Quant
        PromptLengths = $PromptLengths
        AllowedKvTypes = $AllowedKvTypes
        Optimize = $Optimize
        Budget = $Budget
        Runs = $Runs
        Quick = $Quick
        Deep = $Deep
        Aggressive = $Aggressive
        AggressiveKv = $AggressiveKv
        AllowKvQualityRegression = $AllowKvQualityRegression
        Profile = $Profile
        NoSave = $NoSave
        LauncherRoot = $script:LLMProfileRoot
    }
    if ($PSBoundParameters.ContainsKey('SearchStrategy') -and -not [string]::IsNullOrWhiteSpace($SearchStrategy)) {
        $params.SearchStrategy = $SearchStrategy
    }
    if ($PSBoundParameters.ContainsKey('BeamWidth')) {
        $params.BeamWidth = $BeamWidth
    }
    if ($PSBoundParameters.ContainsKey('NCpuMoeCandidates') -and $NCpuMoeCandidates -and $NCpuMoeCandidates.Count -gt 0) {
        $params.NCpuMoeCandidates = $NCpuMoeCandidates
    }

    Find-BenchPilotBestConfig @params
}

function Get-BenchPilotTopNCpuMoeValues {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowEmptyString()][string]$ContextKey = '',
        [int]$TopN = 5
    )
    try { Import-BenchPilotModule | Out-Null } catch { return @() }
    if (Get-Command Get-LlamaCppTopNCpuMoeFromCandidates -ErrorAction SilentlyContinue) {
        return @(Get-LlamaCppTopNCpuMoeFromCandidates -Key $Key -ContextKey $ContextKey -TopN $TopN)
    }
    return @()
}

function Get-BenchPilotLauncherBestConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][string]$Mode,
        [ValidateSet('short','long')][string]$PromptLength = 'short',
        [string]$Quant,
        [ValidateSet('pure','balanced')][string]$Profile = 'pure'
    )

    Import-BenchPilotModule | Out-Null
    if (-not (Get-Command Get-BenchPilotBestConfig -ErrorAction SilentlyContinue)) {
        throw "BenchPilot is available, but Get-BenchPilotBestConfig is not implemented by this version."
    }

    Get-BenchPilotBestConfig -Target LocalBox -Runtime llamacpp -Key $Key -ContextKey $ContextKey -Mode $Mode -PromptLength $PromptLength -Quant $Quant -Profile $Profile
}

function Get-BenchPilotLauncherBestConfigCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][string]$Mode,
        [ValidateSet('short','long')][string]$PromptLength = 'short',
        [string]$Quant,
        [ValidateSet('pure','balanced')][string]$Profile = 'pure'
    )

    Import-BenchPilotModule | Out-Null
    if (-not (Get-Command Get-BenchPilotBestConfigCandidates -ErrorAction SilentlyContinue)) {
        throw "BenchPilot is available, but Get-BenchPilotBestConfigCandidates is not implemented by this version."
    }

    Get-BenchPilotBestConfigCandidates -Target LocalBox -Runtime llamacpp -Key $Key -ContextKey $ContextKey -Mode $Mode -PromptLength $PromptLength -Quant $Quant -Profile $Profile
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
        Write-Host "Tuning     : unavailable until BenchPilot is installed" -ForegroundColor DarkGray
        Write-Host "Configure  : setllm BenchPilotRoot <path-to-benchpilot>" -ForegroundColor DarkGray
    }

    return $status
}

function bpstatus {
    [CmdletBinding()]
    param()

    Show-BenchPilotLauncherStatus | Out-Null
}

function Install-BenchPilot {
    [CmdletBinding()]
    param(
        [string]$Destination = (Join-Path $HOME '.local-llm\tools\benchpilot'),
        [switch]$Force
    )

    if ((Resolve-BenchPilotModulePath -Root $Destination) -and -not $Force) {
        Write-Host "BenchPilot already exists: $Destination" -ForegroundColor Green
        Set-LocalLLMSetting BenchPilotRoot $Destination
        return $Destination
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git is not on PATH; cannot clone BenchPilot."
    }

    $repoUrl = if ($script:Cfg.ContainsKey('BenchPilotRepoUrl') -and -not [string]::IsNullOrWhiteSpace($script:Cfg.BenchPilotRepoUrl)) {
        [string]$script:Cfg.BenchPilotRepoUrl
    } else {
        'https://github.com/David-c0degeek/benchpilot'
    }

    Ensure-Directory (Split-Path -Parent $Destination)
    if (Test-Path -LiteralPath $Destination) {
        throw "Destination already exists: $Destination. Use Update-BenchPilot, or remove it and retry."
    }

    & git clone $repoUrl $Destination
    if ($LASTEXITCODE -ne 0) { throw "git clone failed for $repoUrl" }

    Set-LocalLLMSetting BenchPilotRoot $Destination
    return $Destination
}

function Update-BenchPilot {
    [CmdletBinding()]
    param()

    $resolved = Resolve-BenchPilotRoot
    if (-not $resolved) {
        throw "BenchPilot is not installed. Run Install-BenchPilot first."
    }

    $root = $resolved.Root
    $result = Invoke-LocalLLMGitFastForwardUpdate -Name 'BenchPilot' -Root $root
    if ($result.Status -in @('failed', 'not-git', 'no-upstream', 'diverged')) {
        throw $result.Reason
    }
    return $result
}
