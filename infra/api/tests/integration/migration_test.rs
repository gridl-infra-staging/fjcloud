use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use api::models::index_migration::IndexMigration;
use api::models::vm_inventory::{NewVmInventory, VmInventory};
use api::repos::index_migration_repo::IndexMigrationRepo;
use api::repos::{CatalogLifecycleTargetIdentity, RepoError, TenantRepo, VmInventoryRepo};
use api::secrets::mock::MockNodeSecretManager;
use api::secrets::NodeSecretManager;
use api::services::alerting::{AlertSeverity, MockAlertService};
use api::services::discovery::DiscoveryService;
use api::services::flapjack_node::flapjack_index_uid;
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
    queued_update_metadata_failures: Mutex<VecDeque<bool>>,
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

    fn get_latest(&self) -> Option<IndexMigration> {
        self.rows
            .lock()
            .unwrap()
            .iter()
            .max_by_key(|row| row.started_at)
            .cloned()
    }

    fn seed(
        &self,
        index_name: &str,
        customer_id: Uuid,
        source_vm_id: Uuid,
        dest_vm_id: Uuid,
        status: &str,
        captured_identity: &CatalogLifecycleTargetIdentity,
    ) -> IndexMigration {
        let mut row = IndexMigration {
            id: Uuid::new_v4(),
            index_name: index_name.to_string(),
            customer_id,
            source_vm_id,
            dest_vm_id,
            status: status.to_string(),
            requested_by: "test".to_string(),
            started_at: Utc::now(),
            completed_at: None,
            error: None,
            metadata: serde_json::json!({}),
        };
        row.metadata = row.metadata_with_intent_target_identity(captured_identity);
        self.rows.lock().unwrap().push(row.clone());
        row
    }

    fn fail_second_update_metadata(&self) {
        let mut queued = self.queued_update_metadata_failures.lock().unwrap();
        queued.push_back(false);
        queued.push_back(true);
    }

    fn fail_third_update_metadata(&self) {
        let mut queued = self.queued_update_metadata_failures.lock().unwrap();
        queued.push_back(false);
        queued.push_back(false);
        queued.push_back(true);
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

    async fn update_metadata(
        &self,
        id: Uuid,
        metadata: serde_json::Value,
    ) -> Result<(), RepoError> {
        if self
            .queued_update_metadata_failures
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or(false)
        {
            return Err(RepoError::Other(
                "injected update_metadata failure".to_string(),
            ));
        }

        let mut rows = self.rows.lock().unwrap();
        if let Some(row) = rows.iter_mut().find(|r| r.id == id) {
            row.metadata = metadata;
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
        rows.sort_by_key(|row| std::cmp::Reverse(row.started_at));
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
    tenant_repo: Arc<crate::common::MockTenantRepo>,
    vm_repo: Arc<crate::common::MockVmInventoryRepo>,
    migration_repo: Arc<MockIndexMigrationRepo>,
    alert_service: Arc<MockAlertService>,
    discovery_service: Arc<DiscoveryService>,
    http_client: Arc<MockMigrationHttpClient>,
    node_secret_manager: Arc<MockNodeSecretManager>,
    customer_id: Uuid,
    deployment_id: Uuid,
    index_name: String,
    physical_uid: String,
    source_vm: VmInventory,
    dest_vm: VmInventory,
    source_key: String,
    dest_key: String,
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

fn enqueue_source_ops(http_client: &MockMigrationHttpClient, index_name: &str, current_seq: i64) {
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: serde_json::json!({
            "tenant_id": index_name,
            "ops": [],
            "current_seq": current_seq
        })
        .to_string(),
    }));
}

