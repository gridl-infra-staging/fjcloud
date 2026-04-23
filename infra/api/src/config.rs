//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/config.rs.
use reqwest::Url;
use std::net::IpAddr;
use thiserror::Error;

#[derive(Debug, Clone)]
pub struct AybAdminConfig {
    pub base_url: String,
    pub cluster_id: String,
    pub admin_password: String,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub database_url: String,
    pub listen_addr: String,
    pub s3_listen_addr: String,
    pub s3_rate_limit_rps: u32,
    pub jwt_secret: String,
    pub admin_key: String,
    pub stripe_secret_key: Option<String>,
    pub stripe_publishable_key: Option<String>,
    pub stripe_webhook_secret: Option<String>,
    pub stripe_success_url: String,
    pub stripe_cancel_url: String,
    pub internal_auth_token: Option<String>,
    pub ayb_admin: Option<AybAdminConfig>,
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("missing required env var: {0}")]
    Missing(String),
    #[error("invalid env var: {0}")]
    Invalid(String),
    #[error("{0} must be at least {1} characters")]
    TooShort(String, usize),
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        Self::from_reader(|k| std::env::var(k).ok())
    }

    /// Builds configuration from a generic key→value reader closure.
    /// Requires `DATABASE_URL`, `JWT_SECRET` (≥32 chars), and `ADMIN_KEY` (≥16 chars).
    /// Stripe keys, internal auth token, and AYB admin config are all optional.
    pub fn from_reader<F>(read: F) -> Result<Self, ConfigError>
    where
        F: Fn(&str) -> Option<String>,
    {
        let require = |key: &str| read(key).ok_or_else(|| ConfigError::Missing(key.to_string()));
        let require_min_len = |key: &str, min: usize| {
            let value = require(key)?;
            if value.len() < min {
                return Err(ConfigError::TooShort(key.to_string(), min));
            }
            Ok(value)
        };

        let database_url = require("DATABASE_URL")?;
        let jwt_secret = require_min_len("JWT_SECRET", 32)?;
        let admin_key = require_min_len("ADMIN_KEY", 16)?;

        let listen_addr = read("LISTEN_ADDR").unwrap_or_else(|| "0.0.0.0:3001".to_string());
        let s3_listen_addr = read("S3_LISTEN_ADDR").unwrap_or_else(|| "0.0.0.0:3002".to_string());
        let s3_rate_limit_rps = parse_u32_with_default(read("S3_RATE_LIMIT_RPS"), 100)
            .map_err(|_| ConfigError::Invalid("S3_RATE_LIMIT_RPS".to_string()))?;

        let stripe_secret_key = read("STRIPE_SECRET_KEY");
        let stripe_publishable_key = read("STRIPE_PUBLISHABLE_KEY");
        let stripe_webhook_secret = read("STRIPE_WEBHOOK_SECRET");
        let stripe_success_url = read("STRIPE_SUCCESS_URL")
            .unwrap_or_else(|| "http://localhost:5173/dashboard".to_string());
        let stripe_cancel_url = read("STRIPE_CANCEL_URL")
            .unwrap_or_else(|| "http://localhost:5173/dashboard".to_string());
        let internal_auth_token = read("INTERNAL_AUTH_TOKEN")
            .map(|token| token.trim().to_string())
            .map(|token| {
                if token.is_empty() {
                    Err(ConfigError::Invalid("INTERNAL_AUTH_TOKEN".to_string()))
                } else {
                    Ok(token)
                }
            })
            .transpose()?;

        let ayb_admin = parse_ayb_admin_config(&read)?;

        Ok(Config {
            database_url,
            listen_addr,
            s3_listen_addr,
            s3_rate_limit_rps,
            jwt_secret,
            admin_key,
            stripe_secret_key,
            stripe_publishable_key,
            stripe_webhook_secret,
            stripe_success_url,
            stripe_cancel_url,
            internal_auth_token,
            ayb_admin,
        })
    }
}

fn parse_u32_with_default(value: Option<String>, default_value: u32) -> Result<u32, ()> {
    match value {
        Some(raw) => raw.trim().parse::<u32>().map_err(|_| ()),
        None => Ok(default_value),
    }
}

