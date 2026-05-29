using DS3Drive.Core.Generated;

namespace DS3Drive.Core.Native;

/// <summary>
/// Managed wrapper over the Rust cancellation handle
/// (<c>ds3_cancellation_create</c>/<c>_cancel</c>/<c>_destroy</c>). Parallels
/// Phase 16 D-20's use of .NET <c>CancellationToken</c>: pass an instance into a
/// long-running transfer (download/upload) and call <see cref="Cancel"/> to
/// request abort; dispose frees the native handle exactly once.
///
/// The native pointer is opaque (an <c>Arc&lt;CancellationHandle&gt;</c> raw
/// pointer on the Rust side); this type never dereferences it.
/// </summary>
public sealed class CancellationHandle : IDisposable
{
    private IntPtr _handle;

    /// <summary>
    /// Creates a fresh handle in the "not cancelled" state.
    /// </summary>
    /// <exception cref="InvalidOperationException">If the native allocation failed (null handle).</exception>
    public CancellationHandle()
    {
        _handle = DS3Native.ds3_cancellation_create();
        if (_handle == IntPtr.Zero)
        {
            throw new InvalidOperationException("ds3_cancellation_create returned null (allocation panic).");
        }
    }

    /// <summary>The raw native pointer, for passing into transfer FFI calls. Zero after dispose.</summary>
    internal IntPtr Raw => _handle;

    /// <summary>Requests cancellation. Idempotent and thread-safe; a no-op after dispose.</summary>
    public void Cancel()
    {
        IntPtr h = _handle;
        if (h != IntPtr.Zero)
        {
            DS3Native.ds3_cancellation_cancel(h);
        }
    }

    /// <summary>Destroys the native handle exactly once (Interlocked guard; double-dispose is a no-op).</summary>
    public void Dispose()
    {
        IntPtr prev = Interlocked.Exchange(ref _handle, IntPtr.Zero);
        if (prev != IntPtr.Zero)
        {
            DS3Native.ds3_cancellation_destroy(prev);
        }
    }
}
