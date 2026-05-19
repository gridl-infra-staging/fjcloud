use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::{Customer, IngestQuotaWarningMetric};
use crate::repos::customer_repo::{
    CustomerRepo, ResendPasswordResetOutcome, ResendPasswordResetReservation,
    ResendVerificationOutcome, ResendVerificationReservation, RESEND_VERIFICATION_COOLDOWN_SECONDS,
};
use crate::repos::error::{is_unique_violation, RepoError};
use crate::repos::pg_customer_repo_columns::{customer_columns, list_customers_sql};
use crate::repos::pg_customer_repo_password_reset_resend::{
    rollback_password_reset_token_rotation as rollback_password_reset_token_rotation_sql,
    rotate_password_reset_token_with_resend_cooldown as rotate_password_reset_token_with_resend_cooldown_sql,
};
use crate::repos::pg_customer_repo_quota_warning::{
    claim_ingest_quota_warning_for_month as claim_ingest_quota_warning_for_month_sql,
    rollback_ingest_quota_warning_for_month as rollback_ingest_quota_warning_for_month_sql,
};
pub struct PgCustomerRepo {
    pool: PgPool,
}

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

impl PgCustomerRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl CustomerRepo for PgCustomerRepo {
    async fn list(&self) -> Result<Vec<Customer>, RepoError> {
        let sql = list_customers_sql();
        sqlx::query_as::<_, Customer>(&sql)
            .fetch_all(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn find_by_id(&self, id: Uuid) -> Result<Option<Customer>, RepoError> {
        let customer_columns = customer_columns();
        let sql = format!("SELECT {customer_columns} FROM customers WHERE id = $1");
        sqlx::query_as::<_, Customer>(&sql)
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn find_by_email(&self, email: &str) -> Result<Option<Customer>, RepoError> {
        let customer_columns = customer_columns();
        let sql = format!("SELECT {customer_columns} FROM customers WHERE email = $1");
        sqlx::query_as::<_, Customer>(&sql)
            .bind(email)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn list_deleted_before_cutoff(
        &self,
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
            .fetch_all(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// Inserts a customer (name, email) then re-fetches by email. Unique
    /// violation on email returns `Conflict`.
    async fn create(&self, name: &str, email: &str) -> Result<Customer, RepoError> {
        sqlx::query("INSERT INTO customers (name, email) VALUES ($1, $2)")
            .bind(name)
            .bind(email)
            .execute(&self.pool)
            .await
            .map_err(|e| {
                if is_unique_violation(&e) {
                    RepoError::Conflict("email already exists".into())
                } else {
                    RepoError::Other(e.to_string())
                }
            })?;

        self.find_by_email(email)
            .await?
            .ok_or_else(|| RepoError::Other("created customer could not be reloaded".into()))
    }

    /// Inserts a customer (name, email) then re-fetches by email. Unique
    /// violation on email returns `Conflict`.with_password.
    async fn create_with_password(
        &self,
        name: &str,
        email: &str,
        password_hash: &str,
    ) -> Result<Customer, RepoError> {
        sqlx::query("INSERT INTO customers (name, email, password_hash) VALUES ($1, $2, $3)")
            .bind(name)
            .bind(email)
            .bind(password_hash)
            .execute(&self.pool)
            .await
            .map_err(|e| {
                if is_unique_violation(&e) {
                    RepoError::Conflict("email already exists".into())
                } else {
                    RepoError::Other(e.to_string())
                }
            })?;

        self.find_by_email(email)
            .await?
            .ok_or_else(|| RepoError::Other("created customer could not be reloaded".into()))
    }

    async fn find_oauth_identity(
        &self,
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
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn create_oauth_customer(&self, name: &str, email: &str) -> Result<Customer, RepoError> {
        self.create(name, email).await
    }

    async fn link_oauth_identity(
        &self,
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
        .execute(&self.pool)
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

    /// COALESCE-based partial update for name and/or email. Skips soft-deleted
    /// rows. Unique violation on email returns `Conflict`.
    async fn update(
        &self,
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
        .execute(&self.pool)
        .await
        .map_err(|e| {
            if is_unique_violation(&e) {
                RepoError::Conflict("email already exists".into())
            } else {
                RepoError::Other(e.to_string())
            }
        })?;

        if result.rows_affected() == 0 {
            return Ok(None);
        }

        self.find_by_id(id).await
    }

    async fn soft_delete(&self, id: Uuid) -> Result<bool, RepoError> {
        let result = sqlx::query(
            "UPDATE customers SET status = 'deleted', deleted_at = NOW(), updated_at = NOW() \
             WHERE id = $1 AND status != 'deleted'",
        )
        .bind(id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(result.rows_affected() > 0)
    }

    async fn hard_delete(&self, id: Uuid) -> Result<bool, RepoError> {
        // Run the entire cleanup chain in a single transaction so a failure
        // partway through leaves the customer recoverable, rather than
        // partially-erased with dangling dependent rows.
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| RepoError::Other(e.to_string()))?;

        // Guard: refuse hard-erase while any non-final invoice still
        // references this customer. Open billing state must be wound down
        // before erasure so we don't silently drop money owed or pending
        // refund obligations.
        let open_invoice_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*)::BIGINT FROM invoices \
             WHERE customer_id = $1 AND status NOT IN ('paid', 'refunded')",
        )
        .bind(id)
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;
        if open_invoice_count > 0 {
            return Err(RepoError::Conflict(
                "customer has open invoices; close or refund before hard-erase".into(),
            ));
        }

        // Order matters: cleanup tables that themselves reference other
        // dependents before cleaning those dependents.
        //   * `index_replicas` has a composite FK to
        //     `customer_tenants(customer_id, tenant_id)`, so it must be
        //     removed BEFORE `customer_tenants`.
        //   * `customer_tenants.deployment_id` references
        //     `customer_deployments(id)`, so `customer_tenants` must be
        //     removed BEFORE `customer_deployments`.
        //   * `invoice_line_items` cascades from `invoices`, so deleting
        //     invoices is enough (handled below, last).
        //   * `oauth_identities` cascades from `customers`, so the final
        //     customer DELETE handles that.
        //
        // Each step is intentionally listed by table so tests can fail on
        // a missed dependent rather than relying on a generic loop.
        let cleanup_statements: [&str; 11] = [
            "DELETE FROM api_keys                  WHERE customer_id = $1",
            "DELETE FROM index_replicas            WHERE customer_id = $1",
            "DELETE FROM restore_jobs              WHERE customer_id = $1",
            "DELETE FROM cold_snapshots            WHERE customer_id = $1",
            "DELETE FROM storage_access_keys       WHERE customer_id = $1",
            "DELETE FROM storage_buckets           WHERE customer_id = $1",
            "DELETE FROM customer_tenants          WHERE customer_id = $1",
            "DELETE FROM customer_deployments      WHERE customer_id = $1",
            "DELETE FROM customer_rate_overrides   WHERE customer_id = $1",
            "DELETE FROM usage_records             WHERE customer_id = $1",
            "DELETE FROM usage_daily               WHERE customer_id = $1",
        ];
        for stmt in cleanup_statements {
            sqlx::query(stmt)
                .bind(id)
                .execute(&mut *tx)
                .await
                .map_err(|e| RepoError::Other(e.to_string()))?;
        }

        // Invoices are deleted last among dependents so any FK error
        // surfaces on the table that owns the violation rather than on
        // invoices, which usually has the largest row count.
        sqlx::query("DELETE FROM invoices WHERE customer_id = $1")
            .bind(id)
            .execute(&mut *tx)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))?;

        // `audit_log.target_tenant_id` has no FK to customers (see
        // migrations/041_audit_log.sql — actor/target are intentionally
        // FK-less so the audit trail survives row deletion). We still
        // erase past audit rows here because GDPR hard-erasure must
        // remove all PII references to this customer, including any
        // metadata embedded in audit JSON. The new hard-erase row is
        // written by the caller AFTER hard_delete returns, so it is not
        // affected.
        sqlx::query("DELETE FROM audit_log WHERE target_tenant_id = $1")
            .bind(id)
            .execute(&mut *tx)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))?;

        let result = sqlx::query("DELETE FROM customers WHERE id = $1")
            .bind(id)
            .execute(&mut *tx)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))?;

        tx.commit()
            .await
            .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(result.rows_affected() > 0)
    }

