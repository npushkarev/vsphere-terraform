[CmdletBinding()]
param([string]$ProjectDir = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if ($PSVersionTable.PSVersion -lt [Version]"5.1") {
    throw "PowerShell 5.1 or newer is required."
}

$ProjectDir = [System.IO.Path]::GetFullPath($ProjectDir).TrimEnd("\")
$VendorDir = Join-Path $ProjectDir "vendor"
$ManifestPath = Join-Path $VendorDir "MANIFEST.sha256"
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Vendor manifest is missing."
}
if ((Get-Item -LiteralPath $ManifestPath -Force).Attributes -band
    [System.IO.FileAttributes]::ReparsePoint) {
    throw "Vendor manifest must not be a reparse point."
}

$ReparseItems = @(Get-ChildItem -LiteralPath $VendorDir -Recurse -Force |
        Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint })
if ($ReparseItems.Count -ne 0) {
    throw "Vendor directory must not contain reparse points."
}

$Expected = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' `
    -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
$VendorRoot = [System.IO.Path]::GetFullPath($VendorDir).TrimEnd("\") + "\"
foreach ($Line in [System.IO.File]::ReadAllLines($ManifestPath, [System.Text.Encoding]::ASCII)) {
    if ($Line -notmatch '^([0-9a-f]{64})  (vendor/.+)$') {
        throw "Invalid vendor manifest line."
    }
    $ExpectedHash = $Matches[1]
    $RelativePath = $Matches[2]
    if ($RelativePath.Contains("\") -or $RelativePath.Contains(":") -or
        $RelativePath.Contains("//")) {
        throw "Unsafe vendor manifest path: $RelativePath"
    }
    foreach ($Segment in $RelativePath.Split("/")) {
        if ($Segment -ceq "." -or $Segment -ceq ".." -or
            $Segment.EndsWith(".") -or $Segment.EndsWith(" ")) {
            throw "Unsafe vendor manifest path: $RelativePath"
        }
    }
    if (-not $Expected.Add($RelativePath)) {
        throw "Duplicate vendor manifest path: $RelativePath"
    }
    $Candidate = [System.IO.Path]::GetFullPath((Join-Path $ProjectDir $RelativePath.Replace("/", "\")))
    if (-not $Candidate.StartsWith($VendorRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Vendor manifest path escapes vendor directory: $RelativePath"
    }
    if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
        throw "Vendor file is missing: $RelativePath"
    }
    $Item = Get-Item -LiteralPath $Candidate -Force
    if ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Vendor file must not be a reparse point: $RelativePath"
    }
    if ($Item.Length -ge 99614720) {
        throw "Vendor file exceeds the 95 MiB repository policy: $RelativePath"
    }
    $ActualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Candidate).Hash.ToLowerInvariant()
    if ($ActualHash -cne $ExpectedHash) {
        throw "Vendor checksum mismatch: $RelativePath"
    }
}
if ($Expected.Count -eq 0) { throw "Vendor manifest is empty." }

$Actual = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' `
    -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
foreach ($File in Get-ChildItem -LiteralPath $VendorDir -Recurse -File -Force) {
    if ([StringComparer]::OrdinalIgnoreCase.Equals($File.FullName, $ManifestPath)) { continue }
    $Relative = $File.FullName.Substring($ProjectDir.Length + 1).Replace("\", "/")
    if (-not $Actual.Add($Relative)) { throw "Duplicate vendor file path: $Relative" }
}
if ($Actual.Count -ne $Expected.Count) {
    throw "Vendor manifest does not match the exact file set."
}
foreach ($Path in $Actual) {
    if (-not $Expected.Contains($Path)) {
        throw "Vendor file is not listed in manifest: $Path"
    }
}

Write-Host "Vendored offline payload verified."
