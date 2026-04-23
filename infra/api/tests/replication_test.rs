#![allow(clippy::await_holding_lock)]

mod common;

use std::collections::{HashSet, VecDeque};
use std::sync::{Arc, Mutex, OnceLock};

use api::models::vm_inventory::VmInventory;
use api::repos::vm_inventory_repo::VmInventoryRepo;
use api::repos::{InMemoryIndexReplicaRepo, IndexReplicaRepo};
use api::secrets::mock::MockNodeSecretManager;
use api::secrets::NodeSecretManager;
use api::services::migration::{
    MigrationHttpClient, MigrationHttpClientError, MigrationHttpRequest, MigrationHttpResponse,
};
use api::services::replication::{
    classify_replication_result, classify_response, ReplicationConfig, ReplicationError,
    ReplicationOrchestrator,
};
use api::services::replication_error::{
    AUTH_FAILED_CODE, INTERNAL_APP_ID_HEADER, INTERNAL_AUTH_HEADER, PEER_REJECTED_CODE,
    REPLICATION_APP_ID, TIMEOUT_CODE, TRANSPORT_ERROR_CODE,
};
use async_trait::async_trait;
use chrono::{Duration, Utc};
use common::{oplog_metric, vm_seed, MockReplicationHttpClient};
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Global tracing subscriber that captures warn-level events.  Installed once
/// via `set_global_default` so that callsite interest is correctly cached as
/// "always" for all `warn!()` call sites.  Events are written to a shared
/// buffer protected by `tracing_test_lock()`.
struct GlobalEventCapture {
    events: Mutex<Vec<String>>,
}

static GLOBAL_CAPTURE: OnceLock<GlobalEventCapture> = OnceLock::new();

fn install_global_capture() -> &'static GlobalEventCapture {
    GLOBAL_CAPTURE.get_or_init(|| {
        let capture = GlobalEventCapture {
            events: Mutex::new(Vec::new()),
        };
        // install_global_capture is idempotent — set_global_default fails
        // silently if already set (we use the OnceLock to guard).
        let _ = tracing::subscriber::set_global_default(GlobalCaptureSubscriber);
        capture
    })
}

/// The actual `Subscriber` impl, forwarding events to `GLOBAL_CAPTURE`.
struct GlobalCaptureSubscriber;

impl tracing::Subscriber for GlobalCaptureSubscriber {
    fn register_callsite(
        &self,
        _meta: &'static tracing::Metadata<'static>,
    ) -> tracing::subscriber::Interest {
        tracing::subscriber::Interest::always()
    }
    fn enabled(&self, meta: &tracing::Metadata<'_>) -> bool {
        meta.level() <= &tracing::Level::WARN
    }
    fn new_span(&self, _: &tracing::span::Attributes<'_>) -> tracing::span::Id {
        tracing::span::Id::from_u64(1)
    }
    fn record(&self, _: &tracing::span::Id, _: &tracing::span::Record<'_>) {}
    fn record_follows_from(&self, _: &tracing::span::Id, _: &tracing::span::Id) {}
    fn event(&self, event: &tracing::Event<'_>) {
        struct Visitor(String);
        impl tracing::field::Visit for Visitor {
            fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
                use std::fmt::Write;
                let _ = write!(self.0, "{}={:?} ", field.name(), value);
            }
        }
        let mut v = Visitor(String::new());
        event.record(&mut v);
        if let Some(capture) = GLOBAL_CAPTURE.get() {
            capture.events.lock().unwrap().push(v.0);
        }
    }
    fn enter(&self, _: &tracing::span::Id) {}
    fn exit(&self, _: &tracing::span::Id) {}
}

struct KeyAwareMockReplicationHttpClient {
    requests: Mutex<Vec<MigrationHttpRequest>>,
    responses: Mutex<VecDeque<Result<MigrationHttpResponse, MigrationHttpClientError>>>,
    valid_keys: Mutex<HashSet<String>>,
}

impl KeyAwareMockReplicationHttpClient {
    fn new(valid_keys: Vec<String>) -> Self {
        Self {
            requests: Mutex::new(Vec::new()),
            responses: Mutex::new(VecDeque::new()),
            valid_keys: Mutex::new(valid_keys.into_iter().collect()),
        }
    }

    fn enqueue(&self, response: Result<MigrationHttpResponse, MigrationHttpClientError>) {
        self.responses.lock().unwrap().push_back(response);
    }

    fn recorded_requests(&self) -> Vec<MigrationHttpRequest> {
        self.requests.lock().unwrap().clone()
    }

    fn allow_key(&self, key: String) {
        self.valid_keys.lock().unwrap().insert(key);
    }

    fn revoke_key(&self, key: &str) {
        self.valid_keys.lock().unwrap().remove(key);
    }
}

#[async_trait]
impl MigrationHttpClient for KeyAwareMockReplicationHttpClient {
    async fn send(
        &self,
        request: MigrationHttpRequest,
    ) -> Result<MigrationHttpResponse, MigrationHttpClientError> {
        if let Some(key) = request.headers.get(INTERNAL_AUTH_HEADER) {
            let valid_keys = self.valid_keys.lock().unwrap();
            assert!(
                valid_keys.contains(key),
                "flapjack mock should accept this key"
            );
        }

        self.requests.lock().unwrap().push(request);
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("test must enqueue HTTP responses")
    }
}

fn tracing_test_lock() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|err| err.into_inner())
}

async fn seed_internal_key_for_vm(mgr: &MockNodeSecretManager, vm: &VmInventory) -> String {
    mgr.create_node_api_key(&vm.id.to_string(), &vm.region)
        .await
        .unwrap()
}

struct RotationFixture {
    vm_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
    replica_repo: Arc<InMemoryIndexReplicaRepo>,
    replica_id: Uuid,
    replica_vm: VmInventory,
    mock_secret_mgr: Arc<MockNodeSecretManager>,
    source_key: String,
    old_replica_key: String,
}

