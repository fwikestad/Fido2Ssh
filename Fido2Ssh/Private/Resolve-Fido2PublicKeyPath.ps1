function Resolve-YubikeyFidoPublicKeyPath {
    <#
    .SYNOPSIS
        Finds a resident FIDO2 SSH public key file in the given directory.

    .DESCRIPTION
        Returns the path of the single matching `id_*_sk_rk*.pub` file.
        If multiple files match, prompts the user to select one, displaying
        the label (when present) or thumbprint extracted from the filename.

    .PARAMETER SshDirectory
        Directory to scan, typically `%USERPROFILE%\.ssh`.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SshDirectory
    )

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
