# YubikeyFido2Ssh

PowerShell module for using **resident FIDO2 SSH keys** stored on a YubiKey
(or other FIDO2 authenticator) from Windows. Covers the full lifecycle:
download the keys onto a workstation, then publish the matching public key to
a Linux host either over SSH or via the Azure VM Run Command channel.

Targets Windows PowerShell 5.1 and PowerShell 7+.

## Prerequisites

- Windows with the OpenSSH Client feature installed (`ssh`, `ssh-keygen`, `ssh-add`).
- A FIDO2 authenticator (e.g. YubiKey 5) with one or more **resident**
  (`-O resident`) SSH keys already generated on it.
- For `Publish-YubikeyFidoSshKeyToAzureVM`: Azure CLI (`az`) signed in to a
  tenant / subscription that has permission to run
  `Microsoft.Compute/virtualMachines/runCommand/action` on the target VM.

## Installation

```powershell
# From the repo root — load the module for the current session.
Import-Module .\YubikeyFido2Ssh\YubikeyFido2Ssh.psd1

# Or install permanently for the current user.
Copy-Item -Recurse .\YubikeyFido2Ssh "$HOME\Documents\PowerShell\Modules\"
Import-Module YubikeyFido2Ssh
```

## Layout

```
YubikeyFido2Ssh/
  YubikeyFido2Ssh.psd1                  # module manifest
  YubikeyFido2Ssh.psm1                  # loader: dot-sources Private/, then Public/
  Private/
    Resolve-YubikeyFidoPublicKeyPath.ps1  # shared helper, not exported
  Public/
    Install-YubikeyFidoSshKey.ps1
    Publish-YubikeyFidoSshKey.ps1
    Publish-YubikeyFidoSshKeyToAzureVM.ps1
```

Files under `Public/` are exported. Files under `Private/` are available to all
public functions but not to module consumers.

## Commands

### `Install-YubikeyFidoSshKey`

Downloads every resident FIDO2 SSH key from a connected authenticator into
`%USERPROFILE%\.ssh` (or a directory you specify) and optionally loads each
private key into `ssh-agent`.

```powershell
# Default: install to %USERPROFILE%\.ssh and load into ssh-agent.
Install-YubikeyFidoSshKey

# Custom location, overwrite existing files, skip ssh-agent loading.
Install-YubikeyFidoSshKey -SshDirectory C:\keys -Force -SkipAgent
```

| Parameter       | Description                                                                 |
| --------------- | --------------------------------------------------------------------------- |
| `-SshDirectory` | Destination folder. Defaults to `%USERPROFILE%\.ssh`.                       |
| `-Force`        | Overwrite existing files with the same name.                                |
| `-SkipAgent`    | Don't start `ssh-agent` and don't run `ssh-add`.                            |
| `-WhatIf`       | Standard `SupportsShouldProcess` dry-run.                                   |

Touch the YubiKey when prompted by `ssh-keygen -K`.

### `Publish-YubikeyFidoSshKey`

Publishes a FIDO2 public key (`*.pub`) to a Linux host's
`~/.ssh/authorized_keys` over **plain SSH**.

```powershell
# Append to authorized_keys, deduping if the key is already present (default).
Publish-YubikeyFidoSshKey -HostName server.example.com -UserName azureuser

# Pick a specific key file and a non-default SSH port.
Publish-YubikeyFidoSshKey -HostName 10.0.0.4 -UserName ubuntu -Port 2222 `
    -PublicKeyPath C:\Users\me\.ssh\id_ed25519_sk_rk_yubi5.pub

# Replace authorized_keys entirely (lockout risk; be careful).
Publish-YubikeyFidoSshKey -HostName server -UserName azureuser -WipeExistingKeys
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

### `Publish-YubikeyFidoSshKeyToAzureVM`

Same idea as above, but publishes the key via **Azure VM Run Command**, so
you don't need any inbound SSH connectivity to the VM — only Azure RBAC on
the VM resource.

```powershell
# Default: dedupe-append into ~azureuser/.ssh/authorized_keys on the VM.
Publish-YubikeyFidoSshKeyToAzureVM -ResourceGroupName my-rg -VMName my-vm

# Different OS user, explicit subscription, replace existing keys.
Publish-YubikeyFidoSshKeyToAzureVM -ResourceGroupName my-rg -VMName my-vm `
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

### `Resolve-YubikeyFidoPublicKeyPath` *(private)*

Shared helper used by both `Publish-*` functions to locate and (when needed)
prompt for the correct `.pub` file in `%USERPROFILE%\.ssh`. Not exported.

## Typical workflow

```powershell
Import-Module .\YubikeyFido2Ssh\YubikeyFido2Ssh.psd1

# 1. Pull resident keys off the YubiKey onto this PC.
Install-YubikeyFidoSshKey

# 2a. Push the public key to a reachable Linux host over SSH.
Publish-YubikeyFidoSshKey -HostName server.example.com -UserName azureuser

# 2b. ...or push it to an Azure VM without any inbound SSH.
Publish-YubikeyFidoSshKeyToAzureVM -ResourceGroupName my-rg -VMName my-vm

# 3. Log in using the YubiKey-backed key (touch when prompted).
ssh azureuser@server.example.com
```

## Notes on the Azure variant

`Publish-YubikeyFidoSshKeyToAzureVM` works around several documented pitfalls
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
