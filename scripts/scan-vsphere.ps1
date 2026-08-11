[CmdletBinding()]
param(
    [string]$SourceVm = "tst-win-10-12",
    [string]$OutputDirectory,
    [string]$CaCert,
    [string]$Govc = "govc.exe",
    [string]$Jq = "jq.exe",
    [string]$FixtureDir,
    [string]$GeneratedAt
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($PSVersionTable.PSVersion -lt [Version]"5.1") {
    throw "PowerShell 5.1 or newer is required."
}
if ([string]::IsNullOrWhiteSpace($SourceVm)) {
    throw "SourceVm must not be empty."
}

$Utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
$ScriptDir = $PSScriptRoot
if (Test-Path -LiteralPath (Join-Path $ScriptDir ".govc-version")) {
    $ProjectDir = $ScriptDir
}
else {
    $ProjectDir = Split-Path -Parent $ScriptDir
}
$ExpectedGovcVersion = (Get-Content -LiteralPath (Join-Path $ProjectDir ".govc-version") -Raw).Trim()
$ExpectedJqVersion = (Get-Content -LiteralPath (Join-Path $ProjectDir ".jq-version") -Raw).Trim()

function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $Builder = New-Object System.Text.StringBuilder
    [void]$Builder.Append('"')
    $BackslashCount = 0
    foreach ($Character in $Value.ToCharArray()) {
        if ($Character -eq [char]'\') {
            $BackslashCount++
            continue
        }
        if ($Character -eq [char]'"') {
            for ($Index = 0; $Index -lt ($BackslashCount * 2 + 1); $Index++) {
                [void]$Builder.Append('\')
            }
            [void]$Builder.Append('"')
            $BackslashCount = 0
            continue
        }
        for ($Index = 0; $Index -lt $BackslashCount; $Index++) {
            [void]$Builder.Append('\')
        }
        $BackslashCount = 0
        [void]$Builder.Append($Character)
    }
    for ($Index = 0; $Index -lt ($BackslashCount * 2); $Index++) {
        [void]$Builder.Append('\')
    }
    [void]$Builder.Append('"')
    $Builder.ToString()
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$CommandArguments,
        [hashtable]$Environment,
        [string]$OutputFile,
        [switch]$PassThru,
        [string]$Label = "native command"
    )

    $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $StartInfo.FileName = $Executable
    $StartInfo.Arguments = (@($CommandArguments | ForEach-Object {
                ConvertTo-NativeArgument -Value $_
            }) -join " ")
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true
    $StartInfo.StandardOutputEncoding = $Utf8NoBom
    $StartInfo.StandardErrorEncoding = $Utf8NoBom

    if ($Environment) {
        $InheritedNames = @($StartInfo.EnvironmentVariables.Keys)
        foreach ($Name in $InheritedNames) {
            if ($Name -match '^(?i:GOVC_|GOVMOMI_|HTTP_PROXY$|HTTPS_PROXY$|ALL_PROXY$|NO_PROXY$)') {
                [void]$StartInfo.EnvironmentVariables.Remove($Name)
            }
        }
        foreach ($Name in $Environment.Keys) {
            $Value = $Environment[$Name]
            if ($null -eq $Value) {
                [void]$StartInfo.EnvironmentVariables.Remove($Name)
            }
            else {
                $StartInfo.EnvironmentVariables[$Name] = [string]$Value
            }
        }
    }

    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $StartInfo
    if (-not $Process.Start()) { throw "$Label did not start." }
    $StdoutTask = $Process.StandardOutput.ReadToEndAsync()
    $StderrTask = $Process.StandardError.ReadToEndAsync()
    $Process.WaitForExit()
    $Stdout = $StdoutTask.Result
    $Stderr = $StderrTask.Result
    $ExitCode = $Process.ExitCode
    $Process.Dispose()

    if ($ExitCode -ne 0) {
        $Message = $Stderr.Trim()
        if ([string]::IsNullOrWhiteSpace($Message)) { $Message = "exit code $ExitCode" }
        throw "$Label failed: $Message"
    }
    if ($OutputFile) {
        [System.IO.File]::WriteAllText($OutputFile, $Stdout, $Utf8NoBom)
    }
    if ($PassThru) { return $Stdout }
}

function Test-Truthy {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $Value -match '^(?i:true|1|yes)$'
}

function Get-ObjectPropertyValue {
    param([object]$InputObject, [string]$Name)
    $Property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $Property) { return $null }
    $Property.Value
}

function Protect-PrivateDirectory {
    param([string]$Path)

    if ($env:OS -cne "Windows_NT") { return }
    $Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $Security = New-Object System.Security.AccessControl.DirectorySecurity
    $Security.SetOwner($Identity)
    $Security.SetAccessRuleProtection($true, $false)
    $Inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor `
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $Rule = New-Object -TypeName System.Security.AccessControl.FileSystemAccessRule -ArgumentList @(
        $Identity,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        $Inheritance,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    [void]$Security.AddAccessRule($Rule)
    [System.IO.Directory]::SetAccessControl($Path, $Security)
}

$JqPath = (Get-Command $Jq -CommandType Application -ErrorAction Stop).Path
$ActualJqVersion = (Invoke-NativeCapture -Executable $JqPath `
        -CommandArguments @("--version") -PassThru -Label "jq version").Trim()
if ($ActualJqVersion -cne "jq-$ExpectedJqVersion") {
    throw "Expected jq $ExpectedJqVersion, got $ActualJqVersion."
}

if ([string]::IsNullOrWhiteSpace($GeneratedAt)) {
    $GeneratedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
}
$ScanId = "{0}-{1}" -f [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ"), $PID
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path (Get-Location).Path "scan-results\vsphere-scan-$ScanId"
}
$FinalDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $FinalDirectory) {
    throw "Output directory already exists: $FinalDirectory"
}
$OutputParent = Split-Path -Parent $FinalDirectory
if ([string]::IsNullOrWhiteSpace($OutputParent)) { throw "Invalid output directory." }
New-Item -ItemType Directory -Force -Path $OutputParent | Out-Null
$StageDirectory = Join-Path $OutputParent (".vsphere-scan-" + [guid]::NewGuid())
$RawDirectory = $null
$OwnsRawDirectory = $false
$Published = $false

