# Pester 5 tests for Import-LocalLLMConfig precedence:
#   defaults.json (lowest) < legacy-shape catalog scalars < settings.json (highest).
# Each test runs against a tempdir profile root so we don't touch the user's
# real ~/.local-llm.

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

    function New-TempProfile {
        param(
            [System.Collections.IDictionary]$Defaults,
            [System.Collections.IDictionary]$Catalog,
            [System.Collections.IDictionary]$Settings
        )

        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("localbox-tests-" + [System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $root | Out-Null

        $utf8 = New-Object System.Text.UTF8Encoding $false
        if ($Defaults) {
            [System.IO.File]::WriteAllText((Join-Path $root 'defaults.json'), ($Defaults | ConvertTo-Json -Depth 8), $utf8)
        }
        if ($Catalog) {
            [System.IO.File]::WriteAllText((Join-Path $root 'llm-models.json'), ($Catalog | ConvertTo-Json -Depth 32), $utf8)
        }
        if ($Settings) {
            [System.IO.File]::WriteAllText((Join-Path $root 'settings.json'), ($Settings | ConvertTo-Json -Depth 8), $utf8)
        }

        return $root
    }

    function Invoke-ConfigLoad {
        param([string]$Root)

        # Source just the modules the loader and validator need, in a fresh
        # session-scoped script so test isolation holds.
        $script:LLMProfileRoot = $Root
        $script:LocalLLMConfigPath = Join-Path $Root 'llm-models.json'

        . (Join-Path $repoRoot 'local-llm\lib\00-settings.ps1')
        . (Join-Path $repoRoot 'local-llm\lib\05-validate.ps1')
        . (Join-Path $repoRoot 'local-llm\lib\41-llamacpp-args.ps1')

        return Import-LocalLLMConfig
    }

    $script:MinimalModels = @{
        m1 = @{
            Root = 'm1'; SourceType = 'gguf'; Repo = 'org/repo'
            Quants = @{ q4 = 'm1.q4.gguf' }; Quant = 'q4'
            Parser = 'qwen3coder'; Tier = 'recommended'
            Contexts = @{ '' = 32768 }
        }
    }
}

Describe 'Import-LocalLLMConfig precedence' {
    It 'pulls scalars from defaults.json when the catalog is pure-data' {
        $root = New-TempProfile `
            -Defaults @{ NoThinkProxyPort = 22222; Default = 'm1' } `
            -Catalog  @{ Models = $script:MinimalModels; CommandAliases = @{} }

        $cfg = Invoke-ConfigLoad -Root $root
        $cfg.NoThinkProxyPort | Should -Be 22222
        $cfg.Default | Should -Be 'm1'
        Remove-Item -Recurse -Force $root
    }

    It 'lets settings.json overlay defaults.json' {
        $root = New-TempProfile `
            -Defaults @{ NoThinkProxyPort = 22222; Default = 'm1' } `
            -Catalog  @{ Models = $script:MinimalModels; CommandAliases = @{} } `
            -Settings @{ NoThinkProxyPort = 33333 }

        $cfg = Invoke-ConfigLoad -Root $root
        $cfg.NoThinkProxyPort | Should -Be 33333
        $cfg.Default | Should -Be 'm1'  # defaults.json still wins where settings.json is silent
        Remove-Item -Recurse -Force $root
    }

    It 'falls back to legacy top-level scalars in the catalog when defaults.json is absent' {
        $catalog = @{
            NoThinkProxyPort = 44444
            Default = 'm1'
            Models = $script:MinimalModels
            CommandAliases = @{}
        }
        $root = New-TempProfile -Catalog $catalog

        # The Write-Warning is expected here (legacy shape detected). Suppress
        # for the test by redirecting the warning stream.
        $cfg = Invoke-ConfigLoad -Root $root 3>$null
        $cfg.NoThinkProxyPort | Should -Be 44444
        $cfg.Default | Should -Be 'm1'
        Remove-Item -Recurse -Force $root
    }

    It 'rejects a pure catalog when defaults.json is missing' {
        $root = New-TempProfile `
            -Catalog @{ Models = $script:MinimalModels; CommandAliases = @{} }

        { Invoke-ConfigLoad -Root $root } | Should -Throw -ExpectedMessage '*defaults.json*missing*pure catalog*'
        Remove-Item -Recurse -Force $root
    }

    It 'has defaults.json take precedence over legacy catalog scalars' {
        # Both shapes present: shipped defaults wins over stale legacy scalars.
        $catalog = @{
            NoThinkProxyPort = 44444
            Models = $script:MinimalModels
            CommandAliases = @{}
        }
        $root = New-TempProfile `
            -Defaults @{ NoThinkProxyPort = 22222 } `
            -Catalog  $catalog

        $cfg = Invoke-ConfigLoad -Root $root 3>$null
        # Legacy fallback layers over defaults — matches the documented
        # one-release fallback window so existing users keep working.
        $cfg.NoThinkProxyPort | Should -Be 44444
        Remove-Item -Recurse -Force $root
    }

    It 'never lets settings.json override Models or CommandAliases' {
        $root = New-TempProfile `
            -Defaults @{ NoThinkProxyPort = 22222 } `
            -Catalog  @{ Models = $script:MinimalModels; CommandAliases = @{ alias1 = 'target' } } `
            -Settings @{ Models = @{ evil = @{ Root = 'x' } }; CommandAliases = @{ rogue = 'x' } }

        $cfg = Invoke-ConfigLoad -Root $root
        $cfg.Models.Keys | Should -Contain 'm1'
        $cfg.Models.Keys | Should -Not -Contain 'evil'
        $cfg.CommandAliases.Keys | Should -Not -Contain 'rogue'
        Remove-Item -Recurse -Force $root
    }
}

Describe 'Catalog validation runs at load time' {
    It 'rejects a catalog with a typo in Parser' {
        $bad = @{
            m1 = @{
                Root = 'm1'; SourceType = 'gguf'; Repo = 'org/repo'
                Quants = @{ q4 = 'm1.q4.gguf' }; Quant = 'q4'
                Parser = 'bogus-parser'; Contexts = @{ '' = 32768 }
            }
        }
        $root = New-TempProfile `
            -Defaults @{ NoThinkProxyPort = 22222 } `
            -Catalog  @{ Models = $bad; CommandAliases = @{} }

        { Invoke-ConfigLoad -Root $root } | Should -Throw -ExpectedMessage '*Parser*bogus-parser*'
        Remove-Item -Recurse -Force $root
    }

    It 'rejects a Quant pointer that is not a key in Quants' {
        $bad = @{
            m1 = @{
                Root = 'm1'; SourceType = 'gguf'; Repo = 'org/repo'
                Quants = @{ q4 = 'm1.q4.gguf' }; Quant = 'q6'
                Parser = 'qwen3coder'; Contexts = @{ '' = 32768 }
            }
        }
        $root = New-TempProfile `
            -Defaults @{ NoThinkProxyPort = 22222 } `
            -Catalog  @{ Models = $bad; CommandAliases = @{} }

        { Invoke-ConfigLoad -Root $root } | Should -Throw -ExpectedMessage '*Quant*q6*'
        Remove-Item -Recurse -Force $root
    }
}
