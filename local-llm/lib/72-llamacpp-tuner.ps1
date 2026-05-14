# BenchPilot bridge and AutoBest profile contract.
#
# LocalBox no longer owns llama.cpp benchmark/search logic. Tuning is delegated
# to BenchPilot; this file only keeps the launcher-facing profile I/O and
# compatibility commands (`findbest`, `tunellm`, history display).

$script:LlamaCppTunerVersion = 4

function Get-LlamaCppTunerRoot {
    $root = Join-Path $HOME ".local-llm\tuner"
    Ensure-Directory $root
    return $root
}

function Get-LlamaCppTunerHistoryFile {
    param([Parameter(Mandatory = $true)][string]$Key)
    return Join-Path (Get-LlamaCppTunerRoot) "history-$Key.jsonl"
}

function Get-LlamaCppTunerBestFile {
    param([Parameter(Mandatory = $true)][string]$Key)
    return Join-Path (Get-LlamaCppTunerRoot) "best-$Key.json"
}

function Get-LlamaCppBuildStamp {
    param([ValidateSet('native','turboquant')][string]$Mode = 'native')

    $root = if ($Mode -eq 'turboquant') { Get-LlamaCppTurboquantInstallRoot } else { Get-LlamaCppInstallRoot }
    $path = Join-Path $root ".build-stamp"
    if (-not (Test-Path $path)) { return '' }

    try { return (Get-Content -Raw -Path $path -ErrorAction Stop).Trim() }
    catch { return '' }
}

function Get-LlamaCppGpuNames {
    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) { return @() }

    try {
        return @(& nvidia-smi --query-gpu=name --format=csv,noheader 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    catch {
        return @()
    }
}

function Format-LlamaCppOverrides {
    # One-line stable display form for AutoBest overrides returned by BenchPilot
    # or loaded from the local profile cache.
    param([Parameter(Mandatory = $true)]$Overrides)

    $parts = @()
    foreach ($k in @('NGpuLayers','NCpuMoe','UbatchSize','BatchSize','Threads','FlashAttn','Mlock','NoMmap','KvK','KvV','SwaFull','CachePrompt','CacheReuse')) {
        $value = $null
        $hasValue = $false

        if ($Overrides -is [System.Collections.IDictionary]) {
            $hasValue = $Overrides.Contains($k)
            if ($hasValue) { $value = $Overrides[$k] }
        } else {
            $prop = $Overrides.PSObject.Properties[$k]
            if ($prop) {
                $hasValue = $true
                $value = $prop.Value
            }
        }

        if ($hasValue -and $null -ne $value) {
            $parts += "$k=$value"
        }
    }

    return ($parts -join ' ')
}

function Save-LlamaCppBestConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$Quant,
        [Parameter(Mandatory = $true)][int]$VramGB,
        [int]$ContextTokens = 0,
        [ValidateSet('short','long')][string]$PromptLength = 'short',
        [Parameter(Mandatory = $true)][string[]]$BestArgs,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$BestOverrides,
        [Parameter(Mandatory = $true)][double]$Score,
        [string]$ScoreUnit = 'tg_tps_avg',
        [int]$TrialCount = 0,
        [ValidateSet('pure','balanced')][string]$Profile = 'pure',
        [ValidateSet('greedy','beam')][string]$SearchStrategy = 'greedy',
        [int]$BeamWidth = 1,
        [double]$PureScore = 0.0,
        [System.Collections.IDictionary]$Telemetry = @{},
        [System.Collections.IDictionary]$ScoreBreakdown = @{}
    )

    $def = Get-ModelDef -Key $Key
    $ContextKey = Resolve-ModelContextKey -Def $def -ContextKey $ContextKey
    $path = Get-LlamaCppTunerBestFile -Key $Key

    $existing = if (Test-Path $path) {
        try { Get-Content -Raw -Path $path | ConvertFrom-Json -AsHashtable } catch { $null }
    } else { $null }

    if (-not $existing -or -not $existing.Contains('schema')) {
        $existing = [ordered]@{
            schema  = 1
            key     = $Key
            vramGB  = $VramGB
            entries = @()
        }
    }

    if (-not $ContextTokens -or $ContextTokens -le 0) {
        try { $ContextTokens = [int](Get-ModelContextValue -Def (Get-ModelDef -Key $Key) -ContextKey $ContextKey) } catch {}
    }

    $entries = @($existing.entries | Where-Object {
        $entryPromptLength = if ($_['prompt_length']) { [string]$_['prompt_length'] } else { 'short' }
        $entryProfile = if ($_['profile']) { [string]$_['profile'] } else { 'pure' }
        $entryContextKey = try { Resolve-ModelContextKey -Def $def -ContextKey ([string]$_.contextKey) } catch { [string]$_.contextKey }
        $_.quant -ne $Quant -or
        $entryContextKey -ne $ContextKey -or
        $_.mode -ne $Mode -or
        [int]$_.vramGB -ne $VramGB -or
        $entryPromptLength -ne $PromptLength -or
        $entryProfile -ne $Profile
    })

    $newEntry = [ordered]@{
        quant         = $Quant
        contextKey    = $ContextKey
        contextTokens = $ContextTokens
        mode          = $Mode
        vramGB        = $VramGB
        prompt_length = $PromptLength
        profile       = $Profile
        searchStrategy = $SearchStrategy
        beamWidth     = $BeamWidth
        score         = [math]::Round($Score, 2)
        scoreUnit     = $ScoreUnit
        pureScore     = [math]::Round($(if ($PureScore -gt 0) { $PureScore } else { $Score }), 2)
        args          = @($BestArgs)
        overrides     = $BestOverrides
        telemetry     = $Telemetry
        scoreBreakdown = $ScoreBreakdown
        measured_at   = (Get-Date).ToString('o')
        tuner_version = $script:LlamaCppTunerVersion
        trial_count   = $TrialCount
        gpu_names     = @(Get-LlamaCppGpuNames)
        llamacpp_build = (Get-LlamaCppBuildStamp -Mode $Mode)
    }

    $entries += $newEntry

    $existing.vramGB  = $VramGB
    $existing.key     = $Key
    $existing.schema  = 1
    $existing.entries = $entries

    $json = $existing | ConvertTo-Json -Depth 8
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $json, $utf8NoBom)

    return $path
}

