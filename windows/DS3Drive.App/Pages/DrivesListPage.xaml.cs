namespace DS3Drive.App.Pages;

using DS3Drive.ViewModels.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

/// <summary>
/// Post-tutorial landing page (Plan 08 TODO resolved). Resolves
/// <see cref="DrivesListViewModel"/> from DI; the view-model owns the drives collection,
/// the empty-state copy, and the 3-drive-cap-aware "Add drive" CTA (D-23). Add navigation
/// to the wizard is routed by the view-model via PageKey.DriveSetupWizard.
/// </summary>
public sealed partial class DrivesListPage : Page
{
    public DrivesListPage()
    {
        ViewModel = App.Host.Services.GetRequiredService<DrivesListViewModel>();
        InitializeComponent();
    }

    public DrivesListViewModel ViewModel { get; }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        await ViewModel.LoadCommand.ExecuteAsync(null);
    }
}
