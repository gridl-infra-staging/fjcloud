//! Append-only audit-log writer for high-trust admin actions.
//!
//! ## Why this module exists (read before extending)
//!
//! `audit_log` is the durable record of "who did what to whom and when" for
//! admin write paths whose abuse would be a customer-trust incident
//! (impersonation, suspend/reactivate, hard-erasure, etc.). Stateless JWTs
//! have no DB row of their own, so this table is the only audit surface.
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
//! ## Sentinel actor_id
//!
//! Today `auth/admin.rs::AdminAuth` is gated by a single shared admin key
//! with no per-admin identity. So callers pass `actor_id =
//! ADMIN_SENTINEL_ACTOR_ID` (defined here). When per-admin auth lands the
//! sentinel goes away and callers pass the real id — no schema change
//! required.

use chrono::{DateTime, Utc};
use serde::Serialize;
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, thiserror::Error)]
pub enum AuditLogError {
    #[error("database error: {0}")]
    Db(String),
}

/// Sentinel UUID used as `actor_id` for admin-auth callers, since the
/// current single-shared-admin-key model does not distinguish operators.
///
/// Format chosen to be visually distinguishable from a real Uuid::new_v4()
/// row in psql output — all-zeroes after the version byte. When a future
/// per-admin auth system replaces `AdminAuth`, switch each call site to
/// pass the real admin id and remove this constant.
pub const ADMIN_SENTINEL_ACTOR_ID: Uuid = Uuid::nil();

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
const AUDIT_LOG_READ_LIMIT: i64 = 100;

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
/// * `actor_id` — the operator performing the action. Pass
///   [`ADMIN_SENTINEL_ACTOR_ID`] from `AdminAuth` call sites until
///   per-admin identity exists.
/// * `action` — canonical snake_case action name. Stable identifier used
///   for filtering in T1.4's view; do not rename without migrating
///   historical rows.
/// * `target_tenant_id` — the customer being acted upon (`None` when the
///   action does not target a specific customer).
/// * `metadata` — small JSON object of action-specific context. Pass
///   `serde_json::json!({})` if there's nothing to add.
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
