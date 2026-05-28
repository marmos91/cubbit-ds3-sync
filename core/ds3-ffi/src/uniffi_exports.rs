//! UniFFI exported functions for Swift bindings.
//!
//! `DS3SessionHandle` is an opaque UniFFI Object that wraps the authenticated
//! `DS3Session`. All methods use the shared tokio runtime via `handles::runtime()`
//! to bridge async Rust code to blocking FFI calls.
//!
//! Function groups:
//! - Auth (9): authenticate, verify_2fa, refresh_token, forge_iam_token,
//!   account_info, current_session, get_challenge, logout, session_destroy
//! - Projects/Keys (4): get_projects, load_api_keys, create_api_key, delete_api_key
//! - S3 (12+): list_objects, list_buckets, head_object, download_object,
//!   download_to_memory, upload_object, upload_from_memory, presign_upload_part,
//!   delete_object, delete_objects, copy_object (with metadata)
//! - Markers (2): probe_folder_exists, create_folder_marker
//! - Sync (2): compute_diff, conflict_key (static functions)
//! - Errors (1): ds3_error_code (Phase 16 P02)

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use ds3_auth::DS3Session;
use ds3_models::{
    Account, AccountSession, BucketInfo, Challenge, DS3ApiKey, DS3Error, DiffResultRecord, Project,
    S3DownloadResult, S3ListingResult, S3ObjectMetadata, Token,
};
use ds3_s3::DS3S3Client;

use crate::cancellation::CancellationHandle;
use crate::handles::runtime;
use crate::progress::ProgressCallback;

/// Opaque session handle exposed to Swift via UniFFI.
///
/// Wraps an `Arc<DS3Session>` for auth and HTTP operations, plus an optional
/// `DS3S3Client` for S3 operations (initialized separately after obtaining
/// API key credentials).
#[derive(uniffi::Object)]
pub struct DS3SessionHandle {
    /// The authenticated IAM session. `None` for handles created via
    /// [`Self::s3_only`] — i.e. when only S3 operations are needed and the
    /// Swift adapter holds the full session elsewhere (Plan 03 transition
    /// state: DS3Authentication still owns URLSession-based auth; S3 calls
    /// route through this S3-only handle until Plan 04 wires the full session).
    session: Option<Arc<DS3Session>>,
    s3_client: std::sync::RwLock<Option<DS3S3Client>>,
}

// ---------------------------------------------------------------------------
// Auth functions (8)
// ---------------------------------------------------------------------------
#[uniffi::export]
impl DS3SessionHandle {
    /// Authenticates with the Cubbit IAM server and returns a session handle.
    ///
    /// This is the primary entry point. Orchestrates: get_challenge -> sign ->
    /// post_signin -> get_account_info.
    #[uniffi::constructor]
    pub fn authenticate(
        email: String,
        password: String,
        tenant_id: Option<String>,
        coordinator_url: Option<String>,
    ) -> Result<Arc<Self>, DS3Error> {
        let session = runtime().block_on(DS3Session::authenticate(
            &email,
            &password,
            tenant_id.as_deref(),
            coordinator_url.as_deref(),
        ))?;
        Ok(Arc::new(Self {
            session: Some(Arc::new(session)),
            s3_client: std::sync::RwLock::new(None),
        }))
    }

    /// Authenticates with a 2FA code (for accounts with two-factor enabled).
    #[uniffi::constructor]
    pub fn verify_2fa(
        email: String,
        password: String,
        tfa_code: String,
        tenant_id: Option<String>,
        coordinator_url: Option<String>,
    ) -> Result<Arc<Self>, DS3Error> {
        let session = runtime().block_on(DS3Session::authenticate_with_2fa(
            &email,
            &password,
            &tfa_code,
            tenant_id.as_deref(),
            coordinator_url.as_deref(),
        ))?;
        Ok(Arc::new(Self {
            session: Some(Arc::new(session)),
            s3_client: std::sync::RwLock::new(None),
        }))
    }

