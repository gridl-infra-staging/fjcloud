//! Binary entrypoint for the Flapjack Cloud API service.

use api::config::Config;
use api::dns::DnsManager;
use api::provisioner::region_map::RegionConfig;
use api::provisioner::VmProvisioner;
use api::repos::{ColdSnapshotRepo, IndexReplicaRepo, PgIndexReplicaRepo};
use api::secrets::NodeSecretManager;
use api::services::access_tracker::AccessTracker;
use api::services::alerting::AlertService;
use api::services::ayb_admin::{AybAdminClient, ReqwestAybAdminClient};
use api::services::cold_tier::{FlapjackNodeClient, ReqwestNodeClient};
use api::services::discovery::DiscoveryService;
use api::services::email::EmailService;
use api::services::flapjack_proxy::FlapjackProxy;
use api::services::migration::MigrationService;
use api::services::object_store::{ObjectStore, RegionObjectStoreResolver};
use api::services::provisioning::ProvisioningService;
use api::services::replica::ReplicaService;
use api::services::restore::{RestoreConfig, RestoreService};
use api::services::tenant_quota::{FreeTierLimits, TenantQuotaService};
use api::startup::StorageComponents;
use api::startup_env::StartupEnvSnapshot;
use api::startup_repos::PgRepos;
use api::state::AppState;
use api::stripe::StripeService;
use billing::plan::PlanRegistry;
use sqlx::PgPool;
use std::sync::Arc;
use std::time::Duration;
use tracing_subscriber::EnvFilter;

/// Intermediate bundle from [`wire_services`] carrying all initialized services
/// and their supporting objects.
struct WiredServices {
    object_store: Arc<dyn ObjectStore + Send + Sync>,
    object_store_resolver: Arc<RegionObjectStoreResolver>,
    access_tracker: Arc<AccessTracker>,
    stripe_service: Arc<dyn StripeService>,
    plan_registry: Arc<dyn PlanRegistry>,
    email_service: Arc<dyn EmailService>,
    vm_provisioner: Arc<dyn VmProvisioner>,
    region_config: RegionConfig,
    dns_manager: Arc<dyn DnsManager>,
    node_secret_manager: Arc<dyn NodeSecretManager>,
    alert_service: Arc<dyn AlertService>,
    storage: StorageComponents,
    provisioning_service: Arc<ProvisioningService>,
    flapjack_proxy: Arc<FlapjackProxy>,
    index_replica_repo: Arc<dyn IndexReplicaRepo>,
    discovery_service: Arc<DiscoveryService>,
    replica_service: Arc<ReplicaService>,
    tenant_quota_service: Arc<TenantQuotaService>,
    free_tier_limits: FreeTierLimits,
    migration_service: Arc<MigrationService>,
    migration_http_client: reqwest::Client,
    node_client: Arc<dyn FlapjackNodeClient>,
    cold_snapshot_repo: Arc<dyn ColdSnapshotRepo + Send + Sync>,
    restore_service: Arc<RestoreService>,
    ayb_admin_client: Option<Arc<dyn AybAdminClient + Send + Sync>>,
}

/// Startup bootstrap outputs needed to wire services and build AppState.
struct StartupBootstrapPhase {
    cfg: Config,
    startup_env: StartupEnvSnapshot,
    pool: PgPool,
    repos: PgRepos,
    aws_sdk_config: aws_config::SdkConfig,
}

/// App wiring outputs used by background-task setup and final server launch.
struct AppWiringPhase {
    cfg: Config,
    state: AppState,
    background_deps: api::startup::BackgroundDeps,
}

/// Final launch inputs after background tasks are spawned.
struct ServerLaunchPhase {
    cfg: Config,
    state: AppState,
    shutdown_tx: tokio::sync::watch::Sender<bool>,
    shutdown_rx: tokio::sync::watch::Receiver<bool>,
    handles: api::startup::BackgroundHandles,
}

/// Immutable startup inputs shared by the service-wiring helpers.
struct ServiceWireInputs<'a> {
    pool: &'a PgPool,
    cfg: &'a Config,
    startup_env: &'a StartupEnvSnapshot,
    repos: &'a PgRepos,
    aws_sdk_config: &'a aws_config::SdkConfig,
}

