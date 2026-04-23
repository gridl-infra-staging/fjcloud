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
    match scrape_and_record(
        scrape_context.cfg,
        scrape_context.writer,
        scrape_context.http,
        scrape_context.tenant_state,
        scrape_context.tenant_map,
    )
    .await
    {
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
            let next = circuit_breaker.record_failure();
            if circuit_breaker.is_open() {
                tracing::warn!(
                    next_retry_secs = next.as_secs(),
                    "circuit breaker open — backing off"
                );
            }
            next
        }
    }
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
