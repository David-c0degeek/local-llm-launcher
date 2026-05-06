# Plan — finish the llama.cpp auto-tuner (T2 + T3 + T4)

Continuation of `plan-llamacpp-tuner.md`. T1 shipped in commit `e93198b`
("Add llama.cpp auto-tuner (T1: baseline + n-cpu-moe + batching)") on `main`.
This plan finishes phases 4–8 (full search), the wizard hook, and the polish
items — *minus multi-GPU*, which we are explicitly not building.

## Required reading before you touch anything

Read in this order:

1. `plan-llamacpp-tuner.md` — original design, glossary, rationale.
2. `local-llm/lib/72-llamacpp-tuner.ps1` — T1 implementation.
3. `local-llm/lib/41-llamacpp-args.ps1` — `Build-LlamaServerArgs` (already
   accepts `UbatchSize`, `BatchSize`, `Threads`, `ThreadsBatch`, `FlashAttn`,
   `SplitMode` as of T1).
4. `local-llm/lib/65-claude-launch.ps1` — `Start-ClaudeWithLlamaCppModel`
   (already wires `-AutoBest`).
5. `local-llm/lib/33-llamacpp-install.ps1` — installer logic that needs to
   learn about `llama-bench.exe`.
6. `local-llm/lib/90-wizard.ps1` — action selector you'll extend in T3.

## Conventions inherited from T1

- File numbering matters. Lib files dot-source in numeric order. The tuner is
  `72-…` so it sees everything up to `70-bench.ps1`.
- Tuner state lives under `~/.local-llm/tuner/`:
  `best-<key>.json`, `history-<key>.jsonl`, `logs/trial-*-{stdout,stderr}.log`.
- Public surface: `Find-BestLlamaCppConfig` (alias `findbest`, `tunellm`),
  `Get-BestLlamaCppConfig`, `Save-BestLlamaCppConfig`,
  `Show-LlamaCppTunerHistory`.
- A trial is a hashtable with these fields:
  ```
  ts, phase, overrides, args, oom, startup_ok, runs,
  pp_tps, tg_tps, variance, port, error, log_path,
  score, score_unit, tuner_version
  ```
- `score` units are the median of `tg_tps` (Optimize=gen, default), `pp_tps`
  (Optimize=prompt), or `sqrt(pp*tg)` (Optimize=both).
- `$script:LlamaCppTunerVersion = 1`. **Bump this to 2 the moment you change
  phase order, the prompt, or `n_predict`** — saved bests get invalidated
  gracefully (the cache-key match in `Get-BestLlamaCppConfig` requires the
  stamp to match).
- Reuse helpers — don't duplicate. Especially:
  `Invoke-LlamaCppTunerTrial` (single-trial bookkeeping wrapper),
  `Test-LlamaCppMonotonicityOom`, `Append-LlamaCppTunerHistory`,
  `Format-LlamaCppOverrides`, `Resolve-LlamaCppTunerSearchSpace`.

## How to test as you go

There is no PowerShell unit-test framework in this repo. Smoke-test by
dot-sourcing the profile in a non-interactive shell and exercising the
function. T1 used scripts under `/tmp` invoked via `pwsh -NoProfile -File …`
— follow that pattern.

Two test models are useful:

- A small dense model (e.g. `q36plus` at `iq2m`) for quick correctness checks.
- A larger MoE model (e.g. `q36plus` at a bigger quant) for actually
  exercising the n-cpu-moe sweep.

Always run `lstop` before a tuner test to free VRAM cleanly.

---

## Phase T2 — full search

Each step is independent. Ship them in order, one commit per step, smoke-test
between commits. Bump `$script:LlamaCppTunerVersion` to **2** after step T2.1
and don't bump it again — all of T2 is one tuner-version bucket.

### T2.1 — Phase 4: flash-attn

Add a `flash` phase to `Find-BestLlamaCppConfig`'s phase loop, after
`batching`, before any later phases. Two probes:

```
$cand_on  = best.overrides + @{ FlashAttn = $true  }
$cand_off = best.overrides + @{ FlashAttn = $false }
```

Skip the phase if `Should-RunPhase 'flash'` returns false (catalog
`TunerSkipPhases` opt-out + `-Quick`).