/// Parses AYB admin configuration with all-or-nothing semantics: all three of
/// `AYB_BASE_URL`, `AYB_CLUSTER_ID`, and `AYB_ADMIN_PASSWORD` must be present or
/// absent together. Validates the base URL scheme (HTTPS required, HTTP allowed
/// only for localhost).
fn parse_ayb_admin_config(
    read: &dyn Fn(&str) -> Option<String>,
) -> Result<Option<AybAdminConfig>, ConfigError> {
    let base_url = read("AYB_BASE_URL").map(|s| s.trim().to_string());
    let cluster_id = read("AYB_CLUSTER_ID").map(|s| s.trim().to_string());
    let admin_password = read("AYB_ADMIN_PASSWORD").map(|s| s.trim().to_string());

    match (&base_url, &cluster_id, &admin_password) {
        (None, None, None) => return Ok(None),
        (Some(_), Some(_), Some(_)) => {}
        _ => {
            return Err(ConfigError::Invalid(
                "AYB_BASE_URL, AYB_CLUSTER_ID, and AYB_ADMIN_PASSWORD must all be set or all be unset".to_string(),
            ));
        }
    }

    let base_url = base_url.unwrap();
    let cluster_id = cluster_id.unwrap();
    let admin_password = admin_password.unwrap();

    if base_url.is_empty() {
        return Err(ConfigError::Invalid("AYB_BASE_URL".to_string()));
    }
    if cluster_id.is_empty() {
        return Err(ConfigError::Invalid("AYB_CLUSTER_ID".to_string()));
    }
    if admin_password.is_empty() {
        return Err(ConfigError::Invalid("AYB_ADMIN_PASSWORD".to_string()));
    }

    let parsed_base_url =
        Url::parse(&base_url).map_err(|_| ConfigError::Invalid("AYB_BASE_URL".to_string()))?;
    if !ayb_base_url_uses_allowed_transport(&parsed_base_url) {
        return Err(ConfigError::Invalid("AYB_BASE_URL".to_string()));
    }

    Ok(Some(AybAdminConfig {
        base_url,
        cluster_id,
        admin_password,
    }))
}