async fn setup_rotation_fixture(primary_hostname: &str, replica_hostname: &str) -> RotationFixture {
    let vm_repo = common::mock_vm_inventory_repo();
    let customer_id = Uuid::new_v4();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", primary_hostname))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", replica_hostname))
        .await
        .unwrap();

    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
        .create(
            customer_id,
            "products",
            primary_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();

    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());
    let source_key = seed_internal_key_for_vm(mock_secret_mgr.as_ref(), &primary_vm).await;
    let old_replica_key = seed_internal_key_for_vm(mock_secret_mgr.as_ref(), &replica_vm).await;

    RotationFixture {
        vm_repo,
        replica_repo,
        replica_id: replica.id,
        replica_vm,
        mock_secret_mgr,
        source_key,
        old_replica_key,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Provisioning replicas should be picked up by run_cycle and transition to syncing
/// after the orchestrator issues POST /internal/replicate on the replica VM.
#[tokio::test]
async fn replication_orchestrator_starts_syncing_provisioned_replica() {
    let vm_repo = common::mock_vm_inventory_repo();
    let customer_id = Uuid::new_v4();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary"))
        .await
        .unwrap();

    let replica_vm = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-replica"))
        .await
        .unwrap();

    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
        .create(
            customer_id,
            "products",
            primary_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    assert_eq!(replica.status, "provisioning");

    let http_client = Arc::new(MockReplicationHttpClient::new());
    // Expect: POST /internal/replicate on replica VM → 200
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));

    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());
    let _seeded_key = mock_secret_mgr
        .create_node_api_key(&replica_vm.id.to_string(), &replica_vm.region)
        .await
        .unwrap();

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr,
        ReplicationConfig::default(),
    );

    orchestrator.run_cycle().await;

    // Replica should transition to "syncing"
    let updated = replica_repo.get(replica.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "syncing");

    // Verify the HTTP call was POST /internal/replicate on replica VM
    let requests = http_client.recorded_requests();
    assert_eq!(requests.len(), 1);
    assert!(requests[0]
        .url
        .contains("vm-replica:7700/internal/replicate"));
    let body = requests[0].json_body.as_ref().unwrap();
    assert_eq!(body["index_name"], "products");
    assert_eq!(body["source_flapjack_url"], "http://vm-primary:7700");
}

/// Syncing replicas with low oplog lag should transition to active.
#[tokio::test]
async fn replication_orchestrator_activates_synced_replica() {
    let vm_repo = common::mock_vm_inventory_repo();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-replica"))
        .await
        .unwrap();

    let customer_id = Uuid::new_v4();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
        .create(
            customer_id,
            "products",
            primary_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    // Set to syncing (as if orchestrator already started replication)
    replica_repo
        .set_status(replica.id, "syncing")
        .await
        .unwrap();

    let http_client = Arc::new(MockReplicationHttpClient::new());
    // Source oplog seq check
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 1000),
    }));
    // Replica oplog seq check (close to source)
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 998),
    }));

    let config = ReplicationConfig {
        near_zero_lag_ops: 10,
        ..Default::default()
    };
    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());
    let _source_key = seed_internal_key_for_vm(mock_secret_mgr.as_ref(), &primary_vm).await;
    let _replica_key = seed_internal_key_for_vm(mock_secret_mgr.as_ref(), &replica_vm).await;

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr,
        config,
    );

    orchestrator.run_cycle().await;

    let updated = replica_repo.get(replica.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "active");
    assert_eq!(updated.lag_ops, 2); // 1000 - 998
    let requests = http_client.recorded_requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(requests[0].url, "http://vm-primary:7700/metrics");
    assert_eq!(requests[1].method, reqwest::Method::GET);
    assert_eq!(requests[1].url, "http://vm-replica:7700/metrics");
}

/// Active replicas should have their lag_ops updated during run_cycle.
#[tokio::test]
async fn replication_orchestrator_updates_lag_for_active_replicas() {
    let vm_repo = common::mock_vm_inventory_repo();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-replica"))
        .await
        .unwrap();

    let customer_id = Uuid::new_v4();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
        .create(
            customer_id,
            "products",
            primary_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    replica_repo.set_status(replica.id, "active").await.unwrap();

    let http_client = Arc::new(MockReplicationHttpClient::new());
    // Source oplog seq
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 5000),
    }));
    // Replica oplog seq
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 4950),
    }));
    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());
    let _source_key = seed_internal_key_for_vm(mock_secret_mgr.as_ref(), &primary_vm).await;
    let _replica_key = seed_internal_key_for_vm(mock_secret_mgr.as_ref(), &replica_vm).await;

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr,
        ReplicationConfig::default(),
    );

    orchestrator.run_cycle().await;

    let updated = replica_repo.get(replica.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "active"); // still active
    assert_eq!(updated.lag_ops, 50); // 5000 - 4950
}

/// When the replica VM's metrics endpoint is unreachable, the replica should
/// transition to failed.
#[tokio::test]
async fn replication_orchestrator_marks_unreachable_replica_failed() {
    let vm_repo = common::mock_vm_inventory_repo();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-replica"))
        .await
        .unwrap();

    let customer_id = Uuid::new_v4();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
        .create(
            customer_id,
            "products",
            primary_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    replica_repo.set_status(replica.id, "active").await.unwrap();

    let http_client = Arc::new(MockReplicationHttpClient::new());
    // Source oplog seq succeeds
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 5000),
    }));
    // Replica metrics endpoint unreachable
    http_client.enqueue(Err(MigrationHttpClientError::Unreachable(
        "connection refused".to_string(),
    )));
    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());
    let _source_key = seed_internal_key_for_vm(mock_secret_mgr.as_ref(), &primary_vm).await;
    let _replica_key = seed_internal_key_for_vm(mock_secret_mgr.as_ref(), &replica_vm).await;

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr,
        ReplicationConfig::default(),
    );

    orchestrator.run_cycle().await;

    let updated = replica_repo.get(replica.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "failed");
}

/// Active replicas whose oplog lag exceeds max_acceptable_lag_ops should
/// transition to failed.
#[tokio::test]
async fn replication_orchestrator_marks_excessive_lag_replica_failed() {
    let vm_repo = common::mock_vm_inventory_repo();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-replica"))
        .await
        .unwrap();

    let customer_id = Uuid::new_v4();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
        .create(
            customer_id,
            "products",
            primary_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    replica_repo.set_status(replica.id, "active").await.unwrap();

    let http_client = Arc::new(MockReplicationHttpClient::new());
    // Source oplog seq
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 200_000),
    }));
    // Replica oplog seq — far behind source
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 50_000),
    }));

    let config = ReplicationConfig {
        max_acceptable_lag_ops: 100_000,
        ..Default::default()
    };
    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());
    let _source_key = seed_internal_key_for_vm(mock_secret_mgr.as_ref(), &primary_vm).await;
    let _replica_key = seed_internal_key_for_vm(mock_secret_mgr.as_ref(), &replica_vm).await;

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr,
        config,
    );

    orchestrator.run_cycle().await;

    let updated = replica_repo.get(replica.id).await.unwrap().unwrap();
    // Lag of 150,000 exceeds max_acceptable_lag_ops of 100,000 → failed
    assert_eq!(updated.status, "failed");
}

