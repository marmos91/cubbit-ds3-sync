namespace DS3Drive.App.Pages;

using System;
using System.Threading.Tasks;
using DS3Drive.Core.Records;
using DS3Drive.ViewModels.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

/// <summary>
/// Settings page code-behind. Resolves <see cref="SettingsViewModel"/> from DI, toggles the
/// four section panels from the NavigationView selection, and wires the destructive confirm
/// hooks to ContentDialogs carrying the UI-SPEC §Destructive copy verbatim (Sign out:
/// "Sign out of Cubbit?" / "Stay signed in"; Remove drive: "Remove this drive?"). The Logging
/// section's "Open log folder" surfaces the Phase-18 TeachingTip (P17 placeholder).
/// </summary>
public sealed partial class SettingsPage : Page
{
    public SettingsPage()
    {
        ViewModel = App.Host.Services.GetRequiredService<SettingsViewModel>();
        InitializeComponent();

        ViewModel.ConfirmSignOutAsync = ConfirmSignOutAsync;
        ViewModel.ConfirmRemoveDriveAsync = ConfirmRemoveDriveAsync;
        ViewModel.ShowLogExportPlaceholder = () => LogExportTip.IsOpen = true;
    }

    public SettingsViewModel ViewModel { get; }

    private void OnSectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        string tag = (args.SelectedItem as NavigationViewItem)?.Tag as string ?? "Account";

        AccountSection.Visibility = tag == "Account" ? Visibility.Visible : Visibility.Collapsed;
        CoordinatorSection.Visibility = tag == "Coordinator" ? Visibility.Visible : Visibility.Collapsed;
        DrivesSection.Visibility = tag == "Drives" ? Visibility.Visible : Visibility.Collapsed;
        LoggingSection.Visibility = tag == "Logging" ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnTogglePauseClick(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is DS3Drive drive)
        {
            ViewModel.TogglePauseCommand.Execute(drive);
        }
    }

    private async void OnRemoveDriveClick(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is DS3Drive drive)
        {
            await ViewModel.RemoveDriveCommand.ExecuteAsync(drive);
        }
    }

    /// <summary>UI-SPEC §Destructive — Sign out confirm copy (verbatim).</summary>
    private async Task<bool> ConfirmSignOutAsync()
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Sign out of Cubbit?",
            Content = "Your drives will stop syncing on this PC. You can sign back in any time — no files will be deleted.",
            PrimaryButtonText = "Sign out",
            CloseButtonText = "Stay signed in",
            DefaultButton = ContentDialogButton.Close,
        };

        ContentDialogResult result = await dialog.ShowAsync();
        return result == ContentDialogResult.Primary;
    }

    /// <summary>UI-SPEC §Destructive — Remove drive confirm copy (verbatim).</summary>
    private async Task<bool> ConfirmRemoveDriveAsync(DS3Drive drive)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Remove this drive?",
            Content = $"\"{drive.Name}\" will stop syncing on this PC. Files already in Cubbit DS3 are kept.",
            PrimaryButtonText = "Remove drive",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };

        ContentDialogResult result = await dialog.ShowAsync();
        return result == ContentDialogResult.Primary;
    }
}
