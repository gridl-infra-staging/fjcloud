use chrono::Utc;

use super::record;
use super::{tenant_map::TenantCustomerMap, Config};

#[derive(Debug, serde::Deserialize)]
pub struct StorageResponse {
    tenants: Vec<TenantStorage>,
}

#[derive(Debug, serde::Deserialize)]
pub(crate) struct TenantStorage {
    id: String,
    bytes: i64,
}

#[derive(Debug, Clone, serde::Deserialize)]
pub struct ColdStorageUsageEntry {
    pub customer_id: uuid::Uuid,
    pub tenant_id: String,
    pub size_bytes: i64,
}

/// Fetch current disk-usage gauges from flapjack and write storage usage
/// records for all indexes visible to this node.
///
/// Two sources are queried in sequence:
///
/// 1. **Hot storage** — `GET /internal/storage` on the local flapjack node.
///    Returns a list of `(tenant_id, bytes)` pairs covering all live indexes
///    currently hosted.  Cold/restoring indexes are filtered out here;
///    their storage is billed via the cold-storage path below.
///
/// 2. **Cold storage** — `GET <cold_storage_usage_url>` on the control-plane
///    API, which returns snapshot sizes for indexes in the `cold` tier.  A
///    failure from this endpoint is logged as a warning and does not abort the
///    poll — live-storage records are still persisted even if cold usage is
///    temporarily unavailable.
///
/// Both paths call `writer.write` for each generated record, propagating DB
/// errors to the caller.
pub async fn poll_storage(
    cfg: &Config,
    writer: &dyn record::UsageRecordWriter,
    http: &reqwest::Client,
    tenant_map: &TenantCustomerMap,
) -> anyhow::Result<()> {
    let resp: StorageResponse = http
        .get(cfg.storage_url())
        .header("X-Algolia-API-Key", &cfg.flapjack_api_key)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    let now = Utc::now();
    for rec in build_storage_usage_records(cfg, &resp.tenants, tenant_map, now) {
        writer.write(&rec).await?;
    }

    match fetch_cold_storage_usage(cfg, http).await {
        Ok(cold_usage) => {
            for rec in build_cold_storage_usage_records(cfg, &cold_usage, tenant_map, now) {
                writer.write(&rec).await?;
            }
        }
        Err(err) => {
            tracing::warn!("cold-storage-usage poll failed: {:#}", err);
        }
    }

    Ok(())
}

/// Convert a raw list of hot-storage tenant entries into `StorageBytes` usage
/// records attributed to the correct customers.
///
/// For each entry in `tenants`:
/// - Looks up the `tenant_id` in the `tenant_map`.  Missing entries are
///   warned and skipped — they indicate a stale or out-of-sync tenant map.
/// - Skips indexes whose tier is `cold` or `restoring`; those are metered
///   separately via [`build_cold_storage_usage_records`].
/// - Builds a [`record::UsageRecord`] with the raw byte count as the gauge
///   value and the node/region context from `cfg`.
pub fn build_storage_usage_records(
    cfg: &Config,
    tenants: &[TenantStorage],
    tenant_map: &TenantCustomerMap,
    now: chrono::DateTime<chrono::Utc>,
) -> Vec<record::UsageRecord> {
    let ctx = record::RecordContext {
        node_id: &cfg.node_id,
        region: &cfg.region,
        now,
    };
    let mut records = Vec::new();

    for tenant in tenants {
        let attribution =
            match super::tenant_map::resolve_tenant_attribution(tenant_map, &tenant.id) {
                Some(tenant) => tenant,
                None => {
                    tracing::warn!(
                        tenant_id = tenant.id.as_str(),
                        "tenant map missing index during storage poll; skipping usage attribution"
                    );
                    continue;
                }
            };
        if super::tenant_map::is_cold_tier(&attribution.tier) {
            continue;
        }

        records.push(record::build_usage_record(
            &ctx,
            attribution.customer_id,
            &attribution.tenant_id,
            record::EventType::StorageBytes,
            tenant.bytes,
        ));
    }

    records
}