fn queue_successful_migration_http(
    http_client: &MockMigrationHttpClient,
    index_name: &str,
    source_seq: i64,
    near_zero_dest_seq: i64,
) {
    enqueue_source_ops(http_client, index_name, source_seq);
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
    enqueue_source_ops(http_client, index_name, 100);
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
    let tenant_repo = crate::common::mock_tenant_repo();
    let vm_repo = crate::common::mock_vm_inventory_repo();
    let migration_repo = Arc::new(MockIndexMigrationRepo::default());
    let alert_service = crate::common::mock_alert_service();
    let discovery_service = Arc::new(DiscoveryService::with_ttl(
        tenant_repo.clone(),
        vm_repo.clone(),
        3600,
    ));
    let http_client = Arc::new(MockMigrationHttpClient::default());
    let node_secret_manager = crate::common::mock_node_secret_manager();

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

    let source_key = node_secret_manager
        .create_node_api_key(source_vm.node_secret_id(), &source_vm.region)
        .await
        .expect("seed source vm key");
    let dest_key = node_secret_manager
        .create_node_api_key(dest_vm.node_secret_id(), &dest_vm.region)
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
        deployment_id,
        index_name: index_name.to_string(),
        physical_uid: flapjack_index_uid(customer_id, index_name),
        source_vm,
        dest_vm,
        source_key,
        dest_key,
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

fn fixture_migrating_identity(fixture: &MigrationFixture) -> CatalogLifecycleTargetIdentity {
    CatalogLifecycleTargetIdentity {
        deployment_id: fixture.deployment_id,
        vm_id: Some(fixture.source_vm.id),
        tier: "migrating".to_string(),
        cold_snapshot_id: None,
        service_type: "flapjack".to_string(),
    }
}

fn source_resume_request(fixture: &MigrationFixture) -> MigrationHttpRequest {
    MigrationHttpRequest {
        method: Method::POST,
        url: format!(
            "{}/internal/resume/{}",
            fixture.source_vm.flapjack_url, fixture.physical_uid
        ),
        json_body: None,
        headers: auth_headers(&fixture.source_key),
    }
}

fn destination_delete_request(fixture: &MigrationFixture) -> MigrationHttpRequest {
    MigrationHttpRequest {
        method: Method::DELETE,
        url: format!(
            "{}/1/indexes/{}",
            fixture.dest_vm.flapjack_url, fixture.physical_uid
        ),
        json_body: None,
        headers: auth_headers(&fixture.dest_key),
    }
}

fn auth_headers(api_key: &str) -> std::collections::HashMap<String, String> {
    std::collections::HashMap::from([
        (INTERNAL_AUTH_HEADER.to_string(), api_key.to_string()),
        (
            INTERNAL_APP_ID_HEADER.to_string(),
            REPLICATION_APP_ID.to_string(),
        ),
    ])
}

async fn assert_rolled_back_to_source(fixture: &MigrationFixture, migration_id: Uuid) {
    let tenant = fixture
        .tenant_repo
        .find_raw(fixture.customer_id, &fixture.index_name)
        .await
        .expect("find raw should succeed")
        .expect("tenant should exist");
    assert_eq!(tenant.vm_id, Some(fixture.source_vm.id));
    assert_eq!(tenant.tier, "active");
    assert_eq!(tenant.deployment_id, fixture.deployment_id);
    assert_eq!(tenant.cold_snapshot_id, None);
    assert_eq!(tenant.service_type, "flapjack");

    let row = fixture
        .migration_repo
        .get(migration_id)
        .expect("migration row should exist");
    assert_eq!(row.status, "rolled_back");
    assert_eq!(row.error, None);
    assert_eq!(row.source_vm_id, fixture.source_vm.id);
    assert_eq!(row.dest_vm_id, fixture.dest_vm.id);
    assert_eq!(
        row.intent_target_identity().unwrap(),
        fixture_migrating_identity(fixture)
    );
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
        crate::common::mock_tenant_repo(),
        crate::common::mock_vm_inventory_repo(),
        repo as Arc<dyn IndexMigrationRepo + Send + Sync>,
        crate::common::mock_alert_service(),
        crate::common::mock_discovery_service(),
        crate::common::mock_node_secret_manager(),
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
    queue_successful_migration_http(&fixture.http_client, &fixture.physical_uid, 100, 95);

    fixture
        .service
        .execute(fixture_request(&fixture))
        .await
        .expect("migration execute should succeed");

    let requests = fixture.http_client.recorded_requests();
    let source_key = fixture
        .node_secret_manager
        .get_secret(fixture.source_vm.node_secret_id())
        .expect("source key should be seeded");
    let dest_key = fixture
        .node_secret_manager
        .get_secret(fixture.dest_vm.node_secret_id())
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
            "tenant_id": fixture.physical_uid,
            "ops": []
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
    queue_successful_migration_http(&fixture.http_client, &fixture.physical_uid, 100, 95);

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
                    fixture.source_vm.flapjack_url, fixture.physical_uid
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
    queue_successful_migration_http(&fixture.http_client, &fixture.physical_uid, 100, 95);

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
    queue_successful_migration_http(&fixture.http_client, &fixture.physical_uid, 100, 95);

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
    queue_successful_migration_http(&fixture.http_client, &fixture.physical_uid, 100, 95);

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
                    fixture.dest_vm.flapjack_url, fixture.physical_uid
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
    queue_successful_migration_http(&fixture.http_client, &fixture.physical_uid, 100, 95);

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
    queue_successful_migration_http(&fixture.http_client, &fixture.physical_uid, 100, 95);

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
    let migration = fixture.migration_repo.seed(
        &fixture.index_name,
        fixture.customer_id,
        fixture.source_vm.id,
        fixture.dest_vm.id,
        "cutting_over",
        &fixture_migrating_identity(&fixture),
    );
    fixture
        .tenant_repo
        .set_tier(fixture.customer_id, &fixture.index_name, "migrating")
        .await
        .expect("set migrating tier");

    let pre_rollback = fixture
        .discovery_service
        .discover(fixture.customer_id, &fixture.index_name)
        .await
        .expect("discover before rollback should succeed");
    assert_eq!(pre_rollback.vm, fixture.source_vm.hostname);

    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: "{}".to_string(),
        }));

    fixture
        .service
        .rollback(migration.id)
        .await
        .expect("rollback should succeed");

    assert_eq!(
        fixture.http_client.recorded_requests(),
        vec![source_resume_request(&fixture)]
    );
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

    assert_rolled_back_to_source(&fixture, migration.id).await;
}

