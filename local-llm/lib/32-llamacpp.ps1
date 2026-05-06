# llama-server lifecycle: start (native + docker), stop, health probe, port
# selection, and the script-scoped session state read by the dashboard.

# Tracks one running llama-server at a time. Cleared by Stop-LlamaServer.
$script:CurrentBackendSession = $null

function Get-CurrentBackendSession {
    return $script:CurrentBackendSession
}

function Set-CurrentBackendSession {
    param([Parameter(Mandatory = $true)][hashtable]$Session)
    $script:CurrentBackendSession = $Session
}

function Clear-CurrentBackendSession {
    $script:CurrentBackendSession = $null
}

function New-LlamaServerLogPaths {
    $dir = Join-Path $HOME ".local-llm\logs"
    Ensure-Directory $dir

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    return @{
        Out = Join-Path $dir "llama-server-$stamp.out.log"
        Err = Join-Path $dir "llama-server-$stamp.err.log"
    }
}

function Get-LlamaServerLogTail {
    param(
        [string]$OutLogPath,
        [string]$ErrLogPath,
        [int]$Lines = 40
    )

    $chunks = @()

    foreach ($entry in @(
            @{ Label = "stderr"; Path = $ErrLogPath },
            @{ Label = "stdout"; Path = $OutLogPath }
        )) {
        $path = $entry.Path
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
            continue
        }

        $tail = @(Get-Content -LiteralPath $path -Tail $Lines -ErrorAction SilentlyContinue)
        if ($tail.Count -gt 0) {
            $chunks += "---- $($entry.Label): $path ----"
            $chunks += $tail
        }
    }

    return ($chunks -join "`n")
}

function Test-LlamaCppPortFree {
    param([Parameter(Mandatory = $true)][int]$Port)

    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($listener) {
            try { $listener.Stop() } catch {}
        }
    }
}

function Find-LlamaCppFreePort {
    param([int]$StartPort = 8080, [int]$Span = 20)

    for ($p = $StartPort; $p -lt ($StartPort + $Span); $p++) {
        if (Test-LlamaCppPortFree -Port $p) {
            return $p
        }
    }

    throw "No free port found in range $StartPort..$($StartPort + $Span - 1) for llama-server."
}

function Wait-LlamaServer {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutSec,
        [System.Diagnostics.Process]$Process,
        [string]$OutLogPath,
        [string]$ErrLogPath
    )

    if ($TimeoutSec -le 0) {
        $TimeoutSec = if ($script:Cfg.Contains('LlamaCppHealthCheckTimeoutSec')) { [int]$script:Cfg.LlamaCppHealthCheckTimeoutSec } else { 300 }
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $progressShownAt = $null
    $start = Get-Date

    while ((Get-Date) -lt $deadline) {
        if ($Process) {
            try { $Process.Refresh() } catch {}
            if ($Process.HasExited) {
                if ($progressShownAt) { Write-Host "" }

                $tail = Get-LlamaServerLogTail -OutLogPath $OutLogPath -ErrLogPath $ErrLogPath
                $logHint = if ($OutLogPath -or $ErrLogPath) { " Logs: $OutLogPath / $ErrLogPath." } else { "" }
                $message = "llama-server exited before becoming healthy (exit code $($Process.ExitCode)).$logHint"
                if (-not [string]::IsNullOrWhiteSpace($tail)) {
                    $message += "`n$tail"
                }
                throw $message
            }
        }

        try {
            Invoke-WebRequest -Uri "http://127.0.0.1:$Port/v1/models" -UseBasicParsing -TimeoutSec 2 | Out-Null
            if ($progressShownAt) { Write-Host "" }
            return
        }
        catch {
            $elapsed = (Get-Date) - $start
            if ($elapsed.TotalSeconds -ge 5) {
                if (-not $progressShownAt) {
                    Write-Host -NoNewline "Waiting for llama-server" -ForegroundColor DarkGray
                    $progressShownAt = Get-Date
                }
                elseif (((Get-Date) - $progressShownAt).TotalSeconds -ge 2) {
                    Write-Host -NoNewline "." -ForegroundColor DarkGray
                    $progressShownAt = Get-Date
                }
            }
            Start-Sleep -Milliseconds 500
        }
    }

    if ($progressShownAt) { Write-Host "" }

    $tail = Get-LlamaServerLogTail -OutLogPath $OutLogPath -ErrLogPath $ErrLogPath
    $message = "llama-server did not come up within ${TimeoutSec}s on port $Port."
    if ($OutLogPath -or $ErrLogPath) {
        $message += " Logs: $OutLogPath / $ErrLogPath."
    }
    if (-not [string]::IsNullOrWhiteSpace($tail)) {
        $message += "`n$tail"
    }
    throw $message
}

