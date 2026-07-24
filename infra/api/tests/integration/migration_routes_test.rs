use crate::common::indexes_route_test_support::response_json;
use crate::common::{create_test_jwt, mock_repo, TestStateBuilder};
use api::models::algolia_import_job::{
    AlgoliaImportCreatePlacement, AlgoliaImportJob, AlgoliaImportJobState, AlgoliaImportJobStatus,
    AlgoliaImportSource, AlgoliaImportSourceMetadata, AlgoliaImportTargetBinding,
    NewAlgoliaImportJob, NewAlgoliaReplaceImportJob,
};
use api::models::vm_inventory::NewVmInventory;
use api::models::{AlgoliaImportErrorCode, AlgoliaImportSummary};
use api::repos::algolia_import_job_repo::{
    AlgoliaImportEngineAckOutcome, AlgoliaImportResumeDeadlineClaim,
};
use api::repos::{
    AlgoliaImportCancelOutcome, AlgoliaImportDispatchAdmission,
    AlgoliaImportDispatchAdmissionOutcome, AlgoliaImportDispatchGuard,
    AlgoliaImportDispatchReplayIdentity, AlgoliaImportJobAdmissionError,
    AlgoliaImportJobListCursor, AlgoliaImportJobListPage, AlgoliaImportJobRepo,
    AlgoliaImportReconciliationClaim, AlgoliaImportReconciliationLease,
    AlgoliaImportReconciliationWriteOutcome, AlgoliaImportResumeOutcome, AlgoliaLifecycleError,
    CatalogLifecycleTargetGuard, CatalogLifecycleTargetIdentity, CustomerRepo,
    DestinationEligibilityError, DestinationEligibilitySnapshot, PgAlgoliaImportJobRepo,
    PgCustomerRepo, RepoError, VmInventoryRepo,
};
use api::routes::migration::ListAlgoliaIndexesRequest;
use api::secrets::mock::MockNodeSecretManager;
use api::secrets::NodeSecretManager;
use api::services::algolia_import::{AlgoliaImportAdmissionOutcome, AlgoliaImportAdmissionRequest};
use api::services::algolia_source::{
    AlgoliaClientError, AlgoliaClientRequest, AlgoliaClientResponse, AlgoliaIndexMetadata,
    AlgoliaSourceClient, AlgoliaSourceError, AlgoliaSourceInspectRequest, AlgoliaSourceListRequest,
    AlgoliaSourceListResponse, AlgoliaSourceLister, AlgoliaSourceService,
};
use api::services::flapjack_proxy::{FlapjackProxy, ProxyError};
use api::state::AppState;
use async_trait::async_trait;
use axum::body::Body;
use axum::http::{self, Request, StatusCode};
use axum::routing::post;
use chrono::DateTime;
use chrono::{TimeZone, Utc};
use serde_json::json;
use sqlx::PgPool;
use std::collections::VecDeque;
use std::ffi::OsString;
use std::io;
use std::sync::{Arc, Mutex};
use tower::ServiceExt;
use tracing_subscriber::prelude::*;
use uuid::Uuid;

use crate::common::flapjack_proxy_test_support::MockFlapjackHttpClient;
use crate::common::integration_helpers::tracing_test_lock;
use crate::common::support::pg_schema_harness::{
    connect_and_migrate, insert_active_customer, DbHarness,
};
use crate::common::vm_inventory_reference_guard_fixtures::insert_vm_with_id;
use api::router::build_router;
use api::services::alerting::MockAlertService;

async fn connect_and_migrate_required(schema_prefix: &str) -> DbHarness {
    connect_and_migrate(schema_prefix).await.unwrap_or_else(|| {
        panic!("DATABASE_URL must be set for Stage 4 PostgreSQL migration read tests")
    })
}

#[derive(Clone)]
struct CapturedTraceWriter(Arc<Mutex<Vec<u8>>>);

impl io::Write for CapturedTraceWriter {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buffer);
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for CapturedTraceWriter {
    type Writer = Self;

    fn make_writer(&'a self) -> Self::Writer {
        self.clone()
    }
}

async fn setup_authenticated_app() -> (axum::Router, String) {
    setup_authenticated_app_with_algolia_flag(false).await
}

