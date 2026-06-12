function New-Fido2SshKey {
    <#
    .SYNOPSIS
        Generates a resident FIDO2 SSH key on a connected authenticator.

    .DESCRIPTION
        Prompts for an e-mail (used as the key comment) and a label
        (used in the FIDO2 application string), then runs `ssh-keygen`
        to create a new resident Security Key credential on the
        authenticator (YubiKey or other passkey provider). The
        resulting key files are renamed into the canonical filename
        layout that the rest of this module expects and moved into
        `-SshDirectory` (default `%USERPROFILE%\.ssh`):

            id_<keytype>_sk_rk_<label>_<thumbprint>
            id_<keytype>_sk_rk_<label>_<thumbprint>.pub

        The thumbprint is a short slice of the key's SHA256
        fingerprint, so multiple credentials with the same label
        won't collide.

        By default the credential is created with `-O verify-required`,
        so the authenticator will require its FIDO2 PIN (in addition to
        a touch) every time the key is used. Pass `-NoPin` to omit that
        constraint and require only a touch.

        The private key file is created with an empty passphrase so
        it can be loaded by `ssh-agent` and used by the publish
        cmdlets without further prompting. The actual private key
        material stays on the authenticator; the file on disk is only
        a handle to the resident credential.

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
        Destination folder. Defaults to `%USERPROFILE%\.ssh`.

    .PARAMETER KeyType
        FIDO key algorithm. Defaults to `ed25519-sk`. Use
        `ecdsa-sk` for older authenticators that don't support
        Ed25519.

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

        Generates a touch-only credential with application
        `ssh:work-laptop` and installs it as
        ~/.ssh/id_ed25519_sk_rk_work-laptop_<thumbprint>(.pub).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Email,
        [string]$Label,
        [string]$SshDirectory = (Join-Path $env:USERPROFILE ".ssh"),
        [ValidateSet('ed25519-sk', 'ecdsa-sk')]
        [string]$KeyType = 'ed25519-sk',
        [switch]$NoPin,
        [switch]$Force,
        [switch]$SkipAgent
    )

    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        throw "ssh-keygen was not found. Install the OpenSSH Client Windows feature first."
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
        # Build a single command line and run it via cmd.exe so the
        # empty-passphrase argument (-N "") is preserved verbatim.
        # Windows PowerShell 5.1's native-call operator drops bare
        # empty-string arguments, which would cause ssh-keygen to treat
        # "-f" as the passphrase value. `-q` silences the chatty
        # "Generating public/private..." / fingerprint / randomart
        # output without hiding the FIDO2 PIN prompt.
        $cmdLine = '"{0}" -q -t {1} -O resident {2}-O "application={3}" -C "{4}" -N "" -f "{5}"' -f `
            $sshKeygenExe, $KeyType, $verifyOption, $application, $Email, $tempKeyPath

        Write-Verbose "ssh-keygen command: $cmdLine"

        $shouldProcessDesc = "Generate resident FIDO2 SSH key ($KeyType, application=$application" + $(if ($NoPin) { ', touch-only' } else { ', PIN+touch' }) + ")"
        if (-not $PSCmdlet.ShouldProcess("authenticator", $shouldProcessDesc)) {
            return
        }

        if ($NoPin) {
            Write-Host "Touch your authenticator when it starts blinking."
        }
        else {
            Write-Host "Enter your FIDO2 PIN when prompted, then touch your authenticator when it starts blinking."
        }
        & cmd.exe /c "`"$cmdLine`""
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
        $finalName   = Get-Fido2CanonicalName -KeyType $KeyType -Label $Label -Thumbprint $thumbprint
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
