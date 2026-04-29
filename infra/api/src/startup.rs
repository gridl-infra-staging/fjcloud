//! Startup phase helpers extracted from main().
//!
//! Each function owns one logical phase of server bootstrap. main() calls
//! them in sequence, staying as a short orchestrator. No behavior changes —
//! this is a pure structural refactor.

mod unconfigured_stripe;
use unconfigured_stripe::UnconfiguredStripeService;

use crate::config::Config;
use crate::dns;
use crate::provisioner;
use crate::repos::{PgStorageBucketRepo, PgStorageKeyRepo};
use crate::services::access_tracker::AccessTracker;
use crate::services::alerting::{AlertService, LogAlertService, WebhookAlertService};
use crate::services::cold_tier::{ColdTierConfig, ColdTierDependencies, ColdTierService};
use crate::services::health_monitor::HealthMonitor;
use crate::services::migration::ReqwestMigrationHttpClient;
use crate::services::object_store::{
    InMemoryObjectStore, ObjectStore, RegionObjectStoreResolver, S3ObjectStore,
};
use crate::services::provisioning::resolve_dns_domain;
use crate::services::region_failover::{RegionFailoverConfig, RegionFailoverMonitor};
use crate::services::replication::{ReplicationConfig, ReplicationOrchestrator};
use crate::services::scheduler::{SchedulerConfig, SchedulerService};
use crate::startup_env::{
    ColdStorageStartupMode, NodeSecretBackendMode, RawEnvValueState, SesStartupMode,
    StartupEnvSnapshot, StorageKeyStartupMode,
};
use crate::state::AppState;
use crate::stripe::live::LiveStripeService;

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

/// Resolve the cold-storage object store and per-region resolver from env.
pub async fn init_object_store(
    startup_env: &StartupEnvSnapshot,
) -> (
    Arc<dyn ObjectStore + Send + Sync>,
    Arc<RegionObjectStoreResolver>,
) {
    let cold_storage_regions_state = startup_env.cold_storage_regions_state();

    match startup_env.cold_storage_startup_mode() {
        ColdStorageStartupMode::InMemory => {
            tracing::warn!(
                "ENVIRONMENT=local/dev + NODE_SECRET_BACKEND=memory with absent cold storage env \
                 — using in-memory cold storage object store"
            );
            let store: Arc<dyn ObjectStore + Send + Sync> = Arc::new(InMemoryObjectStore::new());
            let resolver = Arc::new(RegionObjectStoreResolver::single(Arc::clone(&store)));
            (store, resolver)
        }
        ColdStorageStartupMode::S3 => {
            let store: Arc<dyn ObjectStore + Send + Sync> =
                Arc::new(S3ObjectStore::from_env().await);
            let resolver = match cold_storage_regions_state {
                RawEnvValueState::Absent => {
                    Arc::new(RegionObjectStoreResolver::single(Arc::clone(&store)))
                }
                RawEnvValueState::Blank | RawEnvValueState::Present => {
                    Arc::new(RegionObjectStoreResolver::from_env().await)
                }
            };
            (store, resolver)
        }
    }
}

/// Build the Stripe service from config — live, local mock, or unconfigured.
pub fn init_stripe_service(cfg: &Config) -> Arc<dyn crate::stripe::StripeService> {
    match &cfg.stripe_secret_key {
        Some(key) => {
            tracing::info!("Stripe configured");
            Arc::new(LiveStripeService::new(key))
        }
        None => {
            if std::env::var("STRIPE_LOCAL_MODE")
                .ok()
                .filter(|v| v == "1")
                .is_some()
            {
                let webhook_secret = std::env::var("STRIPE_WEBHOOK_SECRET")
                    .unwrap_or_else(|_| "whsec_local_dev_secret".to_string());
                let webhook_url = std::env::var("STRIPE_WEBHOOK_URL")
                    .unwrap_or_else(|_| "http://localhost:3001/webhooks/stripe".to_string());
                let (service, dispatcher) =
                    crate::stripe::local::LocalStripeService::new(webhook_secret, webhook_url);
                tokio::spawn(dispatcher.run());
                tracing::info!(
                    "Local Stripe service configured (stateful mock with webhook dispatch)"
                );
                Arc::new(service)
            } else {
                tracing::warn!("STRIPE_SECRET_KEY not set — Stripe operations will fail");
                Arc::new(UnconfiguredStripeService)
            }
        }
    }
}

