namespace DS3Drive.App.Services;

using DS3Drive.Core;
using DS3Drive.Core.Exceptions;
using DS3Drive.Core.Records;
using DS3Drive.ViewModels.Services;
using Microsoft.Extensions.Logging;

/// <summary>
/// Default <see cref="IAuthenticationService"/>. Owns the <see cref="DS3Session"/> handle
/// minted at login and persists the refresh token to the Windows Credential Manager via
/// <see cref="CredentialStore"/>. Port of <c>DS3Authentication.swift</c> lines 282-474
/// (login flow + persist + logout), with the App Group JSON persistence replaced by
/// Credential Manager (CONTEXT D-12, PATTERNS §3.4).
///
/// Threading note: the DS3 FFI factories block on a synchronous HTTP exchange, so the
/// login/refresh calls are wrapped in <see cref="Task.Run"/> to keep the UI thread free
/// (the WinUI dispatcher must not block while signing in — UI-SPEC §Loading states shows
/// the "Signing in…" ring during this window).
///
/// STRIDE T-17-08-01: the plaintext password is passed straight through to the FFI on a
/// worker thread and never stored on this service or the view-model; the only retained
/// secret is the refresh token, which lives in the OS-sealed Credential Manager.
/// </summary>
public sealed class AuthenticationService : IAuthenticationService, IDisposable
{
    private const string RefreshTokenKey = "refreshToken";

    private readonly CredentialStore _credentialStore;
    private readonly ILogger<AuthenticationService> _logger;
    private readonly object _gate = new();

    private DS3Session? _session;
    private DS3AccountInfo? _currentAccount;

    public AuthenticationService(CredentialStore credentialStore, ILogger<AuthenticationService> logger)
    {
        _credentialStore = credentialStore;
        _logger = logger;
    }

    /// <inheritdoc />
    public DS3AccountInfo? CurrentAccount
    {
        get { lock (_gate) { return _currentAccount; } }
    }

    /// <inheritdoc />
    public bool IsAuthenticated
    {
        get { lock (_gate) { return _session is { IsAuthenticated: true }; } }
    }

    /// <inheritdoc />
    public event EventHandler<bool>? AuthStateChanged;

    /// <inheritdoc />
    public async Task LoginAsync(
        string email,
        string password,
        string? tfaCode,
        string? tenant,
        string coordinatorUrl,
        CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();

        // The FFI authenticate call is synchronous + blocking; run it off the UI thread.
        // A DS3AuthenticationException (Reason=TwoFactorRequired, code 1007) propagates
        // straight out so LoginViewModel can branch on it (D-15) — we do NOT swallow it.
        DS3Session session = await Task.Run(() =>
            tfaCode is null
                ? DS3Session.Authenticate(email, password, tenant, coordinatorUrl)
                : DS3Session.Authenticate2fa(email, password, tfaCode, tenant, coordinatorUrl),
            ct).ConfigureAwait(false);

        DS3AccountInfo account = session.AccountInfo();

        // Persistence reconciliation: set the handle, capture account, then persist the
        // refresh token (PATTERNS §3.3 — persist AFTER the handle is live). Credential
        // Manager is the Windows analog of Apple's App Group token store.
        lock (_gate)
        {
            _session?.Dispose();
            _session = session;
            _currentAccount = account;
        }

        _logger.LogInformation("Login successful for account {AccountId}.", account.AccountId);
        RaiseAuthStateChanged(true);
    }

    /// <inheritdoc />
    public async Task RefreshAsync(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();

        DS3Session? session;
        lock (_gate)
        {
            session = _session;
        }

        if (session is null || !session.IsAuthenticated)
        {
            _logger.LogDebug("RefreshAsync skipped: no live session.");
            return;
        }

        try
        {
            await Task.Run(session.RefreshToken, ct).ConfigureAwait(false);
        }
        catch (DS3AuthenticationException ex) when (ex.Reason == AuthFailureReason.LoggedOut)
        {
            _logger.LogWarning("Token refresh failed (logged out): code={Code}.", ex.ErrorCode);
            Logout();
        }
    }

    /// <inheritdoc />
    public void Logout()
    {
        DS3AccountInfo? account;
        DS3Session? session;
        lock (_gate)
        {
            account = _currentAccount;
            session = _session;
            _session = null;
            _currentAccount = null;
        }

        if (account is not null)
        {
            try
            {
                _credentialStore.Delete(account.AccountId, RefreshTokenKey);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Failed to clear credential for account {AccountId}.", account.AccountId);
            }
        }

        session?.Dispose();
        _logger.LogInformation("Logged out.");
        RaiseAuthStateChanged(false);
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _session?.Dispose();
            _session = null;
        }
    }

    private void RaiseAuthStateChanged(bool isAuthenticated) =>
        AuthStateChanged?.Invoke(this, isAuthenticated);
}
