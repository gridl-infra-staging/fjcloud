#![allow(dead_code)]

use api::dns::mock::MockDnsManager;
use api::provisioner::mock::MockVmProvisioner;
use api::provisioner::region_map::RegionConfig;
use api::repos::index_migration_repo::IndexMigrationRepo;
use api::repos::tenant_repo::TenantRepo;
use api::repos::vm_inventory_repo::VmInventoryRepo;
use api::repos::InMemoryColdSnapshotRepo;
use api::repos::InMemoryStorageBucketRepo;
use api::repos::InMemoryStorageKeyRepo;
use api::router::build_router;
use api::services::alerting::MockAlertService;
use api::services::email::EmailService;
use api::services::flapjack_proxy::FlapjackProxy;
use api::services::metrics::MetricsCollector;
use api::services::migration::MigrationService;
use api::services::object_store::InMemoryObjectStore;
use api::services::provisioning::{ProvisioningService, DEFAULT_DNS_DOMAIN};
use api::services::replica::ReplicaService;
use api::services::restore::RestoreService;
use api::services::storage::s3_proxy::{GarageProxy, GarageProxyConfig};
use api::services::storage::{GarageAdminClient, StorageService};
use api::services::tenant_quota::{FreeTierLimits, QuotaDefaults, TenantQuotaService};
use api::state::AppState;
use axum::Router;
use billing::plan::{PlanRegistry, StaticPlanRegistry};
use sqlx::postgres::PgPoolOptions;
use std::sync::Arc;

use super::mocks::{
    mock_alert_service, mock_api_key_repo, mock_cold_snapshot_repo, mock_deployment_repo,
    mock_dns_manager, mock_email_service, mock_flapjack_proxy, mock_garage_admin_client,
    mock_index_migration_repo, mock_invoice_repo, mock_node_secret_manager, mock_rate_card_repo,
    mock_repo, mock_storage_bucket_repo, mock_storage_key_repo, mock_stripe_service,
    mock_subscription_repo, mock_tenant_repo, mock_usage_repo, mock_vm_inventory_repo,
    mock_vm_provisioner, mock_webhook_event_repo, mock_webhook_http_client, MockApiKeyRepo,
    MockCustomerRepo, MockDeploymentRepo, MockIndexMigrationRepo, MockInvoiceRepo,
    MockRateCardRepo, MockStripeService, MockTenantRepo, MockUsageRepo, MockVmInventoryRepo,
    MockWebhookEventRepo, MockWebhookHttpClient,
};

pub const TEST_JWT_SECRET: &str = "test-jwt-secret-min-32-chars-ok!";
pub const TEST_ADMIN_KEY: &str = "test-admin-key-16";
pub const TEST_INTERNAL_AUTH_TOKEN: &str = "test-internal-key";
pub const TEST_WEBHOOK_SECRET: &str = "test-webhook-secret";

fn lazy_pool() -> sqlx::PgPool {
    PgPoolOptions::new()
        .max_connections(1)
        // Keep fallback-to-in-process lock paths fast in unit tests that use a
        // connect_lazy pool with no real Postgres server. Port 1 is reserved
        // (TCPMUX) and reliably refuses connections, so `pool.begin()` always
        // surfaces `sqlx::Error::Io(connection refused)` — which
        // `repos::advisory_lock::is_connection_error` correctly classifies as
        // "DB unavailable, fall back to in-process lock". Pointing at
        // `localhost/fake_db` instead caused CI hangs in concurrent integration
        // tests when the postgres:16 service container was reachable but the
        // `fake` user/db did not exist: sqlx returned `Database` (auth failure),
        // which the connection-error classifier missed, so handlers returned
        // 503 before signaling test channels.
        .acquire_timeout(std::time::Duration::from_millis(200))
        .connect_lazy("postgres://test:test@127.0.0.1:1/test")
        .expect("connect_lazy should never fail")
}

fn test_tenant_quota_service() -> Arc<TenantQuotaService> {
    Arc::new(TenantQuotaService::new(QuotaDefaults::default()))
}

fn test_metrics_collector() -> Arc<MetricsCollector> {
    Arc::new(MetricsCollector::new())
}

fn test_plan_registry() -> Arc<dyn PlanRegistry> {
    Arc::new(StaticPlanRegistry::new(
        "price_starter_test",
        "price_pro_test",
        "price_enterprise_test",
    ))
}

