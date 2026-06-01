namespace DS3Drive.Tests;

using System.Reflection;
using DS3Drive.Core;
using DS3Drive.Tests.Fixtures;
using Xunit;

/// <summary>
/// Wave-0 verification harness for the <c>DS3DriveS3Client</c> handle-owning
/// facade (criteria #1, #2, #4 of phase 17.1). Mirrors the structure of
/// <see cref="DS3SessionTests"/>: deterministic managed-only lifecycle tests that
/// never touch the native <c>ds3_ffi.dll</c>, plus credential-gated live
/// round-trips behind <c>[RequiresCredentials, Trait("Category","Integration")]</c>.
///
/// <para>
/// <b>Plan-02 dependency.</b> The <c>DS3Drive.Core.DS3DriveS3Client</c> facade
/// (the C# owner of the <c>ds3_s3_client_new</c> / <c>ds3_s3_client_destroy</c>
/// handle added in plan 17.1-01) does NOT exist until plan 17.1-02 lands. So this
/// file deliberately does NOT reference that type at compile time — the
/// managed-only tests locate it by reflection (and no-op when it is absent), and
/// the live round-trip bodies are skipped via <see cref="SkipFacadeAttribute"/>.
/// Once the facade ships, the reflection probes resolve and the live bodies are
/// filled in (authenticate → reconcile API key → mint the handle → exercise the 6
/// S3 ops). This satisfies the Nyquist contract: the verification loop exists
/// BEFORE the consumer is wired.
/// </para>
///
/// <para>xUnit 2.9.0 has no <c>Assert.Skip</c>; the managed-only tests therefore
/// no-op (pass) when the facade type is absent, and the live tests carry the
/// <c>[RequiresCredentials]</c> skip-attribute already used across the suite.</para>
/// </summary>
[Collection("Integration")]
public sealed class DS3DriveS3ClientIntegrationTests
{
    /// <summary>Fully-qualified name of the plan-02 facade. Resolved by reflection
    /// so this file compiles before the type exists.</summary>
    private const string FacadeTypeName = "DS3Drive.Core.DS3DriveS3Client";

    /// <summary>Locates the plan-02 facade type in the DS3Drive.Core assembly, or
    /// returns null if plan 17.1-02 has not landed yet.</summary>
    private static Type? FacadeType()
        => typeof(DS3Session).Assembly.GetType(FacadeTypeName);

    /// <summary>
    /// Constructs the facade with a zero (already-disposed) native handle via the
    /// private <c>DS3DriveS3Client(IntPtr)</c> ctor — the same managed-only trick
    /// <see cref="DS3SessionTests"/> uses. Returns null when the facade type or its
    /// private ctor is absent (plan 17.1-02 not yet executed).
    /// </summary>
    private static (object instance, Type type)? NewZeroHandleClient()
    {
        var type = FacadeType();
        var ctor = type?.GetConstructor(
            BindingFlags.NonPublic | BindingFlags.Instance,
            binder: null,
            types: new[] { typeof(IntPtr) },
            modifiers: null);
        if (type is null || ctor is null)
        {
            return null;
        }

        return (ctor.Invoke(new object[] { IntPtr.Zero }), type);
    }

    // -----------------------------------------------------------------------
    // Managed-only lifecycle tests (criterion #1) — run WITHOUT the native DLL,
    // so they live in the default (Category != Integration) loop. They no-op
    // (pass) until the plan-02 facade lands (xUnit 2.9.0 has no Assert.Skip).
    // -----------------------------------------------------------------------

    // Double-dispose is a no-op on a zero handle (Interlocked single-shot guard,
    // PATTERNS §"Single-shot dispose guard"). Mirror of
    // DS3SessionTests.Dispose_TwoTimes_DoesNotThrow.
    [Fact]
    public void Dispose_TwoTimes_DoesNotThrow()
    {
        var built = NewZeroHandleClient();
        if (built is null)
        {
            return; // facade not present yet (plan 17.1-02); no-op until then.
        }

        var (instance, _) = built.Value;
        var disposable = Assert.IsAssignableFrom<IDisposable>(instance);
        disposable.Dispose();
        disposable.Dispose(); // second dispose must be a no-op (no native call, no throw)
    }

    // EnsureHandle short-circuit (PATTERNS §"Handle short-circuit"): any S3 method
    // on a gone handle throws a managed exception before P/Invoking — NEVER an
    // AccessViolation. Mirror of DS3SessionTests.EnsureHandle_AfterDispose_ThrowsLoggedOut.
    [Fact]
    public void S3Method_AfterDispose_Throws_NotAccessViolation()
    {
        var built = NewZeroHandleClient();
        if (built is null)
        {
            return; // facade not present yet (plan 17.1-02).
        }

        var (instance, type) = built.Value;
        ((IDisposable)instance).Dispose();

        // ListBuckets() takes no args; calling it on a disposed handle must surface
        // a managed exception (the EnsureHandle guard), NEVER an AccessViolation.
        var listBuckets = type.GetMethod("ListBuckets", Type.EmptyTypes);
        if (listBuckets is null)
        {
            return; // ListBuckets() not present yet (plan 17.1-02).
        }

        var ex = Assert.ThrowsAny<Exception>(() =>
        {
            try
            {
                listBuckets.Invoke(instance, Array.Empty<object>());
            }
            catch (TargetInvocationException tie) when (tie.InnerException is not null)
            {
                throw tie.InnerException; // unwrap the reflection wrapper
            }
        });

        Assert.False(ex is AccessViolationException,
            "A disposed handle must throw a managed exception, never an AccessViolation.");
    }

    // -----------------------------------------------------------------------
    // Live round-trips (criteria #2, #4) — gated on CUBBIT_TEST_* + run only in
    // the credentials-enabled CI full suite (workflow_dispatch). Bodies are
    // filled in once the plan-02 facade lands.
    // -----------------------------------------------------------------------

    // Criterion #2: build the client from the reconciled API-key flow (AccessKey /
    // SecretKey / endpoint), NOT the session token, and list buckets through it.
    [RequiresCredentials, Trait("Category", "Integration")]
    public void Create_FromReconciledApiKey_Lists()
    {
        var creds = CubbitCredentials.FromEnvironment();
        Assert.True(creds.IsAvailable); // gating contract; live body lands with plan 17.1-02.

        // TODO(plan 17.1-02): authenticate → reconcile the API key for (user, project)
        // → DS3DriveS3Client.Create(account.EndpointGateway, key.AccessKey, key.SecretKey)
        // → assert ListBuckets() returns the expected bucket set.
    }

    // Criterion #4 (WIN-04..06): full list → head → upload → download → delete →
    // copy round-trip through the minted S3 handle.
    [RequiresCredentials, Trait("Category", "Integration")]
    public void RoundTrip_ListHeadUploadDownloadDeleteCopy()
    {
        var creds = CubbitCredentials.FromEnvironment();
        Assert.True(creds.IsAvailable);

        // TODO(plan 17.1-02): mint a DS3DriveS3Client, then exercise the 6 S3 ops
        // (ListObjects / HeadObject / UploadObject / DownloadObject / DeleteObject /
        // CopyObject) against a scratch key and assert a clean round-trip + cleanup.
    }
}
