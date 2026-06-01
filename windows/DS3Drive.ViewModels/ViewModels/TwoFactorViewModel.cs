namespace DS3Drive.ViewModels.ViewModels;

using System.Threading;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DS3Drive.Core.Exceptions;
using DS3Drive.ViewModels.Navigation;
using DS3Drive.ViewModels.Services;
using Microsoft.Extensions.Logging;

/// <summary>
/// Credentials forwarded from the login form to the 2FA page through
/// <c>Frame.Navigate(parameter)</c>. Held only for the duration of the 2FA exchange and
/// cleared immediately after (STRIDE T-17-08-01: the plaintext password is never retained
/// on a long-lived view-model).
/// </summary>
public sealed record TwoFactorContext(string Email, string Password, string? Tenant, string CoordinatorUrl);

/// <summary>
/// 2FA challenge state machine (PATTERNS §2.3 sibling of LoginViewModel). Submits the
/// 6-digit code via <see cref="IAuthenticationService.LoginAsync"/> with the carried
/// email/password; a wrong code surfaces on <see cref="TfaError"/> (D-15), success
/// navigates onward to the tutorial.
/// </summary>
public partial class TwoFactorViewModel : ObservableObject
{
    private readonly IAuthenticationService _auth;
    private readonly INavigator _navigation;
    private readonly ILogger<TwoFactorViewModel> _logger;

    [ObservableProperty] private string? tfaCode;
    [ObservableProperty] private string? tfaError;
    [ObservableProperty] private bool isLoading;

    private TwoFactorContext? _context;

    public TwoFactorViewModel(
        IAuthenticationService auth,
        INavigator navigation,
        ILogger<TwoFactorViewModel> logger)
    {
        _auth = auth;
        _navigation = navigation;
        _logger = logger;
    }

    /// <summary>
    /// Seeds the carried login credentials from the navigation parameter. The page calls
    /// this in <c>OnNavigatedTo</c>; the context is dropped after a successful verify.
    /// </summary>
    public void Initialize(TwoFactorContext context) => _context = context;

    /// <summary>Verifies the entered <see cref="TfaCode"/> (UI-SPEC primary CTA "Verify").</summary>
    [RelayCommand]
    private async Task VerifyAsync(CancellationToken ct)
    {
        if (IsLoading || _context is null || string.IsNullOrWhiteSpace(TfaCode))
        {
            return;
        }

        TfaError = null;
        IsLoading = true;
        try
        {
            await _auth.LoginAsync(
                _context.Email, _context.Password, TfaCode, _context.Tenant, _context.CoordinatorUrl, ct)
                .ConfigureAwait(true);

            // Drop the carried credentials as soon as they are no longer needed.
            _context = null;
            _logger.LogInformation("2FA verification successful.");
            _navigation.Navigate(PageKey.Tutorial);
        }
        catch (Exception ex)
        {
            _logger.LogError("2FA verification failed: {Message}", ex.Message);
            TfaError = ex is DS3TransportException or DS3AuthenticationException { Reason: AuthFailureReason.ServerError }
                ? "Can't reach Cubbit. Check your internet connection and try again."
                : "That code didn't work. Enter the 6-digit code from your authenticator app.";
        }
        finally
        {
            IsLoading = false;
        }
    }
}
