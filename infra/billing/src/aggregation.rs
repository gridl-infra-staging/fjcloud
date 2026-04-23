//! Usage aggregation: converts raw metering records into billing-period summaries.
use crate::types::{DailyUsageRecord, MonthlyUsageSummary, BYTES_PER_MB};
use chrono::NaiveDate;
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use std::collections::HashMap;
use uuid::Uuid;

/// Aggregate daily usage records into per-(customer, region) monthly summaries.
///
/// Only records with a date in [`period_start`, `period_end`] (inclusive) are
/// included. Records outside the window are silently ignored so callers can
/// pass a raw slice without pre-filtering.
/// Per-customer context passed into summarize for cold storage.
#[derive(Debug, Clone)]
pub struct CustomerBillingContext {
    pub cold_storage_gb_months: Decimal,
    pub object_storage_gb_months: Decimal,
    pub object_storage_egress_gb: Decimal,
}

/// Convert a slice of `DailyUsageRecord`s into per-(customer, region) `MonthlyUsageSummary`s.
///
/// Aggregation rules:
/// - Only records whose `date` falls in `[period_start, period_end]` (inclusive) are processed;
///   records outside the window are silently dropped so callers need not pre-filter.
/// - Records are grouped by `(customer_id, region)` — each group produces one summary.
/// - `total_search_requests` and `total_write_operations` are simple sums across the group.
/// - `storage_mb_months` is a time-weighted average: `sum(daily_storage_bytes) / BYTES_PER_MB /
///   days_in_period`, yielding the mean MB stored per day (= MB-months for a one-month period).
/// - Cold storage (`cold_storage_gb_months`), object storage (`object_storage_gb_months`), and
///   egress (`object_storage_egress_gb`) are per-customer quantities supplied via `billing_ctx`.
///   To prevent double-billing when a customer has records in multiple regions, these values are
///   attached to exactly one region per customer — the lexicographically smallest region key seen
///   in the grouped records. All other regions for that customer get zero for these dimensions.
pub fn summarize(
    records: &[DailyUsageRecord],
    period_start: NaiveDate,
    period_end: NaiveDate,
    billing_ctx: &HashMap<Uuid, CustomerBillingContext>,
) -> Vec<MonthlyUsageSummary> {
    // Group records by (customer_id, region).
    let mut groups: HashMap<(Uuid, String), Vec<&DailyUsageRecord>> = HashMap::new();
    for record in records {
        if record.date >= period_start && record.date <= period_end {
            groups
                .entry((record.customer_id, record.region.clone()))
                .or_default()
                .push(record);
        }
    }

    // Cold and object storage are per-customer quantities (not per-region). Attach
    // each once to a deterministic region key to avoid double-billing on multi-region usage.
    let mut ctx_region_by_customer: HashMap<Uuid, String> = HashMap::new();
    for (customer_id, region) in groups.keys() {
        ctx_region_by_customer
            .entry(*customer_id)
            .and_modify(|current| {
                if region < current {
                    *current = region.clone();
                }
            })
            .or_insert_with(|| region.clone());
    }

    let days_in_period = Decimal::from((period_end - period_start).num_days() + 1);

    groups
        .into_iter()
        .map(|((customer_id, region), daily)| {
            let total_search_requests: i64 = daily.iter().map(|r| r.search_requests).sum();
            let total_write_operations: i64 = daily.iter().map(|r| r.write_operations).sum();

            // Time-weighted average storage: sum(daily_bytes) / BYTES_PER_MB / days_in_period.
            // This gives "average MB stored per day" = MB-months for one billing cycle.
            let total_storage_bytes: i64 = daily.iter().map(|r| r.storage_bytes_avg).sum();
            let storage_mb_months =
                Decimal::from(total_storage_bytes) / Decimal::from(BYTES_PER_MB) / days_in_period;

            let ctx = billing_ctx.get(&customer_id);

            let is_ctx_region = ctx_region_by_customer
                .get(&customer_id)
                .is_some_and(|ctx_region| ctx_region == &region);

            // Extract a per-customer field only for the designated billing-context region.
            let ctx_field = |f: fn(&CustomerBillingContext) -> Decimal| -> Decimal {
                if is_ctx_region {
                    ctx.map(f).unwrap_or(dec!(0))
                } else {
                    dec!(0)
                }
            };

            let cold_storage_gb_months = ctx_field(|c| c.cold_storage_gb_months);
            let object_storage_gb_months = ctx_field(|c| c.object_storage_gb_months);
            let object_storage_egress_gb = ctx_field(|c| c.object_storage_egress_gb);

            MonthlyUsageSummary {
                customer_id,
                period_start,
                period_end,
                region,
                total_search_requests,
                total_write_operations,
                storage_mb_months,
                cold_storage_gb_months,
                object_storage_gb_months,
                object_storage_egress_gb,
            }
        })
        .collect()
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;
    use rust_decimal_macros::dec;
    use uuid::Uuid;

    fn feb() -> (NaiveDate, NaiveDate) {
        (
            NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
            NaiveDate::from_ymd_opt(2026, 2, 28).unwrap(), // 28 days
        )
    }

    fn day(d: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 2, d).unwrap()
    }

    /// Test helper: constructs a `DailyUsageRecord` in the `"us-east-1"` region with the given
    /// customer, date, search count, write count, and raw storage bytes. `documents_count_avg` is
    /// always zero — tests that need document counts should mutate the returned record.
    fn make_record(
        customer_id: Uuid,
        date: NaiveDate,
        searches: i64,
        writes: i64,
        bytes: i64,
    ) -> DailyUsageRecord {
        DailyUsageRecord {
            customer_id,
            date,
            region: "us-east-1".to_string(),
            search_requests: searches,
            write_operations: writes,
            storage_bytes_avg: bytes,
            documents_count_avg: 0,
        }
    }

    fn no_ctx() -> HashMap<Uuid, CustomerBillingContext> {
        HashMap::new()
    }

    // -------------------------------------------------------------------------
    // Basic aggregation
    // -------------------------------------------------------------------------

    #[test]
    fn sums_search_requests_across_days() {
        let cid = Uuid::new_v4();
        let records = vec![
            make_record(cid, day(1), 1_000, 0, 0),
            make_record(cid, day(2), 2_000, 0, 0),
            make_record(cid, day(3), 3_000, 0, 0),
        ];

        let (start, end) = feb();
        let summaries = summarize(&records, start, end, &no_ctx());

        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0].total_search_requests, 6_000);
    }

    #[test]
    fn sums_write_operations_across_days() {
        let cid = Uuid::new_v4();
        let records = vec![
            make_record(cid, day(1), 0, 500, 0),
            make_record(cid, day(2), 0, 300, 0),
        ];

        let (start, end) = feb();
        let summaries = summarize(&records, start, end, &no_ctx());

        assert_eq!(summaries[0].total_write_operations, 800);
    }

    // -------------------------------------------------------------------------
    // Storage: time-weighted average
    // -------------------------------------------------------------------------

    #[test]
    fn constant_1mb_storage_for_full_period_is_1_mb_month() {
        use crate::types::BYTES_PER_MB;
        let cid = Uuid::new_v4();
        let one_mb = BYTES_PER_MB;
        let records: Vec<_> = (1..=28)
            .map(|d| make_record(cid, day(d), 0, 0, one_mb))
            .collect();

        let (start, end) = feb();
        let summaries = summarize(&records, start, end, &no_ctx());

        assert_eq!(summaries[0].storage_mb_months, dec!(1));
    }

    #[test]
    fn storage_grows_over_period_gives_correct_average_mb() {
        use crate::types::BYTES_PER_MB;
        let cid = Uuid::new_v4();
        let two_mb = BYTES_PER_MB * 2;
        let mut records: Vec<_> = (1..=14)
            .map(|d| make_record(cid, day(d), 0, 0, 0))
            .collect();
        records.extend((15..=28).map(|d| make_record(cid, day(d), 0, 0, two_mb)));

        let (start, end) = feb();
        let summaries = summarize(&records, start, end, &no_ctx());

        // 14 days at 0 + 14 days at 2 MB = 28 MB total / 28 days = 1 MB-month
        assert_eq!(summaries[0].storage_mb_months, dec!(1));
    }

    #[test]
    fn zero_storage_gives_zero_mb_months() {
        let cid = Uuid::new_v4();
        let records = vec![make_record(cid, day(1), 100, 0, 0)];

        let (start, end) = feb();
        let summaries = summarize(&records, start, end, &no_ctx());

        assert_eq!(summaries[0].storage_mb_months, dec!(0));
    }

    // -------------------------------------------------------------------------
    // Multi-customer and multi-region grouping
    // -------------------------------------------------------------------------

    /// Records from different customers must never be merged — each customer gets its own summary
    /// with only its own usage, even if both records share the same date and region.
    #[test]
    fn separates_different_customers() {
        let cid_a = Uuid::new_v4();
        let cid_b = Uuid::new_v4();
        let records = vec![
            make_record(cid_a, day(1), 1_000, 0, 0),
            make_record(cid_b, day(1), 2_000, 0, 0),
        ];

        let (start, end) = feb();
        let summaries = summarize(&records, start, end, &no_ctx());

        assert_eq!(summaries.len(), 2);
        let a = summaries.iter().find(|s| s.customer_id == cid_a).unwrap();
        let b = summaries.iter().find(|s| s.customer_id == cid_b).unwrap();
        assert_eq!(a.total_search_requests, 1_000);
        assert_eq!(b.total_search_requests, 2_000);
    }

    #[test]
    fn separates_different_regions_for_same_customer() {
        let cid = Uuid::new_v4();
        let mut r_eu = make_record(cid, day(1), 500, 0, 0);
        r_eu.region = "eu-west-1".to_string();
        let r_us = make_record(cid, day(1), 1_000, 0, 0); // region = "us-east-1"

        let (start, end) = feb();
        let summaries = summarize(&[r_us, r_eu], start, end, &no_ctx());

        assert_eq!(summaries.len(), 2);
        let us = summaries.iter().find(|s| s.region == "us-east-1").unwrap();
        let eu = summaries.iter().find(|s| s.region == "eu-west-1").unwrap();
        assert_eq!(us.total_search_requests, 1_000);
        assert_eq!(eu.total_search_requests, 500);
    }

    // -------------------------------------------------------------------------
    // Period filtering
    // -------------------------------------------------------------------------

    /// Records dated before `period_start` or after `period_end` must be silently discarded.
    /// The boundary is inclusive: only the one in-period record (Feb 15) should appear in the
    /// summary; the Jan 31 and Mar 1 records must not inflate any dimension.
    #[test]
    fn records_outside_period_are_ignored() {
        let cid = Uuid::new_v4();
        let in_period = make_record(cid, day(15), 1_000, 0, 0);
        let before = make_record(
            cid,
            NaiveDate::from_ymd_opt(2026, 1, 31).unwrap(),
            9_999,
            0,
            0,
        );
        let after = make_record(
            cid,
            NaiveDate::from_ymd_opt(2026, 3, 1).unwrap(),
            9_999,
            0,
            0,
        );

        let (start, end) = feb();
        let summaries = summarize(&[in_period, before, after], start, end, &no_ctx());

        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0].total_search_requests, 1_000);
    }

    #[test]
    fn empty_record_slice_returns_empty_summaries() {
        let (start, end) = feb();
        let summaries = summarize(&[], start, end, &no_ctx());
        assert!(summaries.is_empty());
    }

    // -------------------------------------------------------------------------
    // Cold storage
    // -------------------------------------------------------------------------

    fn ctx_cold_only(cold: Decimal) -> CustomerBillingContext {
        CustomerBillingContext {
            cold_storage_gb_months: cold,
            object_storage_gb_months: dec!(0),
            object_storage_egress_gb: dec!(0),
        }
    }

    #[test]
    fn cold_storage_gb_months_passed_through() {
        let cid = Uuid::new_v4();
        let records = vec![make_record(cid, day(1), 100, 0, 0)];

        let mut ctx = HashMap::new();
        ctx.insert(cid, ctx_cold_only(dec!(5.5)));

        let (start, end) = feb();
        let summaries = summarize(&records, start, end, &ctx);

        assert_eq!(summaries[0].cold_storage_gb_months, dec!(5.5));
    }

    /// Cold storage is a per-customer quantity (one pool, not per-region). When a customer has
    /// activity in multiple regions the cold GB-months must be assigned to exactly one region so
    /// that the invoice total equals the original value — not a multiple of it. This test asserts
    /// that summing `cold_storage_gb_months` across all summaries for the customer yields the
    /// original 4 GB-months, not 8 GB-months (which would happen if both regions each got 4).
    #[test]
    fn cold_storage_not_duplicated_across_regions() {
        let cid = Uuid::new_v4();
        let mut r_eu = make_record(cid, day(1), 500, 0, 0);
        r_eu.region = "eu-west-1".to_string();
        let r_us = make_record(cid, day(1), 1_000, 0, 0);

        let mut ctx = HashMap::new();
        ctx.insert(cid, ctx_cold_only(dec!(4)));

        let (start, end) = feb();
        let summaries = summarize(&[r_us, r_eu], start, end, &ctx);
        assert_eq!(summaries.len(), 2);

        let total_cold: Decimal = summaries
            .iter()
            .map(|s| s.cold_storage_gb_months)
            .fold(dec!(0), |acc, v| acc + v);
        assert_eq!(total_cold, dec!(4));
    }

    // -------------------------------------------------------------------------
    // Object storage
    // -------------------------------------------------------------------------

    /// Object (Garage) storage GB-months and egress GB supplied in `billing_ctx` must appear
    /// verbatim in the resulting summary when the customer has only one active region. This
    /// confirms the pass-through path for both the capacity and egress dimensions.
    #[test]
    fn object_storage_gb_months_passed_through() {
        let cid = Uuid::new_v4();
        let records = vec![make_record(cid, day(1), 100, 0, 0)];

        let mut ctx = HashMap::new();
        ctx.insert(
            cid,
            CustomerBillingContext {
                cold_storage_gb_months: dec!(0),
                object_storage_gb_months: dec!(12.5),
                object_storage_egress_gb: dec!(3.0),
            },
        );

        let (start, end) = feb();
        let summaries = summarize(&records, start, end, &ctx);

        assert_eq!(summaries[0].object_storage_gb_months, dec!(12.5));
        assert_eq!(summaries[0].object_storage_egress_gb, dec!(3.0));
    }

    #[test]
    fn bytes_per_mb_constant_is_decimal_megabyte() {
        use crate::types::BYTES_PER_MB;
        assert_eq!(BYTES_PER_MB, 1_000_000);
    }

    #[test]
    fn summarize_produces_storage_mb_months() {
        use crate::types::BYTES_PER_MB;
        let cid = Uuid::new_v4();
        // 1 MB average per day for all 28 days = 1.0 MB-month
        let records: Vec<_> = (1..=28)
            .map(|d| make_record(cid, day(d), 0, 0, BYTES_PER_MB))
            .collect();

        let (start, end) = feb();
        let summaries = summarize(&records, start, end, &no_ctx());

        assert_eq!(summaries[0].storage_mb_months, dec!(1));
    }

    /// Object storage capacity and egress are per-customer quantities. When the customer has
    /// records in two regions, the total `object_storage_gb_months` and `object_storage_egress_gb`
    /// across both summaries must equal the original `billing_ctx` values — not double them.
    /// Mirrors the anti-duplication invariant tested for cold storage.
    #[test]
    fn object_storage_not_duplicated_across_regions() {
        let cid = Uuid::new_v4();
        let mut r_eu = make_record(cid, day(1), 500, 0, 0);
        r_eu.region = "eu-west-1".to_string();
        let r_us = make_record(cid, day(1), 1_000, 0, 0);

        let mut ctx = HashMap::new();
        ctx.insert(
            cid,
            CustomerBillingContext {
                cold_storage_gb_months: dec!(0),
                object_storage_gb_months: dec!(8),
                object_storage_egress_gb: dec!(2),
            },
        );

        let (start, end) = feb();
        let summaries = summarize(&[r_us, r_eu], start, end, &ctx);
        assert_eq!(summaries.len(), 2);

        let total_obj: Decimal = summaries
            .iter()
            .map(|s| s.object_storage_gb_months)
            .fold(dec!(0), |acc, v| acc + v);
        assert_eq!(total_obj, dec!(8));

        let total_egress: Decimal = summaries
            .iter()
            .map(|s| s.object_storage_egress_gb)
            .fold(dec!(0), |acc, v| acc + v);
        assert_eq!(total_egress, dec!(2));
    }
}
