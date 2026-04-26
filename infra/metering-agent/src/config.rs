//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/metering-agent/src/config.rs.
use std::time::Duration;
use thiserror::Error;
use uuid::Uuid;

/// All configuration is supplied via environment variables (12-factor).
#[derive(Debug, Clone)]
pub struct Config {
    /// Base URL of the flapjack node to scrape. No trailing slash.
    /// Example: "http://localhost:7700"
    pub flapjack_url: String,
    /// API key for the flapjack node.
    pub flapjack_api_key: String,
    /// Application-Id sent alongside the API key on flapjack engine
    /// requests. The engine's auth check rejects requests with only the
    /// API key (HTTP 403, "Invalid Application-ID or API key"), so this
    /// must be set or the engine endpoints will all 403 — which is what
    /// caused the staging metering pipeline to silently produce zero
    /// usage_records before this field was wired up. Defaults to
    /// "flapjack" to match the value the synthetic-traffic seeder uses.
    pub flapjack_application_id: String,
    /// Internal auth token for control-plane `/internal/*` endpoints.
    ///
    /// Older nodes reused the flapjack API key for this path, so we keep a
    /// fallback to preserve compatibility during rolling upgrades.
    pub internal_key: String,
    /// How often to scrape the /metrics endpoint.
    pub scrape_interval: Duration,
    /// How often to poll /internal/storage for disk-usage gauges.
    pub storage_poll_interval: Duration,
    /// How often to refresh the tenant map from the control-plane API.
    pub tenant_map_refresh_interval: Duration,
    /// PostgreSQL connection string for writing usage records.
    pub database_url: String,
    /// The customer this agent is metering for.
    pub customer_id: Uuid,
    /// Stable identifier for this flapjack node (used in idempotency keys).
    pub node_id: String,
    /// Cloud region label (e.g. "us-east-1"). Used for billing dimension.
    pub region: String,
    /// Port for the health HTTP endpoint (default 9091).
    pub health_port: u16,
    /// Tenant-map endpoint URL used for index->customer attribution.
    pub tenant_map_url: String,
    /// Cold storage usage endpoint URL for completed snapshot sizes.
    pub cold_storage_usage_url: String,
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("missing required environment variable: {0}")]
    Missing(String),
    #[error("invalid value for {var}: {reason}")]
    Invalid { var: String, reason: String },
}

impl Config {
    /// Load configuration from the process environment.
    pub fn from_env() -> Result<Self, ConfigError> {
        Self::from_reader(|key| std::env::var(key))
    }

