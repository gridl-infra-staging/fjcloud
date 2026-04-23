//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/customer_repo.rs.
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::models::Customer;
use crate::repos::error::RepoError;

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
    async fn update(
        &self,
        id: Uuid,
        name: Option<&str>,
        email: Option<&str>,
    ) -> Result<Option<Customer>, RepoError>;
    async fn soft_delete(&self, id: Uuid) -> Result<bool, RepoError>;

    // Email verification
    async fn set_email_verify_token(
        &self,
        id: Uuid,
        token: &str,
        expires_at: DateTime<Utc>,
    ) -> Result<bool, RepoError>;
    async fn verify_email(&self, token: &str) -> Result<Option<Customer>, RepoError>;

    // Password reset
    async fn set_password_reset_token(
        &self,
        id: Uuid,
        token: &str,
        expires_at: DateTime<Utc>,
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

    // Password change (by authenticated user, not via reset token)
    async fn change_password(&self, id: Uuid, new_password_hash: &str) -> Result<bool, RepoError>;

    // Billing plan
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
}
