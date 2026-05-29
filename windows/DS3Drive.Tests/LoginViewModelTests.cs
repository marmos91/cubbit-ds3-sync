namespace DS3Drive.Tests;

using System;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core;
using DS3Drive.Core.Exceptions;
using DS3Drive.ViewModels.Navigation;
using DS3Drive.ViewModels.Services;
using DS3Drive.ViewModels.ViewModels;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using NSubstitute;
using NSubstitute.ExceptionExtensions;
using Xunit;

/// <summary>
/// Unit tests for <see cref="LoginViewModel"/> covering the D-15 / PATTERNS §2.3
/// error-routing contract (byte-identical to Apple's LoginViewModel.swift). The
/// <c>isTfaAttempt</c> branch is load-bearing: 2FA-verification errors must surface on
/// TfaError, first-attempt errors on LoginError, and a TwoFactorRequired (1007) result must
/// set Need2FA rather than show an error.
/// </summary>
public sealed class LoginViewModelTests
{
    private const string DefaultCoordinator = "https://api.eu00wi.cubbit.services";

    private static ConfigStore MakeConfig()
    {
        var config = new ConfigurationBuilder()
            .AddInMemoryCollection(new System.Collections.Generic.Dictionary<string, string?>
            {
                ["DS3:DefaultCoordinatorUrl"] = DefaultCoordinator,
            })
            .Build();
        return new ConfigStore(config);
    }

    private static (LoginViewModel vm, IAuthenticationService auth, INavigator nav) MakeViewModel()
    {
        var auth = Substitute.For<IAuthenticationService>();
        var nav = Substitute.For<INavigator>();
        var vm = new LoginViewModel(auth, nav, MakeConfig(), NullLogger<LoginViewModel>.Instance);
        return (vm, auth, nav);
    }

