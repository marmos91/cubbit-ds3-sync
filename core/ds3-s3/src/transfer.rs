//! File upload and download operations with progress callbacks.

use std::path::Path;
use std::sync::Arc;

use aws_sdk_s3::primitives::ByteStream;
use tokio::io::AsyncWriteExt;

use crate::cancel::CancelToken;
use crate::client::{normalize_etag, DS3S3Client, MULTIPART_THRESHOLD};
use ds3_models::{DS3Error, S3DownloadResult};

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
        let response = self
            .client
            .get_object()
            .bucket(bucket)
            .key(key)
            .send()
            .await
            .map_err(|e| DS3Error::S3Error(e.to_string()))?;

        let etag = normalize_etag(response.e_tag());
        let content_type = response.content_type().map(String::from);
        let last_modified = response.last_modified().map(|dt| dt.to_string());
        let content_length = response.content_length().unwrap_or(0);

        let mut body = response.body;
        let mut file = tokio::fs::File::create(file_path)
            .await
            .map_err(|_| DS3Error::UnableToOpenFile)?;

        let mut bytes_written: i64 = 0;

        while let Some(chunk) = body
            .try_next()
            .await
            .map_err(|e| DS3Error::S3Error(e.to_string()))?
        {
            file.write_all(&chunk).await?;
            bytes_written += chunk.len() as i64;

            if let Some(cb) = on_progress {
                cb(bytes_written, content_length);
            }
        }

        file.flush().await?;

        Ok(S3DownloadResult {
            etag,
            content_type,
            last_modified,
            content_length,
        })
    }

    /// Uploads a local file to S3. Automatically uses multipart upload for
    /// files exceeding the [`MULTIPART_THRESHOLD`].
    ///
    /// When `cancel_token` is provided, the multipart loop polls it between
    /// parts and aborts the upload on cancel. Non-multipart single-call uploads
    /// are not cancellable (CONTEXT D-20).
    ///
    /// Returns the ETag of the uploaded object (normalized).
    pub async fn upload_object(
        &self,
        bucket: &str,
        key: &str,
        file_path: &Path,
        on_progress: Option<&(dyn Fn(i64, i64) + Send + Sync)>,
        cancel_token: Option<Arc<dyn CancelToken>>,
    ) -> Result<Option<String>, DS3Error> {
        let metadata = tokio::fs::metadata(file_path).await?;
        let file_size = metadata.len();

        if file_size == 0 {
            // Upload empty body (e.g., folder markers).
            let response = self
                .client
                .put_object()
                .bucket(bucket)
                .key(key)
                .body(ByteStream::from_static(b""))
                .send()
                .await
                .map_err(|e| DS3Error::S3Error(e.to_string()))?;

            return Ok(normalize_etag(response.e_tag()));
        }

        if file_size > MULTIPART_THRESHOLD {
            let etag = self
                .upload_multipart(bucket, key, file_path, file_size, on_progress, cancel_token)
                .await?;
            return Ok(Some(etag));
        }

        // Single-part upload.
        let body = ByteStream::from_path(file_path)
            .await
            .map_err(|e| DS3Error::S3Error(e.to_string()))?;

        let response = self
            .client
            .put_object()
            .bucket(bucket)
            .key(key)
            .content_length(file_size as i64)
            .body(body)
            .send()
            .await
            .map_err(|e| DS3Error::S3Error(e.to_string()))?;

        if let Some(cb) = on_progress {
            cb(file_size as i64, file_size as i64);
        }

        Ok(normalize_etag(response.e_tag()))
    }
}
