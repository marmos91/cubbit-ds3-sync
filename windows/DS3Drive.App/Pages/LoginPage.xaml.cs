namespace DS3Drive.App.Pages;

using System;
using DS3Drive.ViewModels.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

/// <summary>
/// Code-behind for the sign-in form. Resolves <see cref="LoginViewModel"/> from DI,
/// auto-focuses the email field on load (Apple parity — LoginView.swift focuses after a
/// short delay), and watches <see cref="LoginViewModel.Need2FA"/> to navigate to the 2FA
/// page (D-15), forwarding the entered credentials via the navigation parameter.
/// </summary>
public sealed partial class LoginPage : Page
{
    public LoginPage()
    {
        ViewModel = App.Host.Services.GetRequiredService<LoginViewModel>();
        InitializeComponent();

        ViewModel.PropertyChanged += OnViewModelPropertyChanged;
        Loaded += OnLoaded;
        Unloaded += (_, _) => ViewModel.PropertyChanged -= OnViewModelPropertyChanged;
    }

    public LoginViewModel ViewModel { get; }

    /// <summary>Primary CTA caption: swaps to "Signing in…" while a request is in flight (UI-SPEC).</summary>
    public string SignInLabel(bool isLoading) => isLoading ? "Signing in…" : "Sign in";

    private void OnLoaded(object sender, RoutedEventArgs e) => EmailBox.Focus(FocusState.Programmatic);

    private void OnViewModelPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(LoginViewModel.Need2FA) && ViewModel.Need2FA)
        {
            var context = new TwoFactorContext(
                ViewModel.Email, ViewModel.Password, ViewModel.Tenant, ViewModel.CoordinatorUrl);
            Frame.Navigate(typeof(TwoFactorPage), context);
        }
    }
}
