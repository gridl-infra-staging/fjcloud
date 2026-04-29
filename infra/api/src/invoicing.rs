use chrono::NaiveDate;
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;

use crate::errors::ApiError;
use crate::models::cold_snapshot::ColdSnapshot;
use crate::models::customer::BillingPlan;
use crate::models::storage::StorageBucket;
use crate::models::UsageDaily;
use crate::repos::invoice_repo::NewLineItem;
use crate::repos::{ColdSnapshotRepo, RateCardRepo, StorageBucketRepo, UsageRepo};

mod cold_storage;
mod line_items;
pub(crate) mod stripe_sync;
#[cfg(test)]
mod tests;

/// Bundles cold-snapshot and object-storage inputs for invoice generation.
#[derive(Default)]
pub struct StorageInputs {
    pub cold_storage_gb_months: Decimal,
    pub object_storage_gb_months: Decimal,
    pub object_storage_egress_gb: Decimal,
    pub object_storage_egress_carryforward_cents: Decimal,
    pub object_storage_egress_watermark_targets: Vec<ObjectStorageEgressWatermarkTarget>,
}

impl StorageInputs {
    pub fn cold_only(cold_storage_gb_months: Decimal) -> Self {
        Self {
            cold_storage_gb_months,
            ..Self::default()
        }
    }