    /// Stores the email verification token and its expiry timestamp.
    /// Skips soft-deleted customers.
    async fn set_email_verify_token(
        &self,
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
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(result.rows_affected() > 0)
    }

    async fn rotate_email_verification_token_with_resend_cooldown(
        &self,
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
        .fetch_optional(&self.pool)
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
        .fetch_optional(&self.pool)
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
        if let Some(retry_after_seconds) = cooldown_state.retry_after_seconds {
            if retry_after_seconds > 0 {
                return Ok(ResendVerificationOutcome::CooldownActive {
                    retry_after_seconds: retry_after_seconds as u64,
                });
            }
        }

        Ok(ResendVerificationOutcome::CustomerNotFound)
    }

    async fn rollback_resend_verification_token_rotation(
        &self,
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
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(rollback_result.rows_affected() > 0)
    }

    /// Looks up a non-expired verification token, sets email_verified_at,
    /// and clears the token fields. Returns the updated customer or None.
    async fn verify_email(&self, token: &str) -> Result<Option<Customer>, RepoError> {
        let customer_id = sqlx::query_scalar::<_, Uuid>(
            "SELECT id FROM customers \
             WHERE email_verify_token = $1 \
               AND email_verify_expires_at > NOW() \
               AND status != 'deleted'",
        )
        .bind(token)
        .fetch_optional(&self.pool)
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
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Ok(None);
        }

