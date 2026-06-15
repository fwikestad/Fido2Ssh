# Fido2Ssh

PowerShell module for using **FIDO2 SSH keys** stored on a passkey provider
(YubiKey, other FIDO2 authenticators). Covers the full lifecycle: create or
import keys, then publish the matching public key to a Linux host either over
SSH or via the Azure VM Run Command channel.

Both **resident** (discoverable) and **non-resident (software) passkey**
credential types are supported — see [Key types](#key-types) below.

Targets Windows PowerShell 5.1 and PowerShell 7+. Most commands also run on
PowerShell 7+ for Linux and macOS; `Enable-Fido2SshKeys` is Windows-only.

## Install

```powershell
Install-Module -Name Fido2Ssh -Scope CurrentUser
Import-Module Fido2Ssh
```

## Commands

- `Enable-Fido2SshKeys` — install OpenSSH Client capability and start `ssh-agent`.
- `Get-Fido2SshKey` — list FIDO2 SSH keys in `~/.ssh` (resident and non-resident). Includes `IsResident` property.
- `New-Fido2SshKey` — create a new FIDO2 SSH credential. Pass `-NonResident` for a software passkey.
- `Import-Fido2SshKey` — extract **resident** FIDO2 SSH keys from the authenticator into `~/.ssh`.
- `Publish-Fido2SshKey` — push a FIDO2 public key to a Linux host's `authorized_keys` over SSH.
- `Publish-Fido2SshKeyToAzureVM` — same, but via Azure VM Run Command (no inbound SSH needed).
- `Remove-Fido2SshKey` — clean up FIDO2 SSH key files and unload them from `ssh-agent`.

Run `Get-Help <Command> -Full` for parameter details and examples.

## Key types

### Resident keys (default)

```powershell
New-Fido2SshKey -Email me@example.com -Label work-laptop
```

The credential is stored on the authenticator itself (`-O resident`). Key
files on disk are handles only — the actual key material lives on the device.
Lost handle files can be re-imported with `Import-Fido2SshKey`. Files follow
the naming convention `id_<type>_sk_rk_<label>_<thumbprint>`.

### Non-resident (software) passkeys

```powershell
New-Fido2SshKey -Email me@example.com -Label work-laptop -NonResident
```

The credential handle is stored **only** in the private key file on disk — not
on the authenticator. The authenticator still provides touch (and optionally
PIN) for every use, but the key cannot be re-imported if the file is lost.
**Back up the private key file.** Files follow the naming convention
`id_<type>_sk_<label>_<thumbprint>` (no `_rk`).

| Feature | Resident | Non-resident |
|---------|----------|--------------|
| Credential stored on authenticator | ✅ | ❌ |
| Recoverable with `Import-Fido2SshKey` | ✅ | ❌ |
| Touch required per use | ✅ | ✅ |
| PIN support (`-NoPin` to disable) | ✅ | ✅ |
| Multiple keys per authenticator | via label | via label |

### Listing keys

```powershell
Get-Fido2SshKey              # all keys, IsResident property shows type
Get-Fido2SshKey -ResidentOnly
Get-Fido2SshKey -NonResidentOnly
```

### Removing non-resident keys

Non-resident keys are **skipped by default** in `Remove-Fido2SshKey` because
deleting the file destroys the credential permanently. Pass
`-IncludeNonResident` to explicitly remove them, and remember to also clean
up the associated passkey from your authenticator's credential store (e.g.
Windows Hello settings, `ykman fido credentials delete`, or your browser's
passkey manager).

## Documentation, source, and issues

Full documentation, the typical end-to-end workflow, security notes, and the
issue tracker live in the GitHub repository:

**https://github.com/fwikestad/Fido2Ssh**

## License

[MIT](https://github.com/fwikestad/Fido2Ssh/blob/main/LICENSE) © fwikestad
