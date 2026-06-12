[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param(
    [Parameter(Mandatory = $true)][string]$HostName,
    [Parameter(Mandatory = $true)][string]$UserName,
    [string]$PublicKeyPath,
    [int]$Port = 22,
    [switch]$WipeExistingKeys,
    [switch]$AllowDuplicate
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-FidoPublicKeyPath {
    param([Parameter(Mandatory = $true)][string]$SshDirectory)

    $files = @(Get-ChildItem -Path $SshDirectory -File -Filter "id_*_sk_rk*.pub" -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTimeUtc -Descending)

    if ($files.Count -eq 0) {
        throw "No FIDO2 public key (*.pub) was found in $SshDirectory. Provide -PublicKeyPath explicitly."
    }
    if ($files.Count -eq 1) { return $files[0].FullName }

    # Expected filename forms:
    #   id_ed25519_sk_rk_<thumbprint>
    #   id_ed25519_sk_rk_<label>_<thumbprint>
    # Display the label when present, otherwise the thumbprint.
    $keys = $files | ForEach-Object {
        $parts = [System.IO.Path]::GetFileNameWithoutExtension($_.Name) -split '_'
        $displayValue = if ($parts.Count -ge 6) { $parts[4] } else { $parts[-1] }
        [PSCustomObject]@{ FullName = $_.FullName; DisplayValue = $displayValue }
    }

    Write-Host "Multiple YubiKey FIDO2 public keys were found. Select one:"
    for ($i = 0; $i -lt $keys.Count; $i++) {
        Write-Host ("[{0}] {1}" -f ($i + 1), $keys[$i].DisplayValue)
    }

    while ($true) {
        try { $selectionText = Read-Host "Key number" }
        catch { throw "Interactive key selection is unavailable. Re-run with -PublicKeyPath." }

        $selection = 0
        if ([int]::TryParse($selectionText, [ref]$selection) -and $selection -ge 1 -and $selection -le $keys.Count) {
            return $keys[$selection - 1].FullName
        }
        Write-Warning "Enter a number between 1 and $($keys.Count)."
    }
}

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    throw "ssh was not found. Install the OpenSSH Client Windows feature first."
}

if ([string]::IsNullOrWhiteSpace($PublicKeyPath)) {
    $PublicKeyPath = Resolve-FidoPublicKeyPath -SshDirectory (Join-Path $env:USERPROFILE ".ssh")
}
if (-not (Test-Path -LiteralPath $PublicKeyPath -PathType Leaf)) {
    throw "Public key file was not found: $PublicKeyPath"
}

$keyLine = (Get-Content -LiteralPath $PublicKeyPath -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($keyLine)) {
    throw "Public key file is empty: $PublicKeyPath"
}

if ($WipeExistingKeys) {
    $remoteCommand = @'
mkdir -p ~/.ssh
chmod 700 ~/.ssh
cat > ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
'@
}
elseif ($AllowDuplicate) {
    $remoteCommand = @'
mkdir -p ~/.ssh
chmod 700 ~/.ssh
cat >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
'@
}
else {
    $remoteCommand = @'
mkdir -p ~/.ssh
chmod 700 ~/.ssh
key="$(cat)"
touch ~/.ssh/authorized_keys
if ! grep -qxF "$key" ~/.ssh/authorized_keys 2>/dev/null; then
    printf '%s\n' "$key" >> ~/.ssh/authorized_keys
fi
chmod 600 ~/.ssh/authorized_keys
'@
}

# Ensure Linux shell receives LF line endings; CRLF can break if/then/fi parsing.
$remoteCommand = $remoteCommand -replace "`r`n", "`n"

$target = "$UserName@$HostName"
$sshArgs = @()
if ($Port -ne 22) { $sshArgs += @("-p", $Port) }
$sshArgs += @($target, $remoteCommand)

$actionDescription = "Publish SSH public key from '$PublicKeyPath' to $target"
if ($WipeExistingKeys) { $actionDescription += " (wipe existing authorized_keys first)" }

if ($PSCmdlet.ShouldProcess($target, $actionDescription)) {
    # Send the local public key line on stdin so the remote shell can write it safely.
    $keyLine | & ssh @sshArgs
    if ($LASTEXITCODE -ne 0) { throw "ssh command failed with exit code $LASTEXITCODE." }
}

Write-Host "Key published to $target using $PublicKeyPath"
if ($WipeExistingKeys) {
    Write-Host "Existing remote authorized_keys entries were replaced."
}
else {
    Write-Host "Existing remote authorized_keys entries were preserved."
}