try {
    New-Item -ItemType Directory -Path $StageDirectory | Out-Null
    Protect-PrivateDirectory -Path $StageDirectory

    $RequiredRawFiles = @(
        "about.json",
        "objects.json",
        "datacenters.jsonseq",
        "clusters.jsonseq",
        "compute-resources.jsonseq",
        "hosts.jsonseq",
        "resource-pools.jsonseq",
        "datastores.jsonseq",
        "storage-pods.jsonseq",
        "distributed-switches.jsonseq",
        "networks.jsonseq",
        "distributed-portgroups.jsonseq",
        "opaque-networks.jsonseq",
        "virtual-machines.jsonseq",
        "source-devices.json"
    )

    if ($FixtureDir) {
        $RawDirectory = (Resolve-Path -LiteralPath $FixtureDir).Path
        $Server = "fixture.vcenter.invalid"
    }
    else {
        foreach ($Name in @("VSPHERE_SERVER", "VSPHERE_USER", "VSPHERE_PASSWORD")) {
            if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Name, "Process"))) {
                throw "Required environment variable is missing: $Name"
            }
        }
        if (Test-Truthy -Value $env:GOVC_INSECURE) {
            throw "GOVC_INSECURE must not enable insecure TLS."
        }
        if (Test-Truthy -Value $env:VSPHERE_ALLOW_UNVERIFIED_SSL) {
            throw "VSPHERE_ALLOW_UNVERIFIED_SSL must not enable insecure TLS."
        }

        $ServerInput = $env:VSPHERE_SERVER.Trim()
        if ($ServerInput.StartsWith("http://", [StringComparison]::OrdinalIgnoreCase)) {
            throw "vCenter must use HTTPS."
        }
        if ($ServerInput.StartsWith("https://", [StringComparison]::OrdinalIgnoreCase)) {
            $GovcBase = $ServerInput
        }
        elseif ($ServerInput.Contains("://")) {
            throw "Unsupported vCenter URL scheme."
        }
        else {
            $GovcBase = "https://$ServerInput"
        }
        $ParsedUri = New-Object -TypeName System.Uri -ArgumentList $GovcBase
        if ($ParsedUri.Scheme -cne "https") { throw "vCenter must use HTTPS." }
        if (-not [string]::IsNullOrEmpty($ParsedUri.UserInfo)) {
            throw "VSPHERE_SERVER must not contain credentials."
        }
        if (-not [string]::IsNullOrEmpty($ParsedUri.Query) -or
            -not [string]::IsNullOrEmpty($ParsedUri.Fragment)) {
            throw "VSPHERE_SERVER must not contain query or fragment."
        }
        $UriPath = $ParsedUri.AbsolutePath.TrimEnd("/")
        if (-not [string]::IsNullOrEmpty($UriPath) -and $UriPath -cne "/sdk") {
            throw "vCenter URL path must be /sdk or empty."
        }
        $Server = $ParsedUri.Authority
        $GovcUrl = "https://$Server/sdk"

        $GovcPath = (Get-Command $Govc -CommandType Application -ErrorAction Stop).Path
        $ActualGovcVersion = (Invoke-NativeCapture -Executable $GovcPath `
                -CommandArguments @("version") -PassThru -Label "govc version").Trim()
        if ($ActualGovcVersion -cne "govc $ExpectedGovcVersion") {
            throw "Expected govc $ExpectedGovcVersion, got $ActualGovcVersion."
        }

        $GovcEnvironment = @{
            "GOVC_URL"             = $GovcUrl
            "GOVC_USERNAME"        = $env:VSPHERE_USER
            "GOVC_PASSWORD"        = $env:VSPHERE_PASSWORD
            "GOVC_INSECURE"        = "false"
            "GOVC_PERSIST_SESSION" = "false"
            "GOVC_DEBUG"           = "false"
            "GOVC_TRACE"           = "false"
            "GOVC_VERBOSE"         = "false"
            "GOVC_DUMP"            = "false"
            "GOVC_DATACENTER"      = $null
            "GOVC_HOST"            = $null
            "GOVC_VM"              = $null
            "GOVC_SESSION"         = $null
            "GOVC_TLS_KNOWN_HOSTS" = $null
            "GOVC_CERTIFICATE"     = $null
            "GOVC_PRIVATE_KEY"     = $null
            "GOVC_DATASTORE"       = $null
            "GOVC_NETWORK"         = $null
            "GOVC_RESOURCE_POOL"   = $null
            "GOVC_FOLDER"          = $null
            "GOVC_GUEST_LOGIN"     = $null
        }
        if ($CaCert) {
            $GovcEnvironment["GOVC_TLS_CA_CERTS"] = (Resolve-Path -LiteralPath $CaCert).Path
        }
        else {
            $GovcEnvironment["GOVC_TLS_CA_CERTS"] = $null
        }

        $RawDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("vsphere-scan-raw-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $RawDirectory | Out-Null
        Protect-PrivateDirectory -Path $RawDirectory
        $OwnsRawDirectory = $true

        function Invoke-GovcFile {
            param([string]$FileName, [string[]]$CommandArguments)
            Invoke-NativeCapture -Executable $GovcPath -CommandArguments $CommandArguments `
                -Environment $GovcEnvironment -OutputFile (Join-Path $RawDirectory $FileName) `
                -Label "read-only govc $($CommandArguments[0])"
        }

        Invoke-GovcFile -FileName "about.json" -CommandArguments @("about", "-json")
        Invoke-NativeCapture -Executable $JqPath `
            -CommandArguments @("-e", '.about.apiType == "VirtualCenter"', (Join-Path $RawDirectory "about.json")) `
            -Label "vCenter endpoint check"
        Invoke-GovcFile -FileName "objects.json" -CommandArguments @("find", "-json", "-l", "-i", "/")
        $ObjectEntries = @(
            [System.IO.File]::ReadAllText((Join-Path $RawDirectory "objects.json"), $Utf8NoBom) |
                ConvertFrom-Json
        )

        function Invoke-GovcCollectIfPresent {
            param(
                [string]$FileName,
                [string]$InventoryType,
                [string]$CommandType,
                [string[]]$Properties
            )
            $Present = @($ObjectEntries | Where-Object {
                    $_.StartsWith("$InventoryType`:", [StringComparison]::Ordinal)
                }).Count -gt 0
            if ($Present) {
                Invoke-GovcFile -FileName $FileName -CommandArguments @(
                    @("object.collect", "-json", "-type", $CommandType, "/") + $Properties
                )
            }
            else {
                [System.IO.File]::WriteAllText((Join-Path $RawDirectory $FileName), "", $Utf8NoBom)
            }
        }

        Invoke-GovcCollectIfPresent -FileName "datacenters.jsonseq" `
            -InventoryType "Datacenter" -CommandType "d" `
            -Properties @("name", "parent", "overallStatus")
        Invoke-GovcCollectIfPresent -FileName "clusters.jsonseq" `
            -InventoryType "ClusterComputeResource" -CommandType "c" `
            -Properties @(
                "name", "parent", "overallStatus", "summary.numHosts", "summary.numEffectiveHosts",
                "summary.totalCpu", "summary.numCpuCores", "summary.totalMemory"
            )
        Invoke-GovcCollectIfPresent -FileName "compute-resources.jsonseq" `
            -InventoryType "ComputeResource" -CommandType "r" `
            -Properties @(
                "name", "parent", "overallStatus", "summary.numHosts", "summary.numEffectiveHosts",
                "summary.totalCpu", "summary.numCpuCores", "summary.totalMemory"
            )
        Invoke-GovcCollectIfPresent -FileName "hosts.jsonseq" `
            -InventoryType "HostSystem" -CommandType "h" `
            -Properties @(
                "name", "parent", "overallStatus", "runtime.connectionState", "runtime.powerState",
                "runtime.inMaintenanceMode", "summary.hardware.vendor", "summary.hardware.model",
                "summary.hardware.cpuMhz", "summary.hardware.numCpuCores", "summary.hardware.memorySize",
                "summary.config.product.fullName"
            )
        Invoke-GovcCollectIfPresent -FileName "resource-pools.jsonseq" `
            -InventoryType "ResourcePool" -CommandType "p" `
            -Properties @("name", "parent", "overallStatus", "runtime.cpu.maxUsage", "runtime.memory.maxUsage")
        Invoke-GovcCollectIfPresent -FileName "datastores.jsonseq" `
            -InventoryType "Datastore" -CommandType "s" `
            -Properties @(
                "name", "parent", "overallStatus", "summary.type", "summary.capacity", "summary.freeSpace",
                "summary.accessible", "summary.maintenanceMode"
            )
        Invoke-GovcCollectIfPresent -FileName "storage-pods.jsonseq" `
            -InventoryType "StoragePod" -CommandType "StoragePod" `
            -Properties @("name", "parent", "overallStatus")
        Invoke-GovcCollectIfPresent -FileName "distributed-switches.jsonseq" `
            -InventoryType "DistributedVirtualSwitch" -CommandType "w" `
            -Properties @("name", "parent", "overallStatus")
        Invoke-GovcCollectIfPresent -FileName "networks.jsonseq" `
            -InventoryType "Network" -CommandType "n" `
            -Properties @("name", "parent", "summary.accessible")
        Invoke-GovcCollectIfPresent -FileName "distributed-portgroups.jsonseq" `
            -InventoryType "DistributedVirtualPortgroup" -CommandType "g" `
            -Properties @("name", "parent", "summary.accessible", "config.distributedVirtualSwitch")
        Invoke-GovcCollectIfPresent -FileName "opaque-networks.jsonseq" `
            -InventoryType "OpaqueNetwork" -CommandType "o" `
            -Properties @("name", "parent", "summary.accessible")
        Invoke-GovcCollectIfPresent -FileName "virtual-machines.jsonseq" `
            -InventoryType "VirtualMachine" -CommandType "m" `
            -Properties @(
                "name", "parent", "runtime.powerState", "runtime.host", "resourcePool", "datastore", "network",
                "config.template", "config.guestId", "config.hardware.numCPU", "config.hardware.memoryMB",
                "config.version", "config.firmware", "config.bootOptions.efiSecureBootEnabled",
                "config.flags.vbsEnabled", "config.flags.vvtdEnabled", "config.nestedHVEnabled",
                "guest.toolsStatus", "guest.toolsRunningStatus", "guest.toolsVersionStatus2",
                "summary.storage.committed", "summary.storage.uncommitted"
            )

        $SourceFilter = @'
