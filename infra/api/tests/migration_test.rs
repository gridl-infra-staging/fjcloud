mod common;

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use api::models::index_migration::IndexMigration;
use api::models::vm_inventory::{NewVmInventory, VmInventory};
use api::repos::index_migration_repo::IndexMigrationRepo;
use api::repos::{RepoError, TenantRepo, VmInventoryRepo};
use api::secrets::mock::MockNodeSecretManager;
use api::secrets::NodeSecretManager;
use api::services::alerting::{AlertSeverity, MockAlertService};
use api::services::discovery::DiscoveryService;
use api::services::migration::{
    MigrationConfig, MigrationError, MigrationHttpClient, MigrationHttpClientError,
    MigrationHttpRequest, MigrationHttpResponse, MigrationRequest, MigrationService,
    MigrationStatus,
};
use api::services::replication_error::{
    INTERNAL_APP_ID_HEADER, INTERNAL_AUTH_HEADER, REPLICATION_APP_ID,
};
use api::services::scheduler::{
    MigrationRequest as SchedulerMigrationRequest, SchedulerMigrationService,
};
use async_trait::async_trait;
use chrono::Utc;
use reqwest::Method;
use uuid::Uuid;

#[derive(Default)]
struct MockIndexMigrationRepo {
    rows: Mutex<Vec<IndexMigration>>,
}

impl MockIndexMigrationRepo {
    fn active_status(status: &str) -> bool {
        matches!(status, "pending" | "replicating" | "cutting_over")
    }

    fn get(&self, id: Uuid) -> Option<IndexMigration> {
        self.rows
            .lock()
            .unwrap()
            .iter()
            .find(|r| r.id == id)
            .cloned()
    }
}

#[async_trait]
impl IndexMigrationRepo for MockIndexMigrationRepo {
    async fn get(&self, id: Uuid) -> Result<Option<IndexMigration>, RepoError> {
        Ok(self.get(id))
    }

    async fn create(&self, req: &MigrationRequest) -> Result<IndexMigration, RepoError> {
        let row = IndexMigration {
            id: Uuid::new_v4(),
            index_name: req.index_name.clone(),
            customer_id: req.customer_id,
            source_vm_id: req.source_vm_id,
            dest_vm_id: req.dest_vm_id,
            status: MigrationStatus::Pending.as_str().to_string(),
            requested_by: req.requested_by.clone(),
            started_at: Utc::now(),
            completed_at: None,
            error: None,
            metadata: serde_json::json!({}),
        };
        self.rows.lock().unwrap().push(row.clone());
        Ok(row)
    }

    async fn update_status(
        &self,
        id: Uuid,
        status: &str,
        error: Option<&str>,
    ) -> Result<(), RepoError> {
        let mut rows = self.rows.lock().unwrap();
        if let Some(row) = rows.iter_mut().find(|r| r.id == id) {
            row.status = status.to_string();
            row.error = error.map(|e| e.to_string());
            return Ok(());
        }
        Err(RepoError::NotFound)
    }

    async fn set_completed(&self, id: Uuid) -> Result<(), RepoError> {
        let mut rows = self.rows.lock().unwrap();
        if let Some(row) = rows.iter_mut().find(|r| r.id == id) {
            row.status = MigrationStatus::Completed.as_str().to_string();
            row.completed_at = Some(Utc::now());
            row.error = None;
            return Ok(());
        }
        Err(RepoError::NotFound)
    }

    async fn list_active(&self) -> Result<Vec<IndexMigration>, RepoError> {
        let rows = self.rows.lock().unwrap();
        Ok(rows
            .iter()
            .filter(|r| Self::active_status(&r.status))
            .cloned()
            .collect())
    }

    async fn list_recent(&self, limit: i64) -> Result<Vec<IndexMigration>, RepoError> {
        let mut rows = self.rows.lock().unwrap().clone();
        rows.sort_by(|a, b| b.started_at.cmp(&a.started_at));
        if limit <= 0 {
            return Ok(Vec::new());
        }
        rows.truncate(limit as usize);
        Ok(rows)
    }

    async fn count_active(&self) -> Result<i64, RepoError> {
        let rows = self.rows.lock().unwrap();
        Ok(rows
            .iter()
            .filter(|r| Self::active_status(&r.status))
            .count() as i64)
    }
}

