# HuggingFace metadata + README parsing for `addllm`. Pulls /api/models/{repo}
# (the same JSON the HF site uses), maps GGUF files to quant codes, and tries
# hard to find a usable Description from the repo / its base_model.

function Resolve-HuggingFaceRepo {
    param([Parameter(Mandatory = $true)][string]$UrlOrRepo)

    $value = $UrlOrRepo.Trim()
    $value = $value -replace '^https?://(www\.)?huggingface\.co/', ''
    $value = $value -replace '/(tree|blob|resolve)/[^/]+.*$', ''
    $value = $value.TrimEnd('/')

    if ($value -notmatch '^[^/\s]+/[^/\s]+$') {
        throw "Cannot parse HuggingFace repo from: $UrlOrRepo"
    }

    return $value
}

function Get-HuggingFaceModelInfo {
    # One round-trip to /api/models/{repo}?blobs=true. Returns the raw object
    # (siblings carry `size` in bytes, plus cardData / tags / etc.).
    param([Parameter(Mandatory = $true)][string]$Repo)

    $url = "https://huggingface.co/api/models/$Repo`?blobs=true"
    return Invoke-RestMethod -Uri $url -UseBasicParsing
}

function Get-HuggingFaceModelFiles {
    param([Parameter(Mandatory = $true)][string]$Repo)

    $info = Get-HuggingFaceModelInfo -Repo $Repo

    if (-not $info.siblings) {
        return @()
    }

    return @($info.siblings | ForEach-Object { $_.rfilename })
}

function Get-HuggingFaceFileSizesGB {
    # Map of rfilename -> size in GB (1 decimal place). Pulled from siblings[*].size
    # which is bytes when ?blobs=true is set on /api/models/{repo}.
    param([Parameter(Mandatory = $true)]$Info)

    $map = [ordered]@{}

    if (-not $Info.siblings) { return $map }

    foreach ($s in $Info.siblings) {
        $name = $s.rfilename
        if (-not $name) { continue }

        $bytes = 0L
        if ($s.PSObject.Properties.Match('lfs').Count -gt 0 -and $s.lfs -and $s.lfs.size) {
            try { $bytes = [long]$s.lfs.size } catch { }
        }
        if ($bytes -le 0 -and $s.PSObject.Properties.Match('size').Count -gt 0 -and $s.size) {
            try { $bytes = [long]$s.size } catch { }
        }

        if ($bytes -gt 0) {
            # Decimal GB (1e9) to match existing catalog entries and HF's UI.
            # Slightly larger than binary GiB but reads the same as HF README tables.
            $map[$name] = [math]::Round($bytes / 1000000000, 1)
        }
    }

    return $map
}

function Get-HuggingFaceReadme {
    # Raw README.md for a repo. Returns $null on any failure (404, network, ...).
    param([Parameter(Mandatory = $true)][string]$Repo)

    $url = "https://huggingface.co/$Repo/raw/main/README.md"

    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10
        return [string]$resp.Content
    } catch {
        return $null
    }
}

