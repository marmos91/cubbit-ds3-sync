//! S3 CRUD operations: head, delete, batch delete, copy.

use std::collections::HashMap;

use aws_sdk_s3::types::{Delete, MetadataDirective, ObjectIdentifier};

use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};

use crate::client::{normalize_etag, DS3S3Client};
use ds3_models::{DS3Error, S3ObjectMetadata};

const COPY_SOURCE_ENCODE_SET: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'_')
    .remove(b'.')
    .remove(b'~')
    .remove(b'/');

impl DS3S3Client {
    /// Retrieves metadata for an object without downloading its body.
    pub async fn head_object(
        &self,
        bucket: &str,
        key: &str,
    ) -> Result<S3ObjectMetadata, DS3Error> {
        let response = self
            .client
            .head_object()
            .bucket(bucket)
            .key(key)
            .send()
            .await
            .map_err(|e| DS3Error::S3Error(e.to_string()))?;

        Ok(S3ObjectMetadata {
            etag: normalize_etag(response.e_tag()),
            content_type: response.content_type().map(String::from),
            last_modified: response.last_modified().map(|dt| dt.to_string()),
            version_id: response.version_id().map(String::from),
            content_length: response.content_length().unwrap_or(0),
            metadata: response
                .metadata()
                .map(|m| m.iter().map(|(k, v)| (k.clone(), v.clone())).collect()),
        })
    }

    /// Deletes a single object from the bucket.
    pub async fn delete_object(&self, bucket: &str, key: &str) -> Result<(), DS3Error> {
        self.client
            .delete_object()
            .bucket(bucket)
            .key(key)
            .send()
            .await
            .map_err(|e| DS3Error::S3Error(e.to_string()))?;

        Ok(())
    }

    /// Deletes multiple objects in a single batch request.
    ///
    /// Returns the number of successfully deleted objects.
    pub async fn delete_objects(
        &self,
        bucket: &str,
        keys: &[String],
    ) -> Result<usize, DS3Error> {
        if keys.is_empty() {
            return Ok(0);
        }

        let objects: Vec<ObjectIdentifier> = keys
            .iter()
            .map(|k| ObjectIdentifier::builder().key(k).build())
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| DS3Error::S3Error(e.to_string()))?;

        let delete = Delete::builder()
            .set_objects(Some(objects))
            .quiet(true)
            .build()
            .map_err(|e| DS3Error::S3Error(e.to_string()))?;

        let response = self
            .client
            .delete_objects()
            .bucket(bucket)
            .delete(delete)
            .send()
            .await
            .map_err(|e| DS3Error::S3Error(e.to_string()))?;

        // In quiet mode, only errors are returned. Count successes as
        // total requested minus errors.
        let error_count = response.errors().len();
        Ok(keys.len() - error_count)
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
        let encoded_key = utf8_percent_encode(source_key, COPY_SOURCE_ENCODE_SET).to_string();
        let copy_source = format!("{}/{}", bucket, encoded_key);

        let mut req = self
            .client
            .copy_object()
            .bucket(bucket)
            .copy_source(&copy_source)
            .key(dest_key);

        if let Some(meta) = metadata {
            req = req.metadata_directive(MetadataDirective::Replace);
            for (k, v) in meta {
                req = req.metadata(k, v);
            }
        }

        req.send()
            .await
            .map_err(|e| DS3Error::S3Error(e.to_string()))?;

        Ok(())
    }
}

/// Returns `true` if the given error indicates S3 NotFound (NoSuchKey / 404).
pub fn is_not_found_error(err: &DS3Error) -> bool {
    match err {
        DS3Error::S3Error(msg) => {
            let lower = msg.to_lowercase();
            lower.contains("nosuchkey")
                || lower.contains("notfound")
                || lower.contains("not found")
                || lower.contains("404")
                || lower.contains("no such key")
                || lower.contains("does not exist")
        }
        _ => false,
    }
}
