#![allow(clippy::field_reassign_with_default)]

use std::sync::{Arc, Mutex, OnceLock};

use api::models::vm_inventory::NewVmInventory;
use api::repos::{ColdSnapshotRepo, InMemoryColdSnapshotRepo, TenantRepo, VmInventoryRepo};
use api::services::alerting::{AlertSeverity, MockAlertService};
use api::services::cold_tier::{
    ColdTierCandidate, ColdTierConfig, ColdTierDependencies, ColdTierService,
};
use api::services::discovery::{DiscoveryError, DiscoveryService};
use api::services::flapjack_node::flapjack_index_uid;
use api::services::object_store::{
    InMemoryObjectStore, ObjectStore, RegionObjectStoreResolver, S3ObjectStoreConfig,
};
use chrono::{Duration, Utc};
use common::MockNodeClient;
use uuid::Uuid;

mod common;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

struct TestHarness {
    customer_repo: Arc<common::MockCustomerRepo>,
    tenant_repo: Arc<common::MockTenantRepo>,
    vm_inventory_repo: Arc<common::MockVmInventoryRepo>,
    discovery_service: Arc<DiscoveryService>,
    migration_repo: Arc<common::MockIndexMigrationRepo>,
    cold_snapshot_repo: Arc<InMemoryColdSnapshotRepo>,
    object_store: Arc<InMemoryObjectStore>,
    alert_service: Arc<MockAlertService>,
    node_client: Arc<MockNodeClient>,
    node_secret_manager: Arc<api::secrets::mock::MockNodeSecretManager>,
}

impl TestHarness {
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
            discovery_service,
            migration_repo: common::mock_index_migration_repo(),
            cold_snapshot_repo: Arc::new(InMemoryColdSnapshotRepo::new()),
            object_store: Arc::new(InMemoryObjectStore::new()),
            alert_service: Arc::new(MockAlertService::new()),
            node_client: Arc::new(MockNodeClient::new()),
            node_secret_manager: common::mock_node_secret_manager(),
        }
    }

    // Unit-level service builder — uses InMemoryObjectStore, no real S3 or HTTP.
    // For live S3 round-trip tests, see integration_cold_tier_test.rs.
    fn build_service(&self) -> ColdTierService {
        self.build_service_with_config(ColdTierConfig::default())
    }

    fn build_service_with_config(&self, config: ColdTierConfig) -> ColdTierService {
        ColdTierService::new(
            config,
            ColdTierDependencies {
                tenant_repo: self.tenant_repo.clone(),
                index_migration_repo: self.migration_repo.clone(),
                cold_snapshot_repo: self.cold_snapshot_repo.clone(),
                vm_inventory_repo: self.vm_inventory_repo.clone(),
                object_store_resolver: Arc::new(RegionObjectStoreResolver::single(
                    self.object_store.clone(),
                )),
                alert_service: self.alert_service.clone(),
                discovery_service: self.discovery_service.clone(),
                node_client: self.node_client.clone(),
                node_secret_manager: self.node_secret_manager.clone(),
            },
        )
    }

    async fn seed_idle_index(&self, tenant_id: &str) -> (Uuid, Uuid) {
        common::seed_idle_cold_tier_index(
            &self.customer_repo,
            &self.tenant_repo,
            &self.vm_inventory_repo,
            tenant_id,
        )
        .await
    }

    /// Seed an idle index on a VM with a specific provider and region.
    async fn seed_idle_index_with_provider(
        &self,
        tenant_id: &str,
        provider: &str,
        region: &str,
        flapjack_url: &str,
    ) -> (Uuid, Uuid) {
        let customer = self.customer_repo.seed("Acme", "acme@example.com");
        let deployment_id = Uuid::new_v4();
        let vm = self
            .vm_inventory_repo
            .create(NewVmInventory {
                region: region.to_string(),
                provider: provider.to_string(),
                hostname: format!("vm-{}.flapjack.foo", Uuid::new_v4()),
                flapjack_url: flapjack_url.to_string(),
                capacity: serde_json::json!({
                    "cpu": 100.0,
                    "memory_mb": 4096.0,
                    "disk_gb": 100.0
                }),
            })
            .await
            .expect("create vm");
        let vm_id = vm.id;

        self.tenant_repo.seed_deployment(
            deployment_id,
            region,
            Some(flapjack_url),
            "healthy",
            "running",
        );

        self.tenant_repo
            .create(customer.id, tenant_id, deployment_id)
            .await
            .expect("create tenant");

        self.tenant_repo
            .set_vm_id(customer.id, tenant_id, vm_id)
            .await
            .expect("set vm_id");

        self.tenant_repo
            .set_last_accessed_at(
                customer.id,
                tenant_id,
                Some(Utc::now() - Duration::days(31)),
            )
            .expect("set last_accessed_at");

        (customer.id, vm_id)
    }
}