#[derive(Default)]
struct MockMigrationHttpClient {
    requests: Mutex<Vec<MigrationHttpRequest>>,
    responses: Mutex<VecDeque<Result<MigrationHttpResponse, MigrationHttpClientError>>>,
}

impl MockMigrationHttpClient {
    fn enqueue_response(&self, response: Result<MigrationHttpResponse, MigrationHttpClientError>) {
        self.responses.lock().unwrap().push_back(response);
    }

    fn recorded_requests(&self) -> Vec<MigrationHttpRequest> {
        self.requests.lock().unwrap().clone()
    }
}

#[async_trait]
impl MigrationHttpClient for MockMigrationHttpClient {
    async fn send(
        &self,
        request: MigrationHttpRequest,
    ) -> Result<MigrationHttpResponse, MigrationHttpClientError> {
        self.requests.lock().unwrap().push(request);
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("test must enqueue HTTP responses")
    }
}

struct MigrationFixture {
    service: MigrationService,
    tenant_repo: Arc<common::MockTenantRepo>,
    vm_repo: Arc<common::MockVmInventoryRepo>,
    migration_repo: Arc<MockIndexMigrationRepo>,
    alert_service: Arc<MockAlertService>,
    discovery_service: Arc<DiscoveryService>,
    http_client: Arc<MockMigrationHttpClient>,
    node_secret_manager: Arc<MockNodeSecretManager>,
    customer_id: Uuid,
    index_name: String,
    source_vm: VmInventory,
    dest_vm: VmInventory,
}

fn vm_seed(region: &str, hostname: &str, flapjack_url: &str) -> NewVmInventory {
    NewVmInventory {
        region: region.to_string(),
        provider: "aws".to_string(),
        hostname: hostname.to_string(),
        flapjack_url: flapjack_url.to_string(),
        capacity: serde_json::json!({
            "cpu_weight": 100.0,
            "mem_rss_bytes": 10_000_000_u64,
            "disk_bytes": 10_000_000_u64,
            "query_rps": 10_000.0,
            "indexing_rps": 10_000.0
        }),
    }
}

fn oplog_metric(index_name: &str, seq: i64) -> String {
    format!(r#"flapjack_oplog_current_seq{{index="{index_name}"}} {seq}"#)
}

fn queue_successful_migration_http(
    http_client: &MockMigrationHttpClient,
    index_name: &str,
    source_seq: i64,
    near_zero_dest_seq: i64,
) {
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric(index_name, source_seq),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric(index_name, near_zero_dest_seq),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric(index_name, source_seq),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric(index_name, source_seq),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
}

fn queue_replication_lag_never_converges_http(
    http_client: &MockMigrationHttpClient,
    index_name: &str,
    polls: usize,
) {
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));

    for _ in 0..polls {
        http_client.enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(index_name, 100),
        }));
        http_client.enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(index_name, 50),
        }));
    }

    // Source resume during failure recovery.
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
    // Destination cleanup (used once cleanup is implemented).
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
}

fn short_replication_timeout_config() -> MigrationConfig {
    MigrationConfig {
        max_concurrent: 3,
        rollback_window: chrono::Duration::seconds(300),
        replication_timeout: std::time::Duration::from_millis(50),
        replication_poll_interval: std::time::Duration::from_millis(10),
        replication_near_zero_lag_ops: 10,
        long_running_warning_threshold: std::time::Duration::from_secs(600),
    }
}

fn service_with_short_replication_timeout(fixture: &MigrationFixture) -> MigrationService {
    MigrationService::with_http_client_and_config(
        fixture.tenant_repo.clone(),
        fixture.vm_repo.clone(),
        fixture.migration_repo.clone(),
        fixture.alert_service.clone(),
        fixture.discovery_service.clone(),
        fixture.node_secret_manager.clone(),
        fixture.http_client.clone(),
        short_replication_timeout_config(),
    )
}

