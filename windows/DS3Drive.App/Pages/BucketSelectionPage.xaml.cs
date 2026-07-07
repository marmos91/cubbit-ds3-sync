namespace DS3Drive.App.Pages;

using DS3Drive.Core.Records;
using DS3Drive.ViewModels.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

/// <summary>
/// Wizard step 2 (Bucket). The shared <see cref="DriveSetupViewModel"/> arrives as the
/// navigation parameter; buckets are loaded by SelectProject on the previous step, so this
/// page only renders + forwards selection to SelectBucket.
/// </summary>
public sealed partial class BucketSelectionPage : Page
{
    public BucketSelectionPage() => InitializeComponent();

    public DriveSetupViewModel? ViewModel { get; private set; }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is DriveSetupViewModel vm)
        {
            ViewModel = vm;
        }
    }

    /// <summary>Shows the IAM-user picker when the project exposes at least one IAM user
    /// (macOS lists them so the user can switch the browse identity).</summary>
    public Visibility UserPickerVisibility(int userCount) =>
        userCount > 0 ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>Empty-state predicate: no buckets, not currently loading, AND no load error
    /// (a failed load surfaces the error InfoBar instead — never the "create a bucket" empty
    /// state, which would mask the failure as an empty project).</summary>
    public Visibility HasNoBuckets(int count, bool isLoading, string? error) =>
        count == 0 && !isLoading && string.IsNullOrEmpty(error) ? Visibility.Visible : Visibility.Collapsed;

    private void BucketsList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ViewModel is not null && BucketsList.SelectedItem is DS3Bucket bucket)
        {
            ViewModel.SelectBucketCommand.Execute(bucket);
        }
    }
}
