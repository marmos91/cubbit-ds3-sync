namespace DS3Drive.ViewModels.Services;

using DS3Drive.Core.Records;

/// <summary>
/// Authentication facade for the WinUI shell (PATTERNS §1.3 / §2.2). Port of the
/// observable wrapper around the session handle in
/// <c>apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift</c> lines 102-474 — owns the
/// <see cref="DS3Drive.Core.DS3Session"/> lifecycle, exposes a simple authenticated/not
/// flag, and raises <see cref="AuthStateChanged"/> so the tray (Plan 11) can update its
/// status icon. ViewModels depend on this interface, never on <c>DS3Session</c> directly,
/// so they stay unit-testable with a substitute (Test suite uses NSubstitute).
/// </summary>
public interface IAuthenticationService
{
    /// <summary>The account identity captured at login; <c>null</c> while signed out.</summary>
    DS3AccountInfo? CurrentAccount { get; }

    /// <summary>True while a live, authenticated session handle is held.</summary>
    bool IsAuthenticated { get; }

    /// <summary>
    /// Raised whenever the authenticated state flips. The bool payload is the new
    /// <see cref="IsAuthenticated"/> value (true = signed in, false = signed out / lost).
    /// </summary>
    event EventHandler<bool>? AuthStateChanged;

    /// <summary>
    /// Authenticates with email + password, optionally a 2FA code and tenant. Throws
    /// <see cref="DS3Drive.Core.Exceptions.DS3AuthenticationException"/> with
    /// <c>Reason == TwoFactorRequired</c> (code 1007) when a 2FA challenge is needed — the
    /// caller (LoginViewModel) branches on it to show the 2FA UI (D-15, byte-identical to
    /// macOS). Persists the refresh token to the Credential Manager on success.
    /// </summary>
    Task LoginAsync(
        string email,
        string password,
        string? tfaCode,
        string? tenant,
        string coordinatorUrl,
        CancellationToken ct);

    /// <summary>Refreshes the access token; raises <see cref="AuthStateChanged"/>(false) if the session is lost.</summary>
    Task RefreshAsync(CancellationToken ct);

    /// <summary>Clears Credential Manager entries for the current account and disposes the session.</summary>
    void Logout();
}