async fn setup_fixture(index_name: &str) -> MigrationFixture {
    let tenant_repo = common::mock_tenant_repo();
    let vm_repo = common::mock_vm_inventory_repo();
    let migration_repo = Arc::new(MockIndexMigrationRepo::default());
    let alert_service = common::mock_alert_service();
    let discovery_service = Arc::new(DiscoveryService::with_ttl(
        tenant_repo.clone(),
        vm_repo.clone(),
        3600,
    ));
    let http_client = Arc::new(MockMigrationHttpClient::default());
    let node_secret_manager = common::mock_node_secret_manager();

    let service = MigrationService::with_http_client(
        tenant_repo.clone(),
        vm_repo.clone(),
        migration_repo.clone(),
        alert_service.clone(),
        discovery_service.clone(),
        node_secret_manager.clone(),
        http_client.clone(),
        3,
    );

    let customer_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();
    tenant_repo
        .create(customer_id, index_name, deployment_id)
        .await
        .expect("seed tenant");

    let source_vm = vm_repo
        .create(vm_seed(
            "us-east-1",
            "vm-source.flapjack.foo",
            "http://source-vm.test",
        ))
        .await
        .expect("seed source vm");

    let dest_vm = vm_repo
        .create(vm_seed(
            "us-east-1",
            "vm-dest.flapjack.foo",
            "http://dest-vm.test",
        ))
        .await
        .expect("seed destination vm");

    node_secret_manager
        .create_node_api_key(&source_vm.id.to_string(), &source_vm.region)
        .await
        .expect("seed source vm key");
    node_secret_manager
        .create_node_api_key(&dest_vm.id.to_string(), &dest_vm.region)
        .await
        .expect("seed destination vm key");

    tenant_repo
        .set_vm_id(customer_id, index_name, source_vm.id)
        .await
        .expect("seed tenant vm assignment");

    MigrationFixture {
        service,
        tenant_repo,
        vm_repo,
        migration_repo,
        alert_service,
        discovery_service,
        http_client,
        node_secret_manager,
        customer_id,
        index_name: index_name.to_string(),
        source_vm,
        dest_vm,
    }
}

fn fixture_request(fixture: &MigrationFixture) -> MigrationRequest {
    MigrationRequest {
        index_name: fixture.index_name.clone(),
        customer_id: fixture.customer_id,
        source_vm_id: fixture.source_vm.id,
        dest_vm_id: fixture.dest_vm.id,
        requested_by: "scheduler".to_string(),
    }
}

fn sample_request(index_name: &str) -> MigrationRequest {
    MigrationRequest {
        index_name: index_name.to_string(),
        customer_id: Uuid::new_v4(),
        source_vm_id: Uuid::new_v4(),
        dest_vm_id: Uuid::new_v4(),
        requested_by: "scheduler".to_string(),
    }
}

#[tokio::test]
async fn migration_create_and_list_active() {
    let repo = Arc::new(MockIndexMigrationRepo::default());

    let req = sample_request("products");
    let created = repo.create(&req).await.expect("create should succeed");

    assert_eq!(created.index_name, "products");
    assert_eq!(created.status, "pending");
    assert_eq!(created.requested_by, "scheduler");
    assert!(created.completed_at.is_none());

    let active = repo
        .list_active()
        .await
        .expect("list active should succeed");
    assert_eq!(active.len(), 1);
    assert_eq!(active[0].id, created.id);
    assert_eq!(repo.count_active().await.unwrap(), 1);

    repo.update_status(created.id, "replicating", None)
        .await
        .expect("status update should succeed");
    assert_eq!(repo.count_active().await.unwrap(), 1);

    repo.set_completed(created.id)
        .await
        .expect("set completed should succeed");
    assert_eq!(repo.count_active().await.unwrap(), 0);

    let active = repo
        .list_active()
        .await
        .expect("list active should succeed");
    assert!(active.is_empty());
}

#[tokio::test]
async fn migration_concurrent_limit_enforced() {
    let repo = Arc::new(MockIndexMigrationRepo::default());
    repo.create(&sample_request("already-running"))
        .await
        .expect("seed active migration");

    let service = MigrationService::new(
        common::mock_tenant_repo(),
        common::mock_vm_inventory_repo(),
        repo as Arc<dyn IndexMigrationRepo + Send + Sync>,
        common::mock_alert_service(),
        common::mock_discovery_service(),
        common::mock_node_secret_manager(),
        reqwest::Client::new(),
        1,
    );

    let err = service
        .execute(sample_request("new-index"))
        .await
        .expect_err("should reject when active migration limit is reached");

    assert!(matches!(
        err,
        MigrationError::ConcurrencyLimitReached { active, max } if active == 1 && max == 1
    ));
}

