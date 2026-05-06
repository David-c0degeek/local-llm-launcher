# Plan — llama.cpp auto-tuner ("find best settings for me")

Goal: given a model + chosen quant + chosen quality bounds (KV cache class, context),
search the per-machine parameter space and converge on the highest-throughput
launch config without sacrificing the user-specified quality. Llama.cpp backend
only — no Ollama path. The result is a saved per-machine profile that the
launcher can load on demand.

> Companion plan to `plan-next.md`. Lives in the same repo style: each phase is
> self-contained and ticked when shipped.

---

## 1. Scope and quality boundaries

**Tunable params (the search space).** Everything under here is performance-only
— flipping any of these does not change which tokens the model emits, only how
fast it emits them, the memory footprint, or whether it OOMs.

| Param | Range | Notes |
|---|---|---|
| `-ngl` (n_gpu_layers) | `[0 .. all]` typically `999` | If weights+kv fit, max. Otherwise sweep down. |
| `--n-cpu-moe` | `[0 .. expert_layer_count]` | MoE-only; biggest single lever for Qwen3-MoE / GLM coder etc. |
| `--ubatch-size` (`-ub`) | `{128, 256, 512, 1024, 2048}` | Physical batch; affects prompt-eval throughput most. |
| `--batch-size` (`-b`) | `{512, 1024, 2048, 4096}`, ≥ ub | Logical batch. |
| `--threads` (`-t`) | `[1 .. logical_cores]` | Mostly relevant when `--n-cpu-moe > 0`. |
| `--threads-batch` (`-tb`) | `[1 .. logical_cores]` | Prompt-eval thread pool. |
| `--flash-attn` (`-fa`) | `{on, off}` | Almost always on; verify on this box's GPU. |
| `--mlock` | `{on, off}` | |
| `--no-mmap` | `{on, off}` | Combined with `--mlock` matters for cold-start vs steady-state. |
| `--split-mode` (`-sm`) | `{none, layer, row}` | Only meaningful on multi-GPU. |
| `--tensor-split` (`-ts`) | `"x,y,..."` | Multi-GPU only; out-of-scope for v1. |
| `--cache-type-k` / `-v` | from user's allowed set | See quality bounds. |
| KV-on-CPU (`--no-kv-offload`) | `{on, off}` | Only probed if `-ngl < all` because of OOM. |

**Quality bounds (locked by the user before the run).**

- **Quant**: fixed. The tuner never substitutes a different GGUF.
- **Context (`-c` / `--ctx-size`)**: fixed at the value chosen in the wizard.
- **KV cache types (`-k`/`-v`)**: user picks an *allowed set* (e.g.
  `{q8_0, f16}` for native, or `{q8_0, f16, turbo3, turbo4}` for turboquant).
  The tuner is allowed to try any element of that set — but never anything
  outside it. Default allowed set is `{the user's chosen kv type}` only (i.e.
  no KV variation unless the user opts in by widening the set).

**Out of scope (quality-affecting).** Won't touch: rope / yarn scaling,
sampler params, chat template, system prompt, number of layers below the
quant's actual count.

---

## 2. Measurement protocol

All trials use the same prompt + same `n_predict` so token rates are
comparable. We need three numbers per trial:

