# Changelog

Past-tense record of shipped changes.

## 2026-05-02 — 256k Qwen3-Coder profile, VRAM-aware tradeoffs, per-quant/context notes

### Added

- **`qcoder30` 256k context.** Added `"256": 262144` to the Qwen3-Coder-30B-A3B Heretic model and a new `iq4xs` quant (`Qwen3-Coder-30B-A3B-Instruct-Heretic.i1-IQ4_XS.gguf`, ~16.5 GB). The 256k profile only fits a 4090 with IQ4_XS weights + q4_0 KV cache (~6 GB at 256k); use `qcoder -Ctx 256 -Quant iq4xs`.
- **`qcodernext` (experimental).** New entry pointing at `mradermacher/Huihui-Qwen3-Coder-Next-abliterated-i1-GGUF` — the 80B/3B-active hybrid DeltaNet+Attention coder. Quants: `iq1m`, `iq2s`, `iq3xxs`. Only `iq1m` (~18.1 GB) fits a single 4090 with any KV headroom; flagged as experimental and "tight on 4090" in the display name.
- **Per-model `Description`, `QuantNotes`, `ContextNotes` catalog fields.** Free-form strings keyed by quant/context name. Backfilled across the existing catalog so users can see file sizes, KV pressure, and "when to pick this" guidance without leaving the launcher.
- **`info` / `llmdocs` / `llm` wizard surfaces.** `Show-ModelCatalog`, `Show-LLMDynamicModelSummary`, `Select-LLMModelKey`, `Select-LLMQuantKey`, and `Format-LLMContextLabel` all render the new notes inline. The current default quant is marked with `*` in the per-quant list.
- **`addllm -Description`, `-QuantNotes`, `-ContextNotes`.** Optional params on `Add-LocalLLMModel` / `addllm` that round-trip into the catalog entry. Notes are hashtables (`@{key='note'}`) keyed by the same quant/context shortname.
- **`-Q8` + long-context guard.** `Invoke-ModelShortcut` refuses `-UseQ8` whenever the resolved `num_ctx` exceeds the `Q8KvMaxContext` ceiling. The error message tells the user to drop `-Q8`, lower `-Ctx`, or raise the threshold.
- **VRAM-aware recommendations.** New top-level `VRAMGB` setting plus `Get-LocalLLMVRAMInfo` helper. Auto-detects via `nvidia-smi --query-gpu=memory.total` (largest GPU on a multi-card box). Override via `Set-LocalLLMSetting VRAMGB 32`. The dashboard surfaces the resolved value + source (configured / auto / fallback).
- **`QuantSizesGB` per-quant numeric field.** Drives a `[fits]` / `[tight]` / `[over]` badge next to each quant in `info` and the wizard, computed against the host's VRAM (weight-budget heuristic: `[fits]` when the model leaves >=7 GB headroom for KV, `[tight]` when only ~2 GB headroom, `[over]` otherwise). Backfilled across `qcoder30`, `qcodernext`, `q36plus`, `q36heretic`, `q27heretic`, `q27hauhau`.
- **`Q8KvMaxContext` now scales with VRAM by default.** Removed the explicit `131072` literal from the catalog. The guard derives `(VRAMGB - 16) * 16384` (floored at 64k) when not pinned, so a 5090 (32 GB) gets ~256k while a 4090 (24 GB) gets ~128k. Override still works via `Set-LocalLLMSetting Q8KvMaxContext`.
- **Quant notes rewritten to be VRAM-agnostic** where possible. The hand-written notes describe quality/use-case (no longer "partial offload on a 4090"); the per-quant `[fits]/[tight]/[over]` badge is the live verdict for the host's actual VRAM.

### Why

Picking a quant and context blindly was costing real time — Q4_K_M is fine at 64k but cannot fit 256k KV; Q6_K is too heavy at any long context; `-Q8` looks free until it OOMs at 128k+. The notes encode the tradeoff directly next to the selector, and the guard prevents the worst foot-gun (`-Q8 -Ctx 256`) from ever launching.

VRAM auto-detection was the next cliff: every recommendation in the catalog implicitly assumed a 24 GB 4090. A 5090 user (32 GB) should see Q5_K_M as `[fits]`, not "partial offload"; a 4080 user (16 GB) should see most 35B variants flagged `[over]` and not waste time downloading them. The fit badge gives a per-host verdict without the user having to do KV-cache arithmetic.

The catalog gained one realistic 256k coder option (`qcoder30 -Ctx 256 -Quant iq4xs`) and one aspirational one (`qcodernext`) so the "uncensored 256k on a 4090" question has a documented answer instead of trial-and-error.

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