#[tokio::test]
async fn migration_replication_start() {
    let fixture = setup_fixture("products").await;
    queue_successful_migration_http(&fixture.http_client, &fixture.index_name, 100, 95);

    fixture
        .service
        .execute(fixture_request(&fixture))
        .await
        .expect("migration execute should succeed");

    let requests = fixture.http_client.recorded_requests();
    let source_key = fixture
        .node_secret_manager
        .get_secret(&fixture.source_vm.id.to_string())
        .expect("source key should be seeded");
    let dest_key = fixture
        .node_secret_manager
        .get_secret(&fixture.dest_vm.id.to_string())
        .expect("destination key should be seeded");

    let replicate = requests
        .iter()
        .find(|r| {
            r.method == Method::POST
                && r.url == format!("{}/internal/replicate", fixture.dest_vm.flapjack_url)
        })
        .expect("replication request should be sent");

    assert_eq!(
        replicate.json_body,
        Some(serde_json::json!({
            "index_name": fixture.index_name,
            "source_flapjack_url": fixture.source_vm.flapjack_url
        }))
    );
    assert_eq!(
        replicate.headers.get(INTERNAL_AUTH_HEADER),
        Some(&dest_key),
        "replication request should use destination node API key"
    );
    assert_eq!(
        replicate
            .headers
            .get(INTERNAL_APP_ID_HEADER)
            .map(String::as_str),
        Some(REPLICATION_APP_ID),
        "replication request should include application-id header"
    );

    for req in requests
        .iter()
        .filter(|r| r.url == format!("{}/metrics", fixture.source_vm.flapjack_url))
    {
        assert_eq!(
            req.headers.get(INTERNAL_AUTH_HEADER),
            Some(&source_key),
            "source metrics requests should use source node API key"
        );
        assert_eq!(
            req.headers.get(INTERNAL_APP_ID_HEADER).map(String::as_str),
            Some(REPLICATION_APP_ID),
            "source metrics requests should include application-id header"
        );
    }

    for req in requests
        .iter()
        .filter(|r| r.url == format!("{}/metrics", fixture.dest_vm.flapjack_url))
    {
        assert_eq!(
            req.headers.get(INTERNAL_AUTH_HEADER),
            Some(&dest_key),
            "destination metrics requests should use destination node API key"
        );
        assert_eq!(
            req.headers.get(INTERNAL_APP_ID_HEADER).map(String::as_str),
            Some(REPLICATION_APP_ID),
            "destination metrics requests should include application-id header"
        );
    }
}

#[tokio::test]
async fn migration_pause_on_source() {
    let fixture = setup_fixture("products").await;
    queue_successful_migration_http(&fixture.http_client, &fixture.index_name, 100, 95);

    fixture
        .service
        .execute(fixture_request(&fixture))
        .await
        .expect("migration execute should succeed");

    let requests = fixture.http_client.recorded_requests();
    assert!(requests.iter().any(|r| {
        r.method == Method::POST
            && r.url
                == format!(
                    "{}/internal/pause/{}",
                    fixture.source_vm.flapjack_url, fixture.index_name
                )
    }));
}

#[tokio::test]
async fn migration_refuses_when_internal_key_lookup_fails() {
    let fixture = setup_fixture("products").await;
    fixture.node_secret_manager.set_should_fail(true);

    let err = fixture
        .service
        .execute(fixture_request(&fixture))
        .await
        .expect_err("migration should fail closed when key lookup fails");

    assert!(
        matches!(err, MigrationError::Http(msg) if msg.contains("failed to load internal key")),
        "error should report internal key lookup failure"
    );
    assert!(
        fixture.http_client.recorded_requests().is_empty(),
        "no internal request should be sent when key lookup fails"
    );
}

#[tokio::test]
async fn migration_catalog_flip_updates_vm_id() {
    let fixture = setup_fixture("products").await;
    queue_successful_migration_http(&fixture.http_client, &fixture.index_name, 100, 95);

    fixture
        .service
        .execute(fixture_request(&fixture))
        .await
        .expect("migration execute should succeed");

    let tenant = fixture
        .tenant_repo
        .find_raw(fixture.customer_id, &fixture.index_name)
        .await
        .expect("find raw should succeed")
        .expect("tenant should exist");
    assert_eq!(tenant.vm_id, Some(fixture.dest_vm.id));
    assert_eq!(tenant.tier, "active");
}

