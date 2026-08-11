[CmdletBinding()]
param(
    [string]$BinDir = (Join-Path $env:LOCALAPPDATA "Programs\jq"),
    [string]$Binary,
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

if (Test-Path -LiteralPath (Join-Path $PSScriptRoot ".jq-version")) {
    $ProjectDir = $PSScriptRoot
}
else {
    $ProjectDir = Split-Path -Parent $PSScriptRoot
}
$Version = (Get-Content -LiteralPath (Join-Path $ProjectDir ".jq-version") -Raw).Trim()
$BinaryName = "jq-windows-amd64.exe"
$PinnedSha256 = "A6FC67FEDAF9128A3309A1E2EBB8B986AECCF70122EE46D2CB4849E423F0C627"
$TemporaryDir = Join-Path ([System.IO.Path]::GetTempPath()) ("jq-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $TemporaryDir | Out-Null

try {
    if ($Binary) {
        $BinaryPath = (Resolve-Path -LiteralPath $Binary).Path
        if ([System.IO.Path]::GetFileName($BinaryPath) -cne $BinaryName) {
            throw "Binary must be named $BinaryName"
        }
    }
    else {
        $BinaryPath = Join-Path $TemporaryDir $BinaryName
        $Uri = "https://github.com/jqlang/jq/releases/download/jq-$Version/$BinaryName"
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $BinaryPath
    }

    $ActualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $BinaryPath).Hash
    if ($ActualSha256 -cne $PinnedSha256) {
        throw "jq binary checksum mismatch."
    }

    New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
    $Target = Join-Path $BinDir "jq.exe"
    Copy-Item -Force -LiteralPath $BinaryPath -Destination $Target

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

    Write-Host "Installed jq $Version to $Target"
    & $Target --version
    if ($LASTEXITCODE -ne 0) { throw "Installed jq did not start." }
}
finally {
    Remove-Item -LiteralPath $TemporaryDir -Recurse -Force -ErrorAction SilentlyContinue
}
