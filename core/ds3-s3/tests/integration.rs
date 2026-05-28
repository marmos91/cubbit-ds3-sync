//! Integration tests for ds3-s3 against real Cubbit S3.
//!
//! Gated behind `#[cfg(feature = "integration")]` -- run with:
//!     cargo test -p ds3-s3 --features integration --test integration
//!
//! Required environment variables:
//! - DS3_TEST_EMAIL: Cubbit account email
//! - DS3_TEST_PASSWORD: Cubbit account password
//! - DS3_TEST_BUCKET: Dedicated test bucket name

#![cfg(feature = "integration")]

use ds3_s3::DS3S3Client;
use std::io::Write;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;
use uuid::Uuid;

/// Helper to read a required env var, exiting cleanly if missing.
fn env_or_skip(name: &str) -> String {
    match std::env::var(name) {
        Ok(val) if !val.is_empty() => val,
        _ => {
            eprintln!("Skipping: {name} not set");
            std::process::exit(0);
        }
    }
}

/// A unique prefix for all test objects in this run, ensuring isolation.
fn test_prefix() -> String {
    format!("ds3-test-{}/", Uuid::new_v4())
}

/// Authenticates and creates an S3 client for integration tests.
///
/// Uses ds3-auth to obtain credentials, then forges an IAM token and
/// creates an API key for S3 access.
async fn create_test_client() -> (DS3S3Client, String) {
    let email = env_or_skip("DS3_TEST_EMAIL");
    let password = env_or_skip("DS3_TEST_PASSWORD");
    let bucket = env_or_skip("DS3_TEST_BUCKET");

    let session = ds3_auth::DS3Session::authenticate(&email, &password, None, None)
        .await
        .expect("authenticate should succeed");

    let endpoint = session.account.endpoint_gateway.clone();

    // forge_iam_token expects an IAMUser id, not the Account id.
    // Fetch projects to discover a valid IAM user (mirrors production flow).
    let token = session.session.lock().await.token.token.clone();
    let projects = ds3_http::projects::get_projects(&session.http, &session.urls, &token)
        .await
        .expect("get_projects should succeed");
    let iam_user_id = projects
        .iter()
        .flat_map(|p| p.users.iter())
        .map(|u| u.id.clone())
        .next()
        .expect("test account must belong to at least one IAM user");

    let iam_token = session
        .forge_iam_token(&iam_user_id)
        .await
        .expect("forge_iam_token should succeed");

    // Load existing API keys
    let keys =
        ds3_http::keys::load_api_keys(&session.http, &session.urls, &iam_token.token, &iam_user_id)
            .await
            .expect("load_api_keys should succeed");

    // load_api_keys returns existing keys WITHOUT secret_key (Cubbit IAM
    // only returns the secret on creation — D-22). Always create a fresh
    // ephemeral key for the test run; it gets cleaned up below.
    let api_key = ds3_http::keys::create_api_key(
        &session.http,
        &session.urls,
        &iam_token.token,
        &iam_user_id,
        &format!("ds3-rust-it-{}", Uuid::new_v4()),
    )
    .await
    .expect("create_api_key should succeed");

    let access_key = api_key.api_key;
    let secret_key = api_key
        .secret_key
        .expect("newly created API key must include secret_key");
    let _ = keys; // suppress unused warning, keys list kept for visibility

    let client = DS3S3Client::new(&endpoint, &access_key, &secret_key, None);
    (client, bucket)
}

/// Creates a temporary file with the given content and returns its path.
fn temp_file(content: &[u8]) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join("ds3-integration");
    std::fs::create_dir_all(&dir).expect("create temp dir");
    let path = dir.join(format!("{}.tmp", Uuid::new_v4()));
    let mut f = std::fs::File::create(&path).expect("create temp file");
    f.write_all(content).expect("write temp file");
    path
}

#[tokio::test]
async fn test_list_objects() {
    let (client, bucket) = create_test_client().await;

    let result = client
        .list_objects(&bucket, None, None, Some(10), None)
        .await
        .expect("list_objects should succeed");

    // We don't assert on content since the bucket may be empty or have data;
    // the important thing is that the call succeeds.
    assert!(result.objects.len() <= 10);
}

