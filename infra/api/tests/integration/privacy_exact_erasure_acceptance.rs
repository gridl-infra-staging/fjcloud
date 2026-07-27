use api::models::algolia_import_job::{
    AlgoliaImportDispatchIntentState, AlgoliaImportEngineAckState, AlgoliaImportErrorCode,
    AlgoliaImportJob, AlgoliaImportJobState, AlgoliaImportJobStatus,
    AlgoliaImportPublicationDisposition, AlgoliaImportSummary, AlgoliaImportTerminalDetails,
    AlgoliaImportTerminalFact, AlgoliaImportTombstoneCleanupPhase,
};
use api::repos::{
    AlgoliaImportEngineAckOutcome, AlgoliaImportJobRepo, AlgoliaImportReconciliationWork,
    AlgoliaImportTerminalFinalizationAuthority, AlgoliaImportTerminalFinalizationOutcome,
    CustomerHardDeleteKind, CustomerHardDeleteOutcome, CustomerRepo, PgAlgoliaImportJobRepo,
    PgCustomerRepo, RepoError,
};
use api::services::flapjack_proxy::ProxyError;
use chrono::{Duration, Utc};
use serde_json::{json, Value};
use sqlx::PgPool;
use uuid::Uuid;

use crate::common::algolia_import_job_test_support::{admit_create_dispatch, new_create_job};
use crate::common::flapjack_proxy_test_support;
use crate::common::support::pg_schema_harness::{connect_and_migrate, insert_active_customer};

const CONTRACT_JSON: &str = include_str!("../fixtures/algolia_migration_engine_contract.json");
const FLAPJACK_URL: &str = "https://flapjack-privacy.test";
const NODE_ID: &str = "node-1";
const REGION: &str = "us-east-1";
const EXPECTED_GENERATION: &str = "erased-tombstone-v1";

#[derive(Debug, Clone)]
struct DeclaredClass {
    name: String,
    expected_column: &'static str,
    imported_column: &'static str,
}

#[derive(Debug)]
struct PrivacyScrubDbCounts {
    tombstones: i64,
    handle_mappings: i64,
    compacted_tombstones: i64,
    acknowledged: i64,
    active_claims: i64,
    active_reservations: i64,
    vm_retirement_blockers: i64,
    uncompacted_scrub_handles: i64,
}

