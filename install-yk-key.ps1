param(
	[Parameter(Mandatory = $true)]
	[string]$RemoteHost,

	[string]$RemoteUser,

	[int]$Port = 22,

	[string]$Pkcs11Path,

	[int]$KeyIndex = 1,

	[switch]$AllKeys
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-Pkcs11Provider {
	param(
		[string]$ExplicitPath
	)

	$candidates = New-Object System.Collections.Generic.List[string]

	if ($ExplicitPath) {
		$candidates.Add($ExplicitPath)
	}

	$candidates.Add((Join-Path $PSScriptRoot 'libykcs11.dll'))
	$candidates.Add((Join-Path $HOME '.ssh\libykcs11.dll'))
	$candidates.Add('C:\Program Files\Yubico\Yubico PIV Tool\bin\libykcs11.dll')
	$candidates.Add('C:\Program Files (x86)\Yubico\Yubico PIV Tool\bin\libykcs11.dll')

	foreach ($path in $candidates) {
		if ($path -and (Test-Path -LiteralPath $path)) {
			return $path
		}
	}

	throw "Unable to find libykcs11.dll. Install Yubico PIV Tool or pass -Pkcs11Path explicitly."
}

function Invoke-CheckedCommand {
	param(
		[Parameter(Mandatory = $true)]
		[string]$FilePath,

		[Parameter(Mandatory = $true)]
		[string[]]$Arguments,

		[Parameter(Mandatory = $true)]
		[string]$FailureMessage
	)

	$output = & $FilePath @Arguments 2>&1
	if ($LASTEXITCODE -ne 0) {
		$text = ($output | Out-String).Trim()
		throw "$FailureMessage`n$text"
	}

	return $output
}

function Get-YubiKeyPublicKeys {
	param(
		[Parameter(Mandatory = $true)]
		[string]$ProviderPath
	)

	$raw = Invoke-CheckedCommand -FilePath 'ssh-keygen' -Arguments @('-D', $ProviderPath, '-e') -FailureMessage 'Failed to export keys from YubiKey PKCS#11 provider.'

	$keys = New-Object System.Collections.Generic.List[string]
	foreach ($line in $raw) {
		$trimmed = "$line".Trim()
		if ($trimmed -match '^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp\d+)\s+\S+\s+Public key for PIV Authentication$') {
			$keys.Add($trimmed)
		}
	}

	if ($keys.Count -eq 0) {
		throw 'No SSH key labeled "Public key for PIV Authentication" was returned by ssh-keygen -D.'
	}

	return $keys | Select-Object -Unique
}

function Get-RemoteTarget {
	param(
		[Parameter(Mandatory = $true)]
		[string]$HostName,
		[string]$UserName
	)

	if ([string]::IsNullOrWhiteSpace($UserName)) {
		return $HostName
	}

	return "$UserName@$HostName"
}

function Escape-ForSingleQuotedShellString {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Text
	)

	return $Text -replace "'", "'\"'\"'"
}

$provider = Resolve-Pkcs11Provider -ExplicitPath $Pkcs11Path
$allExportedKeys = @(Get-YubiKeyPublicKeys -ProviderPath $provider)

if (-not $AllKeys) {
	if ($KeyIndex -lt 1 -or $KeyIndex -gt $allExportedKeys.Count) {
		throw "KeyIndex must be between 1 and $($allExportedKeys.Count)."
	}

	$selectedKeys = @($allExportedKeys[$KeyIndex - 1])
}
else {
	$selectedKeys = $allExportedKeys
}

$remoteTarget = Get-RemoteTarget -HostName $RemoteHost -UserName $RemoteUser

$sshBaseArgs = New-Object System.Collections.Generic.List[string]
if ($Port -ne 22) {
	$sshBaseArgs.Add('-p')
	$sshBaseArgs.Add("$Port")
}
$sshBaseArgs.Add($remoteTarget)

$prepCommand = 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
Invoke-CheckedCommand -FilePath 'ssh' -Arguments @($sshBaseArgs + $prepCommand) -FailureMessage "Failed to initialize ~/.ssh on remote host $remoteTarget."

$installedCount = 0
foreach ($publicKey in $selectedKeys) {
	$escapedKey = Escape-ForSingleQuotedShellString -Text $publicKey
	$installCommand = "grep -qxF '$escapedKey' ~/.ssh/authorized_keys || echo '$escapedKey' >> ~/.ssh/authorized_keys"

	Invoke-CheckedCommand -FilePath 'ssh' -Arguments @($sshBaseArgs + $installCommand) -FailureMessage "Failed to install key on remote host $remoteTarget."
	$installedCount++
}

Write-Host "PKCS#11 provider: $provider"
Write-Host "Exported keys found: $($allExportedKeys.Count)"
Write-Host "Installed keys: $installedCount"
Write-Host "Remote target: $remoteTarget"