function Get-BestLlamaCppConfig {
    # Loads a saved best-config entry matching (key, quant, contextKey, mode, vramGB+/-1).
    # Returns $null on miss. The launcher uses this for -AutoBest.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][string]$Mode,
        [ValidateSet('short','long')][string]$PromptLength = 'short',
        [string]$Quant,
        [int]$VramGB,
        [ValidateSet('pure','balanced')][string]$Profile = 'pure'
    )

    $path = Get-LlamaCppTunerBestFile -Key $Key
    if (-not (Test-Path $path)) { return $null }

    $data = $null
    try { $data = Get-Content -Raw -Path $path | ConvertFrom-Json -AsHashtable }
    catch { return $null }

    if (-not $data -or -not $data.Contains('entries')) { return $null }
    if ([int]($data.tuner_version) -gt 0 -and [int]$data.tuner_version -ne $script:LlamaCppTunerVersion) {
        return $null
    }

    if (-not $VramGB) { $VramGB = Get-LocalLLMVRAMGB }
    $def = Get-ModelDef -Key $Key
    $ContextKey = Resolve-ModelContextKey -Def $def -ContextKey $ContextKey

    if ([string]::IsNullOrWhiteSpace($Quant)) {
        if ($def.Contains('Quant')) { $Quant = [string]$def.Quant }
    }

    foreach ($entry in $data.entries) {
        $entryContextKey = try { Resolve-ModelContextKey -Def $def -ContextKey ([string]$entry.contextKey) } catch { [string]$entry.contextKey }
        if ($entryContextKey -ne $ContextKey) { continue }
        if ($entry.mode       -ne $Mode)       { continue }
        $entryPromptLength = if ($entry.prompt_length) { [string]$entry.prompt_length } else { 'short' }
        if ($entryPromptLength -ne $PromptLength) { continue }
        $entryProfile = if ($entry.profile) { [string]$entry.profile } else { 'pure' }
        if ($entryProfile -ne $Profile) { continue }
        if ($Quant -and $entry.quant -ne $Quant) { continue }
        $delta = [Math]::Abs([int]$entry.vramGB - [int]$VramGB)
        if ($delta -gt 1) { continue }
        if ($entry.tuner_version -and [int]$entry.tuner_version -ne $script:LlamaCppTunerVersion) { continue }
        return $entry
    }

    return $null
}

