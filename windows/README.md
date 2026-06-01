# DS3 Drive — Windows

Windows-native shell for Cubbit DS3 Drive: a WinUI 3 tray app plus a
[Cloud Files API (cfapi)](https://learn.microsoft.com/en-us/windows/win32/cfapi/cloud-files-api-portal)
sync engine that presents Cubbit DS3 (S3-compatible) buckets as on-demand
drives in Windows Explorer. All S3 operations and authentication run in the
shared Rust core (`../core/`), consumed from C# via P/Invoke.

## Solution layout

```
windows/
├── DS3Drive.sln
├── Directory.Build.props        # shared MSBuild props (nullable, warnings-as-errors, lock file)
├── Directory.Packages.props     # central package version management
├── DS3Drive.App/                # WinUI 3 packaged exe (UI, ViewModels, tray) — sparse-package-ready
├── DS3Drive.Sync/               # class lib — cfapi provider + sync engine (SQLite placeholder index)
├── DS3Drive.Core/               # class lib — Rust facade (P/Invoke), credential + config stores
│   └── core-build/              # MSBuild target that invokes cargo + stages the native DLL
└── DS3Drive.Tests/              # xUnit tests for Sync + Core
```

Project references: `DS3Drive.App` → `DS3Drive.Sync` → `DS3Drive.Core`.
`DS3Drive.Tests` references `DS3Drive.Core` + `DS3Drive.Sync`.

## Prerequisites

- **.NET 8 SDK** — <https://dotnet.microsoft.com/download/dotnet/8.0>
- **Visual Studio 2022 17.10+** (with "Windows App SDK C# Templates" / WinUI workload),
  or **VS Code + C# Dev Kit**.
- **Rust toolchain** via [rustup](https://rustup.rs/) with the Windows targets installed:
  ```pwsh
  rustup target add x86_64-pc-windows-msvc aarch64-pc-windows-msvc
  ```
  The `DS3Drive.Core` build invokes `cargo` on every build to compile the
  native core library (see below).
- **WiX Toolset v4 CLI** (for the MSI installer, later plans):
  ```pwsh
  dotnet tool install --global wix --version 4.*
  ```

## Build & test

```pwsh
dotnet restore windows/DS3Drive.sln
dotnet build   windows/DS3Drive.sln
dotnet test    windows/DS3Drive.sln
```

Central package management means projects declare `<PackageReference Include="Foo" />`
without a version; versions are pinned in `Directory.Packages.props`.

## Native core artifact: `ds3_ffi.dll`

The Rust core crate (`core/ds3-ffi`) declares `[lib] name = "ds3_ffi"`, so cargo
emits **`ds3_ffi.dll`** on Windows.

> **Artifact-name disclaimer:** the native library is named **`ds3_ffi`** — NOT
> the older `ds3` + `_` + `core` name used in some early planning notes (e.g.
> CONTEXT.md D-06). That older name is **stale**. The established, Apple-shared
> artifact name is `ds3_ffi`, and the Windows P/Invoke layer loads `ds3_ffi`
> accordingly. Do not reintroduce the stale name anywhere in `windows/`.

`DS3Drive.Core/core-build/DS3Core.Build.targets` runs `cargo build -p ds3-ffi`
for the active RID's target triple on every build and copies the resulting
`ds3_ffi.dll` into:

```
DS3Drive.Core/runtimes/win-x64/native/ds3_ffi.dll      (x86_64-pc-windows-msvc)
DS3Drive.Core/runtimes/win-arm64/native/ds3_ffi.dll    (aarch64-pc-windows-msvc)
```

These follow the NuGet runtimes-folder convention so the DLL resolves
automatically at run time and on publish.
