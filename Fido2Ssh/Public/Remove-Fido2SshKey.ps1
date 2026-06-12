function Remove-Fido2SshKey {
    <#
    .SYNOPSIS
        Removes resident FIDO2 SSH key files from the SSH directory and unloads them from `ssh-agent`.

    .DESCRIPTION
        Cleans up keys produced by `New-Fido2SshKey` / `Import-Fido2SshKey`. By
        default removes every `id_*_sk_rk*` file pair in `-SshDirectory`
        (default `%USERPROFILE%\.ssh`) and unloads each matching identity from
        `ssh-agent`. The resident credential on the FIDO2 authenticator itself
        is NOT touched — use `ssh-keygen -K` followed by FIDO management tools
        (e.g. `ykman fido credentials delete`) for that.

        Scope can be narrowed with `-PublicKeyPath` (a specific key) or
        `-Label` (a substring match against the label segment of the canonical
        filename). When neither is supplied, all FIDO2 resident keys in the
        directory are targeted.

    .PARAMETER PublicKeyPath
        Full path to a specific `*.pub` file to remove. The matching private
        key (same name without `.pub`) is removed along with it.

    .PARAMETER Label
        Case-insensitive substring filter against the label segment of the
        canonical filename (`id_<keytype>_sk_rk_<label>_<thumbprint>`). Only
        keys whose label contains this value are removed.

    .PARAMETER SshDirectory
        Source folder. Defaults to `%USERPROFILE%\.ssh`.

    .PARAMETER SkipAgent
        Don't touch `ssh-agent`. Files on disk are still removed.

    .PARAMETER Force
        Skip the per-key confirmation prompt.

    .EXAMPLE
        Remove-Fido2SshKey

        Lists every FIDO2 resident key in `~/.ssh`, prompts for confirmation,
        unloads each from `ssh-agent` and deletes both file halves.

    .EXAMPLE
        Remove-Fido2SshKey -Label work-laptop -Force

        Removes any FIDO2 key whose canonical filename contains `work-laptop`
        without prompting.

    .EXAMPLE
        Remove-Fido2SshKey -PublicKeyPath C:\Users\me\.ssh\id_ed25519_sk_rk_pin_abc123def456.pub
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'All')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ByPath')]
        [string]$PublicKeyPath,

        [Parameter(ParameterSetName = 'All')]
        [string]$Label,

        [string]$SshDirectory = (Join-Path $env:USERPROFILE ".ssh"),
        [switch]$SkipAgent,
        [switch]$Force
    )

    if (-not (Test-Path -LiteralPath $SshDirectory)) {
        Write-Verbose "SSH directory not found: $SshDirectory. Nothing to remove."
        return
    }

    # Resolve the set of public-key files we'll process.
    $targets = @()
    if ($PSCmdlet.ParameterSetName -eq 'ByPath') {
        if (-not (Test-Path -LiteralPath $PublicKeyPath)) {
            throw "Public key file not found: $PublicKeyPath"
        }
        $targets = @((Get-Item -LiteralPath $PublicKeyPath))
    }
    else {
        $candidates = @(Get-ChildItem -Path $SshDirectory -File -Filter "id_*_sk_rk*.pub" -ErrorAction SilentlyContinue)
        if ($Label) {
            $candidates = @($candidates | Where-Object {
                $base = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                # Strip the leading id_<keytype>_sk_rk_ and the trailing _<thumbprint>
                # so what remains is the label segment (may be empty for unlabelled keys).
                if ($base -match '^id_(?:ed25519_sk|ecdsa_sk)_rk_(?<rest>.+)$') {
                    $rest = $matches['rest']
                    if ($rest -match '^(?<label>.+)_[0-9a-f]{12}$') {
                        return $matches['label'] -like "*$Label*"
                    }
                }
                return $false
            })
        }
        $targets = $candidates
    }

    if ($targets.Count -eq 0) {
        Write-Host "No matching FIDO2 SSH keys found in $SshDirectory."
        return
    }

    # ssh-agent state — start the service only if it is already loadable; we
    # don't want a cleanup cmdlet to spin up services unnecessarily.
    $useAgent = -not $SkipAgent -and [bool](Get-Command ssh-add -ErrorAction SilentlyContinue)
    if ($useAgent) {
        $agentService = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
        if ($agentService -and $agentService.Status -ne 'Running') {
            try { Start-Service ssh-agent -ErrorAction Stop }
            catch {
                Write-Verbose "Could not start ssh-agent ($_). Skipping agent removal."
                $useAgent = $false
            }
        }
    }

    $removedCount = 0
    foreach ($pub in $targets) {
        $pubPath  = $pub.FullName
        $privPath = $pubPath -replace '\.pub$', ''

        $target = if (Test-Path -LiteralPath $privPath) { $privPath } else { $pubPath }
        $action = "Remove FIDO2 SSH key (and ssh-agent entry)"

        if (-not $Force -and -not $PSCmdlet.ShouldProcess($target, $action)) {
            continue
        }
        if ($Force -and -not $PSCmdlet.ShouldProcess($target, $action)) {
            # -Force still respects -WhatIf.
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
    }

    Write-Host ""
    Write-Host "Removed $removedCount FIDO2 SSH key file pair(s) from $SshDirectory."
    if ($SkipAgent) {
        Write-Host "ssh-agent was not modified (-SkipAgent)."
    }
    Write-Host "Note: the resident credential on the authenticator itself is unchanged."
}
