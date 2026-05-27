//! S3 CRUD operations: head, delete, batch delete, copy.

use std::collections::HashMap;

use crate::client::DS3S3Client;
use ds3_models::{DS3Error, S3ObjectMetadata};

impl DS3S3Client {
    /// Retrieves metadata for an object without downloading its body.
    pub async fn head_object(
        &self,
        bucket: &str,
        key: &str,
    ) -> Result<S3ObjectMetadata, DS3Error> {
        todo!("head_object not yet implemented")
    }

    /// Deletes a single object from the bucket.
    pub async fn delete_object(&self, bucket: &str, key: &str) -> Result<(), DS3Error> {
        todo!("delete_object not yet implemented")
    }

    /// Deletes multiple objects in a single batch request.
    ///
    /// Returns the number of successfully deleted objects.
    pub async fn delete_objects(
        &self,
        bucket: &str,
        keys: &[String],
    ) -> Result<usize, DS3Error> {
        todo!("delete_objects not yet implemented")
    }

    /// Copies an object within the same bucket.
    ///
    /// Optionally replaces metadata on the copy.
    pub async fn copy_object(
        &self,
        bucket: &str,
        source_key: &str,
        dest_key: &str,
        metadata: Option<&HashMap<String, String>>,
    ) -> Result<(), DS3Error> {
        todo!("copy_object not yet implemented")
    }
}

/// Returns `true` if the given error indicates S3 NotFound (NoSuchKey / 404).
pub fn is_not_found_error(err: &DS3Error) -> bool {
    todo!("is_not_found_error not yet implemented")
}
