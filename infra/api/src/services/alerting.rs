//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/alerting.rs.
use std::collections::HashMap;
use std::sync::Mutex;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AlertSeverity {
    Info,
    Warning,
    Critical,
}

impl AlertSeverity {
    pub fn as_str(&self) -> &'static str {
        match self {
            AlertSeverity::Info => "info",
            AlertSeverity::Warning => "warning",
            AlertSeverity::Critical => "critical",
        }
    }

    /// Slack attachment color for this severity level.
    pub fn slack_color(&self) -> &'static str {
        match self {
            AlertSeverity::Info => "#36a64f",     // green
            AlertSeverity::Warning => "#daa038",  // yellow
            AlertSeverity::Critical => "#d00000", // red
        }
    }

    /// Discord embed color for this severity level (decimal integer).
    pub fn discord_color(&self) -> u32 {
        match self {
            AlertSeverity::Info => 0x36a64f,     // green
            AlertSeverity::Warning => 0xdaa038,  // yellow
            AlertSeverity::Critical => 0xd00000, // red
        }
    }
}

impl std::fmt::Display for AlertSeverity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

impl std::str::FromStr for AlertSeverity {
    type Err = &'static str;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "info" => Ok(AlertSeverity::Info),
            "warning" => Ok(AlertSeverity::Warning),
            "critical" => Ok(AlertSeverity::Critical),
            _ => Err("invalid alert severity"),
        }
    }
}

/// An alert to be sent and persisted.
#[derive(Debug, Clone)]
pub struct Alert {
    pub severity: AlertSeverity,
    pub title: String,
    pub message: String,
    pub metadata: HashMap<String, String>,
}

/// A persisted alert record (from the `alerts` DB table or mock storage).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AlertRecord {
    pub id: Uuid,
    pub severity: AlertSeverity,
    pub title: String,
    pub message: String,
    pub metadata: serde_json::Value,
    pub delivery_status: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, thiserror::Error)]
pub enum AlertError {
    #[error("failed to send alert: {0}")]
    SendFailed(String),

    #[error("alert service not configured")]
    NotConfigured,

    #[error("database error: {0}")]
    DbError(String),
}

// ---------------------------------------------------------------------------
// Trait
// ---------------------------------------------------------------------------

#[async_trait]
pub trait AlertService: Send + Sync {
    /// Dispatch a notification and persist to storage.
    async fn send_alert(&self, alert: Alert) -> Result<(), AlertError>;

    /// Read recent persisted alerts, ordered by created_at DESC.
    async fn get_recent_alerts(&self, limit: i64) -> Result<Vec<AlertRecord>, AlertError>;
}

// ---------------------------------------------------------------------------
// MockAlertService — in-memory for tests
// ---------------------------------------------------------------------------

pub struct MockAlertService {
    alerts: Mutex<Vec<AlertRecord>>,
}

impl MockAlertService {
    pub fn new() -> Self {
        Self {
            alerts: Mutex::new(Vec::new()),
        }
    }

    /// Return the number of recorded alerts.
    pub fn alert_count(&self) -> usize {
        self.alerts.lock().unwrap().len()
    }

    /// Return all recorded alerts (oldest first).
    pub fn recorded_alerts(&self) -> Vec<AlertRecord> {
        self.alerts.lock().unwrap().clone()
    }
}

impl Default for MockAlertService {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl AlertService for MockAlertService {
    async fn send_alert(&self, alert: Alert) -> Result<(), AlertError> {
        let record = AlertRecord {
            id: Uuid::new_v4(),
            severity: alert.severity,
            title: alert.title,
            message: alert.message,
            metadata: serde_json::to_value(&alert.metadata)
                .unwrap_or(serde_json::Value::Object(Default::default())),
            delivery_status: "mock".to_string(),
            created_at: Utc::now(),
        };
        self.alerts.lock().unwrap().push(record);
        Ok(())
    }

    async fn get_recent_alerts(&self, limit: i64) -> Result<Vec<AlertRecord>, AlertError> {
        if limit <= 0 {
            return Ok(Vec::new());
        }
        let alerts = self.alerts.lock().unwrap();
        let mut sorted: Vec<AlertRecord> = alerts.clone();
        sorted.sort_by_key(|alert| std::cmp::Reverse(alert.created_at));
        sorted.truncate(limit as usize);
        Ok(sorted)
    }
}

// ---------------------------------------------------------------------------
// WebhookAlertService — sends to Slack and/or Discord webhooks + persists to DB
// ---------------------------------------------------------------------------

pub struct WebhookAlertService {
    pool: sqlx::PgPool,
    http_client: reqwest::Client,
    slack_webhook_url: Option<String>,
    discord_webhook_url: Option<String>,
    environment: String,
}

impl WebhookAlertService {
    pub fn new(
        pool: sqlx::PgPool,
        http_client: reqwest::Client,
        slack_webhook_url: Option<String>,
        discord_webhook_url: Option<String>,
        environment: String,
    ) -> Self {
        Self {
            pool,
            http_client,
            slack_webhook_url,
            discord_webhook_url,
            environment,
        }
    }