    /// Load configuration from an injectable key-value reader.
    ///
    /// The reader returns `Ok(value)` when the key is present and `Err(_)`
    /// when it is absent. This signature matches `std::env::var` exactly,
    /// so production code passes `std::env::var` and tests pass a closure
    /// over their own fixture data — no global state, no race conditions.
    pub fn from_reader<F>(read: F) -> Result<Self, ConfigError>
    where
        F: Fn(&str) -> Result<String, std::env::VarError>,
    {
        let require = |key: &str| read(key).map_err(|_| ConfigError::Missing(key.to_string()));

        let parse_u64_opt = |key: &str, default: u64| -> Result<u64, ConfigError> {
            match read(key) {
                Err(_) => Ok(default),
                Ok(val) => val.trim().parse::<u64>().map_err(|e| ConfigError::Invalid {
                    var: key.to_string(),
                    reason: e.to_string(),
                }),
            }
        };

        let flapjack_url = require("FLAPJACK_URL")?.trim_end_matches('/').to_string();
        let flapjack_api_key = require("FLAPJACK_API_KEY")?;
        let flapjack_application_id =
            read("FLAPJACK_APPLICATION_ID").unwrap_or_else(|_| "flapjack".to_string());
        let internal_key = read("INTERNAL_KEY").unwrap_or_else(|_| flapjack_api_key.clone());
        let database_url = require("DATABASE_URL")?;
        let node_id = require("NODE_ID")?;
        let region = require("REGION")?;

        let customer_id = {
            let raw = require("CUSTOMER_ID")?;
            Uuid::parse_str(&raw).map_err(|e| ConfigError::Invalid {
                var: "CUSTOMER_ID".to_string(),
                reason: e.to_string(),
            })?
        };

        let scrape_interval = Duration::from_secs(parse_u64_opt("SCRAPE_INTERVAL_SECS", 60)?);
        let storage_poll_interval =
            Duration::from_secs(parse_u64_opt("STORAGE_POLL_INTERVAL_SECS", 300)?);
        let tenant_map_refresh_interval =
            Duration::from_secs(parse_u64_opt("TENANT_MAP_REFRESH_INTERVAL_SECS", 300)?);
        let health_port = parse_u64_opt("HEALTH_PORT", 9091)? as u16;
        let tenant_map_url = read("TENANT_MAP_URL")
            .unwrap_or_else(|_| "http://127.0.0.1:3001/internal/tenant-map".to_string())
            .trim_end_matches('/')
            .to_string();
        let cold_storage_usage_url = read("COLD_STORAGE_USAGE_URL")
            .unwrap_or_else(|_| "http://127.0.0.1:3001/internal/cold-storage-usage".to_string())
            .trim_end_matches('/')
            .to_string();

        if node_id.is_empty() {
            return Err(ConfigError::Invalid {
                var: "NODE_ID".to_string(),
                reason: "must not be empty".to_string(),
            });
        }
        if region.is_empty() {
            return Err(ConfigError::Invalid {
                var: "REGION".to_string(),
                reason: "must not be empty".to_string(),
            });
        }

        Ok(Config {
            flapjack_url,
            flapjack_api_key,
            flapjack_application_id,
            internal_key,
            scrape_interval,
            storage_poll_interval,
            tenant_map_refresh_interval,
            database_url,
            customer_id,
            node_id,
            region,
            health_port,
            tenant_map_url,
            cold_storage_usage_url,
        })
    }

    pub fn metrics_url(&self) -> String {
        format!("{}/metrics", self.flapjack_url)
    }

    pub fn storage_url(&self) -> String {
        format!("{}/internal/storage", self.flapjack_url)
    }

    pub fn tenant_map_url(&self) -> String {
        self.tenant_map_url.clone()
    }

