//! Tree snapshot types for sync diff computation.
//!
//! A `TreeSnapshot` wraps a `HashMap<String, Option<String>>` where each key is
//! an S3 object key and the value is an optional ETag. This mirrors the data
//! structure used in the Swift `EnumerationDiff.compute(local:remote:)` function.

use std::collections::hash_map::Keys;
use std::collections::HashMap;

/// A snapshot of a file tree, mapping S3 object keys to optional ETags.
///
/// Used as input to [`compute_diff`](crate::diff::compute_diff) to determine
/// which keys are new, modified, or deleted between a local and remote tree.
#[derive(Clone, Debug, Default)]
pub struct TreeSnapshot {
    entries: HashMap<String, Option<String>>,
}

impl TreeSnapshot {
    /// Creates an empty tree snapshot.
    pub fn new() -> Self {
        Self {
            entries: HashMap::new(),
        }
    }

    /// Inserts a key with an optional ETag. Overwrites any existing entry.
    pub fn insert(&mut self, key: String, etag: Option<String>) {
        self.entries.insert(key, etag);
    }

    /// Returns the optional ETag for the given key, or `None` if the key is
    /// not present.
    pub fn get(&self, key: &str) -> Option<&Option<String>> {
        self.entries.get(key)
    }

    /// Returns an iterator over the keys in this snapshot.
    pub fn keys(&self) -> Keys<'_, String, Option<String>> {
        self.entries.keys()
    }

    /// Returns the number of entries in this snapshot.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Returns `true` if this snapshot contains no entries.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Creates a tree snapshot from an existing `HashMap`.
    pub fn from_map(entries: HashMap<String, Option<String>>) -> Self {
        Self { entries }
    }

    /// Returns a reference to the underlying HashMap.
    pub(crate) fn inner(&self) -> &HashMap<String, Option<String>> {
        &self.entries
    }
}