    /// Build the Slack webhook JSON payload for an alert.
    pub fn format_slack_payload(&self, alert: &Alert) -> serde_json::Value {
        let mut fields: Vec<serde_json::Value> = alert
            .metadata
            .iter()
            .map(|(k, v)| {
                serde_json::json!({
                    "title": k,
                    "value": v,
                    "short": true
                })
            })
            .collect();

        fields.push(serde_json::json!({
            "title": "Environment",
            "value": self.environment,
            "short": true
        }));

        serde_json::json!({
            "attachments": [{
                "color": alert.severity.slack_color(),
                "title": alert.title,
                "text": alert.message,
                "fields": fields,
                "ts": Utc::now().timestamp()
            }]
        })
    }

    /// Build the Discord webhook JSON payload for an alert.
    pub fn format_discord_payload(&self, alert: &Alert) -> serde_json::Value {
        let mut fields: Vec<serde_json::Value> = alert
            .metadata
            .iter()
            .map(|(k, v)| {
                serde_json::json!({
                    "name": k,
                    "value": v,
                    "inline": true
                })
            })
            .collect();

        fields.push(serde_json::json!({
            "name": "Environment",
            "value": self.environment,
            "inline": true
        }));

        serde_json::json!({
            "embeds": [{
                "color": alert.severity.discord_color(),
                "title": alert.title,
                "description": alert.message,
                "fields": fields,
                "timestamp": Utc::now().to_rfc3339()
            }]
        })
    }

    /// POST a JSON payload to a webhook URL. Returns true on success.
    async fn post_webhook(&self, url: &str, payload: &serde_json::Value, channel: &str) -> bool {
        let result = self
            .http_client
            .post(url)
            .json(payload)
            .timeout(std::time::Duration::from_secs(5))
            .send()
            .await;

        match result {
            Ok(resp) if resp.status().is_success() => true,
            Ok(resp) => {
                tracing::warn!(
                    "{channel} webhook returned {}: alert skipped",
                    resp.status(),
                );
                false
            }
            Err(e) => {
                tracing::warn!("{channel} webhook failed: {e}");
                false
            }
        }
    }

    /// Resolve persisted delivery status from send attempt outcomes.
    pub fn resolve_delivery_status(any_sent: bool, any_configured: bool) -> &'static str {
        if any_sent {
            "sent"
        } else if any_configured {
            "failed"
        } else {
            "skipped"
        }
    }
}

/// Internal sqlx row type for the alerts table.
#[derive(sqlx::FromRow)]
struct AlertRow {
    id: Uuid,
    severity: String,
    title: String,
    message: String,
    metadata: serde_json::Value,
    delivery_status: String,
    created_at: DateTime<Utc>,
}

impl AlertRow {
    fn into_alert_record(self) -> AlertRecord {
        AlertRecord {
            id: self.id,
            severity: self.severity.parse().unwrap_or(AlertSeverity::Info),
            title: self.title,
            message: self.message,
            metadata: self.metadata,
            delivery_status: self.delivery_status,
            created_at: self.created_at,
        }
    }
}

// ---------------------------------------------------------------------------
// Shared DB helpers — used by both WebhookAlertService and LogAlertService
// ---------------------------------------------------------------------------

/// Persist an alert record to the `alerts` table.
async fn persist_alert(
    pool: &sqlx::PgPool,
    alert: &Alert,
    delivery_status: &str,
) -> Result<AlertRecord, AlertError> {
    let metadata = serde_json::to_value(&alert.metadata)
        .unwrap_or(serde_json::Value::Object(Default::default()));

    let row = sqlx::query_as::<_, AlertRow>(
        r#"
        INSERT INTO alerts (severity, title, message, metadata, delivery_status)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING id, severity, title, message, metadata, delivery_status, created_at
        "#,
    )
    .bind(alert.severity.as_str())
    .bind(&alert.title)
    .bind(&alert.message)
    .bind(&metadata)
    .bind(delivery_status)
    .fetch_one(pool)
    .await
    .map_err(|e| AlertError::DbError(e.to_string()))?;

    Ok(row.into_alert_record())
}

/// Query recent alerts from the `alerts` table, ordered by created_at DESC.
async fn query_recent_alerts(
    pool: &sqlx::PgPool,
    limit: i64,
) -> Result<Vec<AlertRecord>, AlertError> {
    if limit <= 0 {
        return Ok(Vec::new());
    }

    let rows = sqlx::query_as::<_, AlertRow>(
        r#"
        SELECT id, severity, title, message, metadata, delivery_status, created_at
        FROM alerts
        ORDER BY created_at DESC
        LIMIT $1
        "#,
    )
    .bind(limit)
    .fetch_all(pool)
    .await
    .map_err(|e| AlertError::DbError(e.to_string()))?;

    Ok(rows.into_iter().map(|r| r.into_alert_record()).collect())
}

