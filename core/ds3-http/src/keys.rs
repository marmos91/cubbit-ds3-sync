//! API key CRUD operations via the Keyvault API.

use crate::client::SharedHttpClient;
use crate::urls::CubbitAPIURLs;
use ds3_models::{DS3ApiKey, DS3Error};

/// Loads all API keys for a given IAM user.
#[tracing::instrument(skip(client, iam_token, urls))]
pub async fn load_api_keys(
    client: &SharedHttpClient,
    urls: &CubbitAPIURLs,
    iam_token: &str,
    user_id: &str,
) -> Result<Vec<DS3ApiKey>, DS3Error> {
    todo!()
}

/// Creates a new API key for a given IAM user.
#[tracing::instrument(skip(client, iam_token, urls))]
pub async fn create_api_key(
    client: &SharedHttpClient,
    urls: &CubbitAPIURLs,
    iam_token: &str,
    user_id: &str,
    key_name: &str,
) -> Result<DS3ApiKey, DS3Error> {
    todo!()
}

/// Deletes an API key by its access key ID (URL-encoded).
#[tracing::instrument(skip(client, iam_token, urls))]
pub async fn delete_api_key(
    client: &SharedHttpClient,
    urls: &CubbitAPIURLs,
    iam_token: &str,
    user_id: &str,
    api_key_id: &str,
) -> Result<(), DS3Error> {
    todo!()
}

/// Generates a deterministic API key name matching the Swift pattern:
/// `ds3_drive({username}_{project_name_lowercased_spaces_to_underscores}_{app_uuid})`
pub fn api_key_name(username: &str, project_name: &str, app_uuid: &str) -> String {
    todo!()
}