    /// Constructs a session handle that only supports S3 operations.
    ///
    /// Phase 16 Plan 03 transition: the Swift `DS3S3Client` adapter needs a
    /// Rust-backed S3 path before Plan 04 wires the full IAM session through
    /// `DS3SessionHandle`. This constructor connects the underlying `aws-sdk-s3`
    /// client with the provided credentials and endpoint, leaving `session`
    /// unset. Auth/projects/keys methods on the handle will return
    /// `DS3Error::LoggedOut` until Plan 04 replaces this construction with the
    /// authenticated flow.
    #[uniffi::constructor]
    pub fn s3_only(
        endpoint: String,
        access_key: String,
        secret_key: String,
        region: Option<String>,
    ) -> Result<Arc<Self>, DS3Error> {
        let client = DS3S3Client::new(&endpoint, &access_key, &secret_key, region.as_deref());
        Ok(Arc::new(Self {
            session: None,
            s3_client: std::sync::RwLock::new(Some(client)),
        }))
    }

    /// Refreshes the access token if expired.
    pub fn refresh_token(&self) -> Result<(), DS3Error> {
        let session = self.session.as_ref().ok_or(DS3Error::LoggedOut)?;
        runtime().block_on(session.refresh_if_needed())
    }

    /// Forges an IAM-scoped token for the specified user ID.
    pub fn forge_iam_token(&self, user_id: String) -> Result<Token, DS3Error> {
        let session = self.session.as_ref().ok_or(DS3Error::LoggedOut)?;
        runtime().block_on(session.forge_iam_token(&user_id))
    }

    /// Returns the authenticated account information.
    pub fn account_info(&self) -> Result<Account, DS3Error> {
        let session = self.session.as_ref().ok_or(DS3Error::LoggedOut)?;
        Ok(session.account.clone())
    }

    /// Returns a clone of the current session (token + refresh token).
    ///
    /// Used after login/refresh/forge so the Swift adapter can persist the
    /// `AccountSession` to the App Group JSON (PATTERNS.md §"App Group
    /// Persistence Boundary", D-04/D-06).
    pub fn current_session(&self) -> Result<AccountSession, DS3Error> {
        let session = self.session.as_ref().ok_or(DS3Error::LoggedOut)?;
        Ok(runtime().block_on(session.current_session()))
    }

