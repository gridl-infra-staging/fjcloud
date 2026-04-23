//! Stub summary for infra/api/tests/common/mocks.rs.
//! Stub summary for infra/api/tests/common/mocks.rs.
//! Stub summary for infra/api/tests/common/mocks.rs.
//! Stub summary for infra/api/tests/common/mocks.rs.
#![allow(dead_code)]

use api::dns::mock::MockDnsManager;
use api::models::api_key::ApiKeyRow;
use api::models::index_migration::IndexMigration;
use api::models::vm_inventory::{NewVmInventory, VmInventory};
use api::models::{
    Customer, CustomerRateOverrideRow, CustomerTenant, CustomerTenantSummary, Deployment,
    InvoiceLineItemRow, InvoiceRow, PlanTier, RateCardRow, SubscriptionRow, SubscriptionStatus,
    UsageDaily,
};
use api::provisioner::mock::MockVmProvisioner;
use api::repos::api_key_repo::ApiKeyRepo;
use api::repos::index_migration_repo::IndexMigrationRepo;
use api::repos::invoice_repo::{InvoiceRepo, NewInvoice, NewLineItem};
use api::repos::subscription_repo::{NewSubscription, SubscriptionRepo};
use api::repos::tenant_repo::TenantRepo;
use api::repos::vm_inventory_repo::VmInventoryRepo;
use api::repos::webhook_event_repo::WebhookEventRepo;
use api::repos::{
    CustomerRepo, DeploymentRepo, InMemoryColdSnapshotRepo, InMemoryIndexReplicaRepo, RateCardRepo,
    RepoError, UsageRepo,
};
use api::secrets::mock::MockNodeSecretManager;
use api::services::alerting::MockAlertService;
use api::services::cold_tier::{ColdTierError, FlapjackNodeClient};
use api::services::email::MockEmailService;
use api::services::flapjack_proxy::FlapjackProxy;
use api::services::migration::{
    MigrationHttpClient, MigrationHttpClientError, MigrationHttpRequest, MigrationHttpResponse,
    MigrationRequest,
};
use api::stripe::{
    CheckoutSessionResponse, FinalizedInvoice, PaymentMethodSummary, StripeError, StripeEvent,
    StripeInvoiceLineItem, StripeService, SubscriptionData,
};
use async_trait::async_trait;
use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use uuid::Uuid;

pub struct MockCustomerRepo {
    customers: Mutex<Vec<Customer>>,
    pub should_fail_suspend: Mutex<bool>,
    pub should_fail_reactivate: Mutex<bool>,
    fail_next_soft_delete: AtomicBool,
}

impl MockCustomerRepo {
    pub fn new() -> Self {
        Self {
            customers: Mutex::new(Vec::new()),
            should_fail_suspend: Mutex::new(false),
            should_fail_reactivate: Mutex::new(false),
            fail_next_soft_delete: AtomicBool::new(false),
        }
    }

    /// Force the next soft-delete call to report "not found" without mutating state.
    pub fn fail_next_soft_delete(&self) {
        self.fail_next_soft_delete.store(true, Ordering::SeqCst);
    }

    /// Seed the mock with an already-deleted customer (for 404 tests).
    pub fn seed_deleted(&self, name: &str, email: &str) -> Customer {
        let mut customers = self.customers.lock().unwrap();
        let now = Utc::now();
        let customer = Customer {
            id: Uuid::new_v4(),
            name: name.to_string(),
            email: email.to_string(),
            stripe_customer_id: None,
            status: "deleted".to_string(),
            billing_plan: "free".to_string(),
            quota_warning_sent_at: None,
            created_at: now,
            updated_at: now,
            password_hash: None,
            email_verified_at: None,
            email_verify_token: None,
            email_verify_expires_at: None,
            password_reset_token: None,
            password_reset_expires_at: None,
            object_storage_egress_carryforward_cents: Decimal::ZERO,
        };
        customers.push(customer.clone());
        customer
    }

    /// Seed the mock with a customer for testing.
    pub fn seed(&self, name: &str, email: &str) -> Customer {
        let mut customers = self.customers.lock().unwrap();
        let now = Utc::now();
        let customer = Customer {
            id: Uuid::new_v4(),
            name: name.to_string(),
            email: email.to_string(),
            stripe_customer_id: None,
            status: "active".to_string(),
            billing_plan: "free".to_string(),
            quota_warning_sent_at: None,
            created_at: now,
            updated_at: now,
            password_hash: None,
            email_verified_at: None,
            email_verify_token: None,
            email_verify_expires_at: None,
            password_reset_token: None,
            password_reset_expires_at: None,
            object_storage_egress_carryforward_cents: Decimal::ZERO,
        };
        customers.push(customer.clone());
        customer
    }

    pub fn seed_verified_free_customer(&self, name: &str, email: &str) -> Customer {
        let mut customer = self.seed(name, email);
        customer.email_verified_at = Some(Utc::now());
        customer.billing_plan = "free".to_string();

        let mut customers = self.customers.lock().unwrap();
        if let Some(stored) = customers.iter_mut().find(|c| c.id == customer.id) {
            stored.email_verified_at = customer.email_verified_at;
            stored.billing_plan = customer.billing_plan.clone();
        }
        customer
    }

    pub fn seed_verified_shared_customer(&self, name: &str, email: &str) -> Customer {
        let mut customer = self.seed(name, email);
        customer.email_verified_at = Some(Utc::now());
        customer.billing_plan = "shared".to_string();

        let mut customers = self.customers.lock().unwrap();
        if let Some(stored) = customers.iter_mut().find(|c| c.id == customer.id) {
            stored.email_verified_at = customer.email_verified_at;
            stored.billing_plan = customer.billing_plan.clone();
        }
        customer
    }
}

#[async_trait]
impl CustomerRepo for MockCustomerRepo {
    async fn list(&self) -> Result<Vec<Customer>, RepoError> {
        let customers = self.customers.lock().unwrap();
        Ok(customers.iter().cloned().collect())
    }

    async fn find_by_id(&self, id: Uuid) -> Result<Option<Customer>, RepoError> {
        let customers = self.customers.lock().unwrap();
        Ok(customers.iter().find(|c| c.id == id).cloned())
    }

    async fn find_by_email(&self, email: &str) -> Result<Option<Customer>, RepoError> {
        let customers = self.customers.lock().unwrap();
        Ok(customers.iter().find(|c| c.email == email).cloned())
    }

    /// Implements `CustomerRepo::create`. Inserts a new active customer with
    /// `billing_plan = "free"` and no password or email verification. Returns
    /// `RepoError::Conflict` if a customer with the same email already exists.
    async fn create(&self, name: &str, email: &str) -> Result<Customer, RepoError> {
        let mut customers = self.customers.lock().unwrap();

        if customers.iter().any(|c| c.email == email) {
            return Err(RepoError::Conflict("email already exists".into()));
        }

        let now = Utc::now();
        let customer = Customer {
            id: Uuid::new_v4(),
            name: name.to_string(),
            email: email.to_string(),
            stripe_customer_id: None,
            status: "active".to_string(),
            billing_plan: "free".to_string(),
            quota_warning_sent_at: None,
            created_at: now,
            updated_at: now,
            password_hash: None,
            email_verified_at: None,
            email_verify_token: None,
            email_verify_expires_at: None,
            password_reset_token: None,
            password_reset_expires_at: None,
            object_storage_egress_carryforward_cents: Decimal::ZERO,
        };
        customers.push(customer.clone());
        Ok(customer)
    }

    /// Implements `CustomerRepo::create_with_password`. Like `create`, but stores
    /// the provided `password_hash` on the new customer row. Returns
    /// `RepoError::Conflict` if the email is already taken.
    async fn create_with_password(
        &self,
        name: &str,
        email: &str,
        password_hash: &str,
    ) -> Result<Customer, RepoError> {
        let mut customers = self.customers.lock().unwrap();

        if customers.iter().any(|c| c.email == email) {
            return Err(RepoError::Conflict("email already exists".into()));
        }

        let now = Utc::now();
        let customer = Customer {
            id: Uuid::new_v4(),
            name: name.to_string(),
            email: email.to_string(),
            stripe_customer_id: None,
            status: "active".to_string(),
            billing_plan: "free".to_string(),
            quota_warning_sent_at: None,
            created_at: now,
            updated_at: now,
            password_hash: Some(password_hash.to_string()),
            email_verified_at: None,
            email_verify_token: None,
            email_verify_expires_at: None,
            password_reset_token: None,
            password_reset_expires_at: None,
            object_storage_egress_carryforward_cents: Decimal::ZERO,
        };
        customers.push(customer.clone());
        Ok(customer)
    }

    /// Implements `CustomerRepo::update`. Applies optional name and email patches
    /// to a non-deleted customer in the in-memory store. Returns `None` if no
    /// matching active customer is found, and `RepoError::Conflict` if the new
    /// email is already owned by a different customer.
    async fn update(
        &self,
        id: Uuid,
        name: Option<&str>,
        email: Option<&str>,
    ) -> Result<Option<Customer>, RepoError> {
        let mut customers = self.customers.lock().unwrap();

        // Check email uniqueness if changing email
        if let Some(new_email) = email {
            if customers.iter().any(|c| c.email == new_email && c.id != id) {
                return Err(RepoError::Conflict("email already exists".into()));
            }
        }

        let customer = customers
            .iter_mut()
            .find(|c| c.id == id && c.status != "deleted");

        match customer {
            Some(c) => {
                if let Some(new_name) = name {
                    c.name = new_name.to_string();
                }
                if let Some(new_email) = email {
                    c.email = new_email.to_string();
                }
                c.updated_at = Utc::now();
                Ok(Some(c.clone()))
            }
            None => Ok(None),
        }
    }

    /// Implements `CustomerRepo::soft_delete`. Sets the customer's status to
    /// `"deleted"` in the in-memory store. Returns `false` without mutating state
    /// if `fail_next_soft_delete` was armed, enabling 404 path testing. Returns
    /// `false` if no non-deleted customer with that ID is found.
    async fn soft_delete(&self, id: Uuid) -> Result<bool, RepoError> {
        if self.fail_next_soft_delete.swap(false, Ordering::SeqCst) {
            return Ok(false);
        }

        let mut customers = self.customers.lock().unwrap();
        let customer = customers
            .iter_mut()
            .find(|c| c.id == id && c.status != "deleted");

        match customer {
            Some(c) => {
                c.status = "deleted".to_string();
                c.updated_at = Utc::now();
                Ok(true)
            }
            None => Ok(false),
        }
    }

    /// Implements `CustomerRepo::set_email_verify_token`. Stores the token and
    /// expiry on the matching non-deleted customer. Returns `true` on success,
    /// `false` if no matching customer is found.
    async fn set_email_verify_token(
        &self,
        id: Uuid,
        token: &str,
        expires_at: DateTime<Utc>,
    ) -> Result<bool, RepoError> {
        let mut customers = self.customers.lock().unwrap();
        match customers
            .iter_mut()
            .find(|c| c.id == id && c.status != "deleted")
        {
            Some(c) => {
                c.email_verify_token = Some(token.to_string());
                c.email_verify_expires_at = Some(expires_at);
                Ok(true)
            }
            None => Ok(false),
        }
    }

    /// Implements `CustomerRepo::verify_email`. Looks up the customer by token,
    /// sets `email_verified_at` and clears the token fields. Returns `None` if
    /// the token is not found, belongs to a deleted customer, or has already
    /// expired (expiry is `None` or in the past).
    async fn verify_email(&self, token: &str) -> Result<Option<Customer>, RepoError> {
        let mut customers = self.customers.lock().unwrap();
        let now = Utc::now();
        match customers
            .iter_mut()
            .find(|c| c.email_verify_token.as_deref() == Some(token) && c.status != "deleted")
        {
            Some(c) => {
                if c.email_verify_expires_at.is_none_or(|exp| exp < now) {
                    return Ok(None);
                }
                c.email_verified_at = Some(now);
                c.email_verify_token = None;
                c.email_verify_expires_at = None;
                Ok(Some(c.clone()))
            }
            None => Ok(None),
        }
    }

    /// Implements `CustomerRepo::set_password_reset_token`. Stores the reset
    /// token and its expiry on the matching non-deleted customer. Returns `true`
    /// on success, `false` if no matching customer is found.
    async fn set_password_reset_token(
        &self,
        id: Uuid,
        token: &str,
        expires_at: DateTime<Utc>,
    ) -> Result<bool, RepoError> {
        let mut customers = self.customers.lock().unwrap();
        match customers
            .iter_mut()
            .find(|c| c.id == id && c.status != "deleted")
        {
            Some(c) => {
                c.password_reset_token = Some(token.to_string());
                c.password_reset_expires_at = Some(expires_at);
                Ok(true)
            }
            None => Ok(false),
        }
    }

    async fn find_by_reset_token(&self, token: &str) -> Result<Option<Customer>, RepoError> {
        let customers = self.customers.lock().unwrap();
        let now = Utc::now();
        Ok(customers
            .iter()
            .find(|c| {
                c.password_reset_token.as_deref() == Some(token)
                    && c.password_reset_expires_at.is_some_and(|exp| exp > now)
                    && c.status != "deleted"
            })
            .cloned())
    }

