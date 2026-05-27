//! Tests for ds3-sync crate: tree snapshots, diff computation, and conflict keys.

use chrono::TimeZone;
use ds3_sync::conflict::conflict_key;
use ds3_sync::diff::compute_diff;
use ds3_sync::tree::TreeSnapshot;

// ============================================================================
// TreeSnapshot tests
// ============================================================================

#[test]
fn tree_snapshot_new_is_empty() {
    let snap = TreeSnapshot::new();
    assert!(snap.is_empty());
    assert_eq!(snap.len(), 0);
}

#[test]
fn tree_snapshot_insert_and_get() {
    let mut snap = TreeSnapshot::new();
    snap.insert("a.txt".to_string(), Some("etag1".to_string()));
    assert_eq!(snap.len(), 1);
    assert!(!snap.is_empty());
    assert_eq!(snap.get("a.txt"), Some(&Some("etag1".to_string())));
}

#[test]
fn tree_snapshot_insert_none_etag() {
    let mut snap = TreeSnapshot::new();
    snap.insert("b.txt".to_string(), None);
    assert_eq!(snap.get("b.txt"), Some(&None));
}

#[test]
fn tree_snapshot_keys() {
    let mut snap = TreeSnapshot::new();
    snap.insert("a.txt".to_string(), Some("e1".to_string()));
    snap.insert("b.txt".to_string(), Some("e2".to_string()));
    let mut keys: Vec<&String> = snap.keys().collect();
    keys.sort();
    assert_eq!(keys, vec!["a.txt", "b.txt"]);
}

#[test]
fn tree_snapshot_overwrite() {
    let mut snap = TreeSnapshot::new();
    snap.insert("a.txt".to_string(), Some("old".to_string()));
    snap.insert("a.txt".to_string(), Some("new".to_string()));
    assert_eq!(snap.len(), 1);
    assert_eq!(snap.get("a.txt"), Some(&Some("new".to_string())));
}

// ============================================================================
// compute_diff tests
// ============================================================================

#[test]
fn diff_remote_adds_new_key() {
    let local = TreeSnapshot::new();
    let mut remote = TreeSnapshot::new();
    remote.insert("a.txt".to_string(), Some("1".to_string()));

    let result = compute_diff(&local, &remote);
    assert!(result.new_or_modified.contains("a.txt"));
    assert!(result.deleted.is_empty());
}

#[test]
fn diff_remote_modifies_existing_key() {
    let mut local = TreeSnapshot::new();
    local.insert("a.txt".to_string(), Some("1".to_string()));
    let mut remote = TreeSnapshot::new();
    remote.insert("a.txt".to_string(), Some("2".to_string()));

    let result = compute_diff(&local, &remote);
    assert!(result.new_or_modified.contains("a.txt"));
    assert!(result.deleted.is_empty());
}

#[test]
fn diff_identical_snapshots_empty() {
    let mut local = TreeSnapshot::new();
    local.insert("a.txt".to_string(), Some("1".to_string()));
    let mut remote = TreeSnapshot::new();
    remote.insert("a.txt".to_string(), Some("1".to_string()));

    let result = compute_diff(&local, &remote);
    assert!(result.is_empty());
}

#[test]
fn diff_local_has_extra_key_deleted() {
    let mut local = TreeSnapshot::new();
    local.insert("b.txt".to_string(), Some("1".to_string()));
    let remote = TreeSnapshot::new();

    let result = compute_diff(&local, &remote);
    assert!(result.deleted.contains("b.txt"));
    assert!(result.new_or_modified.is_empty());
}

#[test]
fn diff_mixed_add_modify_delete() {
    let mut local = TreeSnapshot::new();
    local.insert("a.txt".to_string(), Some("1".to_string()));
    local.insert("b.txt".to_string(), Some("1".to_string()));

    let mut remote = TreeSnapshot::new();
    remote.insert("a.txt".to_string(), Some("2".to_string())); // modified
    remote.insert("c.txt".to_string(), Some("1".to_string())); // added
    // b.txt absent from remote -> deleted

    let result = compute_diff(&local, &remote);
    assert!(result.new_or_modified.contains("a.txt"));
    assert!(result.new_or_modified.contains("c.txt"));
    assert_eq!(result.new_or_modified.len(), 2);
    assert!(result.deleted.contains("b.txt"));
    assert_eq!(result.deleted.len(), 1);
}

