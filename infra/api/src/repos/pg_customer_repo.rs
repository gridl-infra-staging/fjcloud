use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::Customer;
use crate::repos::customer_repo::CustomerRepo;
use crate::repos::error::{is_unique_violation, RepoError};

// Compatibility projection for mixed local schemas:
// required identity columns are read directly, while newer optional fields
// are read through to_jsonb(customers)->>... so missing columns resolve to NULL
// instead of failing query compilation/execution on older local databases.
const CUSTOMER_COLUMNS: &str = "\
id, \
name, \
email, \
(to_jsonb(customers)->>'stripe_customer_id') AS stripe_customer_id, \
    customers.status, \
(to_jsonb(customers)->>'deleted_at')::timestamptz AS deleted_at, \
billing_plan, \
(to_jsonb(customers)->>'quota_warning_sent_at')::timestamptz AS quota_warning_sent_at, \
created_at, \
updated_at, \
(to_jsonb(customers)->>'password_hash') AS password_hash, \
(to_jsonb(customers)->>'email_verified_at')::timestamptz AS email_verified_at, \
(to_jsonb(customers)->>'email_verify_token') AS email_verify_token, \
(to_jsonb(customers)->>'email_verify_expires_at')::timestamptz AS email_verify_expires_at, \
(to_jsonb(customers)->>'password_reset_token') AS password_reset_token, \
(to_jsonb(customers)->>'password_reset_expires_at')::timestamptz AS password_reset_expires_at, \
COALESCE((to_jsonb(customers)->>'object_storage_egress_carryforward_cents')::numeric, 0) AS object_storage_egress_carryforward_cents";

pub struct PgCustomerRepo {
    pool: PgPool,
}

impl PgCustomerRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    fn list_customers_sql() -> String {
        format!(
            "SELECT {CUSTOMER_COLUMNS}, \
                    tenant_summary.last_accessed_at AS last_accessed_at, \
                    COALESCE(invoice_summary.overdue_invoice_count, 0) AS overdue_invoice_count \
             FROM customers \
             LEFT JOIN ( \
                SELECT customer_id, MAX(last_accessed_at) AS last_accessed_at \
                FROM customer_tenants \
                GROUP BY customer_id \
             ) AS tenant_summary ON tenant_summary.customer_id = customers.id \
             LEFT JOIN ( \
                SELECT customer_id, COUNT(*) AS overdue_invoice_count \
                FROM invoices \
                WHERE status = 'failed' \
                GROUP BY customer_id \
             ) AS invoice_summary ON invoice_summary.customer_id = customers.id \
             ORDER BY customers.created_at DESC"
        )
    }
}

#[cfg(test)]
#[allow(clippy::items_after_test_module)]
mod tests {
    use super::{PgCustomerRepo, CUSTOMER_COLUMNS};

    #[test]
    fn customer_columns_uses_schema_tolerant_carryforward_projection() {
        assert!(
            CUSTOMER_COLUMNS.contains(
                "to_jsonb(customers)->>'object_storage_egress_carryforward_cents'"
            ),
            "customer projection must not require the carryforward column to exist in older local schemas"
        );
    }

    #[test]
    fn customer_columns_uses_schema_tolerant_deleted_at_projection() {
        assert!(
            CUSTOMER_COLUMNS.contains("to_jsonb(customers)->>'deleted_at'"),
            "customer projection must not require deleted_at to exist in older local schemas"
        );
    }

    #[test]
    fn customer_columns_qualifies_status_for_joined_list_query() {
        assert!(
            CUSTOMER_COLUMNS.contains("customers.status"),
            "customer projection must qualify customers.status so the list join cannot hit ambiguous status resolution"
        );
    }

    #[test]
    fn list_sql_uses_shared_subscription_summary_join() {
        let sql = PgCustomerRepo::list_customers_sql();
        assert!(
            !sql.contains("subscriptions"),
            "customer list query must not read subscriptions after subscription seam removal"
        );
    }
}

#[async_trait]
impl CustomerRepo for PgCustomerRepo {
    async fn list(&self) -> Result<Vec<Customer>, RepoError> {
        let sql = Self::list_customers_sql();
        sqlx::query_as::<_, Customer>(&sql)
            .fetch_all(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn find_by_id(&self, id: Uuid) -> Result<Option<Customer>, RepoError> {
        let sql = format!("SELECT {CUSTOMER_COLUMNS} FROM customers WHERE id = $1");
        sqlx::query_as::<_, Customer>(&sql)
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn find_by_email(&self, email: &str) -> Result<Option<Customer>, RepoError> {
        let sql = format!("SELECT {CUSTOMER_COLUMNS} FROM customers WHERE email = $1");
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
        let sql = format!(
            "SELECT * FROM ( \
                SELECT {CUSTOMER_COLUMNS} FROM customers \
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

    async fn find_by_reset_token(&self, token: &str) -> Result<Option<Customer>, RepoError> {
        let sql = format!(
            "SELECT {CUSTOMER_COLUMNS} FROM customers \
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
        let sql = format!(
            "SELECT {CUSTOMER_COLUMNS} FROM customers \
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
}
