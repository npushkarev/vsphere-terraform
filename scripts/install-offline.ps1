[CmdletBinding()]
param(
    [string]$Prefix = (Join-Path $env:LOCALAPPDATA "vsphere-terraform"),
    [switch]$PersistCliConfig
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if ($PSVersionTable.PSVersion -lt [Version]"5.1") {
    throw "PowerShell 5.1 or newer is required."
}
if ($env:OS -cne "Windows_NT") { throw "This installer supports Windows only." }
$NativeArchitecture = $env:PROCESSOR_ARCHITEW6432
if ([string]::IsNullOrWhiteSpace($NativeArchitecture)) {
    $NativeArchitecture = $env:PROCESSOR_ARCHITECTURE
}
if ($NativeArchitecture -cne "AMD64") { throw "This installer supports Windows x64 only." }
$env:CHECKPOINT_DISABLE = "1"

$ManifestPath = Join-Path $PSScriptRoot "MANIFEST.sha256"
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Bundle manifest is missing."
}
$BundleRoot = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd("\") + "\"
foreach ($Line in Get-Content -LiteralPath $ManifestPath) {
    if ([string]::IsNullOrWhiteSpace($Line)) { continue }
    if ($Line -notmatch '^([0-9a-fA-F]{64})  (.+)$') {
        throw "Invalid bundle manifest line."
    }
    $ExpectedHash = $Matches[1]
    $RelativePath = $Matches[2].Replace("/", "\")
    $CandidatePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $RelativePath))
    if (-not $CandidatePath.StartsWith($BundleRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Bundle manifest path escapes the bundle directory."
    }
    if (-not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)) {
        throw "Bundle file is missing: $RelativePath"
    }
    $ActualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $CandidatePath).Hash.ToLowerInvariant()
    if ($ActualHash -ne $ExpectedHash.ToLowerInvariant()) {
        throw "Bundle checksum mismatch: $RelativePath"
    }
}

$TerraformVersion = (Get-Content -LiteralPath (Join-Path $PSScriptRoot ".terraform-version") -Raw).Trim()
$ArchivePath = Join-Path $PSScriptRoot "terraform_${TerraformVersion}_windows_amd64.zip"
if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
    throw "Terraform Windows archive is missing from bundle."
}
$GovcArchivePath = Join-Path $PSScriptRoot "govc_Windows_x86_64.zip"
if (-not (Test-Path -LiteralPath $GovcArchivePath -PathType Leaf)) {
    throw "govc Windows x64 archive is missing from bundle."
}
$JqBinaryPath = Join-Path $PSScriptRoot "jq-windows-amd64.exe"
if (-not (Test-Path -LiteralPath $JqBinaryPath -PathType Leaf)) {
    throw "jq Windows x64 binary is missing from bundle."
}
$ScannerSource = Join-Path $PSScriptRoot "scanner"
if (-not (Test-Path -LiteralPath $ScannerSource -PathType Container)) {
    throw "Scanner files are missing from bundle."
}

$BinDir = Join-Path $Prefix "bin"
$MirrorDir = Join-Path $Prefix "provider-mirror"
$ScannerDir = Join-Path $Prefix "scanner"
& (Join-Path $PSScriptRoot "install-terraform.ps1") -Archive $ArchivePath -BinDir $BinDir
if ($LASTEXITCODE -ne 0) { throw "Offline Terraform installation failed." }
& (Join-Path $PSScriptRoot "install-govc.ps1") -Archive $GovcArchivePath -BinDir $BinDir
if ($LASTEXITCODE -ne 0) { throw "Offline govc installation failed." }
& (Join-Path $PSScriptRoot "install-jq.ps1") -Binary $JqBinaryPath -BinDir $BinDir
if ($LASTEXITCODE -ne 0) { throw "Offline jq installation failed." }

foreach ($ManagedDirectory in @($MirrorDir, $ScannerDir)) {
    if (Test-Path -LiteralPath $ManagedDirectory) {
        Remove-Item -LiteralPath $ManagedDirectory -Recurse -Force
    }
}
New-Item -ItemType Directory -Force -Path $MirrorDir | Out-Null
Copy-Item -Recurse -Force -Path (Join-Path $PSScriptRoot "provider-mirror\*") -Destination $MirrorDir
New-Item -ItemType Directory -Force -Path $ScannerDir | Out-Null
Copy-Item -Recurse -Force -Path (Join-Path $ScannerSource "*") -Destination $ScannerDir

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
$env:Path = "$BinDir;$env:Path"
if ($PersistCliConfig) {
    [Environment]::SetEnvironmentVariable("TF_CLI_CONFIG_FILE", $CliConfig, "User")
}

Write-Host "Offline installation complete. Open a new PowerShell window, or run:"
Write-Host "`$env:Path = `"$BinDir;`$env:Path`""
Write-Host "`$env:TF_CLI_CONFIG_FILE = `"$CliConfig`""
Write-Host "Scanner: $(Join-Path $ScannerDir 'scan-vsphere.ps1')"
Write-Host "Python launcher: python $(Join-Path $ScannerDir 'vsphere.py')"