    /// Implements `CustomerRepo::reset_password`. Looks up the customer by reset
    /// token and updates `password_hash`, then clears the token fields. Returns
    /// `false` if the token is not found or has expired; `true` on success.
    async fn reset_password(
        &self,
        token: &str,
        new_password_hash: &str,
    ) -> Result<bool, RepoError> {
        let mut customers = self.customers.lock().unwrap();
        let now = Utc::now();
        match customers
            .iter_mut()
            .find(|c| c.password_reset_token.as_deref() == Some(token) && c.status != "deleted")
        {
            Some(c) => {
                if c.password_reset_expires_at.is_none_or(|exp| exp < now) {
                    return Ok(false);
                }
                c.password_hash = Some(new_password_hash.to_string());
                c.password_reset_token = None;
                c.password_reset_expires_at = None;
                Ok(true)
            }
            None => Ok(false),
        }
    }

    async fn change_password(&self, id: Uuid, new_password_hash: &str) -> Result<bool, RepoError> {
        let mut customers = self.customers.lock().unwrap();
        match customers
            .iter_mut()
            .find(|c| c.id == id && c.status != "deleted")
        {
            Some(c) => {
                c.password_hash = Some(new_password_hash.to_string());
                c.updated_at = Utc::now();
                Ok(true)
            }
            None => Ok(false),
        }
    }

    /// Implements `CustomerRepo::set_stripe_customer_id`. Stores the Stripe
    /// customer ID on the matching non-deleted customer. Returns `true` on
    /// success, `false` if no matching customer is found.
    async fn set_stripe_customer_id(
        &self,
        id: Uuid,
        stripe_customer_id: &str,
    ) -> Result<bool, RepoError> {
        let mut customers = self.customers.lock().unwrap();
        match customers
            .iter_mut()
            .find(|c| c.id == id && c.status != "deleted")
        {
            Some(c) => {
                c.stripe_customer_id = Some(stripe_customer_id.to_string());
                c.updated_at = Utc::now();
                Ok(true)
            }
            None => Ok(false),
        }
    }

    async fn find_by_stripe_customer_id(
        &self,
        stripe_customer_id: &str,
    ) -> Result<Option<Customer>, RepoError> {
        let customers = self.customers.lock().unwrap();
        Ok(customers
            .iter()
            .find(|c| {
                c.stripe_customer_id.as_deref() == Some(stripe_customer_id) && c.status != "deleted"
            })
            .cloned())
    }

    /// Implements `CustomerRepo::set_quota_warning_sent_at`. Records when the
    /// quota-exceeded warning email was last sent for the given customer. Returns
    /// `true` on success, `false` if no non-deleted customer is found.
    async fn set_quota_warning_sent_at(
        &self,
        id: Uuid,
        sent_at: DateTime<Utc>,
    ) -> Result<bool, RepoError> {
        let mut customers = self.customers.lock().unwrap();
        match customers
            .iter_mut()
            .find(|c| c.id == id && c.status != "deleted")
        {
            Some(c) => {
                c.quota_warning_sent_at = Some(sent_at);
                c.updated_at = Utc::now();
                Ok(true)
            }
            None => Ok(false),
        }
    }

    async fn set_billing_plan(&self, id: Uuid, plan: &str) -> Result<bool, RepoError> {
        let mut customers = self.customers.lock().unwrap();
        match customers
            .iter_mut()
            .find(|c| c.id == id && c.status != "deleted")
        {
            Some(c) => {
                c.billing_plan = plan.to_string();
                c.updated_at = Utc::now();
                Ok(true)
            }
            None => Ok(false),
        }
    }

    /// Implements `CustomerRepo::suspend`. Transitions an `"active"` customer to
    /// `"suspended"`. Returns `RepoError::Other` if `should_fail_suspend` is set
    /// (for error-path testing); returns `false` if the customer is not found or
    /// not currently active.
    async fn suspend(&self, id: Uuid) -> Result<bool, RepoError> {
        if *self.should_fail_suspend.lock().unwrap() {
            return Err(RepoError::Other("injected suspend failure".into()));
        }
        let mut customers = self.customers.lock().unwrap();
        match customers
            .iter_mut()
            .find(|c| c.id == id && c.status == "active")
        {
            Some(c) => {
                c.status = "suspended".to_string();
                c.updated_at = Utc::now();
                Ok(true)
            }
            None => Ok(false),
        }
    }

    /// Implements `CustomerRepo::reactivate`. Transitions a `"suspended"` customer
    /// back to `"active"`. Returns `RepoError::Other` if `should_fail_reactivate`
    /// is set (for error-path testing); returns `false` if the customer is not
    /// found or not currently suspended.
    async fn reactivate(&self, id: Uuid) -> Result<bool, RepoError> {
        if *self.should_fail_reactivate.lock().unwrap() {
            return Err(RepoError::Other("injected reactivate failure".into()));
        }
        let mut customers = self.customers.lock().unwrap();
        match customers
            .iter_mut()
            .find(|c| c.id == id && c.status == "suspended")
        {
            Some(c) => {
                c.status = "active".to_string();
                c.updated_at = Utc::now();
                Ok(true)
            }
            None => Ok(false),
        }
    }

    /// Implements `CustomerRepo::set_object_storage_egress_carryforward_cents`.
    /// Updates the carry-forward egress balance (in cents) for the given
    /// non-deleted customer. Returns `true` on success, `false` if not found.
    async fn set_object_storage_egress_carryforward_cents(
        &self,
        id: Uuid,
        cents: Decimal,
    ) -> Result<bool, RepoError> {
        let mut customers = self.customers.lock().unwrap();
        match customers
            .iter_mut()
            .find(|c| c.id == id && c.status != "deleted")
        {
            Some(c) => {
                c.object_storage_egress_carryforward_cents = cents;
                c.updated_at = Utc::now();
                Ok(true)
            }
            None => Ok(false),
        }
    }
}

pub fn mock_repo() -> Arc<MockCustomerRepo> {
    Arc::new(MockCustomerRepo::new())
}

/// Seed a mock customer with a Stripe customer ID for integration tests.
pub async fn seed_mock_stripe_customer(
    repo: &MockCustomerRepo,
    name: &str,
    email: &str,
) -> Customer {
    let customer = repo.seed(name, email);
    repo.set_stripe_customer_id(
        customer.id,
        &format!("cus_test_{}", &customer.id.to_string()[..8]),
    )
    .await
    .unwrap();
    repo.find_by_id(customer.id).await.unwrap().unwrap()
}

// ---------------------------------------------------------------------------
// MockDeploymentRepo
// ---------------------------------------------------------------------------

pub struct MockDeploymentRepo {
    deployments: Mutex<Vec<Deployment>>,
}

impl MockDeploymentRepo {
    pub fn new() -> Self {
        Self {
            deployments: Mutex::new(Vec::new()),
        }
    }

    /// Seed the mock with a deployment for testing.
    pub fn seed(
        &self,
        customer_id: Uuid,
        node_id: &str,
        region: &str,
        vm_type: &str,
        vm_provider: &str,
        status: &str,
    ) -> Deployment {
        let mut deployments = self.deployments.lock().unwrap();
        let now = Utc::now();
        let terminated_at = if status == "terminated" {
            Some(now)
        } else {
            None
        };
        let deployment = Deployment {
            id: Uuid::new_v4(),
            customer_id,
            node_id: node_id.to_string(),
            region: region.to_string(),
            vm_type: vm_type.to_string(),
            vm_provider: vm_provider.to_string(),
            ip_address: None,
            status: status.to_string(),
            created_at: now,
            terminated_at,
            provider_vm_id: None,
            hostname: None,
            flapjack_url: None,
            last_health_check_at: None,
            health_status: "unknown".to_string(),
        };
        deployments.push(deployment.clone());
        deployment
    }

    /// Seed the mock with a deployment that has provisioning fields set.
    #[allow(clippy::too_many_arguments)]
    pub fn seed_provisioned(
        &self,
        customer_id: Uuid,
        node_id: &str,
        region: &str,
        vm_type: &str,
        vm_provider: &str,
        status: &str,
        flapjack_url: Option<&str>,
    ) -> Deployment {
        let mut deployments = self.deployments.lock().unwrap();
        let now = Utc::now();
        let short_id = &Uuid::new_v4().to_string()[..8];
        let terminated_at = if status == "terminated" {
            Some(now)
        } else {
            None
        };
        let deployment = Deployment {
            id: Uuid::new_v4(),
            customer_id,
            node_id: node_id.to_string(),
            region: region.to_string(),
            vm_type: vm_type.to_string(),
            vm_provider: vm_provider.to_string(),
            ip_address: Some("203.0.113.1".to_string()),
            status: status.to_string(),
            created_at: now,
            terminated_at,
            provider_vm_id: Some(format!("i-{short_id}")),
            hostname: Some(format!("vm-{short_id}.flapjack.foo")),
            flapjack_url: flapjack_url.map(|s| s.to_string()),
            last_health_check_at: None,
            health_status: "unknown".to_string(),
        };
        deployments.push(deployment.clone());
        deployment
    }
}

#[async_trait]
impl DeploymentRepo for MockDeploymentRepo {
    /// Implements `DeploymentRepo::list_by_customer`. Returns all deployments for
    /// the given customer, optionally filtering out `"terminated"` ones. Results
    /// are sorted by `created_at` descending to match `PgDeploymentRepo` ordering.
    async fn list_by_customer(
        &self,
        customer_id: Uuid,
        include_terminated: bool,
    ) -> Result<Vec<Deployment>, RepoError> {
        let deployments = self.deployments.lock().unwrap();
        // Sort by created_at DESC to mirror PgDeploymentRepo ordering
        let mut result: Vec<_> = deployments
            .iter()
            .filter(|d| {
                d.customer_id == customer_id && (include_terminated || d.status != "terminated")
            })
            .cloned()
            .collect();
        result.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        Ok(result)
    }

    async fn find_by_id(&self, id: Uuid) -> Result<Option<Deployment>, RepoError> {
        let deployments = self.deployments.lock().unwrap();
        Ok(deployments.iter().find(|d| d.id == id).cloned())
    }

    /// Implements `DeploymentRepo::create`. Inserts a new deployment with status
    /// `"provisioning"` and no `provider_vm_id`, `hostname`, or `flapjack_url`.
    /// Returns `RepoError::Conflict` if a deployment with the same `node_id`
    /// already exists.
    async fn create(
        &self,
        customer_id: Uuid,
        node_id: &str,
        region: &str,
        vm_type: &str,
        vm_provider: &str,
        ip_address: Option<&str>,
    ) -> Result<Deployment, RepoError> {
        let mut deployments = self.deployments.lock().unwrap();

        if deployments.iter().any(|d| d.node_id == node_id) {
            return Err(RepoError::Conflict("node_id already exists".into()));
        }

        let now = Utc::now();
        let deployment = Deployment {
            id: Uuid::new_v4(),
            customer_id,
            node_id: node_id.to_string(),
            region: region.to_string(),
            vm_type: vm_type.to_string(),
            vm_provider: vm_provider.to_string(),
            ip_address: ip_address.map(|s| s.to_string()),
            status: "provisioning".to_string(),
            created_at: now,
            terminated_at: None,
            provider_vm_id: None,
            hostname: None,
            flapjack_url: None,
            last_health_check_at: None,
            health_status: "unknown".to_string(),
        };
        deployments.push(deployment.clone());
        Ok(deployment)
    }

    /// Implements `DeploymentRepo::update`. Applies optional `ip_address` and
    /// `status` patches to a non-terminated deployment. Also sets `terminated_at`
    /// when the new status is `"terminated"`. Returns `None` if no matching
    /// non-terminated deployment is found.
    async fn update(
        &self,
        id: Uuid,
        ip_address: Option<&str>,
        status: Option<&str>,
    ) -> Result<Option<Deployment>, RepoError> {
        let mut deployments = self.deployments.lock().unwrap();

        let deployment = deployments
            .iter_mut()
            .find(|d| d.id == id && d.status != "terminated");

        match deployment {
            Some(d) => {
                if let Some(new_ip) = ip_address {
                    d.ip_address = Some(new_ip.to_string());
                }
                if let Some(new_status) = status {
                    d.status = new_status.to_string();
                    if new_status == "terminated" {
                        d.terminated_at = Some(Utc::now());
                    }
                }
                Ok(Some(d.clone()))
            }
            None => Ok(None),
        }
    }

    /// Implements `DeploymentRepo::terminate`. Sets status to `"terminated"` and
    /// records `terminated_at` on any non-terminated deployment. Returns `true`
    /// on success, `false` if no matching non-terminated deployment is found.
    async fn terminate(&self, id: Uuid) -> Result<bool, RepoError> {
        let mut deployments = self.deployments.lock().unwrap();

        let deployment = deployments
            .iter_mut()
            .find(|d| d.id == id && d.status != "terminated");

        match deployment {
            Some(d) => {
                d.status = "terminated".to_string();
                d.terminated_at = Some(Utc::now());
                Ok(true)
            }
            None => Ok(false),
        }
    }

