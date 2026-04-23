use std::collections::HashMap;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};

use api::models::cold_snapshot::NewColdSnapshot;
use api::models::vm_inventory::NewVmInventory;
use api::repos::{
    ColdSnapshotRepo, InMemoryColdSnapshotRepo, InMemoryRestoreJobRepo, RestoreJobRepo, TenantRepo,
    VmInventoryRepo,
};
use api::services::alerting::MockAlertService;
use api::services::cold_tier::{ColdTierError, FlapjackNodeClient};
use api::services::discovery::DiscoveryService;
use api::services::flapjack_node::flapjack_index_uid;
use api::services::object_store::{InMemoryObjectStore, ObjectStore, RegionObjectStoreResolver};
use api::services::restore::{RestoreConfig, RestoreError, RestoreService};
use async_trait::async_trait;
use uuid::Uuid;

mod common;

// ---------------------------------------------------------------------------
// Mock node client for restore tests
// ---------------------------------------------------------------------------

struct MockRestoreNodeClient {
    import_calls: Mutex<Vec<(String, String, String)>>,
    verify_calls: Mutex<Vec<(String, String, String)>>,
    import_fail: Mutex<bool>,
    import_delay_ms: Mutex<u64>,
}

impl MockRestoreNodeClient {
    fn new() -> Self {
        Self {
            import_calls: Mutex::new(Vec::new()),
            verify_calls: Mutex::new(Vec::new()),
            import_fail: Mutex::new(false),
            import_delay_ms: Mutex::new(0),
        }
    }

    fn set_import_fail(&self, fail: bool) {
        *self.import_fail.lock().unwrap() = fail;
    }

    fn set_import_delay(&self, delay_ms: u64) {
        *self.import_delay_ms.lock().unwrap() = delay_ms;
    }

    fn import_call_count(&self) -> usize {
        self.import_calls.lock().unwrap().len()
    }

    fn import_calls(&self) -> Vec<(String, String, String)> {
        self.import_calls.lock().unwrap().clone()
    }
}

#[async_trait]
impl FlapjackNodeClient for MockRestoreNodeClient {
    async fn export_index(
        &self,
        _flapjack_url: &str,
        _index_name: &str,
        _api_key: &str,
    ) -> Result<Vec<u8>, ColdTierError> {
        Ok(b"unused".to_vec())
    }

    async fn delete_index(
        &self,
        _flapjack_url: &str,
        _index_name: &str,
        _api_key: &str,
    ) -> Result<(), ColdTierError> {
        Ok(())
    }

    async fn import_index(
        &self,
        flapjack_url: &str,
        index_name: &str,
        _data: &[u8],
        api_key: &str,
    ) -> Result<(), ColdTierError> {
        let delay_ms = *self.import_delay_ms.lock().unwrap();
        if delay_ms > 0 {
            tokio::time::sleep(tokio::time::Duration::from_millis(delay_ms)).await;
        }
        self.import_calls.lock().unwrap().push((
            flapjack_url.to_string(),
            index_name.to_string(),
            api_key.to_string(),
        ));
        if *self.import_fail.lock().unwrap() {
            return Err(ColdTierError::Import("import failed".to_string()));
        }
        Ok(())
    }