/// Services needed to build request-path state before control-plane wiring.
struct RuntimeServices {
    object_store: Arc<dyn ObjectStore + Send + Sync>,
    object_store_resolver: Arc<RegionObjectStoreResolver>,
    access_tracker: Arc<AccessTracker>,
    stripe_service: Arc<dyn StripeService>,
    plan_registry: Arc<dyn PlanRegistry>,
    email_service: Arc<dyn EmailService>,
    vm_provisioner: Arc<dyn VmProvisioner>,
    region_config: RegionConfig,
    dns_manager: Arc<dyn DnsManager>,
    dns_domain: String,
    node_secret_manager: Arc<dyn NodeSecretManager>,
    alert_service: Arc<dyn AlertService>,
    storage: StorageComponents,
    flapjack_proxy: Arc<FlapjackProxy>,
    index_replica_repo: Arc<dyn IndexReplicaRepo>,
    discovery_service: Arc<DiscoveryService>,
    replica_service: Arc<ReplicaService>,
    tenant_quota_service: Arc<TenantQuotaService>,
    free_tier_limits: FreeTierLimits,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    init_tracing();
    let startup_bootstrap = bootstrap_startup_phase().await?;
    let app_wiring = wire_app_state_phase(startup_bootstrap).await?;
    let server_launch = setup_background_tasks_phase(app_wiring)?;
    launch_server_phase(server_launch).await
}

fn init_tracing() {
    tracing_subscriber::fmt()
        .json()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info,api=debug")),
        )
        .with_target(true)
        .init();
}

async fn bootstrap_startup_phase() -> anyhow::Result<StartupBootstrapPhase> {
    let cfg = Config::from_env()?;
    let startup_env = StartupEnvSnapshot::from_env();
    let ses_env_state = startup_env.ses_family_state();
    let cold_storage_env_state = startup_env.cold_storage_family_state();
    let cold_storage_regions_state = startup_env.cold_storage_regions_state();
    let storage_key_state = startup_env.storage_encryption_key_state();
    tracing::debug!(
        ?ses_env_state,
        ?cold_storage_env_state,
        ?cold_storage_regions_state,
        ?storage_key_state,
        "Classified startup environment families"
    );

    let pool = api::db::create_pool(&cfg.database_url).await?;
    let repos = api::startup_repos::init_pg_repos(&pool);
    let aws_sdk_config = aws_config::load_defaults(aws_config::BehaviorVersion::latest()).await;
    Ok(StartupBootstrapPhase {
        cfg,
        startup_env,
        pool,
        repos,
        aws_sdk_config,
    })
}

