namespace DS3Drive.Tests;

using System.Reflection;
using DS3Drive.Core;
using DS3Drive.Core.Exceptions;
using DS3Drive.Tests.Fixtures;
using Xunit;

/// <summary>
/// Wave-0 lifecycle + error-translation tests for <see cref="DS3Session"/>
/// (port of the handle-ownership discipline in
/// apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift lines 102-148, 282-334;
/// the loggedOut short-circuit is PATTERNS §3.2).
///
/// The deterministic tests exercise the managed lifecycle WITHOUT touching the
/// native ds3_ffi.dll: a session is constructed with a zero handle (via the
/// private ctor, reachable through reflection in-assembly), so <c>Dispose</c>
/// never P/Invokes <c>ds3_session_destroy</c> and <c>EnsureHandle</c> takes the
/// loggedOut throw path. This keeps them runnable on the local dev box (which
/// lacks the MSVC-linked native DLL — STATE.md 17-02 blocker).
///
/// The live <c>Authenticate</c> round-trip is gated <c>[RequiresCredentials,
/// Trait("Category","Integration")]</c> so it is skipped on PR builds and only
/// runs on the secrets-enabled CI full suite.
/// </summary>
[Collection("Integration")]
public sealed class DS3SessionTests
{
    /// <summary>
    /// Constructs a <see cref="DS3Session"/> with a zero (already-disposed)
    /// native handle via the private ctor. Safe for managed-only assertions:
    /// Dispose is a no-op and every FFI method short-circuits to loggedOut
    /// before any P/Invoke.
    /// </summary>
    private static DS3Session NewZeroHandleSession()
    {
        var ctor = typeof(DS3Session).GetConstructor(
            BindingFlags.NonPublic | BindingFlags.Instance,
            binder: null,
            types: new[] { typeof(IntPtr) },
            modifiers: null)
            ?? throw new InvalidOperationException("DS3Session(IntPtr) ctor not found");
        return (DS3Session)ctor.Invoke(new object[] { IntPtr.Zero });
    }

    // Dispose is idempotent: a zero-handle session disposes twice without
    // calling the native destroy (Interlocked guard — threat T-17-05-06).
    [Fact]
    public void Dispose_TwoTimes_DoesNotThrow()
    {
        var session = NewZeroHandleSession();
        session.Dispose();
        session.Dispose(); // second dispose must be a no-op (no native call, no throw)
        Assert.False(session.IsAuthenticated);
    }

    // EnsureHandle short-circuit (PATTERNS §3.2): any FFI method on a gone
    // handle throws DS3AuthenticationException(LoggedOut) before P/Invoking.
    [Fact]
    public void EnsureHandle_AfterDispose_ThrowsLoggedOut()
    {
        var session = NewZeroHandleSession();
        session.Dispose();

        var ex = Assert.Throws<DS3AuthenticationException>(() => session.AccountInfo());
        Assert.Equal(AuthFailureReason.LoggedOut, ex.Reason);
        Assert.Equal(1005, ex.ErrorCode);
    }

    // IsAuthenticated reflects the live handle state.
    [Fact]
    public void IsAuthenticated_OnZeroHandle_IsFalse()
    {
        var session = NewZeroHandleSession();
        Assert.False(session.IsAuthenticated);
    }

    // The 1007 → TwoFactorRequired translation is the exact path Authenticate's
    // Complete() takes on a non-zero return code (rc != 0 ⇒
    // DS3ExceptionFactory.From(err)). Verified here without a native call
    // (load-bearing per D-15; the live equivalent is the Integration test below).
    [Fact]
    public void AuthFailure1007_TranslatesToTwoFactorRequired()
    {
        var ex = Assert.IsType<DS3AuthenticationException>(DS3ExceptionFactory.From(1007));
        Assert.Equal(AuthFailureReason.TwoFactorRequired, ex.Reason);
    }

    // Live smoke: authenticate against the production Cubbit coordinator.
    // Skipped unless CUBBIT_TEST_EMAIL / CUBBIT_TEST_PASSWORD are set, and
    // excluded from PR builds via the Category!=Integration filter.
    [RequiresCredentials, Trait("Category", "Integration")]
    public void Authenticate_WithValidCredentials_ReturnsAuthenticatedSession()
    {
        var creds = CubbitCredentials.FromEnvironment();
        using var session = DS3Session.Authenticate(
            creds.Email, creds.Password, creds.Tenant, creds.CoordinatorUrl);

        Assert.True(session.IsAuthenticated);
        Assert.False(string.IsNullOrEmpty(session.AccountId));
    }
}
