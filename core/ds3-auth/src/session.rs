//! DS3Session: the opaque authenticated session handle.

use ds3_http::client::SharedHttpClient;
use ds3_http::urls::CubbitAPIURLs;
use ds3_models::{Account, AccountSession, DS3Error, Token};
use std::sync::RwLock;

/// An authenticated DS3 session holding the HTTP client, credentials, and account info.
///
/// The `session` field uses `RwLock` for interior mutability since refresh
/// operations update the token from within.
pub struct DS3Session {
    pub(crate) http: SharedHttpClient,
    pub(crate) urls: CubbitAPIURLs,
    pub(crate) session: RwLock<AccountSession>,
    pub account: Account,
}

impl DS3Session {
    /// Authenticates with Cubbit IAM and returns a new session.
    ///
    /// Orchestrates the full flow:
    /// 1. `get_challenge(email)`
    /// 2. `sign_challenge(challenge, password)`
    /// 3. `post_signin(email, signed_challenge)`
    /// 4. `get_account_info(token)`
    #[tracing::instrument(skip(password))]
    pub async fn authenticate(
        email: &str,
        password: &str,
        tenant_id: Option<&str>,
        coordinator_url: Option<&str>,
    ) -> Result<Self, DS3Error> {
        todo!()
    }

    /// Refreshes the access token if it has expired.
    ///
    /// Checks `token.exp` against the current time. If expired, calls the
    /// refresh endpoint and updates the session via `RwLock` write.
    pub async fn refresh_if_needed(&self) -> Result<(), DS3Error> {
        todo!()
    }

    /// Forges an IAM-scoped token for the specified user ID.
    pub async fn forge_iam_token(&self, user_id: &str) -> Result<Token, DS3Error> {
        todo!()
    }
}

/// Returns `true` if the token's `exp` field is in the past.
pub fn is_token_expired(token: &Token) -> bool {
    todo!()
}
