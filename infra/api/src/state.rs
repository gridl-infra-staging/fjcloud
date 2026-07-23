use sqlx::postgres::PgPool;
use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use serde::Serialize;
use uuid::Uuid;

use crate::dns::DnsManager;
use crate::provisioner::region_map::RegionConfig;
use crate::provisioner::VmProvisioner;
use crate::repos::ApiKeyRepo;
use crate::repos::ColdSnapshotRepo;
use crate::repos::CustomerRepo;
use crate::repos::DeploymentRepo;
use crate::repos::DisputeRepo;
use crate::repos::IndexMigrationRepo;
use crate::repos::IndexReplicaRepo;
use crate::repos::InvoiceRepo;
use crate::repos::RateCardRepo;
use crate::repos::StorageBucketRepo;
use crate::repos::StorageKeyRepo;
use crate::repos::TenantRepo;
use crate::repos::UsageRepo;
use crate::repos::VmHostMetricsRepo;
use crate::repos::VmInventoryRepo;
use crate::repos::WebhookEventRepo;
use crate::routes::public_infrastructure::PublicInfrastructureResponse;
use crate::services::alerting::AlertService;
use crate::services::algolia_import::AlgoliaImportService;
use crate::services::algolia_source::AlgoliaSourceLister;
use crate::services::discovery::DiscoveryService;
use crate::services::email::EmailService;
use crate::services::flapjack_proxy::FlapjackProxy;
use crate::services::index_lifecycle_lease::IndexLifecycleLease;
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
use crate::services::vm_orphan_reconcile::VmOrphanReconciler;
use crate::services::webhook_http::WebhookHttpClient;
use crate::stripe::StripeService;

#[derive(Clone, Debug)]
pub struct OAuthProviderRuntimeConfig {
    pub client_id: Arc<str>,
    pub client_secret: Arc<str>,
    pub redirect_uri: Arc<str>,
    pub token_endpoint: Arc<str>,
    pub userinfo_endpoint: Arc<str>,
    pub user_emails_endpoint: Option<Arc<str>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OAuthCookieSameSite {
    Lax,
    None,
}

impl OAuthCookieSameSite {
    pub fn header_value(self) -> &'static str {
        match self {
            Self::Lax => "Lax",
            Self::None => "None",
        }
    }
}

#[derive(Clone, Debug)]
pub struct OAuthRuntimeConfig {
    pub google: Option<OAuthProviderRuntimeConfig>,
    pub github: Option<OAuthProviderRuntimeConfig>,
    pub cookie_domain: Option<Arc<str>>,
    pub cookie_secure: bool,
    pub cookie_same_site: OAuthCookieSameSite,
}

impl Default for OAuthRuntimeConfig {
    fn default() -> Self {
        Self {
            google: None,
            github: None,
            cookie_domain: None,
            // OAuth callbacks are cross-site navigations in production, so the
            // secure SameSite=None policy remains the default outside explicit
            // local-http overrides.
            cookie_secure: true,
            cookie_same_site: OAuthCookieSameSite::None,
        }
    }
}

#[derive(Debug, Clone, Serialize, utoipa::ToSchema)]
pub struct CustomerIndexMetricsResponse {
    pub index: String,
    pub documents_count: u64,
    pub storage_bytes: u64,
    pub search_requests_total: u64,
    pub write_operations_total: u64,
    pub fetched_at: DateTime<Utc>,
}

pub const DEFAULT_METRICS_CACHE_TTL: Duration = Duration::from_secs(60);
pub const DEFAULT_PUBLIC_INFRASTRUCTURE_CACHE_TTL: Duration = Duration::from_secs(10);

type MetricsCacheKey = (Uuid, String);

pub struct MetricsCache {
    entries: RwLock<HashMap<MetricsCacheKey, CustomerIndexMetricsResponse>>,
    ttl: Duration,
}

impl Default for MetricsCache {
    fn default() -> Self {
        Self {
            entries: RwLock::new(HashMap::new()),
            ttl: DEFAULT_METRICS_CACHE_TTL,
        }
    }
}

impl MetricsCache {
    pub fn with_ttl(ttl: Duration) -> Self {
        Self {
            entries: RwLock::new(HashMap::new()),
            ttl,
        }
    }

    pub fn ttl(&self) -> Duration {
        self.ttl
    }

