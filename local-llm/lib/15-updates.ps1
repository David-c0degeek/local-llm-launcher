# Git-backed update helpers for LocalBox and optional companion checkouts.

function Find-LocalBoxCheckoutUpwards {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$StartPath)

    if ([string]::IsNullOrWhiteSpace($StartPath)) { return $null }

    $current = $StartPath
    if (Test-Path -LiteralPath $current -PathType Leaf -ErrorAction SilentlyContinue) {
        $current = Split-Path -Parent $current
    }

    try { $current = (Resolve-Path -LiteralPath $current -ErrorAction Stop).Path }
    catch { return $null }

    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $installScript = Join-Path $current 'install.ps1'
        $profileScript = Join-Path $current 'local-llm\LocalLLMProfile.ps1'
        $gitDir = Join-Path $current '.git'

        if ((Test-Path -LiteralPath $installScript -PathType Leaf -ErrorAction SilentlyContinue) -and
            (Test-Path -LiteralPath $profileScript -PathType Leaf -ErrorAction SilentlyContinue) -and
            (Test-Path -LiteralPath $gitDir -ErrorAction SilentlyContinue)) {
            return $current
        }

        $parent = Split-Path -Parent $current
        if ($parent -eq $current) { break }
        $current = $parent
    }

    return $null
}

function Resolve-LocalBoxRoot {
    [CmdletBinding()]
    param()

    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALBOX_ROOT)) {
        $candidates.Add($env:LOCALBOX_ROOT) | Out-Null
    }

    if ($script:Cfg -and $script:Cfg.ContainsKey('LocalBoxRoot') -and -not [string]::IsNullOrWhiteSpace($script:Cfg.LocalBoxRoot)) {
        $candidates.Add($script:Cfg.LocalBoxRoot) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($script:LLMProfileRoot)) {
        $candidates.Add($script:LLMProfileRoot) | Out-Null

        $profileFile = Join-Path $script:LLMProfileRoot 'LocalLLMProfile.ps1'
        $profileItem = Get-Item -LiteralPath $profileFile -Force -ErrorAction SilentlyContinue
        if ($profileItem -and $profileItem.LinkType -eq 'SymbolicLink' -and $profileItem.Target) {
            $target = if ($profileItem.Target -is [array]) { $profileItem.Target[0] } else { $profileItem.Target }
            $candidates.Add($target) | Out-Null
        }
    }

    $candidates.Add((Get-Location).Path) | Out-Null

    foreach ($candidate in @($candidates)) {
        $expanded = Expand-LocalLLMPath $candidate
        $root = Find-LocalBoxCheckoutUpwards -StartPath $expanded
        if ($root) { return $root }
    }

    return $null
}

function Resolve-UnshackledRoot {
    [CmdletBinding()]
    param()

    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($env:UNSHACKLED_ROOT)) {
        $candidates.Add($env:UNSHACKLED_ROOT) | Out-Null
    }

    if ($script:Cfg -and $script:Cfg.ContainsKey('UnshackledRoot') -and -not [string]::IsNullOrWhiteSpace($script:Cfg.UnshackledRoot)) {
        $candidates.Add($script:Cfg.UnshackledRoot) | Out-Null
    }

    $candidates.Add((Join-Path $HOME '.local-llm\tools\unshackled')) | Out-Null

    foreach ($candidate in @($candidates)) {
        $expanded = Expand-LocalLLMPath $candidate
        if ([string]::IsNullOrWhiteSpace($expanded)) { continue }

        $cliPath = Join-Path $expanded 'src\entrypoints\cli.tsx'
        if (Test-Path -LiteralPath $cliPath -PathType Leaf -ErrorAction SilentlyContinue) {
            try { return (Resolve-Path -LiteralPath $expanded -ErrorAction Stop).Path }
            catch { return $expanded }
        }
    }

    return $null
}

function Invoke-LocalLLMGitFastForwardUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyString()][string]$Root,
        [switch]$DryRun
    )

    $result = [ordered]@{
        Name = $Name
        Root = $Root
        Installed = $false
        Status = 'missing'
        Updated = $false
        PreviousHead = ''
        NewHead = ''
        Reason = ''
    }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -ErrorAction SilentlyContinue)) {
        $result.Reason = "$Name is not installed."
        return [pscustomobject]$result
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    $result.Root = $resolvedRoot
    $result.Installed = $true

    if (-not (Test-Path -LiteralPath (Join-Path $resolvedRoot '.git') -ErrorAction SilentlyContinue)) {
        $result.Status = 'not-git'
        $result.Reason = "$Name is installed but is not a git checkout."
        return [pscustomobject]$result
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $result.Status = 'failed'
        $result.Reason = 'git is not on PATH.'
        return [pscustomobject]$result
    }

    $head = (& git -C $resolvedRoot rev-parse HEAD 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $result.Status = 'failed'
        $result.Reason = ($head | Out-String).Trim()
        return [pscustomobject]$result
    }
    $result.PreviousHead = [string]$head
    $result.NewHead = [string]$head

    $upstream = (& git -C $resolvedRoot rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $result.Status = 'no-upstream'
        $result.Reason = "$Name has no configured upstream branch."
        return [pscustomobject]$result
    }

    Write-Host "Checking $Name ($resolvedRoot)..." -ForegroundColor Cyan

    $fetchOutput = (& git -C $resolvedRoot fetch --prune 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $result.Status = 'failed'
        $result.Reason = ($fetchOutput | Out-String).Trim()
        return [pscustomobject]$result
    }

    $counts = (& git -C $resolvedRoot rev-list --left-right --count 'HEAD...@{u}' 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $result.Status = 'failed'
        $result.Reason = ($counts | Out-String).Trim()
        return [pscustomobject]$result
    }

    $parts = ([string]$counts).Trim() -split '\s+'
    $ahead = [int]$parts[0]
    $behind = [int]$parts[1]

    if ($ahead -gt 0 -and $behind -gt 0) {
        $result.Status = 'diverged'
        $result.Reason = "$Name is $ahead commit(s) ahead and $behind commit(s) behind $upstream; not pulling automatically."
        return [pscustomobject]$result
    }

    if ($behind -le 0) {
        $result.Status = 'current'
        $result.Reason = "$Name is already current."
        return [pscustomobject]$result
    }

    if ($DryRun) {
        $result.Status = 'available'
        $result.Reason = "$Name is $behind commit(s) behind $upstream."
        return [pscustomobject]$result
    }

    Write-Host "Updating $Name ($behind commit(s) behind $upstream)..." -ForegroundColor Cyan
    $pullOutput = (& git -C $resolvedRoot pull --ff-only 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $result.Status = 'failed'
        $result.Reason = ($pullOutput | Out-String).Trim()
        return [pscustomobject]$result
    }

    $newHead = (& git -C $resolvedRoot rev-parse HEAD 2>&1)
    if ($LASTEXITCODE -eq 0) { $result.NewHead = [string]$newHead }

    $result.Status = 'updated'
    $result.Updated = $true
    $result.Reason = "$Name updated."
    return [pscustomobject]$result
}