// ---------------------------------------------------------------------------
// Section 3 — Candidate detection tests (from session 201)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn idle_index_detected_as_cold_candidate() {
    let h = TestHarness::new();
    let (customer_id, vm_id) = h.seed_idle_index("idle-index").await;

    let svc = h.build_service();
    let candidates = svc.detect_candidates().await.expect("candidate detection");

    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0].customer_id, customer_id);
    assert_eq!(candidates[0].tenant_id, "idle-index");
    assert_eq!(candidates[0].source_vm_id, vm_id);
}

#[tokio::test]
async fn recent_index_not_cold_candidate() {
    let h = TestHarness::new();
    let (customer_id, _) = h.seed_idle_index("recent-index").await;

    // Override to recent access
    h.tenant_repo
        .set_last_accessed_at(
            customer_id,
            "recent-index",
            Some(Utc::now() - Duration::days(1)),
        )
        .expect("set last_accessed_at");

    let svc = h.build_service();
    let candidates = svc.detect_candidates().await.expect("candidate detection");
    assert!(candidates.is_empty());
}

#[tokio::test]
async fn pinned_index_excluded() {
    let h = TestHarness::new();
    let (customer_id, _) = h.seed_idle_index("pinned-index").await;

    h.tenant_repo
        .set_tier(customer_id, "pinned-index", "pinned")
        .await
        .expect("set tier");

    let svc = h.build_service();
    let candidates = svc.detect_candidates().await.expect("candidate detection");
    assert!(candidates.is_empty());
}

#[tokio::test]
async fn migrating_index_excluded() {
    let h = TestHarness::new();
    let (customer_id, _) = h.seed_idle_index("migrating-index").await;

    h.tenant_repo
        .set_tier(customer_id, "migrating-index", "migrating")
        .await
        .expect("set tier");

    let svc = h.build_service();
    let candidates = svc.detect_candidates().await.expect("candidate detection");
    assert!(candidates.is_empty());
}

#[tokio::test]
async fn candidate_detection_respects_max_candidates_per_cycle() {
    let h = TestHarness::new();
    let (customer_a, vm_a) = h.seed_idle_index("idle-a").await;
    let (customer_b, vm_b) = h.seed_idle_index("idle-b").await;

    let mut config = ColdTierConfig::default();
    config.max_candidates_per_cycle = 1;
    let svc = h.build_service_with_config(config);

    let candidates = svc.detect_candidates().await.expect("candidate detection");
    assert_eq!(candidates.len(), 1, "candidate list should be capped");

    let candidate = &candidates[0];
    let is_a = candidate.customer_id == customer_a
        && candidate.tenant_id == "idle-a"
        && candidate.source_vm_id == vm_a;
    let is_b = candidate.customer_id == customer_b
        && candidate.tenant_id == "idle-b"
        && candidate.source_vm_id == vm_b;
    assert!(is_a || is_b, "unexpected candidate selected");
}

