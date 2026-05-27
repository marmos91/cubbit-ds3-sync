//! Account and AccountEmail types for the Cubbit DS3 platform.

use serde::{Deserialize, Serialize};

/// An email address associated with a Cubbit account.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AccountEmail {
    /// The email record identifier.
    pub id: String,

    /// The email address.
    pub email: String,

    /// Whether this is the default email for the account.
    #[serde(rename = "default")]
    pub is_default: bool,

    /// When the email was created (ISO 8601).
    #[serde(rename = "created_at")]
    pub created_at: String,

    /// Whether the email has been verified.
    #[serde(rename = "verified")]
    pub is_verified: bool,

    /// The tenant identifier.
    #[serde(rename = "tenant_id")]
    pub tenant_id: String,
}

/// An account in the Cubbit DS3 ecosystem.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Account {
    /// The account unique identifier.
    pub id: String,

    /// The user's first name.
    #[serde(rename = "first_name")]
    pub first_name: String,

    /// The user's last name.
    #[serde(rename = "last_name")]
    pub last_name: String,

    /// Whether the account is internal.
    #[serde(rename = "internal")]
    pub is_internal: bool,

    /// Whether the account is banned.
    #[serde(rename = "banned")]
    pub is_banned: bool,

    /// When the account was created (ISO 8601).
    #[serde(rename = "created_at")]
    pub created_at: String,

    /// When the account was deleted, if applicable.
    #[serde(rename = "deleted_at")]
    pub deleted_at: Option<String>,

    /// When the account was banned, if applicable.
    #[serde(rename = "banned_at")]
    pub banned_at: Option<String>,

    /// Maximum number of projects allowed.
    #[serde(rename = "max_allowed_projects")]
    pub max_allowed_projects: i32,

    /// The account's email addresses.
    pub emails: Vec<AccountEmail>,

    /// Whether two-factor authentication is enabled.
    #[serde(rename = "two_factor_enabled")]
    pub is_two_factor_enabled: bool,

    /// The tenant identifier.
    #[serde(rename = "tenant_id")]
    pub tenant_id: String,

    /// The S3 endpoint gateway URL.
    #[serde(rename = "endpoint_gateway")]
    pub endpoint_gateway: String,

    /// The authentication provider.
    #[serde(rename = "auth_provider")]
    pub auth_provider: String,
}