    pub fn has_non_zero_storage(&self) -> bool {
        self.cold_storage_gb_months > Decimal::ZERO
            || self.object_storage_gb_months > Decimal::ZERO
            || self.object_storage_egress_gb > Decimal::ZERO
            || self.object_storage_egress_carryforward_cents > Decimal::ZERO
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ObjectStorageEgressWatermarkTarget {
    pub bucket_id: Uuid,
    pub egress_bytes: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ObjectStorageEgressMetadata {
    pub watermark_targets: Vec<ObjectStorageEgressWatermarkTarget>,
    #[serde(default)]
    pub next_cycle_carryforward_cents: Decimal,
}

/// Compute cold storage GB-months for a single customer from a set of cold snapshots.
/// Only completed snapshots for the given customer are counted.
pub fn compute_cold_storage_gb_months(snapshots: &[ColdSnapshot], customer_id: Uuid) -> Decimal {
    cold_storage::compute_cold_storage_gb_months(snapshots, customer_id)
}

/// Compute object storage GB-months for a single customer from active storage buckets.
pub fn compute_object_storage_gb_months(buckets: &[StorageBucket], customer_id: Uuid) -> Decimal {
    cold_storage::compute_object_storage_gb_months(buckets, customer_id)
}

/// Compute unbilled object storage egress GB for a single customer.
/// Only counts bytes above the watermark to prevent double-billing.
pub fn compute_object_storage_egress_gb(buckets: &[StorageBucket], customer_id: Uuid) -> Decimal {
    cold_storage::compute_object_storage_egress_gb(buckets, customer_id)
}

pub fn compute_object_storage_egress_watermark_targets(
    buckets: &[StorageBucket],
    customer_id: Uuid,
) -> Vec<ObjectStorageEgressWatermarkTarget> {
    cold_storage::compute_object_storage_egress_watermark_targets(buckets, customer_id)
}

pub struct GeneratedInvoice {
    pub customer_id: Uuid,
    pub period_start: NaiveDate,
    pub period_end: NaiveDate,
    pub subtotal_cents: i64,
    pub total_cents: i64,
    pub minimum_applied: bool,
    pub line_items: Vec<NewLineItem>,
}

/// Bundles the repository dependencies for invoice computation.
pub struct BillingRepos<'a> {
    pub rate_card_repo: &'a (dyn RateCardRepo + Send + Sync),
    pub usage_repo: &'a (dyn UsageRepo + Send + Sync),
    pub cold_snapshot_repo: &'a (dyn ColdSnapshotRepo + Send + Sync),
    pub storage_bucket_repo: &'a (dyn StorageBucketRepo + Send + Sync),
}

impl<'a> BillingRepos<'a> {
    pub fn from_state(state: &'a crate::state::AppState) -> Self {
        Self {
            rate_card_repo: state.rate_card_repo.as_ref(),
            usage_repo: state.usage_repo.as_ref(),
            cold_snapshot_repo: state.cold_snapshot_repo.as_ref(),
            storage_bucket_repo: state.storage_bucket_repo.as_ref(),
        }
    }
}

/// Pre-fetched shared data used across batch billing to avoid redundant queries.
pub struct SharedBillingData<'a> {
    pub base_card: &'a crate::models::RateCardRow,
    pub cold_snapshots: &'a [ColdSnapshot],
    pub storage_buckets: &'a [StorageBucket],
}

pub fn generate_invoice(
    usage_rows: &[UsageDaily],
    rate_card: &billing::rate_card::RateCard,
    customer_id: Uuid,
    period_start: NaiveDate,
    period_end: NaiveDate,
    storage: &StorageInputs,
    billing_plan: BillingPlan,
) -> GeneratedInvoice {
    let mut records: Vec<billing::types::DailyUsageRecord> =
        usage_rows.iter().map(|r| r.into()).collect();

    // Storage-only customers must still be billed even when there are no hot-usage rows.
    // Inject a synthetic zero-usage record so the billing pipeline emits a summary.
    if records.is_empty() && storage.has_non_zero_storage() {
        records.push(line_items::synthetic_storage_only_record(
            customer_id,
            period_start,
        ));
    }

    let mut billing_ctx: HashMap<Uuid, billing::aggregation::CustomerBillingContext> =
        HashMap::new();
    billing_ctx.insert(
        customer_id,
        billing::aggregation::CustomerBillingContext {
            cold_storage_gb_months: storage.cold_storage_gb_months,
            object_storage_gb_months: storage.object_storage_gb_months,
            object_storage_egress_gb: storage.object_storage_egress_gb,
        },
    );
    let summaries =
        billing::aggregation::summarize(&records, period_start, period_end, &billing_ctx);

    let mut all_line_items = Vec::new();
    let mut subtotal_cents: i64 = 0;
    let mut next_cycle_egress_carryforward_cents = storage.object_storage_egress_carryforward_cents;

    for summary in &summaries {
        let calc = billing::pricing::calculate_invoice(summary, rate_card);
        for line_item in calc.line_items {
            let line_item = line_items::new_invoice_line_item(
                line_item,
                storage,
                &mut next_cycle_egress_carryforward_cents,
            );
            subtotal_cents += line_item.amount_cents;
            all_line_items.push(line_item);
        }
    }

    // Carry-forward-only month: the billing crate emitted no egress line item (zero
    // quantity), but a fractional remainder must still be snapshotted onto the draft so
    // finalization can persist it to the customer row.
    line_items::append_carryforward_snapshot_if_needed(
        &mut all_line_items,
        storage,
        next_cycle_egress_carryforward_cents,
    );

    // Apply the correct minimum spend based on billing plan.
    // Free plans use the standard minimum; Shared plans use the lower shared minimum.
    let (total_cents, minimum_applied) =
        line_items::invoice_total_with_minimum(subtotal_cents, billing_plan, rate_card);

    GeneratedInvoice {
        customer_id,
        period_start,
        period_end,
        subtotal_cents,
        total_cents,
        minimum_applied,
        line_items: all_line_items,
    }
}

/// Compute an invoice for a single customer, fetching all required data from repos.
pub async fn compute_invoice_for_customer(
    repos: &BillingRepos<'_>,
    customer_id: Uuid,
    period_start: NaiveDate,
    period_end: NaiveDate,
    billing_plan: BillingPlan,
    object_storage_egress_carryforward_cents: Decimal,
) -> Result<GeneratedInvoice, ApiError> {
    let base_card = repos
        .rate_card_repo
        .get_active()
        .await?
        .ok_or_else(|| ApiError::NotFound("no active rate card".into()))?;
    let cold_snapshots = repos
        .cold_snapshot_repo
        .list_completed_for_billing(period_start, period_end)
        .await?;
    let storage_buckets = repos.storage_bucket_repo.list_all().await?;

    let shared = SharedBillingData {
        base_card: &base_card,
        cold_snapshots: &cold_snapshots,
        storage_buckets: &storage_buckets,
    };
    compute_invoice_for_customer_with_shared_inputs(
        repos,
        &shared,
        customer_id,
        period_start,
        period_end,
        billing_plan,
        object_storage_egress_carryforward_cents,
    )
    .await
}

/// Compute an invoice using an explicitly selected base rate card id.
///
/// This path is used by replay and audit workflows that must reproduce invoice
/// amounts against a captured historical card rather than whichever card is
/// currently active at execution time.
pub async fn compute_invoice_for_customer_with_rate_card_id(
    repos: &BillingRepos<'_>,
    customer_id: Uuid,
    rate_card_id: Uuid,
    period_start: NaiveDate,
    period_end: NaiveDate,
    billing_plan: BillingPlan,
    object_storage_egress_carryforward_cents: Decimal,
) -> Result<GeneratedInvoice, ApiError> {
    let base_card = repos
        .rate_card_repo
        .get_by_id(rate_card_id)
        .await?
        .ok_or_else(|| ApiError::NotFound(format!("rate card not found: {}", rate_card_id)))?;
    let cold_snapshots = repos
        .cold_snapshot_repo
        .list_completed_for_billing(period_start, period_end)
        .await?;
    let storage_buckets = repos.storage_bucket_repo.list_all().await?;

    let shared = SharedBillingData {
        base_card: &base_card,
        cold_snapshots: &cold_snapshots,
        storage_buckets: &storage_buckets,
    };
    compute_invoice_for_customer_with_shared_inputs(
        repos,
        &shared,
        customer_id,
        period_start,
        period_end,
        billing_plan,
        object_storage_egress_carryforward_cents,
    )
    .await
}

pub async fn compute_invoice_for_customer_with_shared_inputs(
    repos: &BillingRepos<'_>,
    shared: &SharedBillingData<'_>,
    customer_id: Uuid,
    period_start: NaiveDate,
    period_end: NaiveDate,
    billing_plan: BillingPlan,
    object_storage_egress_carryforward_cents: Decimal,
) -> Result<GeneratedInvoice, ApiError> {
    let effective_card = match repos
        .rate_card_repo
        .get_override(customer_id, shared.base_card.id)
        .await?
    {
        Some(ov) => shared.base_card.with_overrides(&ov.overrides)?,
        None => shared.base_card.clone(),
    };
    let billing_card = effective_card.to_billing_rate_card()?;

    let usage_rows = repos
        .usage_repo
        .get_daily_usage(customer_id, period_start, period_end)
        .await?;

    let storage = cold_storage::storage_inputs_for_customer(
        shared,
        customer_id,
        object_storage_egress_carryforward_cents,
    );

    Ok(generate_invoice(
        &usage_rows,
        &billing_card,
        customer_id,
        period_start,
        period_end,
        &storage,
        billing_plan,
    ))
}