/// A syncing replica whose lag is still converging (above near_zero but below
/// max_acceptable) should remain in syncing state — not prematurely promoted or failed.
#[tokio::test]
async fn replication_orchestrator_syncing_replica_stays_syncing_during_convergence() {
    let vm_repo = common::mock_vm_inventory_repo();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-replica"))
        .await
        .unwrap();

    let customer_id = Uuid::new_v4();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
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
        .set_status(replica.id, "syncing")
        .await
        .unwrap();

    let http_client = Arc::new(MockReplicationHttpClient::new());
    // Source oplog seq
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 10_000),
    }));
    // Replica oplog seq — converging but not yet near-zero
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 5_000),
    }));

    let config = ReplicationConfig {
        near_zero_lag_ops: 100,
        max_acceptable_lag_ops: 100_000,
        ..Default::default()
    };
    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());
    let _source_key = seed_internal_key_for_vm(mock_secret_mgr.as_ref(), &primary_vm).await;
    let _replica_key = seed_internal_key_for_vm(mock_secret_mgr.as_ref(), &replica_vm).await;

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr,
        config,
    );

    orchestrator.run_cycle().await;

    let updated = replica_repo.get(replica.id).await.unwrap().unwrap();
    // Lag of 5,000 is above near_zero (100) but below max (100,000) — stays syncing
    assert_eq!(updated.status, "syncing");
    assert_eq!(updated.lag_ops, 5_000);
}

/// Backward-compatibility: legacy "replicating" status should continue being
/// monitored and promoted to active when lag reaches near-zero.
#[tokio::test]
async fn replication_orchestrator_promotes_legacy_replicating_status_to_active() {
    let vm_repo = common::mock_vm_inventory_repo();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-replica"))
        .await
        .unwrap();

    let customer_id = Uuid::new_v4();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
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
        .set_status(replica.id, "replicating")
        .await
        .unwrap();

    let http_client = Arc::new(MockReplicationHttpClient::new());
    // Source oplog seq
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 1000),
    }));
    // Replica oplog seq — close enough to activate
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 998),
    }));

    let config = ReplicationConfig {
        near_zero_lag_ops: 10,
        ..Default::default()
    };
    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());
    let _source_key = seed_internal_key_for_vm(mock_secret_mgr.as_ref(), &primary_vm).await;
    let _replica_key = seed_internal_key_for_vm(mock_secret_mgr.as_ref(), &replica_vm).await;

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr,
        config,
    );

    orchestrator.run_cycle().await;

    let updated = replica_repo.get(replica.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "active");
    assert_eq!(updated.lag_ops, 2);
}

/// Syncing replicas that have been stuck longer than syncing_timeout_secs should
/// be marked failed — prevents replicas from staying in syncing state forever.
#[tokio::test]
async fn replication_orchestrator_times_out_stale_syncing_replica() {
    let vm_repo = common::mock_vm_inventory_repo();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-replica"))
        .await
        .unwrap();

    let customer_id = Uuid::new_v4();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
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
        .set_status(replica.id, "syncing")
        .await
        .unwrap();

    // Backdate updated_at to 2 hours ago — exceeds the 1-hour timeout
    replica_repo.set_updated_at(replica.id, Utc::now() - Duration::hours(2));

    // No HTTP responses needed — the orchestrator should timeout before checking lag
    let http_client = Arc::new(MockReplicationHttpClient::new());

    let config = ReplicationConfig {
        syncing_timeout_secs: 3600, // 1 hour
        ..Default::default()
    };

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        Arc::new(MockNodeSecretManager::new()),
        config,
    );

    orchestrator.run_cycle().await;

    let updated = replica_repo.get(replica.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "failed");
    // No HTTP requests should have been made — timeout is checked before lag monitoring
    assert_eq!(http_client.recorded_requests().len(), 0);
}

/// Syncing replicas should still time out after sustained lag even when lag is
/// refreshed every cycle; lag updates must not reset syncing timeout age.
#[tokio::test]
async fn replication_orchestrator_times_out_syncing_replica_despite_lag_updates() {
    let vm_repo = common::mock_vm_inventory_repo();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-replica"))
        .await
        .unwrap();

    let customer_id = Uuid::new_v4();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
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
        .set_status(replica.id, "syncing")
        .await
        .unwrap();

    let http_client = Arc::new(MockReplicationHttpClient::new());
    // Two cycles of lag polling should run before timeout is exceeded.
    for _ in 0..4 {
        http_client.enqueue(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric("products", 10_000),
        }));
        http_client.enqueue(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric("products", 5_000),
        }));
    }

    let config = ReplicationConfig {
        near_zero_lag_ops: 100,
        max_acceptable_lag_ops: 100_000,
        syncing_timeout_secs: 1,
        ..Default::default()
    };
    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());
    let _source_key = seed_internal_key_for_vm(mock_secret_mgr.as_ref(), &primary_vm).await;
    let _replica_key = seed_internal_key_for_vm(mock_secret_mgr.as_ref(), &replica_vm).await;

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr,
        config,
    );

    orchestrator.run_cycle().await;
    tokio::time::sleep(std::time::Duration::from_millis(1200)).await;
    orchestrator.run_cycle().await;
    tokio::time::sleep(std::time::Duration::from_millis(1200)).await;
    orchestrator.run_cycle().await;

    let updated = replica_repo.get(replica.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "failed");
    // Timeout should trip before a third lag fetch cycle.
    assert_eq!(http_client.recorded_requests().len(), 4);
}

/// Legacy "replicating" replicas that are still converging (lag above near_zero
/// but below max_acceptable) should be canonicalized to "syncing" during
/// normal lag-update cycles, not left as "replicating" forever.
#[tokio::test]
async fn replication_orchestrator_canonicalizes_replicating_to_syncing() {
    let vm_repo = common::mock_vm_inventory_repo();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-replica"))
        .await
        .unwrap();

    let customer_id = Uuid::new_v4();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
        .create(
            customer_id,
            "products",
            primary_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    // Legacy status from before the rename
    replica_repo
        .set_status(replica.id, "replicating")
        .await
        .unwrap();

    let http_client = Arc::new(MockReplicationHttpClient::new());
    // Source oplog seq
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 10_000),
    }));
    // Replica oplog seq — converging but NOT near-zero
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 5_000),
    }));

    let config = ReplicationConfig {
        near_zero_lag_ops: 100,
        max_acceptable_lag_ops: 100_000,
        ..Default::default()
    };
    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());
    let _source_key = seed_internal_key_for_vm(mock_secret_mgr.as_ref(), &primary_vm).await;
    let _replica_key = seed_internal_key_for_vm(mock_secret_mgr.as_ref(), &replica_vm).await;

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr,
        config,
    );

    orchestrator.run_cycle().await;

    let updated = replica_repo.get(replica.id).await.unwrap().unwrap();
    // Should be canonicalized from "replicating" to "syncing", not left as "replicating"
    assert_eq!(updated.status, "syncing");
    assert_eq!(updated.lag_ops, 5_000);
}

