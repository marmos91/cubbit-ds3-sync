namespace DS3Drive.App.Services;

using System.Text.Json;
using DS3Drive.Core;
using DS3Drive.Core.Exceptions;
using DS3Drive.Core.Records;
using DS3Drive.ViewModels.Services;
using Microsoft.Extensions.Logging;

// Plan 09: AuthenticationService also adapts the live session onto IDS3SessionGateway
// (it is the single owner of the DS3Session handle, so it is the natural adapter). The SDK
// service borrows the session (projects + IAM/API-key calls) through this seam — no second
// handle, no widened interface. The S3 surface (bucket/object listing) no longer routes
// through the session: 17.1-02 moved it onto DS3DriveS3Client, and 17.1-03 builds that
// per-drive client from the reconciled API key (the cfapi sync IDS3SessionAccess is now the
// host-built DriveS3SessionAccess, not this singleton).

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
public sealed class AuthenticationService : IAuthenticationService, IDS3SessionGateway, IDisposable
{
    private const string RefreshTokenKey = "refreshToken";

    // Stay-logged-in store: a single JSON blob (refresh token + coordinator URL + account id) under
    // a fixed, account-agnostic key, so startup can find and restore it without knowing the account
    // id up front. This is the Windows half of the cross-platform persistence model (the logic lives
    // in the shared Rust core; only the secure-storage backend is platform-specific — Credential
    // Manager here, Keychain/App Group on Apple, Keystore on Android).
    private const string SessionStoreAccount = "__session__";
    private const string SessionStoreKey = "session-v1";

    private readonly CredentialStore _credentialStore;
    private readonly ILogger<AuthenticationService> _logger;
    private readonly object _gate = new();

    private DS3Session? _session;
    private DS3AccountInfo? _currentAccount;
    private string? _coordinatorUrl;

