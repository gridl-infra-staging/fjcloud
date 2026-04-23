//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/tests/common/integration_helpers.rs.
// Integration test helpers for fjcloud API.
//
// These helpers are used by integration tests that run against a live stack
// (Postgres + fjcloud API + optionally flapjack).
//
// ## How to run integration tests
//
// Prerequisites:
//   - PostgreSQL 16 running locally
//   - flapjack binary built (optional — only needed for proxy/metering tests)
//   - Ports 3099 (API) and 7799 (flapjack) available
//
// Quick start:
//   ./scripts/integration-test.sh
//
// Manual start:
//   1. ./scripts/integration-up.sh
//   2. INTEGRATION=1 cargo test -p api integration_ -- --test-threads=1
//   3. ./scripts/integration-down.sh
//
// Integration tests are SKIPPED when INTEGRATION env var is not set.

#![allow(dead_code)]
#![allow(clippy::items_after_test_module)]

use reqwest::Client;
use serde_json::Value;
use std::sync::{Mutex, MutexGuard, OnceLock};

// ---------------------------------------------------------------------------
// Constants — must match scripts/integration-up.sh defaults
// ---------------------------------------------------------------------------

pub const API_BASE: &str = "http://localhost:3099";
pub const FLAPJACK_BASE: &str = "http://localhost:7799";
pub const DEFAULT_JWT_SECRET: &str = "integration-test-jwt-secret-000000";
pub const DEFAULT_ADMIN_KEY: &str = "integration-test-admin-key";

// ---------------------------------------------------------------------------
// Env-var gating
// ---------------------------------------------------------------------------

#[doc(hidden)]
#[macro_export]
macro_rules! __integration_flag_enabled {
    ($env_var:literal) => {
        std::env::var($env_var)
            .map(|value| value == "1")
            .unwrap_or(false)
    };
}

/// Returns true when the integration test stack is available.
/// Tests should call this and return early when false.
/// Only enabled when `INTEGRATION=1` — any other value (0, false, etc.) is treated as disabled.
pub fn integration_enabled() -> bool {
    __integration_flag_enabled!("INTEGRATION")
}

/// Returns true when the backend live gate is active.
/// When `BACKEND_LIVE_GATE=1`, integration tests that would normally skip
/// (due to missing infrastructure) must instead FAIL — ensuring that a
/// launch-mode run proves real execution, not just silent skips.
pub fn live_gate_enabled() -> bool {
    __integration_flag_enabled!("BACKEND_LIVE_GATE")
}

/// Global lock for integration tests that mutate process env vars.
///
/// Test binaries include helper tests that toggle env vars like
/// `BACKEND_LIVE_GATE`. This lock allows tests that rely on those vars
/// to serialize reads/writes and avoid cross-test races.
pub fn test_env_lock() -> MutexGuard<'static, ()> {
    static ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    ENV_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

/// Gate macro for live-mode enforcement.
///
/// - If `$condition` is true, execution continues normally.
/// - If `$condition` is false and `BACKEND_LIVE_GATE=1`, panics with a clear
///   message explaining which precondition failed and why.
/// - If `$condition` is false and the gate is off, prints a skip message and
///   returns from the enclosing function (silent skip, preserving existing behavior).
///
/// Usage:
/// ```ignore
/// require_live!(stripe_test_key().is_some(), "STRIPE_TEST_SECRET_KEY not set");
/// ```
#[macro_export]
macro_rules! require_live {
    ($condition:expr, $reason:expr) => {
        if !$condition {
            if $crate::__integration_flag_enabled!("BACKEND_LIVE_GATE") {
                panic!(
                    "[BACKEND_LIVE_GATE] required precondition failed: {}",
                    $reason
                );
            } else {
                eprintln!("[skip] {}", $reason);
                return;
            }
        }
    };
}