    async fn list_active(&self) -> Result<Vec<Deployment>, RepoError> {
        let deployments = self.deployments.lock().unwrap();
        Ok(deployments
            .iter()
            .filter(|d| d.status != "terminated" && d.flapjack_url.is_some())
            .cloned()
            .collect())
    }

    /// Implements `DeploymentRepo::update_health`. Updates `health_status` and
    /// `last_health_check_at` on any deployment (regardless of status). Returns
    /// `RepoError::NotFound` if no deployment with that ID exists.
    async fn update_health(
        &self,
        id: Uuid,
        health_status: &str,
        last_health_check_at: DateTime<Utc>,
    ) -> Result<(), RepoError> {
        let mut deployments = self.deployments.lock().unwrap();
        match deployments.iter_mut().find(|d| d.id == id) {
            Some(d) => {
                d.health_status = health_status.to_string();
                d.last_health_check_at = Some(last_health_check_at);
                Ok(())
            }
            None => Err(RepoError::NotFound),
        }
    }

    async fn claim_provisioning(&self, id: Uuid) -> Result<bool, RepoError> {
        let mut deployments = self.deployments.lock().unwrap();
        match deployments
            .iter_mut()
            .find(|d| d.id == id && d.status == "provisioning" && d.provider_vm_id.is_none())
        {
            Some(d) => {
                // Placeholder lock marker; overwritten by update_provisioning.
                d.provider_vm_id = Some(format!("provisioning-lock:{id}"));
                Ok(true)
            }
            None => Ok(false),
        }
    }

    /// Implements `DeploymentRepo::mark_failed_provisioning`. Transitions a
    /// `"provisioning"` deployment to `"failed"` and clears `provider_vm_id`,
    /// `ip_address`, `hostname`, and `flapjack_url`. Returns `true` on success,
    /// `false` if no matching `"provisioning"` deployment is found.
    async fn mark_failed_provisioning(&self, id: Uuid) -> Result<bool, RepoError> {
        let mut deployments = self.deployments.lock().unwrap();
        match deployments
            .iter_mut()
            .find(|d| d.id == id && d.status == "provisioning")
        {
            Some(d) => {
                d.status = "failed".to_string();
                d.provider_vm_id = None;
                d.ip_address = None;
                d.hostname = None;
                d.flapjack_url = None;
                Ok(true)
            }
            None => Ok(false),
        }
    }

    /// Implements `DeploymentRepo::update_provisioning`. Stores the cloud
    /// provider VM ID, assigned IP address, hostname, and Flapjack URL for a
    /// deployment once it has been provisioned. Returns `None` if no deployment
    /// with that ID exists.
    async fn update_provisioning(
        &self,
        id: Uuid,
        provider_vm_id: &str,
        ip_address: &str,
        hostname: &str,
        flapjack_url: &str,
    ) -> Result<Option<Deployment>, RepoError> {
        let mut deployments = self.deployments.lock().unwrap();
        match deployments.iter_mut().find(|d| d.id == id) {
            Some(d) => {
                d.provider_vm_id = Some(provider_vm_id.to_string());
                d.ip_address = Some(ip_address.to_string());
                d.hostname = Some(hostname.to_string());
                d.flapjack_url = Some(flapjack_url.to_string());
                Ok(Some(d.clone()))
            }
            None => Ok(None),
        }
    }
}

pub fn mock_deployment_repo() -> Arc<MockDeploymentRepo> {
    Arc::new(MockDeploymentRepo::new())
}

// ---------------------------------------------------------------------------
// MockUsageRepo
// ---------------------------------------------------------------------------

pub struct MockUsageRepo {
    rows: Mutex<Vec<UsageDaily>>,
}

impl MockUsageRepo {
    pub fn new() -> Self {
        Self {
            rows: Mutex::new(Vec::new()),
        }
    }

    /// Directly inserts a `UsageDaily` row into the in-memory store. Used in
    /// test setup to pre-populate usage data for a specific customer, date, and
    /// region without going through the repo write path.
    #[allow(clippy::too_many_arguments)]
    pub fn seed(
        &self,
        customer_id: Uuid,
        date: NaiveDate,
        region: &str,
        search_requests: i64,
        write_operations: i64,
        storage_bytes_avg: i64,
        documents_count_avg: i64,
    ) -> UsageDaily {
        let mut rows = self.rows.lock().unwrap();
        let row = UsageDaily {
            customer_id,
            date,
            region: region.to_string(),
            search_requests,
            write_operations,
            storage_bytes_avg,
            documents_count_avg,
            aggregated_at: Utc::now(),
        };
        rows.push(row.clone());
        row
    }
}

#[async_trait]
impl UsageRepo for MockUsageRepo {
    async fn get_daily_usage(
        &self,
        customer_id: Uuid,
        start_date: NaiveDate,
        end_date: NaiveDate,
    ) -> Result<Vec<UsageDaily>, RepoError> {
        let rows = self.rows.lock().unwrap();
        Ok(rows
            .iter()
            .filter(|r| r.customer_id == customer_id && r.date >= start_date && r.date <= end_date)
            .cloned()
            .collect())
    }

    /// Implements `UsageRepo::get_monthly_search_count`. Sums `search_requests`
    /// across all seeded `UsageDaily` rows for the given customer whose date
    /// falls within `[first_day_of_month, first_day_of_next_month)`. Returns
    /// `RepoError::Other` if the provided year/month values are out of range.
    async fn get_monthly_search_count(
        &self,
        customer_id: Uuid,
        year: i32,
        month: u32,
    ) -> Result<i64, RepoError> {
        let start_date = NaiveDate::from_ymd_opt(year, month, 1)
            .ok_or_else(|| RepoError::Other("invalid year/month".to_string()))?;
        let (next_year, next_month) = if month == 12 {
            (year + 1, 1)
        } else {
            (year, month + 1)
        };
        let end_date = NaiveDate::from_ymd_opt(next_year, next_month, 1)
            .ok_or_else(|| RepoError::Other("invalid year/month".to_string()))?;

        let rows = self.rows.lock().unwrap();
        Ok(rows
            .iter()
            .filter(|r| r.customer_id == customer_id && r.date >= start_date && r.date < end_date)
            .map(|r| r.search_requests)
            .sum())
    }
}

pub fn mock_usage_repo() -> Arc<MockUsageRepo> {
    Arc::new(MockUsageRepo::new())
}

// ---------------------------------------------------------------------------
// MockRateCardRepo
// ---------------------------------------------------------------------------

pub struct MockRateCardRepo {
    active_card: Mutex<Option<RateCardRow>>,
    overrides: Mutex<HashMap<(Uuid, Uuid), CustomerRateOverrideRow>>,
}

impl MockRateCardRepo {
    pub fn new() -> Self {
        Self {
            active_card: Mutex::new(None),
            overrides: Mutex::new(HashMap::new()),
        }
    }

    pub fn seed_active_card(&self, card: RateCardRow) {
        *self.active_card.lock().unwrap() = Some(card);
    }

    pub fn seed_override(&self, ov: CustomerRateOverrideRow) {
        self.overrides
            .lock()
            .unwrap()
            .insert((ov.customer_id, ov.rate_card_id), ov);
    }
}

#[async_trait]
impl RateCardRepo for MockRateCardRepo {
    async fn get_active(&self) -> Result<Option<RateCardRow>, RepoError> {
        Ok(self.active_card.lock().unwrap().clone())
    }

    async fn get_by_id(&self, id: Uuid) -> Result<Option<RateCardRow>, RepoError> {
        let card = self.active_card.lock().unwrap();
        Ok(card.as_ref().filter(|c| c.id == id).cloned())
    }

    async fn get_override(
        &self,
        customer_id: Uuid,
        rate_card_id: Uuid,
    ) -> Result<Option<CustomerRateOverrideRow>, RepoError> {
        let overrides = self.overrides.lock().unwrap();
        Ok(overrides.get(&(customer_id, rate_card_id)).cloned())
    }

    /// Implements `RateCardRepo::upsert_override`. Inserts or replaces the
    /// `CustomerRateOverrideRow` for the given `(customer_id, rate_card_id)` pair
    /// in the in-memory overrides map, setting `created_at` to now. Always
    /// succeeds — no conflict or not-found errors are produced.
    async fn upsert_override(
        &self,
        customer_id: Uuid,
        rate_card_id: Uuid,
        overrides_json: serde_json::Value,
    ) -> Result<CustomerRateOverrideRow, RepoError> {
        let mut overrides = self.overrides.lock().unwrap();
        let row = CustomerRateOverrideRow {
            customer_id,
            rate_card_id,
            overrides: overrides_json,
            created_at: Utc::now(),
        };
        overrides.insert((customer_id, rate_card_id), row.clone());
        Ok(row)
    }
}

pub fn mock_rate_card_repo() -> Arc<MockRateCardRepo> {
    Arc::new(MockRateCardRepo::new())
}

// ---------------------------------------------------------------------------
// MockInvoiceRepo
// ---------------------------------------------------------------------------

pub struct MockInvoiceRepo {
    invoices: Mutex<Vec<InvoiceRow>>,
    line_items: Mutex<Vec<InvoiceLineItemRow>>,
    fail_next_finalize: Mutex<bool>,
    fail_next_mark_paid: Mutex<bool>,
}

impl MockInvoiceRepo {
    pub fn new() -> Self {
        Self {
            invoices: Mutex::new(Vec::new()),
            line_items: Mutex::new(Vec::new()),
            fail_next_finalize: Mutex::new(false),
            fail_next_mark_paid: Mutex::new(false),
        }
    }

    pub fn fail_next_finalize(&self) {
        *self.fail_next_finalize.lock().unwrap() = true;
    }

    pub fn fail_next_mark_paid(&self) {
        *self.fail_next_mark_paid.lock().unwrap() = true;
    }

    /// Seed a pre-built invoice with line items for read-only tests.
    #[allow(clippy::too_many_arguments)]
    pub fn seed(
        &self,
        customer_id: Uuid,
        period_start: NaiveDate,
        period_end: NaiveDate,
        subtotal_cents: i64,
        total_cents: i64,
        minimum_applied: bool,
        line_items: Vec<NewLineItem>,
    ) -> InvoiceRow {
        let mut invoices = self.invoices.lock().unwrap();
        let mut stored_items = self.line_items.lock().unwrap();

        let invoice_id = Uuid::new_v4();
        let now = Utc::now();

        let invoice = InvoiceRow {
            id: invoice_id,
            customer_id,
            period_start,
            period_end,
            subtotal_cents,
            tax_cents: 0,
            total_cents,
            currency: "usd".to_string(),
            status: "draft".to_string(),
            minimum_applied,
            stripe_invoice_id: None,
            hosted_invoice_url: None,
            pdf_url: None,
            created_at: now,
            finalized_at: None,
            paid_at: None,
        };

        for li in &line_items {
            stored_items.push(InvoiceLineItemRow {
                id: Uuid::new_v4(),
                invoice_id,
                description: li.description.clone(),
                quantity: li.quantity,
                unit: li.unit.clone(),
                unit_price_cents: li.unit_price_cents,
                amount_cents: li.amount_cents,
                region: li.region.clone(),
                metadata: li.metadata.clone(),
            });
        }

        invoices.push(invoice.clone());
        invoice
    }
}

#[async_trait]
impl InvoiceRepo for MockInvoiceRepo {
    /// Implements `InvoiceRepo::create_with_line_items`. Creates a new `"draft"`
    /// invoice and its line items atomically in the in-memory store. Enforces
    /// uniqueness on `(customer_id, period_start, period_end)`, returning
    /// `RepoError::Conflict` if a duplicate is detected.
    async fn create_with_line_items(
        &self,
        invoice: NewInvoice,
        line_items: Vec<NewLineItem>,
    ) -> Result<(InvoiceRow, Vec<InvoiceLineItemRow>), RepoError> {
        let mut invoices = self.invoices.lock().unwrap();
        let mut stored_items = self.line_items.lock().unwrap();

        // Enforce unique (customer_id, period_start, period_end)
        if invoices.iter().any(|i| {
            i.customer_id == invoice.customer_id
                && i.period_start == invoice.period_start
                && i.period_end == invoice.period_end
        }) {
            return Err(RepoError::Conflict(
                "invoice already exists for this period".into(),
            ));
        }

        let invoice_id = Uuid::new_v4();
        let now = Utc::now();

        let row = InvoiceRow {
            id: invoice_id,
            customer_id: invoice.customer_id,
            period_start: invoice.period_start,
            period_end: invoice.period_end,
            subtotal_cents: invoice.subtotal_cents,
            tax_cents: 0,
            total_cents: invoice.total_cents,
            currency: "usd".to_string(),
            status: "draft".to_string(),
            minimum_applied: invoice.minimum_applied,
            stripe_invoice_id: None,
            hosted_invoice_url: None,
            pdf_url: None,
            created_at: now,
            finalized_at: None,
            paid_at: None,
        };

        let mut created_items = Vec::with_capacity(line_items.len());
        for li in &line_items {
            let item = InvoiceLineItemRow {
                id: Uuid::new_v4(),
                invoice_id,
                description: li.description.clone(),
                quantity: li.quantity,
                unit: li.unit.clone(),
                unit_price_cents: li.unit_price_cents,
                amount_cents: li.amount_cents,
                region: li.region.clone(),
                metadata: li.metadata.clone(),
            };
            created_items.push(item.clone());
            stored_items.push(item);
        }

        invoices.push(row.clone());
        Ok((row, created_items))
    }

