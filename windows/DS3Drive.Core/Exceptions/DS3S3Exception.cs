namespace DS3Drive.Core.Exceptions;

/// <summary>
/// Raised for S3-domain failures (DS3Error codes 2001-2099). Port of Apple's
/// <c>DS3S3Error</c> (apple/DS3Lib/Sources/DS3Lib/DS3S3Error.swift) which the
/// FileProvider extension catches and maps to NSFileProviderError. On Windows
/// the cfapi layer (Plan 06+) maps <see cref="ErrorCode"/> to the corresponding
/// Cloud Filter status.
///
/// The numeric code is preserved (never swallowed) so logs and the sync engine
/// can disambiguate NoSuchKey (2xxx) from transport faults (3xxx).
/// </summary>
public sealed class DS3S3Exception : Exception
{
    /// <summary>The originating numeric DS3Error code (expected range 2001-2099).</summary>
    public int ErrorCode { get; }

    /// <summary>
    /// Creates an S3 exception.
    /// </summary>
    /// <param name="errorCode">The originating DS3Error numeric code.</param>
    /// <param name="message">Optional human-readable detail.</param>
    /// <param name="innerException">Optional wrapped exception.</param>
    public DS3S3Exception(int errorCode, string? message = null, Exception? innerException = null)
        : base($"[{errorCode}] {message ?? "S3 error."}", innerException)
    {
        ErrorCode = errorCode;
    }

    public override string ToString() =>
        $"{nameof(DS3S3Exception)}(Code={ErrorCode}): {Message}";
}
