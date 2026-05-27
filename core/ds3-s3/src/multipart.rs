//! Multipart upload with concurrent part uploads and progress callbacks.

use std::path::Path;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;

use aws_sdk_s3::primitives::ByteStream;
use aws_sdk_s3::types::{CompletedMultipartUpload, CompletedPart};
use futures::stream::{self, StreamExt};
use tokio::io::{AsyncReadExt, AsyncSeekExt};

use crate::client::{normalize_etag, DS3S3Client, MULTIPART_CONCURRENCY, MULTIPART_PART_SIZE};
use ds3_models::DS3Error;

/// Describes a single part in a multipart upload.
#[derive(Debug, Clone, PartialEq)]
pub struct PartDescriptor {
    /// 1-based part number.
    pub part_number: i32,
    /// Byte offset in the source file.
    pub offset: u64,
    /// Number of bytes in this part.
    pub length: usize,
}

/// Divides a file of `total_size` bytes into parts of `part_size` bytes.
///
/// The last part may be smaller than `part_size`.
pub fn compute_parts(total_size: u64, part_size: usize) -> Vec<PartDescriptor> {
    let mut parts = Vec::new();
    let mut offset: u64 = 0;
    let mut part_number: i32 = 1;

    while offset < total_size {
        let length = (total_size - offset).min(part_size as u64) as usize;

        parts.push(PartDescriptor {
            part_number,
            offset,
            length,
        });

        offset += length as u64;
        part_number += 1;
    }

    parts
}

impl DS3S3Client {
    /// Performs a multipart upload with concurrent part uploads.
    ///
    /// Uses [`MULTIPART_CONCURRENCY`] concurrent uploads. On any part failure,
    /// the multipart upload is aborted.
    pub async fn upload_multipart(
        &self,
        bucket: &str,
        key: &str,
        file_path: &Path,
        total_size: u64,
        on_progress: Option<&(dyn Fn(i64, i64) + Send + Sync)>,
    ) -> Result<String, DS3Error> {
        // Step 1: Create multipart upload.
        let create_response = self
            .client
            .create_multipart_upload()
            .bucket(bucket)
            .key(key)
            .send()
            .await
            .map_err(|e| DS3Error::S3Error(e.to_string()))?;

        let upload_id = create_response
            .upload_id()
            .ok_or(DS3Error::MissingUploadId)?
            .to_string();

        // Step 2: Upload parts concurrently with abort on error.
        let parts = compute_parts(total_size, MULTIPART_PART_SIZE);
        let total = total_size as i64;
        let uploaded_bytes = Arc::new(AtomicI64::new(0));

        let upload_result = self
            .upload_parts(
                bucket,
                key,
                &upload_id,
                file_path,
                &parts,
                total,
                &uploaded_bytes,
                on_progress,
            )
            .await;

        match upload_result {
            Ok(completed_parts) => {
                // Step 3: Complete multipart upload.
                let mut sorted = completed_parts;
                sorted.sort_by_key(|p| p.part_number());

                let completed = CompletedMultipartUpload::builder()
                    .set_parts(Some(sorted))
                    .build();

                let complete_response = self
                    .client
                    .complete_multipart_upload()
                    .bucket(bucket)
                    .key(key)
                    .upload_id(&upload_id)
                    .multipart_upload(completed)
                    .send()
                    .await
                    .map_err(|e| DS3Error::S3Error(e.to_string()))?;

                let etag = normalize_etag(complete_response.e_tag())
                    .ok_or(DS3Error::MissingETag)?;

                Ok(etag)
            }
            Err(e) => {
                // Abort on error -- ignore abort failures.
                let _ = self
                    .abort_multipart_upload(bucket, key, &upload_id)
                    .await;
                Err(e)
            }
        }
    }

