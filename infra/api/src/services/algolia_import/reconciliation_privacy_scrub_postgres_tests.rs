use super::*;

fn reconciliation_runtime(
    pool: &PgPool,
) -> AlgoliaImportReconciliationRuntime<PgAlgoliaImportJobRepo> {
    AlgoliaImportReconciliationRuntime::new(
        Arc::new(PgAlgoliaImportJobRepo::new(pool.clone())),
        Arc::new(PgVmInventoryRepo::new(pool.clone())),
        Arc::new(MockAlertService::new()),
        config(),
    )
}

fn privacy_scrub_ack_response(erasure_handle: Uuid) -> Result<FlapjackHttpResponse, ProxyError> {
    privacy_scrub_response(json!({
        "scrubId": erasure_handle,
        "disposition": "acknowledged"
    }))
}

fn privacy_scrub_response(body: serde_json::Value) -> Result<FlapjackHttpResponse, ProxyError> {
    Ok(FlapjackHttpResponse {
        status: 202,
        body: body.to_string(),
        request_api_key: String::new(),
    })
}

#[derive(Debug)]
struct PrivacyScrubSpecimen {
    job_id: Uuid,
    engine_job_id: Uuid,
    destination_vm_id: Uuid,
    customer_id: Uuid,
    erasure_handle: Uuid,
    idempotency_key: String,
}

async fn seed_privacy_scrub_specimen(pool: &PgPool, idempotency_key: &str) -> PrivacyScrubSpecimen {
    seed_privacy_scrub_specimen_after_public_ack(pool, idempotency_key, None).await
}

async fn seed_privacy_scrub_specimen_after_public_ack(
    pool: &PgPool,
    idempotency_key: &str,
    public_ack_state: Option<&str>,
) -> PrivacyScrubSpecimen {
    let destination_vm_id = seed_active_vm(pool).await;
    seed_privacy_scrub_specimen_on_vm(pool, idempotency_key, public_ack_state, destination_vm_id)
        .await
}

async fn seed_privacy_scrub_specimen_on_vm(
    pool: &PgPool,
    idempotency_key: &str,
    public_ack_state: Option<&str>,
    destination_vm_id: Uuid,
) -> PrivacyScrubSpecimen {
    let customer_id = Uuid::new_v4();
    insert_active_customer(pool, customer_id, 1).await;
    let repo = PgAlgoliaImportJobRepo::new(pool.clone());
    let engine_job_id = Uuid::new_v4();
    let job = prepare_running_create_job(
        &repo,
        pool,
        customer_id,
        destination_vm_id,
        engine_job_id,
        idempotency_key,
    )
    .await;
    if let Some(public_ack_state) = public_ack_state {
        sqlx::query(
            "UPDATE algolia_import_jobs
             SET status = 'completed',
                 publication_disposition = 'promoted',
                 engine_ack_state = $2,
                 terminal_at = $3,
                 worker_claimed_at = NULL,
                 worker_lease_expires_at = NULL
             WHERE id = $1",
        )
        .bind(job.id)
        .bind(public_ack_state)
        .bind(postgres_timestamp(Utc::now()))
        .execute(pool)
        .await
        .expect("seed terminal public ACK state before privacy erasure");
    }
    let scrub_work = hard_erase_customer(pool, customer_id).await;
    assert_eq!(
        scrub_work.len(),
        1,
        "one import specimen must produce one opaque scrub unit"
    );
    assert_eq!(scrub_work[0].engine_job_id, Some(engine_job_id));
    assert_eq!(scrub_work[0].destination_vm_id, Some(destination_vm_id));

    PrivacyScrubSpecimen {
        job_id: job.id,
        engine_job_id,
        destination_vm_id,
        customer_id,
        erasure_handle: scrub_work[0].erasure_handle,
        idempotency_key: idempotency_key.to_string(),
    }
}

#[derive(Debug, PartialEq, Eq)]
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

impl PrivacyScrubDbCounts {
    fn pending(active_claims: i64) -> Self {
        Self {
            tombstones: 1,
            handle_mappings: 1,
            compacted_tombstones: 0,
            acknowledged: 0,
            active_claims,
            active_reservations: 0,
            vm_retirement_blockers: 1,
            uncompacted_scrub_handles: 1,
        }
    }