/// Build the email service — SES, Mailpit, or no-op depending on env.
pub async fn init_email_service(
    pool: &sqlx::PgPool,
    startup_env: &StartupEnvSnapshot,
    aws_sdk_config: &aws_config::SdkConfig,
) -> anyhow::Result<Arc<dyn crate::services::email::EmailService>> {
    let app_base_url = app_base_url_from_snapshot(startup_env);
    match startup_env.ses_startup_mode() {
        SesStartupMode::Noop => {
            if let Ok(mailpit_url) = std::env::var("MAILPIT_API_URL") {
                let from_email = std::env::var("EMAIL_FROM_ADDRESS")
                    .unwrap_or_else(|_| "system@flapjack.foo".to_string());
                let from_name = mailpit_from_name_from_env();
                tracing::info!("Mailpit email service configured at {mailpit_url}");
                Ok(Arc::new(
                    crate::services::email::MailpitEmailService::with_app_base_url(
                        mailpit_url,
                        from_email,
                        from_name,
                        app_base_url,
                    ),
                ))
            } else {
                tracing::warn!(
                    "ENVIRONMENT=local/dev + NODE_SECRET_BACKEND=memory with absent SES env \
                     — using noop email service"
                );
                Ok(Arc::new(crate::services::email::NoopEmailService))
            }
        }
        SesStartupMode::Ses => {
            let ses_config = crate::services::email::SesConfig::from_reader(|key| {
                startup_env.env_value(key).map(str::to_string)
            })
            .map_err(|e| anyhow::anyhow!("SES email configuration error: {e}"))?;

            let ses_sdk_config = aws_sdk_sesv2::config::Builder::from(aws_sdk_config)
                .region(aws_sdk_sesv2::config::Region::new(ses_config.region))
                .build();
            let ses_client = aws_sdk_sesv2::Client::from_conf(ses_sdk_config);
            tracing::info!("SES email service configured");
            Ok(Arc::new(
                crate::services::email::SesEmailService::with_app_base_url(
                    ses_client,
                    ses_config.from_address,
                    ses_config.configuration_set,
                    Arc::new(
                        crate::services::email_suppression::PgEmailSuppressionStore::new(
                            pool.clone(),
                        ),
                    ),
                    app_base_url,
                ),
            ))
        }
    }
}

fn app_base_url_from_snapshot(startup_env: &StartupEnvSnapshot) -> String {
    // Keep transactional links config-driven while preserving a canonical
    // Flapjack Cloud default for environments that have not set APP_BASE_URL.
    startup_env
        .env_value("APP_BASE_URL")
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(crate::services::email::DEFAULT_APP_BASE_URL)
        .trim_end_matches('/')
        .to_string()
}

fn mailpit_from_name_from_env() -> String {
    std::env::var("EMAIL_FROM_NAME").unwrap_or_else(|_| "Flapjack Cloud".to_string())
}