    /// Initializes the S3 client for this session with the given credentials.
    ///
    /// Must be called before any S3 operation. Typically called after
    /// `forge_iam_token` + `create_api_key` to obtain S3 credentials.
    pub fn connect_s3(
        &self,
        endpoint: String,
        access_key: String,
        secret_key: String,
        region: Option<String>,
    ) -> Result<(), DS3Error> {
        let client = DS3S3Client::new(&endpoint, &access_key, &secret_key, region.as_deref());
        let mut guard = self
            .s3_client
            .write()
            .map_err(|_| DS3Error::AuthError("S3 client lock poisoned".into()))?;
        *guard = Some(client);
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Projects/Keys functions (4)
// ---------------------------------------------------------------------------
#[uniffi::export]
impl DS3SessionHandle {
    /// Lists all projects for the authenticated user.
    pub fn get_projects(&self) -> Result<Vec<Project>, DS3Error> {
        let session = self.session.as_ref().ok_or(DS3Error::LoggedOut)?;
        self.refresh_token()?;
        let token = self.current_token()?;
        runtime().block_on(ds3_http::projects::get_projects(
            &session.http,
            &session.urls,
            &token,
        ))
    }

    /// Loads API keys for a given IAM user.
    pub fn load_api_keys(
        &self,
        user_id: String,
        iam_token: String,
    ) -> Result<Vec<DS3ApiKey>, DS3Error> {
        let session = self.session.as_ref().ok_or(DS3Error::LoggedOut)?;
        runtime().block_on(ds3_http::keys::load_api_keys(
            &session.http,
            &session.urls,
            &iam_token,
            &user_id,
        ))
    }

    /// Creates a new API key for a given IAM user.
    pub fn create_api_key(
        &self,
        user_id: String,
        key_name: String,
        iam_token: String,
    ) -> Result<DS3ApiKey, DS3Error> {
        let session = self.session.as_ref().ok_or(DS3Error::LoggedOut)?;
        runtime().block_on(ds3_http::keys::create_api_key(
            &session.http,
            &session.urls,
            &iam_token,
            &user_id,
            &key_name,
        ))
    }

    /// Deletes an API key by its access key ID.
    pub fn delete_api_key(
        &self,
        user_id: String,
        api_key_id: String,
        iam_token: String,
    ) -> Result<(), DS3Error> {
        let session = self.session.as_ref().ok_or(DS3Error::LoggedOut)?;
        runtime().block_on(ds3_http::keys::delete_api_key(
            &session.http,
            &session.urls,
            &iam_token,
            &user_id,
            &api_key_id,
        ))
    }
}

// ---------------------------------------------------------------------------
// S3 functions (15)
// ---------------------------------------------------------------------------
#[uniffi::export]
impl DS3SessionHandle {
    /// Lists objects in a bucket with optional prefix, delimiter, and pagination.
    pub fn list_objects(
        &self,
        bucket: String,
        prefix: Option<String>,
        delimiter: Option<String>,
        max_keys: Option<i32>,
        continuation_token: Option<String>,
    ) -> Result<S3ListingResult, DS3Error> {
        let client = self.require_s3()?;
        runtime().block_on(client.list_objects(
            &bucket,
            prefix.as_deref(),
            delimiter.as_deref(),
            max_keys,
            continuation_token.as_deref(),
        ))
    }

    /// Lists all buckets accessible with the current S3 credentials.
    pub fn list_buckets(&self) -> Result<Vec<BucketInfo>, DS3Error> {
        let client = self.require_s3()?;
        let raw = runtime().block_on(client.list_buckets())?;
        Ok(raw
            .into_iter()
            .map(|(name, creation_date)| BucketInfo {
                name,
                creation_date,
            })
            .collect())
    }

    /// Returns metadata for a single S3 object (HeadObject).
    pub fn head_object(&self, bucket: String, key: String) -> Result<S3ObjectMetadata, DS3Error> {
        let client = self.require_s3()?;
        runtime().block_on(client.head_object(&bucket, &key))
    }

    /// Downloads an S3 object to a local file path.
    ///
    /// `cancel_token` is currently unused for download (single-call GET); reserved
    /// for future chunked-download cancellation. See CONTEXT D-20.
    pub fn download_object(
        &self,
        bucket: String,
        key: String,
        file_path: String,
        progress: Option<Box<dyn ProgressCallback>>,
        cancel_token: Option<Arc<CancellationHandle>>,
    ) -> Result<S3DownloadResult, DS3Error> {
        let _ = cancel_token; // reserved for future chunked-download cancellation
        let client = self.require_s3()?;
        let path = Path::new(&file_path);
        let callback = wrap_progress_callback(progress);

        runtime().block_on(client.download_object(&bucket, &key, path, callback.as_deref()))
    }

    /// Uploads a local file to S3. Returns the ETag on success (if provided by S3).
    ///
    /// Automatically uses multipart upload for files larger than 5MB. When
    /// `cancel_token` is provided, multipart upload checks it between parts
    /// and aborts cleanly on cancel.
    pub fn upload_object(
        &self,
        bucket: String,
        key: String,
        file_path: String,
        progress: Option<Box<dyn ProgressCallback>>,
        cancel_token: Option<Arc<CancellationHandle>>,
    ) -> Result<Option<String>, DS3Error> {
        let client = self.require_s3()?;
        let path = Path::new(&file_path);
        let callback = wrap_progress_callback(progress);
        let token: Option<Arc<dyn ds3_s3::CancelToken>> =
            cancel_token.map(|h| h as Arc<dyn ds3_s3::CancelToken>);

        runtime().block_on(client.upload_object(&bucket, &key, path, callback.as_deref(), token))
    }

    /// Deletes a single S3 object.
    pub fn delete_object(&self, bucket: String, key: String) -> Result<(), DS3Error> {
        let client = self.require_s3()?;
        runtime().block_on(client.delete_object(&bucket, &key))
    }

    /// Deletes multiple S3 objects. Returns the count of successfully deleted objects.
    pub fn delete_objects(&self, bucket: String, keys: Vec<String>) -> Result<i32, DS3Error> {
        let client = self.require_s3()?;
        let count = runtime().block_on(client.delete_objects(&bucket, &keys))?;
        Ok(count as i32)
    }

    /// Copies an S3 object within the same bucket.
    ///
    /// When `metadata` is `Some`, sets `MetadataDirective::Replace` and
    /// applies the new metadata. When `None`, preserves the source object's
    /// metadata (default `COPY` directive).
    pub fn copy_object(
        &self,
        bucket: String,
        source_key: String,
        dest_key: String,
        metadata: Option<HashMap<String, String>>,
    ) -> Result<(), DS3Error> {
        let client = self.require_s3()?;
        runtime().block_on(client.copy_object(&bucket, &source_key, &dest_key, metadata.as_ref()))
    }

    /// Downloads an S3 object directly to an in-memory `Vec<u8>`.
    ///
    /// Intended for small payloads (thumbnails, .ds3keep markers, metadata blobs).
    /// For large files, use `download_object` which streams to a file path.
    pub fn download_to_memory(&self, bucket: String, key: String) -> Result<Vec<u8>, DS3Error> {
        let client = self.require_s3()?;
        runtime().block_on(client.download_to_memory(&bucket, &key))
    }

    /// Uploads an in-memory `Vec<u8>` to S3 with optional custom metadata.
    ///
    /// Metadata is sent as `x-amz-meta-*` headers. Empty `data` produces a
    /// zero-byte object (`.ds3keep` folder marker shape).
    pub fn upload_from_memory(
        &self,
        bucket: String,
        key: String,
        data: Vec<u8>,
        metadata: HashMap<String, String>,
    ) -> Result<Option<String>, DS3Error> {
        let client = self.require_s3()?;
        runtime().block_on(client.upload_from_memory(&bucket, &key, data, metadata))
    }

    /// Generates a presigned GET URL for an S3 object.
    ///
    /// `expires_in_seconds` must be in `1..=604_800` (7 days, AWS sigv4 limit).
    /// Swift consumes the returned URL for unauthenticated GET access (thumbnail
    /// fetches, iOS background-downloads, etc.).
    pub fn presign_get(
        &self,
        bucket: String,
        key: String,
        expires_in_seconds: i64,
    ) -> Result<String, DS3Error> {
        let client = self.require_s3()?;
        runtime().block_on(client.presign_get(&bucket, &key, expires_in_seconds))
    }

    /// Generates a presigned PUT URL for a multipart upload part.
    ///
    /// `expires_in_seconds` must be in `1..=604_800` (7 days, AWS sigv4 limit).
    /// Swift consumes the returned URL to upload a single part via
    /// `URLRequest.httpMethod = "PUT"`.
    pub fn presign_upload_part(
        &self,
        bucket: String,
        key: String,
        upload_id: String,
        part_number: i32,
        expires_in_seconds: i64,
    ) -> Result<String, DS3Error> {
        let client = self.require_s3()?;
        runtime().block_on(client.presign_upload_part(
            &bucket,
            &key,
            &upload_id,
            part_number,
            expires_in_seconds,
        ))
    }

    /// Probes whether a folder marker (.ds3keep) exists for the given folder key.
    pub fn probe_folder_exists(
        &self,
        bucket: String,
        folder_key: String,
    ) -> Result<bool, DS3Error> {
        let client = self.require_s3()?;
        runtime().block_on(client.probe_folder_exists(&bucket, &folder_key))
    }

    /// Creates a .ds3keep folder marker for the given folder key.
    pub fn create_folder_marker(&self, bucket: String, folder_key: String) -> Result<(), DS3Error> {
        let client = self.require_s3()?;
        runtime().block_on(client.create_folder_marker(&bucket, &folder_key))
    }
}

// ---------------------------------------------------------------------------
// Static functions (no session needed)
// ---------------------------------------------------------------------------

/// Retrieves an auth challenge from the IAM server.
#[uniffi::export]
pub fn get_challenge(
    email: String,
    tenant_id: Option<String>,
    coordinator_url: Option<String>,
) -> Result<Challenge, DS3Error> {
    use ds3_auth::challenge::get_challenge as auth_get_challenge;
    use ds3_http::client::SharedHttpClient;
    use ds3_http::urls::CubbitAPIURLs;

    let urls = match coordinator_url.as_deref() {
        Some(url) => CubbitAPIURLs::new(url),
        None => CubbitAPIURLs::default_coordinator(),
    };
    let http = SharedHttpClient::new()?;
    runtime().block_on(auth_get_challenge(
        &http,
        &urls,
        &email,
        tenant_id.as_deref(),
    ))
}

/// Computes the diff between local and remote file tree snapshots.
///
/// Both `local_json` and `remote_json` are JSON strings representing
/// `HashMap<String, Option<String>>` (key -> optional ETag).
#[uniffi::export]
pub fn compute_diff(local_json: String, remote_json: String) -> Result<DiffResultRecord, DS3Error> {
    let local: std::collections::HashMap<String, Option<String>> =
        serde_json::from_str(&local_json)?;
    let remote: std::collections::HashMap<String, Option<String>> =
        serde_json::from_str(&remote_json)?;

    let local_tree = ds3_sync::TreeSnapshot::from_map(local);
    let remote_tree = ds3_sync::TreeSnapshot::from_map(remote);

    let result = ds3_sync::compute_diff(&local_tree, &remote_tree);
    Ok(result.into())
}

/// Generates a conflict copy key from the original key and hostname.
///
/// If `nonce` is `None`, a random 4-character hex nonce is generated.
#[uniffi::export]
pub fn conflict_key(original_key: String, hostname: String, nonce: Option<String>) -> String {
    ds3_sync::conflict_key(
        &original_key,
        &hostname,
        chrono::Utc::now(),
        nonce.as_deref(),
    )
}

/// Returns the numeric error code matching a [`DS3Error`] Display string.
///
/// The UniFFI `flat_error` attribute on `DS3Error` collapses all enum variants
/// to a `(message: String)` shape on the Swift side, so the Swift adapter can
/// only inspect the error's stringified Display when it catches one
/// (FFI-AUDIT.md A1). This helper maps that Display string back to the
/// numeric code defined by `DS3Error::code()` so per-adapter translation
/// tables (PATTERNS.md Pattern 3) can dispatch on integers 1001..=3004.
///
/// Returns `-1` for inputs that don't match any known variant (the Swift
/// adapter maps this to a generic "unknown" case).
#[uniffi::export]
pub fn ds3_error_code(message: String) -> i32 {
    // Match on the leading text of `DS3Error`'s `Display` implementation
    // (thiserror `#[error("...")]` strings). Anchored at start so partial
    // matches don't false-positive across categories.
    let m = message.as_str();
    if m.starts_with("Invalid URL:") {
        return 1001;
    }
    if m.starts_with("Server error:") {
        return 1002;
    }
    if m.starts_with("JSON error:") {
        return 1003;
    }
    if m == "Encoding error" {
        return 1004;
    }
    if m == "Not logged in" {
        return 1005;
    }
    if m == "Token expired" {
        return 1006;
    }
    if m == "2FA code required" {
        return 1007;
    }
    if m == "Cookie error" {
        return 1008;
    }
    if m == "Missing upload ID" {
        return 2001;
    }
    if m == "Empty file data" {
        return 2002;
    }
    if m == "Missing ETag" {
        return 2003;
    }
    if m == "Parse error" {
        return 2004;
    }
    if m == "Unable to open file" {
        return 2005;
    }
    if m.starts_with("IO error:") {
        return 3001;
    }
    if m.starts_with("HTTP error:") {
        return 3002;
    }
    if m.starts_with("S3 error:") {
        return 3003;
    }
    if m.starts_with("Auth error:") {
        return 3004;
    }
    -1
}

/// Wraps a UniFFI `ProgressCallback` into a closure compatible with the S3 client.
fn wrap_progress_callback(
    progress: Option<Box<dyn ProgressCallback>>,
) -> Option<Box<dyn Fn(i64, i64) + Send + Sync>> {
    progress.map(|p| {
        Box::new(move |transferred, total| {
            p.on_progress(transferred, total);
        }) as Box<dyn Fn(i64, i64) + Send + Sync>
    })
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------
impl DS3SessionHandle {
    /// Returns the current access token string.
    fn current_token(&self) -> Result<String, DS3Error> {
        let session = self.session.as_ref().ok_or(DS3Error::LoggedOut)?;
        let inner = runtime().block_on(session.session.lock());
        Ok(inner.token.token.clone())
    }

    /// Returns a clone of the S3 client, or an error if not connected.
    fn require_s3(&self) -> Result<DS3S3Client, DS3Error> {
        let guard = self
            .s3_client
            .read()
            .map_err(|_| DS3Error::AuthError("S3 client lock poisoned".into()))?;
        guard.clone().ok_or(DS3Error::LoggedOut)
    }
}
