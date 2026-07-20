use std::collections::HashSet;
use std::ffi::OsString;
use std::sync::Arc;
use std::sync::{Mutex, MutexGuard};

use api::errors::ApiError;
use api::models::algolia_import_job::{
    AlgoliaImportCreateDestination, AlgoliaImportDestinationKind, AlgoliaImportDispatchIntentState,
    AlgoliaImportEngineAckState, AlgoliaImportErrorCode, AlgoliaImportJob, AlgoliaImportJobState,
    AlgoliaImportJobStatus, AlgoliaImportPublicationDisposition, AlgoliaImportSource,
    AlgoliaImportSourceMetadata, AlgoliaImportSummary, AlgoliaImportTargetBinding,
    AlgoliaImportTombstoneCleanupPhase, AlgoliaReplaceTargetFacts, AlgoliaSealScrubWork,
    NewAlgoliaImportJob, NewAlgoliaReplaceImportJob, UNKNOWN_ALGOLIA_SOURCE_SIZE_BYTES,
};
use api::secrets::mock::MockNodeSecretManager;
use api::services::flapjack_proxy::FlapjackProxy;

#[test]
fn seal_scrub_work_serializes_only_opaque_reconciliation_identifiers() {
    let work = AlgoliaSealScrubWork {
        erasure_handle: Uuid::new_v4(),
        engine_job_id: Some(Uuid::new_v4()),
        destination_vm_id: Some(Uuid::new_v4()),
        cleanup_phase: AlgoliaImportTombstoneCleanupPhase::ExactTargetAbsenceRequired,
        publication_disposition: AlgoliaImportPublicationDisposition::Unknown,
        engine_ack_state: AlgoliaImportEngineAckState::Pending,
    };

    let serialized = serde_json::to_value(work).expect("serialize seal/scrub work");
    let fields = serialized
        .as_object()
        .expect("seal/scrub work must serialize as an object");
    assert_eq!(
        fields.keys().map(String::as_str).collect::<Vec<_>>(),
        vec![
            "cleanup_phase",
            "destination_vm_id",
            "engine_ack_state",
            "engine_job_id",
            "erasure_handle",
            "publication_disposition",
        ]
    );
}
use api::provisioner::region_map::RegionConfig;
use api::repos::{
    AlgoliaImportJobAdmissionError, AlgoliaImportJobRepo, CustomerRepo, PgAlgoliaImportJobRepo,
    PgCustomerRepo, PgTenantRepo, RepoError, TenantRepo, VmInventoryRepo,
};
use chrono::{Duration, Utc};
use serde_json::json;
use sqlx::PgPool;
use uuid::Uuid;

use crate::common::flapjack_proxy_test_support::MockFlapjackHttpClient;
use crate::common::support::pg_schema_harness::{connect_and_migrate, insert_active_customer};
use crate::common::vm_inventory_reference_guard_fixtures::insert_vm_with_id;

static FLAPJACK_IDENTITY_ENV_LOCK: Mutex<()> = Mutex::new(());
const FLAPJACK_IDENTITY_ENV_NAMES: [&str; 5] = [
    "FJCLOUD_FLAPJACK_VERSION",
    "FJCLOUD_FLAPJACK_REQUIRED_REVISION",
    "FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID",
    "FJCLOUD_FLAPJACK_REQUIRED_SHA256",
    "FJCLOUD_FLAPJACK_REQUIRED_CAPABILITY",
];

struct FlapjackIdentityEnvGuard {
    _lock: MutexGuard<'static, ()>,
    previous_values: Vec<(&'static str, Option<OsString>)>,
}

impl FlapjackIdentityEnvGuard {
    fn cleared() -> Self {
        let lock = FLAPJACK_IDENTITY_ENV_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let previous_values = FLAPJACK_IDENTITY_ENV_NAMES
            .into_iter()
            .map(|name| (name, std::env::var_os(name)))
            .collect();
        for name in FLAPJACK_IDENTITY_ENV_NAMES {
            std::env::remove_var(name);
        }
        Self {
            _lock: lock,
            previous_values,
        }
    }

    fn configure_complete_identity(&self) {
        std::env::set_var("FJCLOUD_FLAPJACK_VERSION", "1.0.10");
        std::env::set_var("FJCLOUD_FLAPJACK_REQUIRED_REVISION", "abc123");
        std::env::set_var("FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID", "build-1");
        std::env::set_var("FJCLOUD_FLAPJACK_REQUIRED_SHA256", "sha-1");
    }

    fn configure_partial_identity(&self) {
        std::env::set_var("FJCLOUD_FLAPJACK_VERSION", "1.0.10");
        std::env::set_var("FJCLOUD_FLAPJACK_REQUIRED_REVISION", "abc123");
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

async fn insert_replace_target(pool: &PgPool, customer_id: Uuid, target: &str) -> (Uuid, Uuid) {
    sqlx::query(
        "INSERT INTO customers (id, name, email, status)
         VALUES ($1, 'Algolia customer', $2, 'active')",
    )
    .bind(customer_id)
    .bind(format!("{customer_id}@example.com"))
    .execute(pool)
    .await
    .expect("insert customer");

    let vm_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO vm_inventory
         (id, region, provider, hostname, flapjack_url, status, capacity, current_load)
         VALUES ($1, 'us-east-1', 'aws', $2, 'https://private.invalid', 'active',
                 $3::jsonb, $4::jsonb)",
    )
    .bind(vm_id)
    .bind(format!("vm-{vm_id}"))
    .bind(json!({ "disk_bytes": 1_000_000_000 }))
    .bind(json!({ "disk_bytes": 0 }))
    .execute(pool)
    .await
    .expect("insert VM");

    let deployment_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO customer_deployments
         (id, customer_id, node_id, region, vm_type, vm_provider, status,
          flapjack_url, health_status)
         VALUES ($1, $2, $3, 'us-east-1', 't4g.small', 'aws', 'running',
                 'https://private.invalid', 'healthy')",
    )
    .bind(deployment_id)
    .bind(customer_id)
    .bind(format!("node-{deployment_id}"))
    .execute(pool)
    .await
    .expect("insert deployment");

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
    .expect("insert tenant");
    (deployment_id, vm_id)
}

fn replace_request(customer_id: Uuid, target: &str, key: &str) -> NewAlgoliaReplaceImportJob {
    NewAlgoliaReplaceImportJob::new(customer_id, target, source_with_size(key, 12_345), key)
}

fn source_with_size(key: &str, source_size_bytes: i64) -> AlgoliaImportSource {
    AlgoliaImportSource::from_final_key_metadata(
        "AB12CD34EF",
        "Products",
        AlgoliaImportSourceMetadata::new(
            Some(source_size_bytes),
            Some(1_000),
            format!("revision-{key}"),
        ),
    )
}

fn new_job(customer_id: Uuid, key: &str) -> NewAlgoliaImportJob {
    NewAlgoliaImportJob::create(
        customer_id,
        AlgoliaImportCreateDestination::new("products", "us-east-1"),
        source_with_size("canonical-request", 12_345),
        key,
    )
}

fn flapjack_proxy_with_health(body: serde_json::Value) -> Arc<FlapjackProxy> {
    let http = Arc::new(MockFlapjackHttpClient::default());
    http.push_json_response(200, body);
    Arc::new(FlapjackProxy::with_http_client(
        http,
        Arc::new(MockNodeSecretManager::new()),
    ))
}

fn compatible_flapjack_proxy() -> Arc<FlapjackProxy> {
    flapjack_proxy_with_health(json!({
        "version": "1.0.10",
        "producer_revision": "abc123",
        "build_id": "build-1",
        "binary_sha256": "sha-1",
        "dirty": false,
        "capabilities": ["vectorSearchLocal"]
    }))
}

fn assert_engine_upgrade_required(
    error: api::routes::indexes::AlgoliaCreateAdmissionError,
    context: &str,
) {
    match error {
        api::routes::indexes::AlgoliaCreateAdmissionError::Route(ApiError::BadRequest(message)) => {
            assert_eq!(
                message,
                AlgoliaImportErrorCode::EngineUpgradeRequired.as_str(),
                "{context}"
            )
        }
        other => panic!("unexpected engine gate error: {other:?}"),
    }
}

async fn assert_no_algolia_create_persistence(
    pool: &PgPool,
    tenant_repo: &impl TenantRepo,
    customer_id: Uuid,
) {
    let import_jobs: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM algolia_import_jobs")
        .fetch_one(pool)
        .await
        .expect("count import jobs");
    assert_eq!(import_jobs, 0);
    let tenant_rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM customer_tenants")
        .fetch_one(pool)
        .await
        .expect("count tenant rows");
    assert_eq!(tenant_rows, 0);
    assert!(tenant_repo
        .find_by_name(customer_id, "products")
        .await
        .expect("tenant lookup")
        .is_none());
}

fn new_job_with_fingerprint(
    customer_id: Uuid,
    key: &str,
    canonical_fingerprint: &str,
) -> NewAlgoliaImportJob {
    NewAlgoliaImportJob::create(
        customer_id,
        AlgoliaImportCreateDestination::new("products", "us-east-1"),
        AlgoliaImportSource::from_final_key_metadata(
            "AB12CD34EF",
            "Products",
            AlgoliaImportSourceMetadata::new(Some(12_345), Some(1_000), canonical_fingerprint),
        ),
        key,
    )
}

async fn insert_minimal(pool: &PgPool, customer_id: Uuid, suffix: &str) -> Uuid {
    insert_active_customer(pool, customer_id, 1).await;
    let destination_vm_id = Uuid::new_v4();
    insert_vm_with_id(
        pool,
        destination_vm_id,
        &format!("algolia-minimal-{destination_vm_id}"),
        "active",
    )
    .await;
    sqlx::query_scalar(
        "INSERT INTO algolia_import_jobs
         (customer_id, tenant_id, algolia_app_id, destination_kind, logical_target,
          destination_region, destination_deployment_id,
          destination_vm_id, physical_uid, source_name, idempotency_key,
          canonical_fingerprint, routing_identity, source_size_bytes, lifecycle_generation)
         VALUES ($1, 'products', 'AB12CD34EF', 'replace', 'products', 'us-east-1',
                 $2, $3, 'physical', 'source', $4, 'sha256:fingerprint', 'tenant/products', 100, 1)
         RETURNING id",
    )
    .bind(customer_id)
    .bind(Uuid::new_v4())
    .bind(destination_vm_id)
    .bind(format!("key-{suffix}"))
    .fetch_one(pool)
    .await
    .expect("insert minimal import job")
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

async fn import_job_count_for_customer(pool: &PgPool, customer_id: Uuid) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM algolia_import_jobs WHERE customer_id = $1")
        .bind(customer_id)
        .fetch_one(pool)
        .await
        .expect("count customer import jobs")
}

fn assert_destination_changed_admission(
    result: Result<AlgoliaImportJob, AlgoliaImportJobAdmissionError>,
    context: &str,
) {
    assert!(
        matches!(
            result,
            Err(AlgoliaImportJobAdmissionError::Refused(
                AlgoliaImportErrorCode::DestinationChanged
            ))
        ),
        "{context}: expected destination_changed refusal, got {result:?}"
    );
}

#[tokio::test]
async fn migration_creates_distinct_algolia_import_jobs_contract() {
    let Some(db) = connect_and_migrate("algolia_import_contract").await else {
        return;
    };
    let columns: HashSet<String> = sqlx::query_scalar(
        "SELECT column_name FROM information_schema.columns
         WHERE table_schema = current_schema() AND table_name = 'algolia_import_jobs'",
    )
    .fetch_all(&db.pool)
    .await
    .expect("inspect algolia import columns")
    .into_iter()
    .collect();

    let expected = [
        "id",
        "customer_id",
        "tenant_id",
        "algolia_app_id",
        "destination_kind",
        "logical_target",
        "destination_region",
        "destination_deployment_id",
        "destination_vm_id",
        "physical_uid",
        "source_name",
        "cloud_job_id",
        "engine_job_id",
        "dispatch_intent_state",
        "lifecycle_generation",
        "idempotency_key",
        "canonical_fingerprint",
        "routing_identity",
        "source_size_bytes",
        "retryable",
        "worker_claimed_at",
        "worker_lease_expires_at",
        "created_at",
        "updated_at",
        "resume_intent_generation",
        "cancel_requested_at",
        "resume_checkpoint",
        "resume_deadline",
        "resume_status_observed_at",
        "resumable",
        "resume_count",
        "documents_expected",
        "documents_imported",
        "documents_rejected",
        "settings_applied",
        "settings_unsupported",
        "synonyms_expected",
        "synonyms_imported",
        "synonyms_rejected",
        "rules_expected",
        "rules_imported",
        "rules_rejected",
        "warnings",
        "error_code",
        "error_message",
        "status",
        "publication_disposition",
        "engine_ack_state",
        "terminal_at",
        "erasure_handle",
        "cleanup_phase",
        "erased_at",
        "tombstone_compacted_at",
    ];
    for name in expected {
        assert!(columns.contains(name), "missing canonical column {name}");
    }
    for column in &columns {
        let column = column.to_ascii_lowercase();
        assert!(!column.contains("credential"));
        assert!(!column.contains("api_key"));
        assert!(!column.contains("raw_response"));
        assert!(!column.contains("vendor_response"));
    }

    let index_migration_columns: HashSet<String> = sqlx::query_scalar(
        "SELECT column_name FROM information_schema.columns
         WHERE table_schema = current_schema() AND table_name = 'index_migrations'",
    )
    .fetch_all(&db.pool)
    .await
    .unwrap()
    .into_iter()
    .collect();
    assert!(!index_migration_columns.contains("algolia_app_id"));
}

#[tokio::test]
async fn migration_rejects_half_scrubbed_public_jobs() {
    let Some(db) = connect_and_migrate("algolia_import_half_scrub").await else {
        return;
    };
    let customer_id = Uuid::new_v4();
    let job_id = insert_minimal(&db.pool, customer_id, "half-scrub").await;

    let result = sqlx::query("UPDATE algolia_import_jobs SET tenant_id = NULL WHERE id = $1")
        .bind(job_id)
        .execute(&db.pool)
        .await;

    assert!(
        result.is_err(),
        "a public row cannot become partially scrubbed outside the atomic erasure transition"
    );
}

#[tokio::test]
async fn migration_creates_singleton_algolia_import_environment_contract() {
    let Some(db) = connect_and_migrate("algolia_import_environment_contract").await else {
        return;
    };

    let row: (bool, String, i64, i64) = sqlx::query_as(
        "SELECT singleton, rollback_epoch, min_migration_schema_floor, min_protocol_floor
         FROM algolia_import_environment_contract",
    )
    .fetch_one(&db.pool)
    .await
    .expect("environment contract row");

    assert_eq!(row, (true, "pre_admission".into(), 56, 1));
    assert!(
        sqlx::query(
            "INSERT INTO algolia_import_environment_contract
             (singleton, rollback_epoch, min_migration_schema_floor, min_protocol_floor)
             VALUES (TRUE, 'pre_admission', 56, 1)",
        )
        .execute(&db.pool)
        .await
        .is_err(),
        "environment contract must be singleton"
    );
    assert!(
        sqlx::query(
            "UPDATE algolia_import_environment_contract
             SET rollback_epoch='legacy_again'",
        )
        .execute(&db.pool)
        .await
        .is_err(),
        "rollback epoch must be constrained to declared values"
    );
}

#[tokio::test]
async fn record_dispatch_intent_commits_intent_and_first_epoch_atomically() {
    let Some(db) = connect_and_migrate("algolia_import_dispatch_epoch").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let created = repo
        .create(new_job(customer_id, "dispatch-intent"))
        .await
        .unwrap();
    let engine_job_id = Uuid::new_v4();

    let admitted = repo
        .record_dispatch_intent_committed(created.id, engine_job_id)
        .await
        .expect("record dispatch intent");

    assert_eq!(
        admitted.dispatch_intent_state,
        AlgoliaImportDispatchIntentState::Committed
    );
    assert_eq!(admitted.engine_job_id, Some(engine_job_id));
    let epoch: String =
        sqlx::query_scalar("SELECT rollback_epoch FROM algolia_import_environment_contract")
            .fetch_one(&db.pool)
            .await
            .unwrap();
    assert_eq!(epoch, "migration_aware_required");

    let replay = repo
        .record_dispatch_intent_committed(created.id, engine_job_id)
        .await
        .expect("idempotent dispatch intent replay");
    assert_eq!(replay.engine_job_id, Some(engine_job_id));
    assert!(matches!(
        repo.record_dispatch_intent_committed(created.id, Uuid::new_v4())
            .await,
        Err(RepoError::Conflict(_))
    ));
}

#[tokio::test]
async fn stale_customer_generation_cannot_commit_dispatch_intent() {
    let Some(db) = connect_and_migrate("algolia_stale_dispatch_generation").await else {
        return;
    };
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 4).await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let created = repo
        .create(new_job(customer_id, "stale-dispatch"))
        .await
        .expect("admit import against active generation");
    assert_eq!(created.lifecycle_generation, 4);

