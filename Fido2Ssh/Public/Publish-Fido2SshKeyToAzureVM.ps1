function Publish-Fido2SshKeyToAzureVM {
    <#
    .SYNOPSIS
        Publishes a FIDO2 SSH public key to an Azure VM via Run Command.

    .DESCRIPTION
        Uses `az vm run-command invoke` to write the contents of `-PublicKeyPath`
        (or an auto-detected `id_*_sk_rk*.pub` in `%USERPROFILE%\.ssh`) to the
        target user's `~/.ssh/authorized_keys` on the VM. Requires only Azure
        RBAC on the VM resource — no inbound SSH connectivity needed.

    .PARAMETER ResourceGroupName
        Resource group containing the VM.

    .PARAMETER VMName
        Azure VM name.

    .PARAMETER UserName
        Linux user on the VM. Defaults to `azureuser`.

    .PARAMETER PublicKeyPath
        Optional. Specific `.pub` file. If omitted, auto-detects FIDO2 keys
        in `%USERPROFILE%\.ssh` and prompts when multiple match.

    .PARAMETER SubscriptionId
        Optional. Falls back to the active `az` subscription if omitted.

    .PARAMETER WipeExistingKeys
        Replace `authorized_keys` with this key only.

    .PARAMETER AllowDuplicate
        Append unconditionally (skip dedupe).

    .EXAMPLE
        Publish-Fido2SshKeyToAzureVM -ResourceGroupName my-rg -VMName my-vm
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$VMName,
        [string]$UserName = "azureuser",
        [string]$PublicKeyPath,
        [string]$SubscriptionId,
        [switch]$WipeExistingKeys,
        [switch]$AllowDuplicate
    )

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI (az) was not found. Install it from https://aka.ms/installazurecli."
    }

    if ([string]::IsNullOrWhiteSpace($PublicKeyPath)) {
        $PublicKeyPath = Resolve-Fido2PublicKeyPath -SshDirectory (Get-Fido2DefaultSshDirectory)
    }
    if (-not (Test-Path -LiteralPath $PublicKeyPath -PathType Leaf)) {
        throw "Public key file was not found: $PublicKeyPath"
    }

    $keyLine = (Get-Content -LiteralPath $PublicKeyPath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($keyLine)) {
        throw "Public key file is empty: $PublicKeyPath"
    }

    $mode = if ($WipeExistingKeys) { "wipe" } elseif ($AllowDuplicate) { "append" } else { "dedupe" }

    # UserName is interpolated directly into the remote script; reject anything that
    # isn't a simple Linux username to avoid shell injection.
    if ($UserName -notmatch '^[A-Za-z0-9._-]+$') {
        throw "UserName '$UserName' contains characters that are unsafe to embed in a shell script."
    }

    # Base64 the key: `az vm run-command --parameters` mangles values containing
    # spaces (SSH keys always have them), so we embed everything into the script
    # body via string substitution and decode it on the VM.
    $keyBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($keyLine))

    # Bash shebang is required: RunShellScript defaults to /bin/sh, which doesn't
    # support `set -o pipefail`.
    $remoteScript = @'
#!/bin/bash
set -euo pipefail

TARGET_USER="__USER__"
MODE="__MODE__"
KEY_B64="__KEY_B64__"

KEY="$(printf '%s' "$KEY_B64" | base64 -d)"
[ -n "$KEY" ] || { echo "Decoded key is empty." >&2; exit 2; }

HOME_DIR=$(getent passwd "$TARGET_USER" | cut -d: -f6)
[ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ] || { echo "User '$TARGET_USER' was not found on this VM." >&2; exit 3; }

SSH_DIR="$HOME_DIR/.ssh"
AUTH_FILE="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

case "$MODE" in
    wipe)   printf '%s\n' "$KEY" > "$AUTH_FILE" ;;
    append) touch "$AUTH_FILE"; printf '%s\n' "$KEY" >> "$AUTH_FILE" ;;
    dedupe)
        touch "$AUTH_FILE"
        if ! grep -qxF "$KEY" "$AUTH_FILE" 2>/dev/null; then
            printf '%s\n' "$KEY" >> "$AUTH_FILE"
            echo "Key added."
        else
            echo "Key already present; no change."
        fi
        ;;
    *) echo "Unknown mode '$MODE'." >&2; exit 4 ;;
