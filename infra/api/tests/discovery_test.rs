mod common;

use api::models::vm_inventory::NewVmInventory;
use api::repos::tenant_repo::TenantRepo;
use api::repos::vm_inventory_repo::VmInventoryRepo;
use api::repos::{InMemoryIndexReplicaRepo, IndexReplicaRepo};
use api::router::build_router;
use api::services::discovery::DiscoveryService;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{
    mock_api_key_repo, mock_deployment_repo, mock_flapjack_proxy, mock_repo, MockTenantRepo,
    MockVmInventoryRepo,
};
use http_body_util::BodyExt;
use sha2::{Digest, Sha256};
use std::sync::Arc;
use tower::ServiceExt;
use uuid::Uuid;

fn hash_key(key: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(key.as_bytes());
    hex::encode(hasher.finalize())
}

/// Create a VM in the default region (us-east-1/aws). `hostname` doubles as
/// the URL host — the flapjack_url is set to `https://{hostname}`.
async fn create_test_vm(
    vm_repo: &MockVmInventoryRepo,
    hostname: &str,
) -> api::models::vm_inventory::VmInventory {
    create_test_vm_in(vm_repo, hostname, "us-east-1", "aws").await
}

async fn create_test_vm_in(
    vm_repo: &MockVmInventoryRepo,
    hostname: &str,
    region: &str,
    provider: &str,
) -> api::models::vm_inventory::VmInventory {
    vm_repo
        .create(NewVmInventory {
            region: region.to_string(),
            provider: provider.to_string(),
            hostname: hostname.to_string(),
            flapjack_url: format!("https://{hostname}"),
            capacity: serde_json::json!({}),
        })
        .await
        .unwrap()
}

const TEST_API_KEY: &str = "fj_live_0123456789abcdef0123456789abcdef";
const TEST_API_KEY_PREFIX: &str = "fj_live_01234567";

fn seed_api_key(customer_id: Uuid) -> Arc<common::MockApiKeyRepo> {
    seed_api_key_with_scopes(customer_id, vec!["read".to_string(), "search".to_string()])
}

fn seed_api_key_with_scopes(customer_id: Uuid, scopes: Vec<String>) -> Arc<common::MockApiKeyRepo> {
    let api_key_repo = mock_api_key_repo();
    api_key_repo.seed(
        customer_id,
        "discovery-key",
        &hash_key(TEST_API_KEY),
        TEST_API_KEY_PREFIX,
        scopes,
    );
    api_key_repo
}

fn setup() -> (Arc<MockTenantRepo>, Arc<MockVmInventoryRepo>, Uuid, Uuid) {
    let tenant_repo = Arc::new(MockTenantRepo::new());
    let vm_repo = Arc::new(MockVmInventoryRepo::new());
    let customer_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();
    tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("https://legacy.flapjack.foo"),
        "healthy",
        "running",
    );
    (tenant_repo, vm_repo, customer_id, deployment_id)
}

fn setup_discovery_app(
    customer_repo: Arc<common::MockCustomerRepo>,
    deployment_repo: Arc<common::MockDeploymentRepo>,
    tenant_repo: Arc<MockTenantRepo>,
    vm_repo: Arc<MockVmInventoryRepo>,
    api_key_repo: Arc<common::MockApiKeyRepo>,
) -> axum::Router {
    let mut state = common::test_state_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_flapjack_proxy(),
        vm_repo,
    );
    state.api_key_repo = api_key_repo;
    build_router(state)
}

async fn response_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test]
async fn discover_returns_correct_vm_for_owned_index() {
    let (tenant_repo, vm_repo, customer_id, deployment_id) = setup();

    // Create a VM and assign it to the tenant
    let vm = create_test_vm(&vm_repo, "vm-disco.flapjack.foo").await;

    tenant_repo
        .create(customer_id, "products", deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "products", vm.id)
        .await
        .unwrap();

    let svc = DiscoveryService::with_ttl(
        tenant_repo.clone() as Arc<dyn TenantRepo + Send + Sync>,
        vm_repo.clone() as Arc<dyn VmInventoryRepo + Send + Sync>,
        60,
    );

    let result = svc.discover(customer_id, "products").await.unwrap();
    assert_eq!(result.vm, "vm-disco.flapjack.foo");
    assert_eq!(result.flapjack_url, "https://vm-disco.flapjack.foo");
    assert_eq!(result.ttl, 300);
}