    async fn verify_index(
        &self,
        flapjack_url: &str,
        index_name: &str,
        api_key: &str,
    ) -> Result<(), ColdTierError> {
        self.verify_calls.lock().unwrap().push((
            flapjack_url.to_string(),
            index_name.to_string(),
            api_key.to_string(),
        ));
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------

struct RestoreHarness {
    customer_repo: Arc<common::MockCustomerRepo>,
    tenant_repo: Arc<common::MockTenantRepo>,
    vm_inventory_repo: Arc<common::MockVmInventoryRepo>,
    cold_snapshot_repo: Arc<InMemoryColdSnapshotRepo>,
    restore_job_repo: Arc<InMemoryRestoreJobRepo>,
    object_store: Arc<InMemoryObjectStore>,
    alert_service: Arc<MockAlertService>,
    discovery_service: Arc<DiscoveryService>,
    node_client: Arc<MockRestoreNodeClient>,
    node_secret_manager: Arc<api::secrets::mock::MockNodeSecretManager>,
}

impl RestoreHarness {
    fn new() -> Self {
        let customer_repo = common::mock_repo();
        let tenant_repo = common::mock_tenant_repo();
        let vm_inventory_repo = common::mock_vm_inventory_repo();
        let discovery_service = Arc::new(DiscoveryService::with_ttl(
            tenant_repo.clone(),
            vm_inventory_repo.clone(),
            3600,
        ));

        Self {
            customer_repo,
            tenant_repo,
            vm_inventory_repo,
            cold_snapshot_repo: Arc::new(InMemoryColdSnapshotRepo::new()),
            restore_job_repo: Arc::new(InMemoryRestoreJobRepo::new()),
            object_store: Arc::new(InMemoryObjectStore::new()),
            alert_service: Arc::new(MockAlertService::new()),
            discovery_service,
            node_client: Arc::new(MockRestoreNodeClient::new()),
            node_secret_manager: common::mock_node_secret_manager(),
        }
    }

    fn build_service(&self) -> RestoreService {
        self.build_service_with_config(RestoreConfig::default())
    }

    fn build_service_with_deps(
        &self,
        config: RestoreConfig,
        object_store: Arc<dyn ObjectStore + Send + Sync>,
    ) -> RestoreService {
        RestoreService::new(
            config,
            self.tenant_repo.clone(),
            self.cold_snapshot_repo.clone(),
            self.restore_job_repo.clone(),
            self.vm_inventory_repo.clone(),
            Arc::new(RegionObjectStoreResolver::single(object_store)),
            self.alert_service.clone(),
            self.discovery_service.clone(),
            self.node_client.clone(),
            self.node_secret_manager.clone(),
        )
    }

    fn build_service_with_object_store(
        &self,
        object_store: Arc<dyn ObjectStore + Send + Sync>,
    ) -> RestoreService {
        self.build_service_with_deps(RestoreConfig::default(), object_store)
    }

    fn build_service_with_config(&self, config: RestoreConfig) -> RestoreService {
        self.build_service_with_deps(config, self.object_store.clone())
    }

    async fn create_fresh_vm(
        &self,
        region: &str,
        provider: &str,
        hostname: &str,
        flapjack_url: &str,
    ) -> api::models::vm_inventory::VmInventory {
        let vm = self
            .vm_inventory_repo
            .create(NewVmInventory {
                region: region.to_string(),
                provider: provider.to_string(),
                hostname: hostname.to_string(),
                flapjack_url: flapjack_url.to_string(),
                capacity: serde_json::json!({
                    "cpu_weight": 100.0,
                    "mem_rss_bytes": 4_294_967_296_u64,
                    "disk_bytes": 107_374_182_400_u64,
                    "query_rps": 10_000.0,
                    "indexing_rps": 10_000.0
                }),
            })
            .await
            .expect("create vm");

        // Restore placement now requires fresh scheduler load data.
        self.vm_inventory_repo
            .update_load(
                vm.id,
                serde_json::json!({
                    "cpu_weight": 0.0,
                    "mem_rss_bytes": 0_u64,
                    "disk_bytes": 0_u64,
                    "query_rps": 0.0,
                    "indexing_rps": 0.0
                }),
            )
            .await
            .expect("mark vm as freshly scraped");

        vm
    }

    /// Create a customer, VM, tenant, cold snapshot, and store snapshot data.
    /// Returns (customer_id, vm_id, snapshot_id).
    async fn seed_cold_index(&self, tenant_id: &str) -> (Uuid, Uuid, Uuid) {
        let customer = self.customer_repo.seed("ColdCo", "cold@example.com");
        let deployment_id = Uuid::new_v4();
        let vm = self
            .create_fresh_vm(
                "us-east-1",
                "aws",
                &format!("vm-{}.flapjack.foo", Uuid::new_v4()),
                "http://restore-vm.flapjack.foo",
            )
            .await;

        self.tenant_repo.seed_deployment(
            deployment_id,
            "us-east-1",
            Some("http://restore-vm.flapjack.foo"),
            "healthy",
            "running",
        );

        self.tenant_repo
            .create(customer.id, tenant_id, deployment_id)
            .await
            .expect("create tenant");

        // Create completed cold snapshot
        let snapshot = self
            .cold_snapshot_repo
            .create(NewColdSnapshot {
                customer_id: customer.id,
                tenant_id: tenant_id.to_string(),
                source_vm_id: vm.id,
                object_key: format!("cold/{}/{}/test.fj", customer.id, tenant_id),
            })
            .await
            .expect("create snapshot");

        self.cold_snapshot_repo
            .set_exporting(snapshot.id)
            .await
            .expect("set exporting");
        self.cold_snapshot_repo
            .set_completed(snapshot.id, 1024, "abc123")
            .await
            .expect("set completed");

        // Store snapshot data in object store
        self.object_store
            .put(&snapshot.object_key, b"snapshot-data-bytes")
            .await
            .expect("put object");

        // Set tenant to cold tier with snapshot reference
        self.tenant_repo
            .set_tier(customer.id, tenant_id, "cold")
            .await
            .expect("set tier cold");
        self.tenant_repo
            .set_cold_snapshot_id(customer.id, tenant_id, Some(snapshot.id))
            .await
            .expect("set cold_snapshot_id");
        self.tenant_repo
            .clear_vm_id(customer.id, tenant_id)
            .await
            .expect("clear vm_id");

        (customer.id, vm.id, snapshot.id)
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn restore_cold_index_returns_job_id() {
    let h = RestoreHarness::new();
    let (customer_id, _vm_id, _snapshot_id) = h.seed_cold_index("cold-idx").await;

    let svc = h.build_service();
    let result = svc.initiate_restore(customer_id, "cold-idx").await;
    assert!(result.is_ok(), "restore should succeed: {:?}", result.err());

    let response = result.unwrap();
    assert_eq!(response.status, "queued");
    assert!(!response.job_id.is_nil());
}

#[tokio::test]
async fn restore_idempotent_for_same_index() {
    let h = RestoreHarness::new();
    let (customer_id, _vm_id, _snapshot_id) = h.seed_cold_index("idem-idx").await;

    let svc = h.build_service();
    let first = svc
        .initiate_restore(customer_id, "idem-idx")
        .await
        .expect("first restore");
    let second = svc
        .initiate_restore(customer_id, "idem-idx")
        .await
        .expect("second restore");

    assert_eq!(first.job_id, second.job_id, "should return same job");
}

#[tokio::test]
async fn restore_non_cold_index_returns_error() {
    let h = RestoreHarness::new();
    let customer = h.customer_repo.seed("ActiveCo", "active@example.com");
    let deployment_id = Uuid::new_v4();
    h.tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://vm.flapjack.foo"),
        "healthy",
        "running",
    );
    h.tenant_repo
        .create(customer.id, "active-idx", deployment_id)
        .await
        .expect("create tenant");

    let svc = h.build_service();
    let result = svc.initiate_restore(customer.id, "active-idx").await;
    assert!(matches!(result, Err(RestoreError::NotCold)));
}

#[tokio::test]
async fn restore_at_capacity_returns_at_limit() {
    let h = RestoreHarness::new();
    let (customer_id, _vm_id, _snapshot_id) = h.seed_cold_index("cap-idx-1").await;

    // Create a second cold index
    let snapshot2 = h
        .cold_snapshot_repo
        .create(NewColdSnapshot {
            customer_id,
            tenant_id: "cap-idx-2".to_string(),
            source_vm_id: Uuid::new_v4(),
            object_key: "cold/cap2.fj".to_string(),
        })
        .await
        .expect("create snapshot 2");
    h.cold_snapshot_repo
        .set_exporting(snapshot2.id)
        .await
        .unwrap();
    h.cold_snapshot_repo
        .set_completed(snapshot2.id, 512, "def456")
        .await
        .unwrap();

    // Set max_concurrent_restores = 1 — first restore fills the slot
    let config = RestoreConfig {
        max_concurrent_restores: 1,
        ..Default::default()
    };
    let svc = h.build_service_with_config(config);

    // First restore succeeds (fills the slot)
    let _first = svc
        .initiate_restore(customer_id, "cap-idx-1")
        .await
        .expect("first restore");

    // Second should fail with AtLimit
    // Need a second cold tenant for this
    let deployment_id = Uuid::new_v4();
    h.tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://vm2.flapjack.foo"),
        "healthy",
        "running",
    );
    h.tenant_repo
        .create(customer_id, "cap-idx-2", deployment_id)
        .await
        .expect("create tenant 2");
    h.tenant_repo
        .set_tier(customer_id, "cap-idx-2", "cold")
        .await
        .unwrap();
    h.tenant_repo
        .set_cold_snapshot_id(customer_id, "cap-idx-2", Some(snapshot2.id))
        .await
        .unwrap();

    let result = svc.initiate_restore(customer_id, "cap-idx-2").await;
    assert!(matches!(result, Err(RestoreError::AtLimit)));
}

#[tokio::test]
async fn restore_pipeline_downloads_imports_activates() {
    let h = RestoreHarness::new();
    let (customer_id, _vm_id, _snapshot_id) = h.seed_cold_index("pipe-idx").await;

    let svc = h.build_service();
    let response = svc
        .initiate_restore(customer_id, "pipe-idx")
        .await
        .expect("initiate");

    // Execute the restore (the service spawns this, but we call it directly in tests)
    svc.execute_restore(response.job_id).await;

    // Verify job completed
    let job = h
        .restore_job_repo
        .get(response.job_id)
        .await
        .expect("get job")
        .expect("job exists");
    assert_eq!(job.status, "completed");
    assert!(job.completed_at.is_some());

    // Verify tenant catalog updated: tier=active, vm_id set, cold_snapshot_id cleared
    let tenant = h
        .tenant_repo
        .find_raw(customer_id, "pipe-idx")
        .await
        .expect("find tenant")
        .expect("tenant exists");
    assert_eq!(tenant.tier, "active");
    assert!(tenant.vm_id.is_some());
    assert!(tenant.cold_snapshot_id.is_none());

    // Verify import was called
    assert_eq!(h.node_client.import_call_count(), 1);
    let import_calls = h.node_client.import_calls();
    assert_eq!(
        import_calls[0].1,
        flapjack_index_uid(customer_id, "pipe-idx"),
        "restore import must target the tenant-scoped Flapjack index UID"
    );
    assert!(
        !import_calls[0].2.is_empty(),
        "restore import must include the destination VM admin API key"
    );
}

#[tokio::test]
async fn restore_legacy_compact_object_key_falls_back_to_source_vm_region() {
    let h = RestoreHarness::new();
    let customer = h.customer_repo.seed("LegacyCo", "legacy@example.com");
    let deployment_id = Uuid::new_v4();
    let source_vm = h
        .create_fresh_vm(
            "eu-central-1",
            "hetzner",
            &format!("vm-{}.flapjack.foo", Uuid::new_v4()),
            "http://legacy-source.flapjack.foo",
        )
        .await;

    h.tenant_repo.seed_deployment(
        deployment_id,
        "eu-central-1",
        Some("http://legacy-source.flapjack.foo"),
        "healthy",
        "running",
    );
    h.tenant_repo
        .create(customer.id, "legacy-idx", deployment_id)
        .await
        .expect("create tenant");

    let object_key = "cold/legacy.fj".to_string();
    let snapshot = h
        .cold_snapshot_repo
        .create(NewColdSnapshot {
            customer_id: customer.id,
            tenant_id: "legacy-idx".to_string(),
            source_vm_id: source_vm.id,
            object_key: object_key.clone(),
        })
        .await
        .expect("create snapshot");
    h.cold_snapshot_repo
        .set_exporting(snapshot.id)
        .await
        .expect("set exporting");
    h.cold_snapshot_repo
        .set_completed(snapshot.id, 1024, "abc123")
        .await
        .expect("set completed");

    h.tenant_repo
        .set_tier(customer.id, "legacy-idx", "cold")
        .await
        .expect("set tier cold");
    h.tenant_repo
        .set_cold_snapshot_id(customer.id, "legacy-idx", Some(snapshot.id))
        .await
        .expect("set cold snapshot");
    h.tenant_repo
        .clear_vm_id(customer.id, "legacy-idx")
        .await
        .expect("clear vm id");

    let default_store = Arc::new(InMemoryObjectStore::new());
    let eu_store = Arc::new(InMemoryObjectStore::new());
    eu_store
        .put(&object_key, b"snapshot-data-bytes")
        .await
        .expect("seed eu object store");

    let mut region_stores: HashMap<String, Arc<dyn ObjectStore + Send + Sync>> = HashMap::new();
    region_stores.insert(
        "eu-central-1".to_string(),
        eu_store as Arc<dyn ObjectStore + Send + Sync>,
    );
    let resolver = Arc::new(RegionObjectStoreResolver::new(
        default_store as Arc<dyn ObjectStore + Send + Sync>,
        region_stores,
    ));

    let svc = RestoreService::new(
        RestoreConfig::default(),
        h.tenant_repo.clone(),
        h.cold_snapshot_repo.clone(),
        h.restore_job_repo.clone(),
        h.vm_inventory_repo.clone(),
        resolver,
        h.alert_service.clone(),
        h.discovery_service.clone(),
        h.node_client.clone(),
        h.node_secret_manager.clone(),
    );

    let response = svc
        .initiate_restore(customer.id, "legacy-idx")
        .await
        .expect("initiate restore");
    svc.execute_restore(response.job_id).await;

    let job = h
        .restore_job_repo
        .get(response.job_id)
        .await
        .expect("get job")
        .expect("job exists");
    assert_eq!(job.status, "completed");

    let tenant = h
        .tenant_repo
        .find_raw(customer.id, "legacy-idx")
        .await
        .expect("find tenant")
        .expect("tenant exists");
    assert_eq!(tenant.tier, "active");
    assert_eq!(tenant.vm_id, Some(source_vm.id));
    assert!(tenant.cold_snapshot_id.is_none());
    assert_eq!(h.node_client.import_call_count(), 1);
}

#[tokio::test]
async fn restore_uses_region_from_snapshot_object_key_when_source_vm_missing() {
    let h = RestoreHarness::new();
    let customer = h.customer_repo.seed("RegionCo", "region@example.com");
    let deployment_id = Uuid::new_v4();
    let dest_vm = h
        .create_fresh_vm(
            "us-east-1",
            "aws",
            &format!("vm-{}.flapjack.foo", Uuid::new_v4()),
            "http://restore-dest.flapjack.foo",
        )
        .await;

    h.tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://restore-dest.flapjack.foo"),
        "healthy",
        "running",
    );
    h.tenant_repo
        .create(customer.id, "region-idx", deployment_id)
        .await
        .expect("create tenant");

    // Simulate source VM metadata no longer existing in vm_inventory.
    let missing_source_vm_id = Uuid::new_v4();
    let object_key = format!("cold/eu-central-1/{}/{}/test.fj", customer.id, "region-idx");
    let snapshot = h
        .cold_snapshot_repo
        .create(NewColdSnapshot {
            customer_id: customer.id,
            tenant_id: "region-idx".to_string(),
            source_vm_id: missing_source_vm_id,
            object_key: object_key.clone(),
        })
        .await
        .expect("create snapshot");
    h.cold_snapshot_repo
        .set_exporting(snapshot.id)
        .await
        .expect("set exporting");
    h.cold_snapshot_repo
        .set_completed(snapshot.id, 1024, "abc123")
        .await
        .expect("set completed");

    h.tenant_repo
        .set_tier(customer.id, "region-idx", "cold")
        .await
        .expect("set tier cold");
    h.tenant_repo
        .set_cold_snapshot_id(customer.id, "region-idx", Some(snapshot.id))
        .await
        .expect("set cold snapshot");
    h.tenant_repo
        .clear_vm_id(customer.id, "region-idx")
        .await
        .expect("clear vm id");

    let default_store = Arc::new(InMemoryObjectStore::new());
    let eu_store = Arc::new(InMemoryObjectStore::new());
    eu_store
        .put(&object_key, b"snapshot-data-bytes")
        .await
        .expect("seed eu object store");

    let mut region_stores: HashMap<String, Arc<dyn ObjectStore + Send + Sync>> = HashMap::new();
    region_stores.insert(
        "eu-central-1".to_string(),
        eu_store as Arc<dyn ObjectStore + Send + Sync>,
    );
    let resolver = Arc::new(RegionObjectStoreResolver::new(
        default_store as Arc<dyn ObjectStore + Send + Sync>,
        region_stores,
    ));

    let svc = RestoreService::new(
        RestoreConfig::default(),
        h.tenant_repo.clone(),
        h.cold_snapshot_repo.clone(),
        h.restore_job_repo.clone(),
        h.vm_inventory_repo.clone(),
        resolver,
        h.alert_service.clone(),
        h.discovery_service.clone(),
        h.node_client.clone(),
        h.node_secret_manager.clone(),
    );

    let response = svc
        .initiate_restore(customer.id, "region-idx")
        .await
        .expect("initiate restore");
    svc.execute_restore(response.job_id).await;

    let job = h
        .restore_job_repo
        .get(response.job_id)
        .await
        .expect("get job")
        .expect("job exists");
    assert_eq!(job.status, "completed");

    let tenant = h
        .tenant_repo
        .find_raw(customer.id, "region-idx")
        .await
        .expect("find tenant")
        .expect("tenant exists");
    assert_eq!(tenant.tier, "active");
    assert_eq!(tenant.vm_id, Some(dest_vm.id));
    assert!(tenant.cold_snapshot_id.is_none());
    assert_eq!(h.node_client.import_call_count(), 1);
}

#[tokio::test]
async fn restore_malformed_region_key_falls_back_to_source_vm_region() {
    let h = RestoreHarness::new();
    let customer = h.customer_repo.seed("MalformedCo", "malformed@example.com");
    let deployment_id = Uuid::new_v4();
    let source_vm = h
        .create_fresh_vm(
            "us-east-1",
            "aws",
            &format!("vm-{}.flapjack.foo", Uuid::new_v4()),
            "http://source.flapjack.foo",
        )
        .await;

    h.tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://source.flapjack.foo"),
        "healthy",
        "running",
    );
    h.tenant_repo
        .create(customer.id, "malformed-idx", deployment_id)
        .await
        .expect("create tenant");

