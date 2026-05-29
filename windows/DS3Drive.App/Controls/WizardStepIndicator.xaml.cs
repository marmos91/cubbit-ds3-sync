namespace DS3Drive.App.Controls;

using System.Collections.Generic;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

/// <summary>
/// One rendered step in the <see cref="WizardStepIndicator"/>. Pre-computes the brushes +
/// digit text for its state (completed / active / pending) so the DataTemplate stays
/// binding-only. Constructed by <see cref="WizardStepIndicator.Rebuild"/>.
/// </summary>
public sealed class WizardStepItem
{
    public required string DigitText { get; init; }
    public required string Label { get; init; }
    public required Brush CircleFill { get; init; }
    public required Brush CircleBorder { get; init; }
    public required Brush DigitForeground { get; init; }
    public required Visibility ConnectorVisibility { get; init; }
}

/// <summary>
/// Numbered-step progress rail for the drive-setup wizard (UI-SPEC §"Component Inventory"
/// Controls row). Two dependency properties — <see cref="Steps"/> (the labels) and
/// <see cref="CurrentIndex"/> (the active step) — drive a recompute of the per-step visual
/// state: pending, active (BrandPrimary fill + white digit), or completed (BrandPrimary
/// fill + checkmark glyph). Closest macOS analog: TutorialProgress (PATTERNS §dots).
/// </summary>
public sealed partial class WizardStepIndicator : UserControl
{
    // U+2713 checkmark — renders in the body font (no Segoe Fluent Icons dependency).
    private const string CheckMark = "✓";

    public static readonly DependencyProperty StepsProperty =
        DependencyProperty.Register(
            nameof(Steps), typeof(IList<string>), typeof(WizardStepIndicator),
            new PropertyMetadata(null, OnStateChanged));

    public static readonly DependencyProperty CurrentIndexProperty =
        DependencyProperty.Register(
            nameof(CurrentIndex), typeof(int), typeof(WizardStepIndicator),
            new PropertyMetadata(0, OnStateChanged));

    public WizardStepIndicator()
    {
        InitializeComponent();
        Rebuild();
    }

    /// <summary>The ordered step labels (e.g. Project / Bucket / Prefix / Confirm).</summary>
    public IList<string>? Steps
    {
        get => (IList<string>?)GetValue(StepsProperty);
        set => SetValue(StepsProperty, value);
    }

    /// <summary>The zero-based index of the active step.</summary>
    public int CurrentIndex
    {
        get => (int)GetValue(CurrentIndexProperty);
        set => SetValue(CurrentIndexProperty, value);
    }

    private static void OnStateChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((WizardStepIndicator)d).Rebuild();

    private void Rebuild()
    {
        if (StepsItems is null)
        {
            return;
        }

        Brush brandFill = (Brush)Application.Current.Resources["BrandPrimaryBrush"];
        Brush pendingBorder = (Brush)Application.Current.Resources["BorderSubtleBrush"];
        Brush pendingDigit = (Brush)Application.Current.Resources["TextSecondaryBrush"];
        var white = new SolidColorBrush(Colors.White);
        var transparent = new SolidColorBrush(Colors.Transparent);

        var items = new List<WizardStepItem>();
        IList<string> steps = Steps ?? new List<string>();
        for (int i = 0; i < steps.Count; i++)
        {
            bool completed = i < CurrentIndex;
            bool active = i == CurrentIndex;

            items.Add(new WizardStepItem
            {
                // Completed shows a checkmark; else the 1-based step number.
                DigitText = completed ? CheckMark : (i + 1).ToString(),
                Label = steps[i],
                CircleFill = completed || active ? brandFill : transparent,
                CircleBorder = completed || active ? brandFill : pendingBorder,
                DigitForeground = completed || active ? white : pendingDigit,
                ConnectorVisibility = i < steps.Count - 1 ? Visibility.Visible : Visibility.Collapsed,
            });
        }

        StepsItems.ItemsSource = items;
    }
}
