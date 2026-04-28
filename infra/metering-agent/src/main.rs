mod circuit_breaker;
mod config;
mod counter;
mod delta;
pub mod health;
mod record;
mod scraper;
mod storage;
mod tenant_map;
mod version;

use anyhow::Result;
use circuit_breaker::CircuitBreaker;
use config::Config;
use counter::{scrape_and_record, TenantStateMap};
use health::SharedHealthState;
use std::sync::{Arc, Mutex};
use tokio::time::Duration;
use tracing::info;

/// Per-tenant counter state. One entry per index name (tenant_id).
/// In-memory index-to-customer mapping refreshed from `/internal/tenant-map`.
type TenantCustomerMap = tenant_map::TenantCustomerMap;

const CRITICAL_SEVERITY: &str = "critical";
const CRITICAL_SLACK_COLOR: &str = "#d00000";
const CRITICAL_DISCORD_COLOR: u32 = 0xd00000;
const BREAKER_OPEN_ALERT_TITLE: &str = "metering-agent circuit breaker open";

/// Shared read-only inputs for each scrape cycle.
struct ScrapeContext<'a> {
    cfg: &'a Config,
    writer: &'a record::PgUsageRecordWriter<'a>,
    http: &'a reqwest::Client,
    tenant_state: &'a TenantStateMap,
    tenant_map: &'a TenantCustomerMap,
}

/// Entry point for the metering agent binary.
///
/// Handles `--version` before any I/O, initialises structured logging with a
/// default `metering_agent=info` directive, loads [`Config`] from the
/// environment, opens the Postgres connection pool, and delegates to [`run`].
#[tokio::main]
async fn main() -> Result<()> {
    // Handle --version before anything else (no config/DB needed)
    if version::check_version_flag() {
        return Ok(());
    }

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive("metering_agent=info".parse().unwrap()),
        )
        .init();

    let cfg = Config::from_env().map_err(|e| anyhow::anyhow!("{}", e))?;

    info!(
        customer_id = %cfg.customer_id,
        node_id = %cfg.node_id,
        region  = %cfg.region,
        url     = %cfg.flapjack_url,
        "metering agent starting"
    );

    let db_pool = sqlx::PgPool::connect(&cfg.database_url).await?;
    run(cfg, db_pool).await
}

async fn run(cfg: Config, pool: sqlx::PgPool) -> Result<()> {
    let tenant_state: TenantStateMap = Arc::new(dashmap::DashMap::new());
    let tenant_map: TenantCustomerMap = Arc::new(dashmap::DashMap::new());
    let writer = record::PgUsageRecordWriter { pool: &pool };
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()?;

    try_initial_tenant_map_load(&cfg, &http, &tenant_map).await;

    let health_state: SharedHealthState = Arc::new(Mutex::new(health::HealthState::new()));
    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
    let health_handle = tokio::spawn(health::serve_health(
        cfg.health_port,
        Arc::clone(&health_state),
        shutdown_rx,
    ));

    let mut circuit_breaker = CircuitBreaker::new(cfg.scrape_interval);
    let mut scrape_ticker = tokio::time::interval(cfg.scrape_interval);
    let mut storage_ticker = tokio::time::interval(cfg.storage_poll_interval);
    let mut tenant_map_ticker = tokio::time::interval(cfg.tenant_map_refresh_interval);
    let scrape_context = ScrapeContext {
        cfg: &cfg,
        writer: &writer,
        http: &http,
        tenant_state: &tenant_state,
        tenant_map: &tenant_map,
    };
    tenant_map_ticker.tick().await;

    loop {
        tokio::select! {
            _ = scrape_ticker.tick() => {
                let next =
                    handle_scrape_cycle(&scrape_context, &mut circuit_breaker, &health_state).await;
                scrape_ticker = tokio::time::interval(next);
                scrape_ticker.tick().await;
            }
            _ = storage_ticker.tick() => {
                handle_storage_cycle(&cfg, &writer, &http, &tenant_map, &health_state).await;
            }
            _ = tenant_map_ticker.tick() => {
                handle_tenant_map_refresh(&cfg, &http, &tenant_map).await;
            }
            _ = tokio::signal::ctrl_c() => {
                info!("received shutdown signal, exiting");
                let _ = shutdown_tx.send(true);
                break;
            }
        }
    }

    graceful_shutdown(health_handle, pool).await;
    Ok(())
}

