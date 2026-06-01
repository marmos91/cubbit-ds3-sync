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

    /// <summary>Empty-state predicate: no buckets AND not currently loading.</summary>
    public Visibility HasNoBuckets(int count, bool isLoading) =>
        count == 0 && !isLoading ? Visibility.Visible : Visibility.Collapsed;

    private void BucketsList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ViewModel is not null && BucketsList.SelectedItem is DS3Bucket bucket)
        {
            ViewModel.SelectBucketCommand.Execute(bucket);
        }
    }
}
