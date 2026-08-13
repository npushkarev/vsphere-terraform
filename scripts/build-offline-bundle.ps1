[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if ($PSVersionTable.PSVersion -lt [Version]"5.1") {
    throw "PowerShell 5.1 or newer is required."
}
if ($env:OS -cne "Windows_NT") { throw "This builder supports Windows only." }
$NativeArchitecture = $env:PROCESSOR_ARCHITEW6432
if ([string]::IsNullOrWhiteSpace($NativeArchitecture)) {
    $NativeArchitecture = $env:PROCESSOR_ARCHITECTURE
}
if ($NativeArchitecture -cne "AMD64") { throw "This builder supports Windows x64 only." }
$env:CHECKPOINT_DISABLE = "1"
$ProjectDir = Split-Path -Parent $PSScriptRoot
$Utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false

$Version = (Get-Content -LiteralPath (Join-Path $ProjectDir ".terraform-version") -Raw).Trim()
$GovcVersion = (Get-Content -LiteralPath (Join-Path $ProjectDir ".govc-version") -Raw).Trim()
$JqVersion = (Get-Content -LiteralPath (Join-Path $ProjectDir ".jq-version") -Raw).Trim()
$Platform = "windows_amd64"
$ArchiveName = "terraform_${Version}_${Platform}.zip"
$GovcArchiveName = "govc_Windows_x86_64.zip"
$JqBinaryName = "jq-windows-amd64.exe"
$OutputRoot = Join-Path $ProjectDir "offline-dist"
$BundleName = "vsphere-terraform-$Version-govc-$GovcVersion-jq-$JqVersion-$Platform"
$Stage = Join-Path $OutputRoot $BundleName

if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $Stage "lockfiles") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Stage "scanner\schemas") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Stage "licenses") | Out-Null

& (Join-Path $PSScriptRoot "verify-vendor.ps1") -ProjectDir $ProjectDir
$ArchivePath = Join-Path $Stage $ArchiveName
Copy-Item -LiteralPath (Join-Path $ProjectDir "vendor\terraform\$Version\$ArchiveName") `
    -Destination $ArchivePath
$GovcArchivePath = Join-Path $Stage $GovcArchiveName
Copy-Item -LiteralPath (Join-Path $ProjectDir "vendor\govc\$GovcVersion\$GovcArchiveName") `
    -Destination $GovcArchivePath
$JqBinaryPath = Join-Path $Stage $JqBinaryName
Copy-Item -LiteralPath (Join-Path $ProjectDir "vendor\jq\$JqVersion\$JqBinaryName") `
    -Destination $JqBinaryPath
Copy-Item -LiteralPath (Join-Path $ProjectDir "vendor\provider-mirror") `
    -Destination (Join-Path $Stage "provider-mirror") -Recurse
Copy-Item -Path (Join-Path $ProjectDir "vendor\licenses\*") `
    -Destination (Join-Path $Stage "licenses") -Recurse
Copy-Item -LiteralPath (Join-Path $ProjectDir "vendor\provenance.json") `
    -Destination (Join-Path $Stage "vendor-provenance.json")

foreach ($VersionFile in @(".terraform-version", ".govc-version", ".jq-version")) {
    Copy-Item -LiteralPath (Join-Path $ProjectDir $VersionFile) -Destination $Stage
}
foreach ($Installer in @(
        "install-terraform.ps1",
        "install-govc.ps1",
        "install-jq.ps1",
        "install-offline.ps1"
    )) {
    Copy-Item -LiteralPath (Join-Path $ProjectDir "scripts\$Installer") -Destination $Stage
}
Copy-Item -LiteralPath (Join-Path $ProjectDir "vsphere.py") `
    -Destination (Join-Path $Stage "scanner")
foreach ($FilterName in @(
        "discovery-normalize.jq",
        "discovery-devices.jq",
        "discovery-validate.jq",
        "discovery-report.jq",
        "discovery-tree.jq",
        "discovery-tfvars.jq"
    )) {
    Copy-Item -LiteralPath (Join-Path $ProjectDir "scripts\$FilterName") `
        -Destination (Join-Path $Stage "scanner")
}
Copy-Item -LiteralPath (Join-Path $ProjectDir ".govc-version") `
    -Destination (Join-Path $Stage "scanner")
Copy-Item -LiteralPath (Join-Path $ProjectDir ".jq-version") `
    -Destination (Join-Path $Stage "scanner")