// ---------------------------------------------------------------------------
// Section 3 — Snapshot pipeline tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn snapshot_pipeline_exports_uploads_evicts() {
    let h = TestHarness::new();
    let (customer_id, vm_id) = h.seed_idle_index("snap-index").await;

    let export_data = b"fake-flapjack-export-tarball-data".to_vec();
    let flapjack_uid = flapjack_index_uid(customer_id, "snap-index");
    h.node_client
        .set_export_response(&flapjack_uid, Ok(export_data.clone()));

    // Prime discovery cache before cold transition.
    h.discovery_service
        .discover(customer_id, "snap-index")
        .await
        .expect("discover before snapshot");
    assert_eq!(h.tenant_repo.find_raw_call_count(), 1);

    let candidate = ColdTierCandidate {
        customer_id,
        tenant_id: "snap-index".to_string(),
        source_vm_id: vm_id,
        last_accessed_at: Some(Utc::now() - Duration::days(31)),
    };

    let svc = h.build_service();
    let snapshot_id = svc
        .snapshot_candidate(&candidate, "http://vm-1.flapjack.foo", "us-east-1")
        .await
        .expect("snapshot should succeed");

    // Verify discovery cache was invalidated and cold indexes are no longer discoverable.
    let post_snapshot_discover = h
        .discovery_service
        .discover(customer_id, "snap-index")
        .await;
    assert!(
        matches!(post_snapshot_discover, Err(DiscoveryError::NotFound)),
        "cold index with no vm_id must not route via legacy deployment fallback"
    );
    assert_eq!(h.tenant_repo.find_raw_call_count(), 2);

    // Verify snapshot record is completed
    let snapshot = h
        .cold_snapshot_repo
        .get(snapshot_id)
        .await
        .expect("get snapshot")
        .expect("snapshot should exist");
    assert_eq!(snapshot.status, "completed");
    assert!(
        snapshot.object_key.starts_with("cold/us-east-1/"),
        "snapshot object key must include region prefix for provider-aware restore routing"
    );
    assert_eq!(snapshot.size_bytes, export_data.len() as i64);
    assert!(snapshot.checksum.is_some());

    // Verify data was uploaded to object store
    let stored = h
        .object_store
        .get(&snapshot.object_key)
        .await
        .expect("object should exist");
    assert_eq!(stored, export_data);

    // Verify tenant catalog updated: tier=cold, cold_snapshot_id set, vm_id cleared
    let tenant = h
        .tenant_repo
        .find_raw(customer_id, "snap-index")
        .await
        .expect("find tenant")
        .expect("tenant should exist");
    assert_eq!(tenant.tier, "cold");
    assert_eq!(tenant.cold_snapshot_id, Some(snapshot_id));
    assert!(
        tenant.vm_id.is_none(),
        "vm_id should be cleared after eviction"
    );

    // Verify flapjack node calls: export then delete
    assert_eq!(h.node_client.export_call_count(), 1);
    assert_eq!(h.node_client.delete_call_count(), 1);

    // Verify Info alert fired
    assert_eq!(h.alert_service.alert_count(), 1);
    let alerts = h.alert_service.recorded_alerts();
    assert_eq!(alerts[0].severity, AlertSeverity::Info);
}

#[tokio::test]
async fn snapshot_failure_retries_next_cycle() {
    let h = TestHarness::new();
    let (customer_id, vm_id) = h.seed_idle_index("retry-index").await;

    // Make export fail
    h.node_client.set_export_response(
        &flapjack_index_uid(customer_id, "retry-index"),
        Err("connection timeout".to_string()),
    );

    let mut config = ColdTierConfig::default();
    config.max_snapshot_retries = 3;
    let svc = h.build_service_with_config(config);

    let candidate = ColdTierCandidate {
        customer_id,
        tenant_id: "retry-index".to_string(),
        source_vm_id: vm_id,
        last_accessed_at: Some(Utc::now() - Duration::days(31)),
    };

    // First attempt — should fail
    let result = svc
        .snapshot_candidate(&candidate, "http://vm-1.flapjack.foo", "us-east-1")
        .await;
    assert!(result.is_err());

    // Handle the failure (increments retry count)
    svc.handle_snapshot_failure(&candidate, None, "connection timeout")
        .await;

    // Verify tier reset to active (so it can be retried)
    let tenant = h
        .tenant_repo
        .find_raw(customer_id, "retry-index")
        .await
        .expect("find tenant")
        .expect("tenant should exist");
    assert_eq!(tenant.tier, "active");

    // Verify warning alert (not critical yet — only 1 retry)
    assert_eq!(h.alert_service.alert_count(), 1);
    let alerts = h.alert_service.recorded_alerts();
    assert_eq!(alerts[0].severity, AlertSeverity::Warning);

    // Verify not at max retries yet
    assert!(!svc.is_max_retries_exceeded(customer_id, "retry-index"));
}

