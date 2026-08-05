use async_trait::async_trait;
use chrono::NaiveDate;
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::UsageDaily;
use crate::repos::error::RepoError;
use crate::repos::usage_repo::{
    rolling_window_for_days, AdminUsageMutation, DailyUsageWrite, UsageRepo, UsageSummary,
};
use crate::services::audit_log::{
    daily_usage_deleted_audit_entry, daily_usage_upserted_audit_entry, write_audit_log_tx,
    DailyUsageDeleteAuditScope,
};
use crate::usage::summarize_usage_totals;

pub struct PgUsageRepo {
    pool: PgPool,
}

impl PgUsageRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl UsageRepo for PgUsageRepo {
    /// Queries `usage_daily` rows for a customer within a date range,
    /// ordered by date then region.
    async fn get_daily_usage(
        &self,
        customer_id: Uuid,
        start_date: NaiveDate,
        end_date: NaiveDate,
    ) -> Result<Vec<UsageDaily>, RepoError> {
        sqlx::query_as::<_, UsageDaily>(
            "SELECT * FROM usage_daily \
             WHERE customer_id = $1 AND date >= $2 AND date <= $3 \
             ORDER BY date, region",
        )
        .bind(customer_id)
        .bind(start_date)
        .bind(end_date)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// Returns the total search request count for a customer in a given
    /// calendar month, computed as `SUM(search_requests)` over `usage_daily`.
    async fn get_monthly_search_count(
        &self,
        customer_id: Uuid,
        year: i32,
        month: u32,
    ) -> Result<i64, RepoError> {
        let start_date = NaiveDate::from_ymd_opt(year, month, 1)
            .ok_or_else(|| RepoError::Other("invalid year/month".to_string()))?;

        let (next_year, next_month) = if month == 12 {
            (year + 1, 1)
        } else {
            (year, month + 1)
        };
        let end_date = NaiveDate::from_ymd_opt(next_year, next_month, 1)
            .ok_or_else(|| RepoError::Other("invalid year/month".to_string()))?;

        sqlx::query_scalar::<_, i64>(
            "SELECT COALESCE(SUM(search_requests), 0)::BIGINT FROM usage_daily \
             WHERE customer_id = $1 AND date >= $2 AND date < $3",
        )
        .bind(customer_id)
        .bind(start_date)
        .bind(end_date)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn summary_for(&self, customer_id: Uuid, days: u32) -> Result<UsageSummary, RepoError> {
        let (start_date, end_date) = rolling_window_for_days(days)?;
        let rows = self
            .get_daily_usage(customer_id, start_date, end_date)
            .await?;
        Ok(summarize_usage_totals(&rows))
    }

    async fn upsert_daily_usage(
        &self,
        mutation: AdminUsageMutation,
        entries: &[DailyUsageWrite],
    ) -> Result<u64, RepoError> {
        let mut transaction = self.pool.begin().await.map_err(repo_error)?;
        for entry in entries {
            sqlx::query(
                "INSERT INTO usage_daily (customer_id, date, region, search_requests, \
                 write_operations, storage_bytes_avg, documents_count_avg, aggregated_at) \
                 VALUES ($1, $2, $3, $4, $5, $6, $7, NOW()) \
                 ON CONFLICT (customer_id, date, region) DO UPDATE SET \
                 search_requests = EXCLUDED.search_requests, \
                 write_operations = EXCLUDED.write_operations, \
                 storage_bytes_avg = EXCLUDED.storage_bytes_avg, \
                 documents_count_avg = EXCLUDED.documents_count_avg, \
                 aggregated_at = NOW()",
            )
            .bind(mutation.customer_id)
            .bind(entry.date)
            .bind(&entry.region)
            .bind(entry.search_requests)
            .bind(entry.write_operations)
            .bind(entry.storage_bytes_avg)
            .bind(entry.documents_count_avg)
            .execute(&mut *transaction)
            .await
            .map_err(repo_error)?;
        }
        let mutation_count = entries.len() as u64;
        let audit_entry = daily_usage_upserted_audit_entry(
            mutation.operator_id,
            mutation.customer_id,
            entries
                .iter()
                .map(|entry| (entry.date, entry.region.as_str())),
            mutation_count,
        );
        write_audit_log_tx(&mut transaction, &audit_entry)
            .await
            .map_err(audit_repo_error)?;
        transaction.commit().await.map_err(repo_error)?;
        Ok(mutation_count)
    }

    async fn delete_daily_usage(
        &self,
        mutation: AdminUsageMutation,
        start_date: NaiveDate,
        end_date: NaiveDate,
        month: &str,
        region: &str,
    ) -> Result<u64, RepoError> {
        let mut transaction = self.pool.begin().await.map_err(repo_error)?;
        let mutation_count = sqlx::query(
            "DELETE FROM usage_daily \
             WHERE customer_id = $1 AND date >= $2 AND date <= $3 AND region = $4",
        )
        .bind(mutation.customer_id)
        .bind(start_date)
        .bind(end_date)
        .bind(region)
        .execute(&mut *transaction)
        .await
        .map_err(repo_error)?
        .rows_affected();
        let audit_entry = daily_usage_deleted_audit_entry(
            mutation.operator_id,
            mutation.customer_id,
            &DailyUsageDeleteAuditScope {
                month,
                start_date,
                end_date,
                region,
                mutation_count,
            },
        );
        write_audit_log_tx(&mut transaction, &audit_entry)
            .await
            .map_err(audit_repo_error)?;
        transaction.commit().await.map_err(repo_error)?;
        Ok(mutation_count)
    }
}

fn repo_error(error: sqlx::Error) -> RepoError {
    RepoError::Other(error.to_string())
}

fn audit_repo_error(error: crate::services::audit_log::AuditLogError) -> RepoError {
    RepoError::Other(error.to_string())
}
