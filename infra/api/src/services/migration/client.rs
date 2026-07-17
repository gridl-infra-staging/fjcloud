use std::collections::HashMap;
use std::time::Duration;

use async_trait::async_trait;
use reqwest::Method;

const DEFAULT_ROLLBACK_WINDOW_SECS: i64 = 300;
const DEFAULT_REPLICATION_TIMEOUT_SECS: u64 = 600;
const DEFAULT_REPLICATION_POLL_INTERVAL_MILLIS: u64 = 2000;
const DEFAULT_REPLICATION_NEAR_ZERO_LAG_OPS: i64 = 10;
const DEFAULT_LONG_RUNNING_WARNING_SECS: u64 = 600;

#[derive(Debug, Clone)]
pub struct MigrationConfig {
    pub max_concurrent: u32,
    pub rollback_window: chrono::Duration,
    pub replication_timeout: Duration,
    pub replication_poll_interval: Duration,
    pub replication_near_zero_lag_ops: i64,
    pub long_running_warning_threshold: Duration,
}

impl MigrationConfig {
    /// Builds a [`MigrationConfig`] from environment variables, falling back
    /// to compiled defaults for any variable that is unset or unparseable.
    ///
    /// Reads `MIGRATION_ROLLBACK_WINDOW_SECS`, `MIGRATION_REPLICATION_TIMEOUT_SECS`,
    /// `MIGRATION_REPLICATION_POLL_INTERVAL_MILLIS`, `MIGRATION_REPLICATION_NEAR_ZERO_LAG_OPS`,
    /// and `MIGRATION_LONG_RUNNING_WARNING_SECS`. The caller supplies `max_concurrent`
    /// directly (typically from a higher-level config source).
    pub fn from_env(max_concurrent: u32) -> Self {
        let rollback_secs = env_i64(
            "MIGRATION_ROLLBACK_WINDOW_SECS",
            DEFAULT_ROLLBACK_WINDOW_SECS,
        );
        let replication_timeout_secs = env_u64(
            "MIGRATION_REPLICATION_TIMEOUT_SECS",
            DEFAULT_REPLICATION_TIMEOUT_SECS,
        );
        let replication_poll_interval_ms = env_u64(
            "MIGRATION_REPLICATION_POLL_INTERVAL_MILLIS",
            DEFAULT_REPLICATION_POLL_INTERVAL_MILLIS,
        );
        let replication_near_zero_lag_ops = env_i64(
            "MIGRATION_REPLICATION_NEAR_ZERO_LAG_OPS",
            DEFAULT_REPLICATION_NEAR_ZERO_LAG_OPS,
        );
        let long_running_warning_secs = env_u64(
            "MIGRATION_LONG_RUNNING_WARNING_SECS",
            DEFAULT_LONG_RUNNING_WARNING_SECS,
        );

        Self {
            max_concurrent,
            rollback_window: chrono::Duration::seconds(rollback_secs),
            replication_timeout: Duration::from_secs(replication_timeout_secs),
            replication_poll_interval: Duration::from_millis(replication_poll_interval_ms),
            replication_near_zero_lag_ops,
            long_running_warning_threshold: Duration::from_secs(long_running_warning_secs),
        }
    }
}

#[derive(Debug, thiserror::Error, Clone, PartialEq)]
pub enum MigrationHttpClientError {
    #[error("http timeout")]
    Timeout,
    #[error("unreachable: {0}")]
    Unreachable(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct MigrationHttpRequest {
    pub method: Method,
    pub url: String,
    pub json_body: Option<serde_json::Value>,
    pub headers: HashMap<String, String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct MigrationHttpResponse {
    pub status: u16,
    pub body: String,
}

#[async_trait]
pub trait MigrationHttpClient: Send + Sync {
    async fn send(
        &self,
        request: MigrationHttpRequest,
    ) -> Result<MigrationHttpResponse, MigrationHttpClientError>;
}

pub struct ReqwestMigrationHttpClient {
    client: reqwest::Client,
}

impl ReqwestMigrationHttpClient {
    pub fn new(client: reqwest::Client) -> Self {
        Self { client }
    }
}

#[async_trait]
impl MigrationHttpClient for ReqwestMigrationHttpClient {
    /// Sends a [`MigrationHttpRequest`] via reqwest, mapping transport
    /// failures to [`MigrationHttpClientError::Timeout`] or
    /// [`MigrationHttpClientError::Unreachable`]. Returns the raw status
    /// code and response body on success.
    async fn send(
        &self,
        request: MigrationHttpRequest,
    ) -> Result<MigrationHttpResponse, MigrationHttpClientError> {
        let mut req = self.client.request(request.method, &request.url);
        for (key, value) in &request.headers {
            req = req.header(key, value);
        }
        if let Some(body) = request.json_body {
            req = req.json(&body);
        }

        let response = req.send().await.map_err(|e| {
            if e.is_timeout() {
                MigrationHttpClientError::Timeout
            } else {
                MigrationHttpClientError::Unreachable(e.to_string())
            }
        })?;

        let status = response.status().as_u16();
        let body = response
            .text()
            .await
            .map_err(|e| MigrationHttpClientError::Unreachable(e.to_string()))?;

        Ok(MigrationHttpResponse { status, body })
    }
}

fn env_u64(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
}

fn env_i64(key: &str, default: i64) -> i64 {
    std::env::var(key)
        .ok()
        .and_then(|value| value.trim().parse::<i64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migration_http_client_error_display() {
        assert_eq!(
            MigrationHttpClientError::Timeout.to_string(),
            "http timeout"
        );
        let err = MigrationHttpClientError::Unreachable("dns failure".into());
        assert_eq!(err.to_string(), "unreachable: dns failure");
    }

    #[test]
    fn default_constants_are_positive() {
        const { assert!(DEFAULT_ROLLBACK_WINDOW_SECS > 0) };
        const { assert!(DEFAULT_REPLICATION_TIMEOUT_SECS > 0) };
        const { assert!(DEFAULT_REPLICATION_POLL_INTERVAL_MILLIS > 0) };
        const { assert!(DEFAULT_REPLICATION_NEAR_ZERO_LAG_OPS > 0) };
        const { assert!(DEFAULT_LONG_RUNNING_WARNING_SECS > 0) };
    }
}