// ---------------------------------------------------------------------------
// WebhookAlertService trait impl
// ---------------------------------------------------------------------------

#[async_trait]
impl AlertService for WebhookAlertService {
    /// POSTs the alert payload to configured webhook URLs (Slack and/or Discord).
    ///
    /// Persists the alert to the database with the resolved delivery status
    /// (`delivered` on 2xx, `failed` otherwise). Logs transport or HTTP errors
    /// but does not propagate them to callers.
    async fn send_alert(&self, alert: Alert) -> Result<(), AlertError> {
        let mut any_sent = false;
        let any_configured = self.slack_webhook_url.is_some() || self.discord_webhook_url.is_some();

        // Send to Slack if configured
        if let Some(url) = &self.slack_webhook_url {
            let payload = self.format_slack_payload(&alert);
            if self.post_webhook(url, &payload, "slack").await {
                any_sent = true;
            }
        }

        // Send to Discord if configured
        if let Some(url) = &self.discord_webhook_url {
            let payload = self.format_discord_payload(&alert);
            if self.post_webhook(url, &payload, "discord").await {
                any_sent = true;
            }
        }

        let delivery_status = Self::resolve_delivery_status(any_sent, any_configured);
        if delivery_status == "skipped" {
            tracing::warn!(
                "no webhook URLs configured — alert skipped: {}",
                alert.title
            );
        }

        persist_alert(&self.pool, &alert, delivery_status).await?;
        Ok(())
    }

    async fn get_recent_alerts(&self, limit: i64) -> Result<Vec<AlertRecord>, AlertError> {
        query_recent_alerts(&self.pool, limit).await
    }
}

// ---------------------------------------------------------------------------
// LogAlertService — logs alerts + persists to DB
// ---------------------------------------------------------------------------

pub struct LogAlertService {
    pool: sqlx::PgPool,
}

impl LogAlertService {
    pub fn new(pool: sqlx::PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl AlertService for LogAlertService {
    /// Logs the alert at the appropriate severity level (info, warn, or error)
    /// using the `tracing` framework.
    ///
    /// Persists the alert record to the database with a `"logged"` delivery
    /// status. Used as a fallback when no webhook URLs are configured.
    async fn send_alert(&self, alert: Alert) -> Result<(), AlertError> {
        match alert.severity {
            AlertSeverity::Info => {
                tracing::info!(
                    severity = "info",
                    title = %alert.title,
                    message = %alert.message,
                    "alert"
                );
            }
            AlertSeverity::Warning => {
                tracing::warn!(
                    severity = "warning",
                    title = %alert.title,
                    message = %alert.message,
                    "alert"
                );
            }
            AlertSeverity::Critical => {
                tracing::error!(
                    severity = "critical",
                    title = %alert.title,
                    message = %alert.message,
                    "alert"
                );
            }
        }

        persist_alert(&self.pool, &alert, "logged").await?;
        Ok(())
    }

    async fn get_recent_alerts(&self, limit: i64) -> Result<Vec<AlertRecord>, AlertError> {
        query_recent_alerts(&self.pool, limit).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn severity_as_str_round_trips() {
        for s in ["info", "warning", "critical"] {
            let parsed: AlertSeverity = s.parse().unwrap();
            assert_eq!(parsed.as_str(), s);
            assert_eq!(parsed.to_string(), s);
        }
    }

    #[test]
    fn severity_from_str_rejects_invalid() {
        assert!("error".parse::<AlertSeverity>().is_err());
        assert!("".parse::<AlertSeverity>().is_err());
        assert!("INFO".parse::<AlertSeverity>().is_err()); // case-sensitive
    }

    #[test]
    fn slack_color_is_valid_hex() {
        for severity in [
            AlertSeverity::Info,
            AlertSeverity::Warning,
            AlertSeverity::Critical,
        ] {
            let color = severity.slack_color();
            assert!(color.starts_with('#'), "should be hex color");
            assert_eq!(color.len(), 7, "should be #RRGGBB format");
        }
    }

    #[test]
    fn discord_colors_are_distinct() {
        let colors = [
            AlertSeverity::Info.discord_color(),
            AlertSeverity::Warning.discord_color(),
            AlertSeverity::Critical.discord_color(),
        ];
        assert_ne!(colors[0], colors[1]);
        assert_ne!(colors[1], colors[2]);
        assert_ne!(colors[0], colors[2]);
    }

    #[test]
    fn resolve_delivery_status_sent_wins() {
        assert_eq!(
            WebhookAlertService::resolve_delivery_status(true, true),
            "sent"
        );
        assert_eq!(
            WebhookAlertService::resolve_delivery_status(true, false),
            "sent"
        );
    }

    #[test]
    fn resolve_delivery_status_configured_but_failed() {
        assert_eq!(
            WebhookAlertService::resolve_delivery_status(false, true),
            "failed"
        );
    }

    #[test]
    fn resolve_delivery_status_nothing_configured() {
        assert_eq!(
            WebhookAlertService::resolve_delivery_status(false, false),
            "skipped"
        );
    }
}
