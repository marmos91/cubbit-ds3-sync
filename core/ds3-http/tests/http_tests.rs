//! Unit tests for ds3-http crate: URL generation, client creation, key naming.

use ds3_http::urls::CubbitAPIURLs;
use ds3_http::client::SharedHttpClient;
use ds3_http::keys::api_key_name;

// -----------------------------------------------------------------------
// CubbitAPIURLs tests
// -----------------------------------------------------------------------

#[test]
fn test_default_coordinator_challenge_url() {
    let urls = CubbitAPIURLs::default_coordinator();
    assert_eq!(
        urls.challenge_url(),
        "https://api.eu00wi.cubbit.services/iam/v1/auth/signin/challenge"
    );
}

#[test]
fn test_custom_coordinator_strips_trailing_slashes() {
    let urls = CubbitAPIURLs::new("https://custom.api.example.com///");
    assert_eq!(
        urls.challenge_url(),
        "https://custom.api.example.com/iam/v1/auth/signin/challenge"
    );
}

#[test]
fn test_signin_url() {
    let urls = CubbitAPIURLs::default_coordinator();
    assert_eq!(
        urls.signin_url(),
        "https://api.eu00wi.cubbit.services/iam/v1/auth/signin"
    );
}

#[test]
fn test_token_refresh_url() {
    let urls = CubbitAPIURLs::default_coordinator();
    assert_eq!(
        urls.token_refresh_url(),
        "https://api.eu00wi.cubbit.services/iam/v1/auth/refresh/access"
    );
}

#[test]
fn test_forge_access_jwt_url() {
    let urls = CubbitAPIURLs::default_coordinator();
    assert_eq!(
        urls.forge_access_jwt_url(),
        "https://api.eu00wi.cubbit.services/iam/v1/auth/forge/access"
    );
}

#[test]
fn test_accounts_me_url() {
    let urls = CubbitAPIURLs::default_coordinator();
    assert_eq!(
        urls.accounts_me_url(),
        "https://api.eu00wi.cubbit.services/iam/v1/accounts/me"
    );
}

#[test]
fn test_projects_url() {
    let urls = CubbitAPIURLs::default_coordinator();
    assert_eq!(
        urls.projects_url(),
        "https://api.eu00wi.cubbit.services/composer-hub/v1/projects"
    );
}

#[test]
fn test_tenants_url() {
    let urls = CubbitAPIURLs::default_coordinator();
    assert_eq!(
        urls.tenants_url(),
        "https://api.eu00wi.cubbit.services/composer-hub/v1/tenants"
    );
}

#[test]
fn test_keys_url() {
    let urls = CubbitAPIURLs::default_coordinator();
    assert_eq!(
        urls.keys_url(),
        "https://api.eu00wi.cubbit.services/keyvault/api/v3/keys"
    );
}

// -----------------------------------------------------------------------
// SharedHttpClient tests
// -----------------------------------------------------------------------

#[test]
fn test_shared_http_client_creates_successfully() {
    let client = SharedHttpClient::new();
    assert!(client.is_ok(), "SharedHttpClient should create successfully");
}

// -----------------------------------------------------------------------
// API key name tests
// -----------------------------------------------------------------------

#[test]
fn test_api_key_name_basic() {
    let name = api_key_name("user1", "My Project", "abc-123");
    assert_eq!(name, "ds3_drive(user1_my_project_abc-123)");
}

#[test]
fn test_api_key_name_spaces_to_underscores() {
    let name = api_key_name("john_doe", "Test Project Name", "xyz-789");
    assert_eq!(name, "ds3_drive(john_doe_test_project_name_xyz-789)");
}

#[test]
fn test_api_key_name_already_lowercase() {
    let name = api_key_name("admin", "myproject", "uuid-1");
    assert_eq!(name, "ds3_drive(admin_myproject_uuid-1)");
}
