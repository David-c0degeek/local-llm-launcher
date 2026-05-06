# Parser → llama-server flags. Two responsibilities:
# 1. Map a parser name (qwen3coder, qwen36, etc.) to a `--chat-template` or
#    `--chat-template-file` argument set.
# 2. Translate the Ollama PARAMETER lines from Get-ParserLines (40-parsers.ps1)
#    into the equivalent llama-server CLI flags so sampling stays consistent.

function Get-LlamaCppTemplatesDir {
    return (Join-Path $HOME ".local-llm\llamacpp-templates")
}

function Resolve-LlamaCppChatTemplate {
    # Returns a [string[]] of CLI args (empty when the model's GGUF metadata
    # already carries a usable template). Honors a per-model ChatTemplate
    # override that, if set, wins over the parser-based mapping.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Parser,
        [string]$Override
    )

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        if (Test-Path $Override) {
            return @('--chat-template-file', $Override)
        }
        return @('--chat-template', $Override)
    }

    switch ($Parser) {
        'none'           { return @() }
        'qwen3coder'     { return @('--jinja') }
        'qwen36'         { return @('--jinja') }
        'qwen36-think'   { return @('--jinja') }
        default          { return @() }
    }
}

function Get-LlamaCppReasoningArgs {
    # Maps the catalog ThinkingPolicy + parser to llama-server reasoning flags.
    # llama-server emits structured reasoning when --reasoning-format is set;
    # `none` keeps the wire format clean, `deepseek` lets thinking blocks pass.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ThinkingPolicy,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Parser
    )

    $policy = if ([string]::IsNullOrWhiteSpace($ThinkingPolicy)) { 'strip' } else { $ThinkingPolicy }

    if ($policy -eq 'keep') {
        return @('--reasoning-format', 'deepseek')
    }

    return @('--reasoning-format', 'none')
}

function ConvertFrom-OllamaParameter {
    # Reads PARAMETER lines from Get-ParserLines (40-parsers.ps1) and emits the
    # equivalent llama-server CLI flags. Unknown PARAMETER names are skipped
    # silently — they apply to Ollama-only Modelfile features.
    param([Parameter(Mandatory = $true)][System.Collections.IEnumerable]$Lines)

    $out = New-Object System.Collections.Generic.List[string]

    foreach ($line in $Lines) {
        $text = [string]$line
        if (-not $text) { continue }
        if ($text -notmatch '^\s*PARAMETER\s+(\S+)\s+(.+)\s*$') { continue }

        $name = $Matches[1].ToLowerInvariant()
        $value = $Matches[2].Trim()

        # Unwrap one layer of surrounding quotes (single or double).
        if ($value.Length -ge 2 -and ($value[0] -in @('"', "'")) -and $value[-1] -eq $value[0]) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        switch ($name) {
            'temperature'      { $out.Add('--temp');             $out.Add($value); break }
            'top_k'            { $out.Add('--top-k');            $out.Add($value); break }
            'top_p'            { $out.Add('--top-p');            $out.Add($value); break }
            'min_p'            { $out.Add('--min-p');            $out.Add($value); break }
            'repeat_penalty'   { $out.Add('--repeat-penalty');   $out.Add($value); break }
            'repeat_last_n'    { $out.Add('--repeat-last-n');    $out.Add($value); break }
            'presence_penalty' { $out.Add('--presence-penalty'); $out.Add($value); break }
            'frequency_penalty'{ $out.Add('--frequency-penalty');$out.Add($value); break }
            'tfs_z'            { $out.Add('--tfs');              $out.Add($value); break }
            'typical_p'        { $out.Add('--typical');          $out.Add($value); break }
            'mirostat'         { $out.Add('--mirostat');         $out.Add($value); break }
            'mirostat_tau'     { $out.Add('--mirostat-ent');     $out.Add($value); break }
            'mirostat_eta'     { $out.Add('--mirostat-lr');      $out.Add($value); break }
            'seed'             { $out.Add('--seed');             $out.Add($value); break }
            # PARAMETER stop / num_ctx / num_predict are handled elsewhere.
            default            { }
        }
    }

    return @($out)
}

function Get-LlamaCppStrictSystemPromptPath {
    # Renders Get-StrictModelfileLines into a Jinja-free plain text file llama-server
    # can pass via --system-prompt-file. Cached so repeated launches don't churn.
    $dir = Get-LlamaCppTemplatesDir
    Ensure-Directory $dir

    $path = Join-Path $dir "strict-system.txt"

    $lines = Get-StrictModelfileLines
    $body = New-Object System.Collections.Generic.List[string]
    $inSystem = $false

    foreach ($l in $lines) {
        $text = [string]$l
        if ($text -match '^\s*SYSTEM\s+"""') { $inSystem = $true; continue }
        if ($inSystem -and $text -match '^"""\s*$') { $inSystem = $false; continue }
        if ($inSystem) { $body.Add($text) | Out-Null }
    }

    $content = ($body -join [System.Environment]::NewLine)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $content, $utf8NoBom)

    return $path
}

function Get-LlamaCppStrictSamplerArgs {
    # The strict overlay's PARAMETER values, translated for llama-server.
    return (ConvertFrom-OllamaParameter -Lines (Get-StrictModelfileLines))
}