function ConvertFrom-HuggingFaceReadme {
    # Heuristic: pull the first prose paragraph out of a raw HF README.md.
    # Strips frontmatter, HTML comments, headings, badge/image lines, blockquotes,
    # bare URLs, "weighted/imatrix quants of <link>" boilerplate. Falls back to
    # $null if nothing usable remains.
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$Readme)

    if ([string]::IsNullOrWhiteSpace($Readme)) { return $null }

    $text = $Readme

    # Drop YAML frontmatter (--- ... --- at the very top).
    if ($text -match '^\s*---\r?\n') {
        $idx = $text.IndexOf("`n---", 4)
        if ($idx -ge 0) {
            $text = $text.Substring($idx + 4)
        }
    }

    # Strip HTML comments.
    $text = [regex]::Replace($text, '<!--[\s\S]*?-->', '')

    # Strip image lines and bare badge links on their own line.
    $text = [regex]::Replace($text, '(?m)^\s*!\[[^\]]*\]\([^)]*\)\s*$', '')

    $paragraphs = [regex]::Split($text, '\r?\n\s*\r?\n')

    foreach ($p in $paragraphs) {
        $candidate = $p.Trim()
        if (-not $candidate) { continue }
        # Skip headings, fenced code, tables, blockquotes, list-only blocks.
        if ($candidate -match '^(#|```|>|\||---|\* |- |\d+\. )') { continue }
        # Skip lines that are only badges / images / single links.
        if ($candidate -match '^!\[' ) { continue }
        if ($candidate -match '^\[!\[') { continue }
        # Skip mradermacher boilerplate ("weighted/imatrix quants of ...").
        if ($candidate -match '^(weighted/imatrix |static )?quants of\s+https?://') { continue }
        if ($candidate -match '^For a convenient overview') { continue }
        if ($candidate -match '^If you are unsure how to use GGUF') { continue }
        # Need real prose: at least one sentence, not just a URL.
        if ($candidate.Length -lt 30) { continue }
        if ($candidate -match '^\s*https?://\S+\s*$') { continue }

        # Collapse internal whitespace; cap at ~400 chars to keep dashboards readable.
        $candidate = ($candidate -replace '\s+', ' ').Trim()

        # Strip simple inline markdown links: [text](url) -> text
        $candidate = [regex]::Replace($candidate, '\[([^\]]+)\]\([^)]+\)', '$1')
        # Strip emphasis markers.
        $candidate = $candidate -replace '\*{1,3}([^*]+)\*{1,3}', '$1'

        if ($candidate.Length -gt 400) {
            $cut = $candidate.Substring(0, 397)
            $lastDot = $cut.LastIndexOf('. ')
            if ($lastDot -gt 200) { $cut = $cut.Substring(0, $lastDot + 1) }
            $candidate = $cut.TrimEnd() + ($(if ($candidate.Length -gt $cut.Length) { '...' } else { '' }))
        }

        return $candidate
    }

    return $null
}

function Resolve-HuggingFaceDescription {
    # Try to find a usable Description for a repo:
    #   1. cardData.description on this repo (rare for quant repos)
    #   2. README.md of base_model if cardData.base_model is set (mradermacher pattern)
    #   3. README.md of this repo
    # Returns $null if nothing usable.
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [int]$Depth = 0
    )

    if ($Depth -gt 1) { return $null }

    try {
        $info = Get-HuggingFaceModelInfo -Repo $Repo
    } catch {
        return $null
    }

    if ($info.cardData -and $info.cardData.description) {
        $cd = ([string]$info.cardData.description).Trim()
        if ($cd -and $cd.Length -ge 30) { return $cd }
    }

    if ($Depth -eq 0 -and $info.cardData -and $info.cardData.base_model) {
        $base = $info.cardData.base_model
        if ($base -is [array]) { $base = $base[0] }
        $base = [string]$base
        if ($base -match '^[^/\s]+/[^/\s]+$' -and $base -ne $Repo) {
            $fromBase = Resolve-HuggingFaceDescription -Repo $base -Depth ($Depth + 1)
            if ($fromBase) { return $fromBase }
        }
    }

    $readme = Get-HuggingFaceReadme -Repo $Repo
    return (ConvertFrom-HuggingFaceReadme -Readme $readme)
}