    let object_key = format!(
        "cold/eu-central-1/{}/{}/snapshot.fj/extra",
        customer.id, "malformed-idx"
    );
    let snapshot = h
        .cold_snapshot_repo
        .create(NewColdSnapshot {
            customer_id: customer.id,
            tenant_id: "malformed-idx".to_string(),
            source_vm_id: source_vm.id,
            object_key: object_key.clone(),
        })
        .await
        .expect("create snapshot");
    h.cold_snapshot_repo
        .set_exporting(snapshot.id)
        .await
        .expect("set exporting");
    h.cold_snapshot_repo
        .set_completed(snapshot.id, 1024, "abc123")
        .await
        .expect("set completed");

    h.tenant_repo
        .set_tier(customer.id, "malformed-idx", "cold")
        .await
        .expect("set tier cold");
    h.tenant_repo
        .set_cold_snapshot_id(customer.id, "malformed-idx", Some(snapshot.id))
        .await
        .expect("set cold snapshot");
    h.tenant_repo
        .clear_vm_id(customer.id, "malformed-idx")
        .await
        .expect("clear vm id");

    let default_store = Arc::new(InMemoryObjectStore::new());
    default_store
        .put(&object_key, b"snapshot-data-bytes")
        .await
        .expect("seed default store");
    let eu_store = Arc::new(InMemoryObjectStore::new());

