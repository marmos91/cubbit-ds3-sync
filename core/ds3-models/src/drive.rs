//! DS3Drive, SyncAnchor, and Bucket types.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::project::{IAMUser, Project};

/// An S3 bucket reference.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Bucket {
    /// The bucket name.
    pub name: String,
}

/// A synchronization anchor that defines what a DS3 drive syncs.
///
/// Contains the project, IAM user, bucket, and optional prefix. The
/// `IAMUser` field is serialized as `"IAMUser"` (capital letters) to
/// match the existing Swift JSON schema.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SyncAnchor {
    /// The project associated with this sync anchor.
    pub project: Project,

    /// The IAM user that owns this sync anchor.
    #[serde(rename = "IAMUser")]
    pub iam_user: IAMUser,

    /// The S3 bucket to sync.
    pub bucket: Bucket,

    /// An optional prefix to filter files within the bucket.
    pub prefix: Option<String>,
}

/// A DS3 drive instance that maps to an NSFileProviderDomain.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct DS3Drive {
    /// The unique identifier for this drive.
    pub id: Uuid,

    /// The synchronization anchor defining what this drive syncs.
    #[serde(rename = "syncAnchor")]
    pub sync_anchor: SyncAnchor,

    /// The display name of the drive.
    pub name: String,
}
