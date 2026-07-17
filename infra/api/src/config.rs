use thiserror::Error;

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
    pub google_oauth_client_id: Option<String>,
    pub google_oauth_client_secret: Option<String>,
    pub github_oauth_client_id: Option<String>,
    pub github_oauth_client_secret: Option<String>,
    pub dunning_emails_disabled: bool,
    pub algolia_migration_enabled: bool,
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
    /// Stripe keys and internal auth token are optional.
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
            .unwrap_or_else(|| "http://localhost:5173/console".to_string());
        let stripe_cancel_url = read("STRIPE_CANCEL_URL")
            .unwrap_or_else(|| "http://localhost:5173/console".to_string());
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

        let (google_oauth_client_id, google_oauth_client_secret) = parse_optional_oauth_pair(
            &read,
            "GOOGLE_OAUTH_CLIENT_ID",
            "GOOGLE_OAUTH_CLIENT_SECRET",
        )?;
        let (github_oauth_client_id, github_oauth_client_secret) = parse_optional_oauth_pair(
            &read,
            "GITHUB_OAUTH_CLIENT_ID",
            "GITHUB_OAUTH_CLIENT_SECRET",
        )?;
        let dunning_emails_disabled = parse_bool_with_default(
            read("DUNNING_EMAILS_DISABLED"),
            "DUNNING_EMAILS_DISABLED",
            false,
        )?;
        let algolia_migration_enabled = parse_bool_with_default(
            read("FJCLOUD_ALGOLIA_MIGRATION_ENABLED"),
            "FJCLOUD_ALGOLIA_MIGRATION_ENABLED",
            false,
        )?;

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
            google_oauth_client_id,
            google_oauth_client_secret,
            github_oauth_client_id,
            github_oauth_client_secret,
            dunning_emails_disabled,
            algolia_migration_enabled,
        })
    }
}

fn parse_optional_oauth_pair<F>(
    read: &F,
    id_key: &str,
    secret_key: &str,
) -> Result<(Option<String>, Option<String>), ConfigError>
where
    F: Fn(&str) -> Option<String>,
{
    let id = normalize_optional_env(read(id_key), id_key)?;
    let secret = normalize_optional_env(read(secret_key), secret_key)?;

    match (id, secret) {
        (Some(client_id), Some(client_secret)) => Ok((Some(client_id), Some(client_secret))),
        (None, None) => Ok((None, None)),
        (Some(_), None) => Err(ConfigError::Invalid(secret_key.to_string())),
        (None, Some(_)) => Err(ConfigError::Invalid(id_key.to_string())),
    }
}

fn normalize_optional_env(value: Option<String>, key: &str) -> Result<Option<String>, ConfigError> {
    match value {
        None => Ok(None),
        Some(raw) => {
            let trimmed = raw.trim().to_string();
            if trimmed.is_empty() {
                Err(ConfigError::Invalid(key.to_string()))
            } else {
                Ok(Some(trimmed))
            }
        }
    }
}

fn parse_u32_with_default(value: Option<String>, default_value: u32) -> Result<u32, ()> {
    match value {
        Some(raw) => raw.trim().parse::<u32>().map_err(|_| ()),
        None => Ok(default_value),
    }
}