    let mut region_stores: HashMap<String, Arc<dyn ObjectStore + Send + Sync>> = HashMap::new();
    region_stores.insert(
        "eu-central-1".to_string(),
        eu_store as Arc<dyn ObjectStore + Send + Sync>,
    );
    let resolver = Arc::new(RegionObjectStoreResolver::new(
        default_store as Arc<dyn ObjectStore + Send + Sync>,
        region_stores,
    ));

    let svc = RestoreService::new(
        RestoreConfig::default(),
        h.tenant_repo.clone(),
        h.cold_snapshot_repo.clone(),
        h.restore_job_repo.clone(),
        h.vm_inventory_repo.clone(),
        resolver,
        h.alert_service.clone(),
        h.discovery_service.clone(),
        h.node_client.clone(),
        h.node_secret_manager.clone(),
    );

    let response = svc
        .initiate_restore(customer.id, "malformed-idx")
        .await
        .expect("initiate restore");
    svc.execute_restore(response.job_id).await;

    let job = h
        .restore_job_repo
        .get(response.job_id)
        .await
        .expect("get job")
        .expect("job exists");
    assert_eq!(
        job.status, "completed",
        "malformed region-prefixed keys should not override source-vm region routing"
    );
}

#[tokio::test]
async fn restore_failure_resets_tier_to_cold() {
    let h = RestoreHarness::new();
    let (customer_id, _vm_id, _snapshot_id) = h.seed_cold_index("fail-idx").await;

    // Make import fail
    h.node_client.set_import_fail(true);

    let svc = h.build_service();
    let response = svc
        .initiate_restore(customer_id, "fail-idx")
        .await
        .expect("initiate");

    // Execute the restore — should handle failure gracefully
    svc.execute_restore(response.job_id).await;

    // Verify job failed
    let job = h
        .restore_job_repo
        .get(response.job_id)
        .await
        .expect("get job")
        .expect("job exists");
    assert_eq!(job.status, "failed");
    assert!(job.error.is_some());

    // Verify tenant still in cold tier (not stuck in restoring)
    let tenant = h
        .tenant_repo
        .find_raw(customer_id, "fail-idx")
        .await
        .expect("find tenant")
        .expect("tenant exists");
    assert_eq!(tenant.tier, "cold");

    // Verify warning alert fired
    let alerts = h.alert_service.recorded_alerts();
    assert!(
        alerts
            .iter()
            .any(|a| a.severity == api::services::alerting::AlertSeverity::Warning),
        "restore failure should fire warning alert"
    );
}

