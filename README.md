# Fido2Ssh

PowerShell module for using **FIDO2 SSH keys** stored on a passkey
provider (YubiKey, other FIDO2 authenticators). Supports both **resident**
(discoverable) credentials stored on the authenticator and **non-resident
(software) passkeys** where the key handle lives on disk. Covers the full
lifecycle: create or import keys, then publish the matching public key to a
Linux host either over SSH or via the Azure VM Run Command channel.

Targets Windows PowerShell 5.1 and PowerShell 7+. Most commands also run on
PowerShell 7+ for Linux and macOS — see [Cross-platform notes](#cross-platform-notes)
below.

## Prerequisites

- An OpenSSH client (`ssh`, `ssh-keygen`, `ssh-add`).
  - **Windows**: the built-in OpenSSH Client capability. `Enable-Fido2SshKeys`
    installs and configures it for you.
  - **Linux**: distribution-provided `openssh-client` (Debian/Ubuntu) /
    `openssh-clients` (Fedora/RHEL) / `openssh` (Arch). The version must
    support FIDO2 SSH keys (OpenSSH 8.2+); recent LTS distros ship this.
  - **macOS**: Apple's bundled OpenSSH currently lacks `libfido2` support, so
    install OpenSSH via Homebrew (`brew install openssh`) and make sure it
    appears on `PATH` before `/usr/bin/ssh`.
- A FIDO2 authenticator (e.g. YubiKey 5).
- For `Publish-Fido2SshKeyToAzureVM`: Azure CLI (`az`) signed in to a tenant /
  subscription that has permission to run
  `Microsoft.Compute/virtualMachines/runCommand/action` on the target VM.

On Windows, run `Enable-Fido2SshKeys` from an **elevated** PowerShell session
to install the OpenSSH Client capability and start the `ssh-agent` service in
one go. On Linux/macOS, start the agent yourself (e.g.
`eval $(ssh-agent -s)`) before running the other cmdlets.

## Installation

```powershell
# Recommended: install the published module from the PowerShell Gallery.
Install-Module -Name Fido2Ssh -Scope CurrentUser
Import-Module Fido2Ssh

# Or load directly from a clone of this repo.
Import-Module .\Fido2Ssh\Fido2Ssh.psd1

# Or copy into the per-user module path.
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
    Enable-Fido2SshKeys.ps1
    Get-Fido2SshKey.ps1
    Import-Fido2SshKey.ps1
    New-Fido2SshKey.ps1
    Publish-Fido2SshKey.ps1
    Publish-Fido2SshKeyToAzureVM.ps1
    Remove-Fido2SshKey.ps1
```

Files under `Public/` are exported. Files under `Private/` are available to all
public functions but not to module consumers.

## Commands

### `Enable-Fido2SshKeys` (Requires an elevated session)

One-shot bootstrapper that prepares a Windows workstation for the rest of the
module: installs the OpenSSH Client Windows capability (provides `ssh`,
`ssh-keygen`, `ssh-add`) if missing, sets the `ssh-agent` service start type
to `Automatic`, and starts it. Run from an **elevated** PowerShell session.

Azure CLI is intentionally not installed by this script — install `az`
separately if you plan to use `Publish-Fido2SshKeyToAzureVM`.

```powershell
# Elevated PowerShell: install OpenSSH client + start ssh-agent.
Enable-Fido2SshKeys

# Leave ssh-agent on manual startup.
Enable-Fido2SshKeys -SshAgentStartupType Manual
```

| Parameter               | Description                                                                          |
| ----------------------- | ------------------------------------------------------------------------------------ |
| `-SshAgentStartupType`  | `Automatic` (default), `Manual`, or `Disabled` — startup mode for `ssh-agent`.       |
| `-SkipOpenSsh`          | Don't touch the OpenSSH Client capability (use when OpenSSH is provided elsewhere).  |
| `-SkipAgent`            | Don't configure or start the `ssh-agent` service.                                    |
| `-WhatIf` / `-Confirm`  | Standard `SupportsShouldProcess`.                                                    |

### `Get-Fido2SshKey`

Lists FIDO2 SSH keys currently configured in `%USERPROFILE%\.ssh` (or a
directory you specify). Scans for both **resident** keys (`id_*_sk_rk*.pub`)
and **non-resident** (software) passkeys (`id_*_sk_*.pub` without `_rk`).
Returns structured objects with parsed key metadata, file paths, and an
`IsResident` property indicating the credential type.

```powershell
# List all FIDO2 key handles in ~/.ssh (resident and non-resident).
Get-Fido2SshKey

# Filter by label fragment.
Get-Fido2SshKey -Label work

# Show only resident or only non-resident keys.
Get-Fido2SshKey -ResidentOnly
Get-Fido2SshKey -NonResidentOnly
```

| Parameter          | Description                                                                            |
| ------------------ | -------------------------------------------------------------------------------------- |
| `-SshDirectory`    | Source folder. Defaults to `%USERPROFILE%\.ssh` on Windows and `$HOME/.ssh` elsewhere. |
| `-Label`           | Optional case-insensitive substring filter against the parsed label segment.           |
| `-ResidentOnly`    | Return only resident keys (filename contains `_rk`).                                   |
| `-NonResidentOnly` | Return only non-resident (software) passkeys (filename does not contain `_rk`).        |

### `New-Fido2SshKey`

Generates a new FIDO2 SSH credential on a connected authenticator and installs
it into `%USERPROFILE%\.ssh` (or a directory you specify) using the canonical
filename layout the rest of this module expects.

By default the credential is **resident** — stored on the authenticator and
recoverable later with `Import-Fido2SshKey`. Pass `-NonResident` to create a
**software passkey** instead: the key handle lives only in the private key
file on disk. The authenticator still enforces touch (and optionally PIN) for
every use, but the credential cannot be re-imported from the authenticator if
the file is lost — **back it up**.

| Filename layout | |
|---|---|
| Resident | `id_<type>_sk_rk_<label>_<thumbprint>` |
| Non-resident | `id_<type>_sk_<label>_<thumbprint>` |

```powershell
# Interactive: prompts for e-mail and label, requires PIN + touch (resident).
New-Fido2SshKey

# Non-interactive, touch-only (no PIN), resident.
New-Fido2SshKey -Email me@example.com -Label work-laptop -NoPin

# Non-resident (software) passkey — handle lives on disk only.
New-Fido2SshKey -Email me@example.com -Label work-laptop -NonResident
```

| Parameter       | Description                                                                                                     |
| --------------- | --------------------------------------------------------------------------------------------------------------- |
| `-Email`        | Value placed in the public-key comment field. Prompted for when not supplied.                                   |
| `-Label`        | Label embedded in the FIDO application string (`ssh:<label>`) and the installed filename.                       |
| `-SshDirectory` | Destination folder. Defaults to `%USERPROFILE%\.ssh`.                                                           |
| `-KeyType`      | `ed25519-sk` (default) or `ecdsa-sk` for older authenticators.                                                  |
| `-NonResident`  | Create a non-resident (software) passkey. Omits `-O resident`; key handle lives on disk only. Back up the file. |
| `-NoPin`        | Omit the default `-O verify-required` constraint (touch-only credential).                                       |
| `-Force`        | Overwrite an existing key file with the same name.                                                               |
| `-SkipAgent`    | Don't try to add the new private key to `ssh-agent`.                                                             |
| `-WhatIf`       | Standard `SupportsShouldProcess` dry-run.                                                                        |

### `Import-Fido2SshKey` (Requires an elevated session)

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
Publish-Fido2SshKey azureuser@server.example.com

# Authenticate the bootstrap connection with an existing private key.
Publish-Fido2SshKey azureuser@131.123.32.3 -i ~/.ssh/id_rsa

# Pick a specific key file and a non-default SSH port.
Publish-Fido2SshKey ubuntu@10.0.0.4 -Port 2222 `
    -PublicKeyPath C:\Users\me\.ssh\id_ed25519_sk_rk_work-laptop_abc123def456.pub

# Replace authorized_keys entirely (lockout risk; be careful).
Publish-Fido2SshKey azureuser@server -WipeExistingKeys
```

| Parameter              | Description                                                                                                   |
| ---------------------- | ------------------------------------------------------------------------------------------------------------- |
| `-Destination`         | Required, positional. SSH-style `<user>@<host>`, e.g. `azureuser@10.0.0.4`.                                   |
| `-PublicKeyPath`       | Optional. If omitted, scans `%USERPROFILE%\.ssh` for `id_*_sk_rk*.pub` files and prompts when multiple match. |
| `-Port`                | Optional. SSH port (default `22`).                                                                            |
| `-IdentityFile` / `-i` | Optional. Existing SSH private key to authenticate the bootstrap connection (`ssh -i`).                       |
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

Cleans up FIDO2 SSH keys produced by `New-Fido2SshKey` / `Import-Fido2SshKey`.
Removes matching file pairs from `%USERPROFILE%\.ssh` (or a directory you
specify) and unloads each key from `ssh-agent`.

**Non-resident (software) passkeys are skipped by default.** Deleting the
private key handle file permanently destroys the credential — it cannot be
recovered from the authenticator. Pass `-IncludeNonResident` to explicitly
include them, and remember to also clean up the passkey from the
authenticator's credential store (Windows Hello settings, `ykman fido
credentials delete`, your browser's passkey manager, etc.).

The resident credential on the authenticator itself is never touched by this
cmdlet — use `ykman fido credentials delete` (or the equivalent) for that.

```powershell
# Interactive: list every FIDO2 resident key in ~/.ssh and confirm each removal.
# Non-resident keys found are printed but skipped.
Remove-Fido2SshKey

# Remove only keys whose label contains "work-laptop", no prompt.
Remove-Fido2SshKey -Label work-laptop -Force

# Also remove matching non-resident (software) passkeys.
Remove-Fido2SshKey -Label work-laptop -IncludeNonResident -Force

# Remove one specific key.
Remove-Fido2SshKey -PublicKeyPath C:\Users\me\.ssh\id_ed25519_sk_rk_pin_abc123def456.pub

# Files only; leave ssh-agent alone.
Remove-Fido2SshKey -SkipAgent
```

| Parameter               | Description                                                                                                        |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `-PublicKeyPath`        | Remove this specific `*.pub` and its matching private key only.                                                    |
| `-Label`                | Case-insensitive substring filter against the label segment of the canonical filename.                             |
| `-SshDirectory`         | Source folder. Defaults to `%USERPROFILE%\.ssh`.                                                                   |
| `-IncludeNonResident`   | Also remove non-resident (software) passkey file pairs. Use with care — the handle file cannot be recovered.       |
| `-SkipAgent`            | Don't touch `ssh-agent`. Files on disk are still removed.                                                          |
| `-Force`                | Skip the per-key confirmation prompt (still honours `-WhatIf` / explicit `-Confirm`).                              |
| `-WhatIf` / `-Confirm`  | Standard `SupportsShouldProcess` (declared `ConfirmImpact = 'High'`).                                              |

### Private helpers

- `Get-Fido2KeyThumbprint` / `Get-Fido2CanonicalName` — derive the short
  thumbprint and canonical filename. `Get-Fido2CanonicalName` accepts a
  `Resident` bool (default `$true`) to produce either the resident
  `id_<type>_sk_rk[_<label>]_<thumbprint>` or non-resident
  `id_<type>_sk[_<label>]_<thumbprint>` form.
- `Resolve-Fido2PublicKeyPath` — used by both `Publish-*` functions to locate
  and (when needed) prompt for the correct `.pub` file in `%USERPROFILE%\.ssh`.

Not exported.

## Typical workflow

```powershell
Import-Module .\Fido2Ssh\Fido2Ssh.psd1

# 1a. Create a brand-new resident FIDO2 SSH credential on the authenticator.
New-Fido2SshKey -Email me@example.com -Label work-laptop

# 1b. Create a non-resident (software) passkey — handle lives on disk only.
#     Back up the private key file; it cannot be re-imported from the authenticator.
New-Fido2SshKey -Email me@example.com -Label work-laptop -NonResident

# 1c. Or import resident credentials that already exist on the authenticator.
Import-Fido2SshKey

# 2. Inspect what's installed (IsResident column distinguishes key types).
Get-Fido2SshKey

# 3a. Push the public key to a reachable Linux host over SSH.
Publish-Fido2SshKey azureuser@server.example.com

# 3b. …or push it to an Azure VM without any inbound SSH.
Publish-Fido2SshKeyToAzureVM -ResourceGroupName my-rg -VMName my-vm

# 4. Log in using the FIDO2-backed key (touch when prompted).
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

## Cross-platform notes

| Command                        | Windows | Linux | macOS |
| ------------------------------ | ------- | ----- | ----- |
| `Enable-Fido2SshKeys`          | ✅      | n/a   | n/a   |
| `Get-Fido2SshKey`              | ✅      | ✅    | ✅    |
| `New-Fido2SshKey`              | ✅      | ✅    | ✅    |
| `Import-Fido2SshKey`           | ✅¹     | ✅    | ✅    |
| `Publish-Fido2SshKey`          | ✅      | ✅    | ✅    |
| `Publish-Fido2SshKeyToAzureVM` | ✅      | ✅    | ✅    |
| `Remove-Fido2SshKey`           | ✅      | ✅    | ✅    |

¹ Windows requires an elevated PowerShell session for `Import-Fido2SshKey`
(see [Import-Fido2SshKey](#import-fido2sshkey-requires-eleveated-session) above).

`Enable-Fido2SshKeys` is Windows-only — it installs the Windows OpenSSH Client
capability and configures the `ssh-agent` Windows service. On Linux/macOS
install the OpenSSH client via your package manager and manage `ssh-agent`
yourself (`eval $(ssh-agent -s)` or via your desktop keyring), then use the
other cmdlets as documented.

Default `-SshDirectory` paths follow the host OS: `%USERPROFILE%\.ssh` on
Windows, `$HOME/.ssh` on Linux/macOS.

## Security notes

- Both resident and non-resident FIDO2 SSH keys still require a **touch**
  (and, depending on how they were generated, a PIN) on the authenticator for
  every authentication.
- For **resident** keys: the private key file on disk is only a handle into
  the authenticator; it is useless without the physical device, and lost handle
  files can be re-imported with `Import-Fido2SshKey`.
- For **non-resident (software) passkeys**: the private key handle file on disk
  is the only copy. Losing it means the key is permanently gone and cannot be
  recovered from the authenticator. Keep a secure backup.
- `-WipeExistingKeys` will remove **all** other entries from the remote
  `authorized_keys`. Make sure you have a recovery path (console access,
  another admin user, Azure Bastion, etc.) before using it.
- Keep `%USERPROFILE%\.ssh` ACL'd to your user only, just like any other
  SSH key directory.

## CI/CD

Two GitHub Actions workflows live under [.github/workflows/](.github/workflows/):

- [ci.yml](.github/workflows/ci.yml) — runs on every push and pull request to
  `main`. Runs `PSScriptAnalyzer` (errors fail the build, warnings are surfaced)
  and validates the module manifest / import on Windows and Linux runners.
- [publish.yml](.github/workflows/publish.yml) — publishes the module to the
  [PowerShell Gallery](https://www.powershellgallery.com/) when a `v*.*.*` tag
  is pushed, or on manual `workflow_dispatch` with an explicit version. The
  workflow stamps the resolved version into `Fido2Ssh.psd1` via
  `Update-ModuleManifest` before calling `Publish-Module`.

### AI Disclaimer
Most of the heavy lifting of this module has been done by Github Copilot using various models. 