async fn setup_authenticated_app_with_algolia_flag(
    algolia_migration_enabled: bool,
) -> (axum::Router, String) {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);
    let app = build_router(
        TestStateBuilder::new()
            .with_customer_repo(customer_repo)
            .with_algolia_migration_enabled(algolia_migration_enabled)
            .build(),
    );

    (app, jwt)
}

struct FakeAlgoliaSourceLister {
    responses: Mutex<VecDeque<Result<AlgoliaSourceListResponse, AlgoliaSourceError>>>,
    requests: Mutex<Vec<AlgoliaSourceListRequest>>,
    inspect_responses: Mutex<VecDeque<Result<AlgoliaImportSource, AlgoliaSourceError>>>,
    inspect_requests: Mutex<Vec<AlgoliaSourceInspectRequest>>,
}

impl FakeAlgoliaSourceLister {
    fn new(
        responses: impl IntoIterator<Item = Result<AlgoliaSourceListResponse, AlgoliaSourceError>>,
    ) -> Arc<Self> {
        Arc::new(Self {
            responses: Mutex::new(responses.into_iter().collect()),
            requests: Mutex::new(Vec::new()),
            inspect_responses: Mutex::new(VecDeque::new()),
            inspect_requests: Mutex::new(Vec::new()),
        })
    }

    fn with_inspect(
        responses: impl IntoIterator<Item = Result<AlgoliaImportSource, AlgoliaSourceError>>,
    ) -> Arc<Self> {
        Arc::new(Self {
            responses: Mutex::new(VecDeque::new()),
            requests: Mutex::new(Vec::new()),
            inspect_responses: Mutex::new(responses.into_iter().collect()),
            inspect_requests: Mutex::new(Vec::new()),
        })
    }

    fn requests(&self) -> Vec<AlgoliaSourceListRequest> {
        self.requests.lock().unwrap().clone()
    }

    fn inspect_requests(&self) -> Vec<AlgoliaSourceInspectRequest> {
        self.inspect_requests.lock().unwrap().clone()
    }
}

#[async_trait]
impl AlgoliaSourceLister for FakeAlgoliaSourceLister {
    async fn list_indexes(
        &self,
        request: AlgoliaSourceListRequest,
    ) -> Result<AlgoliaSourceListResponse, AlgoliaSourceError> {
        self.requests.lock().unwrap().push(request);
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("fake Algolia response configured")
    }

    async fn inspect_source(
        &self,
        request: AlgoliaSourceInspectRequest,
    ) -> Result<AlgoliaImportSource, AlgoliaSourceError> {
        self.inspect_requests.lock().unwrap().push(request);
        self.inspect_responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("fake Algolia inspect response configured")
    }
}

#[derive(Clone)]
struct FailingAlgoliaSourceClient {
    error: AlgoliaClientError,
}

#[async_trait]
impl AlgoliaSourceClient for FailingAlgoliaSourceClient {
    async fn list_indexes(
        &self,
        _request: AlgoliaClientRequest,
    ) -> Result<AlgoliaClientResponse, AlgoliaClientError> {
        Err(self.error)
    }
}

/// Repository wrapper that delegates every operation to a real
/// `PgAlgoliaImportJobRepo` but forces `record_dispatch_intent_committed` to
/// fail. This is the deterministic linkage-failure seam: it lets a test drive
/// the full admit → guard → engine-send path and then fail committed-linkage
/// recording *after the guard has released*, without racing a lifecycle
/// mutation against the customer row lock the guard holds (which would
/// deadlock).
struct RecordCommitFailingRepo {
    inner: PgAlgoliaImportJobRepo,
}

impl RecordCommitFailingRepo {
    fn new(inner: PgAlgoliaImportJobRepo) -> Self {
        Self { inner }
    }
}

#[async_trait]
impl AlgoliaImportJobRepo for RecordCommitFailingRepo {
    async fn record_dispatch_intent_committed(
        &self,
        _id: Uuid,
        _engine_job_id: Uuid,
    ) -> Result<AlgoliaImportJob, RepoError> {
        // The one behaviour under test: committed-linkage recording fails after
        // a valid engine 202, leaving the retained job ambiguous. The wrapper
        // never touches the row, so no mutation escapes.
        Err(RepoError::Other(
            "injected committed-linkage failure after engine acceptance".into(),
        ))
    }

