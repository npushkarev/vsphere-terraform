[CmdletBinding()]
param([string]$Terraform = "terraform")

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$ProjectDir = Split-Path -Parent $PSScriptRoot
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor `
    [Net.SecurityProtocolType]::Tls12
$Version = (Get-Content -LiteralPath (Join-Path $ProjectDir ".terraform-version") -Raw).Trim()
$Platform = "windows_amd64"
$ArchiveName = "terraform_${Version}_${Platform}.zip"
$PinnedSha256 = "2FF41D2129AFB1982733C132C61A8D6EF038F879F3AEEDE7FC28B8B8B24ACF02"
$OutputRoot = Join-Path $ProjectDir "offline-dist"
$BundleName = "vsphere-terraform-$Version-$Platform"
$Stage = Join-Path $OutputRoot $BundleName

if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $Stage "provider-mirror") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Stage "lockfiles") | Out-Null

$ArchivePath = Join-Path $Stage $ArchiveName
$Uri = "https://releases.hashicorp.com/terraform/$Version/$ArchiveName"
Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $ArchivePath
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $ArchivePath).Hash -ne $PinnedSha256) {
    throw "Terraform archive checksum mismatch."
}

Copy-Item -LiteralPath (Join-Path $ProjectDir ".terraform-version") -Destination $Stage
Copy-Item -LiteralPath (Join-Path $ProjectDir "scripts\install-terraform.ps1") -Destination $Stage
Copy-Item -LiteralPath (Join-Path $ProjectDir "scripts\install-offline.ps1") -Destination $Stage
Copy-Item -LiteralPath (Join-Path $ProjectDir "stacks\inventory\.terraform.lock.hcl") `
    -Destination (Join-Path $Stage "lockfiles\inventory.lock.hcl")
Copy-Item -LiteralPath (Join-Path $ProjectDir "stacks\vm-clones\.terraform.lock.hcl") `
    -Destination (Join-Path $Stage "lockfiles\vm-clones.lock.hcl")
Copy-Item -LiteralPath (Join-Path $ProjectDir "stacks\windows-clone\.terraform.lock.hcl") `
    -Destination (Join-Path $Stage "lockfiles\windows-clone.lock.hcl")

$TerraformArguments = @(
    "-chdir=$(Join-Path $ProjectDir 'stacks\inventory')",
    "providers",
    "mirror",
    "-platform=$Platform",
    (Join-Path $Stage "provider-mirror")
)
& $Terraform @TerraformArguments
if ($LASTEXITCODE -ne 0) { throw "Provider mirror creation failed." }

$ZipPath = Join-Path $OutputRoot "$BundleName.zip"
if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
Compress-Archive -Path $Stage -DestinationPath $ZipPath
Write-Host "Offline bundle: $ZipPath"