    sqlx::query(
        "UPDATE customers \
         SET status = 'deleted', lifecycle_generation = lifecycle_generation + 1 \
         WHERE id = $1",
    )
    .bind(customer_id)
    .execute(&db.pool)
    .await
    .expect("advance customer lifecycle generation");

    assert!(matches!(
        repo.record_dispatch_intent_committed(created.id, Uuid::new_v4())
            .await,
        Err(RepoError::Conflict(_))
    ));
    let unchanged = repo.get(created.id).await.unwrap().unwrap();
    assert_eq!(
        unchanged.dispatch_intent_state,
        AlgoliaImportDispatchIntentState::Absent
    );
    assert_eq!(unchanged.engine_job_id, None);
}

#[tokio::test]
async fn soft_deleted_customer_refuses_create_admission_and_replay_without_mutating_retained_job() {
    let Some(db) = connect_and_migrate("algolia_deleted_create_fence").await else {
        return;
    };
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 7).await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let original_request = new_job(customer_id, "deleted-create-replay");
    let retained = repo
        .create(original_request.clone())
        .await
        .expect("admit active-generation import");
    assert_eq!(retained.lifecycle_generation, 7);
    let retained_before = serialized_import_job_row(&db.pool, retained.id).await;

    soft_delete_customer(&db.pool, customer_id).await;

    assert_destination_changed_admission(
        repo.create(original_request).await,
        "same-key replay after soft-delete",
    );
    assert_destination_changed_admission(
        repo.create(new_job(customer_id, "deleted-create-new-key"))
            .await,
        "new create after soft-delete",
    );
    assert_eq!(
        import_job_count_for_customer(&db.pool, customer_id).await,
        1
    );
    assert_eq!(
        serialized_import_job_row(&db.pool, retained.id).await,
        retained_before
    );
}

#[tokio::test]
async fn soft_deleted_customer_refuses_dispatch_and_no_dispatch_finalizer_without_mutating_retained_job(
) {
    let Some(db) = connect_and_migrate("algolia_deleted_dispatch_fence").await else {
        return;
    };
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 3).await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let retained = repo
        .create(new_job(customer_id, "deleted-dispatch"))
        .await
        .expect("admit queued import");
    let retained_before = serialized_import_job_row(&db.pool, retained.id).await;

    soft_delete_customer(&db.pool, customer_id).await;

    assert!(matches!(
        repo.record_dispatch_intent_committed(retained.id, Uuid::new_v4())
            .await,
        Err(RepoError::Conflict(_))
    ));
    assert!(matches!(
        repo.record_no_dispatch_failure(
            retained.id,
            AlgoliaImportErrorCode::BackendUnavailable,
            Some("source unavailable")
        )
        .await,
        Err(RepoError::Conflict(_))
    ));
    assert_eq!(
        serialized_import_job_row(&db.pool, retained.id).await,
        retained_before
    );
}

#[tokio::test]
async fn generic_state_update_cannot_write_dispatch_intent_or_engine_identity() {
    let Some(db) = connect_and_migrate("algolia_import_generic_no_dispatch").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let created = repo
        .create(new_job(customer_id, "generic-dispatch"))
        .await
        .unwrap();

    let attempted = AlgoliaImportJobState {
        status: AlgoliaImportJobStatus::ValidatingSource,
        publication_disposition: AlgoliaImportPublicationDisposition::NotStarted,
        engine_ack_state: AlgoliaImportEngineAckState::Pending,
        dispatch_intent_state: AlgoliaImportDispatchIntentState::Committed,
        engine_job_id: Some(Uuid::new_v4()),
        lifecycle_generation: 1,
        retryable: false,
        resume_intent_generation: 0,
        resume_mirror: None,
        resumable: false,
        resume_count: 0,
        summary: AlgoliaImportSummary::default(),
        warnings: json!([]),
        error_code: None,
        error_message: None,
    };

    assert!(matches!(
        repo.update_persisted_state(created.id, attempted).await,
        Err(RepoError::Conflict(_))
    ));
    let persisted = repo.get(created.id).await.unwrap().unwrap();
    assert_eq!(
        persisted.dispatch_intent_state,
        AlgoliaImportDispatchIntentState::Absent
    );
    assert_eq!(persisted.engine_job_id, None);
}

#[test]
fn new_import_job_create_destination_has_no_caller_supplied_engine_target() {
    let customer_id = Uuid::new_v4();
    let job = NewAlgoliaImportJob::create(
        customer_id,
        AlgoliaImportCreateDestination::new("products", "us-east-1"),
        source_with_size("create", 12_345),
        "create-key",
    );

    assert_eq!(job.customer_id(), customer_id);
    assert_eq!(job.tenant_id(), "products");
    assert_eq!(
        job.destination().kind(),
        AlgoliaImportDestinationKind::Create
    );
    assert_eq!(job.destination().logical_target(), "products");
    assert_eq!(job.destination().region(), "us-east-1");
    assert_eq!(job.destination().deployment_id(), None);
    assert_eq!(job.destination().vm_id(), None);
    assert_eq!(job.destination().physical_uid(), None);
    assert_eq!(job.destination().routing_identity(), None);
}