fn test_garage_proxy() -> Arc<GarageProxy> {
    Arc::new(GarageProxy::new(
        reqwest::Client::new(),
        GarageProxyConfig {
            endpoint: "http://127.0.0.1:3900".to_string(),
            access_key: "test-access-key".to_string(),
            secret_key: "test-secret-key".to_string(),
            region: "garage".to_string(),
        },
    ))
}

/// Constructs a [`MigrationService`] wired to in-test mock collaborators.
///
/// Uses a short (5 s) reqwest timeout and `mock_node_secret_manager` so that
/// migration protocol calls never reach a real node. The `max_replication_lag`
/// is hard-coded to `3` — enough for tests that exercise lag enforcement
/// without waiting for real replication.
///
/// Connects the tenant repo, VM inventory repo, index migration repo,
/// alert service, and discovery service so migration lifecycle tests
/// (start, validate, promote, rollback) work end-to-end in-process.
fn build_mock_migration_service(
    tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
    vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
    index_migration_repo: Arc<dyn IndexMigrationRepo + Send + Sync>,
    alert_service: Arc<MockAlertService>,
    discovery_service: Arc<api::services::discovery::DiscoveryService>,
) -> Arc<MigrationService> {
    let http_client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .expect("test migration reqwest client should build");
    let node_secret_manager = mock_node_secret_manager();

    Arc::new(MigrationService::new(
        tenant_repo,
        vm_inventory_repo,
        index_migration_repo,
        alert_service,
        discovery_service,
        node_secret_manager,
        http_client,
        3,
    ))
}

/// Constructs the three replica-related services needed for index-routing tests.
///
/// Returns a `(DiscoveryService, InMemoryIndexReplicaRepo, ReplicaService)` tuple.
/// The [`DiscoveryService`] is pre-configured with the replica repo so that
/// replica-aware index lookups work without Postgres. [`ReplicaService`] uses
/// the provided `region_config` to drive placement decisions, letting tests
/// exercise multi-region replica promotion and demotion in-process.
fn build_replica_services(
    tenant_repo: Arc<MockTenantRepo>,
    vm_inventory_repo: Arc<MockVmInventoryRepo>,
    region_config: RegionConfig,
) -> (
    Arc<api::services::discovery::DiscoveryService>,
    Arc<api::repos::InMemoryIndexReplicaRepo>,
    Arc<ReplicaService>,
) {
    let index_replica_repo = Arc::new(api::repos::InMemoryIndexReplicaRepo::new());
    let discovery_service = Arc::new(
        api::services::discovery::DiscoveryService::new(
            tenant_repo.clone(),
            vm_inventory_repo.clone(),
        )
        .with_replica_repo(index_replica_repo.clone()),
    );
    let replica_service = Arc::new(ReplicaService::new(
        index_replica_repo.clone(),
        tenant_repo,
        vm_inventory_repo,
        region_config,
    ));
    (discovery_service, index_replica_repo, replica_service)
}

fn mock_provisioning_service(
    vm_provisioner: Arc<MockVmProvisioner>,
    dns_manager: Arc<MockDnsManager>,
    deployment_repo: Arc<MockDeploymentRepo>,
    customer_repo: Arc<MockCustomerRepo>,
) -> Arc<ProvisioningService> {
    Arc::new(ProvisioningService::new(
        vm_provisioner,
        dns_manager,
        mock_node_secret_manager(),
        deployment_repo,
        customer_repo,
        DEFAULT_DNS_DOMAIN.to_string(),
    ))
}

