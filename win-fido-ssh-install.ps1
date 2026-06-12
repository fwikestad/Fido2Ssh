[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SshDirectory = (Join-Path $env:USERPROFILE ".ssh"),
    [switch]$Force,
    [switch]$SkipAgent
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Test-Command {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return $null -ne (Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Ensure-SshAgent {
    if ($SkipAgent) {
        Write-Verbose "Skipping ssh-agent setup."
        return
    }

    $service = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Warning "ssh-agent service is not available on this machine. Keys will still be installed to disk."
        return
    }

    if ($service.StartType -eq "Disabled") {
        try {
            Set-Service -Name ssh-agent -StartupType Manual
        }
        catch {
            Write-Warning "Unable to change ssh-agent startup type. Run this script from an elevated PowerShell session if you want agent loading."
        }
    }

    $service.Refresh()
    if ($service.Status -ne "Running") {
        try {
            Start-Service -Name ssh-agent
        }
        catch {
            Write-Warning "Unable to start ssh-agent. Run this script from an elevated PowerShell session if you want agent loading."
        }
    }
}

if (-not (Test-Command -Name "ssh-keygen")) {
    throw "ssh-keygen was not found. Install the OpenSSH Client Windows feature first."
}

if (-not (Test-Path -LiteralPath $SshDirectory)) {
    New-Item -ItemType Directory -Path $SshDirectory | Out-Null
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("yubikey-fido-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

$downloadedPrivateKeys = @()

try {
    Push-Location $tempRoot

    Write-Host "Touch your YubiKey if prompted. Downloading resident FIDO SSH keys..."
    & ssh-keygen -K
    if ($LASTEXITCODE -ne 0) {
        throw "ssh-keygen -K failed with exit code $LASTEXITCODE."
    }

    $downloadedPrivateKeys = @(Get-ChildItem -Path $tempRoot -File |
        Where-Object { $_.Extension -ne ".pub" })

    if ($downloadedPrivateKeys.Count -eq 0) {
        throw "No resident FIDO SSH keys were downloaded from the authenticator."
    }

    foreach ($privateKey in $downloadedPrivateKeys) {
        $relatedFiles = @($privateKey)
        $publicKeyPath = "$($privateKey.FullName).pub"

        if (Test-Path -LiteralPath $publicKeyPath) {
            $relatedFiles += Get-Item -LiteralPath $publicKeyPath
        }

        foreach ($file in $relatedFiles) {
            $destinationPath = Join-Path $SshDirectory $file.Name

            if ((Test-Path -LiteralPath $destinationPath) -and -not $Force) {
                throw "Destination file already exists: $destinationPath. Re-run with -Force to overwrite it."
            }

            if ($PSCmdlet.ShouldProcess($destinationPath, "Install extracted key file")) {
                Move-Item -LiteralPath $file.FullName -Destination $destinationPath -Force:$Force
            }
        }
    }
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Ensure-SshAgent

if (-not $SkipAgent) {
    if (-not (Test-Command -Name "ssh-add")) {
        Write-Warning "ssh-add was not found. Keys were installed to disk but not loaded into ssh-agent."
    }
    else {
        foreach ($privateKey in $downloadedPrivateKeys) {
            $installedPath = Join-Path $SshDirectory $privateKey.Name
            Write-Host "Adding $installedPath to ssh-agent..."
            & ssh-add $installedPath
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "ssh-add failed for $installedPath. The key is still installed in $SshDirectory."
            }
        }
    }
}

Write-Host "Installed $($downloadedPrivateKeys.Count) resident FIDO SSH key(s) to $SshDirectory."
Write-Host "Use the corresponding .pub file(s) from $SshDirectory on remote hosts."