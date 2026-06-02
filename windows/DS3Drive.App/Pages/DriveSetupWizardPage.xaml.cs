namespace DS3Drive.App.Pages;

using System;
using System.ComponentModel;
using DS3Drive.App.Services;
using DS3Drive.Core.Records;
using DS3Drive.ViewModels.Services;
using DS3Drive.ViewModels.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

/// <summary>
/// Drive-setup wizard shell. Resolves <see cref="DriveSetupViewModel"/> from DI, drives the
/// inner <see cref="StepFrame"/> from the view-model's <see cref="DriveSetupViewModel.CurrentStep"/>
/// (D-09 order), and maps the bottom-bar buttons to the state-machine commands. On
/// <see cref="DriveSetupViewModel.WizardCompleted"/> / <c>WizardCancelled</c> it navigates the
/// outer Frame back to <see cref="DrivesListPage"/>.
/// </summary>
public sealed partial class DriveSetupWizardPage : Page
{
    private static readonly string[] StepLabels = ["Project", "Bucket", "Prefix", "Confirm"];

    private readonly INavigationService _outerNav;

    public DriveSetupWizardPage()
    {
        ViewModel = App.Host.Services.GetRequiredService<DriveSetupViewModel>();
        _outerNav = App.Host.Services.GetRequiredService<INavigationService>();

        // The wizard creates drives for the signed-in IAM user. The account id is the
        // user scope; the IAM username is composed from account context (Plan 11 enriches it).
        DS3AccountInfo? account = App.Host.Services.GetRequiredService<IAuthenticationService>().CurrentAccount;
        if (account is not null)
        {
            ViewModel.CurrentUser = new DS3IAMUser(account.AccountId, account.AccountId, account.Email);
        }

        InitializeComponent();
        StepIndicator.Steps = StepLabels;

        ViewModel.PropertyChanged += OnViewModelPropertyChanged;
        ViewModel.WizardCompleted += OnWizardFinished;
        ViewModel.WizardCancelled += OnWizardCancelled;
    }

    public DriveSetupViewModel ViewModel { get; }

    /// <summary>Active step as an int (bound to the step indicator's CurrentIndex).</summary>
    public int CurrentStepIndex => (int)ViewModel.CurrentStep;

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        ViewModel.Reset();
        NavigateToStep(ViewModel.CurrentStep);
        UpdateButtons();
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(DriveSetupViewModel.CurrentStep):
                NavigateToStep(ViewModel.CurrentStep);
                UpdateButtons();
                break;

            // The bucket list loads asynchronously after we navigate onto the Bucket step,
            // so the Continue button's enabled state has to be re-evaluated when the list
            // (or its loading/error state) changes — not only on step transitions.
            case nameof(DriveSetupViewModel.Buckets):
            case nameof(DriveSetupViewModel.IsLoadingBuckets):
            case nameof(DriveSetupViewModel.CreationError):
                UpdateButtons();
                break;
        }
    }

    private void NavigateToStep(WizardStep step)
    {
        Type pageType = step switch
        {
            WizardStep.Project => typeof(ProjectSelectionPage),
            WizardStep.Bucket => typeof(BucketSelectionPage),
            WizardStep.Prefix => typeof(PrefixSelectionPage),
            WizardStep.Confirm => typeof(DriveConfirmPage),
            _ => typeof(ProjectSelectionPage),
        };

        StepFrame.Navigate(pageType, ViewModel);
        // Notify the indicator binding.
        Bindings.Update();
    }

    private void UpdateButtons()
    {
        bool isConfirm = ViewModel.CurrentStep == WizardStep.Confirm;
        PrimaryButton.Content = isConfirm ? "Create drive" : "Continue";
        BackButton.Visibility = ViewModel.CurrentStep == WizardStep.Project
            ? Visibility.Collapsed
            : Visibility.Visible;

        // On the Bucket step there's nothing to continue to until at least one bucket is
        // listed (an empty/failed load must not let the user advance with no selection).
        PrimaryButton.IsEnabled = ViewModel.CurrentStep switch
        {
            WizardStep.Bucket => ViewModel.Buckets.Count > 0 && !ViewModel.IsLoadingBuckets,
            _ => true,
        };
    }

    private void Back_Click(object sender, RoutedEventArgs e) => ViewModel.GoBackCommand.Execute(null);

    private void Cancel_Click(object sender, RoutedEventArgs e) => ViewModel.CancelCommand.Execute(null);

    private async void Primary_Click(object sender, RoutedEventArgs e)
    {
        switch (ViewModel.CurrentStep)
        {
            case WizardStep.Prefix:
                // Commit the tree selection (or root) and advance to Confirm.
                if (StepFrame.Content is PrefixSelectionPage prefixPage)
                {
                    prefixPage.CommitSelection();
                }
                else
                {
                    ViewModel.SelectPrefixCommand.Execute(null);
                }

                break;

            case WizardStep.Confirm:
                await ViewModel.CreateDriveCommand.ExecuteAsync(null);
                break;

            // Project / Bucket advance via list selection (SelectProject / SelectBucket);
            // Continue here is a no-op until a row is chosen.
            default:
                break;
        }
    }

    private void OnWizardFinished(object? sender, DS3Drive e) => ReturnToDrivesList();

    private void OnWizardCancelled(object? sender, EventArgs e) => ReturnToDrivesList();

    private void ReturnToDrivesList()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            ViewModel.PropertyChanged -= OnViewModelPropertyChanged;
            ViewModel.WizardCompleted -= OnWizardFinished;
            ViewModel.WizardCancelled -= OnWizardCancelled;
            _outerNav.Navigate(typeof(DrivesListPage));
        });
    }
}
