// Each test binary compiles this support module independently, so helpers
// that are used by one test file appear unused in others.
#![allow(dead_code)]

use std::sync::Arc;

use api::models::vm_inventory::{NewVmInventory, VmInventory};
use api::repos::{TenantRepo, VmInventoryRepo};
use api::secrets::{mock::MockNodeSecretManager, NodeSecretManager};
use api::services::discovery::DiscoveryService;
use api::services::engine_index_identity_observer::OBSERVED_UPSTREAM_AUTH_HEADER_PATTERN;
use api::services::flapjack_node::FLAPJACK_APP_ID_VALUE;
use api::services::migration::{MigrationHttpResponse, MigrationService};
use api::services::replication_error::{
    INTERNAL_APP_ID_HEADER, INTERNAL_AUTH_HEADER, REPLICATION_APP_ID,
};
use serde::ser::SerializeMap;
use serde::{Serialize, Serializer};
use serde_json::{json, Value};
use uuid::Uuid;

use crate::common::flapjack_proxy_test_support::test_flapjack_uid;
use crate::common::{
    mock_alert_service, mock_index_migration_repo, mock_repo, mock_tenant_repo,
    mock_vm_inventory_repo, MockReplicationHttpClient, TestStateBuilder,
};

const REGION: &str = "us-east-1";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ExpectedUpstreamKind {
    PhysicalUid,
    CatalogOnly,
}

#[derive(Debug, Clone, Copy, Serialize)]
pub struct CallerExpectation {
    pub caller_id: &'static str,
    pub owner_path: &'static str,
    pub expected_upstream_kind: ExpectedUpstreamKind,
    pub auth_secret_owner: &'static str,
    pub expected_upstream_path: Option<&'static str>,
    pub expected_upstream_headers: ExpectedUpstreamHeaders,
    pub same_logical_name_isolation: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct ExpectedUpstreamHeaders {
    api_key: Option<&'static str>,
    application_id: Option<&'static str>,
}

impl Serialize for ExpectedUpstreamHeaders {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let field_count =
            usize::from(self.api_key.is_some()) + usize::from(self.application_id.is_some());
        let mut headers = serializer.serialize_map(Some(field_count))?;
        if let Some(api_key) = self.api_key {
            headers.serialize_entry(INTERNAL_AUTH_HEADER, api_key)?;
        }
        if let Some(application_id) = self.application_id {
            headers.serialize_entry(INTERNAL_APP_ID_HEADER, application_id)?;
        }
        headers.end()
    }
}

#[derive(Serialize)]
struct CallerInventory {
    expected_caller_count: usize,
    callers: &'static [CallerExpectation],
}

