function Install-YubikeyFidoSshKey {
    <#
    .SYNOPSIS
        Downloads resident FIDO2 SSH keys from a YubiKey into the local SSH directory.

    .DESCRIPTION
        Runs `ssh-keygen -K` to extract every resident SSH key from a connected
        FIDO2 authenticator and moves the resulting key files into `-SshDirectory`
        (default `%USERPROFILE%\.ssh`). Optionally loads the private keys into
        `ssh-agent`.

    .PARAMETER SshDirectory
        Destination folder. Defaults to `%USERPROFILE%\.ssh`.

    .PARAMETER Force
        Overwrite existing key files with the same name.

    .PARAMETER SkipAgent
        Don't start `ssh-agent` and don't run `ssh-add`.

    .EXAMPLE
        Install-YubikeyFidoSshKey

    .EXAMPLE
        Install-YubikeyFidoSshKey -SshDirectory C:\keys -Force -SkipAgent
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$SshDirectory = (Join-Path $env:USERPROFILE ".ssh"),
        [switch]$Force,
        [switch]$SkipAgent
    )

    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        throw "ssh-keygen was not found. Install the OpenSSH Client Windows feature first."
    }

    if (-not (Test-Path -LiteralPath $SshDirectory)) {
        New-Item -ItemType Directory -Path $SshDirectory | Out-Null
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("yubikey-fido-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null

    $installedPrivateKeys = @()
    $skippedFiles         = @()

    try {
        Push-Location $tempRoot

        Write-Host "Touch your YubiKey if prompted. Downloading resident FIDO SSH keys..."
        & ssh-keygen -K -N ''
        if ($LASTEXITCODE -ne 0) {
            throw "ssh-keygen -K failed with exit code $LASTEXITCODE."
        }

        $extracted = @(Get-ChildItem -Path $tempRoot -File)
        if (-not ($extracted | Where-Object { $_.Extension -ne ".pub" })) {
            throw "No resident FIDO SSH keys were downloaded from the authenticator."
        }

        foreach ($file in $extracted) {
            $destination = Join-Path $SshDirectory $file.Name
            if ((Test-Path -LiteralPath $destination) -and -not $Force) {
                Write-Verbose "Skipping existing file: $destination. Re-run with -Force to overwrite it."
                $skippedFiles += $destination
                continue
            }
            if ($PSCmdlet.ShouldProcess($destination, "Install extracted key file")) {
                Move-Item -LiteralPath $file.FullName -Destination $destination -Force:$Force
                if ($file.Extension -ne ".pub") { $installedPrivateKeys += $destination }
            }
        }
    }
    finally {
        Pop-Location
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not $SkipAgent) {
        $service = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
        if (-not $service) {
            Write-Warning "ssh-agent service is not available on this machine. Keys installed to disk only."
        }
        else {
            if ($service.StartType -eq "Disabled") {
                try { Set-Service -Name ssh-agent -StartupType Manual }
                catch { Write-Warning "Unable to enable ssh-agent startup type. Run from an elevated session for agent loading." }
            }
            if ((Get-Service ssh-agent).Status -ne "Running") {
                try { Start-Service ssh-agent }
                catch { Write-Warning "Unable to start ssh-agent. Run from an elevated session for agent loading." }
            }

            if (-not (Get-Command ssh-add -ErrorAction SilentlyContinue)) {
                Write-Warning "ssh-add was not found. Keys installed to disk but not loaded into ssh-agent."
            }
            else {
                foreach ($keyPath in $installedPrivateKeys) {
                    Write-Host "Adding $keyPath to ssh-agent..."
                    & ssh-add $keyPath
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warning "ssh-add failed for $keyPath. The key is still installed in $SshDirectory."
                    }
                }
            }
        }
    }

    Write-Host "Installed $($installedPrivateKeys.Count) resident FIDO SSH key(s) to $SshDirectory."
    if ($skippedFiles.Count -gt 0) {
        Write-Host "Skipped $($skippedFiles.Count) existing file(s). Re-run with -Force to overwrite them."
    }
    Write-Host "Use the corresponding .pub file(s) from $SshDirectory on remote hosts."
}
