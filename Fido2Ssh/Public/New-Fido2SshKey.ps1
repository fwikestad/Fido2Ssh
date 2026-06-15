function New-Fido2SshKey {
    <#
    .SYNOPSIS
        Generates a FIDO2 SSH key on a connected authenticator.

    .DESCRIPTION
        Prompts for an e-mail (used as the key comment) and a label
        (used in the FIDO2 application string), then runs `ssh-keygen`
        to create a new Security Key credential on the authenticator
        (YubiKey or other passkey provider).

        By default the credential is **resident** — stored on the
        authenticator and recoverable with `Import-Fido2SshKey`. The
        resulting files follow the canonical resident layout:

            id_<keytype>_sk_rk_<label>_<thumbprint>
            id_<keytype>_sk_rk_<label>_<thumbprint>.pub

        Pass `-NonResident` to create a **software passkey** instead.
        In this mode the credential is NOT stored on the authenticator;
        only the private key handle file on disk holds the credential.
        Losing that file means the key cannot be recovered. The files
        follow the non-resident layout (no `_rk` segment):

            id_<keytype>_sk_<label>_<thumbprint>
            id_<keytype>_sk_<label>_<thumbprint>.pub

        In both modes the thumbprint is a short slice of the key's
        SHA256 fingerprint, so multiple credentials with the same label
        won't collide.

        By default the credential is created with `-O verify-required`,
        so the authenticator will require its FIDO2 PIN (in addition to
        a touch) every time the key is used. Pass `-NoPin` to omit that
        constraint and require only a touch.

        The private key file is created with an empty passphrase so
        it can be loaded by `ssh-agent` and used by the publish
        cmdlets without further prompting. For resident keys the actual
        private key material stays on the authenticator; the file on
        disk is only a handle. For non-resident keys the key handle
        itself lives in that file — back it up accordingly.

    .PARAMETER Email
        Value placed in the public-key comment field. Prompted for
        when not supplied.

    .PARAMETER Label
        Short label embedded in the FIDO application string
        (`ssh:<label>`) and in the installed filename. Must only
        contain letters, digits, '.' or '-' (no underscores, since
        the filename parser uses '_' as a token boundary). Prompted
        for when not supplied.

    .PARAMETER SshDirectory
        Destination folder. Defaults to `%USERPROFILE%\.ssh` on Windows and
        `$HOME/.ssh` on Linux/macOS.

    .PARAMETER KeyType
        FIDO key algorithm. Defaults to `ed25519-sk`. Use
        `ecdsa-sk` for older authenticators that don't support
        Ed25519.

    .PARAMETER NonResident
        Create a non-resident (software) passkey. The credential
        handle is stored in the private key file on disk rather than
        on the authenticator. The file cannot be re-imported from the
        authenticator if lost — keep a backup.

    .PARAMETER NoPin
        Omit the default `-O verify-required` constraint so the
        authenticator only requires a touch (no FIDO2 PIN) when the
        key is used.

    .PARAMETER Force
        Overwrite an existing key file with the same name.

    .PARAMETER SkipAgent
        Don't try to add the new private key to `ssh-agent`.

    .EXAMPLE
        New-Fido2SshKey

        Prompts for e-mail and label, generates a PIN-protected
        resident Ed25519 FIDO2 SSH key on the authenticator, then
        installs it into the user's .ssh directory.

    .EXAMPLE
        New-Fido2SshKey -Email me@example.com -Label work-laptop -NoPin

        Generates a touch-only resident credential with application
        `ssh:work-laptop` and installs it as
        ~/.ssh/id_ed25519_sk_rk_work-laptop_<thumbprint>(.pub).

    .EXAMPLE
        New-Fido2SshKey -Email me@example.com -Label work-laptop -NonResident

        Generates a PIN-protected non-resident (software) passkey.
        No resident credential is stored on the authenticator. Key
        installed as ~/.ssh/id_ed25519_sk_work-laptop_<thumbprint>(.pub).
        Keep the private key file backed up — it cannot be re-imported
        from the authenticator.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Email,
        [string]$Label,
        [string]$SshDirectory = (Get-Fido2DefaultSshDirectory),
        [ValidateSet('ed25519-sk', 'ecdsa-sk')]
        [string]$KeyType = 'ed25519-sk',
        [switch]$NonResident,
        [switch]$NoPin,
        [switch]$Force,
        [switch]$SkipAgent
    )

    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        throw "ssh-keygen was not found. Install the OpenSSH client (on Windows: the OpenSSH Client capability; on Linux/macOS: the `openssh-client` / `openssh` package)."
    }

    if ([string]::IsNullOrWhiteSpace($Email)) {
        $Email = Read-Host "E-mail (added as the SSH key comment)"
    }
    $Email = $Email.Trim()
    if ([string]::IsNullOrWhiteSpace($Email)) {
        throw "E-mail must not be empty."
    }
    if ($Email -match '["\r\n]') {
        throw "E-mail must not contain quotes or line breaks."
    }

    if ([string]::IsNullOrWhiteSpace($Label)) {
        $Label = Read-Host "Key label (used in the FIDO application string and the installed filename)"
    }
    $Label = $Label.Trim()
    if ($Label -notmatch '^[A-Za-z0-9.-]+$') {
        throw "Label may only contain letters, digits, '.' or '-' (no underscores)."
    }

    $application  = "ssh:$Label"
    $sshKeygenExe = (Get-Command ssh-keygen).Source
    $verifyOption = if ($NoPin) { '' } else { '-O verify-required ' }
    $isResident   = -not $NonResident.IsPresent

    if (-not (Test-Path -LiteralPath $SshDirectory)) {
        New-Item -ItemType Directory -Path $SshDirectory | Out-Null
    }

    # Generate the resident credential on the authenticator into a
    # temp directory; we then rename/move the produced files into
    # $SshDirectory under the canonical layout.
    $tempRoot    = Join-Path ([System.IO.Path]::GetTempPath()) ("fido2-ssh-new-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $tempKeyPath = Join-Path $tempRoot "newkey"
    $tempPubPath = "$tempKeyPath.pub"

    try {
        $shouldProcessDesc = "Generate $( if ($isResident) { 'resident' } else { 'non-resident (software)' } ) FIDO2 SSH key ($KeyType, application=$application" + $(if ($NoPin) { ', touch-only' } else { ', PIN+touch' }) + ")"
        if (-not $PSCmdlet.ShouldProcess("authenticator", $shouldProcessDesc)) {
            return
        }

        if ($NoPin) {
            Write-Host "Touch your authenticator when it starts blinking."
        }
        else {
            Write-Host "Enter your FIDO2 PIN when prompted, then touch your authenticator when it starts blinking."
        }

        # Windows PowerShell 5.1's native-call operator drops bare empty-string
        # arguments, which would cause ssh-keygen to treat "-f" as the
        # passphrase value for `-N ""`. PowerShell 7+ preserves empty args on
        # every platform, so the cmd.exe workaround is only needed on the
        # legacy desktop edition. `-q` silences the chatty
        # "Generating public/private..." / fingerprint / randomart output
        # without hiding the FIDO2 PIN prompt.
        $useCmdShim = ($PSVersionTable.PSEdition -eq 'Desktop')

        if ($useCmdShim) {
            $residentOption = if ($isResident) { '-O resident ' } else { '' }
            $cmdLine = '"{0}" -q -t {1} {2}{3}-O "application={4}" -C "{5}" -N "" -f "{6}"' -f `
                $sshKeygenExe, $KeyType, $residentOption, $verifyOption, $application, $Email, $tempKeyPath
            Write-Verbose "ssh-keygen command (cmd.exe): $cmdLine"
            & cmd.exe /c "`"$cmdLine`""
        }
        else {
            $sshKeygenArgs = @('-q', '-t', $KeyType)
            if ($isResident) { $sshKeygenArgs += @('-O', 'resident') }
            if (-not $NoPin) { $sshKeygenArgs += @('-O', 'verify-required') }
            $sshKeygenArgs += @('-O', "application=$application", '-C', $Email, '-N', '', '-f', $tempKeyPath)
            Write-Verbose ("ssh-keygen args: " + ($sshKeygenArgs -join ' '))
            & $sshKeygenExe @sshKeygenArgs
        }
        if ($LASTEXITCODE -ne 0) {
            throw "ssh-keygen failed with exit code $LASTEXITCODE."
        }
        if (-not (Test-Path -LiteralPath $tempPubPath)) {
            throw "ssh-keygen did not produce expected public key file: $tempPubPath"
        }

        # Derive a short thumbprint from the SHA256 fingerprint so
        # multiple credentials with the same label don't collide, and
        # so that Import-Fido2SshKey can land an extracted copy of
        # this same credential at the exact same filename.
        $thumbprint  = Get-Fido2KeyThumbprint -PublicKeyPath $tempPubPath
        $finalName   = Get-Fido2CanonicalName -KeyType $KeyType -Label $Label -Thumbprint $thumbprint -Resident $isResident
        $destKeyPath = Join-Path $SshDirectory $finalName
        $destPubPath = "$destKeyPath.pub"

        foreach ($existing in @($destKeyPath, $destPubPath)) {
            if ((Test-Path -LiteralPath $existing) -and -not $Force) {
                throw "Destination already exists: $existing. Re-run with -Force to overwrite."
            }
        }

        Move-Item -LiteralPath $tempKeyPath -Destination $destKeyPath -Force:$Force
        Move-Item -LiteralPath $tempPubPath -Destination $destPubPath -Force:$Force

        Write-Host ""
        Write-Host "FIDO2 SSH key installed:"
        Write-Host "  Private: $destKeyPath"
        Write-Host "  Public:  $destPubPath"
        if (-not $isResident) {
            Write-Host ""
            Write-Host "  NOTE: This is a non-resident (software) passkey. The private key handle"
            Write-Host "  is stored ONLY in the file above — not on the authenticator. If you"
            Write-Host "  lose this file the key cannot be recovered. Back it up securely."
        }

        if (-not $SkipAgent -and (Get-Command ssh-add -ErrorAction SilentlyContinue)) {
            & ssh-add $destKeyPath
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "ssh-add failed for $destKeyPath. The key is still installed in $SshDirectory."
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
