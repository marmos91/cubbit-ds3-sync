# Debugging DS3 Drive in Visual Studio (F5)

The Windows app is **unpackaged** (`WindowsPackageType=None`) and gets package identity from a
**sparse identity package** (`DS3Drive.Installer/SparsePackage/Package.appxmanifest`). cfapi's
`StorageProviderSyncRootManager.Register` **requires package identity**, so a bare F5 of the
unpackaged exe throws at sync-root registration — login + the wizard run, but no drive appears in
Explorer. To debug with cfapi working, register the sparse package against the F5 build output
once, then F5 normally (breakpoints attach to the launched exe regardless of identity).

## 1. Install Visual Studio 2022 (Community is fine)

In the VS Installer, select these **workloads**:

- **.NET desktop development**
- **Windows application development**  ← this is the WinUI 3 / Windows App SDK workload (templates,
  single-project MSIX tooling, Windows SDK). Required.
- **Desktop development with C++**  ← gives MSVC so `cargo` (the `BuildRustCore` MSBuild target that
  builds `ds3_ffi.dll` on every build) links cleanly inside the IDE.

Individual components (most are pulled in by the workloads above; verify):
- **Windows 11 SDK (10.0.26100)** — already on this machine.
- **.NET 8.0 SDK** — already on this machine.
- **MSIX Packaging Tools** (optional; we pack the sparse package via `build-sparse.ps1` + MakeAppx).

Rust toolchain (already installed): `rustup`, target `x86_64-pc-windows-msvc`. The `BuildRustCore`
target runs `cargo build -p ds3-ffi --target x86_64-pc-windows-msvc` on every build. To skip it
(managed-only, faster inner loop once the DLL exists) set MSBuild property `DS3SkipRustCore=true`.

## 2. Enable Developer Mode

Settings → Privacy & security → For developers → **Developer Mode = On**. Required to register the
unsigned sparse package (or sign it — see step 4).

## 3. Open + configure the solution

- Open `windows/DS3Drive.sln`.
- Set **`DS3Drive.App`** as the Startup Project.
- Solution Configuration: **Debug**, Platform: **x64** (this is an ARM64 host running the x64 build
  under emulation, per CONTEXT D-32; x64 is the only target with a built native DLL today).
- Build once (Ctrl+Shift+B) so `bin\x64\Debug\…\DS3Drive.App.exe` + `ds3_ffi.dll` exist.

## 4. Register the sparse identity against the build output (the cfapi enabler)

> **This step is finalized after VS is installed and the first build exists** — the exact F5 output
> path (WinUI apps may nest a `win-x64\` subfolder) and the self-signed dev cert are wired by
> `register-dev-identity.ps1` (to be added). The shape:
>
> 1. Self-sign a dev cert with subject `CN=Cubbit Srl, O=Cubbit Srl, L=Bologna, S=BO, C=IT`
>    (must match `Package.appxmanifest` `<Identity Publisher>` byte-for-byte), trust it in
>    `Cert:\CurrentUser\Root` + `TrustedPeople`.
> 2. `build-sparse.ps1` → `DS3Drive.Identity.msix` (signed with that cert).
> 3. `Add-AppxPackage -Path DS3Drive.Identity.msix -ExternalLocation <App x64 Debug output dir>`.
>
> Re-run only when the manifest identity changes; plain rebuilds keep the registration.

## 5. F5

Breakpoints work across `DS3Drive.App` / `DS3Drive.ViewModels` / `DS3Drive.Sync` / `DS3Drive.Core`.
cfapi callbacks run on OS threads — they'll hit breakpoints too. Runtime cfapi/sync logs also go to
ETW (`Cubbit-DS3Drive-App` / `…-Provider` providers) viewable in Event Viewer, per `manual-smoke-D-33.md`.

## Known issues to expect while testing (see 17-PRE-PR-REVIEW.md)

- **Conflict copy (smoke item 13) has a data-loss bug** — not yet fixed.
- App-restart-resume won't re-sync yet (no session restore); first-run in one session is the supported path.
