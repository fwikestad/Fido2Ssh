function Test-Fido2WindowsElevation {
    <#
    .SYNOPSIS
        Returns $true when the current Windows session is running elevated, or $true on non-Windows platforms.

    .DESCRIPTION
        Used by Import-Fido2SshKey to produce an actionable error when
        ssh-keygen -K fails on Windows without administrator rights. Windows
        OpenSSH needs direct USB-HID access to the authenticator to enumerate
        resident credentials, and that path is reserved for elevated processes;
        non-elevated sessions fall through to the WebAuthn API which does not
        expose CTAP2 credential enumeration.

        On non-Windows platforms (or if the check itself throws) the function
        returns $true so callers degrade quietly to the generic error path.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    # PowerShell 7+ exposes $IsWindows; Windows PowerShell 5.1 does not.
    $isWindowsHost = if (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue) {
        [bool]$IsWindows
    } else {
        $true
    }

    if (-not $isWindowsHost) { return $true }

    try {
        $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $true
    }
}
