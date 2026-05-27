//! API key CRUD operations via the Keyvault API.
//!
//! Ports the Swift `DS3SDK` API key management methods. The key naming function
//! produces deterministic names matching the Swift client's format.

use crate::client::SharedHttpClient;
use crate::urls::CubbitAPIURLs;
use ds3_models::{DS3ApiKey, DS3Error};

/// Loads all API keys for a given IAM user.
///
/// GET `{keys_url}?user_id={user_id}` with Bearer auth.
#[tracing::instrument(skip(client, iam_token, urls))]
pub async fn load_api_keys(
    client: &SharedHttpClient,
    urls: &CubbitAPIURLs,
    iam_token: &str,
    user_id: &str,
) -> Result<Vec<DS3ApiKey>, DS3Error> {
    let url = format!("{}?user_id={}", urls.keys_url(), user_id);
    client
        .get_json::<Vec<DS3ApiKey>>(&url, Some(iam_token))
        .await
}

/// Creates a new API key for a given IAM user.
///
/// POST `{keys_url}/{key_name}?user_id={user_id}` with Bearer auth.
#[tracing::instrument(skip(client, iam_token, urls))]
pub async fn create_api_key(
    client: &SharedHttpClient,
    urls: &CubbitAPIURLs,
    iam_token: &str,
    user_id: &str,
    key_name: &str,
) -> Result<DS3ApiKey, DS3Error> {
    let url = format!(
        "{}/{}?user_id={}",
        urls.keys_url(),
        key_name,
        user_id,
    );

    // POST with empty body -- the server creates the key based on URL params.
    let response = client
        .inner()
        .post(&url)
        .bearer_auth(iam_token)
        .send()
        .await?;

    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        return Err(DS3Error::ServerError {
            status: status.as_u16(),
            body,
        });
    }

    let api_key =
        response
            .json::<DS3ApiKey>()
            .await
            .map_err(|e| DS3Error::JsonError {
                message: e.to_string(),
            })?;

    Ok(api_key)
}

/// Deletes an API key by its access key ID (URL-encoded in path).
///
/// DELETE `{keys_url}/{url_encoded_api_key_id}?user_id={user_id}` with Bearer auth.
#[tracing::instrument(skip(client, iam_token, urls))]
pub async fn delete_api_key(
    client: &SharedHttpClient,
    urls: &CubbitAPIURLs,
    iam_token: &str,
    user_id: &str,
    api_key_id: &str,
) -> Result<(), DS3Error> {
    let encoded_key = urlencoding::encode(api_key_id);
    let url = format!(
        "{}/{}?user_id={}",
        urls.keys_url(),
        encoded_key,
        user_id,
    );

    client.delete(&url, Some(iam_token)).await
}

/// Generates a deterministic API key name matching the Swift pattern:
/// `ds3_drive({username}_{project_name_lowercased_spaces_to_underscores}_{app_uuid})`
///
/// This mirrors the Swift `DS3SDK.apiKeyName(forUser:projectName:)` method,
/// with the `app_uuid` provided externally (platform-dependent storage).
pub fn api_key_name(username: &str, project_name: &str, app_uuid: &str) -> String {
    let normalized = project_name.to_lowercase().replace(' ', "_");
    format!("ds3_drive({username}_{normalized}_{app_uuid})")
}