#[tokio::test]
async fn snapshot_terminal_failure_fires_critical_alert() {
    let h = TestHarness::new();
    let (customer_id, vm_id) = h.seed_idle_index("terminal-index").await;

    let mut config = ColdTierConfig::default();
    config.max_snapshot_retries = 2;
    let svc = h.build_service_with_config(config);

    let candidate = ColdTierCandidate {
        customer_id,
        tenant_id: "terminal-index".to_string(),
        source_vm_id: vm_id,
        last_accessed_at: Some(Utc::now() - Duration::days(31)),
    };

    // Exhaust retries: 2 failures = terminal
    svc.handle_snapshot_failure(&candidate, None, "disk full")
        .await;
    svc.handle_snapshot_failure(&candidate, None, "disk full")
        .await;

    // Verify critical alert was fired on the last failure
    let alerts = h.alert_service.recorded_alerts();
    assert!(alerts.len() >= 2); // warning + critical
    let critical_alerts: Vec<_> = alerts
        .iter()
        .filter(|a| a.severity == AlertSeverity::Critical)
        .collect();
    assert_eq!(critical_alerts.len(), 1);
    assert!(critical_alerts[0].title.contains("permanently failed"));

    // Verify max retries are now exceeded
    assert!(svc.is_max_retries_exceeded(customer_id, "terminal-index"));
}

#[tokio::test]
async fn snapshot_delete_failure_rolls_back_catalog_state() {
    let h = TestHarness::new();
    let (customer_id, vm_id) = h.seed_idle_index("delete-fail-index").await;

    h.node_client.set_export_response(
        &flapjack_index_uid(customer_id, "delete-fail-index"),
        Ok(b"snapshot-bytes".to_vec()),
    );
    h.node_client.set_delete_response(
        &flapjack_index_uid(customer_id, "delete-fail-index"),
        Err("delete refused".to_string()),
    );

    let svc = h.build_service();
    svc.run_cycle(&|id| {
        if id == vm_id {
            Some((
                "http://vm-1.flapjack.foo".to_string(),
                "us-east-1".to_string(),
            ))
        } else {
            None
        }
    })
    .await
    .expect("cycle should complete despite candidate failure");

    let tenant = h
        .tenant_repo
        .find_raw(customer_id, "delete-fail-index")
        .await
        .expect("find tenant")
        .expect("tenant should exist");

    assert_eq!(tenant.tier, "active");
    assert_eq!(tenant.vm_id, Some(vm_id));
    assert!(tenant.cold_snapshot_id.is_none());

    let active_snapshot = h
        .cold_snapshot_repo
        .find_active_for_index(customer_id, "delete-fail-index")
        .await
        .expect("query active snapshot");
    assert!(
        active_snapshot.is_none(),
        "failed snapshot should not stay active"
    );

    assert_eq!(h.node_client.export_call_count(), 1);
    assert_eq!(h.node_client.delete_call_count(), 1);

    let alerts = h.alert_service.recorded_alerts();
    assert!(
        alerts.iter().any(|a| a.severity == AlertSeverity::Warning),
        "retryable failure should fire warning alert"
    );
}

#[tokio::test]
async fn run_cycle_respects_max_concurrent_snapshots_limit() {
    let h = TestHarness::new();
    let (customer_a, _vm_a) = h.seed_idle_index("limit-a").await;
    let (customer_b, _vm_b) = h.seed_idle_index("limit-b").await;
    let (customer_c, _vm_c) = h.seed_idle_index("limit-c").await;

    let mut config = ColdTierConfig::default();
    config.max_concurrent_snapshots = 1;
    config.max_candidates_per_cycle = 5;
    let svc = h.build_service_with_config(config);

    svc.run_cycle(&|_| {
        Some((
            "http://vm-1.flapjack.foo".to_string(),
            "us-east-1".to_string(),
        ))
    })
    .await
    .expect("cycle should complete");

    assert_eq!(
        h.node_client.export_call_count(),
        1,
        "cycle must only execute one snapshot when max_concurrent_snapshots=1"
    );
    assert_eq!(h.node_client.delete_call_count(), 1);

    let tenant_a = h
        .tenant_repo
        .find_raw(customer_a, "limit-a")
        .await
        .expect("find tenant a")
        .expect("tenant a should exist");
    let tenant_b = h
        .tenant_repo
        .find_raw(customer_b, "limit-b")
        .await
        .expect("find tenant b")
        .expect("tenant b should exist");
    let tenant_c = h
        .tenant_repo
        .find_raw(customer_c, "limit-c")
        .await
        .expect("find tenant c")
        .expect("tenant c should exist");

    let cold_count = [tenant_a.tier, tenant_b.tier, tenant_c.tier]
        .into_iter()
        .filter(|tier| tier == "cold")
        .count();
    assert_eq!(cold_count, 1, "only one tenant should be moved to cold");
}

