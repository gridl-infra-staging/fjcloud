use sqlx::PgPool;
use uuid::Uuid;

use crate::repos::error::RepoError;

pub(super) async fn record_failed_login(pool: &PgPool, id: Uuid) -> Result<Option<i64>, RepoError> {
    use crate::auth::lockout::{LOGIN_LOCK_DURATION, LOGIN_THRESHOLD, LOGIN_WINDOW};

    let window_seconds = LOGIN_WINDOW.num_seconds();
    let lock_seconds = LOGIN_LOCK_DURATION.num_seconds();
    let threshold = LOGIN_THRESHOLD as i32;

    let row: Option<(Option<i64>,)> = sqlx::query_as(
        "WITH updated AS (
                UPDATE customers SET
                    failed_login_count = CASE
                        WHEN login_locked_until > NOW() THEN failed_login_count
                        WHEN failed_login_window_start IS NULL
                             OR failed_login_window_start < NOW() - make_interval(secs => $2)
                        THEN 1
                        ELSE failed_login_count + 1
                    END,
                    failed_login_window_start = CASE
                        WHEN login_locked_until > NOW() THEN failed_login_window_start
                        WHEN failed_login_window_start IS NULL
                             OR failed_login_window_start < NOW() - make_interval(secs => $2)
                        THEN NOW()
                        ELSE failed_login_window_start
                    END,
                    login_locked_until = CASE
                        WHEN login_locked_until > NOW() THEN login_locked_until
                        WHEN (CASE
                                WHEN failed_login_window_start IS NULL
                                     OR failed_login_window_start < NOW() - make_interval(secs => $2)
                                THEN 1
                                ELSE failed_login_count + 1
                              END) >= $3
                        THEN NOW() + make_interval(secs => $4)
                        ELSE login_locked_until
                    END,
                    updated_at = NOW()
                WHERE id = $1 AND status != 'deleted'
                RETURNING login_locked_until
            )
            SELECT CASE
                WHEN login_locked_until > NOW()
                THEN CEIL(EXTRACT(EPOCH FROM (login_locked_until - NOW())))::bigint
                ELSE NULL
            END AS lockout_remaining
            FROM updated",
    )
    .bind(id)
    .bind(window_seconds as f64)
    .bind(threshold)
    .bind(lock_seconds as f64)
    .fetch_optional(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    Ok(row.and_then(|(lockout_remaining,)| lockout_remaining))
}

pub(super) async fn record_successful_login(pool: &PgPool, id: Uuid) -> Result<bool, RepoError> {
    let result = sqlx::query(
        "UPDATE customers SET \
                failed_login_count = 0, \
                failed_login_window_start = NULL, \
                login_locked_until = NULL, \
                updated_at = NOW() \
             WHERE id = $1 AND status != 'deleted'",
    )
    .bind(id)
    .execute(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    Ok(result.rows_affected() > 0)
}

pub(super) async fn login_lockout_remaining(
    pool: &PgPool,
    id: Uuid,
) -> Result<Option<i64>, RepoError> {
    let row: Option<(Option<i64>,)> = sqlx::query_as(
        "SELECT CASE \
                WHEN login_locked_until > NOW() \
                THEN CEIL(EXTRACT(EPOCH FROM (login_locked_until - NOW())))::bigint \
                ELSE NULL \
             END AS lockout_remaining \
             FROM customers WHERE id = $1 AND status != 'deleted'",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    Ok(row.and_then(|(lockout_remaining,)| lockout_remaining))
}
