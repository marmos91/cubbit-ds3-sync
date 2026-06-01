@echo off
setlocal
rem ============================================================================
rem run-cargo.cmd — build ds3-ffi for a given target inside the MSVC + LLVM env.
rem
rem Invoked by DS3Core.Build.targets. A C# MSBuild project does NOT set up the
rem Visual C++ developer environment, so cargo's cc-rs cannot find cl.exe for the
rem ARM64 target (it falls back to clang and fails). We therefore:
rem   1. locate VS via vswhere,
rem   2. call vcvarsall.bat for the host_target arch combo (populates INCLUDE/LIB/PATH),
rem   3. prepend the VS LLVM bin so clang/clang-cl are found — aws-lc-sys needs
rem      clang to assemble its ARM64 (armv8) crypto .S files,
rem   4. run cargo from the repo's core/ directory.
rem
rem Args:  %1 = vcvars arch arg (x64 | arm64 | x64_arm64 | arm64_x64)
rem        %2 = rust target triple (e.g. aarch64-pc-windows-msvc)
rem        %3 = cargo profile flag (--release, or empty for debug)
rem
rem Security (T-17-02-02): the cargo working directory is the caller-pinned core/
rem dir passed as the process CWD; no user input flows into the command.
rem ============================================================================
set "VCARCH=%~1"
set "TRIPLE=%~2"
set "PROFILEFLAG=%~3"
set "COREDIR=%CD%"

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" set "VSWHERE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
  echo run-cargo: ERROR vswhere.exe not found 1>&2
  exit /b 1
)

set "VSPATH="
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
if not defined VSPATH (
  echo run-cargo: ERROR Visual Studio with C++ tools not found 1>&2
  exit /b 1
)

rem vcvarsall.bat itself shells out to vswhere by name — make it reachable.
set "PATH=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer;%PATH%"

call "%VSPATH%\VC\Auxiliary\Build\vcvarsall.bat" %VCARCH%
if errorlevel 1 (
  echo run-cargo: ERROR vcvarsall.bat %VCARCH% failed 1>&2
  exit /b 1
)

rem clang for aws-lc-sys ARM64 assembly (harmless to prepend on x64 targets).
if exist "%VSPATH%\VC\Tools\Llvm\bin\clang.exe" set "PATH=%VSPATH%\VC\Tools\Llvm\bin;%PATH%"

rem vcvarsall may change the working directory — return to core/ before building.
cd /d "%COREDIR%"
cargo build -p ds3-ffi --target %TRIPLE% %PROFILEFLAG%
exit /b %errorlevel%