function Get-PreferredLlamaCppBestConfig {
    # For agentic/coding launches, prefer profiles tuned against long prefill
    # and end-to-end scoring. Fall back to short/generation v4 profiles only
    # when no better match exists, so existing installs still launch with a
    # clear warning.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][string]$Mode,
        [string]$Quant,
        [int]$VramGB,
        [ValidateSet('auto','pure','balanced')][string]$Profile = 'auto'
    )

    $candidates = @()
    $selectionProfiles = if ($Profile -eq 'auto') { @('balanced', 'pure') } else { @($Profile) }
    foreach ($selectionProfile in $selectionProfiles) {
        foreach ($promptProfile in @('long', 'short')) {
            $entry = Get-BestLlamaCppConfig -Key $Key -ContextKey $ContextKey -Mode $Mode -PromptLength $promptProfile -Quant $Quant -VramGB $VramGB -Profile $selectionProfile
            if ($entry) {
                $unit = [string]$entry.scoreUnit
                $rank = if ($selectionProfile -eq 'balanced') { 0 } else { 1 }
                $unitRank = if ($unit -match 'coding_agent') { 0 }
                            elseif ($unit -match '^both') { 1 }
                            elseif ($unit -match '^prompt') { 2 }
                            elseif ($unit -match '^gen|^tg') { 3 }
                            else { 4 }
                $candidates += [pscustomobject]@{
                    Entry = $entry
                    PromptLength = $promptProfile
                    Profile = $selectionProfile
                    Rank = $rank
                    UnitRank = $unitRank
                }
            }
        }
    }

    if ($candidates.Count -eq 0) { return $null }
    return @($candidates | Sort-Object Rank, UnitRank, @{ Expression = { if ($_.PromptLength -eq 'long') { 0 } else { 1 } } } | Select-Object -First 1)[0]
}

function Get-LlamaCppBestConfigCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][string]$Mode,
        [ValidateSet('short','long')][string]$PromptLength = 'short',
        [string]$Quant,
        [ValidateSet('pure','balanced')][string]$Profile = 'pure'
    )

    $path = Get-LlamaCppTunerBestFile -Key $Key
    if (-not (Test-Path $path)) { return @() }

    try { $data = Get-Content -Raw -Path $path | ConvertFrom-Json }
    catch { return @() }

    if (-not $data -or -not $data.entries) { return @() }
    $def = Get-ModelDef -Key $Key
    $ContextKey = Resolve-ModelContextKey -Def $def -ContextKey $ContextKey
    return @($data.entries | Where-Object {
        $entryContextKey = try { Resolve-ModelContextKey -Def $def -ContextKey ([string]$_.contextKey) } catch { [string]$_.contextKey }
        $entryContextKey -eq $ContextKey -and
        $_.mode -eq $Mode -and
        ($(if ($_.prompt_length) { [string]$_.prompt_length } else { 'short' }) -eq $PromptLength) -and
        ($(if ($_.profile) { [string]$_.profile } else { 'pure' }) -eq $Profile) -and
        ([string]::IsNullOrWhiteSpace($Quant) -or $_.quant -eq $Quant)
    })
}

