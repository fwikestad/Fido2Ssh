@{
    RootModule        = 'YubikeyFido2Ssh.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'f3c2b1a4-6d7e-4b8a-9c3f-1a2b3c4d5e6f'
    Author            = 'fwikestad'
    Description       = 'Helpers for downloading and publishing YubiKey FIDO2 resident SSH keys from Windows.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Install-YubikeyFidoSshKey',
        'New-YubikeyFidoSshKey',
        'Publish-YubikeyFidoSshKey',
        'Publish-YubikeyFidoSshKeyToAzureVM'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('YubiKey', 'FIDO2', 'SSH', 'Azure')
            ProjectUri = 'https://github.com/fwikestad/Auth'
        }
    }
}
