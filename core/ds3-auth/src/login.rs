//! Login (signin) and account info retrieval.

use ds3_http::client::SharedHttpClient;
use ds3_http::urls::CubbitAPIURLs;
use ds3_models::{Account, AccountSession, DS3Error};
use serde::Serialize;

/// Request body for the signin endpoint, using snake_case serialization
/// to match the Swift encoder's `convertToSnakeCase` strategy.
#[derive(Serialize)]
struct LoginRequest {
    email: String,
    signed_challenge: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    tfa_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tenant_id: Option<String>,
}

/// Posts signin credentials and returns an account session.
///
/// Detects 2FA requirement: if the server responds with HTTP 401 and
/// body containing "Missing 2FA" or "missing two factor code",
/// returns `DS3Error::Missing2FA`.
#[tracing::instrument(skip(client, urls, signed_challenge))]
pub async fn post_signin(
    client: &SharedHttpClient,
    urls: &CubbitAPIURLs,
    email: &str,
    signed_challenge: &str,
    tfa_code: Option<&str>,
    tenant_id: Option<&str>,
) -> Result<AccountSession, DS3Error> {
    todo!()
}

/// Retrieves the current account information.
///
/// GET `{accounts_me_url}` with Bearer auth.
#[tracing::instrument(skip(client, urls, token))]
pub async fn get_account_info(
    client: &SharedHttpClient,
    urls: &CubbitAPIURLs,
    token: &str,
) -> Result<Account, DS3Error> {
    todo!()
}