/// When POST /internal/replicate returns a non-2xx status, the replica should
/// be marked failed rather than transition to syncing.
#[tokio::test]
async fn replication_orchestrator_marks_provisioning_failed_on_http_error() {
    let vm_repo = common::mock_vm_inventory_repo();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-replica"))
        .await
        .unwrap();

    let customer_id = Uuid::new_v4();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
        .create(
            customer_id,
            "products",
            primary_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    assert_eq!(replica.status, "provisioning");

    let http_client = Arc::new(MockReplicationHttpClient::new());
    // POST /internal/replicate returns 500
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 500,
        body: r#"{"error": "internal server error"}"#.to_string(),
    }));

    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());
    let _seeded_key = mock_secret_mgr
        .create_node_api_key(&replica_vm.id.to_string(), &replica_vm.region)
        .await
        .unwrap();

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr,
        ReplicationConfig::default(),
    );

    orchestrator.run_cycle().await;

    let updated = replica_repo.get(replica.id).await.unwrap().unwrap();
    assert_eq!(
        updated.status, "failed",
        "replica should be marked failed when replication start returns HTTP 500"
    );
}

/// ReplicationConfig::from_reader reads all env vars including cycle_interval and timeout.
#[test]
fn replication_config_from_reader_reads_all_vars() {
    let config = ReplicationConfig::from_reader(|key| match key {
        "REPLICATION_CYCLE_INTERVAL_SECS" => Some("45".to_string()),
        "REPLICATION_NEAR_ZERO_LAG_OPS" => Some("50".to_string()),
        "REPLICATION_MAX_ACCEPTABLE_LAG_OPS" => Some("200000".to_string()),
        "REPLICATION_SYNCING_TIMEOUT_SECS" => Some("7200".to_string()),
        _ => None,
    });

    assert_eq!(config.cycle_interval_secs, 45);
    assert_eq!(config.near_zero_lag_ops, 50);
    assert_eq!(config.max_acceptable_lag_ops, 200_000);
    assert_eq!(config.syncing_timeout_secs, 7200);
}

/// ReplicationConfig defaults should be sensible when no env vars are set.
#[test]
fn replication_config_defaults_are_sensible() {
    let config = ReplicationConfig::from_reader(|_| None);

    assert_eq!(config.cycle_interval_secs, 30);
    assert_eq!(config.near_zero_lag_ops, 100);
    assert_eq!(config.max_acceptable_lag_ops, 100_000);
    assert_eq!(config.syncing_timeout_secs, 3600);
}

/// Invalid zero/negative replication env values should fall back to defaults
/// to avoid tight-loop polling or nonsensical lag thresholds.
#[test]
fn replication_config_invalid_values_fall_back_to_defaults() {
    let config = ReplicationConfig::from_reader(|key| match key {
        "REPLICATION_CYCLE_INTERVAL_SECS" => Some("0".to_string()),
        "REPLICATION_NEAR_ZERO_LAG_OPS" => Some("-1".to_string()),
        "REPLICATION_MAX_ACCEPTABLE_LAG_OPS" => Some("0".to_string()),
        "REPLICATION_SYNCING_TIMEOUT_SECS" => Some("0".to_string()),
        _ => None,
    });

    assert_eq!(config.cycle_interval_secs, 30);
    assert_eq!(config.near_zero_lag_ops, 100);
    assert_eq!(config.max_acceptable_lag_ops, 100_000);
    assert_eq!(config.syncing_timeout_secs, 3600);
}

#[test]
fn classify_401_returns_auth_failed() {
    let engine_auth_error_body =
        r#"{"error_code":"auth_failed","message":"invalid x-internal-key"}"#.to_string();
    let result = classify_replication_result(Ok(MigrationHttpResponse {
        status: 401,
        body: engine_auth_error_body.clone(),
    }));

    match result {
        Err(ReplicationError::AuthFailed(body)) => assert_eq!(body, engine_auth_error_body),
        other => panic!("expected auth failure, got {other:?}"),
    }
}

#[test]
fn classify_403_returns_peer_rejected() {
    let result = classify_replication_result(Ok(MigrationHttpResponse {
        status: 403,
        body: "forbidden".to_string(),
    }));

    assert!(matches!(
        result,
        Err(ReplicationError::PeerRejected { status: 403, .. })
    ));
}

#[test]
fn classify_timeout_returns_timeout() {
    let result = classify_replication_result(Err(MigrationHttpClientError::Timeout));

    assert!(matches!(result, Err(ReplicationError::Timeout)));
}

#[test]
fn classify_unreachable_returns_transport_error() {
    let result = classify_replication_result(Err(MigrationHttpClientError::Unreachable(
        "conn refused".to_string(),
    )));

    assert!(matches!(result, Err(ReplicationError::TransportError(_))));
}

#[test]
fn classify_500_returns_transport_error() {
    let result = classify_replication_result(Ok(MigrationHttpResponse {
        status: 500,
        body: r#"{"error": "internal server error"}"#.to_string(),
    }));

    assert!(matches!(result, Err(ReplicationError::TransportError(_))));
}

#[test]
fn classify_200_returns_ok() {
    let response = MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    };

    let result = classify_replication_result(Ok(response.clone()));

    match result {
        Ok(actual) => assert_eq!(actual, response),
        Err(err) => panic!("expected success response, got {err:?}"),
    }
}

#[test]
fn replication_error_reason_codes_are_stable() {
    let auth = ReplicationError::AuthFailed("auth".into());
    let peer = ReplicationError::PeerRejected {
        status: 403,
        body: "peer".into(),
    };
    let transport = ReplicationError::TransportError("io".into());
    let timeout = ReplicationError::Timeout;

    assert_eq!(auth.reason_code(), AUTH_FAILED_CODE);
    assert_eq!(peer.reason_code(), PEER_REJECTED_CODE);
    assert_eq!(transport.reason_code(), TRANSPORT_ERROR_CODE);
    assert_eq!(timeout.reason_code(), TIMEOUT_CODE);
}