/// Fluent builder for [`AppState`] used in unit and integration tests.
///
/// All fields default to lightweight mock or in-memory implementations so that
/// every test can start with `TestStateBuilder::new()` and only override the
/// repos/services relevant to the scenario being tested.
///
/// Key defaults:
/// - Auth: `TEST_JWT_SECRET`, `TEST_ADMIN_KEY`, `TEST_INTERNAL_AUTH_TOKEN`, `TEST_WEBHOOK_SECRET`
/// - All repos: mock or in-memory (no Postgres)
/// - `FlapjackProxy`: mock (no real flapjack node)
/// - `GarageProxy`: points at `http://127.0.0.1:3900` (safe; never called in unit tests)
/// - `StorageMasterKey`: all-zero 32-byte key (deterministic encryption in tests)
///
/// Call `build()` for an [`AppState`] or `build_app()` for a fully-wired
/// axum [`Router`].
#[derive(Clone)]
pub struct TestStateBuilder {
    jwt_secret: Arc<str>,
    admin_key: Arc<str>,
    internal_auth_token: Option<Arc<str>>,
    stripe_webhook_secret: Option<Arc<str>>,
    stripe_success_url: String,
    stripe_cancel_url: String,
    metrics_collector: Arc<MetricsCollector>,
    api_key_repo: Arc<MockApiKeyRepo>,
    customer_repo: Arc<MockCustomerRepo>,
    deployment_repo: Arc<MockDeploymentRepo>,
    usage_repo: Arc<MockUsageRepo>,
    rate_card_repo: Arc<MockRateCardRepo>,
    invoice_repo: Arc<MockInvoiceRepo>,
    subscription_repo: Arc<super::mocks::MockSubscriptionRepo>,
    plan_registry: Arc<dyn PlanRegistry>,
    stripe_service: Arc<MockStripeService>,
    webhook_http_client: Arc<MockWebhookHttpClient>,
    email_service: Arc<dyn EmailService>,
    webhook_event_repo: Arc<MockWebhookEventRepo>,
    object_store: Arc<InMemoryObjectStore>,
    cold_snapshot_repo: Arc<InMemoryColdSnapshotRepo>,
    tenant_repo: Arc<MockTenantRepo>,
    vm_provisioner: Arc<MockVmProvisioner>,
    dns_manager: Arc<MockDnsManager>,
    flapjack_proxy: Arc<FlapjackProxy>,
    alert_service: Arc<MockAlertService>,
    vm_inventory_repo: Arc<MockVmInventoryRepo>,
    index_migration_repo: Arc<MockIndexMigrationRepo>,
    tenant_quota_service: Arc<TenantQuotaService>,
    free_tier_limits: FreeTierLimits,
    region_config: RegionConfig,
    restore_service: Option<Arc<RestoreService>>,
    storage_bucket_repo: Arc<InMemoryStorageBucketRepo>,
    storage_key_repo: Arc<InMemoryStorageKeyRepo>,
    garage_admin_client: Arc<dyn GarageAdminClient>,
    garage_proxy: Arc<GarageProxy>,
    storage_master_key: [u8; 32],
}

impl TestStateBuilder {
    /// Creates a `TestStateBuilder` with all-mock defaults.
    ///
    /// Every repo, service, and auth value is populated from the `mock_*`
    /// helpers in `common::mocks`. Tests only need to override the specific
    /// collaborators relevant to their scenario via the `with_*` methods.
    ///
    /// The `stripe_webhook_secret` and `internal_auth_token` are set by default;
    /// use `without_stripe_webhook_secret()` or supply `None` explicitly when
    /// testing code paths that expect those to be absent.
    pub fn new() -> Self {
        Self {
            jwt_secret: Arc::from(TEST_JWT_SECRET),
            admin_key: Arc::from(TEST_ADMIN_KEY),
            internal_auth_token: Some(Arc::from(TEST_INTERNAL_AUTH_TOKEN)),
            stripe_webhook_secret: Some(Arc::from(TEST_WEBHOOK_SECRET)),
            stripe_success_url: "http://localhost:5173/dashboard".to_string(),
            stripe_cancel_url: "http://localhost:5173/dashboard".to_string(),
            metrics_collector: test_metrics_collector(),
            api_key_repo: mock_api_key_repo(),
            customer_repo: mock_repo(),
            deployment_repo: mock_deployment_repo(),
            usage_repo: mock_usage_repo(),
            rate_card_repo: mock_rate_card_repo(),
            invoice_repo: mock_invoice_repo(),
            subscription_repo: mock_subscription_repo(),
            plan_registry: test_plan_registry(),
            stripe_service: mock_stripe_service(),
            webhook_http_client: mock_webhook_http_client(),
            email_service: mock_email_service() as Arc<dyn EmailService>,
            webhook_event_repo: mock_webhook_event_repo(),
            object_store: Arc::new(InMemoryObjectStore::new()),
            cold_snapshot_repo: mock_cold_snapshot_repo(),
            tenant_repo: mock_tenant_repo(),
            vm_provisioner: mock_vm_provisioner(),
            dns_manager: mock_dns_manager(),
            flapjack_proxy: mock_flapjack_proxy(),
            alert_service: mock_alert_service(),
            vm_inventory_repo: mock_vm_inventory_repo(),
            index_migration_repo: mock_index_migration_repo(),
            tenant_quota_service: test_tenant_quota_service(),
            free_tier_limits: FreeTierLimits::default(),
            region_config: RegionConfig::defaults(),
            restore_service: None,
            storage_bucket_repo: mock_storage_bucket_repo(),
            storage_key_repo: mock_storage_key_repo(),
            garage_admin_client: mock_garage_admin_client(),
            garage_proxy: test_garage_proxy(),
            storage_master_key: [0u8; 32],
        }
    }

