use api::models::algolia_import_job::{
    AlgoliaImportCreateDestination, AlgoliaImportErrorCode, AlgoliaImportJob, AlgoliaImportSource,
    AlgoliaImportSourceMetadata, NewAlgoliaImportJob, NewAlgoliaReplaceImportJob,
};
use api::repos::{AlgoliaImportDispatchAdmission, AlgoliaImportDispatchAdmissionOutcome};
use api::repos::{AlgoliaImportJobAdmissionError, AlgoliaImportJobRepo, PgAlgoliaImportJobRepo};
use chrono::{Duration, Utc};
use serde_json::json;
use sqlx::PgPool;
use uuid::Uuid;

use crate::common::support::pg_schema_harness::connect_and_migrate;

fn assert_admission_refused(
    result: Result<AlgoliaImportJob, AlgoliaImportJobAdmissionError>,
    expected: AlgoliaImportErrorCode,
) {
    assert!(
        matches!(result, Err(AlgoliaImportJobAdmissionError::Refused(code)) if code == expected),
        "expected admission refusal {expected:?}"
    );
}

fn create_job_sized(
    customer_id: Uuid,
    target: &str,
    key: &str,
    source_size_bytes: i64,
) -> NewAlgoliaImportJob {
    NewAlgoliaImportJob::create(
        customer_id,
        AlgoliaImportCreateDestination::new(target, "us-east-1"),
        AlgoliaImportSource::from_final_key_metadata(
            "AB12CD34EF",
            "Products",
            AlgoliaImportSourceMetadata::new(
                Some(source_size_bytes),
                Some(1_000),
                format!("revision-{key}"),
            ),
        ),
        key,
    )
}

fn replace_job_sized(
    customer_id: Uuid,
    target: &str,
    key: &str,
    source_size_bytes: i64,
) -> NewAlgoliaReplaceImportJob {
    NewAlgoliaReplaceImportJob::new(
        customer_id,
        target,
        AlgoliaImportSource::from_final_key_metadata(
            "AB12CD34EF",
            "Products",
            AlgoliaImportSourceMetadata::new(
                Some(source_size_bytes),
                Some(1_000),
                format!("revision-{key}"),
            ),
        ),
        key,
    )
}

async fn insert_customer(pool: &PgPool, customer_id: Uuid) {
    sqlx::query(
        "INSERT INTO customers (id, name, email, status, billing_plan, email_verified_at)
         VALUES ($1, 'Algolia customer', $2, 'active', 'shared', NOW())",
    )
    .bind(customer_id)
    .bind(format!("{customer_id}@example.com"))
    .execute(pool)
    .await
    .expect("insert customer");
}

async fn insert_vm(pool: &PgPool, disk_capacity: i64, disk_load: i64) -> Uuid {
    let vm_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO vm_inventory
         (id, region, provider, hostname, flapjack_url, status, capacity, current_load)
         VALUES ($1, 'us-east-1', 'aws', $2, 'https://private.invalid', 'active',
                 $3::jsonb, $4::jsonb)",
    )
    .bind(vm_id)
    .bind(format!("vm-{vm_id}"))
    .bind(json!({ "disk_bytes": disk_capacity }))
    .bind(json!({ "disk_bytes": disk_load }))
    .execute(pool)
    .await
    .expect("insert vm");
    vm_id
}

async fn insert_replace_target_sized(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    current_size_bytes: i64,
    quota: serde_json::Value,
    disk_capacity: i64,
    disk_load: i64,
) {
    insert_customer(pool, customer_id).await;
    let vm_id = insert_vm(pool, disk_capacity, disk_load).await;
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
         (customer_id, tenant_id, deployment_id, vm_id, tier, service_type, resource_quota)
         VALUES ($1, $2, $3, $4, 'active', 'flapjack', $5::jsonb)",
    )
    .bind(customer_id)
    .bind(target)
    .bind(deployment_id)
    .bind(vm_id)
    .bind(quota)
    .execute(pool)
    .await
    .expect("insert tenant");

    sqlx::query(
        "INSERT INTO usage_daily (customer_id, date, region, storage_bytes_avg)
         VALUES ($1, CURRENT_DATE, 'us-east-1', $2)",
    )
    .bind(customer_id)
    .bind(current_size_bytes)
    .execute(pool)
    .await
    .expect("insert usage daily");
}

