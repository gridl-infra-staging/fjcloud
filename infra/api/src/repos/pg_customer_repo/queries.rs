use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::{Customer, IngestQuotaWarningMetric};
use crate::repos::error::RepoError;
use crate::repos::pg_customer_repo::projection::{customer_columns, list_customers_sql};

/// Fetch all customers with the shared list projection.
pub(super) async fn list(pool: &PgPool) -> Result<Vec<Customer>, RepoError> {
    let sql = list_customers_sql();
    sqlx::query_as::<_, Customer>(&sql)
        .fetch_all(pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
}

/// Fetch a customer by primary key.
pub(super) async fn find_by_id(pool: &PgPool, id: Uuid) -> Result<Option<Customer>, RepoError> {
    let customer_columns = customer_columns();
    let sql = format!("SELECT {customer_columns} FROM customers WHERE id = $1");
    sqlx::query_as::<_, Customer>(&sql)
        .bind(id)
        .fetch_optional(pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
}

/// Fetch a customer by email address.
pub(super) async fn find_by_email(
    pool: &PgPool,
    email: &str,
) -> Result<Option<Customer>, RepoError> {
    let customer_columns = customer_columns();
    let sql = format!("SELECT {customer_columns} FROM customers WHERE email = $1");
    sqlx::query_as::<_, Customer>(&sql)
        .bind(email)
        .fetch_optional(pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
}

/// Fetch soft-deleted customers eligible for hard-erasure.
pub(super) async fn list_deleted_before_cutoff(
    pool: &PgPool,
    cutoff: DateTime<Utc>,
) -> Result<Vec<Customer>, RepoError> {
    let customer_columns = customer_columns();
    let sql = format!(
        "SELECT * FROM ( \
                SELECT {customer_columns} FROM customers \
             ) AS customer_rows \
             WHERE status = 'deleted' \
               AND deleted_at IS NOT NULL \
               AND deleted_at <= $1 \
             ORDER BY deleted_at ASC, id ASC"
    );
    sqlx::query_as::<_, Customer>(&sql)
        .bind(cutoff)
        .fetch_all(pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
}

/// Fetch the active customer linked to an OAuth provider identity.
pub(super) async fn find_oauth_identity(
    pool: &PgPool,
    provider: &str,
    provider_user_id: &str,
) -> Result<Option<Customer>, RepoError> {
    let customer_columns = customer_columns();
    let sql = format!(
        "SELECT {customer_columns} \
             FROM oauth_identities \
             INNER JOIN customers ON customers.id = oauth_identities.customer_id \
             WHERE oauth_identities.provider = $1 \
               AND oauth_identities.provider_user_id = $2 \
               AND customers.status != 'deleted'"
    );
    sqlx::query_as::<_, Customer>(&sql)
        .bind(provider)
        .bind(provider_user_id)
        .fetch_optional(pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
}

/// Fetch the active customer with a non-expired password reset token.
pub(super) async fn find_by_reset_token(
    pool: &PgPool,
    token: &str,
) -> Result<Option<Customer>, RepoError> {
    let customer_columns = customer_columns();
    let sql = format!(
        "SELECT {customer_columns} FROM customers \
             WHERE password_reset_token = $1 \
               AND password_reset_expires_at > NOW() \
               AND status != 'deleted'"
    );
    sqlx::query_as::<_, Customer>(&sql)
        .bind(token)
        .fetch_optional(pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
}

/// Fetch the active customer linked to a Stripe customer id.
pub(super) async fn find_by_stripe_customer_id(
    pool: &PgPool,
    stripe_customer_id: &str,
) -> Result<Option<Customer>, RepoError> {
    let customer_columns = customer_columns();
    let sql = format!(
        "SELECT {customer_columns} FROM customers \
             WHERE stripe_customer_id = $1 AND status != 'deleted'"
    );
    sqlx::query_as::<_, Customer>(&sql)
        .bind(stripe_customer_id)
        .fetch_optional(pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
}

/// Check whether the quota warning marker has already been sent.
pub(super) async fn ingest_quota_warning_sent_for_month(
    pool: &PgPool,
    id: Uuid,
    metric: IngestQuotaWarningMetric,
    year: i32,
    month: u32,
) -> Result<bool, RepoError> {
    let customer = find_by_id(pool, id).await?;
    let Some(customer) = customer else {
        return Ok(false);
    };
    if customer.status == "deleted" {
        return Ok(false);
    }
    Ok(customer.ingest_quota_warning_sent_for_month(metric, year, month))
}
