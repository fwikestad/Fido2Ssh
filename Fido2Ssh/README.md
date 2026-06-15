# Fido2Ssh

PowerShell module for using **FIDO2 SSH keys** — both resident (discoverable)
and non-resident (software) passkeys — stored on a hardware authenticator
(YubiKey, other FIDO2 devices).

Targets Windows PowerShell 5.1 and PowerShell 7+.

## Install

```powershell
Install-Module -Name Fido2Ssh -Scope CurrentUser
Import-Module Fido2Ssh
```

## Commands

- `Enable-Fido2SshKeys`
- `Get-Fido2SshKey`
- `New-Fido2SshKey` — pass `-NonResident` for a software passkey
- `Import-Fido2SshKey`
- `Publish-Fido2SshKey`
- `Publish-Fido2SshKeyToAzureVM`
- `Remove-Fido2SshKey`

Run `Get-Help <Command> -Full` for parameter details and examples.

## Documentation, source, and issues

Full documentation, end-to-end workflow examples, security notes, and the
issue tracker live in the GitHub repository:

**https://github.com/fwikestad/Fido2Ssh**

## License

[MIT](https://github.com/fwikestad/Fido2Ssh/blob/main/LICENSE) © fwikestad
