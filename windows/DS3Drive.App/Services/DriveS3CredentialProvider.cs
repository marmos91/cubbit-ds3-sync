namespace DS3Drive.App.Services;

using System;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core.Records;
using DS3Drive.Sync.Hosting;
using DS3Drive.ViewModels.Services;
using Microsoft.Extensions.Logging;
using DS3DriveModel = DS3Drive.Core.Records.DS3Drive;

/// <summary>
/// App-layer <see cref="IDriveS3CredentialProvider"/>: resolves the per-drive S3 credentials
/// the sync host needs to build a <c>DS3DriveS3Client</c>, derived from the API-key flow
/// (AccessKey/SecretKey + <c>account.endpoint_gateway</c>) — NOT the session token
/// (criterion #2). The reconcile keying mirrors
/// <c>DriveManagementService.RepairCredentialsAsync</c>: the anchor stores only ids, so the
/// IAM user is reconstructed from <c>anchor.IamUserId</c> and the project-name proxy is the
/// bucket (the deterministic API-key name the SDK reconciles is the same one the wizard +
/// repair path use, so the host borrows exactly the key the drive was created with).
///
/// <para>
/// This lives in the App layer (not Sync) because it owns the SDK reconciliation + the live
/// session's endpoint; the Sync host consumes only the <see cref="IDriveS3CredentialProvider"/>
/// seam, keeping <c>DS3Drive.Sync</c> free of a reverse reference on ViewModels (the same
/// boundary discipline as <see cref="DriveLifecycleSource"/>).
/// </para>
/// </summary>
public sealed class DriveS3CredentialProvider : IDriveS3CredentialProvider
{
    private readonly IDS3SdkService _sdk;
    private readonly IDS3SessionGateway _session;
    private readonly ILogger<DriveS3CredentialProvider> _logger;

    public DriveS3CredentialProvider(
        IDS3SdkService sdk,
        IDS3SessionGateway session,
        ILogger<DriveS3CredentialProvider> logger)
    {
        _sdk = sdk ?? throw new ArgumentNullException(nameof(sdk));
        _session = session ?? throw new ArgumentNullException(nameof(session));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    /// <inheritdoc />
    public async Task<DriveS3Credentials> GetCredentialsAsync(DS3DriveModel drive, CancellationToken ct)
    {
        // Reconstruct the IAM user from the anchor (only the id is persisted) — identical to
        // DriveManagementService.RepairCredentialsAsync. The project-name proxy is the bucket
        // (the same argument the repair path passes), so the reconciled deterministic key name
        // matches the one already on disk for this drive; LoadOrCreateApiKeyAsync short-circuits
        // to the cached local key when present.
        var user = new DS3IAMUser(drive.SyncAnchor.IamUserId, drive.SyncAnchor.IamUserId, string.Empty);
        DS3ApiKey key = await _sdk.LoadOrCreateApiKeyAsync(user, drive.SyncAnchor.Bucket, ct).ConfigureAwait(false);

        string endpoint = _session.EndpointGateway;
        if (string.IsNullOrEmpty(endpoint))
        {
            // Guard the empty-endpoint pitfall (T-17.1-13): an empty endpoint would mint a
            // client that fails every op. Surface it as a clear failure the host's per-drive
            // guard logs, rather than building a dead client.
            throw new InvalidOperationException(
                $"Cannot build S3 client for drive {drive.Id}: account endpoint_gateway is empty.");
        }

        _logger.LogDebug("Resolved S3 credentials for drive {DriveId}.", drive.Id);
        return new DriveS3Credentials(endpoint, key.AccessKey, key.SecretKey);
    }
}
