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

    // new_or_modified = (remote-only keys) + (common keys with different ETags)
    let new_or_modified: HashSet<String> = remote_map
        .keys()
        .filter(|key| {
            match local_map.get(*key) {
                // Key not in local -> new
                None => true,
                // Key in both -> modified if ETags differ
                Some(local_etag) => {
                    let remote_etag = remote_map.get(*key).unwrap();
                    local_etag.as_ref() != remote_etag.as_ref()
                }
            }
        })
        .cloned()
        .collect();

    // deleted = keys in local but not in remote
    let deleted: HashSet<String> = local_keys
        .difference(&remote_keys)
        .map(|k| (*k).clone())
        .collect();

    DiffResult {
        new_or_modified,
        deleted,
    }
}