function Test-LocalBoxSymlinkInstall {
    [CmdletBinding()]
    param()

    $profileFile = Join-Path $script:LLMProfileRoot 'LocalLLMProfile.ps1'
    $profileItem = Get-Item -LiteralPath $profileFile -Force -ErrorAction SilentlyContinue
    return [bool]($profileItem -and $profileItem.LinkType -eq 'SymbolicLink')
}

function Invoke-LocalBoxInstallFromRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$DryRun
    )

    $installer = Join-Path $Root 'install.ps1'
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "LocalBox installer not found: $installer"
    }

    $args = @('-SkipToolPrompts')
    if (Test-LocalBoxSymlinkInstall) { $args += '-Symlink' }
    if ($DryRun) { $args += '-DryRun' }

    Write-Host "Reinstalling LocalBox profile files from $Root..." -ForegroundColor Cyan
    & $installer @args
}

function Update-LocalBox {
    [CmdletBinding()]
    param(
        [string]$Root,
        [switch]$DryRun
    )

    $resolvedRoot = if ([string]::IsNullOrWhiteSpace($Root)) { Resolve-LocalBoxRoot } else { $Root }
    $result = Invoke-LocalLLMGitFastForwardUpdate -Name 'LocalBox' -Root $resolvedRoot -DryRun:$DryRun

    if ($result.Updated -or ($DryRun -and $result.Status -eq 'available')) {
        Invoke-LocalBoxInstallFromRoot -Root $result.Root -DryRun:$DryRun
    }

    return $result
}

function Write-LocalLLMUpdateSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Results)

    Write-Host ""
    Write-Host "Update summary" -ForegroundColor Cyan

    foreach ($result in $Results) {
        $color = switch ($result.Status) {
            'updated' { 'Green' }
            'current' { 'DarkGreen' }
            'available' { 'Yellow' }
            'missing' { 'DarkGray' }
            default { 'Yellow' }
        }

        $detail = if ([string]::IsNullOrWhiteSpace($result.Reason)) { $result.Status } else { $result.Reason }
        Write-Host ("  {0,-12} {1,-11} {2}" -f $result.Name, $result.Status, $detail) -ForegroundColor $color
    }
}

function Update-LocalLLMSuite {
    [CmdletBinding()]
    param([switch]$DryRun)

    Write-Section 'LocalBox update'

    $results = @()

    try {
        $results += Update-LocalBox -DryRun:$DryRun
    }
    catch {
        $results += [pscustomobject]@{
            Name = 'LocalBox'
            Root = ''
            Installed = $false
            Status = 'failed'
            Updated = $false
            PreviousHead = ''
            NewHead = ''
            Reason = $_.Exception.Message
        }
    }

    $companions = @(
        [pscustomobject]@{ Name = 'Unshackled'; Root = (Resolve-UnshackledRoot) },
        [pscustomobject]@{ Name = 'BenchPilot'; Root = $(if (Get-Command Resolve-BenchPilotRoot -ErrorAction SilentlyContinue) { $resolved = Resolve-BenchPilotRoot; if ($resolved) { $resolved.Root } else { $null } } else { $null }) }
    )

    foreach ($companion in $companions) {
        try {
            $results += Invoke-LocalLLMGitFastForwardUpdate -Name $companion.Name -Root $companion.Root -DryRun:$DryRun
        }
        catch {
            $results += [pscustomobject]@{
                Name = $companion.Name
                Root = $companion.Root
                Installed = $false
                Status = 'failed'
                Updated = $false
                PreviousHead = ''
                NewHead = ''
                Reason = $_.Exception.Message
            }
        }
    }

    Write-LocalLLMUpdateSummary -Results $results
    return $results
}

function llm-update {
    [CmdletBinding()]
    param([switch]$DryRun)

    Update-LocalLLMSuite -DryRun:$DryRun | Out-Null
}

function llmupdate {
    [CmdletBinding()]
    param([switch]$DryRun)

    llm-update -DryRun:$DryRun
}
