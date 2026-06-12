function Get-Fido2KeyFingerprint {
    <#
    .SYNOPSIS
        Returns the raw SHA256 base64 fingerprint of a FIDO2 SSH public key.

    .DESCRIPTION
        Runs `ssh-keygen -lf <PublicKeyPath>` and returns the SHA256 segment
        (the value after `SHA256:`). This is the canonical identity of the
        underlying credential and is used by `Import-Fido2SshKey` to dedupe
        extracted keys against keys already on disk, independent of filename.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PublicKeyPath
    )

    $fingerprintLine = & ssh-keygen -lf $PublicKeyPath
    if ($LASTEXITCODE -ne 0 -or $fingerprintLine -notmatch 'SHA256:([A-Za-z0-9+/=]+)') {
        throw "Could not read SSH fingerprint from $PublicKeyPath."
    }
    return $matches[1]
}

function Get-Fido2KeyThumbprint {
    <#
    .SYNOPSIS
        Returns the short thumbprint slice derived from a FIDO2 SSH public key's SHA256 fingerprint.

    .DESCRIPTION
        Runs `ssh-keygen -lf <PublicKeyPath>`, extracts the SHA256 fingerprint,
        strips non-alphanumeric characters, and returns the first 12 characters
        in lower case. The same value is embedded into the canonical filename
        by both `New-Fido2SshKey` and `Import-Fido2SshKey`, so the two code
        paths agree on a single on-disk name per credential.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PublicKeyPath
    )

    $fingerprint = Get-Fido2KeyFingerprint -PublicKeyPath $PublicKeyPath
    return (($fingerprint -replace '[^A-Za-z0-9]', '') + '000000000000').Substring(0, 12).ToLowerInvariant()
}

function Get-Fido2CanonicalName {
    <#
    .SYNOPSIS
        Builds the canonical resident FIDO2 SSH key filename used by this module.

    .DESCRIPTION
        Returns a name of the form `id_<typeSuffix>_rk[_<label>]_<thumbprint>`,
        e.g. `id_ed25519_sk_rk_work-laptop_abc123def456`. This is the layout
        produced by `New-Fido2SshKey` and that `Import-Fido2SshKey` renames
        `ssh-keygen -K` output to, so a single credential on the authenticator
        always lands at exactly one filename in the SSH directory regardless of
        whether it was created or extracted.

    .PARAMETER KeyType
        FIDO key algorithm: `ed25519-sk` or `ecdsa-sk`.

    .PARAMETER Label
        Optional label (the part after `ssh:` in the FIDO application string).
        Omitted from the filename when blank.

    .PARAMETER Thumbprint
        Short thumbprint produced by `Get-Fido2KeyThumbprint`.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ed25519-sk', 'ecdsa-sk')]
        [string]$KeyType,
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [string]$Thumbprint
    )

    $typeSuffix = switch ($KeyType) {
        'ed25519-sk' { 'ed25519_sk' }
        'ecdsa-sk'   { 'ecdsa_sk' }
    }

    if ([string]::IsNullOrWhiteSpace($Label)) {
        return "id_${typeSuffix}_rk_${Thumbprint}"
    }
    return "id_${typeSuffix}_rk_${Label}_${Thumbprint}"
}