#[tokio::test]
async fn migration_rollback_uses_captured_identity_instead_of_current_target() {
    let fixture = setup_fixture("products").await;
    let migration = fixture.migration_repo.seed(
        &fixture.index_name,
        fixture.customer_id,
        fixture.source_vm.id,
        fixture.dest_vm.id,
        "cutting_over",
        &fixture_migrating_identity(&fixture),
    );
    let captured_identity = CatalogLifecycleTargetIdentity {
        deployment_id: fixture.deployment_id,
        vm_id: Some(fixture.source_vm.id),
        tier: "migrating".to_string(),
        cold_snapshot_id: None,
        service_type: "flapjack".to_string(),
    };
    fixture
        .migration_repo
        .update_metadata(
            migration.id,
            migration.metadata_with_intent_target_identity(&captured_identity),
        )
        .await
        .expect("persist captured identity metadata");
    let newer_vm = fixture
        .vm_repo
        .create(vm_seed(
            "us-east-1",
            "vm-newer.flapjack.foo",
            "http://newer-vm.test",
        ))
        .await
        .expect("seed newer owner vm");
    fixture
        .tenant_repo
        .set_vm_id(fixture.customer_id, &fixture.index_name, newer_vm.id)
        .await
        .expect("drift target vm");
    fixture
        .tenant_repo
        .set_tier(fixture.customer_id, &fixture.index_name, "pinned")
        .await
        .expect("drift target tier");
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: "{}".to_string(),
        }));

    let err = fixture
        .service
        .rollback(migration.id)
        .await
        .expect_err("rollback must reject a newer current owner");

    assert!(
        matches!(err, MigrationError::DestinationChanged),
        "rollback should use the captured identity and reject current-target drift, got {err:?}"
    );
    let requests = fixture.http_client.recorded_requests();
    assert_eq!(
        requests,
        vec![source_resume_request(&fixture)],
        "rollback must resume source before rejecting stale catalog publication"
    );
    let tenant = fixture
        .tenant_repo
        .find_raw(fixture.customer_id, &fixture.index_name)
        .await
        .expect("find raw should succeed")
        .expect("tenant should exist");
    assert_eq!(tenant.vm_id, Some(newer_vm.id));
    assert_eq!(tenant.tier, "pinned");
}

