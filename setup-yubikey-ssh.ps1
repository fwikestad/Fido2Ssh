$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceCandidates = @(
    (Join-Path $scriptDir 'libykcs11.dll'),
    (Join-Path $scriptDir 'libyks11.dll')
)

$sourcePath = $null
foreach ($candidate in $sourceCandidates) {
    if (Test-Path -LiteralPath $candidate) {
        $sourcePath = $candidate
        break
    }
}

if (-not $sourcePath) {
    throw "Could not find libykcs11.dll (or libyks11.dll) in $scriptDir"
}

$sshDir = Join-Path $HOME '.ssh'
if (-not (Test-Path -LiteralPath $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir | Out-Null
}

$destinationPath = Join-Path $sshDir (Split-Path -Leaf $sourcePath)
Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force

Write-Host "Copied: $sourcePath -> $destinationPath"

# Extract and store the YubiKey authentication public key
$publicKeyPath = Join-Path $sshDir 'yubikey_auth_key.pub'
Write-Host "Extracting YubiKey authentication public key..."

try {
    $publicKeyOutput = & ssh-keygen -D $destinationPath -e 2>&1
    if ($LASTEXITCODE -eq 0) {
        # Filter for authentication key (may contain multiple keys)
        $keys = @($publicKeyOutput) -split '\n' | Where-Object { $_ -match '\S' }
        $authKey = $keys | Where-Object { $_ -match '(?i)(auth|authentication)' } | Select-Object -First 1
        
        if (-not $authKey) {
            # If no explicit auth label, use the first key
            $authKey = $keys | Select-Object -First 1
            Write-Host "No authentication label found, using first key"
        }
        
        Set-Content -LiteralPath $publicKeyPath -Value $authKey
        Write-Host "Stored YubiKey authentication public key: $publicKeyPath"
    } else {
        Write-Warning "Failed to extract YubiKey public key. ssh-keygen returned exit code $LASTEXITCODE"
    }
} catch {
    Write-Warning "Error extracting YubiKey public key: $_"
}

$configPath = Join-Path $sshDir 'config'
if (-not (Test-Path -LiteralPath $configPath)) {
    New-Item -ItemType File -Path $configPath | Out-Null
}

$configLinePath = $destinationPath -replace '\\', '/'
$desiredLine = "PKCS11Provider $configLinePath"

$lines = @()
if (Test-Path -LiteralPath $configPath) {
    $lines = Get-Content -LiteralPath $configPath
}

$providerRegex = '(?i)^\s*PKCS11Provider\s+'
$foundProvider = $false
$result = New-Object System.Collections.Generic.List[string]

foreach ($line in $lines) {
    if ($line -match $providerRegex) {
        if (-not $foundProvider) {
            $result.Add($desiredLine)
            $foundProvider = $true
        }
    }
    else {
        $result.Add($line)
    }
}

if (-not $foundProvider) {
    $result.Add($desiredLine)
}

Set-Content -LiteralPath $configPath -Value $result

Write-Host "Updated SSH config: $configPath"
Write-Host "Configured: $desiredLine"

# Add .ssh directory to PATH if not already present
if ($env:PATH -notlike "*$sshDir*") {
    $env:PATH = "$sshDir;$env:PATH"
    [Environment]::SetEnvironmentVariable("PATH", $env:PATH, [EnvironmentVariableTarget]::User)
    Write-Host "Added $sshDir to PATH"
} else {
    Write-Host "$sshDir is already in PATH"
}