async fn wire_app_state_phase(bootstrap: StartupBootstrapPhase) -> anyhow::Result<AppWiringPhase> {
    let StartupBootstrapPhase {
        cfg,
        startup_env,
        pool,
        repos,
        aws_sdk_config,
    } = bootstrap;
    let wired_services = wire_services(&pool, &cfg, &startup_env, &repos, &aws_sdk_config).await?;
    let WiredServices {
        object_store,
        object_store_resolver,
        access_tracker,
        stripe_service,
        plan_registry,
        email_service,
        vm_provisioner,
        region_config,
        dns_manager,
        node_secret_manager,
        alert_service,
        storage,
        provisioning_service,
        flapjack_proxy,
        index_replica_repo,
        discovery_service,
        replica_service,
        tenant_quota_service,
        free_tier_limits,
        migration_service,
        migration_http_client,
        node_client,
        cold_snapshot_repo,
        restore_service,
        ayb_admin_client,
    } = wired_services;
    let api::startup::StorageComponents {
        storage_bucket_repo,
        storage_key_repo,
        storage_service,
        garage_proxy,
        s3_object_metering,
        storage_master_key,
    } = storage;
    let PgRepos {
        api_key_repo,
        customer_repo,
        deployment_repo,
        usage_repo,
        rate_card_repo,
        invoice_repo,
        subscription_repo,
        tenant_repo,
        webhook_event_repo,
        vm_inventory_repo,
        index_migration_repo,
        cold_snapshot_repo: _repo_cold_snapshot_repo,
        restore_job_repo: _restore_job_repo,
        ayb_tenant_repo,
    } = repos;

    let state = AppState {
        pool,
        jwt_secret: Arc::from(cfg.jwt_secret.as_str()),
        admin_key: Arc::from(cfg.admin_key.as_str()),
        internal_auth_token: cfg.internal_auth_token.as_deref().map(Arc::from),
        stripe_webhook_secret: cfg.stripe_webhook_secret.as_deref().map(Arc::from),
        stripe_success_url: cfg.stripe_success_url.clone(),
        stripe_cancel_url: cfg.stripe_cancel_url.clone(),
        metrics_collector: Arc::new(api::services::metrics::MetricsCollector::new()),
        api_key_repo,
        customer_repo,
        deployment_repo,
        usage_repo,
        rate_card_repo,
        invoice_repo,
        subscription_repo,
        plan_registry,
        stripe_service,
        email_service,
        object_store,
        cold_snapshot_repo: cold_snapshot_repo.clone(),
        tenant_repo,
        webhook_event_repo,
        vm_provisioner,
        dns_manager,
        provisioning_service,
        flapjack_proxy,
        alert_service,
        vm_inventory_repo,
        index_migration_repo,
        discovery_service,
        migration_service,
        tenant_quota_service,
        free_tier_limits,
        region_config,
        restore_service: Some(restore_service),
        index_replica_repo,
        replica_service,
        storage_bucket_repo,
        storage_key_repo,
        storage_service,
        garage_proxy,
        s3_object_metering,
        storage_master_key,
        ayb_admin_client,
        ayb_tenant_repo,
    };
    let background_deps = api::startup::BackgroundDeps {
        node_secret_manager,
        access_tracker,
        cold_snapshot_repo,
        object_store_resolver,
        node_client,
        migration_http_client,
    };
    Ok(AppWiringPhase {
        cfg,
        state,
        background_deps,
    })
}

fn setup_background_tasks_phase(app_wiring: AppWiringPhase) -> anyhow::Result<ServerLaunchPhase> {
    let AppWiringPhase {
        cfg,
        state,
        background_deps,
    } = app_wiring;
    let (shutdown_tx, shutdown_rx) = create_shutdown_channel();
    let handles =
        api::startup::spawn_background_tasks(&state, background_deps, shutdown_rx.clone())?;
    Ok(ServerLaunchPhase {
        cfg,
        state,
        shutdown_tx,
        shutdown_rx,
        handles,
    })
}

async fn launch_server_phase(server_launch: ServerLaunchPhase) -> anyhow::Result<()> {
    let ServerLaunchPhase {
        cfg,
        state,
        shutdown_tx,
        shutdown_rx,
        handles,
    } = server_launch;
    api::startup::serve(state, &cfg, shutdown_tx, shutdown_rx, handles).await
}

fn create_shutdown_channel() -> (
    tokio::sync::watch::Sender<bool>,
    tokio::sync::watch::Receiver<bool>,
) {
    tokio::sync::watch::channel(false)
}

/// Initialize all services and wire cross-service dependencies.
async fn wire_services(
    pool: &PgPool,
    cfg: &Config,
    startup_env: &StartupEnvSnapshot,
    repos: &PgRepos,
    aws_sdk_config: &aws_config::SdkConfig,
) -> anyhow::Result<WiredServices> {
    let inputs = ServiceWireInputs {
        pool,
        cfg,
        startup_env,
        repos,
        aws_sdk_config,
    };
    let runtime_services = wire_runtime_services(&inputs).await?;
    wire_control_plane_services(&inputs, runtime_services).await
}

