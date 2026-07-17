use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use sqlx::PgPool;
use uuid::Uuid;

use crate::repos::error::RepoError;

pub(super) async fn set_stripe_customer_id(
    pool: &PgPool,
    id: Uuid,
    stripe_customer_id: &str,
) -> Result<bool, RepoError> {
    let result = sqlx::query(
        "UPDATE customers SET stripe_customer_id = $2, updated_at = NOW() \
             WHERE id = $1 AND status != 'deleted'",
    )
    .bind(id)
    .bind(stripe_customer_id)
    .execute(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    Ok(result.rows_affected() > 0)
}

pub(super) async fn set_subscription_cycle_anchor(
    pool: &PgPool,
    id: Uuid,
    anchor_at: Option<DateTime<Utc>>,
) -> Result<bool, RepoError> {
    let result = sqlx::query(
        "UPDATE customers SET subscription_cycle_anchor_at = $2, updated_at = NOW() \
             WHERE id = $1 AND status != 'deleted'",
    )
    .bind(id)
    .bind(anchor_at)
    .execute(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    Ok(result.rows_affected() > 0)
}

pub(super) async fn try_upgrade_to_shared_atomic(
    pool: &PgPool,
    id: Uuid,
    subscription_cycle_anchor_at: DateTime<Utc>,
) -> Result<bool, RepoError> {
    let upgraded_customer_id = sqlx::query_scalar::<_, Uuid>(
        "UPDATE customers \
             SET billing_plan = 'shared', subscription_cycle_anchor_at = $2, updated_at = NOW() \
             WHERE id = $1 AND billing_plan = 'free' AND status != 'deleted' \
             RETURNING id",
    )
    .bind(id)
    .bind(subscription_cycle_anchor_at)
    .fetch_optional(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    Ok(upgraded_customer_id.is_some())
}

pub(super) async fn rollback_upgrade_to_free_atomic(
    pool: &PgPool,
    id: Uuid,
    expected_subscription_cycle_anchor_at: DateTime<Utc>,
) -> Result<bool, RepoError> {
    let rolled_back_customer_id = sqlx::query_scalar::<_, Uuid>(
        "UPDATE customers \
             SET billing_plan = 'free', subscription_cycle_anchor_at = NULL, updated_at = NOW() \
             WHERE id = $1 \
               AND billing_plan = 'shared' \
               AND (subscription_cycle_anchor_at = $2 OR subscription_cycle_anchor_at IS NULL) \
               AND status != 'deleted' \
             RETURNING id",
    )
    .bind(id)
    .bind(expected_subscription_cycle_anchor_at)
    .fetch_optional(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    Ok(rolled_back_customer_id.is_some())
}

pub(super) async fn set_billing_plan(
    pool: &PgPool,
    id: Uuid,
    plan: &str,
) -> Result<bool, RepoError> {
    let result = sqlx::query(
        "UPDATE customers SET billing_plan = $2, updated_at = NOW() \
             WHERE id = $1 AND status != 'deleted'",
    )
    .bind(id)
    .bind(plan)
    .execute(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    Ok(result.rows_affected() > 0)
}

pub(super) async fn suspend(pool: &PgPool, id: Uuid) -> Result<bool, RepoError> {
    let result = sqlx::query(
        "UPDATE customers SET status = 'suspended', updated_at = NOW() \
             WHERE id = $1 AND status = 'active'",
    )
    .bind(id)
    .execute(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    Ok(result.rows_affected() > 0)
}

pub(super) async fn reactivate(pool: &PgPool, id: Uuid) -> Result<bool, RepoError> {
    let mut tx = pool
        .begin()
        .await
        .map_err(|error| RepoError::Other(error.to_string()))?;
    let Some(status) = super::lifecycle::lock_customer_status(&mut tx, id).await? else {
        return Ok(false);
    };
    if status != "suspended" {
        return Ok(false);
    }
    super::lifecycle::lock_algolia_import_jobs(&mut tx, id).await?;
    let result = sqlx::query(
        "UPDATE customers SET status = 'active', updated_at = NOW() \
             WHERE id = $1 AND status = 'suspended'",
    )
    .bind(id)
    .execute(&mut *tx)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;
    tx.commit()
        .await
        .map_err(|error| RepoError::Other(error.to_string()))?;
    Ok(result.rows_affected() > 0)
}

pub(super) async fn set_object_storage_egress_carryforward_cents(
    pool: &PgPool,
    id: Uuid,
    cents: Decimal,
) -> Result<bool, RepoError> {
    let result = sqlx::query(
        "UPDATE customers SET object_storage_egress_carryforward_cents = $2, updated_at = NOW() \
             WHERE id = $1 AND status != 'deleted'",
    )
    .bind(id)
    .bind(cents)
    .execute(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    Ok(result.rows_affected() > 0)
}