    async fn list_by_customer(&self, customer_id: Uuid) -> Result<Vec<InvoiceRow>, RepoError> {
        let invoices = self.invoices.lock().unwrap();
        let mut result: Vec<InvoiceRow> = invoices
            .iter()
            .filter(|i| i.customer_id == customer_id)
            .cloned()
            .collect();
        result.sort_by(|a, b| b.period_start.cmp(&a.period_start));
        Ok(result)
    }

    async fn find_by_id(&self, id: Uuid) -> Result<Option<InvoiceRow>, RepoError> {
        let invoices = self.invoices.lock().unwrap();
        Ok(invoices.iter().find(|i| i.id == id).cloned())
    }

    async fn get_line_items(&self, invoice_id: Uuid) -> Result<Vec<InvoiceLineItemRow>, RepoError> {
        let items = self.line_items.lock().unwrap();
        let mut result: Vec<InvoiceLineItemRow> = items
            .iter()
            .filter(|li| li.invoice_id == invoice_id)
            .cloned()
            .collect();
        result.sort_by(|a, b| (&a.region, &a.unit).cmp(&(&b.region, &b.unit)));
        Ok(result)
    }

    /// Implements `InvoiceRepo::finalize`. Transitions a `"draft"` invoice to
    /// `"finalized"` and sets `finalized_at`. Returns `RepoError::Conflict` if
    /// the invoice is not in `"draft"` status or does not exist. Honors the
    /// `fail_next_finalize` latch for error-path testing (latch is consumed
    /// on use, returning `RepoError::Other`).
    async fn finalize(&self, id: Uuid) -> Result<InvoiceRow, RepoError> {
        {
            let mut fail_once = self.fail_next_finalize.lock().unwrap();
            if *fail_once {
                *fail_once = false;
                return Err(RepoError::Other("injected finalize failure".into()));
            }
        }

        let mut invoices = self.invoices.lock().unwrap();
        match invoices.iter_mut().find(|i| i.id == id) {
            Some(inv) if inv.status == "draft" => {
                inv.status = "finalized".to_string();
                inv.finalized_at = Some(Utc::now());
                Ok(inv.clone())
            }
            Some(_) => Err(RepoError::Conflict(
                "invoice not found or not in draft status".into(),
            )),
            None => Err(RepoError::Conflict(
                "invoice not found or not in draft status".into(),
            )),
        }
    }

    /// Implements `InvoiceRepo::mark_paid`. Transitions a `"finalized"` or
    /// `"failed"` invoice to `"paid"` and sets `paid_at`. Returns
    /// `RepoError::Conflict` if the invoice is not in an eligible status or does
    /// not exist. Honors the `fail_next_mark_paid` latch for error-path testing
    /// (latch is consumed on use, returning `RepoError::Other`).
    async fn mark_paid(&self, id: Uuid) -> Result<InvoiceRow, RepoError> {
        {
            let mut fail_once = self.fail_next_mark_paid.lock().unwrap();
            if *fail_once {
                *fail_once = false;
                return Err(RepoError::Other("injected mark_paid failure".into()));
            }
        }

        let mut invoices = self.invoices.lock().unwrap();
        match invoices.iter_mut().find(|i| i.id == id) {
            Some(inv) if inv.status == "finalized" || inv.status == "failed" => {
                inv.status = "paid".to_string();
                inv.paid_at = Some(Utc::now());
                Ok(inv.clone())
            }
            Some(_) => Err(RepoError::Conflict(
                "invoice not found or not in finalized/failed status".into(),
            )),
            None => Err(RepoError::Conflict(
                "invoice not found or not in finalized/failed status".into(),
            )),
        }
    }

    async fn mark_failed(&self, id: Uuid) -> Result<InvoiceRow, RepoError> {
        let mut invoices = self.invoices.lock().unwrap();
        match invoices.iter_mut().find(|i| i.id == id) {
            Some(inv) if inv.status == "finalized" => {
                inv.status = "failed".to_string();
                Ok(inv.clone())
            }
            Some(_) => Err(RepoError::Conflict(
                "invoice not found or not in finalized status".into(),
            )),
            None => Err(RepoError::Conflict(
                "invoice not found or not in finalized status".into(),
            )),
        }
    }

    async fn mark_refunded(&self, id: Uuid) -> Result<InvoiceRow, RepoError> {
        let mut invoices = self.invoices.lock().unwrap();
        match invoices.iter_mut().find(|i| i.id == id) {
            Some(inv) if inv.status == "paid" => {
                inv.status = "refunded".to_string();
                Ok(inv.clone())
            }
            Some(_) => Err(RepoError::Conflict(
                "invoice not found or not in paid status".into(),
            )),
            None => Err(RepoError::Conflict(
                "invoice not found or not in paid status".into(),
            )),
        }
    }

    /// Implements `InvoiceRepo::set_stripe_fields`. Stores the Stripe invoice ID,
    /// hosted URL, and optional PDF URL on the given invoice. Returns
    /// `RepoError::NotFound` if no invoice with that ID exists.
    async fn set_stripe_fields(
        &self,
        id: Uuid,
        stripe_invoice_id: &str,
        hosted_invoice_url: &str,
        pdf_url: Option<&str>,
    ) -> Result<(), RepoError> {
        let mut invoices = self.invoices.lock().unwrap();
        match invoices.iter_mut().find(|i| i.id == id) {
            Some(inv) => {
                inv.stripe_invoice_id = Some(stripe_invoice_id.to_string());
                inv.hosted_invoice_url = Some(hosted_invoice_url.to_string());
                inv.pdf_url = pdf_url.map(|s| s.to_string());
                Ok(())
            }
            None => Err(RepoError::NotFound),
        }
    }

    async fn find_by_stripe_invoice_id(
        &self,
        stripe_invoice_id: &str,
    ) -> Result<Option<InvoiceRow>, RepoError> {
        let invoices = self.invoices.lock().unwrap();
        Ok(invoices
            .iter()
            .find(|i| i.stripe_invoice_id.as_deref() == Some(stripe_invoice_id))
            .cloned())
    }
}

pub fn mock_invoice_repo() -> Arc<MockInvoiceRepo> {
    Arc::new(MockInvoiceRepo::new())
}

// ---------------------------------------------------------------------------
// MockStripeService
// ---------------------------------------------------------------------------

type CheckoutSessionCall = (
    String,
    String,
    String,
    String,
    Option<std::collections::HashMap<String, String>>,
);

pub struct MockStripeService {
    pub customers: Mutex<Vec<(String, String, String)>>, // (id, name, email)
    pub payment_methods: Mutex<Vec<PaymentMethodSummary>>,
    pub default_pm: Mutex<Option<String>>,
    pub invoices_created: Mutex<Vec<FinalizedInvoice>>,
    pub should_fail: Mutex<bool>,
    pub checkout_sessions: Mutex<Vec<CheckoutSessionResponse>>,
    pub checkout_session_calls: Mutex<Vec<CheckoutSessionCall>>,
    // (customer_id, price_id, success_url, cancel_url, metadata)
    pub cancel_subscription_calls: Mutex<Vec<(String, bool)>>, // (subscription_id, cancel_at_period_end)
    pub update_subscription_calls: Mutex<Vec<(String, String, String)>>, // (subscription_id, new_price_id, proration_behavior)
    pub create_and_finalize_calls: Mutex<Vec<(String, Option<String>)>>, // (customer_id, idempotency_key)
    pub subscriptions: Mutex<Vec<SubscriptionData>>,
}

impl MockStripeService {
    pub fn new() -> Self {
        Self {
            customers: Mutex::new(Vec::new()),
            payment_methods: Mutex::new(Vec::new()),
            default_pm: Mutex::new(None),
            invoices_created: Mutex::new(Vec::new()),
            should_fail: Mutex::new(false),
            checkout_sessions: Mutex::new(Vec::new()),
            checkout_session_calls: Mutex::new(Vec::new()),
            cancel_subscription_calls: Mutex::new(Vec::new()),
            update_subscription_calls: Mutex::new(Vec::new()),
            create_and_finalize_calls: Mutex::new(Vec::new()),
            subscriptions: Mutex::new(Vec::new()),
        }
    }

    pub fn set_should_fail(&self, fail: bool) {
        *self.should_fail.lock().unwrap() = fail;
    }

    pub fn seed_payment_method(&self, pm: PaymentMethodSummary) {
        self.payment_methods.lock().unwrap().push(pm);
    }

    pub fn seed_subscription(&self, subscription: SubscriptionData) {
        self.subscriptions.lock().unwrap().push(subscription);
    }
}

#[async_trait]
impl StripeService for MockStripeService {
    async fn create_customer(&self, name: &str, email: &str) -> Result<String, StripeError> {
        if *self.should_fail.lock().unwrap() {
            return Err(StripeError::Api("mock failure".into()));
        }
        let id = format!(
            "cus_mock_{}",
            Uuid::new_v4().to_string().split('-').next().unwrap()
        );
        self.customers
            .lock()
            .unwrap()
            .push((id.clone(), name.to_string(), email.to_string()));
        Ok(id)
    }

    async fn create_setup_intent(&self, stripe_customer_id: &str) -> Result<String, StripeError> {
        if *self.should_fail.lock().unwrap() {
            return Err(StripeError::Api("mock failure".into()));
        }
        Ok(format!("seti_secret_{stripe_customer_id}"))
    }

    /// Implements `StripeService::list_payment_methods`. Returns all seeded
    /// `PaymentMethodSummary` entries, annotating each with `is_default` by
    /// comparing against the stored default PM ID. The `_stripe_customer_id`
    /// argument is ignored — all seeded methods are returned. Returns
    /// `StripeError::Api` if `should_fail` is set.
    async fn list_payment_methods(
        &self,
        _stripe_customer_id: &str,
    ) -> Result<Vec<PaymentMethodSummary>, StripeError> {
        if *self.should_fail.lock().unwrap() {
            return Err(StripeError::Api("mock failure".into()));
        }
        let default_pm = self.default_pm.lock().unwrap().clone();
        let pms = self.payment_methods.lock().unwrap();
        Ok(pms
            .iter()
            .map(|pm| PaymentMethodSummary {
                is_default: default_pm.as_deref() == Some(&pm.id),
                ..pm.clone()
            })
            .collect())
    }

    async fn detach_payment_method(&self, pm_id: &str) -> Result<(), StripeError> {
        if *self.should_fail.lock().unwrap() {
            return Err(StripeError::Api("mock failure".into()));
        }
        let mut pms = self.payment_methods.lock().unwrap();
        pms.retain(|p| p.id != pm_id);
        Ok(())
    }

    async fn set_default_payment_method(
        &self,
        _stripe_customer_id: &str,
        pm_id: &str,
    ) -> Result<(), StripeError> {
        if *self.should_fail.lock().unwrap() {
            return Err(StripeError::Api("mock failure".into()));
        }
        *self.default_pm.lock().unwrap() = Some(pm_id.to_string());
        Ok(())
    }

    /// Implements `StripeService::create_and_finalize_invoice`. Records the call
    /// (customer_id + idempotency_key) in `create_and_finalize_calls`, then
    /// returns a synthetic `FinalizedInvoice` with a mock Stripe invoice ID and
    /// a hardcoded hosted/PDF URL. Line items and metadata are not inspected.
    /// Returns `StripeError::Api` if `should_fail` is set.
    async fn create_and_finalize_invoice(
        &self,
        stripe_customer_id: &str,
        _line_items: &[StripeInvoiceLineItem],
        _metadata: Option<&std::collections::HashMap<String, String>>,
        idempotency_key: Option<&str>,
    ) -> Result<FinalizedInvoice, StripeError> {
        if *self.should_fail.lock().unwrap() {
            return Err(StripeError::Api("mock failure".into()));
        }
        self.create_and_finalize_calls.lock().unwrap().push((
            stripe_customer_id.to_string(),
            idempotency_key.map(|v| v.to_string()),
        ));
        let inv = FinalizedInvoice {
            stripe_invoice_id: format!(
                "in_mock_{}",
                Uuid::new_v4().to_string().split('-').next().unwrap()
            ),
            hosted_invoice_url: "https://invoice.stripe.com/mock".to_string(),
            pdf_url: Some("https://invoice.stripe.com/mock/pdf".to_string()),
        };
        self.invoices_created.lock().unwrap().push(inv.clone());
        Ok(inv)
    }

    /// Implements `StripeService::construct_webhook_event`. Skips real HMAC
    /// signature verification — parses the raw JSON payload directly and
    /// extracts `id`, `type`, and `data` fields. Returns
    /// `StripeError::WebhookVerification` if `should_fail` is set or the
    /// payload is not valid JSON.
    fn construct_webhook_event(
        &self,
        payload: &str,
        _signature: &str,
        _secret: &str,
    ) -> Result<StripeEvent, StripeError> {
        if *self.should_fail.lock().unwrap() {
            return Err(StripeError::WebhookVerification("mock failure".into()));
        }
        let parsed: serde_json::Value = serde_json::from_str(payload)
            .map_err(|e| StripeError::WebhookVerification(e.to_string()))?;
        Ok(StripeEvent {
            id: parsed["id"].as_str().unwrap_or("evt_mock").to_string(),
            event_type: parsed["type"].as_str().unwrap_or("unknown").to_string(),
            data: parsed["data"].clone(),
        })
    }