async fn insert_replace_target_on_vm(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    vm_id: Uuid,
    quota: serde_json::Value,
) {
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
         (customer_id, tenant_id, deployment_id, vm_id, tier, service_type, resource_quota)
         VALUES ($1, $2, $3, $4, 'active', 'flapjack', $5::jsonb)",
    )
    .bind(customer_id)
    .bind(target)
    .bind(deployment_id)
    .bind(vm_id)
    .bind(quota)
    .execute(pool)
    .await
    .expect("insert tenant");
}

async fn reservation_tuple(pool: &PgPool, job_id: Uuid) -> (i64, i64, i64) {
    sqlx::query_as(
        "SELECT reserved_index_count, reserved_customer_storage_bytes,
                reserved_node_transient_bytes
         FROM algolia_import_jobs
         WHERE id = $1",
    )
    .bind(job_id)
    .fetch_one(pool)
    .await
    .expect("fetch reservation tuple")
}

async fn active_reservation_count(pool: &PgPool) -> i64 {
    let sql = format!(
        "SELECT COUNT(*) FROM algolia_import_jobs WHERE {}",
        PgAlgoliaImportJobRepo::active_reservation_predicate_for_contract_tests()
    );
    sqlx::query_scalar(&sql)
        .fetch_one(pool)
        .await
        .expect("count active reservations")
}

struct ReservationPredicateCase {
    status: &'static str,
    disposition: &'static str,
    ack: &'static str,
    dispatch_intent: &'static str,
    engine_linked: bool,
}

impl ReservationPredicateCase {
    fn engine(status: &'static str, disposition: &'static str, ack: &'static str) -> Self {
        Self {
            status,
            disposition,
            ack,
            dispatch_intent: "committed",
            engine_linked: true,
        }
    }

    fn local(
        status: &'static str,
        disposition: &'static str,
        ack: &'static str,
        dispatch_intent: &'static str,
    ) -> Self {
        Self {
            status,
            disposition,
            ack,
            dispatch_intent,
            engine_linked: false,
        }
    }
}

async fn reservation_predicate_is_active(pool: &PgPool, case: &ReservationPredicateCase) -> bool {
    let sql = format!(
        "SELECT ({})
         FROM (SELECT $1::text AS status,
                      $2::text AS publication_disposition,
                      $3::text AS engine_ack_state,
                      $4::text AS dispatch_intent_state,
                      CASE WHEN $5 THEN gen_random_uuid() ELSE NULL::uuid END AS engine_job_id,
                      FALSE AS resumable,
                      NULL::timestamptz AS erased_at) AS candidate",
        PgAlgoliaImportJobRepo::active_reservation_predicate_for_contract_tests()
    );
    sqlx::query_scalar(&sql)
        .bind(case.status)
        .bind(case.disposition)
        .bind(case.ack)
        .bind(case.dispatch_intent)
        .bind(case.engine_linked)
        .fetch_one(pool)
        .await
        .expect("evaluate active reservation contract case")
}

async fn assert_reservation_predicate(
    pool: &PgPool,
    case: ReservationPredicateCase,
    expected_active: bool,
) {
    assert_eq!(
        reservation_predicate_is_active(pool, &case).await,
        expected_active,
        "reservation predicate mismatch for {}+{}+{}",
        case.status,
        case.disposition,
        case.ack
    );
}

#[tokio::test]
async fn active_reservation_predicate_releases_only_canonical_confirmed_terminal_origins() {
    let Some(db) = connect_and_migrate("algolia_reservation_predicate_contract").await else {
        return;
    };
    let engine_terminal_pairs = [
        ("completed", "promoted"),
        ("completed_with_warnings", "promoted"),
        ("cancelled", "unchanged"),
        ("failed", "unchanged"),
        ("failed", "not_started"),
        ("interrupted", "unchanged"),
    ];

    for (status, disposition) in engine_terminal_pairs {
        for ack in ["pending", "outbox_pending"] {
            assert_reservation_predicate(
                &db.pool,
                ReservationPredicateCase::engine(status, disposition, ack),
                true,
            )
            .await;
        }
        assert_reservation_predicate(
            &db.pool,
            ReservationPredicateCase::engine(status, disposition, "acknowledged"),
            false,
        )
        .await;
    }

    for case in [
        ReservationPredicateCase::local("failed", "not_started", "not_applicable", "absent"),
        ReservationPredicateCase::local(
            "interrupted",
            "not_started",
            "seal_acknowledged",
            "ambiguous",
        ),
    ] {
        assert_reservation_predicate(&db.pool, case, false).await;
    }

    for (status, disposition) in [
        ("completed", "unchanged"),
        ("cancelled", "not_started"),
        ("completed", "unknown"),
        ("interrupted", "not_started"),
    ] {
        assert_reservation_predicate(
            &db.pool,
            ReservationPredicateCase::engine(status, disposition, "acknowledged"),
            true,
        )
        .await;
    }
}