/// Macro that wraps an async integration test with the INTEGRATION env-var gate.
/// When INTEGRATION is not set, the test returns immediately (skipped).
///
/// Usage:
/// ```ignore
/// integration_test!(my_test_name, async {
///     let client = reqwest::Client::new();
///     // ... test body
/// });
/// ```
#[macro_export]
macro_rules! integration_test {
    ($name:ident, async $body:block) => {
        #[tokio::test]
        async fn $name() {
            if !$crate::__integration_flag_enabled!("INTEGRATION") {
                // Not running against live stack — skip silently.
                return;
            }
            $body
        }
    };
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

/// Build a reqwest Client suitable for integration tests.
pub fn http_client() -> Client {
    Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .expect("failed to build HTTP client")
}

/// Returns the API base URL, reading from env or falling back to default.
pub fn api_base() -> String {
    std::env::var("INTEGRATION_API_BASE").unwrap_or_else(|_| API_BASE.to_string())
}

/// Returns the flapjack base URL, reading from env or falling back to default.
pub fn flapjack_base() -> String {
    std::env::var("INTEGRATION_FLAPJACK_BASE").unwrap_or_else(|_| FLAPJACK_BASE.to_string())
}

/// Returns true when an endpoint host:port accepts a TCP connection.
/// Used to defer integration tests gracefully when the live stack is not running.
pub async fn endpoint_reachable(base_url: &str) -> bool {
    let parsed = match reqwest::Url::parse(base_url) {
        Ok(url) => url,
        Err(_) => return false,
    };

    let host = match parsed.host_str() {
        Some(host) => host,
        None => return false,
    };
    let port = parsed
        .port_or_known_default()
        .unwrap_or(if parsed.scheme() == "https" { 443 } else { 80 });

    tokio::time::timeout(
        std::time::Duration::from_millis(500),
        tokio::net::TcpStream::connect((host, port)),
    )
    .await
    .is_ok_and(|result| result.is_ok())
}

/// Returns true when the integration database is connectable.
/// Used with `require_live!` to enforce DB availability under BACKEND_LIVE_GATE.
pub async fn db_url_available() -> bool {
    let url = db_url();
    tokio::time::timeout(
        std::time::Duration::from_millis(2000),
        sqlx::PgPool::connect(&url),
    )
    .await
    .is_ok_and(|result| result.is_ok())
}

/// Returns the database URL for direct DB operations in integration tests.
pub fn db_url() -> String {
    if let Ok(url) = std::env::var("INTEGRATION_DB_URL") {
        return url;
    }

    let host = std::env::var("INTEGRATION_DB_HOST").unwrap_or_else(|_| "localhost".to_string());
    let port = std::env::var("INTEGRATION_DB_PORT").unwrap_or_else(|_| "5432".to_string());
    let user = std::env::var("INTEGRATION_DB_USER").ok();
    let password = std::env::var("INTEGRATION_DB_PASSWORD").ok();
    let db_name =
        std::env::var("INTEGRATION_DB").unwrap_or_else(|_| "fjcloud_integration_test".to_string());

    if let Some(user) = user {
        if let Some(password) = password {
            format!("postgres://{user}:{password}@{host}:{port}/{db_name}")
        } else {
            format!("postgres://{user}@{host}:{port}/{db_name}")
        }
    } else {
        format!("postgres://{host}:{port}/{db_name}")
    }
}

/// Returns the JWT secret used by the integration API instance.
pub fn jwt_secret() -> String {
    std::env::var("INTEGRATION_JWT_SECRET").unwrap_or_else(|_| DEFAULT_JWT_SECRET.to_string())
}

/// Returns the admin API key used by the integration API instance.
pub fn admin_key() -> String {
    std::env::var("INTEGRATION_ADMIN_KEY").unwrap_or_else(|_| DEFAULT_ADMIN_KEY.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct EnvGuard<'a> {
        vars: Vec<(&'static str, Option<String>)>,
        // Hold the lock for the duration of the test.
        _lock: std::sync::MutexGuard<'a, ()>,
    }

    impl<'a> EnvGuard<'a> {
        fn new(lock: std::sync::MutexGuard<'a, ()>, keys: &[&'static str]) -> Self {
            let vars = keys
                .iter()
                .map(|k| (*k, std::env::var(k).ok()))
                .collect::<Vec<_>>();
            Self { vars, _lock: lock }
        }
    }

    impl Drop for EnvGuard<'_> {
        fn drop(&mut self) {
            for (k, v) in &self.vars {
                if let Some(value) = v {
                    std::env::set_var(k, value);
                } else {
                    std::env::remove_var(k);
                }
            }
        }
    }

    /// Verifies that `INTEGRATION_DB_URL` takes precedence over all discrete
    /// `INTEGRATION_DB_*` variables when constructing the connection string.
    ///
    /// Guards against regressions where changes to `db_url()` accidentally
    /// compose from host/port/user/password even when the full URL override
    /// is provided.
    #[test]
    fn db_url_prefers_explicit_url_env() {
        let lock = test_env_lock();
        let _guard = EnvGuard::new(
            lock,
            &[
                "INTEGRATION_DB_URL",
                "INTEGRATION_DB_HOST",
                "INTEGRATION_DB_PORT",
                "INTEGRATION_DB_USER",
                "INTEGRATION_DB_PASSWORD",
                "INTEGRATION_DB",
            ],
        );

        std::env::set_var("INTEGRATION_DB_URL", "postgres://a:b@c:123/d");
        std::env::set_var("INTEGRATION_DB_HOST", "ignored-host");
        std::env::set_var("INTEGRATION_DB_PORT", "9999");
        std::env::set_var("INTEGRATION_DB_USER", "ignored-user");
        std::env::set_var("INTEGRATION_DB_PASSWORD", "ignored-pass");
        std::env::set_var("INTEGRATION_DB", "ignored-db");

        assert_eq!(db_url(), "postgres://a:b@c:123/d");
    }

    /// Verifies that `db_url()` assembles a correct `postgres://user:password@host:port/db`
    /// URL from discrete env vars when `INTEGRATION_DB_URL` is absent.
    ///
    /// Ensures the password is included in the credential segment when
    /// `INTEGRATION_DB_PASSWORD` is set, and that the non-default port and
    /// database name are both reflected in the output.
    #[test]
    fn db_url_builds_from_discrete_env_vars_with_password() {
        let lock = test_env_lock();
        let _guard = EnvGuard::new(
            lock,
            &[
                "INTEGRATION_DB_URL",
                "INTEGRATION_DB_HOST",
                "INTEGRATION_DB_PORT",
                "INTEGRATION_DB_USER",
                "INTEGRATION_DB_PASSWORD",
                "INTEGRATION_DB",
            ],
        );

        std::env::remove_var("INTEGRATION_DB_URL");
        std::env::set_var("INTEGRATION_DB_HOST", "db.local");
        std::env::set_var("INTEGRATION_DB_PORT", "15432");
        std::env::set_var("INTEGRATION_DB_USER", "fjcloud");
        std::env::set_var("INTEGRATION_DB_PASSWORD", "fjcloud");
        std::env::set_var("INTEGRATION_DB", "fjcloud_integration_test");

        assert_eq!(
            db_url(),
            "postgres://fjcloud:fjcloud@db.local:15432/fjcloud_integration_test"
        );
    }

    /// Verifies that `db_url()` produces `postgres://host:port/db` (no credentials)
    /// when neither `INTEGRATION_DB_USER` nor `INTEGRATION_DB_PASSWORD` is set.
    ///
    /// This matches local development environments where the DB accepts
    /// peer/trust auth and no username is needed in the connection string.
    #[test]
    fn db_url_includes_port_without_user() {
        let lock = test_env_lock();
        let _guard = EnvGuard::new(
            lock,
            &[
                "INTEGRATION_DB_URL",
                "INTEGRATION_DB_HOST",
                "INTEGRATION_DB_PORT",
                "INTEGRATION_DB_USER",
                "INTEGRATION_DB_PASSWORD",
                "INTEGRATION_DB",
            ],
        );

        std::env::remove_var("INTEGRATION_DB_URL");
        std::env::set_var("INTEGRATION_DB_HOST", "db.local");
        std::env::set_var("INTEGRATION_DB_PORT", "15432");
        std::env::remove_var("INTEGRATION_DB_USER");
        std::env::remove_var("INTEGRATION_DB_PASSWORD");
        std::env::set_var("INTEGRATION_DB", "mydb");

        assert_eq!(db_url(), "postgres://db.local:15432/mydb");
    }

    #[test]
    fn integration_enabled_is_false_when_unset() {
        let lock = test_env_lock();
        let _guard = EnvGuard::new(lock, &["INTEGRATION"]);
        std::env::remove_var("INTEGRATION");

        assert!(
            !integration_enabled(),
            "integration should be disabled when INTEGRATION env var is unset"
        );
    }

    #[test]
    fn integration_enabled_is_true_only_for_one() {
        let lock = test_env_lock();
        let _guard = EnvGuard::new(lock, &["INTEGRATION"]);
        std::env::set_var("INTEGRATION", "1");
        assert!(
            integration_enabled(),
            "INTEGRATION=1 should enable integration tests"
        );

        std::env::set_var("INTEGRATION", "true");
        assert!(
            !integration_enabled(),
            "only INTEGRATION=1 should enable integration tests"
        );
    }

    #[tokio::test]
    async fn endpoint_reachable_detects_closed_local_port() {
        assert!(
            !endpoint_reachable("http://127.0.0.1:1").await,
            "endpoint_reachable should return false for a closed local TCP port"
        );
    }

    #[tokio::test]
    async fn endpoint_reachable_rejects_invalid_url() {
        assert!(
            !endpoint_reachable("not-a-url").await,
            "endpoint_reachable should return false for malformed URL input"
        );
    }

    // -----------------------------------------------------------------------
    // Live gate tests
    // -----------------------------------------------------------------------

    #[test]
    fn live_gate_enabled_is_false_when_unset() {
        let lock = test_env_lock();
        let _guard = EnvGuard::new(lock, &["BACKEND_LIVE_GATE"]);
        std::env::remove_var("BACKEND_LIVE_GATE");

        assert!(
            !live_gate_enabled(),
            "live gate should be disabled when BACKEND_LIVE_GATE is unset"
        );
    }

    #[test]
    fn live_gate_enabled_is_true_when_set_to_one() {
        let lock = test_env_lock();
        let _guard = EnvGuard::new(lock, &["BACKEND_LIVE_GATE"]);
        std::env::set_var("BACKEND_LIVE_GATE", "1");

        assert!(
            live_gate_enabled(),
            "live gate should be enabled when BACKEND_LIVE_GATE=1"
        );
    }

    /// Confirms that `BACKEND_LIVE_GATE` must be exactly `"1"` to activate
    /// the live gate — values like `"true"` or `"0"` must not enable it.
    ///
    /// This prevents accidentally enabling the hard-fail mode in CI environments
    /// that set boolean-style env vars instead of the strict `"1"` convention.
    #[test]
    fn live_gate_enabled_is_false_for_non_one_values() {
        let lock = test_env_lock();
        let _guard = EnvGuard::new(lock, &["BACKEND_LIVE_GATE"]);

        std::env::set_var("BACKEND_LIVE_GATE", "true");
        assert!(
            !live_gate_enabled(),
            "only BACKEND_LIVE_GATE=1 should enable the live gate"
        );

        std::env::set_var("BACKEND_LIVE_GATE", "0");
        assert!(
            !live_gate_enabled(),
            "BACKEND_LIVE_GATE=0 should not enable the live gate"
        );
    }

    #[test]
    fn require_live_skips_silently_when_gate_off_and_condition_false() {
        let lock = test_env_lock();
        let _guard = EnvGuard::new(lock, &["BACKEND_LIVE_GATE"]);
        std::env::remove_var("BACKEND_LIVE_GATE");

        // When gate is off and condition is false, require_live! should `return`
        // from this function — causing the test to pass by early exit.
        // If the macro does NOT return, we hit the panic below and the test fails.
        require_live!(false, "test precondition missing");
        panic!(
            "require_live! should have returned from the test function, but execution continued"
        );
    }

    /// Verifies that `require_live!` panics (rather than silently skipping) when
    /// `BACKEND_LIVE_GATE=1` and the supplied condition is false.
    ///
    /// Also asserts that the panic message includes both the caller-supplied
    /// reason string and the `BACKEND_LIVE_GATE` label, so CI failures are
    /// self-explanatory.
    #[test]
    fn require_live_panics_when_gate_on_and_condition_false() {
        let lock = test_env_lock();
        let _guard = EnvGuard::new(lock, &["BACKEND_LIVE_GATE"]);
        std::env::set_var("BACKEND_LIVE_GATE", "1");

        let result = std::panic::catch_unwind(|| {
            require_live!(false, "STRIPE_TEST_SECRET_KEY not set");
        });
        assert!(
            result.is_err(),
            "require_live! should panic when gate is on and condition is false"
        );

        // Verify the panic message contains the reason
        if let Err(panic_val) = result {
            let msg = panic_val
                .downcast_ref::<String>()
                .map(|s| s.as_str())
                .or_else(|| panic_val.downcast_ref::<&str>().copied())
                .unwrap_or("");
            assert!(
                msg.contains("STRIPE_TEST_SECRET_KEY not set"),
                "panic message should contain the reason: got '{msg}'"
            );
            assert!(
                msg.contains("BACKEND_LIVE_GATE"),
                "panic message should mention BACKEND_LIVE_GATE: got '{msg}'"
            );
        }
    }

    /// Verifies that `require_live!` never panics or short-circuits when the
    /// supplied condition is true, regardless of the `BACKEND_LIVE_GATE` state.
    ///
    /// Tests both `BACKEND_LIVE_GATE=1` and unset in the same test to confirm
    /// that a true condition always lets execution continue.
    #[test]
    fn require_live_continues_when_condition_true_regardless_of_gate() {
        let lock = test_env_lock();
        let _guard = EnvGuard::new(lock, &["BACKEND_LIVE_GATE"]);

        // Gate on, condition true → should not panic
        std::env::set_var("BACKEND_LIVE_GATE", "1");
        let result = std::panic::catch_unwind(|| {
            require_live!(true, "this should not appear");
        });
        assert!(
            result.is_ok(),
            "require_live! should not panic when condition is true (gate on)"
        );

        // Gate off, condition true → should not panic
        std::env::remove_var("BACKEND_LIVE_GATE");
        let result = std::panic::catch_unwind(|| {
            require_live!(true, "this should not appear");
        });
        assert!(
            result.is_ok(),
            "require_live! should not panic when condition is true (gate off)"
        );
    }
}