Copy-Item -LiteralPath (Join-Path $ProjectDir ".terraform-version") `
    -Destination (Join-Path $Stage "scanner")
Copy-Item -LiteralPath (Join-Path $ProjectDir "schemas\vsphere-inventory-v1.schema.json") `
    -Destination (Join-Path $Stage "scanner\schemas")
Copy-Item -LiteralPath (Join-Path $ProjectDir "docs\discovery.md") `
    -Destination (Join-Path $Stage "scanner\DISCOVERY.md")
Copy-Item -LiteralPath (Join-Path $ProjectDir "docs\python-launcher.md") `
    -Destination (Join-Path $Stage "scanner\PYTHON-LAUNCHER.md")
Copy-Item -LiteralPath (Join-Path $ProjectDir "docs\state.md") `
    -Destination (Join-Path $Stage "scanner\state.md")

Copy-Item -LiteralPath (Join-Path $ProjectDir "stacks\inventory\.terraform.lock.hcl") `
    -Destination (Join-Path $Stage "lockfiles\inventory.lock.hcl")
Copy-Item -LiteralPath (Join-Path $ProjectDir "stacks\vm-clones\.terraform.lock.hcl") `
    -Destination (Join-Path $Stage "lockfiles\vm-clones.lock.hcl")
Copy-Item -LiteralPath (Join-Path $ProjectDir "stacks\windows-clone\.terraform.lock.hcl") `
    -Destination (Join-Path $Stage "lockfiles\windows-clone.lock.hcl")

$RepoCommit = "unknown"
$RepoDirty = $true
$GitApplications = @(Get-Command "git.exe" -CommandType Application -ErrorAction SilentlyContinue)
if ($GitApplications.Count -gt 0) {
    $GitPath = $GitApplications[0].Path
    $CommitOutput = @(& $GitPath -C $ProjectDir rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $CommitOutput.Count -gt 0) {
        $RepoCommit = $CommitOutput[0].Trim()
        $StatusOutput = @(& $GitPath -C $ProjectDir status --porcelain --untracked-files=normal)
        if ($LASTEXITCODE -eq 0 -and $StatusOutput.Count -eq 0) { $RepoDirty = $false }
    }
}
$BundleInfo = [ordered]@{
    terraform_version        = $Version
    vsphere_provider_version = "2.15.1"
    govc_version              = $GovcVersion
    jq_version                = $JqVersion
    platform                  = $Platform
    repo_commit               = $RepoCommit
    repo_dirty                = $RepoDirty
} | ConvertTo-Json
[System.IO.File]::WriteAllText((Join-Path $Stage "bundle-info.json"), $BundleInfo + "`n", $Utf8NoBom)

$ManifestLines = @(Get-ChildItem -LiteralPath $Stage -Recurse -File |
        Where-Object { $_.Name -cne "MANIFEST.sha256" } |
        Sort-Object FullName |
        ForEach-Object {
            $RelativePath = $_.FullName.Substring($Stage.Length + 1).Replace("\", "/")
            $Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
            "$Hash  $RelativePath"
        })
[System.IO.File]::WriteAllText(
    (Join-Path $Stage "MANIFEST.sha256"),
    [string]::Join("`n", $ManifestLines) + "`n",
    $Utf8NoBom
)

$ZipPath = Join-Path $OutputRoot "$BundleName.zip"
if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
Compress-Archive -Path $Stage -DestinationPath $ZipPath
$ZipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ZipPath).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText(
    "$ZipPath.sha256",
    "$ZipHash  $([System.IO.Path]::GetFileName($ZipPath))`n",
    $Utf8NoBom
)
Write-Host "Offline bundle: $ZipPath"
Write-Host "Transfer checksum: $ZipPath.sha256"
