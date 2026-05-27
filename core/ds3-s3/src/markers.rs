//! `.ds3keep` folder marker operations for empty folder support.

use crate::client::{DS3S3Client, DELIMITER, MARKER_FILE_NAME};
use crate::crud::is_not_found_error;
use ds3_models::DS3Error;

/// Computes the marker key for a given folder key.
///
/// - `"folder/"` -> `"folder/.ds3keep"`
/// - `"folder"` -> `"folder/.ds3keep"`
/// - `""` -> `".ds3keep"`
pub fn marker_key(folder_key: &str) -> String {
    if folder_key.is_empty() {
        return MARKER_FILE_NAME.to_string();
    }

    let normalized = if folder_key.ends_with(DELIMITER) {
        folder_key.to_string()
    } else {
        format!("{}{}", folder_key, DELIMITER)
    };

    format!("{}{}", normalized, MARKER_FILE_NAME)
}

/// Returns `true` if the key is a `.ds3keep` marker file.
pub fn is_ds3keep_marker_key(key: &str) -> bool {
    if key == MARKER_FILE_NAME {
        return true;
    }
    key.ends_with(&format!("{}{}", DELIMITER, MARKER_FILE_NAME))
}

impl DS3S3Client {
    /// Checks if a folder marker exists by performing a HeadObject on the marker key.
    pub async fn probe_folder_exists(
        &self,
        bucket: &str,
        folder_key: &str,
    ) -> Result<bool, DS3Error> {
        let key = marker_key(folder_key);
        match self.head_object(bucket, &key).await {
            Ok(_) => Ok(true),
            Err(e) if is_not_found_error(&e) => Ok(false),
            Err(e) => Err(e),
        }
    }

    /// Creates an empty `.ds3keep` marker at the computed marker key.
    pub async fn create_folder_marker(
        &self,
        bucket: &str,
        folder_key: &str,
    ) -> Result<(), DS3Error> {
        let key = marker_key(folder_key);

        self.client
            .put_object()
            .bucket(bucket)
            .key(&key)
            .body(aws_sdk_s3::primitives::ByteStream::from_static(b""))
            .send()
            .await
            .map_err(|e| DS3Error::S3Error(e.to_string()))?;

        Ok(())
    }

    /// Copies a folder marker from one prefix to another.
    /// Falls back to creating a new marker if the source doesn't exist.
    pub async fn copy_folder_marker(
        &self,
        bucket: &str,
        source_folder: &str,
        dest_folder: &str,
    ) -> Result<(), DS3Error> {
        let source = marker_key(source_folder);
        let dest = marker_key(dest_folder);

        match self.copy_object(bucket, &source, &dest, None).await {
            Ok(()) => Ok(()),
            Err(e) if is_not_found_error(&e) => {
                // Source marker doesn't exist; create a fresh one at the destination.
                self.create_folder_marker(bucket, dest_folder).await
            }
            Err(e) => Err(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_marker_key_with_trailing_slash() {
        assert_eq!(marker_key("folder/"), "folder/.ds3keep");
    }

    #[test]
    fn test_marker_key_without_trailing_slash() {
        assert_eq!(marker_key("folder"), "folder/.ds3keep");
    }

    #[test]
    fn test_marker_key_empty_string() {
        assert_eq!(marker_key(""), ".ds3keep");
    }

    #[test]
    fn test_is_ds3keep_marker_key_bare() {
        assert!(is_ds3keep_marker_key(".ds3keep"));
    }

    #[test]
    fn test_is_ds3keep_marker_key_with_path() {
        assert!(is_ds3keep_marker_key("some/path/.ds3keep"));
    }

    #[test]
    fn test_is_ds3keep_marker_key_regular_file() {
        assert!(!is_ds3keep_marker_key("file.txt"));
    }

    #[test]
    fn test_is_ds3keep_marker_key_similar_name() {
        assert!(!is_ds3keep_marker_key("file.ds3keep"));
    }
}