#[tokio::test]
async fn migration_finalize_set_vm_id_failure_keeps_source_routing() {
    let fixture = setup_fixture("products").await;
    queue_successful_migration_http(&fixture.http_client, &fixture.physical_uid, 100, 95);
    fixture.tenant_repo.fail_next_set_vm_id();
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

    let cached_before = fixture
        .discovery_service
        .discover(fixture.customer_id, &fixture.index_name)
        .await
        .expect("pre-finalize discovery should cache source routing");
    assert_eq!(cached_before.vm, fixture.source_vm.hostname);

    let err = fixture
        .service
        .execute(fixture_request(&fixture))
        .await
        .expect_err("finalize should fail when tenant vm pointer write fails");
    assert!(
        matches!(&err, MigrationError::Repo(message) if message.contains("injected set_vm_id failure")),
        "unexpected error: {err:?}"
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
        .expect("discovery should still resolve source after pointer failure");
    assert_eq!(discovered.vm, fixture.source_vm.hostname);

    let requests = fixture.http_client.recorded_requests();
    assert!(
        !requests.iter().any(|request| {
            request.method == Method::POST
                && request.url
                    == format!(
                        "{}/internal/resume/{}",
                        fixture.dest_vm.flapjack_url, fixture.physical_uid
                    )
        }),
        "destination writes must not be admitted when the pointer update fails"
    );
    assert!(
        requests.iter().any(|request| {
            request.method == Method::POST
                && request.url
                    == format!(
                        "{}/internal/resume/{}",
                        fixture.source_vm.flapjack_url, fixture.physical_uid
                    )
        }),
        "source writes must be resumed after a pre-destination pointer failure"
    );
}

#[tokio::test]
async fn migration_finalize_fence_write_failure_after_invalidation_rolls_back_future_routing() {
    let fixture = setup_fixture("products").await;
    queue_successful_migration_http(&fixture.http_client, &fixture.physical_uid, 100, 95);
    fixture.migration_repo.fail_second_update_metadata();
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

    let cached_before = fixture
        .discovery_service
        .discover(fixture.customer_id, &fixture.index_name)
        .await
        .expect("pre-finalize discovery should cache source routing");
    assert_eq!(cached_before.vm, fixture.source_vm.hostname);

    let err = fixture
        .service
        .execute(fixture_request(&fixture))
        .await
        .expect_err("finalize should fail when durable cutover fence cannot be closed");
    assert!(
        matches!(&err, MigrationError::Repo(message) if message.contains("injected update_metadata failure")),
        "unexpected error: {err:?}"
    );

    let tenant = fixture
        .tenant_repo
        .find_raw(fixture.customer_id, &fixture.index_name)
        .await
        .expect("find raw should succeed")
        .expect("tenant should exist");
    assert_eq!(
        tenant.vm_id,
        Some(fixture.source_vm.id),
        "future routing must roll back while destination writes were never admitted"
    );
    assert_eq!(tenant.tier, "active");

    let discovered = fixture
        .discovery_service
        .discover(fixture.customer_id, &fixture.index_name)
        .await
        .expect("discovery should resolve source after fence-write rollback");
    assert_eq!(discovered.vm, fixture.source_vm.hostname);

    let requests = fixture.http_client.recorded_requests();
    assert!(
        !requests.iter().any(|request| {
            request.method == Method::POST
                && request.url
                    == format!(
                        "{}/internal/resume/{}",
                        fixture.dest_vm.flapjack_url, fixture.physical_uid
                    )
        }),
        "destination writes must not be admitted until the durable cutover fence is closed"
    );
    assert!(
        requests.iter().any(|request| {
            request.method == Method::DELETE
                && request.url
                    == format!(
                        "{}/1/indexes/{}",
                        fixture.dest_vm.flapjack_url, fixture.physical_uid
                    )
        }),
        "pre-admission rollback should clean up the destination copy"
    );
}

#[tokio::test]
async fn migration_failure_after_destination_resume_preserves_destination_routing() {
    let fixture = setup_fixture("products").await;
    queue_successful_migration_http(&fixture.http_client, &fixture.physical_uid, 100, 95);
    fixture.tenant_repo.fail_next_set_tier_to_active();
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
        .expect_err("final active-tier write should fail after destination resume");
    assert!(matches!(err, MigrationError::Repo(_)));

    let tenant = fixture
        .tenant_repo
        .find_raw(fixture.customer_id, &fixture.index_name)
        .await
        .expect("find raw should succeed")
        .expect("tenant should exist");
    assert_eq!(
        tenant.vm_id,
        Some(fixture.dest_vm.id),
        "post-cutover failure must preserve destination ownership"
    );
    assert_eq!(tenant.tier, "active");

    let discovered = fixture
        .discovery_service
        .discover(fixture.customer_id, &fixture.index_name)
        .await
        .expect("discover after post-cutover failure should succeed");
    assert_eq!(discovered.vm, fixture.dest_vm.hostname);

    let requests = fixture.http_client.recorded_requests();
    let destination_resume_index = requests
        .iter()
        .position(|request| {
            request.method == Method::POST
                && request.url
                    == format!(
                        "{}/internal/resume/{}",
                        fixture.dest_vm.flapjack_url, fixture.physical_uid
                    )
        })
        .expect("destination resume request should be recorded");
    assert!(
        requests[destination_resume_index + 1..]
            .iter()
            .all(|request| {
                request.url
                    != format!(
                        "{}/internal/resume/{}",
                        fixture.source_vm.flapjack_url, fixture.physical_uid
                    )
                    && request.url
                        != format!(
                            "{}/1/indexes/{}",
                            fixture.dest_vm.flapjack_url, fixture.physical_uid
                        )
            }),
        "post-cutover recovery must not resume stale source or delete destination"
    );

    let migration = fixture
        .migration_repo
        .list_recent(1)
        .await
        .expect("list recent should succeed");
    assert_eq!(migration.len(), 1);
    assert_eq!(migration[0].status, "failed");
    assert!(migration[0]
        .error
        .as_deref()
        .is_some_and(|message| message.contains("injected set_tier active failure")));
}

#[tokio::test]
async fn migration_completed_rollback_after_destination_resume_is_forward_only() {
    let fixture = setup_fixture("products").await;
    queue_successful_migration_http(&fixture.http_client, &fixture.physical_uid, 100, 95);
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

    let err = fixture
        .service
        .rollback(migration_id)
        .await
        .expect_err("completed migration with destination writes admitted must not roll back");
    assert!(
        matches!(&err, MigrationError::Protocol(message) if message.contains("source rollback fence closed")),
        "unexpected rollback error: {err:?}"
    );

    let tenant = fixture
        .tenant_repo
        .find_raw(fixture.customer_id, &fixture.index_name)
        .await
        .expect("find raw should succeed")
        .expect("tenant should exist");
    assert_eq!(tenant.vm_id, Some(fixture.dest_vm.id));

    let discovered = fixture
        .discovery_service
        .discover(fixture.customer_id, &fixture.index_name)
        .await
        .expect("discover after rejected rollback should succeed");
    assert_eq!(discovered.vm, fixture.dest_vm.hostname);

    let requests = fixture.http_client.recorded_requests();
    assert_eq!(
        requests.len(),
        before_rollback_requests,
        "rejected completed rollback must not issue source resume"
    );
    let migration = fixture
        .migration_repo
        .get(migration_id)
        .expect("migration row should exist after rejected rollback");
    assert_eq!(migration.status, "completed");
    assert_eq!(migration.metadata["source_restore_allowed"], false);
}

#[tokio::test]
async fn migration_rollback_cutting_over_resumes_source_index() {
    let fixture = setup_fixture("products").await;
    let migration = fixture.migration_repo.seed(
        &fixture.index_name,
        fixture.customer_id,
        fixture.source_vm.id,
        fixture.dest_vm.id,
        "cutting_over",
        &fixture_migrating_identity(&fixture),
    );
    fixture
        .tenant_repo
        .set_tier(fixture.customer_id, &fixture.index_name, "migrating")
        .await
        .expect("seed migrating tier");

    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: "{}".to_string(),
        }));

    fixture
        .service
        .rollback(migration.id)
        .await
        .expect("rollback should succeed");

    assert_eq!(
        fixture.http_client.recorded_requests(),
        vec![source_resume_request(&fixture)],
        "cutting-over rollback must only resume source writes"
    );
    assert_rolled_back_to_source(&fixture, migration.id).await;
}

