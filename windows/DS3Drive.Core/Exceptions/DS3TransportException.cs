namespace DS3Drive.Core.Exceptions;

/// <summary>
/// Raised for wrapped transport-domain failures (DS3Error codes 3001-3099:
/// IoError 3001, HttpError 3002, S3Error 3003, AuthError 3004 — see
/// core/ds3-models/src/error.rs lines 112-115). These are the "transport branch"
/// of Apple's <c>DS3S3Error</c> translation
/// (apple/DS3Lib/Sources/DS3Lib/DS3S3Error.swift lines 186-201).
///
/// The numeric code is preserved so retry/back-off logic can distinguish a
/// transient HTTP fault from a hard I/O failure.
/// </summary>
public sealed class DS3TransportException : Exception
{
    /// <summary>The originating numeric DS3Error code (expected range 3001-3099).</summary>
    public int ErrorCode { get; }

    /// <summary>
    /// Creates a transport exception.
    /// </summary>
    /// <param name="errorCode">The originating DS3Error numeric code.</param>
    /// <param name="message">Optional human-readable detail.</param>
    /// <param name="innerException">Optional wrapped exception.</param>
    public DS3TransportException(int errorCode, string? message = null, Exception? innerException = null)
        : base($"[{errorCode}] {message ?? "Transport error."}", innerException)
    {
        ErrorCode = errorCode;
    }

    public override string ToString() =>
        $"{nameof(DS3TransportException)}(Code={ErrorCode}): {Message}";
}
