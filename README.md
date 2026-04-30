# local-llm-launcher

Run [Claude Code](https://claude.com/claude-code) (or [Unshackled](https://github.com/David-c0degeek/unshackled) — Claude Code fork) against a local Ollama backend, with proper handling of thinking blocks, parser config, KV cache, and per-model tool restrictions.

Windows / PowerShell only.

## What this is

A PowerShell profile that:

- Catalogs local LLMs in `llm-models.json` (Ollama remote pulls or HuggingFace GGUFs).
- Auto-builds Ollama aliases per (model, context-length) with the right Modelfile renderer/parser/sampling for each model family (Qwen3-Coder, Qwen 3.6, Mistral/Devstral).
- Launches Claude Code or Unshackled against Ollama with the correct env vars (`ANTHROPIC_BASE_URL`, model overrides, thinking-disabled, prompt-caching off).
- Routes traffic through a small Python proxy (`no-think-proxy.py`) that strips Anthropic-specific `thinking`/`reasoning` fields Ollama can't handle. Thinking-trained models (`ThinkingPolicy: keep`) bypass the proxy.
- Exposes one PowerShell function per model with flag-based switches.

## Two deployed dirs

The repo ships in two folders that map to two deployed locations:

```
repo                              deployed
local-llm/      ─── install ──→   %USERPROFILE%\.local-llm\
ollama-proxy/   ─── install ──→   %USERPROFILE%\.ollama-proxy\
```

The PowerShell profile dot-sources `~/.local-llm/LocalLLMProfile.ps1`, which reads `~/.local-llm/llm-models.json` and shells out to `~/.ollama-proxy/no-think-proxy.py` and `~/.ollama-proxy/enforcer-claude.ps1`.

## Install

From the repo root:

```powershell
. .\install.ps1                  # copy files to deployed locations + add to $PROFILE
. .\install.ps1 -Symlink         # symlink instead of copy (admin / dev mode)
. .\install.ps1 -Profile         # only ensure $PROFILE dot-sources the deployed file
```

After install, open a fresh PowerShell and run `init` to build Ollama aliases for the recommended models.

## Day-to-day usage

One function per model, flag-based:

```
qcoder -Ctx fast -Fc          Code agent (Qwen3-Coder, 32k, Unshackled)
q36p -Ctx fast -Fc            General Qwen 3.6 agent (32k, Unshackled)
dev -Ctx fast                 Smaller / faster (Devstral 24B, 32k)
q36p -Ctx 128 -Fc             Big context (Qwen 3.6 Plus, 128k)
q36p -Chat                    Raw ollama chat, no Claude Code
q36p -Q8                      Use q8 KV cache for higher quality
q36p -Quant q6kp              Switch the GGUF quant (rebuilds aliases)
llmdefault                    Launch the configured Default model
llm                           Guided wizard
```

| Flag | Effect |
|------|--------|
| `-Ctx <name>` | One of the model's context keys (e.g. `fast`, `deep`, `128`). Omit for default. |
| `-Fc` (alias `-FreeCode`, canonical `-Unshackled`) | Use Unshackled instead of Claude Code. |
| `-Chat` | Run plain `ollama run`, skip Claude Code entirely. |
| `-Q8` | Set `OLLAMA_KV_CACHE_TYPE=q8_0` for this launch. |
| `-Quant <name>` | Switch the model's selected GGUF quant. No launch — rebuilds the alias. |

Run `llmdocs` for the full quick reference, or `info` for the dashboard.

## Adding a model

```powershell
addllm <hf-url-or-repo> -Key <key> [-Quants Q4_K_P,IQ4_XS] [-DefaultQuant Q4_K_P] [-Tier recommended]
initmodel <key>
```

Removing a model:

```powershell
removellm <key>            # confirms first
removellm <key> -Force     # skip confirmation
removellm <key> -KeepFiles # keep the GGUF blobs on disk
```

## Casing convention

The repo mixes three styles intentionally:

- `kebab-case` for folders (`local-llm/`, `ollama-proxy/`) — matches their deployed path.
- `PascalCase` for the entry-point script (`LocalLLMProfile.ps1`) — PowerShell convention.
- `kebab-case` for data files (`llm-models.json`).

These names are user-visible (the deployed paths). Renaming them would break setups, so they stay.

## Per-workspace default model

Drop a `.llm-default` file in any directory containing a single line — a model key, `ShortName`, or `Root`. `llmdefault` (and the enforcer wrapper) walks up from `$PWD` and uses the nearest match. Falls back to the global `Default` field in `llm-models.json`.

```
echo q36p > .llm-default          # this workspace prefers Qwen 3.6 Plus
```

## MCP servers

Claude Code's MCP servers expose tools with names like `mcp__<server>__<tool>`. They reach the local model through the same launch path:

- Models with `"LimitTools": false` (e.g. `dev`) get every MCP tool automatically — the `--tools` flag isn't passed.
- Models with `"LimitTools": true` (default) only see tools in the allowlist. Add the MCP tool names you want to either the global `LocalModelTools` field in `llm-models.json` or a per-model `Tools` override.

Example per-model override:

```json
"q36plus": {
  ...,
  "Tools": "Bash,Read,Write,Edit,Glob,Grep,mcp__filesystem__read_file,mcp__filesystem__write_file"
}
```

`info` shows a `Tools  : ...` line for any model that overrides the global list.

## Bench history

`ospeed <model>` appends one JSONL line per run to `~/.local-llm/bench-history.jsonl`. View with:

```powershell
obench                            # last 20 entries, all models
obench -Model q36plus -Last 50    # filter by model
Trim-LLMBenchHistory -OlderThanDays 90 -DryRun   # preview pruning
Trim-LLMBenchHistory -OlderThanDays 90           # apply pruning
```

## More

- `CHANGELOG.md` — what shipped, when.
