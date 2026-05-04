# Throughput benchmarks via /api/chat. History is appended to a JSONL file in
# the profile root so 'obench' can summarize past runs.

function Test-OllamaSpeed {
    [CmdletBinding()]
    param(
        [string]$Model,
        [string]$Prompt = "Write a compact but detailed explanation of why CPU offload slows local LLM inference. About 500 words.",
        [ValidateRange(1, 8192)][int]$NumPredict = 512,
        [ValidateRange(1, 20)][int]$Runs = 1,
        [switch]$ShowResponse
    )

    if ([string]::IsNullOrWhiteSpace($Model)) {
        $loaded = @(Get-OllamaLoadedModels)

        if (-not $loaded -or $loaded.Count -eq 0) {
            throw "No model specified and no Ollama model is currently loaded. Usage: Test-OllamaSpeed q36plus"
        }

        $Model = $loaded[0].Name
    }

    $results = @()

    for ($i = 1; $i -le $Runs; $i++) {
        Write-Host "Benchmarking $Model, run $i/$Runs..." -ForegroundColor Cyan

        $body = @{
            model    = $Model
            messages = @(@{ role = "user"; content = $Prompt })
            stream   = $false
            options  = @{ num_predict = $NumPredict }
        } | ConvertTo-Json -Depth 8

        try {
            $result = Invoke-RestMethod `
                -Uri "http://localhost:11434/api/chat" `
                -Method Post `
                -ContentType "application/json" `
                -Body $body

            $promptTps = if ($result.prompt_eval_duration -gt 0) {
                [math]::Round(($result.prompt_eval_count / $result.prompt_eval_duration) * 1e9, 2)
            }
            else { 0 }

            $outputTps = if ($result.eval_duration -gt 0) {
                [math]::Round(($result.eval_count / $result.eval_duration) * 1e9, 2)
            }
            else { 0 }

            $item = [pscustomobject]@{
                Run                   = $i
                Model                 = $Model
                PromptTokens          = $result.prompt_eval_count
                PromptTokensPerSecond = $promptTps
                OutputTokens          = $result.eval_count
                OutputTokensPerSecond = $outputTps
                TotalSeconds          = [math]::Round($result.total_duration / 1e9, 2)
                LoadSeconds           = [math]::Round($result.load_duration / 1e9, 2)
            }

            $results += $item

            $historyEntry = [ordered]@{
                timestamp             = (Get-Date).ToString("o")
                model                 = $Model
                run                   = $i
                num_predict           = $NumPredict
                prompt_tokens         = [int]$result.prompt_eval_count
                prompt_tokens_per_sec = $promptTps
                output_tokens         = [int]$result.eval_count
                output_tokens_per_sec = $outputTps
                total_seconds         = [math]::Round($result.total_duration / 1e9, 2)
                load_seconds          = [math]::Round($result.load_duration / 1e9, 2)
            }

            $line = ($historyEntry | ConvertTo-Json -Compress -Depth 4)
            Add-Content -Path (Get-LLMBenchHistoryFile) -Value $line -Encoding UTF8

            if ($ShowResponse) {
                Write-Host ""
                Write-Host "Response:" -ForegroundColor Yellow
                Write-Host $result.message.content
                Write-Host ""
            }
        }
        catch {
            $details = $_.Exception.Message

            if ($_.Exception.Response) {
                try {
                    $stream = $_.Exception.Response.GetResponseStream()
                    $reader = [System.IO.StreamReader]::new($stream)
                    $responseBody = $reader.ReadToEnd()

                    if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
                        $details = "$details`n$responseBody"
                    }
                }
                catch {
                }
            }

            throw "Ollama benchmark failed for '$Model': $details"
        }
    }

    $results | Format-Table -AutoSize

    if ($results.Count -gt 1) {
        Write-Host ""
        Write-Host "Average:" -ForegroundColor Yellow

        [pscustomobject]@{
            Model                    = $Model
            Runs                     = $results.Count
            AvgPromptTokensPerSecond = [math]::Round(($results | Measure-Object PromptTokensPerSecond -Average).Average, 2)
            AvgOutputTokensPerSecond = [math]::Round(($results | Measure-Object OutputTokensPerSecond -Average).Average, 2)
            AvgTotalSeconds          = [math]::Round(($results | Measure-Object TotalSeconds -Average).Average, 2)
            AvgLoadSeconds           = [math]::Round(($results | Measure-Object LoadSeconds -Average).Average, 2)
        } | Format-Table -AutoSize
    }
}

function ospeed {
    param(
        [string]$Model,
        [int]$Runs = 1,
        [int]$NumPredict = 512
    )

    Test-OllamaSpeed -Model $Model -Runs $Runs -NumPredict $NumPredict
}

function Get-LLMBenchHistoryFile {
    return Join-Path $script:LLMProfileRoot "bench-history.jsonl"
}

function Read-LLMBenchHistoryEntries {
    $historyFile = Get-LLMBenchHistoryFile

    if (-not (Test-Path $historyFile)) {
        return @()
    }

    $lines = Get-Content -Path $historyFile -Encoding UTF8

    $entries = foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { ConvertFrom-Json $line } catch { continue }
    }

    return @($entries)
}

function Show-LLMBenchHistory {
    [CmdletBinding()]
    param(
        [string]$Model,
        [int]$Last = 20
    )

    $entries = @(Read-LLMBenchHistoryEntries)

    if ($entries.Count -eq 0) {
        Write-Host "No benchmark history yet. Run 'ospeed <model>' to record." -ForegroundColor DarkGray
        return
    }

    if ($Model) {
        $entries = @($entries | Where-Object { $_.model -eq $Model })
    }

    $entries = @($entries | Select-Object -Last $Last)

    if ($entries.Count -eq 0) {
        Write-Host "No matching entries." -ForegroundColor DarkGray
        return
    }

    $entries | Select-Object timestamp, model, output_tokens_per_sec, prompt_tokens_per_sec, total_seconds | Format-Table -AutoSize
}

function Trim-LLMBenchHistory {
    [CmdletBinding()]
    param(
        [int]$OlderThanDays = 90,
        [switch]$DryRun
    )

    $historyFile = Get-LLMBenchHistoryFile

    if (-not (Test-Path $historyFile)) {
        Write-Host "No benchmark history file." -ForegroundColor DarkGray
        return
    }

    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $entries = @(Read-LLMBenchHistoryEntries)
    $kept = @()
    $dropped = 0

    foreach ($entry in $entries) {
        $ts = $null
        if ([DateTime]::TryParse($entry.timestamp, [ref]$ts) -and $ts -lt $cutoff) {
            $dropped++
            continue
        }
        $kept += $entry
    }

    if ($dropped -eq 0) {
        Write-Host "Nothing to trim. $($entries.Count) entries, none older than $OlderThanDays days." -ForegroundColor Green
        return
    }

    if ($DryRun) {
        Write-Host "[dry-run] Would drop $dropped entries older than $OlderThanDays days, keep $($kept.Count)." -ForegroundColor Cyan
        return
    }

    $tmp = "$historyFile.tmp"
    if (Test-Path $tmp) { Remove-Item $tmp -Force }

    foreach ($entry in $kept) {
        Add-Content -Path $tmp -Value ($entry | ConvertTo-Json -Compress -Depth 4) -Encoding UTF8
    }

    Move-Item -Path $tmp -Destination $historyFile -Force
    Write-Host "Dropped $dropped entries, kept $($kept.Count)." -ForegroundColor Green
}

function obench { Show-LLMBenchHistory @args }