    fn finalized() -> Self {
        Self {
            tombstones: 1,
            handle_mappings: 0,
            compacted_tombstones: 1,
            acknowledged: 1,
            active_claims: 0,
            active_reservations: 0,
            vm_retirement_blockers: 0,
            uncompacted_scrub_handles: 0,
        }
    }

    fn assert_pending(&self) {
        assert!(
            matches!(self.active_claims, 0 | 1),
            "an indeterminate delivery may release its claim or retain one short live lease"
        );
        assert_eq!(self, &Self::pending(self.active_claims));
    }
}

async fn privacy_scrub_db_counts(
    pool: &PgPool,
    specimen: &PrivacyScrubSpecimen,
) -> PrivacyScrubDbCounts {
    let (
        tombstones,
        handle_mappings,
        compacted_tombstones,
        acknowledged,
        active_claims,
        active_reservations,
        uncompacted_scrub_handles,
    ): (i64, i64, i64, i64, i64, i64, i64) = sqlx::query_as(&format!(
        "SELECT
             COUNT(*) FILTER (WHERE erased_at IS NOT NULL)::BIGINT,
             COUNT(*) FILTER (WHERE erasure_handle IS NOT NULL)::BIGINT,
             COUNT(*) FILTER (WHERE tombstone_compacted_at IS NOT NULL)::BIGINT,
             COUNT(*) FILTER (WHERE engine_ack_state = 'acknowledged')::BIGINT,
             COUNT(*) FILTER (
                 WHERE worker_claimed_at IS NOT NULL OR worker_lease_expires_at IS NOT NULL
             )::BIGINT,
             COUNT(*) FILTER (WHERE {})::BIGINT,
             COUNT(*) FILTER (
                 WHERE erasure_handle IS NOT NULL AND tombstone_compacted_at IS NULL
             )::BIGINT
         FROM algolia_import_jobs
         WHERE id = $1",
        PgAlgoliaImportJobRepo::active_reservation_predicate_for_contract_tests()
    ))
    .bind(specimen.job_id)
    .fetch_one(pool)
    .await
    .expect("count specimen-scoped scrub residue");
    let vm_retirement_blockers: i64 = sqlx::query_scalar(
        "SELECT blocker_count
         FROM vm_inventory_reference_blockers($1)
         WHERE owner = 'algolia_import_jobs'
           AND reference_column = 'destination_vm_id'",
    )
    .bind(specimen.destination_vm_id)
    .fetch_one(pool)
    .await
    .expect("count specimen destination-VM blockers");

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

async fn assert_privacy_scrub_pii_absent(pool: &PgPool, specimen: &PrivacyScrubSpecimen) {
    let retained_row: serde_json::Value = sqlx::query_scalar(
        "SELECT to_jsonb(algolia_import_jobs.*)
         FROM algolia_import_jobs
         WHERE id = $1",
    )
    .bind(specimen.job_id)
    .fetch_one(pool)
    .await
    .expect("serialize retained privacy scrub specimen");
    for column in [
        "customer_id",
        "tenant_id",
        "algolia_app_id",
        "logical_target",
        "physical_uid",
        "routing_identity",
        "source_name",
        "idempotency_key",
        "canonical_fingerprint",
    ] {
        assert_eq!(
            retained_row[column],
            serde_json::Value::Null,
            "{column} must remain erased"
        );
    }
    let serialized = retained_row.to_string();
    for pii_canary in [
        specimen.customer_id.to_string(),
        specimen.idempotency_key.clone(),
        "AB12CD34EF".to_string(),
        LOGICAL_TARGET_PII_CANARY.to_string(),
        SOURCE_NAME_PII_CANARY.to_string(),
    ] {
        assert!(
            !serialized.contains(&pii_canary),
            "retained tombstone leaked PII canary {pii_canary}"
        );
    }
}

fn captured_privacy_scrub_requests(http: &QueueHttpClient) -> Vec<CapturedScrubRequest> {
    http.scrub_requests.lock().unwrap().clone()
}

fn assert_opaque_privacy_scrub_request(
    request: &CapturedScrubRequest,
    specimen: &PrivacyScrubSpecimen,
) {
    assert_eq!(request.method, reqwest::Method::POST);
    assert!(request.url.ends_with("/1/migrations/privacy-scrub"));
    assert!(
        request.authenticated,
        "privacy scrub delivery must use the authenticated node transport"
    );
    let body = request
        .json_body
        .as_object()
        .expect("privacy scrub body must be an object");
    let expected_handle = specimen.erasure_handle.to_string();
    assert_eq!(
        body.get("scrubId").and_then(serde_json::Value::as_str),
        Some(expected_handle.as_str()),
        "the tombstone erasure handle is the sole replay identity"
    );
    for required in ["tenant", "expectedGeneration"] {
        assert!(
            body.get(required)
                .and_then(serde_json::Value::as_str)
                .is_some_and(|value| !value.is_empty()),
            "pinned engine contract requires non-empty {required}"
        );
    }
    for field in ["objectIDs", "synonymIDs", "ruleIDs"] {
        if let Some(value) = body.get(field) {
            assert!(value.is_array(), "{field} must be a closed array field");
        }
    }
    for field in body.keys() {
        assert!(
            matches!(
                field.as_str(),
                "scrubId"
                    | "tenant"
                    | "expectedGeneration"
                    | "objectIDs"
                    | "synonymIDs"
                    | "ruleIDs"
            ),
            "unexpected privacy scrub request field {field}"
        );
    }

    let serialized = request.json_body.to_string();
    for forbidden in [
        specimen.customer_id.to_string(),
        specimen.engine_job_id.to_string(),
        specimen.idempotency_key.clone(),
        "AB12CD34EF".to_string(),
        LOGICAL_TARGET_PII_CANARY.to_string(),
        SOURCE_NAME_PII_CANARY.to_string(),
    ] {
        assert!(
            !serialized.contains(&forbidden),
            "privacy scrub request leaked erased canary {forbidden}"
        );
    }
}

#[tokio::test]
async fn postgres_reconcile_once_hard_erasure_restarts_scrub_ack_after_terminal_ack_states() {
    for public_ack_state in ["outbox_pending", "acknowledged"] {
        let schema = match public_ack_state {
            "outbox_pending" => "algolia_reconcile_outbox_then_scrub_ack",
            "acknowledged" => "algolia_reconcile_acknowledged_then_scrub_ack",
            _ => unreachable!("closed public ACK-state specimen set"),
        };
        let Some(db) = connect_and_migrate(schema).await else {
            return;
        };
        let specimen = seed_privacy_scrub_specimen_after_public_ack(
            &db.pool,
            &format!("terminal-then-scrub-{public_ack_state}"),
            Some(public_ack_state),
        )
        .await;
        let pending_row: (
            String,
            String,
            Option<DateTime<Utc>>,
            Option<DateTime<Utc>>,
            Option<DateTime<Utc>>,
            Option<Uuid>,
        ) = sqlx::query_as(
            "SELECT cleanup_phase, engine_ack_state, worker_claimed_at,
                    worker_lease_expires_at, tombstone_compacted_at, erasure_handle
             FROM algolia_import_jobs
             WHERE id = $1",
        )
        .bind(specimen.job_id)
        .fetch_one(&db.pool)
        .await
        .expect("read uncompacted privacy scrub lifecycle");
        assert_eq!(pending_row.0, "exact_target_absence_required");
        assert_eq!(
            pending_row.1, "pending",
            "terminal job ACK state {public_ack_state} is not privacy-scrub ACK proof"
        );
        assert_eq!(pending_row.2, None);
        assert_eq!(pending_row.3, None);
        assert_eq!(pending_row.4, None);
        assert_eq!(pending_row.5, Some(specimen.erasure_handle));

        let (service, http) =
            service_harness(vec![privacy_scrub_ack_response(specimen.erasure_handle)]).await;
        let runtime = reconciliation_runtime(&db.pool);
        let report = service
            .reconcile_once(&runtime, postgres_timestamp(Utc::now()))
            .await
            .expect("exact privacy scrub ACK converges terminal public job tombstone");
        assert_eq!(report.claimed, 1);
        assert_eq!(report.terminal_finalized, 1);
        let requests = captured_privacy_scrub_requests(&http);
        assert_eq!(requests.len(), 1);
        assert_opaque_privacy_scrub_request(&requests[0], &specimen);

        let compacted_row: (
            String,
            String,
            Option<DateTime<Utc>>,
            Option<DateTime<Utc>>,
            Option<DateTime<Utc>>,
            Option<Uuid>,
        ) = sqlx::query_as(
            "SELECT cleanup_phase, engine_ack_state, worker_claimed_at,
                    worker_lease_expires_at, tombstone_compacted_at, erasure_handle
             FROM algolia_import_jobs
             WHERE id = $1",
        )
        .bind(specimen.job_id)
        .fetch_one(&db.pool)
        .await
        .expect("read compacted privacy scrub lifecycle");
        assert_eq!(compacted_row.0, "exact_target_absent");
        assert_eq!(compacted_row.1, "acknowledged");
        assert_eq!(compacted_row.2, None);
        assert_eq!(compacted_row.3, None);
        assert!(compacted_row.4.is_some());
        assert_eq!(compacted_row.5, None);
        assert_eq!(
            privacy_scrub_db_counts(&db.pool, &specimen).await,
            PrivacyScrubDbCounts::finalized()
        );
    }
}

#[tokio::test]
async fn postgres_reconcile_once_retries_recorded_privacy_scrub_with_one_opaque_handle_and_no_pii()
{
    let Some(db) = connect_and_migrate("algolia_reconcile_scrub_retry").await else {
        return;
    };
    let specimen =
        seed_privacy_scrub_specimen(&db.pool, "privacy-scrub-recorded-transport-loss-pii-canary")
            .await;
    assert_eq!(
        privacy_scrub_db_counts(&db.pool, &specimen).await,
        PrivacyScrubDbCounts::pending(0)
    );
    assert_privacy_scrub_pii_absent(&db.pool, &specimen).await;

    let (service, http) = service_harness(vec![
        Err(ProxyError::Unreachable(
            "response lost after engine commit".to_string(),
        )),
        Err(ProxyError::Unreachable(
            "duplicate response lost after engine commit".to_string(),
        )),
    ])
    .await;
    let runtime = reconciliation_runtime(&db.pool);
    let first_attempt_at = postgres_timestamp(Utc::now());

    let first = service
        .reconcile_once(&runtime, first_attempt_at)
        .await
        .expect("an indeterminate scrub delivery remains retryable");

    assert_eq!(
        first.claimed, 1,
        "reconcile_once must claim the erased tombstone through the existing worker seam"
    );
    assert_eq!(
        first.terminal_finalized, 0,
        "a recorded request followed by transport loss is not a durable ACK"
    );
    let first_requests = captured_privacy_scrub_requests(&http);
    assert_eq!(first_requests.len(), 1);
    assert_opaque_privacy_scrub_request(&first_requests[0], &specimen);
    privacy_scrub_db_counts(&db.pool, &specimen)
        .await
        .assert_pending();
    assert_privacy_scrub_pii_absent(&db.pool, &specimen).await;

    let retry_at = first_attempt_at + config().lease_duration + Duration::seconds(1);
    let retry = service
        .reconcile_once(&runtime, retry_at)
        .await
        .expect("duplicate invocation retries the indeterminate scrub");

    assert_eq!(retry.claimed, 1);
    assert_eq!(retry.terminal_finalized, 0);
    let retry_requests = captured_privacy_scrub_requests(&http);
    assert_eq!(retry_requests.len(), 2);
    assert_eq!(
        retry_requests[0], retry_requests[1],
        "duplicate delivery must replay byte-equivalent opaque target identity"
    );
    assert_opaque_privacy_scrub_request(&retry_requests[1], &specimen);
    privacy_scrub_db_counts(&db.pool, &specimen)
        .await
        .assert_pending();
    assert_privacy_scrub_pii_absent(&db.pool, &specimen).await;
}

#[tokio::test]
async fn postgres_reconcile_once_restarts_replays_ack_and_compacts_privacy_scrub_once() {
    let Some(db) = connect_and_migrate("algolia_reconcile_scrub_restart_ack").await else {
        return;
    };
    let specimen =
        seed_privacy_scrub_specimen(&db.pool, "privacy-scrub-restart-ack-pii-canary").await;
    let first_attempt_at = postgres_timestamp(Utc::now());
    let (first_service, first_http) = service_harness(vec![Err(ProxyError::Unreachable(
        "response lost after engine commit".to_string(),
    ))])
    .await;
    let first_runtime = reconciliation_runtime(&db.pool);

    let indeterminate = first_service
        .reconcile_once(&first_runtime, first_attempt_at)
        .await
        .expect("response loss leaves durable scrub work");

    assert_eq!(indeterminate.claimed, 1);
    assert_eq!(indeterminate.terminal_finalized, 0);
    let original_requests = captured_privacy_scrub_requests(&first_http);
    assert_eq!(original_requests.len(), 1);
    assert_opaque_privacy_scrub_request(&original_requests[0], &specimen);
    privacy_scrub_db_counts(&db.pool, &specimen)
        .await
        .assert_pending();

    let restart_at = first_attempt_at + config().lease_duration + Duration::seconds(1);
    let (restarted_service, restarted_http) =
        service_harness(vec![privacy_scrub_ack_response(specimen.erasure_handle)]).await;
    let restarted_runtime = reconciliation_runtime(&db.pool);

    let recovered = restarted_service
        .reconcile_once(&restarted_runtime, restart_at)
        .await
        .expect("fresh worker replays the retained scrub request");

    assert_eq!(recovered.claimed, 1);
    assert_eq!(
        recovered.terminal_finalized, 1,
        "only the exact-handle authenticated 202 response may persist the ACK"
    );
    let replayed_requests = captured_privacy_scrub_requests(&restarted_http);
    assert_eq!(replayed_requests.len(), 1);
    assert_eq!(
        original_requests[0], replayed_requests[0],
        "worker restart must preserve the same opaque handle and target request"
    );
    assert_opaque_privacy_scrub_request(&replayed_requests[0], &specimen);
    assert_eq!(
        privacy_scrub_db_counts(&db.pool, &specimen).await,
        PrivacyScrubDbCounts::finalized(),
        "the sole authenticated exact-absence ACK must clear every specimen residue count"
    );
    assert_privacy_scrub_pii_absent(&db.pool, &specimen).await;

    let (ack_replay_service, ack_replay_http) = service_harness(Vec::new()).await;
    let ack_replay_runtime = reconciliation_runtime(&db.pool);
    let replay_report = ack_replay_service
        .reconcile_once(&ack_replay_runtime, restart_at + Duration::seconds(1))
        .await
        .expect("durable local ACK makes later worker invocation a no-op");

    assert_eq!(replay_report.claimed, 0);
    assert_eq!(replay_report.terminal_finalized, 0);
    assert!(
        captured_privacy_scrub_requests(&ack_replay_http).is_empty(),
        "a compacted tombstone must not create a second request or success receipt"
    );
    assert_eq!(
        privacy_scrub_db_counts(&db.pool, &specimen).await,
        PrivacyScrubDbCounts::finalized()
    );
}

// Drive one reconcile_once delivery against a privacy-scrub HTTP 202 whose body does
// NOT prove exact-target absence for the claimed handle, and assert the tombstone stays
// pending: no durable ACK, no compaction, no handle clearing, and no destination-VM
// blocker release. Currently RED — the public claim seam does not yet expose erased
// tombstone scrub work, so `claimed` is observed 0 versus the required 1.
async fn assert_scrub_ack_never_finalizes(
    schema: &str,
    idempotency_key: &str,
    ack_body: impl FnOnce(&PrivacyScrubSpecimen) -> serde_json::Value,
) {
    let Some(db) = connect_and_migrate(schema).await else {
        return;
    };
    let specimen = seed_privacy_scrub_specimen(&db.pool, idempotency_key).await;
    assert_eq!(
        privacy_scrub_db_counts(&db.pool, &specimen).await,
        PrivacyScrubDbCounts::pending(0)
    );

    let (service, http) = service_harness(vec![privacy_scrub_response(ack_body(&specimen))]).await;
    let runtime = reconciliation_runtime(&db.pool);

    let report = service
        .reconcile_once(&runtime, postgres_timestamp(Utc::now()))
        .await
        .expect("a non-exact-absence ACK is an indeterminate, retryable outcome, not a hard error");

    assert_eq!(
        report.claimed, 1,
        "reconcile_once must claim the erased tombstone through the existing worker seam before delivery"
    );
    assert_eq!(
        report.terminal_finalized, 0,
        "only an exact-target-absence ACK for the claimed handle may persist the durable ACK"
    );
    let requests = captured_privacy_scrub_requests(&http);
    assert_eq!(requests.len(), 1);
    assert_opaque_privacy_scrub_request(&requests[0], &specimen);
    privacy_scrub_db_counts(&db.pool, &specimen)
        .await
        .assert_pending();
    assert_privacy_scrub_pii_absent(&db.pool, &specimen).await;
}

#[tokio::test]
async fn postgres_reconcile_once_mismatched_scrub_ack_never_finalizes() {
    assert_scrub_ack_never_finalizes(
        "algolia_reconcile_scrub_ack_mismatch",
        "privacy-scrub-mismatched-ack-pii-canary",
        |specimen| {
            let unrelated_handle = Uuid::new_v4();
            assert_ne!(
                unrelated_handle, specimen.erasure_handle,
                "the RED case must deliver an ACK for a handle other than the claimed one"
            );
            json!({
                "scrubId": unrelated_handle,
                "disposition": "acknowledged"
            })
        },
    )
    .await;
}

#[tokio::test]
async fn postgres_reconcile_once_missing_disposition_scrub_ack_never_finalizes() {
    assert_scrub_ack_never_finalizes(
        "algolia_reconcile_scrub_ack_missing_disposition",
        "privacy-scrub-missing-disposition-ack-pii-canary",
        |specimen| {
            json!({
                "scrubId": specimen.erasure_handle
            })
        },
    )
    .await;
}

#[tokio::test]
async fn postgres_reconcile_once_invalid_disposition_scrub_ack_never_finalizes() {
    assert_scrub_ack_never_finalizes(
        "algolia_reconcile_scrub_ack_invalid_disposition",
        "privacy-scrub-invalid-disposition-ack-pii-canary",
        |specimen| {
            json!({
                "scrubId": specimen.erasure_handle,
                "disposition": "rejected"
            })
        },
    )
    .await;
}

#[tokio::test]
async fn postgres_compacted_privacy_scrub_can_clear_handle_only_after_exact_absence_and_ack() {
    let Some(db) = connect_and_migrate("algolia_reconcile_scrub_compaction_schema").await else {
        return;
    };
    let specimen =
        seed_privacy_scrub_specimen(&db.pool, "privacy-scrub-compaction-schema-pii-canary").await;

    let premature_clear = sqlx::query(
        "UPDATE algolia_import_jobs
         SET erasure_handle = NULL
         WHERE id = $1",
    )
    .bind(specimen.job_id)
    .execute(&db.pool)
    .await;
    assert!(
        premature_clear.is_err(),
        "an uncompacted or unacknowledged erased row must retain its opaque handle"
    );
    assert_eq!(
        privacy_scrub_db_counts(&db.pool, &specimen).await,
        PrivacyScrubDbCounts::pending(0)
    );

    let compacted = sqlx::query(
        "UPDATE algolia_import_jobs
         SET cleanup_phase = 'exact_target_absent',
             engine_ack_state = 'acknowledged',
             tombstone_compacted_at = $2,
             erasure_handle = NULL
         WHERE id = $1",
    )
    .bind(specimen.job_id)
    .bind(postgres_timestamp(Utc::now()))
    .execute(&db.pool)
    .await
    .expect(
        "Stage 2 forward migration must relax migration 056 only for exact-absence-plus-ACK compaction",
    );
    assert_eq!(compacted.rows_affected(), 1);
    assert_eq!(
        privacy_scrub_db_counts(&db.pool, &specimen).await,
        PrivacyScrubDbCounts::finalized()
    );
    assert_privacy_scrub_pii_absent(&db.pool, &specimen).await;
}

#[tokio::test]
async fn postgres_reconcile_once_migration_067_upgrades_existing_erased_compaction_contract() {
    let Some(db) = connect_and_migrate_through("algolia_reconcile_migration_067_upgrade", 66).await
    else {
        return;
    };
    let applied_before: i64 = sqlx::query_scalar("SELECT MAX(version) FROM _sqlx_migrations")
        .fetch_one(&db.pool)
        .await
        .expect("read pre-upgrade migration version");
    assert_eq!(applied_before, 66);

    let destination_vm_id = seed_active_vm(&db.pool).await;
    let pending = privacy_scrub_legacy_schema_fixtures::seed_migration_067_erased_specimen_on_vm(
        &db.pool,
        "migration-067-pending-erased",
        destination_vm_id,
    )
    .await;
    let acknowledged =
        privacy_scrub_legacy_schema_fixtures::seed_migration_067_erased_specimen_on_vm(
            &db.pool,
            "migration-067-acknowledged-erased",
            destination_vm_id,
        )
        .await;
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET cleanup_phase = 'exact_target_absent',
             engine_ack_state = 'acknowledged'
         WHERE id = $1",
    )
    .bind(acknowledged.job_id)
    .execute(&db.pool)
    .await
    .expect("seed acknowledged uncompacted erased row under migration 066");

    migrate_through_version(&db.pool, 67)
        .await
        .expect("apply migration 067 to existing erased rows");
    let applied_after: i64 = sqlx::query_scalar("SELECT MAX(version) FROM _sqlx_migrations")
        .fetch_one(&db.pool)
        .await
        .expect("read upgraded migration version");
    assert_eq!(applied_after, 67);

    let premature_compaction = sqlx::query(
        "UPDATE algolia_import_jobs
         SET tombstone_compacted_at = $2, erasure_handle = NULL
         WHERE id = $1",
    )
    .bind(pending.job_id)
    .bind(postgres_timestamp(Utc::now()))
    .execute(&db.pool)
    .await;
    assert!(
        premature_compaction.is_err(),
        "migration 067 must reject compaction without exact-absence ACK"
    );

    let compacted_at = postgres_timestamp(Utc::now());
    let valid_compaction = sqlx::query(
        "UPDATE algolia_import_jobs
         SET tombstone_compacted_at = $2, erasure_handle = NULL
         WHERE id = $1",
    )
    .bind(acknowledged.job_id)
    .bind(compacted_at)
    .execute(&db.pool)
    .await
    .expect("migration 067 permits exactly acknowledged exact-absence compaction");
    assert_eq!(valid_compaction.rows_affected(), 1);

    let rows: Vec<(Uuid, String, String, Option<Uuid>, Option<DateTime<Utc>>)> = sqlx::query_as(
        "SELECT id, cleanup_phase, engine_ack_state, erasure_handle, tombstone_compacted_at
         FROM algolia_import_jobs
         WHERE id = ANY($1)
         ORDER BY id",
    )
    .bind(vec![pending.job_id, acknowledged.job_id])
    .fetch_all(&db.pool)
    .await
    .expect("read upgraded erased compaction specimens");
    let pending_row = rows
        .iter()
        .find(|row| row.0 == pending.job_id)
        .expect("pending upgraded specimen remains");
    assert_eq!(pending_row.1, "exact_target_absence_required");
    assert_eq!(pending_row.2, "pending");
    assert_eq!(pending_row.3, Some(pending.erasure_handle));
    assert_eq!(pending_row.4, None);
    let acknowledged_row = rows
        .iter()
        .find(|row| row.0 == acknowledged.job_id)
        .expect("acknowledged upgraded specimen remains");
    assert_eq!(acknowledged_row.1, "exact_target_absent");
    assert_eq!(acknowledged_row.2, "acknowledged");
    assert_eq!(acknowledged_row.3, None);
    assert_eq!(acknowledged_row.4, Some(compacted_at));
}