#[tokio::test]
async fn snapshot_timeout_rolls_back_catalog_state_and_warns() {
    let h = TestHarness::new();
    let (customer_id, vm_id) = h.seed_idle_index("timeout-index").await;

    h.node_client
        .set_export_delay_ms(&flapjack_index_uid(customer_id, "timeout-index"), 1_500);

    let mut config = ColdTierConfig::default();
    config.snapshot_timeout_secs = 1;
    let svc = h.build_service_with_config(config);

    svc.run_cycle(&|id| {
        if id == vm_id {
            Some((
                "http://vm-1.flapjack.foo".to_string(),
                "us-east-1".to_string(),
            ))
        } else {
            None
        }
    })
    .await
    .expect("cycle should continue on timeout failure");

    assert_eq!(h.node_client.export_call_count(), 1);
    assert_eq!(
        h.node_client.delete_call_count(),
        0,
        "timed out snapshot should never reach eviction"
    );

    let tenant = h
        .tenant_repo
        .find_raw(customer_id, "timeout-index")
        .await
        .expect("find tenant")
        .expect("tenant should exist");
    assert_eq!(tenant.tier, "active");
    assert_eq!(tenant.vm_id, Some(vm_id));
    assert!(tenant.cold_snapshot_id.is_none());

    let active_snapshot = h
        .cold_snapshot_repo
        .find_active_for_index(customer_id, "timeout-index")
        .await
        .expect("query active snapshot");
    assert!(active_snapshot.is_none());

    let alerts = h.alert_service.recorded_alerts();
    assert!(
        alerts.iter().any(|a| a.severity == AlertSeverity::Warning),
        "timeout should be treated as retryable failure"
    );
}

// ---------------------------------------------------------------------------
// Stage 9 §6 — Cold storage cross-region support
// ---------------------------------------------------------------------------

fn cold_tier_env_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

struct EnvVarGuard {
    key: &'static str,
    previous: Option<String>,
}

impl EnvVarGuard {
    fn set(key: &'static str, value: &str) -> Self {
        let previous = std::env::var(key).ok();
        std::env::set_var(key, value);
        Self { key, previous }
    }
}

impl Drop for EnvVarGuard {
    fn drop(&mut self) {
        match &self.previous {
            Some(value) => std::env::set_var(self.key, value),
            None => std::env::remove_var(self.key),
        }
    }
}

/// §6 test: S3ObjectStore configured with a Hetzner Object Storage endpoint
/// produces the correct config (bucket, prefix, region, endpoint with
/// force_path_style). This covers the cross-region cold storage foundation.
#[test]
fn cold_storage_with_custom_endpoint() {
    let _lock = cold_tier_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _bucket = EnvVarGuard::set("COLD_STORAGE_BUCKET", "fjcloud-cold-eu");
    let _prefix = EnvVarGuard::set("COLD_STORAGE_PREFIX", "cold");
    let _region = EnvVarGuard::set("COLD_STORAGE_REGION", "eu-central-1");
    let _endpoint = EnvVarGuard::set(
        "COLD_STORAGE_ENDPOINT",
        "https://fsn1.your-objectstorage.com",
    );
    let _access_key = EnvVarGuard::set("COLD_STORAGE_ACCESS_KEY", "cold-access");
    let _secret_key = EnvVarGuard::set("COLD_STORAGE_SECRET_KEY", "cold-secret");

    let config = S3ObjectStoreConfig::from_env();
    assert_eq!(config.bucket, "fjcloud-cold-eu");
    assert_eq!(config.prefix, "cold");
    assert_eq!(config.region, "eu-central-1");
    assert_eq!(
        config.endpoint.as_deref(),
        Some("https://fsn1.your-objectstorage.com"),
        "Hetzner Object Storage endpoint must be set for cross-region cold storage"
    );
    assert_eq!(config.access_key.as_deref(), Some("cold-access"));
    assert_eq!(config.secret_key.as_deref(), Some("cold-secret"));
}

