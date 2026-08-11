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

$PlanItem = Get-Item -LiteralPath (Resolve-Path -LiteralPath $Plan).Path -Force
if ($PlanItem.PSIsContainer) { throw "Expected a plan file." }
$PlanPath = $PlanItem.FullName
$Stack = $PlanItem.Directory.Name
if ($Stack -notin @("vm-clones", "windows-clone")) {
    throw "Only vm-clones and windows-clone saved plans are accepted."
}
$AllowedDir = [System.IO.Path]::GetFullPath((Join-Path $ProjectDir ".plans\$Stack"))
if (-not [StringComparer]::OrdinalIgnoreCase.Equals($PlanItem.Directory.FullName, $AllowedDir)) {
    throw "Only direct .plans/$Stack plans are accepted."
}
if ([System.IO.Path]::GetExtension($PlanPath) -ne ".tfplan") { throw "Expected a .tfplan file." }

if ($Stack -eq "vm-clones") {
    if ($env:ALLOW_VM_APPLY -cne "yes") {
        throw "Set ALLOW_VM_APPLY=yes after reviewing the saved plan."
    }
}
elseif ($env:ALLOW_WINDOWS_CLONE_APPLY -cne "yes") {
    throw "Set ALLOW_WINDOWS_CLONE_APPLY=yes after reviewing the saved plan."
}

$StackDir = Join-Path $ProjectDir "stacks\$Stack"
$HashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $PlanPath).Hash
$JsonLines = @(& $Terraform "-chdir=$StackDir" show -json $PlanPath)
if ($LASTEXITCODE -ne 0) { throw "terraform show failed." }
$PlanObject = ([string]::Join([Environment]::NewLine, $JsonLines)) | ConvertFrom-Json
$Changes = @(Get-ResourceChanges -PlanObject $PlanObject)
if ($Stack -eq "vm-clones") {
    $DeleteChanges = @($Changes | Where-Object { @($_.change.actions) -contains "delete" })
    if ($DeleteChanges.Count -gt 0) { throw "Saved plan contains delete/replace; refusing." }
}
else {
    $ManagedChanges = @($Changes | Where-Object {
        $Actions = @($_.change.actions)
        $_.mode -eq "managed" -and -not ($Actions.Count -eq 1 -and $Actions[0] -ceq "no-op")
    })
    $SafeCreate = $ManagedChanges.Count -eq 1 -and `
        $ManagedChanges[0].address -ceq "vsphere_virtual_machine.clone" -and `
        @($ManagedChanges[0].change.actions).Count -eq 1 -and `
        @($ManagedChanges[0].change.actions)[0] -ceq "create"
    if ($ManagedChanges.Count -gt 0 -and -not $SafeCreate) {
        throw "Windows clone plan must be no-op or exactly one create; refusing."
    }
}
$HashAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $PlanPath).Hash
if ($HashBefore -cne $HashAfter) { throw "Plan file changed during review; refusing." }

& $Terraform "-chdir=$StackDir" apply -input=false -lock-timeout=5m $PlanPath
if ($LASTEXITCODE -ne 0) { throw "terraform apply failed." }
