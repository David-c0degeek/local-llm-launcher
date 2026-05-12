# Generic filesystem / console / HuggingFace download primitives shared by
# everything else. No dependencies on the catalog or model defs.

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Convert-ToPosixPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return ($Path -replace '\\', '/')
}

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Title)

    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Pause-Menu {
    Read-Host "Press Enter to continue" | Out-Null
}

function Resolve-HuggingFaceLocalPath {
    param(
        [Parameter(Mandatory = $true)][string]$DestinationFolder,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $normalizedFileName = ($FileName -replace '\\', '/')
    $localRelativePath = ($normalizedFileName -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    return Join-Path $DestinationFolder $localRelativePath
}

function Convert-HuggingFaceFileNameToUrlPath {
    param([Parameter(Mandatory = $true)][string]$FileName)

    $normalizedFileName = ($FileName -replace '\\', '/')

    return (($normalizedFileName -split '/') | ForEach-Object {
            [System.Uri]::EscapeDataString($_)
        }) -join '/'
}

function Download-HuggingFaceFile {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$DestinationFolder
    )

    Ensure-Directory $DestinationFolder

    $normalizedFileName = ($FileName -replace '\\', '/')
    $destinationFile = Resolve-HuggingFaceLocalPath -DestinationFolder $DestinationFolder -FileName $normalizedFileName
    $destinationParent = Split-Path -Parent $destinationFile

    Ensure-Directory $destinationParent

    if (Test-Path $destinationFile) {
        Write-Host "Using existing file: $destinationFile" -ForegroundColor Green
        return $destinationFile
    }

    $downloaders = @()

    if (Get-Command uvx -ErrorAction SilentlyContinue) {
        $downloaders += "uvx-hf"
    }

    # hf/huggingface-cli are intentionally disabled because broken local Python
    # environments commonly fail on Windows. uvx or direct download is safer.
    $downloaders += "direct"

    foreach ($downloader in $downloaders) {
        Write-Host "Downloading $normalizedFileName using $downloader..." -ForegroundColor Cyan

        try {
            switch ($downloader) {
                "uvx-hf" {
                    $oldPythonUtf8 = $env:PYTHONUTF8
                    $oldPythonIoEncoding = $env:PYTHONIOENCODING
                    $oldHfSsl = $env:HF_HUB_DISABLE_SSL_VERIFICATION

                    try {
                        $env:PYTHONUTF8 = "1"
                        $env:PYTHONIOENCODING = "utf-8"
                        $env:HF_HUB_DISABLE_SSL_VERIFICATION = "1"

                        & uvx hf download $Repo $normalizedFileName --local-dir $DestinationFolder | Out-Host

                        if (Test-Path $destinationFile) {
                            Write-Host "Download completed: $destinationFile" -ForegroundColor Green
                            return $destinationFile
                        }

                        if ($LASTEXITCODE -ne 0) {
                            throw "uvx hf download failed with exit code $LASTEXITCODE"
                        }
                    }
                    finally {
                        if ($null -ne $oldPythonUtf8) {
                            $env:PYTHONUTF8 = $oldPythonUtf8
                        }
                        else {
                            Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue
                        }

                        if ($null -ne $oldPythonIoEncoding) {
                            $env:PYTHONIOENCODING = $oldPythonIoEncoding
                        }
                        else {
                            Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
                        }

                        if ($null -ne $oldHfSsl) {
                            $env:HF_HUB_DISABLE_SSL_VERIFICATION = $oldHfSsl
                        }
                        else {
                            Remove-Item Env:HF_HUB_DISABLE_SSL_VERIFICATION -ErrorAction SilentlyContinue
                        }
                    }
                }

                "direct" {
                    $urlFileName = Convert-HuggingFaceFileNameToUrlPath -FileName $normalizedFileName
                    $url = "https://huggingface.co/$Repo/resolve/main/$urlFileName"
                    $partialFile = "$destinationFile.partial"

                    $existingBytes = 0L

                    if (Test-Path $partialFile) {
                        $existingBytes = (Get-Item $partialFile).Length
                        Write-Host "Resuming from $([math]::Round($existingBytes / 1MB, 1)) MB at $partialFile" -ForegroundColor DarkCyan
                    }

                    Ensure-Directory $destinationParent

                    $oldProgress = $global:ProgressPreference
                    $global:ProgressPreference = 'SilentlyContinue'

                    try {
                        $request = [System.Net.HttpWebRequest]::Create($url)
                        $request.Method = "GET"
                        $request.AllowAutoRedirect = $true
                        $request.UserAgent = "LocalLLMProfile/1.0"
                        $request.ServerCertificateValidationCallback = { $true }

                        if ($existingBytes -gt 0) {
                            $request.AddRange($existingBytes)
                        }

                        $response = $null

                        try {
                            $response = $request.GetResponse()
                        }
                        catch [System.Net.WebException] {
                            # 416 Requested Range Not Satisfiable means the partial is already
                            # the full size; treat that as completion.
                            $errResponse = $_.Exception.Response

                            if ($errResponse -and [int]$errResponse.StatusCode -eq 416) {
                                Write-Host "Server reports already complete; finalizing." -ForegroundColor DarkCyan
                                Move-Item -Path $partialFile -Destination $destinationFile -Force
                                break
                            }

                            throw
                        }

                        try {
                            $appendMode = ($existingBytes -gt 0 -and [int]$response.StatusCode -eq 206)

                            if (-not $appendMode -and (Test-Path $partialFile)) {
                                Remove-Item $partialFile -Force -ErrorAction SilentlyContinue
                            }

                            $fileMode = if ($appendMode) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
                            $output = [System.IO.File]::Open($partialFile, $fileMode, [System.IO.FileAccess]::Write)

                            try {
                                $stream = $response.GetResponseStream()
                                $buffer = New-Object byte[] 1048576
                                $totalRead = $existingBytes
                                $expectedTotal = $existingBytes + [int64]$response.ContentLength
                                $lastReport = Get-Date

                                while ($true) {
                                    $read = $stream.Read($buffer, 0, $buffer.Length)
                                    if ($read -le 0) { break }
                                    $output.Write($buffer, 0, $read)
                                    $totalRead += $read

                                    if (((Get-Date) - $lastReport).TotalSeconds -ge 5) {
                                        $mb = [math]::Round($totalRead / 1MB, 1)
                                        $totalMb = if ($expectedTotal -gt 0) { [math]::Round($expectedTotal / 1MB, 1) } else { "?" }
                                        Write-Host "  ... $mb / $totalMb MB" -ForegroundColor DarkGray
                                        $lastReport = Get-Date
                                    }
                                }
                            }
                            finally {
                                $output.Close()
                            }
                        }
                        finally {
                            if ($response) { $response.Close() }
                        }
                    }
                    finally {
                        $global:ProgressPreference = $oldProgress
                    }

                    if (Test-Path $partialFile) {
                        Move-Item -Path $partialFile -Destination $destinationFile -Force
                    }
                }
            }

            if (Test-Path $destinationFile) {
                Write-Host "Download completed: $destinationFile" -ForegroundColor Green
                return $destinationFile
            }

            Write-Warning "$downloader completed but file was not found: $destinationFile"
        }
        catch {
            Write-Warning "$downloader failed: $($_.Exception.Message)"
            continue
        }
    }

    throw "All download methods failed for $Repo / $normalizedFileName"
}
