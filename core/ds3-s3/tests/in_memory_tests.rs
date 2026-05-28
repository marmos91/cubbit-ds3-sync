//! Integration tests for in-memory upload/download against real Cubbit S3.
//!
//! These tests cover the new FFI surface added in Phase 16 Plan 02:
//! - `download_to_memory(bucket, key) -> Vec<u8>`
//! - `upload_from_memory(bucket, key, data, metadata) -> Option<String>`
//! - `copy_object` with `metadata = Some(...)` (REPLACE directive)
//!
//! Gated behind `#[cfg(feature = "integration")]` -- run with:
//!     cargo test -p ds3-s3 --features integration --test in_memory_tests
//!
//! Required environment variables (matching tests/integration.rs):
//! - DS3_TEST_EMAIL, DS3_TEST_PASSWORD, DS3_TEST_BUCKET
//!
//! ## Retry policy (D-18 + RESEARCH A2/A3 decision log)
//!
//! aws-sdk-s3 v1.x applies its own retry strategy when `behavior_version_latest()`
//! is set (verified in `client.rs::new`). The `MAX_RETRIES = 5` constant is now
//! explicitly applied via `.retry_config(RetryConfig::standard().with_max_attempts(MAX_RETRIES))`
//! on the client builder so the SDK retries up to 5 times on transient failures
//! (5xx, 429, connection resets) — matching the original Soto `DefaultSettings.S3.maxRetries`.
//!
//! The reqwest layer (`ds3-http`) retry is wired separately in Task 3 of this plan
//! via `reqwest-retry` middleware.

#![cfg(feature = "integration")]

use std::collections::HashMap;
use std::io::Write;
use ds3_s3::DS3S3Client;
use uuid::Uuid;

fn env_or_skip(name: &str) -> String {
    match std::env::var(name) {
        Ok(val) if !val.is_empty() => val,
        _ => {
            eprintln!("Skipping: {name} not set");
            std::process::exit(0);
        }
    }
}

fn test_prefix() -> String {
    format!("ds3-test-mem-{}/", Uuid::new_v4())
}

async fn create_test_client() -> (DS3S3Client, String) {
    let email = env_or_skip("DS3_TEST_EMAIL");
    let password = env_or_skip("DS3_TEST_PASSWORD");
    let bucket = env_or_skip("DS3_TEST_BUCKET");

    let session = ds3_auth::DS3Session::authenticate(&email, &password, None, None)
        .await
        .expect("authenticate should succeed");

    let endpoint = &session.account.endpoint_gateway;

    let iam_token = session
        .forge_iam_token(&session.account.id)
        .await
        .expect("forge_iam_token should succeed");

    let keys = ds3_http::keys::load_api_keys(
        &session.http,
        &session.urls,
        &iam_token.token,
        &session.account.id,
    )
    .await
    .expect("load_api_keys should succeed");

    let api_key = if let Some(key) = keys.first() {
        key.clone()
    } else {
        ds3_http::keys::create_api_key(
            &session.http,
            &session.urls,
            &iam_token.token,
            &session.account.id,
            "ds3-rust-integration-test",
        )
        .await
        .expect("create_api_key should succeed")
    };

    let access_key = api_key.api_key;
    let secret_key = api_key
        .secret_key
        .expect("API key must have a secret");

    let client = DS3S3Client::new(endpoint, &access_key, &secret_key, None);
    (client, bucket)
}

fn temp_file(content: &[u8]) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join("ds3-integration");
    std::fs::create_dir_all(&dir).expect("create temp dir");
    let path = dir.join(format!("{}.tmp", Uuid::new_v4()));
    let mut f = std::fs::File::create(&path).expect("create temp file");
    f.write_all(content).expect("write temp file");
    path
}

// ---------------------------------------------------------------------------
// download_to_memory
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_download_to_memory_returns_bytes_for_existing_key() {
    let (client, bucket) = create_test_client().await;
    let prefix = test_prefix();
    let key = format!("{prefix}dl-mem.txt");
    let content = b"download-to-memory payload";

    // Seed via upload_object
    let upload_path = temp_file(content);
    client
        .upload_object(&bucket, &key, &upload_path, None)
        .await
        .expect("upload should succeed");

    let bytes = client
        .download_to_memory(&bucket, &key)
        .await
        .expect("download_to_memory should succeed");

    assert_eq!(bytes, content.to_vec());

    // Cleanup
    let _ = client.delete_object(&bucket, &key).await;
    let _ = std::fs::remove_file(&upload_path);
}

#[tokio::test]
async fn test_download_to_memory_returns_error_for_missing_key() {
    let (client, bucket) = create_test_client().await;
    let prefix = test_prefix();
    let key = format!("{prefix}does-not-exist.bin");

    let result = client.download_to_memory(&bucket, &key).await;

    assert!(result.is_err(), "missing key should return an error");
    let err_str = format!("{:?}", result.unwrap_err()).to_lowercase();
    assert!(
        err_str.contains("nosuchkey") || err_str.contains("not found") || err_str.contains("404"),
        "expected NoSuchKey-style error, got: {err_str}"
    );
}