    /// Implements `StripeService::create_checkout_session`. Records all call
    /// arguments in `checkout_session_calls`, then returns a synthetic
    /// `CheckoutSessionResponse` with a mock session ID and a hardcoded URL.
    /// Returns `StripeError::Api` if `should_fail` is set.
    async fn create_checkout_session(
        &self,
        stripe_customer_id: &str,
        price_id: &str,
        success_url: &str,
        cancel_url: &str,
        metadata: Option<&std::collections::HashMap<String, String>>,
    ) -> Result<CheckoutSessionResponse, StripeError> {
        if *self.should_fail.lock().unwrap() {
            return Err(StripeError::Api("mock failure".into()));
        }
        self.checkout_session_calls.lock().unwrap().push((
            stripe_customer_id.to_string(),
            price_id.to_string(),
            success_url.to_string(),
            cancel_url.to_string(),
            metadata.cloned(),
        ));
        let session = CheckoutSessionResponse {
            id: format!(
                "cs_mock_{}",
                Uuid::new_v4().to_string().split('-').next().unwrap()
            ),
            url: "https://checkout.stripe.com/mock".to_string(),
        };
        self.checkout_sessions.lock().unwrap().push(session.clone());
        Ok(session)
    }

    async fn retrieve_subscription(
        &self,
        subscription_id: &str,
    ) -> Result<SubscriptionData, StripeError> {
        if *self.should_fail.lock().unwrap() {
            return Err(StripeError::Api("mock failure".into()));
        }
        let subscriptions = self.subscriptions.lock().unwrap();
        subscriptions
            .iter()
            .find(|s| s.id == subscription_id)
            .cloned()
            .ok_or_else(|| StripeError::Api("subscription not found".into()))
    }

    /// Implements `StripeService::cancel_subscription`. Records the call in
    /// `cancel_subscription_calls`, then mutates the matching seeded
    /// `SubscriptionData`: sets `cancel_at_period_end` and, if immediate
    /// cancellation is requested, sets status to `"canceled"`. Returns
    /// `StripeError::Api` if `should_fail` is set or the subscription is not
    /// found in the seeded list.
    async fn cancel_subscription(
        &self,
        subscription_id: &str,
        cancel_at_period_end: bool,
    ) -> Result<SubscriptionData, StripeError> {
        if *self.should_fail.lock().unwrap() {
            return Err(StripeError::Api("mock failure".into()));
        }
        self.cancel_subscription_calls
            .lock()
            .unwrap()
            .push((subscription_id.to_string(), cancel_at_period_end));
        let mut subscriptions = self.subscriptions.lock().unwrap();
        if let Some(sub) = subscriptions.iter_mut().find(|s| s.id == subscription_id) {
            sub.cancel_at_period_end = cancel_at_period_end;
            if !cancel_at_period_end {
                sub.status = "canceled".to_string();
            }
            return Ok(sub.clone());
        }
        Err(StripeError::Api("subscription not found".into()))
    }

    /// Implements `StripeService::update_subscription_price`. Records the call
    /// in `update_subscription_calls`, then updates the `price_id` on the first
    /// item of the matching seeded `SubscriptionData`. Returns `StripeError::Api`
    /// if `should_fail` is set or the subscription is not found.
    async fn update_subscription_price(
        &self,
        subscription_id: &str,
        new_price_id: &str,
        proration_behavior: &str,
    ) -> Result<SubscriptionData, StripeError> {
        if *self.should_fail.lock().unwrap() {
            return Err(StripeError::Api("mock failure".into()));
        }
        self.update_subscription_calls.lock().unwrap().push((
            subscription_id.to_string(),
            new_price_id.to_string(),
            proration_behavior.to_string(),
        ));
        let mut subscriptions = self.subscriptions.lock().unwrap();
        if let Some(sub) = subscriptions.iter_mut().find(|s| s.id == subscription_id) {
            if let Some(item) = sub.items.first_mut() {
                item.price_id = new_price_id.to_string();
            }
            return Ok(sub.clone());
        }
        Err(StripeError::Api("subscription not found".into()))
    }
}

pub fn mock_stripe_service() -> Arc<MockStripeService> {
    Arc::new(MockStripeService::new())
}

pub fn mock_email_service() -> Arc<MockEmailService> {
    Arc::new(MockEmailService::new())
}

// ---------------------------------------------------------------------------
// MockWebhookEventRepo
// ---------------------------------------------------------------------------

pub struct MockWebhookEventRepo {
    events: Mutex<HashMap<String, bool>>,
}

impl MockWebhookEventRepo {
    pub fn new() -> Self {
        Self {
            events: Mutex::new(HashMap::new()),
        }
    }

    /// Return the number of unique events stored.
    pub fn event_count(&self) -> usize {
        self.events.lock().unwrap().len()
    }
}

#[async_trait]
impl WebhookEventRepo for MockWebhookEventRepo {
    /// Implements `WebhookEventRepo::try_insert`. Provides idempotency for
    /// incoming Stripe webhook events. The internal map stores each event ID as
    /// `false` (pending) when first seen, or `true` once marked processed.
    /// Returns `true` (process it) if the event has never been seen or is still
    /// pending; returns `false` (already handled) if it has been marked
    /// processed. `_event_type` and `_payload` are not stored.
    async fn try_insert(
        &self,
        stripe_event_id: &str,
        _event_type: &str,
        _payload: &serde_json::Value,
    ) -> Result<bool, RepoError> {
        let mut events = self.events.lock().unwrap();
        match events.get(stripe_event_id).copied() {
            Some(true) => Ok(false),
            Some(false) => Ok(true),
            None => {
                events.insert(stripe_event_id.to_string(), false);
                Ok(true)
            }
        }
    }

    async fn mark_processed(&self, stripe_event_id: &str) -> Result<(), RepoError> {
        let mut events = self.events.lock().unwrap();
        events.insert(stripe_event_id.to_string(), true);
        Ok(())
    }
}

pub fn mock_webhook_event_repo() -> Arc<MockWebhookEventRepo> {
    Arc::new(MockWebhookEventRepo::new())
}

pub fn mock_vm_provisioner() -> Arc<MockVmProvisioner> {
    Arc::new(MockVmProvisioner::new())
}

pub fn mock_dns_manager() -> Arc<MockDnsManager> {
    Arc::new(MockDnsManager::new())
}

pub fn mock_node_secret_manager() -> Arc<MockNodeSecretManager> {
    Arc::new(MockNodeSecretManager::new())
}

pub fn mock_flapjack_proxy() -> Arc<FlapjackProxy> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .unwrap();
    Arc::new(FlapjackProxy::new(client, mock_node_secret_manager()))
}

pub fn mock_alert_service() -> Arc<MockAlertService> {
    Arc::new(MockAlertService::new())
}

// ---------------------------------------------------------------------------
// MockApiKeyRepo
// ---------------------------------------------------------------------------

pub struct MockApiKeyRepo {
    keys: Mutex<Vec<ApiKeyRow>>,
}

impl MockApiKeyRepo {
    pub fn new() -> Self {
        Self {
            keys: Mutex::new(Vec::new()),
        }
    }

    /// Directly inserts an `ApiKeyRow` into the in-memory store. Used in test
    /// setup to pre-populate API keys without going through the `create` path —
    /// useful when the plain-text key value is needed for auth header tests.
    pub fn seed(
        &self,
        customer_id: Uuid,
        name: &str,
        key_hash: &str,
        key_prefix: &str,
        scopes: Vec<String>,
    ) -> ApiKeyRow {
        let mut keys = self.keys.lock().unwrap();
        let row = ApiKeyRow {
            id: Uuid::new_v4(),
            customer_id,
            name: name.to_string(),
            key_prefix: key_prefix.to_string(),
            key_hash: key_hash.to_string(),
            scopes,
            last_used_at: None,
            created_at: Utc::now(),
            revoked_at: None,
        };
        keys.push(row.clone());
        row
    }
}

#[async_trait]
impl ApiKeyRepo for MockApiKeyRepo {
    /// Implements `ApiKeyRepo::create`. Inserts a new `ApiKeyRow` with no
    /// `revoked_at` or `last_used_at`. Always succeeds — does not enforce
    /// uniqueness on the key hash or prefix (use `seed` directly for controlled
    /// test setup when exact field values matter).
    async fn create(
        &self,
        customer_id: Uuid,
        name: &str,
        key_hash: &str,
        key_prefix: &str,
        scopes: &[String],
    ) -> Result<ApiKeyRow, RepoError> {
        let mut keys = self.keys.lock().unwrap();
        let row = ApiKeyRow {
            id: Uuid::new_v4(),
            customer_id,
            name: name.to_string(),
            key_prefix: key_prefix.to_string(),
            key_hash: key_hash.to_string(),
            scopes: scopes.to_vec(),
            last_used_at: None,
            created_at: Utc::now(),
            revoked_at: None,
        };
        keys.push(row.clone());
        Ok(row)
    }

    async fn list_by_customer(&self, customer_id: Uuid) -> Result<Vec<ApiKeyRow>, RepoError> {
        let keys = self.keys.lock().unwrap();
        Ok(keys
            .iter()
            .filter(|k| k.customer_id == customer_id && k.revoked_at.is_none())
            .cloned()
            .collect())
    }

    async fn find_by_id(&self, id: Uuid) -> Result<Option<ApiKeyRow>, RepoError> {
        let keys = self.keys.lock().unwrap();
        Ok(keys.iter().find(|k| k.id == id).cloned())
    }

    async fn find_by_prefix(&self, key_prefix: &str) -> Result<Vec<ApiKeyRow>, RepoError> {
        let keys = self.keys.lock().unwrap();
        Ok(keys
            .iter()
            .filter(|k| k.key_prefix == key_prefix && k.revoked_at.is_none())
            .cloned()
            .collect())
    }

    async fn revoke(&self, id: Uuid) -> Result<ApiKeyRow, RepoError> {
        let mut keys = self.keys.lock().unwrap();
        match keys
            .iter_mut()
            .find(|k| k.id == id && k.revoked_at.is_none())
        {
            Some(k) => {
                k.revoked_at = Some(Utc::now());
                Ok(k.clone())
            }
            None => Err(RepoError::Conflict(
                "key not found or already revoked".into(),
            )),
        }
    }

    async fn update_last_used(&self, id: Uuid) -> Result<(), RepoError> {
        let mut keys = self.keys.lock().unwrap();
        match keys.iter_mut().find(|k| k.id == id) {
            Some(k) => {
                k.last_used_at = Some(Utc::now());
                Ok(())
            }
            None => Err(RepoError::NotFound),
        }
    }
}

pub fn mock_api_key_repo() -> Arc<MockApiKeyRepo> {
    Arc::new(MockApiKeyRepo::new())
}

// ---------------------------------------------------------------------------
// MockVmInventoryRepo
// ---------------------------------------------------------------------------

pub struct MockVmInventoryRepo {
    vms: Mutex<Vec<VmInventory>>,
    get_calls: Mutex<usize>,
    create_calls: Mutex<usize>,
    pub should_fail: Arc<AtomicBool>,
}