#[test]
fn diff_both_empty() {
    let local = TreeSnapshot::new();
    let remote = TreeSnapshot::new();

    let result = compute_diff(&local, &remote);
    assert!(result.is_empty());
}

#[test]
fn diff_none_etag_remote_vs_some_local_is_modified() {
    let mut local = TreeSnapshot::new();
    local.insert("a.txt".to_string(), Some("etag1".to_string()));
    let mut remote = TreeSnapshot::new();
    remote.insert("a.txt".to_string(), None);

    let result = compute_diff(&local, &remote);
    assert!(result.new_or_modified.contains("a.txt"));
}

#[test]
fn diff_some_etag_remote_vs_none_local_is_modified() {
    let mut local = TreeSnapshot::new();
    local.insert("a.txt".to_string(), None);
    let mut remote = TreeSnapshot::new();
    remote.insert("a.txt".to_string(), Some("etag1".to_string()));

    let result = compute_diff(&local, &remote);
    assert!(result.new_or_modified.contains("a.txt"));
}

#[test]
fn diff_none_etag_both_sides_is_identical() {
    let mut local = TreeSnapshot::new();
    local.insert("a.txt".to_string(), None);
    let mut remote = TreeSnapshot::new();
    remote.insert("a.txt".to_string(), None);

    let result = compute_diff(&local, &remote);
    assert!(result.is_empty());
}

// ============================================================================
// conflict_key tests
// ============================================================================

fn test_date() -> chrono::DateTime<chrono::Utc> {
    chrono::Utc.with_ymd_and_hms(2026, 1, 15, 12, 30, 45).unwrap()
}

#[test]
fn conflict_key_standard_file_with_folder() {
    let result = conflict_key("folder/file.txt", "Mac", test_date(), Some("ab12"));
    assert_eq!(
        result,
        "folder/file (Conflict on Mac 2026-01-15 12-30-45 ab12).txt"
    );
}

#[test]
fn conflict_key_root_level_file() {
    let result = conflict_key("file.txt", "Mac", test_date(), Some("ab12"));
    assert_eq!(
        result,
        "file (Conflict on Mac 2026-01-15 12-30-45 ab12).txt"
    );
}

#[test]
fn conflict_key_hidden_file_no_ext() {
    let result = conflict_key("folder/.hidden", "Mac", test_date(), Some("ab12"));
    assert_eq!(
        result,
        "folder/.hidden (Conflict on Mac 2026-01-15 12-30-45 ab12)"
    );
}

#[test]
fn conflict_key_no_extension() {
    let result = conflict_key("folder/file", "Mac", test_date(), Some("ab12"));
    assert_eq!(
        result,
        "folder/file (Conflict on Mac 2026-01-15 12-30-45 ab12)"
    );
}

#[test]
fn conflict_key_multiple_dots() {
    let result = conflict_key("a/b/c.tar.gz", "Mac", test_date(), Some("ab12"));
    assert_eq!(
        result,
        "a/b/c.tar (Conflict on Mac 2026-01-15 12-30-45 ab12).gz"
    );
}

#[test]
fn conflict_key_default_nonce_is_4_chars() {
    let result = conflict_key("file.txt", "Mac", test_date(), None);
    // Pattern: "file (Conflict on Mac 2026-01-15 12-30-45 XXXX).txt"
    // The nonce is 4 lowercase hex chars from UUID
    assert!(result.starts_with("file (Conflict on Mac 2026-01-15 12-30-45 "));
    assert!(result.ends_with(").txt"));
    // Extract nonce: between last space before ')' and ')'
    let suffix_start = "file (Conflict on Mac 2026-01-15 12-30-45 ".len();
    let suffix_end = result.len() - ").txt".len();
    let nonce = &result[suffix_start..suffix_end];
    assert_eq!(nonce.len(), 4);
    assert!(nonce.chars().all(|c| c.is_ascii_hexdigit()));
}

#[test]
fn conflict_key_deeply_nested_path() {
    let result = conflict_key("a/b/c/d/file.txt", "Mac", test_date(), Some("ab12"));
    assert_eq!(
        result,
        "a/b/c/d/file (Conflict on Mac 2026-01-15 12-30-45 ab12).txt"
    );
}

#[test]
fn conflict_key_hostname_with_spaces() {
    let result = conflict_key("file.txt", "My Mac Pro", test_date(), Some("ab12"));
    assert_eq!(
        result,
        "file (Conflict on My Mac Pro 2026-01-15 12-30-45 ab12).txt"
    );
}
