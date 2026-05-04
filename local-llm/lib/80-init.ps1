# Init / teardown lifecycle. `init` builds all recommended aliases; `purge`
# removes every alias and GGUF file. Includes the small Ollama process verbs.

function Initialize-LocalLLM {
    [CmdletBinding()]
    param(
        [string[]]$Keys,
        [switch]$Force,
        [switch]$All,
        [switch]$Stale
    )

    Write-Host ""
    Write-Host "=== Local LLM Setup ===" -ForegroundColor Green
    Write-Host ""

    if (-not (Test-OllamaVersionMinimum -MinVersion $script:Cfg.MinOllamaVersion)) {
        $raw = & ollama --version 2>$null
        Write-Host "ERROR: Ollama >= $($script:Cfg.MinOllamaVersion) required (got: $raw)" -ForegroundColor Red
        Write-Host "Update: winget upgrade Ollama.Ollama" -ForegroundColor Yellow
        return
    }

    if ($Stale) {
        $staleEntries = @(Get-StaleModelAliases)

        if ($staleEntries.Count -eq 0) {
            Write-Host "No stale aliases." -ForegroundColor Green
            return
        }

        Write-Host "Rebuilding $($staleEntries.Count) stale alias(es)..." -ForegroundColor Cyan

        foreach ($entry in $staleEntries) {
            Write-Host "  rebuilding: $($entry.AliasName)" -ForegroundColor DarkGray

            if ($entry.Kind -eq 'strict') {
                Ensure-ModelStrictAlias -Key $entry.Key -ForceRebuild | Out-Null
            } else {
                Ensure-ModelAlias -Key $entry.Key -ContextKey $entry.Context -ForceRebuild | Out-Null
            }
        }

        Write-Host ""
        Write-Host "Done." -ForegroundColor Green
        return
    }

    if (-not $Keys -or $Keys.Count -eq 0) {
        $Keys = Get-FilteredModelKeys -IncludeAll:$All
    }

    if ($Keys.Count -eq 0) {
        Write-Host "No models to set up." -ForegroundColor Yellow
        return
    }

    $step = 1
    $total = $Keys.Count

    foreach ($key in $Keys) {
        $def = Get-ModelDef -Key $key
        Write-Host ("Step {0}/{1}: Setting up {2}..." -f $step, $total, $def.DisplayName) -ForegroundColor Cyan
        Ensure-ModelAllAliases -Key $key -ForceRebuild:$Force
        $step++
    }

    Write-Host ""
    Write-Host "Setup complete. Run 'info' to verify." -ForegroundColor Green
    Write-Host ""
}

function Initialize-LocalLLMModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Keys,
        [switch]$Force
    )

    Initialize-LocalLLM -Keys $Keys -Force:$Force
}

function Remove-AllLocalLLM {
    param([switch]$DeleteFiles)

    Write-Host ""

    if ($DeleteFiles) {
        Write-Host "=== Full Purge (models + GGUF files) ===" -ForegroundColor Red
    }
    else {
        Write-Host "=== Cleanup (models only) ===" -ForegroundColor Yellow
    }

    Write-Host ""

    Stop-OllamaModels
    Stop-OllamaApp
    Reset-OllamaEnv

    foreach ($key in (Get-ModelKeys)) {
        Remove-ModelAliases -Key $key
        Remove-ModelRemotePull -Key $key

        if ($DeleteFiles) {
            Remove-ModelFiles -Key $key
        }
    }

    Start-OllamaApp
    Wait-Ollama

    Write-Host ""
    Write-Host "Done." -ForegroundColor Green
    Write-Host ""
}

function Teardown-Ollama {
    param([switch]$DeleteFiles)

    Stop-OllamaModels
    Stop-OllamaApp
    Reset-OllamaEnv

    if ($DeleteFiles) {
        foreach ($key in (Get-ModelKeys)) {
            Remove-ModelAliases -Key $key
            Remove-ModelRemotePull -Key $key
            Remove-ModelFiles -Key $key
        }
    }

    Start-OllamaApp
    Wait-Ollama
}

function init {
    [CmdletBinding()]
    param([switch]$Force, [switch]$All, [switch]$Stale)
    Initialize-LocalLLM -Force:$Force -All:$All -Stale:$Stale
}

function initmodel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Keys,
        [switch]$Force
    )
    Initialize-LocalLLMModel -Keys $Keys -Force:$Force
}

function purge { Remove-AllLocalLLM -DeleteFiles }
function ostop { Teardown-Ollama }
function qkill { Stop-OllamaModels }
function ops { & ollama ps }