async fn wire_runtime_services(inputs: &ServiceWireInputs<'_>) -> anyhow::Result<RuntimeServices> {
    let (object_store, object_store_resolver) =
        api::startup::init_object_store(inputs.startup_env).await;
    let access_tracker = Arc::new(AccessTracker::new(
        inputs.repos.tenant_repo.clone() as Arc<dyn api::repos::TenantRepo + Send + Sync>
    ));
    let stripe_service = api::startup::init_stripe_service(inputs.cfg);
    let plan_registry: Arc<dyn PlanRegistry> = Arc::new(billing::plan::EnvPlanRegistry::new());
    let email_service =
        api::startup::init_email_service(inputs.startup_env, inputs.aws_sdk_config).await?;
    let (vm_providers, aws_enabled) = api::startup::init_vm_providers(inputs.aws_sdk_config);
    let (dns_manager, dns_domain) = api::startup::init_dns_manager(inputs.aws_sdk_config);
    let node_secret_manager = api::startup::init_node_secret_manager(
        inputs.startup_env,
        aws_enabled,
        inputs.aws_sdk_config,
    );
    let alert_service = api::startup::init_alert_service(inputs.pool)?;
    let storage = api::startup::init_storage_services(inputs.startup_env, inputs.pool)?;
    let region_config =
        api::provisioner::effective_region_config(RegionConfig::from_env(), &vm_providers);
    let vm_provisioner =
        api::provisioner::build_vm_provisioner(vm_providers, region_config.clone());
    let proxy_http = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()?;
    let flapjack_proxy = Arc::new(FlapjackProxy::new_with_access_tracker(
        proxy_http,
        Arc::clone(&node_secret_manager),
        access_tracker.clone(),
    ));
    let index_replica_repo: Arc<dyn IndexReplicaRepo> =
        Arc::new(PgIndexReplicaRepo::new(inputs.pool.clone()));
    let discovery_service = Arc::new(
        DiscoveryService::new(
            inputs.repos.tenant_repo.clone() as Arc<dyn api::repos::TenantRepo + Send + Sync>,
            inputs.repos.vm_inventory_repo.clone()
                as Arc<dyn api::repos::VmInventoryRepo + Send + Sync>,
        )
        .with_replica_repo(index_replica_repo.clone()),
    );
    let replica_service = Arc::new(ReplicaService::new(
        index_replica_repo.clone(),
        inputs.repos.tenant_repo.clone() as Arc<dyn api::repos::TenantRepo + Send + Sync>,
        inputs.repos.vm_inventory_repo.clone()
            as Arc<dyn api::repos::VmInventoryRepo + Send + Sync>,
        region_config.clone(),
    ));
    let tenant_quota_service = Arc::new(TenantQuotaService::new(
        api::services::tenant_quota::QuotaDefaults::from_env(),
    ));
    let free_tier_limits = FreeTierLimits::from_env();
    Ok(RuntimeServices {
        object_store,
        object_store_resolver,
        access_tracker,
        stripe_service,
        plan_registry,
        email_service,
        vm_provisioner,
        region_config,
        dns_manager,
        dns_domain,
        node_secret_manager,
        alert_service,
        storage,
        flapjack_proxy,
        index_replica_repo,
        discovery_service,
        replica_service,
        tenant_quota_service,
        free_tier_limits,
    })
}

