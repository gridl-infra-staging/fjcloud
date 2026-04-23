//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar25_am_3_customer_multitenant_multiregion_coverage/fjcloud_dev/infra/api/src/repos/pg_usage_repo.rs.
use async_trait::async_trait;
use chrono::NaiveDate;
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::UsageDaily;
use crate::repos::error::RepoError;
use crate::repos::usage_repo::UsageRepo;

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
}