#[tokio::test]
async fn restore_download_failure_resets_tier_to_cold() {
    let h = RestoreHarness::new();
    let (customer_id, _vm_id, snapshot_id) = h.seed_cold_index("download-fail-idx").await;

    let snapshot = h
        .cold_snapshot_repo
        .get(snapshot_id)
        .await
        .expect("get snapshot")
        .expect("snapshot exists");
    let object_key = snapshot.object_key.clone();

    let should_fail = Arc::new(AtomicBool::new(false));
    let failing_store = Arc::new(common::FailableObjectStore::new(
        h.object_store.clone(),
        Arc::clone(&should_fail),
    ));
    // Ensure snapshot data exists before toggling failures.
    failing_store
        .inner()
        .put(&object_key, b"snapshot-data-bytes")
        .await
        .expect("seed snapshot data");
    should_fail.store(true, std::sync::atomic::Ordering::SeqCst);

    let svc =
        h.build_service_with_object_store(failing_store as Arc<dyn ObjectStore + Send + Sync>);
    let response = svc
        .initiate_restore(customer_id, "download-fail-idx")
        .await
        .expect("initiate");

    svc.execute_restore(response.job_id).await;

    let job = h
        .restore_job_repo
        .get(response.job_id)
        .await
        .expect("get job")
        .expect("job exists");
    assert_eq!(job.status, "failed");
    let err = job.error.clone().unwrap_or_default();
    assert!(
        err.contains("download failed"),
        "restore failure should mention download failure, got: {err}"
    );

    let tenant = h
        .tenant_repo
        .find_raw(customer_id, "download-fail-idx")
        .await
        .expect("find tenant")
        .expect("tenant exists");
    assert_eq!(tenant.tier, "cold");

    let alerts = h.alert_service.recorded_alerts();
    assert!(
        alerts
            .iter()
            .any(|a| a.severity == api::services::alerting::AlertSeverity::Warning),
        "download failure should fire warning alert"
    );
}

