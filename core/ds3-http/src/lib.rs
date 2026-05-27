//! HTTP client layer for non-S3 Cubbit API calls.
//!
//! Provides a shared HTTP client with cookie jar support for the Cubbit IAM,
//! Composer Hub, and Keyvault APIs. Handles request construction, response
//! validation, and JSON deserialization.