    /// <summary>The persisted session blob. The refresh token rotates on every refresh/forge, so it
    /// is re-saved after each of those operations; a stale token simply fails restore → login.</summary>
    private sealed record PersistedSession(string RefreshToken, string CoordinatorUrl, string AccountId);

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
            _coordinatorUrl = coordinatorUrl;
        }

        _logger.LogInformation("Login successful for account {AccountId}.", account.AccountId);

        // Persist the refresh token so the next launch restores the session (stay logged in).
        PersistSession();
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
            // The refresh token rotated — re-persist so the saved copy never goes stale.
            PersistSession();
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
            _coordinatorUrl = null;
        }

        // Clear the stay-logged-in blob so the next launch lands on Login (T-17-11-04 EoP).
        try
        {
            _credentialStore.Delete(SessionStoreAccount, SessionStoreKey);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to clear persisted session on logout.");
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

    /// <summary>
    /// True if a persisted session blob exists (a fast local Credential Manager read — no network).
    /// The App uses this to decide whether to start hidden in the tray (returning user) or show the
    /// Login window (fresh user) before the actual <see cref="TryRestoreSession"/> network call runs.
    /// </summary>
    public bool HasPersistedSession
    {
        get
        {
            try
            {
                return !string.IsNullOrEmpty(_credentialStore.Load(SessionStoreAccount, SessionStoreKey));
            }
            catch
            {
                return false;
            }
        }
    }

    /// <summary>
    /// Attempts to restore a session from the persisted refresh token (stay logged in across
    /// launches). On success the session is live, <see cref="AuthStateChanged"/>(true) fires, and
    /// the rotated token is re-saved; returns true. A missing/revoked/expired token (or an offline
    /// coordinator) returns false and clears the stale blob so the caller routes to Login. Network
    /// I/O runs inline, so call this off the UI thread.
    /// </summary>
    public bool TryRestoreSession()
    {
        string? json;
        try
        {
            json = _credentialStore.Load(SessionStoreAccount, SessionStoreKey);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to read persisted session.");
            return false;
        }

        if (string.IsNullOrEmpty(json))
        {
            return false;
        }

        PersistedSession? persisted;
        try
        {
            persisted = JsonSerializer.Deserialize<PersistedSession>(json);
        }
        catch (JsonException)
        {
            persisted = null;
        }

        if (persisted is null || string.IsNullOrEmpty(persisted.RefreshToken))
        {
            // Corrupt/unparseable blob — clear it so we don't re-attempt restore on every launch.
            _logger.LogWarning("Persisted session blob is invalid; clearing it.");
            ClearPersistedSession();
            return false;
        }

        try
        {
            DS3Session session = DS3Session.RestoreFromRefreshToken(persisted.RefreshToken, persisted.CoordinatorUrl);
            DS3AccountInfo account = session.AccountInfo();

            lock (_gate)
            {
                _session?.Dispose();
                _session = session;
                _currentAccount = account;
                _coordinatorUrl = persisted.CoordinatorUrl;
            }

            _logger.LogInformation("Session restored for account {AccountId}.", account.AccountId);

            // The refresh token rotated during restore — save the fresh one.
            PersistSession();
            RaiseAuthStateChanged(true);
            return true;
        }
        catch (Exception ex)
        {
            _logger.LogInformation(ex, "Persisted session could not be restored; clearing it.");
            ClearPersistedSession();
            return false;
        }
    }

    /// <summary>
    /// Best-effort removal of the persisted session blob. Failures are logged and swallowed so
    /// they never break the restore-or-route-to-login flow.
    /// </summary>
    private void ClearPersistedSession()
    {
        try
        {
            _credentialStore.Delete(SessionStoreAccount, SessionStoreKey);
        }
        catch (Exception delEx)
        {
            _logger.LogWarning(delEx, "Failed to clear unrestorable session blob.");
        }
    }

    /// <summary>
    /// Saves the current session's (rotating) refresh token, coordinator URL, and account id to the
    /// secure store. Best-effort: a persistence failure logs and is swallowed so it never breaks
    /// login/refresh/forge. Called after every token-rotating operation.
    /// </summary>
    private void PersistSession()
    {
        DS3Session? session;
        DS3AccountInfo? account;
        string? coordinator;
        lock (_gate)
        {
            session = _session;
            account = _currentAccount;
            coordinator = _coordinatorUrl;
        }

        if (session is null || account is null || string.IsNullOrEmpty(coordinator))
        {
            return;
        }

        try
        {
            string refresh = session.CurrentRefreshToken();
            string json = JsonSerializer.Serialize(new PersistedSession(refresh, coordinator, account.AccountId));
            _credentialStore.Save(SessionStoreAccount, SessionStoreKey, json);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to persist session for stay-logged-in.");
        }
    }

    // === IDS3SessionGateway (Plan 09): adapts the live session for the SDK service ===

    private DS3Session EnsureSession()
    {
        lock (_gate)
        {
            if (_session is { IsAuthenticated: true } s)
            {
                return s;
            }
        }

        throw new DS3AuthenticationException(AuthFailureReason.LoggedOut, errorCode: 1005);
    }

    /// <inheritdoc />
    string IDS3SessionGateway.AccountId => CurrentAccount?.AccountId ?? string.Empty;

    /// <inheritdoc />
    string IDS3SessionGateway.EndpointGateway => CurrentAccount?.EndpointGateway ?? string.Empty;

    /// <inheritdoc />
    IReadOnlyList<DS3Project> IDS3SessionGateway.GetProjects() => EnsureSession().GetProjects();

    /// <inheritdoc />
    string IDS3SessionGateway.ForgeIamToken(string iamUserId)
    {
        string token = EnsureSession().ForgeIamToken(iamUserId);
        // The refresh token rotates on forge — re-persist so a saved token never goes stale.
        PersistSession();
        return token;
    }

    /// <inheritdoc />
    IReadOnlyList<DS3ApiKey> IDS3SessionGateway.LoadApiKeys(string iamUserId, string iamToken) =>
        EnsureSession().LoadApiKeys(iamUserId, iamToken);

    /// <inheritdoc />
    DS3ApiKey IDS3SessionGateway.CreateApiKey(string iamUserId, string iamToken, string apiKeyName) =>
        EnsureSession().CreateApiKey(iamUserId, iamToken, apiKeyName);

    /// <inheritdoc />
    void IDS3SessionGateway.DeleteApiKey(string iamUserId, string apiKeyId, string iamToken) =>
        EnsureSession().DeleteApiKey(iamUserId, apiKeyId, iamToken);
}