// ---------------------------------------------------------------------------
// Extracted select-branch helpers
// ---------------------------------------------------------------------------

/// Eagerly load the tenant map before the main loop starts.
/// Failure is a warning, not fatal — the periodic refresh will retry.
async fn try_initial_tenant_map_load(
    cfg: &Config,
    http: &reqwest::Client,
    tenant_map: &TenantCustomerMap,
) {
    match tenant_map::refresh_tenant_map(cfg, http, tenant_map).await {
        Ok(count) => info!(entries = count, "loaded tenant map"),
        Err(err) => tracing::warn!("failed to load tenant map at startup: {:#}", err),
    }
}

/// Run one scrape cycle with circuit-breaker bookkeeping.
/// Returns the interval to use for the next scrape tick.
async fn handle_scrape_cycle(
    scrape_context: &ScrapeContext<'_>,
    circuit_breaker: &mut CircuitBreaker,
    health_state: &SharedHealthState,
) -> Duration {
    let scrape_result = scrape_and_record(
        scrape_context.cfg,
        scrape_context.writer,
        scrape_context.http,
        scrape_context.tenant_state,
        scrape_context.tenant_map,
    )
    .await;

    handle_scrape_cycle_with_result(scrape_context, circuit_breaker, health_state, scrape_result)
        .await
}

/// Apply scrape-cycle side effects (health + circuit-breaker state) for an
/// already-computed scrape result.
///
/// This seam keeps `handle_scrape_cycle` wired to the real scraper while
/// allowing tests to inject deterministic success/failure outcomes without
/// network I/O or DB writes.
async fn handle_scrape_cycle_with_result(
    scrape_context: &ScrapeContext<'_>,
    circuit_breaker: &mut CircuitBreaker,
    health_state: &SharedHealthState,
    scrape_result: anyhow::Result<()>,
) -> Duration {
    match scrape_result {
        Ok(()) => {
            let was_open = circuit_breaker.is_open();
            let next = circuit_breaker.record_success();
            if was_open {
                info!("circuit breaker closed — flapjack connectivity restored");
            }
            if let Ok(mut guard) = health_state.lock() {
                guard.last_scrape_at = Some(chrono::Utc::now());
            }
            next
        }
        Err(e) => {
            tracing::error!("scrape failed: {:#}", e);
            let was_open = circuit_breaker.is_open();
            let next = circuit_breaker.record_failure();
            let is_open = circuit_breaker.is_open();
            if !was_open && is_open {
                if let Err(alert_err) =
                    dispatch_breaker_open_alert(scrape_context.cfg, scrape_context.http, next).await
                {
                    tracing::warn!("failed to dispatch breaker-open alert: {:#}", alert_err);
                }
            }
            if is_open {
                tracing::warn!(
                    next_retry_secs = next.as_secs(),
                    "circuit breaker open — backing off"
                );
            }
            next
        }
    }
}

fn breaker_open_alert_message(next_retry: Duration) -> String {
    format!(
        "metering scrape failures reached circuit-open state; backing off for {} seconds",
        next_retry.as_secs()
    )
}

