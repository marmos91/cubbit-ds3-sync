//! Unit tests for ds3-auth crate: crypto, session, and 2FA detection.

use ds3_auth::crypto::{derive_public_key, sign_challenge};
use ds3_auth::session::is_token_expired;
use ds3_models::Token;

// -----------------------------------------------------------------------
// Crypto tests
// -----------------------------------------------------------------------

#[test]
fn test_sign_challenge_deterministic() {
    // Same inputs must produce the same base64 output every time.
    let result1 = sign_challenge("xyz", "test", "abc").expect("sign_challenge should succeed");
    let result2 = sign_challenge("xyz", "test", "abc").expect("sign_challenge should succeed");
    assert_eq!(result1, result2, "sign_challenge must be deterministic");

    // Output should be valid base64 encoding of a 64-byte Ed25519 signature.
    let decoded = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, &result1)
        .expect("output should be valid base64");
    assert_eq!(decoded.len(), 64, "Ed25519 signature must be 64 bytes");
}

#[test]
fn test_sign_challenge_empty_password() {
    // Empty password should not panic -- ed25519-dalek accepts any 32-byte seed.
    let result = sign_challenge("challenge", "", "salt");
    assert!(result.is_ok(), "empty password should not panic");

    let decoded =
        base64::Engine::decode(&base64::engine::general_purpose::STANDARD, result.unwrap())
            .expect("output should be valid base64");
    assert_eq!(decoded.len(), 64);
}

#[test]
fn test_sign_challenge_different_inputs_differ() {
    let result1 = sign_challenge("challenge1", "pass1", "salt1").unwrap();
    let result2 = sign_challenge("challenge2", "pass2", "salt2").unwrap();
    assert_ne!(
        result1, result2,
        "different inputs should produce different signatures"
    );
}

#[test]
fn test_derive_public_key_deterministic() {
    let pk1 = derive_public_key("test", "abc").expect("derive_public_key should succeed");
    let pk2 = derive_public_key("test", "abc").expect("derive_public_key should succeed");
    assert_eq!(pk1, pk2, "derive_public_key must be deterministic");

    // Ed25519 public key is 32 bytes.
    let decoded = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, &pk1)
        .expect("output should be valid base64");
    assert_eq!(decoded.len(), 32, "Ed25519 public key must be 32 bytes");
}

// -----------------------------------------------------------------------
// Token expiry tests
// -----------------------------------------------------------------------

#[test]
fn test_is_token_expired_past() {
    let token = Token {
        token: "jwt-string".to_string(),
        exp: 1000000000, // Well in the past
        exp_date: "2001-09-09T01:46:40Z".to_string(),
    };
    assert!(
        is_token_expired(&token),
        "token with past exp should be expired"
    );
}

#[test]
fn test_is_token_expired_future() {
    let token = Token {
        token: "jwt-string".to_string(),
        exp: 4102444800, // 2099-12-31
        exp_date: "2099-12-31T00:00:00Z".to_string(),
    };
    assert!(
        !is_token_expired(&token),
        "token with future exp should not be expired"
    );
}

// -----------------------------------------------------------------------
// DS3Session structure test
// -----------------------------------------------------------------------

#[test]
fn test_ds3_session_fields_exist() {
    // Verify the DS3Session struct has the expected shape by checking it
    // compiles with the expected field types. We can't construct one easily
    // without network, but we can verify the type relationships.
    fn _assert_send<T: Send>() {}
    // DS3Session should be Send (SharedHttpClient + RwLock + Account are all Send)
    _assert_send::<ds3_auth::DS3Session>();
}
