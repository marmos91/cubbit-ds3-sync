//! S3 CRUD operations: head, delete, batch delete, copy, in-memory transfers.

use std::collections::HashMap;

use aws_sdk_s3::primitives::ByteStream;
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
    pub async fn head_object(&self, bucket: &str, key: &str) -> Result<S3ObjectMetadata, DS3Error> {
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
    pub async fn delete_objects(&self, bucket: &str, keys: &[String]) -> Result<usize, DS3Error> {
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

    /// Downloads an object to an in-memory `Vec<u8>` (no temp file).
    ///
    /// Intended for small payloads where streaming to disk is unnecessary
    /// (e.g. thumbnails, .ds3keep markers, JSON metadata blobs).
    pub async fn download_to_memory(
        &self,
        bucket: &str,
        key: &str,
    ) -> Result<Vec<u8>, DS3Error> {
        let response = self
            .client
            .get_object()
            .bucket(bucket)
            .key(key)
            .send()
            .await
            .map_err(|e| DS3Error::S3Error(e.to_string()))?;

        let bytes = response
            .body
            .collect()
            .await
            .map_err(|e| DS3Error::S3Error(e.to_string()))?
            .into_bytes();

        Ok(bytes.to_vec())
    }

    /// Uploads an in-memory `Vec<u8>` to S3 with optional custom metadata.
    ///
    /// `metadata` keys/values are sent as `x-amz-meta-*` headers. Empty `data`
    /// produces a zero-byte object (used for `.ds3keep` folder markers).
    /// Returns the normalized ETag on success.
    ///
    /// Metadata keys are validated to be ASCII without control characters
    /// (HTTP header safe — threat T-16-02-02).
    pub async fn upload_from_memory(
        &self,
        bucket: &str,
        key: &str,
        data: Vec<u8>,
        metadata: HashMap<String, String>,
    ) -> Result<Option<String>, DS3Error> {
        for (k, v) in &metadata {
            validate_metadata_key(k)?;
            validate_metadata_value(v)?;
        }

        let mut req = self
            .client
            .put_object()
            .bucket(bucket)
            .key(key)
            .content_length(data.len() as i64)
            .body(ByteStream::from(data));

        for (k, v) in &metadata {
            req = req.metadata(k, v);
        }

        let response = req
            .send()
            .await
            .map_err(|e| DS3Error::S3Error(e.to_string()))?;

        Ok(normalize_etag(response.e_tag()))
    }
}

/// Validates an S3 custom-metadata key against HTTP-header restrictions.
///
/// S3 sends user metadata as `x-amz-meta-<key>` HTTP headers. Keys must be
/// ASCII and free of control characters (CR/LF/NUL) to prevent header
/// injection (threat T-16-02-02).
fn validate_metadata_key(key: &str) -> Result<(), DS3Error> {
    if key.is_empty() {
        return Err(DS3Error::S3Error("invalid metadata key: empty".into()));
    }
    if !key.is_ascii() {
        return Err(DS3Error::S3Error(
            "invalid metadata key: non-ASCII".into(),
        ));
    }
    if key.chars().any(|c| c.is_control() || c == ':' || c == ' ') {
        return Err(DS3Error::S3Error(
            "invalid metadata key: control or separator char".into(),
        ));
    }
    Ok(())
}

/// Validates an S3 custom-metadata value against HTTP-header restrictions.
fn validate_metadata_value(value: &str) -> Result<(), DS3Error> {
    if !value.is_ascii() {
        return Err(DS3Error::S3Error(
            "invalid metadata value: non-ASCII".into(),
        ));
    }
    if value
        .chars()
        .any(|c| c == '\r' || c == '\n' || c == '\0')
    {
        return Err(DS3Error::S3Error(
            "invalid metadata value: control char".into(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod metadata_validation_tests {
    use super::*;

    #[test]
    fn rejects_empty_metadata_key() {
        assert!(validate_metadata_key("").is_err());
    }

    #[test]
    fn rejects_non_ascii_metadata_key() {
        assert!(validate_metadata_key("kéy").is_err());
    }

    #[test]
    fn rejects_metadata_key_with_crlf() {
        assert!(validate_metadata_key("k\r\n").is_err());
    }

    #[test]
    fn rejects_metadata_key_with_colon() {
        assert!(validate_metadata_key("k:v").is_err());
    }

    #[test]
    fn accepts_normal_metadata_key() {
        assert!(validate_metadata_key("custom-tag").is_ok());
        assert!(validate_metadata_key("origin_id").is_ok());
    }

    #[test]
    fn rejects_metadata_value_with_newline() {
        assert!(validate_metadata_value("v\nattack").is_err());
    }

    #[test]
    fn accepts_normal_metadata_value() {
        assert!(validate_metadata_value("v1").is_ok());
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