#[tokio::test]
async fn privacy_exact_erasure_acceptance_reaches_exact_absence() {
    let Some(db) = connect_and_migrate("privacy_exact_erasure").await else {
        return;
    };
    let contract = contract();
    let classes = declared_classes(&contract);
    let request_contract = contract["privacy_scrub_contract"]["request"].clone();
    let ack_status = contract["privacy_scrub_contract"]["ack"]["http_status"]
        .as_u64()
        .expect("privacy scrub ACK status must be numeric") as u16;

    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let retained_customer_id = Uuid::new_v4();
    let erased_customer_id = Uuid::new_v4();
    let gate_customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, retained_customer_id, 1).await;
    insert_active_customer(&db.pool, erased_customer_id, 1).await;
    insert_active_customer(&db.pool, gate_customer_id, 1).await;

    let retained_job = seed_dispatched_job(
        &db.pool,
        &repo,
        retained_customer_id,
        "retained-ordinary",
        &classes,
        true,
    )
    .await;
    finalize_and_ack_retained_job(
        &repo,
        retained_job.id,
        retained_job.engine_job_id.unwrap(),
        &classes,
    )
    .await;
    let retained_customer_before = serialized_customer_row(&db.pool, retained_customer_id).await;
    let retained_job_before = serialized_job_row(&db.pool, retained_job.id).await;
    assert_imported_denominator(&db.pool, retained_job.id, &classes, 6).await;

    let erased_dispatched = seed_dispatched_job(
        &db.pool,
        &repo,
        erased_customer_id,
        "erased-dispatched",
        &classes,
        true,
    )
    .await;
    let destination_vm_id = erased_dispatched
        .destination_vm_id
        .expect("erased dispatched specimen must be VM-attached");
    assert_imported_denominator(&db.pool, erased_dispatched.id, &classes, 6).await;

    let gate_job = seed_engine_disposition_job(&repo, gate_customer_id, "gate-undispatched").await;
    let erased_customer_job_ids = customer_job_ids(&db.pool, erased_customer_id).await;
    let erased_handle = erase_single_job_customer(
        &db.pool,
        erased_customer_id,
        erased_dispatched.id,
        AlgoliaImportTombstoneCleanupPhase::ExactTargetAbsenceRequired,
        Some(destination_vm_id),
    )
    .await;
    let gate_handle = erase_single_job_customer(
        &db.pool,
        gate_customer_id,
        gate_job.id,
        AlgoliaImportTombstoneCleanupPhase::EngineDispositionRequired,
        None,
    )
    .await;

    assert_undispatched_tombstone(&db.pool, gate_job.id, gate_handle).await;
    let pre_ack_counts =
        privacy_scrub_db_counts(&db.pool, erased_dispatched.id, destination_vm_id).await;
    assert_eq!(pre_ack_counts.tombstones, 1, "pre-ACK tombstone count");
    assert_eq!(pre_ack_counts.handle_mappings, 1, "pre-ACK handle count");
    assert_eq!(
        pre_ack_counts.vm_retirement_blockers, 1,
        "pre-ACK VM blocker count"
    );
    assert_customer_absent(&db.pool, erased_customer_id).await;

    let claimed_handle = claim_erased_tombstone(&repo, erased_dispatched.id).await;
    assert_eq!(
        claimed_handle, erased_handle,
        "public claim must carry the hard-delete scrub handle"
    );

    let expected_body = expected_scrub_body(claimed_handle);
    assert_request_conforms_to_contract(&expected_body, &classes, &request_contract);
    assert_non_202_is_flapjack_error(&expected_body, ack_status).await;
    let transmissions = send_loss_then_replay(&expected_body, claimed_handle, ack_status).await;
    assert_eq!(
        transmissions, 2,
        "privacy scrub transmissions for replayed handle"
    );
    assert_durable_acks(&db.pool, erased_dispatched.id, 0).await;

    let undispatched_before = selected_tombstone_state(&db.pool, gate_job.id).await;
    assert_absence_gate_conflict(&repo, gate_job.id).await;
    assert_eq!(
        selected_tombstone_state(&db.pool, gate_job.id).await,
        undispatched_before,
        "failed ACK must leave the engine-disposition tombstone unchanged"
    );

    let first_ack = repo
        .mark_engine_acknowledged(erased_dispatched.id)
        .await
        .expect("acknowledge exact-absence tombstone");
    assert_acknowledged(first_ack, erased_dispatched.id);
    let replay_ack = repo
        .mark_engine_acknowledged(erased_dispatched.id)
        .await
        .expect("replay acknowledged exact-absence tombstone");
    assert_acknowledged(replay_ack, erased_dispatched.id);
    assert_durable_acks(&db.pool, erased_dispatched.id, 1).await;

    let final_counts =
        privacy_scrub_db_counts(&db.pool, erased_dispatched.id, destination_vm_id).await;
    assert_final_counts(&final_counts);
    assert_customer_absent(&db.pool, erased_customer_id).await;
    assert_customer_erasure_residue_absent(&db.pool, &erased_customer_job_ids).await;
    assert_declared_class_absence(&db.pool, &erased_customer_job_ids, &classes).await;
    assert_eq!(
        serialized_job_row(&db.pool, retained_job.id).await,
        retained_job_before,
        "retained customer's ordinary import row must be unchanged"
    );
    assert_imported_denominator(&db.pool, retained_job.id, &classes, 6).await;
    assert_eq!(
        serialized_customer_row(&db.pool, retained_customer_id).await,
        retained_customer_before,
        "retained customer's database row must be unchanged"
    );
}

fn contract() -> Value {
    serde_json::from_str(CONTRACT_JSON).expect("contract fixture must parse")
}

fn declared_classes(contract: &Value) -> Vec<DeclaredClass> {
    let names = contract["privacy_scrub_contract"]["receipt"]["exact_absence_resource_classes"]
        .as_array()
        .expect("exact absence classes must be an array");
    assert!(
        !names.is_empty(),
        "exact absence class list must not be empty"
    );
    names
        .iter()
        .map(|name| {
            let name = name
                .as_str()
                .expect("exact absence classes must be strings");
            class_columns(name).unwrap_or_else(|| {
                panic!("declared exact absence class {name} has no fjcloud ledger column mapping")
            })
        })
        .collect()
}

