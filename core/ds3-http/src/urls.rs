//! Cubbit API URL generation from a coordinator base URL.

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
        todo!()
    }

    /// Creates a URL generator with the default coordinator.
    pub fn default_coordinator() -> Self {
        todo!()
    }

    fn iam_base_url(&self) -> String {
        todo!()
    }

    fn auth_base_url(&self) -> String {
        todo!()
    }

    /// Returns the challenge endpoint URL.
    pub fn challenge_url(&self) -> String {
        todo!()
    }

    /// Returns the signin endpoint URL.
    pub fn signin_url(&self) -> String {
        todo!()
    }

    /// Returns the token refresh endpoint URL.
    pub fn token_refresh_url(&self) -> String {
        todo!()
    }

    /// Returns the forge access JWT endpoint URL.
    pub fn forge_access_jwt_url(&self) -> String {
        todo!()
    }

    /// Returns the accounts/me endpoint URL.
    pub fn accounts_me_url(&self) -> String {
        todo!()
    }

    fn composer_hub_base_url(&self) -> String {
        todo!()
    }

    /// Returns the projects endpoint URL.
    pub fn projects_url(&self) -> String {
        todo!()
    }

    /// Returns the tenants endpoint URL.
    pub fn tenants_url(&self) -> String {
        todo!()
    }

    fn keyvault_base_url(&self) -> String {
        todo!()
    }

    /// Returns the keys endpoint URL.
    pub fn keys_url(&self) -> String {
        todo!()
    }
}
