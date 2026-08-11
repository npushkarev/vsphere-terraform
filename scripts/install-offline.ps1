[CmdletBinding()]
param(
    [string]$Prefix = (Join-Path $env:LOCALAPPDATA "vsphere-terraform"),
    [switch]$PersistCliConfig
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Archive = Get-ChildItem -LiteralPath $PSScriptRoot -Filter "terraform_*_windows_amd64.zip" -File |
    Select-Object -First 1
if (-not $Archive) { throw "Terraform Windows archive is missing from bundle." }

$BinDir = Join-Path $Prefix "bin"
$MirrorDir = Join-Path $Prefix "provider-mirror"
& (Join-Path $PSScriptRoot "install-terraform.ps1") -Archive $Archive.FullName -BinDir $BinDir -AddToUserPath
if ($LASTEXITCODE -ne 0) { throw "Offline Terraform installation failed." }

New-Item -ItemType Directory -Force -Path $MirrorDir | Out-Null
Copy-Item -Recurse -Force -Path (Join-Path $PSScriptRoot "provider-mirror\*") -Destination $MirrorDir

$CliConfig = Join-Path $Prefix "terraform.rc"
$EscapedMirror = $MirrorDir.Replace("\", "/")
$Config = @"
disable_checkpoint = true
provider_installation {
  filesystem_mirror {
    path    = "$EscapedMirror"
    include = ["registry.terraform.io/vmware/vsphere"]
  }
}
"@
$Utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
[System.IO.File]::WriteAllText($CliConfig, $Config, $Utf8NoBom)
$env:TF_CLI_CONFIG_FILE = $CliConfig
if ($PersistCliConfig) {
    [Environment]::SetEnvironmentVariable("TF_CLI_CONFIG_FILE", $CliConfig, "User")
}

Write-Host "Offline installation complete. Open a new PowerShell window, or run:"
Write-Host "`$env:Path = `"$BinDir;`$env:Path`""
Write-Host "`$env:TF_CLI_CONFIG_FILE = `"$CliConfig`""
