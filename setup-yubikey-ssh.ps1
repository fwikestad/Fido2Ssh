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
Move-Item -LiteralPath $sourcePath -Destination $destinationPath -Force

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

Write-Host "Moved: $sourcePath -> $destinationPath"
Write-Host "Updated SSH config: $configPath"
Write-Host "Configured: $desiredLine"
