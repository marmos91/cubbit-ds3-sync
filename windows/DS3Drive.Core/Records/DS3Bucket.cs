namespace DS3Drive.Core.Records;

using System.Text.Json.Serialization;

/// <summary>
/// An S3 bucket. Mirrors the JSON shape emitted by <c>ds3_list_buckets</c>
/// (core/ds3-ffi/src/c_exports.rs lines 452-457: <c>{"name", "creation_date"}</c>).
/// Apple represents this as Soto's <c>S3.Bucket</c>; the Windows record is the
/// flat equivalent.
/// </summary>
public sealed record DS3Bucket(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("creation_date")] DateTime CreationDate);
