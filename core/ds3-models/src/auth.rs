//! Authentication types: Challenge, Token, and AccountSession.

use serde::{Deserialize, Serialize};

/// A security challenge issued by the Cubbit IAM server.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct Challenge {
    /// The challenge string to be signed.
    pub challenge: String,

    /// The salt used in key derivation.
    pub salt: String,
}

/// A JWT access token with expiration metadata.
///
/// In the Swift codebase, `exp_date` is decoded from an ISO 8601 string into
/// a `Date`. Here we store it as a `String` for JSON compatibility and let
/// consumers parse it with chrono when needed.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct Token {
    /// The JWT access token string.
    pub token: String,

    /// The token expiration as Unix timestamp (seconds).
    pub exp: i64,

    /// The token expiration as an ISO 8601 date string.
    #[serde(rename = "exp_date")]
    pub exp_date: String,
}

/// An authenticated session containing an access token and refresh token.
///
/// Matches the Swift `AccountSession` JSON schema where `refreshToken` is
/// serialized in camelCase (not snake_case).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct AccountSession {
    /// The current access token.
    pub token: Token,

    /// The refresh token string.
    #[serde(rename = "refreshToken")]
    pub refresh_token: String,
}
