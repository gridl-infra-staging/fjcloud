use dashmap::DashMap;
use std::collections::HashMap;
use std::sync::Arc;

use super::record;
use super::tenant_map::{is_cold_tier, resolve_tenant_attribution, TenantCustomerMap};
use crate::config::Config;
use crate::delta::CounterState;
use crate::scraper;

pub type TenantStateMap = Arc<DashMap<String, CounterState>>;

struct CounterTotals<'a> {
    search_totals: &'a HashMap<String, u64>,
    write_totals: &'a HashMap<String, u64>,
    indexed_totals: &'a HashMap<String, u64>,
    deleted_totals: &'a HashMap<String, u64>,
}

/// Perform one full scrape cycle: fetch Prometheus metrics from flapjack,
/// compute per-index deltas and document-count snapshots, then persist a
/// usage record for each non-zero result.
///
/// HTTP errors (connection failure, non-2xx status) are propagated to the
/// caller, which runs a circuit breaker to back off on repeated failures.
/// Individual record-write errors are also propagated so the caller can
/// decide whether to retry.
pub async fn scrape_and_record(
    cfg: &Config,
    writer: &dyn record::UsageRecordWriter,
    http: &reqwest::Client,
    state: &TenantStateMap,
    tenant_map: &TenantCustomerMap,
) -> anyhow::Result<()> {
    let body = http
        .get(cfg.metrics_url())
        .header("X-Algolia-API-Key", &cfg.flapjack_api_key)
        .header("X-Algolia-Application-Id", &cfg.flapjack_application_id)
        .send()
        .await?
        .error_for_status()?
        .text()
        .await?;

    let samples = scraper::parse_prometheus_text(&body)?;
    let metrics = scraper::extract_flapjack_metrics(&samples);
    let now = chrono::Utc::now();

    for rec in build_counter_usage_records(cfg, &metrics, state, tenant_map, now) {
        writer.write(&rec).await?;
    }

    Ok(())
}

/// Build the full set of usage records for one scrape cycle.
///
/// Combines two record sources:
/// 1. **Counter deltas** — per-index incremental counts for searches, writes,
///    documents indexed, and documents deleted, computed by
///    [`build_counter_delta_records`].
/// 2. **Document-count gauges** — point-in-time snapshot of the document
///    count for each live index, computed by [`build_document_count_records`].
///
/// Cold and restoring indexes are excluded from both sources.
pub fn build_counter_usage_records(
    cfg: &Config,
    metrics: &scraper::FlapjackMetrics,
    state: &TenantStateMap,
    tenant_map: &TenantCustomerMap,
    now: chrono::DateTime<chrono::Utc>,
) -> Vec<record::UsageRecord> {
    let mut records = Vec::new();
    records.extend_from_slice(&build_counter_delta_records(
        cfg,
        &CounterTotals {
            search_totals: &metrics.search_requests_total,
            write_totals: &metrics.write_operations_total,
            indexed_totals: &metrics.documents_indexed_total,
            deleted_totals: &metrics.documents_deleted_total,
        },
        state,
        tenant_map,
        now,
    ));
    records.extend_from_slice(&build_document_count_records(
        cfg,
        &metrics.documents_count,
        tenant_map,
        now,
    ));

    records
}