#[tokio::test]
async fn discover_includes_healthy_replicas_when_configured() {
    let (tenant_repo, vm_repo, customer_id, deployment_id) = setup();

    let primary_vm = create_test_vm(&vm_repo, "vm-primary.flapjack.foo").await;
    let replica_vm = create_test_vm_in(
        &vm_repo,
        "vm-replica.flapjack.foo",
        "eu-central-1",
        "hetzner",
    )
    .await;

    tenant_repo
        .create(customer_id, "products", deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "products", primary_vm.id)
        .await
        .unwrap();

    let replica_repo: Arc<dyn IndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let active_replica = replica_repo
        .create(
            customer_id,
            "products",
            primary_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    replica_repo
        .set_status(active_replica.id, "active")
        .await
        .unwrap();
    replica_repo.set_lag(active_replica.id, 7).await.unwrap();

    let svc = DiscoveryService::with_ttl(
        tenant_repo.clone() as Arc<dyn TenantRepo + Send + Sync>,
        vm_repo.clone() as Arc<dyn VmInventoryRepo + Send + Sync>,
        60,
    )
    .with_replica_repo(replica_repo);

    let result = svc.discover(customer_id, "products").await.unwrap();
    assert_eq!(result.replicas.len(), 1);
    assert_eq!(result.replicas[0].vm, "vm-replica.flapjack.foo");
    assert_eq!(
        result.replicas[0].flapjack_url,
        "https://vm-replica.flapjack.foo"
    );
    assert_eq!(result.replicas[0].region, "eu-central-1");
    assert_eq!(result.replicas[0].lag_ops, 7);
}

#[tokio::test]
async fn discover_excludes_inactive_replicas() {
    let (tenant_repo, vm_repo, customer_id, deployment_id) = setup();

    let primary_vm = create_test_vm(&vm_repo, "vm-primary2.flapjack.foo").await;
    let replica_vm =
        create_test_vm_in(&vm_repo, "vm-inactive.flapjack.foo", "eu-west-1", "hetzner").await;

    tenant_repo
        .create(customer_id, "products2", deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "products2", primary_vm.id)
        .await
        .unwrap();

    let replica_repo: Arc<dyn IndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let inactive_replica = replica_repo
        .create(
            customer_id,
            "products2",
            primary_vm.id,
            replica_vm.id,
            "eu-west-1",
        )
        .await
        .unwrap();
    replica_repo
        .set_status(inactive_replica.id, "inactive")
        .await
        .unwrap();
    replica_repo
        .set_lag(inactive_replica.id, 100)
        .await
        .unwrap();

    let svc = DiscoveryService::with_ttl(
        tenant_repo.clone() as Arc<dyn TenantRepo + Send + Sync>,
        vm_repo.clone() as Arc<dyn VmInventoryRepo + Send + Sync>,
        60,
    )
    .with_replica_repo(replica_repo);

    let result = svc.discover(customer_id, "products2").await.unwrap();
    assert!(
        result.replicas.is_empty(),
        "inactive replicas should be excluded from discovery"
    );
}

#[tokio::test]
async fn discover_includes_service_type_in_result() {
    let (tenant_repo, vm_repo, customer_id, deployment_id) = setup();

    let vm = create_test_vm(&vm_repo, "vm-stype.flapjack.foo").await;

    tenant_repo
        .create(customer_id, "products", deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "products", vm.id)
        .await
        .unwrap();

    let svc = DiscoveryService::with_ttl(
        tenant_repo.clone() as Arc<dyn TenantRepo + Send + Sync>,
        vm_repo.clone() as Arc<dyn VmInventoryRepo + Send + Sync>,
        60,
    );

    let result = svc.discover(customer_id, "products").await.unwrap();
    assert_eq!(result.service_type, "flapjack");
}

#[tokio::test]
async fn discover_legacy_fallback_includes_service_type() {
    let (tenant_repo, vm_repo, customer_id, deployment_id) = setup();

    // Create tenant without vm_id (legacy single-tenant path)
    tenant_repo
        .create(customer_id, "legacy-stype", deployment_id)
        .await
        .unwrap();

    let svc = DiscoveryService::with_ttl(
        tenant_repo.clone() as Arc<dyn TenantRepo + Send + Sync>,
        vm_repo.clone() as Arc<dyn VmInventoryRepo + Send + Sync>,
        60,
    );

    let result = svc.discover(customer_id, "legacy-stype").await.unwrap();
    assert_eq!(result.service_type, "flapjack");
}

#[tokio::test]
async fn discover_endpoint_response_includes_service_type() {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = Arc::new(MockTenantRepo::new());
    let vm_repo = Arc::new(MockVmInventoryRepo::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");
    let api_key_repo = seed_api_key(customer.id);

    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "node-1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://legacy.flapjack.foo"),
    );
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("https://legacy.flapjack.foo"),
        "healthy",
        "running",
    );
    let vm = create_test_vm(&vm_repo, "vm-stype-ep.flapjack.foo").await;
    tenant_repo
        .create(customer.id, "products", deployment.id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer.id, "products", vm.id)
        .await
        .unwrap();

    let app = setup_discovery_app(
        customer_repo,
        deployment_repo,
        tenant_repo,
        vm_repo,
        api_key_repo,
    );

    let response = app
        .oneshot(
            Request::builder()
                .uri("/v1/discover?index=products")
                .header("authorization", format!("Bearer {TEST_API_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = response_json(response).await;
    assert_eq!(body["service_type"], "flapjack");
}

#[tokio::test]
async fn discover_404_for_unknown_index() {
    let (tenant_repo, vm_repo, customer_id, _deployment_id) = setup();

    let svc = DiscoveryService::with_ttl(
        tenant_repo.clone() as Arc<dyn TenantRepo + Send + Sync>,
        vm_repo.clone() as Arc<dyn VmInventoryRepo + Send + Sync>,
        60,
    );

    let result = svc.discover(customer_id, "nonexistent").await;
    assert!(result.is_err());
    assert!(matches!(
        result.unwrap_err(),
        api::services::discovery::DiscoveryError::NotFound
    ));
}

#[tokio::test]
async fn discover_404_for_cross_tenant_access() {
    let (tenant_repo, vm_repo, _customer_id, deployment_id) = setup();

    let owner_id = Uuid::new_v4();
    let attacker_id = Uuid::new_v4();

    tenant_repo
        .create(owner_id, "secret-index", deployment_id)
        .await
        .unwrap();

    let svc = DiscoveryService::with_ttl(
        tenant_repo.clone() as Arc<dyn TenantRepo + Send + Sync>,
        vm_repo.clone() as Arc<dyn VmInventoryRepo + Send + Sync>,
        60,
    );

    // Attacker tries to discover owner's index
    let result = svc.discover(attacker_id, "secret-index").await;
    assert!(result.is_err());
    assert!(matches!(
        result.unwrap_err(),
        api::services::discovery::DiscoveryError::NotFound
    ));
}

#[tokio::test]
async fn discover_returns_source_vm_during_migration() {
    let (tenant_repo, vm_repo, customer_id, deployment_id) = setup();

    let vm = create_test_vm(&vm_repo, "vm-source.flapjack.foo").await;

    tenant_repo
        .create(customer_id, "migrating-idx", deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "migrating-idx", vm.id)
        .await
        .unwrap();
    tenant_repo
        .set_tier(customer_id, "migrating-idx", "migrating")
        .await
        .unwrap();

    let svc = DiscoveryService::with_ttl(
        tenant_repo.clone() as Arc<dyn TenantRepo + Send + Sync>,
        vm_repo.clone() as Arc<dyn VmInventoryRepo + Send + Sync>,
        60,
    );

    // Should still return source VM — NOT 503
    let result = svc.discover(customer_id, "migrating-idx").await.unwrap();
    assert_eq!(result.vm, "vm-source.flapjack.foo");
}

#[tokio::test]
async fn discover_cache_hit_avoids_repeated_lookup() {
    let (tenant_repo, vm_repo, customer_id, deployment_id) = setup();

    let vm = create_test_vm(&vm_repo, "vm-cached.flapjack.foo").await;

    tenant_repo
        .create(customer_id, "cached-idx", deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "cached-idx", vm.id)
        .await
        .unwrap();

    let svc = DiscoveryService::with_ttl(
        tenant_repo.clone() as Arc<dyn TenantRepo + Send + Sync>,
        vm_repo.clone() as Arc<dyn VmInventoryRepo + Send + Sync>,
        60,
    );

    // First call (cache miss)
    let find_raw_before = tenant_repo.find_raw_call_count();
    let vm_get_before = vm_repo.get_call_count();
    let r1 = svc.discover(customer_id, "cached-idx").await.unwrap();
    let find_raw_after_first = tenant_repo.find_raw_call_count();
    let vm_get_after_first = vm_repo.get_call_count();

    assert_eq!(find_raw_after_first, find_raw_before + 1);
    assert_eq!(vm_get_after_first, vm_get_before + 1);

    // Second call (cache hit) — should still return correct result
    let r2 = svc.discover(customer_id, "cached-idx").await.unwrap();
    assert_eq!(r1.vm, r2.vm);
    assert_eq!(r1.flapjack_url, r2.flapjack_url);
    assert_eq!(tenant_repo.find_raw_call_count(), find_raw_after_first);
    assert_eq!(vm_repo.get_call_count(), vm_get_after_first);
}

#[tokio::test]
async fn discover_ttl_expiry_triggers_fresh_fetch() {
    let (tenant_repo, vm_repo, customer_id, deployment_id) = setup();

    let vm = create_test_vm(&vm_repo, "vm-ttl.flapjack.foo").await;

    tenant_repo
        .create(customer_id, "ttl-idx", deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "ttl-idx", vm.id)
        .await
        .unwrap();

    let svc = DiscoveryService::with_ttl(
        tenant_repo.clone() as Arc<dyn TenantRepo + Send + Sync>,
        vm_repo.clone() as Arc<dyn VmInventoryRepo + Send + Sync>,
        1, // 1 second TTL (build_cache uses Duration::from_secs)
    );

    // First call (cache miss)
    let find_raw_before = tenant_repo.find_raw_call_count();
    svc.discover(customer_id, "ttl-idx").await.unwrap();
    assert_eq!(tenant_repo.find_raw_call_count(), find_raw_before + 1);

    // Wait for TTL to expire plus buffer for Moka's async cleanup
    tokio::time::sleep(tokio::time::Duration::from_secs(3)).await;

    // Second call (should be cache miss due to TTL expiry)
    let find_raw_before_second = tenant_repo.find_raw_call_count();
    svc.discover(customer_id, "ttl-idx").await.unwrap();
    assert_eq!(
        tenant_repo.find_raw_call_count(),
        find_raw_before_second + 1,
        "TTL expiry should trigger a fresh repo fetch"
    );
}

/// Verifies that once the first request populates the cache, subsequent
/// requests are served from cache without additional repo lookups.
/// NOTE: on a single-threaded `#[tokio::test]` runtime the spawned tasks
/// execute sequentially (the mock resolves immediately with no yield points),
/// so this validates cache-after-first-populate, not true concurrent coalescing.
/// True coalescing would require `moka::Cache::try_get_with()` or similar.
#[tokio::test]
async fn discover_spawned_requests_share_cache() {
    let (tenant_repo, vm_repo, customer_id, deployment_id) = setup();

    let vm = create_test_vm(&vm_repo, "vm-concurrent.flapjack.foo").await;

    tenant_repo
        .create(customer_id, "concurrent-idx", deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "concurrent-idx", vm.id)
        .await
        .unwrap();

    let svc = Arc::new(DiscoveryService::with_ttl(
        tenant_repo.clone() as Arc<dyn TenantRepo + Send + Sync>,
        vm_repo.clone() as Arc<dyn VmInventoryRepo + Send + Sync>,
        60,
    ));

    let find_raw_before = tenant_repo.find_raw_call_count();

    // Spawn 5 discovery requests for the same index
    let mut handles = Vec::new();
    for _ in 0..5 {
        let svc = svc.clone();
        let handle = tokio::spawn(async move { svc.discover(customer_id, "concurrent-idx").await });
        handles.push(handle);
    }

    // Wait for all to complete
    for handle in handles {
        handle.await.unwrap().unwrap();
    }

    // First request populates cache; remaining 4 hit cache
    assert_eq!(
        tenant_repo.find_raw_call_count(),
        find_raw_before + 1,
        "after first request populates cache, subsequent requests should not re-fetch"
    );
}

#[tokio::test]
async fn discover_cache_invalidation_returns_fresh_result() {
    let (tenant_repo, vm_repo, customer_id, deployment_id) = setup();

    let vm_old = create_test_vm(&vm_repo, "vm-old.flapjack.foo").await;
    let vm_new = create_test_vm(&vm_repo, "vm-new.flapjack.foo").await;

    tenant_repo
        .create(customer_id, "flip-idx", deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "flip-idx", vm_old.id)
        .await
        .unwrap();

    let svc = DiscoveryService::with_ttl(
        tenant_repo.clone() as Arc<dyn TenantRepo + Send + Sync>,
        vm_repo.clone() as Arc<dyn VmInventoryRepo + Send + Sync>,
        60,
    );

    // Populate cache with old VM
    let r1 = svc.discover(customer_id, "flip-idx").await.unwrap();
    assert_eq!(r1.vm, "vm-old.flapjack.foo");

    // Simulate catalog flip (migration executor updates vm_id + invalidates cache)
    tenant_repo
        .set_vm_id(customer_id, "flip-idx", vm_new.id)
        .await
        .unwrap();
    svc.invalidate(customer_id, "flip-idx");

    // After invalidation, should get fresh result from new VM
    let r2 = svc.discover(customer_id, "flip-idx").await.unwrap();
    assert_eq!(r2.vm, "vm-new.flapjack.foo");
}

#[tokio::test]
async fn discover_cache_keys_are_per_tenant() {
    let (tenant_repo, vm_repo, _customer_id, deployment_id) = setup();

    let customer_a = Uuid::new_v4();
    let customer_b = Uuid::new_v4();
    let deployment_b = Uuid::new_v4();
    tenant_repo.seed_deployment(
        deployment_b,
        "us-east-1",
        Some("https://b.flapjack.foo"),
        "healthy",
        "running",
    );

    let vm_a = create_test_vm(&vm_repo, "vm-a.flapjack.foo").await;
    let vm_b = create_test_vm(&vm_repo, "vm-b.flapjack.foo").await;

    // Both customers have an index with the same name but on different VMs
    tenant_repo
        .create(customer_a, "products", deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_a, "products", vm_a.id)
        .await
        .unwrap();

    tenant_repo
        .create(customer_b, "products", deployment_b)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_b, "products", vm_b.id)
        .await
        .unwrap();

    let svc = DiscoveryService::with_ttl(
        tenant_repo.clone() as Arc<dyn TenantRepo + Send + Sync>,
        vm_repo.clone() as Arc<dyn VmInventoryRepo + Send + Sync>,
        60,
    );

    let ra = svc.discover(customer_a, "products").await.unwrap();
    let rb = svc.discover(customer_b, "products").await.unwrap();

    // Customer A's cached result must NOT serve customer B
    assert_eq!(ra.vm, "vm-a.flapjack.foo");
    assert_eq!(rb.vm, "vm-b.flapjack.foo");
    assert_ne!(ra.vm, rb.vm);
}

#[tokio::test]
async fn discover_invalidate_by_index_clears_all_tenants() {
    let (tenant_repo, vm_repo, _customer_id, deployment_id) = setup();

    let customer_a = Uuid::new_v4();
    let customer_b = Uuid::new_v4();
    let deployment_b = Uuid::new_v4();
    tenant_repo.seed_deployment(
        deployment_b,
        "us-east-1",
        Some("https://b.flapjack.foo"),
        "healthy",
        "running",
    );

    let vm_a = create_test_vm(&vm_repo, "vm-inv-a.flapjack.foo").await;
    let vm_b = create_test_vm(&vm_repo, "vm-inv-b.flapjack.foo").await;

    tenant_repo
        .create(customer_a, "shared-name", deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_a, "shared-name", vm_a.id)
        .await
        .unwrap();
    tenant_repo
        .create(customer_b, "shared-name", deployment_b)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_b, "shared-name", vm_b.id)
        .await
        .unwrap();

    let svc = DiscoveryService::with_ttl(
        tenant_repo.clone() as Arc<dyn TenantRepo + Send + Sync>,
        vm_repo.clone() as Arc<dyn VmInventoryRepo + Send + Sync>,
        60,
    );

    // Populate cache for both customers
    svc.discover(customer_a, "shared-name").await.unwrap();
    svc.discover(customer_b, "shared-name").await.unwrap();

    let calls_before = tenant_repo.find_raw_call_count();

    // Invalidate by index name (clears all tenants' cache for this index)
    svc.invalidate_by_index("shared-name");

    // Both should now miss cache (2 new find_raw calls)
    svc.discover(customer_a, "shared-name").await.unwrap();
    svc.discover(customer_b, "shared-name").await.unwrap();

    let calls_after = tenant_repo.find_raw_call_count();
    assert_eq!(
        calls_after - calls_before,
        2,
        "both cache entries should have been invalidated"
    );
}

