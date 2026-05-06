```
 _                 _      _ _                _                            _
| | ___   ___ __ _| |    | | |_ __ ___      | | __ _ _   _ _ __   ___ ___| |__   ___ _ __
| |/ _ \ / __/ _` | |____| | | '_ ` _ \  ___| |/ _` | | | | '_ \ / __/ __| '_ \ / _ \ '__|
| | (_) | (_| (_| | |____| | | | | | | ||___| | (_| | |_| | | | | (__\__ \ | | |  __/ |
|_|\___/ \___\__,_|_|    |_|_|_| |_| |_|    |_|\__,_|\__,_|_| |_|\___|___/_| |_|\___|_|

                  Put a local LLM behind the Claude Code harness.
```

# local-llm-launcher

A PowerShell-driven launcher that runs [Claude Code](https://claude.com/claude-code)
(or the [Unshackled](https://github.com/David-c0degeek/unshackled) fork) against a
**local model** — Ollama or llama.cpp — with the right Modelfile / chat template,
KV-cache type, sampling, system prompt, and tool allowlist for each model family.

> **Windows / PowerShell only.** Does not work in WSL/bash. The launcher reaches
> into Ollama and llama-server lifecycle, drives `Start-Process`, manages
> `$PROFILE`, and reads `nvidia-smi`. None of that travels cleanly across shells.

---

## What this is

The vendored Anthropic models (Opus, Sonnet, Haiku) are good. They're also paid,
rate-limited, hosted, and out of your control. A *local* model running through
the *same agent harness* gets you the Claude Code editing loop, tool-calling
discipline, and CLI ergonomics — but pointed at weights you actually own.

That sounds simple. In practice it isn't:

- **Each model family wants a different chat template, sampler, and stop set.**
  Qwen3-Coder needs the `qwen3-coder` parser; Qwen 3.6 wants `qwen36`; Devstral
  self-templates and you must pass `Parser: none` or it fights the GGUF.
- **Anthropic's wire format carries `thinking` / `reasoning` blocks** that
  Ollama's `/v1/messages` endpoint can't ingest. The launcher routes traffic
  through a small Python proxy (`no-think-proxy.py`) that strips them on the
  way in. Thinking-trained models (`ThinkingPolicy: keep`) bypass the proxy.
- **VRAM math is non-trivial.** Q8 KV at 256 k tokens OOMs a 4090. Q4_K_M
  weights leave room for KV but lose precision on coding. The launcher tags
  every quant with `[fits] / [tight] / [over]` against your actual card and
  *refuses* combinations that will OOM, telling you what to drop.
- **One alias per (model, context, quant) — built lazily.** Ollama bakes
  `num_ctx` into the Modelfile at create time, so `qcoder30` at 32 k and at
  256 k are physically different aliases. The launcher generates and tracks
  them; a sidecar version stamp catches drift when parsers or contexts change.
- **Two harnesses, one dispatch path.** Whether you launch Claude Code or
  Unshackled, the same env stack and proxy is set up — `-Fc` is just a
  switch on every model function.

The end result: one PowerShell function per model, flag-based, with the
fiddly bits (process bouncing, env restoration, cache types, KV ceilings,
tool allowlists, system prompts, parser stamps) hidden behind it.

```powershell
qcoder -Ctx fast -Fc          # Qwen3-Coder @ 32k → Unshackled
q36p -Ctx 128                 # Qwen 3.6 Plus @ 128k → Claude Code
qcoder -Ctx 256 -Quant iq4xs  # 256k coder context (4090 ceiling)
llmdefault                    # whatever the catalog / settings / .llm-default says
llm                           # interactive wizard (Spectre-rendered when available)
info                          # dashboard: VRAM fit, parser freshness, defaults
```

---

## Harness mode

A **harness** is the agent loop wrapping the model — the thing that turns raw
generation into "read this file, run that command, edit this code, then ask the
user". Claude Code is one such harness. Unshackled is a fork of it. `ollama run`
is *not* a harness; it's a chat REPL.

This launcher's whole job is to make a local model usable inside a real
harness. Three modes are supported:

### Claude Code harness (default)

```powershell
qcoder -Ctx fast              # qcoder is the per-model function name
```

What happens:

1. The launcher snapshots and clears any `ANTHROPIC_*` env vars in the current shell.
2. Starts the no-think proxy on `127.0.0.1:11435` (Python; ~300 ms cold).
3. Bounces Ollama with the right `OLLAMA_FLASH_ATTENTION` and `OLLAMA_KV_CACHE_TYPE`.
4. Builds (or reuses) the Ollama alias for `(model, context)` with the correct
   parser-derived Modelfile.
5. Sets `ANTHROPIC_BASE_URL=http://localhost:11435`, points
   `ANTHROPIC_DEFAULT_*_MODEL` at the alias, disables thinking + prompt caching,
   bumps `API_TIMEOUT_MS` to 30 min (local prefill is slow on big prompts).
6. Launches `claude --model <alias> --dangerously-skip-permissions
   [--tools <allowlist>] --append-system-prompt <local-tool-rules>`.
7. On exit, restores the original env and stops the proxy.

The model believes it's Claude. Claude Code believes it's talking to Anthropic.
The proxy quietly strips Anthropic-only fields the local backend can't parse.

### Unshackled harness (`-Fc`)

Same flow, except the launch shells into `bun src/entrypoints/cli.tsx` against
an [Unshackled](https://github.com/David-c0degeek/unshackled) checkout instead
of `claude`. If the configured `UnshackledRoot` doesn't exist, the first launch
offers to `git clone` from `UnshackledRepoUrl` (default
`https://github.com/David-c0degeek/unshackled`). Decline to abort.

```powershell
qcoder -Ctx fast -Fc          # alias: -FreeCode, canonical: -Unshackled
```

`-Fc` exists because Claude Code is occasionally restrictive in ways a local
model shouldn't be — refusing mundane edits, chasing safety theatre, or
declining tool calls a 30B uncensored Qwen would happily do. Unshackled is a
fork of Claude Code with those edges sanded off. The launcher treats it as
peer to Claude Code: same env stack, same proxy, same tool restrictions.

### Strict overlay (engineering harness)

Some models in the catalog have `Strict: true`. For those, `init` builds a
second alias — `<root>-strict` — that derives `FROM <root>:latest` and overlays
two things:

- **Tighter sampling**: `temperature 0.2`, `top_p 0.8`, `top_k 20`, `min_p 0.05`,
  `repeat_penalty 1.15`, `repeat_last_n 4096`.
- **A non-negotiable engineering system prompt** with rules the model is held
  to before every turn:
  > Do not create mocks, stubs, fake data, dummy implementations, placeholder
  > services, TODO implementations, temporary bypasses, hardcoded sample
  > responses, or `NotImplementedException`.
  > Do not invent new architecture, schema fields, configuration properties,
  > or abstractions unless they fit existing patterns.
  > Do not make tests pass by weakening, bypassing, deleting, or faking real
  > behavior.
  > Reuse existing architecture and production code paths. If the real
  > implementation is missing, blocked, or ambiguous: stop and explain what
  > is missing instead of inventing a substitute.

The strict alias is parser-agnostic — inheritance via `FROM` carries the
RENDERER/PARSER/template forward, and the overlay only overrides
SYSTEM + sampling. Any model family works without per-parser branching.

The same overlay is wired into the llama.cpp path: pass `-Strict` and
`Build-LlamaServerArgs` injects the strict sampler flags plus a
`--system-prompt-file` pointing at the rendered overlay (cached under
`~/.local-llm/llamacpp-templates/strict-system.txt`).

> **When to use it.** Strict overlay is for actual engineering work where the
> model's lazy paths (mock, stub, "// TODO", placeholder JSON) cost real time.
> Skip it for chat, brainstorming, RAG-style Q&A.

### Chat mode (no harness)

```powershell
q36p -Chat                    # plain `ollama run`, no Claude Code, no proxy
```

Useful for ad-hoc prompts, GGUF smoke tests, and bench comparisons. No tool
calls, no agent loop, no env-var dance. Llama.cpp doesn't have a built-in chat
REPL; for that backend, run `launch-claude` and point Claude Code or the
llama-server web UI at the running server.

---

## Backends

The launcher dispatches to one of two backends per launch.

### Ollama (default)

The original target. Ollama manages the model server, GGUF storage, alias
namespace, and KV cache. The launcher writes Modelfiles, runs `ollama create`,
sets `OLLAMA_FLASH_ATTENTION=1` plus an optional `OLLAMA_KV_CACHE_TYPE`, and
expects Ollama ≥ the catalog's `MinOllamaVersion`. Models with
`SourceType: remote` pull from `ollama.com`; `SourceType: gguf` materializes
a local GGUF (resolved via HuggingFace or reused from an existing Ollama copy)
and creates the alias with `FROM <gguf-path>`.

### llama.cpp

For models the catalog marks `SourceType: gguf` and not `LlamaCppCompatible:
false`, the wizard offers a **llama.cpp** path:

- **`native`** — upstream `llama-server.exe`. Mainline KV types only
  (`q8_0`, `f16`, `q5_1`, `q5_0`, `q4_1`, `q4_0`, `iq4_nl`, `bf16`, `f32`).
- **`turboquant`** — TheTom's [llama.cpp turboquant fork](https://github.com/TheTom/llama-cpp-turboquant), which
  ships `turbo3` and `turbo4` KV cache types (more aggressive than `q4_0` but
  with a quality cliff that's a function of context length). Only available
  through the fork binary.

Both modes start a native `llama-server` process, pin to a free port from
`LlamaCppPort` (default `8080`), wait for `/v1/models` to come up, then point
Claude Code at `http://localhost:<port>`. The Ollama daemon is shut down
during the launch unless `LlamaCppCoexistOllama` is set (single-GPU systems
don't have the VRAM headroom to run both).

```powershell
# Wizard route — pick backend interactively
llm

# Direct (catalog must list a gguf model with no LlamaCppCompatible: false)
Invoke-Backend -Action launch-claude -Backend llamacpp `
  -Key qcoder30 -ContextKey 256 `
  -LlamaCppMode turboquant -KvCacheK turbo4 -KvCacheV turbo4 -Strict

lps                           # show running llama-server (port, pid, gguf path)
lstop                         # stop it
```

llama.cpp is the path you want when:
- You need a KV cache type Ollama doesn't expose (`turbo4`, `iq4_nl`).
- You want explicit control over `--n-cpu-moe`, `--mlock`, `--no-mmap`.
- You're running a quant Ollama refuses to load.
- You want the strict overlay applied as a `--system-prompt-file` rather than
  baked into a Modelfile.

Otherwise Ollama is the simpler default — alias namespace, `ollama ps`,
`ollama show`, the bench history all assume Ollama.

---

## Architecture

The repo ships in two folders that map to two deployed locations:

```
repo                              deployed
local-llm/      ─── install ──→   %USERPROFILE%\.local-llm\
ollama-proxy/   ─── install ──→   %USERPROFILE%\.ollama-proxy\
```

```
local-llm/
  LocalLLMProfile.ps1   minimal entry point — dot-sourced by $PROFILE
  llm-models.json       model catalog (committed, sharable)
  lib/
    00-settings.ps1     config loader, settings.json overlay, env names
    10-helpers.ps1      pwsh utility primitives (Section/Pause/Convert paths)
    20-models.ps1       model-def access, alias naming, strict-sibling helpers
    25-vram.ps1         nvidia-smi auto-detect, fit-class arithmetic
    30-ollama.ps1       ollama lifecycle (start/stop/wait/env/version probe)
    32-llamacpp.ps1     llama-server lifecycle (port pick, health, session)
    33-llamacpp-install.ps1   resolve native + turboquant llama-server binaries
    35-backend.ps1      Invoke-Backend dispatcher (ollama vs llamacpp)
    40-parsers.ps1      per-family chat template / sampler / strict overlay
    41-llamacpp-args.ps1   pure argv builder for llama-server
    42-llamacpp-templates.ps1  parser → llama-server flag mapping, strict file
    45-profile-version.ps1  Modelfile content hash for staleness detection
    50-modelfile.ps1    Ollama alias creation + lifecycle (incl. strict siblings)
    55-huggingface.ps1  HF repo discovery, GGUF download, quant code recognition
    60-catalog.ps1      catalog editor (addllm/updatellm/removellm/setllm)
    65-claude-launch.ps1   Claude/Unshackled launcher; env save/restore, proxy
    70-bench.ps1        ospeed → bench-history.jsonl, Show-LLMBenchHistory
    75-display.ps1      info dashboard (Spectre + plain-text fallbacks)
    80-init.ps1         init/initmodel/purge/ostop/qkill/ops
    85-shortcuts.ps1    per-model function generator, default-key resolution
    90-wizard.ps1       Spectre + classic interactive wizards
    99-entrypoints.ps1  llm/llmmenu/llmc/reloadllm/lps/lstop

ollama-proxy/
  no-think-proxy.py     strips Anthropic thinking/reasoning blocks
  enforcer-claude.ps1   wrapper that re-enters the local backend on Claude → Claude calls
```

`LocalLLMProfile.ps1` dot-sources every `lib/*.ps1` in numeric prefix order,
loads `llm-models.json` overlaid with `~/.local-llm/settings.json`, and
registers per-model shortcut functions. Everything else hangs off that.

---

## Install

From the repo root:

```powershell
. .\install.ps1                  # copy files to deployed locations + add to $PROFILE
. .\install.ps1 -Symlink         # symlink instead of copy (admin / dev mode)
. .\install.ps1 -SetupProfile    # only ensure $PROFILE dot-sources the deployed file
. .\install.ps1 -DryRun          # preview without changing anything
```

After install, open a fresh PowerShell. Two things to do:

```powershell
init                             # build aliases for the recommended-tier models
info                             # verify: VRAM, default model, parser freshness
```

The `Show-Diagnostics` step at the end of install reports on `ollama`,
`python`, `bun` (only needed for Unshackled), and `PwshSpectreConsole` (only
needed for the rich dashboard / wizard). Anything missing is flagged with
install hints.

---

## Day-to-day usage

One function per model. Flag-based:

```
qcoder -Ctx fast -Fc          Code agent (Qwen3-Coder, 32k, Unshackled)
q36p -Ctx fast -Fc            General Qwen 3.6 agent (32k, Unshackled)
dev -Ctx fast                 Smaller / faster (Devstral 24B, 32k)
q36p -Ctx 128 -Fc             Big context (Qwen 3.6 Plus, 128k)
qcoder -Ctx 256 -Quant iq4xs  256k coder context (4090 ceiling — no -Q8)
q36p -Chat                    Raw ollama chat, no Claude Code
q36p -Q8                      Use q8 KV cache for higher quality
q36p -Quant q6kp              Switch the GGUF quant (rebuilds aliases)
llmdefault                    Launch the configured Default model
llmdefaultfc                  Same, via Unshackled
llmdefaultchat                Same, plain chat
llm                           Guided wizard
llmc                          Wizard, Spectre bypass (force classic)
info                          Dashboard
llmdocs                       Quick reference
```

| Flag | Effect |
|------|--------|
| `-Ctx <name>` | One of the model's context keys (`fast`, `deep`, `128`, `256`). Omit for default. |
| `-Fc` (alias `-FreeCode`, canonical `-Unshackled`) | Use Unshackled instead of Claude Code. |
| `-Chat` | Run plain `ollama run`, skip Claude Code entirely. |
| `-Q8` | Set `OLLAMA_KV_CACHE_TYPE=q8_0` for this launch. Refused above the VRAM-derived `Q8KvMaxContext` ceiling — q8 KV at long context will OOM. |
| `-Quant <name>` | Switch the model's selected GGUF quant. No launch — rebuilds the alias. |

### 256 k context on a 24 GB card

The combination of **Qwen3-Coder-30B-A3B Heretic** (4 KV heads, 48 layers) at
the **IQ4_XS** quant with **q4_0 KV cache** is the only setup that fits a full
256k context on a single 4090:

```powershell
qcoder -Ctx 256 -Quant iq4xs        # Claude Code @ 256k
qcoder -Ctx 256 -Quant iq4xs -Fc    # Unshackled @ 256k
```

Weights ~16.5 GB; q4_0 KV @ 256k ~6 GB; total ~23.6 GB. The launcher will
**refuse `-Q8` at this context** because q8 KV would push KV cache to ~12 GB
and OOM the card. Run `llmdocs` for the full quick reference, or `info` for
the dashboard.

---

## Adding a model

```powershell
addllm <hf-url-or-repo> -Key <key> [-Quants Q4_K_P,IQ4_XS] [-DefaultQuant Q4_K_P] [-Tier recommended]
initmodel <key>
```

`addllm` registers **every recognized GGUF quant** the HF repo publishes by
default (the `imatrix.gguf` calibration file is excluded). Pass `-Quants` only
when you want to filter the catalog entry to a subset.

Backfilling missing quants on an existing entry (rerunning HF discovery
without overwriting your manual `QuantNotes` / `ContextNotes`):

```powershell
updatellm <key>            # adds any HF quants missing from the entry
updatellm <key> -DryRun    # preview without writing
```

Removing a model:

```powershell
removellm <key>            # confirms first
removellm <key> -Force     # skip confirmation
removellm <key> -KeepFiles # keep the GGUF blobs on disk
```

---

## VRAM-aware tradeoffs

The launcher reads your GPU's VRAM and uses it to:

1. **Tag every quant** with `[fits]` / `[tight]` / `[over]` in `info` and the
   `llm` wizard, so you can see at a glance which builds will load fully on
   your card.
2. **Set the `Q8KvMaxContext` ceiling** — the largest `num_ctx` that pairs
   safely with `-Q8` (q8_0 KV cache). Roughly +16k tokens of headroom per GB
   above 16 GB; floors at 64 k. The guard refuses launches that would exceed
   this and tells you what to drop.

VRAM resolves in this order:

1. `VRAMGB` set in `settings.json` or `llm-models.json` (top-level).
2. `nvidia-smi --query-gpu=memory.total` auto-detect (largest GPU on a multi-GPU box).
3. Fallback to 24.

The `info` dashboard shows the resolved value and source
(`auto` / `configured` / `fallback`).

```powershell
Set-LocalLLMSetting VRAMGB 32          # 5090
Set-LocalLLMSetting VRAMGB 48          # RTX 6000 Ada / dual-card aggregate
Set-LocalLLMSetting VRAMGB $null       # remove override, fall back to auto-detect
Set-LocalLLMSetting Q8KvMaxContext 196608   # pin the q8 ceiling explicitly
```

Per-quant tradeoffs come from two optional catalog fields:

- `QuantSizesGB` — file size per quant in GB (drives the fit badge).
- `QuantNotes` — human-readable note per quant (quality/use-case context). Shown verbatim.

Per-context guidance comes from `ContextNotes` in the same shape. Backfill
these on any model you add — they show up inline in `info` and the wizard.

---

## Per-machine settings (`settings.json`)

`llm-models.json` is the model **catalog** — committed, sharable. Per-machine
paths and preferences belong in a sibling `settings.json` at
`~/.local-llm/settings.json` (gitignored). It overlays top-level scalars from
the catalog at load time, so you don't have to hand-edit `llm-models.json` to
fix paths on a fresh machine.

Use the helper instead of editing JSON:

```powershell
Set-LocalLLMSetting UnshackledRoot 'C:\repos\unshackled'
Set-LocalLLMSetting Default q36plus
Set-LocalLLMSetting KeepAlive '5m'
Set-LocalLLMSetting VRAMGB 32                        # override auto-detect
Set-LocalLLMSetting Q8KvMaxContext 196608            # pin the -Q8 ceiling
Set-LocalLLMSetting LlamaCppDefaultMode native       # or 'turboquant'
Set-LocalLLMSetting LlamaCppCoexistOllama $true      # rare: allow both backends concurrently
Set-LocalLLMSetting LlamaCppNCpuMoe 35               # MoE expert CPU offload (default 35; 0 to disable)
Set-LocalLLMSetting LlamaCppMlock $false             # disable RAM locking (default $true)
Set-LocalLLMSetting LlamaCppNoMmap $false            # disable no-mmap (default $true)
Set-LocalLLMSetting UnshackledRoot $null             # remove an entry
```

The `Models` and `CommandAliases` keys are catalog-only and rejected by
`Set-LocalLLMSetting`. Everything else is fair game.

### Per-workspace default model

Drop a `.llm-default` file in any directory containing a single line — a
model key, `ShortName`, or `Root`. `llmdefault` (and the enforcer wrapper)
walks up from `$PWD` and uses the nearest match. Falls back to settings →
catalog `Default`.

```
echo q36p > .llm-default          # this workspace prefers Qwen 3.6 Plus
```

---

## MCP servers

Claude Code's MCP servers expose tools with names like `mcp__<server>__<tool>`.
They reach the local model through the same launch path:

- Models with `"LimitTools": false` (e.g. `dev`) get every MCP tool
  automatically — the `--tools` flag isn't passed.
- Models with `"LimitTools": true` (default) only see tools in the allowlist.
  Add the MCP tool names you want to either the global `LocalModelTools` field
  in `llm-models.json` or a per-model `Tools` override.

Example per-model override:

```json
"q36plus": {
  ...,
  "Tools": "Bash,Read,Write,Edit,Glob,Grep,mcp__filesystem__read_file,mcp__filesystem__write_file"
}
```

`info` shows a `Tools  : ...` line for any model that overrides the global list.

---

## Bench history

`ospeed <model>` appends one JSONL line per run to
`~/.local-llm/bench-history.jsonl`. View with:

```powershell
obench                            # last 20 entries, all models
obench -Model q36plus -Last 50    # filter by model
Trim-LLMBenchHistory -OlderThanDays 90 -DryRun   # preview pruning
Trim-LLMBenchHistory -OlderThanDays 90           # apply pruning
```

---

## llama.cpp auto-tuner (`findbest`)

`findbest` searches the perf-only flag space for the highest-throughput launch
config on this machine — without touching anything that could affect generation
quality (quant, context, KV cache types stay locked unless you explicitly
widen). Result lands in `~/.local-llm/tuner/best-<key>.json` and is replayed by
`Start-ClaudeWithLlamaCppModel -AutoBest`.

```powershell
# Tune q36plus at the 256k context preset, native llama.cpp, default budget
findbest q36plus -ContextKey 256k

# Quick mode — only baseline + n-cpu-moe + batching (~10 trials)
findbest q36plus -ContextKey 256k -Quick

# Deep mode — normal phases, then finer local offload/batch/thread refinement
findbest q36plus -ContextKey 256k -Deep

# Optimize for prompt-eval (prefill) instead of generation
findbest q36plus -ContextKey 256k -Optimize prompt

# Allow KV cache variation (default = the model's current single type)
findbest q36plus -ContextKey 256k -AllowedKvTypes q8_0,f16

# Try mismatched K/V pairs too, and allow an explicit quality trade if wanted
findbest q36plus -ContextKey 256k -AllowedKvTypes q8_0,q4_0 -AggressiveKv

# Power-user: tune separate short- and long-prefill profiles
findbest q36plus -ContextKey 256k -PromptLengths short,long

# Inspect every trial run for a model
Show-LlamaCppTunerHistory -Key q36plus -Last 50
```

When `llama-bench.exe` is available in mainline mode, the tuner automatically
uses it for the coarse performance-only phases and verifies the winner through
`llama-server` before saving. Turboquant mode and KV-cache probes stay on the
server path for fidelity.

**What gets searched:**

1. **baseline** — catalog defaults, one probe.
2. **moe_or_ngl** — for MoE models, sweep `--n-cpu-moe` to find the smallest
   value that still fits VRAM (more layers on GPU = faster). For dense models
   with `-ngl` already at 999, this phase is a no-op unless baseline OOMed.
3. **batching** — joint sweep of `(--ubatch-size, --batch-size)` over a small
   2-D grid.
4. **flash** — compares flash-attention on/off.
5. **mmap** — compares `--mlock --no-mmap` against the default mapping mode
   (`-Aggressive` tries the cross-combinations too).
6. **threads** — sweeps CPU thread counts when the winning config keeps MoE
   experts or dense layers on CPU.
7. **kv** — only runs when `-AllowedKvTypes` contains more than one type.
   KV variation can change generations, so widened searches are an explicit
   opt-in; the tuner runs a small perplexity sanity check and refuses a >1%
   regression unless `-AllowKvQualityRegression` is passed.
8. **deep** — optional (`-Deep`). Re-tests a finer local neighborhood around
   the winning offload value, expands the batch grid up to `-ub 2048` /
   `-b 4096`, re-checks flash-attention after batch changes, and tries a wider
   CPU-thread set when CPU offload remains. If `-Budget` is omitted, deep mode
   raises the budget from 30 to 60.
9. **verify** — re-runs the final winner through `llama-server` when a coarse
   bench phase was used.

OOM/failure is detected from process output; OOM-monotonicity prunes branches
that are guaranteed to fail. Saved entries include the GPU name and llama.cpp
build stamp, so `-AutoBest` can warn when a re-tune is advisable after a
hardware or llama.cpp upgrade. Tuner version changes require a re-tune.

`-PromptLengths short,long` stores separate profile entries. `-AutoBest`
defaults to the short profile; use `-AutoBestProfile long` to replay the
long-prefill winner.

**Replaying the saved best:**

```powershell
Start-ClaudeWithLlamaCppModel -Key q36plus -ContextKey 256k -Mode native -AutoBest
```

The launcher matches the saved entry on `(key, contextKey, mode, vramGB ± 1)`
and a tuner-version stamp; on a miss it warns and falls through to defaults.
Caller-supplied `-KvCacheK` / `-KvCacheV` / `-ExtraArgs` always win over the
saved values.

In the wizard, choose the llama.cpp backend and then **Find best settings** to
run the same tuner interactively, with prompts for normal vs deep tuning, KV
variation, saving the winner, and launching immediately with `-AutoBest`.
Choose **Delete best settings** from the same action menu to remove saved
AutoBest entries for the selected `(model, quant, context, backend mode, VRAM)`
before re-tuning.

After a matching best config has been saved, normal wizard launches for the
same `(model, quant, context, backend mode, VRAM)` automatically replay it and
skip the manual KV-cache picker. If no matching entry exists, the wizard keeps
the usual manual KV-cache selection.

---

## Wizard

`llm` launches an interactive picker (Spectre-rendered when
`PwshSpectreConsole` is installed; classic Read-Host fallback otherwise).
It walks: model → quant → backend → context → action → q8/kvcache → launch.
Each step has a Back option (`0` in classic, `[[Back]]` in Spectre); the
Spectre wizard wraps each prompt in `Invoke-LLMWizardStep` and logs the
full exception trace to `~/.local-llm/wizard-errors.log` if anything throws,
so a Spectre live-display refresh can't scroll the trace off screen. Inspect
with `llmlogerr [-Lines 80]`; reset with `llmlogerrclear`.

`llmc` forces the classic wizard regardless of whether Spectre is available
— useful when a Spectre render bug makes the rich wizard unusable.

```powershell
$env:LOCAL_LLM_NO_SPECTRE = '1'   # globally fall back to classic
```

---

## Casing convention

The repo mixes three styles intentionally:

- `kebab-case` for folders (`local-llm/`, `ollama-proxy/`) — matches their deployed path.
- `PascalCase` for the entry-point script (`LocalLLMProfile.ps1`) — PowerShell convention.
- `kebab-case` for data files (`llm-models.json`).

These names are user-visible (the deployed paths). Renaming them would break
setups, so they stay.

---

## Troubleshooting

- **`init` says Ollama version too old** → `winget upgrade Ollama.Ollama`.
- **`Refusing -Q8 with -Ctx 256 ...`** → drop `-Q8`, lower `-Ctx`, or raise
  the ceiling: `Set-LocalLLMSetting Q8KvMaxContext <tokens>`.
- **`<model> does not advertise tool support`** → `RequireAdvertisedTools` is
  on by default; some uncensored Qwen variants don't advertise capabilities.
  Verify with `ollama show <alias>`. Bypass for one launch with
  `Start-ClaudeWithOllamaModel -Model <alias> -SkipToolCheck`, or globally
  via `Set-LocalLLMSetting RequireAdvertisedTools $false`.
- **Stale aliases after editing a parser** → `init -Stale` rebuilds only the
  aliases whose Modelfile content hash drifted.
- **Spectre wizard crashed** → `llmlogerr` for the full trace; set
  `$env:LOCAL_LLM_NO_SPECTRE=1` to use the classic wizard until it's fixed.
- **`bun` not on PATH** → only required for `-Fc` / Unshackled launches.
  Install via `winget install Oven-sh.Bun`.

---

## More

- `CHANGELOG.md` — what shipped, when.
- `analysis.md` / `plan-next.md` — second-pass review and planned work.