fn class_columns(name: &str) -> Option<DeclaredClass> {
    let (expected_column, imported_column) = match name {
        "objectIDs" => ("documents_expected", "documents_imported"),
        "synonymIDs" => ("synonyms_expected", "synonyms_imported"),
        "ruleIDs" => ("rules_expected", "rules_imported"),
        _ => return None,
    };
    Some(DeclaredClass {
        name: name.to_string(),
        expected_column,
        imported_column,
    })
}

async fn seed_dispatched_job(
    pool: &PgPool,
    repo: &PgAlgoliaImportJobRepo,
    customer_id: Uuid,
    key: &str,
    classes: &[DeclaredClass],
    attach_vm: bool,
) -> AlgoliaImportJob {
    let created = admit_create_dispatch(repo, new_create_job(customer_id, key, key)).await;
    let engine_job_id = Uuid::new_v4();
    let committed = repo
        .record_dispatch_intent_committed(created.id, engine_job_id)
        .await
        .expect("commit dispatch intent");
    if attach_vm {
        attach_active_vm(pool, &committed).await;
    }
    let mut state = admitted_state(AlgoliaImportJobStatus::ValidatingSource, engine_job_id);
    state.summary = summary_for_classes(classes);
    repo.update_persisted_state(created.id, state)
        .await
        .expect("seed persisted class ledger")
}

async fn seed_engine_disposition_job(
    repo: &PgAlgoliaImportJobRepo,
    customer_id: Uuid,
    key: &str,
) -> AlgoliaImportJob {
    let created = repo
        .create(new_create_job(customer_id, key, key))
        .await
        .expect("create no-dispatch precursor");
    repo.record_no_dispatch_failure(
        created.id,
        AlgoliaImportErrorCode::InvalidCredentials,
        Some("sanitized pre-dispatch rejection"),
    )
    .await
    .expect("seed engine-disposition tombstone precursor")
}

async fn finalize_and_ack_retained_job(
    repo: &PgAlgoliaImportJobRepo,
    job_id: Uuid,
    engine_job_id: Uuid,
    classes: &[DeclaredClass],
) {
    let now = Utc::now();
    let claim = repo
        .claim_reconciliation_jobs(now, now + Duration::minutes(5), 10)
        .await
        .expect("claim retained job for finalization")
        .into_iter()
        .find(|claim| claim.job.id == job_id)
        .expect("retained job must be claimable for terminal finalization");
    let fact = AlgoliaImportTerminalFact::new(
        engine_job_id,
        AlgoliaImportJobStatus::Completed,
        AlgoliaImportPublicationDisposition::Promoted,
        Utc::now(),
        AlgoliaImportTerminalDetails {
            summary: summary_for_classes(classes),
            terminal_outcome_observed: true,
            warnings: Vec::new(),
            error_code: None,
            error_message: None,
        },
    )
    .expect("retained terminal fact");
    let outcome = repo
        .finalize_terminal_observation(
            AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(claim.lease),
            fact,
        )
        .await
        .expect("finalize retained terminal job");
    assert!(
        matches!(
            outcome,
            AlgoliaImportTerminalFinalizationOutcome::Applied(_)
        ),
        "retained terminal finalization must apply, got {outcome:?}"
    );
    repo.mark_engine_acknowledged(job_id)
        .await
        .expect("acknowledge retained terminal outbox");
}

fn admitted_state(status: AlgoliaImportJobStatus, engine_job_id: Uuid) -> AlgoliaImportJobState {
    AlgoliaImportJobState {
        status,
        publication_disposition: AlgoliaImportPublicationDisposition::Unchanged,
        engine_ack_state: AlgoliaImportEngineAckState::Pending,
        dispatch_intent_state: AlgoliaImportDispatchIntentState::Committed,
        engine_job_id: Some(engine_job_id),
        lifecycle_generation: 1,
        retryable: true,
        resume_intent_generation: 0,
        resume_mirror: None,
        resumable: false,
        resume_count: 0,
        summary: AlgoliaImportSummary::default(),
        terminal_outcome_observed: false,
        warnings: Vec::new(),
        error_code: None,
        error_message: None,
    }
}

fn summary_for_classes(classes: &[DeclaredClass]) -> AlgoliaImportSummary {
    let mut summary = AlgoliaImportSummary::default();
    for class in classes {
        match class.name.as_str() {
            "objectIDs" => {
                summary.documents_expected = 2;
                summary.documents_imported = 2;
            }
            "synonymIDs" => {
                summary.synonyms_expected = 2;
                summary.synonyms_imported = 2;
            }
            "ruleIDs" => {
                summary.rules_expected = 2;
                summary.rules_imported = 2;
            }
            other => panic!("declared exact absence class {other} has no summary mapping"),
        }
    }
    summary
}

