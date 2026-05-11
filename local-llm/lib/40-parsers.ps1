# Parser → Modelfile fragment lookup. Each parser name maps to the
# RENDERER/PARSER/PARAMETER lines emitted into a generated Modelfile.
# To add a new model family, add a case here.

function Get-ParserLines {
    param([Parameter(Mandatory = $true)][string]$Parser)

    $lines = New-Object System.Collections.Generic.List[string]

    switch ($Parser) {
        "none" {
        }

        "qwen3coder" {
            $lines.Add("RENDERER qwen3-coder")
            $lines.Add("PARSER qwen3-coder")
            $lines.Add("PARAMETER temperature 0.7")
            $lines.Add("PARAMETER top_k 20")
            $lines.Add("PARAMETER top_p 0.8")
            $lines.Add("PARAMETER repeat_penalty 1.05")
            $lines.Add('PARAMETER stop "<|im_end|>"')
            $lines.Add('PARAMETER stop "<|im_start|>"')
            $lines.Add('PARAMETER stop "<|endoftext|>"')
        }

        "qwen36" {
            # Qwen 3.5 / 3.6 with the qwen3-coder XML tool format (matches training).
            # Non-thinking, coding-oriented sampling profile. Keep presence
            # penalty off so identifiers, keywords, braces, and import paths
            # can repeat naturally in generated code.
            $lines.Add("RENDERER qwen3-coder")
            $lines.Add("PARSER qwen3-coder")
            $lines.Add("PARAMETER temperature 0.7")
            $lines.Add("PARAMETER top_k 20")
            $lines.Add("PARAMETER top_p 0.8")
            $lines.Add("PARAMETER min_p 0")
            $lines.Add("PARAMETER presence_penalty 0")
            $lines.Add("PARAMETER repeat_penalty 1.05")
            $lines.Add('PARAMETER stop "<|im_end|>"')
            $lines.Add('PARAMETER stop "<|im_start|>"')
        }

        "qwen36-think" {
            # Same renderer/parser as qwen36, with thinking-style sampling
            # (lower temperature, higher top_p) for thinking-trained variants.
            $lines.Add("RENDERER qwen3-coder")
            $lines.Add("PARSER qwen3-coder")
            $lines.Add("PARAMETER temperature 0.6")
            $lines.Add("PARAMETER top_k 20")
            $lines.Add("PARAMETER top_p 0.95")
            $lines.Add('PARAMETER stop "<|im_end|>"')
            $lines.Add('PARAMETER stop "<|im_start|>"')
        }

        default {
            throw "Unknown parser: $Parser"
        }
    }

    return $lines
}

# Strict overlay — applied on top of any base alias via FROM <base>:latest.
# Parser-agnostic: relies on Modelfile inheritance for RENDERER/PARSER/template,
# and only OVERRIDES sampling parameters and SYSTEM. Add new model families to
# Get-ParserLines without touching this — strict keeps working.
#
# num_ctx is intentionally omitted: it's set per-alias by the caller, matching
# the selected base context.
function Get-StrictModelfileLines {
    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add("PARAMETER temperature 0.2")
    $lines.Add("PARAMETER top_p 0.8")
    $lines.Add("PARAMETER top_k 20")
    $lines.Add("PARAMETER min_p 0.05")
    $lines.Add("PARAMETER presence_penalty 0")
    $lines.Add("PARAMETER repeat_penalty 1.15")
    $lines.Add("PARAMETER repeat_last_n 4096")

    $lines.Add('SYSTEM """')
    $lines.Add("You are a strict senior software engineer working inside a real repository.")
    $lines.Add("")
    $lines.Add("Non-negotiable rules:")
    $lines.Add("- Do not create mocks, stubs, fake data, dummy implementations, placeholder services, TODO implementations, temporary bypasses, hardcoded sample responses, or NotImplementedException unless the user explicitly asks for them.")
    $lines.Add("- Do not invent new architecture, new schema fields, new configuration properties, or new abstractions unless they already fit the repository's existing patterns.")
    $lines.Add("- Do not make tests pass by weakening, bypassing, deleting, or faking real behavior.")
    $lines.Add("- Before implementing, search the repository for the real implementation, real dependency, real configuration, and existing architectural pattern.")
    $lines.Add("- Reuse existing architecture and production code paths.")
    $lines.Add("- If the real implementation is missing, blocked, inaccessible, or ambiguous, stop and explain exactly what is missing instead of inventing a substitute.")
    $lines.Add("- Prefer small, verifiable edits.")
    $lines.Add("- After every file edit, summarize the actual file changed and why.")
    $lines.Add("- Before finishing, inspect your own changes for: mock, stub, fake, dummy, sample, todo, placeholder, temporary, hardcoded, NotImplementedException.")
    $lines.Add('"""')

    return $lines
}

function Suggest-LocalLLMParser {
    param([Parameter(Mandatory = $true)][string]$Repo)

    $name = $Repo.ToLowerInvariant()

    if ($name -match 'coder') {
        return 'qwen3coder'
    }

    if ($name -match 'qwen3\.?[56]') {
        if ($name -match 'thinking|reasoning|opus|sonnet|haiku|claude') {
            return 'qwen36-think'
        }
        return 'qwen36'
    }

    return 'none'
}
