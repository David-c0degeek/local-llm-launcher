# Pester 5 tests for VRAM math / quant fit (lib/25-vram.ps1).
#
# These functions are pure over their inputs (a model def + the cached VRAM
# value in $script:Cfg), so we fake the cache and feed minimal model defs.

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    . (Join-Path $repoRoot 'local-llm\lib\25-vram.ps1')

    function Set-FakeVRAM {
        param([int]$GB)
        # Set the configured override so Get-LocalLLMVRAMInfo skips nvidia-smi.
        $script:Cfg = @{ VRAMGB = $GB }
        # Bust any cached auto-detect from earlier calls.
        $script:LocalLLMVRAMCache = $null
    }

    function New-FakeDef {
        param([System.Collections.IDictionary]$Quants, [System.Collections.IDictionary]$QuantSizesGB)
        return @{
            Quants       = $Quants
            QuantSizesGB = $QuantSizesGB
        }
    }
}

Describe 'Get-QuantSizeGB' {
    BeforeAll { Set-FakeVRAM -GB 24 }

    It 'returns the size for a known quant key' {
        $def = New-FakeDef -Quants @{ q4 = 'a.gguf' } -QuantSizesGB @{ q4 = 18.5 }
        Get-QuantSizeGB -Def $def -QuantKey 'q4' | Should -Be 18.5
    }

    It 'is case-insensitive on the quant key' {
        $def = New-FakeDef -Quants @{ Q4 = 'a.gguf' } -QuantSizesGB @{ Q4 = 18.5 }
        Get-QuantSizeGB -Def $def -QuantKey 'q4' | Should -Be 18.5
    }

    It 'returns $null when QuantSizesGB is missing' {
        $def = @{ Quants = @{ q4 = 'a.gguf' } }
        Get-QuantSizeGB -Def $def -QuantKey 'q4' | Should -BeNullOrEmpty
    }

    It 'returns $null when the quant key is empty' {
        $def = New-FakeDef -Quants @{ q4 = 'a.gguf' } -QuantSizesGB @{ q4 = 18.5 }
        Get-QuantSizeGB -Def $def -QuantKey '' | Should -BeNullOrEmpty
    }
}

Describe 'Get-QuantFitClass' {
    Context '24 GB host (typical 4090)' {
        BeforeAll { Set-FakeVRAM -GB 24 }

        It 'classifies as fits when size leaves >= 7 GB headroom' {
            $def = New-FakeDef -Quants @{ q4 = 'a.gguf' } -QuantSizesGB @{ q4 = 17.0 }
            Get-QuantFitClass -Def $def -QuantKey 'q4' | Should -Be 'fits'
        }

        It 'classifies as tight when headroom is between 2 and 7 GB' {
            $def = New-FakeDef -Quants @{ q4 = 'a.gguf' } -QuantSizesGB @{ q4 = 21.0 }
            Get-QuantFitClass -Def $def -QuantKey 'q4' | Should -Be 'tight'
        }

        It 'classifies as over when weights alone exceed VRAM - 2 GB' {
            $def = New-FakeDef -Quants @{ q4 = 'a.gguf' } -QuantSizesGB @{ q4 = 30.0 }
            Get-QuantFitClass -Def $def -QuantKey 'q4' | Should -Be 'over'
        }

        It 'returns empty string when size is unknown' {
            $def = @{ Quants = @{ q4 = 'a.gguf' } }
            Get-QuantFitClass -Def $def -QuantKey 'q4' | Should -BeExactly ''
        }
    }

    Context '48 GB host' {
        BeforeAll { Set-FakeVRAM -GB 48 }

        It 'puts a 30 GB quant into the fits bucket' {
            $def = New-FakeDef -Quants @{ q4 = 'a.gguf' } -QuantSizesGB @{ q4 = 30.0 }
            Get-QuantFitClass -Def $def -QuantKey 'q4' | Should -Be 'fits'
        }
    }
}

Describe 'Get-Q8KvMaxContext' {
    It 'honors the explicit Q8KvMaxContext override' {
        $script:Cfg = @{ Q8KvMaxContext = 200000 }
        $script:LocalLLMVRAMCache = @{ GB = 24; Source = 'configured' }
        Get-Q8KvMaxContext | Should -Be 200000
    }

    It 'floors at 64k when VRAM is at or below 16 GB' {
        Set-FakeVRAM -GB 16
        Get-Q8KvMaxContext | Should -Be 65536
    }

    It 'scales with VRAM above 16 GB' {
        Set-FakeVRAM -GB 24
        # (24 - 16) * 16384 = 131072
        Get-Q8KvMaxContext | Should -Be 131072
    }

    It 'returns a much higher ceiling on a 48 GB card' {
        Set-FakeVRAM -GB 48
        # (48 - 16) * 16384 = 524288
        Get-Q8KvMaxContext | Should -Be 524288
    }
}