    pub fn with_customer_repo(mut self, customer_repo: Arc<MockCustomerRepo>) -> Self {
        self.customer_repo = customer_repo;
        self
    }

    pub fn with_deployment_repo(mut self, deployment_repo: Arc<MockDeploymentRepo>) -> Self {
        self.deployment_repo = deployment_repo;
        self
    }

    pub fn with_usage_repo(mut self, usage_repo: Arc<MockUsageRepo>) -> Self {
        self.usage_repo = usage_repo;
        self
    }

    pub fn with_rate_card_repo(mut self, rate_card_repo: Arc<MockRateCardRepo>) -> Self {
        self.rate_card_repo = rate_card_repo;
        self
    }

    pub fn with_invoice_repo(mut self, invoice_repo: Arc<MockInvoiceRepo>) -> Self {
        self.invoice_repo = invoice_repo;
        self
    }

    pub fn with_subscription_repo(
        mut self,
        subscription_repo: Arc<super::mocks::MockSubscriptionRepo>,
    ) -> Self {
        self.subscription_repo = subscription_repo;
        self
    }

    pub fn with_stripe_service(mut self, stripe_service: Arc<MockStripeService>) -> Self {
        self.stripe_service = stripe_service;
        self
    }

    pub fn with_webhook_http_client(
        mut self,
        webhook_http_client: Arc<MockWebhookHttpClient>,
    ) -> Self {
        self.webhook_http_client = webhook_http_client;
        self
    }

    pub fn with_tenant_repo(mut self, tenant_repo: Arc<MockTenantRepo>) -> Self {
        self.tenant_repo = tenant_repo;
        self
    }

    pub fn with_flapjack_proxy(mut self, flapjack_proxy: Arc<FlapjackProxy>) -> Self {
        self.flapjack_proxy = flapjack_proxy;
        self
    }

    pub fn with_email_service(mut self, email_service: Arc<dyn EmailService>) -> Self {
        self.email_service = email_service;
        self
    }

    pub fn with_vm_inventory_repo(mut self, vm_inventory_repo: Arc<MockVmInventoryRepo>) -> Self {
        self.vm_inventory_repo = vm_inventory_repo;
        self
    }

    pub fn with_provisioner(mut self, vm_provisioner: Arc<MockVmProvisioner>) -> Self {
        self.vm_provisioner = vm_provisioner;
        self
    }

    pub fn with_api_key_repo(mut self, api_key_repo: Arc<MockApiKeyRepo>) -> Self {
        self.api_key_repo = api_key_repo;
        self
    }

    pub fn with_webhook_event_repo(
        mut self,
        webhook_event_repo: Arc<MockWebhookEventRepo>,
    ) -> Self {
        self.webhook_event_repo = webhook_event_repo;
        self
    }

    pub fn with_cold_snapshot_repo(
        mut self,
        cold_snapshot_repo: Arc<InMemoryColdSnapshotRepo>,
    ) -> Self {
        self.cold_snapshot_repo = cold_snapshot_repo;
        self
    }

    pub fn with_alert_service(mut self, alert_service: Arc<MockAlertService>) -> Self {
        self.alert_service = alert_service;
        self
    }

    pub fn with_index_migration_repo(mut self, repo: Arc<MockIndexMigrationRepo>) -> Self {
        self.index_migration_repo = repo;
        self
    }

    pub fn with_dns_manager(mut self, dns_manager: Arc<MockDnsManager>) -> Self {
        self.dns_manager = dns_manager;
        self
    }

    pub fn with_object_store(mut self, object_store: Arc<InMemoryObjectStore>) -> Self {
        self.object_store = object_store;
        self
    }

