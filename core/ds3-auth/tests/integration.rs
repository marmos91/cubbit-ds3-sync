//! Integration tests for ds3-auth against real Cubbit IAM.
//!
//! Gated behind `#[cfg(feature = "integration")]` -- run with:
//!     cargo test -p ds3-auth --features integration --test integration
//!
//! Required environment variables:
//! - DS3_TEST_EMAIL: Cubbit account email
//! - DS3_TEST_PASSWORD: Cubbit account password

#![cfg(feature = "integration")]

use ds3_auth::DS3Session;

/// Helper to read a required env var, skipping the test if missing.
fn env_or_skip(name: &str) -> String {
    match std::env::var(name) {
        Ok(val) if !val.is_empty() => val,
        _ => {
            eprintln!("Skipping: {name} not set");
            std::process::exit(0);
        }
    }
}

#[tokio::test]
async fn test_authenticate() {
    let email = env_or_skip("DS3_TEST_EMAIL");
    let password = env_or_skip("DS3_TEST_PASSWORD");

    let session = DS3Session::authenticate(&email, &password, None, None)
        .await
        .expect("authenticate should succeed");

    assert!(
        !session.account.tenant_id.is_empty(),
        "tenant_id must be non-empty"
    );

    let token = session
        .session
        .lock()
        .await
        .token
        .token
        .clone();
    assert!(!token.is_empty(), "session token must be non-empty");
}

#[tokio::test]
async fn test_refresh_after_auth() {
    let email = env_or_skip("DS3_TEST_EMAIL");
    let password = env_or_skip("DS3_TEST_PASSWORD");

    let session = DS3Session::authenticate(&email, &password, None, None)
        .await
        .expect("authenticate should succeed");

    // refresh_if_needed should succeed (even if token is still fresh)
    session
        .refresh_if_needed()
        .await
        .expect("refresh_if_needed should not error");
}

#[tokio::test]
async fn test_forge_iam_token() {
    let email = env_or_skip("DS3_TEST_EMAIL");
    let password = env_or_skip("DS3_TEST_PASSWORD");

    let session = DS3Session::authenticate(&email, &password, None, None)
        .await
        .expect("authenticate should succeed");

    // Use the account ID to forge an IAM token
    let user_id = &session.account.id;
    assert!(!user_id.is_empty(), "account id must be non-empty");

    let iam_token = session
        .forge_iam_token(user_id)
        .await
        .expect("forge_iam_token should succeed");

    assert!(!iam_token.token.is_empty(), "IAM token must be non-empty");
    assert!(iam_token.exp > 0, "IAM token exp must be > 0");
}

#[tokio::test]
async fn test_get_projects() {
    let email = env_or_skip("DS3_TEST_EMAIL");
    let password = env_or_skip("DS3_TEST_PASSWORD");

    let session = DS3Session::authenticate(&email, &password, None, None)
        .await
        .expect("authenticate should succeed");

    let token = session
        .session
        .lock()
        .await
        .token
        .token
        .clone();

    let projects = ds3_http::projects::get_projects(&session.http, &session.urls, &token)
        .await
        .expect("get_projects should succeed");

    assert!(!projects.is_empty(), "should have at least one project");
}
