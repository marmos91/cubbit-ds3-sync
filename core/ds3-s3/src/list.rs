//! S3 listing operations (ListObjectsV2, ListBuckets).

use crate::client::{decode_s3_key, normalize_etag, DS3S3Client, LIST_BATCH_SIZE};
use ds3_models::{DS3Error, S3ListingResult, S3ObjectSummary};

impl DS3S3Client {
    /// Lists objects in a bucket with optional prefix, delimiter, and pagination.
    ///
    /// Keys in the response are URL-decoded (+ to space, percent-decoding)
    /// because we request `encoding_type = url` from S3.
    pub async fn list_objects(
        &self,
        bucket: &str,
        prefix: Option<&str>,
        delimiter: Option<&str>,
        max_keys: Option<i32>,
        continuation_token: Option<&str>,
    ) -> Result<S3ListingResult, DS3Error> {
        let mut req = self
            .client
            .list_objects_v2()
            .bucket(bucket)
            .max_keys(max_keys.unwrap_or(LIST_BATCH_SIZE))
            .encoding_type(aws_sdk_s3::types::EncodingType::Url);

        if let Some(p) = prefix {
            req = req.prefix(p);
        }
        if let Some(d) = delimiter {
            req = req.delimiter(d);
        }
        if let Some(t) = continuation_token {
            req = req.continuation_token(t);
        }

        let response = req
            .send()
            .await
            .map_err(|e| DS3Error::S3Error(e.to_string()))?;

        let objects = response
            .contents()
            .iter()
            .filter_map(|obj| {
                let raw_key = obj.key()?;
                let key = decode_s3_key(raw_key).ok()?;
                Some(S3ObjectSummary {
                    key,
                    etag: normalize_etag(obj.e_tag()),
                    last_modified: obj.last_modified().map(|dt| dt.to_string()),
                    size: obj.size().unwrap_or(0),
                })
            })
            .collect();

        let common_prefixes = response
            .common_prefixes()
            .iter()
            .filter_map(|cp| {
                let raw = cp.prefix()?;
                decode_s3_key(raw).ok()
            })
            .collect();

        let next_continuation_token = response.next_continuation_token().map(String::from);
        let is_truncated = response.is_truncated().unwrap_or(false);

        Ok(S3ListingResult {
            objects,
            common_prefixes,
            next_continuation_token,
            is_truncated,
        })
    }

    /// Lists all buckets accessible with the current credentials.
    ///
    /// Returns a vector of `(name, creation_date)` pairs.
    pub async fn list_buckets(&self) -> Result<Vec<(String, Option<String>)>, DS3Error> {
        let response = self
            .client
            .list_buckets()
            .send()
            .await
            .map_err(|e| DS3Error::S3Error(e.to_string()))?;

        let buckets = response
            .buckets()
            .iter()
            .map(|b| {
                let name = b.name().unwrap_or("<No name>").to_string();
                let creation_date = b.creation_date().map(|d| d.to_string());
                (name, creation_date)
            })
            .collect();

        Ok(buckets)
    }
}
