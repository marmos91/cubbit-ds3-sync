//! DS3Session: the opaque authenticated session handle.
//!
//! Orchestrates the full Cubbit IAM auth flow and provides methods for
//! token refresh and IAM token forging.

use crate::challenge::get_challenge;
use crate::crypto::sign_challenge;
use crate::login::{get_account_info, post_signin};
use crate::refresh;
use chrono::Utc;
use ds3_http::client::SharedHttpClient;
use ds3_http::urls::CubbitAPIURLs;
use ds3_models::{Account, AccountSession, DS3Error, Token};
use tokio::sync::{Mutex, MutexGuard};

/// An authenticated DS3 session holding the HTTP client, credentials, and account info.
///
/// The `session` field uses a `Mutex` for interior mutability, serializing
/// token refresh and preventing TOCTOU races.
pub struct DS3Session {
    /// The shared HTTP client with cookie jar for all API calls.
    pub http: SharedHttpClient,
    /// The API URL configuration derived from the coordinator URL.
    pub urls: CubbitAPIURLs,
    /// The current auth session (token + refresh token) behind a Mutex
    /// to serialize token refresh and prevent TOCTOU races.
    pub session: Mutex<AccountSession>,
    /// The authenticated account information.
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
        Self::authenticate_impl(email, password, None, tenant_id, coordinator_url).await
    }

    /// Authenticates with a 2FA code for accounts requiring two-factor auth.
    ///
    /// Same flow as `authenticate` but passes the `tfa_code` to the signin endpoint.
    #[tracing::instrument(skip(password, tfa_code))]
    pub async fn authenticate_with_2fa(
        email: &str,
        password: &str,
        tfa_code: &str,
        tenant_id: Option<&str>,
        coordinator_url: Option<&str>,
    ) -> Result<Self, DS3Error> {
        Self::authenticate_impl(email, password, Some(tfa_code), tenant_id, coordinator_url).await
    }

    /// Shared authentication implementation with optional 2FA code.
    async fn authenticate_impl(
        email: &str,
        password: &str,
        tfa_code: Option<&str>,
        tenant_id: Option<&str>,
        coordinator_url: Option<&str>,
    ) -> Result<Self, DS3Error> {
        let urls = match coordinator_url {
            Some(url) => CubbitAPIURLs::new(url),
            None => CubbitAPIURLs::default_coordinator(),
        };

        let http = SharedHttpClient::new()?;
        let challenge = get_challenge(&http, &urls, email, tenant_id).await?;
        let signed = sign_challenge(&challenge.challenge, password, &challenge.salt)?;
        let account_session =
            post_signin(&http, &urls, email, &signed, tfa_code, tenant_id).await?;
        let account = get_account_info(&http, &urls, &account_session.token.token).await?;

        Ok(Self {
            http,
            urls,
            session: Mutex::new(account_session),
            account,
        })
    }

    /// Restores a session from a persisted refresh token, without email/password.
    ///
    /// Exchanges the saved refresh token at the refresh endpoint for a live access
    /// token (and a freshly rotated refresh token), then re-fetches account info. This
    /// is the cross-platform "stay logged in across launches" path: the platform layer
    /// persists the refresh token in OS-native secure storage (Keychain / Credential
    /// Manager / Keystore) and hands it back here at startup. A revoked or expired
    /// refresh token surfaces as the same error the refresh endpoint returns, so the
    /// caller can fall back to a full login.
    #[tracing::instrument(skip(refresh_token))]
    pub async fn restore_from_refresh_token(
        refresh_token: &str,
        coordinator_url: Option<&str>,
    ) -> Result<Self, DS3Error> {
        let urls = match coordinator_url {
            Some(url) => CubbitAPIURLs::new(url),
            None => CubbitAPIURLs::default_coordinator(),
        };

        let http = SharedHttpClient::new()?;

        // Seed an AccountSession carrying only the saved refresh token; the access-token
        // fields are unused by the refresh call (it authenticates via the `_refresh`
        // cookie), and the exchange returns a fresh token plus a rotated refresh token.
        let seed = AccountSession {
            token: Token {
                token: String::new(),
                exp: 0,
                exp_date: String::new(),
            },
            refresh_token: refresh_token.to_string(),
        };

        let (new_token, new_refresh) = refresh::refresh_token(&http, &urls, &seed).await?;
        let account = get_account_info(&http, &urls, &new_token.token).await?;

        Ok(Self {
            http,
            urls,
            session: Mutex::new(AccountSession {
                token: new_token,
                refresh_token: new_refresh,
            }),
            account,
        })
    }

    /// Refreshes the access token if it has expired.
    ///
    /// Checks `token.exp` against the current UTC time. If expired, calls
    /// the refresh endpoint and updates the session under the Mutex lock.
    pub async fn refresh_if_needed(&self) -> Result<(), DS3Error> {
        let mut session = self.lock_session().await;

        if !is_token_expired(&session.token) {
            return Ok(());
        }

        let (new_token, new_refresh) =
            refresh::refresh_token(&self.http, &self.urls, &session).await?;

        session.token = new_token;
        session.refresh_token = new_refresh;

        Ok(())
    }

    /// Forges an IAM-scoped token for the specified user ID.
    pub async fn forge_iam_token(&self, user_id: &str) -> Result<Token, DS3Error> {
        self.refresh_if_needed().await?;

        let mut session = self.lock_session().await;

        let (iam_token, new_refresh) =
            refresh::forge_iam_token(&self.http, &self.urls, &session, user_id).await?;

        session.refresh_token = new_refresh;

        Ok(iam_token)
    }

    async fn lock_session(&self) -> MutexGuard<'_, AccountSession> {
        self.session.lock().await
    }

    /// Returns a clone of the current `AccountSession` (token + refresh token).
    ///
    /// Used by the FFI surface to reconstruct the Swift-side `AccountSession`
    /// after login/refresh/forge — see PATTERNS.md §"App Group Persistence
    /// Boundary" (D-04, D-06).
    pub async fn current_session(&self) -> AccountSession {
        self.lock_session().await.clone()
    }
}

/// Returns `true` if the token's `exp` field (Unix timestamp) is in the past.
pub fn is_token_expired(token: &Token) -> bool {
    let now = Utc::now().timestamp();
    token.exp < now
}
