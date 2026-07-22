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
use api::repos::PgAlgoliaImportJobRepo;
use api::router::build_router;
use api::services::alerting::MockAlertService;
use api::services::algolia_source::{
    AlgoliaSourceLister, AlgoliaSourceService, ReqwestAlgoliaSourceClient,
};
use api::services::email::EmailService;
use api::services::flapjack_proxy::FlapjackProxy;
use api::services::health_monitor::{EngineHealthWaitPolicy, HealthCheckClient};
use api::services::index_lifecycle_lease::IndexLifecycleLease;
use api::services::metrics::MetricsCollector;
use api::services::migration::MigrationService;
use api::services::object_store::InMemoryObjectStore;
use api::services::provisioning::{ProvisioningService, DEFAULT_DNS_DOMAIN};
use api::services::replica::ReplicaService;
use api::services::restore::RestoreService;
use api::services::storage::s3_proxy::{GarageProxy, GarageProxyConfig};
use api::services::storage::{GarageAdminClient, StorageService};
use api::services::tenant_quota::{FreeTierLimits, QuotaDefaults, TenantQuotaService};
use api::services::vm_orphan_reconcile::{VmOrphanDependencies, VmOrphanReconciler};
use api::state::AppState;
use api::state::MetricsCache;
use api::state::{OAuthCookieSameSite, OAuthProviderRuntimeConfig, OAuthRuntimeConfig};
use axum::Router;
use sqlx::postgres::PgPoolOptions;
use std::sync::Arc;

