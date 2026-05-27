//! Shared HTTP client with cookie jar for Cubbit API calls.

use ds3_models::DS3Error;
use serde::de::DeserializeOwned;
use serde::Serialize;

/// Shared HTTP client wrapping reqwest with cookie jar support.
///
/// The cookie jar enables automatic `_refresh` token lifecycle management
/// across login, refresh, and forge requests.
pub struct SharedHttpClient {
    inner: reqwest::Client,
}

impl SharedHttpClient {
    /// Creates a new shared HTTP client with cookie store enabled.
    pub fn new() -> Result<Self, DS3Error> {
        todo!()
    }

    /// Returns a reference to the inner reqwest client.
    pub fn inner(&self) -> &reqwest::Client {
        &self.inner
    }

    /// Sends a GET request and deserializes the JSON response.
    #[tracing::instrument(skip(self, bearer_token))]
    pub async fn get_json<T: DeserializeOwned>(
        &self,
        url: &str,
        bearer_token: Option<&str>,
    ) -> Result<T, DS3Error> {
        todo!()
    }

    /// Sends a POST request with a JSON body and deserializes the response.
    #[tracing::instrument(skip(self, body, bearer_token))]
    pub async fn post_json<B: Serialize, T: DeserializeOwned>(
        &self,
        url: &str,
        body: &B,
        bearer_token: Option<&str>,
    ) -> Result<T, DS3Error> {
        todo!()
    }

    /// Sends a DELETE request and returns success/failure.
    #[tracing::instrument(skip(self, bearer_token))]
    pub async fn delete(
        &self,
        url: &str,
        bearer_token: Option<&str>,
    ) -> Result<(), DS3Error> {
        todo!()
    }
}