#[tokio::test]
async fn create_reservation_counts_future_index_and_source_bytes() {
    let Some(db) = connect_and_migrate("algolia_reserve_create_bytes").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_customer(&db.pool, customer).await;

    let job = repo
        .create(create_job_sized(customer, "products", "key-sized", 2_000))
        .await
        .expect("create import job");

    assert_eq!(reservation_tuple(&db.pool, job.id).await, (1, 2_000, 0));
}

#[tokio::test]
async fn ambiguous_dispatch_admission_remains_an_active_reservation() {
    let Some(db) = connect_and_migrate("algolia_reserve_ambiguous_dispatch").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_customer(&db.pool, customer).await;

    let admitted = repo
        .admit_dispatch(AlgoliaImportDispatchAdmission::Create(create_job_sized(
            customer,
            "products",
            "ambiguous-reservation",
            2_000,
        )))
        .await
        .expect("dispatch admission");
    let AlgoliaImportDispatchAdmissionOutcome::New(job) = admitted else {
        panic!("first dispatch admission must create a retained reservation");
    };

    assert_eq!(reservation_tuple(&db.pool, job.id).await, (1, 2_000, 0));
    assert_eq!(active_reservation_count(&db.pool).await, 1);
}

#[tokio::test]
async fn committed_dispatch_admission_remains_an_active_reservation_without_engine_status() {
    let Some(db) = connect_and_migrate("algolia_reserve_committed_dispatch").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_customer(&db.pool, customer).await;
    let admitted = repo
        .admit_dispatch(AlgoliaImportDispatchAdmission::Create(create_job_sized(
            customer,
            "products",
            "committed-reservation",
            2_000,
        )))
        .await
        .expect("dispatch admission");
    let AlgoliaImportDispatchAdmissionOutcome::New(job) = admitted else {
        panic!("first dispatch admission must create a retained reservation");
    };

    repo.record_dispatch_intent_committed(job.id, Uuid::new_v4())
        .await
        .expect("commit engine linkage");

    assert_eq!(reservation_tuple(&db.pool, job.id).await, (1, 2_000, 0));
    assert_eq!(active_reservation_count(&db.pool).await, 1);
}

#[tokio::test]
async fn ambiguous_and_committed_reservations_survive_worker_claim_expiry_and_api_outage() {
    let Some(db) = connect_and_migrate("algolia_reserve_claim_expiry").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_customer(&db.pool, customer).await;
    let ambiguous = repo
        .admit_dispatch(AlgoliaImportDispatchAdmission::Create(create_job_sized(
            customer,
            "products-ambiguous",
            "ambiguous-claim-expiry",
            2_000,
        )))
        .await
        .expect("ambiguous dispatch admission");
    let AlgoliaImportDispatchAdmissionOutcome::New(ambiguous) = ambiguous else {
        panic!("first ambiguous admission must create a retained reservation");
    };
    let committed = repo
        .admit_dispatch(AlgoliaImportDispatchAdmission::Create(create_job_sized(
            customer,
            "products-committed",
            "committed-claim-expiry",
            3_000,
        )))
        .await
        .expect("committed dispatch admission");
    let AlgoliaImportDispatchAdmissionOutcome::New(committed) = committed else {
        panic!("first committed admission must create a retained reservation");
    };
    repo.record_dispatch_intent_committed(committed.id, Uuid::new_v4())
        .await
        .expect("commit engine linkage");
    let stale_claimed_at = Utc::now() - Duration::hours(2);
    let stale_lease_expires_at = Utc::now() - Duration::hours(1);

    sqlx::query(
        "UPDATE algolia_import_jobs
         SET worker_claimed_at = $1, worker_lease_expires_at = $2
         WHERE id IN ($3, $4)",
    )
    .bind(stale_claimed_at)
    .bind(stale_lease_expires_at)
    .bind(ambiguous.id)
    .bind(committed.id)
    .execute(&db.pool)
    .await
    .expect("simulate stale worker claims and a long API outage");

    assert_eq!(
        reservation_tuple(&db.pool, ambiguous.id).await,
        (1, 2_000, 0)
    );
    assert_eq!(
        reservation_tuple(&db.pool, committed.id).await,
        (1, 3_000, 0)
    );
    assert_eq!(active_reservation_count(&db.pool).await, 2);
}

