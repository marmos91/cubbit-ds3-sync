namespace DS3Drive.ViewModels.ViewModels;

using System.Collections.Generic;
using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DS3Drive.ViewModels.Navigation;
using Microsoft.Extensions.Logging;
using Microsoft.Win32;

/// <summary>
/// One tutorial slide. Port of the macOS <c>Slide</c> struct
/// (apple/DS3Drive/Views/Tutorial/ViewModels/TutorialViewModel.swift). <paramref name="ImageName"/>
/// is a logical asset name (Assets/Tutorial/&lt;name&gt;.png); the login-item slide carries a null
/// image and renders the "Open at login" toggle instead.
/// </summary>
public sealed record TutorialSlide(string Id, string? ImageName, string Title, string Description);

/// <summary>
/// First-launch tutorial state machine. Port of
/// <c>apple/DS3Drive/Views/Tutorial/ViewModels/TutorialViewModel.swift</c> +
/// <c>TutorialView.swift</c> lines 149-162 (PATTERNS §2.16). Copy is reused verbatim from the
/// macOS <c>Localizable.xcstrings</c> tutorial keys (English-only, parity with macOS deferred
/// localization). The login-item consent gate writes the HKCU Run key only on explicit opt-in
/// (CONTEXT D-26), mirroring Apple's <c>applyLoginItemPreference</c> consent discipline.
/// </summary>
public partial class TutorialViewModel : ObservableObject
{
    /// <summary>Id of the trailing consent slide that renders the "Open at login" toggle.</summary>
    public const string LoginItemSlideId = "slide-login-item";

    // HKCU Run key + value name (CONTEXT D-26). The WiX uninstaller (Plan 12) removes this;
    // documented here so the analog of Apple's setLoginItem is discoverable.
    // See PATTERNS §2.16 applyLoginItemPreference.
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValueName = "Cubbit DS3 Drive";

    private readonly INavigator _navigation;
    private readonly ILogger<TutorialViewModel> _logger;

    [ObservableProperty] private int currentSlideIndex;
    [ObservableProperty] private bool startAtLoginEnabled = true;

    public TutorialViewModel(INavigator navigation, ILogger<TutorialViewModel> logger)
    {
        _navigation = navigation;
        _logger = logger;
        Slides = new ReadOnlyCollection<TutorialSlide>(DefaultSlides());
    }

    /// <summary>The ordered slide deck (feature slides + the trailing login-item consent slide).</summary>
    public IReadOnlyList<TutorialSlide> Slides { get; }

    /// <summary>The slide currently shown (drives the page's title/description/image bindings).</summary>
    public TutorialSlide CurrentSlide => Slides[CurrentSlideIndex];

    /// <summary>True when the current slide is the last one (CTA reads "Get started").</summary>
    public bool IsLastSlide => CurrentSlideIndex == Slides.Count - 1;

    /// <summary>True when the current slide is the login-item consent slide (renders the toggle).</summary>
    public bool IsLoginItemSlide => Slides[CurrentSlideIndex].Id == LoginItemSlideId;

    /// <summary>Primary CTA caption: "Get started" on the last slide, else "Next" (UI-SPEC).</summary>
    public string PrimaryCtaLabel => IsLastSlide ? "Get started" : "Next";

    partial void OnCurrentSlideIndexChanged(int value)
    {
        OnPropertyChanged(nameof(CurrentSlide));
        OnPropertyChanged(nameof(IsLastSlide));
        OnPropertyChanged(nameof(IsLoginItemSlide));
        OnPropertyChanged(nameof(PrimaryCtaLabel));
    }

    /// <summary>Advances to the next slide, or finishes the tutorial on the last slide.</summary>
    [RelayCommand]
    private void Next()
    {
        if (!IsLastSlide)
        {
            CurrentSlideIndex++;
            return;
        }

        Finish();
    }

    /// <summary>Skips the remaining slides and finishes the tutorial.</summary>
    [RelayCommand]
    private void Skip() => Finish();

    private void Finish()
    {
        ApplyLoginItemPreference();

        // TODO(Plan 09): mark tutorial_shown in the SQLite ConfigStore and navigate to
        // DrivesListPage / DriveSetupWizardPage. For now the tutorial is the end of the
        // wired flow in this plan.
        _logger.LogInformation("Tutorial completed (startAtLogin={StartAtLogin}).", StartAtLoginEnabled);
    }

    /// <summary>
    /// Writes (or removes) the HKCU Run key per the user's opt-in (CONTEXT D-26). Analog of
    /// Apple's <c>applyLoginItemPreference</c> (TutorialView.swift lines 154-162): the registry
    /// write happens ONLY here, on explicit consent — never silently at startup.
    /// </summary>
    private void ApplyLoginItemPreference()
    {
        try
        {
            using RegistryKey? runKey = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
            if (runKey is null)
            {
                _logger.LogWarning("HKCU Run key not found; skipping start-at-login preference.");
                return;
            }

            if (StartAtLoginEnabled)
            {
                string exePath = Environment.ProcessPath ?? string.Empty;
                if (!string.IsNullOrEmpty(exePath))
                {
                    runKey.SetValue(RunValueName, $"\"{exePath}\"");
                }
            }
            else
            {
                runKey.DeleteValue(RunValueName, throwOnMissingValue: false);
            }
        }
        catch (Exception ex)
        {
            // Non-fatal: a failed login-item write must not block finishing the tutorial.
            _logger.LogWarning(ex, "Failed to apply start-at-login preference.");
        }
    }

    /// <summary>
    /// Slide copy reused verbatim from the macOS tutorial strings (Localizable.xcstrings keys
    /// tutorial.slide1/2/3/5/7 + tutorial.loginItem). Five feature slides + one consent slide.
    /// </summary>
    private static List<TutorialSlide> DefaultSlides() =>
    [
        new("slide-1", "tutorial-slide-1",
            "See sync status right in Explorer",
            "Every file in your DS3 drive shows a badge — synced, syncing, error, or cloud-only — so you always know what's safe in the cloud."),
        new("slide-2", "tutorial-slide-2",
            "Control everything from the system tray",
            "Click the Cubbit icon to open the tray. Each drive shows up as a card with its sync state, recent activity, and quick actions."),
        new("slide-3", "tutorial-slide-3",
            "Watch your transfers in real time",
            "Live upload and download speeds appear at the top of the tray, so you know exactly how fast your files are moving."),
        new("slide-5", "tutorial-slide-5",
            "Tune Cubbit DS3 Drive to your taste",
            "Start at login, toggle notifications, manage updates, and customize everything from a single Settings window."),
        new("slide-7", "tutorial-slide-7",
            "Name it and start syncing",
            "Review your selection, give the drive a name, and click Create drive — your files appear in Explorer seconds later."),
        new(LoginItemSlideId, null,
            "Launch DS3 Drive at login?",
            "DS3 Drive only syncs while it's running. Turn this on to have it start automatically when you log in. You can change this anytime in Settings."),
    ];
}
