namespace DS3Drive.Core.Exceptions;

/// <summary>
/// Authentication failure categories, mirroring Apple's <c>DS3AuthenticationError</c>
/// enum cases (apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift lines 6-54).
///
/// The numeric DS3Error codes that drive these come from the Rust core
/// (core/ds3-models/src/error.rs lines 90-118). The <c>TwoFactorRequired</c>
/// case is load-bearing per Phase 16 D-15: the Login flow detects it to prompt
/// for a 2FA code; any other mapping silently bypasses the 2FA UI (auth bypass).
/// </summary>
public enum AuthFailureReason
{
    /// <summary>The provided coordinator/IAM URL is malformed (DS3Error 1001).</summary>
    InvalidUrl,

    /// <summary>The server returned an unexpected status (DS3Error 1002).</summary>
    ServerError,

    /// <summary>JSON serialization/deserialization failed (DS3Error 1003).</summary>
    JsonConversion,

    /// <summary>String encoding/decoding failed (DS3Error 1004).</summary>
    Encoding,

    /// <summary>The user is not logged in (DS3Error 1005).</summary>
    LoggedOut,

    /// <summary>The access token has expired (DS3Error 1006).</summary>
    TokenExpired,

    /// <summary>
    /// A two-factor authentication code is required (DS3Error 1007).
    /// Load-bearing: the Login UI branches on this to show the 2FA prompt (D-15).
    /// </summary>
    TwoFactorRequired,

    /// <summary>Cookie extraction or parsing failed (DS3Error 1008).</summary>
    Cookies,

    /// <summary>
    /// The caller attempted to log in while already authenticated.
    /// Mirrors Apple's <c>.alreadyLoggedIn</c>; raised by the facade, not the Rust core.
    /// </summary>
    AlreadyLoggedIn,
}