async fn attach_active_vm(pool: &PgPool, job: &AlgoliaImportJob) -> Uuid {
    let vm_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO vm_inventory (id, region, provider, hostname, flapjack_url, status, capacity, current_load)
         VALUES ($1, 'us-east-1', 'aws', $2, 'https://node-1.example', 'active', $3::jsonb, $4::jsonb)",
    )
    .bind(vm_id)
    .bind(format!("privacy-exact-{vm_id}"))
    .bind(json!({ "disk_bytes": 10_000_000_000_i64 }))
    .bind(json!({ "disk_bytes": 0_i64 }))
    .execute(pool)
    .await
    .expect("seed active VM");
    let physical_uid = format!("{}_{}", job.customer_id.as_simple(), job.logical_target);
    sqlx::query(
        "UPDATE algolia_import_jobs SET destination_vm_id = $2, physical_uid = $3, routing_identity = $3 WHERE id = $1",
    )
    .bind(job.id)
    .bind(vm_id)
    .bind(physical_uid)
    .execute(pool)
    .await
    .expect("attach VM placement");
    vm_id
}

async fn erase_single_job_customer(
    pool: &PgPool,
    customer_id: Uuid,
    job_id: Uuid,
    expected_phase: AlgoliaImportTombstoneCleanupPhase,
    destination_vm_id: Option<Uuid>,
) -> Uuid {
    assert!(
        PgCustomerRepo::new(pool.clone())
            .soft_delete(customer_id)
            .await
            .expect("soft-delete erased customer"),
        "erased customer must start active"
    );
    let CustomerHardDeleteOutcome::Erased { seal_scrub_work } = PgCustomerRepo::new(pool.clone())
        .hard_delete(customer_id, CustomerHardDeleteKind::PrivacyErasure)
        .await
        .expect("hard-delete erased customer")
    else {
        panic!("privacy erasure must hard-delete the soft-deleted customer");
    };
    assert_eq!(seal_scrub_work.len(), 1, "single-job scrub work count");
    let work = &seal_scrub_work[0];
    assert_eq!(work.cleanup_phase, expected_phase, "scrub cleanup phase");
    assert_eq!(
        work.engine_job_id.is_some(),
        expected_phase == AlgoliaImportTombstoneCleanupPhase::ExactTargetAbsenceRequired
    );
    assert_eq!(work.destination_vm_id, destination_vm_id);
    assert_eq!(
        erasure_handle_for_job(pool, job_id).await,
        work.erasure_handle
    );
    work.erasure_handle
}

async fn erasure_handle_for_job(pool: &PgPool, job_id: Uuid) -> Uuid {
    sqlx::query_scalar("SELECT erasure_handle FROM algolia_import_jobs WHERE id = $1")
        .bind(job_id)
        .fetch_one(pool)
        .await
        .expect("fetch erasure handle")
}

async fn claim_erased_tombstone(repo: &PgAlgoliaImportJobRepo, job_id: Uuid) -> Uuid {
    let now = Utc::now();
    let claims = repo
        .claim_reconciliation_jobs(now, now + Duration::minutes(5), 10)
        .await
        .expect("claim erased tombstone reconciliation work");
    let claim = claims
        .into_iter()
        .find(|claim| claim.job.id == job_id)
        .expect("claim for erased dispatched job");
    let AlgoliaImportReconciliationWork::ErasedTombstone(work) = claim.work else {
        panic!("claimed work for erased job must be erased-tombstone scrub");
    };
    work.erasure_handle
}

fn expected_scrub_body(handle: Uuid) -> String {
    json!({
        "scrubId": handle,
        "tenant": format!("erased-{handle}"),
        "expectedGeneration": EXPECTED_GENERATION,
        "objectIDs": [],
        "synonymIDs": [],
        "ruleIDs": []
    })
    .to_string()
}