/// Compute per-index delta usage records from monotonic Prometheus counters.
///
/// For each `tenant_id` present in `totals.search_totals`:
/// - Resolves customer attribution from `tenant_map`; unmapped indexes are
///   warned and skipped.
/// - Skips cold/restoring tiers — live counter metrics do not apply to them.
/// - Calls [`CounterState::advance`] to compute the delta since the previous
///   scrape.  On the very first scrape for an index, `advance` returns zero
///   for all counters (the baseline is set but nothing is emitted).
/// - Emits one record per event type (search, write, indexed, deleted) only
///   when the delta is non-zero, preventing zero-value noise in the DB.
///
/// Other counter totals (write, indexed, deleted) default to 0 when absent
/// from the scrape payload so a partial metrics exposure never panics.
fn build_counter_delta_records(
    cfg: &Config,
    totals: &CounterTotals<'_>,
    state: &TenantStateMap,
    tenant_map: &TenantCustomerMap,
    now: chrono::DateTime<chrono::Utc>,
) -> Vec<record::UsageRecord> {
    let ctx = record::RecordContext {
        node_id: &cfg.node_id,
        region: &cfg.region,
        now,
    };
    let mut records = Vec::new();

    for (tenant_id, search_total) in totals.search_totals {
        let tenant = match resolve_tenant_attribution(tenant_map, tenant_id) {
            Some(tenant) => tenant,
            None => {
                tracing::warn!(
                    tenant_id = tenant_id.as_str(),
                    "tenant map missing index during metrics scrape; skipping usage attribution"
                );
                continue;
            }
        };

        if is_cold_tier(&tenant.tier) {
            continue;
        }

        // Delta state belongs to the canonical tenant id, not the flapjack
        // label observed in this scrape, so alias/canonical label changes do
        // not reset the billing baseline mid-stream.
        let mut entry = state.entry(tenant.tenant_id.clone()).or_default();
        let write_total = totals.write_totals.get(tenant_id).copied().unwrap_or(0);
        let indexed_total = totals.indexed_totals.get(tenant_id).copied().unwrap_or(0);
        let deleted_total = totals.deleted_totals.get(tenant_id).copied().unwrap_or(0);
        let deltas = entry.advance(*search_total, write_total, indexed_total, deleted_total);

        for (event_type, value) in [
            (record::EventType::SearchRequests, deltas.search_requests),
            (record::EventType::WriteOperations, deltas.write_operations),
            (
                record::EventType::DocumentsIndexed,
                deltas.documents_indexed,
            ),
            (
                record::EventType::DocumentsDeleted,
                deltas.documents_deleted,
            ),
        ] {
            if value == 0 {
                continue;
            }
            records.push(record::build_usage_record(
                &ctx,
                tenant.customer_id,
                &tenant.tenant_id,
                event_type,
                value as i64,
            ));
        }
    }

    records
}