    async fn create(
        &self,
        job: NewAlgoliaImportJob,
    ) -> Result<AlgoliaImportJob, AlgoliaImportJobAdmissionError> {
        self.inner.create(job).await
    }

    async fn create_replace(
        &self,
        job: NewAlgoliaReplaceImportJob,
    ) -> Result<AlgoliaImportJob, AlgoliaImportJobAdmissionError> {
        self.inner.create_replace(job).await
    }

    async fn admit_dispatch(
        &self,
        admission: AlgoliaImportDispatchAdmission,
    ) -> Result<AlgoliaImportDispatchAdmissionOutcome, AlgoliaImportJobAdmissionError> {
        self.inner.admit_dispatch(admission).await
    }

    async fn find_active_dispatch_replay(
        &self,
        customer_id: Uuid,
        idempotency_key: &str,
        identity: &AlgoliaImportDispatchReplayIdentity,
    ) -> Result<Option<AlgoliaImportJob>, AlgoliaImportJobAdmissionError> {
        self.inner
            .find_active_dispatch_replay(customer_id, idempotency_key, identity)
            .await
    }

    async fn get(&self, id: Uuid) -> Result<Option<AlgoliaImportJob>, RepoError> {
        self.inner.get(id).await
    }

    async fn get_for_customer(
        &self,
        customer_id: Uuid,
        id: Uuid,
    ) -> Result<Option<AlgoliaImportJob>, RepoError> {
        self.inner.get_for_customer(customer_id, id).await
    }

    async fn list_for_customer(
        &self,
        customer_id: Uuid,
        after: Option<AlgoliaImportJobListCursor>,
        limit: i64,
    ) -> Result<AlgoliaImportJobListPage, RepoError> {
        self.inner
            .list_for_customer(customer_id, after, limit)
            .await
    }

    async fn snapshot_replace_target_eligibility(
        &self,
        customer_id: Uuid,
        logical_target: &str,
    ) -> Result<DestinationEligibilitySnapshot, DestinationEligibilityError> {
        self.inner
            .snapshot_replace_target_eligibility(customer_id, logical_target)
            .await
    }

    async fn find_by_idempotency_key(
        &self,
        customer_id: Uuid,
        key: &str,
    ) -> Result<Option<AlgoliaImportJob>, RepoError> {
        self.inner.find_by_idempotency_key(customer_id, key).await
    }

    async fn update_persisted_state(
        &self,
        id: Uuid,
        state: AlgoliaImportJobState,
    ) -> Result<AlgoliaImportJob, RepoError> {
        self.inner.update_persisted_state(id, state).await
    }

    async fn acquire_dispatch_guard(
        &self,
        id: Uuid,
    ) -> Result<AlgoliaImportDispatchGuard, RepoError> {
        self.inner.acquire_dispatch_guard(id).await
    }

    async fn release_dispatch_guard(
        &self,
        guard: AlgoliaImportDispatchGuard,
    ) -> Result<(), RepoError> {
        self.inner.release_dispatch_guard(guard).await
    }

    async fn record_no_dispatch_failure(
        &self,
        id: Uuid,
        error_code: AlgoliaImportErrorCode,
        error_message: Option<&str>,
    ) -> Result<AlgoliaImportJob, RepoError> {
        self.inner
            .record_no_dispatch_failure(id, error_code, error_message)
            .await
    }

    async fn request_cancel(&self, id: Uuid) -> Result<AlgoliaImportCancelOutcome, RepoError> {
        self.inner.request_cancel(id).await
    }

    async fn prepare_resume(&self, id: Uuid) -> Result<AlgoliaImportResumeOutcome, RepoError> {
        self.inner.prepare_resume(id).await
    }

    async fn request_cancel_for_customer(
        &self,
        customer_id: Uuid,
        id: Uuid,
    ) -> Result<AlgoliaImportCancelOutcome, AlgoliaLifecycleError> {
        self.inner
            .request_cancel_for_customer(customer_id, id)
            .await
    }

