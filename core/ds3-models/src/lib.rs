//! DS3 domain model types shared across all crates.
//!
//! This crate defines the data types that represent the Cubbit DS3 domain:
//! accounts, authentication tokens, drives, projects, API keys, S3 objects,
//! sync state, and errors. All types implement `Serialize`/`Deserialize`
//! with field names matching the existing Swift/JSON schemas.

pub mod account;
pub mod api_key;
pub mod auth;
pub mod drive;
pub mod error;
pub mod project;
pub mod s3;
pub mod sync;

// Re-export key types at crate root for convenience.
pub use account::{Account, AccountEmail};
pub use api_key::DS3ApiKey;
pub use auth::{AccountSession, Challenge, Token};
pub use drive::{Bucket, DS3Drive, SyncAnchor};
pub use error::DS3Error;
pub use project::{IAMUser, Project};
pub use s3::{
    CompletedPartResult, MultipartUploadContext, S3ListingResult, S3ObjectMetadata,
    S3ObjectSummary, TransferProgress,
};
pub use sync::{ConflictInfo, DiffResult};