#[tokio::test]
async fn migration_cache_invalidated_on_flip() {
    let fixture = setup_fixture("products").await;
    queue_successful_migration_http(&fixture.http_client, &fixture.index_name, 100, 95);

    let before = fixture
        .discovery_service
        .discover(fixture.customer_id, &fixture.index_name)
        .await
        .expect("discover before migration should succeed");
    assert_eq!(before.vm, fixture.source_vm.hostname);

    fixture
        .service
        .execute(fixture_request(&fixture))
        .await
        .expect("migration execute should succeed");

    let after = fixture
        .discovery_service
        .discover(fixture.customer_id, &fixture.index_name)
        .await
        .expect("discover after migration should succeed");
    assert_eq!(after.vm, fixture.dest_vm.hostname);
}

#[tokio::test]
async fn migration_resume_on_destination() {
    let fixture = setup_fixture("products").await;
    queue_successful_migration_http(&fixture.http_client, &fixture.index_name, 100, 95);

    fixture
        .service
        .execute(fixture_request(&fixture))
        .await
        .expect("migration execute should succeed");

    let requests = fixture.http_client.recorded_requests();
    assert!(requests.iter().any(|r| {
        r.method == Method::POST
            && r.url
                == format!(
                    "{}/internal/resume/{}",
                    fixture.dest_vm.flapjack_url, fixture.index_name
                )
    }));
}

#[tokio::test]
async fn migration_failure_fires_critical_alert() {
    let fixture = setup_fixture("products").await;
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 500,
            body: "replication failed".to_string(),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: "{}".to_string(),
        }));

    let err = fixture
        .service
        .execute(fixture_request(&fixture))
        .await
        .expect_err("execute should fail when replication endpoint fails");
    assert!(matches!(err, MigrationError::Http(_)));

    let alerts = fixture.alert_service.recorded_alerts();
    assert_eq!(alerts.len(), 1);
    assert_eq!(alerts[0].severity, AlertSeverity::Critical);

    let tenant = fixture
        .tenant_repo
        .find_raw(fixture.customer_id, &fixture.index_name)
        .await
        .expect("find raw should succeed")
        .expect("tenant should exist");
    assert_eq!(tenant.tier, "active");
    assert_eq!(tenant.vm_id, Some(fixture.source_vm.id));

    let migration = fixture
        .migration_repo
        .list_recent(1)
        .await
        .expect("list recent should succeed");
    assert_eq!(migration.len(), 1);
    assert_eq!(migration[0].status, "failed");
    assert!(migration[0].error.is_some());
}

#[tokio::test]
async fn migration_success_fires_info_alert() {
    let fixture = setup_fixture("products").await;
    queue_successful_migration_http(&fixture.http_client, &fixture.index_name, 100, 95);

    let migration_id = fixture
        .service
        .execute(fixture_request(&fixture))
        .await
        .expect("migration execute should succeed");

    let alerts = fixture.alert_service.recorded_alerts();
    assert_eq!(alerts.len(), 1);
    assert_eq!(alerts[0].severity, AlertSeverity::Info);

    let row = fixture
        .migration_repo
        .get(migration_id)
        .expect("created migration should exist");
    assert_eq!(row.status, "completed");
    assert!(row.completed_at.is_some());
    assert!(row.error.is_none());

    let active = fixture
        .migration_repo
        .list_active()
        .await
        .expect("list active should succeed");
    assert!(active.is_empty());
}

#[tokio::test]
async fn migration_service_scheduler_adapter_forwards_reason_and_executes() {
    let fixture = setup_fixture("products").await;
    queue_successful_migration_http(&fixture.http_client, &fixture.index_name, 100, 95);

    fixture
        .service
        .request_migration(SchedulerMigrationRequest {
            index_name: fixture.index_name.clone(),
            customer_id: fixture.customer_id,
            source_vm_id: fixture.source_vm.id,
            dest_vm_id: fixture.dest_vm.id,
            reason: "overload".to_string(),
        })
        .await
        .expect("scheduler migration adapter should execute migration");

    let tenant = fixture
        .tenant_repo
        .find_raw(fixture.customer_id, &fixture.index_name)
        .await
        .expect("find raw should succeed")
        .expect("tenant should exist");
    assert_eq!(tenant.vm_id, Some(fixture.dest_vm.id));

    let recent = fixture
        .migration_repo
        .list_recent(1)
        .await
        .expect("list recent should succeed");
    assert_eq!(recent.len(), 1);
    assert_eq!(recent[0].requested_by, "overload");
}

