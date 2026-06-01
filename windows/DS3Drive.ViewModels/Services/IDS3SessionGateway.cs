namespace DS3Drive.ViewModels.Services;

using DS3Drive.Core.Records;

/// <summary>
/// Mockable seam over the handful of <see cref="DS3Drive.Core.DS3Session"/> calls the
/// SDK + reconciliation algorithm needs. <c>DS3Session</c> is a sealed FFI facade and
/// cannot be substituted directly in tests, so the App layer adapts the live session
/// (owned by <see cref="IAuthenticationService"/>) onto this interface and the unit
/// tests provide an NSubstitute fake for the remote API-key calls (PATTERNS §2.6 test
/// cases A2-A6). Every method mirrors the corresponding <c>DS3Session</c> method 1:1.
/// </summary>
public interface IDS3SessionGateway
{
    /// <summary>The account id of the live session (Credential Manager scope key).</summary>
    string AccountId { get; }

    /// <summary>Lists the projects visible to the account (<c>DS3Session.GetProjects</c>).</summary>
    IReadOnlyList<DS3Project> GetProjects();

    /// <summary>Lists the buckets reachable with the session credentials (<c>DS3Session.ListBuckets</c>).</summary>
    IReadOnlyList<DS3Bucket> ListBuckets();

    /// <summary>Lists objects under a prefix (<c>DS3Session.ListObjects</c>).</summary>
    IReadOnlyList<DS3Object> ListObjects(string bucket, string prefix, string delimiter, string? continuationToken);

    /// <summary>Forges an IAM token for a user (<c>DS3Session.ForgeIamToken</c>).</summary>
    string ForgeIamToken(string iamUserId);

    /// <summary>Loads the remote API keys for an IAM user (<c>DS3Session.LoadApiKeys</c>).</summary>
    IReadOnlyList<DS3ApiKey> LoadApiKeys(string iamUserId, string iamToken);

    /// <summary>Creates a new API key (<c>DS3Session.CreateApiKey</c>; the secret is returned only here).</summary>
    DS3ApiKey CreateApiKey(string iamUserId, string iamToken, string apiKeyName);

    /// <summary>Deletes an API key by id (<c>DS3Session.DeleteApiKey</c>).</summary>
    void DeleteApiKey(string iamUserId, string apiKeyId, string iamToken);
}
