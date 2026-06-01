namespace DS3Drive.Core.Records;

using System.Text.Json.Serialization;

/// <summary>
/// An IAM user inside a project. Port of Apple's <c>IAMUser</c>
/// (apple/DS3Lib/Sources/DS3Lib/Models/IAMUser.swift). JSON keys match the
/// coordinator wire format (<c>user_id</c>, <c>user_name</c>). The contract's
/// <c>Email</c> field has no coordinator equivalent in the Apple model (which
/// carries <c>is_root</c> instead); it is populated from account context when
/// available and otherwise empty.
/// </summary>
public sealed record DS3IAMUser(
    [property: JsonPropertyName("user_id")] string Id,
    [property: JsonPropertyName("user_name")] string Username,
    [property: JsonPropertyName("email")] string Email);
