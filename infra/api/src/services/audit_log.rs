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
//!   3. **One place to decide error-handling policy.** Rate-card, webhook,
//!      and other low-risk callers retain best-effort pool writes: they log
//!      an audit failure without undoing the completed action. Fail-closed
//!      callers instead require the audit write before exposing the action:
//!
//!      - [`ACTION_IMPERSONATION_TOKEN_CREATED`] uses the required pool-backed
//!        writer as a precondition before its in-memory JWT is signed.
//!      - [`ACTION_CUSTOMER_HARD_ERASE`] and [`ACTION_CUSTOMER_SUSPENDED`] use
//!        [`write_audit_log_tx`] so the audit row and database mutation commit
//!        or roll back together.
//!      - [`ACTION_DAILY_USAGE_UPSERTED`] and [`ACTION_DAILY_USAGE_DELETED`]
//!        use the same transaction as their `usage_daily` mutation because
//!        billing data must never change without an operator-attributed receipt.
//!
//!      Any change to this set requires an inline justification here explaining
//!      why audit failure may or may not expose the action.
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

use async_trait::async_trait;
use std::collections::BTreeSet;

use chrono::{DateTime, NaiveDate, Utc};
use serde::Serialize;
use sqlx::{Executor, PgPool, Postgres, Transaction};
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
/// history for that customer are all removed. To avoid restoring erased
/// customer identity, delete target-bound history first and then insert the
/// surviving receipt with `target_tenant_id = None`.
pub const ACTION_CUSTOMER_HARD_ERASE: &str = "customer_hard_erase";
/// Canonical action name for `POST /admin/customers/{id}/sync-stripe`.
pub const ACTION_STRIPE_SYNC: &str = "stripe_sync";
/// Canonical action name for `PUT /admin/tenants/{id}/rate-card`.
pub const ACTION_RATE_CARD_OVERRIDE: &str = "rate_card_override";
/// Canonical action name for `PUT /admin/tenants/{id}/quotas`.
pub const ACTION_QUOTAS_UPDATED: &str = "quotas_updated";
/// Canonical action name for `POST /admin/tenants/{id}/usage`.
pub const ACTION_DAILY_USAGE_UPSERTED: &str = "daily_usage_upserted";
/// Canonical action name for `DELETE /admin/tenants/{id}/usage`.
pub const ACTION_DAILY_USAGE_DELETED: &str = "daily_usage_deleted";
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

/// Owned audit data passed from a route to the repository that owns its transaction.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuditEntry {
    pub actor_id: Uuid,
    pub action: String,
    pub target_tenant_id: Option<Uuid>,
    pub metadata: serde_json::Value,
}

/// Build the canonical receipt for an operator's daily-usage upsert.
pub fn daily_usage_upserted_audit_entry<'a>(
    actor_id: Uuid,
    target_tenant_id: Uuid,
    entries: impl IntoIterator<Item = (NaiveDate, &'a str)>,
    mutation_count: u64,
) -> AuditEntry {
    let mut dates = BTreeSet::new();
    let mut months = BTreeSet::new();
    let mut regions = BTreeSet::new();
    for (date, region) in entries {
        dates.insert(date);
        months.insert(date.format("%Y-%m").to_string());
        regions.insert(region.to_owned());
    }

    AuditEntry {
        actor_id,
        action: ACTION_DAILY_USAGE_UPSERTED.to_owned(),
        target_tenant_id: Some(target_tenant_id),
        metadata: serde_json::json!({
            "dates": dates,
            "months": months,
            "regions": regions,
            "mutation_count": mutation_count,
        }),
    }
}

/// Build the canonical receipt for an operator's scoped daily-usage deletion.
pub fn daily_usage_deleted_audit_entry(
    actor_id: Uuid,
    target_tenant_id: Uuid,
    scope: &DailyUsageDeleteAuditScope<'_>,
) -> AuditEntry {
    AuditEntry {
        actor_id,
        action: ACTION_DAILY_USAGE_DELETED.to_owned(),
        target_tenant_id: Some(target_tenant_id),
        metadata: serde_json::json!({
            "month": scope.month,
            "start_date": scope.start_date,
            "end_date": scope.end_date,
            "region": scope.region,
            "mutation_count": scope.mutation_count,
        }),
    }
}

/// Request scope and committed row count for a daily-usage deletion receipt.
pub struct DailyUsageDeleteAuditScope<'a> {
    pub month: &'a str,
    pub start_date: NaiveDate,
    pub end_date: NaiveDate,
    pub region: &'a str,
    pub mutation_count: u64,
}

/// Injectable sink for standalone, fail-closed audit writes.
///
/// Production state supplies a [`PgPool`]. The trait keeps route contracts
/// testable without teaching handlers to bypass mandatory audit persistence.
#[async_trait]
pub trait AuditLogWriter: Send + Sync {
    async fn write(&self, entry: &AuditEntry) -> Result<(), AuditLogError>;
}

#[async_trait]
impl AuditLogWriter for PgPool {
    async fn write(&self, entry: &AuditEntry) -> Result<(), AuditLogError> {
        execute_audit_insert(self, entry).await
    }
}

/// Audit requirement carried into the customer repository's hard-delete transaction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CustomerHardDeleteAuditPolicy {
    /// Registration rollback and repository fixtures do not create an erasure receipt.
    NoAudit,
    /// Privacy erasure must atomically persist a receipt for this operator.
    Required { operator_id: Uuid },
}

/// Build the canonical target-free receipt after hard-delete work is known.
pub fn customer_hard_erase_audit_entry(
    policy: CustomerHardDeleteAuditPolicy,
    erased_algolia_job_count: usize,
) -> Option<AuditEntry> {
    let CustomerHardDeleteAuditPolicy::Required { operator_id } = policy else {
        return None;
    };

    Some(AuditEntry {
        actor_id: operator_id,
        action: ACTION_CUSTOMER_HARD_ERASE.to_owned(),
        target_tenant_id: None,
        metadata: serde_json::json!({
            "erased_algolia_job_count": erased_algolia_job_count,
        }),
    })
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

/// Insert one standalone row into `audit_log` through the pool.
///
/// Rate-card, webhook, and similar low-risk callers use this as a best-effort
/// path: they log an `Err` for operational visibility but preserve the
/// completed action. Impersonation requires this writer to succeed before its
/// in-memory JWT is signed. Fail-closed actions with database mutations use
/// [`write_audit_log_tx`] so the action and audit row share a transaction.
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
    let entry = AuditEntry {
        actor_id,
        action: action.to_owned(),
        target_tenant_id,
        metadata,
    };
    pool.write(&entry).await
}

/// Insert one audit row through a caller-owned PostgreSQL transaction.
///
/// This function never commits the transaction. Fail-closed callers propagate
/// the error and leave the owner to roll back both the action and audit entry.
pub async fn write_audit_log_tx(
    transaction: &mut Transaction<'_, Postgres>,
    entry: &AuditEntry,
) -> Result<(), AuditLogError> {
    execute_audit_insert(&mut **transaction, entry).await
}

async fn execute_audit_insert<'executor, E>(
    executor: E,
    entry: &AuditEntry,
) -> Result<(), AuditLogError>
where
    E: Executor<'executor, Database = Postgres>,
{
    sqlx::query(
        "INSERT INTO audit_log (actor_id, action, target_tenant_id, metadata) \
         VALUES ($1, $2, $3, $4)",
    )
    .bind(entry.actor_id)
    .bind(&entry.action)
    .bind(entry.target_tenant_id)
    .bind(&entry.metadata)
    .execute(executor)
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