impl MockVmInventoryRepo {
    pub fn new() -> Self {
        Self {
            vms: Mutex::new(Vec::new()),
            get_calls: Mutex::new(0),
            create_calls: Mutex::new(0),
            should_fail: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn get_call_count(&self) -> usize {
        *self.get_calls.lock().unwrap()
    }

    pub fn create_call_count(&self) -> usize {
        *self.create_calls.lock().unwrap()
    }

    pub fn set_should_fail(&self, fail: bool) {
        self.should_fail.store(fail, Ordering::SeqCst);
    }

    fn check_failure(&self) -> Result<(), RepoError> {
        if self.should_fail.load(Ordering::SeqCst) {
            Err(RepoError::Other("mock vm inventory failure".to_string()))
        } else {
            Ok(())
        }
    }

    /// Seed a shared VM for testing. Returns the VmInventory entry.
    pub fn seed(&self, region: &str, flapjack_url: &str) -> VmInventory {
        let mut vms = self.vms.lock().unwrap();
        let now = Utc::now();
        let hostname = flapjack_url
            .strip_prefix("https://")
            .or_else(|| flapjack_url.strip_prefix("http://"))
            .unwrap_or(flapjack_url)
            .to_string();
        let entry = VmInventory {
            id: Uuid::new_v4(),
            region: region.to_string(),
            provider: "aws".to_string(),
            hostname,
            flapjack_url: flapjack_url.to_string(),
            capacity: serde_json::json!({}),
            current_load: serde_json::json!({}),
            load_scraped_at: None,
            status: "active".to_string(),
            created_at: now,
            updated_at: now,
        };
        vms.push(entry.clone());
        entry
    }
}

#[async_trait]
impl VmInventoryRepo for MockVmInventoryRepo {
    async fn list_active(&self, region: Option<&str>) -> Result<Vec<VmInventory>, RepoError> {
        self.check_failure()?;
        let vms = self.vms.lock().unwrap();
        let results: Vec<VmInventory> = vms
            .iter()
            .filter(|v| v.status == "active")
            .filter(|v| region.is_none_or(|r| v.region == r))
            .cloned()
            .collect();
        Ok(results)
    }

    async fn get(&self, id: Uuid) -> Result<Option<VmInventory>, RepoError> {
        let mut calls = self.get_calls.lock().unwrap();
        *calls += 1;
        let vms = self.vms.lock().unwrap();
        Ok(vms.iter().find(|v| v.id == id).cloned())
    }

    /// Implements `VmInventoryRepo::create`. Inserts a new `VmInventory` entry
    /// with status `"active"`, empty `current_load`, and no `load_scraped_at`.
    /// Increments the internal `create_calls` counter so tests can assert
    /// invocation counts. Returns `RepoError::Other` if `should_fail` is set.
    async fn create(&self, vm: NewVmInventory) -> Result<VmInventory, RepoError> {
        let mut calls = self.create_calls.lock().unwrap();
        *calls += 1;
        drop(calls);
        self.check_failure()?;
        let mut vms = self.vms.lock().unwrap();
        let now = Utc::now();
        let entry = VmInventory {
            id: Uuid::new_v4(),
            region: vm.region,
            provider: vm.provider,
            hostname: vm.hostname,
            flapjack_url: vm.flapjack_url,
            capacity: vm.capacity,
            current_load: serde_json::json!({}),
            load_scraped_at: None,
            status: "active".to_string(),
            created_at: now,
            updated_at: now,
        };
        vms.push(entry.clone());
        Ok(entry)
    }

    async fn update_load(&self, id: Uuid, load: serde_json::Value) -> Result<(), RepoError> {
        let mut vms = self.vms.lock().unwrap();
        if let Some(vm) = vms.iter_mut().find(|v| v.id == id) {
            vm.current_load = load;
            vm.load_scraped_at = Some(Utc::now());
            vm.updated_at = Utc::now();
            Ok(())
        } else {
            Err(RepoError::NotFound)
        }
    }

    async fn set_status(&self, id: Uuid, status: &str) -> Result<(), RepoError> {
        let mut vms = self.vms.lock().unwrap();
        if let Some(vm) = vms.iter_mut().find(|v| v.id == id) {
            vm.status = status.to_string();
            vm.updated_at = Utc::now();
            Ok(())
        } else {
            Err(RepoError::NotFound)
        }
    }

    async fn find_by_hostname(&self, hostname: &str) -> Result<Option<VmInventory>, RepoError> {
        let vms = self.vms.lock().unwrap();
        Ok(vms.iter().find(|v| v.hostname == hostname).cloned())
    }
}

pub fn mock_vm_inventory_repo() -> Arc<MockVmInventoryRepo> {
    Arc::new(MockVmInventoryRepo::new())
}

pub fn mock_discovery_service() -> Arc<api::services::discovery::DiscoveryService> {
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let index_replica_repo = Arc::new(InMemoryIndexReplicaRepo::new());
    Arc::new(
        api::services::discovery::DiscoveryService::new(tenant_repo, vm_inventory_repo)
            .with_replica_repo(index_replica_repo),
    )
}

// ---------------------------------------------------------------------------
// MockIndexMigrationRepo
// ---------------------------------------------------------------------------

pub struct MockIndexMigrationRepo {
    rows: Mutex<Vec<IndexMigration>>,
}

impl MockIndexMigrationRepo {
    pub fn new() -> Self {
        Self {
            rows: Mutex::new(Vec::new()),
        }
    }

    fn active_status(status: &str) -> bool {
        matches!(status, "pending" | "replicating" | "cutting_over")
    }

    /// Directly inserts an `IndexMigration` row into the in-memory store with
    /// the given status. Used in test setup to pre-populate migrations in
    /// arbitrary states (e.g., `"replicating"`, `"completed"`) without going
    /// through the `create` path.
    pub fn seed(
        &self,
        index_name: &str,
        customer_id: Uuid,
        source_vm_id: Uuid,
        dest_vm_id: Uuid,
        status: &str,
    ) -> IndexMigration {
        let row = IndexMigration {
            id: Uuid::new_v4(),
            index_name: index_name.to_string(),
            customer_id,
            source_vm_id,
            dest_vm_id,
            status: status.to_string(),
            requested_by: "test".to_string(),
            started_at: Utc::now(),
            completed_at: None,
            error: None,
            metadata: serde_json::json!({}),
        };
        self.rows.lock().unwrap().push(row.clone());
        row
    }
}

#[async_trait]
impl IndexMigrationRepo for MockIndexMigrationRepo {
    async fn get(&self, id: Uuid) -> Result<Option<IndexMigration>, RepoError> {
        let rows = self.rows.lock().unwrap();
        Ok(rows.iter().find(|r| r.id == id).cloned())
    }

    /// Implements `IndexMigrationRepo::create`. Creates a new `IndexMigration`
    /// with status `"pending"`, `started_at` set to now, and empty `metadata`.
    /// Always succeeds — no duplicate detection is performed.
    async fn create(&self, req: &MigrationRequest) -> Result<IndexMigration, RepoError> {
        let row = IndexMigration {
            id: Uuid::new_v4(),
            index_name: req.index_name.clone(),
            customer_id: req.customer_id,
            source_vm_id: req.source_vm_id,
            dest_vm_id: req.dest_vm_id,
            status: "pending".to_string(),
            requested_by: req.requested_by.clone(),
            started_at: Utc::now(),
            completed_at: None,
            error: None,
            metadata: serde_json::json!({}),
        };
        self.rows.lock().unwrap().push(row.clone());
        Ok(row)
    }

    async fn update_status(
        &self,
        id: Uuid,
        status: &str,
        error: Option<&str>,
    ) -> Result<(), RepoError> {
        let mut rows = self.rows.lock().unwrap();
        if let Some(row) = rows.iter_mut().find(|r| r.id == id) {
            row.status = status.to_string();
            row.error = error.map(str::to_string);
            return Ok(());
        }
        Err(RepoError::NotFound)
    }

    async fn set_completed(&self, id: Uuid) -> Result<(), RepoError> {
        let mut rows = self.rows.lock().unwrap();
        if let Some(row) = rows.iter_mut().find(|r| r.id == id) {
            row.status = "completed".to_string();
            row.completed_at = Some(Utc::now());
            row.error = None;
            return Ok(());
        }
        Err(RepoError::NotFound)
    }

    async fn list_active(&self) -> Result<Vec<IndexMigration>, RepoError> {
        let rows = self.rows.lock().unwrap();
        Ok(rows
            .iter()
            .filter(|r| Self::active_status(&r.status))
            .cloned()
            .collect())
    }

    async fn list_recent(&self, limit: i64) -> Result<Vec<IndexMigration>, RepoError> {
        if limit <= 0 {
            return Ok(Vec::new());
        }
        let mut rows = self.rows.lock().unwrap().clone();
        rows.sort_by(|a, b| b.started_at.cmp(&a.started_at));
        rows.truncate(limit as usize);
        Ok(rows)
    }

    async fn count_active(&self) -> Result<i64, RepoError> {
        let rows = self.rows.lock().unwrap();
        Ok(rows
            .iter()
            .filter(|r| Self::active_status(&r.status))
            .count() as i64)
    }
}

pub fn mock_index_migration_repo() -> Arc<MockIndexMigrationRepo> {
    Arc::new(MockIndexMigrationRepo::new())
}

// ---------------------------------------------------------------------------
// MockTenantRepo
// ---------------------------------------------------------------------------

/// Deployment metadata stored alongside tenants for producing `CustomerTenantSummary` results.
#[derive(Clone)]
struct DeploymentInfo {
    id: Uuid,
    region: String,
    flapjack_url: Option<String>,
    health_status: String,
    status: String,
}

pub struct MockTenantRepo {
    tenants: Mutex<Vec<CustomerTenant>>,
    deployments: Mutex<HashMap<Uuid, DeploymentInfo>>,
    find_raw_calls: Mutex<usize>,
    last_accessed_updates: Mutex<Vec<(Uuid, String, DateTime<Utc>)>>,
    update_last_accessed_calls: Mutex<usize>,
}

impl MockTenantRepo {
    pub fn new() -> Self {
        Self {
            tenants: Mutex::new(Vec::new()),
            deployments: Mutex::new(HashMap::new()),
            find_raw_calls: Mutex::new(0),
            last_accessed_updates: Mutex::new(Vec::new()),
            update_last_accessed_calls: Mutex::new(0),
        }
    }

    pub fn find_raw_call_count(&self) -> usize {
        *self.find_raw_calls.lock().unwrap()
    }

    pub fn last_accessed_updates(&self) -> Vec<(Uuid, String, DateTime<Utc>)> {
        self.last_accessed_updates.lock().unwrap().clone()
    }

    pub fn update_last_accessed_call_count(&self) -> usize {
        *self.update_last_accessed_calls.lock().unwrap()
    }

    /// Test-helper (not part of `TenantRepo` trait) that directly sets
    /// `last_accessed_at` on a seeded tenant. Used to pre-condition specific
    /// access-time scenarios in unit tests. Returns `RepoError::NotFound` if
    /// no tenant matching `(customer_id, tenant_id)` is in the store.
    pub fn set_last_accessed_at(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        last_accessed_at: Option<DateTime<Utc>>,
    ) -> Result<(), RepoError> {
        let mut tenants = self.tenants.lock().unwrap();
        if let Some(tenant) = tenants
            .iter_mut()
            .find(|t| t.customer_id == customer_id && t.tenant_id == tenant_id)
        {
            tenant.last_accessed_at = last_accessed_at;
            Ok(())
        } else {
            Err(RepoError::NotFound)
        }
    }

    /// Register deployment metadata so `find_by_customer` / `find_by_name` can produce summaries.
    pub fn seed_deployment(
        &self,
        id: Uuid,
        region: &str,
        flapjack_url: Option<&str>,
        health_status: &str,
        status: &str,
    ) {
        self.deployments.lock().unwrap().insert(
            id,
            DeploymentInfo {
                id,
                region: region.to_string(),
                flapjack_url: flapjack_url.map(|s| s.to_string()),
                health_status: health_status.to_string(),
                status: status.to_string(),
            },
        );
    }
}

#[async_trait]
impl TenantRepo for MockTenantRepo {
    /// Implements `TenantRepo::create`. Inserts a new `CustomerTenant` with
    /// `tier = "active"`, `service_type = "flapjack"`, and empty
    /// `resource_quota`. Returns `RepoError::Conflict` if a tenant with the
    /// same `(customer_id, tenant_id)` already exists.
    async fn create(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        deployment_id: Uuid,
    ) -> Result<CustomerTenant, RepoError> {
        let mut tenants = self.tenants.lock().unwrap();

        if tenants
            .iter()
            .any(|t| t.customer_id == customer_id && t.tenant_id == tenant_id)
        {
            return Err(RepoError::Conflict(format!(
                "index '{}' already exists for this customer",
                tenant_id
            )));
        }

        let tenant = CustomerTenant {
            customer_id,
            tenant_id: tenant_id.to_string(),
            deployment_id,
            created_at: Utc::now(),
            vm_id: None,
            tier: "active".to_string(),
            last_accessed_at: None,
            cold_snapshot_id: None,
            resource_quota: serde_json::json!({}),
            service_type: "flapjack".to_string(),
        };
        tenants.push(tenant.clone());
        Ok(tenant)
    }

    /// Implements `TenantRepo::find_by_customer`. Returns `CustomerTenantSummary`
    /// rows for all non-terminated tenants belonging to the customer, joined
    /// with seeded deployment metadata. Tenants whose deployment is not found in
    /// the seeded map, or whose deployment status is `"terminated"`, are
    /// excluded. Results are sorted by `created_at` descending.
    async fn find_by_customer(
        &self,
        customer_id: Uuid,
    ) -> Result<Vec<CustomerTenantSummary>, RepoError> {
        let tenants = self.tenants.lock().unwrap();
        let deployments = self.deployments.lock().unwrap();

        let mut results: Vec<CustomerTenantSummary> = tenants
            .iter()
            .filter(|t| t.customer_id == customer_id)
            .filter_map(|t| {
                let d = deployments.get(&t.deployment_id)?;
                if d.status == "terminated" {
                    return None;
                }
                Some(CustomerTenantSummary {
                    customer_id: t.customer_id,
                    tenant_id: t.tenant_id.clone(),
                    deployment_id: t.deployment_id,
                    created_at: t.created_at,
                    region: d.region.clone(),
                    flapjack_url: d.flapjack_url.clone(),
                    health_status: d.health_status.clone(),
                    tier: t.tier.clone(),
                    last_accessed_at: t.last_accessed_at,
                    cold_snapshot_id: t.cold_snapshot_id,
                    service_type: t.service_type.clone(),
                })
            })
            .collect();
        results.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        Ok(results)
    }

    /// Implements `TenantRepo::find_by_name`. Returns a single
    /// `CustomerTenantSummary` for the tenant identified by `(customer_id,
    /// tenant_id)`, joined with seeded deployment metadata. Returns `None` if
    /// the tenant does not exist, its deployment is not seeded, or the deployment
    /// is `"terminated"`.
    async fn find_by_name(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
    ) -> Result<Option<CustomerTenantSummary>, RepoError> {
        let tenants = self.tenants.lock().unwrap();
        let deployments = self.deployments.lock().unwrap();

        let result = tenants
            .iter()
            .find(|t| t.customer_id == customer_id && t.tenant_id == tenant_id)
            .and_then(|t| {
                let d = deployments.get(&t.deployment_id)?;
                if d.status == "terminated" {
                    return None;
                }
                Some(CustomerTenantSummary {
                    customer_id: t.customer_id,
                    tenant_id: t.tenant_id.clone(),
                    deployment_id: t.deployment_id,
                    created_at: t.created_at,
                    region: d.region.clone(),
                    flapjack_url: d.flapjack_url.clone(),
                    health_status: d.health_status.clone(),
                    tier: t.tier.clone(),
                    last_accessed_at: t.last_accessed_at,
                    cold_snapshot_id: t.cold_snapshot_id,
                    service_type: t.service_type.clone(),
                })
            });
        Ok(result)
    }

    async fn delete(&self, customer_id: Uuid, tenant_id: &str) -> Result<bool, RepoError> {
        let mut tenants = self.tenants.lock().unwrap();
        let len_before = tenants.len();
        tenants.retain(|t| !(t.customer_id == customer_id && t.tenant_id == tenant_id));
        Ok(tenants.len() < len_before)
    }

    async fn count_by_customer(&self, customer_id: Uuid) -> Result<i64, RepoError> {
        let tenants = self.tenants.lock().unwrap();
        let deployments = self.deployments.lock().unwrap();
        let count = tenants
            .iter()
            .filter(|t| t.customer_id == customer_id)
            .filter(|t| {
                deployments
                    .get(&t.deployment_id)
                    .map(|d| d.status != "terminated")
                    .unwrap_or(false)
            })
            .count();
        Ok(count as i64)
    }

    async fn find_by_deployment(
        &self,
        deployment_id: Uuid,
    ) -> Result<Vec<CustomerTenant>, RepoError> {
        let tenants = self.tenants.lock().unwrap();
        let mut results: Vec<CustomerTenant> = tenants
            .iter()
            .filter(|t| t.deployment_id == deployment_id)
            .cloned()
            .collect();
        results.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        Ok(results)
    }

    /// Implements `TenantRepo::set_vm_id`. Assigns the shared-VM `vm_id` to the
    /// tenant identified by `(customer_id, tenant_id)`. Returns
    /// `RepoError::NotFound` if the tenant does not exist.
    async fn set_vm_id(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        vm_id: Uuid,
    ) -> Result<(), RepoError> {
        let mut tenants = self.tenants.lock().unwrap();
        if let Some(t) = tenants
            .iter_mut()
            .find(|t| t.customer_id == customer_id && t.tenant_id == tenant_id)
        {
            t.vm_id = Some(vm_id);
            Ok(())
        } else {
            Err(RepoError::NotFound)
        }
    }

    /// Implements `TenantRepo::set_tier`. Updates the storage tier (e.g.,
    /// `"active"`, `"cold"`, `"migrating"`) for the tenant identified by
    /// `(customer_id, tenant_id)`. Returns `RepoError::NotFound` if the tenant
    /// does not exist.
    async fn set_tier(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        tier: &str,
    ) -> Result<(), RepoError> {
        let mut tenants = self.tenants.lock().unwrap();
        if let Some(t) = tenants
            .iter_mut()
            .find(|t| t.customer_id == customer_id && t.tenant_id == tenant_id)
        {
            t.tier = tier.to_string();
            Ok(())
        } else {
            Err(RepoError::NotFound)
        }
    }

    async fn list_by_vm(&self, vm_id: Uuid) -> Result<Vec<CustomerTenant>, RepoError> {
        let tenants = self.tenants.lock().unwrap();
        let mut results: Vec<CustomerTenant> = tenants
            .iter()
            .filter(|t| t.vm_id == Some(vm_id))
            .cloned()
            .collect();
        results.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        Ok(results)
    }

    async fn list_migrating(&self) -> Result<Vec<CustomerTenant>, RepoError> {
        let tenants = self.tenants.lock().unwrap();
        let mut results: Vec<CustomerTenant> = tenants
            .iter()
            .filter(|t| t.tier == "migrating")
            .cloned()
            .collect();
        results.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        Ok(results)
    }

    async fn list_unplaced(&self) -> Result<Vec<CustomerTenant>, RepoError> {
        let tenants = self.tenants.lock().unwrap();
        let mut results: Vec<CustomerTenant> = tenants
            .iter()
            .filter(|t| t.vm_id.is_none())
            .cloned()
            .collect();
        results.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        Ok(results)
    }

    /// Implements `TenantRepo::list_active_global`. Returns all `CustomerTenant`
    /// rows whose deployment has been seeded and is not `"terminated"`. Tenants
    /// whose deployment ID is absent from the seeded deployment map are excluded.
    /// Results are sorted by `created_at` descending.
    async fn list_active_global(&self) -> Result<Vec<CustomerTenant>, RepoError> {
        let tenants = self.tenants.lock().unwrap();
        let deployments = self.deployments.lock().unwrap();
        let mut results: Vec<CustomerTenant> = tenants
            .iter()
            .filter(|t| {
                deployments
                    .get(&t.deployment_id)
                    .map(|d| d.status != "terminated")
                    .unwrap_or(false)
            })
            .cloned()
            .collect();
        results.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        Ok(results)
    }

    /// Implements `TenantRepo::find_by_tenant_id_global`. Finds a tenant by its
    /// `tenant_id` string across all customers, joined with seeded deployment
    /// metadata. Returns `None` if no matching tenant is found, or if its
    /// deployment is not seeded or is `"terminated"`.
    async fn find_by_tenant_id_global(
        &self,
        tenant_id: &str,
    ) -> Result<Option<CustomerTenantSummary>, RepoError> {
        let tenants = self.tenants.lock().unwrap();
        let deployments = self.deployments.lock().unwrap();

        let result = tenants
            .iter()
            .find(|t| t.tenant_id == tenant_id)
            .and_then(|t| {
                let d = deployments.get(&t.deployment_id)?;
                if d.status == "terminated" {
                    return None;
                }
                Some(CustomerTenantSummary {
                    customer_id: t.customer_id,
                    tenant_id: t.tenant_id.clone(),
                    deployment_id: t.deployment_id,
                    created_at: t.created_at,
                    region: d.region.clone(),
                    flapjack_url: d.flapjack_url.clone(),
                    health_status: d.health_status.clone(),
                    tier: t.tier.clone(),
                    last_accessed_at: t.last_accessed_at,
                    cold_snapshot_id: t.cold_snapshot_id,
                    service_type: t.service_type.clone(),
                })
            });
        Ok(result)
    }

    async fn find_raw(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
    ) -> Result<Option<CustomerTenant>, RepoError> {
        let mut calls = self.find_raw_calls.lock().unwrap();
        *calls += 1;
        let tenants = self.tenants.lock().unwrap();
        Ok(tenants
            .iter()
            .find(|t| t.customer_id == customer_id && t.tenant_id == tenant_id)
            .cloned())
    }

    /// Implements `TenantRepo::set_resource_quota`. Replaces the `resource_quota`
    /// JSON blob for the tenant identified by `(customer_id, tenant_id)`.
    /// Returns `RepoError::NotFound` if the tenant does not exist.
    async fn set_resource_quota(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        quota: serde_json::Value,
    ) -> Result<(), RepoError> {
        let mut tenants = self.tenants.lock().unwrap();
        if let Some(t) = tenants
            .iter_mut()
            .find(|t| t.customer_id == customer_id && t.tenant_id == tenant_id)
        {
            t.resource_quota = quota;
            Ok(())
        } else {
            Err(RepoError::NotFound)
        }
    }

    async fn list_raw_by_customer(
        &self,
        customer_id: Uuid,
    ) -> Result<Vec<CustomerTenant>, RepoError> {
        let tenants = self.tenants.lock().unwrap();
        let mut results: Vec<CustomerTenant> = tenants
            .iter()
            .filter(|t| t.customer_id == customer_id)
            .cloned()
            .collect();
        results.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        Ok(results)
    }

    /// Implements `TenantRepo::update_last_accessed_batch`. Applies a batch of
    /// `(customer_id, tenant_id, timestamp)` updates, persisting them both in
    /// the tenant store and in `last_accessed_updates` for test assertions.
    /// Increments `update_last_accessed_calls` so callers can verify the method
    /// was invoked the expected number of times. Replaces any previous batch
    /// snapshot in `last_accessed_updates`.
    async fn update_last_accessed_batch(
        &self,
        updates: &[(Uuid, String, DateTime<Utc>)],
    ) -> Result<(), RepoError> {
        *self.update_last_accessed_calls.lock().unwrap() += 1;
        let mut tenants = self.tenants.lock().unwrap();
        let mut stored = self.last_accessed_updates.lock().unwrap();
        stored.clear();
        for (customer_id, tenant_id, ts) in updates {
            stored.push((*customer_id, tenant_id.clone(), *ts));
            if let Some(tenant) = tenants
                .iter_mut()
                .find(|t| t.customer_id == *customer_id && t.tenant_id == *tenant_id)
            {
                tenant.last_accessed_at = Some(*ts);
            }
        }
        Ok(())
    }

    /// Implements `TenantRepo::set_cold_snapshot_id`. Updates the
    /// `cold_snapshot_id` field on the tenant identified by `(customer_id,
    /// tenant_id)`. Passing `None` clears the association (used when the tenant
    /// is restored from cold storage). Returns `RepoError::NotFound` if the
    /// tenant does not exist.
    async fn set_cold_snapshot_id(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        snapshot_id: Option<Uuid>,
    ) -> Result<(), RepoError> {
        let mut tenants = self.tenants.lock().unwrap();
        if let Some(t) = tenants
            .iter_mut()
            .find(|t| t.customer_id == customer_id && t.tenant_id == tenant_id)
        {
            t.cold_snapshot_id = snapshot_id;
            Ok(())
        } else {
            Err(RepoError::NotFound)
        }
    }

    async fn clear_vm_id(&self, customer_id: Uuid, tenant_id: &str) -> Result<(), RepoError> {
        let mut tenants = self.tenants.lock().unwrap();
        if let Some(t) = tenants
            .iter_mut()
            .find(|t| t.customer_id == customer_id && t.tenant_id == tenant_id)
        {
            t.vm_id = None;
            Ok(())
        } else {
            Err(RepoError::NotFound)
        }
    }
}

pub fn mock_tenant_repo() -> Arc<MockTenantRepo> {
    Arc::new(MockTenantRepo::new())
}

pub fn mock_cold_snapshot_repo() -> Arc<InMemoryColdSnapshotRepo> {
    Arc::new(InMemoryColdSnapshotRepo::new())
}

pub struct MockReplicationHttpClient {
    requests: Mutex<Vec<MigrationHttpRequest>>,
    responses: Mutex<VecDeque<Result<MigrationHttpResponse, MigrationHttpClientError>>>,
}

impl MockReplicationHttpClient {
    pub fn new() -> Self {
        Self {
            requests: Mutex::new(Vec::new()),
            responses: Mutex::new(VecDeque::new()),
        }
    }

    pub fn enqueue(&self, response: Result<MigrationHttpResponse, MigrationHttpClientError>) {
        self.responses.lock().unwrap().push_back(response);
    }

    pub fn recorded_requests(&self) -> Vec<MigrationHttpRequest> {
        self.requests.lock().unwrap().clone()
    }
}

#[async_trait]
impl MigrationHttpClient for MockReplicationHttpClient {
    async fn send(
        &self,
        request: MigrationHttpRequest,
    ) -> Result<MigrationHttpResponse, MigrationHttpClientError> {
        self.requests.lock().unwrap().push(request);
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("test must enqueue HTTP responses")
    }
}

pub struct MockNodeClient {
    export_responses: Mutex<HashMap<String, Result<Vec<u8>, String>>>,
    export_delays_ms: Mutex<HashMap<String, u64>>,
    delete_responses: Mutex<HashMap<String, Result<(), String>>>,
    export_calls: Mutex<Vec<(String, String, String)>>,
    delete_calls: Mutex<Vec<(String, String, String)>>,
}

impl MockNodeClient {
    pub fn new() -> Self {
        Self {
            export_responses: Mutex::new(HashMap::new()),
            export_delays_ms: Mutex::new(HashMap::new()),
            delete_responses: Mutex::new(HashMap::new()),
            export_calls: Mutex::new(Vec::new()),
            delete_calls: Mutex::new(Vec::new()),
        }
    }

    pub fn set_export_response(&self, index_name: &str, response: Result<Vec<u8>, String>) {
        self.export_responses
            .lock()
            .unwrap()
            .insert(index_name.to_string(), response);
    }

    pub fn set_export_delay_ms(&self, index_name: &str, delay_ms: u64) {
        self.export_delays_ms
            .lock()
            .unwrap()
            .insert(index_name.to_string(), delay_ms);
    }

    pub fn set_delete_response(&self, index_name: &str, response: Result<(), String>) {
        self.delete_responses
            .lock()
            .unwrap()
            .insert(index_name.to_string(), response);
    }

    pub fn export_call_count(&self) -> usize {
        self.export_calls.lock().unwrap().len()
    }

    pub fn delete_call_count(&self) -> usize {
        self.delete_calls.lock().unwrap().len()
    }

    pub fn export_calls(&self) -> Vec<(String, String, String)> {
        self.export_calls.lock().unwrap().clone()
    }

    pub fn delete_calls(&self) -> Vec<(String, String, String)> {
        self.delete_calls.lock().unwrap().clone()
    }
}

#[async_trait]
impl FlapjackNodeClient for MockNodeClient {
    /// Implements `FlapjackNodeClient::export_index`. Records the call in
    /// `export_calls`, then simulates an optional artificial delay before
    /// returning the pre-configured response for `index_name`. Returns
    /// `ColdTierError::Export` if a failure was registered via
    /// `set_export_response`. Falls back to a default `b"default-export-data"`
    /// payload if no response has been configured for the index.
    async fn export_index(
        &self,
        flapjack_url: &str,
        index_name: &str,
        api_key: &str,
    ) -> Result<Vec<u8>, ColdTierError> {
        self.export_calls.lock().unwrap().push((
            flapjack_url.to_string(),
            index_name.to_string(),
            api_key.to_string(),
        ));

        let delay_ms = self
            .export_delays_ms
            .lock()
            .unwrap()
            .get(index_name)
            .copied()
            .unwrap_or(0);
        if delay_ms > 0 {
            tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
        }

        let responses = self.export_responses.lock().unwrap();
        match responses.get(index_name) {
            Some(Ok(data)) => Ok(data.clone()),
            Some(Err(e)) => Err(ColdTierError::Export(e.clone())),
            None => Ok(b"default-export-data".to_vec()),
        }
    }

    /// Implements `FlapjackNodeClient::delete_index`. Records the call in
    /// `delete_calls`, then returns the pre-configured result for `index_name`.
    /// Returns `ColdTierError::Evict` if a failure was registered via
    /// `set_delete_response`. Defaults to `Ok(())` if no response is configured.
    async fn delete_index(
        &self,
        flapjack_url: &str,
        index_name: &str,
        api_key: &str,
    ) -> Result<(), ColdTierError> {
        self.delete_calls.lock().unwrap().push((
            flapjack_url.to_string(),
            index_name.to_string(),
            api_key.to_string(),
        ));

        let responses = self.delete_responses.lock().unwrap();
        match responses.get(index_name) {
            Some(Ok(())) => Ok(()),
            Some(Err(e)) => Err(ColdTierError::Evict(e.clone())),
            None => Ok(()),
        }
    }

    async fn import_index(
        &self,
        _flapjack_url: &str,
        _index_name: &str,
        _data: &[u8],
        _api_key: &str,
    ) -> Result<(), ColdTierError> {
        Ok(())
    }

    async fn verify_index(
        &self,
        _flapjack_url: &str,
        _index_name: &str,
        _api_key: &str,
    ) -> Result<(), ColdTierError> {
        Ok(())
    }
}

pub struct MockSubscriptionRepo {
    subscriptions: Mutex<Vec<SubscriptionRow>>,
}

fn is_current_subscription(row: &SubscriptionRow) -> bool {
    row.status != SubscriptionStatus::Canceled.as_str()
}

impl MockSubscriptionRepo {
    pub fn new() -> Self {
        Self {
            subscriptions: Mutex::new(Vec::new()),
        }
    }

    /// Seed a subscription directly (for test setup).
    pub fn seed(&self, subscription: SubscriptionRow) {
        self.subscriptions.lock().unwrap().push(subscription);
    }

    pub fn count(&self) -> usize {
        self.subscriptions.lock().unwrap().len()
    }
}

#[async_trait]
impl SubscriptionRepo for MockSubscriptionRepo {
    /// Implements `SubscriptionRepo::create`. Inserts a new `SubscriptionRow`
    /// into the in-memory store. Enforces two uniqueness invariants: at most one
    /// non-canceled subscription per customer, and uniqueness of
    /// `stripe_subscription_id`. Returns `RepoError::Conflict` if either is
    /// violated.
    async fn create(&self, subscription: NewSubscription) -> Result<SubscriptionRow, RepoError> {
        let mut subs = self.subscriptions.lock().unwrap();

        // Only one non-canceled subscription per customer.
        if subs
            .iter()
            .any(|s| s.customer_id == subscription.customer_id && is_current_subscription(s))
        {
            return Err(RepoError::Conflict(
                "subscription already exists for this customer".into(),
            ));
        }

        // Check for duplicate stripe_subscription_id
        if subs
            .iter()
            .any(|s| s.stripe_subscription_id == subscription.stripe_subscription_id)
        {
            return Err(RepoError::Conflict(
                "stripe subscription id already in use".into(),
            ));
        }

        let row = SubscriptionRow {
            id: Uuid::new_v4(),
            customer_id: subscription.customer_id,
            stripe_subscription_id: subscription.stripe_subscription_id,
            stripe_price_id: subscription.stripe_price_id,
            plan_tier: subscription.plan_tier.as_str().to_string(),
            status: subscription.status.as_str().to_string(),
            current_period_start: subscription.current_period_start,
            current_period_end: subscription.current_period_end,
            cancel_at_period_end: subscription.cancel_at_period_end,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };

        subs.push(row.clone());
        Ok(row)
    }

    async fn find_by_id(&self, id: Uuid) -> Result<Option<SubscriptionRow>, RepoError> {
        let subs = self.subscriptions.lock().unwrap();
        Ok(subs.iter().find(|s| s.id == id).cloned())
    }

    async fn find_by_customer(
        &self,
        customer_id: Uuid,
    ) -> Result<Option<SubscriptionRow>, RepoError> {
        let subs = self.subscriptions.lock().unwrap();
        Ok(subs
            .iter()
            .rev()
            .find(|s| s.customer_id == customer_id && is_current_subscription(s))
            .cloned())
    }

    async fn find_by_stripe_id(
        &self,
        stripe_subscription_id: &str,
    ) -> Result<Option<SubscriptionRow>, RepoError> {
        let subs = self.subscriptions.lock().unwrap();
        Ok(subs
            .iter()
            .find(|s| s.stripe_subscription_id == stripe_subscription_id)
            .cloned())
    }

    async fn update_status(&self, id: Uuid, status: SubscriptionStatus) -> Result<(), RepoError> {
        let mut subs = self.subscriptions.lock().unwrap();
        let sub = subs
            .iter_mut()
            .find(|s| s.id == id)
            .ok_or(RepoError::NotFound)?;
        sub.status = status.as_str().to_string();
        sub.updated_at = Utc::now();
        Ok(())
    }

    /// Implements `SubscriptionRepo::update_plan`. Updates `plan_tier` and
    /// `stripe_price_id` on the subscription identified by `id`. Returns
    /// `RepoError::NotFound` if no subscription with that ID exists.
    async fn update_plan(
        &self,
        id: Uuid,
        plan_tier: PlanTier,
        stripe_price_id: &str,
    ) -> Result<(), RepoError> {
        let mut subs = self.subscriptions.lock().unwrap();
        let sub = subs
            .iter_mut()
            .find(|s| s.id == id)
            .ok_or(RepoError::NotFound)?;
        sub.plan_tier = plan_tier.as_str().to_string();
        sub.stripe_price_id = stripe_price_id.to_string();
        sub.updated_at = Utc::now();
        Ok(())
    }

    /// Implements `SubscriptionRepo::update_period`. Updates
    /// `current_period_start` and `current_period_end` on the subscription
    /// identified by `id`. Returns `RepoError::NotFound` if no subscription
    /// with that ID exists.
    async fn update_period(
        &self,
        id: Uuid,
        period_start: NaiveDate,
        period_end: NaiveDate,
    ) -> Result<(), RepoError> {
        let mut subs = self.subscriptions.lock().unwrap();
        let sub = subs
            .iter_mut()
            .find(|s| s.id == id)
            .ok_or(RepoError::NotFound)?;
        sub.current_period_start = period_start;
        sub.current_period_end = period_end;
        sub.updated_at = Utc::now();
        Ok(())
    }

    async fn set_cancel_at_period_end(&self, id: Uuid, cancel: bool) -> Result<(), RepoError> {
        let mut subs = self.subscriptions.lock().unwrap();
        let sub = subs
            .iter_mut()
            .find(|s| s.id == id)
            .ok_or(RepoError::NotFound)?;
        sub.cancel_at_period_end = cancel;
        sub.updated_at = Utc::now();
        Ok(())
    }

    async fn mark_canceled(&self, id: Uuid) -> Result<(), RepoError> {
        let mut subs = self.subscriptions.lock().unwrap();
        let sub = subs
            .iter_mut()
            .find(|s| s.id == id)
            .ok_or(RepoError::NotFound)?;
        sub.status = SubscriptionStatus::Canceled.as_str().to_string();
        sub.cancel_at_period_end = false;
        sub.updated_at = Utc::now();
        Ok(())
    }
}

pub fn mock_subscription_repo() -> Arc<MockSubscriptionRepo> {
    Arc::new(MockSubscriptionRepo::new())
}

// ── Storage mocks ──────────────────────────────────────────────────────

use api::services::storage::{GarageAdminClient, GarageBucketInfo, GarageKeyInfo, StorageError};

#[derive(Default)]
struct MockGarageAdminState {
    bucket_aliases: Vec<String>,
    bucket_ids_by_alias: HashMap<String, String>,
    deleted_bucket_ids: Vec<String>,
    created_key_names: Vec<String>,
    deleted_key_ids: Vec<String>,
    allow_calls: Vec<(String, String, bool, bool)>,
}

/// Recordable mock that returns success for all Garage admin operations.
pub struct MockGarageAdminClient {
    state: Mutex<MockGarageAdminState>,
}

impl MockGarageAdminClient {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(MockGarageAdminState::default()),
        }
    }

