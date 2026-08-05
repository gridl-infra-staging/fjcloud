use async_trait::async_trait;
use chrono::{Duration, NaiveDate, Utc};
use serde::Serialize;
use uuid::Uuid;

use crate::models::UsageDaily;
use crate::repos::error::RepoError;

#[derive(Debug, Clone, PartialEq)]
pub struct DailyUsageWrite {
    pub date: NaiveDate,
    pub region: String,
    pub search_requests: i64,
    pub write_operations: i64,
    pub storage_bytes_avg: i64,
    pub documents_count_avg: i64,
}

/// Operator and customer identity required for an audited admin usage mutation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AdminUsageMutation {
    pub operator_id: Uuid,
    pub customer_id: Uuid,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct UsageSummary {
    pub total_search_requests: i64,
    pub total_write_operations: i64,
    pub avg_storage_gb: f64,
    pub avg_document_count: i64,
}

/// Returns the inclusive `[start_date, end_date]` window covering `days`
/// calendar days ending on `end_date`.
pub fn window_for_days_ending_on(
    end_date: NaiveDate,
    days: u32,
) -> Result<(NaiveDate, NaiveDate), RepoError> {
    if days == 0 {
        return Err(RepoError::Other("days must be at least 1".to_string()));
    }
    let start_date = end_date - Duration::days(i64::from(days - 1));
    Ok((start_date, end_date))
}

/// Returns the inclusive UTC date window for the trailing `days`-day summary.
pub fn rolling_window_for_days(days: u32) -> Result<(NaiveDate, NaiveDate), RepoError> {
    window_for_days_ending_on(Utc::now().date_naive(), days)
}

#[async_trait]
pub trait UsageRepo {
    async fn get_daily_usage(
        &self,
        customer_id: Uuid,
        start_date: NaiveDate,
        end_date: NaiveDate,
    ) -> Result<Vec<UsageDaily>, RepoError>;

    async fn get_monthly_search_count(
        &self,
        customer_id: Uuid,
        year: i32,
        month: u32,
    ) -> Result<i64, RepoError>;

    async fn summary_for(&self, customer_id: Uuid, days: u32) -> Result<UsageSummary, RepoError>;

    async fn upsert_daily_usage(
        &self,
        _mutation: AdminUsageMutation,
        _entries: &[DailyUsageWrite],
    ) -> Result<u64, RepoError> {
        Err(RepoError::Other(
            "daily usage mutation is not supported by this repository".to_string(),
        ))
    }

    async fn delete_daily_usage(
        &self,
        _mutation: AdminUsageMutation,
        _start_date: NaiveDate,
        _end_date: NaiveDate,
        _month: &str,
        _region: &str,
    ) -> Result<u64, RepoError> {
        Err(RepoError::Other(
            "daily usage mutation is not supported by this repository".to_string(),
        ))
    }
}