    pub fn with_restore_service(mut self, restore_service: Option<Arc<RestoreService>>) -> Self {
        self.restore_service = restore_service;
        self
    }

    pub fn with_onboarding(
        mut self,
        tenant_repo: Arc<MockTenantRepo>,
        api_key_repo: Arc<MockApiKeyRepo>,
        stripe_service: Arc<MockStripeService>,
        flapjack_proxy: Arc<FlapjackProxy>,
    ) -> Self {
        self.tenant_repo = tenant_repo;
        self.api_key_repo = api_key_repo;
        self.stripe_service = stripe_service;
        self.flapjack_proxy = flapjack_proxy;
        self
    }

    pub fn with_free_tier_limits(mut self, free_tier_limits: FreeTierLimits) -> Self {
        self.free_tier_limits = free_tier_limits;
        self
    }

    pub fn without_stripe_webhook_secret(mut self) -> Self {
        self.stripe_webhook_secret = None;
        self
    }

    pub fn with_stripe_redirect_urls(mut self, success_url: &str, cancel_url: &str) -> Self {
        self.stripe_success_url = success_url.to_string();
        self.stripe_cancel_url = cancel_url.to_string();
        self
    }

    /// Consumes the builder and produces a fully-wired [`AppState`].
    ///
    /// Internally calls `build_replica_services` and `build_mock_migration_service`
    /// to assemble the discovery/replica/migration graph, then wires up
    /// `ProvisioningService` and `StorageService` before assembling the final
    /// [`AppState`] struct.
    ///
    /// The returned state uses a lazy (never-actually-connected) Postgres pool,
    /// so tests that only exercise in-memory repos will never require a live DB.
    pub fn build(self) -> AppState {
        let (discovery_service, index_replica_repo, replica_service) = build_replica_services(
            self.tenant_repo.clone(),
            self.vm_inventory_repo.clone(),
            self.region_config.clone(),
        );
        let migration_service = build_mock_migration_service(
            self.tenant_repo.clone(),
            self.vm_inventory_repo.clone(),
            self.index_migration_repo.clone(),
            self.alert_service.clone(),
            discovery_service.clone(),
        );
        let provisioning_service = mock_provisioning_service(
            self.vm_provisioner.clone(),
            self.dns_manager.clone(),
            self.deployment_repo.clone(),
            self.customer_repo.clone(),
        );
        let storage_service = Arc::new(StorageService::new(
            self.storage_bucket_repo.clone(),
            self.storage_key_repo.clone(),
            self.garage_admin_client.clone(),
            self.storage_master_key,
        ));
        let s3_object_metering = Arc::new(
            api::services::storage::object_metering::S3ObjectMeteringService::new(
                self.storage_bucket_repo.clone(),
                self.garage_proxy.clone(),
            ),
        );

        AppState {
            pool: lazy_pool(),
            jwt_secret: self.jwt_secret,
            admin_key: self.admin_key,
            internal_auth_token: self.internal_auth_token,
            stripe_webhook_secret: self.stripe_webhook_secret,
            stripe_success_url: self.stripe_success_url,
            stripe_cancel_url: self.stripe_cancel_url,
            metrics_collector: self.metrics_collector,
            api_key_repo: self.api_key_repo,
            customer_repo: self.customer_repo,
            deployment_repo: self.deployment_repo,
            usage_repo: self.usage_repo,
            rate_card_repo: self.rate_card_repo,
            invoice_repo: self.invoice_repo,
            subscription_repo: self.subscription_repo,
            plan_registry: self.plan_registry,
            stripe_service: self.stripe_service,
            webhook_http_client: self.webhook_http_client,
            email_service: self.email_service,
            webhook_event_repo: self.webhook_event_repo,
            object_store: self.object_store,
            cold_snapshot_repo: self.cold_snapshot_repo,
            tenant_repo: self.tenant_repo,
            vm_provisioner: self.vm_provisioner,
            dns_manager: self.dns_manager,
            provisioning_service,
            flapjack_proxy: self.flapjack_proxy,
            alert_service: self.alert_service,
            vm_inventory_repo: self.vm_inventory_repo,
            index_migration_repo: self.index_migration_repo,
            discovery_service,
            migration_service,
            tenant_quota_service: self.tenant_quota_service,
            free_tier_limits: self.free_tier_limits,
            region_config: self.region_config,
            restore_service: self.restore_service,
            index_replica_repo,
            replica_service,
            storage_bucket_repo: self.storage_bucket_repo,
            storage_key_repo: self.storage_key_repo,
            storage_service,
            garage_proxy: self.garage_proxy,
            s3_object_metering,
            storage_master_key: self.storage_master_key,
        }
    }

