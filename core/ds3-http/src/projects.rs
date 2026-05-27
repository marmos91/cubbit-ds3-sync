//! Project listing via the Composer Hub API.

use crate::client::SharedHttpClient;
use crate::urls::CubbitAPIURLs;
use ds3_models::{DS3Error, Project};

/// Fetches the list of projects for the authenticated user.
///
/// GET `{projects_url}` with `Authorization: Bearer {token}`.
#[tracing::instrument(skip(client, token, urls))]
pub async fn get_projects(
    client: &SharedHttpClient,
    urls: &CubbitAPIURLs,
    token: &str,
) -> Result<Vec<Project>, DS3Error> {
    client
        .get_json::<Vec<Project>>(&urls.projects_url(), Some(token))
        .await
}
