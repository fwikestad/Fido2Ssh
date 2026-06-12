@{
    RootModule        = 'Fido2Ssh.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'f3c2b1a4-6d7e-4b8a-9c3f-1a2b3c4d5e6f'
    Author            = 'fwikestad'
    Description       = 'Helpers for importing and publishing resident FIDO2 SSH keys (YubiKey, other passkey providers) from Windows.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Enable-Fido2SshKeys',
        'Import-Fido2SshKey',
        'New-Fido2SshKey',
        'Publish-Fido2SshKey',
        'Publish-Fido2SshKeyToAzureVM',
        'Remove-Fido2SshKey'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('FIDO2', 'Passkey', 'SSH', 'Azure', 'YubiKey')
            ProjectUri = 'https://github.com/fwikestad/Auth'
            LicenseUri = 'https://github.com/fwikestad/Auth/blob/main/LICENSE'
        }
    }
}