// ---------------------------------------------------------------------------
// upload_from_memory
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_upload_from_memory_writes_bytes_and_returns_etag() {
    let (client, bucket) = create_test_client().await;
    let prefix = test_prefix();
    let key = format!("{prefix}ul-mem.txt");
    let payload = b"upload-from-memory payload".to_vec();

    let etag = client
        .upload_from_memory(&bucket, &key, payload.clone(), HashMap::new())
        .await
        .expect("upload_from_memory should succeed");

    assert!(etag.is_some(), "upload_from_memory should return an ETag");

    // Round-trip via download_to_memory
    let downloaded = client
        .download_to_memory(&bucket, &key)
        .await
        .expect("download should succeed");
    assert_eq!(downloaded, payload);

    let _ = client.delete_object(&bucket, &key).await;
}

#[tokio::test]
async fn test_upload_from_memory_with_metadata_persists_custom_headers() {
    let (client, bucket) = create_test_client().await;
    let prefix = test_prefix();
    let key = format!("{prefix}ul-mem-meta.txt");

    let mut metadata = HashMap::new();
    metadata.insert("custom-tag".to_string(), "v1".to_string());
    metadata.insert("origin".to_string(), "ds3-rust".to_string());

    client
        .upload_from_memory(&bucket, &key, b"with-meta".to_vec(), metadata.clone())
        .await
        .expect("upload should succeed");

    let head = client
        .head_object(&bucket, &key)
        .await
        .expect("head should succeed");

    let returned = head.metadata.expect("head should return metadata");
    assert_eq!(returned.get("custom-tag").map(String::as_str), Some("v1"));
    assert_eq!(returned.get("origin").map(String::as_str), Some("ds3-rust"));

    let _ = client.delete_object(&bucket, &key).await;
}

#[tokio::test]
async fn test_upload_from_memory_empty_vec_writes_zero_byte_object() {
    let (client, bucket) = create_test_client().await;
    let prefix = test_prefix();
    let key = format!("{prefix}.ds3keep");

    let etag = client
        .upload_from_memory(&bucket, &key, Vec::new(), HashMap::new())
        .await
        .expect("zero-byte upload should succeed");

    assert!(etag.is_some(), "etag should be returned for zero-byte object");

    let head = client.head_object(&bucket, &key).await.expect("head should succeed");
    assert_eq!(head.content_length, 0);

    let _ = client.delete_object(&bucket, &key).await;
}

// ---------------------------------------------------------------------------
// copy_object metadata REPLACE
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_copy_object_with_metadata_some_sets_replace_directive() {
    let (client, bucket) = create_test_client().await;
    let prefix = test_prefix();
    let src = format!("{prefix}src.txt");
    let dst = format!("{prefix}dst.txt");

    // Seed src with old metadata
    let mut old_meta = HashMap::new();
    old_meta.insert("version".to_string(), "old".to_string());
    client
        .upload_from_memory(&bucket, &src, b"payload".to_vec(), old_meta)
        .await
        .expect("seed upload should succeed");

    // Copy with new metadata
    let mut new_meta = HashMap::new();
    new_meta.insert("version".to_string(), "new".to_string());
    client
        .copy_object(&bucket, &src, &dst, Some(&new_meta))
        .await
        .expect("copy with metadata should succeed");

    let head = client
        .head_object(&bucket, &dst)
        .await
        .expect("head dst should succeed");
    let returned = head.metadata.expect("dst should have metadata");
    assert_eq!(returned.get("version").map(String::as_str), Some("new"));

    let _ = client.delete_object(&bucket, &src).await;
    let _ = client.delete_object(&bucket, &dst).await;
}

#[tokio::test]
async fn test_copy_object_with_metadata_none_preserves_existing() {
    let (client, bucket) = create_test_client().await;
    let prefix = test_prefix();
    let src = format!("{prefix}src2.txt");
    let dst = format!("{prefix}dst2.txt");

    let mut meta = HashMap::new();
    meta.insert("preserved".to_string(), "yes".to_string());
    client
        .upload_from_memory(&bucket, &src, b"payload".to_vec(), meta)
        .await
        .expect("seed should succeed");

    client
        .copy_object(&bucket, &src, &dst, None)
        .await
        .expect("copy without metadata override should succeed");

    let head = client.head_object(&bucket, &dst).await.expect("head should succeed");
    let returned = head.metadata.expect("dst should have metadata (copied)");
    assert_eq!(returned.get("preserved").map(String::as_str), Some("yes"));

    let _ = client.delete_object(&bucket, &src).await;
    let _ = client.delete_object(&bucket, &dst).await;
}
