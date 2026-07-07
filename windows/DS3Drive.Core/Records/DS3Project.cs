namespace DS3Drive.Core.Records;

using System.Collections.Generic;
using System.Text.Json.Serialization;

/// <summary>
/// A Cubbit DS3 project. Port of Apple's <c>Project</c>
/// (apple/DS3Lib/Sources/DS3Lib/Models/Project.swift). The JSON property names
/// match the coordinator wire format (<c>project_id</c>, <c>project_name</c>,
/// <c>project_tenant_id</c>, <c>users</c>) that <c>ds3_get_projects</c> emits, so this
/// record deserializes directly from the FFI JSON output.
///
/// <para><see cref="Users"/> carries the project's IAM users (from the core's project list). The
/// drive-setup flow forges the access JWT for one of these users (the picker defaults to the root
/// user). Without this field the wizard had to fall back to the account id, which the coordinator
/// rejects with HTTP 401.</para>
/// </summary>
public sealed record DS3Project(
    [property: JsonPropertyName("project_id")] string Id,
    [property: JsonPropertyName("project_name")] string Name,
    [property: JsonPropertyName("project_tenant_id")] string OrganizationId,
    [property: JsonPropertyName("users")] IReadOnlyList<DS3IAMUser> Users);