const ENGINE_INDEX_IDENTITY_CALLERS: &[CallerExpectation] = &[
    physical_caller(
        "migration.protocol.start_replication",
        "infra/api/src/services/migration/protocol.rs::MigrationService::start_replication",
        "/internal/replicate",
        REPLICATION_APP_ID,
    ),
    physical_caller(
        "migration.protocol.pause_index",
        "infra/api/src/services/migration/protocol.rs::MigrationService::pause_index",
        "/internal/pause/{physical_uid}",
        REPLICATION_APP_ID,
    ),
    physical_caller(
        "migration.protocol.resume_index",
        "infra/api/src/services/migration/protocol.rs::MigrationService::resume_index",
        "/internal/resume/{physical_uid}",
        REPLICATION_APP_ID,
    ),
    physical_caller(
        "migration.protocol.delete_index",
        "infra/api/src/services/migration/protocol.rs::MigrationService::delete_index",
        "/1/indexes/{physical_uid}",
        REPLICATION_APP_ID,
    ),
    physical_caller(
        "migration.recovery.rollback_replicating",
        "infra/api/src/services/migration/recovery.rs::MigrationService::rollback_replicating",
        "/1/indexes/{physical_uid}",
        REPLICATION_APP_ID,
    ),
    physical_caller(
        "migration.recovery.recover_source_on_failure",
        "infra/api/src/services/migration/recovery.rs::MigrationService::recover_source_on_failure",
        "/1/indexes/{physical_uid}",
        REPLICATION_APP_ID,
    ),
    physical_caller(
        "migration.replication.fetch_oplog_seq",
        "infra/api/src/services/migration/replication.rs::MigrationService::fetch_oplog_seq",
        "/metrics",
        REPLICATION_APP_ID,
    ),
    physical_caller(
        "migration.replication.build_auth_headers",
        "infra/api/src/services/migration/replication.rs::MigrationService::build_auth_headers",
        "/internal/resume/{physical_uid}",
        REPLICATION_APP_ID,
    ),
    catalog_caller(
        "routes.indexes.lifecycle.create_replica",
        "infra/api/src/routes/indexes/lifecycle.rs::create_replica",
    ),
    catalog_caller(
        "routes.indexes.lifecycle.list_replicas",
        "infra/api/src/routes/indexes/lifecycle.rs::list_replicas",
    ),
    catalog_caller(
        "routes.indexes.lifecycle.delete_replica",
        "infra/api/src/routes/indexes/lifecycle.rs::delete_replica",
    ),
    physical_caller(
        "routes.indexes.lifecycle.delete_index",
        "infra/api/src/routes/indexes/lifecycle.rs::delete_index",
        "/1/indexes/{physical_uid}",
        FLAPJACK_APP_ID_VALUE,
    ),
    physical_caller(
        "routes.indexes.index_metrics_route.get_index_metrics",
        "infra/api/src/routes/indexes/index_metrics_route.rs::get_index_metrics",
        "/metrics",
        FLAPJACK_APP_ID_VALUE,
    ),
    catalog_caller(
        "routes.admin.migrations.validate_migration_request",
        "infra/api/src/routes/admin/migrations.rs::validate_migration_request",
    ),
    physical_caller(
        "routes.admin.migrations.execute_migration",
        "infra/api/src/routes/admin/migrations.rs::execute_migration",
        "/internal/replicate",
        REPLICATION_APP_ID,
    ),
    catalog_caller(
        "routes.admin.migrations.list_migrations",
        "infra/api/src/routes/admin/migrations.rs::list_migrations",
    ),
    catalog_caller(
        "routes.admin.replicas.list_replicas",
        "infra/api/src/routes/admin/replicas.rs::list_replicas",
    ),
];

pub fn engine_index_identity_callers() -> &'static [CallerExpectation] {
    ENGINE_INDEX_IDENTITY_CALLERS
}

pub fn engine_index_identity_inventory_json() -> Value {
    serde_json::to_value(CallerInventory {
        expected_caller_count: engine_index_identity_callers().len(),
        callers: engine_index_identity_callers(),
    })
    .expect("caller inventory should serialize")
}

const fn physical_caller(
    caller_id: &'static str,
    owner_path: &'static str,
    expected_upstream_path: &'static str,
    expected_application_id: &'static str,
) -> CallerExpectation {
    CallerExpectation {
        caller_id,
        owner_path,
        expected_upstream_kind: ExpectedUpstreamKind::PhysicalUid,
        auth_secret_owner: "VmInventory::node_secret_id",
        expected_upstream_path: Some(expected_upstream_path),
        expected_upstream_headers: ExpectedUpstreamHeaders {
            api_key: Some(OBSERVED_UPSTREAM_AUTH_HEADER_PATTERN),
            application_id: Some(expected_application_id),
        },
        same_logical_name_isolation: true,
    }
}

const fn catalog_caller(caller_id: &'static str, owner_path: &'static str) -> CallerExpectation {
    CallerExpectation {
        caller_id,
        owner_path,
        expected_upstream_kind: ExpectedUpstreamKind::CatalogOnly,
        auth_secret_owner: "no direct Flapjack request",
        expected_upstream_path: None,
        expected_upstream_headers: ExpectedUpstreamHeaders {
            api_key: None,
            application_id: None,
        },
        same_logical_name_isolation: false,
    }
}

