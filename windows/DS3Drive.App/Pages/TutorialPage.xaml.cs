namespace DS3Drive.App.Pages;

using DS3Drive.ViewModels.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;

/// <summary>
/// Code-behind for the first-launch tutorial. Resolves <see cref="TutorialViewModel"/>
/// from DI; the view-model owns slide advancement, the login-item consent toggle, and the
/// HKCU Run-key write on finish (CONTEXT D-26).
/// </summary>
public sealed partial class TutorialPage : Page
{
    public TutorialPage()
    {
        ViewModel = App.Host.Services.GetRequiredService<TutorialViewModel>();
        InitializeComponent();
    }

    public TutorialViewModel ViewModel { get; }

    /// <summary>1-based slide position for the progress bar (slide N of M).</summary>
    public double SlideProgress(int currentSlideIndex) => currentSlideIndex + 1;
}