    async fn prepare_resume_for_customer(
        &self,
        customer_id: Uuid,
        id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<AlgoliaImportResumeOutcome, AlgoliaLifecycleError> {
        self.inner
            .prepare_resume_for_customer(customer_id, id, now)
            .await
    }

    async fn record_resume_accepted(
        &self,
        id: Uuid,
        generation: i64,
        summary: AlgoliaImportSummary,
    ) -> Result<AlgoliaImportJob, RepoError> {
        self.inner
            .record_resume_accepted(id, generation, summary)
            .await
    }

    async fn mark_engine_acknowledged(
        &self,
        id: Uuid,
    ) -> Result<AlgoliaImportEngineAckOutcome, RepoError> {
        self.inner.mark_engine_acknowledged(id).await
    }

    async fn gc_retained_terminal_history(
        &self,
        now: DateTime<Utc>,
        limit: i64,
    ) -> Result<Vec<Uuid>, RepoError> {
        self.inner.gc_retained_terminal_history(now, limit).await
    }

    async fn claim_reconciliation_jobs(
        &self,
        now: DateTime<Utc>,
        lease_expires_at: DateTime<Utc>,
        limit: i64,
    ) -> Result<Vec<AlgoliaImportReconciliationClaim>, RepoError> {
        self.inner
            .claim_reconciliation_jobs(now, lease_expires_at, limit)
            .await
    }

    async fn record_reconciliation_observation(
        &self,
        lease: &AlgoliaImportReconciliationLease,
        observed_at: DateTime<Utc>,
        state: AlgoliaImportJobState,
    ) -> Result<AlgoliaImportReconciliationWriteOutcome, RepoError> {
        self.inner
            .record_reconciliation_observation(lease, observed_at, state)
            .await
    }

    async fn finalize_terminal_observation(
        &self,
        authority: api::repos::AlgoliaImportTerminalFinalizationAuthority,
        fact: api::models::algolia_import_job::AlgoliaImportTerminalFact,
    ) -> Result<api::repos::AlgoliaImportTerminalFinalizationOutcome, RepoError> {
        self.inner
            .finalize_terminal_observation(authority, fact)
            .await
    }

    async fn claim_elapsed_resume_deadlines(
        &self,
        now: DateTime<Utc>,
        lease_expires_at: DateTime<Utc>,
        limit: i64,
    ) -> Result<Vec<AlgoliaImportResumeDeadlineClaim>, RepoError> {
        self.inner
            .claim_elapsed_resume_deadlines(now, lease_expires_at, limit)
            .await
    }

    async fn begin_lifecycle_target_guard(
        &self,
        customer_id: Uuid,
        logical_target: &str,
    ) -> Result<CatalogLifecycleTargetGuard, RepoError> {
        self.inner
            .begin_lifecycle_target_guard(customer_id, logical_target)
            .await
    }

    async fn commit_lifecycle_target_guard(
        &self,
        guard: CatalogLifecycleTargetGuard,
        expected_identity: Option<&CatalogLifecycleTargetIdentity>,
    ) -> Result<(), RepoError> {
        self.inner
            .commit_lifecycle_target_guard(guard, expected_identity)
            .await
    }
}

async fn setup_algolia_cloud_discovery_app(
    service: Arc<dyn AlgoliaSourceLister>,
) -> (axum::Router, String) {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);
    let app = build_router(
        TestStateBuilder::new()
            .with_customer_repo(customer_repo)
            .with_algolia_source_service(service)
            .build(),
    );
    (app, jwt)
}

async fn setup_algolia_cloud_job_test_app(
    algolia_migration_enabled: bool,
) -> (axum::Router, String) {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);
    let state = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_algolia_migration_enabled(algolia_migration_enabled)
        .build();
    let app = axum::Router::new()
        .route(
            "/migration/algolia/destination-eligibility",
            post(api::routes::migration::check_algolia_destination_eligibility),
        )
        .with_state(state);

    (app, jwt)
}