#[tokio::test]
async fn migration_rollback_completed_with_open_source_restore_resumes_source_index() {
    let fixture = setup_fixture("products").await;
    let migration = fixture.migration_repo.seed(
        &fixture.index_name,
        fixture.customer_id,
        fixture.source_vm.id,
        fixture.dest_vm.id,
        "cutting_over",
        &fixture_migrating_identity(&fixture),
    );
    fixture
        .migration_repo
        .set_completed(migration.id)
        .await
        .expect("mark migration completed");
    let completed = fixture
        .migration_repo
        .get(migration.id)
        .expect("completed migration row exists");
    fixture
        .migration_repo
        .update_metadata(
            migration.id,
            completed.metadata_with_source_restore_allowed(true),
        )
        .await
        .expect("open source restore fence");
    fixture
        .tenant_repo
        .set_tier(fixture.customer_id, &fixture.index_name, "migrating")
        .await
        .expect("seed operation-owned migrating tier");
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: "{}".to_string(),
        }));

    fixture
        .service
        .rollback(migration.id)
        .await
        .expect("completed rollback should succeed while source restore fence is open");

    assert_eq!(
        fixture.http_client.recorded_requests(),
        vec![source_resume_request(&fixture)],
        "completed rollback with an open source restore fence must only resume source writes"
    );
    assert_rolled_back_to_source(&fixture, migration.id).await;
}