- **Prompt eval tokens/sec** (`pp_tps`) — prefill speed.
- **Generation tokens/sec** (`tg_tps`) — steady-state output speed.
- **Composite score** — tunable weighting; default `tg_tps` (matches "feels
  fast" UX; user can switch with `-Optimize prompt|gen|both`).

**Two measurement modes**, chosen automatically based on what's installed:

1. **`llama-bench.exe`** (fast path). Ships with llama.cpp; designed for this
   exact job. One process per config, no HTTP, prints a clean table of
   `pp512` / `tg128` numbers. Supports sweeping `-ngl`/`-ncmoe`/`-ub`/`-b`/`-fa`
   in a single invocation, which collapses N trials into N llama-bench rows.
   - Caveats: doesn't honor every llama-server flag identically; doesn't
     verify the actual server starts; doesn't run the no-think-proxy path. Use
     it for the *coarse* sweep.
2. **llama-server probe** (full-fidelity path). Same launch path the launcher
   already uses (`Start-ClaudeWithLlamaCppModel` → `Start-LlamaServerNative` →
   `Wait-LlamaServer`), then POST a fixed prompt to `/v1/completions` with
   `n_predict = 256`, `stream = false`. Read `timings.predicted_per_second`
   and `timings.prompt_per_second` from the response (llama-server returns
   these natively). One probe per surviving config from the coarse sweep.

Both modes feed the same `BenchTrial` record (see §6).

**OOM / failure handling.**
- llama-bench: non-zero exit + stderr containing `CUDA error: out of memory`
  → record as OOM, prune that branch.
- llama-server: `Wait-LlamaServer` timeout OR process exits inside warmup →
  read tail of stderr for OOM markers, mark trial OOM. The existing
  `Stop-LlamaServer` already cleans up.
- A `--n-cpu-moe` of N implies more on CPU → **less** VRAM. So OOM at moe=K
  means everything below K is also OOM; we use this monotonicity to skip.
- Conversely `-ngl 999` uses **more** VRAM than `-ngl 30`. Same monotonicity
  on the other axis. Use both to prune.

**Warmup.** First 8 generated tokens of every probe are dropped from the
rate calculation. llama-bench already does its own warmup.

**Stability.** Each surviving config gets `-Runs N` (default 2) probes; we
take the median `tg_tps`. Variance > 15 % across runs → bump to 3.

---

## 3. Search strategy

A budget-aware, axis-by-axis hill climb. Total budget ≤ 30 trials by
default; user can pass `-Budget N`. Each trial costs a model load
(seconds–tens of seconds) + ~10 s of generation, so budget matters.

### Phase order (each phase is independent — earlier phases don't invalidate
later ones because we lock the winner before moving on)

1. **Baseline.** Use the catalog defaults (`Build-LlamaServerArgs` with no
   overrides). One probe. If this fails, the model can't run at the chosen
   quality at all → bail with a clear error before wasting budget.
2. **VRAM-fit calibration.** For MoE models, sweep `--n-cpu-moe` *down*
   from the catalog default until OOM. For dense models, sweep `-ngl` *up*
   to 999 until OOM. Lock the largest still-fitting value.
3. **Batching.** Joint sweep of `(--ubatch-size, --batch-size)` from a small
   2-D grid of common values: `ub ∈ {256, 512, 1024}`, `b ∈ {512, 1024, 2048}`
   with `b >= ub`. Take fastest. (Most quality-neutral and most consistently
   impactful single change.)
4. **Flash-attn.** Two probes: `-fa on/off`. Keep winner. (Often `on` is
   better but some 50-series + driver combos regress.)
5. **Memory-mapping.** Two probes: `(--mlock=true, --no-mmap=true)` vs
   `(--mlock=false, --no-mmap=false)`. (The other two combos are ~rarely
   useful and skip them by default; `-Aggressive` switch enables the full
   2x2.)
6. **Threads (CPU-offload models only).** Only when `--n-cpu-moe > 0` from
   §2. Sweep `-t` over `{cores/2, cores*3/4, cores}`. If MoE offload is 0,
   skip — threads barely matter when everything's on GPU.
7. **KV cache** (only if user allowed > 1 KV type). Probe each allowed
   `(K, V)` pair where K == V (mismatched K/V is rarely worth it; gated
   behind `-AggressiveKv`). Pick fastest.
8. **Final verification.** Run the full chosen config through the
   llama-server path even if the coarse sweep used llama-bench. Confirm
   the score didn't regress > 10 % (sanity check that flag combos
   compose).

The result: a `BestConfig` hashtable that's a drop-in for `ExtraArgs`.

### Why this and not Bayesian / random search