#[tokio::test]
async fn repository_authenticates_replace_selector_and_derives_destination_identity() {
    let Some(db) = connect_and_migrate("algolia_authenticated_replace").await else {
        return;
    };
    let customer_id = Uuid::new_v4();
    let other_customer_id = Uuid::new_v4();
    let (deployment_id, vm_id) = insert_replace_target(&db.pool, customer_id, "products").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());

    let forged = repo
        .create_replace(replace_request(other_customer_id, "products", "forged"))
        .await;
    assert!(matches!(
        forged,
        Err(AlgoliaImportJobAdmissionError::Refused(
            AlgoliaImportErrorCode::DestinationChanged
        ))
    ));

    let job = repo
        .create_replace(replace_request(customer_id, "products", "replace-key"))
        .await
        .expect("authenticated catalog target is eligible");
    let expected_uid = api::services::flapjack_node::flapjack_index_uid(customer_id, "products");

    assert_eq!(job.destination_kind, AlgoliaImportDestinationKind::Replace);
    assert_eq!(job.logical_target, "products");
    assert_eq!(job.destination_deployment_id, Some(deployment_id));
    assert_eq!(job.destination_vm_id, Some(vm_id));
    assert_eq!(job.physical_uid.as_deref(), Some(expected_uid.as_str()));
    assert_eq!(job.routing_identity.as_deref(), Some(expected_uid.as_str()));
}

#[tokio::test]
async fn stale_replace_target_binding_is_refused_before_job_insertion() {
    let Some(db) = connect_and_migrate("algolia_stale_replace_binding").await else {
        return;
    };
    let customer_id = Uuid::new_v4();
    insert_replace_target(&db.pool, customer_id, "products").await;
    let lifecycle_generation: i64 =
        sqlx::query_scalar("SELECT lifecycle_generation FROM customers WHERE id = $1")
            .bind(customer_id)
            .fetch_one(&db.pool)
            .await
            .expect("read lifecycle generation");
    let binding = AlgoliaImportTargetBinding::replace(
        customer_id,
        "products",
        "us-east-1",
        lifecycle_generation,
        api::services::flapjack_node::flapjack_index_uid(customer_id, "products"),
    );
    sqlx::query(
        "UPDATE customers SET lifecycle_generation = lifecycle_generation + 1 WHERE id = $1",
    )
    .bind(customer_id)
    .execute(&db.pool)
    .await
    .expect("advance lifecycle generation");

    let result = PgAlgoliaImportJobRepo::new(db.pool.clone())
        .create_replace(
            NewAlgoliaReplaceImportJob::from_target_binding(
                binding,
                source_with_size("stale-binding", 12_345),
                "stale-binding",
            )
            .expect("construct trusted replace request"),
        )
        .await;

    assert!(matches!(
        result,
        Err(AlgoliaImportJobAdmissionError::Refused(
            AlgoliaImportErrorCode::DestinationChanged
        ))
    ));
    let persisted: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM algolia_import_jobs WHERE customer_id = $1")
            .bind(customer_id)
            .fetch_one(&db.pool)
            .await
            .expect("count import jobs");
    assert_eq!(persisted, 0);
}

#[tokio::test]
async fn repository_persists_typed_create_and_replace_destinations() {
    let Some(db) = connect_and_migrate("algolia_typed_destination").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let create_customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, create_customer_id, 1).await;
    let created = repo
        .create(NewAlgoliaImportJob::create(
            create_customer_id,
            AlgoliaImportCreateDestination::new("products", "us-east-1"),
            source_with_size("typed-create", 12_345),
            "typed-create",
        ))
        .await
        .unwrap();

    assert_eq!(
        created.destination_kind,
        AlgoliaImportDestinationKind::Create
    );
    assert_eq!(created.logical_target, "products");
    assert_eq!(created.destination_region, "us-east-1");
    assert_eq!(created.destination_deployment_id, None);
    assert_eq!(created.destination_vm_id, None);
    assert_eq!(created.physical_uid, None);
    assert_eq!(created.routing_identity, None);

    let replace_customer_id = Uuid::new_v4();
    let (deployment_id, vm_id) =
        insert_replace_target(&db.pool, replace_customer_id, "products").await;
    let replaced = repo
        .create_replace(replace_request(
            replace_customer_id,
            "products",
            "typed-replace",
        ))
        .await
        .unwrap();
    let expected_uid =
        api::services::flapjack_node::flapjack_index_uid(replace_customer_id, "products");

    assert_eq!(
        replaced.destination_kind,
        AlgoliaImportDestinationKind::Replace
    );
    assert_eq!(replaced.destination_deployment_id, Some(deployment_id));
    assert_eq!(replaced.destination_vm_id, Some(vm_id));
    assert_eq!(
        replaced.physical_uid.as_deref(),
        Some(expected_uid.as_str())
    );
    assert_eq!(
        replaced.routing_identity.as_deref(),
        Some(expected_uid.as_str())
    );
}

#[tokio::test]
async fn algolia_create_import_engine_compatibility_uses_shared_admission_and_placement_before_persistence(
) {
    let Some(db) = connect_and_migrate("algolia_shared_admission").await else {
        return;
    };
    let identity_env = FlapjackIdentityEnvGuard::cleared();
    identity_env.configure_complete_identity();
    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed_verified_free_customer(
        "Algolia admission customer",
        "algolia-admission@example.com",
    );
    sqlx::query(
        "INSERT INTO customers (id, name, email, status, email_verified_at)
         VALUES ($1, $2, $3, 'active', NOW())",
    )
    .bind(customer.id)
    .bind(&customer.name)
    .bind(&customer.email)
    .execute(&db.pool)
    .await
    .expect("insert persisted customer");

    let tenant_repo = crate::common::mock_tenant_repo();
    let vm_repo = crate::common::mock_vm_inventory_repo();
    let vm = vm_repo
        .create(crate::common::vm_seed("us-east-1", "aws", "shared.invalid"))
        .await
        .expect("seed shared VM with storage capacity");
    sqlx::query(
        "INSERT INTO vm_inventory
         (id, region, provider, hostname, flapjack_url, capacity, current_load, status)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
    )
    .bind(vm.id)
    .bind(&vm.region)
    .bind(&vm.provider)
    .bind(&vm.hostname)
    .bind(&vm.flapjack_url)
    .bind(&vm.capacity)
    .bind(&vm.current_load)
    .bind(&vm.status)
    .execute(&db.pool)
    .await
    .expect("persist the placed VM for reservation headroom fencing");
    let mut state = crate::common::test_state_with_indexes_and_vm_inventory(
        customer_repo,
        crate::common::mock_deployment_repo(),
        tenant_repo.clone(),
        compatible_flapjack_proxy(),
        vm_repo,
    );
    state.pool = db.pool.clone();

    let created = api::routes::indexes::create_algolia_import_job(
        &state,
        NewAlgoliaImportJob::create(
            customer.id,
            AlgoliaImportCreateDestination::new("products", "us-east-1"),
            source_with_size("shared-admission", 12_345),
            "shared-admission",
        ),
    )
    .await
    .expect("shared admission should persist an eligible reservation");

    let expected_uid = api::services::flapjack_node::flapjack_index_uid(customer.id, "products");
    assert_eq!(created.destination_vm_id, Some(vm.id));
    assert_eq!(created.physical_uid.as_deref(), Some(expected_uid.as_str()));
    assert_eq!(
        created.routing_identity.as_deref(),
        Some(expected_uid.as_str())
    );
    assert!(tenant_repo
        .find_by_name(customer.id, "products")
        .await
        .expect("tenant lookup")
        .is_none());
}

#[tokio::test]
async fn algolia_create_import_engine_compatibility_rejects_incompatible_health_before_persistence()
{
    let Some(db) = connect_and_migrate("algolia_import_engine_gate_reject").await else {
        return;
    };
    let identity_env = FlapjackIdentityEnvGuard::cleared();
    identity_env.configure_complete_identity();
    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed_verified_free_customer(
        "Algolia engine gate customer",
        "algolia-engine-gate@example.com",
    );
    sqlx::query(
        "INSERT INTO customers (id, name, email, status, email_verified_at)
         VALUES ($1, $2, $3, 'active', NOW())",
    )
    .bind(customer.id)
    .bind(&customer.name)
    .bind(&customer.email)
    .execute(&db.pool)
    .await
    .expect("insert persisted customer");

    let tenant_repo = crate::common::mock_tenant_repo();
    let vm_repo = crate::common::mock_vm_inventory_repo();
    let vm = vm_repo
        .create(crate::common::vm_seed(
            "us-east-1",
            "aws",
            "engine-gate.invalid",
        ))
        .await
        .expect("seed shared VM with storage capacity");
    sqlx::query(
        "INSERT INTO vm_inventory
         (id, region, provider, hostname, flapjack_url, capacity, current_load, status)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
    )
    .bind(vm.id)
    .bind(&vm.region)
    .bind(&vm.provider)
    .bind(&vm.hostname)
    .bind(&vm.flapjack_url)
    .bind(&vm.capacity)
    .bind(&vm.current_load)
    .bind(&vm.status)
    .execute(&db.pool)
    .await
    .expect("persist the selected VM for reservation");
    let mut state = crate::common::test_state_with_indexes_and_vm_inventory(
        customer_repo,
        crate::common::mock_deployment_repo(),
        tenant_repo.clone(),
        flapjack_proxy_with_health(json!({
            "version": "1.0.10",
            "dirty": true,
            "capabilities": ["vectorSearchLocal"]
        })),
        vm_repo,
    );
    state.pool = db.pool.clone();

    let error = api::routes::indexes::create_algolia_import_job(
        &state,
        NewAlgoliaImportJob::create(
            customer.id,
            AlgoliaImportCreateDestination::new("products", "us-east-1"),
            source_with_size("engine-gate", 12_345),
            "engine-gate",
        ),
    )
    .await
    .expect_err("incompatible engine must reject import before persistence");

    assert_engine_upgrade_required(error, "incompatible health must fail closed");
    assert_no_algolia_create_persistence(&db.pool, tenant_repo.as_ref(), customer.id).await;
}

#[tokio::test]
async fn algolia_create_import_engine_compatibility_rejects_absent_or_partial_identity_config() {
    let Some(db) = connect_and_migrate("algolia_import_engine_config_gate").await else {
        return;
    };
    let identity_env = FlapjackIdentityEnvGuard::cleared();
    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed_verified_free_customer(
        "Algolia identity config customer",
        "algolia-identity-config@example.com",
    );
    sqlx::query(
        "INSERT INTO customers (id, name, email, status, email_verified_at)
         VALUES ($1, $2, $3, 'active', NOW())",
    )
    .bind(customer.id)
    .bind(&customer.name)
    .bind(&customer.email)
    .execute(&db.pool)
    .await
    .expect("insert persisted customer");

    let tenant_repo = crate::common::mock_tenant_repo();
    let vm_repo = crate::common::mock_vm_inventory_repo();
    let vm = vm_repo
        .create(crate::common::vm_seed(
            "us-east-1",
            "aws",
            "identity-config.invalid",
        ))
        .await
        .expect("seed shared VM with storage capacity");
    sqlx::query(
        "INSERT INTO vm_inventory
         (id, region, provider, hostname, flapjack_url, capacity, current_load, status)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
    )
    .bind(vm.id)
    .bind(&vm.region)
    .bind(&vm.provider)
    .bind(&vm.hostname)
    .bind(&vm.flapjack_url)
    .bind(&vm.capacity)
    .bind(&vm.current_load)
    .bind(&vm.status)
    .execute(&db.pool)
    .await
    .expect("persist the selected VM for reservation");
    let mut state = crate::common::test_state_with_indexes_and_vm_inventory(
        customer_repo,
        crate::common::mock_deployment_repo(),
        tenant_repo.clone(),
        compatible_flapjack_proxy(),
        vm_repo,
    );
    state.pool = db.pool.clone();

    for (configuration, idempotency_key) in
        [("absent", "config-absent"), ("partial", "config-partial")]
    {
        if configuration == "partial" {
            identity_env.configure_partial_identity();
        }
        let error = api::routes::indexes::create_algolia_import_job(
            &state,
            NewAlgoliaImportJob::create(
                customer.id,
                AlgoliaImportCreateDestination::new("products", "us-east-1"),
                source_with_size(idempotency_key, 12_345),
                idempotency_key,
            ),
        )
        .await
        .expect_err("incomplete engine identity config must reject import");
        assert_engine_upgrade_required(
            error,
            &format!("{configuration} identity configuration must fail closed"),
        );
    }

    assert_no_algolia_create_persistence(&db.pool, tenant_repo.as_ref(), customer.id).await;
}

