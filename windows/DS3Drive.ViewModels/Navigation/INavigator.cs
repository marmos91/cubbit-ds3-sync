namespace DS3Drive.ViewModels.Navigation;

/// <summary>
/// WinUI-free navigation abstraction consumed by view-models. The App layer implements
/// it over a <c>Frame</c> (mapping <see cref="PageKey"/> → concrete Page Type). Keeping
/// this interface free of WinUI types is what lets the view-models — and their tests —
/// build without the WinUI runtime.
/// </summary>
public interface INavigator
{
    /// <summary>Navigates to the page identified by <paramref name="key"/>, optionally passing a parameter.</summary>
    void Navigate(PageKey key, object? parameter = null);
}
