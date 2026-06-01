namespace DS3Drive.Core.Exceptions;

/// <summary>
/// Raised for authentication-domain failures (DS3Error codes 1001-1099 and the
/// catch-all default). Port of Apple's <c>DS3AuthenticationError</c> enum
/// (apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift lines 6-88).
///
/// The <see cref="Reason"/> property exposes the categorical failure so callers
/// branch on it the way the macOS LoginViewModel branches on the Swift enum
/// (D-15: <c>Reason == AuthFailureReason.TwoFactorRequired</c> drives the 2FA UI).
/// </summary>
public sealed class DS3AuthenticationException : Exception
{
    /// <summary>The categorical authentication failure.</summary>
    public AuthFailureReason Reason { get; }

    /// <summary>The originating numeric DS3Error code, when produced by the Rust core.</summary>
    public int? ErrorCode { get; }

    /// <summary>
    /// Creates an authentication exception.
    /// </summary>
    /// <param name="reason">The categorical failure (drives UI branching).</param>
    /// <param name="message">Optional human-readable detail. A default is derived from the reason.</param>
    /// <param name="errorCode">Optional originating DS3Error numeric code.</param>
    /// <param name="innerException">Optional wrapped exception.</param>
    public DS3AuthenticationException(
        AuthFailureReason reason,
        string? message = null,
        int? errorCode = null,
        Exception? innerException = null)
        : base(FormatMessage(reason, message, errorCode), innerException)
    {
        Reason = reason;
        ErrorCode = errorCode;
    }

    private static string FormatMessage(AuthFailureReason reason, string? message, int? errorCode)
    {
        string detail = message ?? DefaultDetail(reason);
        return errorCode is { } code
            ? $"[{code}] {detail}"
            : detail;
    }

    private static string DefaultDetail(AuthFailureReason reason) => reason switch
    {
        AuthFailureReason.InvalidUrl => "The provided URL is invalid.",
        AuthFailureReason.ServerError => "There was an error with the server. Please try again later.",
        AuthFailureReason.JsonConversion => "There was an error while converting JSON data.",
        AuthFailureReason.Encoding => "There was an error while encoding/decoding data.",
        AuthFailureReason.LoggedOut => "You need to be logged in to perform this operation.",
        AuthFailureReason.TokenExpired => "The session token expired.",
        AuthFailureReason.TwoFactorRequired => "Two-factor authentication required.",
        AuthFailureReason.Cookies => "Cannot retrieve cookies.",
        AuthFailureReason.AlreadyLoggedIn => "You are already logged in.",
        _ => "Authentication error.",
    };

    public override string ToString() =>
        $"{nameof(DS3AuthenticationException)}(Reason={Reason}, Code={ErrorCode?.ToString() ?? "null"}): {Message}";
}
