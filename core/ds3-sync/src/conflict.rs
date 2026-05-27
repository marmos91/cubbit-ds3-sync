//! Deterministic conflict key generation.
//!
//! Generates S3 keys for conflict copies following the pattern:
//! `"filename (Conflict on [hostname] [YYYY-MM-DD HH-MM-SS] [nonce]).ext"`
//!
//! Matches the Swift `ConflictNaming.conflictKey` format exactly.

use chrono::{DateTime, Utc};
use uuid::Uuid;

/// Creates a conflict copy S3 key from the original key, hostname, and date.
///
/// Matches the Swift `ConflictNaming.conflictKey` format exactly:
/// - `"folder/file.txt"` -> `"folder/file (Conflict on Mac 2026-01-15 12-30-45 ab12).txt"`
/// - `"file.txt"` (no folder) -> `"file (Conflict on Mac 2026-01-15 12-30-45 ab12).txt"`
/// - `"folder/.hidden"` (hidden, no ext) -> `"folder/.hidden (Conflict on Mac 2026-01-15 12-30-45 ab12)"`
/// - `"folder/file"` (no ext) -> `"folder/file (Conflict on Mac 2026-01-15 12-30-45 ab12)"`
/// - `"a/b/c.tar.gz"` (multi-dot) -> `"a/b/c.tar (Conflict on Mac 2026-01-15 12-30-45 ab12).gz"`
///
/// If `nonce` is `None`, a 4-character lowercase hex nonce is generated from a UUID.
pub fn conflict_key(
    original_key: &str,
    hostname: &str,
    date: DateTime<Utc>,
    nonce: Option<&str>,
) -> String {
    let date_str = format_date(date);
    let nonce = match nonce {
        Some(n) => n.to_string(),
        None => Uuid::new_v4().to_string()[..4].to_lowercase(),
    };

    // Separate parent path from filename (S3 uses '/' as delimiter)
    let (parent_path, filename) = split_parent_and_filename(original_key);

    // Split filename into name and extension, matching NSString behavior:
    // - ".hidden" -> name=".hidden", ext=""  (hidden file with no real extension)
    // - "file.txt" -> name="file", ext="txt"
    // - "c.tar.gz" -> name="c.tar", ext="gz"
    // - "file" -> name="file", ext=""
    let (name, ext) = split_name_and_extension(filename);

    let suffix = format!(" (Conflict on {hostname} {date_str} {nonce})");
    let new_filename = if ext.is_empty() {
        format!("{name}{suffix}")
    } else {
        format!("{name}{suffix}.{ext}")
    };

    if parent_path.is_empty() {
        new_filename
    } else {
        format!("{parent_path}/{new_filename}")
    }
}

/// Splits an S3 key into parent path and filename.
///
/// Mimics `NSString.deletingLastPathComponent` and `NSString.lastPathComponent`.
fn split_parent_and_filename(key: &str) -> (&str, &str) {
    match key.rfind('/') {
        Some(idx) => (&key[..idx], &key[idx + 1..]),
        None => ("", key),
    }
}

/// Splits a filename into name and extension, matching NSString behavior.
///
/// NSString treats the extension as everything after the last dot, but hidden
/// files (starting with '.') where removing the extension yields an empty string
/// are treated as having no extension.
///
/// Examples:
/// - "file.txt" -> ("file", "txt")
/// - "c.tar.gz" -> ("c.tar", "gz")
/// - ".hidden" -> (".hidden", "")
/// - "file" -> ("file", "")
fn split_name_and_extension(filename: &str) -> (&str, &str) {
    // Find the last dot position
    match filename.rfind('.') {
        Some(dot_pos) => {
            let raw_ext = &filename[dot_pos + 1..];
            let name_without_ext = &filename[..dot_pos];

            // NSString behavior: if the extension is empty (dot at end),
            // or if this is a hidden file where deletingPathExtension is empty,
            // treat the whole thing as the name with no extension.
            let is_hidden_without_ext =
                filename.starts_with('.') && name_without_ext.is_empty();

            if raw_ext.is_empty() || is_hidden_without_ext {
                (filename, "")
            } else {
                (name_without_ext, raw_ext)
            }
        }
        None => (filename, ""),
    }
}

/// Formats a date as "YYYY-MM-DD HH-MM-SS" in UTC, matching Swift's
/// `DateFormatter` with format `"yyyy-MM-dd HH-mm-ss"` and UTC timezone.
fn format_date(date: DateTime<Utc>) -> String {
    date.format("%Y-%m-%d %H-%M-%S").to_string()
}
