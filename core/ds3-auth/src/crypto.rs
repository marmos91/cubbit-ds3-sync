//! SHA-256 + Ed25519 challenge signing for Cubbit IAM auth.

use ds3_models::DS3Error;

/// Signs a challenge using SHA-256 key derivation and Ed25519.
///
/// Steps:
/// 1. SHA-256(password_bytes + salt_bytes) -> 32-byte seed
/// 2. Ed25519 `SigningKey::from_bytes(&seed)`
/// 3. Sign the challenge bytes
/// 4. Base64 STANDARD encode the 64-byte signature
///
/// Must produce byte-identical output to the Swift `signChallenge` function.
pub fn sign_challenge(challenge: &str, password: &str, salt: &str) -> Result<String, DS3Error> {
    todo!()
}

/// Derives the Ed25519 public key from password and salt.
///
/// Uses the same SHA-256(password + salt) derivation as `sign_challenge`.
/// Returns the base64-encoded verifying (public) key.
pub fn derive_public_key(password: &str, salt: &str) -> Result<String, DS3Error> {
    todo!()
}