async fn setup_algolia_cloud_job_eligibility_app_with_pool(
    pool: PgPool,
    algolia_migration_enabled: bool,
) -> (axum::Router, String, Uuid, Arc<FakeAlgoliaSourceLister>) {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    insert_active_customer(&pool, customer.id, 1).await;
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let state = TestStateBuilder::new()
        .with_pool(pool)
        .with_customer_repo(customer_repo)
        .with_algolia_source_service(source_service.clone())
        .with_algolia_migration_enabled(algolia_migration_enabled)
        .build();
    let app = axum::Router::new()
        .route(
            "/migration/algolia/destination-eligibility",
            post(api::routes::migration::check_algolia_destination_eligibility),
        )
        .with_state(state);

    (
        app,
        create_test_jwt(customer.id),
        customer.id,
        source_service,
    )
}

const FLAPJACK_IDENTITY_ENV_NAMES: [&str; 5] = [
    "FJCLOUD_FLAPJACK_VERSION",
    "FJCLOUD_FLAPJACK_REQUIRED_REVISION",
    "FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID",
    "FJCLOUD_FLAPJACK_REQUIRED_SHA256",
    "FJCLOUD_FLAPJACK_REQUIRED_CAPABILITY",
];

struct FlapjackIdentityEnvGuard {
    _lock: std::sync::MutexGuard<'static, ()>,
    previous_values: Vec<(&'static str, Option<OsString>)>,
}

impl FlapjackIdentityEnvGuard {
    fn compatible() -> Self {
        let lock = crate::common::integration_helpers::test_env_lock();
        let previous_values = FLAPJACK_IDENTITY_ENV_NAMES
            .into_iter()
            .map(|name| (name, std::env::var_os(name)))
            .collect();
        std::env::set_var("FJCLOUD_FLAPJACK_VERSION", "1.0.10");
        std::env::set_var("FJCLOUD_FLAPJACK_REQUIRED_REVISION", "abc123");
        std::env::set_var("FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID", "build-1");
        std::env::set_var("FJCLOUD_FLAPJACK_REQUIRED_SHA256", "sha-1");
        std::env::remove_var("FJCLOUD_FLAPJACK_REQUIRED_CAPABILITY");
        Self {
            _lock: lock,
            previous_values,
        }
    }
}

impl Drop for FlapjackIdentityEnvGuard {
    fn drop(&mut self) {
        for (name, previous_value) in &self.previous_values {
            match previous_value {
                Some(value) => std::env::set_var(name, value),
                None => std::env::remove_var(name),
            }
        }
    }
}

async fn setup_algolia_cloud_job_create_app(
    pool: PgPool,
    source_service: Arc<dyn AlgoliaSourceLister>,
) -> (axum::Router, String, Uuid, Arc<MockFlapjackHttpClient>) {
    let (app, jwt, customer_id, flapjack_http, _alert_service) =
        setup_algolia_cloud_job_create_app_with_alerts(pool, source_service).await;
    (app, jwt, customer_id, flapjack_http)
}

/// Collaborators for the Algolia create-admission path, shared between the
/// full-route tests and the service-level linkage-failure seam test. Exposes
/// the built `AppState` (which owns the wired `AlgoliaImportService`) plus the
/// seeded VM id so a service-level test can build a create placement without
/// replicating the route's destination-preparation logic.
struct AlgoliaCreateHarness {
    state: AppState,
    jwt: String,
    customer_id: Uuid,
    vm_id: Uuid,
    flapjack_http: Arc<MockFlapjackHttpClient>,
    alert_service: Arc<MockAlertService>,
}

async fn setup_algolia_cloud_job_create_app_with_alerts(
    pool: PgPool,
    source_service: Arc<dyn AlgoliaSourceLister>,
) -> (
    axum::Router,
    String,
    Uuid,
    Arc<MockFlapjackHttpClient>,
    Arc<MockAlertService>,
) {
    let harness = setup_algolia_cloud_job_create_harness(pool, source_service).await;
    let app = axum::Router::new()
        .route(
            "/migration/algolia/destination-eligibility",
            post(api::routes::migration::check_algolia_destination_eligibility),
        )
        .route(
            "/migration/algolia/jobs",
            post(api::routes::migration::create_algolia_import_job)
                .get(api::routes::migration::list_algolia_import_jobs),
        )
        .route(
            "/migration/algolia/jobs/:id",
            axum::routing::get(api::routes::migration::get_algolia_import_job),
        )
        .with_state(harness.state);
    (
        app,
        harness.jwt,
        harness.customer_id,
        harness.flapjack_http,
        harness.alert_service,
    )
}

async fn setup_algolia_cloud_job_create_harness(
    pool: PgPool,
    source_service: Arc<dyn AlgoliaSourceLister>,
) -> AlgoliaCreateHarness {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    insert_active_customer(&pool, customer.id, 1).await;

    let vm_inventory_repo = crate::common::mock_vm_inventory_repo();
    let vm = vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-algolia-create.flapjack.test".to_string(),
            flapjack_url: "https://vm-algolia-create.flapjack.test".to_string(),
            capacity: json!({ "disk_bytes": 10_000_000_000_i64 }),
        })
        .await
        .expect("seed mock VM inventory");
    sqlx::query(
        "INSERT INTO vm_inventory
         (id, region, provider, hostname, flapjack_url, status, capacity, current_load)
         VALUES ($1, 'us-east-1', 'aws', 'vm-algolia-create.flapjack.test',
                 'https://vm-algolia-create.flapjack.test', 'active',
                 $2::jsonb, $3::jsonb)",
    )
    .bind(vm.id)
    .bind(json!({ "disk_bytes": 10_000_000_000_i64 }))
    .bind(json!({ "disk_bytes": 0_i64 }))
    .execute(&pool)
    .await
    .expect("seed SQL VM inventory");

    let node_secret_manager = Arc::new(MockNodeSecretManager::new());
    node_secret_manager
        .create_node_api_key(vm.node_secret_id(), "us-east-1")
        .await
        .expect("seed VM admin key");
    let flapjack_http = Arc::new(MockFlapjackHttpClient::default());
    for _ in 0..3 {
        flapjack_http.push_json_response(
            200,
            json!({
                "version": "1.0.10",
                "producer_revision": "abc123",
                "build_id": "build-1",
                "binary_sha256": "sha-1",
                "dirty": false,
                "capabilities": ["vectorSearchLocal"]
            }),
        );
    }
    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        flapjack_http.clone(),
        node_secret_manager,
    ));
    let alert_service = Arc::new(MockAlertService::new());

    let state = TestStateBuilder::new()
        .with_pool(pool)
        .with_customer_repo(customer_repo)
        .with_vm_inventory_repo(vm_inventory_repo)
        .with_flapjack_proxy(flapjack_proxy)
        .with_alert_service(alert_service.clone())
        .with_algolia_source_service(source_service)
        .with_algolia_migration_enabled(true)
        .build();
    AlgoliaCreateHarness {
        state,
        jwt: create_test_jwt(customer.id),
        customer_id: customer.id,
        vm_id: vm.id,
        flapjack_http,
        alert_service,
    }
}

