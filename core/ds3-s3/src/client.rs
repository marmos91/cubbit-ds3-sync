//! DS3 S3 client wrapper around `aws-sdk-s3` with custom endpoint support.

use ds3_models::DS3Error;
use percent_encoding::percent_decode_str;

// ---------------------------------------------------------------------------
// Constants (matching Swift DefaultSettings.S3)
// ---------------------------------------------------------------------------

/// Number of objects to fetch per ListObjectsV2 call.
pub const LIST_BATCH_SIZE: i32 = 2000;

/// S3 key delimiter for virtual directories.
pub const DELIMITER: &str = "/";

/// Part size for multipart uploads (5 MB).
pub const MULTIPART_PART_SIZE: usize = 5 * 1024 * 1024;

/// Files larger than this threshold use multipart upload (5 MB).
pub const MULTIPART_THRESHOLD: u64 = 5 * 1024 * 1024;

/// Maximum concurrent part uploads.
pub const MULTIPART_CONCURRENCY: usize = 4;

/// Default timeout for S3 operations in seconds.
pub const TIMEOUT_SECONDS: u64 = 300;

/// Maximum retries for transient failures.
pub const MAX_RETRIES: u32 = 5;

/// Name of the empty marker file used to represent empty folders.
pub const MARKER_FILE_NAME: &str = ".ds3keep";

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// S3 client wrapping `aws_sdk_s3::Client` configured for Cubbit's
/// S3-compatible endpoint with path-style addressing.
#[derive(Clone)]
pub struct DS3S3Client {
    pub(crate) client: aws_sdk_s3::Client,
}

impl DS3S3Client {
    /// Creates a new S3 client for the given endpoint and credentials.
    ///
    /// Uses `force_path_style(true)` for Cubbit compatibility and defaults
    /// the region to `us-east-1` if not specified.
    #[tracing::instrument(skip(access_key, secret_key))]
    pub fn new(
        endpoint: &str,
        access_key: &str,
        secret_key: &str,
        region: Option<&str>,
    ) -> Self {
        let creds = aws_sdk_s3::config::Credentials::new(
            access_key,
            secret_key,
            None, // session token
            None, // expiry
            "ds3",
        );

        let config = aws_sdk_s3::config::Builder::new()
            .behavior_version_latest()
            .endpoint_url(endpoint)
            .credentials_provider(creds)
            .region(aws_sdk_s3::config::Region::new(
                region.unwrap_or("us-east-1").to_string(),
            ))
            .force_path_style(true)
            .build();

        let client = aws_sdk_s3::Client::from_conf(config);

        DS3S3Client { client }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Strips surrounding double-quotes from an S3 ETag string.
///
/// Returns `None` if the input is `None`.
pub fn normalize_etag(etag: Option<&str>) -> Option<String> {
    etag.map(|e| e.trim_matches('"').to_string())
}

/// Decodes an S3 URL-encoded key: replaces `+` with space, then
/// percent-decodes the result.
///
/// Matches the Swift `decodeS3Key` implementation.
pub fn decode_s3_key(key: &str) -> Result<String, DS3Error> {
    // S3 encodes spaces as `+` when using encoding-type=url.
    // Replace `+` with `%20` first, then percent-decode.
    let normalized = key.replace('+', "%20");
    let decoded = percent_decode_str(&normalized)
        .decode_utf8()
        .map_err(|_| DS3Error::ParseError)?;
    Ok(decoded.into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_decode_s3_key_replaces_plus_and_percent() {
        let result = decode_s3_key("a+b%20c").unwrap();
        assert_eq!(result, "a b c");
    }

    #[test]
    fn test_decode_s3_key_no_encoding() {
        let result = decode_s3_key("simple/key/file.txt").unwrap();
        assert_eq!(result, "simple/key/file.txt");
    }

    #[test]
    fn test_normalize_etag_strips_quotes() {
        let result = normalize_etag(Some("\"abc123\""));
        assert_eq!(result, Some("abc123".to_string()));
    }

    #[test]
    fn test_normalize_etag_none_input() {
        let result = normalize_etag(None);
        assert_eq!(result, None);
    }

    #[test]
    fn test_client_construction() {
        // Verifies the client constructs without panicking.
        let _client = DS3S3Client::new(
            "https://s3.example.com",
            "test-access-key",
            "test-secret-key",
            Some("us-east-1"),
        );
    }
}
