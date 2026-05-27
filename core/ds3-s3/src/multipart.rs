//! Multipart upload with concurrent part uploads and progress callbacks.

use std::path::Path;

use crate::client::DS3S3Client;
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
    todo!("compute_parts not yet implemented")
}

impl DS3S3Client {
    /// Performs a multipart upload with concurrent part uploads.
    ///
    /// Uses [`MULTIPART_CONCURRENCY`](crate::MULTIPART_CONCURRENCY) concurrent
    /// uploads. On any part failure, the multipart upload is aborted.
    pub async fn upload_multipart(
        &self,
        bucket: &str,
        key: &str,
        file_path: &Path,
        total_size: u64,
        on_progress: Option<&(dyn Fn(i64, i64) + Send + Sync)>,
    ) -> Result<String, DS3Error> {
        todo!("upload_multipart not yet implemented")
    }

    /// Aborts an in-progress multipart upload, releasing server-side resources.
    pub async fn abort_multipart_upload(
        &self,
        bucket: &str,
        key: &str,
        upload_id: &str,
    ) -> Result<(), DS3Error> {
        todo!("abort_multipart_upload not yet implemented")
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
