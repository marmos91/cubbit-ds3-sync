//! Cubbit API URL generation from a coordinator base URL.
//!
//! Ports the Swift `CubbitAPIURLs` class. All endpoint URLs are derived from
//! a single coordinator base URL via string concatenation.

/// Generates all Cubbit API endpoint URLs from a coordinator base URL.
///
/// Default coordinator: `https://api.eu00wi.cubbit.services`
#[derive(Debug, Clone)]
pub struct CubbitAPIURLs {
    coordinator_url: String,
}

impl CubbitAPIURLs {
    /// Default Cubbit coordinator URL.
    pub const DEFAULT_COORDINATOR_URL: &str = "https://api.eu00wi.cubbit.services";

    /// Creates a new URL generator, stripping trailing slashes from the coordinator URL.
    pub fn new(coordinator_url: &str) -> Self {
        let mut url = coordinator_url.to_string();
        while url.ends_with('/') {
            url.pop();
        }
        Self {
            coordinator_url: url,
        }
    }

    /// Creates a URL generator with the default coordinator.
    pub fn default_coordinator() -> Self {
        Self::new(Self::DEFAULT_COORDINATOR_URL)
    }

    fn iam_base_url(&self) -> String {
        format!("{}/iam/v1", self.coordinator_url)
    }

    fn auth_base_url(&self) -> String {
        format!("{}/auth", self.iam_base_url())
    }

    /// Returns the challenge endpoint URL.
    pub fn challenge_url(&self) -> String {
        format!("{}/signin/challenge", self.auth_base_url())
    }

    /// Returns the signin endpoint URL.
    pub fn signin_url(&self) -> String {
        format!("{}/signin", self.auth_base_url())
    }

    /// Returns the token refresh endpoint URL.
    pub fn token_refresh_url(&self) -> String {
        format!("{}/refresh/access", self.auth_base_url())
    }

    /// Returns the forge access JWT endpoint URL.
    pub fn forge_access_jwt_url(&self) -> String {
        format!("{}/forge/access", self.auth_base_url())
    }

    /// Returns the accounts/me endpoint URL.
    pub fn accounts_me_url(&self) -> String {
        format!("{}/accounts/me", self.iam_base_url())
    }

    fn composer_hub_base_url(&self) -> String {
        format!("{}/composer-hub/v1", self.coordinator_url)
    }

    /// Returns the projects endpoint URL.
    pub fn projects_url(&self) -> String {
        format!("{}/projects", self.composer_hub_base_url())
    }

    /// Returns the tenants endpoint URL.
    pub fn tenants_url(&self) -> String {
        format!("{}/tenants", self.composer_hub_base_url())
    }

    fn keyvault_base_url(&self) -> String {
        format!("{}/keyvault/api/v3", self.coordinator_url)
    }

    /// Returns the keys endpoint URL.
    pub fn keys_url(&self) -> String {
        format!("{}/keys", self.keyvault_base_url())
    }
}