#[test]
fn final_key_metadata_owns_source_size_and_canonical_fingerprint() {
    let forged_browser_data_size = 1;
    let refreshed = source_with_size("refreshed", 42_000);
    let changed_same_size = AlgoliaImportSource::from_final_key_metadata(
        "AB12CD34EF",
        "Products",
        AlgoliaImportSourceMetadata::new(Some(42_000), Some(1_001), "revision-refreshed"),
    );

    assert_eq!(refreshed.source_size_bytes(), 42_000);
    assert_ne!(refreshed.source_size_bytes(), forged_browser_data_size);
    assert_ne!(
        refreshed.canonical_fingerprint(),
        changed_same_size.canonical_fingerprint(),
        "same-size source changes must still alter the canonical fingerprint"
    );
}

#[test]
fn missing_final_key_source_size_reserves_conservative_bound() {
    let source = AlgoliaImportSource::from_final_key_metadata(
        "AB12CD34EF",
        "Products",
        AlgoliaImportSourceMetadata::new(None, Some(1_000), "revision-without-size"),
    );

    assert_eq!(
        source.source_size_bytes(),
        UNKNOWN_ALGOLIA_SOURCE_SIZE_BYTES
    );
}

#[tokio::test]
async fn same_key_same_size_changed_source_metadata_conflicts() {
    let Some(db) = connect_and_migrate("algolia_source_metadata_idempotency").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let original_source = AlgoliaImportSource::from_final_key_metadata(
        "AB12CD34EF",
        "Products",
        AlgoliaImportSourceMetadata::new(Some(12_345), Some(1_000), "revision-a"),
    );
    let changed_source = AlgoliaImportSource::from_final_key_metadata(
        "AB12CD34EF",
        "Products",
        AlgoliaImportSourceMetadata::new(Some(12_345), Some(1_001), "revision-a"),
    );

    let _original = repo
        .create(NewAlgoliaImportJob::create(
            customer,
            AlgoliaImportCreateDestination::new("products", "us-east-1"),
            original_source,
            "same-key",
        ))
        .await
        .expect("original import job");
    let changed = repo
        .create(NewAlgoliaImportJob::create(
            customer,
            AlgoliaImportCreateDestination::new("products", "us-east-1"),
            changed_source,
            "same-key",
        ))
        .await;

    assert!(
        matches!(
            changed,
            Err(AlgoliaImportJobAdmissionError::Refused(
                AlgoliaImportErrorCode::DestinationConflict
            ))
        ),
        "same idempotency key plus changed authenticated source metadata must conflict"
    );
}

#[tokio::test]
async fn unknown_source_size_quota_failure_is_atomic() {
    let Some(db) = connect_and_migrate("algolia_source_size_atomic").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO customers (id, name, email, status, email_verified_at)
         VALUES ($1, 'Algolia customer', $2, 'active', NOW())",
    )
    .bind(customer)
    .bind(format!("{customer}@example.com"))
    .execute(&db.pool)
    .await
    .expect("insert customer");
    sqlx::query(
        "INSERT INTO customer_deployments
         (id, customer_id, node_id, region, vm_type, vm_provider, status)
         VALUES ($1, $2, $3, 'us-east-1', 't4g.small', 'aws', 'running')",
    )
    .bind(Uuid::new_v4())
    .bind(customer)
    .bind("quota-node")
    .execute(&db.pool)
    .await
    .expect("insert quota owner deployment");
    sqlx::query(
        "INSERT INTO customer_tenants
         (customer_id, tenant_id, deployment_id, tier, service_type, resource_quota)
         SELECT $1, 'existing', id, 'active', 'flapjack',
                $2::jsonb
         FROM customer_deployments WHERE customer_id = $1 LIMIT 1",
    )
    .bind(customer)
    .bind(json!({
        "max_indexes": 10,
        "max_storage_bytes": UNKNOWN_ALGOLIA_SOURCE_SIZE_BYTES - 1
    }))
    .execute(&db.pool)
    .await
    .expect("insert quota owner tenant");

    let source = AlgoliaImportSource::from_final_key_metadata(
        "AB12CD34EF",
        "Products",
        AlgoliaImportSourceMetadata::new(None, Some(1_000), "revision-without-size"),
    );
    let result = repo
        .create(NewAlgoliaImportJob::create(
            customer,
            AlgoliaImportCreateDestination::new("products", "us-east-1"),
            source,
            "unknown-size-over-quota",
        ))
        .await;

    assert!(matches!(
        result,
        Err(AlgoliaImportJobAdmissionError::Refused(
            AlgoliaImportErrorCode::QuotaExceeded
        ))
    ));
    let persisted: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM algolia_import_jobs
         WHERE customer_id = $1 AND idempotency_key = 'unknown-size-over-quota'",
    )
    .bind(customer)
    .fetch_one(&db.pool)
    .await
    .expect("count failed import rows");
    assert_eq!(persisted, 0, "quota failure must not stage an import row");
}

#[tokio::test]
async fn create_reservation_stays_absent_from_catalog_and_discovery_surfaces() {
    let Some(db) = connect_and_migrate("algolia_create_visibility").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let tenant_repo = PgTenantRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;

    let _job = repo
        .create(new_job(customer, "visibility-create"))
        .await
        .expect("create import reservation");

    assert!(tenant_repo
        .find_by_name(customer, "products")
        .await
        .expect("tenant lookup")
        .is_none());
    assert!(tenant_repo
        .find_raw(customer, "products")
        .await
        .expect("raw tenant lookup")
        .is_none());
    assert!(tenant_repo
        .find_by_customer(customer)
        .await
        .expect("customer list")
        .is_empty());
    assert!(tenant_repo
        .list_raw_by_customer(customer)
        .await
        .expect("raw customer list")
        .is_empty());
    assert!(tenant_repo
        .find_by_tenant_id_global("products")
        .await
        .expect("global discovery lookup")
        .is_none());
    assert!(!tenant_repo
        .list_active_global()
        .await
        .expect("global active list")
        .iter()
        .any(|tenant| tenant.customer_id == customer && tenant.tenant_id == "products"));
}

#[tokio::test]
async fn replace_reservation_keeps_existing_target_cataloged_until_promotion() {
    let Some(db) = connect_and_migrate("algolia_replace_visibility").await else {
        return;
    };
    let customer = Uuid::new_v4();
    let (deployment_id, vm_id) = insert_replace_target(&db.pool, customer, "products").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let tenant_repo = PgTenantRepo::new(db.pool.clone());

    let job = repo
        .create_replace(replace_request(customer, "products", "visibility-replace"))
        .await
        .expect("replace import reservation");

    assert_eq!(job.destination_deployment_id, Some(deployment_id));
    assert_eq!(job.destination_vm_id, Some(vm_id));
    let visible = tenant_repo
        .find_by_name(customer, "products")
        .await
        .expect("tenant lookup")
        .expect("replacement target stays cataloged");
    assert_eq!(visible.deployment_id, deployment_id);
    assert_eq!(
        tenant_repo
            .find_by_customer(customer)
            .await
            .expect("customer list")
            .iter()
            .map(|tenant| tenant.tenant_id.as_str())
            .collect::<Vec<_>>(),
        vec!["products"]
    );
    assert!(tenant_repo
        .find_raw(customer, "products")
        .await
        .expect("raw tenant lookup")
        .is_some());
    assert!(tenant_repo
        .list_active_global()
        .await
        .expect("global active list")
        .iter()
        .any(|tenant| tenant.customer_id == customer && tenant.tenant_id == "products"));
}

#[tokio::test]
async fn same_logical_target_visibility_is_customer_isolated() {
    let Some(db) = connect_and_migrate("algolia_visibility_isolated").await else {
        return;
    };
    let customer_with_create = Uuid::new_v4();
    let customer_with_existing = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_with_create, 1).await;
    insert_replace_target(&db.pool, customer_with_existing, "products").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let tenant_repo = PgTenantRepo::new(db.pool.clone());

    let _job = repo
        .create(new_job(customer_with_create, "visibility-isolated"))
        .await
        .expect("create import reservation");

    assert!(tenant_repo
        .find_by_name(customer_with_create, "products")
        .await
        .expect("create customer lookup")
        .is_none());
    assert!(tenant_repo
        .find_by_name(customer_with_existing, "products")
        .await
        .expect("existing customer lookup")
        .is_some());
    assert!(tenant_repo
        .find_by_customer(customer_with_create)
        .await
        .expect("create customer list")
        .is_empty());
    assert_eq!(
        tenant_repo
            .find_by_customer(customer_with_existing)
            .await
            .expect("existing customer list")
            .len(),
        1
    );
}

