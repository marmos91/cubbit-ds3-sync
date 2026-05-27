//! Authentication module for the Cubbit DS3 platform.
//!
//! Implements the challenge-response authentication flow using SHA-256 key
//! derivation and Ed25519 signing. Manages the session lifecycle including
//! login, token refresh, and IAM token forging.