- 30 trials max. Bayesian optimization with surrogate models pays for
  itself only at hundreds of trials.
- Strong monotonicity priors (more VRAM offload = faster, until OOM)
  make axis-aligned sweeps near-optimal in practice.
- Reproducible — same hardware, same model, same answer.

---

## 4. UX / entry points

### 4.1 New cmdlet

```
Find-BestLlamaCppConfig `
    -Key q36plus `
    -ContextKey 256k `
    -Mode native `             # native | turboquant
    -AllowedKvTypes q8_0,f16 ` # default = the user's current single type
    -Budget 30 `
    -Optimize gen `            # gen | prompt | both
    -Aggressive:$false `       # opt into expanded mlock/no-mmap matrix
    -Quick                     # only phases 1-3 (~10 trials)
```

Output: a printed table of trials in trial order + a "Best:" panel showing
the winning argv. Side effect: a saved `tuner-best.json` entry (§5).

Aliases for muscle memory: `findbest`, `tunellm`.

### 4.2 Wizard hook

In `Select-LLMAction`, add for `llamacpp` backend:

```
Find best settings - Auto-tune for this machine
```

When picked:
1. Re-use the existing model/quant/context/backend prompts (already done by
   the wizard before reaching the action selector).
2. Optional Spectre prompt: "Allow KV cache variation? (y/N) — widens the
   search to other types in your quality class."
3. Run `Find-BestLlamaCppConfig`.
4. On success, ask: "Save as the default for this machine? (Y/n)" — if yes,
   write to settings.json under `LlamaCppPerModelOverrides.<key>` and
   reload (§5).
5. Offer to launch immediately with the new config.

### 4.3 Re-using saved best on launch

`Start-ClaudeWithLlamaCppModel` gains `-AutoBest`. When set, it loads the
saved best config (matched by `(key, quant, contextKey, mode, vramGB)`) and
splats it as `ExtraArgs` *before* any caller-supplied `ExtraArgs` (so caller
overrides still win).

If no saved config matches: warn and fall through to defaults.

---

## 5. Persistence

```
~/.local-llm/tuner/
  history-<key>.jsonl       # every trial ever run, append-only
  best-<key>.json           # current winner per (quant, ctx, mode, vramGB)
```

`best-<key>.json` shape:

```json
{
  "schema": 1,
  "key": "q36plus",
  "vramGB": 24,
  "entries": [
    {
      "quant": "Q4_K_M",
      "contextKey": "256k",
      "mode": "native",
      "score": 38.1,
      "scoreUnit": "tg_tps_median",
      "args": ["-ngl", "999", "--n-cpu-moe", "32", "-ub", "1024",
               "-b", "2048", "--flash-attn", "--mlock", "--no-mmap",
               "--cache-type-k", "q8_0", "--cache-type-v", "q8_0"],
      "measured_at": "2026-05-06T12:00:00Z",
      "tuner_version": 1,
      "trial_count": 18
    }
  ]
}
```

`history-<key>.jsonl` shape (one trial per line):

```json
{"ts":"...","phase":"moe_sweep","args":[...],"pp_tps":210.3,
 "tg_tps":37.5,"oom":false,"runs":2,"variance":0.04}
```

Mirrors the `bench-history.jsonl` pattern in `70-bench.ps1` so the existing
trim/show helpers can be generalized to this file.

**Cache invalidation.** A saved best is reused only when:
- model key matches AND
- quant matches AND
- contextKey matches AND
- mode matches AND
- detected VRAM is within ±1 GB of the saved `vramGB` AND
- `tuner_version` matches the current code (bumped on any change to phase
  order or measurement protocol).

Mismatch → warn, fall through to defaults, suggest re-running tuner.

---

## 6. Code layout

New file `local-llm/lib/72-llamacpp-tuner.ps1` (loads after `70-bench.ps1`).

Public:
- `Find-BestLlamaCppConfig` — entry point, returns `BestConfig` hashtable.
- `Get-BestLlamaCppConfig -Key ... -ContextKey ... -Mode ...` — loads from
  disk, returns `$null` on miss.