pub fn assert_flapjack_request_sequence(
    requests: &[api::services::flapjack_proxy::FlapjackHttpRequest],
    expected: &[ExpectedFlapjackRequest],
) {
    assert_eq!(
        requests.len(),
        expected.len(),
        "recorded Flapjack requests: {requests:#?}"
    );
    for (request, expected) in requests.iter().zip(expected) {
        expected.assert_matches(request);
    }
}

pub struct ExpectedFlapjackRequest {
    method: reqwest::Method,
    url: String,
    api_key: String,
    json_body: Option<Value>,
}

impl ExpectedFlapjackRequest {
    pub fn get(url: String, api_key: &str) -> Self {
        Self::new(reqwest::Method::GET, url, api_key, None)
    }

    pub fn delete(url: String, api_key: &str) -> Self {
        Self::new(reqwest::Method::DELETE, url, api_key, None)
    }

    fn new(method: reqwest::Method, url: String, api_key: &str, json_body: Option<Value>) -> Self {
        Self {
            method,
            url,
            api_key: api_key.to_string(),
            json_body,
        }
    }

    fn assert_matches(&self, request: &api::services::flapjack_proxy::FlapjackHttpRequest) {
        assert_eq!(request.method, self.method);
        assert_eq!(request.url, self.url);
        assert_eq!(request.api_key, self.api_key);
        assert_eq!(request.json_body, self.json_body);
    }
}

pub fn assert_migration_request_sequence(
    requests: &[api::services::migration::MigrationHttpRequest],
    expected: &[ExpectedMigrationRequest],
) {
    assert_eq!(
        requests.len(),
        expected.len(),
        "recorded migration requests: {requests:#?}"
    );
    for (request, expected) in requests.iter().zip(expected) {
        expected.assert_matches(request);
    }
}

pub struct ExpectedMigrationRequest {
    method: reqwest::Method,
    url: String,
    json_body: Option<Value>,
    auth_key: Option<String>,
}

impl ExpectedMigrationRequest {
    pub fn get(url: String, auth_key: &str) -> Self {
        Self::new(reqwest::Method::GET, url, None, Some(auth_key))
    }

    pub fn post(url: String, json_body: Option<Value>, auth_key: &str) -> Self {
        Self::new(reqwest::Method::POST, url, json_body, Some(auth_key))
    }

    pub fn delete(url: String, auth_key: &str) -> Self {
        Self::new(reqwest::Method::DELETE, url, None, Some(auth_key))
    }

    fn new(
        method: reqwest::Method,
        url: String,
        json_body: Option<Value>,
        auth_key: Option<&str>,
    ) -> Self {
        Self {
            method,
            url,
            json_body,
            auth_key: auth_key.map(str::to_string),
        }
    }

    fn assert_matches(&self, request: &api::services::migration::MigrationHttpRequest) {
        assert_eq!(request.method, self.method);
        assert_eq!(request.url, self.url);
        assert_eq!(request.json_body, self.json_body);
        match self.auth_key.as_deref() {
            Some(auth_key) => {
                assert_eq!(
                    request
                        .headers
                        .get(INTERNAL_AUTH_HEADER)
                        .map(String::as_str),
                    Some(auth_key)
                );
                assert_eq!(
                    request
                        .headers
                        .get(INTERNAL_APP_ID_HEADER)
                        .map(String::as_str),
                    Some(api::services::replication_error::REPLICATION_APP_ID)
                );
            }
            None => assert!(
                request.headers.is_empty(),
                "expected no headers for {} {}, got {:?}",
                request.method,
                request.url,
                request.headers
            ),
        }
    }
}

pub struct MigrationFixture {
    pub service: MigrationService,
    pub tenant_repo: Arc<crate::common::MockTenantRepo>,
    pub vm_repo: Arc<crate::common::MockVmInventoryRepo>,
    pub migration_repo: Arc<crate::common::MockIndexMigrationRepo>,
    pub http_client: Arc<MockReplicationHttpClient>,
    pub customer_repo: Arc<crate::common::MockCustomerRepo>,
    pub customer_id: Uuid,
    pub physical_uid: String,
    pub source_vm: VmInventory,
    pub dest_vm: VmInventory,
    pub source_key: String,
    pub dest_key: String,
}