use super::mocks::{
    mock_alert_service, mock_api_key_repo, mock_cold_snapshot_repo, mock_deployment_repo,
    mock_dispute_repo, mock_dns_manager, mock_email_service, mock_flapjack_proxy,
    mock_garage_admin_client, mock_index_migration_repo, mock_invoice_repo,
    mock_node_secret_manager, mock_rate_card_repo, mock_repo, mock_storage_bucket_repo,
    mock_storage_key_repo, mock_stripe_service, mock_tenant_repo, mock_usage_repo,
    mock_vm_host_metrics_repo, mock_vm_inventory_repo, mock_vm_provisioner,
    mock_webhook_event_repo, mock_webhook_http_client, MockApiKeyRepo, MockCustomerRepo,
    MockDeploymentRepo, MockDisputeRepo, MockIndexMigrationRepo, MockInvoiceRepo, MockRateCardRepo,
    MockStripeService, MockTenantRepo, MockUsageRepo, MockVmHostMetricsRepo, MockVmInventoryRepo,
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
    node_secret_manager: Arc<dyn api::secrets::NodeSecretManager>,
) -> Arc<MigrationService> {
    let http_client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .expect("test migration reqwest client should build");

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
    let replica_service = Arc::new(ReplicaService::new_without_lifecycle_guard_for_tests(
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
    node_secret_manager: Arc<dyn api::secrets::NodeSecretManager>,
    deployment_repo: Arc<MockDeploymentRepo>,
    customer_repo: Arc<MockCustomerRepo>,
    dns_domain: String,
) -> Arc<ProvisioningService> {
    Arc::new(ProvisioningService::new(
        vm_provisioner,
        dns_manager,
        node_secret_manager,
        deployment_repo,
        customer_repo,
        dns_domain,
    ))
    .with_engine_health_client_for_test(
        test_engine_health_client(),
        test_engine_health_wait_policy(),
    )
}

pub(crate) fn test_engine_health_client() -> Arc<dyn HealthCheckClient> {
    super::engine_health::EngineHealthClient::healthy()
}

pub(crate) fn test_engine_health_wait_policy() -> EngineHealthWaitPolicy {
    EngineHealthWaitPolicy::new(
        std::time::Duration::from_millis(50),
        std::time::Duration::from_millis(10),
        std::time::Duration::from_millis(1),
    )
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
    stripe_publishable_key: Option<String>,
    stripe_success_url: String,
    stripe_cancel_url: String,
    metrics_collector: Arc<MetricsCollector>,
    api_key_repo: Arc<MockApiKeyRepo>,
    customer_repo: Arc<MockCustomerRepo>,
    deployment_repo: Arc<MockDeploymentRepo>,
    usage_repo: Arc<MockUsageRepo>,
    rate_card_repo: Arc<MockRateCardRepo>,
    invoice_repo: Arc<MockInvoiceRepo>,
    dispute_repo: Arc<MockDisputeRepo>,
    stripe_service: Arc<MockStripeService>,
    webhook_http_client: Arc<MockWebhookHttpClient>,
    email_service: Arc<dyn EmailService>,
    dunning_emails_disabled: bool,
    algolia_migration_enabled: bool,
    algolia_source_service: Arc<dyn AlgoliaSourceLister>,
    pool_override: Option<sqlx::PgPool>,
    webhook_event_repo: Arc<MockWebhookEventRepo>,
    object_store: Arc<InMemoryObjectStore>,
    cold_snapshot_repo: Arc<InMemoryColdSnapshotRepo>,
    tenant_repo: Arc<MockTenantRepo>,
    vm_provisioner: Arc<MockVmProvisioner>,
    dns_manager: Arc<MockDnsManager>,
    node_secret_manager: Arc<api::secrets::mock::MockNodeSecretManager>,
    flapjack_proxy: Arc<FlapjackProxy>,
    alert_service: Arc<MockAlertService>,
    vm_host_metrics_repo: Arc<MockVmHostMetricsRepo>,
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
    oauth: OAuthRuntimeConfig,
    metrics_cache: Arc<MetricsCache>,
    dns_domain: String,
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
            stripe_publishable_key: None,
            stripe_success_url: "http://localhost:5173/console".to_string(),
            stripe_cancel_url: "http://localhost:5173/console".to_string(),
            metrics_collector: test_metrics_collector(),
            api_key_repo: mock_api_key_repo(),
            customer_repo: mock_repo(),
            deployment_repo: mock_deployment_repo(),
            usage_repo: mock_usage_repo(),
            rate_card_repo: mock_rate_card_repo(),
            invoice_repo: mock_invoice_repo(),
            dispute_repo: mock_dispute_repo(),
            stripe_service: mock_stripe_service(),
            webhook_http_client: mock_webhook_http_client(),
            email_service: mock_email_service() as Arc<dyn EmailService>,
            dunning_emails_disabled: false,
            algolia_migration_enabled: false,
            pool_override: None,
            algolia_source_service: Arc::new(
                AlgoliaSourceService::new(
                    Arc::new(
                        ReqwestAlgoliaSourceClient::new()
                            .expect("build Algolia source test HTTP client"),
                    ),
                    TEST_JWT_SECRET.as_bytes(),
                )
                .expect("build Algolia source test service"),
            ),
            webhook_event_repo: mock_webhook_event_repo(),
            object_store: Arc::new(InMemoryObjectStore::new()),
            cold_snapshot_repo: mock_cold_snapshot_repo(),
            tenant_repo: mock_tenant_repo(),
            vm_provisioner: mock_vm_provisioner(),
            dns_manager: mock_dns_manager(),
            node_secret_manager: mock_node_secret_manager(),
            flapjack_proxy: mock_flapjack_proxy(),
            alert_service: mock_alert_service(),
            vm_host_metrics_repo: mock_vm_host_metrics_repo(),
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
            oauth: OAuthRuntimeConfig::default(),
            metrics_cache: Arc::new(MetricsCache::default()),
            dns_domain: DEFAULT_DNS_DOMAIN.to_string(),
        }
    }

    pub fn with_metrics_cache(mut self, metrics_cache: Arc<MetricsCache>) -> Self {
        self.metrics_cache = metrics_cache;
        self
    }

    pub fn with_dns_domain(mut self, dns_domain: &str) -> Self {
        self.dns_domain = dns_domain.to_string();
        self
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

    pub fn with_dispute_repo(mut self, dispute_repo: Arc<MockDisputeRepo>) -> Self {
        self.dispute_repo = dispute_repo;
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

    pub fn with_dunning_emails_disabled(mut self, dunning_emails_disabled: bool) -> Self {
        self.dunning_emails_disabled = dunning_emails_disabled;
        self
    }

    pub fn with_algolia_migration_enabled(mut self, algolia_migration_enabled: bool) -> Self {
        self.algolia_migration_enabled = algolia_migration_enabled;
        self
    }

    /// Back the built `AppState` with a real Postgres pool (e.g. from
    /// `connect_and_migrate`) so route handlers that construct a
    /// `PgAlgoliaImportJobRepo` from `state.pool` exercise real SQL instead of
    /// the never-connecting lazy pool.
    pub fn with_pool(mut self, pool: sqlx::PgPool) -> Self {
        self.pool_override = Some(pool);
        self
    }

    pub fn with_algolia_source_service(
        mut self,
        algolia_source_service: Arc<dyn AlgoliaSourceLister>,
    ) -> Self {
        self.algolia_source_service = algolia_source_service;
        self
    }

    pub fn with_vm_inventory_repo(mut self, vm_inventory_repo: Arc<MockVmInventoryRepo>) -> Self {
        self.vm_inventory_repo = vm_inventory_repo;
        self
    }

    pub fn with_vm_host_metrics_repo(
        mut self,
        vm_host_metrics_repo: Arc<MockVmHostMetricsRepo>,
    ) -> Self {
        self.vm_host_metrics_repo = vm_host_metrics_repo;
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

    pub fn with_node_secret_manager(
        mut self,
        node_secret_manager: Arc<api::secrets::mock::MockNodeSecretManager>,
    ) -> Self {
        self.node_secret_manager = node_secret_manager;
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

    pub fn with_stripe_publishable_key(mut self, stripe_publishable_key: Option<String>) -> Self {
        self.stripe_publishable_key = stripe_publishable_key;
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
            self.node_secret_manager.clone(),
        );
        let vm_orphan_reconciler = Arc::new(VmOrphanReconciler::new(
            VmOrphanDependencies {
                inventory: self.vm_inventory_repo.clone(),
                dns: self.dns_manager.clone(),
                secrets: self.node_secret_manager.clone(),
                provisioner: self.vm_provisioner.clone(),
            },
            self.dns_domain.clone(),
        ));
        let provisioning_service = mock_provisioning_service(
            self.vm_provisioner.clone(),
            self.dns_manager.clone(),
            self.node_secret_manager.clone(),
            self.deployment_repo.clone(),
            self.customer_repo.clone(),
            self.dns_domain,
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
        let pool = self.pool_override.unwrap_or_else(lazy_pool);

        AppState {
            pool: pool.clone(),
            jwt_secret: self.jwt_secret,
            admin_key: self.admin_key,
            internal_auth_token: self.internal_auth_token,
            stripe_webhook_secret: self.stripe_webhook_secret,
            stripe_publishable_key: self.stripe_publishable_key,
            stripe_success_url: self.stripe_success_url,
            stripe_cancel_url: self.stripe_cancel_url,
            metrics_collector: self.metrics_collector,
            api_key_repo: self.api_key_repo,
            customer_repo: self.customer_repo,
            deployment_repo: self.deployment_repo,
            usage_repo: self.usage_repo,
            rate_card_repo: self.rate_card_repo,
            invoice_repo: self.invoice_repo,
            dispute_repo: self.dispute_repo,
            stripe_service: self.stripe_service,
            webhook_http_client: self.webhook_http_client,
            email_service: self.email_service,
            dunning_emails_disabled: self.dunning_emails_disabled,
            algolia_migration_enabled: self.algolia_migration_enabled,
            algolia_source_service: self.algolia_source_service,
            webhook_event_repo: self.webhook_event_repo,
            object_store: self.object_store,
            cold_snapshot_repo: self.cold_snapshot_repo,
            tenant_repo: self.tenant_repo,
            vm_provisioner: self.vm_provisioner,
            dns_manager: self.dns_manager,
            provisioning_service,
            flapjack_proxy: self.flapjack_proxy,
            alert_service: self.alert_service,
            vm_host_metrics_repo: self.vm_host_metrics_repo,
            vm_inventory_repo: self.vm_inventory_repo,
            vm_orphan_reconciler,
            index_migration_repo: self.index_migration_repo,
            discovery_service,
            migration_service,
            tenant_quota_service: self.tenant_quota_service,
            free_tier_limits: self.free_tier_limits,
            region_config: self.region_config,
            restore_service: self.restore_service,
            index_replica_repo,
            replica_service,
            index_lifecycle_lease: Arc::new(IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(
                pool,
            ))),
            storage_bucket_repo: self.storage_bucket_repo,
            storage_key_repo: self.storage_key_repo,
            storage_service,
            garage_proxy: self.garage_proxy,
            s3_object_metering,
            storage_master_key: self.storage_master_key,
            oauth: self.oauth,
            metrics_cache: self.metrics_cache,
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

    pub fn with_oauth_google_provider(
        self,
        client_id: &str,
        client_secret: &str,
        redirect_uri: &str,
    ) -> Self {
        self.with_oauth_google_provider_with_endpoints(
            client_id,
            client_secret,
            redirect_uri,
            "https://oauth2.googleapis.com/token",
            "https://openidconnect.googleapis.com/v1/userinfo",
        )
    }

    pub fn with_oauth_google_provider_with_endpoints(
        mut self,
        client_id: &str,
        client_secret: &str,
        redirect_uri: &str,
        token_endpoint: &str,
        userinfo_endpoint: &str,
    ) -> Self {
        self.oauth.google = Some(OAuthProviderRuntimeConfig {
            client_id: Arc::from(client_id),
            client_secret: Arc::from(client_secret),
            redirect_uri: Arc::from(redirect_uri),
            token_endpoint: Arc::from(token_endpoint),
            userinfo_endpoint: Arc::from(userinfo_endpoint),
            user_emails_endpoint: None,
        });
        self
    }

    pub fn with_oauth_github_provider(
        self,
        client_id: &str,
        client_secret: &str,
        redirect_uri: &str,
    ) -> Self {
        self.with_oauth_github_provider_with_endpoints(
            client_id,
            client_secret,
            redirect_uri,
            "https://github.com/login/oauth/access_token",
            "https://api.github.com/user",
            "https://api.github.com/user/emails",
        )
    }

    pub fn with_oauth_github_provider_with_endpoints(
        mut self,
        client_id: &str,
        client_secret: &str,
        redirect_uri: &str,
        token_endpoint: &str,
        userinfo_endpoint: &str,
        user_emails_endpoint: &str,
    ) -> Self {
        self.oauth.github = Some(OAuthProviderRuntimeConfig {
            client_id: Arc::from(client_id),
            client_secret: Arc::from(client_secret),
            redirect_uri: Arc::from(redirect_uri),
            token_endpoint: Arc::from(token_endpoint),
            userinfo_endpoint: Arc::from(userinfo_endpoint),
            user_emails_endpoint: Some(Arc::from(user_emails_endpoint)),
        });
        self
    }

    pub fn with_oauth_cookie_domain(mut self, domain: Option<&str>) -> Self {
        self.oauth.cookie_domain = domain.map(Arc::from);
        self
    }

    pub fn with_oauth_cookie_policy(
        mut self,
        secure: bool,
        same_site: OAuthCookieSameSite,
    ) -> Self {
        self.oauth.cookie_secure = secure;
        self.oauth.cookie_same_site = same_site;
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

pub fn test_app_with_indexes_vm_inventory_and_metrics_cache(
    customer_repo: Arc<MockCustomerRepo>,
    deployment_repo: Arc<MockDeploymentRepo>,
    tenant_repo: Arc<MockTenantRepo>,
    flapjack_proxy: Arc<FlapjackProxy>,
    vm_inventory_repo: Arc<MockVmInventoryRepo>,
    metrics_cache: Arc<MetricsCache>,
) -> Router {
    build_router(
        with_example_stripe_urls(
            TestStateBuilder::new()
                .with_customer_repo(customer_repo)
                .with_deployment_repo(deployment_repo)
                .with_tenant_repo(tenant_repo)
                .with_flapjack_proxy(flapjack_proxy)
                .with_vm_inventory_repo(vm_inventory_repo)
                .with_metrics_cache(metrics_cache),
        )
        .build(),
    )
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

#[cfg(test)]
mod tests {
    use super::TestStateBuilder;

    #[tokio::test]
    async fn builder_threads_oauth_runtime_config_into_app_state() {
        let state = TestStateBuilder::new()
            .with_oauth_google_provider(
                "google-client-id",
                "google-client-secret",
                "https://cloud.flapjack.foo/auth/oauth/google/callback",
            )
            .with_oauth_github_provider(
                "github-client-id",
                "github-client-secret",
                "https://cloud.flapjack.foo/auth/oauth/github/callback",
            )
            .with_oauth_cookie_domain(Some(".flapjack.foo"))
            .build();

        assert_eq!(
            state
                .oauth
                .google
                .as_ref()
                .map(|cfg| cfg.client_id.as_ref()),
            Some("google-client-id")
        );
        assert_eq!(
            state
                .oauth
                .github
                .as_ref()
                .map(|cfg| cfg.client_secret.as_ref()),
            Some("github-client-secret")
        );
        assert_eq!(state.oauth.cookie_domain.as_deref(), Some(".flapjack.foo"));
    }
}
