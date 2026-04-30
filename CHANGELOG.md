# Changelog

Past-tense record of shipped changes.

## 2026-04-30 — Per-machine settings + auto-install Unshackled

### Added

- **`~/.local-llm/settings.json`** — per-machine overlay for the catalog. Top-level scalars (`UnshackledRoot`, `OllamaAppPath`, `Default`, `KeepAlive`, `RequireAdvertisedTools`, `NoThinkProxyPort`, `LocalModelTools`, `UnshackledRepoUrl`, etc.) load from `llm-models.json` first, then any matching keys in `settings.json` override. `Models` and `CommandAliases` are catalog-only and protected from override.
- **`Set-LocalLLMSetting <Key> <Value>`** — writes to `settings.json` and reloads. Pass `$null`/`""` to remove a key. Refuses `Models`/`CommandAliases`.
- **`UnshackledRepoUrl`** config field, defaulting to `https://github.com/David-c0degeek/unshackled`.
- **`Ensure-UnshackledInstalled`** — called by `Invoke-UnshackledCli` before doing anything. If the configured `UnshackledRoot` doesn't contain `src/entrypoints/cli.tsx`, it prompts `Clone <url>? [y/N]` and runs `git clone` on confirmation. Aborts with a clear instruction otherwise.
- `settings.json` added to `.gitignore` so per-machine config never lands in the repo.
- `install.ps1` prints a tip pointing at `Set-LocalLLMSetting` for fresh-machine setup.

### Why

Cloning the public repo onto a different machine should not require editing `llm-models.json` to fix `UnshackledRoot` (and risking merge conflicts with future pulls). And `-Fc` should do the obvious thing on a fresh machine instead of failing because no Unshackled is around.

## 2026-04-30 — Unshackled rename

