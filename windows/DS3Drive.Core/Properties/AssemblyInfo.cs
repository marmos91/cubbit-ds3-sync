using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

// Expose internal types (DS3ExceptionFactory, DS3Native, Native marshalling
// helpers) to the test assembly so Wave-0 unit tests can exercise them
// directly without a public surface leak. See 17-05-PLAN Task 1/2.
[assembly: InternalsVisibleTo("DS3Drive.Tests")]

// Threat T-17-05-04 (DLL hijack of ds3_ffi.dll): restrict the unmanaged DLL
// search to the assembly directory + System32, so a planted ds3_ffi.dll in the
// working directory or %PATH% cannot be loaded. The MSI installs to
// %ProgramFiles% (Plan 12); the DLL is staged next to the managed assembly.
[assembly: DefaultDllImportSearchPaths(
    DllImportSearchPath.AssemblyDirectory | DllImportSearchPath.System32)]
