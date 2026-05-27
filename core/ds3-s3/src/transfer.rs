//! File upload and download operations with progress callbacks.

use std::path::Path;

use crate::client::DS3S3Client;
use ds3_models::DS3Error;

/// Result metadata from a download operation.
pub struct S3DownloadResult {
    /// The object's ETag (normalized, without quotes).
    pub etag: Option<String>,
    /// The MIME content type.
    pub content_type: Option<String>,
    /// When the object was last modified.
    pub last_modified: Option<String>,
    /// Content length in bytes.
    pub content_length: i64,
}

impl DS3S3Client {
    /// Downloads an object to a local file, optionally reporting progress.
    ///
    /// The `on_progress` callback receives `(bytes_written, total_bytes)`.
    pub async fn download_object(
        &self,
        bucket: &str,
        key: &str,
        file_path: &Path,
        on_progress: Option<&(dyn Fn(i64, i64) + Send + Sync)>,
    ) -> Result<S3DownloadResult, DS3Error> {
        todo!("download_object not yet implemented")
    }

    /// Uploads a local file to S3. Automatically uses multipart upload for
    /// files exceeding the [`MULTIPART_THRESHOLD`](crate::MULTIPART_THRESHOLD).
    ///
    /// Returns the ETag of the uploaded object (normalized).
    pub async fn upload_object(
        &self,
        bucket: &str,
        key: &str,
        file_path: &Path,
        on_progress: Option<&(dyn Fn(i64, i64) + Send + Sync)>,
    ) -> Result<Option<String>, DS3Error> {
        todo!("upload_object not yet implemented")
    }
}
