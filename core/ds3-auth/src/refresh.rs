//! Token refresh and IAM token forging.

use ds3_http::client::SharedHttpClient;
use ds3_http::urls::CubbitAPIURLs;
use ds3_models::{AccountSession, DS3Error, Token};

/// Refreshes the access token using the refresh cookie.
///
/// GET `{token_refresh_url}` with `Cookie: _refresh={refresh_token}`.
/// Returns the new Token and new refresh_token string.
#[tracing::instrument(skip(client, urls, session))]
pub async fn refresh_token(
    client: &SharedHttpClient,
    urls: &CubbitAPIURLs,
    session: &AccountSession,
) -> Result<(Token, String), DS3Error> {
    todo!()
}

/// Forges an IAM-scoped JWT for a specific user_id.
///
/// GET `{forge_access_jwt_url}?user_id={user_id}` with `Cookie: _refresh={refresh_token}`.
/// Returns the IAM Token and new refresh_token string.
#[tracing::instrument(skip(client, urls, session))]
pub async fn forge_iam_token(
    client: &SharedHttpClient,
    urls: &CubbitAPIURLs,
    session: &AccountSession,
    user_id: &str,
) -> Result<(Token, String), DS3Error> {
    todo!()
}
