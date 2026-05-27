//! Tree snapshot types for sync diff computation.
//!
//! A `TreeSnapshot` wraps a `HashMap<String, Option<String>>` where each key is
//! an S3 object key and the value is an optional ETag. This mirrors the data
//! structure used in the Swift `EnumerationDiff.compute(local:remote:)` function.
