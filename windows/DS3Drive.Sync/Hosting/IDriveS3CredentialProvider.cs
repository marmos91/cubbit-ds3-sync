namespace DS3Drive.Sync.Hosting;

using System.Threading;
using System.Threading.Tasks;
using DS3DriveModel = DS3Drive.Core.Records.DS3Drive;

/// <summary>
/// The per-drive S3 credentials the host needs to build a <c>DS3DriveS3Client</c>:
/// the account's S3 <c>endpoint_gateway</c> plus the drive's reconciled API-key pair.
/// The secret is re-hydrated transiently from the OS-sealed Credential Manager
/// (T-17.1-09) and is NOT retained beyond the <c>DS3DriveS3Client.Create</c> call.
/// </summary>
public sealed record DriveS3Credentials(string Endpoint, string AccessKey, string SecretKey);

/// <summary>
/// Resolves the S3 credentials for a drive. Implemented in the App layer (it owns the
/// live session + the API-key reconciliation SDK + the Credential Manager); the Sync host
/// only consumes this seam so <c>DS3Drive.Sync</c> takes no reverse reference on the
/// App/ViewModels layers (the same boundary discipline as
/// <see cref="IDriveLifecycleSource"/>).
///
/// <para>
/// The provider derives credentials from the API-key flow (AccessKey/SecretKey +
/// <c>account.endpoint_gateway</c>), NOT the session token — criterion #2 of phase 17.1.
/// </para>
/// </summary>
public interface IDriveS3CredentialProvider
{
    /// <summary>
    /// Reconciles + returns the S3 credentials for <paramref name="drive"/>. Mirrors the
    /// reconcile keying of <c>DriveManagementService.RepairCredentialsAsync</c>: the
    /// anchor stores only ids, so the SDK forges the IAM token from the anchor's user id
    /// and resolves the rest. Throws (propagated to the host's per-drive guard) when the
    /// session is gone or the endpoint/secret cannot be resolved.
    /// </summary>
    Task<DriveS3Credentials> GetCredentialsAsync(DS3DriveModel drive, CancellationToken ct);
}
