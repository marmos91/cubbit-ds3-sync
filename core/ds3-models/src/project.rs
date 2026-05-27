//! Project and IAMUser types for the Cubbit DS3 platform.

use serde::{Deserialize, Serialize};

/// An IAM User in the Cubbit DS3 ecosystem.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct IAMUser {
    /// The IAM user ID.
    #[serde(rename = "user_id")]
    pub id: String,

    /// The IAM username.
    #[serde(rename = "user_name")]
    pub username: String,

    /// Whether the user is a root user.
    #[serde(rename = "is_root")]
    pub is_root: bool,
}

/// A project in the Cubbit DS3 ecosystem.
///
/// JSON keys use a `project_` prefix for most fields, matching the API
/// response schema and the Swift `CodingKeys`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Project {
    /// The project unique ID.
    #[serde(rename = "project_id")]
    pub id: String,

    /// The project name.
    #[serde(rename = "project_name")]
    pub name: String,

    /// The project description.
    #[serde(rename = "project_description")]
    pub description: String,

    /// The project email (used for ACL operations, not a real address).
    #[serde(rename = "project_email")]
    pub email: String,

    /// When the project was created (ISO 8601).
    #[serde(rename = "project_created_at")]
    pub created_at: String,

    /// When the project was banned, if applicable.
    #[serde(rename = "project_banned_at")]
    pub banned_at: Option<String>,

    /// The project image URL, if set.
    #[serde(rename = "project_image_url")]
    pub image_url: Option<String>,

    /// The project tenant ID.
    #[serde(rename = "project_tenant_id")]
    pub tenant_id: String,

    /// The root account email, if set.
    #[serde(rename = "root_account_email")]
    pub root_account_email: Option<String>,

    /// The IAM users belonging to this project.
    pub users: Vec<IAMUser>,
}