#[tokio::test]
async fn migration_rollback_source_restore_fence_blocks_remote_work() {
    let fixture = setup_fixture("products").await;
    let migration = fixture.migration_repo.seed(
        &fixture.index_name,
        fixture.customer_id,
        fixture.source_vm.id,
        fixture.dest_vm.id,
        "cutting_over",
        &fixture_migrating_identity(&fixture),
    );
    fixture
        .migration_repo
        .update_metadata(
            migration.id,
            migration.metadata_with_source_restore_allowed(false),
        )
        .await
        .expect("close source restore fence");
    fixture
        .tenant_repo
        .set_tier(fixture.customer_id, &fixture.index_name, "migrating")
        .await
        .expect("seed migrating tier");

    let err = fixture
        .service
        .rollback(migration.id)
        .await
        .expect_err("closed source restore fence must reject rollback");

    assert!(
        matches!(&err, MigrationError::Protocol(message) if message.contains("source rollback fence closed")),
        "unexpected rollback error: {err:?}"
    );
    assert!(
        fixture.http_client.recorded_requests().is_empty(),
        "closed source restore fence must reject before remote source resume"
    );
    let row = fixture
        .migration_repo
        .get(migration.id)
        .expect("migration row should remain");
    assert_eq!(row.status, "cutting_over");
    assert_eq!(row.metadata["source_restore_allowed"], false);
}

