//! Token refresh and IAM token forging.
//!
//! Ports the Swift `refreshIfNeeded` and `forgeIAMToken` methods from
//! `DS3Authentication.swift`. Both use the `_refresh` cookie for authentication.

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
    let response = client
        .inner()
        .get(urls.token_refresh_url())
        .header("Cookie", format!("_refresh={}", session.refresh_token))
        .send()
        .await?;

    parse_token_response(response).await
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
    let url = format!("{}?user_id={}", urls.forge_access_jwt_url(), user_id);

    let response = client
        .inner()
        .get(url)
        .header("Cookie", format!("_refresh={}", session.refresh_token))
        .send()
        .await?;

    parse_token_response(response).await
}

/// Parses a token refresh or forge response.
///
/// Extracts the Token from the JSON body and the new `_refresh` cookie
/// from the `Set-Cookie` response headers.
async fn parse_token_response(
    response: reqwest::Response,
) -> Result<(Token, String), DS3Error> {
    let status = response.status();

    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        return Err(DS3Error::ServerError {
            status: status.as_u16(),
            body,
        });
    }

    // Extract new _refresh cookie from Set-Cookie headers.
    let refresh_token = crate::extract_refresh_cookie(&response)?;

    let token = response
        .json::<Token>()
        .await
        .map_err(|e| DS3Error::JsonError {
            message: e.to_string(),
        })?;

    Ok((token, refresh_token))
}

