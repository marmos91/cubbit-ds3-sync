# Build ds3_ffi.dll for Windows from the ds3-ffi Rust crate (PowerShell).
#
# Targets (per 17-CONTEXT.md D-06):
#   - x86_64-pc-windows-msvc   -> runtimes\win-x64\native\ds3_ffi.dll
#   - aarch64-pc-windows-msvc  -> runtimes\win-arm64\native\ds3_ffi.dll
#
# Artifact name: ds3_ffi.dll (NOT ds3_core.dll - see 17-RESEARCH Pitfall 6).
# The companion shell script (build-dll-windows.sh) produces the same layout
# on a darwin / Linux host via cross-compilation.
#
# Usage:
#   pwsh -NoProfile -File .\core\scripts\build-dll-windows.ps1 [-BuildProfile release|debug]
#
# NOTE: the parameter is `-BuildProfile`, NOT `-Profile` — PowerShell exposes
# `$PROFILE` as an automatic variable holding the path to the current user's
# profile script. Shadowing it with `param([string]$Profile)` works inside
# this script but creates a silent footgun if a helper function is later
# extracted: outside the script's param scope `$Profile` reverts to the
# profile-script path and cargo receives a garbage `--release`/empty value.
#
# Prerequisites:
#   - Visual Studio 2022 Build Tools with the MSVC x64/ARM64 toolsets
#   - Rust toolchain with the Windows MSVC targets installed
#       rustup target add x86_64-pc-windows-msvc aarch64-pc-windows-msvc

param(
    [ValidateSet('release','debug')]
    [string]$BuildProfile = 'release'
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$DllName      = 'ds3_ffi.dll'
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$CoreDir      = (Resolve-Path (Join-Path $ScriptDir '..')).Path
$OutBase      = Join-Path $CoreDir 'out\windows'
$CargoManifest = Join-Path $CoreDir 'Cargo.toml'

Set-Location $CoreDir

if ($BuildProfile -eq 'release') {
    $BuildProfileFlag = '--release'
} else {
    $BuildProfileFlag = ''
}

# Cargo target triple -> NuGet runtime identifier (D-06 layout).
$Targets = @(
    @{ Triple = 'x86_64-pc-windows-msvc';  Rid = 'win-x64'   },
    @{ Triple = 'aarch64-pc-windows-msvc'; Rid = 'win-arm64' }
)

Write-Host "==> Building $DllName for $($Targets.Count) Windows targets ($BuildProfile)..."
Write-Host "    Artifact name: $DllName (canonical per 17-RESEARCH Pitfall 6)"

# ---------------------------------------------------------------------------
# Step 1: Ensure Windows rustup targets are installed.
# ---------------------------------------------------------------------------
Write-Host '==> Ensuring rustup targets are installed...'
foreach ($t in $Targets) {
    & rustup target add $t.Triple | Out-Null
}

# ---------------------------------------------------------------------------
# Step 2: Build the DLL for each Windows target.
# ---------------------------------------------------------------------------
foreach ($t in $Targets) {
    $triple = $t.Triple
    $rid    = $t.Rid
    Write-Host "==> cargo build --target $triple ($rid)"

    $cargoArgs = @(
        'build',
        '--manifest-path', $CargoManifest,
        '--package', 'ds3-ffi',
        '--target', $triple
    )
    if ($BuildProfileFlag -ne '') { $cargoArgs += $BuildProfileFlag }
    & cargo @cargoArgs
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed for $triple (exit $LASTEXITCODE)"
    }

    $srcDll  = Join-Path $CoreDir "target\$triple\$BuildProfile\$DllName"
    $destDir = Join-Path $OutBase "runtimes\$rid\native"
    $destDll = Join-Path $destDir $DllName

    if (-not (Test-Path -LiteralPath $srcDll)) {
        throw "Expected DLL not found at $srcDll"
    }

    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }
    Copy-Item -Force -LiteralPath $srcDll -Destination $destDll
}

# ---------------------------------------------------------------------------
# Step 3: Summary table (triple -> size -> sha256).
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '==> Build complete. Artifacts:'
'{0,-30} {1,-15} {2,-12} {3}' -f 'TRIPLE','RID','SIZE','SHA256' | Write-Host

foreach ($t in $Targets) {
    $triple = $t.Triple
    $rid    = $t.Rid
    $destDll = Join-Path $OutBase "runtimes\$rid\native\$DllName"

    if (-not (Test-Path -LiteralPath $destDll)) {
        throw "$destDll missing after build"
    }

    $size = (Get-Item -LiteralPath $destDll).Length
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $destDll).Hash.ToLower()
    '{0,-30} {1,-15} {2,-12} {3}' -f $triple, $rid, $size, $hash | Write-Host
}

Write-Host ''
Write-Host "==> Layout: $OutBase\runtimes\win-x64\native\$DllName"
Write-Host "             $OutBase\runtimes\win-arm64\native\$DllName"
