namespace DS3Drive.Core.Records;

using System.Collections.Generic;
using System.Text.Json.Serialization;

/// <summary>
/// The result of an S3 ListObjectsV2 call: the objects in this page, the common prefixes
/// (the virtual "folders" surfaced when a delimiter is supplied), and pagination state. The
/// native list-objects call returns this whole object — deserializing just an object array
/// drops the common prefixes and fails outright.
/// </summary>
public sealed record DS3ObjectListing(
    [property: JsonPropertyName("objects")] IReadOnlyList<DS3Object> Objects,
    [property: JsonPropertyName("common_prefixes")] IReadOnlyList<string> CommonPrefixes,
    [property: JsonPropertyName("next_continuation_token")] string? NextContinuationToken,
    [property: JsonPropertyName("is_truncated")] bool IsTruncated);