#[tokio::test]
async fn schema_enforces_engine_owned_resume_mirror() {
    let Some(db) = connect_and_migrate("algolia_resume_mirror").await else {
        return;
    };

    struct Case {
        name: &'static str,
        status: &'static str,
        error_code: &'static str,
        intent: &'static str,
        has_engine_job: bool,
        checkpoint: Option<&'static str>,
        deadline_offset_seconds: i64,
        disposition: &'static str,
        ack: &'static str,
        accepted: bool,
    }

    let cases = [
        Case {
            name: "engine credential failure",
            status: "failed",
            error_code: "invalid_credentials",
            intent: "committed",
            has_engine_job: true,
            checkpoint: Some("opaque-checkpoint"),
            deadline_offset_seconds: 60,
            disposition: "unchanged",
            ack: "pending",
            accepted: true,
        },
        Case {
            name: "engine permission failure",
            status: "failed",
            error_code: "missing_source_permission",
            intent: "ambiguous",
            has_engine_job: true,
            checkpoint: Some("opaque-checkpoint"),
            deadline_offset_seconds: 60,
            disposition: "unchanged",
            ack: "pending",
            accepted: true,
        },
        Case {
            name: "engine interruption",
            status: "interrupted",
            error_code: "interrupted",
            intent: "committed",
            has_engine_job: true,
            checkpoint: Some("opaque-checkpoint"),
            deadline_offset_seconds: 60,
            disposition: "unchanged",
            ack: "pending",
            accepted: true,
        },
        Case {
            name: "cloud local failure",
            status: "failed",
            error_code: "invalid_credentials",
            intent: "absent",
            has_engine_job: false,
            checkpoint: Some("opaque-checkpoint"),
            deadline_offset_seconds: 60,
            disposition: "not_started",
            ack: "not_applicable",
            accepted: false,
        },
        Case {
            name: "cancelled",
            status: "cancelled",
            error_code: "internal",
            intent: "committed",
            has_engine_job: true,
            checkpoint: Some("opaque-checkpoint"),
            deadline_offset_seconds: 60,
            disposition: "unchanged",
            ack: "pending",
            accepted: false,
        },
        Case {
            name: "acknowledged",
            status: "failed",
            error_code: "internal",
            intent: "committed",
            has_engine_job: true,
            checkpoint: Some("opaque-checkpoint"),
            deadline_offset_seconds: 60,
            disposition: "unchanged",
            ack: "acknowledged",
            accepted: false,
        },
        Case {
            name: "missing handle",
            status: "failed",
            error_code: "internal",
            intent: "committed",
            has_engine_job: true,
            checkpoint: None,
            deadline_offset_seconds: 60,
            disposition: "unchanged",
            ack: "pending",
            accepted: false,
        },
        Case {
            name: "empty handle",
            status: "failed",
            error_code: "internal",
            intent: "committed",
            has_engine_job: true,
            checkpoint: Some(""),
            deadline_offset_seconds: 60,
            disposition: "unchanged",
            ack: "pending",
            accepted: false,
        },
        Case {
            name: "expired deadline",
            status: "failed",
            error_code: "internal",
            intent: "committed",
            has_engine_job: true,
            checkpoint: Some("opaque-checkpoint"),
            deadline_offset_seconds: -1,
            disposition: "unchanged",
            ack: "pending",
            accepted: false,
        },
    ];

    for (index, case) in cases.iter().enumerate() {
        let id = insert_minimal(&db.pool, Uuid::new_v4(), &format!("resume-{index}")).await;
        let observed_at = Utc::now();
        let result = sqlx::query(
            "UPDATE algolia_import_jobs SET status=$2, error_code=$3,
             dispatch_intent_state=$4, engine_job_id=$5, resume_checkpoint=$6,
             resume_status_observed_at=$7, resume_deadline=$8, resumable=TRUE,
             publication_disposition=$9, engine_ack_state=$10 WHERE id=$1",
        )
        .bind(id)
        .bind(case.status)
        .bind(case.error_code)
        .bind(case.intent)
        .bind(case.has_engine_job.then(Uuid::new_v4))
        .bind(case.checkpoint)
        .bind(observed_at)
        .bind(observed_at + Duration::seconds(case.deadline_offset_seconds))
        .bind(case.disposition)
        .bind(case.ack)
        .execute(&db.pool)
        .await;
        assert_eq!(result.is_ok(), case.accepted, "{}", case.name);
    }

    let id = insert_minimal(&db.pool, Uuid::new_v4(), "oversized-resume-checkpoint").await;
    let observed_at = Utc::now();
    assert!(
        sqlx::query(
            "UPDATE algolia_import_jobs SET status='failed', error_code='internal',
             dispatch_intent_state='committed', engine_job_id=$2, resume_checkpoint=$3,
             resume_status_observed_at=$4, resume_deadline=$5, resumable=TRUE,
             publication_disposition='unchanged', engine_ack_state='pending' WHERE id=$1",
        )
        .bind(id)
        .bind(Uuid::new_v4())
        .bind("x".repeat(1025))
        .bind(observed_at)
        .bind(observed_at + Duration::seconds(60))
        .execute(&db.pool)
        .await
        .is_err(),
        "oversized handle"
    );

    let id = insert_minimal(&db.pool, Uuid::new_v4(), "negative-resume-count").await;
    assert!(
        sqlx::query("UPDATE algolia_import_jobs SET resume_count=-1 WHERE id=$1")
            .bind(id)
            .execute(&db.pool)
            .await
            .is_err()
    );
}

#[tokio::test]
async fn cloud_and_engine_job_identifiers_have_single_owners() {
    let Some(db) = connect_and_migrate("algolia_import_identity").await else {
        return;
    };
    let first = insert_minimal(&db.pool, Uuid::new_v4(), "identity-first").await;
    let second = insert_minimal(&db.pool, Uuid::new_v4(), "identity-second").await;
    let first_cloud_job_id: Uuid =
        sqlx::query_scalar("SELECT cloud_job_id FROM algolia_import_jobs WHERE id=$1")
            .bind(first)
            .fetch_one(&db.pool)
            .await
            .unwrap();

    assert!(
        sqlx::query("UPDATE algolia_import_jobs SET cloud_job_id=$1 WHERE id=$2")
            .bind(first_cloud_job_id)
            .bind(second)
            .execute(&db.pool)
            .await
            .is_err()
    );

    let engine_job_id = Uuid::new_v4();
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET dispatch_intent_state='committed', engine_job_id=$1 WHERE id=$2",
    )
    .bind(engine_job_id)
    .bind(first)
    .execute(&db.pool)
    .await
    .unwrap();
    assert!(sqlx::query(
        "UPDATE algolia_import_jobs
         SET dispatch_intent_state='committed', engine_job_id=$1 WHERE id=$2",
    )
    .bind(engine_job_id)
    .bind(second)
    .execute(&db.pool)
    .await
    .is_err());
}

async fn assert_closed_statuses(pool: &PgPool, id: Uuid) {
    for status in [
        "queued",
        "validating_source",
        "copying_configuration",
        "copying_documents",
        "verifying",
        "promoting",
        "cancelling",
        "cancelled",
        "resuming",
        "completed",
        "completed_with_warnings",
        "failed",
    ] {
        let terminal = matches!(
            status,
            "cancelled" | "completed" | "completed_with_warnings" | "failed"
        );
        sqlx::query(
            "UPDATE algolia_import_jobs
             SET status=$1, error_code=NULL, publication_disposition=$2,
                 engine_ack_state='pending', dispatch_intent_state=$3, engine_job_id=$4
             WHERE id=$5",
        )
        .bind(status)
        .bind(if status == "cancelled" {
            "unchanged"
        } else {
            "not_started"
        })
        .bind(if terminal { "committed" } else { "absent" })
        .bind(terminal.then(Uuid::new_v4))
        .bind(id)
        .execute(pool)
        .await
        .expect("accepted status");
    }
}

async fn assert_ack_states(pool: &PgPool, id: Uuid) {
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status='queued', error_code=NULL, publication_disposition='not_started',
             engine_ack_state='pending', dispatch_intent_state='absent', engine_job_id=NULL
         WHERE id=$1",
    )
    .bind(id)
    .execute(pool)
    .await
    .expect("accepted pending ACK state");
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status='interrupted', error_code='interrupted',
             publication_disposition='not_started', engine_ack_state='seal_acknowledged',
             dispatch_intent_state='committed', engine_job_id=NULL WHERE id=$1",
    )
    .bind(id)
    .execute(pool)
    .await
    .expect("accepted seal ACK state");
    for ack in ["outbox_pending", "acknowledged"] {
        sqlx::query(
            "UPDATE algolia_import_jobs
             SET status='completed', error_code=NULL, publication_disposition='promoted',
                 engine_ack_state=$1, dispatch_intent_state='committed', engine_job_id=$2
             WHERE id=$3",
        )
        .bind(ack)
        .bind(Uuid::new_v4())
        .bind(id)
        .execute(pool)
        .await
        .expect("accepted terminal ACK state");
    }
}

async fn assert_error_codes_and_dispositions(pool: &PgPool, id: Uuid) {
    for code in [
        "invalid_credentials",
        "missing_source_permission",
        "source_not_found",
        "source_catalog_too_large",
        "destination_conflict",
        "quota_exceeded",
        "source_too_large",
        "insufficient_engine_storage",
        "destination_changed",
        "source_changed",
        "incompatible_data",
        "engine_upgrade_required",
        "migration_ha_not_supported",
        "migration_provider_unsupported",
        "backend_unavailable",
        "cancel_not_permitted",
        "not_resumable",
        "internal",
    ] {
        sqlx::query(
            "UPDATE algolia_import_jobs
             SET status='completed', error_code=$1, engine_ack_state='pending' WHERE id=$2",
        )
        .bind(code)
        .bind(id)
        .execute(pool)
        .await
        .expect("accepted stable error code");
    }
    for disposition in ["not_started", "unchanged", "promoted", "unknown"] {
        sqlx::query(
            "UPDATE algolia_import_jobs
             SET status='completed', error_code=NULL, engine_ack_state='pending',
                 publication_disposition=$1 WHERE id=$2",
        )
        .bind(disposition)
        .bind(id)
        .execute(pool)
        .await
        .expect("accepted publication disposition");
    }
}

async fn assert_interrupted_origins(pool: &PgPool, id: Uuid) {
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status='interrupted', error_code='interrupted',
             publication_disposition='not_started', engine_ack_state='seal_acknowledged',
             dispatch_intent_state='committed', engine_job_id=NULL WHERE id=$1",
    )
    .bind(id)
    .execute(pool)
    .await
    .expect("legal cloud interrupted origin");
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status='interrupted', error_code='interrupted', publication_disposition='unchanged',
             engine_ack_state='pending', dispatch_intent_state='committed', engine_job_id=$1
         WHERE id=$2",
    )
    .bind(Uuid::new_v4())
    .bind(id)
    .execute(pool)
    .await
    .expect("legal engine interrupted origin");
    for disposition in ["promoted", "unknown"] {
        assert!(sqlx::query(
            "UPDATE algolia_import_jobs
             SET status='interrupted', error_code='interrupted', publication_disposition=$1,
                 engine_ack_state='pending', dispatch_intent_state='committed', engine_job_id=$2
             WHERE id=$3",
        )
        .bind(disposition)
        .bind(Uuid::new_v4())
        .bind(id)
        .execute(pool)
        .await
        .is_err());
    }
}

#[tokio::test]
async fn schema_rejects_invalid_closed_values_and_interrupted_publication() {
    let Some(db) = connect_and_migrate("algolia_import_checks").await else {
        return;
    };
    let id = insert_minimal(&db.pool, Uuid::new_v4(), "checks").await;

    for (column, invalid) in [
        ("status", "invented"),
        ("engine_ack_state", "invented"),
        ("publication_disposition", "invented"),
        ("error_code", "invented"),
        ("dispatch_intent_state", "invented"),
    ] {
        let sql = format!("UPDATE algolia_import_jobs SET {column} = $1 WHERE id = $2");
        assert!(sqlx::query(&sql)
            .bind(invalid)
            .bind(id)
            .execute(&db.pool)
            .await
            .is_err());
    }
    assert_closed_statuses(&db.pool, id).await;
    assert_ack_states(&db.pool, id).await;
    assert_error_codes_and_dispositions(&db.pool, id).await;
    assert_interrupted_origins(&db.pool, id).await;
}

