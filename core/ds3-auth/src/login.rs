//! Login (signin) and account info retrieval.
//!
//! Ports the Swift `login`, `getAccountSession`, and `accountInfo` methods
//! from `DS3Authentication.swift`.

use ds3_http::client::SharedHttpClient;
use ds3_http::urls::CubbitAPIURLs;
use ds3_models::{Account, AccountSession, DS3Error, Token};
use serde::{Deserialize, Serialize};

/// Request body for the signin endpoint.
///
/// Uses snake_case field names to match the Swift encoder's
/// `convertToSnakeCase` strategy.
#[derive(Serialize)]
struct LoginRequest {
    email: String,
    signed_challenge: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    tfa_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tenant_id: Option<String>,
}

/// Response body when 2FA is required (HTTP 401).
#[derive(Deserialize)]
struct Missing2FAResponse {
    message: String,
}

/// Posts signin credentials and returns an account session.
///
/// Detects 2FA requirement: if the server responds with HTTP 401 and
/// body containing "missing two factor code", returns `DS3Error::Missing2FA`.
///
/// The `_refresh` cookie is extracted from `Set-Cookie` headers and stored
/// in the returned `AccountSession`.
#[tracing::instrument(skip(client, urls, signed_challenge))]
pub async fn post_signin(
    client: &SharedHttpClient,
    urls: &CubbitAPIURLs,
    email: &str,
    signed_challenge: &str,
    tfa_code: Option<&str>,
    tenant_id: Option<&str>,
) -> Result<AccountSession, DS3Error> {
    let body = LoginRequest {
        email: email.to_string(),
        signed_challenge: signed_challenge.to_string(),
        tfa_code: tfa_code.map(|s| s.to_string()),
        tenant_id: tenant_id.map(|s| s.to_string()),
    };

    let response = client
        .inner()
        .post(urls.signin_url())
        .json(&body)
        .send()
        .await?;

    let status = response.status();

    // Check for 2FA requirement (HTTP 401 with specific message).
    if status.as_u16() == 401 {
        let body_text = response.text().await.unwrap_or_default();
        if let Ok(mfa_response) = serde_json::from_str::<Missing2FAResponse>(&body_text) {
            if mfa_response.message == "missing two factor code" {
                return Err(DS3Error::Missing2FA);
            }
        }
        return Err(DS3Error::ServerError {
            status: 401,
            body: body_text,
        });
    }

    if !status.is_success() {
        let body_text = response.text().await.unwrap_or_default();
        return Err(DS3Error::ServerError {
            status: status.as_u16(),
            body: body_text,
        });
    }

    // Extract _refresh cookie from Set-Cookie headers.
    let refresh_token = extract_refresh_cookie(&response)?;

    // Parse token from JSON body.
    let token = response
        .json::<Token>()
        .await
        .map_err(|e| DS3Error::JsonError {
            message: e.to_string(),
        })?;

    Ok(AccountSession {
        token,
        refresh_token,
    })
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
    client
        .get_json::<Account>(&urls.accounts_me_url(), Some(token))
        .await
}

/// Extracts the `_refresh` cookie value from response `Set-Cookie` headers.
fn extract_refresh_cookie(response: &reqwest::Response) -> Result<String, DS3Error> {
    for cookie_header in response.headers().get_all(reqwest::header::SET_COOKIE) {
        let cookie_str = cookie_header.to_str().unwrap_or("");
        // Cookie format: "_refresh=<value>; Path=/; ..."
        if let Some(rest) = cookie_str.strip_prefix("_refresh=") {
            if let Some(value) = rest.split(';').next() {
                if !value.is_empty() {
                    return Ok(value.to_string());
                }
            }
        }
    }
    Err(DS3Error::CookieError)
}
