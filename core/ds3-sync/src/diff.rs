//! Pure sync diff computation.
//!
//! Compares local and remote tree snapshots to produce a `DiffResult` indicating
//! which keys are new/modified and which are deleted. Mirrors Swift's
//! `EnumerationDiff.compute(local:remote:)`.