#[tokio::test]
async fn dispatch_admitted_replace_reservation_uses_final_key_metadata() {
    let Some(db) = connect_and_migrate("algolia_reserve_dispatch_replace_final").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_replace_target_sized(
        &db.pool,
        customer,
        "products",
        1_000,
        json!({ "max_indexes": 10, "max_storage_bytes": 10_000 }),
        20_000,
        1_000,
    )
    .await;

    let admitted = repo
        .admit_dispatch(AlgoliaImportDispatchAdmission::Replace(replace_job_sized(
            customer,
            "products",
            "dispatch-replace-final-size",
            1_700,
        )))
        .await
        .expect("dispatch replace admission");
    let AlgoliaImportDispatchAdmissionOutcome::New(job) = admitted else {
        panic!("first dispatch replace admission must create a retained reservation");
    };

    assert_eq!(reservation_tuple(&db.pool, job.id).await, (0, 700, 3_700));
    assert_eq!(active_reservation_count(&db.pool).await, 1);
}

#[tokio::test]
async fn create_reservation_rejects_customer_index_count_quota_race() {
    let Some(db) = connect_and_migrate("algolia_reserve_create_count").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_replace_target_sized(
        &db.pool,
        customer,
        "existing",
        500,
        json!({ "max_indexes": 1, "max_storage_bytes": 10_000 }),
        100_000,
        0,
    )
    .await;

    let result = repo
        .create(create_job_sized(
            customer,
            "products",
            "key-over-count",
            100,
        ))
        .await;

    assert_admission_refused(result, AlgoliaImportErrorCode::QuotaExceeded);
}

#[tokio::test]
async fn create_reservation_rejects_projected_customer_storage_quota_race() {
    let Some(db) = connect_and_migrate("algolia_reserve_create_storage").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_replace_target_sized(
        &db.pool,
        customer,
        "existing",
        1_000,
        json!({ "max_indexes": 10, "max_storage_bytes": 1_500 }),
        100_000,
        0,
    )
    .await;

    let result = repo
        .create(create_job_sized(
            customer,
            "products",
            "key-over-storage",
            501,
        ))
        .await;

    assert_admission_refused(result, AlgoliaImportErrorCode::QuotaExceeded);
}

#[tokio::test]
async fn replace_reservation_uses_positive_final_size_delta_only() {
    let Some(db) = connect_and_migrate("algolia_reserve_replace_delta").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let shrink_customer = Uuid::new_v4();
    let same_customer = Uuid::new_v4();
    let grow_customer = Uuid::new_v4();
    for customer in [shrink_customer, same_customer, grow_customer] {
        insert_replace_target_sized(
            &db.pool,
            customer,
            "products",
            1_000,
            json!({ "max_indexes": 10, "max_storage_bytes": 10_000 }),
            20_000,
            1_000,
        )
        .await;
    }

    let shrink = repo
        .create_replace(replace_job_sized(
            shrink_customer,
            "products",
            "replace-shrink",
            700,
        ))
        .await
        .expect("shrinking replacement");
    let same = repo
        .create_replace(replace_job_sized(
            same_customer,
            "products",
            "replace-same",
            1_000,
        ))
        .await
        .expect("same-size replacement");
    let grow = repo
        .create_replace(replace_job_sized(
            grow_customer,
            "products",
            "replace-grow",
            1_700,
        ))
        .await
        .expect("growing replacement");

    assert_eq!(reservation_tuple(&db.pool, shrink.id).await.1, 0);
    assert_eq!(reservation_tuple(&db.pool, same.id).await.1, 0);
    assert_eq!(reservation_tuple(&db.pool, grow.id).await.1, 700);
}

#[tokio::test]
async fn replace_reservation_persists_exact_transient_backup_amplification() {
    let Some(db) = connect_and_migrate("algolia_reserve_replace_transient").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_replace_target_sized(
        &db.pool,
        customer,
        "products",
        1_000,
        json!({ "max_indexes": 10, "max_storage_bytes": 10_000 }),
        20_000,
        1_000,
    )
    .await;

    let job = repo
        .create_replace(replace_job_sized(
            customer,
            "products",
            "replace-transient",
            1_700,
        ))
        .await
        .expect("replacement with transient capacity");

    assert_eq!(reservation_tuple(&db.pool, job.id).await.2, 3_700);
}

