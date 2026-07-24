use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

use crate::models::Customer;
use crate::repos::error::{is_unique_violation, RepoError};
use crate::repos::pg_customer_repo::queries;

pub(super) async fn lock_customer_status(
    tx: &mut Transaction<'_, Postgres>,
    id: Uuid,
) -> Result<Option<String>, RepoError> {
    sqlx::query_scalar("SELECT status FROM customers WHERE id = $1 FOR UPDATE")
        .bind(id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(|error| RepoError::Other(error.to_string()))
}

pub(super) async fn lock_algolia_import_jobs(
    tx: &mut Transaction<'_, Postgres>,
    customer_id: Uuid,
) -> Result<(), RepoError> {
    sqlx::query_scalar::<_, Uuid>(
        "SELECT id FROM algolia_import_jobs WHERE customer_id = $1 ORDER BY id FOR UPDATE",
    )
    .bind(customer_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(|error| RepoError::Other(error.to_string()))?;
    Ok(())
}

fn email_conflict_or_other(error: sqlx::Error) -> RepoError {
    if is_unique_violation(&error) {
        RepoError::Conflict("email already exists".into())
    } else {
        RepoError::Other(error.to_string())
    }
}

async fn reload_created_customer(pool: &PgPool, email: &str) -> Result<Customer, RepoError> {
    queries::find_by_email(pool, email)
        .await?
        .ok_or_else(|| RepoError::Other("created customer could not be reloaded".into()))
}

pub(super) async fn create(pool: &PgPool, name: &str, email: &str) -> Result<Customer, RepoError> {
    sqlx::query("INSERT INTO customers (name, email) VALUES ($1, $2)")
        .bind(name)
        .bind(email)
        .execute(pool)
        .await
        .map_err(email_conflict_or_other)?;

    reload_created_customer(pool, email).await
}

pub(super) async fn create_with_password(
    pool: &PgPool,
    name: &str,
    email: &str,
    password_hash: &str,
) -> Result<Customer, RepoError> {
    sqlx::query("INSERT INTO customers (name, email, password_hash) VALUES ($1, $2, $3)")
        .bind(name)
        .bind(email)
        .bind(password_hash)
        .execute(pool)
        .await
        .map_err(email_conflict_or_other)?;

    reload_created_customer(pool, email).await
}

pub(super) async fn link_oauth_identity(
    pool: &PgPool,
    customer_id: Uuid,
    provider: &str,
    provider_user_id: &str,
) -> Result<(), RepoError> {
    let insert_result = sqlx::query(
        "INSERT INTO oauth_identities (customer_id, provider, provider_user_id) \
             SELECT id, $2, $3 \
             FROM customers \
             WHERE id = $1 AND status != 'deleted'",
    )
    .bind(customer_id)
    .bind(provider)
    .bind(provider_user_id)
    .execute(pool)
    .await
    .map_err(|e| {
        if is_unique_violation(&e) {
            RepoError::Conflict("oauth identity already linked".into())
        } else {
            RepoError::Other(e.to_string())
        }
    })?;

    if insert_result.rows_affected() == 0 {
        return Err(RepoError::NotFound);
    }

    Ok(())
}

pub(super) async fn update(
    pool: &PgPool,
    id: Uuid,
    name: Option<&str>,
    email: Option<&str>,
) -> Result<Option<Customer>, RepoError> {
    let result = sqlx::query(
        "UPDATE customers SET \
                name = COALESCE($2, name), \
                email = COALESCE($3, email), \
                updated_at = NOW() \
             WHERE id = $1 AND status != 'deleted'",
    )
    .bind(id)
    .bind(name)
    .bind(email)
    .execute(pool)
    .await
    .map_err(email_conflict_or_other)?;

    if result.rows_affected() == 0 {
        return Ok(None);
    }

    queries::find_by_id(pool, id).await
}

pub(super) async fn soft_delete(pool: &PgPool, id: Uuid) -> Result<bool, RepoError> {
    let mut tx = pool
        .begin()
        .await
        .map_err(|error| RepoError::Other(error.to_string()))?;
    let Some(status) = lock_customer_status(&mut tx, id).await? else {
        tx.rollback()
            .await
            .map_err(|error| RepoError::Other(error.to_string()))?;
        return Ok(false);
    };
    if status == "deleted" {
        tx.rollback()
            .await
            .map_err(|error| RepoError::Other(error.to_string()))?;
        return Ok(false);
    }
    lock_algolia_import_jobs(&mut tx, id).await?;
    let result = sqlx::query(
        "UPDATE customers SET status = 'deleted', deleted_at = NOW(), updated_at = NOW(), \
                lifecycle_generation = lifecycle_generation + 1 \
             WHERE id = $1 AND status != 'deleted'",
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