#[tokio::test]
async fn no_dispatch_failure_requires_absent_intent_proof() {
    let Some(db) = connect_and_migrate("algolia_no_dispatch").await else {
        return;
    };
    let id = insert_minimal(&db.pool, Uuid::new_v4(), "no-dispatch").await;
    sqlx::query("UPDATE algolia_import_jobs SET status='failed', error_code='invalid_credentials', dispatch_intent_state='absent', engine_ack_state='not_applicable' WHERE id=$1")
        .bind(id).execute(&db.pool).await.expect("persist proven cloud-local failure");
    for intent in ["committed", "ambiguous"] {
        assert!(sqlx::query("UPDATE algolia_import_jobs SET dispatch_intent_state=$1, engine_ack_state='not_applicable' WHERE id=$2")
            .bind(intent).bind(id).execute(&db.pool).await.is_err());
    }
    assert!(
        sqlx::query("UPDATE algolia_import_jobs SET engine_ack_state='pending' WHERE id=$1")
            .bind(id)
            .execute(&db.pool)
            .await
            .is_err()
    );
}

#[tokio::test]
async fn repository_no_dispatch_write_is_atomic_and_refuses_committed_intent() {
    let Some(db) = connect_and_migrate("algolia_repo_no_dispatch").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let local_failure_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, local_failure_customer, 1).await;
    let local_failure = repo
        .create(new_job(local_failure_customer, "local-failure"))
        .await
        .unwrap();
    let failed = repo
        .record_no_dispatch_failure(
            local_failure.id,
            AlgoliaImportErrorCode::InvalidCredentials,
            Some("source credential rejected"),
        )
        .await
        .unwrap();
    assert_eq!(failed.status, AlgoliaImportJobStatus::Failed);
    assert_eq!(
        failed.engine_ack_state,
        AlgoliaImportEngineAckState::NotApplicable
    );
    assert_eq!(
        failed.dispatch_intent_state,
        AlgoliaImportDispatchIntentState::Absent
    );

    let dispatched_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, dispatched_customer, 1).await;
    let dispatched = repo
        .create(new_job(dispatched_customer, "dispatched"))
        .await
        .unwrap();
    sqlx::query("UPDATE algolia_import_jobs SET dispatch_intent_state='committed' WHERE id=$1")
        .bind(dispatched.id)
        .execute(&db.pool)
        .await
        .unwrap();
    assert!(matches!(
        repo.record_no_dispatch_failure(
            dispatched.id,
            AlgoliaImportErrorCode::InvalidCredentials,
            None
        )
        .await,
        Err(RepoError::Conflict(_))
    ));
}

#[tokio::test]
async fn repository_cannot_resurrect_proven_no_dispatch_failure() {
    let Some(db) = connect_and_migrate("algolia_no_dispatch_terminal").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let created = repo
        .create(new_job(customer_id, "terminal-proof"))
        .await
        .unwrap();
    let failed = repo
        .record_no_dispatch_failure(created.id, AlgoliaImportErrorCode::InvalidCredentials, None)
        .await
        .unwrap();
    let resurrected = AlgoliaImportJobState {
        status: AlgoliaImportJobStatus::Failed,
        publication_disposition: AlgoliaImportPublicationDisposition::NotStarted,
        engine_ack_state: AlgoliaImportEngineAckState::Pending,
        dispatch_intent_state: AlgoliaImportDispatchIntentState::Committed,
        engine_job_id: Some(Uuid::new_v4()),
        lifecycle_generation: failed.lifecycle_generation,
        retryable: false,
        resume_intent_generation: failed.resume_intent_generation,
        resume_mirror: None,
        resumable: false,
        resume_count: failed.resume_count,
        summary: failed.summary,
        warnings: failed.warnings,
        error_code: failed.error_code,
        error_message: failed.error_message,
    };
    assert!(matches!(
        repo.update_persisted_state(failed.id, resurrected).await,
        Err(RepoError::Conflict(_))
    ));
    assert_eq!(
        repo.get(failed.id).await.unwrap().unwrap().engine_ack_state,
        AlgoliaImportEngineAckState::NotApplicable
    );
}

#[tokio::test]
async fn repository_owns_idempotency_and_canonical_updates() {
    let Some(db) = connect_and_migrate("algolia_import_repo").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let created = repo.create(new_job(customer_id, "same-key")).await.unwrap();
    assert_eq!(created.status, AlgoliaImportJobStatus::Queued);
    assert_eq!(created.tenant_id, "products");
    assert_eq!(created.resume_intent_generation, 0);
    assert_eq!(created.summary, AlgoliaImportSummary::default());

    let replayed = repo.create(new_job(customer_id, "same-key")).await.unwrap();
    assert_eq!(
        replayed.id, created.id,
        "same customer idempotency key and canonical fingerprint must return the original job"
    );
    assert!(matches!(
        repo.create(new_job_with_fingerprint(
            customer_id,
            "same-key",
            "sha256:different-canonical-request"
        ))
        .await,
        Err(AlgoliaImportJobAdmissionError::Refused(
            AlgoliaImportErrorCode::DestinationConflict
        )),
    ));
    let other_customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, other_customer_id, 1).await;
    assert!(repo
        .create(new_job(other_customer_id, "same-key"))
        .await
        .is_ok());
    assert_eq!(
        repo.find_by_idempotency_key(customer_id, "same-key")
            .await
            .unwrap()
            .unwrap()
            .id,
        created.id
    );

    let engine_job_id = Uuid::new_v4();
    repo.record_dispatch_intent_committed(created.id, engine_job_id)
        .await
        .expect("commit dispatch identity before engine state updates");
    let illegal_jump = AlgoliaImportJobState {
        status: AlgoliaImportJobStatus::CopyingDocuments,
        publication_disposition: AlgoliaImportPublicationDisposition::Unchanged,
        engine_ack_state: AlgoliaImportEngineAckState::Pending,
        dispatch_intent_state: AlgoliaImportDispatchIntentState::Committed,
        engine_job_id: Some(engine_job_id),
        lifecycle_generation: 1,
        retryable: true,
        resume_intent_generation: 2,
        resume_mirror: None,
        resumable: false,
        resume_count: 0,
        summary: AlgoliaImportSummary {
            documents_expected: 10,
            documents_imported: 8,
            documents_rejected: 2,
            settings_applied: 3,
            settings_unsupported: 1,
            synonyms_expected: 4,
            synonyms_imported: 3,
            synonyms_rejected: 1,
            rules_expected: 2,
            rules_imported: 2,
            rules_rejected: 0,
        },
        warnings: json!([{"code": "unsupported_setting"}]),
        error_code: None,
        error_message: None,
    };
    assert!(matches!(
        repo.update_persisted_state(created.id, illegal_jump.clone())
            .await,
        Err(RepoError::Conflict(_))
    ));

    let state = AlgoliaImportJobState {
        status: AlgoliaImportJobStatus::ValidatingSource,
        ..illegal_jump
    };
    let updated = repo
        .update_persisted_state(created.id, state.clone())
        .await
        .unwrap();
    assert_eq!(updated.summary, state.summary);
    assert_eq!(updated.warnings, state.warnings);

    let mut impossible_ack_state = state.clone();
    impossible_ack_state.engine_ack_state = AlgoliaImportEngineAckState::SealAcknowledged;
    assert!(matches!(
        repo.update_persisted_state(created.id, impossible_ack_state)
            .await,
        Err(RepoError::Conflict(_))
    ));

    let mut terminal_without_engine = state.clone();
    terminal_without_engine.status = AlgoliaImportJobStatus::Failed;
    terminal_without_engine.dispatch_intent_state = AlgoliaImportDispatchIntentState::Absent;
    terminal_without_engine.engine_job_id = None;
    terminal_without_engine.error_code = Some(AlgoliaImportErrorCode::InvalidCredentials);
    assert!(matches!(
        repo.update_persisted_state(created.id, terminal_without_engine)
            .await,
        Err(RepoError::Conflict(_))
    ));

    let mut stale_state = state;
    stale_state.resume_intent_generation = 1;
    assert!(matches!(
        repo.update_persisted_state(created.id, stale_state).await,
        Err(RepoError::Conflict(_))
    ));
}

#[test]
fn public_model_has_no_secret_or_raw_vendor_payload_fields() {
    let source = include_str!("../../src/models/algolia_import_job.rs");
    assert!(source.contains("pub tenant_id: String"));
    assert!(source.contains("pub publication_disposition: AlgoliaImportPublicationDisposition"));
    let public_fields: Vec<_> = source
        .lines()
        .map(str::trim)
        .filter(|line| line.starts_with("pub "))
        .collect();
    assert!(["credential", "api_key", "raw_response", "vendor_response"]
        .iter()
        .all(|forbidden| !public_fields
            .iter()
            .any(|line| line.to_ascii_lowercase().contains(forbidden))));
}

#[test]
fn algolia_destination_admission_reuses_index_lifecycle_seams() {
    let lifecycle = include_str!("../../src/routes/indexes/lifecycle.rs");
    let shared_vm = include_str!("../../src/routes/indexes/shared_vm.rs");
    let indexes = include_str!("../../src/routes/indexes/mod.rs");
    let model = include_str!("../../src/models/algolia_import_job.rs");

    assert!(lifecycle.contains("admit_new_index_destination("));
    assert!(lifecycle.contains("create_index_on_shared_vm("));
    assert!(shared_vm.contains("pub(crate) async fn reserve_shared_vm_destination("));
    assert!(shared_vm.contains("pub(crate) async fn create_shared_deployment("));
    assert!(indexes.contains("pub(crate) struct AdmittedIndexDestination"));
    assert!(indexes.contains("pub(crate) fn admitted_flapjack_index_uid("));
    assert!(indexes.contains("flapjack_index_uid(customer_id, index_name)"));
    assert!(model.contains("flapjack_node::flapjack_index_uid("));

    let algolia_admission = lifecycle
        .split("pub async fn create_algolia_import_job(")
        .nth(1)
        .expect("indexes lifecycle must own Algolia create admission");
    assert!(algolia_admission.contains("admit_new_index_destination("));
    assert!(algolia_admission.contains("provider_for_region("));
    assert!(algolia_admission.contains("reserve_shared_vm_destination("));
    assert!(algolia_admission.contains("ensure_algolia_import_engine_compatible("));
    assert!(algolia_admission.contains("destination.flapjack_uid()"));
    assert!(algolia_admission.contains("PgAlgoliaImportJobRepo::new("));
    for forbidden in [
        "producer_revision",
        "workspaceDigest",
        "binary_sha256",
        "capabilities",
        "runtime_security",
    ] {
        assert!(
            !algolia_admission.contains(forbidden),
            "Algolia admission must delegate Flapjack identity parsing for {forbidden}"
        );
    }
}

#[test]
fn algolia_domain_does_not_copy_lifecycle_quota_placement_or_uid_logic() {
    let model = include_str!("../../src/models/algolia_import_job.rs");
    let repo = include_str!("../../src/repos/pg_algolia_import_job_repo.rs");
    let lifecycle = include_str!("../../src/routes/indexes/lifecycle.rs");
    let shared_vm = include_str!("../../src/routes/indexes/shared_vm.rs");

    for source in [model, repo] {
        assert!(!source.contains("max_indexes"));
        assert!(!source.contains("free_tier_limits"));
        assert!(!source.contains("count_by_customer"));
        assert!(!source.contains("place_index("));
        assert!(!source.contains("as_simple()"));
    }
    assert!(lifecycle.contains("resolve_customer_quota("));
    assert!(lifecycle.contains("validate_index_name("));
    assert!(shared_vm.contains("place_index("));
}

// ---------------------------------------------------------------------------
// Provider gating: create destinations only allow AWS-backed regions
// ---------------------------------------------------------------------------

