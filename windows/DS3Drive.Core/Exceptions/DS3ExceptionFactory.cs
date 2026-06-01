namespace DS3Drive.Core.Exceptions;
using Microsoft.Extensions.Logging;

/// <summary>
/// Maps a numeric DS3Error code (returned by the Rust core via the C ABI's
/// <c>out_error</c> out-parameter) to the corresponding typed C# exception.
///
/// Direct port of the load-bearing switch in
/// apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift lines 56-88 (the
/// <c>translate(_:)</c> function). The 1007 → TwoFactorRequired arm is
/// load-bearing per Phase 16 D-15: the Login UI branches on
/// <c>AuthFailureReason.TwoFactorRequired</c> to show the 2FA prompt; any other
/// mapping silently bypasses the 2FA flow (an auth bypass).
///
/// Code ranges (core/ds3-models/src/error.rs lines 90-118):
///   1001-1008  auth      → DS3AuthenticationException(reason)
///   2001-2099  S3        → DS3S3Exception(code)
///   3001-3099  transport → DS3TransportException(code)
///   9999       panic     → DS3PanicException
///   default              → DS3AuthenticationException(ServerError)  (never swallowed; logged)
/// </summary>
internal static class DS3ExceptionFactory
{
    /// <summary>
    /// Optional logger wired by the App layer at startup. Used only to surface
    /// unknown codes (threat T-17-05-03: logs the numeric code via a named
    /// placeholder, never the raw message which may contain a token).
    /// </summary>
    internal static ILogger? Logger { get; set; }

    /// <summary>
    /// Translates a DS3Error numeric code into the matching typed exception.
    /// </summary>
    /// <param name="errorCode">The numeric DS3Error code from the Rust core.</param>
    /// <param name="message">Optional Display message accompanying the error.</param>
    /// <returns>A typed exception; never null.</returns>
    public static Exception From(int errorCode, string? message = null) => errorCode switch
    {
        1001 => new DS3AuthenticationException(AuthFailureReason.InvalidUrl, message, errorCode),
        1002 => new DS3AuthenticationException(AuthFailureReason.ServerError, message, errorCode),
        1003 => new DS3AuthenticationException(AuthFailureReason.JsonConversion, message, errorCode),
        1004 => new DS3AuthenticationException(AuthFailureReason.Encoding, message, errorCode),
        1005 => new DS3AuthenticationException(AuthFailureReason.LoggedOut, message, errorCode),
        1006 => new DS3AuthenticationException(AuthFailureReason.TokenExpired, message, errorCode),
        1007 => new DS3AuthenticationException(AuthFailureReason.TwoFactorRequired, message, errorCode), // load-bearing per D-15 (DS3Authentication.swift:73)
        1008 => new DS3AuthenticationException(AuthFailureReason.Cookies, message, errorCode),
        >= 2001 and <= 2099 => new DS3S3Exception(errorCode, message),
        >= 3001 and <= 3099 => new DS3TransportException(errorCode, message),
        9999 => new DS3PanicException(message),
        _ => UnknownCode(errorCode, message),
    };

    private static Exception UnknownCode(int errorCode, string? message)
    {
        // Never silently swallow an unknown code: log it (code only — T-17-05-03)
        // and fall back to the same default Apple uses (DS3Authentication.swift:75).
        Logger?.LogError("DS3 error: unknown code={Code}", errorCode);
        return new DS3AuthenticationException(AuthFailureReason.ServerError, message, errorCode);
    }
}