fn build_breaker_open_slack_payload(cfg: &Config, next_retry: Duration) -> serde_json::Value {
    let alert_message = breaker_open_alert_message(next_retry);
    let metadata = [
        ("severity", CRITICAL_SEVERITY.to_string()),
        ("customer_id", cfg.customer_id.to_string()),
        ("node_id", cfg.node_id.clone()),
        ("region", cfg.region.clone()),
        ("next_retry_secs", next_retry.as_secs().to_string()),
    ];
    let mut slack_fields: Vec<serde_json::Value> = metadata
        .iter()
        .map(|(name, value)| {
            serde_json::json!({
                "title": name,
                "value": value,
                "short": true
            })
        })
        .collect();
    slack_fields.push(serde_json::json!({
        "title": "Environment",
        "value": cfg.environment.clone(),
        "short": true
    }));
    serde_json::json!({
        "attachments": [{
            "color": CRITICAL_SLACK_COLOR,
            "title": BREAKER_OPEN_ALERT_TITLE,
            "text": alert_message,
            "fields": slack_fields,
            "ts": chrono::Utc::now().timestamp()
        }]
    })
}

fn build_breaker_open_discord_payload(cfg: &Config, next_retry: Duration) -> serde_json::Value {
    let alert_message = breaker_open_alert_message(next_retry);
    let metadata = [
        ("severity", CRITICAL_SEVERITY.to_string()),
        ("customer_id", cfg.customer_id.to_string()),
        ("node_id", cfg.node_id.clone()),
        ("region", cfg.region.clone()),
        ("next_retry_secs", next_retry.as_secs().to_string()),
    ];
    let mut discord_fields: Vec<serde_json::Value> = metadata
        .iter()
        .map(|(name, value)| {
            serde_json::json!({
                "name": name,
                "value": value,
                "inline": true
            })
        })
        .collect();
    discord_fields.push(serde_json::json!({
        "name": "Environment",
        "value": cfg.environment.clone(),
        "inline": true
    }));

    serde_json::json!({
        "embeds": [{
            "color": CRITICAL_DISCORD_COLOR,
            "title": BREAKER_OPEN_ALERT_TITLE,
            "description": alert_message,
            "fields": discord_fields,
            "timestamp": chrono::Utc::now().to_rfc3339()
        }]
    })
}

async fn post_breaker_alert_webhook(
    http: &reqwest::Client,
    webhook_url: &str,
    payload: &serde_json::Value,
) -> anyhow::Result<()> {
    let response = http
        .post(webhook_url)
        .json(payload)
        .timeout(Duration::from_secs(5))
        .send()
        .await?;
    if !response.status().is_success() {
        anyhow::bail!(
            "breaker alert webhook returned non-success status: {}",
            response.status()
        );
    }
    Ok(())
}

async fn dispatch_breaker_open_alert(
    cfg: &Config,
    http: &reqwest::Client,
    next_retry: Duration,
) -> anyhow::Result<()> {
    let mut failures = Vec::new();

    if let Some(slack_webhook_url) = cfg.slack_webhook_url.as_deref() {
        let slack_payload = build_breaker_open_slack_payload(cfg, next_retry);
        if let Err(err) = post_breaker_alert_webhook(http, slack_webhook_url, &slack_payload).await
        {
            failures.push(format!("slack delivery failed: {err:#}"));
        }
    }

    if let Some(discord_webhook_url) = cfg.discord_webhook_url.as_deref() {
        let discord_payload = build_breaker_open_discord_payload(cfg, next_retry);
        if let Err(err) =
            post_breaker_alert_webhook(http, discord_webhook_url, &discord_payload).await
        {
            failures.push(format!("discord delivery failed: {err:#}"));
        }
    }

    if !failures.is_empty() {
        anyhow::bail!(failures.join("; "));
    }

    Ok(())
}

/// Run one storage-poll cycle, updating the health timestamp on success.
async fn handle_storage_cycle(
    cfg: &Config,
    writer: &record::PgUsageRecordWriter<'_>,
    http: &reqwest::Client,
    tenant_map: &TenantCustomerMap,
    health_state: &SharedHealthState,
) {
    match storage::poll_storage(cfg, writer, http, tenant_map).await {
        Ok(()) => {
            if let Ok(mut guard) = health_state.lock() {
                guard.last_storage_poll_at = Some(chrono::Utc::now());
            }
        }
        Err(e) => {
            tracing::error!("storage poll failed: {:#}", e);
        }
    }
}