function Remove-LlamaCppBestConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][string]$Mode,
        [string]$Quant,
        [int]$VramGB,
        [ValidateSet('short','long')][string]$PromptLength,
        [switch]$AllPromptLengths
    )

    if (-not $VramGB) { $VramGB = Get-LocalLLMVRAMGB }
    $def = Get-ModelDef -Key $Key
    $ContextKey = Resolve-ModelContextKey -Def $def -ContextKey $ContextKey
    if ([string]::IsNullOrWhiteSpace($Quant)) {
        if ($def.Contains('Quant')) { $Quant = [string]$def.Quant }
    }

    $path = Get-LlamaCppTunerBestFile -Key $Key
    if (-not (Test-Path $path)) {
        return [pscustomobject]@{ Path = $path; Removed = 0; Remaining = 0; DeletedFile = $false; RemovedBenchPilotProfiles = @() }
    }

    $data = $null
    try { $data = Get-Content -Raw -Path $path | ConvertFrom-Json -AsHashtable }
    catch {
        throw "Could not read saved best settings from $path. $($_.Exception.Message)"
    }

    if (-not $data -or -not $data.Contains('entries')) {
        return [pscustomobject]@{ Path = $path; Removed = 0; Remaining = 0; DeletedFile = $false; RemovedBenchPilotProfiles = @() }
    }

    $kept = @()
    $removed = 0
    $removedBenchPilotProfiles = @()
    foreach ($entry in @($data.entries)) {
        $entryPromptLength = if ($entry.prompt_length) { [string]$entry.prompt_length } else { 'short' }
        $vramMatches = $entry.vramGB -and ([Math]::Abs([int]$entry.vramGB - [int]$VramGB) -le 1)
        $promptMatches = if ($AllPromptLengths -or [string]::IsNullOrWhiteSpace($PromptLength)) {
            $true
        } else {
            $entryPromptLength -eq $PromptLength
        }

        $entryContextKey = try { Resolve-ModelContextKey -Def $def -ContextKey ([string]$entry.contextKey) } catch { [string]$entry.contextKey }
        $matches = (
            $entryContextKey -eq $ContextKey -and
            $entry.mode -eq $Mode -and
            $vramMatches -and
            $promptMatches -and
            ([string]::IsNullOrWhiteSpace($Quant) -or $entry.quant -eq $Quant)
        )

        if ($matches) {
            $removed++
            if ($entry.benchpilot_profile_path) {
                $removedBenchPilotProfiles += [string]$entry.benchpilot_profile_path
            }
        } else {
            $kept += $entry
        }
    }

    if ($removed -le 0) {
        return [pscustomobject]@{ Path = $path; Removed = 0; Remaining = @($data.entries).Count; DeletedFile = $false; RemovedBenchPilotProfiles = @() }
    }

    if ($kept.Count -eq 0) {
        Remove-Item -LiteralPath $path -Force
        foreach ($profilePath in @($removedBenchPilotProfiles | Where-Object { $_ } | Select-Object -Unique)) {
            $expanded = Expand-LocalLLMPath $profilePath
            if (Test-Path -LiteralPath $expanded) {
                Remove-Item -LiteralPath $expanded -Force -ErrorAction SilentlyContinue
            }
        }
        return [pscustomobject]@{ Path = $path; Removed = $removed; Remaining = 0; DeletedFile = $true; RemovedBenchPilotProfiles = @($removedBenchPilotProfiles) }
    }

    $data.entries = $kept
    $json = $data | ConvertTo-Json -Depth 8
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $json, $utf8NoBom)

    foreach ($profilePath in @($removedBenchPilotProfiles | Where-Object { $_ } | Select-Object -Unique)) {
        $expanded = Expand-LocalLLMPath $profilePath
        if (Test-Path -LiteralPath $expanded) {
            Remove-Item -LiteralPath $expanded -Force -ErrorAction SilentlyContinue
        }
    }

    return [pscustomobject]@{ Path = $path; Removed = $removed; Remaining = $kept.Count; DeletedFile = $false; RemovedBenchPilotProfiles = @($removedBenchPilotProfiles) }
}

function Test-LlamaCppBestConfigStale {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [ValidateSet('native','turboquant')][string]$Mode = 'native'
    )

    $reasons = @()

    $savedGpus = @($Entry.gpu_names | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $currentGpus = @(Get-LlamaCppGpuNames)
    if ($savedGpus.Count -gt 0 -and $currentGpus.Count -gt 0) {
        if (($savedGpus -join '|') -ne ($currentGpus -join '|')) {
            $reasons += "GPU changed: saved='$($savedGpus -join ', ')' current='$($currentGpus -join ', ')'"
        }
    }

    $savedBuild = [string]$Entry.llamacpp_build
    $currentBuild = Get-LlamaCppBuildStamp -Mode $Mode
    if (-not [string]::IsNullOrWhiteSpace($savedBuild) -and -not [string]::IsNullOrWhiteSpace($currentBuild) -and $savedBuild -ne $currentBuild) {
        $reasons += "llama.cpp build changed"
    }

    return @($reasons)
}