#[test]
fn replication_error_determinism_flags_match_retry_semantics() {
    assert!(ReplicationError::AuthFailed("auth".into()).is_deterministic());
    assert!(!ReplicationError::PeerRejected {
        status: 403,
        body: "peer".into(),
    }
    .is_deterministic());
    assert!(!ReplicationError::TransportError("io".into()).is_deterministic());
    assert!(!ReplicationError::Timeout.is_deterministic());
}

#[test]
fn classify_response_maps_status_codes_to_structured_errors() {
    let auth = classify_response(MigrationHttpResponse {
        status: 401,
        body: "auth".into(),
    });
    let peer = classify_response(MigrationHttpResponse {
        status: 403,
        body: "forbidden".into(),
    });
    let transport = classify_response(MigrationHttpResponse {
        status: 500,
        body: "server".into(),
    });
    let ok = classify_response(MigrationHttpResponse {
        status: 204,
        body: "{}".into(),
    });

    assert!(matches!(auth, Err(ReplicationError::AuthFailed(_))));
    assert!(matches!(
        peer,
        Err(ReplicationError::PeerRejected { status: 403, .. })
    ));
    assert!(matches!(
        transport,
        Err(ReplicationError::TransportError(_))
    ));
    assert!(ok.is_ok());
}

#[test]
fn classify_429_returns_peer_rejected() {
    let result = classify_replication_result(Ok(MigrationHttpResponse {
        status: 429,
        body: "too many requests".to_string(),
    }));

    assert!(matches!(
        result,
        Err(ReplicationError::PeerRejected { status: 429, .. })
    ));
}

#[tokio::test]
async fn orchestrator_sends_internal_key_on_replicate() {
    let vm_repo = common::mock_vm_inventory_repo();
    let customer_id = Uuid::new_v4();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary-auth-replicate"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed(
            "eu-central-1",
            "hetzner",
            "vm-replica-auth-replicate",
        ))
        .await
        .unwrap();

    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let _replica = replica_repo
        .create(
            customer_id,
            "products",
            primary_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();

    let http_client = Arc::new(MockReplicationHttpClient::new());
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));

    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());
    let seeded_key = mock_secret_mgr
        .create_node_api_key(&replica_vm.id.to_string(), &replica_vm.region)
        .await
        .unwrap();

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr,
        ReplicationConfig::default(),
    );

    orchestrator.run_cycle().await;

    let requests = http_client.recorded_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].headers.get(INTERNAL_AUTH_HEADER),
        Some(&seeded_key)
    );
    assert_eq!(
        requests[0]
            .headers
            .get(INTERNAL_APP_ID_HEADER)
            .map(String::as_str),
        Some(REPLICATION_APP_ID)
    );
}

#[tokio::test]
async fn orchestrator_sends_internal_key_on_metrics() {
    let vm_repo = common::mock_vm_inventory_repo();
    let customer_id = Uuid::new_v4();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary-auth-metrics"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed(
            "eu-central-1",
            "hetzner",
            "vm-replica-auth-metrics",
        ))
        .await
        .unwrap();

    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
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
        .set_status(replica.id, "syncing")
        .await
        .unwrap();

    let http_client = Arc::new(MockReplicationHttpClient::new());
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 10_000),
    }));
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 5_000),
    }));

    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());
    let source_key = mock_secret_mgr
        .create_node_api_key(&primary_vm.id.to_string(), &primary_vm.region)
        .await
        .unwrap();
    let replica_key = mock_secret_mgr
        .create_node_api_key(&replica_vm.id.to_string(), &replica_vm.region)
        .await
        .unwrap();

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr,
        ReplicationConfig::default(),
    );

    orchestrator.run_cycle().await;

    let requests = http_client.recorded_requests();
    assert_eq!(requests.len(), 2);
    let source_req = requests
        .iter()
        .find(|req| req.url.contains("vm-primary-auth-metrics:7700/metrics"))
        .unwrap();
    let replica_req = requests
        .iter()
        .find(|req| req.url.contains("vm-replica-auth-metrics:7700/metrics"))
        .unwrap();

    assert_eq!(
        source_req.headers.get(INTERNAL_AUTH_HEADER),
        Some(&source_key)
    );
    assert_eq!(
        source_req
            .headers
            .get(INTERNAL_APP_ID_HEADER)
            .map(String::as_str),
        Some(REPLICATION_APP_ID)
    );
    assert_eq!(
        replica_req.headers.get(INTERNAL_AUTH_HEADER),
        Some(&replica_key)
    );
    assert_eq!(
        replica_req
            .headers
            .get(INTERNAL_APP_ID_HEADER)
            .map(String::as_str),
        Some(REPLICATION_APP_ID)
    );
}

#[tokio::test]
async fn orchestrator_lag_monitoring_refuses_without_source_internal_key() {
    let vm_repo = common::mock_vm_inventory_repo();
    let customer_id = Uuid::new_v4();

    let source_vm = vm_repo
        .create(vm_seed(
            "us-east-1",
            "aws",
            "vm-primary-auth-metrics-missing",
        ))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed(
            "eu-central-1",
            "hetzner",
            "vm-replica-auth-metrics-missing",
        ))
        .await
        .unwrap();

    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
        .create(
            customer_id,
            "products",
            source_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    replica_repo.set_status(replica.id, "active").await.unwrap();

    let http_client = Arc::new(MockReplicationHttpClient::new());
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 1000),
    }));
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 998),
    }));

    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());
    let _replica_key = mock_secret_mgr
        .create_node_api_key(&replica_vm.id.to_string(), &replica_vm.region)
        .await
        .unwrap();

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr,
        ReplicationConfig::default(),
    );

    orchestrator.run_cycle().await;

    let updated = replica_repo.get(replica.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "failed");
    assert_eq!(http_client.recorded_requests().len(), 0);
}

#[tokio::test]
async fn orchestrator_does_not_permanently_fail_on_single_auth_error() {
    let vm_repo = common::mock_vm_inventory_repo();
    let customer_id = Uuid::new_v4();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary-auth-single-401"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed(
            "eu-central-1",
            "hetzner",
            "vm-replica-auth-single-401",
        ))
        .await
        .unwrap();

    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
        .create(
            customer_id,
            "products",
            primary_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();

    let http_client = Arc::new(MockReplicationHttpClient::new());
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 401,
        body: r#"{"error_code":"auth_failed"}"#.to_string(),
    }));

    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());
    let _seeded_key = mock_secret_mgr
        .create_node_api_key(&replica_vm.id.to_string(), &replica_vm.region)
        .await
        .unwrap();

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client,
        mock_secret_mgr,
        ReplicationConfig::default(),
    );

    orchestrator.run_cycle().await;

    let updated = replica_repo.get(replica.id).await.unwrap().unwrap();
    assert_ne!(updated.status, "failed");
}