function Start-LlamaServerNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServerPath,
        [Parameter(Mandatory = $true)][string[]]$ServerArgs,
        [string]$OutLogPath,
        [string]$ErrLogPath
    )

    $startArgs = @{
        FilePath      = $ServerPath
        ArgumentList  = $ServerArgs
        PassThru      = $true
        WindowStyle   = 'Hidden'
        ErrorAction   = 'Stop'
    }

    if (-not [string]::IsNullOrWhiteSpace($OutLogPath)) {
        $startArgs.RedirectStandardOutput = $OutLogPath
    }
    if (-not [string]::IsNullOrWhiteSpace($ErrLogPath)) {
        $startArgs.RedirectStandardError = $ErrLogPath
    }

    $proc = Start-Process @startArgs
    return $proc
}

function Stop-LlamaServer {
    [CmdletBinding()]
    param([switch]$Quiet)

    $session = Get-CurrentBackendSession
    if (-not $session) { return }

    try {
        if ($session.Pid) {
            $p = Get-Process -Id $session.Pid -ErrorAction SilentlyContinue
            if ($p -and -not $p.HasExited) {
                if (-not $Quiet) { Write-Host "Stopping llama-server (pid $($session.Pid))..." -ForegroundColor DarkGray }
                Stop-Process -Id $session.Pid -Force -ErrorAction SilentlyContinue
            }
        }
    }
    finally {
        Clear-CurrentBackendSession
    }
}

function Stop-AllLlamaServers {
    # Reap every llama-server.exe process — useful when a previous shell
    # crashed without running its `finally` cleanup, leaving the GPU pinned.
    # Includes the tracked session, so you don't need to call Stop-LlamaServer
    # first.
    [CmdletBinding()]
    param([switch]$Quiet)

    $procs = Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue
    if (-not $procs) {
        if (-not $Quiet) { Write-Host "No llama-server processes running." -ForegroundColor DarkGray }
        Clear-CurrentBackendSession
        return
    }

    foreach ($p in $procs) {
        if (-not $Quiet) { Write-Host "Stopping llama-server (pid $($p.Id))..." -ForegroundColor DarkGray }
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }

    Clear-CurrentBackendSession
}

function Get-LlamaServerStatus {
    $session = Get-CurrentBackendSession
    if (-not $session) {
        Write-Host "No llama-server session active." -ForegroundColor DarkGray
        return
    }

    Write-Host "Backend  : $($session.Backend) ($($session.Mode))" -ForegroundColor Cyan
    Write-Host "Port     : $($session.Port)" -ForegroundColor DarkGray
    Write-Host "Base URL : $($session.BaseUrl)" -ForegroundColor DarkGray
    if ($session.Pid)      { Write-Host "PID      : $($session.Pid)" -ForegroundColor DarkGray }
    if ($session.Model)    { Write-Host "Model    : $($session.Model)" -ForegroundColor DarkGray }
    if ($session.GgufPath) { Write-Host "GGUF     : $($session.GgufPath)" -ForegroundColor DarkGray }
}