#[test]
fn algolia_create_rejects_hetzner_backed_region() {
    let config = RegionConfig::defaults();
    for hetzner_region in ["eu-central-1", "eu-north-1", "us-east-2", "us-west-1"] {
        assert_eq!(
            config.provider_for_region(hetzner_region),
            Some("hetzner"),
            "precondition: {hetzner_region} should be hetzner"
        );
        let result = api::models::algolia_import_job::validate_algolia_create_provider(
            &config,
            hetzner_region,
        );
        assert_eq!(
            result,
            Err(AlgoliaImportErrorCode::MigrationProviderUnsupported),
            "Hetzner region {hetzner_region} must be rejected for Algolia import"
        );
    }
}

#[test]
fn algolia_create_rejects_unknown_region() {
    let config = RegionConfig::defaults();
    let result = api::models::algolia_import_job::validate_algolia_create_provider(
        &config,
        "ap-southeast-99",
    );
    assert_eq!(
        result,
        Err(AlgoliaImportErrorCode::MigrationProviderUnsupported),
    );
}

#[test]
fn algolia_create_accepts_aws_backed_region() {
    let config = RegionConfig::defaults();
    for aws_region in ["us-east-1", "eu-west-1"] {
        assert_eq!(
            config.provider_for_region(aws_region),
            Some("aws"),
            "precondition: {aws_region} should be aws"
        );
        let result =
            api::models::algolia_import_job::validate_algolia_create_provider(&config, aws_region);
        assert!(
            result.is_ok(),
            "AWS region {aws_region} must be accepted for Algolia import"
        );
    }
}

#[test]
fn algolia_create_exposes_only_aws_eligible_regions() {
    let config = RegionConfig::defaults();
    let eligible = api::models::algolia_import_job::algolia_eligible_regions(&config);
    assert!(
        !eligible.is_empty(),
        "at least one AWS region must be eligible"
    );
    for (id, entry) in &eligible {
        assert_eq!(
            entry.provider, "aws",
            "eligible region {id} must be AWS-backed"
        );
        assert!(entry.available, "eligible region {id} must be available");
    }
    let all_aws: Vec<_> = config
        .available_regions()
        .into_iter()
        .filter(|(_, e)| e.provider == "aws")
        .collect();
    assert_eq!(
        eligible.len(),
        all_aws.len(),
        "eligible list must match all available AWS regions"
    );
}

#[test]
fn algolia_create_rejects_unavailable_aws_region() {
    use api::provisioner::region_map::RegionEntry;
    use std::collections::HashMap;
    let mut regions = HashMap::new();
    regions.insert(
        "us-east-1".to_string(),
        RegionEntry {
            provider: "aws".to_string(),
            provider_location: "us-east-1".to_string(),
            display_name: "US East".to_string(),
            available: false,
        },
    );
    let config = RegionConfig::from_regions(regions);
    let result =
        api::models::algolia_import_job::validate_algolia_create_provider(&config, "us-east-1");
    assert_eq!(
        result,
        Err(AlgoliaImportErrorCode::MigrationProviderUnsupported),
        "unavailable AWS region must be rejected"
    );
}

// ---------------------------------------------------------------------------
// Provider gating: replace targets require eligible AWS-backed VM
// ---------------------------------------------------------------------------

fn eligible_replace_facts() -> AlgoliaReplaceTargetFacts {
    AlgoliaReplaceTargetFacts {
        provider: "aws".into(),
        vm_status: "active".into(),
        deployment_status: "active".into(),
        health_status: "healthy".into(),
        service_type: "flapjack".into(),
        has_active_lifecycle_operation: false,
        has_active_import_lease: false,
        has_flapjack_url: true,
    }
}

#[test]
fn algolia_replace_accepts_eligible_aws_target() {
    let facts = eligible_replace_facts();
    assert!(facts.validate().is_ok());
}

#[test]
fn algolia_replace_rejects_hetzner_provider() {
    let mut facts = eligible_replace_facts();
    facts.provider = "hetzner".into();
    assert_eq!(
        facts.validate(),
        Err(AlgoliaImportErrorCode::MigrationProviderUnsupported),
    );
}

#[test]
fn algolia_replace_rejects_gcp_oci_bare_metal_local_unknown_providers() {
    for provider in ["gcp", "oci", "bare-metal", "local", "unknown", ""] {
        let mut facts = eligible_replace_facts();
        facts.provider = provider.into();
        assert_eq!(
            facts.validate(),
            Err(AlgoliaImportErrorCode::MigrationProviderUnsupported),
            "provider '{provider}' must be rejected"
        );
    }
}

#[test]
fn algolia_replace_rejects_inactive_vm() {
    let mut facts = eligible_replace_facts();
    facts.vm_status = "terminated".into();
    assert_eq!(
        facts.validate(),
        Err(AlgoliaImportErrorCode::BackendUnavailable),
    );
}

#[test]
fn algolia_replace_rejects_inactive_deployment() {
    let mut facts = eligible_replace_facts();
    facts.deployment_status = "terminated".into();
    assert_eq!(
        facts.validate(),
        Err(AlgoliaImportErrorCode::BackendUnavailable),
    );
}

#[test]
fn algolia_replace_rejects_unhealthy_target() {
    let mut facts = eligible_replace_facts();
    facts.health_status = "unhealthy".into();
    assert_eq!(
        facts.validate(),
        Err(AlgoliaImportErrorCode::BackendUnavailable),
    );
}

#[test]
fn algolia_replace_rejects_non_standalone_service_types() {
    for service_type in ["shared", "shared_flapjack", "ha", "", "unknown"] {
        let mut facts = eligible_replace_facts();
        facts.service_type = service_type.into();

        assert_eq!(
            facts.validate(),
            Err(AlgoliaImportErrorCode::MigrationHaNotSupported),
            "service type '{service_type}' must not be eligible for replacement"
        );
    }
}

#[test]
fn algolia_replace_rejects_active_lifecycle_operation() {
    let mut facts = eligible_replace_facts();
    facts.has_active_lifecycle_operation = true;
    assert_eq!(
        facts.validate(),
        Err(AlgoliaImportErrorCode::DestinationConflict),
    );
}

#[test]
fn algolia_replace_rejects_active_import_lease() {
    let mut facts = eligible_replace_facts();
    facts.has_active_import_lease = true;
    assert_eq!(
        facts.validate(),
        Err(AlgoliaImportErrorCode::DestinationConflict),
    );
}

#[test]
fn algolia_replace_rejects_missing_flapjack_url() {
    let mut facts = eligible_replace_facts();
    facts.has_flapjack_url = false;
    assert_eq!(
        facts.validate(),
        Err(AlgoliaImportErrorCode::BackendUnavailable),
    );
}

#[test]
fn algolia_replace_provider_check_takes_priority_over_other_failures() {
    let facts = AlgoliaReplaceTargetFacts {
        provider: "hetzner".into(),
        vm_status: "terminated".into(),
        deployment_status: "terminated".into(),
        health_status: "unhealthy".into(),
        service_type: "flapjack".into(),
        has_active_lifecycle_operation: true,
        has_active_import_lease: true,
        has_flapjack_url: false,
    };
    assert_eq!(
        facts.validate(),
        Err(AlgoliaImportErrorCode::MigrationProviderUnsupported),
        "provider check must be the first gate"
    );
}

// ---------------------------------------------------------------------------
// Credential-free replace-target eligibility snapshot (Stage 2, group 1)
// ---------------------------------------------------------------------------
//
// The eligibility endpoint's `target` phase must read the current customer
// routing generation and re-authenticate the concrete replace target before
// issuing a signed binding, reusing the same locked-generation and
// authenticated replace-target queries the create path already owns. These
// tests pin that repository snapshot: it returns the current generation, the
// authoritative destination region, and the derived routing identity for an
// owned healthy standalone AWS flapjack target, and rejects every ineligible
// state with the same typed codes create admission would raise — without
// mutating any row.

async fn seeded_customer_generation(pool: &PgPool, customer_id: Uuid) -> i64 {
    sqlx::query_scalar("SELECT lifecycle_generation FROM customers WHERE id = $1")
        .bind(customer_id)
        .fetch_one(pool)
        .await
        .expect("read customer generation")
}

#[tokio::test]
async fn algolia_cloud_job_eligibility_snapshot_authenticates_owned_healthy_target() {
    let Some(db) = connect_and_migrate("algolia_eligibility_snapshot_ok").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_replace_target(&db.pool, customer_id, "products").await;
    let expected_generation = seeded_customer_generation(&db.pool, customer_id).await;

    let snapshot = repo
        .snapshot_replace_target_eligibility(customer_id, "products")
        .await
        .expect("owned healthy AWS target is eligible");

    assert_eq!(snapshot.lifecycle_generation, expected_generation);
    assert_eq!(snapshot.region, "us-east-1");
    assert_eq!(
        snapshot.routing_identity,
        api::services::flapjack_node::flapjack_index_uid(customer_id, "products")
    );

    // A snapshot is a read; it must not consume the reservation or leave a job.
    let jobs: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM algolia_import_jobs")
        .fetch_one(&db.pool)
        .await
        .expect("count import jobs");
    assert_eq!(jobs, 0);
}

#[tokio::test]
async fn algolia_cloud_job_eligibility_snapshot_rejects_missing_target() {
    let Some(db) = connect_and_migrate("algolia_eligibility_snapshot_missing").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;

    let error = repo
        .snapshot_replace_target_eligibility(customer_id, "does-not-exist")
        .await
        .expect_err("a replace target that does not exist is not eligible");
    assert_eq!(
        error,
        api::repos::DestinationEligibilityError::TargetNotFound,
        "got {error:?}"
    );
}

#[tokio::test]
async fn algolia_cloud_job_eligibility_snapshot_rejects_cross_customer_target() {
    let Some(db) = connect_and_migrate("algolia_eligibility_snapshot_cross").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let owner_id = Uuid::new_v4();
    let intruder_id = Uuid::new_v4();
    insert_replace_target(&db.pool, owner_id, "products").await;
    insert_active_customer(&db.pool, intruder_id, 1).await;

    let error = repo
        .snapshot_replace_target_eligibility(intruder_id, "products")
        .await
        .expect_err("another customer's target must not be eligible");
    assert_eq!(
        error,
        api::repos::DestinationEligibilityError::TargetNotFound,
        "got {error:?}"
    );
}

#[tokio::test]
async fn algolia_cloud_job_eligibility_snapshot_rejects_inactive_customer() {
    let Some(db) = connect_and_migrate("algolia_eligibility_snapshot_inactive").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_replace_target(&db.pool, customer_id, "products").await;
    sqlx::query("UPDATE customers SET status = 'suspended' WHERE id = $1")
        .bind(customer_id)
        .execute(&db.pool)
        .await
        .expect("suspend customer lifecycle");

    let error = repo
        .snapshot_replace_target_eligibility(customer_id, "products")
        .await
        .expect_err("a non-active customer cannot pin a routing generation");
    assert_eq!(
        error,
        api::repos::DestinationEligibilityError::LifecycleUnavailable,
        "got {error:?}"
    );
}