Update `Should-RunPhase` so `'flash'` is **not** in the `-Quick` allowlist
(quick mode stays at baseline + moe_or_ngl + batching only).

After the phase, replace `best` with whichever of the two won by score
(remember the existing best may be neither — it didn't have FlashAttn set,
so the server's own default decided; treat the unset-baseline as a third
contender by leaving `best` in the running and only updating it when a probe
beats its score).

OOM-monotonicity prune doesn't apply here — flash-attn changes neither
NGpuLayers nor NCpuMoe — but call `Test-LlamaCppMonotonicityOom` anyway for
consistency (it returns false in this case).

**Validation:** A run with `-Quick` should NOT include the flash phase. A
run without `-Quick` should print 2 trial rows with `phase=flash`.

### T2.2 — Phase 5: mlock / no-mmap

Add an `mmap` phase. Default: 2 probes.

```
$cand_a = best.overrides + @{ Mlock = $true;  NoMmap = $true  }
$cand_b = best.overrides + @{ Mlock = $false; NoMmap = $false }
```

If `-Aggressive` is set, also run the cross combos:
`@{ Mlock=$true; NoMmap=$false }` and `@{ Mlock=$false; NoMmap=$true }`.

**Risk:** on a box with limited free RAM, `--mlock` can fail. Treat that as
a normal trial loss — the existing `startup_ok=false` / OOM-detection path
should handle it. Add `failed to lock` and `mlockall failed` patterns to
`$script:LlamaCppOomPatterns` (rename it to `$script:LlamaCppFailurePatterns`
since they're not strictly OOM anymore — update all call sites).

### T2.3 — Phase 6: threads

Add a `threads` phase. Run only when `best.overrides.NCpuMoe -gt 0`
(MoE offload happening) **or** the model is dense AND `best.overrides.NGpuLayers -lt 999`
(some layers on CPU). Otherwise skip — threads barely matter when the GPU
does everything.

Detect logical cores:

```powershell
$logicalCores = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
```

Sweep 3 candidates: `{floor(cores/2), floor(cores*3/4), cores}`. De-dup
(small machines collapse). For each, set both `Threads` and `ThreadsBatch`
to the same value (separate sweeping isn't worth the budget). Take the
fastest.

If you exceed budget (`$trialIndex -ge $Budget`) before all 3 fit, drop the
middle candidate first.

### T2.4 — Phase 7: KV cache types

Only run when `$AllowedKvTypes.Count -gt 1`. Otherwise this phase is a no-op
because there's nothing to vary.

Default: probe each pair where `K == V`, e.g. `AllowedKvTypes=q8_0,f16` →
`@{KvK=q8_0;KvV=q8_0}` and `@{KvK=f16;KvV=f16}`. With `-AggressiveKv`
(new switch), also probe mismatched pairs (Cartesian product minus the
identity pairs already covered).

Add `-AggressiveKv [switch]` to `Find-BestLlamaCppConfig`, `findbest`,
`tunellm`. Defaults to false.

Validate every (K, V) pair with `Test-LlamaCppKvType -Type $t -Mode $Mode`
before running the trial — this is the existing helper from
`41-llamacpp-args.ps1` that rejects turboquant types in native mode.

**Quality caveat:** This is the only phase that can change generations. It's
gated behind explicit user opt-in via `-AllowedKvTypes`. Document this in
the README section you'll touch in T2.6.

### T2.5 — Phase 8: final verification

After all other phases complete, re-run the winning config one more time
through the same server-probe path and compare the score to what was
recorded. If the verification score is < 90 % of the recorded best:

```
Write-Warning "Verification regressed (..)% vs coarse sweep — recording verified score."
$best.score = $verifiedScore
$best.trial.score = $verifiedScore
```

This isn't strictly necessary in T2 (we only ever ran one mode — server
probe — so coarse and fine should agree). It becomes load-bearing in T2.6
(llama-bench fast path) where the bench numbers can diverge from server
numbers by 5–15 %.

Implement the helper so T2.6 can lean on it; for T2 alone, you can write
`if ($script:LlamaCppCoarseMode -eq 'server') { return $best }` to skip
the extra trial unless something coarser actually ran.

### T2.6 — llama-bench fast path

This is the largest piece. Two parts: installer + alternative trial driver.

#### T2.6a — Installer fetches llama-bench.exe

Edit `local-llm/lib/33-llamacpp-install.ps1`:

- After `Install-LlamaServerNative` extracts the archive, also verify
  `llama-bench.exe` ended up in the install root. The mainline release ZIP
  ships both binaries; the existing `Get-ChildItem … -Filter "llama-server.exe"
  -Recurse` flatten step should also flatten `llama-bench.exe`. Make the
  flatten loop generic: copy every `*.exe` from the source dir, not just
  llama-server.exe.
- Add `Find-LlamaBenchExe` mirroring `Find-LlamaServerExe`:

```powershell
function Find-LlamaBenchExe {
    $defaultPath = Join-Path (Get-LlamaCppInstallRoot) "llama-bench.exe"
    if (Test-Path $defaultPath) { return $defaultPath }
    $cmd = Get-Command llama-bench.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}
```

- Add `Ensure-LlamaBenchExe -NonInteractive` that returns the path or runs
  `Install-LlamaServerNative -Force` (since the bench binary ships in the
  same archive, reinstalling the server gets it too) and re-checks.

Skip turboquant — turboquant ships its own binaries; we don't have a
guaranteed `llama-bench.exe` from that fork. Keep the bench fast path
mainline-only; `Mode=turboquant` falls back to the server-probe path.

#### T2.6b — Alternative trial driver

Add `Invoke-LlamaCppTrialBench` to `72-llamacpp-tuner.ps1`. Signature
mirrors `Invoke-LlamaCppTrialServer` exactly so the call site is
interchangeable.

llama-bench accepts comma-separated sweep values per axis:

```
llama-bench -m model.gguf -ngl 999 -ncmoe 24,28,32 -ub 256,512,1024 -b 512,1024,2048 -fa 0,1 -p 512 -n 128 -o json
```

Output is JSON when `-o json`. Each row has `n_gpu_layers`, `n_ubatch`,
`n_batch`, `n_threads`, `flash_attn`, `pp_avg_ts` (`pp512`),
`tg_avg_ts` (`tg128`).

The bench path is most efficient when you batch many trials per process
launch. Two integration approaches:

1. **One-trial-per-invocation** (simpler, slightly slower). Build the
   `llama-bench` argv from the candidate's overrides, parse one row.
2. **Sweep-per-phase** (faster). The phase generates N candidates; emit
   them as comma-separated values to llama-bench in a single call; parse
   N rows; map each back to a `BenchTrial`.

Start with approach 1. Approach 2 is a follow-up if budget time matters.

KV cache type, mlock, no-mmap, threads — all have llama-bench equivalents.
Run `llama-bench --help` and map each `Build-LlamaServerArgs` flag.
**Some flags don't have a llama-bench equivalent** (e.g. chat templates
don't matter to llama-bench, which doesn't run the chat path). For those,
just don't pass them to llama-bench.

