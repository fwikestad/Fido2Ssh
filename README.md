# Fido2Ssh

PowerShell module for using **resident FIDO2 SSH keys** stored on a passkey
provider (YubiKey, other FIDO2 authenticators) from Windows. Covers the full
lifecycle: create the keys on the authenticator, import them onto a
workstation, then publish the matching public key to a Linux host either over
SSH or via the Azure VM Run Command channel.

Targets Windows PowerShell 5.1 and PowerShell 7+.

## Prerequisites

- Windows with the OpenSSH Client feature installed (`ssh`, `ssh-keygen`, `ssh-add`).
- A FIDO2 authenticator (e.g. YubiKey 5)
- For `Publish-Fido2SshKeyToAzureVM`: Azure CLI (`az`) signed in to a tenant /
  subscription that has permission to run
  `Microsoft.Compute/virtualMachines/runCommand/action` on the target VM.

## Installation

```powershell
# From the repo root — load the module for the current session.
Import-Module .\Fido2Ssh\Fido2Ssh.psd1

# Or install permanently for the current user.
Copy-Item -Recurse .\Fido2Ssh "$HOME\Documents\PowerShell\Modules\"
Import-Module Fido2Ssh
```

## Layout

```
Fido2Ssh/
  Fido2Ssh.psd1                       # module manifest
  Fido2Ssh.psm1                       # loader: dot-sources Private/, then Public/
  Private/
    Get-Fido2CanonicalName.ps1        # shared helpers (thumbprint + canonical filename)
    Resolve-Fido2PublicKeyPath.ps1    # shared helper, not exported
  Public/
    Import-Fido2SshKey.ps1
    New-Fido2SshKey.ps1
    Publish-Fido2SshKey.ps1
    Publish-Fido2SshKeyToAzureVM.ps1
    Remove-Fido2SshKey.ps1
```

Files under `Public/` are exported. Files under `Private/` are available to all
public functions but not to module consumers.

## Commands

### `New-Fido2SshKey`

Generates a new resident FIDO2 SSH credential on a connected authenticator and
installs it into `%USERPROFILE%\.ssh` (or a directory you specify) using the
canonical filename layout the rest of this module expects.

```powershell
# Interactive: prompts for e-mail and label, requires PIN + touch.
New-Fido2SshKey

# Non-interactive, touch-only (no PIN), with a custom label.
New-Fido2SshKey -Email me@example.com -Label work-laptop -NoPin
```

| Parameter       | Description                                                                                  |
| --------------- | -------------------------------------------------------------------------------------------- |
| `-Email`        | Value placed in the public-key comment field. Prompted for when not supplied.                |
| `-Label`        | Label embedded in the FIDO application string (`ssh:<label>`) and the installed filename.    |
| `-SshDirectory` | Destination folder. Defaults to `%USERPROFILE%\.ssh`.                                        |
| `-KeyType`      | `ed25519-sk` (default) or `ecdsa-sk` for older authenticators.                               |
| `-NoPin`        | Omit the default `-O verify-required` constraint (touch-only credential).                    |
| `-Force`        | Overwrite an existing key file with the same name.                                           |
| `-SkipAgent`    | Don’t try to add the new private key to `ssh-agent`.                                         |
| `-WhatIf`       | Standard `SupportsShouldProcess` dry-run.                                                    |

### `Import-Fido2SshKey`

Extracts every resident FIDO2 SSH key from a connected authenticator into
`%USERPROFILE%\.ssh` (or a directory you specify) and optionally loads each
private key into `ssh-agent`. Filenames match the layout `New-Fido2SshKey`
produces, so re-running this cmdlet doesn’t create duplicates.

```powershell
# Default: import to %USERPROFILE%\.ssh and load into ssh-agent.
Import-Fido2SshKey

# Custom location, overwrite existing files, skip ssh-agent loading.
Import-Fido2SshKey -SshDirectory C:\keys -Force -SkipAgent
```