# Quant code -> (family label, quality tier text). Hand-curated from the
# llama.cpp / mradermacher quant table. Used by New-LocalLLMQuantNoteText to
# generate baseline QuantNotes when the user doesn't supply their own.
$script:LocalLLMQuantSemantics = @{
    'IQ1_S'    = @('1-bit imatrix',          'for the desperate')
    'IQ1_M'    = @('1-bit imatrix',          'mostly desperate')
    'IQ2_XXS'  = @('2-bit imatrix',          'very low quality')
    'IQ2_XS'   = @('2-bit imatrix',          'very low quality')
    'IQ2_S'    = @('2-bit imatrix',          'low quality')
    'IQ2_M'    = @('2-bit imatrix',          'low quality, long-context only')
    'Q2_K_S'   = @('2-bit k-quant small',    'very low quality')
    'Q2_K'     = @('2-bit k-quant',          'IQ3_XXS often better')
    'IQ3_XXS'  = @('3-bit imatrix',          'lower quality')
    'IQ3_XS'   = @('3-bit imatrix',          'lower quality')
    'Q3_K_S'   = @('3-bit k-quant small',    'IQ3_XS often better')
    'IQ3_S'    = @('3-bit imatrix',          'beats Q3_K*')
    'IQ3_M'    = @('3-bit imatrix',          'good 3-bit baseline')
    'Q3_K_M'   = @('3-bit k-quant medium',   'IQ3_S often better')
    'Q3_K_L'   = @('3-bit k-quant large',    'IQ3_M often better')
    'IQ4_XS'   = @('4-bit imatrix',          'good 4-bit, smallest 4-bit option')
    'IQ4_NL'   = @('4-bit imatrix non-linear','good 4-bit baseline')
    'Q4_0'     = @('4-bit legacy',           'fast, low quality')
    'Q4_1'     = @('4-bit legacy',           '')
    'Q4_K_S'   = @('4-bit k-quant small',    'optimal size/speed/quality')
    'Q4_K_M'   = @('4-bit k-quant medium',   'fast, recommended sweet spot')
    'Q4_K_P'   = @('4-bit k-quant',          'similar to Q4_K_M')
    'MXFP4'    = @('4-bit MoE-aware',        'similar to IQ4_NL')
    'MXFP4_MOE'= @('4-bit MoE-aware',        'similar to IQ4_NL')
    'Q5_K_S'   = @('5-bit k-quant small',    'noticeable quality bump')
    'Q5_K_M'   = @('5-bit k-quant medium',   'noticeable quality bump')
    'Q6_K'     = @('6-bit k-quant',          'high quality')
    'Q6_K_P'   = @('6-bit k-quant',          'high quality')
    'Q8_0'     = @('8-bit',                  'highest practical quality')
    'BF16'     = @('bfloat16 full precision','expect partial offload')
    'F16'      = @('float16 full precision', 'expect partial offload')
    'F32'      = @('float32 full precision', 'almost certainly partial offload')
}

function New-LocalLLMQuantNoteText {
    # Generic baseline note for a quant when the user doesn't supply -QuantNotes.
    # Format: "<CODE> · <family> · ~<size> GB · <tier note>"
    # Any missing field is omitted. Returns "" if nothing useful is known.
    param(
        [Parameter(Mandatory = $true)][string]$QuantCode,
        [AllowNull()][object]$SizeGB
    )

    $upper = $QuantCode.ToUpperInvariant()
    $family = $null
    $tier = $null

    if ($script:LocalLLMQuantSemantics.ContainsKey($upper)) {
        $entry = $script:LocalLLMQuantSemantics[$upper]
        $family = $entry[0]
        $tier = $entry[1]
    }

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add($upper) | Out-Null
    if ($family) { $parts.Add($family) | Out-Null }
    if ($null -ne $SizeGB -and $SizeGB -gt 0) {
        $parts.Add("~$([math]::Round([double]$SizeGB, 1)) GB") | Out-Null
    }
    if ($tier) { $parts.Add($tier) | Out-Null }

    return ($parts -join ' · ')
}

function Get-HuggingFaceQuantCode {
    param([Parameter(Mandatory = $true)][string]$FileName)

    $leaf = ($FileName -split '/' | Select-Object -Last 1)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($leaf)

    $patterns = @(
        '(IQ\d_[A-Z]+(?:_[A-Z0-9]+)?)$',
        '(MXFP\d_[A-Z]+)$',
        '(Q\d_K_[A-Z])$',
        '(Q\d_K)$',
        '(Q\d_\d)$',
        # mudler / APEX scheme: APEX-Mini / APEX-Compact / APEX-Balanced /
        # APEX-Quality, plus an `-I-` infix marking the imatrix variant.
        # Match any capitalized tier word so new tiers don't need code changes.
        '(APEX(?:-I)?-[A-Z][A-Za-z]+)$',
        '(BF16|F16|F32)$'
    )

    foreach ($pattern in $patterns) {
        if ($name -match $pattern) {
            return $Matches[1]
        }
    }

    return $null
}

function ConvertTo-LocalLLMQuantKey {
    param([Parameter(Mandatory = $true)][string]$QuantCode)

    return ($QuantCode -replace '_', '').ToLowerInvariant()
}

function Format-LocalLLMDisplayName {
    param([Parameter(Mandatory = $true)][string]$Repo)

    $tail = ($Repo -split '/')[-1]
    $display = $tail -replace '-', ' '
    $display = $display -replace '(?i)Qwen(\d)', 'Qwen $1'
    return $display
}

function Get-LocalLLMDefaultContexts {
    return [ordered]@{
        ''     = 65536
        '32k'  = 32768
        '64k'  = 65536
        '128k' = 131072
        '256k' = 262144
    }
}