        self.find_by_id(customer_id).await
    }

    /// Stores the password-reset token and its expiry timestamp.
    /// Skips soft-deleted customers.
    async fn set_password_reset_token(
        &self,
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
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(result.rows_affected() > 0)
    }

    async fn restore_password_reset_state(
        &self,
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
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(result.rows_affected() > 0)
    }

    async fn rotate_password_reset_token_with_resend_cooldown(
        &self,
        id: Uuid,
        token: &str,
        expires_at: DateTime<Utc>,
    ) -> Result<ResendPasswordResetOutcome, RepoError> {
        rotate_password_reset_token_with_resend_cooldown_sql(&self.pool, id, token, expires_at)
            .await
    }

    async fn rollback_password_reset_token_rotation(
        &self,
        id: Uuid,
        reserved_token: &str,
        reservation: &ResendPasswordResetReservation,
    ) -> Result<bool, RepoError> {
        rollback_password_reset_token_rotation_sql(&self.pool, id, reserved_token, reservation)
            .await
    }

    async fn find_by_reset_token(&self, token: &str) -> Result<Option<Customer>, RepoError> {
        let customer_columns = customer_columns();
        let sql = format!(
            "SELECT {customer_columns} FROM customers \
             WHERE password_reset_token = $1 \
               AND password_reset_expires_at > NOW() \
               AND status != 'deleted'"
        );
        sqlx::query_as::<_, Customer>(&sql)
            .bind(token)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// Validates a non-expired reset token, updates password_hash, and
    /// clears the token fields. Returns false if the token is invalid
    /// or expired.
    async fn reset_password(
        &self,
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
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(result.rows_affected() > 0)
    }

    /// Links the customer to a Stripe customer ID. Skips soft-deleted rows.
    async fn set_stripe_customer_id(
        &self,
        id: Uuid,
        stripe_customer_id: &str,
    ) -> Result<bool, RepoError> {
        let result = sqlx::query(
            "UPDATE customers SET stripe_customer_id = $2, updated_at = NOW() \
             WHERE id = $1 AND status != 'deleted'",
        )
        .bind(id)
        .bind(stripe_customer_id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(result.rows_affected() > 0)
    }

    async fn find_by_stripe_customer_id(
        &self,
        stripe_customer_id: &str,
    ) -> Result<Option<Customer>, RepoError> {
        let customer_columns = customer_columns();
        let sql = format!(
            "SELECT {customer_columns} FROM customers \
             WHERE stripe_customer_id = $1 AND status != 'deleted'"
        );
        sqlx::query_as::<_, Customer>(&sql)
            .bind(stripe_customer_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// Records when the usage-quota warning email was sent. Skips
    /// soft-deleted rows.
    async fn set_quota_warning_sent_at(
        &self,
        id: Uuid,
        sent_at: DateTime<Utc>,
    ) -> Result<bool, RepoError> {
        let result = sqlx::query(
            "UPDATE customers SET quota_warning_sent_at = $2, updated_at = NOW() \
             WHERE id = $1 AND status != 'deleted'",
        )
        .bind(id)
        .bind(sent_at)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(result.rows_affected() > 0)
    }

    async fn ingest_quota_warning_sent_for_month(
        &self,
        id: Uuid,
        metric: IngestQuotaWarningMetric,
        year: i32,
        month: u32,
    ) -> Result<bool, RepoError> {
        let customer = self.find_by_id(id).await?;
        let Some(customer) = customer else {
            return Ok(false);
        };
        if customer.status == "deleted" {
            return Ok(false);
        }
        Ok(customer.ingest_quota_warning_sent_for_month(metric, year, month))
    }

    async fn claim_ingest_quota_warning_for_month(
        &self,
        id: Uuid,
        metric: IngestQuotaWarningMetric,
        year: i32,
        month: u32,
    ) -> Result<bool, RepoError> {
        claim_ingest_quota_warning_for_month_sql(&self.pool, id, metric, year, month).await
    }

    async fn rollback_ingest_quota_warning_for_month(
        &self,
        id: Uuid,
        metric: IngestQuotaWarningMetric,
        year: i32,
        month: u32,
    ) -> Result<bool, RepoError> {
        rollback_ingest_quota_warning_for_month_sql(&self.pool, id, metric, year, month).await
    }

    async fn change_password(&self, id: Uuid, new_password_hash: &str) -> Result<bool, RepoError> {
        let result = sqlx::query(
            "UPDATE customers SET password_hash = $2, updated_at = NOW() \
             WHERE id = $1 AND status != 'deleted'",
        )
        .bind(id)
        .bind(new_password_hash)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(result.rows_affected() > 0)
    }

    async fn set_subscription_cycle_anchor(
        &self,
        id: Uuid,
        anchor_at: Option<DateTime<Utc>>,
    ) -> Result<bool, RepoError> {
        let result = sqlx::query(
            "UPDATE customers SET subscription_cycle_anchor_at = $2, updated_at = NOW() \
             WHERE id = $1 AND status != 'deleted'",
        )
        .bind(id)
        .bind(anchor_at)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(result.rows_affected() > 0)
    }

    async fn try_upgrade_to_shared_atomic(
        &self,
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
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(upgraded_customer_id.is_some())
    }

    async fn rollback_upgrade_to_free_atomic(
        &self,
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
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(rolled_back_customer_id.is_some())
    }

    async fn set_billing_plan(&self, id: Uuid, plan: &str) -> Result<bool, RepoError> {
        let result = sqlx::query(
            "UPDATE customers SET billing_plan = $2, updated_at = NOW() \
             WHERE id = $1 AND status != 'deleted'",
        )
        .bind(id)
        .bind(plan)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(result.rows_affected() > 0)
    }

    async fn suspend(&self, id: Uuid) -> Result<bool, RepoError> {
        let result = sqlx::query(
            "UPDATE customers SET status = 'suspended', updated_at = NOW() \
             WHERE id = $1 AND status = 'active'",
        )
        .bind(id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(result.rows_affected() > 0)
    }

    async fn reactivate(&self, id: Uuid) -> Result<bool, RepoError> {
        let result = sqlx::query(
            "UPDATE customers SET status = 'active', updated_at = NOW() \
             WHERE id = $1 AND status = 'suspended'",
        )
        .bind(id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(result.rows_affected() > 0)
    }

    /// Persists the sub-cent egress remainder for the next billing cycle.
    /// Skips soft-deleted rows.
    async fn set_object_storage_egress_carryforward_cents(
        &self,
        id: Uuid,
        cents: Decimal,
    ) -> Result<bool, RepoError> {
        let result = sqlx::query(
            "UPDATE customers SET object_storage_egress_carryforward_cents = $2, updated_at = NOW() \
             WHERE id = $1 AND status != 'deleted'",
        )
        .bind(id)
        .bind(cents)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(result.rows_affected() > 0)
    }

    async fn record_failed_login(&self, id: Uuid) -> Result<Option<i64>, RepoError> {
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
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        match row {
            Some((lockout_remaining,)) => Ok(lockout_remaining),
            None => Ok(None),
        }
    }

    async fn record_successful_login(&self, id: Uuid) -> Result<bool, RepoError> {
        let result = sqlx::query(
            "UPDATE customers SET \
                failed_login_count = 0, \
                failed_login_window_start = NULL, \
                login_locked_until = NULL, \
                updated_at = NOW() \
             WHERE id = $1 AND status != 'deleted'",
        )
        .bind(id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(result.rows_affected() > 0)
    }

    async fn login_lockout_remaining(&self, id: Uuid) -> Result<Option<i64>, RepoError> {
        let row: Option<(Option<i64>,)> = sqlx::query_as(
            "SELECT CASE \
                WHEN login_locked_until > NOW() \
                THEN CEIL(EXTRACT(EPOCH FROM (login_locked_until - NOW())))::bigint \
                ELSE NULL \
             END AS lockout_remaining \
             FROM customers WHERE id = $1 AND status != 'deleted'",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        match row {
            Some((lockout_remaining,)) => Ok(lockout_remaining),
            None => Ok(None),
        }
    }
}
