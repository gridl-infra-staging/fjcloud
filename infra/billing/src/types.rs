//! Shared billing types: usage summaries, byte constants, and billing plan definitions.
use chrono::NaiveDate;
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Raw daily usage for one customer in one region.
/// Written by the aggregation job that processes metering-agent records.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DailyUsageRecord {
    pub customer_id: Uuid,
    pub date: NaiveDate,
    pub region: String,
    pub search_requests: i64,
    pub write_operations: i64,
    /// Time-weighted average bytes stored during this calendar day.
    pub storage_bytes_avg: i64,
    pub documents_count_avg: i64,
}

/// Aggregated usage for one customer in one region over a billing period.
///
/// Produced by `aggregation::summarize` from a slice of `DailyUsageRecord`s.
/// Each field represents one billable dimension for the period:
/// - `storage_mb_months`: time-weighted average hot (Flapjack index) storage in MB-months.
/// - `cold_storage_gb_months`: cold snapshot storage in GB-months (per-customer, assigned to one
///   canonical region to avoid double-billing when the customer spans multiple regions).
/// - `object_storage_gb_months`: Garage S3-compatible object storage in GB-months (same
///   anti-duplication rule applies).
/// - `object_storage_egress_gb`: cumulative egress GB since the last billing watermark.
///
/// Search requests and write operations are tracked for quota enforcement but are NOT billable
/// under the flat storage pricing model.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MonthlyUsageSummary {
    pub customer_id: Uuid,
    pub period_start: NaiveDate,
    pub period_end: NaiveDate,
    pub region: String,
    pub total_search_requests: i64,
    pub total_write_operations: i64,
    /// MB-months: time-weighted average hot storage over the billing period.
    /// Computed as: sum(daily_storage_bytes) / BYTES_PER_MB / days_in_period.
    pub storage_mb_months: Decimal,
    /// GB-months of cold (object-storage) snapshot storage.
    pub cold_storage_gb_months: Decimal,
    /// GB-months of object (Garage) storage.
    pub object_storage_gb_months: Decimal,
    /// GB of object (Garage) storage egress since last watermark.
    pub object_storage_egress_gb: Decimal,
}

/// Binary GiB for cold/object storage calculations.
pub const BYTES_PER_GIB: i64 = 1_073_741_824;
/// Decimal MB for hot storage pricing (5¢/MB/month).
pub const BYTES_PER_MB: i64 = 1_000_000;
