[CmdletBinding()]
param([string]$Terraform = "terraform")

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$ProjectDir = Split-Path -Parent $PSScriptRoot
$Utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
$ExpectedGovcVersion = (Get-Content -LiteralPath (Join-Path $ProjectDir ".govc-version") -Raw).Trim()
$ExpectedJqVersion = (Get-Content -LiteralPath (Join-Path $ProjectDir ".jq-version") -Raw).Trim()

foreach ($Name in @("VSPHERE_USER", "VSPHERE_PASSWORD", "VSPHERE_SERVER")) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Name, "Process"))) {
        [Environment]::SetEnvironmentVariable($Name, "validation-only", "Process")
    }
}

function Invoke-Terraform {
    param([string[]]$Arguments)
    & $Terraform @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Terraform failed: $($Arguments -join ' ')"
    }
}

$GovcApplications = @(Get-Command "govc.exe" -CommandType Application -ErrorAction Stop)
$Govc = $GovcApplications[0].Path
$GovcActual = @(& $Govc version)
if ($LASTEXITCODE -ne 0 -or ($GovcActual -join "`n").Trim() -cne "govc $ExpectedGovcVersion") {
    throw "Unexpected govc version."
}
$JqApplications = @(Get-Command "jq.exe" -CommandType Application -ErrorAction Stop)
$Jq = $JqApplications[0].Path
$JqActual = @(& $Jq --version)
if ($LASTEXITCODE -ne 0 -or ($JqActual -join "`n").Trim() -cne "jq-$ExpectedJqVersion") {
    throw "Unexpected jq version."
}

Invoke-Terraform -Arguments @("-chdir=$ProjectDir", "fmt", "-check", "-recursive")
foreach ($Stack in @("inventory", "vm-clones", "windows-clone")) {
    $StackDir = Join-Path $ProjectDir "stacks\$Stack"
    Invoke-Terraform -Arguments @("-chdir=$StackDir", "init", "-backend=false", "-lockfile=readonly", "-input=false")
    Invoke-Terraform -Arguments @("-chdir=$StackDir", "validate")
}

Invoke-Terraform -Arguments @("-chdir=$(Join-Path $ProjectDir 'stacks\windows-clone')", "test")

foreach ($PowerShellFile in Get-ChildItem -LiteralPath (Join-Path $ProjectDir "scripts") -Filter "*.ps1" -File) {
    $Tokens = $null
    $ParseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $PowerShellFile.FullName,
        [ref]$Tokens,
        [ref]$ParseErrors
    ) | Out-Null
    if ($ParseErrors.Count -gt 0) {
        throw "PowerShell syntax error in $($PowerShellFile.Name): $($ParseErrors[0].Message)"
    }
}

$DiscoveryTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vsphere-discovery-validation-" + [guid]::NewGuid())
$DiscoveryOutput = Join-Path $DiscoveryTestRoot "result with spaces"
New-Item -ItemType Directory -Path $DiscoveryTestRoot | Out-Null
try {
    & (Join-Path $ProjectDir "scripts\scan-vsphere.ps1") `
        -FixtureDir (Join-Path $ProjectDir "tests\discovery\fixtures") `
        -SourceVm "tst-win-10-12" `
        -OutputDirectory $DiscoveryOutput `
        -GeneratedAt "2026-08-11T00:00:00Z" `
        -Jq $Jq

    $InventoryText = [System.IO.File]::ReadAllText(
        (Join-Path $DiscoveryOutput "inventory.json"),
        $Utf8NoBom
    )
    $Inventory = $InventoryText | ConvertFrom-Json
    if ($Inventory.schema_version -cne "1.0.0" -or -not $Inventory.read_only) {
        throw "Unexpected discovery result metadata."
    }
    if ($Inventory.counts.datacenters -ne 1 -or $Inventory.counts.virtual_machines -ne 1 -or
        $Inventory.counts.templates -ne 1 -or $Inventory.clone_candidate.match_count -ne 1) {
        throw "Unexpected discovery fixture counts."
    }
    if ($Inventory.clone_candidate.source_vm_path -cne "/INC/vm/Test Lab/tst-win-10-12") {
        throw "Discovery source VM resolution failed."
    }
    $NetworkRefs = @($Inventory.inventory.networks | ForEach-Object { $_.ref })
    if ($NetworkRefs.Count -ne @($NetworkRefs | Select-Object -Unique).Count) {
        throw "Discovery output contains duplicate networks."
    }

    $AllResultText = @(Get-ChildItem -LiteralPath $DiscoveryOutput -File | ForEach-Object {
            [System.IO.File]::ReadAllText($_.FullName, $Utf8NoBom)
        }) -join "`n"
    foreach ($Sentinel in @(
            "SECRET-EXTRACONFIG-SENTINEL",
            "SECRET-MAC-SENTINEL",
            "SECRET-VMDK-PATH",
            "macAddress",
            "extraConfig",
            "ipAddress"
        )) {
        if ($AllResultText.Contains($Sentinel)) {
            throw "Discovery output leaked forbidden field: $Sentinel"
        }
    }
    $ExpectedUnicode = (-join @(
            [char]0x0428,
            [char]0x0430,
            [char]0x0431,
            [char]0x043B,
            [char]0x043E,
            [char]0x043D
        )) + " Windows"
    if (-not $AllResultText.Contains($ExpectedUnicode)) {
        throw "Discovery output did not preserve UTF-8 inventory names."
    }
    $GeneratedTfvars = Join-Path $DiscoveryOutput "windows-clone.generated.tfvars"
    $GeneratedText = [System.IO.File]::ReadAllText($GeneratedTfvars, $Utf8NoBom)
    if (-not $GeneratedText.Contains('source_powered_off_acknowledgement = ""')) {
        throw "Generated tfvars must not authorize clone apply."
    }
    Invoke-Terraform -Arguments @("fmt", "-check", $GeneratedTfvars)

    foreach ($Line in Get-Content -LiteralPath (Join-Path $DiscoveryOutput "SHA256SUMS")) {
        if ($Line -notmatch '^([0-9a-f]{64})  (.+)$') { throw "Invalid discovery checksum line." }
        $ActualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath `
                (Join-Path $DiscoveryOutput $Matches[2])).Hash.ToLowerInvariant()
        if ($ActualHash -ne $Matches[1]) { throw "Discovery result checksum mismatch." }
    }
    $OutputAcl = Get-Acl -LiteralPath $DiscoveryOutput
    if (-not $OutputAcl.AreAccessRulesProtected) {
        throw "Discovery result directory inherited unexpected ACL rules."
    }

    $RejectedExistingOutput = $false
    try {
        & (Join-Path $ProjectDir "scripts\scan-vsphere.ps1") `
            -FixtureDir (Join-Path $ProjectDir "tests\discovery\fixtures") `
            -OutputDirectory $DiscoveryOutput `
            -GeneratedAt "2026-08-11T00:00:00Z" `
            -Jq $Jq
    }
    catch {
        $RejectedExistingOutput = $true
    }
    if (-not $RejectedExistingOutput) { throw "Scanner overwrote an existing result directory." }
}
finally {
    Remove-Item -LiteralPath $DiscoveryTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

& git -C $ProjectDir check-ignore -q "scan-results/validation/inventory.json"
if ($LASTEXITCODE -ne 0) { throw "scan-results must be ignored by Git." }

$OfflineShell = Get-Content -LiteralPath (Join-Path $ProjectDir "scripts\install-offline.sh") -Raw
if (-not $OfflineShell.Contains("export CHECKPOINT_DISABLE=1")) {
    throw "Linux offline installer must disable Terraform checkpoint before first execution."
}
$OfflinePowerShell = Get-Content -LiteralPath (Join-Path $ProjectDir "scripts\install-offline.ps1") -Raw
if (-not $OfflinePowerShell.Contains('CHECKPOINT_DISABLE = "1"')) {
    throw "Windows offline installer must disable Terraform checkpoint before first execution."
}

foreach ($VersionsFile in @(
        (Join-Path $ProjectDir "stacks\inventory\versions.tf"),
        (Join-Path $ProjectDir "stacks\vm-clones\versions.tf"),
        (Join-Path $ProjectDir "stacks\windows-clone\versions.tf"),
        (Join-Path $ProjectDir "modules\linux-vm-clone\versions.tf")
    )) {
    $Versions = Get-Content -LiteralPath $VersionsFile -Raw
    if ($Versions -notmatch 'source\s+=\s+"vmware/vsphere"') { throw "Unexpected provider source in $VersionsFile." }
    if ($Versions -notmatch 'version\s+=\s+"= 2\.15\.1"') { throw "Unexpected provider version in $VersionsFile." }
}

$ModuleMain = Get-Content -LiteralPath (Join-Path $ProjectDir "modules\linux-vm-clone\main.tf") -Raw
if ($ModuleMain -notmatch 'prevent_destroy\s+=\s+true') { throw "prevent_destroy is missing." }
$WindowsMain = Get-Content -LiteralPath (Join-Path $ProjectDir "stacks\windows-clone\main.tf") -Raw
if ($WindowsMain -notmatch 'prevent_destroy\s+=\s+true') { throw "Windows prevent_destroy is missing." }
if ($WindowsMain -match 'admin_password|domain_admin_password|product_key|windows_sysprep_text') {
    throw "Windows clone stack must not contain guest secrets."
}

Write-Host "All validation checks passed."