    pub fn bucket_aliases(&self) -> Vec<String> {
        self.state.lock().unwrap().bucket_aliases.clone()
    }

    pub fn deleted_bucket_ids(&self) -> Vec<String> {
        self.state.lock().unwrap().deleted_bucket_ids.clone()
    }

    pub fn deleted_key_ids(&self) -> Vec<String> {
        self.state.lock().unwrap().deleted_key_ids.clone()
    }

    pub fn allow_calls(&self) -> Vec<(String, String, bool, bool)> {
        self.state.lock().unwrap().allow_calls.clone()
    }
}

#[async_trait]
impl GarageAdminClient for MockGarageAdminClient {
    async fn create_bucket(&self, name: &str) -> Result<GarageBucketInfo, StorageError> {
        let mut state = self.state.lock().unwrap();
        let bucket_id = format!("bucket-{}", state.bucket_aliases.len() + 1);
        state.bucket_aliases.push(name.to_string());
        state
            .bucket_ids_by_alias
            .insert(name.to_string(), bucket_id.clone());
        Ok(GarageBucketInfo { id: bucket_id })
    }

    async fn get_bucket_by_alias(
        &self,
        global_alias: &str,
    ) -> Result<GarageBucketInfo, StorageError> {
        let mut state = self.state.lock().unwrap();
        let bucket_id = state
            .bucket_ids_by_alias
            .entry(global_alias.to_string())
            .or_insert_with(|| format!("garage-bucket-{global_alias}"))
            .clone();
        Ok(GarageBucketInfo { id: bucket_id })
    }

