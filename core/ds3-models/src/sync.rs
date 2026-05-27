//! Sync diff result and conflict info types.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Result of computing the diff between local and remote file trees.
///
/// Mirrors the Swift `EnumerationDelta` type: `new_or_modified` contains keys
/// that are new or changed (different ETags), and `deleted` contains keys
/// present locally but absent remotely.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct DiffResult {
    /// Keys that are new or have a different ETag compared to the local tree.
    pub new_or_modified: HashSet<String>,

    /// Keys that exist locally but no longer exist remotely.
    pub deleted: HashSet<String>,
}

impl DiffResult {
    /// Returns true if there are no changes to apply.
    pub fn is_empty(&self) -> bool {
        self.new_or_modified.is_empty() && self.deleted.is_empty()
    }
}

/// Information about a detected file conflict, sent via IPC from the
/// File Provider extension to the main app.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ConflictInfo {
    /// The drive where the conflict occurred.
    #[serde(rename = "driveId")]
    pub drive_id: Uuid,

    /// The original filename (user-facing, without S3 path prefix).
    #[serde(rename = "originalFilename")]
    pub original_filename: String,

    /// The full S3 key of the conflict copy.
    #[serde(rename = "conflictKey")]
    pub conflict_key: String,
}
