# LocalBox Refactor Plan

Plan for the five accepted items from the external review (review items #1, #2, #3, #4, #6). Items #5 (folder restructure of `lib/`) and #7 (TOML/YAML config) were intentionally rejected and are out of scope.

Order is by ROI: dry-run first (cheapest, biggest user-visible win), then split, then proxy pin, then validator, then tests.

---

## Phase 1 — Dry-run / preview mode for launches (review #6)

**Goal:** before any backend process is spawned, print the resolved command line, environment, estimated VRAM, and selected quant/context so the user can sanity-check.

**Scope (in):**
- Ollama launches via `llm` / `llmctx` / strict-sibling launchers
- llama.cpp launches via `llm-server` / agent profile
- Claude Code launches that wrap the above (`local-llm/lib/65-claude-launch.ps1`)

**Scope (out):** model downloads, alias rebuilds, BenchPilot runs (separate dry-run already exists on `updatellm`).

**Design:**
- Add a `-DryRun` switch (alias `-WhatIf` where the verb supports it) to the public launch entrypoints in `lib/99-entrypoints.ps1`.
- Centralize preview rendering in a new helper `Show-LocalLLMLaunchPlan` in `lib/75-display.ps1`:
  - Resolved model key, quant, context, parser
  - Full argv that would be passed to `llama-server` / `ollama`
  - Env vars that would be set (filter from `$script:ClaudeEnvNames`)
  - Estimated VRAM (reuse `Get-LocalLLMQuantFit` from `lib/25-vram.ps1`) with the detected GPU VRAM for comparison
  - Health-check URL and timeout
- Launch functions in `lib/32-llamacpp.ps1`, `lib/30-ollama.ps1`, and `lib/65-claude-launch.ps1` accept `-DryRun`; when set, they build the command/env exactly as they would for a real launch, call `Show-LocalLLMLaunchPlan`, and return without spawning.

**Acceptance:**
- `llm-server qcoder30 -DryRun` prints argv + VRAM estimate + env and exits 0 with no process started.
- `llm qcoder30 -DryRun` does the same for the Ollama path.
- Claude launch wrappers propagate `-DryRun` so `claude-local … -DryRun` previews both the backend command and the Claude env it would set.

**Estimated cost:** ~1 day. No new dependencies. Risk: low — pure addition, no behavior change on the default path.

---

## Phase 2 — Split catalog from settings (review #1)

**Goal:** `llm-models.json` becomes a pure model catalog. Global launcher config moves to `settings.json`.

**Current state:**
- `local-llm/llm-models.json` (274 lines) mixes `Models` (catalog data) with 18+ top-level scalars: `Default`, `KeepAlive`, `OllamaAppPath`, `OllamaCommunityRoot`, `RequireAdvertisedTools`, `NoThinkProxyPort`, `LlamaCppPort`, `LlamaCppServerPath`, `LlamaCppTurboquantRoot`, `LlamaCppTurboquantRepo`, `LlamaCppGgufRoot`, `LlamaCppDefaultMode`, `LlamaCppHealthCheckTimeoutSec`, `LlamaCppCoexistOllama`, `LocalModelTools`, `MinOllamaVersion`, `CommandAliases`.
- `local-llm/settings.json` exists but is only used for per-machine overrides (currently 2 lines: `BenchPilotRoot`).
- `Import-LocalLLMConfig` in `lib/00-settings.ps1` already overlays settings on top of the catalog — that machinery stays.

**Design:**
- New file `local-llm/defaults.json` (committed, ships with the launcher) holds all current top-level scalars. Rename rationale: "settings" remains the per-machine override file; "defaults" is the shipped baseline.
- `llm-models.json` keeps only `Models` and `CommandAliases` (which is data tied to the catalog, not launcher config).
- Load order in `Import-LocalLLMConfig`:
  1. `defaults.json` (committed defaults)
  2. `llm-models.json` `Models` + `CommandAliases`
  3. `settings.json` overlay (per-machine, gitignored)
- Migration: a one-shot helper `Migrate-LocalLLMConfig` (in `lib/15-updates.ps1`) runs at profile load. If `llm-models.json` still has top-level scalars and `defaults.json` doesn't exist, it writes them out to `defaults.json` and rewrites `llm-models.json` to keep only `Models`/`CommandAliases`. Idempotent.
- `Set-LocalLLMSetting` already blocks `Models`/`CommandAliases`; extend it to know which keys belong in `defaults.json` vs `settings.json` for clearer error messages.

**Acceptance:**
- Fresh checkout: `defaults.json` ships in repo, `llm-models.json` contains only `Models` + `CommandAliases`.
- Existing installs: profile load migrates in place without user action; old shape continues to work for one release as a fallback (warning emitted).
- `addllm` / `updatellm` / `removellm` touch only `llm-models.json`. Adding a model is a diff to `Models.<key>` only.

**Estimated cost:** ~1 day. Risk: medium — migration must be safe on dirty/stale configs.

---

## Phase 3 — Version-pin the no-think proxy (review #3)

**Goal:** launcher and `no-think-proxy.py` carry coupled versions; the installer / runtime detects mismatch and fails loud.

**Current state:**
- `ollama-proxy/no-think-proxy.py` has no version constant.
- `install.ps1` copies/symlinks both `local-llm/` and `ollama-proxy/` to `~/.local-llm` and `~/.ollama-proxy`. They can drift if a user only updates one.
- The proxy is what makes Anthropic wire format work with local backends — a silent mismatch is the worst class of bug.

**Design:**
- Add `__version__ = "1.0.0"` near the top of `no-think-proxy.py`. Bumped any time wire-format handling changes.
- Add `--version` CLI flag that prints just the version and exits 0.
- Add `NoThinkProxyRequiredVersion` to `defaults.json` (carried alongside `NoThinkProxyPort`). Bumped in lockstep when the proxy changes.
- On profile load — and on `install.ps1` run — call `python no-think-proxy.py --version` and compare against the required version. Mismatch:
  - In install: prompt to overwrite the deployed copy from the repo (default Yes).
  - In profile load: emit a single warning with the exact fix command (`Update-LocalLLMProxy` or rerun `install.ps1`).
- Add `Update-LocalLLMProxy` helper in `lib/15-updates.ps1` that copies the repo's `ollama-proxy/no-think-proxy.py` over the deployed copy at `~/.ollama-proxy/no-think-proxy.py`. Honors `-Symlink` if the existing deployment is a symlink (no-op).

**Acceptance:**
- Profile load on a system with stale proxy prints a single yellow warning naming the deployed version, the required version, and the fix command.
- `install.ps1` on the same system fixes the mismatch.
- Bumping the version constant and re-installing flips the check.

**Estimated cost:** ~half a day. Risk: low.

---

## Phase 4 — Catalog validator function (review #4)

**Goal:** catch typos and missing/invalid fields in `llm-models.json` at load time with a readable error, not at the call site of whatever function later trips over them.

**Approach:** PowerShell validator function, not JSON Schema. Schema would need external tooling; a validator is 50–100 lines and lives next to the loader.

**Design:**
- New file `local-llm/lib/05-validate.ps1` (load order: after `00-settings.ps1`, before everything else that reads the catalog).
- `Test-LocalLLMCatalog` walks the loaded catalog and validates every model entry:
  - Required fields per `SourceType` (`gguf` vs `remote`)
  - `Quant` must exist as a key in `Quants`
  - `Parser` must be one of the known parsers (`none`, `qwen3coder`, `qwen36`, `qwen36-think`)
  - `Tier` must be one of `recommended` / `experimental` / `legacy`
  - `QuantSizesGB` / `QuantNotes` keys must be a subset of `Quants` keys
  - `Contexts` values must be positive integers
  - Optional llama.cpp fields (`NGpuLayers`, `NCpuMoe`, `KvCacheK`, `KvCacheV`) typed correctly when present
- Errors collected, not throw-on-first: one consolidated error message listing every problem with `model.field` paths.
- Wired into `Import-LocalLLMConfig`: validate after merge, before returning the config. Validation failures throw with the full error list.
- `addllm` / `updatellm` call the same validator on the in-memory entry before saving, so bad input is caught before it hits disk.

**Acceptance:**
- Hand-edit `llm-models.json` to add a model with `Parser: "bogus"` and a `Quant` that isn't in `Quants` → profile load fails with a single error message naming both problems and the model key.
- Catalog with no problems loads silently (no perf regression beyond a quick walk).

**Estimated cost:** ~half a day. Risk: low.

---

## Phase 5 — Pester tests on the high-value pure functions (review #2)

**Goal:** unit coverage on the three areas where regressions hurt most. Not "coverage for its own sake."

**Targets (and only these):**
1. **VRAM math / quant fit** — `Get-LocalLLMQuantFit` and friends in `lib/25-vram.ps1`. Pure function over `(QuantSizesGB, Context, AvailableVRAMGB)`. Easy to fixture.
2. **Config merge** — `Import-LocalLLMConfig` after Phase 2. Verify `defaults.json` + `llm-models.json` + `settings.json` overlay precedence, including the legacy-shape fallback during the migration window.
3. **Modelfile generation** — `lib/50-modelfile.ps1`. Given a model entry + context, the generated Modelfile string must be deterministic and contain the expected `PARAMETER`/`TEMPLATE` lines.

**Explicitly out of scope:** proxy behavior (integration territory; fixture maintenance cost is too high for the value), HuggingFace fetchers (network-bound), wizard flows (interactive).

**Design:**
- New folder `tests/unit/` with one `.tests.ps1` per target area.
- Pester 5 (declare in a short `tests/README.md`; no auto-installer).
- Test catalog fixtures in `tests/fixtures/catalog/` — minimal hand-crafted JSON snippets, never the real `llm-models.json`.
- CI: add a GitHub Actions workflow `.github/workflows/pester.yml` running on `pwsh` (Windows runner) that invokes `Invoke-Pester tests/unit -CI`. Keep the existing `tests/smoke-autobest-compat.ps1` separate; not migrated.

**Acceptance:**
- `Invoke-Pester tests/unit` from a fresh clone runs green with no network and no GPU.
- Intentionally breaking `Get-LocalLLMQuantFit` (e.g. flip a comparison) fails at least one test with a clear message naming the function.

**Estimated cost:** ~1.5 days (Pester setup + three test files + CI). Risk: low.

---

## Sequencing summary

| Phase | Item | Estimated cost | Depends on |
|-------|------|----------------|------------|
| 1 | Dry-run / preview | 1 d | — |
| 2 | Split catalog/settings | 1 d | — |
| 3 | Proxy version pin | 0.5 d | Phase 2 (uses `defaults.json`) |
| 4 | Catalog validator | 0.5 d | Phase 2 (validates post-merge) |
| 5 | Pester unit tests | 1.5 d | Phases 2 + 4 (tests cover the merged loader and validator) |

Phases 1 and 2 are independent and can land in either order. 3, 4, 5 chain on 2.

## Out of scope (explicitly rejected from the review)

- **#5 lib/ folder restructure** — the numeric `00–99` prefixes encode dot-source order, which matters. A `lib/README.md` index page is the cheaper fix if navigation becomes a real problem; not planned now.
- **#7 TOML/YAML config** — `settings.json` is 2 lines; once Phase 2 lands, `llm-models.json` is pure data and doesn't need comments. PowerShell's native JSON support is sufficient. Adding a parser dependency is not justified.
