namespace DS3Drive.App.Pages;

using DS3Drive.ViewModels.ViewModels;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

/// <summary>
/// Wizard step 4 (Confirm). Shows the selection summary + editable drive name; the
/// "Create drive" CTA on the wizard bottom bar runs
/// <see cref="DriveSetupViewModel.CreateDriveAsync"/>. The shared view-model is the
/// navigation parameter.
/// </summary>
public sealed partial class DriveConfirmPage : Page
{
    public DriveConfirmPage() => InitializeComponent();

    public DriveSetupViewModel? ViewModel { get; private set; }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is DriveSetupViewModel vm)
        {
            ViewModel = vm;
            ProjectValue.Text = vm.SelectedProject?.Name ?? string.Empty;
            BucketValue.Text = vm.SelectedBucket?.Name ?? string.Empty;
            PrefixValue.Text = string.IsNullOrEmpty(vm.SelectedPrefix) ? "Root" : vm.SelectedPrefix!;
        }
    }
}
