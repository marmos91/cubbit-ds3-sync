using Xunit;

namespace DS3Drive.Tests.Fixtures;

/// <summary>
/// Env-var-backed credentials for the integration test suite.
///
/// Mirrors the Apple-side convention (apple/DS3DriveProviderTests/TestFixtures.swift):
/// real Cubbit credentials are supplied out-of-band (CI repo secrets or a developer's
/// shell), never committed. When the required vars are absent, <see cref="IsAvailable"/>
/// is false and <see cref="RequiresCredentialsAttribute"/> skips the test instead of
/// failing it — so the default PR build (which sets no secrets) stays green.
///
/// Required:  CUBBIT_TEST_EMAIL, CUBBIT_TEST_PASSWORD
/// Optional:  CUBBIT_TEST_TENANT (may be null/empty for single-tenant accounts)
///            CUBBIT_TEST_COORDINATOR_URL (defaults to the EU prod coordinator)
///
/// Security (threat T-17-03-01): this type never logs credential VALUES. Only the
/// boolean availability flag is ever surfaced.
/// </summary>
public sealed class CubbitCredentials
{
    /// <summary>Default coordinator URL when CUBBIT_TEST_COORDINATOR_URL is unset.</summary>
    public const string DefaultCoordinatorUrl = "https://api.eu00wi.cubbit.services";

    public string Email { get; }
    public string Password { get; }
    public string? Tenant { get; }
    public string CoordinatorUrl { get; }

    /// <summary>True iff both required vars (email + password) are non-empty.</summary>
    public bool IsAvailable { get; }

    private CubbitCredentials(string email, string password, string? tenant, string coordinatorUrl)
    {
        Email = email;
        Password = password;
        Tenant = tenant;
        CoordinatorUrl = coordinatorUrl;
        IsAvailable = !string.IsNullOrWhiteSpace(email) && !string.IsNullOrWhiteSpace(password);
    }

    /// <summary>
    /// Reads the CUBBIT_TEST_* environment variables. Always returns a non-null
    /// instance; check <see cref="IsAvailable"/> before using it for a live call.
    /// </summary>
    public static CubbitCredentials FromEnvironment()
    {
        string email = Environment.GetEnvironmentVariable("CUBBIT_TEST_EMAIL") ?? string.Empty;
        string password = Environment.GetEnvironmentVariable("CUBBIT_TEST_PASSWORD") ?? string.Empty;

        string? tenant = Environment.GetEnvironmentVariable("CUBBIT_TEST_TENANT");
        if (string.IsNullOrWhiteSpace(tenant))
        {
            tenant = null;
        }

        string coordinator = Environment.GetEnvironmentVariable("CUBBIT_TEST_COORDINATOR_URL") ?? string.Empty;
        if (string.IsNullOrWhiteSpace(coordinator))
        {
            coordinator = DefaultCoordinatorUrl;
        }

        return new CubbitCredentials(email, password, tenant, coordinator);
    }
}

/// <summary>
/// Collection definition that serializes every credential-gated integration test
/// (cfapi/S3 round-trips must not interleave; reinforces xunit.runner.json's
/// parallelizeTestCollections=false). Apply with
/// <c>[Collection("Integration")]</c> on integration test classes.
/// </summary>
[CollectionDefinition("Integration")]
public sealed class IntegrationCollection
{
}

/// <summary>
/// A <see cref="FactAttribute"/> that auto-skips when Cubbit credentials are not
/// present in the environment. Pair with <c>[Trait("Category", "Integration")]</c>
/// so the CI <c>Category!=Integration</c> filter excludes it on PR builds while a
/// secrets-enabled full-suite run still executes it.
///
/// Usage:
///   [RequiresCredentials, Trait("Category", "Integration")]
///   public async Task Authenticate_WithRealCreds_ReturnsSession() { ... }
/// </summary>
public sealed class RequiresCredentialsAttribute : FactAttribute
{
    public RequiresCredentialsAttribute()
    {
        if (!CubbitCredentials.FromEnvironment().IsAvailable)
        {
            Skip = "Cubbit credentials not set (CUBBIT_TEST_EMAIL / CUBBIT_TEST_PASSWORD)";
        }
    }
}
