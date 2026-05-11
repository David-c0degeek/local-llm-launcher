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

function Get-LocalLLMDeployedProxyPath {
    return Join-Path $HOME '.ollama-proxy\no-think-proxy.py'
}

function Get-LocalLLMRepoProxyPath {
    # The proxy source-of-truth alongside the launcher checkout. Walk up from
    # the profile root until we find ../ollama-proxy/no-think-proxy.py.
    $root = Resolve-LocalBoxRoot
    if ([string]::IsNullOrWhiteSpace($root)) { return $null }
    $candidate = Join-Path $root 'ollama-proxy\no-think-proxy.py'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}

function Get-LocalLLMDeployedProxyVersion {
    # Returns the deployed proxy's __version__ via `python no-think-proxy.py
    # --version`. $null when the proxy or python is missing, or the check
    # fails for any reason (treated as "unknown" by callers).
    [CmdletBinding()]
    param([string]$ProxyPath)

    if ([string]::IsNullOrWhiteSpace($ProxyPath)) {
        $ProxyPath = Get-LocalLLMDeployedProxyPath
    }

    if (-not (Test-Path -LiteralPath $ProxyPath)) { return $null }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { return $null }

    try {
        $output = & $python.Source $ProxyPath --version 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        $line = ($output | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($line)) { return $null }
        return $line.Trim()
    }
    catch {
        return $null
    }
}

function Test-LocalLLMProxyVersion {
    # Compare the deployed proxy version against the launcher's required
    # version (defaults.json -> NoThinkProxyRequiredVersion). Returns a status
    # hashtable; never throws. Emits a single yellow warning on mismatch.
    [CmdletBinding()]
    param([switch]$Quiet)

    $required = if ($script:Cfg -and $script:Cfg.Contains('NoThinkProxyRequiredVersion')) {
        [string]$script:Cfg.NoThinkProxyRequiredVersion
    } else {
        $null
    }

    if ([string]::IsNullOrWhiteSpace($required)) {
        return @{ Status = 'no-pin'; Required = $null; Deployed = $null }
    }

    $deployed = Get-LocalLLMDeployedProxyVersion
    if ([string]::IsNullOrWhiteSpace($deployed)) {
        if (-not $Quiet) {
            $deployedPath = Get-LocalLLMDeployedProxyPath
            $msg = ("no-think proxy version unknown (deployed copy at {0} did not respond to --version). " +
                "Required: {1}. Run Update-LocalLLMProxy or re-run install.ps1.") -f $deployedPath, $required
            Write-Warning $msg
        }
        return @{ Status = 'unknown'; Required = $required; Deployed = $null }
    }

    if ($deployed -eq $required) {
        return @{ Status = 'ok'; Required = $required; Deployed = $deployed }
    }

    if (-not $Quiet) {
        $msg = ("no-think proxy version mismatch: deployed={0}, required={1}. " +
            "Wire-format may have changed. Run Update-LocalLLMProxy to refresh.") -f $deployed, $required
        Write-Warning $msg
    }
    return @{ Status = 'mismatch'; Required = $required; Deployed = $deployed }
}

function Update-LocalLLMProxy {
    # Copy the repo's no-think-proxy.py over the deployed copy. No-op when the
    # deployed copy is a symlink (it already points at the repo).
    [CmdletBinding()]
    param([switch]$Force)

    $deployed = Get-LocalLLMDeployedProxyPath
    $source = Get-LocalLLMRepoProxyPath
    if (-not $source) {
        throw "Cannot locate ollama-proxy\no-think-proxy.py in the launcher repo. Set LOCALBOX_ROOT or re-run install.ps1."
    }

    # Symlink deployments stay in sync automatically.
    $item = Get-Item -LiteralPath $deployed -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType -eq 'SymbolicLink') {
        Write-Host "Deployed proxy is a symlink to: $($item.Target). Nothing to copy." -ForegroundColor DarkGray
        return @{ Status = 'symlink'; Deployed = $deployed; Source = $source }
    }

    if ((Test-Path -LiteralPath $deployed) -and -not $Force) {
        $deployedHash = (Get-FileHash -LiteralPath $deployed -Algorithm SHA256).Hash
        $sourceHash   = (Get-FileHash -LiteralPath $source   -Algorithm SHA256).Hash
        if ($deployedHash -eq $sourceHash) {
            Write-Host "Deployed proxy is already up to date: $deployed" -ForegroundColor DarkGray
            return @{ Status = 'up-to-date'; Deployed = $deployed; Source = $source }
        }
    }

    $deployedDir = Split-Path -Parent $deployed
    if (-not (Test-Path -LiteralPath $deployedDir)) {
        New-Item -ItemType Directory -Path $deployedDir | Out-Null
    }

    Copy-Item -LiteralPath $source -Destination $deployed -Force
    Write-Host "Updated no-think proxy: $deployed (from $source)" -ForegroundColor Green
    return @{ Status = 'updated'; Deployed = $deployed; Source = $source }
}

function Migrate-LocalLLMConfig {
    # One-shot migration to the defaults.json / llm-models.json split. Looks at
    # the deployed catalog (the file Import-LocalLLMConfig reads); if it still
    # carries the legacy top-level scalars and a defaults.json doesn't yet exist
    # next to it, splits them out. Idempotent: returns 'noop' when nothing
    # needs doing.
    [CmdletBinding()]
    param([switch]$WhatIf, [switch]$Quiet)

    $catalogPath = $script:LocalLLMConfigPath
    $defaultsPath = Get-LocalLLMDefaultsPath

    if (-not (Test-Path -LiteralPath $catalogPath)) {
        if (-not $Quiet) { Write-Host "Catalog not found: $catalogPath" -ForegroundColor DarkGray }
        return 'noop'
    }

    $catalog = Get-Content -Raw -Path $catalogPath | ConvertFrom-Json -AsHashtable

    $legacy = [ordered]@{}
    foreach ($key in @($catalog.Keys)) {
        if ($key -in @('Models', 'CommandAliases')) { continue }
        $legacy[$key] = $catalog[$key]
    }

    if ($legacy.Count -eq 0) {
        if (-not $Quiet) { Write-Host "Catalog is already in pure-data shape." -ForegroundColor DarkGray }
        return 'noop'
    }

    if (Test-Path -LiteralPath $defaultsPath) {
        if (-not $Quiet) {
            Write-Warning ("defaults.json already exists; refusing to overwrite. Move conflicting keys " +
                "from $catalogPath into $defaultsPath manually, then delete them from the catalog.")
        }
        return 'conflict'
    }

    if ($WhatIf) {
        Write-Host "Would move these keys from $catalogPath to $defaultsPath :" -ForegroundColor Cyan
        foreach ($k in $legacy.Keys) { Write-Host "  $k" -ForegroundColor DarkGray }
        return 'pending'
    }

    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($defaultsPath, ($legacy | ConvertTo-Json -Depth 8), $utf8)

    $newCatalog = [ordered]@{}
    if ($catalog.Contains('Models'))         { $newCatalog['Models']         = $catalog['Models'] }
    if ($catalog.Contains('CommandAliases')) { $newCatalog['CommandAliases'] = $catalog['CommandAliases'] }

    [System.IO.File]::WriteAllText($catalogPath, ($newCatalog | ConvertTo-Json -Depth 32), $utf8)

    if (-not $Quiet) {
        Write-Host "Migrated: moved $($legacy.Count) launcher setting(s) from $catalogPath to $defaultsPath" -ForegroundColor Green
    }

    return 'migrated'
}
