//! Serde round-trip tests for all ds3-models domain types.
//!
//! Each test verifies that a JSON payload matching the Swift/API schema
//! deserializes correctly into the Rust struct and re-serializes to an
//! equivalent JSON value.

use ds3_models::account::Account;
use ds3_models::api_key::DS3ApiKey;
use ds3_models::auth::{AccountSession, Challenge, Token};
use ds3_models::drive::DS3Drive;
use ds3_models::error::DS3Error;
use ds3_models::project::{IAMUser, Project};
use ds3_models::s3::{
    CompletedPartResult, MultipartUploadContext, S3ListingResult, S3ObjectMetadata,
    S3ObjectSummary, TransferProgress,
};
use ds3_models::sync::{ConflictInfo, DiffResult};
use serde_json::json;

// ---------------------------------------------------------------------------
// Test 1: Account deserializes from JSON with snake_case keys
// ---------------------------------------------------------------------------
#[test]
fn test_account_deserialize() {
    let json_data = json!({
        "id": "acc-123",
        "first_name": "Marco",
        "last_name": "Rossi",
        "internal": true,
        "banned": false,
        "created_at": "2024-01-15T10:00:00Z",
        "deleted_at": null,
        "banned_at": null,
        "max_allowed_projects": 5,
        "emails": [{
            "id": "em-1",
            "email": "marco@example.com",
            "default": true,
            "created_at": "2024-01-15T10:00:00Z",
            "verified": true,
            "tenant_id": "tenant-abc"
        }],
        "two_factor_enabled": false,
        "tenant_id": "tenant-abc",
        "endpoint_gateway": "https://s3.example.com",
        "auth_provider": "cubbit"
    });

    let account: Account = serde_json::from_value(json_data.clone()).unwrap();
    assert_eq!(account.id, "acc-123");
    assert_eq!(account.first_name, "Marco");
    assert_eq!(account.last_name, "Rossi");
    assert!(account.is_internal);
    assert!(!account.is_banned);
    assert_eq!(account.created_at, "2024-01-15T10:00:00Z");
    assert!(account.deleted_at.is_none());
    assert!(account.banned_at.is_none());
    assert_eq!(account.max_allowed_projects, 5);
    assert_eq!(account.emails.len(), 1);
    assert_eq!(account.emails[0].email, "marco@example.com");
    assert!(account.emails[0].is_default);
    assert!(account.emails[0].is_verified);
    assert_eq!(account.emails[0].tenant_id, "tenant-abc");
    assert!(!account.is_two_factor_enabled);
    assert_eq!(account.tenant_id, "tenant-abc");
    assert_eq!(account.endpoint_gateway, "https://s3.example.com");
    assert_eq!(account.auth_provider, "cubbit");

    // Round-trip
    let serialized = serde_json::to_value(&account).unwrap();
    assert_eq!(serialized["internal"], true);
    assert_eq!(serialized["banned"], false);
    assert_eq!(serialized["first_name"], "Marco");
}

// ---------------------------------------------------------------------------
// Test 2: Challenge deserializes from JSON
// ---------------------------------------------------------------------------
#[test]
fn test_challenge_deserialize() {
    let json_data = json!({
        "challenge": "abc123challenge",
        "salt": "salt456"
    });

    let challenge: Challenge = serde_json::from_value(json_data).unwrap();
    assert_eq!(challenge.challenge, "abc123challenge");
    assert_eq!(challenge.salt, "salt456");
}

// ---------------------------------------------------------------------------
// Test 3: Token deserializes from JSON with exp_date
// ---------------------------------------------------------------------------
#[test]
fn test_token_deserialize() {
    let json_data = json!({
        "token": "eyJhbGciOiJIUzI1NiJ9.test",
        "exp": 1700000000_i64,
        "exp_date": "2023-11-14T22:13:20Z"
    });

    let token: Token = serde_json::from_value(json_data).unwrap();
    assert_eq!(token.token, "eyJhbGciOiJIUzI1NiJ9.test");
    assert_eq!(token.exp, 1700000000);
    assert_eq!(token.exp_date, "2023-11-14T22:13:20Z");
}

// ---------------------------------------------------------------------------
// Test 4: AccountSession round-trips with nested Token and refreshToken
// ---------------------------------------------------------------------------
#[test]
fn test_account_session_round_trip() {
    let json_data = json!({
        "token": {
            "token": "access-jwt",
            "exp": 1700000000_i64,
            "exp_date": "2023-11-14T22:13:20Z"
        },
        "refreshToken": "refresh-token-value"
    });

    let session: AccountSession = serde_json::from_value(json_data.clone()).unwrap();
    assert_eq!(session.token.token, "access-jwt");
    assert_eq!(session.refresh_token, "refresh-token-value");

    // Round-trip: refreshToken must serialize back as "refreshToken" (camelCase)
    let serialized = serde_json::to_value(&session).unwrap();
    assert_eq!(serialized["refreshToken"], "refresh-token-value");
    assert!(serialized.get("token").is_some());
}

