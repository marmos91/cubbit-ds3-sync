namespace DS3Drive.App.Pages;

using DS3Drive.ViewModels.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;
using Windows.System;

/// <summary>
/// Code-behind for the 2FA challenge page. Resolves <see cref="TwoFactorViewModel"/> from
/// DI and seeds it with the credentials forwarded via the navigation parameter
/// (<see cref="TwoFactorContext"/>), focusing the code field on load.
/// </summary>
public sealed partial class TwoFactorPage : Page
{
    public TwoFactorPage()
    {
        ViewModel = App.Host.Services.GetRequiredService<TwoFactorViewModel>();
        InitializeComponent();
        Loaded += (_, _) => CodeBox.Focus(FocusState.Programmatic);
    }

    public TwoFactorViewModel ViewModel { get; }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is TwoFactorContext context)
        {
            ViewModel.Initialize(context);
        }
    }

    /// <summary>Submits the 2FA code when Enter is pressed in the code field, unless a
    /// verification is already in flight.</summary>
    private void OnCodeKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter && ViewModel.VerifyCommand.CanExecute(null))
        {
            e.Handled = true;
            ViewModel.VerifyCommand.Execute(null);
        }
    }

    // Resend is wired in Phase 18; for now it is a no-op placeholder (UI-SPEC: "Resend code").
    private void OnResendClick(object sender, RoutedEventArgs e)
    {
        // TODO(Phase 18): re-trigger the 2FA challenge send.
    }
}