#[tokio::test]
async fn restore_download_failure_does_not_corrupt_snapshot() {
    let h = RestoreHarness::new();
    let (customer_id, _vm_id, snapshot_id) = h.seed_cold_index("download-integrity-idx").await;

    let before = h
        .cold_snapshot_repo
        .get(snapshot_id)
        .await
        .expect("get snapshot before")
        .expect("snapshot exists");

    let should_fail = Arc::new(AtomicBool::new(true));
    let failing_store = Arc::new(common::FailableObjectStore::new(
        h.object_store.clone(),
        Arc::clone(&should_fail),
    ));
    let svc =
        h.build_service_with_object_store(failing_store as Arc<dyn ObjectStore + Send + Sync>);
    let response = svc
        .initiate_restore(customer_id, "download-integrity-idx")
        .await
        .expect("initiate");
    svc.execute_restore(response.job_id).await;

    let after = h
        .cold_snapshot_repo
        .get(snapshot_id)
        .await
        .expect("get snapshot after")
        .expect("snapshot exists");
    assert_eq!(after.status, "completed");
    assert_eq!(after.object_key, before.object_key);
    assert_eq!(after.checksum, before.checksum);
}

#[tokio::test]
async fn get_restore_status_returns_active_job() {
    let h = RestoreHarness::new();
    let (customer_id, _vm_id, _snapshot_id) = h.seed_cold_index("status-idx").await;

    let svc = h.build_service();
    let response = svc
        .initiate_restore(customer_id, "status-idx")
        .await
        .expect("initiate");

    let status = svc
        .get_restore_status(customer_id, "status-idx")
        .await
        .expect("get restore status");

    let restore_status = status.expect("active restore job should exist");
    assert_eq!(restore_status.job.id, response.job_id);
    assert_eq!(restore_status.job.status, "queued");
    assert!(
        restore_status.estimated_completion_at.is_some(),
        "restore status should include estimated completion"
    );
}

