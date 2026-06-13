function Get-Fido2SshKey {
    <#
    .SYNOPSIS
        Lists resident FIDO2 SSH keys currently configured in the local SSH directory.

    .DESCRIPTION
        Scans `-SshDirectory` (default `%USERPROFILE%\.ssh` on Windows and
        `$HOME/.ssh` on Linux/macOS) for files matching `id_*_sk_rk*.pub` and
        returns one object per match.

        The command surfaces canonical filename metadata (key type, label,
        thumbprint) and whether the matching private-key handle file exists.

    .PARAMETER SshDirectory
        Source folder. Defaults to `%USERPROFILE%\.ssh` on Windows and
        `$HOME/.ssh` on Linux/macOS.

    .PARAMETER Label
        Optional case-insensitive substring filter against the parsed label
        segment of the canonical filename.

    .EXAMPLE
        Get-Fido2SshKey

    .EXAMPLE
        Get-Fido2SshKey -Label work
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$SshDirectory = (Get-Fido2DefaultSshDirectory),
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $SshDirectory)) {
        Write-Verbose "SSH directory not found: $SshDirectory"
        return
    }

    $pubFiles = @(Get-ChildItem -Path $SshDirectory -File -Filter 'id_*_sk_rk*.pub' -ErrorAction SilentlyContinue)

    foreach ($pub in ($pubFiles | Sort-Object Name)) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($pub.Name)
        $privatePath = Join-Path $pub.DirectoryName $baseName

        $keyType = $null
        $parsedLabel = $null
        $thumbprint = $null

        if ($baseName -match '^id_(?<typeSuffix>ed25519_sk|ecdsa_sk)_rk(?:_(?<label>.+))?_(?<thumb>[A-Za-z0-9]{12})$') {
            $keyType = switch ($matches['typeSuffix']) {
                'ed25519_sk' { 'ed25519-sk' }
                'ecdsa_sk' { 'ecdsa-sk' }
                default { $null }
            }
            $parsedLabel = $matches['label']
            $thumbprint = $matches['thumb'].ToLowerInvariant()
        }

        $labelValue = if ($null -ne $parsedLabel) { $parsedLabel } else { '' }
        if ($Label -and ($labelValue -notlike "*$Label*")) {
            continue
        }

        $line = Get-Content -LiteralPath $pub.FullName -TotalCount 1 -ErrorAction SilentlyContinue
        $algorithm = $null
        $comment = $null
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $parts = $line -split '\s+'
            if ($parts.Count -ge 1) { $algorithm = $parts[0] }
            if ($parts.Count -ge 3) { $comment = ($parts[2..($parts.Count - 1)] -join ' ') }
        }

        $result = [pscustomobject]@{
            Name = $baseName
            KeyType = $keyType
            Label = $parsedLabel
            Thumbprint = $thumbprint
            Algorithm = $algorithm
            Comment = $comment
            PublicKeyPath = $pub.FullName
            PrivateKeyPath = $privatePath
            HasPrivateKey = (Test-Path -LiteralPath $privatePath)
        }

        $defaultDisplay = New-Object System.Management.Automation.PSPropertySet(
            'DefaultDisplayPropertySet',
            [string[]]@('Label', 'Algorithm')
        )
        $result | Add-Member -MemberType MemberSet -Name PSStandardMembers -Value ([System.Management.Automation.PSMemberInfo[]]@($defaultDisplay))

        $result
    }
}