/// Refresh the in-memory tenant→customer mapping from `/internal/tenant-map`.
async fn handle_tenant_map_refresh(
    cfg: &Config,
    http: &reqwest::Client,
    tenant_map: &TenantCustomerMap,
) {
    match tenant_map::refresh_tenant_map(cfg, http, tenant_map).await {
        Ok(count) => info!(entries = count, "refreshed tenant map"),
        Err(err) => tracing::warn!("tenant-map refresh failed: {:#}", err),
    }
}

/// Tear down the health server and close the database connection pool.
async fn graceful_shutdown(health_handle: tokio::task::JoinHandle<()>, pool: sqlx::PgPool) {
    let _ = health_handle.await;
    pool.close().await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{extract::State, routing::post, Json, Router};
    use serde_json::Value;
    use std::sync::{Arc, Mutex};
    use tokio::net::TcpListener;

    type CapturedBodies = Arc<Mutex<Vec<Value>>>;

    async fn capture_webhook(
        State(captured): State<CapturedBodies>,
        Json(payload): Json<Value>,
    ) -> &'static str {
        captured
            .lock()
            .expect("capture mutex should lock")
            .push(payload);
        "ok"
    }

    async fn spawn_webhook_receiver() -> (String, CapturedBodies, tokio::task::JoinHandle<()>) {
        let captured: CapturedBodies = Arc::new(Mutex::new(Vec::new()));
        let app = Router::new()
            .route("/", post(capture_webhook))
            .with_state(Arc::clone(&captured));
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("listener should bind");
        let addr = listener.local_addr().expect("listener should expose addr");
        let handle = tokio::spawn(async move {
            axum::serve(listener, app)
                .await
                .expect("webhook receiver should run");
        });
        (format!("http://{addr}"), captured, handle)
    }

    fn test_config_with_webhooks(
        slack_webhook_url: Option<&str>,
        discord_webhook_url: Option<&str>,
    ) -> Config {
        Config::from_reader(|key| match key {
            "FLAPJACK_URL" => Ok("http://localhost:7700".into()),
            "FLAPJACK_API_KEY" => Ok("test-key".into()),
            "DATABASE_URL" => Ok("postgres://localhost/test".into()),
            "CUSTOMER_ID" => Ok("550e8400-e29b-41d4-a716-446655440000".into()),
            "NODE_ID" => Ok("node-alert-node".into()),
            "REGION" => Ok("us-east-1".into()),
            "ENVIRONMENT" => Ok("stage1-test".into()),
            "SLACK_WEBHOOK_URL" => slack_webhook_url
                .map(ToString::to_string)
                .ok_or(std::env::VarError::NotPresent),
            "DISCORD_WEBHOOK_URL" => discord_webhook_url
                .map(ToString::to_string)
                .ok_or(std::env::VarError::NotPresent),
            _ => Err(std::env::VarError::NotPresent),
        })
        .expect("test config should parse")
    }

    fn test_scrape_context<'a>(
        cfg: &'a Config,
        writer: &'a record::PgUsageRecordWriter<'a>,
        http: &'a reqwest::Client,
        tenant_state: &'a TenantStateMap,
        tenant_map: &'a TenantCustomerMap,
    ) -> ScrapeContext<'a> {
        ScrapeContext {
            cfg,
            writer,
            http,
            tenant_state,
            tenant_map,
        }
    }

    fn assert_critical_slack_breaker_payload(body: &Value) {
        let attachments = body["attachments"]
            .as_array()
            .expect("payload should expose Slack-style 'attachments'");
        assert_eq!(attachments.len(), 1, "expected one Slack attachment");
        assert_eq!(attachments[0]["color"], "#d00000");
        assert!(
            body.get("embeds").is_none(),
            "slack payload should not include Discord embed fields"
        );

        let slack_fields = attachments[0]["fields"]
            .as_array()
            .expect("Slack payload should include fields");
        assert!(
            slack_fields
                .iter()
                .any(|field| field["title"] == "severity" && field["value"] == "critical"),
            "severity metadata must include critical"
        );
        assert!(
            slack_fields
                .iter()
                .any(|field| field["title"] == "customer_id"
                    && field["value"] == "550e8400-e29b-41d4-a716-446655440000"),
            "customer_id metadata must be present"
        );
        assert!(
            slack_fields
                .iter()
                .any(|field| field["title"] == "node_id" && field["value"] == "node-alert-node"),
            "node_id metadata must be present"
        );
        assert!(
            slack_fields
                .iter()
                .any(|field| field["title"] == "region" && field["value"] == "us-east-1"),
            "region metadata must be present"
        );
        assert!(
            slack_fields
                .iter()
                .any(|field| field["title"] == "Environment" && field["value"] == "stage1-test"),
            "environment metadata must be present"
        );
    }

    fn assert_critical_discord_breaker_payload(body: &Value) {
        let embeds = body["embeds"]
            .as_array()
            .expect("payload should expose Discord-style 'embeds'");
        assert_eq!(embeds.len(), 1, "expected one Discord embed");
        assert_eq!(embeds[0]["color"], 0xd00000_u32);
        assert!(
            body.get("attachments").is_none(),
            "discord payload should not include Slack attachment fields"
        );

        let discord_fields = embeds[0]["fields"]
            .as_array()
            .expect("Discord payload should include fields");
        assert!(
            discord_fields
                .iter()
                .any(|field| field["name"] == "severity" && field["value"] == "critical"),
            "severity metadata must include critical"
        );
        assert!(
            discord_fields
                .iter()
                .any(|field| field["name"] == "customer_id"
                    && field["value"] == "550e8400-e29b-41d4-a716-446655440000"),
            "customer_id metadata must be present"
        );
        assert!(
            discord_fields
                .iter()
                .any(|field| field["name"] == "node_id" && field["value"] == "node-alert-node"),
            "node_id metadata must be present"
        );
        assert!(
            discord_fields
                .iter()
                .any(|field| field["name"] == "region" && field["value"] == "us-east-1"),
            "region metadata must be present"
        );
        assert!(
            discord_fields
                .iter()
                .any(|field| field["name"] == "Environment" && field["value"] == "stage1-test"),
            "environment metadata must be present"
        );
    }

    #[tokio::test]
    async fn handle_scrape_cycle_alerts_once_on_closed_to_open_transition() {
        let (webhook_url, captured, server_handle) = spawn_webhook_receiver().await;
        let cfg = test_config_with_webhooks(Some(&webhook_url), None);

        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(1)
            .acquire_timeout(Duration::from_millis(100))
            .connect_lazy("postgres://test:test@127.0.0.1:1/test")
            .expect("connect_lazy should succeed");
        let writer = record::PgUsageRecordWriter { pool: &pool };
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
            .expect("reqwest client should build");
        let tenant_state: TenantStateMap = Arc::new(dashmap::DashMap::new());
        let tenant_map: TenantCustomerMap = Arc::new(dashmap::DashMap::new());
        let scrape_context = test_scrape_context(&cfg, &writer, &http, &tenant_state, &tenant_map);
        let health_state: SharedHealthState = Arc::new(Mutex::new(health::HealthState::new()));
        let mut circuit_breaker = CircuitBreaker::new(Duration::from_secs(60));

        for _ in 0..4 {
            handle_scrape_cycle_with_result(
                &scrape_context,
                &mut circuit_breaker,
                &health_state,
                Err(anyhow::anyhow!("simulated scrape failure")),
            )
            .await;
        }

        assert_eq!(
            captured.lock().expect("capture mutex should lock").len(),
            0,
            "failures 1-4 should not emit an alert"
        );

        handle_scrape_cycle_with_result(
            &scrape_context,
            &mut circuit_breaker,
            &health_state,
            Err(anyhow::anyhow!("simulated scrape failure")),
        )
        .await;

        let captured_bodies = captured.lock().expect("capture mutex should lock");
        assert_eq!(
            captured_bodies.len(),
            1,
            "failure 5 should emit exactly one transition alert"
        );
        assert_critical_slack_breaker_payload(&captured_bodies[0]);

        server_handle.abort();
    }

    #[tokio::test]
    async fn handle_scrape_cycle_keeps_sixth_failure_quiet_while_open() {
        let (webhook_url, captured, server_handle) = spawn_webhook_receiver().await;
        let cfg = test_config_with_webhooks(Some(&webhook_url), None);

        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(1)
            .acquire_timeout(Duration::from_millis(100))
            .connect_lazy("postgres://test:test@127.0.0.1:1/test")
            .expect("connect_lazy should succeed");
        let writer = record::PgUsageRecordWriter { pool: &pool };
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
            .expect("reqwest client should build");
        let tenant_state: TenantStateMap = Arc::new(dashmap::DashMap::new());
        let tenant_map: TenantCustomerMap = Arc::new(dashmap::DashMap::new());
        let scrape_context = test_scrape_context(&cfg, &writer, &http, &tenant_state, &tenant_map);
        let health_state: SharedHealthState = Arc::new(Mutex::new(health::HealthState::new()));
        let mut circuit_breaker = CircuitBreaker::new(Duration::from_secs(60));

        for _ in 0..5 {
            handle_scrape_cycle_with_result(
                &scrape_context,
                &mut circuit_breaker,
                &health_state,
                Err(anyhow::anyhow!("simulated scrape failure")),
            )
            .await;
        }
        assert_eq!(
            captured.lock().expect("capture mutex should lock").len(),
            1,
            "failure 5 should emit exactly one transition alert"
        );

        handle_scrape_cycle_with_result(
            &scrape_context,
            &mut circuit_breaker,
            &health_state,
            Err(anyhow::anyhow!("simulated scrape failure")),
        )
        .await;

        assert_eq!(
            captured.lock().expect("capture mutex should lock").len(),
            1,
            "failure 6 should not emit a second alert while breaker remains open"
        );

        server_handle.abort();
    }

    #[tokio::test]
    async fn handle_scrape_cycle_alerts_to_both_webhook_channels() {
        let (slack_url, slack_captured, slack_server_handle) = spawn_webhook_receiver().await;
        let (discord_url, discord_captured, discord_server_handle) = spawn_webhook_receiver().await;
        let cfg = test_config_with_webhooks(Some(&slack_url), Some(&discord_url));

        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(1)
            .acquire_timeout(Duration::from_millis(100))
            .connect_lazy("postgres://test:test@127.0.0.1:1/test")
            .expect("connect_lazy should succeed");
        let writer = record::PgUsageRecordWriter { pool: &pool };
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
            .expect("reqwest client should build");
        let tenant_state: TenantStateMap = Arc::new(dashmap::DashMap::new());
        let tenant_map: TenantCustomerMap = Arc::new(dashmap::DashMap::new());
        let scrape_context = test_scrape_context(&cfg, &writer, &http, &tenant_state, &tenant_map);
        let health_state: SharedHealthState = Arc::new(Mutex::new(health::HealthState::new()));
        let mut circuit_breaker = CircuitBreaker::new(Duration::from_secs(60));

        for _ in 0..5 {
            handle_scrape_cycle_with_result(
                &scrape_context,
                &mut circuit_breaker,
                &health_state,
                Err(anyhow::anyhow!("simulated scrape failure")),
            )
            .await;
        }

        let slack_captured_bodies = slack_captured.lock().expect("capture mutex should lock");
        let discord_captured_bodies = discord_captured.lock().expect("capture mutex should lock");
        assert_eq!(
            slack_captured_bodies.len(),
            1,
            "slack webhook should receive exactly one transition alert"
        );
        assert_eq!(
            discord_captured_bodies.len(),
            1,
            "discord webhook should receive exactly one transition alert"
        );
        assert_critical_slack_breaker_payload(&slack_captured_bodies[0]);
        assert_critical_discord_breaker_payload(&discord_captured_bodies[0]);

        slack_server_handle.abort();
        discord_server_handle.abort();
    }
}