| Parameter       | Description                                                                 |
| --------------- | --------------------------------------------------------------------------- |
| `-SshDirectory` | Destination folder. Defaults to `%USERPROFILE%\.ssh`.                       |
| `-Force`        | Overwrite existing files with the same name.                                |
| `-SkipAgent`    | Don't start `ssh-agent` and don't run `ssh-add`.                            |
| `-WhatIf`       | Standard `SupportsShouldProcess` dry-run.                                   |

Touch the authenticator when prompted by `ssh-keygen -K`.

### `Publish-Fido2SshKey`

Publishes a FIDO2 public key (`*.pub`) to a Linux host's
`~/.ssh/authorized_keys` over **plain SSH**.

```powershell
# Append to authorized_keys, deduping if the key is already present (default).
Publish-Fido2SshKey -HostName server.example.com -UserName azureuser

# Pick a specific key file and a non-default SSH port.
Publish-Fido2SshKey -HostName 10.0.0.4 -UserName ubuntu -Port 2222 `
    -PublicKeyPath C:\Users\me\.ssh\id_ed25519_sk_rk_work-laptop_abc123def456.pub

# Replace authorized_keys entirely (lockout risk; be careful).
Publish-Fido2SshKey -HostName server -UserName azureuser -WipeExistingKeys
```

| Parameter              | Description                                                                                                   |
| ---------------------- | ------------------------------------------------------------------------------------------------------------- |
| `-HostName`            | Required. DNS name or IP of the target host.                                                                  |
| `-UserName`            | Required. Linux user whose `authorized_keys` to update.                                                       |
| `-PublicKeyPath`       | Optional. If omitted, scans `%USERPROFILE%\.ssh` for `id_*_sk_rk*.pub` files and prompts when multiple match. |
| `-Port`                | Optional. SSH port (default `22`).                                                                            |
| `-WipeExistingKeys`    | Replace `authorized_keys` with this key only.                                                                 |
| `-AllowDuplicate`      | Append even if the key is already present (skip dedupe check).                                                |
| `-WhatIf` / `-Confirm` | Standard `SupportsShouldProcess`.                                                                             |

You will need an existing password or SSH login to the target.

### `Publish-Fido2SshKeyToAzureVM`

Same idea as above, but publishes the key via **Azure VM Run Command**, so
you don't need any inbound SSH connectivity to the VM — only Azure RBAC on
the VM resource.

```powershell
# Default: dedupe-append into ~azureuser/.ssh/authorized_keys on the VM.
Publish-Fido2SshKeyToAzureVM -ResourceGroupName my-rg -VMName my-vm

# Different OS user, explicit subscription, replace existing keys.
Publish-Fido2SshKeyToAzureVM -ResourceGroupName my-rg -VMName my-vm `
    -UserName ubuntu -SubscriptionId 00000000-0000-0000-0000-000000000000 `
    -WipeExistingKeys
```

| Parameter              | Description                                                      |
| ---------------------- | ---------------------------------------------------------------- |
| `-ResourceGroupName`   | Required. Resource group containing the VM.                      |
| `-VMName`              | Required. Azure VM name.                                         |
| `-UserName`            | Linux user on the VM (default `azureuser`).                      |
| `-PublicKeyPath`       | Optional, same behavior as the SSH variant.                      |
| `-SubscriptionId`      | Optional. Falls back to the active `az` subscription if omitted. |
| `-WipeExistingKeys`    | Replace `authorized_keys` with this key only.                    |
| `-AllowDuplicate`      | Append unconditionally (skip dedupe).                            |
| `-WhatIf` / `-Confirm` | Standard `SupportsShouldProcess`.                                |

See [Notes on the Azure variant](#notes-on-the-azure-variant) below for the
quirks this function works around.

### `Remove-Fido2SshKey`

Cleans up resident FIDO2 SSH keys produced by `New-Fido2SshKey` /
`Import-Fido2SshKey`. Removes the matching `id_*_sk_rk*` file pair from
`%USERPROFILE%\.ssh` (or a directory you specify) and unloads each key from
`ssh-agent`. The resident credential on the authenticator itself is not
touched — use `ykman fido credentials delete` (or the equivalent tool for
your authenticator) for that.

```powershell
# Interactive: list every FIDO2 key in ~/.ssh and confirm each removal.
Remove-Fido2SshKey

