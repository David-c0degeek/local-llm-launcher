# VRAM detection (nvidia-smi → cached value → fallback) and quant-fit classification.
# Cached for the session so repeated dashboard renders don't hammer nvidia-smi.

$script:LocalLLMVRAMCache = $null

function Get-AutoDetectVRAMGB {
    # Returns the largest GPU's VRAM in GB via nvidia-smi, or $null if nvidia-smi
    # isn't on PATH / fails. Multi-GPU: takes the max (Ollama loads to one card).
    try {
        $cmd = Get-Command nvidia-smi -ErrorAction SilentlyContinue
        if (-not $cmd) { return $null }

        $output = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null

        if ($LASTEXITCODE -ne 0 -or -not $output) { return $null }

        $values = @()
        foreach ($line in @($output)) {
            $trimmed = $line.Trim()
            if ($trimmed -match '^\d+$') { $values += [int]$trimmed }
        }

        if ($values.Count -eq 0) { return $null }

        $maxMb = ($values | Measure-Object -Maximum).Maximum

        if ($maxMb -le 0) { return $null }

        return [int][math]::Round($maxMb / 1024)
    } catch {
        return $null
    }
}

function Get-LocalLLMVRAMInfo {
    # Resolve VRAM in three steps:
    #   1. user-configured via settings.json / catalog (Source = "configured")
    #   2. nvidia-smi auto-detect, cached for the session (Source = "auto")
    #   3. fallback to 24 (Source = "fallback")
    if ($script:Cfg -and $script:Cfg.Contains("VRAMGB")) {
        try {
            $val = [int]$script:Cfg.VRAMGB
            if ($val -gt 0) {
                return @{ GB = $val; Source = "configured" }
            }
        } catch { }
    }

    if ($null -eq $script:LocalLLMVRAMCache) {
        $auto = Get-AutoDetectVRAMGB
        if ($auto) {
            $script:LocalLLMVRAMCache = @{ GB = $auto; Source = "auto" }
        } else {
            $script:LocalLLMVRAMCache = @{ GB = 24; Source = "fallback" }
        }
    }

    return $script:LocalLLMVRAMCache
}

function Get-LocalLLMVRAMGB {
    return (Get-LocalLLMVRAMInfo).GB
}

function Get-Q8KvMaxContext {
    # Largest num_ctx safe to combine with -Q8 (q8_0 KV cache).
    # Override explicitly via settings.json: Set-LocalLLMSetting Q8KvMaxContext 262144
    # Default scales with VRAM: each GB above ~16 GB is worth ~16k extra q8 tokens
    # (rough heuristic across the catalog's MoE coders). Floors at 64k.
    if ($script:Cfg -and $script:Cfg.Contains("Q8KvMaxContext")) {
        try { return [int]$script:Cfg.Q8KvMaxContext } catch { }
    }

    $vramGB = Get-LocalLLMVRAMGB
    $derived = ($vramGB - 16) * 16384

    if ($derived -lt 65536) { return 65536 }

    return [int]$derived
}

function Get-QuantSizeGB {
    # Per-quant numeric size (GB) from the optional QuantSizesGB hashtable on a
    # model def. Returns $null when the catalog hasn't filled it in.
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$QuantKey
    )

    if (-not $Def.Contains("QuantSizesGB") -or -not $Def.QuantSizesGB) { return $null }
    if ([string]::IsNullOrEmpty($QuantKey)) { return $null }

    foreach ($k in $Def.QuantSizesGB.Keys) {
        if ($k -ieq $QuantKey) {
            try { return [double]$Def.QuantSizesGB[$k] } catch { return $null }
        }
    }

    return $null
}

function Get-QuantFitClass {
    # Classify a quant against the host's VRAM budget:
    #   "fits"  — leaves >= 7 GB headroom for KV cache + overhead
    #   "tight" — fits weights but only ~2 GB headroom; fine at short context
    #   "over"  — won't fit fully on one GPU; expect partial offload
    #   ""      — size unknown (no QuantSizesGB entry)
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Def,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$QuantKey
    )

    $size = Get-QuantSizeGB -Def $Def -QuantKey $QuantKey
    if ($null -eq $size) { return "" }

    $vramGB = Get-LocalLLMVRAMGB

    if ($size -le ($vramGB - 7)) { return "fits" }
    if ($size -le ($vramGB - 2)) { return "tight" }
    return "over"
}

function Format-QuantFitBadge {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$FitClass)

    switch ($FitClass) {
        "fits"  { return "[fits]" }
        "tight" { return "[tight]" }
        "over"  { return "[over]" }
        default { return "" }
    }
}

function Get-QuantFitBadgeColor {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$FitClass)

    switch ($FitClass) {
        "fits"  { return "Green" }
        "tight" { return "Yellow" }
        "over"  { return "Red" }
        default { return "DarkGray" }
    }
}