fn parse_bool_with_default(
    value: Option<String>,
    key: &str,
    default_value: bool,
) -> Result<bool, ConfigError> {
    let Some(raw) = value else {
        return Ok(default_value);
    };
    let normalized = raw.trim().to_ascii_lowercase();
    if normalized.is_empty() {
        return Err(ConfigError::Invalid(key.to_string()));
    }
    match normalized.as_str() {
        "true" => Ok(true),
        "false" => Ok(false),
        _ => Err(ConfigError::Invalid(key.to_string())),
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
        assert!(cfg.google_oauth_client_id.is_none());
        assert!(cfg.google_oauth_client_secret.is_none());
        assert!(cfg.github_oauth_client_id.is_none());
        assert!(cfg.github_oauth_client_secret.is_none());
        assert!(!cfg.dunning_emails_disabled);
        assert!(!cfg.algolia_migration_enabled);
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
        assert!(!cfg.dunning_emails_disabled);
        assert!(!cfg.algolia_migration_enabled);
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

    #[test]
    fn oauth_pairs_are_optional_and_trimmed_when_present() {
        let cfg = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("GOOGLE_OAUTH_CLIENT_ID", "  google-client-id  "),
            ("GOOGLE_OAUTH_CLIENT_SECRET", "  google-client-secret  "),
            ("GITHUB_OAUTH_CLIENT_ID", "  github-client-id  "),
            ("GITHUB_OAUTH_CLIENT_SECRET", "  github-client-secret  "),
        ])))
        .expect("oauth env pair should parse");

        assert_eq!(
            cfg.google_oauth_client_id.as_deref(),
            Some("google-client-id")
        );
        assert_eq!(
            cfg.google_oauth_client_secret.as_deref(),
            Some("google-client-secret")
        );
        assert_eq!(
            cfg.github_oauth_client_id.as_deref(),
            Some("github-client-id")
        );
        assert_eq!(
            cfg.github_oauth_client_secret.as_deref(),
            Some("github-client-secret")
        );
    }

    #[test]
    fn oauth_id_without_secret_is_rejected() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("GOOGLE_OAUTH_CLIENT_ID", "google-client-id"),
        ])))
        .unwrap_err();

        assert!(matches!(
            err,
            ConfigError::Invalid(ref key) if key == "GOOGLE_OAUTH_CLIENT_SECRET"
        ));
    }

    #[test]
    fn oauth_secret_without_id_is_rejected() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("GITHUB_OAUTH_CLIENT_SECRET", "github-client-secret"),
        ])))
        .unwrap_err();

        assert!(matches!(
            err,
            ConfigError::Invalid(ref key) if key == "GITHUB_OAUTH_CLIENT_ID"
        ));
    }

    #[test]
    fn oauth_blank_values_are_rejected() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("GOOGLE_OAUTH_CLIENT_ID", "   "),
            ("GOOGLE_OAUTH_CLIENT_SECRET", "google-client-secret"),
        ])))
        .unwrap_err();

        assert!(matches!(
            err,
            ConfigError::Invalid(ref key) if key == "GOOGLE_OAUTH_CLIENT_ID"
        ));
    }

    #[test]
    fn dunning_emails_disabled_defaults_to_false() {
        let cfg = Config::from_reader(valid_env()).expect("should parse valid config");
        assert!(!cfg.dunning_emails_disabled);
    }

    #[test]
    fn algolia_migration_enabled_defaults_to_false() {
        let cfg = Config::from_reader(valid_env()).expect("should parse valid config");
        assert!(!cfg.algolia_migration_enabled);
    }

    #[test]
    fn algolia_migration_enabled_parses_true_and_false() {
        let enabled = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("FJCLOUD_ALGOLIA_MIGRATION_ENABLED", "true"),
        ])))
        .expect("should parse enabled flag");
        assert!(enabled.algolia_migration_enabled);

        let disabled = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("FJCLOUD_ALGOLIA_MIGRATION_ENABLED", "false"),
        ])))
        .expect("should parse disabled flag");
        assert!(!disabled.algolia_migration_enabled);
    }

    #[test]
    fn dunning_emails_disabled_parses_true_and_false() {
        let enabled = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("DUNNING_EMAILS_DISABLED", "  TRUE  "),
        ])))
        .expect("dunning disable flag should parse true");
        assert!(enabled.dunning_emails_disabled);

        let disabled = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("DUNNING_EMAILS_DISABLED", "false"),
        ])))
        .expect("dunning disable flag should parse false");
        assert!(!disabled.dunning_emails_disabled);
    }

    #[test]
    fn dunning_emails_disabled_rejects_blank_value() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("DUNNING_EMAILS_DISABLED", "   "),
        ])))
        .unwrap_err();

        assert!(matches!(
            err,
            ConfigError::Invalid(ref key) if key == "DUNNING_EMAILS_DISABLED"
        ));
    }

    #[test]
    fn dunning_emails_disabled_rejects_invalid_value() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("DUNNING_EMAILS_DISABLED", "yes"),
        ])))
        .unwrap_err();

        assert!(matches!(
            err,
            ConfigError::Invalid(ref key) if key == "DUNNING_EMAILS_DISABLED"
        ));
    }
}