/// Convert cold-tier storage usage entries (snapshot sizes) into
/// `StorageBytes` usage records.
///
/// Only entries that satisfy all three conditions produce a record:
///
/// 1. The `tenant_id` exists in the `tenant_map` (unknown indexes are
///    silently skipped — the control-plane owns cold-tier attribution).
/// 2. The index's tier is `cold` or `restoring` — active indexes must not
///    be double-counted here (they are covered by hot storage polling).
/// 3. The `customer_id` in the payload matches the attribution in the tenant
///    map.  A mismatch indicates a data inconsistency between the cold-storage
///    service and the tenant map; it is logged as a warning and skipped rather
///    than persisted with potentially wrong attribution.
pub fn build_cold_storage_usage_records(
    cfg: &Config,
    entries: &[ColdStorageUsageEntry],
    tenant_map: &TenantCustomerMap,
    now: chrono::DateTime<chrono::Utc>,
) -> Vec<record::UsageRecord> {
    let mut records = Vec::new();

    for entry in entries {
        let Some(attribution) =
            super::tenant_map::resolve_tenant_attribution(tenant_map, &entry.tenant_id)
        else {
            continue;
        };
        if !super::tenant_map::is_cold_tier(&attribution.tier) {
            continue;
        }
        if attribution.customer_id != entry.customer_id {
            tracing::warn!(
                tenant_id = entry.tenant_id.as_str(),
                expected_customer_id = %attribution.customer_id,
                payload_customer_id = %entry.customer_id,
                "cold-storage-usage customer mismatch; skipping record"
            );
            continue;
        }

        let ctx = record::RecordContext {
            node_id: &cfg.node_id,
            region: &cfg.region,
            now,
        };
        records.push(record::build_usage_record(
            &ctx,
            entry.customer_id,
            &entry.tenant_id,
            record::EventType::StorageBytes,
            entry.size_bytes,
        ));
    }

    records
}

