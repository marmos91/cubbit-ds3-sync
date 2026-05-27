//! `.ds3keep` folder marker operations for empty folder support.

use crate::client::{DS3S3Client, MARKER_FILE_NAME};
use ds3_models::DS3Error;

/// Computes the marker key for a given folder key.
///
/// - `"folder/"` -> `"folder/.ds3keep"`
/// - `"folder"` -> `"folder/.ds3keep"`
/// - `""` -> `".ds3keep"`
pub fn marker_key(folder_key: &str) -> String {
    todo!("marker_key not yet implemented")
}

/// Returns `true` if the key is a `.ds3keep` marker file.
pub fn is_ds3keep_marker_key(key: &str) -> bool {
    todo!("is_ds3keep_marker_key not yet implemented")
}

impl DS3S3Client {
    /// Checks if a folder marker exists by performing a HeadObject on the marker key.
    pub async fn probe_folder_exists(
        &self,
        bucket: &str,
        folder_key: &str,
    ) -> Result<bool, DS3Error> {
        todo!("probe_folder_exists not yet implemented")
    }

    /// Creates an empty `.ds3keep` marker at the computed marker key.
    pub async fn create_folder_marker(
        &self,
        bucket: &str,
        folder_key: &str,
    ) -> Result<(), DS3Error> {
        todo!("create_folder_marker not yet implemented")
    }

    /// Copies a folder marker from one prefix to another.
    /// Falls back to creating a new marker if the source doesn't exist.
    pub async fn copy_folder_marker(
        &self,
        bucket: &str,
        source_folder: &str,
        dest_folder: &str,
    ) -> Result<(), DS3Error> {
        todo!("copy_folder_marker not yet implemented")
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
