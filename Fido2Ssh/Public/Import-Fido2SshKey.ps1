function Import-Fido2SshKey {
    <#
    .SYNOPSIS
        Imports resident FIDO2 SSH keys from a connected authenticator into the local SSH directory.

    .DESCRIPTION
        Runs `ssh-keygen -K` to extract every resident SSH key from a connected
        FIDO2 authenticator (YubiKey or other passkey provider) and installs
        them into `-SshDirectory` (default `%USERPROFILE%\.ssh`) using the same
        canonical filename layout that `New-Fido2SshKey` produces:

            id_<keytype>_sk_rk[_<label>]_<thumbprint>

        Because the thumbprint is derived from the public key fingerprint, a
        credential extracted here lands at the exact same filename as if it had
        been created by `New-Fido2SshKey`, so re-running this cmdlet does not
        produce duplicate files, duplicate `ssh-agent` entries, or duplicate
        selection prompts in the publish cmdlets. Optionally loads the private
        keys into `ssh-agent`.

    .PARAMETER SshDirectory
        Destination folder. Defaults to `%USERPROFILE%\.ssh`.

    .PARAMETER Force
        Overwrite existing key files with the same name.

    .PARAMETER SkipAgent
        Don't start `ssh-agent` and don't run `ssh-add`.

    .EXAMPLE
        Import-Fido2SshKey

    .EXAMPLE
        Import-Fido2SshKey -SshDirectory C:\keys -Force -SkipAgent
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

    # Fail fast on Windows when not elevated. ssh-keygen -K needs raw USB-HID
    # access to the authenticator to issue CTAP2 authenticatorCredentialManagement;
    # that path is reserved for elevated processes. Non-elevated sessions fall
    # through to the Windows WebAuthn API, which does not expose credential
    # enumeration, so ssh-keygen prompts for a PIN, then prints
    # "Unable to load resident keys: invalid format" and exits -1. Bailing here
    # avoids the spurious PIN prompt and the misleading ssh-keygen output.
    if (-not (Test-Fido2WindowsElevation)) {
        Write-Host ''
        Write-Host '  This Windows session is not elevated.' -ForegroundColor Red
        Write-Host ''
        Write-Host '  Import-Fido2SshKey requires an elevated PowerShell session on Windows.' -ForegroundColor Cyan
        Write-Host ''
        throw 'Import-Fido2SshKey requires an elevated PowerShell session on Windows.'
    }

    if (-not (Test-Path -LiteralPath $SshDirectory)) {
        New-Item -ItemType Directory -Path $SshDirectory | Out-Null
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("fido2-ssh-import-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null

    $installedPrivateKeys = @()
    $skippedFiles         = @()

    try {
        Push-Location $tempRoot

        Write-Host "Touch your authenticator if prompted. Downloading resident FIDO2 SSH keys..."
        # `-q` silences ssh-keygen's per-key "Saved..." chatter while
        # keeping the FIDO2 PIN prompt (which is written to stdout on
        # Windows) visible to the user.
        & ssh-keygen -q -K -N ''
        if ($LASTEXITCODE -ne 0) {
            throw "ssh-keygen -K failed with exit code $LASTEXITCODE."
        }

        $extracted = @(Get-ChildItem -Path $tempRoot -File)
        $extractedPubs = @($extracted | Where-Object { $_.Extension -eq ".pub" })
        if ($extractedPubs.Count -eq 0) {
            throw "No resident FIDO2 SSH keys were extracted from the authenticator."
        }

        # Build a fingerprint -> path map of every FIDO2 SSH key that's
        # already in $SshDirectory. We dedupe by SHA256 fingerprint, not
        # filename, because OpenSSH's ssh-keygen -K names extracted files
        # using the credential's application *and* user_id (a long hex
        # blob), while New-Fido2SshKey produces a shorter canonical name
        # without the user_id. Filename-only dedupe would therefore miss
        # the match and re-install the same credential under a second
        # filename.
        $existingFingerprints = @{}
        foreach ($existingPub in (Get-ChildItem -Path $SshDirectory -File -Filter "id_*_sk_rk*.pub" -ErrorAction SilentlyContinue)) {
            try {
                $existingFingerprints[(Get-Fido2KeyFingerprint -PublicKeyPath $existingPub.FullName)] = $existingPub.FullName
            }
            catch {
                Write-Verbose "Skipping unreadable existing key $($existingPub.FullName): $_"
            }
        }

        # ssh-keygen -K names files as `id_<keytype>_sk_rk_<application>`,
        # optionally followed by `_<user_id_hex>` (typically 32-64 hex
        # chars) on recent OpenSSH releases. We strip that trailing hex
        # blob so the on-disk label matches the one New-Fido2SshKey would
        # have used, then re-derive the canonical `_<thumbprint>` form.
        foreach ($pub in $extractedPubs) {
            $extractedBase = [System.IO.Path]::GetFileNameWithoutExtension($pub.Name)
            $extractedPriv = Join-Path $tempRoot $extractedBase

            if (-not (Test-Path -LiteralPath $extractedPriv)) {
                Write-Warning "Public key $($pub.Name) had no matching private key file in ssh-keygen output. Skipping."
                continue
            }

            $fingerprint = Get-Fido2KeyFingerprint -PublicKeyPath $pub.FullName
            if ($existingFingerprints.ContainsKey($fingerprint) -and -not $Force) {
                Write-Verbose "Skipping $($pub.Name): same credential is already installed as $($existingFingerprints[$fingerprint])."
                $skippedFiles += $existingFingerprints[$fingerprint]
                continue
            }

            # Map ssh-keygen's `id_<typeSuffix>_rk[_<label>[_<user_id_hex>]]`
            # layout back to KeyType + Label so the shared canonical-name
            # helper can rebuild the filename the rest of the module expects.
            if ($extractedBase -notmatch '^id_(?<typeSuffix>ed25519_sk|ecdsa_sk)_rk(?:_(?<label>.+))?$') {
                Write-Warning "Extracted file $($pub.Name) does not match the expected `id_<keytype>_sk_rk...` layout. Installing verbatim."
                $destPub  = Join-Path $SshDirectory $pub.Name
                $destPriv = Join-Path $SshDirectory $extractedBase
                if ((Test-Path -LiteralPath $destPriv) -and -not $Force) {
                    $skippedFiles += $destPriv
                    continue
                }
                if ($PSCmdlet.ShouldProcess($destPriv, "Install extracted key file")) {
                    Move-Item -LiteralPath $extractedPriv -Destination $destPriv -Force:$Force
                    Move-Item -LiteralPath $pub.FullName  -Destination $destPub  -Force:$Force
                    $installedPrivateKeys += $destPriv
                    $existingFingerprints[$fingerprint] = $destPriv
                }
                continue
            }

            $keyType = switch ($matches['typeSuffix']) {
                'ed25519_sk' { 'ed25519-sk' }
                'ecdsa_sk'   { 'ecdsa-sk' }
            }
            $label = $matches['label']

            # Strip a trailing `_<hex>` segment (OpenSSH appends the FIDO
            # user_id as hex when extracting). Anything that ends in `_`
            # followed by at least 16 hex characters is treated as the
            # user_id and removed so the canonical filename matches what
            # New-Fido2SshKey produced for the same credential.
            if ($label -match '^(?<clean>.+?)_[0-9a-fA-F]{16,}$') {
                $label = $matches['clean']
            }

            $thumbprint  = Get-Fido2KeyThumbprint -PublicKeyPath $pub.FullName
            $canonical   = Get-Fido2CanonicalName -KeyType $keyType -Label $label -Thumbprint $thumbprint
            $destPrivate = Join-Path $SshDirectory $canonical
            $destPublic  = "$destPrivate.pub"

            if ((Test-Path -LiteralPath $destPrivate) -and -not $Force) {
                Write-Verbose "Skipping existing file: $destPrivate. Same credential is already installed; re-run with -Force to overwrite."
                $skippedFiles += $destPrivate
                continue
            }

            if ($PSCmdlet.ShouldProcess($destPrivate, "Install extracted key as canonical filename")) {
                Move-Item -LiteralPath $extractedPriv -Destination $destPrivate -Force:$Force
                Move-Item -LiteralPath $pub.FullName  -Destination $destPublic  -Force:$Force
                $installedPrivateKeys += $destPrivate
                $existingFingerprints[$fingerprint] = $destPrivate
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

    Write-Host "Imported $($installedPrivateKeys.Count) resident FIDO2 SSH key(s) to $SshDirectory."
    if ($skippedFiles.Count -gt 0) {
        Write-Host "Skipped $($skippedFiles.Count) existing file(s). Re-run with -Force to overwrite them."
    }
    Write-Host "Use the corresponding .pub file(s) from $SshDirectory on remote hosts."
}
