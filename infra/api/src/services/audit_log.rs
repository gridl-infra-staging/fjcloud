//! Append-only audit-log writer for high-trust human and system actions.
//!
//! ## Why this module exists (read before extending)
//!
//! `audit_log` is the durable record of "who did what to whom and when" for
//! admin write paths and machine-initiated webhook events whose abuse would be
//! a customer-trust incident (impersonation, suspend/reactivate, hard-erasure,
//! suppression, disputes, etc.). This table is the shared audit surface for
//! both human operators and stable system identities.
//!
//! This service exists rather than inline `INSERT INTO audit_log` at each
//! call site because:
//!
//!   1. **SSOT for the action-name vocabulary.** Action strings must stay
//!      stable (T1.4's read view filters by action). Centralizing them here
//!      lets us add an enum or constants module later without rewriting
//!      callers.
//!
//!   2. **SSOT for the metadata-JSON shape.** Each action has a small set
//!      of conventional metadata fields (e.g. `duration_secs` for
//!      impersonation). When that vocabulary expands, it expands here, not
//!      across N route handlers.
//!
//!   3. **One place to decide error-handling policy.** Audit writes are
//!      best-effort: a transient DB failure must NOT block the user-facing
//!      action (we don't want to lock an operator out of legitimate
//!      impersonation just because the DB hiccuped). Centralizing means
//!      every caller gets the same policy — see `write_audit_log` doc.
//!
//! ## Why no batching (cf. `access_tracker.rs`'s debounced batch)
//!
//! Operator-scale write rate. Impersonation events happen a few times per
//! day, customer suspend events even less. The access_tracker batches
//! because customer-API access is thousands of writes/sec; admin actions
//! are not. YAGNI on debouncing until profiling says otherwise — and if
//! it ever does, we'd reach for the same access_tracker pattern, not
//! reinvent it.
//!
//! ## Actor identities
//!
//! Human admin routes pass the authenticated `AdminAuth::operator_id`.
//! Machine-initiated call sites use their stable system actor constants and
//! add the conventional system metadata with [`system_audit_metadata`].

use chrono::{DateTime, Utc};
use serde::Serialize;
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, thiserror::Error)]
pub enum AuditLogError {
    #[error("database error: {0}")]
    Db(String),
}

/// Stable actor identity for AWS SES webhook audit rows.
///
/// UUIDv5 derived from `https://fjcloud.com/audit/system/ses` in the URL
/// namespace. This value is durable audit data and must not be regenerated.
pub const SES_SYSTEM_ACTOR_ID: Uuid = Uuid::from_u128(0x8a0f2350_fc1d_5c32_8f1e_09d9dd362d4a);

/// Stable actor identity for Stripe webhook audit rows.
///
/// UUIDv5 derived from `https://fjcloud.com/audit/system/stripe` in the URL
/// namespace. This value is durable audit data and must not be regenerated.
pub const STRIPE_SYSTEM_ACTOR_ID: Uuid = Uuid::from_u128(0x2b9e4725_b5fe_5cd3_ba7a_537abb6d31e9);

/// Canonical action name for `POST /admin/tokens` impersonation token mints.
pub const ACTION_IMPERSONATION_TOKEN_CREATED: &str = "impersonation_token_created";
/// Canonical action name for `POST /admin/tenants`.
pub const ACTION_TENANT_CREATED: &str = "tenant_created";
/// Canonical action name for `PUT /admin/tenants/{id}`.
pub const ACTION_TENANT_UPDATED: &str = "tenant_updated";
/// Canonical action name for `DELETE /admin/tenants/{id}`.
pub const ACTION_TENANT_DELETED: &str = "tenant_deleted";
/// Canonical action name for `POST /admin/customers/{id}/suspend`.
pub const ACTION_CUSTOMER_SUSPENDED: &str = "customer_suspended";
/// Canonical action name for `POST /admin/customers/{id}/reactivate`.
pub const ACTION_CUSTOMER_REACTIVATED: &str = "customer_reactivated";
/// Canonical action name for `POST /admin/customers/{id}/hard-erase`.
///
/// The audit row is the only surviving trace once `CustomerRepo::hard_delete`
/// completes — the customer row, billing artifacts, and earlier audit
/// history for that customer are all removed. Keep the row attached to
/// the now-defunct customer id so the GDPR-erasure event is queryable by
/// `target_tenant_id`.
pub const ACTION_CUSTOMER_HARD_ERASE: &str = "customer_hard_erase";
/// Canonical action name for `POST /admin/customers/{id}/sync-stripe`.
pub const ACTION_STRIPE_SYNC: &str = "stripe_sync";
/// Canonical action name for `PUT /admin/tenants/{id}/rate-card`.
pub const ACTION_RATE_CARD_OVERRIDE: &str = "rate_card_override";
/// Canonical action name for `PUT /admin/tenants/{id}/quotas`.
pub const ACTION_QUOTAS_UPDATED: &str = "quotas_updated";
/// Canonical action name for SES permanent-bounce suppression upserts.
pub const ACTION_SES_PERMANENT_BOUNCE_SUPPRESSED: &str = "ses_permanent_bounce_suppressed";
/// Canonical action name for SES complaint suppression upserts.
pub const ACTION_SES_COMPLAINT_SUPPRESSED: &str = "ses_complaint_suppressed";
/// Canonical action name for Stripe dispute webhook persistence milestones.
pub const ACTION_STRIPE_DISPUTE_UPDATED: &str = "stripe_dispute_updated";
const AUDIT_LOG_READ_LIMIT: i64 = 100;

