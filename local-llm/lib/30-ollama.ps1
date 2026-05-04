# Ollama process control + state probes. Talks to the local Ollama daemon and
# the `ollama` CLI; doesn't know about model defs.

function Get-OllamaLoadedModels {
    $lines = & ollama ps 2>$null | Select-Object -Skip 1
    $items = @()

    foreach ($line in $lines) {
        if (-not $line.Trim()) { continue }

        $parts = $line -split '\s{2,}'

        if ($parts.Count -ge 6) {
            $items += [pscustomobject]@{
                Name      = $parts[0]
                Id        = $parts[1]
                Size      = $parts[2]
                Processor = $parts[3]
                Context   = $parts[4]
                Until     = $parts[5]
            }
        }
    }

    return $items
}

function Stop-OllamaModels {
    $loaded = Get-OllamaLoadedModels

    foreach ($item in $loaded) {
        if ($item.Name) {
            & ollama stop $item.Name | Out-Null
        }
    }
}

function Stop-OllamaApp {
    Get-Process -Name "ollama app", "ollama" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
}

function Start-OllamaApp {
    if (Test-Path $script:Cfg.OllamaAppPath) {
        Start-Process -FilePath $script:Cfg.OllamaAppPath | Out-Null
    }
    else {
        Start-Process -FilePath "ollama app.exe" | Out-Null
    }
}

function Wait-Ollama {
    $start = Get-Date
    $deadline = $start.AddSeconds(60)
    $progressShownAt = $null

    do {
        try {
            Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -UseBasicParsing -TimeoutSec 2 | Out-Null

            if ($progressShownAt) {
                Write-Host ""
            }

            return
        }
        catch {
            $elapsed = (Get-Date) - $start

            if ($elapsed.TotalSeconds -ge 5) {
                if (-not $progressShownAt) {
                    Write-Host -NoNewline "Waiting for Ollama" -ForegroundColor DarkGray
                    $progressShownAt = Get-Date
                }
                elseif (((Get-Date) - $progressShownAt).TotalSeconds -ge 2) {
                    Write-Host -NoNewline "." -ForegroundColor DarkGray
                    $progressShownAt = Get-Date
                }
            }

            Start-Sleep -Milliseconds 500
        }
    } while ((Get-Date) -lt $deadline)

    if ($progressShownAt) {
        Write-Host ""
    }

    throw "Ollama did not come up in time (60s)."
}

function Reset-OllamaEnv {
    Remove-Item Env:OLLAMA_CONTEXT_LENGTH -ErrorAction SilentlyContinue
    Remove-Item Env:OLLAMA_FLASH_ATTENTION -ErrorAction SilentlyContinue
    Remove-Item Env:OLLAMA_KEEP_ALIVE -ErrorAction SilentlyContinue
    Remove-Item Env:OLLAMA_KV_CACHE_TYPE -ErrorAction SilentlyContinue
}

function Set-OllamaRuntimeEnv {
    param([switch]$UseQ8)

    $env:OLLAMA_FLASH_ATTENTION = "1"

    $keepAlive = if ($script:Cfg.Contains("KeepAlive") -and -not [string]::IsNullOrWhiteSpace($script:Cfg.KeepAlive)) {
        [string]$script:Cfg.KeepAlive
    } else {
        "-1"
    }

    $env:OLLAMA_KEEP_ALIVE = $keepAlive

    if ($UseQ8) {
        $env:OLLAMA_KV_CACHE_TYPE = "q8_0"
    }
}

function Test-OllamaModelExists {
    param([Parameter(Mandatory = $true)][string]$ModelName)

    & ollama show $ModelName *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-OllamaInstalledModelNames {
    # Single-shot fetch of the installed Ollama model list.
    # Returns short names ("foo:latest" -> "foo") and the raw "name:tag" pair.
    $lines = & ollama list 2>$null | Select-Object -Skip 1
    $names = New-Object System.Collections.Generic.List[string]

    foreach ($line in $lines) {
        if (-not $line.Trim()) { continue }
        $first = ($line -split '\s+', 2)[0]

        if (-not $first) { continue }

        $names.Add($first) | Out-Null

        if ($first -like '*:latest') {
            $names.Add($first.Substring(0, $first.Length - 7)) | Out-Null
        }
    }

    return @($names)
}

function Test-OllamaModelSupportsTools {
    param([Parameter(Mandatory = $true)][string]$ModelName)

    # Prefer the structured /api/show endpoint — it exposes a `capabilities`
    # array we can check exactly. Fall back to a regex on `ollama show` output
    # only if the endpoint isn't reachable (older Ollama, server stopped).
    try {
        $body = @{ name = $ModelName } | ConvertTo-Json -Compress
        $response = Invoke-RestMethod `
            -Uri "http://localhost:11434/api/show" `
            -Method Post `
            -ContentType "application/json" `
            -Body $body `
            -TimeoutSec 5

        if ($response.capabilities) {
            return ($response.capabilities -contains "tools")
        }
    }
    catch {
        # API unreachable; fall through to the text-based fallback.
    }

    $output = & ollama show $ModelName 2>$null

    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    return ($output -match '(?im)\btools\b')
}

function Test-OllamaVersionMinimum {
    param([Parameter(Mandatory = $true)][string]$MinVersion)

    $raw = & ollama --version 2>$null

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not determine Ollama version. Is Ollama installed?"
        return $false
    }

    if ($raw -match '(\d+\.\d+\.\d+)') {
        $current = [version]$Matches[1]
        $minimum = [version]$MinVersion
        return ($current -ge $minimum)
    }

    Write-Warning "Could not parse Ollama version from: $raw"
    return $false
}
