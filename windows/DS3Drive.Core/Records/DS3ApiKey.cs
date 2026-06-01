namespace DS3Drive.Core.Records;
using System.Text.Json.Serialization;

/// <summary>
/// An S3 API key (access key + secret). Port of Apple's <c>DS3ApiKey</c>
/// (apple/DS3Lib/Sources/DS3Lib/Models/DS3APIKey.swift). The coordinator wire
/// format is <c>{name, api_key, secret_key, created_at}</c>. The coordinator has
/// no separate id, so <c>Id</c> is derived from <see cref="Name"/> (see
/// <see cref="Identifier"/>) and is not deserialized; <c>IamUserId</c> is filled
/// in by the caller (it is not part of the key payload). The secret is returned
/// only on creation — <c>SecretKey</c> may be empty when re-listed.
/// </summary>
public sealed record DS3ApiKey(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("api_key")] string AccessKey,
    [property: JsonPropertyName("secret_key")] string SecretKey,
    [property: JsonIgnore] string IamUserId = "")
{
    /// <summary>Stable identifier for the key (the coordinator keys on the name).</summary>
    [JsonIgnore]
    public string Id => Name;
}
