# Pester 5 tests for parser-driven Modelfile fragments (lib/40-parsers.ps1).
# The Modelfile that ends up on disk is FROM + (Get-ParserLines) + optional
# `PARAMETER num_ctx N`, so locking down Get-ParserLines locks down the
# Modelfile shape modulo I/O.

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    . (Join-Path $repoRoot 'local-llm\lib\40-parsers.ps1')
}

Describe 'Get-ParserLines' {
    It 'returns an empty list for parser=none' {
        $lines = @(Get-ParserLines -Parser 'none')
        $lines.Count | Should -Be 0
    }

    It 'emits the qwen3-coder RENDERER/PARSER pair for qwen3coder' {
        $lines = @(Get-ParserLines -Parser 'qwen3coder')
        $lines | Should -Contain 'RENDERER qwen3-coder'
        $lines | Should -Contain 'PARSER qwen3-coder'
    }

    It 'pins qwen3coder sampling parameters' {
        $lines = @(Get-ParserLines -Parser 'qwen3coder')
        $lines | Should -Contain 'PARAMETER temperature 0.7'
        $lines | Should -Contain 'PARAMETER top_k 20'
        $lines | Should -Contain 'PARAMETER top_p 0.8'
        $lines | Should -Contain 'PARAMETER repeat_penalty 1.05'
    }

    It 'includes the qwen3coder stop-token triad' {
        $lines = @(Get-ParserLines -Parser 'qwen3coder')
        $lines | Should -Contain 'PARAMETER stop "<|im_end|>"'
        $lines | Should -Contain 'PARAMETER stop "<|im_start|>"'
        $lines | Should -Contain 'PARAMETER stop "<|endoftext|>"'
    }

    It 'distinguishes qwen36 from qwen36-think on temperature/top_p' {
        $qwen36     = @(Get-ParserLines -Parser 'qwen36')
        $qwen36Think = @(Get-ParserLines -Parser 'qwen36-think')

        $qwen36      | Should -Contain 'PARAMETER temperature 0.7'
        $qwen36      | Should -Contain 'PARAMETER top_p 0.8'

        $qwen36Think | Should -Contain 'PARAMETER temperature 0.6'
        $qwen36Think | Should -Contain 'PARAMETER top_p 0.95'
    }

    It 'qwen36 carries presence/min_p but qwen36-think does not' {
        $qwen36     = @(Get-ParserLines -Parser 'qwen36')
        $qwen36Think = @(Get-ParserLines -Parser 'qwen36-think')

        $qwen36      | Should -Contain 'PARAMETER min_p 0'
        $qwen36      | Should -Contain 'PARAMETER presence_penalty 0'

        $qwen36Think | Should -Not -Contain 'PARAMETER min_p 0'
        $qwen36Think | Should -Not -Contain 'PARAMETER presence_penalty 0'
    }

    It 'throws on an unknown parser name' {
        { Get-ParserLines -Parser 'totally-fake-parser' } | Should -Throw -ExpectedMessage '*Unknown parser*'
    }

    It 'is deterministic: two calls produce the same line list' {
        $a = @(Get-ParserLines -Parser 'qwen3coder')
        $b = @(Get-ParserLines -Parser 'qwen3coder')
        ($a -join "`n") | Should -BeExactly ($b -join "`n")
    }
}
