//! SHA-256 + Ed25519 challenge signing for Cubbit IAM auth.
//!
//! Ports the Swift `signChallenge` function from `DS3Authentication.swift`.
//! The derivation is: SHA-256(password_bytes + salt_bytes) -> 32-byte seed
//! -> Ed25519 `SigningKey` -> sign challenge -> base64 encode signature.

use base64::Engine;
use ds3_models::DS3Error;
use ed25519_dalek::{Signer, SigningKey};
use sha2::{Digest, Sha256};

/// Signs a challenge using SHA-256 key derivation and Ed25519.
///
/// Steps:
/// 1. `SHA256(password_bytes + salt_bytes)` -> 32-byte seed
/// 2. `SigningKey::from_bytes(&seed)`
/// 3. `signing_key.sign(challenge.as_bytes())`
/// 4. Base64 STANDARD encode the 64-byte signature
///
/// Must produce byte-identical output to the Swift `signChallenge` function
/// for the same inputs (D-12).
pub fn sign_challenge(challenge: &str, password: &str, salt: &str) -> Result<String, DS3Error> {
    let seed = derive_seed(password, salt);
    let signing_key = SigningKey::from_bytes(&seed);
    let signature = signing_key.sign(challenge.as_bytes());
    Ok(base64::engine::general_purpose::STANDARD.encode(signature.to_bytes()))
}

/// Derives the Ed25519 public key from password and salt.
///
/// Uses the same SHA-256(password + salt) derivation as `sign_challenge`.
/// Returns the base64-encoded verifying (public) key.
pub fn derive_public_key(password: &str, salt: &str) -> Result<String, DS3Error> {
    let seed = derive_seed(password, salt);
    let signing_key = SigningKey::from_bytes(&seed);
    let verifying_key = signing_key.verifying_key();
    Ok(base64::engine::general_purpose::STANDARD.encode(verifying_key.as_bytes()))
}

/// Derives a 32-byte seed from password and salt via SHA-256.
fn derive_seed(password: &str, salt: &str) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(password.as_bytes());
    hasher.update(salt.as_bytes());
    let hash = hasher.finalize();
    let mut seed = [0u8; 32];
    seed.copy_from_slice(&hash);
    seed
}
