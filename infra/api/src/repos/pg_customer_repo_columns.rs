use crate::repos::pg_customer_repo_quota_warning::QUOTA_WARNINGS_SENT_PROJECTION;

// Compatibility projection for mixed local schemas:
// required identity columns are read directly, while newer optional fields
// are read through to_jsonb(customers)->>... so missing columns resolve to NULL
// instead of failing query compilation/execution on older local databases.
pub(super) fn customer_columns() -> String {
    format!(
        "\
customers.id, \
name, \
email, \
(to_jsonb(customers)->>'stripe_customer_id') AS stripe_customer_id, \
    customers.status, \
(to_jsonb(customers)->>'deleted_at')::timestamptz AS deleted_at, \
billing_plan, \
(to_jsonb(customers)->>'subscription_cycle_anchor_at')::timestamptz AS subscription_cycle_anchor_at, \
(to_jsonb(customers)->>'quota_warning_sent_at')::timestamptz AS quota_warning_sent_at, \
{QUOTA_WARNINGS_SENT_PROJECTION}, \
created_at, \
updated_at, \
(to_jsonb(customers)->>'password_hash') AS password_hash, \
(to_jsonb(customers)->>'email_verified_at')::timestamptz AS email_verified_at, \
(to_jsonb(customers)->>'email_verify_token') AS email_verify_token, \
(to_jsonb(customers)->>'email_verify_expires_at')::timestamptz AS email_verify_expires_at, \
(to_jsonb(customers)->>'resend_verification_sent_at')::timestamptz AS resend_verification_sent_at, \
(to_jsonb(customers)->>'password_reset_token') AS password_reset_token, \
(to_jsonb(customers)->>'password_reset_expires_at')::timestamptz AS password_reset_expires_at, \
COALESCE((to_jsonb(customers)->>'object_storage_egress_carryforward_cents')::numeric, 0) AS object_storage_egress_carryforward_cents, \
COALESCE((to_jsonb(customers)->>'failed_login_count')::int, 0) AS failed_login_count, \
(to_jsonb(customers)->>'failed_login_window_start')::timestamptz AS failed_login_window_start, \
(to_jsonb(customers)->>'login_locked_until')::timestamptz AS login_locked_until, \
COALESCE((to_jsonb(customers)->>'failed_verify_count')::int, 0) AS failed_verify_count, \
(to_jsonb(customers)->>'failed_verify_window_start')::timestamptz AS failed_verify_window_start, \
(to_jsonb(customers)->>'verify_locked_until')::timestamptz AS verify_locked_until, \
COALESCE((to_jsonb(customers)->>'failed_reset_count')::int, 0) AS failed_reset_count, \
(to_jsonb(customers)->>'failed_reset_window_start')::timestamptz AS failed_reset_window_start, \
(to_jsonb(customers)->>'reset_locked_until')::timestamptz AS reset_locked_until"
    )
}

pub(super) fn list_customers_sql() -> String {
    let customer_columns = customer_columns();
    format!(
        "SELECT {customer_columns}, \
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

#[cfg(test)]
mod tests {
    use super::{customer_columns, list_customers_sql};

    #[test]
    fn customer_columns_uses_schema_tolerant_carryforward_projection() {
        assert!(
            customer_columns()
                .contains("to_jsonb(customers)->>'object_storage_egress_carryforward_cents'"),
            "customer projection must not require the carryforward column to exist in older local schemas"
        );
    }

    #[test]
    fn customer_columns_uses_schema_tolerant_deleted_at_projection() {
        assert!(
            customer_columns().contains("to_jsonb(customers)->>'deleted_at'"),
            "customer projection must not require deleted_at to exist in older local schemas"
        );
    }

    #[test]
    fn customer_columns_uses_schema_tolerant_quota_warnings_projection() {
        assert!(
            customer_columns().contains("to_jsonb(customers)->>'quota_warnings_sent'"),
            "customer projection must not require quota_warnings_sent to exist in older local schemas"
        );
    }

    #[test]
    fn customer_columns_uses_schema_tolerant_subscription_cycle_anchor_projection() {
        assert!(
            customer_columns().contains("to_jsonb(customers)->>'subscription_cycle_anchor_at'"),
            "customer projection must not require subscription_cycle_anchor_at to exist in older local schemas"
        );
    }

    #[test]
    fn customer_columns_qualifies_status_for_joined_list_query() {
        assert!(
            customer_columns().contains("customers.status"),
            "customer projection must qualify customers.status so the list join cannot hit ambiguous status resolution"
        );
    }

    #[test]
    fn customer_columns_qualifies_id_for_oauth_identity_join() {
        assert!(
            customer_columns().contains("customers.id"),
            "customer projection must qualify customers.id so the oauth_identities join cannot hit ambiguous id resolution"
        );
    }

    #[test]
    fn list_sql_uses_shared_subscription_summary_join() {
        let sql = list_customers_sql();
        assert!(
            !sql.contains("subscriptions"),
            "customer list query must not read subscriptions after subscription seam removal"
        );
    }
}