async fn wire_control_plane_services(
    inputs: &ServiceWireInputs<'_>,
    rt: RuntimeServices,
) -> anyhow::Result<WiredServices> {
    let provisioning_service = Arc::new(ProvisioningService::new(
        Arc::clone(&rt.vm_provisioner),
        Arc::clone(&rt.dns_manager),
        Arc::clone(&rt.node_secret_manager),
        inputs.repos.deployment_repo.clone() as Arc<dyn api::repos::DeploymentRepo + Send + Sync>,
        inputs.repos.customer_repo.clone() as Arc<dyn api::repos::CustomerRepo + Send + Sync>,
        rt.dns_domain,
    ));
    let migration_http = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()?;
    let migration_service = Arc::new(MigrationService::new(
        inputs.repos.tenant_repo.clone() as Arc<dyn api::repos::TenantRepo + Send + Sync>,
        inputs.repos.vm_inventory_repo.clone()
            as Arc<dyn api::repos::VmInventoryRepo + Send + Sync>,
        inputs.repos.index_migration_repo.clone()
            as Arc<dyn api::repos::IndexMigrationRepo + Send + Sync>,
        rt.alert_service.clone(),
        rt.discovery_service.clone(),
        Arc::clone(&rt.node_secret_manager),
        migration_http.clone(),
        3,
    ));
    let node_http = reqwest::Client::builder()
        .timeout(Duration::from_secs(120))
        .build()?;
    let node_client: Arc<dyn FlapjackNodeClient> = Arc::new(ReqwestNodeClient::new(node_http));
    let cold_snapshot_repo: Arc<dyn ColdSnapshotRepo + Send + Sync> =
        inputs.repos.cold_snapshot_repo.clone();
    let restore_service = Arc::new(RestoreService::new(
        RestoreConfig::from_env(),
        inputs.repos.tenant_repo.clone() as Arc<dyn api::repos::TenantRepo + Send + Sync>,
        cold_snapshot_repo.clone(),
        inputs.repos.restore_job_repo.clone() as Arc<dyn api::repos::RestoreJobRepo + Send + Sync>,
        inputs.repos.vm_inventory_repo.clone()
            as Arc<dyn api::repos::VmInventoryRepo + Send + Sync>,
        rt.object_store_resolver.clone(),
        rt.alert_service.clone(),
        rt.discovery_service.clone(),
        node_client.clone(),
        Arc::clone(&rt.node_secret_manager),
    ));
    let ayb_admin_client: Option<Arc<dyn AybAdminClient + Send + Sync>> =
        match &inputs.cfg.ayb_admin {
            Some(ayb_cfg) => {
                tracing::info!("AYB admin configured (cluster: {})", ayb_cfg.cluster_id);
                Some(Arc::new(ReqwestAybAdminClient::new(ayb_cfg)))
            }
            None => {
                tracing::info!("AYB admin not configured — operations will return 503");
                None
            }
        };
    if inputs.cfg.internal_auth_token.is_none() {
        tracing::warn!("INTERNAL_AUTH_TOKEN not set — /internal/* reject (fail-closed)");
    }
    Ok(WiredServices {
        object_store: rt.object_store,
        object_store_resolver: rt.object_store_resolver,
        access_tracker: rt.access_tracker,
        stripe_service: rt.stripe_service,
        plan_registry: rt.plan_registry,
        email_service: rt.email_service,
        vm_provisioner: rt.vm_provisioner,
        region_config: rt.region_config,
        dns_manager: rt.dns_manager,
        node_secret_manager: rt.node_secret_manager,
        alert_service: rt.alert_service,
        storage: rt.storage,
        provisioning_service,
        flapjack_proxy: rt.flapjack_proxy,
        index_replica_repo: rt.index_replica_repo,
        discovery_service: rt.discovery_service,
        replica_service: rt.replica_service,
        tenant_quota_service: rt.tenant_quota_service,
        free_tier_limits: rt.free_tier_limits,
        migration_service,
        migration_http_client: migration_http,
        node_client,
        cold_snapshot_repo,
        restore_service,
        ayb_admin_client,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn startup_phase_helpers_are_defined() {
        let _bootstrap_phase = bootstrap_startup_phase;
        let _app_wiring_phase = wire_app_state_phase;
        let _background_phase = setup_background_tasks_phase;
        let _launch_phase = launch_server_phase;
    }

    #[tokio::test]
    async fn shutdown_channel_starts_false_and_fans_out() {
        let (shutdown_tx, mut shutdown_rx) = create_shutdown_channel();
        let mut shutdown_rx_clone = shutdown_rx.clone();

        assert!(
            !*shutdown_rx.borrow(),
            "shutdown channel should begin at false"
        );
        shutdown_tx.send(true).expect("send should succeed");
        shutdown_rx
            .changed()
            .await
            .expect("first receiver should observe shutdown");
        shutdown_rx_clone
            .changed()
            .await
            .expect("cloned receiver should observe shutdown");
        assert!(
            *shutdown_rx.borrow(),
            "first receiver should observe true shutdown signal"
        );
        assert!(
            *shutdown_rx_clone.borrow(),
            "cloned receiver should observe true shutdown signal"
        );
    }
}