fn ayb_base_url_uses_allowed_transport(parsed_base_url: &Url) -> bool {
    match parsed_base_url.scheme() {
        "https" => true,
        "http" => parsed_base_url.host_str().is_some_and(|host| {
            host.eq_ignore_ascii_case("localhost")
                || host
                    .parse::<IpAddr>()
                    .map(|ip| ip.is_loopback())
                    .unwrap_or(false)
        }),
        _ => false,
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn reader(vars: HashMap<&'static str, &'static str>) -> impl Fn(&str) -> Option<String> {
        move |k| vars.get(k).map(|v| v.to_string())
    }

    fn valid_env() -> impl Fn(&str) -> Option<String> {
        reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("LISTEN_ADDR", "0.0.0.0:3001"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
        ]))
    }

    #[test]
    fn loads_all_required_fields() {
        let cfg = Config::from_reader(valid_env()).expect("should parse valid config");
        assert_eq!(cfg.database_url, "postgres://localhost/fjcloud");
        assert_eq!(cfg.listen_addr, "0.0.0.0:3001");
        assert_eq!(cfg.s3_listen_addr, "0.0.0.0:3002");
        assert_eq!(cfg.s3_rate_limit_rps, 100);
        assert_eq!(cfg.jwt_secret, "super-secret-key-for-testing-1234");
        assert_eq!(cfg.admin_key, "admin-bootstrap-key-for-testing");
        assert!(cfg.stripe_secret_key.is_none());
        assert!(cfg.stripe_publishable_key.is_none());
        assert!(cfg.stripe_webhook_secret.is_none());
        assert!(cfg.internal_auth_token.is_none());
        assert!(cfg.ayb_admin.is_none());
    }

    /// Verifies that Stripe and internal auth keys are optional in config,
    /// and are correctly parsed when present.
    #[test]
    fn stripe_keys_are_optional() {
        let cfg = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("STRIPE_SECRET_KEY", "sk_test_123"),
            ("STRIPE_PUBLISHABLE_KEY", "pk_test_456"),
            ("STRIPE_WEBHOOK_SECRET", "whsec_789"),
            ("INTERNAL_AUTH_TOKEN", "internal-key-123"),
        ])))
        .expect("should parse with stripe keys");
        assert_eq!(cfg.stripe_secret_key.as_deref(), Some("sk_test_123"));
        assert_eq!(cfg.stripe_publishable_key.as_deref(), Some("pk_test_456"));
        assert_eq!(cfg.stripe_webhook_secret.as_deref(), Some("whsec_789"));
        assert_eq!(cfg.internal_auth_token.as_deref(), Some("internal-key-123"));
    }

    #[test]
    fn internal_auth_token_is_trimmed() {
        let cfg = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("INTERNAL_AUTH_TOKEN", "  internal-key-123  "),
        ])))
        .expect("should parse with internal auth token");

        assert_eq!(cfg.internal_auth_token.as_deref(), Some("internal-key-123"));
    }

    #[test]
    fn internal_auth_token_whitespace_is_rejected() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("INTERNAL_AUTH_TOKEN", "   "),
        ])))
        .unwrap_err();

        assert!(matches!(
            err,
            ConfigError::Invalid(ref key) if key == "INTERNAL_AUTH_TOKEN"
        ));
    }

    #[test]
    fn internal_auth_token_empty_string_is_rejected() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("INTERNAL_AUTH_TOKEN", ""),
        ])))
        .unwrap_err();

        assert!(matches!(
            err,
            ConfigError::Invalid(ref key) if key == "INTERNAL_AUTH_TOKEN"
        ));
    }

    #[test]
    fn missing_listen_addr_uses_default() {
        let cfg = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
        ])))
        .expect("should use default listen_addr");
        assert_eq!(cfg.listen_addr, "0.0.0.0:3001");
        assert_eq!(cfg.s3_listen_addr, "0.0.0.0:3002");
        assert_eq!(cfg.s3_rate_limit_rps, 100);
    }

    #[test]
    fn s3_addr_and_rate_limit_are_loaded_from_env() {
        let cfg = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("S3_LISTEN_ADDR", "127.0.0.1:4002"),
            ("S3_RATE_LIMIT_RPS", "250"),
        ])))
        .expect("should parse S3 config");
        assert_eq!(cfg.s3_listen_addr, "127.0.0.1:4002");
        assert_eq!(cfg.s3_rate_limit_rps, 250);
    }

    #[test]
    fn invalid_s3_rate_limit_is_rejected() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("S3_RATE_LIMIT_RPS", "abc"),
        ])))
        .unwrap_err();

        assert!(matches!(
            err,
            ConfigError::Invalid(ref key) if key == "S3_RATE_LIMIT_RPS"
        ));
    }

    #[test]
    fn missing_database_url_is_error() {
        let err = Config::from_reader(reader(HashMap::from([
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
        ])))
        .unwrap_err();
        assert!(matches!(err, ConfigError::Missing(ref k) if k == "DATABASE_URL"));
    }

    #[test]
    fn missing_jwt_secret_is_error() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
        ])))
        .unwrap_err();
        assert!(matches!(err, ConfigError::Missing(ref k) if k == "JWT_SECRET"));
    }

    #[test]
    fn missing_admin_key_is_error() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
        ])))
        .unwrap_err();
        assert!(matches!(err, ConfigError::Missing(ref k) if k == "ADMIN_KEY"));
    }

    #[test]
    fn short_jwt_secret_is_rejected() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "too-short"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
        ])))
        .unwrap_err();
        assert!(matches!(err, ConfigError::TooShort(ref k, 32) if k == "JWT_SECRET"));
    }

    #[test]
    fn short_admin_key_is_rejected() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "short"),
        ])))
        .unwrap_err();
        assert!(matches!(err, ConfigError::TooShort(ref k, 16) if k == "ADMIN_KEY"));
    }

    #[test]
    fn jwt_secret_at_minimum_length_is_accepted() {
        let secret_32 = "abcdefghijklmnopqrstuvwxyz012345";
        assert_eq!(secret_32.len(), 32);
        let cfg = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", secret_32),
            ("ADMIN_KEY", "admin-key-16-char"),
        ])))
        .expect("32-char JWT_SECRET should be accepted");
        assert_eq!(cfg.jwt_secret, secret_32);
    }

    // ─── AybAdminConfig tests ──────────────────────────────────────────

    fn valid_env_with_ayb() -> impl Fn(&str) -> Option<String> {
        reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("AYB_BASE_URL", "https://ayb.example.com"),
            ("AYB_CLUSTER_ID", "cluster-01"),
            ("AYB_ADMIN_PASSWORD", "s3cret-admin-pw"),
        ]))
    }

    #[test]
    fn ayb_admin_all_present_parses_successfully() {
        let cfg =
            Config::from_reader(valid_env_with_ayb()).expect("should parse with all AYB vars");
        let ayb = cfg.ayb_admin.expect("ayb_admin should be Some");
        assert_eq!(ayb.base_url, "https://ayb.example.com");
        assert_eq!(ayb.cluster_id, "cluster-01");
        assert_eq!(ayb.admin_password, "s3cret-admin-pw");
    }

    #[test]
    fn ayb_admin_all_absent_returns_none() {
        let cfg = Config::from_reader(valid_env()).expect("should parse without AYB vars");
        assert!(cfg.ayb_admin.is_none());
    }

    #[test]
    fn ayb_admin_values_are_trimmed() {
        let cfg = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("AYB_BASE_URL", "  https://ayb.example.com  "),
            ("AYB_CLUSTER_ID", "  cluster-01  "),
            ("AYB_ADMIN_PASSWORD", "  s3cret-admin-pw  "),
        ])))
        .expect("should trim AYB values");
        let ayb = cfg.ayb_admin.expect("ayb_admin should be Some");
        assert_eq!(ayb.base_url, "https://ayb.example.com");
        assert_eq!(ayb.cluster_id, "cluster-01");
        assert_eq!(ayb.admin_password, "s3cret-admin-pw");
    }

    #[test]
    fn ayb_admin_partial_only_base_url_is_rejected() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("AYB_BASE_URL", "https://ayb.example.com"),
        ])))
        .unwrap_err();
        assert!(matches!(err, ConfigError::Invalid(_)));
    }

    #[test]
    fn ayb_admin_partial_only_cluster_id_is_rejected() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("AYB_CLUSTER_ID", "cluster-01"),
        ])))
        .unwrap_err();
        assert!(matches!(err, ConfigError::Invalid(_)));
    }

    #[test]
    fn ayb_admin_partial_only_password_is_rejected() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("AYB_ADMIN_PASSWORD", "s3cret-admin-pw"),
        ])))
        .unwrap_err();
        assert!(matches!(err, ConfigError::Invalid(_)));
    }

    #[test]
    fn ayb_admin_partial_two_of_three_is_rejected() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("AYB_BASE_URL", "https://ayb.example.com"),
            ("AYB_CLUSTER_ID", "cluster-01"),
        ])))
        .unwrap_err();
        assert!(matches!(err, ConfigError::Invalid(_)));
    }

    #[test]
    fn ayb_admin_invalid_url_no_scheme_is_rejected() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("AYB_BASE_URL", "ayb.example.com"),
            ("AYB_CLUSTER_ID", "cluster-01"),
            ("AYB_ADMIN_PASSWORD", "s3cret-admin-pw"),
        ])))
        .unwrap_err();
        assert!(matches!(err, ConfigError::Invalid(ref k) if k == "AYB_BASE_URL"));
    }

    #[test]
    fn ayb_admin_invalid_url_malformed_but_prefixed_is_rejected() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("AYB_BASE_URL", "https://exa mple.com"),
            ("AYB_CLUSTER_ID", "cluster-01"),
            ("AYB_ADMIN_PASSWORD", "s3cret-admin-pw"),
        ])))
        .unwrap_err();
        assert!(matches!(err, ConfigError::Invalid(ref k) if k == "AYB_BASE_URL"));
    }

    #[test]
    fn ayb_admin_loopback_http_url_is_accepted() {
        let cfg = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("AYB_BASE_URL", "http://localhost:8080"),
            ("AYB_CLUSTER_ID", "cluster-01"),
            ("AYB_ADMIN_PASSWORD", "s3cret-admin-pw"),
        ])))
        .expect("http:// URL should be accepted");
        let ayb = cfg.ayb_admin.expect("ayb_admin should be Some");
        assert_eq!(ayb.base_url, "http://localhost:8080");
    }

    #[test]
    fn ayb_admin_non_loopback_http_url_is_rejected() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("AYB_BASE_URL", "http://ayb.example.com"),
            ("AYB_CLUSTER_ID", "cluster-01"),
            ("AYB_ADMIN_PASSWORD", "s3cret-admin-pw"),
        ])))
        .unwrap_err();
        assert!(matches!(err, ConfigError::Invalid(ref k) if k == "AYB_BASE_URL"));
    }

    #[test]
    fn ayb_admin_empty_value_after_trim_is_rejected() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("AYB_BASE_URL", "https://ayb.example.com"),
            ("AYB_CLUSTER_ID", "   "),
            ("AYB_ADMIN_PASSWORD", "s3cret-admin-pw"),
        ])))
        .unwrap_err();
        assert!(matches!(err, ConfigError::Invalid(ref k) if k == "AYB_CLUSTER_ID"));
    }
}
