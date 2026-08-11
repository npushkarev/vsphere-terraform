[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("inventory", "vm-clones", "windows-clone")]
    [string]$Stack,
    [string]$VarFile,
    [string]$Terraform = "terraform"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$ProjectDir = Split-Path -Parent $PSScriptRoot

function Get-PlanObject {
    param([string]$TerraformExe, [string]$StackDirectory, [string]$PlanPath)
    $Lines = @(& $TerraformExe "-chdir=$StackDirectory" show -json $PlanPath)
    if ($LASTEXITCODE -ne 0) { throw "terraform show failed." }
    try {
        return (([string]::Join("`n", $Lines)) | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        throw "terraform show returned invalid JSON: $($_.Exception.Message)"
    }
}

function Get-ResourceChanges {
    param([object]$PlanObject)
    $Property = $PlanObject.PSObject.Properties["resource_changes"]
    if ($null -ne $Property -and $null -ne $Property.Value) { $Property.Value }
}

foreach ($Name in @("VSPHERE_SERVER", "VSPHERE_USER", "VSPHERE_PASSWORD")) {
    $Value = [Environment]::GetEnvironmentVariable($Name, "Process")
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "Required environment variable is missing: $Name" }
}

$StackDir = Join-Path $ProjectDir "stacks\$Stack"
$PlanDir = Join-Path $ProjectDir ".plans\$Stack"
New-Item -ItemType Directory -Force -Path $PlanDir | Out-Null
$Nonce = [Guid]::NewGuid().ToString("N").Substring(0, 8)
$PlanId = "{0}-{1}-{2}" -f [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ"), $PID, $Nonce
$PlanFile = Join-Path $PlanDir "$PlanId.tfplan"

& $Terraform "-chdir=$StackDir" init -input=false -lockfile=readonly
if ($LASTEXITCODE -ne 0) { throw "terraform init failed." }

try {
    $PlanArgs = @("-chdir=$StackDir", "plan", "-input=false", "-lock-timeout=5m", "-out=$PlanFile")
    if ($VarFile) {
        $ResolvedVarFile = (Resolve-Path -LiteralPath $VarFile).Path
        $PlanArgs += "-var-file=$ResolvedVarFile"
    }
    & $Terraform @PlanArgs
    if ($LASTEXITCODE -ne 0) { throw "terraform plan failed." }

    $PlanObject = Get-PlanObject -TerraformExe $Terraform -StackDirectory $StackDir -PlanPath $PlanFile
    $Changes = @(Get-ResourceChanges -PlanObject $PlanObject)

    if ($Stack -eq "inventory") {
        $ManagedChanges = @($Changes | Where-Object {
            $Actions = @($_.change.actions)
            $_.mode -eq "managed" -and -not ($Actions.Count -eq 1 -and $Actions[0] -ceq "no-op")
        })
        if ($ManagedChanges.Count -gt 0) { throw "Inventory plan contains a managed-resource change; refusing." }
    }
    elseif ($Stack -eq "vm-clones") {
        $DeleteChanges = @($Changes | Where-Object { @($_.change.actions) -contains "delete" })
        if ($DeleteChanges.Count -gt 0) { throw "VM plan contains delete/replace; refusing." }
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

    Write-Host "Saved reviewed-plan candidate: $PlanFile"
    Write-Host "Inspect with: terraform -chdir=$StackDir show `"$PlanFile`""
}
catch {
    Remove-Item -LiteralPath $PlanFile -Force -ErrorAction SilentlyContinue
    throw
}
