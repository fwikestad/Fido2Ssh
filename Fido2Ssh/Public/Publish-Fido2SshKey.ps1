function Publish-YubikeyFidoSshKey {
    <#
    .SYNOPSIS
        Publishes a FIDO2 SSH public key to a Linux host's authorized_keys over SSH.

    .DESCRIPTION
        Connects to `-UserName`@`-HostName` over SSH and writes the contents
        of `-PublicKeyPath` (or an auto-detected `id_*_sk_rk*.pub` in
        `%USERPROFILE%\.ssh`) to `~/.ssh/authorized_keys`. By default the key
        is appended only if it isn't already present.

    .PARAMETER HostName
        DNS name or IP of the target host.

    .PARAMETER UserName
        Linux user whose `authorized_keys` to update.

    .PARAMETER PublicKeyPath
        Optional. Specific `.pub` file. If omitted, auto-detects FIDO2 keys
        in `%USERPROFILE%\.ssh` and prompts when multiple match.

    .PARAMETER Port
        SSH port. Defaults to 22.

    .PARAMETER WipeExistingKeys
        Replace `authorized_keys` with this key only. Lockout risk.

    .PARAMETER AllowDuplicate
        Append even if the key is already present (skip dedupe check).

    .EXAMPLE
        Publish-YubikeyFidoSshKey -HostName server.example.com -UserName azureuser
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][string]$UserName,
        [string]$PublicKeyPath,
        [int]$Port = 22,
        [switch]$WipeExistingKeys,
        [switch]$AllowDuplicate
    )

    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        throw "ssh was not found. Install the OpenSSH Client Windows feature first."
    }

    if ([string]::IsNullOrWhiteSpace($PublicKeyPath)) {
        $PublicKeyPath = Resolve-YubikeyFidoPublicKeyPath -SshDirectory (Join-Path $env:USERPROFILE ".ssh")
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
}
