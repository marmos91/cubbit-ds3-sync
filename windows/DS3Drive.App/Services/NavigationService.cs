namespace DS3Drive.App.Services;

using DS3Drive.App.Pages;
using DS3Drive.ViewModels.Navigation;
using Microsoft.Extensions.Logging;
using Microsoft.UI.Xaml.Controls;

/// <summary>
/// Default <see cref="INavigationService"/> over a single MainWindow
/// <see cref="Frame"/>. Greenfield (PATTERNS §2.19) — WinUI 3 <c>Frame</c>
/// navigation; macOS uses scenes and has no analog.
/// </summary>
public sealed class NavigationService : INavigationService
{
    private readonly ILogger<NavigationService> _logger;
    private Frame? _frame;

    public NavigationService(ILogger<NavigationService> logger) => _logger = logger;

    /// <inheritdoc />
    public void Initialize(Frame frame)
    {
        _frame = frame ?? throw new ArgumentNullException(nameof(frame));
    }

    /// <inheritdoc />
    public void Navigate(Type pageType, object? parameter = null)
    {
        if (_frame is null)
        {
            _logger.LogError("Navigate called before Initialize; pageType={PageType}", pageType.Name);
            throw new InvalidOperationException("NavigationService.Initialize must be called before Navigate.");
        }

        _logger.LogInformation("Navigating to {PageType}", pageType.Name);
        _frame.Navigate(pageType, parameter);
    }

    /// <inheritdoc />
    public void GoBack()
    {
        if (_frame is { CanGoBack: true })
        {
            _frame.GoBack();
        }
    }

    /// <inheritdoc />
    public void Navigate(PageKey key, object? parameter = null) => Navigate(MapKey(key), parameter);

    /// <summary>Maps a WinUI-free <see cref="PageKey"/> to the concrete Page Type.</summary>
    private static Type MapKey(PageKey key) => key switch
    {
        PageKey.Login => typeof(LoginPage),
        PageKey.TwoFactor => typeof(TwoFactorPage),
        PageKey.Tutorial => typeof(TutorialPage),
        // Plan 09 wires DrivesListPage; fall back to the tutorial until then.
        PageKey.DrivesList => typeof(TutorialPage),
        _ => typeof(LoginPage),
    };
}