fn assert_request_conforms_to_contract(
    body: &str,
    classes: &[DeclaredClass],
    request_contract: &Value,
) {
    let value: Value = serde_json::from_str(body).expect("expected scrub body must parse");
    let object = value.as_object().expect("scrub body must be an object");
    for field in request_contract["required_fields"]
        .as_array()
        .expect("required_fields must be an array")
    {
        let field = field
            .as_str()
            .expect("required field names must be strings");
        assert!(
            object.contains_key(field),
            "required scrub field {field} missing"
        );
    }
    for class in classes {
        assert!(
            object.contains_key(&class.name),
            "declared class {} missing from scrub payload",
            class.name
        );
    }
    let property_types = request_contract["property_types"]
        .as_object()
        .expect("property_types must be an object");
    for (field, schema) in property_types {
        let actual = object
            .get(field)
            .unwrap_or_else(|| panic!("contract field {field} missing from scrub body"));
        assert_json_type(field, actual, schema);
    }
}

fn assert_json_type(field: &str, actual: &Value, schema: &Value) {
    let expected_type = schema["type"]
        .as_str()
        .unwrap_or_else(|| panic!("property type for {field} must be a string"));
    match expected_type {
        "string" => assert!(actual.is_string(), "{field} must be a string"),
        "array" => assert!(actual.is_array(), "{field} must be an array"),
        other => panic!("unsupported contract JSON type {other} for {field}"),
    }
}

async fn assert_non_202_is_flapjack_error(expected_body: &str, ack_status: u16) {
    let (http, _ssm, proxy) = flapjack_proxy_test_support::setup().await;
    http.expect_sensitive_json_body(expected_body);
    http.push_sensitive_json_response(ack_status.saturating_sub(1), json!({"error": "no ack"}));
    let error = proxy
        .privacy_scrub_algolia_migration(FLAPJACK_URL, NODE_ID, REGION, scrub_id(expected_body))
        .await
        .expect_err("non-202 scrub response must fail");
    assert!(
        matches!(error, ProxyError::FlapjackError { .. }),
        "non-202 scrub response must return ProxyError::FlapjackError"
    );
}

async fn send_loss_then_replay(expected_body: &str, handle: Uuid, ack_status: u16) -> usize {
    let (http, ssm, proxy) = flapjack_proxy_test_support::setup().await;
    let expected_api_key = ssm
        .get_secret(NODE_ID)
        .expect("mock secret manager must seed node key");
    http.push_error(ProxyError::Unreachable(
        "lost privacy scrub response".to_string(),
    ));
    http.expect_sensitive_json_body(expected_body);
    proxy
        .privacy_scrub_algolia_migration(FLAPJACK_URL, NODE_ID, REGION, handle)
        .await
        .expect_err("first send loses response");

    http.expect_sensitive_json_body(expected_body);
    http.push_sensitive_json_response(
        ack_status,
        json!({"scrubId": handle, "disposition": "acknowledged"}),
    );
    proxy
        .privacy_scrub_algolia_migration(FLAPJACK_URL, NODE_ID, REGION, handle)
        .await
        .expect("second send receives ACK");

    let observations = http.take_sensitive_requests();
    assert_eq!(observations.len(), 2, "loss replay must send exactly twice");
    for observation in &observations {
        assert_eq!(observation.method, reqwest::Method::POST);
        assert_eq!(
            observation.url,
            format!("{FLAPJACK_URL}/1/migrations/privacy-scrub")
        );
        assert_eq!(
            observation.api_key, expected_api_key,
            "privacy scrub must use the private migration node credential"
        );
    }
    assert_eq!(observations[0].url, observations[1].url);
    assert_eq!(observations[0].api_key, observations[1].api_key);
    observations.len()
}

fn scrub_id(body: &str) -> Uuid {
    serde_json::from_str::<Value>(body).expect("scrub body must parse")["scrubId"]
        .as_str()
        .expect("scrubId must be a string")
        .parse()
        .expect("scrubId must be a UUID")
}

