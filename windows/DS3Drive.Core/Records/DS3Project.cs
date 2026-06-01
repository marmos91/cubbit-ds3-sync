namespace DS3Drive.Core.Records;

using System.Text.Json.Serialization;

/// <summary>
/// A Cubbit DS3 project. Port of Apple's <c>Project</c>
/// (apple/DS3Lib/Sources/DS3Lib/Models/Project.swift). The JSON property names
/// match the coordinator wire format (<c>project_id</c>, <c>project_name</c>,
/// <c>project_tenant_id</c>) that <c>ds3_get_projects</c> emits, so this record
/// deserializes directly from the FFI JSON output.
/// </summary>
public sealed record DS3Project(
    [property: JsonPropertyName("project_id")] string Id,
    [property: JsonPropertyName("project_name")] string Name,
    [property: JsonPropertyName("project_tenant_id")] string OrganizationId);