map(capture("^(?<type>[^:]+):(?<moid>[^\t]+)\t(?<path>.*)$")) |
map(select(.type == "VirtualMachine")) |
map(. + {ref: (.type + ":" + .moid), name: (.path | split("/")[-1])}) |
map(select(.path == $source or (.path | ltrimstr("/")) == ($source | ltrimstr("/")) or .name == $source)) |
if length == 1 then .[0].ref else "" end
'@
        $SourceRef = (Invoke-NativeCapture -Executable $JqPath `
                -CommandArguments @("-r", "--arg", "source", $SourceVm, $SourceFilter, (Join-Path $RawDirectory "objects.json")) `
                -PassThru -Label "source VM resolution").Trim()
        $SourceDevicesPath = Join-Path $RawDirectory "source-devices.json"
        if ([string]::IsNullOrWhiteSpace($SourceRef)) {
            [System.IO.File]::WriteAllText($SourceDevicesPath, "{`"devices`":[]}`n", $Utf8NoBom)
        }
        else {
            $DeviceJson = Invoke-NativeCapture -Executable $GovcPath -CommandArguments @(
                "device.info", "-json", "-vm", $SourceRef
            ) -Environment $GovcEnvironment -PassThru -Label "read-only govc device.info"
            $DevicePayload = $DeviceJson | ConvertFrom-Json
            $SafeDevices = New-Object System.Collections.ArrayList
            foreach ($Device in @($DevicePayload.devices)) {
                $Type = [string](Get-ObjectPropertyValue -InputObject $Device -Name "type")
                $Name = Get-ObjectPropertyValue -InputObject $Device -Name "name"
                $BusNumber = Get-ObjectPropertyValue -InputObject $Device -Name "busNumber"
                $SafeDevice = $null
                if ($Type -ceq "VirtualDisk") {
                    $SafeDevice = [ordered]@{
                        type            = $Type
                        name            = $Name
                        controllerKey   = Get-ObjectPropertyValue -InputObject $Device -Name "controllerKey"
                        unitNumber      = Get-ObjectPropertyValue -InputObject $Device -Name "unitNumber"
                        capacityInBytes = Get-ObjectPropertyValue -InputObject $Device -Name "capacityInBytes"
                        capacityInKB    = Get-ObjectPropertyValue -InputObject $Device -Name "capacityInKB"
                    }
                }
                elseif ($null -ne $BusNumber -and $Type -match '(?i:SCSI|LsiLogic|BusLogic)') {
                    $SafeDevice = [ordered]@{
                        type      = $Type
                        name      = $Name
                        key       = Get-ObjectPropertyValue -InputObject $Device -Name "key"
                        busNumber = $BusNumber
                    }
                }
                elseif ($null -ne $Device.PSObject.Properties["macAddress"]) {
                    $SafeDevice = [ordered]@{
                        type          = $Type
                        name          = $Name
                        controllerKey = Get-ObjectPropertyValue -InputObject $Device -Name "controllerKey"
                        unitNumber    = Get-ObjectPropertyValue -InputObject $Device -Name "unitNumber"
                        is_nic        = $true
                    }
                }
                elseif ($Type -ceq "VirtualTPM") {
                    $SafeDevice = [ordered]@{
                        type = $Type
                        name = $Name
                        key  = Get-ObjectPropertyValue -InputObject $Device -Name "key"
                    }
                }
                if ($null -ne $SafeDevice) { [void]$SafeDevices.Add($SafeDevice) }
            }
            $SafeDeviceJson = [ordered]@{devices = @($SafeDevices)} | ConvertTo-Json -Depth 5
            [System.IO.File]::WriteAllText($SourceDevicesPath, $SafeDeviceJson + "`n", $Utf8NoBom)
            $DeviceJson = $null
            $DevicePayload = $null
        }
    }

    foreach ($FileName in $RequiredRawFiles) {
        $RawPath = Join-Path $RawDirectory $FileName
        if (-not (Test-Path -LiteralPath $RawPath -PathType Leaf)) {
            throw "Discovery input is missing: $FileName"
        }
    }

    $NormalizeArguments = @(
        "-n",
        "--arg", "generated_at", $GeneratedAt,
        "--arg", "server", $Server,
        "--arg", "source_vm", $SourceVm,
        "--arg", "govc_version", $ExpectedGovcVersion,
        "--arg", "jq_version", $ExpectedJqVersion,
        "--slurpfile", "about", (Join-Path $RawDirectory "about.json"),
        "--slurpfile", "objects", (Join-Path $RawDirectory "objects.json"),
        "--slurpfile", "datacenters", (Join-Path $RawDirectory "datacenters.jsonseq"),
        "--slurpfile", "clusters", (Join-Path $RawDirectory "clusters.jsonseq"),
        "--slurpfile", "compute_resources", (Join-Path $RawDirectory "compute-resources.jsonseq"),
        "--slurpfile", "hosts", (Join-Path $RawDirectory "hosts.jsonseq"),
        "--slurpfile", "resource_pools", (Join-Path $RawDirectory "resource-pools.jsonseq"),
        "--slurpfile", "datastores", (Join-Path $RawDirectory "datastores.jsonseq"),
        "--slurpfile", "storage_pods", (Join-Path $RawDirectory "storage-pods.jsonseq"),
        "--slurpfile", "distributed_switches", (Join-Path $RawDirectory "distributed-switches.jsonseq"),
        "--slurpfile", "networks", (Join-Path $RawDirectory "networks.jsonseq"),
        "--slurpfile", "distributed_portgroups", (Join-Path $RawDirectory "distributed-portgroups.jsonseq"),
        "--slurpfile", "opaque_networks", (Join-Path $RawDirectory "opaque-networks.jsonseq"),
        "--slurpfile", "virtual_machines", (Join-Path $RawDirectory "virtual-machines.jsonseq"),
        "--slurpfile", "source_devices", (Join-Path $RawDirectory "source-devices.json"),
        "-f", (Join-Path $ScriptDir "discovery-normalize.jq")
    )
    $InventoryPath = Join-Path $StageDirectory "inventory.json"
    Invoke-NativeCapture -Executable $JqPath -CommandArguments $NormalizeArguments `
        -OutputFile $InventoryPath -Label "inventory normalization"
    Invoke-NativeCapture -Executable $JqPath -CommandArguments @(
        "-e",
        "-f",
        (Join-Path $ScriptDir "discovery-validate.jq"),
        $InventoryPath
    ) -Label "inventory schema check"

    Invoke-NativeCapture -Executable $JqPath -CommandArguments @(
        "-r", "-f", (Join-Path $ScriptDir "discovery-report.jq"), $InventoryPath
    ) -OutputFile (Join-Path $StageDirectory "inventory.md") -Label "Markdown report"
    Invoke-NativeCapture -Executable $JqPath -CommandArguments @(
        "-r", "-f", (Join-Path $ScriptDir "discovery-tree.jq"), $InventoryPath
    ) -OutputFile (Join-Path $StageDirectory "inventory-tree.txt") -Label "inventory tree"
    Invoke-NativeCapture -Executable $JqPath -CommandArguments @(
        "-r", "-f", (Join-Path $ScriptDir "discovery-tfvars.jq"), $InventoryPath
    ) -OutputFile (Join-Path $StageDirectory "windows-clone.generated.tfvars") -Label "generated tfvars"

    $ResultFiles = @(
        "inventory.json",
        "inventory.md",
        "inventory-tree.txt",
        "windows-clone.generated.tfvars"
    )
    $ChecksumLines = @($ResultFiles | ForEach-Object {
            $Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $StageDirectory $_)).Hash.ToLowerInvariant()
            "$Hash  $_"
        })
    [System.IO.File]::WriteAllText(
        (Join-Path $StageDirectory "SHA256SUMS"),
        ([string]::Join("`n", $ChecksumLines) + "`n"),
        $Utf8NoBom
    )

    Move-Item -LiteralPath $StageDirectory -Destination $FinalDirectory
    $Published = $true

    $Counts = (Invoke-NativeCapture -Executable $JqPath -CommandArguments @(
            "-r",
            '"datacenters=\(.counts.datacenters) clusters=\(.counts.clusters) hosts=\(.counts.hosts) datastores=\(.counts.datastores) networks=\(.counts.networks) vms=\(.counts.virtual_machines) templates=\(.counts.templates)"',
            (Join-Path $FinalDirectory "inventory.json")
        ) -PassThru -Label "result summary").Trim()
    Write-Host "Read-only scan complete: $Counts"
    Write-Host "Private report directory: $FinalDirectory"
}
finally {
    if ($OwnsRawDirectory -and $RawDirectory -and (Test-Path -LiteralPath $RawDirectory)) {
        Remove-Item -LiteralPath $RawDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $Published -and (Test-Path -LiteralPath $StageDirectory)) {
        Remove-Item -LiteralPath $StageDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
