//! Challenge retrieval from the Cubbit IAM server.

use ds3_http::client::SharedHttpClient;
use ds3_http::urls::CubbitAPIURLs;
use ds3_models::{Challenge, DS3Error};
use serde::Serialize;

/// Request body for the challenge endpoint.
#[derive(Serialize)]
struct ChallengeRequest {
    email: String,
    #[serde(rename = "tenant_id", skip_serializing_if = "Option::is_none")]
    tenant_id: Option<String>,
}

/// Retrieves a challenge from the Cubbit IAM server.
///
/// POST `{challenge_url}` with `{"email": "...", "tenant_id": "..."}`.
#[tracing::instrument(skip(client, urls))]
pub async fn get_challenge(
    client: &SharedHttpClient,
    urls: &CubbitAPIURLs,
    email: &str,
    tenant_id: Option<&str>,
) -> Result<Challenge, DS3Error> {
    todo!()
}
