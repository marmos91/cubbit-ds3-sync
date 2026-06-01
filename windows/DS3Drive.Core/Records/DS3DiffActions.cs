namespace DS3Drive.Core.Records;

using System.Text.Json.Serialization;

/// <summary>
/// The result of <c>ds3_compute_diff</c>: the keys to upload/download
/// (new or modified) and the keys to delete. Deserialized from the
/// <c>DiffResultRecord</c> JSON the Rust core emits (core/ds3-models). Mirror of
/// Apple's <c>EnumerationDelta</c>
/// (apple/DS3Lib/Sources/DS3Lib/Enumeration/EnumerationDiff.swift).
/// </summary>
public sealed record DS3DiffActions(
    [property: JsonPropertyName("new_or_modified")] IReadOnlyList<string> NewOrModified,
    [property: JsonPropertyName("deleted")] IReadOnlyList<string> Deleted);
