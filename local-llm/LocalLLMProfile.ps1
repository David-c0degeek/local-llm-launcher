# =========================
# Local LLM profile entry point
# Ollama + Claude Code + Unshackled
# Windows / PowerShell only — does not work in WSL/bash.
# =========================
#
# Usage:
#   1. Keep this file beside llm-models.json and the lib/ directory.
#   2. Dot-source from your PowerShell profile:
#        . "$HOME\.local-llm\LocalLLMProfile.ps1"
#   3. Reload:
#        . $PROFILE
#
# Code lives in lib/*.ps1, dot-sourced in numeric order. Add new functionality
# by editing the matching lib file (or adding a new numbered one) — keep this
# entry point minimal.
#
# Do not enable top-level StrictMode in a profile.

$script:LLMProfileRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PROFILE }
$script:LocalLLMConfigPath = if ($env:LOCAL_LLM_CONFIG) { $env:LOCAL_LLM_CONFIG } else { Join-Path $script:LLMProfileRoot "llm-models.json" }

# Dot-source every lib file in numeric prefix order. Dot-sourcing pulls
# functions and $script: variables into THIS file's scope, which is what the
# rest of the codebase expects ($script:Cfg, etc.).
$libDir = Join-Path $script:LLMProfileRoot "lib"

if (-not (Test-Path $libDir)) {
    throw "LocalLLMProfile: lib/ directory not found at $libDir. Reinstall via install.ps1."
}

foreach ($file in (Get-ChildItem -Path $libDir -Filter '*.ps1' | Sort-Object Name)) {
    . $file.FullName
}

# Bootstrap: load config + dependent runtime state, then register per-model
# shortcut functions. Order matters here (these statements EXECUTE at load
# time and depend on functions from the lib files above).
$script:Cfg = Import-LocalLLMConfig
$script:NoThinkProxyPort = [int]$script:Cfg.NoThinkProxyPort

# Enforcer — Claude Code, when invoked from within an Unshackled-style flow,
# runs through the local backend wrapper.
$env:ENFORCER_CLAUDE_CMD = "pwsh -NoProfile -File $HOME\.ollama-proxy\enforcer-claude.ps1"

Register-ModelShortcuts
