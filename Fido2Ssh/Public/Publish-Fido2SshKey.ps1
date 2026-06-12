function Publish-Fido2SshKey {
    <#
    .SYNOPSIS
        Publishes a FIDO2 SSH public key to a Linux host's authorized_keys over SSH.

    .DESCRIPTION
        Connects to the SSH-style `<user>@<host>` destination and writes the
        contents of `-PublicKeyPath` (or an auto-detected `id_*_sk_rk*.pub`
        in `%USERPROFILE%\.ssh`) to `~/.ssh/authorized_keys`. By default the
        key is appended only if it isn't already present.

    .PARAMETER Destination
        SSH-style target in the form `<user>@<host>`, e.g. `azureuser@10.0.0.4`
        or `ubuntu@server.example.com`. The host part may be a DNS name, an
        IPv4 address, or a bracketed IPv6 address (`user@[2001:db8::1]`).

    .PARAMETER PublicKeyPath
        Optional. Specific `.pub` file. If omitted, auto-detects FIDO2 keys
        in `%USERPROFILE%\.ssh` and prompts when multiple match.

    .PARAMETER Port
        SSH port. Defaults to 22.

    .PARAMETER IdentityFile
        Optional. Path to an existing SSH private key to authenticate the
        bootstrap connection with (passed to ssh as `-i`). Useful for
        publishing a new FIDO2 key on a host where you already have another
        key-based login.

    .PARAMETER WipeExistingKeys
        Replace `authorized_keys` with this key only. Lockout risk.

    .PARAMETER AllowDuplicate
        Append even if the key is already present (skip dedupe check).

    .EXAMPLE
        Publish-Fido2SshKey azureuser@server.example.com

    .EXAMPLE
        Publish-Fido2SshKey azureuser@131.123.32.3 -IdentityFile ~/.ssh/id_rsa

    .EXAMPLE
        Publish-Fido2SshKey ubuntu@10.0.0.4 -Port 2222 -WipeExistingKeys
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('Target', 'HostName')]
        [ValidatePattern('^[^@\s]+@.+$')]
        [string]$Destination,
        [string]$PublicKeyPath,
        [int]$Port = 22,
        [Alias('i')]
        [string]$IdentityFile,
        [switch]$WipeExistingKeys,
        [switch]$AllowDuplicate
    )

    # Split <user>@<host>; rsplit on '@' so usernames containing '@' (rare) still work.
    $atIndex = $Destination.LastIndexOf('@')
    $UserName = $Destination.Substring(0, $atIndex)
    $HostName = $Destination.Substring($atIndex + 1)
    if ([string]::IsNullOrWhiteSpace($UserName) -or [string]::IsNullOrWhiteSpace($HostName)) {
        throw "Destination '$Destination' is not in the expected <user>@<host> format."
    }

    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        throw "ssh was not found. Install the OpenSSH Client Windows feature first."
    }

    if ([string]::IsNullOrWhiteSpace($PublicKeyPath)) {
        $PublicKeyPath = Resolve-Fido2PublicKeyPath -SshDirectory (Join-Path $env:USERPROFILE ".ssh")
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
    if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
        $resolvedIdentity = (Resolve-Path -LiteralPath $IdentityFile -ErrorAction SilentlyContinue)
        if (-not $resolvedIdentity) {
            throw "Identity file was not found: $IdentityFile"
        }
        # IdentitiesOnly=yes makes ssh ignore agent / default keys and use this one only.
        $sshArgs += @('-o', 'IdentitiesOnly=yes', '-i', $resolvedIdentity.Path)
    }
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