esac

chmod 600 "$AUTH_FILE"
chown -R "$TARGET_USER:$TARGET_USER" "$SSH_DIR"

echo "Done: $TARGET_USER mode=$MODE file=$AUTH_FILE"
wc -l "$AUTH_FILE"
'@

    $remoteScript = $remoteScript.
        Replace("__USER__", $UserName).
        Replace("__MODE__", $mode).
        Replace("__KEY_B64__", $keyBase64)

    # Force LF line endings; CRLF breaks bash parsing inside Run Command.
    $remoteScript = $remoteScript -replace "`r`n", "`n"

    $target = "$VMName (resource group '$ResourceGroupName')"
    $actionDescription = "Publish SSH public key from '$PublicKeyPath' to $target via Azure VM Run Command"
    if ($WipeExistingKeys) { $actionDescription += " (wipe existing authorized_keys first)" }

    if ($PSCmdlet.ShouldProcess($target, $actionDescription)) {
        # Write the script to a UTF-8 (no BOM) LF temp file and pass `--scripts @<path>`.
        # Inline script bodies get line-ending/encoding mangled through the
        # PowerShell -> az (Python) -> ARM -> VM pipeline.
        $tempScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("publish-fido2-ssh-key-{0}.sh" -f ([System.Guid]::NewGuid().ToString("N")))

        try {
            [System.IO.File]::WriteAllText($tempScriptPath, $remoteScript, (New-Object System.Text.UTF8Encoding($false)))

            $azArgs = @(
                "vm", "run-command", "invoke",
                "--resource-group", $ResourceGroupName,
                "--name", $VMName,
                "--command-id", "RunShellScript",
                "--scripts", ("@" + $tempScriptPath),
                "--output", "json"
            )
            if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
                $azArgs += @("--subscription", $SubscriptionId)
            }

            $rawResult = & az @azArgs
            if ($LASTEXITCODE -ne 0) { throw "az vm run-command invoke failed with exit code $LASTEXITCODE." }
        }
        finally {
            Remove-Item -LiteralPath $tempScriptPath -Force -ErrorAction SilentlyContinue
        }

        $resultJson = ($rawResult -join "`n")
        try { $result = $resultJson | ConvertFrom-Json }
        catch { Write-Host $resultJson; throw "Unable to parse Azure CLI response as JSON: $($_.Exception.Message)" }

        $stdout = ""
        $stderr = ""
        $entries = if ($result.PSObject.Properties.Name -contains "value") { @($result.value) } else { @() }
        foreach ($entry in $entries) {
            $code = [string]$entry.code
            $message = [string]$entry.message

            if ($code -like "*StdOut*") { $stdout = $message; continue }
            if ($code -like "*StdErr*") { $stderr = $message; continue }

            # Newer az format: a single entry whose message embeds both
            # "[stdout]\n...\n[stderr]\n..." sections.
            if ($message -match '(?s)\[stdout\]\s*\n(.*?)\n\[stderr\]\s*\n(.*)$') {
                $stdout = $Matches[1]
                $stderr = $Matches[2]
            }
        }

        Write-Host "--- Remote stdout ---"
        if ([string]::IsNullOrWhiteSpace($stdout)) { Write-Host "(empty)" } else { Write-Host $stdout.TrimEnd() }

        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Warning "--- Remote stderr ---"
            Write-Warning $stderr.TrimEnd()
            throw "Remote script reported errors on $VMName."
        }
    }

    Write-Host "Key published to $UserName@$VMName using $PublicKeyPath"
    if ($WipeExistingKeys) {
        Write-Host "Existing remote authorized_keys entries were replaced."
    }
    else {
        Write-Host "Existing remote authorized_keys entries were preserved."
    }
}
