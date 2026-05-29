namespace DS3Drive.App;

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

/// <summary>
/// The single top-level window. Exposes its content <see cref="Frame"/> so
/// <see cref="Services.INavigationService"/> can drive page navigation without a
/// reference to the visual tree, and customises the title bar to extend into the
/// client area for the Cubbit branding (Fluent v2 idiom). Greenfield — macOS uses
/// SwiftUI <c>WindowGroup</c> scenes with no MainWindow analog (PATTERNS §2.19).
/// </summary>
public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();

        // Extend content into the title bar and use our custom drag region so the
        // Mica backdrop runs edge-to-edge behind the caption buttons.
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
    }

    /// <summary>
    /// The content host that <see cref="Services.INavigationService"/> initialises and
    /// drives. The XAML compiler generates the backing field from
    /// <c>x:Name="ContentFrame"</c>; this property surfaces it with documentation.
    /// </summary>
    public Frame NavigationFrame => ContentFrame;

    /// <summary>Brings this window to the foreground (second-instance activation, D-27).</summary>
    public void BringToForeground()
    {
        // Activate raises the window; on a minimised window this restores it.
        this.Activate();
    }
}
