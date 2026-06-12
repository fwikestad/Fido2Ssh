function New-YubikeyFidoSshKey {
    <#
    .SYNOPSIS
        Generates a resident FIDO2 SSH key on a connected YubiKey.

    .DESCRIPTION
        Prompts for an e-mail (used as the key comment) and a label
        (used in the FIDO2 application string), then runs `ssh-keygen`
        to create a new resident Security Key credential on the
        YubiKey. The credential is then installed into `-SshDirectory`
        (default `%USERPROFILE%\.ssh`) by delegating to
        `Install-YubikeyFidoSshKey`, which extracts every resident
        credential from the authenticator with the canonical filename
        layout the rest of this module expects:

            id_ed25519_sk_rk_<label>
            id_ed25519_sk_rk_<label>.pub

        By default the credential is created with `-O verify-required`,
        so the YubiKey will require its FIDO2 PIN (in addition to a
        touch) every time the key is used. Pass `-NoPin` to omit that
        constraint and require only a touch.

        The private key file is created with an empty passphrase so
        it can be loaded by `ssh-agent` and used by the publish
        cmdlets without further prompting. The actual private key
        material stays on the YubiKey; the file on disk is only a
        handle to the resident credential.

    .PARAMETER Email
        Value placed in the public-key comment field. Prompted for
        when not supplied.

    .PARAMETER Label
        Short label embedded in the FIDO application string
        (`ssh:<label>`) and therefore in the installed filename.
        Must only contain letters, digits, '.', '_' or '-'.
        Prompted for when not supplied.

    .PARAMETER SshDirectory
        Destination folder. Defaults to `%USERPROFILE%\.ssh`.

    .PARAMETER KeyType
        FIDO key algorithm. Defaults to `ed25519-sk`. Use
        `ecdsa-sk` for older authenticators that don't support
        Ed25519.

    .PARAMETER NoPin
        Omit the default `-O verify-required` constraint so the
        YubiKey only requires a touch (no FIDO2 PIN) when the key
        is used.

    .PARAMETER Force
        Forwarded to `Install-YubikeyFidoSshKey` to overwrite
        previously extracted resident-key files of the same name.

    .PARAMETER SkipAgent
        Forwarded to `Install-YubikeyFidoSshKey` to skip loading
        installed keys into `ssh-agent`.

    .EXAMPLE
        New-YubikeyFidoSshKey

        Prompts for e-mail and label, generates a PIN-protected
        resident Ed25519 FIDO2 SSH key on the YubiKey, then
        installs it into the user's .ssh directory.

    .EXAMPLE
        New-YubikeyFidoSshKey -Email me@example.com -Label work-laptop -NoPin

        Generates a touch-only credential with application
        `ssh:work-laptop` and installs it as
        ~/.ssh/id_ed25519_sk_rk_work-laptop(.pub).
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
    if ($Label -notmatch '^[A-Za-z0-9._-]+$') {
        throw "Label may only contain letters, digits, '.', '_' or '-'."
    }

    $application  = "ssh:$Label"
    $sshKeygenExe = (Get-Command ssh-keygen).Source
    $verifyOption = if ($NoPin) { '' } else { '-O verify-required ' }

    # Generate the resident credential on the YubiKey. ssh-keygen also
    # writes a local key file; we point it at a throwaway temp file
    # because Install-YubikeyFidoSshKey will re-extract the credential
    # into $SshDirectory under the canonical filename.
    $tempRoot    = Join-Path ([System.IO.Path]::GetTempPath()) ("yubikey-fido-new-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $tempKeyPath = Join-Path $tempRoot "newkey"

    try {
        # Build a single command line and run it via cmd.exe so the
        # empty-passphrase argument (-N "") is preserved verbatim.
        # Windows PowerShell 5.1's native-call operator drops bare
        # empty-string arguments, which would cause ssh-keygen to treat
        # "-f" as the passphrase value.
        $cmdLine = '"{0}" -t {1} -O resident {2}-O "application={3}" -C "{4}" -N "" -f "{5}"' -f `
            $sshKeygenExe, $KeyType, $verifyOption, $application, $Email, $tempKeyPath

        Write-Verbose "ssh-keygen command: $cmdLine"

        $shouldProcessDesc = "Generate resident FIDO2 SSH key ($KeyType, application=$application" + $(if ($NoPin) { ', touch-only' } else { ', PIN+touch' }) + ")"
        if ($PSCmdlet.ShouldProcess("YubiKey", $shouldProcessDesc)) {
            if ($NoPin) {
                Write-Host "Touch your YubiKey when it starts blinking."
            }
            else {
                Write-Host "Enter your YubiKey FIDO2 PIN when prompted, then touch the YubiKey when it starts blinking."
            }
            & cmd.exe /c "`"$cmdLine`""
            if ($LASTEXITCODE -ne 0) {
                throw "ssh-keygen failed with exit code $LASTEXITCODE."
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Install the freshly created resident credential (and re-extract
    # any pre-existing ones) into $SshDirectory using the canonical
    # filename layout that the publish cmdlets expect. Suppress
    # Install's informational Write-Host output; warnings (e.g.
    # "skipping existing file") and errors still surface.
    Install-YubikeyFidoSshKey -SshDirectory $SshDirectory -Force:$Force 6 | Out-Null
}
