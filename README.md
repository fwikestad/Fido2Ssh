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

## Key types

### Resident keys (default)  **Hardware security keys only**

Resident (discoverable) credentials are **stored on the authenticator itself**.
The private key file on disk is only a handle; the actual key material lives
on the device.

```powershell
New-Fido2SshKey -Email me@example.com -Label work-laptop
```

- Recoverable from the authenticator with `Import-Fido2SshKey`.
- Filename: `id_<type>_sk_rk_<label>_<thumbprint>`

### Non-resident passkeys

**Supports hardware and software security keys, so can be used with ie. both Windows Hello and Yubikey**

The credential handle is stored **only in the private key file on disk** — not
on the authenticator. The authenticator still enforces touch (and optionally
PIN) for every use, but the credential cannot be recovered if the file is lost.
**Back up the private key file.**

```powershell
New-Fido2SshKey -Email me@example.com -Label work-laptop -NonResident
```

- Cannot be re-imported from the authenticator.
- Filename: `id_<type>_sk_<label>_<thumbprint>` (no `_rk`)

### Comparison

| Feature | Resident | Non-resident |
|---------|----------|--------------|
| Credential stored on authenticator | ✅ | ❌ |
| Recoverable with `Import-Fido2SshKey` | ✅ | ❌ |
| Touch required per use | ✅ | ✅ |
| PIN support (`-NoPin` to disable) | ✅ | ✅ |
| Multiple keys per authenticator | via label | via label |

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

# 2. Inspect what is installed (IsResident column distinguishes key types).
Get-Fido2SshKey

# 3a. Push the public key to a reachable Linux host over SSH.
Publish-Fido2SshKey azureuser@server.example.com

# 3b. Or push it to an Azure VM without any inbound SSH.
Publish-Fido2SshKeyToAzureVM -ResourceGroupName my-rg -VMName my-vm

# 4. Log in using the FIDO2-backed key (touch when prompted).
ssh azureuser@server.example.com
```

For full parameter details on every command see [REFERENCE.md](REFERENCE.md).

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
(raw HID access to the authenticator is reserved for elevated processes).

`Enable-Fido2SshKeys` is Windows-only — it installs the Windows OpenSSH Client
capability and configures the `ssh-agent` Windows service. On Linux/macOS
install the OpenSSH client via your package manager and manage `ssh-agent`
yourself (`eval $(ssh-agent -s)` or via your desktop keyring), then use the
other cmdlets as documented.

Default `-SshDirectory` paths follow the host OS: `%USERPROFILE%\.ssh` on
Windows, `$HOME/.ssh` on Linux/macOS.

## Security notes

- Both resident and non-resident FIDO2 SSH keys require a **touch** (and,
  depending on how they were generated, a PIN) on the authenticator for every
  authentication.
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

### Releasing a new version

1. Configure a repository secret named `PSGALLERY_API_KEY` in the `PSGallery`
   GitHub Environment (Settings → Environments). Generate the key at
   <https://www.powershellgallery.com/account/apikeys> scoped to the
   `Fido2Ssh` package.
2. Tag the release commit and push the tag:

   ```powershell
   git tag v0.2.0
   git push origin v0.2.0
   ```

3. Watch the **Publish to PSGallery** workflow run on the Actions tab. After it
   succeeds the new version is live on the gallery within a few minutes.

### AI Disclaimer
Most of the heavy lifting of this module has been done by Github Copilot using various models.
