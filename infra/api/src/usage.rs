//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar22_pm_2_utoipa_openapi_docs/fjcloud_dev/infra/api/src/usage.rs.
use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

use crate::models::UsageDaily;

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
    use std::collections::BTreeMap;

    let bytes_per_gb = billing::types::BYTES_PER_GIB as f64;

    // Group rows by region for per-region stats
    let mut region_map: BTreeMap<String, Vec<&UsageDaily>> = BTreeMap::new();
    // Group by date for cross-region totals (sum across regions per day, then average across days)
    let mut date_totals: BTreeMap<chrono::NaiveDate, (i64, i64)> = BTreeMap::new();

    for row in rows {
        region_map.entry(row.region.clone()).or_default().push(row);

        let entry = date_totals.entry(row.date).or_default();
        entry.0 += row.storage_bytes_avg;
        entry.1 += row.documents_count_avg;
    }

    let mut total_search: i64 = 0;
    let mut total_write: i64 = 0;
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

        total_search += search;
        total_write += write;

        by_region.push(RegionUsageSummary {
            region: region.clone(),
            search_requests: search,
            write_operations: write,
            avg_storage_gb,
            avg_document_count: avg_doc_count,
        });
    }

    // Cross-region totals: average the per-day sums across unique dates
    let unique_days = date_totals.len();
    let (avg_storage_gb, avg_document_count) = if unique_days > 0 {
        let total_storage: i64 = date_totals.values().map(|(s, _)| s).sum();
        let total_docs: i64 = date_totals.values().map(|(_, d)| d).sum();
        (
            (total_storage as f64 / unique_days as f64) / bytes_per_gb,
            total_docs / unique_days as i64,
        )
    } else {
        (0.0, 0)
    };

    UsageSummaryResponse {
        month: month.to_string(),
        total_search_requests: total_search,
        total_write_operations: total_write,
        avg_storage_gb,
        avg_document_count,
        by_region,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
}