#[tokio::test]
async fn orchestrator_auth_retries_are_bounded() {
    let vm_repo = common::mock_vm_inventory_repo();
    let customer_id = Uuid::new_v4();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary-auth-bounded"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed(
            "eu-central-1",
            "hetzner",
            "vm-replica-auth-bounded",
        ))
        .await
        .unwrap();

    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
        .create(
            customer_id,
            "products",
            primary_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();

    let http_client = Arc::new(MockReplicationHttpClient::new());
    let engine_auth_error_body =
        r#"{"error_code":"auth_failed","message":"invalid x-internal-key"}"#;
    for _ in 0..5 {
        http_client.enqueue(Ok(MigrationHttpResponse {
            status: 401,
            body: engine_auth_error_body.to_string(),
        }));
    }

    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());
    let _seeded_key = mock_secret_mgr
        .create_node_api_key(&replica_vm.id.to_string(), &replica_vm.region)
        .await
        .unwrap();

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr,
        ReplicationConfig::default(),
    );

    orchestrator.run_cycle().await;
    let after_first_cycle = replica_repo.get(replica.id).await.unwrap().unwrap();
    assert_eq!(after_first_cycle.status, "provisioning");

    for _ in 0..4 {
        orchestrator.run_cycle().await;
    }
    let final_state = replica_repo.get(replica.id).await.unwrap().unwrap();
    assert_eq!(final_state.status, "failed");
    assert_eq!(
        http_client.recorded_requests().len(),
        5,
        "auth circuit-breaker should fail exactly on the fifth consecutive 401"
    );
}

#[tokio::test]
async fn orchestrator_auth_failure_logs_preserve_engine_401_body() {
    let capture = install_global_capture();
    let _guard = tracing_test_lock();
    capture.events.lock().unwrap().clear();

    let vm_repo = common::mock_vm_inventory_repo();
    let customer_id = Uuid::new_v4();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary-auth-body-log"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed(
            "eu-central-1",
            "hetzner",
            "vm-replica-auth-body-log",
        ))
        .await
        .unwrap();

    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
        .create(
            customer_id,
            "products",
            primary_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();

    let http_client = Arc::new(MockReplicationHttpClient::new());
    let engine_auth_error_body =
        r#"{"error_code":"auth_failed","message":"invalid x-internal-key"}"#;
    for _ in 0..5 {
        http_client.enqueue(Ok(MigrationHttpResponse {
            status: 401,
            body: engine_auth_error_body.to_string(),
        }));
    }

    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());
    let _seeded_key = mock_secret_mgr
        .create_node_api_key(&replica_vm.id.to_string(), &replica_vm.region)
        .await
        .unwrap();

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr,
        ReplicationConfig::default(),
    );

    for _ in 0..5 {
        orchestrator.run_cycle().await;
    }

    let final_state = replica_repo.get(replica.id).await.unwrap().unwrap();
    assert_eq!(final_state.status, "failed");

    let all_logs = capture.events.lock().unwrap().join("\n");
    assert!(
        all_logs.contains("invalid x-internal-key"),
        "failure logs should preserve the engine auth body for triage"
    );
}

#[tokio::test]
async fn orchestrator_auth_failure_count_resets_after_success() {
    let vm_repo = common::mock_vm_inventory_repo();
    let customer_id = Uuid::new_v4();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary-auth-reset"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-replica-auth-reset"))
        .await
        .unwrap();

    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
        .create(
            customer_id,
            "products",
            primary_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();

    let http_client = Arc::new(MockReplicationHttpClient::new());
    for _ in 0..4 {
        http_client.enqueue(Ok(MigrationHttpResponse {
            status: 401,
            body: r#"{"error_code":"auth_failed"}"#.to_string(),
        }));
    }
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
    for _ in 0..4 {
        http_client.enqueue(Ok(MigrationHttpResponse {
            status: 401,
            body: r#"{"error_code":"auth_failed"}"#.to_string(),
        }));
    }

    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());
    let _seeded_key = mock_secret_mgr
        .create_node_api_key(&replica_vm.id.to_string(), &replica_vm.region)
        .await
        .unwrap();

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr,
        ReplicationConfig::default(),
    );

    for _ in 0..4 {
        orchestrator.run_cycle().await;
    }
    let after_four_auth_failures = replica_repo.get(replica.id).await.unwrap().unwrap();
    assert_eq!(after_four_auth_failures.status, "provisioning");

    orchestrator.run_cycle().await;
    let after_success = replica_repo.get(replica.id).await.unwrap().unwrap();
    assert_eq!(after_success.status, "syncing");

    // Re-queue the replica into provisioning to verify the next auth failures
    // are counted from zero after the success path.
    replica_repo
        .set_status(replica.id, "provisioning")
        .await
        .unwrap();

    for _ in 0..4 {
        orchestrator.run_cycle().await;
    }
    let after_second_auth_streak = replica_repo.get(replica.id).await.unwrap().unwrap();
    assert_eq!(
        after_second_auth_streak.status, "provisioning",
        "auth failures after a successful call should start a new streak"
    );

    assert_eq!(
        http_client.recorded_requests().len(),
        9,
        "expected 4 auth failures, 1 success, then 4 auth failures after reset"
    );
}

#[tokio::test]
async fn orchestrator_valid_key_replication_succeeds() {
    let vm_repo = common::mock_vm_inventory_repo();
    let customer_id = Uuid::new_v4();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary-auth-valid-key"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed(
            "eu-central-1",
            "hetzner",
            "vm-replica-auth-valid-key",
        ))
        .await
        .unwrap();

    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
        .create(
            customer_id,
            "products",
            primary_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();

    let http_client = Arc::new(MockReplicationHttpClient::new());
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));

    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());
    let seeded_key = mock_secret_mgr
        .create_node_api_key(&replica_vm.id.to_string(), &replica_vm.region)
        .await
        .unwrap();

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr,
        ReplicationConfig::default(),
    );

    orchestrator.run_cycle().await;

    let updated = replica_repo.get(replica.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "syncing");

    let requests = http_client.recorded_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].headers.get(INTERNAL_AUTH_HEADER),
        Some(&seeded_key)
    );
    assert_eq!(
        requests[0]
            .headers
            .get(INTERNAL_APP_ID_HEADER)
            .map(String::as_str),
        Some(REPLICATION_APP_ID)
    );
}