    /// Uploads parts with bounded concurrency, returning completed parts.
    #[allow(clippy::too_many_arguments)]
    async fn upload_parts(
        &self,
        bucket: &str,
        key: &str,
        upload_id: &str,
        file_path: &Path,
        parts: &[PartDescriptor],
        total: i64,
        uploaded_bytes: &Arc<AtomicI64>,
        on_progress: Option<&(dyn Fn(i64, i64) + Send + Sync)>,
    ) -> Result<Vec<CompletedPart>, DS3Error> {
        let mut stream = stream::iter(parts.iter().cloned())
            .map(|part| {
                let bucket = bucket.to_string();
                let key = key.to_string();
                let upload_id = upload_id.to_string();
                let file_path = file_path.to_path_buf();
                let uploaded = Arc::clone(uploaded_bytes);

                async move {
                    let mut file = tokio::fs::File::open(&file_path)
                        .await
                        .map_err(|_| DS3Error::UnableToOpenFile)?;

                    file.seek(std::io::SeekFrom::Start(part.offset)).await?;
                    let mut buf = vec![0u8; part.length];
                    file.read_exact(&mut buf).await?;

                    let body = ByteStream::from(buf);

                    let response = self
                        .client
                        .upload_part()
                        .bucket(&bucket)
                        .key(&key)
                        .upload_id(&upload_id)
                        .part_number(part.part_number)
                        .content_length(part.length as i64)
                        .body(body)
                        .send()
                        .await
                        .map_err(|e| DS3Error::S3Error(e.to_string()))?;

                    let etag = response.e_tag().ok_or(DS3Error::MissingETag)?.to_string();

                    uploaded.fetch_add(part.length as i64, Ordering::Relaxed);

                    Ok::<_, DS3Error>(CompletedPart::builder()
                        .part_number(part.part_number)
                        .e_tag(etag)
                        .build())
                }
            })
            .buffer_unordered(MULTIPART_CONCURRENCY);

        let mut completed = Vec::with_capacity(parts.len());
        while let Some(result) = stream.next().await {
            completed.push(result?);
            if let Some(cb) = on_progress {
                cb(uploaded_bytes.load(Ordering::Relaxed), total);
            }
        }

        Ok(completed)
    }

    /// Aborts an in-progress multipart upload, releasing server-side resources.
    pub async fn abort_multipart_upload(
        &self,
        bucket: &str,
        key: &str,
        upload_id: &str,
    ) -> Result<(), DS3Error> {
        self.client
            .abort_multipart_upload()
            .bucket(bucket)
            .key(key)
            .upload_id(upload_id)
            .send()
            .await
            .map_err(|e| DS3Error::S3Error(e.to_string()))?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compute_parts_12mb() {
        let part_size = 5 * 1024 * 1024; // 5 MB
        let total_size = 12 * 1024 * 1024; // 12 MB
        let parts = compute_parts(total_size, part_size);
        assert_eq!(parts.len(), 3);

        assert_eq!(parts[0].part_number, 1);
        assert_eq!(parts[0].offset, 0);
        assert_eq!(parts[0].length, 5 * 1024 * 1024);

        assert_eq!(parts[1].part_number, 2);
        assert_eq!(parts[1].offset, 5 * 1024 * 1024);
        assert_eq!(parts[1].length, 5 * 1024 * 1024);

        assert_eq!(parts[2].part_number, 3);
        assert_eq!(parts[2].offset, 10 * 1024 * 1024);
        assert_eq!(parts[2].length, 2 * 1024 * 1024);
    }

    #[test]
    fn test_compute_parts_4mb_single_part() {
        let part_size = 5 * 1024 * 1024;
        let total_size = 4 * 1024 * 1024;
        let parts = compute_parts(total_size, part_size);
        assert_eq!(parts.len(), 1);
        assert_eq!(parts[0].part_number, 1);
        assert_eq!(parts[0].offset, 0);
        assert_eq!(parts[0].length, 4 * 1024 * 1024);
    }

    #[test]
    fn test_compute_parts_exactly_5mb() {
        let part_size = 5 * 1024 * 1024;
        let total_size = 5 * 1024 * 1024;
        let parts = compute_parts(total_size, part_size);
        assert_eq!(parts.len(), 1);
        assert_eq!(parts[0].part_number, 1);
        assert_eq!(parts[0].offset, 0);
        assert_eq!(parts[0].length, 5 * 1024 * 1024);
    }
}
