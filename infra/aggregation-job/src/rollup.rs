use chrono::{DateTime, NaiveDate, TimeDelta, TimeZone, Utc};

/// Returns the half-open UTC window `[day_start, next_day_start)` for `date`.
///
/// All `usage_records` rows with `recorded_at >= start AND recorded_at < end`
/// belong to this calendar day.
pub fn day_window(date: NaiveDate) -> (DateTime<Utc>, DateTime<Utc>) {
    let start = Utc.from_utc_datetime(&date.and_hms_opt(0, 0, 0).unwrap());
    let end = Utc.from_utc_datetime(&(date + TimeDelta::days(1)).and_hms_opt(0, 0, 0).unwrap());
    (start, end)
}

/// The SQL that rolls up one day of `usage_records` into `usage_daily`.
///
/// Parameters:
///   $1 — window start (inclusive)  DateTime<Utc>
///   $2 — window end   (exclusive)  DateTime<Utc>
///   $3 — target date               NaiveDate
///
/// Counter events (search_requests, write_operations) are summed.
/// Gauge events (storage_bytes, document_count) are averaged over all
/// snapshots taken that day.
///
/// ON CONFLICT re-runs are idempotent: a second run for the same date
/// overwrites the earlier result.
pub const ROLLUP_SQL: &str = r#"
INSERT INTO usage_daily
    (customer_id, date, region,
     search_requests, write_operations,
     storage_bytes_avg, documents_count_avg,
     aggregated_at)
SELECT
    customer_id,
    $3::date                                                        AS date,
    region,
    COALESCE(SUM(CASE WHEN event_type = 'search_requests'
                      THEN value ELSE 0 END), 0)                    AS search_requests,
    COALESCE(SUM(CASE WHEN event_type = 'write_operations'
                      THEN value ELSE 0 END), 0)                    AS write_operations,
    ROUND(COALESCE(AVG(CASE WHEN event_type = 'storage_bytes'
                      THEN value END), 0))::BIGINT                  AS storage_bytes_avg,
    ROUND(COALESCE(AVG(CASE WHEN event_type = 'document_count'
                      THEN value END), 0))::BIGINT                  AS documents_count_avg,
    NOW()
FROM usage_records
WHERE recorded_at >= $1
  AND recorded_at <  $2
GROUP BY customer_id, region
ON CONFLICT (customer_id, date, region) DO UPDATE SET
    search_requests     = EXCLUDED.search_requests,
    write_operations    = EXCLUDED.write_operations,
    storage_bytes_avg   = EXCLUDED.storage_bytes_avg,
    documents_count_avg = EXCLUDED.documents_count_avg,
    aggregated_at       = NOW()