#[tokio::test]
async fn migration_rollback_reverts_catalog() {
    let fixture = setup_fixture("products").await;
    queue_successful_migration_http(&fixture.http_client, &fixture.index_name, 100, 95);

    let migration_id = fixture
        .service
        .execute(fixture_request(&fixture))
        .await
        .expect("migration execute should succeed");

    let post_execute = fixture
        .discovery_service
        .discover(fixture.customer_id, &fixture.index_name)
        .await
        .expect("discover after execute should succeed");
    assert_eq!(post_execute.vm, fixture.dest_vm.hostname);

    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: "{}".to_string(),
        }));

    fixture
        .service
        .rollback(migration_id)
        .await
        .expect("rollback should succeed");

    let tenant = fixture
        .tenant_repo
        .find_raw(fixture.customer_id, &fixture.index_name)
        .await
        .expect("find raw should succeed")
        .expect("tenant should exist");
    assert_eq!(tenant.vm_id, Some(fixture.source_vm.id));
    assert_eq!(tenant.tier, "active");

    let post_rollback = fixture
        .discovery_service
        .discover(fixture.customer_id, &fixture.index_name)
        .await
        .expect("discover after rollback should succeed");
    assert_eq!(post_rollback.vm, fixture.source_vm.hostname);

    let row = fixture
        .migration_repo
        .get(migration_id)
        .expect("migration row should exist");
    assert_eq!(row.status, "rolled_back");
    assert!(row.error.is_none());
}

#[tokio::test]
async fn migration_completed_rollback_resumes_source_index() {
    let fixture = setup_fixture("products").await;
    queue_successful_migration_http(&fixture.http_client, &fixture.index_name, 100, 95);

    let migration_id = fixture
        .service
        .execute(fixture_request(&fixture))
        .await
        .expect("migration execute should succeed");

    let before_rollback_requests = fixture.http_client.recorded_requests().len();
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: "{}".to_string(),
        }));

    fixture
        .service
        .rollback(migration_id)
        .await
        .expect("rollback should succeed");

    let requests = fixture.http_client.recorded_requests();
    assert_eq!(
        requests.len(),
        before_rollback_requests + 1,
        "completed rollback must issue one additional HTTP call to resume source writes"
    );

    let last = requests.last().expect("at least one request should exist");
    assert_eq!(last.method, Method::POST);
    assert_eq!(
        last.url,
        format!(
            "{}/internal/resume/{}",
            fixture.source_vm.flapjack_url, fixture.index_name
        )
    );
}

#[tokio::test]
async fn migration_rejects_same_source_and_destination_vm() {
    let fixture = setup_fixture("products").await;
    queue_successful_migration_http(&fixture.http_client, &fixture.index_name, 100, 95);

    let mut req = fixture_request(&fixture);
    req.dest_vm_id = fixture.source_vm.id;

    let err = fixture
        .service
        .execute(req)
        .await
        .expect_err("same source/destination vm must be rejected");

    match err {
        MigrationError::Protocol(message) => {
            assert!(message.contains("source VM and destination VM must differ"));
        }
        other => panic!("expected protocol error, got {other:?}"),
    }
}

#[tokio::test]
async fn migration_rejects_non_active_destination_vm() {
    let fixture = setup_fixture("products").await;
    fixture
        .vm_repo
        .set_status(fixture.dest_vm.id, "draining")
        .await
        .expect("set destination vm status");
    queue_successful_migration_http(&fixture.http_client, &fixture.index_name, 100, 95);

    let err = fixture
        .service
        .execute(fixture_request(&fixture))
        .await
        .expect_err("non-active destination vm must be rejected");

    match err {
        MigrationError::Protocol(message) => {
            assert!(message.contains("destination VM must be active"));
        }
        other => panic!("expected protocol error, got {other:?}"),
    }
}

