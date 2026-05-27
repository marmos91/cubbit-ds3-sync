//! Pure sync diff computation.
//!
//! Compares local and remote tree snapshots to produce a `DiffResult` indicating
//! which keys are new/modified and which are deleted. Mirrors Swift's
//! `EnumerationDiff.compute(local:remote:)`.

use std::collections::HashSet;

use ds3_models::sync::DiffResult;

use crate::tree::TreeSnapshot;

/// Computes the diff between a local and remote tree snapshot.
///
/// Algorithm (matches Swift `EnumerationDiff.compute`):
/// 1. Keys in remote but not local -> added to `new_or_modified`
/// 2. Keys in both where ETags differ (including `None` vs `Some`) -> `new_or_modified`
/// 3. Keys in local but not remote -> added to `deleted`
///
/// Two `None` ETags on the same key are treated as identical (no modification).
pub fn compute_diff(local: &TreeSnapshot, remote: &TreeSnapshot) -> DiffResult {
    let local_map = local.inner();
    let remote_map = remote.inner();

    let local_keys: HashSet<&String> = local_map.keys().collect();
    let remote_keys: HashSet<&String> = remote_map.keys().collect();

    // Keys only in remote -> added
    let added: HashSet<String> = remote_keys
        .difference(&local_keys)
        .map(|k| (*k).clone())
        .collect();

    // Keys in both but with different ETags -> modified
    let common = remote_keys.intersection(&local_keys);
    let modified: HashSet<String> = common
        .filter(|key| {
            let local_etag = local_map.get(**key).and_then(|e| e.as_ref());
            let remote_etag = remote_map.get(**key).and_then(|e| e.as_ref());
            local_etag != remote_etag
        })
        .map(|k| (*k).clone())
        .collect();

    // Keys only in local -> deleted
    let deleted: HashSet<String> = local_keys
        .difference(&remote_keys)
        .map(|k| (*k).clone())
        .collect();

    DiffResult {
        new_or_modified: added.union(&modified).cloned().collect(),
        deleted,
    }
}