impl MigrationFixture {
    pub async fn setup(index_name: &str) -> Self {
        let tenant_repo = mock_tenant_repo();
        let vm_repo = mock_vm_inventory_repo();
        let migration_repo = mock_index_migration_repo();
        let customer_repo = mock_repo();
        let alert_service = mock_alert_service();
        let discovery_service =
            Arc::new(DiscoveryService::new(tenant_repo.clone(), vm_repo.clone()));
        let http_client = Arc::new(MockReplicationHttpClient::new());
        let node_secret_manager = Arc::new(MockNodeSecretManager::new());
        let customer_id = customer_repo
            .seed_verified_free_customer("Alice", "alice@example.com")
            .id;
        let deployment_id = Uuid::new_v4();
        tenant_repo
            .create(customer_id, index_name, deployment_id)
            .await
            .unwrap();

        let source_vm = vm_repo.create(vm_seed("source")).await.unwrap();
        let dest_vm = vm_repo.create(vm_seed("dest")).await.unwrap();
        tenant_repo.seed_deployment(
            deployment_id,
            REGION,
            Some(&source_vm.flapjack_url),
            "healthy",
            "running",
        );
        tenant_repo
            .set_vm_id(customer_id, index_name, source_vm.id)
            .await
            .unwrap();

        let source_key = node_secret_manager
            .create_node_api_key(source_vm.node_secret_id(), REGION)
            .await
            .unwrap();
        let dest_key = node_secret_manager
            .create_node_api_key(dest_vm.node_secret_id(), REGION)
            .await
            .unwrap();
        let service = MigrationService::with_http_client(
            tenant_repo.clone(),
            vm_repo.clone(),
            migration_repo.clone(),
            alert_service,
            discovery_service,
            node_secret_manager,
            http_client.clone(),
            3,
        );
        let physical_uid = test_flapjack_uid(customer_id, index_name);

        Self {
            service,
            tenant_repo,
            vm_repo,
            migration_repo,
            http_client,
            customer_repo,
            customer_id,
            physical_uid,
            source_vm,
            dest_vm,
            source_key,
            dest_key,
        }
    }

    pub fn state(&self) -> api::state::AppState {
        TestStateBuilder::new()
            .with_customer_repo(self.customer_repo.clone())
            .with_tenant_repo(self.tenant_repo.clone())
            .with_vm_inventory_repo(self.vm_repo.clone())
            .with_index_migration_repo(self.migration_repo.clone())
            .build()
    }

    pub fn queue_successful_protocol(&self) {
        self.queue_successful_cutover_until_destination_resume();
    }

    fn enqueue_ok(&self) {
        self.http_client.enqueue(Ok(MigrationHttpResponse {
            status: 200,
            body: "{}".to_string(),
        }));
    }

    fn enqueue_source_ops(&self) {
        self.http_client.enqueue(Ok(MigrationHttpResponse {
            status: 200,
            body: json!({
                "tenant_id": self.physical_uid,
                "ops": [],
                "current_seq": 100
            })
            .to_string(),
        }));
    }

    fn enqueue_metric(&self, seq: i64) {
        self.http_client.enqueue(Ok(MigrationHttpResponse {
            status: 200,
            body: crate::common::oplog_metric(&self.physical_uid, seq),
        }));
    }

    fn queue_successful_cutover_until_destination_resume(&self) {
        self.enqueue_source_ops();
        self.enqueue_ok();
        self.enqueue_metric(100);
        self.enqueue_metric(100);
        self.enqueue_ok();
        self.enqueue_metric(100);
        self.enqueue_metric(100);
        self.enqueue_ok();
    }

    pub fn queue_source_resume_failure_protocol(&self) {
        self.queue_destination_resume_failure();
        self.http_client.enqueue(Ok(MigrationHttpResponse {
            status: 500,
            body: "source resume failed".to_string(),
        }));
        self.enqueue_ok();
    }