    pub fn with_storage_bucket_repo(mut self, repo: Arc<InMemoryStorageBucketRepo>) -> Self {
        self.storage_bucket_repo = repo;
        self
    }

    pub fn with_storage_key_repo(mut self, storage_key_repo: Arc<InMemoryStorageKeyRepo>) -> Self {
        self.storage_key_repo = storage_key_repo;
        self
    }

    pub fn with_garage_admin_client(mut self, client: Arc<dyn GarageAdminClient>) -> Self {
        self.garage_admin_client = client;
        self
    }

    pub fn with_storage_master_key(mut self, storage_master_key: [u8; 32]) -> Self {
        self.storage_master_key = storage_master_key;
        self
    }

    pub fn with_garage_proxy(mut self, garage_proxy: Arc<GarageProxy>) -> Self {
        self.garage_proxy = garage_proxy;
        self
    }

    pub fn build_app(self) -> Router {
        build_router(self.build())
    }
}

impl Default for TestStateBuilder {
    fn default() -> Self {
        Self::new()
    }
}

fn with_example_stripe_urls(builder: TestStateBuilder) -> TestStateBuilder {
    builder
        .without_stripe_webhook_secret()
        .with_stripe_redirect_urls("https://example.com/success", "https://example.com/cancel")
}

pub fn test_state_all(
    customer_repo: Arc<MockCustomerRepo>,
    deployment_repo: Arc<MockDeploymentRepo>,
    usage_repo: Arc<MockUsageRepo>,
    rate_card_repo: Arc<MockRateCardRepo>,
    invoice_repo: Arc<MockInvoiceRepo>,
) -> AppState {
    TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_deployment_repo(deployment_repo)
        .with_usage_repo(usage_repo)
        .with_rate_card_repo(rate_card_repo)
        .with_invoice_repo(invoice_repo)
        .build()
}

/// Builds an [`AppState`] with the five standard billing repos plus a caller-supplied
/// [`MockStripeService`].
///
/// Use this variant over `test_state_all` when the test needs to assert on
/// Stripe API calls (e.g. checkout-session creation, subscription cancellation).
/// All other services default to their mock implementations.
pub fn test_state_all_with_stripe(
    customer_repo: Arc<MockCustomerRepo>,
    deployment_repo: Arc<MockDeploymentRepo>,
    usage_repo: Arc<MockUsageRepo>,
    rate_card_repo: Arc<MockRateCardRepo>,
    invoice_repo: Arc<MockInvoiceRepo>,
    stripe_service: Arc<MockStripeService>,
) -> AppState {
    TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_deployment_repo(deployment_repo)
        .with_usage_repo(usage_repo)
        .with_rate_card_repo(rate_card_repo)
        .with_invoice_repo(invoice_repo)
        .with_stripe_service(stripe_service)
        .build()
}

pub fn test_state_full(
    customer_repo: Arc<MockCustomerRepo>,
    deployment_repo: Arc<MockDeploymentRepo>,
    usage_repo: Arc<MockUsageRepo>,
    rate_card_repo: Arc<MockRateCardRepo>,
) -> AppState {
    test_state_all(
        customer_repo,
        deployment_repo,
        usage_repo,
        rate_card_repo,
        mock_invoice_repo(),
    )
}

pub fn test_state_with_repos(
    customer_repo: Arc<MockCustomerRepo>,
    deployment_repo: Arc<MockDeploymentRepo>,
) -> AppState {
    TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_deployment_repo(deployment_repo)
        .build()
}

pub fn test_state_with_repo(repo: Arc<MockCustomerRepo>) -> AppState {
    TestStateBuilder::new().with_customer_repo(repo).build()
}

pub fn test_state() -> AppState {
    TestStateBuilder::new().build()
}

pub fn test_app() -> Router {
    TestStateBuilder::new().build_app()
}

pub fn test_app_with_repo(repo: Arc<MockCustomerRepo>) -> Router {
    TestStateBuilder::new().with_customer_repo(repo).build_app()
}