#[tokio::test]
async fn orchestrator_rotation_continues_without_replication_downtime() {
    let RotationFixture {
        vm_repo,
        replica_repo,
        replica_id,
        replica_vm,
        mock_secret_mgr,
        source_key,
        old_replica_key,
    } = setup_rotation_fixture("vm-primary-rotate", "vm-replica-rotate").await;

    let http_client = Arc::new(KeyAwareMockReplicationHttpClient::new(vec![
        source_key.clone(),
        old_replica_key.clone(),
    ]));

    // Start with the replica on its old key.
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));

    let config = ReplicationConfig {
        near_zero_lag_ops: 0,
        ..Default::default()
    };

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr.clone(),
        config,
    );

    // Seed replica as provisioning initially so it can enter syncing.
    replica_repo
        .set_status(replica_id, "provisioning")
        .await
        .unwrap();

    orchestrator.run_cycle().await;
    assert_eq!(http_client.recorded_requests().len(), 1);

    {
        let requests = http_client.recorded_requests();
        let req = &requests[0];
        assert_eq!(req.url, "http://vm-replica-rotate:7700/internal/replicate");
        assert_eq!(
            req.headers.get(INTERNAL_AUTH_HEADER),
            Some(&old_replica_key)
        );
        assert_eq!(
            req.headers.get(INTERNAL_APP_ID_HEADER).map(String::as_str),
            Some(REPLICATION_APP_ID)
        );
    };

    let updated = replica_repo.get(replica_id).await.unwrap().unwrap();
    assert_eq!(updated.status, "syncing");

    // Rotate replica key and allow overlap for old + new keys.
    let (rot_old, rot_new) = mock_secret_mgr
        .rotate_node_api_key(&replica_vm.id.to_string(), &replica_vm.region)
        .await
        .unwrap();
    assert_eq!(rot_old, old_replica_key);
    http_client.allow_key(rot_new.clone());

    // During overlap, the flapjack mock accepts both keys, so replication keeps moving.
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 1000),
    }));
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 999),
    }));
    orchestrator.run_cycle().await;

    let updated = replica_repo.get(replica_id).await.unwrap().unwrap();
    assert_eq!(updated.status, "syncing");
    let requests = http_client.recorded_requests();
    assert_eq!(
        requests[1].headers.get(INTERNAL_AUTH_HEADER),
        Some(&source_key)
    );
    assert_eq!(
        requests[1]
            .headers
            .get(INTERNAL_APP_ID_HEADER)
            .map(String::as_str),
        Some(REPLICATION_APP_ID)
    );
    assert_eq!(
        requests[2].headers.get(INTERNAL_AUTH_HEADER),
        Some(&rot_new)
    );
    assert_eq!(
        requests[2]
            .headers
            .get(INTERNAL_APP_ID_HEADER)
            .map(String::as_str),
        Some(REPLICATION_APP_ID)
    );

    // Commit rotation drops the old key from the allowed set.
    mock_secret_mgr
        .commit_rotation(
            &replica_vm.id.to_string(),
            &replica_vm.region,
            &old_replica_key,
        )
        .await
        .unwrap();
    http_client.revoke_key(&old_replica_key);

    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 1000),
    }));
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 998),
    }));
    orchestrator.run_cycle().await;

    let requests = http_client.recorded_requests();
    assert_eq!(
        requests[3].headers.get(INTERNAL_AUTH_HEADER),
        Some(&source_key)
    );
    assert_eq!(
        requests[3]
            .headers
            .get(INTERNAL_APP_ID_HEADER)
            .map(String::as_str),
        Some(REPLICATION_APP_ID)
    );
    assert_eq!(
        requests[4].headers.get(INTERNAL_AUTH_HEADER),
        Some(&rot_new)
    );
    assert_eq!(
        requests[4]
            .headers
            .get(INTERNAL_APP_ID_HEADER)
            .map(String::as_str),
        Some(REPLICATION_APP_ID)
    );
}

#[tokio::test]
async fn orchestrator_provisioning_refuses_on_failed_key_lookup() {
    let vm_repo = common::mock_vm_inventory_repo();
    let customer_id = Uuid::new_v4();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary-auth-failed-key"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed(
            "eu-central-1",
            "hetzner",
            "vm-replica-auth-failed-key",
        ))
        .await
        .unwrap();

    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
        .create(
            customer_id,
            "products",
            primary_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();

    let http_client = Arc::new(MockReplicationHttpClient::new());
    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());
    mock_secret_mgr.set_should_fail(true);

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr,
        ReplicationConfig::default(),
    );

    orchestrator.run_cycle().await;

    let updated = replica_repo.get(replica.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "failed");
    assert_eq!(http_client.recorded_requests().len(), 0);
}

#[tokio::test]
async fn orchestrator_provisioning_refuses_on_failed_key_lookup_without_secret_leak() {
    let capture = install_global_capture();
    let _guard = tracing_test_lock();

    // Clear any events from other tests
    capture.events.lock().unwrap().clear();

    let vm_repo = common::mock_vm_inventory_repo();
    let customer_id = Uuid::new_v4();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary-auth-secret"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-replica-auth-secret"))
        .await
        .unwrap();

    let repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = repo
        .create(
            customer_id,
            "products",
            primary_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    let mgr = Arc::new(MockNodeSecretManager::new());
    let secret_key = mgr
        .create_node_api_key(&replica_vm.id.to_string(), &replica_vm.region)
        .await
        .unwrap();
    mgr.set_should_fail(true);

    let http_client = Arc::new(MockReplicationHttpClient::new());
    let orchestrator = ReplicationOrchestrator::new(
        repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mgr.clone(),
        ReplicationConfig::default(),
    );

    orchestrator.run_cycle().await;

    let updated = repo.get(replica.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "failed");
    assert_eq!(http_client.recorded_requests().len(), 0);

    let events = capture.events.lock().unwrap();
    let all_logs = events.join("\n");
    assert!(
        !all_logs.contains(&secret_key),
        "log output should not include internal key material"
    );
    assert!(
        all_logs.contains("failed to load internal key"),
        "logs should include an auth lookup failure reason"
    );
}

#[tokio::test]
async fn orchestrator_provisioning_refuses_without_internal_key() {
    let vm_repo = common::mock_vm_inventory_repo();
    let customer_id = Uuid::new_v4();

    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary-auth-missing-key"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed(
            "eu-central-1",
            "hetzner",
            "vm-replica-auth-missing-key",
        ))
        .await
        .unwrap();

    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
        .create(
            customer_id,
            "products",
            primary_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();

    let http_client = Arc::new(MockReplicationHttpClient::new());
    // If key lookup is missing, the orchestrator should refuse to send a request.

    let mock_secret_mgr = Arc::new(MockNodeSecretManager::new());

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr,
        ReplicationConfig::default(),
    );

    orchestrator.run_cycle().await;

    let updated = replica_repo.get(replica.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "failed");
    assert_eq!(
        http_client.recorded_requests().len(),
        0,
        "no outbound request should be sent when key is missing"
    );
}