/// Merge the conventional machine-actor fields into event-specific metadata.
///
/// Audit metadata is contractually a JSON object. Keeping these keys here
/// prevents webhook call sites from drifting on the reader-visible shape.
pub fn system_audit_metadata(system: &str, mut metadata: serde_json::Value) -> serde_json::Value {
    let fields = metadata
        .as_object_mut()
        .expect("audit metadata must be a JSON object");
    fields.insert("actor_type".into(), serde_json::json!("system"));
    fields.insert("system".into(), serde_json::json!(system));
    metadata
}

#[derive(Debug, Clone, Serialize, sqlx::FromRow)]
pub struct AuditLogRow {
    pub id: Uuid,
    pub actor_id: Uuid,
    pub action: String,
    pub target_tenant_id: Option<Uuid>,
    pub metadata: serde_json::Value,
    pub created_at: DateTime<Utc>,
}

/// Insert one row into `audit_log`.
///
/// Best-effort: callers should treat this as fire-and-forget — log the
/// `Err` at `error!` level for ops visibility but DO NOT propagate it as
/// a 5xx to the user. A failed audit write is bad (we lose the trail for
/// that one event), but blocking the legitimate admin action behind it
/// is worse (we lock the operator out of customer support).
///
/// Parameters:
/// * `actor_id` — the human or system identity performing the action. Pass
///   `AdminAuth::operator_id` for human admin call sites; machine call sites
///   pass their stable system actor ID.
/// * `action` — canonical snake_case action name. Stable identifier used
///   for filtering in T1.4's view; do not rename without migrating
///   historical rows.
/// * `target_tenant_id` — the customer being acted upon (`None` when the
///   action does not target a specific customer).
/// * `metadata` — small JSON object of action-specific context. System actors
///   must merge their reader-visible identity fields with
///   [`system_audit_metadata`]. Pass `serde_json::json!({})` if there's
///   nothing to add.
pub async fn write_audit_log(
    pool: &PgPool,
    actor_id: Uuid,
    action: &str,
    target_tenant_id: Option<Uuid>,
    metadata: serde_json::Value,
) -> Result<(), AuditLogError> {
    sqlx::query(
        "INSERT INTO audit_log (actor_id, action, target_tenant_id, metadata) \
         VALUES ($1, $2, $3, $4)",
    )
    .bind(actor_id)
    .bind(action)
    .bind(target_tenant_id)
    .bind(metadata)
    .execute(pool)
    .await
    .map_err(|e| AuditLogError::Db(e.to_string()))?;

    Ok(())
}

/// Read the newest audit rows for a single customer.
///
/// Mirrors migration 041's query contract: filter by `target_tenant_id`, order
/// newest-first by `created_at DESC`, and cap at 100 rows.
pub async fn list_audit_log_for_target_tenant(
    pool: &PgPool,
    target_tenant_id: Uuid,
) -> Result<Vec<AuditLogRow>, AuditLogError> {
    sqlx::query_as::<_, AuditLogRow>(
        "SELECT id, actor_id, action, target_tenant_id, metadata, created_at \
         FROM audit_log \
         WHERE target_tenant_id = $1 \
         ORDER BY created_at DESC \
         LIMIT $2",
    )
    .bind(target_tenant_id)
    .bind(AUDIT_LOG_READ_LIMIT)
    .fetch_all(pool)
    .await
    .map_err(|e| AuditLogError::Db(e.to_string()))
}