    pub fn queue_replication_lag_timeout_protocol(&self, polls: usize) {
        self.enqueue_source_ops();
        self.enqueue_ok();
        for _ in 0..polls {
            self.enqueue_metric(100);
            self.enqueue_metric(50);
        }
        self.enqueue_ok();
        self.enqueue_ok();
    }

    pub fn queue_destination_cleanup_failure_after_replication_started_protocol(&self) {
        self.queue_destination_resume_failure();
        self.enqueue_ok();
        self.http_client.enqueue(Ok(MigrationHttpResponse {
            status: 401,
            body: "destination cleanup denied".to_string(),
        }));
    }

    fn queue_destination_resume_failure(&self) {
        self.enqueue_source_ops();
        self.enqueue_ok();
        self.enqueue_metric(100);
        self.enqueue_metric(100);
        self.enqueue_ok();
        self.enqueue_metric(100);
        self.enqueue_metric(100);
        self.http_client.enqueue(Ok(MigrationHttpResponse {
            status: 500,
            body: "destination resume failed".to_string(),
        }));
    }

    pub fn queue_destination_resume_failure_protocol(&self) {
        self.queue_destination_resume_failure();
        self.enqueue_ok();
        self.enqueue_ok();
    }

    pub fn successful_protocol_requests(&self) -> Vec<ExpectedMigrationRequest> {
        vec![
            ExpectedMigrationRequest::get(
                format!(
                    "{}/internal/ops?tenant_id={}&since_seq=0",
                    self.source_vm.flapjack_url,
                    urlencoding::encode(&self.physical_uid)
                ),
                &self.source_key,
            ),
            ExpectedMigrationRequest::post(
                format!("{}/internal/replicate", self.dest_vm.flapjack_url),
                Some(json!({
                    "tenant_id": self.physical_uid,
                    "ops": []
                })),
                &self.dest_key,
            ),
            ExpectedMigrationRequest::get(
                format!("{}/metrics", self.source_vm.flapjack_url),
                &self.source_key,
            ),
            ExpectedMigrationRequest::get(
                format!("{}/metrics", self.dest_vm.flapjack_url),
                &self.dest_key,
            ),
            ExpectedMigrationRequest::post(
                format!(
                    "{}/internal/pause/{}",
                    self.source_vm.flapjack_url, self.physical_uid
                ),
                None,
                &self.source_key,
            ),
            ExpectedMigrationRequest::get(
                format!("{}/metrics", self.source_vm.flapjack_url),
                &self.source_key,
            ),
            ExpectedMigrationRequest::get(
                format!("{}/metrics", self.dest_vm.flapjack_url),
                &self.dest_key,
            ),
            ExpectedMigrationRequest::post(
                format!(
                    "{}/internal/resume/{}",
                    self.dest_vm.flapjack_url, self.physical_uid
                ),
                None,
                &self.dest_key,
            ),
        ]
    }

    pub fn source_resume_request(&self) -> ExpectedMigrationRequest {
        ExpectedMigrationRequest::post(
            format!(
                "{}/internal/resume/{}",
                self.source_vm.flapjack_url, self.physical_uid
            ),
            None,
            &self.source_key,
        )
    }

    pub fn destination_delete_request(&self) -> ExpectedMigrationRequest {
        ExpectedMigrationRequest::delete(
            format!(
                "{}/1/indexes/{}",
                self.dest_vm.flapjack_url, self.physical_uid
            ),
            &self.dest_key,
        )
    }
}

fn vm_seed(name: &str) -> NewVmInventory {
    NewVmInventory {
        region: REGION.to_string(),
        provider: "aws".to_string(),
        hostname: format!("vm-{name}.flapjack.foo"),
        flapjack_url: format!("http://vm-{name}.test"),
        capacity: json!({
            "cpu_weight": 100.0,
            "mem_rss_bytes": 10_000_000_u64,
            "disk_bytes": 10_000_000_u64,
            "query_rps": 10_000.0,
            "indexing_rps": 10_000.0
        }),
    }
}