- `Save-BestLlamaCppConfig` — persists.
- `Show-LlamaCppTunerHistory -Key ... -Last 50` — table of past trials.

Private helpers:
- `Invoke-LlamaCppTrial` — runs one config, returns `BenchTrial`. Internally
  routes to `Invoke-LlamaCppTrial-Bench` (llama-bench) or
  `Invoke-LlamaCppTrial-Server` (llama-server probe).
- `Get-LlamaCppTrialPrompt` — returns the fixed bench prompt + n_predict.
  Make these constants so future cross-runs stay comparable.
- `Test-LlamaCppOomMessage` — stderr scan for OOM markers (CUDA OOM,
  Vulkan OOM, allocation failures).
- `Resolve-LlamaCppTunerSearchSpace -Def $def` — derives the per-model
  search axes from the catalog (e.g., MoE expert count for `--n-cpu-moe`
  upper bound).

Catalog additions in `llm-models.json` (per-model, optional):
- `MoeExpertLayers`: integer cap for `--n-cpu-moe` sweep upper bound. If
  missing, fall back to `[expert_layers from gguf metadata]` via a one-time
  probe at first tune.
- `TunerSkipPhases`: array, e.g. `["mlock"]`, for models we know don't
  benefit from a phase.
- `TunerLockedKvTypes`: optional override of the allowed-KV-type set
  (defense-in-depth — locks even if a future UI accidentally widens it).

