use rust_decimal::Decimal;
use uuid::Uuid;

use crate::models::cold_snapshot::ColdSnapshot;
use crate::models::storage::StorageBucket;

use super::{ObjectStorageEgressWatermarkTarget, SharedBillingData, StorageInputs};

/// Compute cold storage GB-months for a single customer from a set of cold snapshots.
/// Only completed snapshots for the given customer are counted.
pub(crate) fn compute_cold_storage_gb_months(
    snapshots: &[ColdSnapshot],
    customer_id: Uuid,
) -> Decimal {
    let total_bytes: i64 = snapshots
        .iter()
        .filter(|s| s.customer_id == customer_id && s.status == "completed")
        .map(|s| s.size_bytes)
        .sum();
    Decimal::from(total_bytes) / Decimal::from(billing::types::BYTES_PER_GIB)
}

pub(crate) fn active_customer_buckets(
    buckets: &[StorageBucket],
    customer_id: Uuid,
) -> impl Iterator<Item = &StorageBucket> {
    buckets
        .iter()
        .filter(move |b| b.customer_id == customer_id && b.status == "active")
}

/// Compute object storage GB-months for a single customer from active storage buckets.
pub(crate) fn compute_object_storage_gb_months(
    buckets: &[StorageBucket],
    customer_id: Uuid,
) -> Decimal {
    let total_bytes: i64 = active_customer_buckets(buckets, customer_id)
        .map(|b| b.size_bytes)
        .sum();
    Decimal::from(total_bytes) / Decimal::from(billing::types::BYTES_PER_GIB)
}

/// Compute unbilled object storage egress GB for a single customer.
/// Only counts bytes above the watermark to prevent double-billing.
pub(crate) fn compute_object_storage_egress_gb(
    buckets: &[StorageBucket],
    customer_id: Uuid,
) -> Decimal {
    let total_unbilled_bytes: i64 = active_customer_buckets(buckets, customer_id)
        .map(|b| (b.egress_bytes - b.egress_watermark_bytes).max(0))
        .sum();
    Decimal::from(total_unbilled_bytes) / Decimal::from(billing::types::BYTES_PER_GIB)
}

pub(crate) fn compute_object_storage_egress_watermark_targets(
    buckets: &[StorageBucket],
    customer_id: Uuid,
) -> Vec<ObjectStorageEgressWatermarkTarget> {
    active_customer_buckets(buckets, customer_id)
        .filter(|b| b.egress_bytes > b.egress_watermark_bytes)
        .map(|b| ObjectStorageEgressWatermarkTarget {
            bucket_id: b.id,
            egress_bytes: b.egress_bytes,
        })
        .collect()
}

/// Build storage inputs for a customer from shared billing data.
pub(crate) fn storage_inputs_for_customer(
    shared: &SharedBillingData<'_>,
    customer_id: Uuid,
    object_storage_egress_carryforward_cents: Decimal,
) -> StorageInputs {
    StorageInputs {
        cold_storage_gb_months: compute_cold_storage_gb_months(shared.cold_snapshots, customer_id),
        object_storage_gb_months: compute_object_storage_gb_months(
            shared.storage_buckets,
            customer_id,
        ),
        object_storage_egress_gb: compute_object_storage_egress_gb(
            shared.storage_buckets,
            customer_id,
        ),
        object_storage_egress_carryforward_cents,
        object_storage_egress_watermark_targets: compute_object_storage_egress_watermark_targets(
            shared.storage_buckets,
            customer_id,
        ),
    }
}
