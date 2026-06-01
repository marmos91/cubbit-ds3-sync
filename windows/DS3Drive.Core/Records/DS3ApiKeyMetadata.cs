namespace DS3Drive.Core.Records;

using System.Text.Json.Serialization;

/// <summary>
/// Non-secret API-key metadata (name + owning IAM user) used by the key
/// reconciliation algorithm (PATTERNS §2.6) which compares local and remote keys
/// by name without ever materializing the secret. Derived from Apple's
/// <c>DS3ApiKey</c> minus the credential fields.
/// </summary>
public sealed record DS3ApiKeyMetadata(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonIgnore] string IamUserId = "")
{
    /// <summary>Stable identifier for the key (the coordinator keys on the name).</summary>
    [JsonIgnore]
    public string Id => Name;
}