#[tokio::test]
async fn migration_failure_after_catalog_flip_recovers_source_routing() {
    let fixture = setup_fixture("products").await;

    // Protocol flow:
    // 1) start replication
    // 2) near-zero lag check (source=100, dest=95)
    // 3) pause source
    // 4) exact lag check (source=100, dest=100)
    // 5) resume destination fails (HTTP 500) -> service must recover to source
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: "{}".to_string(),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.index_name, 100),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.index_name, 95),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: "{}".to_string(),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.index_name, 100),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.index_name, 100),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 500,
            body: "destination resume failed".to_string(),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: "{}".to_string(),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: "{}".to_string(),
        }));

    let err = fixture
        .service
        .execute(fixture_request(&fixture))
        .await
        .expect_err("execute should fail when destination resume fails");
    assert!(matches!(err, MigrationError::Http(_)));

    let tenant = fixture
        .tenant_repo
        .find_raw(fixture.customer_id, &fixture.index_name)
        .await
        .expect("find raw should succeed")
        .expect("tenant should exist");
    assert_eq!(
        tenant.vm_id,
        Some(fixture.source_vm.id),
        "failed cutover must revert routing to source VM"
    );
    assert_eq!(tenant.tier, "active");

    let discovered = fixture
        .discovery_service
        .discover(fixture.customer_id, &fixture.index_name)
        .await
        .expect("discover should still succeed");
    assert_eq!(discovered.vm, fixture.source_vm.hostname);

    let requests = fixture.http_client.recorded_requests();
    assert!(
        requests.iter().any(|r| {
            r.method == Method::POST
                && r.url
                    == format!(
                        "{}/internal/resume/{}",
                        fixture.source_vm.flapjack_url, fixture.index_name
                    )
        }),
        "failure recovery must resume source writes"
    );
}

#[tokio::test]
async fn migration_failure_recovery_restores_routing_even_if_source_resume_fails() {
    let fixture = setup_fixture("products").await;

    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: "{}".to_string(),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.index_name, 100),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.index_name, 95),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: "{}".to_string(),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.index_name, 100),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.index_name, 100),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 500,
            body: "destination resume failed".to_string(),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 500,
            body: "source resume failed".to_string(),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: "{}".to_string(),
        }));

    let err = fixture
        .service
        .execute(fixture_request(&fixture))
        .await
        .expect_err("execute should fail when destination resume fails");
    assert!(matches!(err, MigrationError::Http(_)));

    let tenant = fixture
        .tenant_repo
        .find_raw(fixture.customer_id, &fixture.index_name)
        .await
        .expect("find raw should succeed")
        .expect("tenant should exist");
    assert_eq!(
        tenant.vm_id,
        Some(fixture.source_vm.id),
        "source routing must be restored even if source resume call fails"
    );
    assert_eq!(tenant.tier, "active");

    let discovered = fixture
        .discovery_service
        .discover(fixture.customer_id, &fixture.index_name)
        .await
        .expect("discover should still succeed");
    assert_eq!(discovered.vm, fixture.source_vm.hostname);
}

#[tokio::test]
async fn migration_replication_lag_timeout_restores_source_routing() {
    let fixture = setup_fixture("products").await;
    let service = service_with_short_replication_timeout(&fixture);

    queue_replication_lag_never_converges_http(&fixture.http_client, &fixture.index_name, 20);

    let err = service
        .execute(fixture_request(&fixture))
        .await
        .expect_err("execute should fail when replication lag never converges");
    assert!(
        matches!(err, MigrationError::ReplicationLagTimeout { .. }),
        "expected ReplicationLagTimeout, got {err:?}"
    );

    let tenant = fixture
        .tenant_repo
        .find_raw(fixture.customer_id, &fixture.index_name)
        .await
        .expect("find raw should succeed")
        .expect("tenant should exist");
    assert_eq!(tenant.vm_id, Some(fixture.source_vm.id));
    assert_eq!(tenant.tier, "active");

    let discovered = fixture
        .discovery_service
        .discover(fixture.customer_id, &fixture.index_name)
        .await
        .expect("discover should still succeed");
    assert_eq!(discovered.vm, fixture.source_vm.hostname);

    let migration = fixture
        .migration_repo
        .list_recent(1)
        .await
        .expect("list recent should succeed");
    assert_eq!(migration.len(), 1);
    assert_eq!(migration[0].status, "failed");
    assert!(
        migration[0]
            .error
            .as_deref()
            .is_some_and(|msg| msg.contains("replication lag timeout")),
        "migration error should include replication lag timeout details"
    );
}

#[tokio::test]
async fn migration_failure_cleans_up_destination_replica() {
    let fixture = setup_fixture("products").await;
    let service = service_with_short_replication_timeout(&fixture);

    queue_replication_lag_never_converges_http(&fixture.http_client, &fixture.index_name, 20);

    let err = service
        .execute(fixture_request(&fixture))
        .await
        .expect_err("execute should fail when replication lag never converges");
    assert!(matches!(err, MigrationError::ReplicationLagTimeout { .. }));

    let requests = fixture.http_client.recorded_requests();
    assert!(
        requests.iter().any(|request| {
            request.method == Method::DELETE
                && request.url
                    == format!(
                        "{}/1/indexes/{}",
                        fixture.dest_vm.flapjack_url, fixture.index_name
                    )
        }),
        "failure recovery must delete the orphaned destination index"
    );
}

