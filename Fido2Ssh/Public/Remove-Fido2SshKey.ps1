function Remove-Fido2SshKey {
    <#
    .SYNOPSIS
        Removes FIDO2 SSH key files from the SSH directory and unloads them from `ssh-agent`.

    .DESCRIPTION
        Cleans up keys produced by `New-Fido2SshKey` / `Import-Fido2SshKey`.

        By default only **resident** key file pairs (`id_*_sk_rk*`) are targeted.
        Non-resident (software) passkeys are intentionally skipped because their
        private key handle file is the only copy of the credential — deleting it
        means the key is permanently lost and cannot be recovered from the
        authenticator. Pass `-IncludeNonResident` to include them.

        The resident credential on the FIDO2 authenticator itself is NOT touched
        by this cmdlet — use `ssh-keygen -K` followed by FIDO management tools
        (e.g. `ykman fido credentials delete`) for that.

        Scope can be narrowed with `-PublicKeyPath` (a specific key) or
        `-Label` (a substring match against the label segment of the canonical
        filename). When neither is supplied, all targeted key types in the
        directory are processed.

    .PARAMETER PublicKeyPath
        Full path to a specific `*.pub` file to remove. The matching private
        key (same name without `.pub`) is removed along with it.

    .PARAMETER Label
        Case-insensitive substring filter against the label segment of the
        canonical filename. Only keys whose label contains this value are removed.

    .PARAMETER SshDirectory
        Source folder. Defaults to `%USERPROFILE%\.ssh` on Windows and
        `$HOME/.ssh` on Linux/macOS.

    .PARAMETER IncludeNonResident
        Also remove non-resident (software) passkey file pairs. Use with care:
        the private key handle file is the only copy of the credential. After
        removal you will also want to delete the corresponding passkey from the
        authenticator's credential store (e.g. via Windows Hello settings, your
        browser's passkey manager, or `ykman fido credentials delete`).

    .PARAMETER SkipAgent
        Don't touch `ssh-agent`. Files on disk are still removed.

    .PARAMETER Force
        Skip the per-key confirmation prompt.

    .EXAMPLE
        Remove-Fido2SshKey

        Lists every FIDO2 resident key in `~/.ssh`, prompts for confirmation,
        unloads each from `ssh-agent` and deletes both file halves. Non-resident
        (software) passkeys are printed but skipped.

    .EXAMPLE
        Remove-Fido2SshKey -Label work-laptop -Force

        Removes any FIDO2 resident key whose canonical filename contains
        `work-laptop` without prompting.

    .EXAMPLE
        Remove-Fido2SshKey -IncludeNonResident -Label work-laptop -Force

        Removes both the resident key AND the non-resident (software) passkey
        that match `work-laptop`. Remember to also clean up the passkey from
        the authenticator's credential store.

    .EXAMPLE
        Remove-Fido2SshKey -PublicKeyPath C:\Users\me\.ssh\id_ed25519_sk_rk_pin_abc123def456.pub
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'All')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ByPath')]
        [string]$PublicKeyPath,

        [Parameter(ParameterSetName = 'All')]
        [string]$Label,

        [string]$SshDirectory = (Get-Fido2DefaultSshDirectory),
        [switch]$IncludeNonResident,
        [switch]$SkipAgent,
        [switch]$Force
    )

    # -Force suppresses the High-impact confirmation prompt while still
    # honouring an explicit -Confirm or -WhatIf from the caller.
    if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) {
        $ConfirmPreference = 'None'
    }

    if (-not (Test-Path -LiteralPath $SshDirectory)) {
        Write-Verbose "SSH directory not found: $SshDirectory. Nothing to remove."
        return
    }

    # Resolve the set of public-key files we'll process.
    $targets    = @()   # keys to remove
    $nrSkipped  = @()   # non-resident keys that were found but skipped

    if ($PSCmdlet.ParameterSetName -eq 'ByPath') {
        if (-not (Test-Path -LiteralPath $PublicKeyPath)) {
            throw "Public key file not found: $PublicKeyPath"
        }
        $pub = Get-Item -LiteralPath $PublicKeyPath
        $isNonResident = ($pub.Name -notmatch '_rk')
        if ($isNonResident -and -not $IncludeNonResident) {
            Write-Host "Skipped non-resident (software) passkey: $($pub.FullName)"
            Write-Host "  Non-resident keys are not removed by default. Re-run with -IncludeNonResident to delete it."
            Write-Host "  WARNING: deleting the private key handle file permanently destroys the credential."
            return
        }
        $targets = @($pub)
    }
    else {
        # Collect resident candidates.
        $residentCandidates = @(Get-ChildItem -Path $SshDirectory -File -Filter "id_*_sk_rk*.pub" -ErrorAction SilentlyContinue)

        # Collect non-resident candidates (id_*_sk_*.pub without _rk).
        $allSkPubs   = @(Get-ChildItem -Path $SshDirectory -File -Filter "id_*_sk_*.pub" -ErrorAction SilentlyContinue)
        $nrCandidates = @($allSkPubs | Where-Object { $_.Name -notmatch '_rk' })

        $applyLabelFilter = {
            param($candidates)
            if (-not $Label) { return $candidates }
            return @($candidates | Where-Object {
                $base = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                if ($base -match '^id_(?:ed25519_sk|ecdsa_sk)_(?:rk_)?(?<rest>.+)$') {
                    $rest = $matches['rest']
                    if ($rest -match '^(?<label>.+)_[0-9a-f]{12}$') {
                        return $matches['label'] -like "*$Label*"
                    }
                }
                return $false
            })
        }

        $residentCandidates = & $applyLabelFilter $residentCandidates
        $nrCandidates       = & $applyLabelFilter $nrCandidates

        $targets = $residentCandidates

        if ($nrCandidates.Count -gt 0) {
            if ($IncludeNonResident) {
                $targets = @($targets) + @($nrCandidates)
            }
            else {
                $nrSkipped = $nrCandidates
            }
        }
    }

    if ($targets.Count -eq 0 -and $nrSkipped.Count -eq 0) {
        Write-Host "No matching FIDO2 SSH keys found in $SshDirectory."
        return
    }

    if ($targets.Count -eq 0) {
        Write-Host "No resident FIDO2 SSH keys matched. $($nrSkipped.Count) non-resident (software) passkey(s) were found but skipped (see below)."
    }

    # ssh-agent state — start the service only if it is already loadable; we
    # don't want a cleanup cmdlet to spin up services unnecessarily.
    $useAgent = -not $SkipAgent -and [bool](Get-Command ssh-add -ErrorAction SilentlyContinue)
    if ($useAgent) {
        $isWindowsHost = if (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue) {
            [bool]$IsWindows
        } else {
            $true
        }

        if ($isWindowsHost) {
            $agentService = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
            if ($agentService -and $agentService.Status -ne 'Running') {
                try { Start-Service ssh-agent -ErrorAction Stop }
                catch {
                    Write-Verbose "Could not start ssh-agent ($_). Skipping agent removal."
                    $useAgent = $false
                }
            }
        }
        else {
            # On Linux/macOS the user owns ssh-agent lifecycle. If no agent
            # socket is exposed, ssh-add can't do anything useful; skip.
            if ([string]::IsNullOrWhiteSpace($env:SSH_AUTH_SOCK)) {
                Write-Verbose 'SSH_AUTH_SOCK is not set. Skipping ssh-agent removal; files on disk will still be removed.'
                $useAgent = $false
            }
        }
    }

    $removedCount    = 0
    $removedNrCount  = 0
    foreach ($pub in $targets) {
        $pubPath  = $pub.FullName
        $privPath = $pubPath -replace '\.pub$', ''
        $isNonResident = ($pub.Name -notmatch '_rk')

        $target = if (Test-Path -LiteralPath $privPath) { $privPath } else { $pubPath }
        $action = "Remove FIDO2 SSH key (and ssh-agent entry)"

        if (-not $PSCmdlet.ShouldProcess($target, $action)) {
            continue
        }

        if ($useAgent -and (Test-Path -LiteralPath $privPath)) {
            # `ssh-add -d` writes a one-line success/failure message to stderr
            # which is noisy when the identity wasn't loaded. Swallow the
            # exit code; the file removal below is the authoritative cleanup.
            & ssh-add -d $privPath 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Verbose "Unloaded $privPath from ssh-agent."
            }
            else {
                Write-Verbose "ssh-add -d returned $LASTEXITCODE for $privPath (likely not loaded)."
            }
        }

        foreach ($file in @($privPath, $pubPath)) {
            if (Test-Path -LiteralPath $file) {
                Remove-Item -LiteralPath $file -Force -ErrorAction Stop
                Write-Verbose "Deleted $file."
            }
        }

        Write-Host "Removed $target"
        $removedCount++
        if ($isNonResident) { $removedNrCount++ }
    }

    Write-Host ""
    Write-Host "Removed $removedCount FIDO2 SSH key file pair(s) from $SshDirectory."
    if ($SkipAgent) {
        Write-Host "ssh-agent was not modified (-SkipAgent)."
    }
    if ($removedNrCount -gt 0) {
        Write-Host ""
        Write-Host "  IMPORTANT: $removedNrCount non-resident (software) passkey(s) were deleted."
        Write-Host "  The private key handle is gone and cannot be recovered from the authenticator."
        Write-Host "  You should also remove the corresponding passkey from the authenticator's"
        Write-Host "  credential store to keep it clean:"
        Write-Host "    - Windows Hello / Microsoft Authenticator: Settings > Accounts > Passkeys"
        Write-Host "    - YubiKey: ykman fido credentials list / delete"
        Write-Host "    - Other: use your authenticator's management tool or browser passkey settings."
    }
    if ($nrSkipped.Count -gt 0) {
        Write-Host ""
        Write-Host "  Skipped $($nrSkipped.Count) non-resident (software) passkey(s) — they are NOT removed by"
        Write-Host "  default because the private key handle cannot be recovered if deleted."
        Write-Host "  Re-run with -IncludeNonResident to also remove them."
        foreach ($skipped in $nrSkipped) {
            Write-Host "    $($skipped.FullName)"
        }
    }
    if ($removedNrCount -eq 0 -and $nrSkipped.Count -eq 0) {
        Write-Host "Note: the resident credential on the authenticator itself is unchanged."
    }
}
