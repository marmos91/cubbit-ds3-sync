//! Shared HTTP client with cookie jar for Cubbit API calls.
//!
//! Wraps `reqwest::Client` with `cookie_store(true)` to handle the `_refresh`
//! token lifecycle automatically. Provides typed JSON request helpers.

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
    /// Creates a new shared HTTP client with cookie store enabled
    /// and default `Content-Type: application/json` header.
    pub fn new() -> Result<Self, DS3Error> {
        let mut headers = reqwest::header::HeaderMap::new();
        headers.insert(
            reqwest::header::CONTENT_TYPE,
            reqwest::header::HeaderValue::from_static("application/json"),
        );

        let client = reqwest::ClientBuilder::new()
            .cookie_store(true)
            .default_headers(headers)
            .build()
            .map_err(|e| DS3Error::HttpError(e.to_string()))?;

        Ok(Self { inner: client })
    }

    /// Returns a reference to the inner reqwest client.
    pub fn inner(&self) -> &reqwest::Client {
        &self.inner
    }

    /// Sends a GET request and deserializes the JSON response.
    ///
    /// If `bearer_token` is provided, adds an `Authorization: Bearer` header.
    #[tracing::instrument(skip(self, bearer_token))]
    pub async fn get_json<T: DeserializeOwned>(
        &self,
        url: &str,
        bearer_token: Option<&str>,
    ) -> Result<T, DS3Error> {
        let mut req = self.inner.get(url);
        if let Some(token) = bearer_token {
            req = req.bearer_auth(token);
        }

        let response = req.send().await?;
        let status = response.status();

        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(DS3Error::ServerError {
                status: status.as_u16(),
                body,
            });
        }

        let result = response
            .json::<T>()
            .await
            .map_err(|e| DS3Error::JsonError {
                message: e.to_string(),
            })?;

        Ok(result)
    }

    /// Sends a POST request with a JSON body and deserializes the response.
    ///
    /// If `bearer_token` is provided, adds an `Authorization: Bearer` header.
    #[tracing::instrument(skip(self, body, bearer_token))]
    pub async fn post_json<B: Serialize, T: DeserializeOwned>(
        &self,
        url: &str,
        body: &B,
        bearer_token: Option<&str>,
    ) -> Result<T, DS3Error> {
        let mut req = self.inner.post(url).json(body);
        if let Some(token) = bearer_token {
            req = req.bearer_auth(token);
        }

        let response = req.send().await?;
        let status = response.status();

        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(DS3Error::ServerError {
                status: status.as_u16(),
                body,
            });
        }

        let result = response
            .json::<T>()
            .await
            .map_err(|e| DS3Error::JsonError {
                message: e.to_string(),
            })?;

        Ok(result)
    }

    /// Sends a DELETE request and validates the response status.
    ///
    /// If `bearer_token` is provided, adds an `Authorization: Bearer` header.
    #[tracing::instrument(skip(self, bearer_token))]
    pub async fn delete(&self, url: &str, bearer_token: Option<&str>) -> Result<(), DS3Error> {
        let mut req = self.inner.delete(url);
        if let Some(token) = bearer_token {
            req = req.bearer_auth(token);
        }

        let response = req.send().await?;
        let status = response.status();

        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(DS3Error::ServerError {
                status: status.as_u16(),
                body,
            });
        }

        Ok(())
    }
}
