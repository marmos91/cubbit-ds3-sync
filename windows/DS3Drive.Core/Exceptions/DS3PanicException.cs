namespace DS3Drive.Core.Exceptions;

/// <summary>
/// Raised when the Rust core caught a panic crossing the FFI boundary (the
/// <c>ffi_guard!</c> macro returns -2 and a synthesized code 9999). Inherited
/// from Phase 16 D-17 panic mapping — there is no Apple enum case because the
/// UniFFI binding surfaces panics differently; on Windows the P/Invoke return
/// code is the only signal, so it gets its own exception type.
///
/// A panic indicates a bug in the Rust core, not a recoverable runtime
/// condition — callers should surface it (with a generic message, never the
/// raw panic payload) rather than retry.
/// </summary>
public sealed class DS3PanicException : Exception
{
    /// <summary>The panic sentinel code (9999).</summary>
    public const int PanicCode = 9999;

    /// <summary>
    /// Creates a panic exception.
    /// </summary>
    /// <param name="message">Optional human-readable detail.</param>
    /// <param name="innerException">Optional wrapped exception.</param>
    public DS3PanicException(string? message = null, Exception? innerException = null)
        : base($"[{PanicCode}] {message ?? "The native core panicked."}", innerException)
    {
    }

    public override string ToString() =>
        $"{nameof(DS3PanicException)}: {Message}";
}