# Remove only keys whose label contains "work-laptop", no prompt.
Remove-Fido2SshKey -Label work-laptop -Force

# Remove one specific key.
Remove-Fido2SshKey -PublicKeyPath C:\Users\me\.ssh\id_ed25519_sk_rk_pin_abc123def456.pub

# Files only; leave ssh-agent alone.
Remove-Fido2SshKey -SkipAgent
```

| Parameter              | Description                                                                                |
| ---------------------- | ------------------------------------------------------------------------------------------ |
| `-PublicKeyPath`       | Remove this specific `*.pub` and its matching private key only.                            |
| `-Label`               | Case-insensitive substring filter against the label segment of the canonical filename.     |
| `-SshDirectory`        | Source folder. Defaults to `%USERPROFILE%\.ssh`.                                           |
| `-SkipAgent`           | Don't touch `ssh-agent`. Files on disk are still removed.                                  |
| `-Force`               | Skip the per-key confirmation prompt (still honours `-WhatIf` / explicit `-Confirm`).      |
| `-WhatIf` / `-Confirm` | Standard `SupportsShouldProcess` (declared `ConfirmImpact = 'High'`).                      |

### Private helpers

- `Get-Fido2KeyThumbprint` / `Get-Fido2CanonicalName` — derive the short
  thumbprint and canonical `id_<keytype>_sk_rk[_<label>]_<thumbprint>`
  filename used by `New-Fido2SshKey` and `Import-Fido2SshKey`.
- `Resolve-Fido2PublicKeyPath` — used by both `Publish-*` functions to locate
  and (when needed) prompt for the correct `.pub` file in `%USERPROFILE%\.ssh`.

Not exported.

## Typical workflow

```powershell
Import-Module .\Fido2Ssh\Fido2Ssh.psd1

# 1a. Create a brand-new resident FIDO2 SSH credential on the authenticator.
New-Fido2SshKey -Email me@example.com -Label work-laptop

# 1b. …or import credentials that already exist on the authenticator.
Import-Fido2SshKey

# 2a. Push the public key to a reachable Linux host over SSH.
Publish-Fido2SshKey -HostName server.example.com -UserName azureuser

# 2b. …or push it to an Azure VM without any inbound SSH.
Publish-Fido2SshKeyToAzureVM -ResourceGroupName my-rg -VMName my-vm

# 3. Log in using the FIDO2-backed key (touch when prompted).
ssh azureuser@server.example.com
```

## Notes on the Azure variant

`Publish-Fido2SshKeyToAzureVM` works around several documented pitfalls
of `az vm run-command invoke`:

- **`#!/bin/bash` shebang** — `RunShellScript` runs under `/bin/sh` by
  default, which doesn't support `set -o pipefail`.
- **No `--parameters`** — the VM Agent splits positional arguments on spaces,
  and SSH public keys always contain spaces. The key is base64-encoded into
  the script body and decoded with `base64 -d` on the VM.
- **`--scripts @<path>` with UTF-8 (no BOM) LF temp file** — inline script
  bodies get line-ending / encoding mangled through the
  PowerShell → az (Python) → ARM → VM pipeline.
- **Dual stdout/stderr parsing** — newer `az` returns a single result entry
  whose `message` field embeds `[stdout]\n…\n[stderr]\n…` sections; the
  function handles both the old and new shapes.
- **Username allow-list** — `-UserName` is interpolated into the remote
  script body, so it is validated against `^[A-Za-z0-9._-]+$` to prevent
  shell injection.

## Security notes

- Resident FIDO2 SSH keys still require a **touch** (and, depending on how
  they were generated, a PIN) on the authenticator for every authentication.
  The "private key" file on disk is only a handle into the authenticator; it
  is useless without the physical device.
- `-WipeExistingKeys` will remove **all** other entries from the remote
  `authorized_keys`. Make sure you have a recovery path (console access,
  another admin user, Azure Bastion, etc.) before using it.
- Keep `%USERPROFILE%\.ssh` ACL'd to your user only, just like any other
  SSH key directory.
