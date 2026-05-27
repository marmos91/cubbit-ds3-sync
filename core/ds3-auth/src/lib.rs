//! Authentication module for the Cubbit DS3 platform.
//!
//! Implements the challenge-response authentication flow using SHA-256 key
//! derivation and Ed25519 signing. Manages the session lifecycle including
//! login, token refresh, and IAM token forging.

pub mod challenge;
pub mod crypto;
pub mod login;
pub mod refresh;
pub mod session;

pub use session::DS3Session;

/// Extracts the `_refresh` cookie value from response `Set-Cookie` headers.
pub(crate) fn extract_refresh_cookie(
    response: &reqwest::Response,
) -> Result<String, ds3_models::DS3Error> {
    for cookie_header in response.headers().get_all(reqwest::header::SET_COOKIE) {
        let cookie_str = cookie_header.to_str().unwrap_or("");
        if let Some(rest) = cookie_str.strip_prefix("_refresh=") {
            if let Some(value) = rest.split(';').next() {
                if !value.is_empty() {
                    return Ok(value.to_string());
                }
            }
        }
    }
    Err(ds3_models::DS3Error::CookieError)
}
