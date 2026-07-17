use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::Customer;
use crate::repos::customer_repo::{
    ResendVerificationOutcome, ResendVerificationReservation, RESEND_VERIFICATION_COOLDOWN_SECONDS,
};
use crate::repos::error::RepoError;
use crate::repos::pg_customer_repo::queries;

#[derive(sqlx::FromRow)]
struct ResendCooldownStateRow {
    status: String,
    email_verified_at: Option<DateTime<Utc>>,
    retry_after_seconds: Option<i64>,
}

#[derive(sqlx::FromRow)]
struct ResendReservationRow {
    previous_email_verify_token: Option<String>,
    previous_email_verify_expires_at: Option<DateTime<Utc>>,
    previous_resend_verification_sent_at: Option<DateTime<Utc>>,
    reserved_resend_verification_sent_at: DateTime<Utc>,
}

pub(super) async fn set_email_verify_token(
    pool: &PgPool,
    id: Uuid,
    token: &str,
    expires_at: DateTime<Utc>,
) -> Result<bool, RepoError> {
    let result = sqlx::query(
        "UPDATE customers SET \
                email_verify_token = $2, \
                email_verify_expires_at = $3, \
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

pub(super) async fn rotate_email_verification_token_with_resend_cooldown(
    pool: &PgPool,
    id: Uuid,
    token: &str,
    expires_at: DateTime<Utc>,
) -> Result<ResendVerificationOutcome, RepoError> {
    let reservation = sqlx::query_as::<_, ResendReservationRow>(
        "WITH eligible AS ( \
                SELECT \
                    email_verify_token, \
                    email_verify_expires_at, \
                    resend_verification_sent_at \
                FROM customers \
                WHERE id = $1 \
                  AND status != 'deleted' \
                  AND email_verified_at IS NULL \
                  AND ( \
                        resend_verification_sent_at IS NULL \
                        OR resend_verification_sent_at <= NOW() - ($4::bigint * INTERVAL '1 second') \
                  ) \
                FOR UPDATE \
             ), \
             updated AS ( \
                UPDATE customers SET \
                    email_verify_token = $2, \
                    email_verify_expires_at = $3, \
                    resend_verification_sent_at = NOW(), \
                    updated_at = NOW() \
                WHERE id = $1 \
                  AND EXISTS (SELECT 1 FROM eligible) \
                RETURNING resend_verification_sent_at \
             ) \
             SELECT \
                eligible.email_verify_token AS previous_email_verify_token, \
                eligible.email_verify_expires_at AS previous_email_verify_expires_at, \
                eligible.resend_verification_sent_at AS previous_resend_verification_sent_at, \
                updated.resend_verification_sent_at AS reserved_resend_verification_sent_at \
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
        return Ok(ResendVerificationOutcome::Allowed {
            reservation: ResendVerificationReservation {
                previous_email_verify_token: reservation.previous_email_verify_token,
                previous_email_verify_expires_at: reservation.previous_email_verify_expires_at,
                previous_resend_verification_sent_at: reservation
                    .previous_resend_verification_sent_at,
                reserved_resend_verification_sent_at: reservation
                    .reserved_resend_verification_sent_at,
            },
        });
    }

    let cooldown_state = sqlx::query_as::<_, ResendCooldownStateRow>(
        "SELECT \
                status, \
                email_verified_at, \
                CASE \
                    WHEN resend_verification_sent_at IS NULL THEN NULL \
                    WHEN resend_verification_sent_at + ($2::bigint * INTERVAL '1 second') <= NOW() THEN NULL \
                    ELSE GREATEST( \
                        1, \
                        CEIL(EXTRACT(EPOCH FROM (resend_verification_sent_at + ($2::bigint * INTERVAL '1 second') - NOW())))::bigint \
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
        return Ok(ResendVerificationOutcome::CustomerNotFound);
    };

    if cooldown_state.status == "deleted" {
        return Ok(ResendVerificationOutcome::CustomerNotFound);
    }
    if cooldown_state.email_verified_at.is_some() {
        return Ok(ResendVerificationOutcome::AlreadyVerified);
    }
    match cooldown_state.retry_after_seconds {
        Some(retry_after_seconds) if retry_after_seconds > 0 => {
            return Ok(ResendVerificationOutcome::CooldownActive {
                retry_after_seconds: retry_after_seconds as u64,
            });
        }
        _ => {}
    }

    Ok(ResendVerificationOutcome::CustomerNotFound)
}

pub(super) async fn rollback_resend_verification_token_rotation(
    pool: &PgPool,
    id: Uuid,
    reserved_token: &str,
    reservation: &ResendVerificationReservation,
) -> Result<bool, RepoError> {
    let rollback_result = sqlx::query(
        "UPDATE customers SET \
                email_verify_token = $3, \
                email_verify_expires_at = $4, \
                resend_verification_sent_at = $5, \
                updated_at = NOW() \
             WHERE id = $1 \
               AND status != 'deleted' \
               AND email_verified_at IS NULL \
               AND email_verify_token = $2 \
               AND resend_verification_sent_at = $6",
    )
    .bind(id)
    .bind(reserved_token)
    .bind(reservation.previous_email_verify_token.as_deref())
    .bind(reservation.previous_email_verify_expires_at)
    .bind(reservation.previous_resend_verification_sent_at)
    .bind(reservation.reserved_resend_verification_sent_at)
    .execute(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    Ok(rollback_result.rows_affected() > 0)
}

pub(super) async fn verify_email(
    pool: &PgPool,
    token: &str,
) -> Result<Option<Customer>, RepoError> {
    let customer_id = sqlx::query_scalar::<_, Uuid>(
        "SELECT id FROM customers \
             WHERE email_verify_token = $1 \
               AND email_verify_expires_at > NOW() \
               AND status != 'deleted'",
    )
    .bind(token)
    .fetch_optional(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    let Some(customer_id) = customer_id else {
        return Ok(None);
    };

    let result = sqlx::query(
        "UPDATE customers SET \
                email_verified_at = NOW(), \
                email_verify_token = NULL, \
                email_verify_expires_at = NULL, \
                updated_at = NOW() \
             WHERE id = $1 AND status != 'deleted'",
    )
    .bind(customer_id)
    .execute(pool)
    .await
    .map_err(|e| RepoError::Other(e.to_string()))?;

    if result.rows_affected() == 0 {
        return Ok(None);
    }

    queries::find_by_id(pool, customer_id).await
}