async fn seed_algolia_replace_target(pool: &PgPool, customer_id: Uuid, target: &str) {
    let vm_id = match sqlx::query_scalar::<_, Uuid>(
        "SELECT id FROM vm_inventory WHERE status = 'active' ORDER BY created_at, id LIMIT 1",
    )
    .fetch_optional(pool)
    .await
    .expect("find existing replace VM")
    {
        Some(vm_id) => vm_id,
        None => {
            let vm_id = Uuid::new_v4();
            sqlx::query(
                "INSERT INTO vm_inventory
                 (id, region, provider, hostname, flapjack_url, status, capacity, current_load)
                 VALUES ($1, 'us-east-1', 'aws', $2, 'https://replace-target.invalid', 'active',
                         $3::jsonb, $4::jsonb)",
            )
            .bind(vm_id)
            .bind(format!("vm-{vm_id}"))
            .bind(json!({ "disk_bytes": 10_000_000_000_i64 }))
            .bind(json!({ "disk_bytes": 0_i64 }))
            .execute(pool)
            .await
            .expect("seed replace VM");
            vm_id
        }
    };

    let deployment_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO customer_deployments
         (id, customer_id, node_id, region, vm_type, vm_provider, status,
          flapjack_url, health_status)
         VALUES ($1, $2, $3, 'us-east-1', 't4g.small', 'aws', 'running',
                 'https://replace-target.invalid', 'healthy')",
    )
    .bind(deployment_id)
    .bind(customer_id)
    .bind(format!("node-{deployment_id}"))
    .execute(pool)
    .await
    .expect("seed replace deployment");

    sqlx::query(
        "INSERT INTO customer_tenants
         (customer_id, tenant_id, deployment_id, vm_id, tier, service_type)
         VALUES ($1, $2, $3, $4, 'active', 'flapjack')",
    )
    .bind(customer_id)
    .bind(target)
    .bind(deployment_id)
    .bind(vm_id)
    .execute(pool)
    .await
    .expect("seed replace target");
}

