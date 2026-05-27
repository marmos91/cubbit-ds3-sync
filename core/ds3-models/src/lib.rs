//! DS3 domain model types shared across all crates.
//!
//! This crate defines the data types that represent the Cubbit DS3 domain:
//! accounts, authentication tokens, drives, projects, API keys, S3 objects,
//! sync state, and errors. All types implement `Serialize`/`Deserialize`
//! with field names matching the existing Swift/JSON schemas.
