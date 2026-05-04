# Stamps each created Ollama alias with a hash of the Modelfile fragment this
# profile would emit for it. Lets us detect aliases that were built from an
# older version of the profile and rebuild them on demand.

function Get-ModelfileLinesVersion {
    # Hash of the given Modelfile lines plus a context-length field. Returned
    # as a 12-char hex prefix so it fits a stamp file and is easy to compare.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object]$Lines,
        [Nullable[int]]$NumCtx
    )

    $payload = (@($Lines) -join "`n") + "`nnum_ctx=$NumCtx"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return ([System.BitConverter]::ToString($hash) -replace '-', '').Substring(0, 12).ToLowerInvariant()
}

function Get-ProfileVersion {
    # Detects when an existing alias was built from a different version of
    # *this profile* (so we know to rebuild it). Does NOT detect drift in
    # Ollama's own template handling, in the GGUF blob, or in aliases rebuilt
    # outside our wrapper — only that our emitted Modelfile would now look
    # different.
    param(
        [Parameter(Mandatory = $true)][string]$Parser,
        [Nullable[int]]$NumCtx
    )

    return Get-ModelfileLinesVersion -Lines (Get-ParserLines -Parser $Parser) -NumCtx $NumCtx
}

function Get-StrictProfileVersion {
    # Same idea as Get-ProfileVersion, but for strict siblings. They derive
    # from <base>:latest, so the hash only covers the strict overlay + num_ctx
    # — the base parser's contribution is inherited and not part of this stamp.
    param([Nullable[int]]$NumCtx)

    return Get-ModelfileLinesVersion -Lines (Get-StrictModelfileLines) -NumCtx $NumCtx
}

function Get-ProfileVersionDir {
    $dir = Join-Path $script:LLMProfileRoot "profile-versions"
    Ensure-Directory $dir
    return $dir
}

function Get-ProfileVersionFile {
    param([Parameter(Mandatory = $true)][string]$ModelName)
    $safe = ($ModelName -replace '[:/\\]', '_')
    return Join-Path (Get-ProfileVersionDir) "$safe.txt"
}

function Save-ProfileVersionStamp {
    param(
        [Parameter(Mandatory = $true)][string]$ModelName,
        [Parameter(Mandatory = $true)][string]$Version
    )
    Set-Content -Path (Get-ProfileVersionFile -ModelName $ModelName) -Value $Version -Encoding UTF8
}

function Get-ProfileVersionStamp {
    param([Parameter(Mandatory = $true)][string]$ModelName)
    $file = Get-ProfileVersionFile -ModelName $ModelName

    if (-not (Test-Path $file)) {
        return $null
    }

    return (Get-Content -Path $file -Raw -ErrorAction SilentlyContinue).Trim()
}
