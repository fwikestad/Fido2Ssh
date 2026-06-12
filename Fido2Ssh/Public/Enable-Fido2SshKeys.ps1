function Enable-Fido2SshKeys {
    <#
    .SYNOPSIS
        Bootstraps a Windows machine for using resident FIDO2 SSH keys.

    .DESCRIPTION
        One-shot bootstrapper that prepares a Windows workstation to use the
        rest of the Fido2Ssh module:

          * Installs the OpenSSH Client Windows capability if missing
            (provides `ssh`, `ssh-keygen`, `ssh-add`).
          * Sets the `ssh-agent` service start type to `Automatic` (override
            via `-SshAgentStartupType`) and starts it.
          * Verifies the OpenSSH client tools resolve on PATH.

        Azure CLI is intentionally **not** installed. If you plan to use
        `Publish-Fido2SshKeyToAzureVM`, install `az` separately (e.g.
        `winget install Microsoft.AzureCLI`).

        Installing the OpenSSH Windows capability and changing the
        `ssh-agent` service require an elevated PowerShell session. If the
        capability is already installed and the service is already configured
        correctly, the script can run unelevated.

    .PARAMETER SshAgentStartupType
        Desired Windows service startup type for `ssh-agent`. Defaults to
        `Automatic`. Use `Manual` if you prefer to start the agent on demand.

    .PARAMETER SkipOpenSsh
        Don't touch the OpenSSH Client Windows capability. Use when OpenSSH
        is provided by another mechanism (e.g. a portable install on PATH).

    .PARAMETER SkipAgent
        Don't configure or start the `ssh-agent` service.

    .EXAMPLE
        Enable-Fido2SshKeys

        Installs OpenSSH Client (if missing) and configures + starts the
        ssh-agent service. Run from an elevated PowerShell session.

    .EXAMPLE
        Enable-Fido2SshKeys -SshAgentStartupType Manual

        Same as above but leaves ssh-agent on manual startup.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [ValidateSet('Automatic', 'Manual', 'Disabled')]
        [string]$SshAgentStartupType = 'Automatic',
        [switch]$SkipOpenSsh,
        [switch]$SkipAgent
    )

    if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
        throw "Enable-Fido2SshKeys is Windows-only."
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )

    # -- 1. OpenSSH Client Windows capability ---------------------------------
    if (-not $SkipOpenSsh) {
        $capabilityName = 'OpenSSH.Client~~~~0.0.1.0'
        $capability     = $null
        try {
            $capability = Get-WindowsCapability -Online -Name $capabilityName -ErrorAction Stop
        } catch {
            Write-Warning "Could not query Windows capabilities ($($_.Exception.Message)). Falling back to PATH detection."
        }

        if ($capability -and $capability.State -eq 'Installed') {
            Write-Host "OpenSSH Client capability already installed."
        } elseif ($capability) {
            if (-not $isAdmin) {
                throw "OpenSSH Client capability is not installed. Re-run from an elevated PowerShell session, or install it manually: Add-WindowsCapability -Online -Name $capabilityName"
            }
            if ($PSCmdlet.ShouldProcess($capabilityName, 'Add-WindowsCapability -Online')) {
                Write-Host "Installing OpenSSH Client Windows capability..."
                $result = Add-WindowsCapability -Online -Name $capabilityName -ErrorAction Stop
                if ($result.RestartNeeded) {
                    Write-Warning "OpenSSH Client installed. A reboot is recommended before using ssh-agent."
                } else {
                    Write-Host "OpenSSH Client installed."
                }
            }
        } else {
            # Couldn't query capability state; rely on PATH check below.
        }

        foreach ($tool in @('ssh', 'ssh-keygen', 'ssh-add')) {
            if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
                Write-Warning "$tool was not found on PATH after installation. You may need to open a new shell or reboot."
            }
        }
    } else {
        Write-Verbose "Skipping OpenSSH Client install (-SkipOpenSsh)."
    }

    # -- 2. ssh-agent service -------------------------------------------------
    if (-not $SkipAgent) {
        $service = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
        if (-not $service) {
            Write-Warning "ssh-agent service is not registered. Install OpenSSH Client first (run without -SkipOpenSsh from an elevated shell)."
        } else {
            $currentStartup = (Get-CimInstance -ClassName Win32_Service -Filter "Name='ssh-agent'" -ErrorAction SilentlyContinue).StartMode
            # Win32_Service.StartMode returns 'Auto' / 'Manual' / 'Disabled'.
            $desired = $SshAgentStartupType
            $needChange = $true
            if ($currentStartup -eq 'Auto' -and $desired -eq 'Automatic') { $needChange = $false }
            elseif ($currentStartup -eq $desired) { $needChange = $false }

            if ($needChange) {
                if (-not $isAdmin) {
                    Write-Warning "ssh-agent startup type is '$currentStartup'; cannot change to '$desired' without elevation. Re-run elevated or pass -SkipAgent."
                } elseif ($PSCmdlet.ShouldProcess('ssh-agent', "Set-Service -StartupType $desired")) {
                    Set-Service -Name ssh-agent -StartupType $desired -ErrorAction Stop
                    Write-Host "ssh-agent startup type set to $desired."
                }
            } else {
                Write-Verbose "ssh-agent startup type already '$desired'."
            }

            $service.Refresh()
            if ($service.Status -ne 'Running' -and $desired -ne 'Disabled') {
                if ($PSCmdlet.ShouldProcess('ssh-agent', 'Start-Service')) {
                    try {
                        Start-Service -Name ssh-agent -ErrorAction Stop
                        Write-Host "ssh-agent service started."
                    } catch {
                        if (-not $isAdmin) {
                            Write-Warning "Could not start ssh-agent: $($_.Exception.Message). Re-run from an elevated session."
                        } else {
                            throw
                        }
                    }
                }
            } else {
                Write-Host "ssh-agent service status: $($service.Status)."
            }
        }
    } else {
        Write-Verbose "Skipping ssh-agent configuration (-SkipAgent)."
    }

    Write-Host ""
    Write-Host "Fido2Ssh prerequisites OK. Next steps:"
    Write-Host "  - Plug in your FIDO2 authenticator."
    Write-Host "  - Create a key:  New-Fido2SshKey"
    Write-Host "  - Or import existing resident keys:  Import-Fido2SshKey"
}