// ---------------------------------------------------------------------------
// Test 5: Project deserializes with project_-prefixed JSON keys
// ---------------------------------------------------------------------------
#[test]
fn test_project_deserialize() {
    let json_data = json!({
        "project_id": "proj-001",
        "project_name": "My Project",
        "project_description": "A test project",
        "project_email": "project@example.com",
        "project_created_at": "2024-01-01T00:00:00Z",
        "project_banned_at": null,
        "project_image_url": null,
        "project_tenant_id": "tenant-xyz",
        "root_account_email": "root@example.com",
        "users": [{
            "user_id": "user-001",
            "user_name": "admin",
            "is_root": true
        }]
    });

    let project: Project = serde_json::from_value(json_data).unwrap();
    assert_eq!(project.id, "proj-001");
    assert_eq!(project.name, "My Project");
    assert_eq!(project.description, "A test project");
    assert_eq!(project.email, "project@example.com");
    assert_eq!(project.created_at, "2024-01-01T00:00:00Z");
    assert!(project.banned_at.is_none());
    assert!(project.image_url.is_none());
    assert_eq!(project.tenant_id, "tenant-xyz");
    assert_eq!(
        project.root_account_email.as_deref(),
        Some("root@example.com")
    );
    assert_eq!(project.users.len(), 1);
    assert_eq!(project.users[0].id, "user-001");
    assert!(project.users[0].is_root);

    // Round-trip: verify project_-prefix keys
    let serialized = serde_json::to_value(&project).unwrap();
    assert_eq!(serialized["project_id"], "proj-001");
    assert_eq!(serialized["project_name"], "My Project");
}

// ---------------------------------------------------------------------------
// Test 6: IAMUser deserializes with user_id, user_name, is_root keys
// ---------------------------------------------------------------------------
#[test]
fn test_iam_user_deserialize() {
    let json_data = json!({
        "user_id": "iam-user-42",
        "user_name": "alice",
        "is_root": false
    });

    let user: IAMUser = serde_json::from_value(json_data).unwrap();
    assert_eq!(user.id, "iam-user-42");
    assert_eq!(user.username, "alice");
    assert!(!user.is_root);

    let serialized = serde_json::to_value(&user).unwrap();
    assert_eq!(serialized["user_id"], "iam-user-42");
    assert_eq!(serialized["user_name"], "alice");
}

// ---------------------------------------------------------------------------
// Test 7: DS3ApiKey deserializes; secret_key is Option
// ---------------------------------------------------------------------------
#[test]
fn test_api_key_deserialize() {
    // With secret_key present
    let json_with_secret = json!({
        "name": "ds3-drive-key",
        "api_key": "AKIA123456",
        "secret_key": "secret789",
        "created_at": "2024-06-01T12:00:00Z"
    });

    let key: DS3ApiKey = serde_json::from_value(json_with_secret).unwrap();
    assert_eq!(key.name, "ds3-drive-key");
    assert_eq!(key.api_key, "AKIA123456");
    assert_eq!(key.secret_key.as_deref(), Some("secret789"));
    assert_eq!(key.created_at, "2024-06-01T12:00:00Z");

    // Without secret_key (listing existing keys)
    let json_without_secret = json!({
        "name": "ds3-drive-key",
        "api_key": "AKIA123456",
        "created_at": "2024-06-01T12:00:00Z"
    });

    let key2: DS3ApiKey = serde_json::from_value(json_without_secret).unwrap();
    assert!(key2.secret_key.is_none());
}

// ---------------------------------------------------------------------------
// Test 8: DS3Drive round-trips with UUID id, nested SyncAnchor
// ---------------------------------------------------------------------------
#[test]
fn test_ds3_drive_round_trip() {
    let json_data = json!({
        "id": "550e8400-e29b-41d4-a716-446655440000",
        "syncAnchor": {
            "project": {
                "project_id": "proj-001",
                "project_name": "Test",
                "project_description": "desc",
                "project_email": "p@example.com",
                "project_created_at": "2024-01-01T00:00:00Z",
                "project_tenant_id": "t-1",
                "users": []
            },
            "IAMUser": {
                "user_id": "u-1",
                "user_name": "root",
                "is_root": true
            },
            "bucket": {
                "name": "my-bucket"
            },
            "prefix": "documents/"
        },
        "name": "My Drive"
    });

    let drive: DS3Drive = serde_json::from_value(json_data).unwrap();
    assert_eq!(drive.id.to_string(), "550e8400-e29b-41d4-a716-446655440000");
    assert_eq!(drive.name, "My Drive");
    assert_eq!(drive.sync_anchor.bucket.name, "my-bucket");
    assert_eq!(drive.sync_anchor.prefix.as_deref(), Some("documents/"));
    assert_eq!(drive.sync_anchor.iam_user.id, "u-1");
    assert_eq!(drive.sync_anchor.project.id, "proj-001");

    // Round-trip
    let serialized = serde_json::to_value(&drive).unwrap();
    assert_eq!(serialized["syncAnchor"]["IAMUser"]["user_id"], "u-1");
    assert_eq!(serialized["syncAnchor"]["bucket"]["name"], "my-bucket");
}

