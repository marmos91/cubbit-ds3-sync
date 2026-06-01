namespace DS3Drive.Core.Records;

using System.Text.Json.Serialization;

/// <summary>
/// An S3 object's metadata, as returned by <c>ds3_head_object</c> and the entries
/// of <c>ds3_list_objects</c>. Mirrors the metadata Soto's <c>S3.Object</c>
/// exposes on the Apple side; the JSON keys follow the ds3-models serialization
/// (<c>key</c>, <c>etag</c>, <c>last_modified</c>, <c>size</c>, <c>content_type</c>).
/// </summary>
public sealed record DS3Object(
    [property: JsonPropertyName("key")] string Key,
    [property: JsonPropertyName("etag")] string ETag,
    [property: JsonPropertyName("last_modified")] DateTime LastModified,
    [property: JsonPropertyName("size")] long Size,
    [property: JsonPropertyName("content_type")] string ContentType);
