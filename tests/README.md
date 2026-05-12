# LocalBox unit tests

Pester 5 suite for the high-value pure functions in `local-llm/lib/`.

## Coverage

- **`vram.tests.ps1`** — `Get-QuantSizeGB`, `Get-QuantFitClass`,
  `Get-Q8KvMaxContext`. Pure functions over `(QuantSizesGB, VRAMGB)`.
- **`config-merge.tests.ps1`** — `Import-LocalLLMConfig` and the legacy-shape
  fallback during the Phase 2 migration window.
- **`modelfile.tests.ps1`** — `Get-ParserLines` Modelfile snippet emission.

Out of scope (per the refactor plan): proxy behavior, HuggingFace fetchers,
wizard flows. The smoke check in `tests/smoke-autobest-compat.ps1` is separate
and not migrated here.

## Running

Requires Pester 5.

```powershell
Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser
Invoke-Pester tests/unit -CI
```

`-CI` makes Pester return a non-zero exit code on any failure (useful in
GitHub Actions). All tests run without network access and without a GPU.