#[tokio::test]
async fn get_restore_status_returns_completed_job_after_completion() {
    let h = RestoreHarness::new();
    let (customer_id, _vm_id, _snapshot_id) = h.seed_cold_index("status-done-idx").await;

    let svc = h.build_service();
    let response = svc
        .initiate_restore(customer_id, "status-done-idx")
        .await
        .expect("initiate");
    svc.execute_restore(response.job_id).await;

    let status = svc
        .get_restore_status(customer_id, "status-done-idx")
        .await
        .expect("get restore status");
    let restore_status = status.expect("completed restore job should remain pollable");
    assert_eq!(restore_status.job.id, response.job_id);
    assert_eq!(restore_status.job.status, "completed");
    assert!(restore_status.job.completed_at.is_some());
}

#[tokio::test]
async fn restore_timeout_marks_job_failed() {
    let h = RestoreHarness::new();
    let (customer_id, _vm_id, _snapshot_id) = h.seed_cold_index("timeout-idx").await;

    // Configure an immediate timeout (0 seconds)
    let config = RestoreConfig {
        max_concurrent_restores: 3,
        restore_timeout_secs: 0,
    };
    let svc = h.build_service_with_config(config);

    // Make the mock slow (500ms delay)
    h.node_client.set_import_delay(500);

    let response = svc
        .initiate_restore(customer_id, "timeout-idx")
        .await
        .expect("initiate");

    // Execute restore - should timeout
    svc.execute_restore(response.job_id).await;

    // Verify job is marked as failed with timeout message
    let job = h
        .restore_job_repo
        .get(response.job_id)
        .await
        .unwrap()
        .expect("job should exist");
    assert_eq!(job.status, "failed", "job should be marked as failed");
    assert!(job.error.is_some(), "job should have an error message");
    let error_msg = job.error.unwrap();
    assert!(
        error_msg.contains("timed out"),
        "error should indicate timeout, got: {}",
        error_msg
    );

    // Verify tenant tier was reset to cold
    let tenant = h
        .tenant_repo
        .find_raw(customer_id, "timeout-idx")
        .await
        .unwrap()
        .expect("tenant should exist");
    assert_eq!(
        tenant.tier, "cold",
        "tier should be reset to cold after timeout"
    );
}