// ---------------------------------------------------------------------------
// Test 9: S3 types constructable with correct field types
// ---------------------------------------------------------------------------
#[test]
fn test_s3_types() {
    let summary = S3ObjectSummary {
        key: "folder/file.txt".to_string(),
        etag: Some("\"abc123\"".to_string()),
        last_modified: Some("2024-01-15T10:00:00Z".to_string()),
        size: 1024,
    };
    assert_eq!(summary.key, "folder/file.txt");
    assert_eq!(summary.size, 1024);

    let listing = S3ListingResult {
        objects: vec![summary.clone()],
        common_prefixes: vec!["folder/".to_string()],
        next_continuation_token: None,
        is_truncated: false,
    };
    assert_eq!(listing.objects.len(), 1);
    assert!(!listing.is_truncated);

    let metadata = S3ObjectMetadata {
        etag: Some("\"abc123\"".to_string()),
        content_type: Some("text/plain".to_string()),
        last_modified: Some("2024-01-15T10:00:00Z".to_string()),
        version_id: None,
        content_length: 1024,
        metadata: None,
    };
    assert_eq!(metadata.content_length, 1024);

    let progress = TransferProgress {
        bytes_transferred: 512,
        total_bytes: Some(1024),
    };
    assert_eq!(progress.bytes_transferred, 512);

    let ctx = MultipartUploadContext {
        bucket: "my-bucket".to_string(),
        key: "large-file.zip".to_string(),
        upload_id: "upload-123".to_string(),
        total_size: 10_000_000,
    };
    assert_eq!(ctx.upload_id, "upload-123");

    let part = CompletedPartResult {
        part_number: 1,
        etag: "\"part-etag\"".to_string(),
    };
    assert_eq!(part.part_number, 1);
}

// ---------------------------------------------------------------------------
// Test 10: DiffResult and ConflictInfo
// ---------------------------------------------------------------------------
#[test]
fn test_diff_result_and_conflict_info() {
    let mut diff = DiffResult::default();
    assert!(diff.is_empty());

    diff.new_or_modified.insert("file1.txt".to_string());
    diff.deleted.insert("old.txt".to_string());
    assert!(!diff.is_empty());

    let conflict = ConflictInfo {
        drive_id: uuid::Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap(),
        original_filename: "report.pdf".to_string(),
        conflict_key: "report (Conflict on mac 2024-01-15 10-30-00 a1b2).pdf".to_string(),
    };
    assert_eq!(conflict.original_filename, "report.pdf");

    // ConflictInfo round-trip via serde
    let json = serde_json::to_value(&conflict).unwrap();
    let deserialized: ConflictInfo = serde_json::from_value(json).unwrap();
    assert_eq!(deserialized.drive_id, conflict.drive_id);
}

// ---------------------------------------------------------------------------
// Test 11: DS3Error has numeric code() method
// ---------------------------------------------------------------------------
#[test]
fn test_ds3_error_codes() {
    let errors = vec![
        (DS3Error::InvalidUrl { url: "bad".into() }, 1001),
        (
            DS3Error::ServerError {
                status: 500,
                body: "err".into(),
            },
            1002,
        ),
        (
            DS3Error::JsonError {
                message: "parse".into(),
            },
            1003,
        ),
        (DS3Error::Encoding, 1004),
        (DS3Error::LoggedOut, 1005),
        (DS3Error::TokenExpired, 1006),
        (DS3Error::Missing2FA, 1007),
        (DS3Error::CookieError, 1008),
        (DS3Error::MissingUploadId, 2001),
        (DS3Error::EmptyFileData, 2002),
        (DS3Error::MissingETag, 2003),
        (DS3Error::ParseError, 2004),
        (DS3Error::UnableToOpenFile, 2005),
        (DS3Error::IoError("io".into()), 3001),
        (DS3Error::HttpError("http".into()), 3002),
        (DS3Error::S3Error("s3".into()), 3003),
        (DS3Error::AuthError("auth".into()), 3004),
    ];

    // Verify all codes are distinct
    let codes: Vec<i32> = errors.iter().map(|(e, _)| e.code()).collect();
    let mut unique_codes = codes.clone();
    unique_codes.sort();
    unique_codes.dedup();
    assert_eq!(
        codes.len(),
        unique_codes.len(),
        "Error codes must be unique"
    );

    // Verify expected codes
    for (error, expected_code) in &errors {
        assert_eq!(error.code(), *expected_code, "Wrong code for {:?}", error);
    }
}
