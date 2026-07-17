use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::models::{AlgoliaSealScrubWork, Customer, IngestQuotaWarningMetric};
use crate::repos::error::RepoError;

pub const RESEND_VERIFICATION_COOLDOWN_SECONDS: i64 = 60;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResendVerificationReservation {
    pub previous_email_verify_token: Option<String>,
    pub previous_email_verify_expires_at: Option<DateTime<Utc>>,
    pub previous_resend_verification_sent_at: Option<DateTime<Utc>>,
    pub reserved_resend_verification_sent_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResendPasswordResetReservation {
    pub previous_password_reset_token: Option<String>,
    pub previous_password_reset_expires_at: Option<DateTime<Utc>>,
    pub previous_password_reset_sent_at: Option<DateTime<Utc>>,
    pub reserved_password_reset_sent_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResendVerificationOutcome {
    Allowed {
        reservation: ResendVerificationReservation,
    },
    CooldownActive {
        retry_after_seconds: u64,
    },
    AlreadyVerified,
    CustomerNotFound,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResendPasswordResetOutcome {
    Allowed {
        reservation: ResendPasswordResetReservation,
    },
    CooldownActive {
        retry_after_seconds: u64,
    },
    CustomerNotFound,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CustomerHardDeleteKind {
    RegistrationRollback,
    PrivacyErasure,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CustomerHardDeleteOutcome {
    Erased {
        seal_scrub_work: Vec<AlgoliaSealScrubWork>,
    },
    NotFound,
    NotSoftDeleted,
}

/// Customer lifecycle repository: CRUD, authentication (password hashing,
/// email verification, password reset tokens), Stripe linking, billing-plan
/// management, suspension, and sub-cent egress carry-forward persistence.
#[async_trait]
pub trait CustomerRepo {
    async fn list(&self) -> Result<Vec<Customer>, RepoError>;
    async fn find_by_id(&self, id: Uuid) -> Result<Option<Customer>, RepoError>;
    async fn find_by_email(&self, email: &str) -> Result<Option<Customer>, RepoError>;
    async fn create(&self, name: &str, email: &str) -> Result<Customer, RepoError>;
    async fn create_with_password(
        &self,
        name: &str,
        email: &str,
        password_hash: &str,
    ) -> Result<Customer, RepoError>;
    async fn find_oauth_identity(
        &self,
        provider: &str,
        provider_user_id: &str,
    ) -> Result<Option<Customer>, RepoError>;
    async fn create_oauth_customer(&self, name: &str, email: &str) -> Result<Customer, RepoError>;
    async fn link_oauth_identity(
        &self,
        customer_id: Uuid,
        provider: &str,
        provider_user_id: &str,
    ) -> Result<(), RepoError>;
    async fn update(
        &self,
        id: Uuid,
        name: Option<&str>,
        email: Option<&str>,
    ) -> Result<Option<Customer>, RepoError>;
    async fn soft_delete(&self, id: Uuid) -> Result<bool, RepoError>;
    /// Permanently erase a previously soft-deleted customer plus all
    /// dependent rows that reference `customers(id)`. The customer row is
    /// removed last.
    ///
    /// Contract:
    /// * Returns `Erased` with opaque reconciliation work when the customer
    ///   existed and was removed.
    /// * Returns `NotFound` when no `customers` row with this id exists
    ///   (already hard-erased, or never existed).
    /// * Returns `Err(RepoError::Conflict)` when the customer still has
    ///   open invoices (non-final billing state). GDPR hard-erasure must
    ///   not silently drop in-flight billing — callers (admins) must wind
    ///   those down first.
    /// * Implementations must rely on the `oauth_identities` FK cascade
    ///   for that table only; every other dependent table must be cleaned
    ///   explicitly so partial-delete regressions can be caught by tests.
    async fn hard_delete(
        &self,
        id: Uuid,
        kind: CustomerHardDeleteKind,
    ) -> Result<CustomerHardDeleteOutcome, RepoError>;
    async fn list_deleted_before_cutoff(
        &self,
        cutoff: DateTime<Utc>,
    ) -> Result<Vec<Customer>, RepoError>;

    // Email verification
    async fn set_email_verify_token(
        &self,
        id: Uuid,
        token: &str,
        expires_at: DateTime<Utc>,
    ) -> Result<bool, RepoError>;
    async fn rotate_email_verification_token_with_resend_cooldown(
        &self,
        id: Uuid,
        token: &str,
        expires_at: DateTime<Utc>,
    ) -> Result<ResendVerificationOutcome, RepoError>;
    async fn rollback_resend_verification_token_rotation(
        &self,
        id: Uuid,
        reserved_token: &str,
        reservation: &ResendVerificationReservation,
    ) -> Result<bool, RepoError>;
    async fn verify_email(&self, token: &str) -> Result<Option<Customer>, RepoError>;

    // Password reset
    async fn set_password_reset_token(
        &self,
        id: Uuid,
        token: &str,
        expires_at: DateTime<Utc>,
    ) -> Result<bool, RepoError>;
    async fn restore_password_reset_state(
        &self,
        id: Uuid,
        token: Option<&str>,
        expires_at: Option<DateTime<Utc>>,
    ) -> Result<bool, RepoError>;
    async fn rotate_password_reset_token_with_resend_cooldown(
        &self,
        id: Uuid,
        token: &str,
        expires_at: DateTime<Utc>,
    ) -> Result<ResendPasswordResetOutcome, RepoError>;
    async fn rollback_password_reset_token_rotation(
        &self,
        id: Uuid,
        reserved_token: &str,
        reservation: &ResendPasswordResetReservation,
    ) -> Result<bool, RepoError>;
    async fn find_by_reset_token(&self, token: &str) -> Result<Option<Customer>, RepoError>;
    async fn reset_password(&self, token: &str, new_password_hash: &str)
        -> Result<bool, RepoError>;

    // Stripe linking
    async fn set_stripe_customer_id(
        &self,
        id: Uuid,
        stripe_customer_id: &str,
    ) -> Result<bool, RepoError>;

    async fn find_by_stripe_customer_id(
        &self,
        stripe_customer_id: &str,
    ) -> Result<Option<Customer>, RepoError>;

    async fn set_quota_warning_sent_at(
        &self,
        id: Uuid,
        sent_at: DateTime<Utc>,
    ) -> Result<bool, RepoError>;
    async fn ingest_quota_warning_sent_for_month(
        &self,
        id: Uuid,
        metric: IngestQuotaWarningMetric,
        year: i32,
        month: u32,
    ) -> Result<bool, RepoError>;
    async fn claim_ingest_quota_warning_for_month(
        &self,
        id: Uuid,
        metric: IngestQuotaWarningMetric,
        year: i32,
        month: u32,
    ) -> Result<bool, RepoError>;
    async fn rollback_ingest_quota_warning_for_month(
        &self,
        id: Uuid,
        metric: IngestQuotaWarningMetric,
        year: i32,
        month: u32,
    ) -> Result<bool, RepoError>;

    // Password change (by authenticated user, not via reset token)
    async fn change_password(&self, id: Uuid, new_password_hash: &str) -> Result<bool, RepoError>;

    // Billing plan
    async fn set_subscription_cycle_anchor(
        &self,
        id: Uuid,
        anchor_at: Option<DateTime<Utc>>,
    ) -> Result<bool, RepoError>;
    async fn try_upgrade_to_shared_atomic(
        &self,
        id: Uuid,
        subscription_cycle_anchor_at: DateTime<Utc>,
    ) -> Result<bool, RepoError>;
    async fn rollback_upgrade_to_free_atomic(
        &self,
        id: Uuid,
        expected_subscription_cycle_anchor_at: DateTime<Utc>,
    ) -> Result<bool, RepoError>;
    async fn set_billing_plan(&self, id: Uuid, plan: &str) -> Result<bool, RepoError>;

    // Suspension
    async fn suspend(&self, id: Uuid) -> Result<bool, RepoError>;
    async fn reactivate(&self, id: Uuid) -> Result<bool, RepoError>;

    // Object-storage egress carry-forward (sub-cent remainder persistence)
    async fn set_object_storage_egress_carryforward_cents(
        &self,
        id: Uuid,
        cents: Decimal,
    ) -> Result<bool, RepoError>;

    // Login lockout
    async fn record_failed_login(&self, id: Uuid) -> Result<Option<i64>, RepoError>;
    async fn record_successful_login(&self, id: Uuid) -> Result<bool, RepoError>;
    async fn login_lockout_remaining(&self, id: Uuid) -> Result<Option<i64>, RepoError>;
}