#[tokio::test]
async fn discover_legacy_fallback_when_no_vm_id() {
    let (tenant_repo, vm_repo, customer_id, deployment_id) = setup();

    // Create tenant without vm_id (legacy single-tenant path)
    tenant_repo
        .create(customer_id, "legacy-idx", deployment_id)
        .await
        .unwrap();

    let svc = DiscoveryService::with_ttl(
        tenant_repo.clone() as Arc<dyn TenantRepo + Send + Sync>,
        vm_repo.clone() as Arc<dyn VmInventoryRepo + Send + Sync>,
        60,
    );

    let result = svc.discover(customer_id, "legacy-idx").await.unwrap();
    assert_eq!(result.vm, "legacy.flapjack.foo");
    assert_eq!(result.flapjack_url, "https://legacy.flapjack.foo");
}

#[tokio::test]
async fn discover_cold_index_returns_not_found() {
    let (tenant_repo, vm_repo, customer_id, deployment_id) = setup();

    tenant_repo
        .create(customer_id, "cold-idx", deployment_id)
        .await
        .unwrap();
    // Simulate cold tier: tier=cold, vm_id cleared
    tenant_repo
        .set_tier(customer_id, "cold-idx", "cold")
        .await
        .unwrap();

    let svc = DiscoveryService::with_ttl(
        tenant_repo.clone() as Arc<dyn TenantRepo + Send + Sync>,
        vm_repo.clone() as Arc<dyn VmInventoryRepo + Send + Sync>,
        60,
    );

    let result = svc.discover(customer_id, "cold-idx").await;
    assert!(
        matches!(
            result,
            Err(api::services::discovery::DiscoveryError::NotFound)
        ),
        "cold index should not be discoverable"
    );
}

