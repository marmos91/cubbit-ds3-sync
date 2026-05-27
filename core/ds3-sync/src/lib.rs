//! Sync diff computation and conflict resolution for DS3 drives.
//!
//! Computes the difference between local and remote file trees to determine
//! which files need to be created, updated, or deleted. Generates conflict
//! keys for files modified on multiple devices.

pub mod conflict;
pub mod diff;
pub mod tree;

// Re-export primary types and functions for convenience.
pub use conflict::conflict_key;
pub use diff::compute_diff;
pub use tree::TreeSnapshot;