async fn privacy_scrub_db_counts(
    pool: &PgPool,
    job_id: Uuid,
    destination_vm_id: Uuid,
) -> PrivacyScrubDbCounts {
    // Mirrors PrivacyScrubDbCounts in
    // infra/api/src/services/algolia_import/reconciliation_privacy_scrub_postgres_tests.rs.
    let (
        tombstones,
        handle_mappings,
        compacted_tombstones,
        acknowledged,
        active_claims,
        active_reservations,
        uncompacted_scrub_handles,
    ): (i64, i64, i64, i64, i64, i64, i64) = sqlx::query_as(&format!(
        "SELECT COUNT(*) FILTER (WHERE erased_at IS NOT NULL)::BIGINT,
                COUNT(*) FILTER (WHERE erasure_handle IS NOT NULL)::BIGINT,
                COUNT(*) FILTER (WHERE tombstone_compacted_at IS NOT NULL)::BIGINT,
                COUNT(*) FILTER (WHERE engine_ack_state = 'acknowledged')::BIGINT,
                COUNT(*) FILTER (WHERE worker_claimed_at IS NOT NULL OR worker_lease_expires_at IS NOT NULL)::BIGINT,
                COUNT(*) FILTER (WHERE {})::BIGINT,
                COUNT(*) FILTER (WHERE erasure_handle IS NOT NULL AND tombstone_compacted_at IS NULL)::BIGINT
         FROM algolia_import_jobs WHERE id = $1",
        PgAlgoliaImportJobRepo::active_reservation_predicate_for_contract_tests()
    ))
    .bind(job_id)
    .fetch_one(pool)
    .await
    .expect("count job-scoped privacy scrub residue");
    let vm_retirement_blockers: i64 = sqlx::query_scalar(
        "SELECT COALESCE((SELECT blocker_count FROM vm_inventory_reference_blockers($1)
          WHERE owner = 'algolia_import_jobs' AND reference_column = 'destination_vm_id'), 0)::BIGINT",
    )
    .bind(destination_vm_id)
    .fetch_one(pool)
    .await
    .expect("count VM retirement blockers");
    PrivacyScrubDbCounts {
        tombstones,
        handle_mappings,
        compacted_tombstones,
        acknowledged,
        active_claims,
        active_reservations,
        vm_retirement_blockers,
        uncompacted_scrub_handles,
    }
}

fn assert_final_counts(counts: &PrivacyScrubDbCounts) {
    assert_eq!(counts.tombstones, 1, "final tombstone count");
    assert_eq!(counts.acknowledged, 1, "final durable ACK count");
    assert_eq!(
        counts.compacted_tombstones, 1,
        "final compacted tombstone count"
    );
    assert_eq!(counts.handle_mappings, 0, "final handle mapping residue");
    assert_eq!(counts.active_claims, 0, "final active claim residue");
    assert_eq!(
        counts.active_reservations, 0,
        "final active reservation residue"
    );
    assert_eq!(
        counts.vm_retirement_blockers, 0,
        "final VM retirement blocker residue"
    );
    assert_eq!(
        counts.uncompacted_scrub_handles, 0,
        "final uncompacted scrub handle residue"
    );
}

async fn assert_declared_class_absence(pool: &PgPool, job_ids: &[Uuid], classes: &[DeclaredClass]) {
    for job_id in job_ids {
        let row = serialized_job_row(pool, *job_id).await;
        for class in classes {
            let expected = &row[class.expected_column];
            let imported = &row[class.imported_column];
            assert!(
                expected.is_null() && imported.is_null(),
                "declared class {} residue remains: {}={expected}, {}={imported}",
                class.name,
                class.expected_column,
                class.imported_column
            );
        }
    }
}

async fn assert_imported_denominator(
    pool: &PgPool,
    job_id: Uuid,
    classes: &[DeclaredClass],
    expected: i64,
) {
    let row = serialized_job_row(pool, job_id).await;
    let denominator: i64 = classes
        .iter()
        .map(|class| {
            row[class.imported_column]
                .as_i64()
                .unwrap_or_else(|| panic!("{} must be seeded", class.imported_column))
        })
        .sum();
    assert_eq!(denominator, expected, "seeded imported denominator");
}

async fn serialized_job_row(pool: &PgPool, job_id: Uuid) -> Value {
    sqlx::query_scalar(
        "SELECT to_jsonb(algolia_import_jobs.*) FROM algolia_import_jobs WHERE id = $1",
    )
    .bind(job_id)
    .fetch_one(pool)
    .await
    .expect("serialize import job row")
}

async fn serialized_customer_row(pool: &PgPool, customer_id: Uuid) -> Value {
    sqlx::query_scalar("SELECT to_jsonb(customers.*) FROM customers WHERE id = $1")
        .bind(customer_id)
        .fetch_one(pool)
        .await
        .expect("serialize customer row")
}