pub async fn fetch_cold_storage_usage(
    cfg: &Config,
    http: &reqwest::Client,
) -> anyhow::Result<Vec<ColdStorageUsageEntry>> {
    let response = http
        .get(cfg.cold_storage_usage_url())
        .header("x-internal-key", &cfg.internal_key)
        .send()
        .await?
        .error_for_status()?;
    Ok(response.json::<Vec<ColdStorageUsageEntry>>().await?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{extract::State, http::HeaderMap, routing::get, Router};
    use dashmap::DashMap;
    use std::sync::Arc;
    use tokio::net::TcpListener;

    use crate::config::Config;

    #[derive(Clone)]
    struct HeaderCaptureState {
        observed_key: Arc<std::sync::Mutex<Option<String>>>,
        payload: Arc<String>,
    }

    async fn spawn_cold_storage_server(
        state: HeaderCaptureState,
    ) -> (String, tokio::task::JoinHandle<()>) {
        let app = Router::new()
            .route(
                "/internal/cold-storage-usage",
                get(capture_cold_storage_headers),
            )
            .with_state(state);
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("listener should bind");
        let addr = listener.local_addr().expect("listener should expose addr");
        let handle = tokio::spawn(async move {
            axum::serve(listener, app)
                .await
                .expect("test server should run");
        });
        (format!("http://{addr}"), handle)
    }

    async fn capture_cold_storage_headers(
        State(state): State<HeaderCaptureState>,
        headers: HeaderMap,
    ) -> String {
        let observed = headers
            .get("x-internal-key")
            .and_then(|value| value.to_str().ok())
            .map(ToOwned::to_owned);
        *state
            .observed_key
            .lock()
            .expect("header capture mutex should lock") = observed;
        (*state.payload).clone()
    }

    /// Guards the cold-storage tier filter: only indexes whose tenant-map tier
    /// is `"cold"` should produce a `StorageBytes` record from
    /// `build_cold_storage_usage_records`.
    ///
    /// The test inserts one `cold` index and one `active` index into the
    /// tenant map, then submits usage entries for both.  The invariant is that
    /// exactly one record is emitted — for the cold index — and the active
    /// index is silently skipped to avoid double-counting with the hot-storage
    /// poll path.
    #[test]
    fn metering_generates_cold_storage_usage_records() {
        let cfg = Config {
            flapjack_url: "http://localhost:7700".to_string(),
            flapjack_api_key: "test-key".to_string(),
            internal_key: "test-key".to_string(),
            scrape_interval: std::time::Duration::from_secs(60),
            storage_poll_interval: std::time::Duration::from_secs(300),
            tenant_map_refresh_interval: std::time::Duration::from_secs(300),
            database_url: "postgres://localhost/test".to_string(),
            customer_id: uuid::Uuid::new_v4(),
            node_id: "node-a".to_string(),
            region: "us-east-1".to_string(),
            health_port: 9091,
            tenant_map_url: "http://127.0.0.1:3001/internal/tenant-map".to_string(),
            cold_storage_usage_url: "http://127.0.0.1:3001/internal/cold-storage-usage".to_string(),
        };

        let tenant_map: super::super::tenant_map::TenantCustomerMap = Arc::new(DashMap::new());
        let customer_id = uuid::Uuid::new_v4();

        tenant_map.insert(
            "cold-idx".to_string(),
            super::super::tenant_map::TenantAttribution {
                customer_id,
                tenant_id: "cold-idx".to_string(),
                tier: "cold".to_string(),
            },
        );
        tenant_map.insert(
            "active-idx".to_string(),
            super::super::tenant_map::TenantAttribution {
                customer_id,
                tenant_id: "active-idx".to_string(),
                tier: "active".to_string(),
            },
        );

        let records = build_cold_storage_usage_records(
            &cfg,
            &[
                ColdStorageUsageEntry {
                    customer_id,
                    tenant_id: "cold-idx".to_string(),
                    size_bytes: 10,
                },
                ColdStorageUsageEntry {
                    customer_id,
                    tenant_id: "active-idx".to_string(),
                    size_bytes: 20,
                },
            ],
            &tenant_map,
            chrono::Utc::now(),
        );

        assert_eq!(records.len(), 1);
        assert_eq!(records[0].tenant_id, "cold-idx");
        assert_eq!(records[0].value, 10);
        assert_eq!(records[0].event_type, record::EventType::StorageBytes);
    }

    #[tokio::test]
    async fn fetch_cold_storage_usage_sends_internal_key_header() {
        let observed_key = Arc::new(std::sync::Mutex::new(None));
        let payload = Arc::new(
            r#"[{"customer_id":"00000000-0000-0000-0000-000000000000","tenant_id":"cold-idx","size_bytes":42}]"#
                .to_string(),
        );
        let state = HeaderCaptureState {
            observed_key: Arc::clone(&observed_key),
            payload: Arc::clone(&payload),
        };
        let (base_url, handle) = spawn_cold_storage_server(state).await;
        let cfg = Config {
            flapjack_url: "http://localhost:7700".to_string(),
            flapjack_api_key: "node-api-key".to_string(),
            internal_key: "internal-key-123".to_string(),
            scrape_interval: std::time::Duration::from_secs(60),
            storage_poll_interval: std::time::Duration::from_secs(300),
            tenant_map_refresh_interval: std::time::Duration::from_secs(300),
            database_url: "postgres://localhost/test".to_string(),
            customer_id: uuid::Uuid::new_v4(),
            node_id: "node-a".to_string(),
            region: "us-east-1".to_string(),
            health_port: 9091,
            tenant_map_url: format!("{base_url}/internal/tenant-map"),
            cold_storage_usage_url: format!("{base_url}/internal/cold-storage-usage"),
        };
        let http = reqwest::Client::new();

        let entries = fetch_cold_storage_usage(&cfg, &http)
            .await
            .expect("cold storage usage request should succeed");

        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].size_bytes, 42);
        assert_eq!(
            observed_key
                .lock()
                .expect("header capture mutex should lock")
                .clone(),
            Some("internal-key-123".to_string())
        );
        handle.abort();
    }
}