The `free-code` fork was renamed to [Unshackled](https://github.com/David-c0degeek/unshackled). Propagated through this project:

- JSON config field `FreeCodeRoot` → `UnshackledRoot`. Old configs are migrated on read (the field is renamed in memory; saved configs use the new name).
- Internal function `Invoke-FreeCodeCli` → `Invoke-UnshackledCli`.
- Switch parameter `-FreeCode` → `-Unshackled` on `Start-ClaudeWithOllamaModel`, `Invoke-ModelShortcut`, and the per-model shortcut functions. `-FreeCode` and `-Fc` remain as aliases — muscle memory like `q27 -Fc` is unchanged.
- User-visible labels updated: launcher banner, wizard action label, install diagnostics, README, quick reference (`llmdocs`).
- Local folder path (`D:\repos\free-code`) was not renamed and still works as the configured `UnshackledRoot`.

## 2026-04-29 — second-pass refactor

Reviewed the project, then ran a single-day refactor pass guided by an explicit plan (`plan.md`, retired into this changelog).

### Bugs fixed

- **Persona pollution.** `LocalLLMProfile.ps1` had a hardcoded "You are Qwen, created by Alibaba Cloud" prepended to every model launch — wrong for Devstral and even somewhat wrong for the Qwen variants whose GGUF templates already self-identify. Removed the persona layer entirely; the system prompt now contains only universal tool-use rules, plus an opt-in deferred-tool-schema block (gated on `LimitTools`).
- **`enforcer-claude.ps1` rewritten.** The wrapper used to hardcode `qcoder30` and bypass the no-think proxy by pointing at `localhost:11434`. Now it reads `Default` from `llm-models.json` (or `$env:ENFORCER_MODEL`), routes through the proxy on `11435`, self-starts the proxy if needed, and sets the same thinking/caching/attribution env stack as the main launcher.
- **`claudefc` stub deleted.** It was a one-liner that called `Invoke-FreeCodeCli` with no args and ignored everything. The `<alias>fc` shortcuts already covered free-code launches; the new flag-based `-Fc` covers it now.
- **Tool-support detection rewritten.** `Test-OllamaModelSupportsTools` used to grep `ollama show` text for the literal word "tools" — which could match unrelated lines. Now POSTs to `/api/show` and checks the structured `capabilities` array. Falls back to the regex if the API is unreachable.
- **Devstral parser confirmed correct.** `Parser: "none"` was the right call (its GGUF self-templates with persona, `[SYSTEM_PROMPT]`/`[TOOL_CALLS]` tags, and `capabilities=[completion,vision,tools]`). Documented inline via a `ParserNote` field.
- **`init -Stale` parameter shadow bug.** `Initialize-LocalLLM` declared `[switch]$Stale`; the body did `$stale = @(Get-StaleModelAliases)`. PowerShell variables are case-insensitive, so the assignment tried to coerce an array into a `SwitchParameter` and failed silently, leaving `$stale` as the boolean `$true`. Renamed the local to `$staleEntries`.

### Added capabilities

- **Per-model `Tools` allowlist.** `Start-ClaudeWithOllamaModel` now takes `-Tools`; `Invoke-ModelShortcut` reads the optional `Tools` field from the model def, falling back to the global `LocalModelTools`. No models populated yet — capability only.
- **Auto-generated alias prefixes.** Added `ShortName` field per model. `Register-ModelShortcuts` walked `ShortName × Contexts × actions` and registered PowerShell aliases. Pruned the 30 hand-maintained `CommandAliases` entries to `{}`.
- **Parser-version stamping.** `New-OllamaModelFromSource` now writes a sha256-hash sidecar at `<profile-root>\parser-versions\<aliasname>.txt`. `Test-ModelAliasFresh`, `Get-StaleModelAliases`, `init -Stale`, and the `info` dashboard surface stale aliases (parser config drifted since build).
- **Default model.** Added `"Default"` field at the top of `llm-models.json`. `Get-DefaultModelKey` reads it (with a recommended-tier fallback). New shortcuts: `llmdefault`, `llmdefaultfc`, `llmdefaultchat`. Used by the enforcer.
- **`ThinkingPolicy` per model.** Either `strip` (default) or `keep`. `keep` mode bypasses the no-think proxy, points `ANTHROPIC_BASE_URL` at Ollama directly, and skips the thinking-disable env vars. Set on `q36opus47abl`. Launcher banner shows the active mode.
- **Configurable `OLLAMA_KEEP_ALIVE`.** Top-level `KeepAlive` field; `Set-OllamaRuntimeEnv` reads it (defaults to `"-1"`).
- **`Wait-Ollama` resilience.** Deadline bumped 20s → 60s. After 5s of waiting, prints `Waiting for Ollama` and adds a `.` every 2s.
- **Bench history persistence.** `Test-OllamaSpeed` now appends to `<profile-root>\bench-history.jsonl` per run. `Show-LLMBenchHistory [-Model] [-Last N]` and the short `obench` alias display recent runs.
- **Header truth.** File header lost the "+ LM Studio" advertisement (LM Studio support was never implemented). Now states "Windows / PowerShell only — does not work in WSL/bash."

### Architectural changes

- **Flag-based shortcut scheme (Option C).** Replaced ~135 multi-suffix functions (e.g. `q27hfast`, `qopfastfc`, `setq36piq6kp`) with 9 model functions: `dev`, `qcoder`, `q36`, `q36hau`, `q36p`, `q36h`, `q27`, `q27hau`, `qop`. Each takes `-Ctx`, `-Fc`, `-Chat`, `-Q8`, and (where applicable) `-Quant`. Introduced `Get-ModelShortcutName` and `Unregister-AllModelShortcuts`; `Register-ModelShortcuts` is now idempotent and cleans up old-style functions on reload.

### Deferred

- **Diagnostic logging on tool-call failure.** Naive stderr-tee breaks Claude Code's interactive terminal; needs better design (probably a debug-mode flag rather than a wrapper).

## Pre-2026-04-29

Project predates this changelog. The state at the start of this round:

- Single 2,506-line `LocalLLMProfile.ps1` engine with JSON catalog (`llm-models.json`).
- Per-(model, context) Ollama aliases.
- Hand-maintained `CommandAliases` map.
- HTTP proxy on `11435` stripping Anthropic thinking/reasoning fields.
- Hardcoded "You are Qwen" persona prepended to every launch.
- `enforcer-claude.ps1` hardcoded to `qcoder30` and pointing at the wrong port.