Choose the trial driver per phase:

- baseline → server (need to confirm the model actually loads via the same
  path Start-ClaudeWithLlamaCppModel uses).
- moe_or_ngl, batching, flash, mmap, threads → bench when available.
- kv → server (llama-bench doesn't honor every KV type and you want
  fidelity).
- final verification → server.

Track which phase used which driver via a `$script:LlamaCppTrialDriverByPhase`
hashtable so phase 8 can decide whether to re-verify.

OOM detection from llama-bench: non-zero exit + stderr containing one of the
existing `$script:LlamaCppFailurePatterns`. Same as server.

#### T2.6c — Update README + help text

Add a sentence to the README section that mentions the bench fast path
auto-engages for mainline mode. No flag for the user — it's transparent.

---

## Phase T3 — wizard integration

Read `local-llm/lib/90-wizard.ps1` first to learn the structure. Look for
`Select-LLMAction` (or its current equivalent — function name may have
drifted). The action selector is what you extend.

### T3.1 — Action selector entry

Add a new action option for the `llamacpp` backend only:

```
Find best settings - Auto-tune for this machine
```

The Ollama backend already doesn't get this option — gate on the resolved
`$Backend` variable inside `Select-LLMAction`.

### T3.2 — KV variation prompt

After the user picks "Find best settings", show a Spectre yes/no prompt
(see existing yes/no toggles in the wizard for the pattern — the recent
"Spectre yes/no toggles" fix in commit `176af3c` is the reference):

