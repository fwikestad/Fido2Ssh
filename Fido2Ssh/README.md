# Fido2Ssh

PowerShell module for using **resident FIDO2 SSH keys** stored on a passkey
provider (YubiKey, other FIDO2 authenticators) from Windows. Covers the full
lifecycle: create the keys on the authenticator, import them onto a
workstation, then publish the matching public key to a Linux host either over
SSH or via the Azure VM Run Command channel.

Targets Windows PowerShell 5.1 and PowerShell 7+.

## Install

```powershell
Install-Module -Name Fido2Ssh -Scope CurrentUser
Import-Module Fido2Ssh
```

## Commands

- `Enable-Fido2SshKeys` — install OpenSSH Client capability and start `ssh-agent`.
- `New-Fido2SshKey` — create a new resident FIDO2 SSH credential on the authenticator.
- `Import-Fido2SshKey` — extract resident FIDO2 SSH keys from the authenticator into `~/.ssh`.
- `Publish-Fido2SshKey` — push a FIDO2 public key to a Linux host's `authorized_keys` over SSH.
- `Publish-Fido2SshKeyToAzureVM` — same, but via Azure VM Run Command (no inbound SSH needed).
- `Remove-Fido2SshKey` — clean up FIDO2 SSH key files and unload them from `ssh-agent`.

Run `Get-Help <Command> -Full` for parameter details and examples.

## Documentation, source, and issues

Full documentation, the typical end-to-end workflow, security notes, and the
issue tracker live in the GitHub repository:

**https://github.com/fwikestad/Auth**

## License

[MIT](https://github.com/fwikestad/Auth/blob/main/LICENSE) © fwikestad
