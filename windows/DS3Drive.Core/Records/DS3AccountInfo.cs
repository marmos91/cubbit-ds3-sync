namespace DS3Drive.Core.Records;
using System.Text.Json.Serialization;

/// <summary>
/// Minimal account identity surfaced by the facade. Port of the load-bearing
/// scalar fields of Apple's <c>Account</c>
/// (apple/DS3Lib/Sources/DS3Lib/Models/Account.swift): the full account payload
/// from <c>ds3_account_info</c> carries the email list, 2FA flag, endpoint
/// gateway, etc. — the App layer (Plan 07) deserializes the complete object when
/// it needs them. This record exposes only the identity the credential store
/// (D-12 target name) and the tray UI need.
///
/// <c>DisplayName</c> and <c>Email</c> have no single scalar in the wire payload
/// (name is split into first/last; email is a list with a default flag), so they
/// are not deserialized here and are composed by the App layer; <c>AccountId</c>
/// (<c>id</c>) and <c>TenantId</c> (<c>tenant_id</c>) map directly.
/// </summary>
public sealed record DS3AccountInfo(
    [property: JsonPropertyName("id")] string AccountId,
    [property: JsonPropertyName("tenant_id")] string TenantId,
    [property: JsonIgnore] string Email = "",
    [property: JsonIgnore] string DisplayName = "");
