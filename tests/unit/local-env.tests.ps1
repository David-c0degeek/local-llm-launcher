BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:LLMProfileRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("localbox-tests-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $script:LLMProfileRoot | Out-Null
    $script:LocalLLMConfigPath = Join-Path $script:LLMProfileRoot 'llm-models.json'
    $script:Cfg = @{ LocalModelMaxOutputTokens = 4096 }
    $script:NoThinkProxyPort = 11435

    . (Join-Path $repoRoot 'local-llm\lib\00-settings.ps1')
    . (Join-Path $repoRoot 'local-llm\lib\65-claude-launch.ps1')
    . (Join-Path $repoRoot 'local-llm\lib\75-display.ps1')

    function Write-LaunchLog { param([string]$Message, [string]$Level) }
}

AfterAll {
    Remove-Item -Recurse -Force $script:LLMProfileRoot -ErrorAction SilentlyContinue
}

Describe 'Local Claude environment' {
    It 'disables beta tool shapes and ToolSearch for local proxy-compatible launches' {
        Set-ClaudeLocalEnv -BaseUrl 'http://localhost:11435' -Model 'local-test'

        $env:CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS | Should -Be '1'
        $env:ENABLE_TOOL_SEARCH | Should -Be 'false'
    }

    It 'restores local-only env vars after launch cleanup' {
        $env:CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS = 'original-beta'
        $env:ENABLE_TOOL_SEARCH = 'auto'
        $env:API_TIMEOUT_MS = '123'
        $env:CLAUDE_CODE_DISABLE_AUTO_MEMORY = '0'

        Save-ClaudeEnvBackup
        Set-ClaudeLocalEnv -BaseUrl 'http://localhost:11435' -Model 'local-test'
        Restore-ClaudeEnvBackup

        $env:CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS | Should -Be 'original-beta'
        $env:ENABLE_TOOL_SEARCH | Should -Be 'auto'
        $env:API_TIMEOUT_MS | Should -Be '123'
        $env:CLAUDE_CODE_DISABLE_AUTO_MEMORY | Should -Be '0'
    }

    It 'shows the beta/tool-search kill switches in dry-run env snapshots' {
        $snapshot = Get-LocalLLMClaudeEnvSnapshot -BaseUrl 'http://localhost:11435' -Model 'local-test'

        $snapshot.CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS | Should -Be '1'
        $snapshot.ENABLE_TOOL_SEARCH | Should -Be 'false'
    }

    It 'does not advertise ToolSearch in inline deferred schemas' {
        $prompt = Get-LocalModelSystemPrompt -IncludeInlineToolSchemas

        $prompt | Should -Not -Match 'ToolSearch'
    }
}
