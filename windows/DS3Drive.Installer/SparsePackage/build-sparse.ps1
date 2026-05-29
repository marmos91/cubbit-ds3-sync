# build-sparse.ps1 — packs and (optionally) signs the DS3 Drive sparse identity
# package into DS3Drive.Identity.msix (consumed by the WiX MSI in Plan 12 via
# `Add-AppxPackage -ExternalLocation`). See RESEARCH §"Don't Hand-Roll" (MSIX manifest
# authoring — schema only validated at MakeAppx pack time) and CONTEXT D-29
# (Authenticode cert timing — unsigned MSIX acceptable for the P17 beta).
[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'Package.appxmanifest'),
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\bin'),
    [string]$CertPath,
    [System.Security.SecureString]$CertPassword,  # SecureString: keeps cert pwd out of history (T-17-04-03)
    [switch]$SkipSign
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-SdkTool {
    param([Parameter(Mandatory)][string]$ToolName)

    $glob = "C:\Program Files (x86)\Windows Kits\10\bin\*\x64\$ToolName"
    $tool = Get-ChildItem -Path $glob -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1

    if (-not $tool) {
        throw "Could not locate $ToolName under the Windows 10 SDK " +
              "('C:\Program Files (x86)\Windows Kits\10\bin\*\x64\'). " +
              "Install the Windows 10/11 SDK (or the 'Desktop development with C++' " +
              "Visual Studio workload) and retry."
    }
    return $tool.FullName
}

# --- Resolve SDK tooling -----------------------------------------------------
$makeAppx = Resolve-SdkTool -ToolName 'MakeAppx.exe'
Write-Verbose "MakeAppx: $makeAppx"

$signTool = $null
if (-not $SkipSign) {
    $signTool = Resolve-SdkTool -ToolName 'SignTool.exe'
    Write-Verbose "SignTool: $signTool"
}

# --- Validate inputs ---------------------------------------------------------
if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Manifest not found: $ManifestPath"
}

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
$msixPath = Join-Path $OutputDir 'DS3Drive.Identity.msix'

# --- Pack --------------------------------------------------------------------
# /m  = pack from a manifest (no layout dir; sparse package references external content)
# /nv = skip semantic validation (the manifest is hand-authored per RESEARCH §Don't Hand-Roll)
Write-Host "Packing sparse package -> $msixPath"
& $makeAppx pack /m $ManifestPath /p $msixPath /nv
if ($LASTEXITCODE -ne 0) {
    throw "MakeAppx pack failed with exit code $LASTEXITCODE"
}

# --- Sign (optional) ---------------------------------------------------------
if ($SkipSign) {
    Write-Warning "SkipSign set; emitting UNSIGNED MSIX. 'Add-AppxPackage -ExternalLocation' " +
                  "will require a dev-mode-enabled machine (CONTEXT D-29 / RESEARCH Open Question #5)."
}
elseif ($CertPath) {
    if (-not (Test-Path -LiteralPath $CertPath)) {
        throw "Cert not found: $CertPath"
    }
    Write-Host "Signing $msixPath with $CertPath"
    if ($CertPassword) {
        # Marshal the SecureString to a plaintext password only at the call site,
        # then zero it immediately (threat T-17-04-03).
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($CertPassword)
        try {
            $plainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            & $signTool sign /fd SHA256 /a /f $CertPath /p $plainPwd $msixPath
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
    else {
        & $signTool sign /fd SHA256 /a /f $CertPath $msixPath
    }
    if ($LASTEXITCODE -ne 0) {
        throw "SignTool sign failed with exit code $LASTEXITCODE"
    }
}
else {
    Write-Warning "No -CertPath provided; emitting UNSIGNED MSIX. 'Add-AppxPackage -ExternalLocation' " +
                  "will require a dev-mode-enabled machine (CONTEXT D-29 / RESEARCH Open Question #5)."
}

# --- Report ------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $msixPath)) {
    throw "Expected output not produced: $msixPath"
}

$item = Get-Item -LiteralPath $msixPath
$sha256 = (Get-FileHash -LiteralPath $msixPath -Algorithm SHA256).Hash

# Read the manifest <Identity> version so the report ties the artifact to its version.
[xml]$manifestXml = Get-Content -Raw -LiteralPath $ManifestPath
$version = $manifestXml.Package.Identity.Version

Write-Host ""
Write-Host "=== DS3Drive.Identity.msix ==="
Write-Host "Path    : $msixPath"
Write-Host "Version : $version"
Write-Host "Size    : $($item.Length) bytes"
Write-Host "SHA256  : $sha256"

exit 0