/// §6 test: The cold tier snapshot pipeline succeeds identically for a Hetzner VM.
/// The cold tier manager uses the flapjack HTTP API (provider-agnostic) for
/// export/delete and the ObjectStore trait for upload. The VM's provider field
/// ("hetzner") must not interfere with any step.
#[tokio::test]
async fn cold_snapshot_from_hetzner_vm_succeeds() {
    let h = TestHarness::new();
    let hetzner_url = "http://hetzner-fsn1-vm.flapjack.foo:7700";
    let (customer_id, vm_id) = h
        .seed_idle_index_with_provider("hetzner-index", "hetzner", "eu-central-1", hetzner_url)
        .await;

    let export_data = b"hetzner-flapjack-export-tarball".to_vec();
    let flapjack_uid = flapjack_index_uid(customer_id, "hetzner-index");
    h.node_client
        .set_export_response(&flapjack_uid, Ok(export_data.clone()));

    let candidate = ColdTierCandidate {
        customer_id,
        tenant_id: "hetzner-index".to_string(),
        source_vm_id: vm_id,
        last_accessed_at: Some(Utc::now() - Duration::days(31)),
    };

    let svc = h.build_service();
    let snapshot_id = svc
        .snapshot_candidate(&candidate, hetzner_url, "eu-central-1")
        .await
        .expect("snapshot from Hetzner VM should succeed");

    // Verify snapshot record
    let snapshot = h
        .cold_snapshot_repo
        .get(snapshot_id)
        .await
        .expect("get snapshot")
        .expect("snapshot should exist");
    assert_eq!(snapshot.status, "completed");
    assert!(
        snapshot.object_key.starts_with("cold/eu-central-1/"),
        "snapshot object key must include region prefix for provider-aware restore routing"
    );
    assert_eq!(snapshot.size_bytes, export_data.len() as i64);
    assert!(snapshot.checksum.is_some());

    // Verify data uploaded to object store
    let stored = h
        .object_store
        .get(&snapshot.object_key)
        .await
        .expect("object should exist in store");
    assert_eq!(stored, export_data);

    // Verify tenant catalog: tier=cold, vm_id cleared, cold_snapshot_id set
    let tenant = h
        .tenant_repo
        .find_raw(customer_id, "hetzner-index")
        .await
        .expect("find tenant")
        .expect("tenant should exist");
    assert_eq!(tenant.tier, "cold");
    assert_eq!(tenant.cold_snapshot_id, Some(snapshot_id));
    assert!(
        tenant.vm_id.is_none(),
        "vm_id should be cleared after Hetzner VM eviction"
    );

    // Verify flapjack node calls used the Hetzner URL
    assert_eq!(h.node_client.export_call_count(), 1);
    assert_eq!(h.node_client.delete_call_count(), 1);
    let export_calls = h.node_client.export_calls();
    assert_eq!(
        export_calls[0].0, hetzner_url,
        "export must target Hetzner VM URL"
    );
    assert_eq!(export_calls[0].1, flapjack_uid);
    assert!(
        !export_calls[0].2.is_empty(),
        "export must include the VM admin API key"
    );
    let delete_calls = h.node_client.delete_calls();
    assert_eq!(
        delete_calls[0].0, hetzner_url,
        "delete must target Hetzner VM URL"
    );
    assert_eq!(delete_calls[0].1, flapjack_uid);
    assert_eq!(
        delete_calls[0].2, export_calls[0].2,
        "delete must use the same VM admin API key as export"
    );

    // Verify success alert
    assert_eq!(h.alert_service.alert_count(), 1);
    let alerts = h.alert_service.recorded_alerts();
    assert_eq!(alerts[0].severity, AlertSeverity::Info);
    assert!(alerts[0].title.contains("cold storage"));
}
