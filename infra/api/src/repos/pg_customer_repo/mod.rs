//! Postgres-backed customer repository owner.
mod billing;
mod hard_delete;
mod lifecycle;
mod lockout;
mod password_reset;
mod projection;
mod queries;
mod quota_warning;
mod verification;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::{Customer, IngestQuotaWarningMetric};
use crate::repos::customer_repo::{
    CustomerHardDeleteKind, CustomerHardDeleteOutcome, CustomerRepo, ResendPasswordResetOutcome,
    ResendPasswordResetReservation, ResendVerificationOutcome, ResendVerificationReservation,
};
use crate::repos::error::RepoError;

pub struct PgCustomerRepo {
    pool: PgPool,
}

impl PgCustomerRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl CustomerRepo for PgCustomerRepo {
    async fn list(&self) -> Result<Vec<Customer>, RepoError> {
        queries::list(&self.pool).await
    }

    async fn find_by_id(&self, id: Uuid) -> Result<Option<Customer>, RepoError> {
        queries::find_by_id(&self.pool, id).await
    }

    async fn find_by_email(&self, email: &str) -> Result<Option<Customer>, RepoError> {
        queries::find_by_email(&self.pool, email).await
    }

    async fn list_deleted_before_cutoff(
        &self,
        cutoff: DateTime<Utc>,
    ) -> Result<Vec<Customer>, RepoError> {
        queries::list_deleted_before_cutoff(&self.pool, cutoff).await
    }

    async fn create(&self, name: &str, email: &str) -> Result<Customer, RepoError> {
        lifecycle::create(&self.pool, name, email).await
    }

    async fn create_with_password(
        &self,
        name: &str,
        email: &str,
        password_hash: &str,
    ) -> Result<Customer, RepoError> {
        lifecycle::create_with_password(&self.pool, name, email, password_hash).await
    }

    async fn find_oauth_identity(
        &self,
        provider: &str,
        provider_user_id: &str,
    ) -> Result<Option<Customer>, RepoError> {
        queries::find_oauth_identity(&self.pool, provider, provider_user_id).await
    }

    async fn create_oauth_customer(&self, name: &str, email: &str) -> Result<Customer, RepoError> {
        lifecycle::create(&self.pool, name, email).await
    }

    async fn link_oauth_identity(
        &self,
        customer_id: Uuid,
        provider: &str,
        provider_user_id: &str,
    ) -> Result<(), RepoError> {
        lifecycle::link_oauth_identity(&self.pool, customer_id, provider, provider_user_id).await
    }

    async fn update(
        &self,
        id: Uuid,
        name: Option<&str>,
        email: Option<&str>,
    ) -> Result<Option<Customer>, RepoError> {
        lifecycle::update(&self.pool, id, name, email).await
    }

    async fn soft_delete(&self, id: Uuid) -> Result<bool, RepoError> {
        lifecycle::soft_delete(&self.pool, id).await
    }

    async fn hard_delete(
        &self,
        id: Uuid,
        kind: CustomerHardDeleteKind,
    ) -> Result<CustomerHardDeleteOutcome, RepoError> {
        hard_delete::hard_delete(&self.pool, id, kind).await
    }

    async fn set_email_verify_token(
        &self,
        id: Uuid,
        token: &str,
        expires_at: DateTime<Utc>,
    ) -> Result<bool, RepoError> {
        verification::set_email_verify_token(&self.pool, id, token, expires_at).await
    }

    async fn rotate_email_verification_token_with_resend_cooldown(
        &self,
        id: Uuid,
        token: &str,
        expires_at: DateTime<Utc>,
    ) -> Result<ResendVerificationOutcome, RepoError> {
        verification::rotate_email_verification_token_with_resend_cooldown(
            &self.pool, id, token, expires_at,
        )
        .await
    }

    async fn rollback_resend_verification_token_rotation(
        &self,
        id: Uuid,
        reserved_token: &str,
        reservation: &ResendVerificationReservation,
    ) -> Result<bool, RepoError> {
        verification::rollback_resend_verification_token_rotation(
            &self.pool,
            id,
            reserved_token,
            reservation,
        )
        .await
    }

    async fn verify_email(&self, token: &str) -> Result<Option<Customer>, RepoError> {
        verification::verify_email(&self.pool, token).await
    }

    async fn set_password_reset_token(
        &self,
        id: Uuid,
        token: &str,
        expires_at: DateTime<Utc>,
    ) -> Result<bool, RepoError> {
        password_reset::set_password_reset_token(&self.pool, id, token, expires_at).await
    }

    async fn restore_password_reset_state(
        &self,
        id: Uuid,
        token: Option<&str>,
        expires_at: Option<DateTime<Utc>>,
    ) -> Result<bool, RepoError> {
        password_reset::restore_password_reset_state(&self.pool, id, token, expires_at).await
    }

    async fn rotate_password_reset_token_with_resend_cooldown(
        &self,
        id: Uuid,
        token: &str,
        expires_at: DateTime<Utc>,
    ) -> Result<ResendPasswordResetOutcome, RepoError> {
        password_reset::rotate_password_reset_token_with_resend_cooldown(
            &self.pool, id, token, expires_at,
        )
        .await
    }

