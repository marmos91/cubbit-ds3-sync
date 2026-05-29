namespace DS3Drive.ViewModels.Services;

using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core.Records;

/// <summary>
/// SDK facade for the drive-setup wizard: project + bucket listing and the
/// load-bearing API-key reconciliation algorithm (port of Apple's <c>DS3SDK</c>,
/// apple/DS3Lib/Sources/DS3Lib/DS3SDK.swift:68-249, PATTERNS §2.6). ViewModels depend
/// on this interface (never on <see cref="DS3Drive.Core.DS3Session"/> directly) so the
/// wizard stays unit-testable with an NSubstitute fake.
/// </summary>
public interface IDS3SdkService
{
    /// <summary>Lists the projects visible to the account (DS3SDK.swift:88-102 port).</summary>
    Task<IReadOnlyList<DS3Project>> GetProjectsAsync(CancellationToken ct);

    /// <summary>Lists the buckets in a project (DS3Session.ListBuckets — the session
    /// is already scoped to the account's S3 credentials).</summary>
    Task<IReadOnlyList<DS3Bucket>> GetBucketsAsync(DS3Project project, CancellationToken ct);

    /// <summary>
    /// Loads the matching API key from disk, or reconciles it against the remote list
    /// and (re)creates it — the byte-for-byte port of DS3SDK.swift:163-195 (D-10,
    /// PATTERNS §2.6). The same deterministic name pattern Apple uses → the same key
    /// shows up in the Cubbit console, which is what makes a Windows drive interoperable
    /// with a macOS one for the same bucket.
    /// </summary>
    Task<DS3ApiKey> LoadOrCreateApiKeyAsync(DS3IAMUser user, string projectName, CancellationToken ct);

    /// <summary>
    /// The deterministic API-key name (port of DS3SDK.swift:242-248 — DO NOT modify):
    /// <c>{prefix}({username}_{project lowercased, spaces→underscores}_{installationId})</c>.
    /// </summary>
    string ApiKeyName(DS3IAMUser user, string projectName);
}