    async fn delete_bucket(&self, id: &str) -> Result<(), StorageError> {
        self.state
            .lock()
            .unwrap()
            .deleted_bucket_ids
            .push(id.to_string());
        Ok(())
    }

    async fn create_key(&self, name: &str) -> Result<GarageKeyInfo, StorageError> {
        let mut state = self.state.lock().unwrap();
        let key_id = format!("garage-key-{}", state.created_key_names.len() + 1);
        state.created_key_names.push(name.to_string());
        Ok(GarageKeyInfo {
            id: key_id,
            secret_key: "mock-garage-secret".to_string(),
        })
    }

    async fn delete_key(&self, id: &str) -> Result<(), StorageError> {
        self.state
            .lock()
            .unwrap()
            .deleted_key_ids
            .push(id.to_string());
        Ok(())
    }

    async fn allow_key(
        &self,
        bucket_id: &str,
        key_id: &str,
        allow_read: bool,
        allow_write: bool,
    ) -> Result<(), StorageError> {
        self.state.lock().unwrap().allow_calls.push((
            bucket_id.to_string(),
            key_id.to_string(),
            allow_read,
            allow_write,
        ));
        Ok(())
    }
}

pub fn mock_garage_admin_client() -> Arc<MockGarageAdminClient> {
    Arc::new(MockGarageAdminClient::new())
}

use api::repos::InMemoryStorageBucketRepo;
use api::repos::InMemoryStorageKeyRepo;

pub fn mock_storage_bucket_repo() -> Arc<InMemoryStorageBucketRepo> {
    Arc::new(InMemoryStorageBucketRepo::new())
}

pub fn mock_storage_key_repo() -> Arc<InMemoryStorageKeyRepo> {
    Arc::new(InMemoryStorageKeyRepo::new())
}
