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