    async fn rollback_password_reset_token_rotation(
        &self,
        id: Uuid,
        reserved_token: &str,
        reservation: &ResendPasswordResetReservation,
    ) -> Result<bool, RepoError> {
        password_reset::rollback_password_reset_token_rotation(
            &self.pool,
            id,
            reserved_token,
            reservation,
        )
        .await
    }

    async fn find_by_reset_token(&self, token: &str) -> Result<Option<Customer>, RepoError> {
        queries::find_by_reset_token(&self.pool, token).await
    }

    async fn reset_password(
        &self,
        token: &str,
        new_password_hash: &str,
    ) -> Result<bool, RepoError> {
        password_reset::reset_password(&self.pool, token, new_password_hash).await
    }

    async fn set_stripe_customer_id(
        &self,
        id: Uuid,
        stripe_customer_id: &str,
    ) -> Result<bool, RepoError> {
        billing::set_stripe_customer_id(&self.pool, id, stripe_customer_id).await
    }

    async fn find_by_stripe_customer_id(
        &self,
        stripe_customer_id: &str,
    ) -> Result<Option<Customer>, RepoError> {
        queries::find_by_stripe_customer_id(&self.pool, stripe_customer_id).await
    }

    async fn set_quota_warning_sent_at(
        &self,
        id: Uuid,
        sent_at: DateTime<Utc>,
    ) -> Result<bool, RepoError> {
        quota_warning::set_quota_warning_sent_at(&self.pool, id, sent_at).await
    }

    async fn ingest_quota_warning_sent_for_month(
        &self,
        id: Uuid,
        metric: IngestQuotaWarningMetric,
        year: i32,
        month: u32,
    ) -> Result<bool, RepoError> {
        queries::ingest_quota_warning_sent_for_month(&self.pool, id, metric, year, month).await
    }

    async fn claim_ingest_quota_warning_for_month(
        &self,
        id: Uuid,
        metric: IngestQuotaWarningMetric,
        year: i32,
        month: u32,
    ) -> Result<bool, RepoError> {
        quota_warning::claim_ingest_quota_warning_for_month(&self.pool, id, metric, year, month)
            .await
    }

    async fn rollback_ingest_quota_warning_for_month(
        &self,
        id: Uuid,
        metric: IngestQuotaWarningMetric,
        year: i32,
        month: u32,
    ) -> Result<bool, RepoError> {
        quota_warning::rollback_ingest_quota_warning_for_month(&self.pool, id, metric, year, month)
            .await
    }

    async fn change_password(&self, id: Uuid, new_password_hash: &str) -> Result<bool, RepoError> {
        password_reset::change_password(&self.pool, id, new_password_hash).await
    }

    async fn set_subscription_cycle_anchor(
        &self,
        id: Uuid,
        anchor_at: Option<DateTime<Utc>>,
    ) -> Result<bool, RepoError> {
        billing::set_subscription_cycle_anchor(&self.pool, id, anchor_at).await
    }

    async fn try_upgrade_to_shared_atomic(
        &self,
        id: Uuid,
        subscription_cycle_anchor_at: DateTime<Utc>,
    ) -> Result<bool, RepoError> {
        billing::try_upgrade_to_shared_atomic(&self.pool, id, subscription_cycle_anchor_at).await
    }

    async fn rollback_upgrade_to_free_atomic(
        &self,
        id: Uuid,
        expected_subscription_cycle_anchor_at: DateTime<Utc>,
    ) -> Result<bool, RepoError> {
        billing::rollback_upgrade_to_free_atomic(
            &self.pool,
            id,
            expected_subscription_cycle_anchor_at,
        )
        .await
    }

    async fn set_billing_plan(&self, id: Uuid, plan: &str) -> Result<bool, RepoError> {
        billing::set_billing_plan(&self.pool, id, plan).await
    }

    async fn suspend(&self, id: Uuid) -> Result<bool, RepoError> {
        billing::suspend(&self.pool, id).await
    }

    async fn reactivate(&self, id: Uuid) -> Result<bool, RepoError> {
        billing::reactivate(&self.pool, id).await
    }

    async fn set_object_storage_egress_carryforward_cents(
        &self,
        id: Uuid,
        cents: Decimal,
    ) -> Result<bool, RepoError> {
        billing::set_object_storage_egress_carryforward_cents(&self.pool, id, cents).await
    }

    async fn record_failed_login(&self, id: Uuid) -> Result<Option<i64>, RepoError> {
        lockout::record_failed_login(&self.pool, id).await
    }

    async fn record_successful_login(&self, id: Uuid) -> Result<bool, RepoError> {
        lockout::record_successful_login(&self.pool, id).await
    }

    async fn login_lockout_remaining(&self, id: Uuid) -> Result<Option<i64>, RepoError> {
        lockout::login_lockout_remaining(&self.pool, id).await
    }
}
