[CmdletBinding()]
param([string]$Terraform = "terraform")

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$ProjectDir = Split-Path -Parent $PSScriptRoot

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

Invoke-Terraform -Arguments @("-chdir=$ProjectDir", "fmt", "-check", "-recursive")
foreach ($Stack in @("inventory", "vm-clones")) {
    $StackDir = Join-Path $ProjectDir "stacks\$Stack"
    Invoke-Terraform -Arguments @("-chdir=$StackDir", "init", "-backend=false", "-lockfile=readonly", "-input=false")
    Invoke-Terraform -Arguments @("-chdir=$StackDir", "validate")
}

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

foreach ($VersionsFile in @(
        (Join-Path $ProjectDir "stacks\inventory\versions.tf"),
        (Join-Path $ProjectDir "stacks\vm-clones\versions.tf"),
        (Join-Path $ProjectDir "modules\linux-vm-clone\versions.tf")
    )) {
    $Versions = Get-Content -LiteralPath $VersionsFile -Raw
    if ($Versions -notmatch 'source\s+=\s+"vmware/vsphere"') { throw "Unexpected provider source in $VersionsFile." }
    if ($Versions -notmatch 'version\s+=\s+"= 2\.15\.1"') { throw "Unexpected provider version in $VersionsFile." }
}

$ModuleMain = Get-Content -LiteralPath (Join-Path $ProjectDir "modules\linux-vm-clone\main.tf") -Raw
if ($ModuleMain -notmatch 'prevent_destroy\s+=\s+true') { throw "prevent_destroy is missing." }

Write-Host "All validation checks passed."