#[tokio::test]
async fn discover_restoring_index_returns_not_found() {
    let (tenant_repo, vm_repo, customer_id, deployment_id) = setup();

    tenant_repo
        .create(customer_id, "restoring-idx", deployment_id)
        .await
        .unwrap();
    // Simulate restoring tier: tier=restoring, vm_id cleared
    tenant_repo
        .set_tier(customer_id, "restoring-idx", "restoring")
        .await
        .unwrap();

    let svc = DiscoveryService::with_ttl(
        tenant_repo.clone() as Arc<dyn TenantRepo + Send + Sync>,
        vm_repo.clone() as Arc<dyn VmInventoryRepo + Send + Sync>,
        60,
    );

    let result = svc.discover(customer_id, "restoring-idx").await;
    assert!(
        matches!(
            result,
            Err(api::services::discovery::DiscoveryError::NotFound)
        ),
        "restoring index should not be discoverable"
    );
}

#[tokio::test]
async fn discover_endpoint_returns_correct_vm_for_owned_index() {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = Arc::new(MockTenantRepo::new());
    let vm_repo = Arc::new(MockVmInventoryRepo::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");
    let api_key_repo = seed_api_key(customer.id);

    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "node-1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://legacy.flapjack.foo"),
    );
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("https://legacy.flapjack.foo"),
        "healthy",
        "running",
    );
    let vm = create_test_vm(&vm_repo, "vm-discover.flapjack.foo").await;
    tenant_repo
        .create(customer.id, "products", deployment.id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer.id, "products", vm.id)
        .await
        .unwrap();

    let app = setup_discovery_app(
        customer_repo,
        deployment_repo,
        tenant_repo,
        vm_repo,
        api_key_repo,
    );

    let response = app
        .oneshot(
            Request::builder()
                .uri("/v1/discover?index=products")
                .header("authorization", format!("Bearer {TEST_API_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert!(
        response.headers().get("x-request-id").is_some(),
        "response should include x-request-id"
    );
    let body = response_json(response).await;
    assert_eq!(body["vm"], "vm-discover.flapjack.foo");
    assert_eq!(body["flapjack_url"], "https://vm-discover.flapjack.foo");
    assert_eq!(body["ttl"], 300);
}

#[tokio::test]
async fn discover_endpoint_404_for_unknown_index() {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = Arc::new(MockTenantRepo::new());
    let vm_repo = Arc::new(MockVmInventoryRepo::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");
    let api_key_repo = seed_api_key(customer.id);

    let app = setup_discovery_app(
        customer_repo,
        deployment_repo,
        tenant_repo,
        vm_repo,
        api_key_repo,
    );

    let response = app
        .oneshot(
            Request::builder()
                .uri("/v1/discover?index=missing")
                .header("authorization", format!("Bearer {TEST_API_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn discover_endpoint_404_for_cross_tenant_access() {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = Arc::new(MockTenantRepo::new());
    let vm_repo = Arc::new(MockVmInventoryRepo::new());

    let owner = customer_repo.seed("Owner", "owner@example.com");
    let attacker = customer_repo.seed("Attacker", "attacker@example.com");
    let api_key_repo = seed_api_key(attacker.id);

    let owner_deployment = deployment_repo.seed_provisioned(
        owner.id,
        "node-owner",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://owner.flapjack.foo"),
    );
    tenant_repo.seed_deployment(
        owner_deployment.id,
        "us-east-1",
        Some("https://owner.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(owner.id, "secret-index", owner_deployment.id)
        .await
        .unwrap();

    let app = setup_discovery_app(
        customer_repo,
        deployment_repo,
        tenant_repo,
        vm_repo,
        api_key_repo,
    );

    let response = app
        .oneshot(
            Request::builder()
                .uri("/v1/discover?index=secret-index")
                .header("authorization", format!("Bearer {TEST_API_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn discover_endpoint_returns_source_vm_during_migration() {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = Arc::new(MockTenantRepo::new());
    let vm_repo = Arc::new(MockVmInventoryRepo::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");
    let api_key_repo = seed_api_key(customer.id);

    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "node-1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://legacy.flapjack.foo"),
    );
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("https://legacy.flapjack.foo"),
        "healthy",
        "running",
    );
    let vm = create_test_vm(&vm_repo, "vm-source.flapjack.foo").await;

    tenant_repo
        .create(customer.id, "migrating-idx", deployment.id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer.id, "migrating-idx", vm.id)
        .await
        .unwrap();
    tenant_repo
        .set_tier(customer.id, "migrating-idx", "migrating")
        .await
        .unwrap();

    let app = setup_discovery_app(
        customer_repo,
        deployment_repo,
        tenant_repo,
        vm_repo,
        api_key_repo,
    );

    let response = app
        .oneshot(
            Request::builder()
                .uri("/v1/discover?index=migrating-idx")
                .header("authorization", format!("Bearer {TEST_API_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = response_json(response).await;
    assert_eq!(body["vm"], "vm-source.flapjack.foo");
}

/// Discovery requires the `search` management scope (via `scopes::SEARCH`).
/// A key with only non-search scopes must be rejected with 403.
#[tokio::test]
async fn discover_endpoint_403_without_search_scope() {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = Arc::new(MockTenantRepo::new());
    let vm_repo = Arc::new(MockVmInventoryRepo::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    // Key has indexes:read but NOT search
    let api_key_repo = seed_api_key_with_scopes(customer.id, vec!["indexes:read".to_string()]);

    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "node-1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://legacy.flapjack.foo"),
    );
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("https://legacy.flapjack.foo"),
        "healthy",
        "running",
    );
    let vm = create_test_vm(&vm_repo, "vm-noscope.flapjack.foo").await;
    tenant_repo
        .create(customer.id, "products", deployment.id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer.id, "products", vm.id)
        .await
        .unwrap();

    let app = setup_discovery_app(
        customer_repo,
        deployment_repo,
        tenant_repo,
        vm_repo,
        api_key_repo,
    );

    let response = app
        .oneshot(
            Request::builder()
                .uri("/v1/discover?index=products")
                .header("authorization", format!("Bearer {TEST_API_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(
        response.status(),
        StatusCode::FORBIDDEN,
        "discovery must reject keys without the search scope"
    );
}

#[tokio::test]
async fn discover_endpoint_401_without_auth() {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = Arc::new(MockTenantRepo::new());
    let vm_repo = Arc::new(MockVmInventoryRepo::new());
    let api_key_repo = mock_api_key_repo();

    let app = setup_discovery_app(
        customer_repo,
        deployment_repo,
        tenant_repo,
        vm_repo,
        api_key_repo,
    );

    // No authorization header at all
    let response = app
        .oneshot(
            Request::builder()
                .uri("/v1/discover?index=anything")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(
        response.status(),
        StatusCode::UNAUTHORIZED,
        "discovery endpoint must reject unauthenticated requests"
    );
}
