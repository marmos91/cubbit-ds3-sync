namespace DS3Drive.App.Pages;

using DS3Drive.Core.Records;
using DS3Drive.ViewModels.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

/// <summary>
/// Wizard step 1 (Project). Hosted in the wizard's inner Frame; the shared
/// <see cref="DriveSetupViewModel"/> is passed as the navigation parameter. Triggers the
/// project load on navigation and forwards row selection to SelectProject.
/// </summary>
public sealed partial class ProjectSelectionPage : Page
{
    public ProjectSelectionPage() => InitializeComponent();

    public DriveSetupViewModel? ViewModel { get; private set; }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is DriveSetupViewModel vm)
        {
            ViewModel = vm;
            // Load projects when the step appears (UI-SPEC "Loading projects…" ring).
            if (vm.Projects.Count == 0)
            {
                await vm.LoadProjectsCommand.ExecuteAsync(null);
            }
        }
    }

    /// <summary>Empty-state predicate: no projects AND not currently loading.</summary>
    public Visibility HasNoProjects(int count, bool isLoading) =>
        count == 0 && !isLoading ? Visibility.Visible : Visibility.Collapsed;

    private void ProjectsList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ViewModel is not null && ProjectsList.SelectedItem is DS3Project project)
        {
            ViewModel.SelectProjectCommand.Execute(project);
        }
    }
}
