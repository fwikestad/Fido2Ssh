# YubiKey FIDO OpenSSH Installer

This repository contains a PowerShell helper that downloads resident SSH FIDO credentials from a YubiKey and installs them into the current user's OpenSSH client profile.

## What it does

- Runs `ssh-keygen -K` to download resident FIDO SSH credentials from the attached YubiKey.
- Moves the extracted private and public key files into `%USERPROFILE%\.ssh`.
- Tries to start `ssh-agent` and load the private keys with `ssh-add`.

## Requirements

- Windows with the OpenSSH Client feature installed.
- A YubiKey with resident SSH FIDO credentials already created.
- PowerShell.

## Usage

```powershell
./install-yubikey-fido-ssh.ps1
```

Useful options:

```powershell
./install-yubikey-fido-ssh.ps1 -Force
./install-yubikey-fido-ssh.ps1 -SkipAgent
./install-yubikey-fido-ssh.ps1 -SshDirectory "$env:USERPROFILE\.ssh"
```

If `ssh-agent` is disabled, run the script in an elevated PowerShell session so it can enable or start the service.