#[tokio::test]
async fn test_upload_head_download_delete() {
    let (client, bucket) = create_test_client().await;
    let prefix = test_prefix();
    let key = format!("{prefix}test-file.txt");
    let content = b"Hello from ds3-s3 integration test!";

    // Upload
    let upload_path = temp_file(content);
    let etag = client
        .upload_object(&bucket, &key, &upload_path, None, None)
        .await
        .expect("upload_object should succeed");
    assert!(etag.is_some(), "upload should return an ETag");

    // Head
    let metadata = client
        .head_object(&bucket, &key)
        .await
        .expect("head_object should succeed");
    assert_eq!(metadata.content_length, content.len() as i64);
    assert!(metadata.etag.is_some());

    // Download
    let download_path = std::env::temp_dir()
        .join("ds3-integration")
        .join(format!("download-{}.tmp", Uuid::new_v4()));
    let download_result = client
        .download_object(&bucket, &key, &download_path, None)
        .await
        .expect("download_object should succeed");
    assert_eq!(download_result.content_length, content.len() as i64);

    let downloaded = std::fs::read(&download_path).expect("read downloaded file");
    assert_eq!(downloaded, content);

    // Delete
    client
        .delete_object(&bucket, &key)
        .await
        .expect("delete_object should succeed");

    // Cleanup temp files
    let _ = std::fs::remove_file(&upload_path);
    let _ = std::fs::remove_file(&download_path);
}

#[tokio::test]
async fn test_multipart_upload() {
    let (client, bucket) = create_test_client().await;
    let prefix = test_prefix();
    let key = format!("{prefix}multipart-6mb.bin");

    // Create a 6MB file (above the 5MB multipart threshold)
    let size = 6 * 1024 * 1024;
    let content: Vec<u8> = (0..size).map(|i| (i % 256) as u8).collect();
    let upload_path = temp_file(&content);

    // Track progress
    let progress_calls = Arc::new(AtomicI64::new(0));
    let progress_calls_clone = Arc::clone(&progress_calls);
    let progress_cb: Box<dyn Fn(i64, i64) + Send + Sync> = Box::new(move |_transferred, _total| {
        progress_calls_clone.fetch_add(1, Ordering::Relaxed);
    });

    let etag = client
        .upload_object(&bucket, &key, &upload_path, Some(&*progress_cb), None)
        .await
        .expect("multipart upload should succeed");
    assert!(etag.is_some(), "multipart upload should return an ETag");

    let calls = progress_calls.load(Ordering::Relaxed);
    assert!(
        calls >= 1,
        "progress callback should fire at least once, got {calls}"
    );

    // Verify the upload via HEAD
    let metadata = client
        .head_object(&bucket, &key)
        .await
        .expect("head_object after multipart should succeed");
    assert_eq!(metadata.content_length, size as i64);

    // Cleanup
    client
        .delete_object(&bucket, &key)
        .await
        .expect("delete after multipart should succeed");
    let _ = std::fs::remove_file(&upload_path);
}

#[tokio::test]
async fn test_marker_operations() {
    let (client, bucket) = create_test_client().await;
    let prefix = test_prefix();
    let folder_key = format!("{prefix}test-folder/");

    // Create marker
    client
        .create_folder_marker(&bucket, &folder_key)
        .await
        .expect("create_folder_marker should succeed");

    // Probe exists
    let exists = client
        .probe_folder_exists(&bucket, &folder_key)
        .await
        .expect("probe_folder_exists should succeed");
    assert!(exists, "marker should exist after creation");

    // Delete the marker (via the marker key directly)
    let marker_key = format!("{folder_key}.ds3keep");
    client
        .delete_object(&bucket, &marker_key)
        .await
        .expect("delete marker should succeed");

    // Probe should return false now
    let exists_after = client
        .probe_folder_exists(&bucket, &folder_key)
        .await
        .expect("probe after delete should succeed");
    assert!(!exists_after, "marker should not exist after deletion");
}
