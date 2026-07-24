use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::{Customer, IngestQuotaWarningMetric};
use crate::repos::error::RepoError;

pub(super) const QUOTA_WARNINGS_SENT_PROJECTION: &str =
    "COALESCE((to_jsonb(customers)->>'quota_warnings_sent')::jsonb, '{}'::jsonb) AS quota_warnings_sent";

const CLAIM_INGEST_QUOTA_WARNING_SQL: &str = "UPDATE customers SET \
    quota_warnings_sent = jsonb_set( \
        COALESCE(quota_warnings_sent, '{}'::jsonb), \
        ARRAY[$2::text], \
        to_jsonb($3::text), \
        true \
    ), \
    updated_at = NOW() \
 WHERE id = $1 \
   AND status != 'deleted' \
   AND COALESCE(quota_warnings_sent->>$2, '') <> $3";

const ROLLBACK_INGEST_QUOTA_WARNING_SQL: &str = "UPDATE customers SET \
    quota_warnings_sent = COALESCE(quota_warnings_sent, '{}'::jsonb) - $2::text, \
    updated_at = NOW() \
 WHERE id = $1 \
   AND status != 'deleted' \
   AND COALESCE(quota_warnings_sent->>$2, '') = $3";

fn normalized_month_key(year: i32, month: u32) -> Result<String, RepoError> {
    Customer::normalized_ingest_quota_warning_month_key(year, month)
        .ok_or_else(|| RepoError::Other("invalid ingest quota warning month".to_string()))
}

pub(super) async fn set_quota_warning_sent_at(
    pool: &PgPool,
    id: Uuid,
    sent_at: DateTime<Utc>,
) -> Result<bool, RepoError> {
    let result = sqlx::query(
        "UPDATE customers SET quota_warning_sent_at = $2, updated_at = NOW() \
             WHERE id = $1 AND status != 'deleted'",
    )
    .bind(id)
    .bind(sent_at)
    .execute(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    Ok(result.rows_affected() > 0)
}

pub(super) async fn claim_ingest_quota_warning_for_month(
    pool: &PgPool,
    id: Uuid,
    metric: IngestQuotaWarningMetric,
    year: i32,
    month: u32,
) -> Result<bool, RepoError> {
    let month_key = normalized_month_key(year, month)?;
    let result = sqlx::query(CLAIM_INGEST_QUOTA_WARNING_SQL)
        .bind(id)
        .bind(metric.as_json_key())
        .bind(month_key)
        .execute(pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;
    Ok(result.rows_affected() > 0)
}

pub(super) async fn rollback_ingest_quota_warning_for_month(
    pool: &PgPool,
    id: Uuid,
    metric: IngestQuotaWarningMetric,
    year: i32,
    month: u32,
) -> Result<bool, RepoError> {
    let month_key = normalized_month_key(year, month)?;
    let result = sqlx::query(ROLLBACK_INGEST_QUOTA_WARNING_SQL)
        .bind(id)
        .bind(metric.as_json_key())
        .bind(month_key)
        .execute(pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;
    Ok(result.rows_affected() > 0)
}
