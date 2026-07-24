use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use crate::repos::customer_repo::{
    ResendPasswordResetOutcome, ResendPasswordResetReservation,
    RESEND_VERIFICATION_COOLDOWN_SECONDS,
};
use crate::repos::error::RepoError;

#[derive(sqlx::FromRow)]
struct PasswordResetResendCooldownStateRow {
    status: String,
    retry_after_seconds: Option<i64>,
}

#[derive(sqlx::FromRow)]
struct PasswordResetResendReservationRow {
    previous_password_reset_token: Option<String>,
    previous_password_reset_expires_at: Option<DateTime<Utc>>,
    previous_password_reset_sent_at: Option<DateTime<Utc>>,
    reserved_password_reset_sent_at: DateTime<Utc>,
}

pub(super) async fn set_password_reset_token(
    pool: &PgPool,
    id: Uuid,
    token: &str,
    expires_at: DateTime<Utc>,
) -> Result<bool, RepoError> {
    let result = sqlx::query(
        "UPDATE customers SET \
                password_reset_token = $2, \
                password_reset_expires_at = $3, \
                updated_at = NOW() \
             WHERE id = $1 AND status != 'deleted'",
    )
    .bind(id)
    .bind(token)
    .bind(expires_at)
    .execute(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    Ok(result.rows_affected() > 0)
}

pub(super) async fn restore_password_reset_state(
    pool: &PgPool,
    id: Uuid,
    token: Option<&str>,
    expires_at: Option<DateTime<Utc>>,
) -> Result<bool, RepoError> {
    let result = sqlx::query(
        "UPDATE customers SET \
                password_reset_token = $2, \
                password_reset_expires_at = $3, \
                updated_at = NOW() \
             WHERE id = $1 AND status != 'deleted'",
    )
    .bind(id)
    .bind(token)
    .bind(expires_at)
    .execute(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    Ok(result.rows_affected() > 0)
}

pub(super) async fn rotate_password_reset_token_with_resend_cooldown(
    pool: &PgPool,
    id: Uuid,
    token: &str,
    expires_at: DateTime<Utc>,
) -> Result<ResendPasswordResetOutcome, RepoError> {
    let reservation = sqlx::query_as::<_, PasswordResetResendReservationRow>(
        "WITH eligible AS ( \
            SELECT \
                password_reset_token, \
                password_reset_expires_at, \
                resend_password_reset_sent_at \
            FROM customers \
            WHERE id = $1 \
              AND status != 'deleted' \
              AND ( \
                    resend_password_reset_sent_at IS NULL \
                    OR resend_password_reset_sent_at <= NOW() - ($4::bigint * INTERVAL '1 second') \
              ) \
            FOR UPDATE \
         ), \
         updated AS ( \
            UPDATE customers SET \
                password_reset_token = $2, \
                password_reset_expires_at = $3, \
                resend_password_reset_sent_at = NOW(), \
                updated_at = NOW() \
            WHERE id = $1 \
              AND EXISTS (SELECT 1 FROM eligible) \
            RETURNING resend_password_reset_sent_at \
         ) \
         SELECT \
            eligible.password_reset_token AS previous_password_reset_token, \
            eligible.password_reset_expires_at AS previous_password_reset_expires_at, \
            eligible.resend_password_reset_sent_at AS previous_password_reset_sent_at, \
            updated.resend_password_reset_sent_at AS reserved_password_reset_sent_at \
         FROM eligible \
         INNER JOIN updated ON TRUE",
    )
    .bind(id)
    .bind(token)
    .bind(expires_at)
    .bind(RESEND_VERIFICATION_COOLDOWN_SECONDS)
    .fetch_optional(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    if let Some(reservation) = reservation {
        return Ok(ResendPasswordResetOutcome::Allowed {
            reservation: ResendPasswordResetReservation {
                previous_password_reset_token: reservation.previous_password_reset_token,
                previous_password_reset_expires_at: reservation.previous_password_reset_expires_at,
                previous_password_reset_sent_at: reservation.previous_password_reset_sent_at,
                reserved_password_reset_sent_at: reservation.reserved_password_reset_sent_at,
            },
        });
    }

    let cooldown_state = sqlx::query_as::<_, PasswordResetResendCooldownStateRow>(
        "SELECT \
            status, \
            CASE \
                WHEN resend_password_reset_sent_at IS NULL THEN NULL \
                WHEN resend_password_reset_sent_at + ($2::bigint * INTERVAL '1 second') <= NOW() THEN NULL \
                ELSE GREATEST( \
                    1, \
                    CEIL(EXTRACT(EPOCH FROM (resend_password_reset_sent_at + ($2::bigint * INTERVAL '1 second') - NOW())))::bigint \
                ) \
            END AS retry_after_seconds \
         FROM customers \
         WHERE id = $1",
    )
    .bind(id)
    .bind(RESEND_VERIFICATION_COOLDOWN_SECONDS)
    .fetch_optional(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    let Some(cooldown_state) = cooldown_state else {
        return Ok(ResendPasswordResetOutcome::CustomerNotFound);
    };

    if cooldown_state.status == "deleted" {
        return Ok(ResendPasswordResetOutcome::CustomerNotFound);
    }
    match cooldown_state.retry_after_seconds {
        Some(retry_after_seconds) if retry_after_seconds > 0 => {
            return Ok(ResendPasswordResetOutcome::CooldownActive {
                retry_after_seconds: retry_after_seconds as u64,
            });
        }
        _ => {}
    }

    Ok(ResendPasswordResetOutcome::CustomerNotFound)
}

pub(super) async fn rollback_password_reset_token_rotation(
    pool: &PgPool,
    id: Uuid,
    reserved_token: &str,
    reservation: &ResendPasswordResetReservation,
) -> Result<bool, RepoError> {
    let rollback_result = sqlx::query(
        "UPDATE customers SET \
            password_reset_token = $3, \
            password_reset_expires_at = $4, \
            resend_password_reset_sent_at = $5, \
            updated_at = NOW() \
         WHERE id = $1 \
           AND status != 'deleted' \
           AND password_reset_token = $2 \
           AND resend_password_reset_sent_at = $6",
    )
    .bind(id)
    .bind(reserved_token)
    .bind(reservation.previous_password_reset_token.as_deref())
    .bind(reservation.previous_password_reset_expires_at)
    .bind(reservation.previous_password_reset_sent_at)
    .bind(reservation.reserved_password_reset_sent_at)
    .execute(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    Ok(rollback_result.rows_affected() > 0)
}

pub(super) async fn reset_password(
    pool: &PgPool,
    token: &str,
    new_password_hash: &str,
) -> Result<bool, RepoError> {
    let result = sqlx::query(
        "UPDATE customers SET \
                password_hash = $2, \
                password_reset_token = NULL, \
                password_reset_expires_at = NULL, \
                updated_at = NOW() \
             WHERE password_reset_token = $1 \
               AND password_reset_expires_at > NOW() \
               AND status != 'deleted'",
    )
    .bind(token)
    .bind(new_password_hash)
    .execute(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    Ok(result.rows_affected() > 0)
}

pub(super) async fn change_password(
    pool: &PgPool,
    id: Uuid,
    new_password_hash: &str,
) -> Result<bool, RepoError> {
    let result = sqlx::query(
        "UPDATE customers SET password_hash = $2, updated_at = NOW() \
             WHERE id = $1 AND status != 'deleted'",
    )
    .bind(id)
    .bind(new_password_hash)
    .execute(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    Ok(result.rows_affected() > 0)
}