    pub fn cold_storage_usage_url(&self) -> String {
        self.cold_storage_usage_url.clone()
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    /// Base fixture: all required vars present, optional vars absent (defaults apply).
    fn valid_env(key: &str) -> Result<String, std::env::VarError> {
        match key {
            "FLAPJACK_URL" => Ok("http://localhost:7700".into()),
            "FLAPJACK_API_KEY" => Ok("test-key".into()),
            "DATABASE_URL" => Ok("postgres://localhost/test".into()),
            "CUSTOMER_ID" => Ok("550e8400-e29b-41d4-a716-446655440000".into()),
            "NODE_ID" => Ok("node-a".into()),
            "REGION" => Ok("us-east-1".into()),
            _ => Err(std::env::VarError::NotPresent),
        }
    }

    // -------------------------------------------------------------------------

    /// Guards the happy-path config load: all required environment variables
    /// present, all optional variables absent (defaults apply).
    ///
    /// Asserts the parsed values match the `valid_env` fixture and that
    /// default intervals (60 s scrape, 300 s storage poll and tenant-map
    /// refresh, port 9091) and default endpoint URLs are set correctly.
    #[test]
    fn loads_valid_config() {
        let cfg = Config::from_reader(valid_env).expect("should parse");
        assert_eq!(cfg.flapjack_url, "http://localhost:7700");
        assert_eq!(cfg.flapjack_api_key, "test-key");
        assert_eq!(cfg.internal_key, "test-key");
        assert_eq!(cfg.node_id, "node-a");
        assert_eq!(cfg.region, "us-east-1");
        assert_eq!(cfg.scrape_interval, Duration::from_secs(60));
        assert_eq!(cfg.storage_poll_interval, Duration::from_secs(300));
        assert_eq!(cfg.tenant_map_refresh_interval, Duration::from_secs(300));
        assert_eq!(cfg.health_port, 9091);
        assert_eq!(
            cfg.tenant_map_url(),
            "http://127.0.0.1:3001/internal/tenant-map"
        );
        assert_eq!(
            cfg.cold_storage_usage_url(),
            "http://127.0.0.1:3001/internal/cold-storage-usage"
        );
    }

    #[test]
    fn trailing_slash_stripped_from_flapjack_url() {
        let cfg = Config::from_reader(|key| match key {
            "FLAPJACK_URL" => Ok("http://localhost:7700/".into()),
            other => valid_env(other),
        })
        .unwrap();
        assert_eq!(cfg.flapjack_url, "http://localhost:7700");
    }

    #[test]
    fn metrics_url_appends_path() {
        let cfg = Config::from_reader(valid_env).unwrap();
        assert_eq!(cfg.metrics_url(), "http://localhost:7700/metrics");
    }

    #[test]
    fn storage_url_appends_path() {
        let cfg = Config::from_reader(valid_env).unwrap();
        assert_eq!(cfg.storage_url(), "http://localhost:7700/internal/storage");
    }

    #[test]
    fn missing_required_var_returns_error() {
        let err = Config::from_reader(|key| match key {
            "FLAPJACK_URL" => Err(std::env::VarError::NotPresent),
            other => valid_env(other),
        })
        .unwrap_err();
        assert!(matches!(err, ConfigError::Missing(ref k) if k == "FLAPJACK_URL"));
    }

    #[test]
    fn invalid_customer_id_returns_error() {
        let err = Config::from_reader(|key| match key {
            "CUSTOMER_ID" => Ok("not-a-uuid".into()),
            other => valid_env(other),
        })
        .unwrap_err();
        assert!(matches!(err, ConfigError::Invalid { ref var, .. } if var == "CUSTOMER_ID"));
    }

    #[test]
    fn custom_scrape_interval_is_respected() {
        let cfg = Config::from_reader(|key| match key {
            "SCRAPE_INTERVAL_SECS" => Ok("120".into()),
            other => valid_env(other),
        })
        .unwrap();
        assert_eq!(cfg.scrape_interval, Duration::from_secs(120));
    }

    #[test]
    fn non_numeric_scrape_interval_returns_error() {
        let err = Config::from_reader(|key| match key {
            "SCRAPE_INTERVAL_SECS" => Ok("fast".into()),
            other => valid_env(other),
        })
        .unwrap_err();
        assert!(
            matches!(err, ConfigError::Invalid { ref var, .. } if var == "SCRAPE_INTERVAL_SECS")
        );
    }

    /// Guards that `TENANT_MAP_REFRESH_INTERVAL_SECS`, `TENANT_MAP_URL`, and
    /// `COLD_STORAGE_USAGE_URL` override the built-in defaults when supplied.
    ///
    /// Also verifies that trailing slashes in both URL vars are stripped, so
    /// path concatenation in callers never produces a double-slash.
    #[test]
    fn custom_tenant_map_values_are_respected() {
        let cfg = Config::from_reader(|key| match key {
            "INTERNAL_KEY" => Ok("internal-key-123".into()),
            "TENANT_MAP_REFRESH_INTERVAL_SECS" => Ok("120".into()),
            "TENANT_MAP_URL" => Ok("https://api.flapjack.foo/internal/tenant-map/".into()),
            "COLD_STORAGE_USAGE_URL" => {
                Ok("https://api.flapjack.foo/internal/cold-storage-usage/".into())
            }
            "METERING_TENANT_MAP_URL" => Ok("https://wrong.example.test/tenant-map".into()),
            "METERING_COLD_STORAGE_URL" => Ok("https://wrong.example.test/cold-storage".into()),
            other => valid_env(other),
        })
        .unwrap();
        assert_eq!(cfg.internal_key, "internal-key-123");
        assert_eq!(cfg.tenant_map_refresh_interval, Duration::from_secs(120));
        assert_eq!(
            cfg.tenant_map_url(),
            "https://api.flapjack.foo/internal/tenant-map"
        );
        assert_eq!(
            cfg.cold_storage_usage_url(),
            "https://api.flapjack.foo/internal/cold-storage-usage"
        );
    }
}
