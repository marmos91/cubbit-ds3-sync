namespace DS3Drive.App.Services;

using DS3Drive.ViewModels.Navigation;
using Microsoft.UI.Xaml.Controls;

/// <summary>
/// Frame-based page navigation for the single-window WinUI 3 shell. Implements the
/// WinUI-free <see cref="INavigator"/> (PageKey → Page Type) consumed by view-models, plus
/// the WinUI-typed <see cref="Navigate(System.Type, object?)"/> used by the App layer.
///
/// Greenfield (no macOS analog — macOS uses <c>WindowGroup</c> scenes in
/// apple/DS3Drive/DS3DriveApp.swift; PATTERNS §1.3 / §2.19). The app holds a
/// single <see cref="Frame"/> on the MainWindow; this service drives it so
/// view-models can request navigation without a reference to the visual tree.
/// </summary>
public interface INavigationService : INavigator
{
    /// <summary>Binds the service to the MainWindow's content <see cref="Frame"/>.</summary>
    void Initialize(Frame frame);

    /// <summary>Navigates the frame to <paramref name="pageType"/>, optionally passing a parameter.</summary>
    void Navigate(Type pageType, object? parameter = null);

    /// <summary>Navigates back one entry if the back stack is non-empty.</summary>
    void GoBack();
}
