//! Deterministic conflict key generation.
//!
//! Generates S3 keys for conflict copies following the pattern:
//! `"filename (Conflict on [hostname] [YYYY-MM-DD HH-MM-SS] [nonce]).ext"`
//!
//! Matches the Swift `ConflictNaming.conflictKey` format exactly.
