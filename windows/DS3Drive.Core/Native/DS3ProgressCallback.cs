namespace DS3Drive.Core.Native;

/// <summary>
/// Managed transfer-progress callback: <c>(transferred, total)</c> in bytes.
/// Adapter over the native <c>DS3ProgressCallbackFn</c> ABI (which also passes an
/// opaque context pointer the facade owns). Used by
/// <see cref="DS3Drive.Core.DS3Session"/> download/upload methods.
/// </summary>
public delegate void DS3ProgressCallback(long transferred, long total);
