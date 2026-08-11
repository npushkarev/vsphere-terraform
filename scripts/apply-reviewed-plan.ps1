[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Plan,
    [string]$Terraform = "terraform"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$ProjectDir = Split-Path -Parent $PSScriptRoot

function Get-ResourceChanges {
    param([object]$PlanObject)
    $Property = $PlanObject.PSObject.Properties["resource_changes"]
    if ($null -ne $Property -and $null -ne $Property.Value) { $Property.Value }
}

if ($env:ALLOW_VM_APPLY -cne "yes") {
    throw "Set ALLOW_VM_APPLY=yes after reviewing the saved plan."
}

$PlanItem = Get-Item -LiteralPath (Resolve-Path -LiteralPath $Plan).Path -Force
if ($PlanItem.PSIsContainer) { throw "Expected a plan file." }
$PlanPath = $PlanItem.FullName
$AllowedDir = [System.IO.Path]::GetFullPath((Join-Path $ProjectDir ".plans\vm-clones"))
if (-not [StringComparer]::OrdinalIgnoreCase.Equals($PlanItem.Directory.FullName, $AllowedDir)) {
    throw "Only plans produced under .plans/vm-clones are accepted."
}
if ([System.IO.Path]::GetExtension($PlanPath) -ne ".tfplan") { throw "Expected a .tfplan file." }

$StackDir = Join-Path $ProjectDir "stacks\vm-clones"
$HashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $PlanPath).Hash
$JsonLines = @(& $Terraform "-chdir=$StackDir" show -json $PlanPath)
if ($LASTEXITCODE -ne 0) { throw "terraform show failed." }
$PlanObject = ([string]::Join([Environment]::NewLine, $JsonLines)) | ConvertFrom-Json
$Changes = @(Get-ResourceChanges -PlanObject $PlanObject)
$DeleteChanges = @($Changes | Where-Object { @($_.change.actions) -contains "delete" })
if ($DeleteChanges.Count -gt 0) { throw "Saved plan contains delete/replace; refusing." }
$HashAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $PlanPath).Hash
if ($HashBefore -cne $HashAfter) { throw "Plan file changed during review; refusing." }

& $Terraform "-chdir=$StackDir" apply -input=false -lock-timeout=5m $PlanPath
if ($LASTEXITCODE -ne 0) { throw "terraform apply failed." }