#[tokio::test]
async fn migration_rejects_same_source_and_destination_vm() {
    let fixture = setup_fixture("products").await;
    queue_successful_migration_http(&fixture.http_client, &fixture.physical_uid, 100, 95);

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
    queue_successful_migration_http(&fixture.http_client, &fixture.physical_uid, 100, 95);

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
    enqueue_source_ops(&fixture.http_client, &fixture.physical_uid, 100);
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
            body: oplog_metric(&fixture.physical_uid, 100),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.physical_uid, 95),
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
            body: oplog_metric(&fixture.physical_uid, 100),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.physical_uid, 100),
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
                        fixture.source_vm.flapjack_url, fixture.physical_uid
                    )
        }),
        "failure recovery must resume source writes"
    );
}

#[tokio::test]
async fn migration_destination_resume_failure_with_fence_reopen_error_restores_source_routing() {
    let fixture = setup_fixture("products").await;
    fixture.migration_repo.fail_third_update_metadata();

    enqueue_source_ops(&fixture.http_client, &fixture.physical_uid, 100);
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
            body: oplog_metric(&fixture.physical_uid, 100),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.physical_uid, 95),
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
            body: oplog_metric(&fixture.physical_uid, 100),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.physical_uid, 100),
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
    assert_eq!(tenant.vm_id, Some(fixture.source_vm.id));
    assert_eq!(tenant.tier, "active");

    let discovered = fixture
        .discovery_service
        .discover(fixture.customer_id, &fixture.index_name)
        .await
        .expect("discover should resolve source after failed fence reopen");
    assert_eq!(discovered.vm, fixture.source_vm.hostname);

    let migration = fixture
        .migration_repo
        .get_latest()
        .expect("migration row should exist after execute failure");
    assert_eq!(
        migration.metadata["source_restore_allowed"],
        serde_json::Value::Bool(false),
        "second metadata write should fail and leave the durable fence closed"
    );

    let requests = fixture.http_client.recorded_requests();
    assert!(
        requests.iter().any(|request| {
            request.method == Method::POST
                && request.url
                    == format!(
                        "{}/internal/resume/{}",
                        fixture.source_vm.flapjack_url, fixture.physical_uid
                    )
        }),
        "pre-admission failure must still resume the source index"
    );
    assert!(
        requests.iter().any(|request| {
            request.method == Method::DELETE
                && request.url
                    == format!(
                        "{}/1/indexes/{}",
                        fixture.dest_vm.flapjack_url, fixture.physical_uid
                    )
        }),
        "pre-admission failure must still clean up the destination index"
    );
}

#[tokio::test]
async fn migration_failure_recovery_restores_routing_even_if_source_resume_fails() {
    let fixture = setup_fixture("products").await;

    enqueue_source_ops(&fixture.http_client, &fixture.physical_uid, 100);
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
            body: oplog_metric(&fixture.physical_uid, 100),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.physical_uid, 95),
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
            body: oplog_metric(&fixture.physical_uid, 100),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.physical_uid, 100),
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

    queue_replication_lag_never_converges_http(&fixture.http_client, &fixture.physical_uid, 20);

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

    queue_replication_lag_never_converges_http(&fixture.http_client, &fixture.physical_uid, 20);

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
                        fixture.dest_vm.flapjack_url, fixture.physical_uid
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

    enqueue_source_ops(&fixture.http_client, &fixture.physical_uid, 100);
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
            body: oplog_metric(&fixture.physical_uid, 100),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.physical_uid, 80),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.physical_uid, 100),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.physical_uid, 95),
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
            body: oplog_metric(&fixture.physical_uid, 100),
        }));
    fixture
        .http_client
        .enqueue_response(Ok(MigrationHttpResponse {
            status: 200,
            body: oplog_metric(&fixture.physical_uid, 100),
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
    fixture
        .migration_repo
        .update_metadata(
            row.id,
            row.metadata_with_intent_target_identity(&fixture_migrating_identity(&fixture)),
        )
        .await
        .expect("set captured identity metadata");

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

    assert_eq!(
        fixture.http_client.recorded_requests(),
        vec![destination_delete_request(&fixture)],
        "replicating rollback must only delete the destination replica"
    );

    assert_rolled_back_to_source(&fixture, row.id).await;
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
