# build-msi.ps1 — MSI build for Cubbit DS3 Drive (WIN-09 / CONTEXT D-28).
# Pipeline: ds3_ffi.dll -> dotnet publish -> sparse msix -> wix build -> sign.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,   # e.g. 2.0.0.0
    [ValidateSet('Debug', 'Release')][string]$Profile = 'Release',
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\bin\Release'),
    [string]$CertPath,                                # optional Authenticode .pfx (D-29)
    [System.Security.SecureString]$CertPassword,      # SecureString: keeps pwd out of history (T-17-04-03)
    [switch]$SkipSign
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pipeline notes:
#   RESEARCH Pitfall 6: the native artifact is ds3_ffi.dll (the Phase 15 [lib] name).
#   RESEARCH Pitfall 7: sparse manifest Version is pinned to -Version byte-for-byte (step 4).
#   D-29: signing optional; unsigned MSI acceptable for the P17 beta (cert = Phase 18 POL-05).

# Normalise paths.
$repoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$installer  = $PSScriptRoot
$publishDir = Join-Path $OutputDir 'publish'
$identityDir = Join-Path $publishDir 'Identity'
$msiPath    = Join-Path $OutputDir "DS3Drive-$Version-x64.msi"

# Cargo profile flag (Debug -> dev/debug, Release -> release) mirrors D-07.
$cargoProfile = if ($Profile -eq 'Release') { 'release' } else { 'debug' }

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# --- 1. Build the Rust native DLL (ds3_ffi.dll) ------------------------------
Write-Host "==> [1/6] Building Rust core (ds3_ffi.dll, $cargoProfile)"
& (Join-Path $repoRoot 'core\scripts\build-dll-windows.ps1') -BuildProfile $cargoProfile
if ($LASTEXITCODE -ne 0) { throw "build-dll-windows.ps1 failed with exit code $LASTEXITCODE" }

# Stage the freshly-built x64 DLL where DS3Drive.Core's publish step expects it.
$coreNative = Join-Path $repoRoot 'windows\DS3Drive.Core\runtimes\win-x64\native'
New-Item -ItemType Directory -Force -Path $coreNative | Out-Null
Copy-Item -Force `
    -Path (Join-Path $repoRoot 'core\out\windows\runtimes\win-x64\native\ds3_ffi.dll') `
    -Destination (Join-Path $coreNative 'ds3_ffi.dll')

# --- 2. dotnet publish the WinUI 3 app ---------------------------------------
Write-Host "==> [2/6] Publishing DS3Drive.App ($Profile, win-x64)"
& dotnet publish (Join-Path $repoRoot 'windows\DS3Drive.App\DS3Drive.App.csproj') `
    --configuration $Profile `
    --runtime win-x64 `
    --self-contained false `
    -p:DS3SkipRustCore=true `
    --output $publishDir
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE" }

# --- 3. Pack the sparse identity package -------------------------------------
Write-Host "==> [3/6] Packing sparse identity package -> Identity\DS3Drive.Identity.msix"
$sparseArgs = @{
    ManifestPath = (Join-Path $installer 'SparsePackage\Package.appxmanifest')
    OutputDir    = $identityDir
}
if ($SkipSign -or -not $CertPath) {
    $sparseArgs.SkipSign = $true
} else {
    $sparseArgs.CertPath = $CertPath
    if ($CertPassword) { $sparseArgs.CertPassword = $CertPassword }
}
& (Join-Path $installer 'SparsePackage\build-sparse.ps1') @sparseArgs
if ($LASTEXITCODE -ne 0) { throw "build-sparse.ps1 failed with exit code $LASTEXITCODE" }

# --- 4. Sync Variables.wxi ProductVersion to -Version (Pitfall 7) ------------
Write-Host "==> [4/6] Pinning Variables.wxi ProductVersion = $Version"
$varsPath = Join-Path $installer 'Variables.wxi'
$vars = Get-Content -Raw -LiteralPath $varsPath
$vars = $vars -replace '(<\?define ProductVersion = ")[^"]*(" \?>)', "`${1}$Version`${2}"
Set-Content -LiteralPath $varsPath -Value $vars -NoNewline

# Keep the sparse manifest <Identity Version> in lock-step (RESEARCH Pitfall 7).
$manifestPath = Join-Path $installer 'SparsePackage\Package.appxmanifest'
$manifest = Get-Content -Raw -LiteralPath $manifestPath
$manifest = $manifest -replace '(<Identity[^>]*?Version=")[^"]*(")', "`${1}$Version`${2}"
Set-Content -LiteralPath $manifestPath -Value $manifest -NoNewline

# --- 5. Build the MSI via the WiX CLI ----------------------------------------
Write-Host "==> [5/6] Building MSI -> $msiPath"
& wix build `
    (Join-Path $installer 'Product.wxs') `
    (Join-Path $installer 'Components.wxs') `
    (Join-Path $installer 'UI.wxs') `
    -bindpath "publish=$publishDir" `
    -ext WixToolset.UI.wixext `
    -arch x64 `
    -out $msiPath
if ($LASTEXITCODE -ne 0) { throw "wix build failed with exit code $LASTEXITCODE" }

# --- 6. Optionally Authenticode-sign the MSI (D-29) --------------------------
if ($SkipSign) {
    Write-Warning "SkipSign set; emitting UNSIGNED MSI. SmartScreen will warn on first run " +
                  "(CONTEXT D-29 — acceptable for the P17 beta; cert procurement = Phase 18 POL-05)."
}
elseif ($CertPath) {
    if (-not (Test-Path -LiteralPath $CertPath)) { throw "Cert not found: $CertPath" }
    Write-Host "==> [6/6] Signing MSI with $CertPath (SHA256 + RFC-3161 timestamp)"
    if ($CertPassword) {
        # Marshal the SecureString to plaintext only at the call site, then zero it (T-17-04-03).
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($CertPassword)
        try {
            $plainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            & signtool sign /fd SHA256 /a /f $CertPath /p $plainPwd /tr http://timestamp.digicert.com /td SHA256 $msiPath
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
    else {
        & signtool sign /fd SHA256 /a /f $CertPath /tr http://timestamp.digicert.com /td SHA256 $msiPath
    }
    if ($LASTEXITCODE -ne 0) { throw "signtool sign failed with exit code $LASTEXITCODE" }
}
else {
    Write-Warning "No -CertPath provided; emitting UNSIGNED MSI (CONTEXT D-29 — P17 beta)."
}

# --- Report ------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $msiPath)) { throw "Expected MSI not produced: $msiPath" }
$item   = Get-Item -LiteralPath $msiPath
$sha256 = (Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash

Write-Host ""
Write-Host "=== DS3Drive-$Version-x64.msi ==="
Write-Host "Path    : $msiPath"
Write-Host "Version : $Version"
Write-Host "Size    : $($item.Length) bytes"
Write-Host "SHA256  : $sha256"

exit 0
