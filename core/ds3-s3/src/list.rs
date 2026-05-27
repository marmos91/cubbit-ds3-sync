//! S3 listing operations (ListObjectsV2, ListBuckets).

use crate::client::DS3S3Client;
use ds3_models::{DS3Error, S3ListingResult};

impl DS3S3Client {
    /// Lists objects in a bucket with optional prefix, delimiter, and pagination.
    ///
    /// Keys in the response are URL-decoded (+ to space, percent-decoding).
    pub async fn list_objects(
        &self,
        bucket: &str,
        prefix: Option<&str>,
        delimiter: Option<&str>,
        max_keys: Option<i32>,
        continuation_token: Option<&str>,
    ) -> Result<S3ListingResult, DS3Error> {
        todo!("list_objects not yet implemented")
    }

    /// Lists all buckets accessible with the current credentials.
    ///
    /// Returns a vector of `(name, creation_date)` pairs.
    pub async fn list_buckets(&self) -> Result<Vec<(String, Option<String>)>, DS3Error> {
        todo!("list_buckets not yet implemented")
    }
}