    pub fn get(&self, customer_id: Uuid, index_name: &str) -> Option<CustomerIndexMetricsResponse> {
        let entries = self.entries.read().unwrap();
        let key = (customer_id, index_name.to_string());
        let entry = entries.get(&key)?;
        let age = Utc::now().signed_duration_since(entry.fetched_at);
        if age.num_milliseconds() < self.ttl.as_millis() as i64 {
            Some(entry.clone())
        } else {
            None
        }
    }

    pub fn insert(
        &self,
        customer_id: Uuid,
        index_name: &str,
        response: CustomerIndexMetricsResponse,
    ) {
        let key = (customer_id, index_name.to_string());
        let mut entries = self.entries.write().unwrap();
        entries.insert(key, response);
    }

    pub fn expire_for_test(&self, customer_id: Uuid, index_name: &str) {
        let key = (customer_id, index_name.to_string());
        let mut entries = self.entries.write().unwrap();
        entries.remove(&key);
    }
}

pub struct PublicInfrastructureCache {
    entry: RwLock<Option<(Instant, PublicInfrastructureResponse)>>,
    ttl: Duration,
}

impl Default for PublicInfrastructureCache {
    fn default() -> Self {
        Self {
            entry: RwLock::new(None),
            ttl: DEFAULT_PUBLIC_INFRASTRUCTURE_CACHE_TTL,
        }
    }
}

impl PublicInfrastructureCache {
    pub fn with_ttl(ttl: Duration) -> Self {
        Self {
            entry: RwLock::new(None),
            ttl,
        }
    }

    pub fn ttl(&self) -> Duration {
        self.ttl
    }

    pub fn get(&self) -> Option<PublicInfrastructureResponse> {
        let entry = self.entry.read().unwrap();
        let (inserted_at, response) = entry.as_ref()?;
        if inserted_at.elapsed() < self.ttl {
            Some(response.clone())
        } else {
            None
        }
    }

    pub fn insert(&self, response: PublicInfrastructureResponse) {
        let mut entry = self.entry.write().unwrap();
        *entry = Some((Instant::now(), response));
    }

    pub fn expire_for_test(&self) {
        let mut entry = self.entry.write().unwrap();
        *entry = None;
    }
}