#[tokio::test]
async fn migration_long_running_fires_warning_alert() {
    let fixture = setup_fixture("products").await;
    let service = MigrationService::with_http_client_and_config(
        fixture.tenant_repo.clone(),
        fixture.vm_repo.clone(),
        fixture.migration_repo.clone(),
        fixture.alert_service.clone(),
        fixture.discovery_service.clone(),
        fixture.node_secret_manager.clone(),
        fixture.http_client.clone(),
        MigrationConfig {
            max_concurrent: 3,
            rollback_window: chrono::Duration::seconds(300),
            replication_timeout: std::time::Duration::from_secs(30),
            replication_poll_interval: std::time::Duration::from_millis(1),
            replication_near_zero_lag_ops: 10,
            long_running_warning_threshold: std::time::Duration::ZERO,
        },
    );

    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: "{}".to_string(),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.index_name, 100),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.index_name, 80),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.index_name, 100),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.index_name, 95),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: "{}".to_string(),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.index_name, 100),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.index_name, 100),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: "{}".to_string(),
        }));

    service
        .execute(fixture_request(&fixture))
        .await
        .expect("migration execute should succeed");

    let alerts = fixture.alert_service.recorded_alerts();
    assert!(
        alerts.iter().any(|a| a.severity == AlertSeverity::Warning),
        "expected at least one warning alert for long-running migration"
    );
}

#[tokio::test]
async fn migration_rollback_during_replicating_deletes_dest_copy() {
    let fixture = setup_fixture("products").await;

    // Manually create a migration record in "replicating" status
    let req = fixture_request(&fixture);
    let row = fixture
        .migration_repo
        .create(&req)
        .await
        .expect("create migration");
    fixture
        .migration_repo
        .update_status(row.id, "replicating", None)
        .await
        .expect("set replicating");

    // Set tier to migrating (as the execute protocol would)
    fixture
        .tenant_repo
        .set_tier(fixture.customer_id, &fixture.index_name, "migrating")
        .await
        .expect("set tier");

    // Rollback during replicating should DELETE the destination index copy
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: "{}".to_string(),
        }));

    fixture
        .service
        .rollback(row.id)
        .await
        .expect("rollback should succeed");

    // Verify the HTTP call was a DELETE to dest VM
    let requests = fixture.http_client.recorded_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, Method::DELETE);
    assert!(
        requests[0].url.contains(&fixture.dest_vm.flapjack_url),
        "should delete on destination VM"
    );
    assert!(
        requests[0].url.contains(&fixture.index_name),
        "should delete the migrating index"
    );

    // Tier should be reset to active
    let tenant = fixture
        .tenant_repo
        .find_raw(fixture.customer_id, &fixture.index_name)
        .await
        .expect("find raw")
        .expect("tenant exists");
    assert_eq!(tenant.tier, "active");
    // vm_id should still point to source (unchanged)
    assert_eq!(tenant.vm_id, Some(fixture.source_vm.id));

    // Migration record should be marked rolled_back
    let migration = fixture
        .migration_repo
        .get(row.id)
        .expect("migration row exists");
    assert_eq!(migration.status, "rolled_back");
}

#[tokio::test]
async fn migration_rollback_unsupported_status_returns_error() {
    let fixture = setup_fixture("products").await;

    // Create a migration record and set it to "failed" status
    let req = fixture_request(&fixture);
    let row = fixture
        .migration_repo
        .create(&req)
        .await
        .expect("create migration");
    fixture
        .migration_repo
        .update_status(row.id, "failed", Some("test failure"))
        .await
        .expect("set failed");

    let err = fixture
        .service
        .rollback(row.id)
        .await
        .expect_err("rollback of failed migration should error");

    match err {
        MigrationError::RollbackUnsupportedStatus {
            migration_id,
            status,
        } => {
            assert_eq!(migration_id, row.id);
            assert_eq!(status, "failed");
        }
        other => panic!("expected RollbackUnsupportedStatus, got {other:?}"),
    }
}
