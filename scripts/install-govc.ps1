[CmdletBinding()]
param(
    [string]$BinDir = (Join-Path $env:LOCALAPPDATA "Programs\govc"),
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

if (Test-Path -LiteralPath (Join-Path $PSScriptRoot ".govc-version")) {
    $ProjectDir = $PSScriptRoot
}
else {
    $ProjectDir = Split-Path -Parent $PSScriptRoot
}
$Version = (Get-Content -LiteralPath (Join-Path $ProjectDir ".govc-version") -Raw).Trim()
$ArchiveName = "govc_Windows_x86_64.zip"
$PinnedSha256 = "4ABB6CBD441311F2D9FFDB37F00497A44CEF7DFFA4BD1CE38D59E526D52CDD70"
$TemporaryDir = Join-Path ([System.IO.Path]::GetTempPath()) ("govc-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $TemporaryDir | Out-Null

try {
    if ($Archive) {
        $ArchivePath = (Resolve-Path -LiteralPath $Archive).Path
        if ([System.IO.Path]::GetFileName($ArchivePath) -cne $ArchiveName) {
            throw "Archive must be named $ArchiveName"
        }
    }
    else {
        $ArchivePath = Join-Path $TemporaryDir $ArchiveName
        $Uri = "https://github.com/vmware/govmomi/releases/download/v$Version/$ArchiveName"
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $ArchivePath
    }

    $ActualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $ArchivePath).Hash
    if ($ActualSha256 -cne $PinnedSha256) {
        throw "govc archive checksum mismatch."
    }

    $ExtractDir = Join-Path $TemporaryDir "extracted"
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractDir
    New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
    $Target = Join-Path $BinDir "govc.exe"
    Copy-Item -Force -LiteralPath (Join-Path $ExtractDir "govc.exe") -Destination $Target

    if ($AddToUserPath) {
        $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $PathEntries = @($UserPath -split ";" | Where-Object { $_ })
        if ($PathEntries -notcontains $BinDir) {
            [Environment]::SetEnvironmentVariable(
                "Path",
                (@($PathEntries) + $BinDir) -join ";",
                "User"
            )
        }
        if (($env:Path -split ";") -notcontains $BinDir) {
            $env:Path = "$BinDir;$env:Path"
        }
    }

    Write-Host "Installed govc $Version to $Target"
    & $Target version
    if ($LASTEXITCODE -ne 0) { throw "Installed govc did not start." }
}
finally {
    Remove-Item -LiteralPath $TemporaryDir -Recurse -Force -ErrorAction SilentlyContinue
}