pub fn test_state_with_email(
    repo: Arc<MockCustomerRepo>,
    email_service: Arc<dyn EmailService>,
) -> AppState {
    TestStateBuilder::new()
        .with_customer_repo(repo)
        .with_email_service(email_service)
        .build()
}

pub fn build_test_app_with_email(
    repo: Arc<MockCustomerRepo>,
    email_service: Arc<dyn EmailService>,
) -> Router {
    TestStateBuilder::new()
        .with_customer_repo(repo)
        .with_email_service(email_service)
        .build_app()
}

pub fn test_app_with_repos(
    customer_repo: Arc<MockCustomerRepo>,
    deployment_repo: Arc<MockDeploymentRepo>,
) -> Router {
    TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_deployment_repo(deployment_repo)
        .build_app()
}

pub fn test_state_with_tenant_repo(tenant_repo: Arc<MockTenantRepo>) -> AppState {
    test_state_with_indexes(
        mock_repo(),
        mock_deployment_repo(),
        tenant_repo,
        mock_flapjack_proxy(),
    )
}

pub fn test_app_with_tenant_repo(tenant_repo: Arc<MockTenantRepo>) -> Router {
    build_router(test_state_with_tenant_repo(tenant_repo))
}

pub fn test_app_with_cold_snapshot_repo(
    cold_snapshot_repo: Arc<InMemoryColdSnapshotRepo>,
) -> Router {
    TestStateBuilder::new()
        .with_cold_snapshot_repo(cold_snapshot_repo)
        .build_app()
}

pub fn test_app_full(
    customer_repo: Arc<MockCustomerRepo>,
    deployment_repo: Arc<MockDeploymentRepo>,
    usage_repo: Arc<MockUsageRepo>,
    rate_card_repo: Arc<MockRateCardRepo>,
) -> Router {
    build_router(test_state_full(
        customer_repo,
        deployment_repo,
        usage_repo,
        rate_card_repo,
    ))
}

pub fn test_app_all(
    customer_repo: Arc<MockCustomerRepo>,
    deployment_repo: Arc<MockDeploymentRepo>,
    usage_repo: Arc<MockUsageRepo>,
    rate_card_repo: Arc<MockRateCardRepo>,
    invoice_repo: Arc<MockInvoiceRepo>,
) -> Router {
    build_router(test_state_all(
        customer_repo,
        deployment_repo,
        usage_repo,
        rate_card_repo,
        invoice_repo,
    ))
}

pub fn test_state_with_provisioner(
    customer_repo: Arc<MockCustomerRepo>,
    deployment_repo: Arc<MockDeploymentRepo>,
    vm_provisioner: Arc<MockVmProvisioner>,
) -> AppState {
    with_example_stripe_urls(
        TestStateBuilder::new()
            .with_customer_repo(customer_repo)
            .with_deployment_repo(deployment_repo)
            .with_provisioner(vm_provisioner),
    )
    .build()
}

pub fn test_app_with_provisioner(
    customer_repo: Arc<MockCustomerRepo>,
    deployment_repo: Arc<MockDeploymentRepo>,
    vm_provisioner: Arc<MockVmProvisioner>,
) -> Router {
    with_example_stripe_urls(
        TestStateBuilder::new()
            .with_customer_repo(customer_repo)
            .with_deployment_repo(deployment_repo)
            .with_provisioner(vm_provisioner),
    )
    .build_app()
}

pub fn test_state_with_api_key_repo(
    customer_repo: Arc<MockCustomerRepo>,
    api_key_repo: Arc<MockApiKeyRepo>,
) -> AppState {
    with_example_stripe_urls(
        TestStateBuilder::new()
            .with_customer_repo(customer_repo)
            .with_api_key_repo(api_key_repo),
    )
    .build()
}

pub fn test_state_with_indexes(
    customer_repo: Arc<MockCustomerRepo>,
    deployment_repo: Arc<MockDeploymentRepo>,
    tenant_repo: Arc<MockTenantRepo>,
    flapjack_proxy: Arc<FlapjackProxy>,
) -> AppState {
    test_state_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo,
        flapjack_proxy,
        mock_vm_inventory_repo(),
    )
}