Re-uses (don't duplicate):
- `Build-LlamaServerArgs` — extend it to accept new tunable args (`UbatchSize`,
  `BatchSize`, `Threads`, `ThreadsBatch`, `FlashAttn`, `SplitMode`) so the
  tuner doesn't reinvent argv assembly.
- `Find-LlamaCppFreePort`, `Wait-LlamaServer`, `Stop-LlamaServer`.
- `Get-LocalLLMVRAMGB` for the cache-key match.

---

## 7. Open questions / design decisions to confirm before coding

1. **llama-bench.exe** isn't currently shipped by `Ensure-LlamaServerNative`
   (`33-llamacpp-install.ps1`). Do we extend the installer to fetch it
   alongside `llama-server.exe`, or skip the fast path and only use the
   server probe? Recommendation: ship it; same release archive.
2. **Quality verification.** The plan trusts that "performance flags don't
   affect output." That's true for everything in §1's tunable list *except*
   reduced-precision KV cache types (q4_0/q4_1/iq4_nl/turbo3/turbo4 do
   change generations). Should §3 phase 7 require a side-by-side perplexity
   sanity check on a fixed prompt? Recommendation: no in v1; keep the
   user-controlled "allowed KV types" set as the only knob, and document
   that turbo3 / turbo4 trade quality. Add a perplexity probe in v2 if
   anyone asks.
3. **Concurrency / GPU contention.** The tuner needs the GPU to itself.
   Reuse `Stop-OllamaModels`, `Stop-OllamaApp`, `Stop-AllLlamaServers`
   exactly like `Start-ClaudeWithLlamaCppModel` does. Refuse to start if
   another GPU process is detected via `nvidia-smi` (already wired into
   `25-vram.ps1`).
4. **Multi-GPU.** v1 = single GPU only. Detect `nvidia-smi` returning > 1
   row → bail with "multi-GPU tuner not supported yet" rather than emit a
   wrong recommendation. v2 adds `--tensor-split` sweep.

---

## 8. Phasing — what to ship in what order

### Phase T1 — minimum viable (target: ~2 sessions of work)
- `72-llamacpp-tuner.ps1` skeleton.
- Server-probe trial only (skip llama-bench).
- Phases 1, 2, 3 only (baseline + MoE/ngl + batching). Skips KV / flash-attn
  / mlock / threads.
- `Find-BestLlamaCppConfig` cmdlet, no wizard hook yet.
- Persistence to `best-<key>.json`.
- README section.

This already produces a 2x-or-better result on most MoE models because
n-cpu-moe is the dominant lever and batching is the second.

### Phase T2 — full search
- Add llama-bench fast path (after extending installer).
- Add phases 4-7.
- History append + `Show-LlamaCppTunerHistory`.
- `-AutoBest` switch on `Start-ClaudeWithLlamaCppModel`.

### Phase T3 — wizard integration
- Wizard action "Find best settings".
- Spectre prompts for "allow KV variation".
- Save-and-launch flow.

### Phase T4 — polish (deferred unless asked)
- Perplexity sanity check for KV-type changes.
- Multi-GPU `--tensor-split` sweep.
- "Re-tune if hardware changed" auto-detection on launch.
- Per-prompt-length tuning (different best for short vs long prompts —
  ubatch can flip).

---

## 9. Risks / things that can go wrong

- **First trial OOMs**: catalog default is too aggressive on this box. The
  tuner needs to recover by stepping `--n-cpu-moe` *up* (more on CPU), not
  bail. Phase 2 already handles this — but order phase 2 before phase 1's
  baseline failure is fatal.
- **Long load times dominate budget**: at 60 s load + 10 s gen, 30 trials =
  35 minutes. Cache-warm second runs help. Show progress bar with ETA so
  the user knows what they bought.
- **llama-bench scores diverge from server scores**: the final-verification
  step in phase 8 catches this; if divergence > 10 %, log a warning and
  trust the server number.
- **Saved best becomes stale after a llama.cpp upgrade**: bump
  `tuner_version` on every release that changes flag semantics; old
  configs invalidate gracefully.
- **User adds a new GPU mid-cycle**: `vramGB` cache-key mismatch → falls
  through to defaults. Acceptable.

---

## 10. Sketch of the tuner loop (pseudocode)

```
function Find-BestLlamaCppConfig {
    $space = Resolve-LlamaCppTunerSearchSpace -Def $def
    $best  = Invoke-Phase-Baseline             $space      # $null on hard fail

    foreach ($phase in @('moe_or_ngl','batching','flash','mmap','threads','kv')) {
        if ($phase -in $def.TunerSkipPhases)              { continue }
        if ($Quick -and $phase -notin @('moe_or_ngl','batching')) { continue }
        $candidates = Get-PhaseCandidates -Phase $phase -Best $best -Space $space
        foreach ($cfg in $candidates) {
            if (Test-PrunedByMonotonicity -Cfg $cfg -History $history) { continue }
            $trial = Invoke-LlamaCppTrial -Cfg $cfg
            $history.Add($trial)
            if (-not $trial.oom -and $trial.score -gt $best.score) {
                $best = $cfg.WithScore($trial.score)
            }
        }
        Lock-Phase -Best $best
    }

    $verified = Invoke-LlamaCppTrial -Cfg $best -Mode 'server'
    if ($verified.score -lt 0.9 * $best.score) {
        Write-Warning "Verification regressed vs coarse sweep — recording verified score."
        $best = $best.WithScore($verified.score)
    }

    Save-BestLlamaCppConfig -Cfg $best
    return $best
}
```

---

## 11. Acceptance criteria for "v1 done"

- `findbest q36plus -ContextKey 256k -Mode native` runs end-to-end on a
  fresh machine without crashes, finishes within `Budget` trials, and
  prints a winning argv that includes at minimum tuned `-ngl` /
  `--n-cpu-moe` / `-ub` / `-b`.
- Re-running `findbest` after `lstop` produces the same winner ± one
  candidate (deterministic enough to trust).
- `Start-ClaudeWithLlamaCppModel -Key q36plus -ContextKey 256k -AutoBest`
  loads the saved config and starts a server that answers `/v1/models`
  within the existing `LlamaCppHealthCheckTimeoutSec`.
- Existing `claude` / `chat` / wizard paths are unchanged when `-AutoBest`
  isn't set (no regression risk for users who don't opt in).