#[tokio::test]
async fn replace_reservation_rejects_node_transient_capacity_race() {
    let Some(db) = connect_and_migrate("algolia_reserve_replace_node_cap").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_replace_target_sized(
        &db.pool,
        customer,
        "products",
        1_000,
        json!({ "max_indexes": 10, "max_storage_bytes": 10_000 }),
        4_000,
        1_000,
    )
    .await;

    let result = repo
        .create_replace(replace_job_sized(
            customer,
            "products",
            "replace-over-node",
            1_700,
        ))
        .await;

    assert_admission_refused(result, AlgoliaImportErrorCode::BackendUnavailable);
}

#[tokio::test]
async fn active_customer_import_job_limit_rejects_with_backend_unavailable() {
    let Some(db) = connect_and_migrate("algolia_reserve_customer_jobs").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_customer(&db.pool, customer).await;

    for index in 0..8 {
        repo.create(create_job_sized(
            customer,
            &format!("products-{index}"),
            &format!("active-{index}"),
            100,
        ))
        .await
        .expect("active import inside limit");
    }

    let result = repo
        .create(create_job_sized(
            customer,
            "products-over",
            "active-over",
            100,
        ))
        .await;

    assert_admission_refused(result, AlgoliaImportErrorCode::BackendUnavailable);
}

#[tokio::test]
async fn active_customer_reserved_byte_limit_rejects_with_backend_unavailable() {
    let Some(db) = connect_and_migrate("algolia_reserve_customer_bytes").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_replace_target_sized(
        &db.pool,
        customer,
        "quota-anchor",
        0,
        json!({ "max_indexes": 100, "max_storage_bytes": 107_374_182_400_i64 }),
        200_000_000_000,
        0,
    )
    .await;

    repo.create(create_job_sized(
        customer,
        "products-large",
        "active-large",
        10_737_418_239,
    ))
    .await
    .expect("active import inside byte limit");

    let result = repo
        .create(create_job_sized(
            customer,
            "products-over",
            "active-over",
            2,
        ))
        .await;

    assert_admission_refused(result, AlgoliaImportErrorCode::BackendUnavailable);
}

#[tokio::test]
async fn active_node_import_job_limit_rejects_with_backend_unavailable() {
    let Some(db) = connect_and_migrate("algolia_reserve_node_jobs").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_customer(&db.pool, customer).await;
    let vm_id = insert_vm(&db.pool, 100_000_000, 0).await;
    let quota = json!({ "max_indexes": 100, "max_storage_bytes": 100_000_000_i64 });

    for index in 0..4 {
        let target = format!("products-{index}");
        insert_replace_target_on_vm(&db.pool, customer, &target, vm_id, quota.clone()).await;
        repo.create_replace(replace_job_sized(
            customer,
            &target,
            &format!("replace-{index}"),
            100,
        ))
        .await
        .expect("active node import inside limit");
    }

    insert_replace_target_on_vm(&db.pool, customer, "products-over", vm_id, quota).await;
    let result = repo
        .create_replace(replace_job_sized(
            customer,
            "products-over",
            "replace-over",
            100,
        ))
        .await;

    assert_admission_refused(result, AlgoliaImportErrorCode::BackendUnavailable);
}

#[tokio::test]
async fn terminal_no_dispatch_failure_clears_active_customer_limit() {
    let Some(db) = connect_and_migrate("algolia_reserve_limit_release").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_customer(&db.pool, customer).await;

    let first = repo
        .create(create_job_sized(customer, "products-0", "active-0", 100))
        .await
        .expect("first active import");
    for index in 1..8 {
        repo.create(create_job_sized(
            customer,
            &format!("products-{index}"),
            &format!("active-{index}"),
            100,
        ))
        .await
        .expect("active import inside limit");
    }

    repo.record_no_dispatch_failure(
        first.id,
        api::models::algolia_import_job::AlgoliaImportErrorCode::BackendUnavailable,
        Some("admission capacity unavailable"),
    )
    .await
    .expect("release first active reservation");

    repo.create(create_job_sized(
        customer,
        "products-next",
        "active-next",
        100,
    ))
    .await
    .expect("terminal release clears active customer limit");
}