/// Builds an [`AppState`] for index-management tests that also need VM inventory
/// (e.g. shared-VM placement, replica scheduling).
///
/// Wires up customer repo, deployment repo, tenant repo, flapjack proxy, and VM
/// inventory repo; all other services default to mocks. Stripe redirect URLs are
/// set to `https://example.com/{success,cancel}` and the webhook secret is
/// removed — matching the typical setup for routes that don't exercise billing.
///
/// Prefer `test_state_with_indexes` when `vm_inventory_repo` is not relevant to
/// the test; that helper calls this one with `mock_vm_inventory_repo()`.
pub fn test_state_with_indexes_and_vm_inventory(
    customer_repo: Arc<MockCustomerRepo>,
    deployment_repo: Arc<MockDeploymentRepo>,
    tenant_repo: Arc<MockTenantRepo>,
    flapjack_proxy: Arc<FlapjackProxy>,
    vm_inventory_repo: Arc<MockVmInventoryRepo>,
) -> AppState {
    with_example_stripe_urls(
        TestStateBuilder::new()
            .with_customer_repo(customer_repo)
            .with_deployment_repo(deployment_repo)
            .with_tenant_repo(tenant_repo)
            .with_flapjack_proxy(flapjack_proxy)
            .with_vm_inventory_repo(vm_inventory_repo),
    )
    .build()
}

pub fn test_app_with_indexes(
    customer_repo: Arc<MockCustomerRepo>,
    deployment_repo: Arc<MockDeploymentRepo>,
    tenant_repo: Arc<MockTenantRepo>,
    flapjack_proxy: Arc<FlapjackProxy>,
) -> Router {
    build_router(test_state_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo,
        flapjack_proxy,
    ))
}

pub fn test_app_with_indexes_and_vm_inventory(
    customer_repo: Arc<MockCustomerRepo>,
    deployment_repo: Arc<MockDeploymentRepo>,
    tenant_repo: Arc<MockTenantRepo>,
    flapjack_proxy: Arc<FlapjackProxy>,
    vm_inventory_repo: Arc<MockVmInventoryRepo>,
) -> Router {
    build_router(test_state_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo,
        flapjack_proxy,
        vm_inventory_repo,
    ))
}

pub fn mock_flapjack_proxy_with_secrets(
    node_secret_manager: Arc<api::secrets::mock::MockNodeSecretManager>,
) -> Arc<FlapjackProxy> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .unwrap();
    Arc::new(FlapjackProxy::new(client, node_secret_manager))
}

/// Builds an [`AppState`] for onboarding flow tests.
///
/// Wires together customer repo, deployment repo, tenant repo, API key repo,
/// Stripe service, and flapjack proxy — the exact set of collaborators exercised
/// during new-tenant sign-up (registration → email verification → index creation).
/// Stripe redirect URLs are set to example values and the webhook secret is
/// cleared to avoid signature-verification failures in routes that don't process
/// webhooks.
pub fn test_state_with_onboarding(
    customer_repo: Arc<MockCustomerRepo>,
    deployment_repo: Arc<MockDeploymentRepo>,
    tenant_repo: Arc<MockTenantRepo>,
    api_key_repo: Arc<MockApiKeyRepo>,
    stripe_service: Arc<MockStripeService>,
    flapjack_proxy: Arc<FlapjackProxy>,
) -> AppState {
    with_example_stripe_urls(
        TestStateBuilder::new()
            .with_customer_repo(customer_repo)
            .with_deployment_repo(deployment_repo)
            .with_onboarding(tenant_repo, api_key_repo, stripe_service, flapjack_proxy),
    )
    .build()
}

/// Builds a fully-wired axum [`Router`] for onboarding flow tests.
///
/// Delegates to `test_state_with_onboarding` and wraps the result with
/// `build_router`. Use this when the test drives HTTP requests end-to-end
/// rather than calling service methods directly.
pub fn test_app_with_onboarding(
    customer_repo: Arc<MockCustomerRepo>,
    deployment_repo: Arc<MockDeploymentRepo>,
    tenant_repo: Arc<MockTenantRepo>,
    api_key_repo: Arc<MockApiKeyRepo>,
    stripe_service: Arc<MockStripeService>,
    flapjack_proxy: Arc<FlapjackProxy>,
) -> Router {
    build_router(test_state_with_onboarding(
        customer_repo,
        deployment_repo,
        tenant_repo,
        api_key_repo,
        stripe_service,
        flapjack_proxy,
    ))
}