/// Build point-in-time `DocumentCount` gauge records for all live indexes.
///
/// Unlike the counter-delta path, document count is emitted as an absolute
/// snapshot value every scrape cycle (it is a gauge, not a monotonic
/// counter).  Cold and restoring indexes are excluded — their document counts
/// are not meaningful while the index is off-line.  Unmapped indexes are
/// warned and skipped.
fn build_document_count_records(
    cfg: &Config,
    doc_counts: &std::collections::HashMap<String, u64>,
    tenant_map: &TenantCustomerMap,
    now: chrono::DateTime<chrono::Utc>,
) -> Vec<record::UsageRecord> {
    let ctx = record::RecordContext {
        node_id: &cfg.node_id,
        region: &cfg.region,
        now,
    };
    let mut records = Vec::new();

    for (tenant_id, &doc_count) in doc_counts {
        let tenant = match resolve_tenant_attribution(tenant_map, tenant_id) {
            Some(tenant) => tenant,
            None => {
                tracing::warn!(
                    tenant_id = tenant_id.as_str(),
                    "tenant map missing index during doc-count scrape; skipping usage attribution"
                );
                continue;
            }
        };

        if is_cold_tier(&tenant.tier) {
            continue;
        }

        records.push(record::build_usage_record(
            &ctx,
            tenant.customer_id,
            &tenant.tenant_id,
            record::EventType::DocumentCount,
            doc_count as i64,
        ));
    }

    records
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tenant_map::TenantAttribution;
    use chrono::Utc;
    use dashmap::DashMap;
    use std::sync::Arc;
    use uuid::Uuid;

    /// Returns a minimal [`Config`] suitable for unit tests.
    ///
    /// Uses `localhost:7700` as the flapjack URL, a dummy Postgres URL that
    /// won't actually be connected to, and default scrape/poll intervals.
    /// The `customer_id` is a freshly generated UUID so tests that inspect
    /// it need to capture it separately.
    fn test_config() -> Config {
        Config {
            flapjack_url: "http://localhost:7700".to_string(),
            flapjack_api_key: "test-key".to_string(),
            flapjack_application_id: "flapjack".to_string(),
            internal_key: "test-key".to_string(),
            scrape_interval: std::time::Duration::from_secs(60),
            storage_poll_interval: std::time::Duration::from_secs(300),
            tenant_map_refresh_interval: std::time::Duration::from_secs(300),
            database_url: "postgres://localhost/test".to_string(),
            customer_id: Uuid::new_v4().to_string(),
            node_id: "node-a".to_string(),
            region: "us-east-1".to_string(),
            environment: "test".to_string(),
            slack_webhook_url: None,
            discord_webhook_url: None,
            health_port: 9091,
            tenant_map_url: "http://127.0.0.1:3001/internal/tenant-map".to_string(),
            cold_storage_usage_url: "http://127.0.0.1:3001/internal/cold-storage-usage".to_string(),
        }
    }

    fn setup_active_counter_test(name: &str) -> (Config, TenantStateMap, TenantCustomerMap) {
        let cfg = test_config();
        let state: TenantStateMap = Arc::new(DashMap::new());
        let tenant_map: TenantCustomerMap = Arc::new(DashMap::new());
        let customer_id = Uuid::new_v4();
        tenant_map.insert(
            name.to_string(),
            TenantAttribution {
                customer_id,
                tenant_id: name.to_string(),
                tier: "active".to_string(),
            },
        );
        state.insert(name.to_string(), CounterState::default());
        (cfg, state, tenant_map)
    }

    /// Guards the attribution invariant: usage records must carry the
    /// `customer_id` of the customer who owns the index, not a shared or
    /// default ID.
    ///
    /// Sets up two indexes owned by different customers, injects deltas for
    /// both, and asserts that each resulting record carries the correct
    /// `customer_id`.  A bug in tenant-map lookup or record construction that
    /// mixed up customer IDs would be caught here.
    #[test]
    fn metering_attributes_metrics_to_correct_customer() {
        let cfg = test_config();
        let state: TenantStateMap = Arc::new(DashMap::new());
        let tenant_map: TenantCustomerMap = Arc::new(DashMap::new());

        let customer_a = Uuid::new_v4();
        let customer_b = Uuid::new_v4();
        tenant_map.insert(
            "products".to_string(),
            TenantAttribution {
                customer_id: customer_a,
                tenant_id: "products".to_string(),
                tier: "active".to_string(),
            },
        );
        tenant_map.insert(
            "orders".to_string(),
            TenantAttribution {
                customer_id: customer_b,
                tenant_id: "orders".to_string(),
                tier: "active".to_string(),
            },
        );

        state.insert(
            "products".to_string(),
            CounterState {
                search_requests: Some(10),
                write_operations: Some(0),
                documents_indexed: Some(0),
                documents_deleted: Some(0),
            },
        );
        state.insert(
            "orders".to_string(),
            CounterState {
                search_requests: Some(20),
                write_operations: Some(0),
                documents_indexed: Some(0),
                documents_deleted: Some(0),
            },
        );

        let mut metrics = crate::scraper::FlapjackMetrics::default();
        metrics
            .search_requests_total
            .insert("products".to_string(), 15);
        metrics
            .search_requests_total
            .insert("orders".to_string(), 27);

        let records = build_counter_usage_records(&cfg, &metrics, &state, &tenant_map, Utc::now());

        let products = records
            .iter()
            .find(|r| {
                r.tenant_id == "products" && r.event_type == record::EventType::SearchRequests
            })
            .expect("products search record should be present");
        assert_eq!(products.customer_id, customer_a);

        let orders = records
            .iter()
            .find(|r| r.tenant_id == "orders" && r.event_type == record::EventType::SearchRequests)
            .expect("orders search record should be present");
        assert_eq!(orders.customer_id, customer_b);
    }

    /// Guards the unmapped-index guard: metrics for indexes that have no entry
    /// in the tenant map must not produce usage records.
    ///
    /// This prevents billing for indexes that the control plane doesn't know
    /// about (e.g. stale flapjack state after an index is deleted).  The
    /// "known" index should still produce a record; the "unknown" index must
    /// be entirely absent from the output.
    #[test]
    fn metering_skips_unmapped_indexes() {
        let cfg = test_config();
        let state: TenantStateMap = Arc::new(DashMap::new());
        let tenant_map: TenantCustomerMap = Arc::new(DashMap::new());

        let customer = Uuid::new_v4();
        tenant_map.insert(
            "known".to_string(),
            TenantAttribution {
                customer_id: customer,
                tenant_id: "known".to_string(),
                tier: "active".to_string(),
            },
        );

        state.insert(
            "known".to_string(),
            CounterState {
                search_requests: Some(1),
                write_operations: Some(0),
                documents_indexed: Some(0),
                documents_deleted: Some(0),
            },
        );
        state.insert(
            "unknown".to_string(),
            CounterState {
                search_requests: Some(1),
                write_operations: Some(0),
                documents_indexed: Some(0),
                documents_deleted: Some(0),
            },
        );

        let mut metrics = crate::scraper::FlapjackMetrics::default();
        metrics.search_requests_total.insert("known".to_string(), 3);
        metrics
            .search_requests_total
            .insert("unknown".to_string(), 8);

        let records = build_counter_usage_records(&cfg, &metrics, &state, &tenant_map, Utc::now());

        assert!(records.iter().any(|r| r.tenant_id == "known"));
        assert!(records.iter().all(|r| r.tenant_id != "unknown"));
    }

    #[test]
    fn metering_uses_canonical_tenant_id_when_metrics_use_flapjack_uid() {
        let cfg = test_config();
        let state: TenantStateMap = Arc::new(DashMap::new());
        let tenant_map: TenantCustomerMap = Arc::new(DashMap::new());
        let customer_id = Uuid::new_v4();
        let flapjack_uid = format!("{}_products", customer_id.as_simple());

        tenant_map.insert(
            flapjack_uid.clone(),
            TenantAttribution {
                customer_id,
                tenant_id: "products".to_string(),
                tier: "active".to_string(),
            },
        );

        state.insert(flapjack_uid.clone(), CounterState::default());

        let mut metrics = crate::scraper::FlapjackMetrics::default();
        metrics
            .search_requests_total
            .insert(flapjack_uid.clone(), 10);
        metrics.documents_count.insert(flapjack_uid, 4);

        let first_records =
            build_counter_usage_records(&cfg, &metrics, &state, &tenant_map, Utc::now());
        assert!(
            first_records
                .iter()
                .all(|record| record.tenant_id == "products"),
            "first scrape should establish state using the canonical tenant id"
        );

        let mut metrics2 = crate::scraper::FlapjackMetrics::default();
        metrics2
            .search_requests_total
            .insert(format!("{}_products", customer_id.as_simple()), 12);
        metrics2
            .documents_count
            .insert(format!("{}_products", customer_id.as_simple()), 5);
        let records = build_counter_usage_records(&cfg, &metrics2, &state, &tenant_map, Utc::now());
        assert!(
            records.iter().all(|record| record.tenant_id == "products"),
            "billing rows should store the customer-facing tenant id"
        );
    }

    #[test]
    fn metering_preserves_counter_state_across_alias_to_canonical_label_change() {
        let cfg = test_config();
        let state: TenantStateMap = Arc::new(DashMap::new());
        let tenant_map: TenantCustomerMap = Arc::new(DashMap::new());
        let customer_id = Uuid::new_v4();
        let flapjack_uid = format!("{}_products", customer_id.as_simple());

        tenant_map.insert(
            "products".to_string(),
            TenantAttribution {
                customer_id,
                tenant_id: "products".to_string(),
                tier: "active".to_string(),
            },
        );
        tenant_map.insert(
            flapjack_uid.clone(),
            TenantAttribution {
                customer_id,
                tenant_id: "products".to_string(),
                tier: "active".to_string(),
            },
        );

        let mut alias_metrics = crate::scraper::FlapjackMetrics::default();
        alias_metrics.search_requests_total.insert(flapjack_uid, 10);
        let first_records =
            build_counter_usage_records(&cfg, &alias_metrics, &state, &tenant_map, Utc::now());
        assert_eq!(
            first_records.len(),
            0,
            "first scrape should establish the baseline only"
        );

        let mut canonical_metrics = crate::scraper::FlapjackMetrics::default();
        canonical_metrics
            .search_requests_total
            .insert("products".to_string(), 12);
        let second_records =
            build_counter_usage_records(&cfg, &canonical_metrics, &state, &tenant_map, Utc::now());

        let search_records: Vec<_> = second_records
            .iter()
            .filter(|record| record.event_type == record::EventType::SearchRequests)
            .collect();
        assert_eq!(search_records.len(), 1);
        assert_eq!(search_records[0].tenant_id, "products");
        assert_eq!(search_records[0].value, 2);
    }

    /// Guards the cold-tier exclusion from live counter metrics.
    ///
    /// Indexes in the `cold` or `restoring` tier must not appear in counter
    /// usage records.  Their search/write activity is not meaningful (they
    /// are offline) and their storage is billed separately through the cold-
    /// storage path.  Only the `active` index should appear in the output.
    #[test]
    fn metering_skips_cold_and_restoring_indexes_for_live_metrics() {
        let cfg = test_config();
        let state: TenantStateMap = Arc::new(DashMap::new());
        let tenant_map: TenantCustomerMap = Arc::new(DashMap::new());
        let customer_id = Uuid::new_v4();

        tenant_map.insert(
            "active".to_string(),
            TenantAttribution {
                customer_id,
                tenant_id: "active".to_string(),
                tier: "active".to_string(),
            },
        );
        tenant_map.insert(
            "cold".to_string(),
            TenantAttribution {
                customer_id,
                tenant_id: "cold".to_string(),
                tier: "cold".to_string(),
            },
        );
        tenant_map.insert(
            "restoring".to_string(),
            TenantAttribution {
                customer_id,
                tenant_id: "restoring".to_string(),
                tier: "restoring".to_string(),
            },
        );

        state.insert("active".to_string(), CounterState::default());
        state.insert("cold".to_string(), CounterState::default());
        state.insert("restoring".to_string(), CounterState::default());

        let mut metrics = crate::scraper::FlapjackMetrics::default();
        metrics
            .search_requests_total
            .insert("active".to_string(), 5);
        metrics.search_requests_total.insert("cold".to_string(), 5);
        metrics
            .search_requests_total
            .insert("restoring".to_string(), 5);

        let records = build_counter_usage_records(&cfg, &metrics, &state, &tenant_map, Utc::now());

        assert!(records.iter().all(|record| record.tenant_id == "active"));
    }

    /// Guards graceful handling of a partial Prometheus scrape payload — one
    /// where only `search_requests_total` is present for an index, with no
    /// write/indexed/deleted counters.
    ///
    /// On the first scrape with a new counter value the delta is zero (no
    /// prior baseline), so no record is emitted.  On the second scrape, a
    /// delta of 50 is computed and emitted as a `SearchRequests` record.
    /// Write operations must remain absent from the output because the metric
    /// was never reported by flapjack.
    #[test]
    fn metering_handles_partial_metrics_gracefully() {
        let (cfg, state, tenant_map) = setup_active_counter_test("partial-idx");

        let mut metrics = crate::scraper::FlapjackMetrics::default();
        metrics
            .search_requests_total
            .insert("partial-idx".to_string(), 100);

        let records = build_counter_usage_records(&cfg, &metrics, &state, &tenant_map, Utc::now());
        let search_records: Vec<_> = records
            .iter()
            .filter(|r| r.event_type == record::EventType::SearchRequests)
            .collect();
        assert_eq!(search_records.len(), 0);

        let mut metrics2 = crate::scraper::FlapjackMetrics::default();
        metrics2
            .search_requests_total
            .insert("partial-idx".to_string(), 150);
        let records2 =
            build_counter_usage_records(&cfg, &metrics2, &state, &tenant_map, Utc::now());

        let search_records2: Vec<_> = records2
            .iter()
            .filter(|r| r.event_type == record::EventType::SearchRequests)
            .collect();
        assert_eq!(search_records2.len(), 1);
        assert_eq!(search_records2[0].value, 50);

        let write_records: Vec<_> = records2
            .iter()
            .filter(|r| r.event_type == record::EventType::WriteOperations)
            .collect();
        assert_eq!(write_records.len(), 0);
    }

    /// Guards delta computation when a counter type appears for the first time
    /// mid-stream — i.e. the first scrape has no `write_operations_total` but
    /// the second does.
    ///
    /// First scrape: only `search_requests_total=50` → no records emitted
    /// (baseline set, no prior value).
    ///
    /// Second scrape: `search_requests_total=75`, `write_operations_total=30`
    /// → search delta of 25 and write delta of 30 (first observation acts as
    /// a baseline, not counted as activity).
    #[test]
    fn metering_delta_computation_with_missing_counters() {
        let (cfg, state, tenant_map) = setup_active_counter_test("test-idx");

        let mut metrics = crate::scraper::FlapjackMetrics::default();
        metrics
            .search_requests_total
            .insert("test-idx".to_string(), 50);
        let records1 = build_counter_usage_records(&cfg, &metrics, &state, &tenant_map, Utc::now());
        assert_eq!(records1.len(), 0);

        let mut metrics2 = crate::scraper::FlapjackMetrics::default();
        metrics2
            .search_requests_total
            .insert("test-idx".to_string(), 75);
        metrics2
            .write_operations_total
            .insert("test-idx".to_string(), 30);

        let records2 =
            build_counter_usage_records(&cfg, &metrics2, &state, &tenant_map, Utc::now());

        let search_delta: i64 = records2
            .iter()
            .filter(|r| r.event_type == record::EventType::SearchRequests)
            .map(|r| r.value)
            .sum();
        let write_delta: i64 = records2
            .iter()
            .filter(|r| r.event_type == record::EventType::WriteOperations)
            .map(|r| r.value)
            .sum();

        assert_eq!(search_delta, 25);
        assert_eq!(write_delta, 30);
    }
}
