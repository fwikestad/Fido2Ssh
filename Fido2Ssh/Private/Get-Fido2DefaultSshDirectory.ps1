function Get-Fido2DefaultSshDirectory {
    <#
    .SYNOPSIS
        Returns the default per-user SSH directory for the current OS.

    .DESCRIPTION
        Used as the default value for `-SshDirectory` parameters on the
        public cmdlets. Resolves to `%USERPROFILE%\.ssh` on Windows and
        `$HOME/.ssh` on Linux/macOS. Falls back to
        `[Environment]::GetFolderPath('UserProfile')` when neither
        environment variable is populated (some sandboxed PS 7 hosts).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # PowerShell 7+ exposes $IsWindows; Windows PowerShell 5.1 does not.
    $isWindowsHost = if (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue) {
        [bool]$IsWindows
    } else {
        $true
    }

    # `$home` is a PowerShell automatic variable; use a distinct name here
    # so Set-StrictMode doesn't surface an "assigning to an automatic
    # variable" warning under PSScriptAnalyzer.
    $homeDir = if ($isWindowsHost) {
        if ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath('UserProfile') }
    } else {
        if ($env:HOME) { $env:HOME } else { [Environment]::GetFolderPath('UserProfile') }
    }

    if ([string]::IsNullOrWhiteSpace($homeDir)) {
        throw "Could not determine the user's home directory. Pass -SshDirectory explicitly."
    }

    return (Join-Path $homeDir '.ssh')
}
