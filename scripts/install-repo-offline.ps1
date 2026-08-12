[CmdletBinding()]
param([switch]$VerifyOnly)

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

$ProjectDir = Split-Path -Parent $PSScriptRoot
$TerraformVersion = (Get-Content -LiteralPath (Join-Path $ProjectDir ".terraform-version") -Raw).Trim()
$GovcVersion = (Get-Content -LiteralPath (Join-Path $ProjectDir ".govc-version") -Raw).Trim()
$JqVersion = (Get-Content -LiteralPath (Join-Path $ProjectDir ".jq-version") -Raw).Trim()
$VersionsText = Get-Content -LiteralPath (Join-Path $ProjectDir "stacks\inventory\versions.tf") -Raw
if ($VersionsText -notmatch 'version\s*=\s*"= ([0-9.]+)"') {
    throw "Cannot determine pinned provider version."
}
$ProviderVersion = $Matches[1]
& (Join-Path $PSScriptRoot "verify-vendor.ps1") -ProjectDir $ProjectDir
if ($VerifyOnly) {
    Write-Host "Verification only: no files installed."
    return
}

function Protect-PrivateDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $Sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $Acl = New-Object -TypeName System.Security.AccessControl.DirectorySecurity
    $Rule = New-Object -TypeName System.Security.AccessControl.FileSystemAccessRule -ArgumentList @(
        $Sid,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor `
            [System.Security.AccessControl.InheritanceFlags]::ObjectInherit,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $Acl.SetOwner($Sid)
    $Acl.SetAccessRuleProtection($true, $false)
    [void]$Acl.AddAccessRule($Rule)
    [System.IO.Directory]::SetAccessControl($Path, $Acl)
}

$ToolsRoot = Join-Path $ProjectDir ".vsphere-tools"
$Prefix = Join-Path $ToolsRoot "windows_amd64"
foreach ($Candidate in @($ToolsRoot, $Prefix)) {
    if (Test-Path -LiteralPath $Candidate) {
        if ((Get-Item -LiteralPath $Candidate -Force).Attributes -band
            [System.IO.FileAttributes]::ReparsePoint) {
            throw ".vsphere-tools and its platform directory must not be reparse points."
        }
    }
}
New-Item -ItemType Directory -Force -Path $ToolsRoot | Out-Null
Protect-PrivateDirectory -Path $ToolsRoot
$Stage = Join-Path $ToolsRoot (".stage-windows-amd64-" + [guid]::NewGuid().ToString("N"))
$Backup = $null
New-Item -ItemType Directory -Path $Stage | Out-Null
Protect-PrivateDirectory -Path $Stage

try {
    $BinDir = Join-Path $Stage "bin"
    & (Join-Path $PSScriptRoot "install-terraform.ps1") `
        -Archive (Join-Path $ProjectDir "vendor\terraform\$TerraformVersion\terraform_${TerraformVersion}_windows_amd64.zip") `
        -BinDir $BinDir
    & (Join-Path $PSScriptRoot "install-govc.ps1") `
        -Archive (Join-Path $ProjectDir "vendor\govc\$GovcVersion\govc_Windows_x86_64.zip") `
        -BinDir $BinDir
    & (Join-Path $PSScriptRoot "install-jq.ps1") `
        -Binary (Join-Path $ProjectDir "vendor\jq\$JqVersion\jq-windows-amd64.exe") `
        -BinDir $BinDir

    Copy-Item -LiteralPath (Join-Path $ProjectDir "vendor\provider-mirror") `
        -Destination (Join-Path $Stage "provider-mirror") -Recurse
    $FinalMirror = (Join-Path $Prefix "provider-mirror").Replace("\", "/")
    $Config = @"
disable_checkpoint = true
provider_installation {
  filesystem_mirror {
    path    = "$FinalMirror"
    include = ["registry.terraform.io/vmware/vsphere"]
  }
}
"@
    $Utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText((Join-Path $Stage "terraform.rc"), $Config, $Utf8NoBom)
    $ManifestHash = (Get-FileHash -Algorithm SHA256 -LiteralPath `
            (Join-Path $ProjectDir "vendor\MANIFEST.sha256")).Hash.ToLowerInvariant()
    $Receipt = [ordered]@{
        schema_version           = 1
        platform                 = "windows_amd64"
        vendor_manifest_sha256   = $ManifestHash
        terraform_version        = $TerraformVersion
        govc_version              = $GovcVersion
        jq_version                = $JqVersion
        vsphere_provider_version = $ProviderVersion
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText(
        (Join-Path $Stage "install-receipt.json"),
        $Receipt + "`n",
        $Utf8NoBom
    )

    if (Test-Path -LiteralPath $Prefix) {
        $Backup = Join-Path $ToolsRoot (".backup-windows-amd64-" + [guid]::NewGuid().ToString("N"))
        Move-Item -LiteralPath $Prefix -Destination $Backup
    }
    try {
        Move-Item -LiteralPath $Stage -Destination $Prefix
        $Stage = $null
    }
    catch {
        if ($Backup -and -not (Test-Path -LiteralPath $Prefix)) {
            Move-Item -LiteralPath $Backup -Destination $Prefix
            $Backup = $null
        }
        throw
    }
    if ($Backup) {
        Remove-Item -LiteralPath $Backup -Recurse -Force
        $Backup = $null
    }
}
finally {
    if ($Stage -and (Test-Path -LiteralPath $Stage)) {
        Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($Backup -and -not (Test-Path -LiteralPath $Prefix) -and
        (Test-Path -LiteralPath $Backup)) {
        Move-Item -LiteralPath $Backup -Destination $Prefix -ErrorAction SilentlyContinue
    }
}

Write-Host "Repo-local offline toolchain installed: $Prefix"
Write-Host "Run: python $ProjectDir\vsphere.py check"
