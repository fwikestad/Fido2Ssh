[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SshDirectory = (Join-Path $env:USERPROFILE ".ssh"),
    [switch]$Force,
    [switch]$SkipAgent
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    throw "ssh-keygen was not found. Install the OpenSSH Client Windows feature first."
}

if (-not (Test-Path -LiteralPath $SshDirectory)) {
    New-Item -ItemType Directory -Path $SshDirectory | Out-Null
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("yubikey-fido-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

$installedPrivateKeys = @()

try {
    Push-Location $tempRoot

    Write-Host "Touch your YubiKey if prompted. Downloading resident FIDO SSH keys..."
    & ssh-keygen -K
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
            throw "Destination file already exists: $destination. Re-run with -Force to overwrite it."
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
Write-Host "Use the corresponding .pub file(s) from $SshDirectory on remote hosts."