    [Fact] // Test 1
    public async Task LoginSuccess_TogglesLoading_CallsAuthOnce_Navigates()
    {
        var (vm, auth, nav) = MakeViewModel();
        vm.Email = "user@example.com";
        vm.Password = "pw";

        bool sawLoadingTrue = false;
        vm.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(LoginViewModel.IsLoading) && vm.IsLoading)
            {
                sawLoadingTrue = true;
            }
        };

        await vm.LoginCommand.ExecuteAsync(null);

        Assert.True(sawLoadingTrue);
        Assert.False(vm.IsLoading);
        await auth.Received(1).LoginAsync(
            Arg.Is("user@example.com"), Arg.Is("pw"), Arg.Is<string?>(c => c == null),
            Arg.Any<string?>(), Arg.Is(DefaultCoordinator), Arg.Any<CancellationToken>());
        nav.Received(1).Navigate(PageKey.Tutorial, Arg.Any<object?>());
        Assert.Null(vm.LoginError);
    }

    [Fact] // Test 2
    public async Task LoginTwoFactorRequired_SetsNeed2FA_ClearsLoginError()
    {
        var (vm, auth, _) = MakeViewModel();
        auth.LoginAsync(Arg.Any<string>(), Arg.Any<string>(), Arg.Is<string?>(c => c == null), Arg.Any<string?>(), Arg.Any<string>(), Arg.Any<CancellationToken>())
            .Throws(new DS3AuthenticationException(AuthFailureReason.TwoFactorRequired, errorCode: 1007));

        await vm.LoginCommand.ExecuteAsync(null);

        Assert.True(vm.Need2FA);
        Assert.Null(vm.LoginError);
    }

    [Fact] // Test 3
    public async Task LoginServerError_SetsNetworkCopy_OnLoginError()
    {
        var (vm, auth, _) = MakeViewModel();
        auth.LoginAsync(Arg.Any<string>(), Arg.Any<string>(), Arg.Is<string?>(c => c == null), Arg.Any<string?>(), Arg.Any<string>(), Arg.Any<CancellationToken>())
            .Throws(new DS3AuthenticationException(AuthFailureReason.ServerError, errorCode: 1002));

        await vm.LoginCommand.ExecuteAsync(null);

        Assert.Equal("Can't reach Cubbit. Check your internet connection and try again.", vm.LoginError);
        Assert.Null(vm.TfaError);
    }

    [Fact] // Test 4
    public async Task LoginFirstAttempt_ClearsLoginErrorBeforeRun()
    {
        var (vm, auth, _) = MakeViewModel();
        vm.LoginError = "stale error";
        auth.LoginAsync(Arg.Any<string>(), Arg.Any<string>(), Arg.Is<string?>(c => c == null), Arg.Any<string?>(), Arg.Any<string>(), Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);

        await vm.LoginCommand.ExecuteAsync(null);

        // Stale error cleared, no new error on success.
        Assert.Null(vm.LoginError);
    }

    [Fact] // Test 5
    public async Task VerifyTfa_WithCode_CallsAuthWithCode_NavigatesOnSuccess()
    {
        var (vm, auth, nav) = MakeViewModel();
        vm.Email = "user@example.com";
        vm.Password = "pw";
        vm.TfaCode = "123456";

        await vm.VerifyTfaCommand.ExecuteAsync(null);

        await auth.Received(1).LoginAsync(
            Arg.Is("user@example.com"), Arg.Is("pw"), Arg.Is<string?>(c => c == "123456"),
            Arg.Any<string?>(), Arg.Is(DefaultCoordinator), Arg.Any<CancellationToken>());
        nav.Received(1).Navigate(PageKey.Tutorial, Arg.Any<object?>());
        Assert.Null(vm.TfaError);
    }

    [Fact] // Test 6
    public async Task VerifyTfa_WrongCode_RoutesToTfaError_NotLoginError()
    {
        var (vm, auth, _) = MakeViewModel();
        vm.TfaCode = "000000";
        auth.LoginAsync(Arg.Any<string>(), Arg.Any<string>(), Arg.Is<string?>(c => c == "000000"), Arg.Any<string?>(), Arg.Any<string>(), Arg.Any<CancellationToken>())
            .Throws(new DS3AuthenticationException(AuthFailureReason.ServerError, "bad code"));

        // ServerError maps to the network copy on either surface, so use a plain auth
        // failure (default reason) to exercise the wrong-code copy on the TFA surface.
        await vm.VerifyTfaCommand.ExecuteAsync(null);

        // ServerError → network copy, but it MUST be on TfaError (the 2FA surface), never LoginError.
        Assert.Null(vm.LoginError);
        Assert.NotNull(vm.TfaError);
    }

    [Fact] // Test 6b — wrong-code copy verbatim
    public async Task VerifyTfa_AuthFailure_ShowsWrongCodeCopy()
    {
        var (vm, auth, _) = MakeViewModel();
        vm.TfaCode = "000000";
        auth.LoginAsync(Arg.Any<string>(), Arg.Any<string>(), Arg.Is<string?>(c => c == "000000"), Arg.Any<string?>(), Arg.Any<string>(), Arg.Any<CancellationToken>())
            .Throws(new DS3AuthenticationException(AuthFailureReason.LoggedOut, "denied"));

        await vm.VerifyTfaCommand.ExecuteAsync(null);

        Assert.Equal("That code didn't work. Enter the 6-digit code from your authenticator app.", vm.TfaError);
        Assert.Null(vm.LoginError);
    }

    [Fact] // Test 7
    public async Task Login_WhileLoading_IsNoOp()
    {
        var (vm, auth, _) = MakeViewModel();
        var gate = new TaskCompletionSource();
        auth.LoginAsync(Arg.Any<string>(), Arg.Any<string>(), Arg.Is<string?>(c => c == null), Arg.Any<string?>(), Arg.Any<string>(), Arg.Any<CancellationToken>())
            .Returns(_ => gate.Task);

        // First call starts and parks on the gate (IsLoading == true).
        Task first = vm.LoginCommand.ExecuteAsync(null);
        Assert.True(vm.IsLoading);

        // Second call must be a no-op while the first is in flight.
        await vm.LoginCommand.ExecuteAsync(null);

        gate.SetResult();
        await first;

        // Exactly one auth call despite two command invocations.
        await auth.Received(1).LoginAsync(
            Arg.Any<string>(), Arg.Any<string>(), Arg.Is<string?>(c => c == null), Arg.Any<string?>(), Arg.Any<string>(), Arg.Any<CancellationToken>());
    }

    [Fact] // Test 8
    public void CoordinatorUrl_DefaultsToConfigValue()
    {
        var (vm, _, _) = MakeViewModel();
        Assert.Equal(DefaultCoordinator, vm.CoordinatorUrl);
    }
}