function Save-BestLlamaCppConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$Quant,
        [Parameter(Mandatory = $true)][int]$VramGB,
        [int]$ContextTokens = 0,
        [ValidateSet('short','long')][string]$PromptLength = 'short',
        [Parameter(Mandatory = $true)][string[]]$BestArgs,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$BestOverrides,
        [Parameter(Mandatory = $true)][double]$Score,
        [string]$ScoreUnit = 'tg_tps_avg',
        [int]$TrialCount = 0,
        [ValidateSet('pure','balanced')][string]$Profile = 'pure',
        [ValidateSet('greedy','beam')][string]$SearchStrategy = 'greedy',
        [int]$BeamWidth = 1,
        [double]$PureScore = 0.0,
        [System.Collections.IDictionary]$Telemetry = @{},
        [System.Collections.IDictionary]$ScoreBreakdown = @{}
    )
    return Save-LlamaCppBestConfig @PSBoundParameters
}

function Find-BestLlamaCppConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [ValidateSet('native','turboquant')][string]$Mode = 'native',
        [string]$Quant,
        [string[]]$AllowedKvTypes,
        [int]$Budget = 100,
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

    if (-not $PromptLengths -or $PromptLengths.Count -eq 0) {
        $PromptLengths = if ($Optimize -eq 'coding-agent') { @('long') } else { @('short') }
        $PSBoundParameters['PromptLengths'] = $PromptLengths
    }

    $bpStatus = Test-BenchPilotIntegrationAvailable -Quiet
    if (-not $bpStatus.Available) {
        throw "BenchPilot is required for tuning. Reason: $($bpStatus.Reason). Run Install-BenchPilot or setllm BenchPilotRoot <path-to-benchpilot>."
    }

    Write-Host "findbest: using BenchPilot ($($bpStatus.Version), $($bpStatus.Source))." -ForegroundColor Cyan
    return Invoke-BenchPilotLauncherFindBest @PSBoundParameters
}

function Read-LlamaCppTunerHistoryEntries {
    param([Parameter(Mandatory = $true)][string]$Key)

    $path = Get-LlamaCppTunerHistoryFile -Key $Key
    if (-not (Test-Path $path)) { return @() }

    $lines = Get-Content -Path $path -Encoding UTF8
    $entries = foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { ConvertFrom-Json $line } catch { continue }
    }
    return @($entries)
}

function Show-LlamaCppTunerHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [int]$Last = 50
    )

    if (Get-Command Show-BenchPilotLauncherHistory -ErrorAction SilentlyContinue) {
        Show-BenchPilotLauncherHistory -Key $Key -Last $Last
        return
    }

    $entries = @(Read-LlamaCppTunerHistoryEntries -Key $Key)

    if ($entries.Count -eq 0) {
        Write-Host "No tuner history for $Key. Run 'findbest $Key -ContextKey ...' first." -ForegroundColor DarkGray
        return
    }

    $entries | Select-Object -Last $Last | ForEach-Object {
        $ov = if ($_.overrides) { ($_.overrides.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' ' } else { '' }
        [pscustomobject]@{
            ts       = $_.ts
            phase    = $_.phase
            oom      = [bool]$_.oom
            startup  = [bool]$_.startup_ok
            pp_tps   = $_.pp_tps
            tg_tps   = $_.tg_tps
            score    = $_.score
            override = $ov
        }
    } | Format-Table -AutoSize
}

function findbest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [ValidateSet('native','turboquant')][string]$Mode = 'native',
        [string]$Quant,
        [string[]]$AllowedKvTypes,
        [int]$Budget = 100,
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
    if (-not $PromptLengths -or $PromptLengths.Count -eq 0) {
        $PromptLengths = if ($Optimize -eq 'coding-agent') { @('long') } else { @('short') }
        $PSBoundParameters['PromptLengths'] = $PromptLengths
    }
    Find-BestLlamaCppConfig @PSBoundParameters
}

function tunellm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ContextKey,
        [ValidateSet('native','turboquant')][string]$Mode = 'native',
        [string]$Quant,
        [string[]]$AllowedKvTypes,
        [int]$Budget = 100,
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
    if (-not $PromptLengths -or $PromptLengths.Count -eq 0) {
        $PromptLengths = if ($Optimize -eq 'coding-agent') { @('long') } else { @('short') }
        $PSBoundParameters['PromptLengths'] = $PromptLengths
    }
    Find-BestLlamaCppConfig @PSBoundParameters
}