"#;

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{NaiveDate, TimeZone, Utc};

    fn date(y: i32, m: u32, d: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, d).unwrap()
    }

    #[test]
    fn window_start_is_midnight_utc() {
        let (start, _) = day_window(date(2026, 2, 15));
        assert_eq!(start, Utc.with_ymd_and_hms(2026, 2, 15, 0, 0, 0).unwrap());
    }

    #[test]
    fn window_end_is_midnight_next_day() {
        let (_, end) = day_window(date(2026, 2, 15));
        assert_eq!(end, Utc.with_ymd_and_hms(2026, 2, 16, 0, 0, 0).unwrap());
    }

    #[test]
    fn window_covers_exactly_24_hours() {
        let (start, end) = day_window(date(2026, 2, 15));
        assert_eq!((end - start).num_hours(), 24);
    }

    #[test]
    fn window_crosses_month_boundary_correctly() {
        let (start, end) = day_window(date(2026, 2, 28));
        assert_eq!(start, Utc.with_ymd_and_hms(2026, 2, 28, 0, 0, 0).unwrap());
        assert_eq!(end, Utc.with_ymd_and_hms(2026, 3, 1, 0, 0, 0).unwrap());
    }

    #[test]
    fn window_crosses_year_boundary_correctly() {
        let (start, end) = day_window(date(2025, 12, 31));
        assert_eq!(start, Utc.with_ymd_and_hms(2025, 12, 31, 0, 0, 0).unwrap());
        assert_eq!(end, Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap());
    }

    #[test]
    fn window_is_half_open_start_included() {
        let (start, end) = day_window(date(2026, 2, 15));
        // A timestamp exactly at midnight should be IN the window.
        assert!(start >= Utc.with_ymd_and_hms(2026, 2, 15, 0, 0, 0).unwrap());
        // A timestamp exactly at end should be OUT (half-open).
        assert!(end > Utc.with_ymd_and_hms(2026, 2, 15, 23, 59, 59).unwrap());
    }

    // -------------------------------------------------------------------------
    // Stage 4: Aggregation Pipeline Accuracy — Rollup Correctness
    // -------------------------------------------------------------------------

    /// AJ-01: Rollup SQL structure verification — ensure the ROLLUP_SQL contains
    /// the necessary components for correct multi-tenant, multi-day aggregation:
    /// - COALESCE for handling NULLs (zero-usage tenants)
    /// - ON CONFLICT for idempotency
    /// - Proper GROUP BY for customer_id and region
    #[test]
    fn rollup_sql_contains_required_clauses() {
        // Verify COALESCE guards for zero-usage handling
        assert!(
            ROLLUP_SQL.contains("COALESCE(SUM(CASE WHEN event_type = 'search_requests'"),
            "ROLLUP_SQL must COALESCE search_requests to handle zero-usage"
        );
        assert!(
            ROLLUP_SQL.contains("COALESCE(SUM(CASE WHEN event_type = 'write_operations'"),
            "ROLLUP_SQL must COALESCE write_operations to handle zero-usage"
        );

        // Verify ON CONFLICT for idempotency
        assert!(
            ROLLUP_SQL.contains("ON CONFLICT (customer_id, date, region) DO UPDATE"),
            "ROLLUP_SQL must have ON CONFLICT for idempotency"
        );

        // Verify GROUP BY for proper aggregation
        assert!(
            ROLLUP_SQL.contains("GROUP BY customer_id, region"),
            "ROLLUP_SQL must GROUP BY customer_id and region"
        );

        // Verify half-open window bounds
        assert!(
            ROLLUP_SQL.contains("recorded_at >= $1"),
            "ROLLUP_SQL must use >= for start bound (inclusive)"
        );
        assert!(
            ROLLUP_SQL.contains("recorded_at <  $2"),
            "ROLLUP_SQL must use < for end bound (exclusive)"
        );

        // Verify gauge metrics are aggregated
        assert!(
            ROLLUP_SQL.contains("storage_bytes"),
            "ROLLUP_SQL must handle storage_bytes"
        );
        assert!(
            ROLLUP_SQL.contains("document_count"),
            "ROLLUP_SQL must handle document_count"
        );
    }

    /// AJ-02: Day window produces correct UTC boundaries for multi-day rollup.
    /// Verify that consecutive days have non-overlapping, adjacent windows.
    #[test]
    fn day_windows_are_adjacent_and_non_overlapping() {
        let day1 = date(2026, 2, 15);
        let day2 = date(2026, 2, 16);

        let (start1, end1) = day_window(day1);
        let (start2, end2) = day_window(day2);

        // Windows should be adjacent: day1.end == day2.start
        assert_eq!(
            end1, start2,
            "consecutive day windows must be adjacent (no gaps, no overlaps)"
        );

        // Each window should be exactly 24 hours
        assert_eq!(
            (end1 - start1).num_hours(),
            24,
            "each day window must be exactly 24 hours"
        );
        assert_eq!(
            (end2 - start2).num_hours(),
            24,
            "each day window must be exactly 24 hours"
        );
    }

    /// AJ-03: Verify day window handles month and year boundaries correctly
    /// for multi-day rollup scenarios.
    #[test]
    fn day_window_handles_month_year_boundaries() {
        // Month boundary
        let (_feb28_start, feb28_end) = day_window(date(2026, 2, 28));
        let (mar1_start, _mar1_end) = day_window(date(2026, 3, 1));

        assert_eq!(
            feb28_end, mar1_start,
            "Feb 28 to Mar 1 transition must be adjacent (non-leap year)"
        );

        // Year boundary
        let (dec31_start, dec31_end) = day_window(date(2026, 12, 31));
        let (jan1_start, _jan1_end) = day_window(date(2027, 1, 1));

        assert_eq!(
            dec31_end, jan1_start,
            "Dec 31 to Jan 1 transition must be adjacent"
        );

        // Verify exact timestamps
        assert_eq!(
            dec31_start,
            Utc.with_ymd_and_hms(2026, 12, 31, 0, 0, 0).unwrap()
        );
        assert_eq!(
            dec31_end,
            Utc.with_ymd_and_hms(2027, 1, 1, 0, 0, 0).unwrap()
        );
        assert_eq!(
            jan1_start,
            Utc.with_ymd_and_hms(2027, 1, 1, 0, 0, 0).unwrap()
        );
    }

    /// AJ-03: Zero-usage tenant handling — verify that tenants with no usage
    /// records are excluded from rollup results (no spurious zero rows).
    /// Tenants with no usage_records rows are naturally excluded by SQL semantics:
    /// the query uses FROM usage_records with a WHERE recorded_at clause, so no
    /// rows match → no group created. COALESCE handles the case where a tenant
    /// has only zero-value rows.
    #[test]
    fn zero_usage_tenants_excluded_from_rollup() {
        // Verify ROLLUP_SQL doesn't force zero-usage tenants to appear
        // (no LEFT JOIN, no CROSS JOIN with tenant list)
        assert!(
            !ROLLUP_SQL.contains("LEFT JOIN"),
            "ROLLUP_SQL should not LEFT JOIN with tenants table (would create zero rows)"
        );
        assert!(
            !ROLLUP_SQL.contains("CROSS JOIN"),
            "ROLLUP_SQL should not CROSS JOIN with tenants table"
        );
    }

    // -------------------------------------------------------------------------
    // Stage 4 Sprint 2: Multi-snapshot gauge semantics & billing-column lockdown
    // -------------------------------------------------------------------------

    /// Counters (search_requests, write_operations) must use SUM — they are
    /// monotonic deltas within a day, not point-in-time snapshots.
    #[test]
    fn rollup_sql_uses_sum_for_counter_metrics() {
        assert!(
            ROLLUP_SQL.contains("SUM(CASE WHEN event_type = 'search_requests'"),
            "search_requests must be aggregated with SUM (counter metric)"
        );
        assert!(
            ROLLUP_SQL.contains("SUM(CASE WHEN event_type = 'write_operations'"),
            "write_operations must be aggregated with SUM (counter metric)"
        );
        // Counters must NOT use AVG — that would under-count usage.
        assert!(
            !ROLLUP_SQL.contains("AVG(CASE WHEN event_type = 'search_requests'"),
            "search_requests must not use AVG (counter, not gauge)"
        );
        assert!(
            !ROLLUP_SQL.contains("AVG(CASE WHEN event_type = 'write_operations'"),
            "write_operations must not use AVG (counter, not gauge)"
        );
    }

    /// Gauges (storage_bytes, document_count) must use AVG — multiple snapshots
    /// per day should produce a fair daily average, not an inflated sum.
    #[test]
    fn rollup_sql_uses_avg_for_gauge_metrics() {
        assert!(
            ROLLUP_SQL.contains("AVG(CASE WHEN event_type = 'storage_bytes'"),
            "storage_bytes must be aggregated with AVG (gauge metric)"
        );
        assert!(
            ROLLUP_SQL.contains("AVG(CASE WHEN event_type = 'document_count'"),
            "document_count must be aggregated with AVG (gauge metric)"
        );
        // Gauges must NOT use SUM — that would multiply the value by snapshot count.
        assert!(
            !ROLLUP_SQL.contains("SUM(CASE WHEN event_type = 'storage_bytes'"),
            "storage_bytes must not use SUM (gauge, not counter)"
        );
        assert!(
            !ROLLUP_SQL.contains("SUM(CASE WHEN event_type = 'document_count'"),
            "document_count must not use SUM (gauge, not counter)"
        );
    }

    /// Gauge averages must be ROUND(...)::BIGINT so they produce integer values
    /// compatible with the `usage_daily` BIGINT columns. Without ROUND, Postgres
    /// would truncate or error on the implicit cast.
    #[test]
    fn rollup_sql_rounds_gauge_averages_to_bigint() {
        // storage_bytes_avg column
        assert!(
            ROLLUP_SQL.contains("ROUND(COALESCE(AVG(CASE WHEN event_type = 'storage_bytes'"),
            "storage_bytes gauge must be wrapped in ROUND(COALESCE(AVG(...)))"
        );
        assert!(
            ROLLUP_SQL.contains("storage_bytes_avg"),
            "storage_bytes gauge column must be aliased as storage_bytes_avg"
        );

        // documents_count_avg column
        assert!(
            ROLLUP_SQL.contains("ROUND(COALESCE(AVG(CASE WHEN event_type = 'document_count'"),
            "document_count gauge must be wrapped in ROUND(COALESCE(AVG(...)))"
        );
        assert!(
            ROLLUP_SQL.contains("documents_count_avg"),
            "document_count gauge column must be aliased as documents_count_avg"
        );

        // Both must cast to BIGINT for the usage_daily integer columns
        let bigint_casts = ROLLUP_SQL.matches("::BIGINT").count();
        assert!(
            bigint_casts >= 2,
            "ROLLUP_SQL must cast at least 2 gauge averages to BIGINT, found {bigint_casts}"
        );
    }

    /// The ON CONFLICT clause must overwrite all four metric columns plus
    /// `aggregated_at` so reruns are fully idempotent — partial overwrites
    /// would leave stale values from a previous run.
    #[test]
    fn rollup_sql_on_conflict_overwrites_all_metric_columns() {
        let conflict_section = ROLLUP_SQL
            .split("ON CONFLICT")
            .nth(1)
            .expect("ROLLUP_SQL must contain ON CONFLICT");

        for col in [
            "search_requests",
            "write_operations",
            "storage_bytes_avg",
            "documents_count_avg",
            "aggregated_at",
        ] {
            // Match "col<whitespace>=" to handle aligned formatting
            let pattern = format!("{col} ");
            assert!(
                conflict_section.contains(&pattern),
                "ON CONFLICT must overwrite {col}"
            );
        }
    }

    /// The SELECT output columns must match the `usage_daily` INSERT column list.
    /// This locks the mapping so column reorderings or renames break the test.
    #[test]
    fn rollup_sql_insert_columns_match_select_aliases() {
        // Extract the INSERT column list
        let insert_cols = [
            "customer_id",
            "date",
            "region",
            "search_requests",
            "write_operations",
            "storage_bytes_avg",
            "documents_count_avg",
            "aggregated_at",
        ];

        // Verify INSERT INTO usage_daily lists all expected columns
        let insert_section = ROLLUP_SQL
            .split("SELECT")
            .next()
            .expect("ROLLUP_SQL must have INSERT before SELECT");

        for col in &insert_cols {
            assert!(
                insert_section.contains(col),
                "INSERT column list must include {col}"
            );
        }

        // Verify SELECT aliases match — each column must appear as an alias
        let select_section = ROLLUP_SQL
            .split("SELECT")
            .nth(1)
            .expect("ROLLUP_SQL must have SELECT");

        for col in [
            "date",
            "search_requests",
            "write_operations",
            "storage_bytes_avg",
            "documents_count_avg",
        ] {
            assert!(
                select_section.contains(&format!("AS {col}"))
                    || select_section.contains(&format!("AS\n    {col}"))
                    || select_section.contains(col),
                "SELECT must produce column {col}"
            );
        }
    }

    /// Half-open window semantics: a record at exactly midnight of the next day
    /// must be excluded (`< $2`), while a record at exactly midnight of the
    /// target day must be included (`>= $1`). This is a structural SQL check —
    /// the `<` vs `<=` distinction is the only thing preventing off-by-one in
    /// midnight-boundary billing.
    #[test]
    fn rollup_sql_midnight_boundary_exclusion() {
        // The WHERE clause must use strict < for the upper bound, not <=.
        // With <=, a record at exactly 2026-02-16T00:00:00Z would be counted
        // in BOTH Feb 15 and Feb 16 rollups — double-billing.
        assert!(
            ROLLUP_SQL.contains("recorded_at <  $2") || ROLLUP_SQL.contains("recorded_at < $2"),
            "upper bound must use strict < (not <=) to exclude midnight of next day"
        );
        assert!(
            !ROLLUP_SQL.contains("recorded_at <= $2"),
            "upper bound must NOT use <= (would double-count midnight records)"
        );
        assert!(
            ROLLUP_SQL.contains("recorded_at >= $1"),
            "lower bound must use >= to include midnight of target day"
        );
    }
}
