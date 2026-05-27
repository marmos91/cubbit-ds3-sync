//! SHA-256 + Ed25519 challenge signing for Cubbit IAM auth.
//!
//! Ports the Swift `signChallenge` function from `DS3Authentication.swift`.
//! The derivation is: SHA-256(password_bytes + salt_bytes) -> 32-byte seed
//! -> Ed25519 signing key -> sign challenge -> base64 encode signature.

use base64::Engine;
use ds3_models::DS3Error;
use ring::digest;
use ring::signature::{Ed25519KeyPair, KeyPair};

/// Signs a challenge using SHA-256 key derivation and Ed25519.
///
/// Must produce byte-identical output to the Swift `signChallenge` function
/// for the same inputs (D-12).
pub fn sign_challenge(challenge: &str, password: &str, salt: &str) -> Result<String, DS3Error> {
    let seed = derive_seed(password, salt);
    let key_pair = Ed25519KeyPair::from_seed_unchecked(&seed)
        .map_err(|e| DS3Error::AuthError(format!("ed25519 seed error: {e}")))?;
    let signature = key_pair.sign(challenge.as_bytes());
    Ok(base64::engine::general_purpose::STANDARD.encode(signature.as_ref()))
}

/// Derives the Ed25519 public key from password and salt.
///
/// Uses the same SHA-256(password + salt) derivation as `sign_challenge`.
/// Returns the base64-encoded verifying (public) key.
pub fn derive_public_key(password: &str, salt: &str) -> Result<String, DS3Error> {
    let seed = derive_seed(password, salt);
    let key_pair = Ed25519KeyPair::from_seed_unchecked(&seed)
        .map_err(|e| DS3Error::AuthError(format!("ed25519 seed error: {e}")))?;
    Ok(base64::engine::general_purpose::STANDARD.encode(key_pair.public_key().as_ref()))
}

/// Derives a 32-byte seed from password and salt via SHA-256.
fn derive_seed(password: &str, salt: &str) -> [u8; 32] {
    let mut ctx = digest::Context::new(&digest::SHA256);
    ctx.update(password.as_bytes());
    ctx.update(salt.as_bytes());
    let hash = ctx.finish();
    let mut seed = [0u8; 32];
    seed.copy_from_slice(hash.as_ref());
    seed
}