/// Register all configured VM provider backends and return the map + whether
/// AWS was successfully configured (needed for SSM secret manager fallback).
pub fn init_vm_providers(
    aws_sdk_config: &aws_config::SdkConfig,
) -> (HashMap<String, Arc<dyn provisioner::VmProvisioner>>, bool) {
    let aws_cfg = provisioner::aws::AwsProvisionerConfig::from_env();
    let gcp_cfg = provisioner::gcp::GcpProvisionerConfig::from_env();
    let hetzner_cfg = provisioner::hetzner::HetznerProvisionerConfig::from_env();
    let oci_cfg = provisioner::oci::OciProvisionerConfig::from_env();
    let ssh_cfg = provisioner::ssh::SshProvisionerConfig::from_env();

    let mut providers: HashMap<String, Arc<dyn provisioner::VmProvisioner>> = HashMap::new();

    if let Ok(cfg) = &aws_cfg {
        let ec2_client = aws_sdk_ec2::Client::new(aws_sdk_config);
        tracing::info!("AWS VM provisioner configured: ami={}", cfg.ami_id);
        providers.insert(
            "aws".to_string(),
            Arc::new(provisioner::aws::AwsVmProvisioner::new(
                cfg.clone(),
                ec2_client,
            )),
        );
    } else if let Err(err) = &aws_cfg {
        tracing::warn!("AWS VM provisioner not configured: {err}");
    }

    if let Ok(cfg) = &gcp_cfg {
        tracing::info!(
            "GCP VM provisioner configured: project={}, zone={}, machine_type={}",
            cfg.project_id,
            cfg.zone,
            cfg.machine_type
        );
        providers.insert(
            "gcp".to_string(),
            Arc::new(provisioner::gcp::GcpVmProvisioner::new(cfg.clone())),
        );
    } else if let Err(err) = &gcp_cfg {
        tracing::warn!("GCP VM provisioner not configured: {err}");
    }

    if let Ok(cfg) = &hetzner_cfg {
        tracing::info!(
            "Hetzner VM provisioner configured: type={}, image={}, location={}",
            cfg.server_type,
            cfg.image,
            cfg.location
        );
        providers.insert(
            "hetzner".to_string(),
            Arc::new(provisioner::hetzner::HetznerVmProvisioner::new(cfg.clone())),
        );
    } else if let Err(err) = &hetzner_cfg {
        tracing::warn!("Hetzner VM provisioner not configured: {err}");
    }

    if let Ok(cfg) = &oci_cfg {
        tracing::info!(
            "OCI VM provisioner configured: region={}, ad={}, shape={}",
            cfg.region,
            cfg.availability_domain,
            cfg.shape
        );
        match provisioner::oci::OciVmProvisioner::new(cfg.clone()) {
            Ok(p) => {
                providers.insert("oci".to_string(), Arc::new(p));
            }
            Err(err) => {
                tracing::warn!("OCI VM provisioner failed to initialize: {err}");
            }
        }
    } else if let Err(err) = &oci_cfg {
        tracing::warn!("OCI VM provisioner not configured: {err}");
    }

    if let Ok(cfg) = &ssh_cfg {
        tracing::info!(
            "SSH bare-metal VM provisioner configured: user={}, port={}, servers={}",
            cfg.ssh_user,
            cfg.ssh_port,
            cfg.servers.len()
        );
        providers.insert(
            "bare_metal".to_string(),
            Arc::new(provisioner::ssh::SshVmProvisioner::new(cfg.clone())),
        );
    } else if let Err(err) = &ssh_cfg {
        tracing::warn!("SSH bare-metal VM provisioner not configured: {err}");
    }

    if aws_cfg.is_err()
        && gcp_cfg.is_err()
        && hetzner_cfg.is_err()
        && oci_cfg.is_err()
        && ssh_cfg.is_err()
    {
        tracing::warn!(
            "No VM providers configured — set at least one of: AWS_AMI_ID, \
             GCP_API_TOKEN+GCP_PROJECT_ID, HETZNER_API_TOKEN, OCI_TENANCY_OCID+..., \
             or SSH_KEY_PATH+SSH_SERVERS"
        );
    }

    let aws_enabled = aws_cfg.is_ok();
    (providers, aws_enabled)
}