// ---------------------------------------------------------------------------
// Auth helpers
// ---------------------------------------------------------------------------

/// Register a new user, bypass email verification via direct DB update, log in,
/// and return the JWT token.
///
/// This is the standard way to get an authenticated session in integration tests.
pub async fn register_and_login(client: &Client, base: &str, email: &str) -> String {
    let name = email.split('@').next().unwrap_or("testuser");

    // Register
    let register_resp = client
        .post(format!("{base}/auth/register"))
        .json(&serde_json::json!({
            "name": name,
            "email": email,
            "password": "Integration-Test-Pass-1!"
        }))
        .send()
        .await
        .expect("register request failed");

    assert!(
        register_resp.status().is_success(),
        "register failed: {} — {}",
        register_resp.status(),
        register_resp.text().await.unwrap_or_default()
    );

    // Bypass email verification by updating the DB directly
    let pool = sqlx::PgPool::connect(&db_url())
        .await
        .expect("failed to connect to integration DB");
    sqlx::query("UPDATE customers SET email_verified_at = NOW() WHERE email = $1")
        .bind(email)
        .execute(&pool)
        .await
        .expect("failed to verify email in DB");

    // Login
    let login_resp = client
        .post(format!("{base}/auth/login"))
        .json(&serde_json::json!({
            "email": email,
            "password": "Integration-Test-Pass-1!"
        }))
        .send()
        .await
        .expect("login request failed");

    assert!(
        login_resp.status().is_success(),
        "login failed: {} — {}",
        login_resp.status(),
        login_resp.text().await.unwrap_or_default()
    );

    let body: Value = login_resp.json().await.expect("login response not JSON");
    body["token"]
        .as_str()
        .expect("login response missing 'token'")
        .to_string()
}

/// Seed a verified user directly into Postgres (no HTTP round-trip).
/// Returns the user's UUID.
pub async fn seed_verified_user_directly(pool: &sqlx::PgPool, email: &str) -> uuid::Uuid {
    let name = email.split('@').next().unwrap_or("testuser");
    // Use argon2 to hash a known password, matching the API's password hashing
    let password_hash = {
        use argon2::{password_hash::SaltString, Argon2, PasswordHasher};
        let salt = SaltString::generate(&mut rand::thread_rng());
        Argon2::default()
            .hash_password(b"Integration-Test-Pass-1!", &salt)
            .expect("failed to hash password")
            .to_string()
    };

    let row = sqlx::query_scalar::<_, uuid::Uuid>(
        "INSERT INTO customers (id, name, email, status, password_hash, email_verified_at, created_at, updated_at)
         VALUES (gen_random_uuid(), $1, $2, 'active', $3, NOW(), NOW(), NOW())
         RETURNING id"
    )
    .bind(name)
    .bind(email)
    .bind(&password_hash)
    .fetch_one(pool)
    .await
    .expect("failed to seed verified user");

    row
}
