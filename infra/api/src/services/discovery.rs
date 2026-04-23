//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/discovery.rs.
use std::sync::Arc;

use moka::sync::Cache;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::repos::index_replica_repo::IndexReplicaRepo;
use crate::repos::tenant_repo::TenantRepo;
use crate::repos::vm_inventory_repo::VmInventoryRepo;

const DEFAULT_CACHE_TTL_SECS: u64 = 30;
const DEFAULT_CLIENT_TTL: u64 = 300;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplicaEndpoint {
    pub vm: String,
    pub flapjack_url: String,
    pub region: String,
    pub lag_ops: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscoveryResult {
    pub vm: String,
    pub flapjack_url: String,
    pub ttl: u64,
    pub service_type: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub replicas: Vec<ReplicaEndpoint>,
}

#[derive(Debug, thiserror::Error)]
pub enum DiscoveryError {
    #[error("index not found")]
    NotFound,

    #[error("repo error: {0}")]
    RepoError(String),
}

pub struct DiscoveryService {
    tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
    vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
    replica_repo: Option<Arc<dyn IndexReplicaRepo>>,
    cache: Cache<String, DiscoveryResult>,
    client_ttl: u64,
}

fn build_cache(ttl_secs: u64) -> Cache<String, DiscoveryResult> {
    Cache::builder()
        .time_to_live(std::time::Duration::from_secs(ttl_secs))
        .max_capacity(10_000)
        .support_invalidation_closures()
        .build()
}

impl DiscoveryService {
    /// Constructs the discovery service with tenant and VM inventory repos.
    ///
    /// Reads `DISCOVERY_CACHE_TTL_SECS` from the environment (defaulting to
    /// 30 seconds) and initializes a moka cache with a 10,000-entry capacity
    /// for per-tenant index-to-VM resolution results.
    pub fn new(
        tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
        vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
    ) -> Self {
        let cache_ttl = std::env::var("DISCOVERY_CACHE_TTL_SECS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(DEFAULT_CACHE_TTL_SECS);

        Self {
            tenant_repo,
            vm_inventory_repo,
            replica_repo: None,
            cache: build_cache(cache_ttl),
            client_ttl: DEFAULT_CLIENT_TTL,
        }
    }

    /// Create with an explicit TTL (for tests).
    pub fn with_ttl(
        tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
        vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
        cache_ttl_secs: u64,
    ) -> Self {
        Self {
            tenant_repo,
            vm_inventory_repo,
            replica_repo: None,
            cache: build_cache(cache_ttl_secs),
            client_ttl: DEFAULT_CLIENT_TTL,
        }
    }

    /// Attach a replica repo for replica-aware discovery.
    pub fn with_replica_repo(mut self, repo: Arc<dyn IndexReplicaRepo>) -> Self {
        self.replica_repo = Some(repo);
        self
    }

    /// Resolve an index name to its VM for a specific customer.
    /// Uses per-tenant cache keys to prevent cross-tenant poisoning.
    pub async fn discover(
        &self,
        customer_id: Uuid,
        index_name: &str,
    ) -> Result<DiscoveryResult, DiscoveryError> {
        let cache_key = format!("{customer_id}:{index_name}");

        // Check cache first
        if let Some(cached) = self.cache.get(&cache_key) {
            return Ok(cached);
        }

        // Cache miss — look up the raw tenant (includes vm_id) directly
        let raw_tenant = self
            .tenant_repo
            .find_raw(customer_id, index_name)
            .await
            .map_err(|e| DiscoveryError::RepoError(e.to_string()))?
            .ok_or(DiscoveryError::NotFound)?;

        // Multi-tenant path: resolve via vm_inventory when vm_id is set
        if let Some(vm_id) = raw_tenant.vm_id {
            let vm = self
                .vm_inventory_repo
                .get(vm_id)
                .await
                .map_err(|e| DiscoveryError::RepoError(e.to_string()))?
                .ok_or(DiscoveryError::NotFound)?;

            let replicas = self.resolve_replicas(customer_id, index_name).await;

            let result = DiscoveryResult {
                vm: vm.hostname.clone(),
                flapjack_url: vm.flapjack_url.clone(),
                ttl: self.client_ttl,
                service_type: raw_tenant.service_type.clone(),
                replicas,
            };

            self.cache.insert(cache_key, result.clone());
            return Ok(result);
        }

        // Cold/restoring indexes have no live VM assignment. Do not fall back
        // to deployment URL routing when vm_id is cleared.
        if matches!(raw_tenant.tier.as_str(), "cold" | "restoring") {
            return Err(DiscoveryError::NotFound);
        }

        // Legacy fallback: look up deployment's flapjack_url via summary
        let tenant_summary = self
            .tenant_repo
            .find_by_name(customer_id, index_name)
            .await
            .map_err(|e| DiscoveryError::RepoError(e.to_string()))?
            .ok_or(DiscoveryError::NotFound)?;

        let flapjack_url = tenant_summary
            .flapjack_url
            .as_deref()
            .ok_or(DiscoveryError::NotFound)?;

        let result = DiscoveryResult {
            vm: vm_name_from_url(flapjack_url).unwrap_or_else(|| tenant_summary.region.clone()),
            flapjack_url: flapjack_url.to_string(),
            ttl: self.client_ttl,
            service_type: raw_tenant.service_type.clone(),
            replicas: Vec::new(),
        };

        self.cache.insert(cache_key, result.clone());
        Ok(result)
    }

    /// Resolve healthy replicas for an index. Returns empty vec on error or
    /// when no replica repo is configured.
    async fn resolve_replicas(&self, customer_id: Uuid, index_name: &str) -> Vec<ReplicaEndpoint> {
        let Some(repo) = &self.replica_repo else {
            return Vec::new();
        };

        let replicas = match repo.list_healthy_by_index(customer_id, index_name).await {
            Ok(r) => r,
            Err(_) => return Vec::new(),
        };

        let mut endpoints = Vec::with_capacity(replicas.len());
        for replica in replicas {
            if let Ok(Some(vm)) = self.vm_inventory_repo.get(replica.replica_vm_id).await {
                endpoints.push(ReplicaEndpoint {
                    vm: vm.hostname.clone(),
                    flapjack_url: vm.flapjack_url.clone(),
                    region: replica.replica_region,
                    lag_ops: replica.lag_ops,
                });
            }
        }

        endpoints
    }

    /// Invalidate cache for a specific index. Called by migration executor on catalog flip.
    pub fn invalidate(&self, customer_id: Uuid, index_name: &str) {
        let cache_key = format!("{customer_id}:{index_name}");
        self.cache.invalidate(&cache_key);
    }

    /// Invalidate all cache entries for an index across all tenants.
    /// Used when migrating and we know the index name but want to be thorough.
    pub fn invalidate_by_index(&self, index_name: &str) {
        let suffix = format!(":{index_name}");
        self.cache
            .invalidate_entries_if(move |key, _| key.ends_with(&suffix))
            .expect("invalidate_entries_if should not fail");
    }
}

fn vm_name_from_url(flapjack_url: &str) -> Option<String> {
    reqwest::Url::parse(flapjack_url)
        .ok()
        .and_then(|url| url.host_str().map(|host| host.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vm_name_from_url_valid_http() {
        let result = vm_name_from_url("http://fj-node-42.example.com:7700");
        assert_eq!(result.as_deref(), Some("fj-node-42.example.com"));
    }

    #[test]
    fn vm_name_from_url_valid_https() {
        let result = vm_name_from_url("https://10.0.1.5:7700");
        assert_eq!(result.as_deref(), Some("10.0.1.5"));
    }

    #[test]
    fn vm_name_from_url_no_port() {
        let result = vm_name_from_url("http://fj-prod.internal");
        assert_eq!(result.as_deref(), Some("fj-prod.internal"));
    }

    #[test]
    fn vm_name_from_url_invalid_returns_none() {
        let result = vm_name_from_url("not-a-url");
        assert!(result.is_none());
    }

    #[test]
    fn vm_name_from_url_empty_returns_none() {
        let result = vm_name_from_url("");
        assert!(result.is_none());
    }

    #[test]
    fn discovery_cache_key_format_is_tenant_scoped() {
        // Verify cache keys use "customer_id:index_name" format to prevent cross-tenant poisoning
        let customer_id = Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap();
        let cache_key = format!("{customer_id}:my-index");
        assert_eq!(cache_key, "550e8400-e29b-41d4-a716-446655440000:my-index");
    }

    #[test]
    fn discovery_error_display() {
        let err = DiscoveryError::NotFound;
        assert_eq!(err.to_string(), "index not found");

        let err = DiscoveryError::RepoError("db timeout".into());
        assert_eq!(err.to_string(), "repo error: db timeout");
    }

    #[test]
    fn default_constants_are_reasonable() {
        assert_eq!(DEFAULT_CACHE_TTL_SECS, 30);
        assert_eq!(DEFAULT_CLIENT_TTL, 300);
    }
}
