use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

use crate::models::UsageDaily;
use crate::repos::usage_repo::UsageSummary;

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct DailyUsageEntry {
    pub date: NaiveDate,
    pub region: String,
    pub search_requests: i64,
    pub write_operations: i64,
    pub storage_gb: f64,
    pub document_count: i64,
}

impl DailyUsageEntry {
    pub fn from_row(row: &UsageDaily) -> Self {
        let bytes_per_gb = billing::types::BYTES_PER_GIB as f64;
        Self {
            date: row.date,
            region: row.region.clone(),
            search_requests: row.search_requests,
            write_operations: row.write_operations,
            storage_gb: row.storage_bytes_avg as f64 / bytes_per_gb,
            document_count: row.documents_count_avg,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct UsageSummaryResponse {
    pub month: String,
    pub total_search_requests: i64,
    pub total_write_operations: i64,
    pub avg_storage_gb: f64,
    pub avg_document_count: i64,
    pub by_region: Vec<RegionUsageSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct RegionUsageSummary {
    pub region: String,
    pub search_requests: i64,
    pub write_operations: i64,
    pub avg_storage_gb: f64,
    pub avg_document_count: i64,
}

/// Aggregates daily usage rows into a monthly summary grouped by region
/// (BTreeMap for alphabetical ordering). Computes per-region sums for
/// searches/writes and averages for storage/documents, plus cross-region
/// daily totals averaged across unique dates.
pub fn aggregate_monthly(rows: &[UsageDaily], month: &str) -> UsageSummaryResponse {
    let summary = summarize_usage_totals(rows);
    let by_region = summarize_usage_by_region(rows);

    UsageSummaryResponse {
        month: month.to_string(),
        total_search_requests: summary.total_search_requests,
        total_write_operations: summary.total_write_operations,
        avg_storage_gb: summary.avg_storage_gb,
        avg_document_count: summary.avg_document_count,
        by_region,
    }
}

/// Aggregates cross-region totals and daily averages shared by monthly usage
/// responses and repo-level rolling-window usage summaries.
pub fn summarize_usage_totals(rows: &[UsageDaily]) -> UsageSummary {
    use std::collections::BTreeMap;

    let bytes_per_gb = billing::types::BYTES_PER_GIB as f64;
    let total_search_requests: i64 = rows.iter().map(|row| row.search_requests).sum();
    let total_write_operations: i64 = rows.iter().map(|row| row.write_operations).sum();

    // Sum storage/documents across all regions for each date, then average
    // those daily totals across unique days.
    let mut daily_totals: BTreeMap<chrono::NaiveDate, (i64, i64)> = BTreeMap::new();
    for row in rows {
        let entry = daily_totals.entry(row.date).or_default();
        entry.0 += row.storage_bytes_avg;
        entry.1 += row.documents_count_avg;
    }

    let unique_days = daily_totals.len();
    let (avg_storage_gb, avg_document_count) = if unique_days > 0 {
        let total_storage: i64 = daily_totals.values().map(|(storage, _)| storage).sum();
        let total_documents: i64 = daily_totals.values().map(|(_, docs)| docs).sum();
        (
            (total_storage as f64 / unique_days as f64) / bytes_per_gb,
            total_documents / unique_days as i64,
        )
    } else {
        (0.0, 0)
    };

    UsageSummary {
        total_search_requests,
        total_write_operations,
        avg_storage_gb,
        avg_document_count,
    }
}

fn summarize_usage_by_region(rows: &[UsageDaily]) -> Vec<RegionUsageSummary> {
    use std::collections::BTreeMap;

    let bytes_per_gb = billing::types::BYTES_PER_GIB as f64;

    // Group rows by region for per-region stats
    let mut region_map: BTreeMap<String, Vec<&UsageDaily>> = BTreeMap::new();

    for row in rows {
        region_map.entry(row.region.clone()).or_default().push(row);
    }

    let mut by_region = Vec::new();

    // BTreeMap iterates in sorted key order — alphabetical
    for (region, days) in &region_map {
        let day_count = days.len();
        let search: i64 = days.iter().map(|d| d.search_requests).sum();
        let write: i64 = days.iter().map(|d| d.write_operations).sum();
        let storage_sum: i64 = days.iter().map(|d| d.storage_bytes_avg).sum();
        let doc_sum: i64 = days.iter().map(|d| d.documents_count_avg).sum();

        let avg_storage_gb = if day_count > 0 {
            (storage_sum as f64 / day_count as f64) / bytes_per_gb
        } else {
            0.0
        };
        let avg_doc_count = if day_count > 0 {
            doc_sum / day_count as i64
        } else {
            0
        };

        by_region.push(RegionUsageSummary {
            region: region.clone(),
            search_requests: search,
            write_operations: write,
            avg_storage_gb,
            avg_document_count: avg_doc_count,
        });
    }

    by_region
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::repos::usage_repo::window_for_days_ending_on;
    use chrono::{NaiveDate, Utc};
    use uuid::Uuid;

    /// Test helper: creates a [`UsageDaily`] with the given parameters.
    fn make_usage(
        customer_id: Uuid,
        date: NaiveDate,
        region: &str,
        search: i64,
        write: i64,
        storage_bytes: i64,
        doc_count: i64,
    ) -> UsageDaily {
        UsageDaily {
            customer_id,
            date,
            region: region.to_string(),
            search_requests: search,
            write_operations: write,
            storage_bytes_avg: storage_bytes,
            documents_count_avg: doc_count,
            aggregated_at: Utc::now(),
        }
    }

    #[test]
    fn empty_input_returns_zero_totals() {
        let result = aggregate_monthly(&[], "2026-02");
        assert_eq!(result.month, "2026-02");
        assert_eq!(result.total_search_requests, 0);
        assert_eq!(result.total_write_operations, 0);
        assert_eq!(result.avg_storage_gb, 0.0);
        assert_eq!(result.avg_document_count, 0);
        assert!(result.by_region.is_empty());
    }

    /// Verifies search/write sums and storage/document averages across
    /// two days in a single region.
    #[test]
    fn single_region_multiple_days_sums_correctly() {
        let cid = Uuid::new_v4();
        let rows = vec![
            make_usage(
                cid,
                NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
                "us-east-1",
                1000,
                100,
                billing::types::BYTES_PER_GIB, // 1 GB
                5000,
            ),
            make_usage(
                cid,
                NaiveDate::from_ymd_opt(2026, 2, 2).unwrap(),
                "us-east-1",
                2000,
                200,
                billing::types::BYTES_PER_GIB * 3, // 3 GB
                7000,
            ),
        ];

        let result = aggregate_monthly(&rows, "2026-02");

        assert_eq!(result.total_search_requests, 3000);
        assert_eq!(result.total_write_operations, 300);
        // avg storage: (1GB + 3GB) / 2 days = 2.0 GB
        assert!((result.avg_storage_gb - 2.0).abs() < 0.001);
        // avg docs: (5000 + 7000) / 2 = 6000
        assert_eq!(result.avg_document_count, 6000);
        assert_eq!(result.by_region.len(), 1);
        assert_eq!(result.by_region[0].region, "us-east-1");
    }

    /// Verifies alphabetical region ordering and correct cross-region
    /// per-day averaging.
    #[test]
    fn multiple_regions_aggregated_and_sorted() {
        let cid = Uuid::new_v4();
        let rows = vec![
            make_usage(
                cid,
                NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
                "us-east-1",
                1000,
                100,
                billing::types::BYTES_PER_GIB,
                4000,
            ),
            make_usage(
                cid,
                NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
                "eu-west-1",
                500,
                50,
                billing::types::BYTES_PER_GIB * 2,
                6000,
            ),
        ];

        let result = aggregate_monthly(&rows, "2026-02");

        // Totals
        assert_eq!(result.total_search_requests, 1500);
        assert_eq!(result.total_write_operations, 150);

        // by_region sorted alphabetically: eu-west-1 before us-east-1
        assert_eq!(result.by_region.len(), 2);
        assert_eq!(result.by_region[0].region, "eu-west-1");
        assert_eq!(result.by_region[0].search_requests, 500);
        assert_eq!(result.by_region[1].region, "us-east-1");
        assert_eq!(result.by_region[1].search_requests, 1000);

        // Cross-region avg storage: day 1 total = 1GB + 2GB = 3GB, 1 unique day → 3.0 GB
        assert!((result.avg_storage_gb - 3.0).abs() < 0.001);
        // Cross-region avg docs: day 1 total = 4000 + 6000 = 10000, 1 unique day → 10000
        assert_eq!(result.avg_document_count, 10000);
    }

    #[test]
    fn seven_day_window_excludes_stale_rows_and_matches_summary_fields() {
        let cid = Uuid::new_v4();
        let anchor = NaiveDate::from_ymd_opt(2026, 3, 7).unwrap();
        let stale_date = NaiveDate::from_ymd_opt(2026, 2, 28).unwrap();
        let bytes_per_gb = billing::types::BYTES_PER_GIB;
        let rows = [
            make_usage(
                cid,
                NaiveDate::from_ymd_opt(2026, 3, 1).unwrap(),
                "us-east-1",
                10,
                1,
                bytes_per_gb,
                100,
            ),
            make_usage(
                cid,
                NaiveDate::from_ymd_opt(2026, 3, 2).unwrap(),
                "us-east-1",
                20,
                2,
                bytes_per_gb * 2,
                200,
            ),
            make_usage(
                cid,
                NaiveDate::from_ymd_opt(2026, 3, 3).unwrap(),
                "us-east-1",
                30,
                3,
                bytes_per_gb * 3,
                300,
            ),
            make_usage(
                cid,
                NaiveDate::from_ymd_opt(2026, 3, 4).unwrap(),
                "us-east-1",
                40,
                4,
                bytes_per_gb * 4,
                400,
            ),
            make_usage(
                cid,
                NaiveDate::from_ymd_opt(2026, 3, 5).unwrap(),
                "us-east-1",
                50,
                5,
                bytes_per_gb * 5,
                500,
            ),
            make_usage(
                cid,
                NaiveDate::from_ymd_opt(2026, 3, 6).unwrap(),
                "us-east-1",
                60,
                6,
                bytes_per_gb * 6,
                600,
            ),
            make_usage(
                cid,
                NaiveDate::from_ymd_opt(2026, 3, 7).unwrap(),
                "us-east-1",
                70,
                7,
                bytes_per_gb * 7,
                700,
            ),
            make_usage(
                cid,
                stale_date,
                "us-east-1",
                999,
                999,
                bytes_per_gb * 99,
                9999,
            ),
        ];

        let (start_date, end_date) = window_for_days_ending_on(anchor, 7).unwrap();
        let window_rows: Vec<UsageDaily> = rows
            .iter()
            .filter(|row| row.date >= start_date && row.date <= end_date)
            .cloned()
            .collect();
        assert_eq!(window_rows.len(), 7);

        let summary = summarize_usage_totals(&window_rows);
        assert_eq!(summary.total_search_requests, 280);
        assert_eq!(summary.total_write_operations, 28);
        assert!((summary.avg_storage_gb - 4.0).abs() < 0.0001);
        assert_eq!(summary.avg_document_count, 400);

        let monthly = aggregate_monthly(&window_rows, "2026-03");
        assert_eq!(monthly.total_search_requests, summary.total_search_requests);
        assert_eq!(
            monthly.total_write_operations,
            summary.total_write_operations
        );
        assert!((monthly.avg_storage_gb - summary.avg_storage_gb).abs() < 0.0001);
        assert_eq!(monthly.avg_document_count, summary.avg_document_count);
    }
}
