using System.Runtime.InteropServices;
using DS3Drive.Core;
using Xunit;

namespace DS3Drive.Tests;

/// <summary>
/// Round-trip tests for <see cref="CredentialStore"/> against the live Windows
/// Credential Manager (D-12). Serialized via a shared collection because they
/// mutate OS-global keychain state. Each test uses a unique
/// <c>accountId = "test-{Guid}"</c> and tears down with <c>Delete</c> in a
/// <c>finally</c>, so they leave no residue.
///
/// Gated <c>[Trait("Category","Windows")]</c>: the Advapi32 P/Invoke only works
/// on Windows, so on a non-Windows host (e.g. a Linux cargo runner) each test
/// early-returns (a pass with no assertions) rather than failing. CI runs the
/// real assertions on the <c>windows-latest</c> runner.
/// </summary>
[Collection("Windows-Credential-Manager")]
[Trait("Category", "Windows")]
public sealed class CredentialStoreTests
{
    private const string Key = "refreshToken";

    /// <summary>True on Windows; gates the body of every test (Advapi32 is Windows-only).</summary>
    private static bool OnWindows => RuntimeInformation.IsOSPlatform(OSPlatform.Windows);

    private static string NewAccountId() => $"test-{Guid.NewGuid()}";

    // Test 1: Save then Load returns the stored secret.
    [Fact]
    public void Save_ThenLoad_ReturnsSecret()
    {
        if (!OnWindows) return;
        var store = new CredentialStore();
        string account = NewAccountId();
        try
        {
            store.Save(account, Key, "secret-value");
            Assert.Equal("secret-value", store.Load(account, Key));
        }
        finally
        {
            store.Delete(account, Key);
        }
    }

    // Test 2: Save then Delete then Load returns null.
    [Fact]
    public void Save_ThenDelete_LoadReturnsNull()
    {
        if (!OnWindows) return;
        var store = new CredentialStore();
        string account = NewAccountId();
        try
        {
            store.Save(account, Key, "secret-value");
            store.Delete(account, Key);
            Assert.Null(store.Load(account, Key));
        }
        finally
        {
            store.Delete(account, Key);
        }
    }

    // Test 3: Save twice overwrites (Load returns the latest value).
    [Fact]
    public void Save_Twice_LoadReturnsLatest()
    {
        if (!OnWindows) return;
        var store = new CredentialStore();
        string account = NewAccountId();
        try
        {
            store.Save(account, Key, "v1");
            store.Save(account, Key, "v2");
            Assert.Equal("v2", store.Load(account, Key));
        }
        finally
        {
            store.Delete(account, Key);
        }
    }

    // Test 4: Enumerate returns target names matching the "Cubbit DS3 Drive — *" prefix.
    [Fact]
    public void Enumerate_ReturnsPrefixedTargetNames()
    {
        if (!OnWindows) return;
        var store = new CredentialStore();
        string account = NewAccountId();
        try
        {
            store.Save(account, Key, "secret-value");
            string expected = $"Cubbit DS3 Drive — {account} — {Key}";
            Assert.Contains(store.Enumerate(), name =>
                name.StartsWith("Cubbit DS3 Drive — ", StringComparison.Ordinal)
                && name == expected);
        }
        finally
        {
            store.Delete(account, Key);
        }
    }

    // Test 5: Target name format uses an em-dash (U+2014), NOT a hyphen (D-12 load-bearing).
    [Fact]
    public void TargetName_UsesEmDash()
    {
        if (!OnWindows) return;
        var store = new CredentialStore();
        string account = NewAccountId();
        try
        {
            store.Save(account, Key, "secret-value");
            string emDash = $"Cubbit DS3 Drive — {account} — {Key}";
            string hyphen = $"Cubbit DS3 Drive - {account} - {Key}";
            var names = store.Enumerate().ToList();
            Assert.Contains(emDash, names);
            Assert.DoesNotContain(hyphen, names);
        }
        finally
        {
            store.Delete(account, Key);
        }
    }

    // Test 6: Saving an empty/null secret throws ArgumentException.
    [Fact]
    public void Save_EmptySecret_Throws()
    {
        if (!OnWindows) return;
        var store = new CredentialStore();
        string account = NewAccountId();
        Assert.Throws<ArgumentException>(() => store.Save(account, Key, ""));
        Assert.Throws<ArgumentException>(() => store.Save(account, Key, null!));
    }
}
