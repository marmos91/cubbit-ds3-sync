//! S3 operation types: listing results, object metadata, transfer progress,
//! and multipart upload context.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// Result of an S3 ListObjectsV2 call.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct S3ListingResult {
    /// The objects returned in this page.
    pub objects: Vec<S3ObjectSummary>,

    /// Common prefixes (virtual "directories") when using a delimiter.
    pub common_prefixes: Vec<String>,

    /// Token for fetching the next page, if the result is truncated.
    pub next_continuation_token: Option<String>,

    /// Whether there are more results to fetch.
    pub is_truncated: bool,
}

/// Summary of a single S3 object from a listing.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct S3ObjectSummary {
    /// The full S3 object key.
    pub key: String,

    /// The object's ETag (entity tag for version/integrity checking).
    pub etag: Option<String>,

    /// When the object was last modified (ISO 8601 or S3 date format).
    pub last_modified: Option<String>,

    /// The object size in bytes.
    pub size: i64,
}

/// Metadata returned from an S3 HeadObject call.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct S3ObjectMetadata {
    /// The object's ETag.
    pub etag: Option<String>,

    /// The MIME content type.
    pub content_type: Option<String>,

    /// When the object was last modified.
    pub last_modified: Option<String>,

    /// The version ID (if bucket versioning is enabled).
    pub version_id: Option<String>,

    /// The object size in bytes.
    pub content_length: i64,

    /// User-defined metadata key-value pairs.
    pub metadata: Option<HashMap<String, String>>,
}

/// Progress of a file transfer (upload or download).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TransferProgress {
    /// Bytes transferred so far.
    pub bytes_transferred: i64,

    /// Total bytes expected (may be unknown for downloads).
    pub total_bytes: Option<i64>,
}

/// Context for an active multipart upload.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MultipartUploadContext {
    /// The target bucket.
    pub bucket: String,

    /// The target object key.
    pub key: String,

    /// The upload ID assigned by S3.
    pub upload_id: String,

    /// The total file size in bytes.
    pub total_size: i64,
}

/// Result of a single completed multipart upload part.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CompletedPartResult {
    /// The part number (1-based).
    pub part_number: i32,

    /// The ETag returned by S3 for this part.
    pub etag: String,
}
