[CmdletBinding()]
param(
    [string]$BinDir = (Join-Path $env:LOCALAPPDATA "Programs\Terraform"),
    [string]$Archive,
    [switch]$AddToUserPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($PSVersionTable.PSVersion -lt [Version]"5.1") {
    throw "PowerShell 5.1 or newer is required."
}
if ($env:OS -cne "Windows_NT") {
    throw "This installer supports Windows only."
}
$NativeArchitecture = $env:PROCESSOR_ARCHITEW6432
if ([string]::IsNullOrWhiteSpace($NativeArchitecture)) {
    $NativeArchitecture = $env:PROCESSOR_ARCHITECTURE
}
if ($NativeArchitecture -cne "AMD64") {
    throw "This installer supports Windows x64 only."
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor `
    [Net.SecurityProtocolType]::Tls12

if (Test-Path -LiteralPath (Join-Path $PSScriptRoot ".terraform-version")) {
    $ProjectDir = $PSScriptRoot
}
else {
    $ProjectDir = Split-Path -Parent $PSScriptRoot
}
$Version = (Get-Content -LiteralPath (Join-Path $ProjectDir ".terraform-version") -Raw).Trim()
$ArchiveName = "terraform_${Version}_windows_amd64.zip"
$PinnedSha256 = "2FF41D2129AFB1982733C132C61A8D6EF038F879F3AEEDE7FC28B8B8B24ACF02"
$TemporaryDir = Join-Path ([System.IO.Path]::GetTempPath()) ("terraform-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $TemporaryDir | Out-Null

try {
    if ($Archive) {
        $ArchivePath = (Resolve-Path -LiteralPath $Archive).Path
        if ([System.IO.Path]::GetFileName($ArchivePath) -ne $ArchiveName) {
            throw "Archive must be named $ArchiveName"
        }
    }
    else {
        $ArchivePath = Join-Path $TemporaryDir $ArchiveName
        $Uri = "https://releases.hashicorp.com/terraform/$Version/$ArchiveName"
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $ArchivePath
    }

    $ActualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $ArchivePath).Hash
    if ($ActualSha256 -ne $PinnedSha256) {
        throw "Terraform archive checksum mismatch."
    }

    $ExtractDir = Join-Path $TemporaryDir "extracted"
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractDir
    New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
    $Target = Join-Path $BinDir "terraform.exe"
    Copy-Item -Force -LiteralPath (Join-Path $ExtractDir "terraform.exe") -Destination $Target

    if ($AddToUserPath) {
        $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $PathEntries = @($UserPath -split ";" | Where-Object { $_ })
        if ($PathEntries -notcontains $BinDir) {
            $NewUserPath = (@($PathEntries) + $BinDir) -join ";"
            [Environment]::SetEnvironmentVariable("Path", $NewUserPath, "User")
        }
        if (($env:Path -split ";") -notcontains $BinDir) {
            $env:Path = "$BinDir;$env:Path"
        }
    }

    Write-Host "Installed Terraform $Version to $Target"
    & $Target version
    if ($LASTEXITCODE -ne 0) { throw "Installed Terraform did not start." }
}
finally {
    Remove-Item -LiteralPath $TemporaryDir -Recurse -Force -ErrorAction SilentlyContinue
}
