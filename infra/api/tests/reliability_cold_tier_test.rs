mod common;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use api::repos::{ColdSnapshotRepo, InMemoryColdSnapshotRepo};
use api::services::alerting::{AlertSeverity, MockAlertService};
use api::services::cold_tier::{
    ColdTierCandidate, ColdTierConfig, ColdTierDependencies, ColdTierError, ColdTierService,
};
use api::services::discovery::DiscoveryService;
use api::services::object_store::{InMemoryObjectStore, RegionObjectStoreResolver};
use chrono::{Duration, Utc};
use common::MockNodeClient;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------

struct TestHarness {
    customer_repo: Arc<common::MockCustomerRepo>,
    tenant_repo: Arc<common::MockTenantRepo>,
    vm_inventory_repo: Arc<common::MockVmInventoryRepo>,
    discovery_service: Arc<DiscoveryService>,
    migration_repo: Arc<common::MockIndexMigrationRepo>,
    cold_snapshot_repo: Arc<InMemoryColdSnapshotRepo>,
    failable_store: Arc<common::FailableObjectStore>,
    should_fail: Arc<AtomicBool>,
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

        let should_fail = Arc::new(AtomicBool::new(false));
        let failable_store = Arc::new(common::FailableObjectStore::new(
            Arc::new(InMemoryObjectStore::new()),
            should_fail.clone(),
        ));

        Self {
            customer_repo,
            tenant_repo,
            vm_inventory_repo,
            discovery_service,
            migration_repo: common::mock_index_migration_repo(),
            cold_snapshot_repo: Arc::new(InMemoryColdSnapshotRepo::new()),
            failable_store,
            should_fail,
            alert_service: Arc::new(MockAlertService::new()),
            node_client: Arc::new(MockNodeClient::new()),
            node_secret_manager: common::mock_node_secret_manager(),
        }
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
                    self.failable_store.clone(),
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
}

// ---------------------------------------------------------------------------
// Class 4: S3 auth revocation during cold-tier snapshot
// ---------------------------------------------------------------------------

/// S3 auth revocation during snapshot upload: after max retries, a Critical
/// alert fires. Validates that persistent S3 403 errors are detected and escalated.
#[tokio::test]
async fn s3_auth_revocation_during_snapshot_upload_fires_critical_alert() {
    let h = TestHarness::new();
    let config = ColdTierConfig {
        max_snapshot_retries: 3,
        ..Default::default()
    };
    let svc = h.build_service_with_config(config);

    let (customer_id, vm_id) = h.seed_idle_index("products").await;
    let candidate = ColdTierCandidate {
        customer_id,
        tenant_id: "products".to_string(),
        source_vm_id: vm_id,
        last_accessed_at: Some(Utc::now() - Duration::days(31)),
    };

    // S3 put() will fail with 403.
    h.should_fail.store(true, Ordering::SeqCst);

    // Repeat 3 times (max_snapshot_retries).
    for _ in 0..3 {
        let result = svc
            .snapshot_candidate(&candidate, "http://vm-1.flapjack.foo", "us-east-1")
            .await;
        assert!(result.is_err(), "snapshot should fail with S3 403");

        let err_msg = match &result {
            Err(ColdTierError::Upload(msg)) => msg.clone(),
            Err(e) => format!("{e}"),
            Ok(_) => unreachable!(),
        };

        // Find the orphaned snapshot record so handle_snapshot_failure can mark it failed.
        let active_snap = h
            .cold_snapshot_repo
            .find_active_for_index(customer_id, "products")
            .await
            .unwrap();
        let snap_id = active_snap.map(|s| s.id);

        svc.handle_snapshot_failure(&candidate, snap_id, &err_msg)
            .await;
    }

    // After 3 retries, max_retries should be exceeded.
    assert!(
        svc.is_max_retries_exceeded(customer_id, "products"),
        "retry count should reach max after 3 failures"
    );

    // A Critical alert should have been sent on the final failure.
    let alerts = h.alert_service.recorded_alerts();
    let critical_alerts: Vec<_> = alerts
        .iter()
        .filter(|a| a.severity == AlertSeverity::Critical)
        .collect();
    assert!(
        !critical_alerts.is_empty(),
        "a Critical alert should fire after max retries exceeded"
    );
}

