use dashmap::DashMap;
use std::collections::HashMap;
use std::sync::Arc;

use crate::config::Config;
use crate::delta::CounterState;
use crate::record;
use crate::tenant_map::{
    is_cold_tier, resolve_tenant_attribution, TenantAttribution, TenantCustomerMap,
};

pub type TenantStateMap = Arc<DashMap<String, CounterState>>;

pub(super) struct CounterTotals<'a> {
    pub search_totals: &'a HashMap<String, u64>,
    pub write_totals: &'a HashMap<String, u64>,
    pub indexed_totals: &'a HashMap<String, u64>,
    pub deleted_totals: &'a HashMap<String, u64>,
}

pub(super) struct CounterObservation {
    pub tenant: TenantAttribution,
    pub search_total: u64,
    pub write_total: Option<u64>,
    pub indexed_total: Option<u64>,
    pub deleted_total: Option<u64>,
}

pub(super) struct PendingCounterRecord {
    pub usage_record: Option<record::UsageRecord>,
    pub tenant_id: String,
    pub event_type: record::EventType,
    pub current_total: u64,
}

pub(super) fn build_pending_counter_records(
    cfg: &Config,
    totals: &CounterTotals<'_>,
    state: &TenantStateMap,
    tenant_map: &TenantCustomerMap,
    now: chrono::DateTime<chrono::Utc>,
) -> Vec<PendingCounterRecord> {
    let ctx = record::RecordContext {
        node_id: &cfg.node_id,
        region: &cfg.region,
        now,
    };
    let mut pending_records = Vec::new();

    for observation in counter_observations(cfg, totals, state, tenant_map) {
        let mut previous = state
            .get(&observation.tenant.tenant_id)
            .expect("counter observation should seed tenant state")
            .clone();
        let deltas = previous.advance(
            observation.search_total,
            observation.write_total.unwrap_or(0),
            observation.indexed_total.unwrap_or(0),
            observation.deleted_total.unwrap_or(0),
        );
        for (event_type, current_total, delta) in [
            (
                record::EventType::SearchRequests,
                Some(observation.search_total),
                deltas.search_requests,
            ),
            (
                record::EventType::WriteOperations,
                observation.write_total,
                deltas.write_operations,
            ),
            (
                record::EventType::DocumentsIndexed,
                observation.indexed_total,
                deltas.documents_indexed,
            ),
            (
                record::EventType::DocumentsDeleted,
                observation.deleted_total,
                deltas.documents_deleted,
            ),
        ] {
            let Some(current_total) = current_total else {
                continue;
            };
            pending_records.push(PendingCounterRecord {
                usage_record: (delta != 0).then(|| {
                    record::build_usage_record(
                        &ctx,
                        observation.tenant.customer_id,
                        &observation.tenant.tenant_id,
                        event_type.clone(),
                        delta as i64,
                    )
                }),
                tenant_id: observation.tenant.tenant_id.clone(),
                event_type,
                current_total,
            });
        }
    }

    pending_records
}

pub(super) fn counter_observations(
    cfg: &Config,
    totals: &CounterTotals<'_>,
    state: &TenantStateMap,
    tenant_map: &TenantCustomerMap,
) -> Vec<CounterObservation> {
    let mut observations = Vec::new();

    for (observed_tenant_id, &search_total) in totals.search_totals {
        let tenant = match resolve_tenant_attribution(tenant_map, observed_tenant_id) {
            Some(tenant) => tenant,
            None => {
                tracing::warn!(
                    tenant_id = observed_tenant_id.as_str(),
                    "tenant map missing index during metrics scrape; skipping usage attribution"
                );
                continue;
            }
        };
        if is_cold_tier(&tenant.tier) {
            continue;
        }

        let observation = CounterObservation {
            tenant,
            search_total,
            write_total: totals.write_totals.get(observed_tenant_id).copied(),
            indexed_total: totals.indexed_totals.get(observed_tenant_id).copied(),
            deleted_total: totals.deleted_totals.get(observed_tenant_id).copied(),
        };
        state
            .entry(observation.tenant.tenant_id.clone())
            .or_insert_with(|| initial_counter_state(cfg, &observation));
        observations.push(observation);
    }

    observations
}

fn initial_counter_state(cfg: &Config, observation: &CounterObservation) -> CounterState {
    if observation.tenant.created_at > cfg.started_at {
        CounterState::seeded_zero()
    } else {
        CounterState {
            search_requests: Some(observation.search_total),
            write_operations: observation.write_total,
            documents_indexed: observation.indexed_total,
            documents_deleted: observation.deleted_total,
        }
    }
}

pub(super) fn commit_counter_total(
    state: &TenantStateMap,
    tenant_id: &str,
    event_type: &record::EventType,
    current_total: u64,
) {
    let mut entry = state
        .get_mut(tenant_id)
        .expect("pending counter record should have seeded tenant state");
    match event_type {
        record::EventType::SearchRequests => entry.search_requests = Some(current_total),
        record::EventType::WriteOperations => entry.write_operations = Some(current_total),
        record::EventType::DocumentsIndexed => entry.documents_indexed = Some(current_total),
        record::EventType::DocumentsDeleted => entry.documents_deleted = Some(current_total),
        record::EventType::StorageBytes | record::EventType::DocumentCount => {
            unreachable!("gauge event cannot be a pending counter record")
        }
    }
}