fn discovery_response(next_cursor: Option<&str>) -> AlgoliaSourceListResponse {
    AlgoliaSourceListResponse {
        items: vec![AlgoliaIndexMetadata {
            name: "products".to_string(),
            entries: 42,
            data_size: 2048,
            file_size: 4096,
            updated_at: Utc.with_ymd_and_hms(2026, 7, 15, 12, 30, 0).unwrap(),
            last_build_time_s: 3,
            pending_task: false,
            primary: Some("products".to_string()),
            replicas: vec!["products_price_asc".to_string()],
        }],
        next_cursor: next_cursor.map(str::to_string),
    }
}

async fn post_discovery(
    app: axum::Router,
    jwt: Option<&str>,
    body: serde_json::Value,
) -> (StatusCode, serde_json::Value) {
    let mut request = Request::builder()
        .method(http::Method::POST)
        .uri("/migration/algolia/list-indexes")
        .header("content-type", "application/json");
    if let Some(jwt) = jwt {
        request = request.header("authorization", format!("Bearer {jwt}"));
    }
    let response = app
        .oneshot(request.body(Body::from(body.to_string())).unwrap())
        .await
        .unwrap();
    response_json(response).await
}

async fn post_destination_eligibility(
    app: axum::Router,
    jwt: Option<&str>,
    body: serde_json::Value,
) -> (StatusCode, http::HeaderMap, serde_json::Value) {
    let mut request = Request::builder()
        .method(http::Method::POST)
        .uri("/migration/algolia/destination-eligibility")
        .header("content-type", "application/json");
    if let Some(jwt) = jwt {
        request = request.header("authorization", format!("Bearer {jwt}"));
    }
    let response = app
        .oneshot(request.body(Body::from(body.to_string())).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let headers = response.headers().clone();
    let (_, body) = response_json(response).await;
    (status, headers, body)
}

async fn post_create_job(
    app: axum::Router,
    jwt: &str,
    idempotency_key: &str,
    body: serde_json::Value,
) -> (StatusCode, http::HeaderMap, serde_json::Value) {
    let response = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/algolia/jobs")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .header("idempotency-key", idempotency_key)
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let headers = response.headers().clone();
    let (_, body) = response_json(response).await;
    (status, headers, body)
}

fn inspected_source(app_id: &str, source_name: &str, revision: &str) -> AlgoliaImportSource {
    AlgoliaImportSource::from_final_key_metadata(
        app_id,
        source_name,
        AlgoliaImportSourceMetadata::new(Some(4096), Some(42), revision),
    )
}

fn assert_no_secret_eligibility_fields(body: &serde_json::Value) {
    for field in [
        "apiKey",
        "api_key",
        "credential",
        "credentials",
        "sourceSizeBytes",
        "source_size_bytes",
        "checkpoint",
        "resumeCheckpoint",
    ] {
        assert!(
            body.get(field).is_none(),
            "eligibility response must not expose volatile or source-derived field {field}"
        );
    }
}

async fn provider_eligibility_token(app: &axum::Router, jwt: &str) -> String {
    let (status, _headers, body) = post_destination_eligibility(
        app.clone(),
        Some(jwt),
        json!({
            "phase": "provider",
            "mode": "create",
            "target": { "region": "us-east-1", "name": "products" }
        }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::OK,
        "provider phase must mint an envelope"
    );
    body["eligibilityToken"]
        .as_str()
        .expect("provider envelope token")
        .to_string()
}

async fn target_create_eligibility_token(app: &axum::Router, jwt: &str) -> String {
    let provider_token = provider_eligibility_token(app, jwt).await;
    let (status, _headers, body) = post_destination_eligibility(
        app.clone(),
        Some(jwt),
        json!({
            "phase": "target",
            "mode": "create",
            "target": { "region": "us-east-1", "name": "products" },
            "eligibilityToken": provider_token,
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "target phase must mint a token");
    body["eligibilityToken"].as_str().unwrap().to_string()
}

async fn target_replace_eligibility_token(app: &axum::Router, jwt: &str, target: &str) -> String {
    let (status, _headers, body) = post_destination_eligibility(
        app.clone(),
        Some(jwt),
        json!({
            "phase": "target",
            "mode": "replace",
            "target": { "region": "us-east-1", "name": target },
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "replace eligibility body: {body}");
    body["eligibilityToken"].as_str().unwrap().to_string()
}

async fn setup_two_customer_eligibility_app() -> (axum::Router, String, String) {
    let customer_repo = mock_repo();
    let alice = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let bob = customer_repo.seed_verified_free_customer("Bob", "bob@example.com");
    let app = axum::Router::new()
        .route(
            "/migration/algolia/destination-eligibility",
            post(api::routes::migration::check_algolia_destination_eligibility),
        )
        .with_state(
            TestStateBuilder::new()
                .with_customer_repo(customer_repo)
                .with_algolia_migration_enabled(true)
                .build(),
        );
    (app, create_test_jwt(alice.id), create_test_jwt(bob.id))
}

fn assert_public_job_body(
    body: &serde_json::Value,
    expected_mode: &str,
    expected_target: &str,
    expected_region: &str,
    expected_source_name: &str,
) {
    assert!(body["id"].as_str().is_some());
    assert_eq!(body["status"], "queued");
    assert_eq!(body["mode"], expected_mode);
    assert_eq!(body["destination"]["kind"], expected_mode);
    assert_eq!(body["destination"]["target"], expected_target);
    assert_eq!(body["destination"]["region"], expected_region);
    assert_eq!(body["source"], json!({ "name": expected_source_name }));
    assert!(body["createdAt"].as_str().is_some());
    assert!(body["updatedAt"].as_str().is_some());
    for forbidden in [
        "customerId",
        "tenantId",
        "dispatchIntentState",
        "engineJobId",
        "idempotencyKey",
        "canonicalFingerprint",
        "routingIdentity",
        "cloudJobId",
        "reservedIndexCount",
        "reservedCustomerStorageBytes",
        "reservedNodeTransientBytes",
        "resumeCheckpoint",
        "workerClaimedAt",
        "workerLeaseExpiresAt",
        "warnings",
    ] {
        assert!(
            body.get(forbidden).is_none(),
            "public job body leaked internal field {forbidden}: {body}"
        );
    }
    assert!(body["error"].get("message").is_none());
    assert!(!body.to_string().contains("temporary-create-key"));
}

async fn count_algolia_import_jobs(pool: &PgPool) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM algolia_import_jobs")
        .fetch_one(pool)
        .await
        .expect("count import jobs")
}

async fn soft_delete_customer(pool: &PgPool, customer_id: Uuid) {
    assert!(
        PgCustomerRepo::new(pool.clone())
            .soft_delete(customer_id)
            .await
            .expect("soft-delete customer"),
        "customer fixture should be active before soft-delete"
    );
}

async fn serialized_import_job_row(pool: &PgPool, id: Uuid) -> serde_json::Value {
    sqlx::query_scalar(
        "SELECT to_jsonb(algolia_import_jobs.*)
         FROM algolia_import_jobs WHERE id = $1",
    )
    .bind(id)
    .fetch_one(pool)
    .await
    .expect("serialize retained import job row")
}

#[path = "migration_routes_test/create.rs"]
mod create;
#[path = "migration_routes_test/discovery.rs"]
mod discovery;
#[path = "migration_routes_test/eligibility.rs"]
mod eligibility;
#[path = "migration_routes_test/read/mod.rs"]
mod read;