/// Build the DNS manager — Route53 if zone ID is set, otherwise unconfigured.
pub fn init_dns_manager(
    aws_sdk_config: &aws_config::SdkConfig,
) -> (Arc<dyn dns::DnsManager>, String) {
    let dns_domain = resolve_dns_domain();

    let cloudflare_api_token = std::env::var("CLOUDFLARE_API_TOKEN")
        .ok()
        .or_else(|| std::env::var("CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_FLAPJACK_FOO").ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    let cloudflare_zone_id = std::env::var("CLOUDFLARE_ZONE_ID")
        .ok()
        .or_else(|| std::env::var("CLOUDFLARE_ZONE_ID_FLAPJACK_FOO").ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());

    let manager: Arc<dyn dns::DnsManager> = if let (Some(api_token), Some(zone_id)) =
        (cloudflare_api_token, cloudflare_zone_id)
    {
        tracing::info!("DNS configured: provider=cloudflare, zone={zone_id}, domain={dns_domain}");
        Arc::new(dns::cloudflare::CloudflareDnsManager::new(
            reqwest::Client::new(),
            api_token,
            zone_id,
            dns_domain.clone(),
        ))
    } else if let Some(zone_id) = std::env::var("DNS_HOSTED_ZONE_ID")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
    {
        let r53_client = aws_sdk_route53::Client::new(aws_sdk_config);
        tracing::info!("DNS configured: provider=route53, zone={zone_id}, domain={dns_domain}");
        Arc::new(dns::route53::Route53DnsManager::new(
            r53_client,
            zone_id,
            dns_domain.clone(),
        ))
    } else {
        tracing::warn!(
            "No DNS provider configured — set CLOUDFLARE_API_TOKEN+CLOUDFLARE_ZONE_ID \
                 (or flapjack.foo aliases) or DNS_HOSTED_ZONE_ID"
        );
        Arc::new(dns::UnconfiguredDnsManager)
    };

    (manager, dns_domain)
}

/// Build the node secret manager — in-memory, SSM, or unconfigured.
pub fn init_node_secret_manager(
    startup_env: &StartupEnvSnapshot,
    aws_provisioner_enabled: bool,
    aws_sdk_config: &aws_config::SdkConfig,
) -> Arc<dyn crate::secrets::NodeSecretManager> {
    let local_zero_dependency_mode = startup_env.is_local_zero_dependency_mode();
    let backend = startup_env.classify_node_secret_backend();

    match backend {
        NodeSecretBackendMode::Memory => {
            if local_zero_dependency_mode {
                tracing::warn!(
                    "ENVIRONMENT=local/dev + NODE_SECRET_BACKEND=memory configured \
                     — using in-memory node secrets (local dev only)"
                );
            } else {
                tracing::warn!(
                    "NODE_SECRET_BACKEND=memory configured without ENVIRONMENT=local/dev \
                     — using in-memory node secrets but keeping production startup checks enabled"
                );
            }
            Arc::new(crate::secrets::memory::InMemoryNodeSecretManager::new())
        }
        NodeSecretBackendMode::Disabled { normalized_backend } => {
            tracing::warn!(
                "NODE_SECRET_BACKEND={normalized_backend} configured \
                 — node secret manager disabled"
            );
            Arc::new(crate::secrets::UnconfiguredNodeSecretManager)
        }
        NodeSecretBackendMode::AutoLike { normalized_backend } => {
            let b = normalized_backend.as_str();
            if b != "ssm" && b != "auto" && !b.is_empty() {
                tracing::warn!("Unknown NODE_SECRET_BACKEND='{b}' — falling back to auto mode");
            }
            if aws_provisioner_enabled {
                let ssm_client = aws_sdk_ssm::Client::new(aws_sdk_config);
                tracing::info!("SSM node secret manager configured");
                Arc::new(crate::secrets::aws::SsmNodeSecretManager::new(ssm_client))
            } else {
                let hint = if b == "ssm" {
                    "NODE_SECRET_BACKEND=ssm set but AWS provisioner is not configured \
                     — node secrets unavailable"
                } else {
                    "AWS provisioner not configured — node secret manager will be unavailable \
                     (set NODE_SECRET_BACKEND=memory for local dev)"
                };
                tracing::warn!("{}", hint);
                Arc::new(crate::secrets::UnconfiguredNodeSecretManager)
            }
        }
    }
}

/// Build the alert service — webhook-backed if Slack/Discord URL is set,
/// otherwise log-only.
pub fn init_alert_service(pool: &sqlx::PgPool) -> anyhow::Result<Arc<dyn AlertService>> {
    let slack_url = std::env::var("SLACK_WEBHOOK_URL").ok();
    let discord_url = std::env::var("DISCORD_WEBHOOK_URL").ok();

    if slack_url.is_some() || discord_url.is_some() {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()?;
        let environment = std::env::var("ENVIRONMENT").unwrap_or_else(|_| "unknown".to_string());
        if slack_url.is_some() {
            tracing::info!("Slack alert webhook configured");
        }
        if discord_url.is_some() {
            tracing::info!("Discord alert webhook configured");
        }
        Ok(Arc::new(WebhookAlertService::new(
            pool.clone(),
            http,
            slack_url,
            discord_url,
            environment,
        )))
    } else {
        tracing::info!("No webhook URLs — using log-only alert service");
        Ok(Arc::new(LogAlertService::new(pool.clone())))
    }
}

/// Components returned by [`init_storage_services`].
pub struct StorageComponents {
    pub storage_bucket_repo: Arc<dyn crate::repos::StorageBucketRepo + Send + Sync>,
    pub storage_key_repo: Arc<dyn crate::repos::StorageKeyRepo + Send + Sync>,
    pub storage_service: Arc<crate::services::storage::StorageService>,
    pub garage_proxy: Arc<crate::services::storage::s3_proxy::GarageProxy>,
    pub s3_object_metering: Arc<crate::services::storage::object_metering::S3ObjectMeteringService>,
    pub storage_master_key: [u8; 32],
}

/// Build the storage service stack: bucket/key repos, Garage admin, encryption,
/// S3 proxy, and object metering.
pub fn init_storage_services(
    startup_env: &StartupEnvSnapshot,
    pool: &sqlx::PgPool,
) -> anyhow::Result<StorageComponents> {
    let storage_bucket_repo = Arc::new(PgStorageBucketRepo::new(pool.clone()));
    let storage_key_repo = Arc::new(PgStorageKeyRepo::new(pool.clone()));

    let garage_admin_http = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()?;
    let garage_admin_client: Arc<dyn crate::services::storage::GarageAdminClient> = Arc::new(
        crate::services::storage::garage_admin::ReqwestGarageAdminClient::from_env(
            garage_admin_http,
        ),
    );

    let storage_master_key = match startup_env.storage_key_startup_mode() {
        StorageKeyStartupMode::DevKey => {
            tracing::warn!(
                "ENVIRONMENT=local/dev + NODE_SECRET_BACKEND=memory enabled deterministic \
                 dev master key — NOT for production"
            );
            crate::services::storage::encryption::deterministic_dev_master_key()
        }
        StorageKeyStartupMode::Parse => {
            let hex_key = startup_env
                .storage_encryption_key_raw()
                .ok_or_else(|| anyhow::anyhow!("STORAGE_ENCRYPTION_KEY is required"))?;
            crate::services::storage::encryption::parse_master_key_hex(hex_key)
                .map_err(|e| anyhow::anyhow!("invalid STORAGE_ENCRYPTION_KEY: {e}"))?
        }
    };

    let storage_service = Arc::new(crate::services::storage::StorageService::new(
        storage_bucket_repo.clone() as Arc<dyn crate::repos::StorageBucketRepo + Send + Sync>,
        storage_key_repo.clone() as Arc<dyn crate::repos::StorageKeyRepo + Send + Sync>,
        garage_admin_client,
        storage_master_key,
    ));

    let garage_proxy_http = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()?;
    let garage_proxy = Arc::new(crate::services::storage::s3_proxy::GarageProxy::from_env(
        garage_proxy_http,
    ));

    let s3_object_metering = Arc::new(
        crate::services::storage::object_metering::S3ObjectMeteringService::new(
            storage_bucket_repo.clone() as Arc<dyn crate::repos::StorageBucketRepo + Send + Sync>,
            garage_proxy.clone(),
        ),
    );

    Ok(StorageComponents {
        storage_bucket_repo: storage_bucket_repo
            as Arc<dyn crate::repos::StorageBucketRepo + Send + Sync>,
        storage_key_repo: storage_key_repo as Arc<dyn crate::repos::StorageKeyRepo + Send + Sync>,
        storage_service,
        garage_proxy,
        s3_object_metering,
        storage_master_key,
    })
}

/// Handles returned by [`spawn_background_tasks`] for shutdown coordination.
pub struct BackgroundHandles {
    pub named_handles: Vec<(&'static str, tokio::task::JoinHandle<()>)>,
    pub access_tracker_handle: tokio::task::JoinHandle<()>,
}

/// Dependencies for background task spawning, bundled to stay under the
/// 6-parameter hard limit.
pub struct BackgroundDeps {
    pub node_secret_manager: Arc<dyn crate::secrets::NodeSecretManager>,
    pub access_tracker: Arc<AccessTracker>,
    pub cold_snapshot_repo: Arc<dyn crate::repos::ColdSnapshotRepo + Send + Sync>,
    pub object_store_resolver: Arc<RegionObjectStoreResolver>,
    pub node_client: Arc<dyn crate::services::cold_tier::FlapjackNodeClient>,
    pub migration_http_client: reqwest::Client,
}

/// Spawn all background services (health monitor, scheduler, replication,
/// region failover, cold tier, access tracker). Returns handles for
/// shutdown-time join.
pub fn spawn_background_tasks(
    state: &AppState,
    deps: BackgroundDeps,
    shutdown_rx: tokio::sync::watch::Receiver<bool>,
) -> anyhow::Result<BackgroundHandles> {
    // Health monitor
    let health_http = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()?;
    let health_monitor = Arc::new(HealthMonitor::new(
        state.deployment_repo.clone(),
        health_http,
        Duration::from_secs(60),
        Some(state.alert_service.clone()),
    ));
    let health_monitor_handle = {
        let monitor = Arc::clone(&health_monitor);
        let rx = shutdown_rx.clone();
        tokio::spawn(async move {
            monitor.run(rx).await;
        })
    };

    // Scheduler
    let scheduler_http = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()?;
    let scheduler = Arc::new(SchedulerService::new(
        SchedulerConfig::from_env(),
        state.vm_inventory_repo.clone(),
        state.tenant_repo.clone(),
        state.migration_service.clone(),
        state.alert_service.clone(),
        Arc::clone(&deps.node_secret_manager),
        scheduler_http,
    ));
    let scheduler_handle = {
        let s = Arc::clone(&scheduler);
        let rx = shutdown_rx.clone();
        tokio::spawn(async move {
            s.run(rx).await;
        })
    };

    // Replication orchestrator
    let replication_orchestrator = Arc::new(ReplicationOrchestrator::new(
        state.index_replica_repo.clone(),
        state.vm_inventory_repo.clone(),
        Arc::new(ReqwestMigrationHttpClient::new(deps.migration_http_client)),
        Arc::clone(&deps.node_secret_manager),
        ReplicationConfig::from_env(),
    ));
    let replication_handle = {
        let o = Arc::clone(&replication_orchestrator);
        let rx = shutdown_rx.clone();
        tokio::spawn(async move {
            o.run(rx).await;
        })
    };

    // Region failover monitor
    let region_failover_monitor = Arc::new(RegionFailoverMonitor::new(
        state.vm_inventory_repo.clone(),
        state.tenant_repo.clone(),
        state.index_replica_repo.clone(),
        state.alert_service.clone(),
        RegionFailoverConfig::from_env(),
    ));
    let region_failover_handle = {
        let monitor = Arc::clone(&region_failover_monitor);
        let rx = shutdown_rx.clone();
        monitor.spawn(rx)
    };

    // Access tracker
    let access_tracker_handle = deps.access_tracker.start(60);

    // Cold tier manager
    let cold_tier_service = Arc::new(ColdTierService::new(
        ColdTierConfig::from_env(),
        ColdTierDependencies {
            tenant_repo: state.tenant_repo.clone(),
            index_migration_repo: state.index_migration_repo.clone(),
            cold_snapshot_repo: deps.cold_snapshot_repo,
            vm_inventory_repo: state.vm_inventory_repo.clone(),
            object_store_resolver: deps.object_store_resolver,
            alert_service: state.alert_service.clone(),
            discovery_service: state.discovery_service.clone(),
            node_client: deps.node_client,
            node_secret_manager: deps.node_secret_manager,
        },
    ));
    let cold_tier_handle = {
        let service = Arc::clone(&cold_tier_service);
        let rx = shutdown_rx.clone();
        tokio::spawn(async move {
            service.run(rx).await;
        })
    };

    Ok(BackgroundHandles {
        named_handles: vec![
            ("health monitor", health_monitor_handle),
            ("scheduler", scheduler_handle),
            ("replication", replication_handle),
            ("region failover", region_failover_handle),
            ("cold tier", cold_tier_handle),
        ],
        access_tracker_handle,
    })
}

/// Run both API and S3 servers, then await shutdown and join background tasks.
pub async fn serve(
    state: AppState,
    cfg: &Config,
    shutdown_tx: tokio::sync::watch::Sender<bool>,
    shutdown_rx: tokio::sync::watch::Receiver<bool>,
    handles: BackgroundHandles,
) -> anyhow::Result<()> {
    let s3_app = crate::router::build_s3_router(state.clone(), cfg);
    let app = crate::router::build_router(state);
    let listener = tokio::net::TcpListener::bind(&cfg.listen_addr).await?;
    let s3_listener = tokio::net::TcpListener::bind(&cfg.s3_listen_addr).await?;
    tracing::info!("API listening on {}", cfg.listen_addr);
    tracing::info!("S3 API listening on {}", cfg.s3_listen_addr);

    let s3_shutdown_rx = shutdown_rx.clone();
    let s3_server_handle = tokio::spawn(async move {
        axum::serve(s3_listener, s3_app)
            .with_graceful_shutdown(wait_for_shutdown(s3_shutdown_rx))
            .await
    });

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal(shutdown_tx))
        .await?;

    match s3_server_handle.await {
        Ok(Ok(())) => {}
        Ok(Err(error)) => tracing::error!("S3 API server failed: {error}"),
        Err(error) => tracing::error!("S3 API server task join failed: {error}"),
    }

    // Wait for background tasks to finish and log any failures
    for (name, handle) in handles.named_handles {
        if let Err(e) = handle.await {
            tracing::error!("{name} task failed: {e}");
        }
    }
    handles.access_tracker_handle.abort();
    let _ = handles.access_tracker_handle.await;

    Ok(())
}

async fn shutdown_signal(shutdown_tx: tokio::sync::watch::Sender<bool>) {
    tokio::signal::ctrl_c()
        .await
        .expect("failed to install ctrl-c handler");
    tracing::info!("shutdown signal received");
    let _ = shutdown_tx.send(true);
}

async fn wait_for_shutdown(mut shutdown_rx: tokio::sync::watch::Receiver<bool>) {
    let _ = shutdown_rx.wait_for(|&shutdown| shutdown).await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    struct EnvVarGuard {
        key: &'static str,
        previous: Option<String>,
    }

    impl EnvVarGuard {
        fn set(key: &'static str, value: Option<&str>) -> Self {
            let previous = std::env::var(key).ok();
            // SAFETY: The env lock serializes these process-env mutations.
            unsafe {
                match value {
                    Some(v) => std::env::set_var(key, v),
                    None => std::env::remove_var(key),
                }
            }
            Self { key, previous }
        }
    }

    impl Drop for EnvVarGuard {
        fn drop(&mut self) {
            // SAFETY: The env lock serializes these process-env mutations.
            unsafe {
                match &self.previous {
                    Some(value) => std::env::set_var(self.key, value),
                    None => std::env::remove_var(self.key),
                }
            }
        }
    }

    #[test]
    fn mailpit_from_name_falls_back_to_flapjack_cloud() {
        let _guard = env_lock().lock().expect("env lock poisoned");
        let _env = EnvVarGuard::set("EMAIL_FROM_NAME", None);

        assert_eq!(mailpit_from_name_from_env(), "Flapjack Cloud");
    }

    #[test]
    fn mailpit_from_name_respects_env_override() {
        let _guard = env_lock().lock().expect("env lock poisoned");
        let _env = EnvVarGuard::set("EMAIL_FROM_NAME", Some("Custom Sender"));

        assert_eq!(mailpit_from_name_from_env(), "Custom Sender");
    }
}