async fn customer_job_ids(pool: &PgPool, customer_id: Uuid) -> Vec<Uuid> {
    sqlx::query_scalar("SELECT id FROM algolia_import_jobs WHERE customer_id = $1 ORDER BY id")
        .bind(customer_id)
        .fetch_all(pool)
        .await
        .expect("snapshot erased customer's complete job set")
}

async fn assert_customer_erasure_residue_absent(pool: &PgPool, job_ids: &[Uuid]) {
    assert!(!job_ids.is_empty(), "erased customer job scope is empty");
    let (tombstones, handles, active_reservations): (i64, i64, i64) = sqlx::query_as(&format!(
        "SELECT COUNT(*) FILTER (WHERE erased_at IS NOT NULL)::BIGINT,
                    COUNT(*) FILTER (WHERE erasure_handle IS NOT NULL)::BIGINT,
                    COUNT(*) FILTER (WHERE {})::BIGINT
             FROM algolia_import_jobs WHERE id = ANY($1)",
        PgAlgoliaImportJobRepo::active_reservation_predicate_for_contract_tests()
    ))
    .bind(job_ids)
    .fetch_one(pool)
    .await
    .expect("count customer-wide erasure residue");
    assert_eq!(
        tombstones,
        job_ids.len() as i64,
        "every erased customer job must remain represented by a tombstone"
    );
    assert_eq!(handles, 0, "erased customer handle residue");
    assert_eq!(
        active_reservations, 0,
        "erased customer reservation residue"
    );
}

async fn assert_undispatched_tombstone(pool: &PgPool, job_id: Uuid, handle: Uuid) {
    let row = selected_tombstone_state(pool, job_id).await;
    assert_eq!(row["erasure_handle"], json!(handle));
    assert_eq!(row["cleanup_phase"], "engine_disposition_required");
    assert_ne!(row["engine_ack_state"], "acknowledged");
    assert!(
        row["erased_at"].is_string(),
        "undispatched row must be erased"
    );
    assert!(row["tombstone_compacted_at"].is_null());
    assert!(row["worker_claimed_at"].is_null());
    assert!(row["worker_lease_expires_at"].is_null());
}

async fn selected_tombstone_state(pool: &PgPool, job_id: Uuid) -> Value {
    sqlx::query_scalar(
        "SELECT jsonb_build_object(
             'erased_at', erased_at, 'erasure_handle', erasure_handle,
             'cleanup_phase', cleanup_phase, 'engine_ack_state', engine_ack_state,
             'tombstone_compacted_at', tombstone_compacted_at,
             'worker_claimed_at', worker_claimed_at, 'worker_lease_expires_at', worker_lease_expires_at)
         FROM algolia_import_jobs WHERE id = $1",
    )
    .bind(job_id)
    .fetch_one(pool)
    .await
    .expect("select tombstone state")
}

async fn assert_absence_gate_conflict(repo: &PgAlgoliaImportJobRepo, job_id: Uuid) {
    let result = repo.mark_engine_acknowledged(job_id).await;
    assert!(
        matches!(
            result,
            Err(RepoError::Conflict(message))
                if message == "erased tombstone acknowledgement requires proven exact-target absence"
        ),
        "engine-disposition tombstone ACK must fail with exact-target absence conflict"
    );
}

fn assert_acknowledged(outcome: AlgoliaImportEngineAckOutcome, job_id: Uuid) {
    assert_eq!(outcome.id, job_id);
    assert_eq!(
        outcome.engine_ack_state,
        AlgoliaImportEngineAckState::Acknowledged
    );
}

async fn assert_durable_acks(pool: &PgPool, job_id: Uuid, expected: i64) {
    let actual: i64 = sqlx::query_scalar(
        "SELECT COUNT(*)::BIGINT FROM algolia_import_jobs
         WHERE id = $1 AND engine_ack_state = 'acknowledged'",
    )
    .bind(job_id)
    .fetch_one(pool)
    .await
    .expect("count durable ACKs");
    assert_eq!(actual, expected, "durable ACK count for erased job");
}

async fn assert_customer_absent(pool: &PgPool, customer_id: Uuid) {
    assert_customer_count(pool, customer_id, 0, "erased customer identity residue").await;
}

async fn assert_customer_count(pool: &PgPool, customer_id: Uuid, expected: i64, context: &str) {
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*)::BIGINT FROM customers WHERE id = $1")
        .bind(customer_id)
        .fetch_one(pool)
        .await
        .expect("count customer identity");
    assert_eq!(count, expected, "{context}");
}