```
Allow KV cache variation? (y/N)
  Widens the search to other types in your quality class.
```

If yes, derive an `$AllowedKvTypes` from the model's mode:
- `native` → `@('q8_0', 'f16')`
- `turboquant` → `@('q8_0', 'f16', 'turbo3', 'turbo4')`

If no, leave `$AllowedKvTypes` unset so `Find-BestLlamaCppConfig` defaults
to the user's current single type.

### T3.3 — Run + save + launch

```powershell
$result = Find-BestLlamaCppConfig -Key $key -ContextKey $ctx -Mode $mode `
    -AllowedKvTypes $allowedKvTypes -NoSave  # we'll prompt before saving

# Show the result panel via Format-LlamaCppOverrides
# Then:
$saveAnswer = (Spectre-PromptYesNo "Save as the default for this machine? [Y/n]" -DefaultYes)
if ($saveAnswer) {
    Save-BestLlamaCppConfig -Key $key -ContextKey $ctx -Mode $mode `
        -Quant $result.Quant -VramGB $result.VramGB `
        -BestArgs $result.Args -BestOverrides $result.Overrides `
        -Score $result.Score -ScoreUnit $result.ScoreUnit `
        -TrialCount $result.TrialCount
}

$launchAnswer = (Spectre-PromptYesNo "Launch immediately with the new config? [Y/n]" -DefaultYes)
if ($launchAnswer) {
    Start-ClaudeWithLlamaCppModel -Key $key -ContextKey $ctx -Mode $mode -AutoBest
}
```

(`Spectre-PromptYesNo` isn't a real function — replace with whatever the
wizard already uses. The `Spectre yes/no toggles` commit shows the
gotcha to avoid: 'Yes' was being treated as 'Back', so verify the
yes-path actually returns yes.)

Add `-NoSave` and the `$result` return shape to T1's
`Find-BestLlamaCppConfig` if they're not already there (T1 already returns
`@{ Score; ScoreUnit; Overrides; Args; Trial; TrialCount; ElapsedSec;
VramGB; ContextKey; Mode; Quant }`, and `-NoSave` is already a switch).

### T3.4 — Validation

Manual: launch `llm`, walk a llamacpp model to the action selector, pick
"Find best settings", confirm prompts behave (especially yes/no — the
fix in `176af3c` is recent and any regression is on us). Confirm the
saved file lands at `~/.local-llm/tuner/best-<key>.json`. Confirm
"Launch immediately" works end-to-end.

---

## Phase T4 — polish

These are independent and can ship in any order.

### T4.1 — Perplexity sanity check (KV-type changes only)

Background: the only T1/T2 phase that can change generations is phase 7
(KV cache types). Adding a perplexity check guards against regressing
quality when the user opts in to a wider `-AllowedKvTypes`.

Implementation:

1. Extend the installer (T2.6a's pattern) to also fetch
   `llama-perplexity.exe` from the same release archive.
2. Add `Invoke-LlamaCppPerplexity -Cfg $cfg -PromptFile $path`. Returns
   a perplexity number (lower = better). Uses a small fixed text file
   shipped in `local-llm/data/perplexity-fixture.txt` (~2 KB of plain
   English; pick something boring and stable like the first chapter of a
   public-domain book).
3. In the KV phase, after picking the fastest pair, also run perplexity
   against the baseline KV pair (whatever the model originally used).
   If `(candidate_perplexity - baseline_perplexity) / baseline_perplexity > 0.01`
   (1 %), warn loudly and refuse to record the candidate as best unless
   the user re-runs with `-AllowKvQualityRegression`.
4. Report the perplexity numbers in the trial table for kv-phase rows.

Add a new switch `-AllowKvQualityRegression` to bypass the gate.

This ONLY runs when `-AllowedKvTypes` widens past the single user-selected
type. For the default single-type case, perplexity is identical by
construction and the check is skipped.

### T4.2 — Hardware-change auto-retune detection

When `Start-ClaudeWithLlamaCppModel -AutoBest` loads a saved entry, also
check whether the current hardware has materially changed since the
measurement:

- New GPU model (compare against `nvidia-smi --query-gpu=name`).
- VRAM delta > 1 GB (already enforced by the cache-key match — but tighten
  this to "warn loudly even on miss" so users see *why* the saved best
  wasn't used).
- llama.cpp build stamp changed (read `Get-LlamaCppInstallRoot/.build-stamp`
  and compare against the value at measurement time — requires saving
  `llamacpp_build` in the best-file entry; bump tuner_version when you do).

On detected change, print:

```
AutoBest: hardware/build changed since last tune — saved config may be
stale. Re-run: findbest <key> -ContextKey <ctx>
```

But still load the saved config (a stale tune is usually better than
defaults). Add `-AutoBestStrict` switch to make stale = abort instead.

### T4.3 — Per-prompt-length tuning

Current bench prompt is fixed at ~280 tokens. The optimal `(ub, b)` for
a 16 k-token prefill is often different from the optimum for a 200-token
prefill. Add an axis:

- Default: keep current behavior (one bench prompt, one best per key).
- `-PromptLengths short,long` flag: run the full search twice with
  different bench prompts (short=~280 tokens, long=~16k tokens of repeated
  text). Save two best entries keyed on `prompt_length` in addition to
  `(quant, contextKey, mode, vramGB)`.

`Start-ClaudeWithLlamaCppModel -AutoBest` defaults to the `short` entry.
Add `-AutoBestProfile long` (or numeric `-AutoBestPromptLength 16384`) to
pick the other. Rare power-user feature; document as such.

This requires schema changes to `best-<key>.json` — bump
`$script:LlamaCppTunerVersion` to 3 (or whatever's next) so old saves
invalidate cleanly.

---

## Out of scope (do NOT implement)

- **Multi-GPU.** The v1 bail in `Find-BestLlamaCppConfig` (throws when
  `nvidia-smi` reports >1 GPU) stays as the policy decision. Don't add
  `--tensor-split` / `--split-mode row|layer` sweeping. Don't remove the
  bail.
- **Bayesian / random search.** Axis-aligned hill climb is fine at this
  budget. Don't pull in surrogate models.
- **GPU process detection that reaches outside this profile.** We already
  call `Stop-OllamaModels` / `Stop-OllamaApp` / `Stop-LlamaServer`. Don't
  start killing arbitrary `nvidia-smi`-detected processes — that's a
  footgun.

---

## Schema migration checklist

Whenever you change anything in the trial protocol or saved-best shape:

1. Bump `$script:LlamaCppTunerVersion`.
2. `Get-BestLlamaCppConfig` already filters on the stamp — old entries
   become invisible automatically.
3. Add a one-line note to the README under the "llama.cpp auto-tuner"
   section pointing out that a re-tune is needed after upgrading.
4. Do **not** write a migrator for `best-<key>.json` — easier to re-tune
   than to maintain version migrations for a fast-changing local file.

---

## Acceptance criteria — "T2 + T3 done"

- `findbest q36plus -ContextKey 256k` runs all phases (1–8), prints rows
  for each, and saves a winner that includes at minimum tuned
  `-ngl` / `--n-cpu-moe` / `-ub` / `-b` / `--flash-attn` / `--mlock` /
  `--threads`.
- `findbest q36plus -ContextKey 256k -AllowedKvTypes q8_0,f16` adds 2
  KV-phase rows and the winning argv may include the alternate K/V.
- `findbest q36plus -ContextKey 256k -Quick` runs only baseline +
  moe_or_ngl + batching (no flash/mmap/threads/kv).
- The wizard exposes "Find best settings" for llamacpp-backed models,
  walks the prompts cleanly, and offers save + launch.
- `Start-ClaudeWithLlamaCppModel -Key q36plus -ContextKey 256k -AutoBest`
  loads the saved config and starts a server that answers `/v1/models`
  within `LlamaCppHealthCheckTimeoutSec`.
- Existing `claude` / `chat` / wizard launch paths are unchanged when
  `-AutoBest` isn't set.

## Acceptance criteria — "T4 done"

- `findbest q36plus -ContextKey 256k -AllowedKvTypes q8_0,q4_0` warns or
  refuses if perplexity rises >1 % vs the baseline pair.
- `Start-ClaudeWithLlamaCppModel -AutoBest` warns when GPU model or
  llama.cpp build has changed since the saved measurement.
- `findbest … -PromptLengths short,long` produces two saved entries and
  `-AutoBestProfile long` selects the long-prompt winner.