/// Central shared application state cloned into every request handler.
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
    pub dispute_repo: Arc<dyn DisputeRepo + Send + Sync>,
    pub stripe_service: Arc<dyn StripeService>,
    pub webhook_http_client: Arc<dyn WebhookHttpClient>,
    pub email_service: Arc<dyn EmailService>,
    pub dunning_emails_disabled: bool,
    pub algolia_migration_enabled: bool,
    pub algolia_import_service: Arc<AlgoliaImportService>,
    pub algolia_source_service: Arc<dyn AlgoliaSourceLister>,
    pub webhook_event_repo: Arc<dyn WebhookEventRepo + Send + Sync>,
    pub object_store: Arc<dyn ObjectStore + Send + Sync>,
    pub cold_snapshot_repo: Arc<dyn ColdSnapshotRepo + Send + Sync>,
    pub tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
    pub vm_provisioner: Arc<dyn VmProvisioner>,
    pub dns_manager: Arc<dyn DnsManager>,
    pub provisioning_service: Arc<ProvisioningService>,
    pub flapjack_proxy: Arc<FlapjackProxy>,
    pub alert_service: Arc<dyn AlertService>,
    pub vm_host_metrics_repo: Arc<dyn VmHostMetricsRepo + Send + Sync>,
    pub vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
    pub vm_orphan_reconciler: Arc<VmOrphanReconciler>,
    pub index_migration_repo: Arc<dyn IndexMigrationRepo + Send + Sync>,
    pub discovery_service: Arc<DiscoveryService>,
    pub migration_service: Arc<MigrationService>,
    pub tenant_quota_service: Arc<TenantQuotaService>,
    pub free_tier_limits: FreeTierLimits,
    pub region_config: RegionConfig,
    pub restore_service: Option<Arc<RestoreService>>,
    pub index_replica_repo: Arc<dyn IndexReplicaRepo>,
    pub replica_service: Arc<ReplicaService>,
    pub index_lifecycle_lease: Arc<IndexLifecycleLease>,
    pub storage_bucket_repo: Arc<dyn StorageBucketRepo + Send + Sync>,
    pub storage_key_repo: Arc<dyn StorageKeyRepo + Send + Sync>,
    pub storage_service: Arc<StorageService>,
    pub garage_proxy: Arc<GarageProxy>,
    pub s3_object_metering: Arc<S3ObjectMeteringService>,
    pub storage_master_key: [u8; 32],
    pub oauth: OAuthRuntimeConfig,
    pub metrics_cache: Arc<MetricsCache>,
    pub public_infrastructure_cache: Arc<PublicInfrastructureCache>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::routes::public_infrastructure::{
        PublicInfrastructureOverall, PublicInfrastructureResponse, PublicRegionHealth,
        PublicRegionInfrastructure,
    };

    fn public_infrastructure_response() -> PublicInfrastructureResponse {
        PublicInfrastructureResponse {
            regions: vec![PublicRegionInfrastructure {
                region: "alpha-1".to_string(),
                provider: "aws".to_string(),
                display_name: "Alpha Region".to_string(),
                provider_location: "alpha-location".to_string(),
                health: PublicRegionHealth::Operational,
                utilization: None,
                vm_count: 2,
            }],
            overall: PublicInfrastructureOverall {
                availability_pct: Some(100.0),
                total_regions: 1,
                total_vms: 2,
            },
        }
    }

    #[test]
    fn public_infrastructure_cache_uses_default_and_injected_ttl() {
        assert_eq!(
            PublicInfrastructureCache::default().ttl(),
            DEFAULT_PUBLIC_INFRASTRUCTURE_CACHE_TTL
        );
        assert_eq!(
            PublicInfrastructureCache::with_ttl(Duration::from_secs(3)).ttl(),
            Duration::from_secs(3)
        );
    }

    #[test]
    fn public_infrastructure_cache_insert_get_roundtrip() {
        let cache = PublicInfrastructureCache::default();
        let response = public_infrastructure_response();

        cache.insert(response.clone());

        assert_eq!(cache.get(), Some(response));
    }

    #[test]
    fn public_infrastructure_cache_expire_for_test_removes_entry() {
        let cache = PublicInfrastructureCache::default();

        cache.insert(public_infrastructure_response());
        assert!(cache.get().is_some());

        cache.expire_for_test();
        assert!(cache.get().is_none());
    }

    #[test]
    fn metrics_cache_insert_get_roundtrip() {
        let cache = MetricsCache::default();
        let customer_id = Uuid::new_v4();
        let response = CustomerIndexMetricsResponse {
            index: "products".to_string(),
            documents_count: 100,
            storage_bytes: 2048,
            search_requests_total: 50,
            write_operations_total: 10,
            fetched_at: Utc::now(),
        };

        cache.insert(customer_id, "products", response.clone());
        let got = cache.get(customer_id, "products").unwrap();
        assert_eq!(got.index, "products");
        assert_eq!(got.documents_count, 100);
        assert_eq!(got.storage_bytes, 2048);
        assert_eq!(got.search_requests_total, 50);
        assert_eq!(got.write_operations_total, 10);
    }

    #[test]
    fn metrics_cache_expire_for_test_removes_entry() {
        let cache = MetricsCache::default();
        let customer_id = Uuid::new_v4();
        let response = CustomerIndexMetricsResponse {
            index: "products".to_string(),
            documents_count: 1,
            storage_bytes: 1,
            search_requests_total: 1,
            write_operations_total: 1,
            fetched_at: Utc::now(),
        };

        cache.insert(customer_id, "products", response);
        assert!(cache.get(customer_id, "products").is_some());

        cache.expire_for_test(customer_id, "products");
        assert!(cache.get(customer_id, "products").is_none());
    }

    #[test]
    fn metrics_cache_isolates_distinct_keys() {
        let cache = MetricsCache::default();
        let customer_a = Uuid::new_v4();
        let customer_b = Uuid::new_v4();

        let resp_a = CustomerIndexMetricsResponse {
            index: "idx_a".to_string(),
            documents_count: 100,
            storage_bytes: 200,
            search_requests_total: 300,
            write_operations_total: 400,
            fetched_at: Utc::now(),
        };
        let resp_b = CustomerIndexMetricsResponse {
            index: "idx_b".to_string(),
            documents_count: 999,
            storage_bytes: 888,
            search_requests_total: 777,
            write_operations_total: 666,
            fetched_at: Utc::now(),
        };

        cache.insert(customer_a, "idx_a", resp_a);
        cache.insert(customer_b, "idx_b", resp_b);

        assert!(cache.get(customer_a, "idx_b").is_none());
        assert!(cache.get(customer_b, "idx_a").is_none());

        let got_a = cache.get(customer_a, "idx_a").unwrap();
        assert_eq!(got_a.documents_count, 100);

        let got_b = cache.get(customer_b, "idx_b").unwrap();
        assert_eq!(got_b.documents_count, 999);
    }
}
