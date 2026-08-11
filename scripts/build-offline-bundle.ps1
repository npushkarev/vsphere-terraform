[CmdletBinding()]
param([string]$Terraform = "terraform")

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
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor `
    [Net.SecurityProtocolType]::Tls12
$Utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false

$Version = (Get-Content -LiteralPath (Join-Path $ProjectDir ".terraform-version") -Raw).Trim()
$GovcVersion = (Get-Content -LiteralPath (Join-Path $ProjectDir ".govc-version") -Raw).Trim()
$JqVersion = (Get-Content -LiteralPath (Join-Path $ProjectDir ".jq-version") -Raw).Trim()
$TerraformVersionOutput = @(& $Terraform version)
if ($LASTEXITCODE -ne 0 -or $TerraformVersionOutput.Count -eq 0 -or
    $TerraformVersionOutput[0].Trim() -cne "Terraform v$Version") {
    throw "Expected Terraform $Version for bundle creation."
}
$Platform = "windows_amd64"
$ArchiveName = "terraform_${Version}_${Platform}.zip"
$PinnedSha256 = "2FF41D2129AFB1982733C132C61A8D6EF038F879F3AEEDE7FC28B8B8B24ACF02"
$GovcArchiveName = "govc_Windows_x86_64.zip"
$GovcPinnedSha256 = "4ABB6CBD441311F2D9FFDB37F00497A44CEF7DFFA4BD1CE38D59E526D52CDD70"
$JqBinaryName = "jq-windows-amd64.exe"
$JqPinnedSha256 = "A6FC67FEDAF9128A3309A1E2EBB8B986AECCF70122EE46D2CB4849E423F0C627"
$OutputRoot = Join-Path $ProjectDir "offline-dist"
$BundleName = "vsphere-terraform-$Version-govc-$GovcVersion-jq-$JqVersion-$Platform"
$Stage = Join-Path $OutputRoot $BundleName

if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $Stage "provider-mirror") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Stage "lockfiles") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Stage "scanner\schemas") | Out-Null

$ArchivePath = Join-Path $Stage $ArchiveName
$Uri = "https://releases.hashicorp.com/terraform/$Version/$ArchiveName"
Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $ArchivePath
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $ArchivePath).Hash -cne $PinnedSha256) {
    throw "Terraform archive checksum mismatch."
}

$GovcArchivePath = Join-Path $Stage $GovcArchiveName
$GovcUri = "https://github.com/vmware/govmomi/releases/download/v$GovcVersion/$GovcArchiveName"
Invoke-WebRequest -UseBasicParsing -Uri $GovcUri -OutFile $GovcArchivePath
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $GovcArchivePath).Hash -cne $GovcPinnedSha256) {
    throw "govc archive checksum mismatch."
}

$JqBinaryPath = Join-Path $Stage $JqBinaryName
$JqUri = "https://github.com/jqlang/jq/releases/download/jq-$JqVersion/$JqBinaryName"
Invoke-WebRequest -UseBasicParsing -Uri $JqUri -OutFile $JqBinaryPath
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $JqBinaryPath).Hash -cne $JqPinnedSha256) {
    throw "jq binary checksum mismatch."
}

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
Copy-Item -LiteralPath (Join-Path $ProjectDir "scripts\scan-vsphere.ps1") `
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
Copy-Item -LiteralPath (Join-Path $ProjectDir "schemas\vsphere-inventory-v1.schema.json") `
    -Destination (Join-Path $Stage "scanner\schemas")
Copy-Item -LiteralPath (Join-Path $ProjectDir "docs\discovery.md") `
    -Destination (Join-Path $Stage "scanner\DISCOVERY.md")

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
