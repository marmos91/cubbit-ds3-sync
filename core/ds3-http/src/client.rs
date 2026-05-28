//! Shared HTTP client with cookie jar + retry middleware for Cubbit API calls.
//!
//! Wraps `reqwest::Client` with `cookie_store(true)` to handle the `_refresh`
//! token lifecycle automatically, and applies `reqwest-retry`'s
//! `RetryTransientMiddleware` so transient failures (5xx, 429, network errors)
//! are retried with exponential backoff (max 5 attempts — matching Phase 16
//! D-18 + Soto's `DefaultSettings.S3.maxRetries`).
//!
//! 4xx responses are NOT retried by `RetryTransientMiddleware`, so legitimate
//! client errors (auth required, NotFound) propagate immediately
//! (threat T-16-02-03 mitigation).

use ds3_models::DS3Error;
use reqwest_middleware::{ClientBuilder as MiddlewareClientBuilder, ClientWithMiddleware};
use reqwest_retry::{policies::ExponentialBackoff, RetryTransientMiddleware};
use serde::de::DeserializeOwned;
use serde::Serialize;

/// Maximum retry attempts for transient failures.
///
/// Matches `ds3_s3::MAX_RETRIES` and the original Swift Soto default.
pub const MAX_HTTP_RETRIES: u32 = 5;

/// Shared HTTP client wrapping reqwest with cookie jar + retry middleware.
///
/// The cookie jar enables automatic `_refresh` token lifecycle management
/// across login, refresh, and forge requests. The retry middleware retries
/// transient HTTP failures up to [`MAX_HTTP_RETRIES`] times.
pub struct SharedHttpClient {
    inner: ClientWithMiddleware,
}

impl SharedHttpClient {
    /// Creates a new shared HTTP client with cookie store, default JSON header,
    /// and exponential-backoff retry on transient failures.
    pub fn new() -> Result<Self, DS3Error> {
        let mut headers = reqwest::header::HeaderMap::new();
        headers.insert(
            reqwest::header::CONTENT_TYPE,
            reqwest::header::HeaderValue::from_static("application/json"),
        );

        let raw = reqwest::ClientBuilder::new()
            .cookie_store(true)
            .default_headers(headers)
            .build()
            .map_err(|e| DS3Error::HttpError(e.to_string()))?;

        let retry_policy = ExponentialBackoff::builder().build_with_max_retries(MAX_HTTP_RETRIES);
        let client = MiddlewareClientBuilder::new(raw)
            .with(RetryTransientMiddleware::new_with_policy(retry_policy))
            .build();

        Ok(Self { inner: client })
    }

    /// Returns a reference to the inner middleware-wrapped client.
    ///
    /// The returned type has the same `.get()` / `.post()` / `.delete()` API
    /// as `reqwest::Client`; `send().await` returns a `reqwest_middleware::Error`
    /// instead of `reqwest::Error` (handled by `From<reqwest_middleware::Error>`
    /// on `DS3Error`).
    pub fn inner(&self) -> &ClientWithMiddleware {
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