/// S3 recovery after auth fix: after 2 failures (below max), fixing the IAM
/// policy allows the snapshot to complete successfully.
#[tokio::test]
async fn s3_recovery_after_auth_fix_completes_snapshot() {
    let h = TestHarness::new();
    let config = ColdTierConfig {
        max_snapshot_retries: 3,
        ..Default::default()
    };
    let svc = h.build_service_with_config(config);

    let (customer_id, vm_id) = h.seed_idle_index("products").await;
    let candidate = ColdTierCandidate {
        customer_id,
        tenant_id: "products".to_string(),
        source_vm_id: vm_id,
        last_accessed_at: Some(Utc::now() - Duration::days(31)),
    };

    // Start with S3 failing.
    h.should_fail.store(true, Ordering::SeqCst);

    // Fail twice (below max of 3).
    for _ in 0..2 {
        let result = svc
            .snapshot_candidate(&candidate, "http://vm-1.flapjack.foo", "us-east-1")
            .await;
        assert!(result.is_err());
        let err_msg = match &result {
            Err(e) => format!("{e}"),
            Ok(_) => unreachable!(),
        };

        // Find the orphaned snapshot record so handle_snapshot_failure can mark it failed.
        let active_snap = h
            .cold_snapshot_repo
            .find_active_for_index(customer_id, "products")
            .await
            .unwrap();
        let snap_id = active_snap.map(|s| s.id);

        svc.handle_snapshot_failure(&candidate, snap_id, &err_msg)
            .await;
    }

    // Fix the IAM policy — S3 works again.
    h.should_fail.store(false, Ordering::SeqCst);

    // This attempt should succeed.
    let snapshot_id = svc
        .snapshot_candidate(&candidate, "http://vm-1.flapjack.foo", "us-east-1")
        .await
        .expect("snapshot should succeed after S3 recovery");

    // Verify the snapshot ID is a valid UUID (non-nil).
    assert_ne!(snapshot_id, Uuid::nil());

    // Verify the snapshot record is completed in the cold_snapshot_repo.
    let snapshot = h
        .cold_snapshot_repo
        .get(snapshot_id)
        .await
        .unwrap()
        .expect("snapshot record should exist");
    assert_eq!(
        snapshot.status, "completed",
        "snapshot should be completed after S3 recovery"
    );
    assert!(
        snapshot.size_bytes > 0,
        "snapshot should have non-zero size"
    );
}

/// S3 put() failure at step 5 of the snapshot pipeline should be classified as
/// ColdTierError::Upload with the original error message preserved.
#[tokio::test]
async fn s3_upload_failure_returns_cold_tier_error_upload() {
    let h = TestHarness::new();
    let svc = h.build_service_with_config(ColdTierConfig::default());

    let (customer_id, vm_id) = h.seed_idle_index("products").await;
    let candidate = ColdTierCandidate {
        customer_id,
        tenant_id: "products".to_string(),
        source_vm_id: vm_id,
        last_accessed_at: Some(Utc::now() - Duration::days(31)),
    };

    // S3 put() will fail with 403.
    h.should_fail.store(true, Ordering::SeqCst);

    let result = svc
        .snapshot_candidate(&candidate, "http://vm-1.flapjack.foo", "us-east-1")
        .await;

    match result {
        Err(ColdTierError::Upload(msg)) => {
            assert!(
                msg.contains("403 Forbidden"),
                "Upload error should contain '403 Forbidden', got: {msg}"
            );
        }
        Err(other) => panic!("expected ColdTierError::Upload, got: {other:?}"),
        Ok(_) => panic!("expected error, got Ok"),
    }
}
