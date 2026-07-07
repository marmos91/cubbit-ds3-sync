namespace DS3Drive.Core.Records;

using System.Text.Json.Serialization;

/// <summary>
/// An IAM user inside a project. Port of Apple's <c>IAMUser</c>
/// (apple/DS3Lib/Sources/DS3Lib/Models/IAMUser.swift). JSON keys match the
/// coordinator wire format (<c>user_id</c>, <c>user_name</c>, <c>is_root</c>). The
/// contract's <c>Email</c> field has no coordinator equivalent; it is populated from
/// account context when available and otherwise empty.
///
/// <para><see cref="IsRoot"/> mirrors the Apple model's <c>is_root</c> — the wizard's
/// IAM-user picker labels the root user and defaults to it (the user the account owner
/// can always forge an access JWT for). It defaults to <c>false</c> so the existing
/// 3-arg constructions (synthetic users reconstructed from an anchor) still compile.</para>
/// </summary>
public sealed record DS3IAMUser(
    [property: JsonPropertyName("user_id")] string Id,
    [property: JsonPropertyName("user_name")] string Username,
    [property: JsonPropertyName("email")] string Email,
    [property: JsonPropertyName("is_root")] bool IsRoot = false)
{
    /// <summary>Display label for the IAM-user picker: <c>"{username} (root)"</c> for the
    /// root user, else the bare username (mirrors macOS TreeNavigationView's "(root)" tag).</summary>
    [JsonIgnore]
    public string DisplayLabel => IsRoot ? $"{Username} (root)" : Username;
}