// -------------------------------------------------------------------------
// Stage 4: Rotation integration + failure path tests
// -------------------------------------------------------------------------

/// After rotation + commit, the secret manager only returns the new key.
/// The flapjack mock rejects the old key. Verifies the orchestrator never
/// sends the old key post-commit.
#[tokio::test]
async fn orchestrator_post_commit_uses_new_key_and_old_key_is_invalid() {
    let RotationFixture {
        vm_repo,
        replica_repo,
        replica_id,
        replica_vm,
        mock_secret_mgr,
        source_key,
        old_replica_key,
    } = setup_rotation_fixture("vm-primary-post-commit", "vm-replica-post-commit").await;

    // Rotate + commit before first orchestrator cycle.
    let (rot_old, rot_new) = mock_secret_mgr
        .rotate_node_api_key(&replica_vm.id.to_string(), &replica_vm.region)
        .await
        .unwrap();
    assert_eq!(rot_old, old_replica_key);
    mock_secret_mgr
        .commit_rotation(
            &replica_vm.id.to_string(),
            &replica_vm.region,
            &old_replica_key,
        )
        .await
        .unwrap();

    // Verify secret manager state: only new key available, previous key removed.
    assert_eq!(
        mock_secret_mgr.get_secret(&replica_vm.id.to_string()),
        Some(rot_new.clone())
    );
    assert!(mock_secret_mgr
        .get_previous_secret(&replica_vm.id.to_string())
        .is_none());

    // Flapjack mock accepts only new key + source key; old key would panic.
    let http_client = Arc::new(KeyAwareMockReplicationHttpClient::new(vec![
        source_key.clone(),
        rot_new.clone(),
    ]));

    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr.clone(),
        ReplicationConfig::default(),
    );

    replica_repo
        .set_status(replica_id, "provisioning")
        .await
        .unwrap();

    orchestrator.run_cycle().await;

    let requests = http_client.recorded_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].headers.get(INTERNAL_AUTH_HEADER),
        Some(&rot_new),
        "orchestrator should use the new key post-commit"
    );
    assert_eq!(
        requests[0]
            .headers
            .get(INTERNAL_APP_ID_HEADER)
            .map(String::as_str),
        Some(REPLICATION_APP_ID)
    );
    let updated = replica_repo.get(replica_id).await.unwrap().unwrap();
    assert_eq!(updated.status, "syncing");
}

/// After a failed rotate, orchestrator continues with the original key.
/// No unauthenticated fallback or state corruption.
#[tokio::test]
async fn orchestrator_continues_with_original_key_after_failed_rotate() {
    let RotationFixture {
        vm_repo,
        replica_repo,
        replica_id,
        replica_vm,
        mock_secret_mgr,
        source_key,
        old_replica_key: original_replica_key,
    } = setup_rotation_fixture("vm-primary-failed-rotate", "vm-replica-failed-rotate").await;

    // Attempt rotate but it fails.
    mock_secret_mgr.set_should_fail(true);
    let result = mock_secret_mgr
        .rotate_node_api_key(&replica_vm.id.to_string(), &replica_vm.region)
        .await;
    assert!(result.is_err());
    mock_secret_mgr.set_should_fail(false);

    // Orchestrator should still use the original key.
    let http_client = Arc::new(KeyAwareMockReplicationHttpClient::new(vec![
        source_key.clone(),
        original_replica_key.clone(),
    ]));
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr.clone(),
        ReplicationConfig::default(),
    );

    replica_repo
        .set_status(replica_id, "provisioning")
        .await
        .unwrap();
    orchestrator.run_cycle().await;

    let requests = http_client.recorded_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].headers.get(INTERNAL_AUTH_HEADER),
        Some(&original_replica_key),
        "orchestrator should still use original key after failed rotation"
    );
    assert_eq!(
        requests[0]
            .headers
            .get(INTERNAL_APP_ID_HEADER)
            .map(String::as_str),
        Some(REPLICATION_APP_ID)
    );
    let updated = replica_repo.get(replica_id).await.unwrap().unwrap();
    assert_eq!(updated.status, "syncing");
}

/// After a failed commit, orchestrator continues using the new key.
/// Both keys remain valid during the extended overlap window.
#[tokio::test]
async fn orchestrator_continues_with_new_key_after_failed_commit() {
    let RotationFixture {
        vm_repo,
        replica_repo,
        replica_id,
        replica_vm,
        mock_secret_mgr,
        source_key,
        old_replica_key,
    } = setup_rotation_fixture("vm-primary-failed-commit", "vm-replica-failed-commit").await;

    // Rotate succeeds, creating overlap window.
    let (rot_old, rot_new) = mock_secret_mgr
        .rotate_node_api_key(&replica_vm.id.to_string(), &replica_vm.region)
        .await
        .unwrap();
    assert_eq!(rot_old, old_replica_key);

    // Commit fails — overlap window stays open.
    mock_secret_mgr.set_should_fail(true);
    let result = mock_secret_mgr
        .commit_rotation(
            &replica_vm.id.to_string(),
            &replica_vm.region,
            &old_replica_key,
        )
        .await;
    assert!(result.is_err());
    mock_secret_mgr.set_should_fail(false);

    assert!(mock_secret_mgr
        .get_previous_secret(&replica_vm.id.to_string())
        .is_some());

    // Orchestrator uses the new key despite failed commit.
    let http_client = Arc::new(KeyAwareMockReplicationHttpClient::new(vec![
        source_key.clone(),
        old_replica_key.clone(),
        rot_new.clone(),
    ]));
    http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo.clone(),
        http_client.clone(),
        mock_secret_mgr.clone(),
        ReplicationConfig::default(),
    );

    replica_repo
        .set_status(replica_id, "provisioning")
        .await
        .unwrap();
    orchestrator.run_cycle().await;

    let requests = http_client.recorded_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].headers.get(INTERNAL_AUTH_HEADER),
        Some(&rot_new),
        "orchestrator should use new key after successful rotate, even when commit fails"
    );
    assert_eq!(
        requests[0]
            .headers
            .get(INTERNAL_APP_ID_HEADER)
            .map(String::as_str),
        Some(REPLICATION_APP_ID)
    );
    let updated = replica_repo.get(replica_id).await.unwrap().unwrap();
    assert_eq!(updated.status, "syncing");
}