#[tokio::test]
async fn algolia_cloud_job_eligibility_snapshot_rejects_unhealthy_target() {
    let Some(db) = connect_and_migrate("algolia_eligibility_snapshot_unhealthy").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_replace_target(&db.pool, customer_id, "products").await;
    sqlx::query(
        "UPDATE customer_deployments SET health_status = 'degraded' WHERE customer_id = $1",
    )
    .bind(customer_id)
    .execute(&db.pool)
    .await
    .expect("degrade target health");

    let error = repo
        .snapshot_replace_target_eligibility(customer_id, "products")
        .await
        .expect_err("an unhealthy target is not eligible");
    assert_eq!(
        error,
        api::repos::DestinationEligibilityError::Ineligible(
            AlgoliaImportErrorCode::BackendUnavailable
        ),
        "got {error:?}"
    );
}

// ---------------------------------------------------------------------------
// Tenant-scoped retained get / keyset list primitives (Stage 2, group 3)
// ---------------------------------------------------------------------------

async fn insert_retained_job(
    pool: &PgPool,
    customer_id: Uuid,
    id: Uuid,
    key_suffix: &str,
    created_at: chrono::DateTime<Utc>,
) {
    // A distinct logical target per job avoids the partial unique index on
    // active (customer_id, logical_target); retained get/list do not depend on
    // target uniqueness.
    let target = format!("products-{key_suffix}");
    let destination_vm_id = Uuid::new_v4();
    insert_vm_with_id(
        pool,
        destination_vm_id,
        &format!("algolia-retained-{destination_vm_id}"),
        "active",
    )
    .await;
    sqlx::query(
        "INSERT INTO algolia_import_jobs
         (id, customer_id, tenant_id, algolia_app_id, destination_kind, logical_target,
          destination_region, destination_deployment_id, destination_vm_id, physical_uid,
          source_name, idempotency_key, canonical_fingerprint, routing_identity,
          source_size_bytes, lifecycle_generation, created_at, updated_at)
         VALUES ($1, $2, $7, 'AB12CD34EF', 'replace', $7, 'us-east-1',
                 $3, $4, 'physical', 'source', $5, 'sha256:fingerprint', 'tenant/products',
                 100, 1, $6, $6)",
    )
    .bind(id)
    .bind(customer_id)
    .bind(Uuid::new_v4())
    .bind(destination_vm_id)
    .bind(format!("retained-key-{key_suffix}"))
    .bind(created_at)
    .bind(target)
    .execute(pool)
    .await
    .expect("insert retained import job");
}

/// Drive a retained job into the fully-scrubbed erased shape the table's
/// erasure check constraint requires (all business columns NULL, tombstone
/// fields set), so retained get/list exclusion can be exercised.
async fn erase_retained_job(pool: &PgPool, id: Uuid) {
    sqlx::query(
        "UPDATE algolia_import_jobs SET
            erased_at = now(), erasure_handle = gen_random_uuid(),
            cleanup_phase = 'engine_disposition_required',
            customer_id = NULL, tenant_id = NULL, algolia_app_id = NULL, destination_kind = NULL,
            logical_target = NULL, destination_region = NULL, destination_deployment_id = NULL,
            destination_vm_id = NULL, physical_uid = NULL, source_name = NULL, cloud_job_id = NULL,
            dispatch_intent_state = NULL, lifecycle_generation = NULL, idempotency_key = NULL,
            canonical_fingerprint = NULL, routing_identity = NULL, source_size_bytes = NULL,
            reserved_index_count = NULL, reserved_customer_storage_bytes = NULL,
            reserved_node_transient_bytes = NULL, retryable = NULL, worker_claimed_at = NULL,
            worker_lease_expires_at = NULL, cancel_requested_at = NULL,
            resume_intent_generation = NULL, resume_checkpoint = NULL, resume_deadline = NULL,
            resume_status_observed_at = NULL, resumable = NULL, resume_count = NULL,
            documents_expected = NULL, documents_imported = NULL, documents_rejected = NULL,
            settings_applied = NULL, settings_unsupported = NULL, synonyms_expected = NULL,
            synonyms_imported = NULL, synonyms_rejected = NULL, rules_expected = NULL,
            rules_imported = NULL, rules_rejected = NULL, warnings = NULL, error_code = NULL,
            error_message = NULL, status = NULL, terminal_at = NULL
         WHERE id = $1",
    )
    .bind(id)
    .execute(pool)
    .await
    .expect("erase retained job");
}

#[test]
fn algolia_cloud_job_list_limit_clamps_default_and_max() {
    use api::repos::clamp_algolia_import_job_list_limit as clamp;
    assert_eq!(clamp(None), 50);
    assert_eq!(clamp(Some(0)), 50);
    assert_eq!(clamp(Some(-5)), 50);
    assert_eq!(clamp(Some(1)), 1);
    assert_eq!(clamp(Some(50)), 50);
    assert_eq!(clamp(Some(200)), 200);
    assert_eq!(clamp(Some(201)), 200);
    assert_eq!(clamp(Some(10_000)), 200);
}

#[tokio::test]
async fn algolia_cloud_job_get_for_customer_enforces_ownership_in_sql() {
    let Some(db) = connect_and_migrate("algolia_retained_get").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let owner = Uuid::new_v4();
    let intruder = Uuid::new_v4();
    insert_active_customer(&db.pool, owner, 1).await;
    insert_active_customer(&db.pool, intruder, 1).await;
    let job_id = Uuid::new_v4();
    insert_retained_job(&db.pool, owner, job_id, "get", Utc::now()).await;

    assert!(repo
        .get_for_customer(owner, job_id)
        .await
        .expect("owner read")
        .is_some());
    assert!(
        repo.get_for_customer(intruder, job_id)
            .await
            .expect("intruder read")
            .is_none(),
        "ownership must be enforced in SQL, not by fetch-then-compare"
    );

    erase_retained_job(&db.pool, job_id).await;
    assert!(repo
        .get_for_customer(owner, job_id)
        .await
        .expect("erased read")
        .is_none());
}

#[tokio::test]
async fn algolia_cloud_job_list_for_customer_orders_newest_first_with_id_tiebreak() {
    let Some(db) = connect_and_migrate("algolia_retained_order").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let base = Utc::now();
    let older = base - Duration::seconds(60);
    // Two jobs share a created_at so the id tie-break (DESC) is exercised.
    let tie_low = Uuid::parse_str("00000000-0000-0000-0000-000000000001").unwrap();
    let tie_high = Uuid::parse_str("ffffffff-0000-0000-0000-000000000000").unwrap();
    let newest = Uuid::new_v4();
    insert_retained_job(&db.pool, customer, tie_low, "tie-low", older).await;
    insert_retained_job(&db.pool, customer, tie_high, "tie-high", older).await;
    insert_retained_job(&db.pool, customer, newest, "newest", base).await;

    let page = repo
        .list_for_customer(customer, None, 10)
        .await
        .expect("list page");
    let ids: Vec<Uuid> = page.jobs.iter().map(|job| job.id).collect();
    // newest created_at first, then within the tie the larger id first.
    assert_eq!(ids, vec![newest, tie_high, tie_low]);
    assert!(
        !page.has_more,
        "three rows under a limit of ten cannot have another page"
    );
}

#[tokio::test]
async fn algolia_cloud_job_list_for_customer_keyset_paginates_without_gaps() {
    let Some(db) = connect_and_migrate("algolia_retained_keyset").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let base = Utc::now();
    let mut expected = Vec::new();
    for index in 0..5 {
        let id = Uuid::new_v4();
        // Distinct, strictly decreasing created_at so the expected order is stable.
        insert_retained_job(
            &db.pool,
            customer,
            id,
            &format!("page-{index}"),
            base - Duration::seconds(index),
        )
        .await;
        expected.push((base - Duration::seconds(index), id));
    }
    // expected is already newest-first (index 0 is the newest).

    let mut seen = Vec::new();
    let mut cursor: Option<api::repos::AlgoliaImportJobListCursor> = None;
    loop {
        let page = repo
            .list_for_customer(customer, cursor, 2)
            .await
            .expect("keyset page");
        for job in &page.jobs {
            seen.push(job.id);
        }
        let Some(last) = page.jobs.last() else {
            break;
        };
        cursor = Some(api::repos::AlgoliaImportJobListCursor {
            created_at: last.created_at,
            id: last.id,
        });
        // The lookahead flag, not row count, decides when to stop paging.
        if !page.has_more {
            break;
        }
    }

    let expected_ids: Vec<Uuid> = expected.iter().map(|(_, id)| *id).collect();
    assert_eq!(
        seen, expected_ids,
        "keyset paging must have no gaps or duplicates"
    );
}

#[tokio::test]
async fn algolia_cloud_job_list_for_customer_excludes_erased_and_other_customers() {
    let Some(db) = connect_and_migrate("algolia_retained_isolation").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    let other = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    insert_active_customer(&db.pool, other, 1).await;
    let base = Utc::now();
    let kept = Uuid::new_v4();
    let erased = Uuid::new_v4();
    let foreign = Uuid::new_v4();
    insert_retained_job(&db.pool, customer, kept, "kept", base).await;
    insert_retained_job(
        &db.pool,
        customer,
        erased,
        "erased",
        base - Duration::seconds(1),
    )
    .await;
    insert_retained_job(&db.pool, other, foreign, "foreign", base).await;
    erase_retained_job(&db.pool, erased).await;

    let page = repo
        .list_for_customer(customer, None, 50)
        .await
        .expect("list page");
    let ids: Vec<Uuid> = page.jobs.iter().map(|job| job.id).collect();
    assert_eq!(
        ids,
        vec![kept],
        "erased rows and other customers must be excluded"
    );
}

/// The repository's own `has_more` flag must come from a `limit + 1` lookahead,
/// not from `len == limit`, so an exact-full page (and the final page of an
/// exact multiple of the page size) reports no further page.
#[tokio::test]
async fn algolia_cloud_job_list_for_customer_exact_full_page_reports_no_more() {
    let Some(db) = connect_and_migrate("algolia_retained_exact_full").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let base = Utc::now();
    let mut ids = Vec::new();
    for index in 0..4 {
        let id = Uuid::new_v4();
        insert_retained_job(
            &db.pool,
            customer,
            id,
            &format!("full-{index}"),
            base - Duration::seconds(index),
        )
        .await;
        ids.push(id);
    }

    // Requesting exactly as many rows as exist: full page, but no lookahead row.
    let page = repo
        .list_for_customer(customer, None, 4)
        .await
        .expect("exact-full page");
    assert_eq!(page.jobs.len(), 4);
    assert!(
        !page.has_more,
        "an exact-full page with no further row must report has_more=false"
    );

    // Exact multiple of the page size: page one is full and has more; page two
    // is full and is the final page.
    let first = repo
        .list_for_customer(customer, None, 2)
        .await
        .expect("first page");
    assert_eq!(first.jobs.len(), 2);
    assert!(
        first.has_more,
        "a full first page over a longer list must report has_more=true"
    );
    let last = first.jobs.last().unwrap();
    let second = repo
        .list_for_customer(
            customer,
            Some(api::repos::AlgoliaImportJobListCursor {
                created_at: last.created_at,
                id: last.id,
            }),
            2,
        )
        .await
        .expect("second page");
    let second_ids: Vec<Uuid> = second.jobs.iter().map(|job| job.id).collect();
    assert_eq!(second_ids, vec![ids[2], ids[3]]);
    assert!(
        !second.has_more,
        "the final full page of an exact multiple must report has_more=false"
    );
}
