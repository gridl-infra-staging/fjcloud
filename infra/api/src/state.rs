//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/state.rs.
use sqlx::postgres::PgPool;
use std::sync::Arc;

use crate::dns::DnsManager;
use crate::provisioner::region_map::RegionConfig;
use crate::provisioner::VmProvisioner;
use crate::repos::ApiKeyRepo;
use crate::repos::ColdSnapshotRepo;
use crate::repos::CustomerRepo;
use crate::repos::DeploymentRepo;
use crate::repos::IndexMigrationRepo;
use crate::repos::IndexReplicaRepo;
use crate::repos::InvoiceRepo;
use crate::repos::RateCardRepo;
use crate::repos::StorageBucketRepo;
use crate::repos::StorageKeyRepo;
use crate::repos::TenantRepo;
use crate::repos::UsageRepo;
use crate::repos::VmInventoryRepo;
use crate::repos::WebhookEventRepo;
use crate::services::alerting::AlertService;
use crate::services::discovery::DiscoveryService;
use crate::services::email::EmailService;
use crate::services::flapjack_proxy::FlapjackProxy;
use crate::services::metrics::MetricsCollector;
use crate::services::migration::MigrationService;
use crate::services::object_store::ObjectStore;
use crate::services::provisioning::ProvisioningService;
use crate::services::replica::ReplicaService;
use crate::services::restore::RestoreService;
use crate::services::storage::object_metering::S3ObjectMeteringService;
use crate::services::storage::s3_proxy::GarageProxy;
use crate::services::storage::StorageService;
use crate::services::tenant_quota::{FreeTierLimits, TenantQuotaService};
use crate::services::webhook_http::WebhookHttpClient;
use crate::stripe::StripeService;

/// Central shared application state cloned into every request handler.
/// Holds the database pool, JWT/admin secrets, Stripe config, metrics collector,
/// all repository trait objects (`Arc<dyn …>`), and service instances for
/// provisioning, proxying, alerting, discovery, migration, quota, replica,
/// and storage.
#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub jwt_secret: Arc<str>,
    pub admin_key: Arc<str>,
    pub internal_auth_token: Option<Arc<str>>,
    pub stripe_webhook_secret: Option<Arc<str>>,
    pub stripe_publishable_key: Option<String>,
    pub stripe_success_url: String,
    pub stripe_cancel_url: String,
    pub metrics_collector: Arc<MetricsCollector>,
    pub api_key_repo: Arc<dyn ApiKeyRepo + Send + Sync>,
    pub customer_repo: Arc<dyn CustomerRepo + Send + Sync>,
    pub deployment_repo: Arc<dyn DeploymentRepo + Send + Sync>,
    pub usage_repo: Arc<dyn UsageRepo + Send + Sync>,
    pub rate_card_repo: Arc<dyn RateCardRepo + Send + Sync>,
    pub invoice_repo: Arc<dyn InvoiceRepo + Send + Sync>,
    pub stripe_service: Arc<dyn StripeService>,
    pub webhook_http_client: Arc<dyn WebhookHttpClient>,
    pub email_service: Arc<dyn EmailService>,
    pub webhook_event_repo: Arc<dyn WebhookEventRepo + Send + Sync>,
    pub object_store: Arc<dyn ObjectStore + Send + Sync>,
    pub cold_snapshot_repo: Arc<dyn ColdSnapshotRepo + Send + Sync>,
    pub tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
    pub vm_provisioner: Arc<dyn VmProvisioner>,
    pub dns_manager: Arc<dyn DnsManager>,
    pub provisioning_service: Arc<ProvisioningService>,
    pub flapjack_proxy: Arc<FlapjackProxy>,
    pub alert_service: Arc<dyn AlertService>,
    pub vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
    pub index_migration_repo: Arc<dyn IndexMigrationRepo + Send + Sync>,
    pub discovery_service: Arc<DiscoveryService>,
    pub migration_service: Arc<MigrationService>,
    pub tenant_quota_service: Arc<TenantQuotaService>,
    pub free_tier_limits: FreeTierLimits,
    pub region_config: RegionConfig,
    pub restore_service: Option<Arc<RestoreService>>,
    pub index_replica_repo: Arc<dyn IndexReplicaRepo>,
    pub replica_service: Arc<ReplicaService>,
    pub storage_bucket_repo: Arc<dyn StorageBucketRepo + Send + Sync>,
    pub storage_key_repo: Arc<dyn StorageKeyRepo + Send + Sync>,
    pub storage_service: Arc<StorageService>,
    pub garage_proxy: Arc<GarageProxy>,
    pub s3_object_metering: Arc<S3ObjectMeteringService>,
    pub storage_master_key: [u8; 32],
}
