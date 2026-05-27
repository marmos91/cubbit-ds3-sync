//! DS3 API key type for S3 credential management.

use serde::{Deserialize, Serialize};

/// An S3 API key in the Cubbit DS3 ecosystem.
///
/// The `secret_key` is only present when a key is first created (the server
/// returns it once). When listing existing keys, `secret_key` is `None`.
/// The `created_at` field is stored as an ISO 8601 string.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct DS3ApiKey {
    /// The name of the API key.
    pub name: String,

    /// The S3 access key ID (public key).
    #[serde(rename = "api_key")]
    pub api_key: String,

    /// The S3 secret access key (private key), only present on creation.
    #[serde(
        rename = "secret_key",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub secret_key: Option<String>,

    /// When the API key was created (ISO 8601 string).
    #[serde(rename = "created_at")]
    pub created_at: String,
}
