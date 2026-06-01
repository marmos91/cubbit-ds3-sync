namespace DS3Drive.ViewModels.ViewModels;

using System.Threading;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DS3Drive.Core;
using DS3Drive.Core.Exceptions;
using DS3Drive.ViewModels.Navigation;
using DS3Drive.ViewModels.Services;
using Microsoft.Extensions.Logging;

/// <summary>
/// Login form state machine. Byte-identical port of
/// <c>apple/DS3Drive/Views/Login/ViewModels/LoginViewModel.swift</c> lines 1-74
/// (PATTERNS §2.3) — the <c>isTfaAttempt</c> error-routing guard is load-bearing per
/// D-15: 2FA-verification errors MUST surface on the 2FA UI (TfaError), first-attempt
/// errors on the login form (LoginError), and a TwoFactorRequired (code 1007) result
/// MUST set <see cref="Need2FA"/> rather than show an error. Reordering or dropping the
/// guard silently regresses the 2FA flow.
/// </summary>
public partial class LoginViewModel : ObservableObject
{
    private readonly IAuthenticationService _auth;
    private readonly INavigator _navigation;
    private readonly ConfigStore _config;
    private readonly ILogger<LoginViewModel> _logger;

    [ObservableProperty] private string email = string.Empty;
    [ObservableProperty] private string password = string.Empty;
    [ObservableProperty] private string? tenant;
    [ObservableProperty] private string coordinatorUrl;
    [ObservableProperty] private bool rememberMe = true;
    [ObservableProperty] private string? loginError;
    [ObservableProperty] private bool need2FA;
    [ObservableProperty] private string? tfaCode;
    [ObservableProperty] private string? tfaError;
    [ObservableProperty] private bool isLoading;

    public LoginViewModel(
        IAuthenticationService auth,
        INavigator navigation,
        ConfigStore config,
        ILogger<LoginViewModel> logger)
    {
        _auth = auth;
        _navigation = navigation;
        _config = config;
        _logger = logger;

        // CoordinatorUrl defaults to the configured Cubbit coordinator (D-13 / behavior #8).
        coordinatorUrl = config.DefaultCoordinatorUrl;
    }

    /// <summary>Primary submit (email + password, no 2FA code).</summary>
    [RelayCommand]
    private Task LoginAsync(CancellationToken ct) => AuthenticateAsync(ct);

    /// <summary>2FA verification submit (carries the entered <see cref="TfaCode"/>).</summary>
    [RelayCommand]
    private Task VerifyTfaAsync(CancellationToken ct) => AuthenticateAsync(ct);

    /// <summary>
    /// Shared authenticate path — port of LoginViewModel.swift login() (lines 22-73).
    /// Whether this is a 2FA attempt is decided solely by <see cref="TfaCode"/> being
    /// non-null (PATTERNS §2.3 load-bearing): isTfaAttempt = TfaCode is not null.
    /// </summary>
    private async Task AuthenticateAsync(CancellationToken ct)
    {
        // Guard: while a request is in flight, ignore re-entrant submits (Test 7,
        // STRIDE T-17-08-05 double-submit guard).
        if (IsLoading)
        {
            return;
        }

        // D-15 / PATTERNS §2.3 — clear the stale error for THIS attempt's surface.
        // DO NOT reorder: the routing below mirrors this exact branch.
        var isTfaAttempt = TfaCode is not null;
        if (isTfaAttempt)
        {
            TfaError = null;
        }
        else
        {
            LoginError = null;
        }

        IsLoading = true;
        try
        {
            _logger.LogInformation("Logging in to Cubbit DS3 (tfaAttempt={IsTfa}).", isTfaAttempt);
            await _auth.LoginAsync(Email, Password, TfaCode, Tenant, CoordinatorUrl, ct).ConfigureAwait(true);

            _logger.LogInformation("Login successful.");

            // Success → first launch shows the tutorial; Plan 09 swaps in DrivesList.
            _navigation.Navigate(PageKey.Tutorial);
        }
        catch (DS3AuthenticationException ex) when (ex.Reason == AuthFailureReason.TwoFactorRequired)
        {
            // D-15: route to the 2FA UI, NOT an error banner.
            _logger.LogInformation("2FA is required.");
            Need2FA = true;
        }
        catch (Exception ex)
        {
            _logger.LogError("Login failed: {Message}", ex.Message);
            // Route per the same isTfaAttempt branch decided above.
            if (isTfaAttempt)
            {
                TfaError = MapErrorCopy(ex, isTfaAttempt: true);
            }
            else
            {
                LoginError = MapErrorCopy(ex, isTfaAttempt: false);
            }
        }
        finally
        {
            IsLoading = false;
        }
    }

    /// <summary>
    /// Maps an exception to user-facing copy from UI-SPEC §"Error states" (verbatim).
    /// Never embeds raw server/exception text into a user-facing string
    /// (STRIDE T-17-08-04: no server-response leakage). Network/URL failures share copy
    /// across both surfaces; a plain auth failure during a 2FA attempt is a wrong code,
    /// during a first attempt is wrong credentials.
    /// </summary>
    private static string MapErrorCopy(Exception ex, bool isTfaAttempt) => ex switch
    {
        DS3AuthenticationException { Reason: AuthFailureReason.ServerError } =>
            "Can't reach Cubbit. Check your internet connection and try again.",
        DS3AuthenticationException { Reason: AuthFailureReason.InvalidUrl } =>
            "Coordinator URL is invalid. Use a URL like https://api.eu00wi.cubbit.services.",
        DS3TransportException =>
            "Can't reach Cubbit. Check your internet connection and try again.",
        _ when isTfaAttempt =>
            // Wrong 2FA code (UI-SPEC §Error states, 2FA wrong code).
            "That code didn't work. Enter the 6-digit code from your authenticator app.",
        _ =>
            // Wrong credentials / generic auth failure on the first attempt.
            "Sign-in failed. Check your email and password, then try again.",
    };
}
