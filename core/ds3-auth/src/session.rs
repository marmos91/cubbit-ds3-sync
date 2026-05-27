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
use std::sync::RwLock;

/// An authenticated DS3 session holding the HTTP client, credentials, and account info.
///
/// The `session` field uses `RwLock` for interior mutability since refresh
/// operations update the token from within.
pub struct DS3Session {
    /// The shared HTTP client with cookie jar for all API calls.
    pub http: SharedHttpClient,
    /// The API URL configuration derived from the coordinator URL.
    pub urls: CubbitAPIURLs,
    /// The current auth session (token + refresh token) behind an RwLock
    /// for interior mutability during token refresh.
    pub session: RwLock<AccountSession>,
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
        let urls = match coordinator_url {
            Some(url) => CubbitAPIURLs::new(url),
            None => CubbitAPIURLs::default_coordinator(),
        };

        let http = SharedHttpClient::new()?;

        // Step 1: Get challenge
        let challenge = get_challenge(&http, &urls, email, tenant_id).await?;

        // Step 2: Sign challenge
        let signed = sign_challenge(&challenge.challenge, password, &challenge.salt)?;

        // Step 3: Post signin
        let account_session =
            post_signin(&http, &urls, email, &signed, None, tenant_id).await?;

        // Step 4: Get account info
        let account =
            get_account_info(&http, &urls, &account_session.token.token).await?;

        Ok(Self {
            http,
            urls,
            session: RwLock::new(account_session),
            account,
        })
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
        let urls = match coordinator_url {
            Some(url) => CubbitAPIURLs::new(url),
            None => CubbitAPIURLs::default_coordinator(),
        };

        let http = SharedHttpClient::new()?;

        let challenge = get_challenge(&http, &urls, email, tenant_id).await?;
        let signed = sign_challenge(&challenge.challenge, password, &challenge.salt)?;
        let account_session =
            post_signin(&http, &urls, email, &signed, Some(tfa_code), tenant_id).await?;
        let account =
            get_account_info(&http, &urls, &account_session.token.token).await?;

        Ok(Self {
            http,
            urls,
            session: RwLock::new(account_session),
            account,
        })
    }

    /// Refreshes the access token if it has expired.
    ///
    /// Checks `token.exp` against the current UTC time. If expired, calls
    /// the refresh endpoint and updates the session via `RwLock` write.
    pub async fn refresh_if_needed(&self) -> Result<(), DS3Error> {
        let needs_refresh = {
            let session = self
                .session
                .read()
                .map_err(|_| DS3Error::AuthError("session lock poisoned".into()))?;
            is_token_expired(&session.token)
        };

        if !needs_refresh {
            return Ok(());
        }

        let current_session = {
            self.session
                .read()
                .map_err(|_| DS3Error::AuthError("session lock poisoned".into()))?
                .clone()
        };

        let (new_token, new_refresh) =
            refresh::refresh_token(&self.http, &self.urls, &current_session).await?;

        let mut session = self
            .session
            .write()
            .map_err(|_| DS3Error::AuthError("session lock poisoned".into()))?;
        session.token = new_token;
        session.refresh_token = new_refresh;

        Ok(())
    }

    /// Forges an IAM-scoped token for the specified user ID.
    pub async fn forge_iam_token(&self, user_id: &str) -> Result<Token, DS3Error> {
        self.refresh_if_needed().await?;

        let current_session = {
            self.session
                .read()
                .map_err(|_| DS3Error::AuthError("session lock poisoned".into()))?
                .clone()
        };

        let (iam_token, new_refresh) =
            refresh::forge_iam_token(&self.http, &self.urls, &current_session, user_id)
                .await?;

        // Update refresh token after forge.
        let mut session = self
            .session
            .write()
            .map_err(|_| DS3Error::AuthError("session lock poisoned".into()))?;
        session.refresh_token = new_refresh;

        Ok(iam_token)
    }
}

/// Returns `true` if the token's `exp` field (Unix timestamp) is in the past.
pub fn is_token_expired(token: &Token) -> bool {
    let now = Utc::now().timestamp();
    token.exp < now
}
