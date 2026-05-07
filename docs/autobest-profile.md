# LocalBox AutoBest Profile Contract

`Start-ClaudeWithLlamaCppModel -AutoBest` loads saved launcher profiles from:

```text
~/.local-llm/tuner/best-<key>.json
```

The current compatibility schema is `localbox-autobest-v1`. The top
level object keeps launcher-owned routing fields and an `entries` array. Each
entry is matched by `Get-BestLlamaCppConfig` using:

- `contextKey`
- `mode`
- `profile` (`pure` when omitted)
- `prompt_length` (`short` when omitted)
- `quant`
- `vramGB` within +/- 1 GB
- `tuner_version` when present

Entries must include an `overrides` object whose keys can be splatted into
`Build-LlamaServerArgs`. The currently accepted tuning override keys are:

- `KvK`
- `KvV`
- `NGpuLayers`
- `NCpuMoe`
- `Mlock`
- `NoMmap`
- `UbatchSize`
- `BatchSize`
- `Threads`
- `ThreadsBatch`
- `FlashAttn`
- `SplitMode`

Tuner version 4 is the current launch-time profile generation. It invalidates
older saved profiles and uses `coding_agent_e2e_tps` by default, so AutoBest
prefers long-prefill, end-to-end latency over decode-only generation TPS.
Expanded BenchPilot entries can be saved as `pure` or `balanced`; entries
without a `profile` field are treated as `pure` for backwards compatibility.

`Start-ClaudeWithLlamaCppModel -AutoBest` defaults to
`-AutoBestProfile auto`, which prefers `balanced` entries when available and
falls back to `pure`. `-AutoBestProfile pure` and `-AutoBestProfile balanced`
force the selection profile. `-AutoBestProfile short` and
`-AutoBestProfile long` remain legacy prompt-length overrides and load pure
profiles only.

After a saved profile is applied and llama-server is healthy, LocalBox performs
a small Anthropic-compatible `/v1/messages` launch smoke request before handing
the session to Claude or Unshackled. The smoke includes the real launch system
prompt and must produce visible response text; output inside `<think>...</think>`
is ignored for this check. For strip-mode models this first
uses the no-think proxy, matching the normal launch route. llama.cpp strip-mode
launches also disable reasoning generation with `--reasoning off` and
`--reasoning-budget 0`; the proxy remains as a defensive cleaner for any leaked
tags. If that proxy route does not produce visible text, LocalBox tries the
direct llama-server route for the same session. If neither route succeeds,
AutoBest launch aborts so a high-throughput profile cannot silently become an
unusable interactive session.

Claude/Unshackled llama.cpp launches are single-session agent workloads, so the
launcher also applies `--parallel 1` and `--cache-reuse 256` outside the saved
tuner override set. This keeps title/smoke/sidebar requests from competing with
the main agent turn across multiple slots and gives repeated large prompts a
stable cache path.

The wizard exposes saved selection profiles directly. When both `balanced` and
`pure` entries exist, launch settings include explicit profile choices in
addition to the `auto` preference (`balanced`, then `pure`). Immediate launch
after a `-Profile both` tuning run asks which saved profile should be replayed.

BenchPilot-compatible exports add provenance without changing the launch-time
reader:

- `source = "benchpilot"`
- `benchpilot_version`
- `benchpilot_profile_path`
- `report_path`
- `launcher_export_version`

Expanded BenchPilot exports also store selection metadata and optional
diagnostics:

- `profile`
- `searchStrategy`
- `beamWidth`
- `pureScore`
- `telemetry`
- `scoreBreakdown`

Staleness checks continue to read `gpu_names` and `llamacpp_build` from each
entry.
