//! PostgreSQL contracts for erased Algolia exact-target VM retention.

use api::repos::{
    CustomerHardDeleteKind, CustomerHardDeleteOutcome, CustomerRepo, PgAlgoliaImportJobRepo,
    PgCustomerRepo,
};
use sqlx::{PgPool, Row};
use uuid::Uuid;

use crate::common::support::pg_schema_harness::connect_and_migrate;
use crate::common::vm_inventory_reference_guard_fixtures::{
    insert_algolia_import_job, insert_customer, insert_vm, AlgoliaReservationState,
};

#[tokio::test]
async fn migration_062_algolia_erased_vm_retirement_blocker_is_present() {
    let migrations = sqlx::migrate!("../migrations");
    let found = migrations.iter().any(|migration| {
        migration.version == 62
            && migration
                .description
                .contains("algolia erased vm retirement blocker")
    });

    assert!(
        found,
        "migration 062_algolia_erased_vm_retirement_blocker must be present"
    );
}

#[tokio::test]
async fn erased_exact_target_work_blocks_vm_until_absence_and_ack_are_confirmed() {
    let Some(db) = connect_and_migrate("algolia_erased_vm_retirement_blocker").await else {
        return;
    };
    let vm_id = insert_vm(&db.pool, "algolia-erased-retained-vm", "active").await;
    let customer_id = insert_customer(&db.pool, "algolia-erased-retention").await;

    insert_algolia_import_job(
        &db.pool,
        customer_id,
        "dispatched_exact_target",
        vm_id,
        AlgoliaReservationState {
            status: "copying_documents",
            publication_disposition: "unchanged",
            resumable: false,
            engine_ack_state: "pending",
        },
    )
    .await
    .expect("insert dispatched Algolia job");
    let dispatched_job_id: Uuid = sqlx::query_scalar(
        "UPDATE algolia_import_jobs
         SET dispatch_intent_state = 'committed', engine_job_id = gen_random_uuid()
         WHERE customer_id = $1 AND logical_target = 'dispatched_exact_target'
         RETURNING id",
    )
    .bind(customer_id)
    .fetch_one(&db.pool)
    .await
    .expect("link dispatched Algolia job");

    insert_algolia_import_job(
        &db.pool,
        customer_id,
        "ordinary_erased_row",
        vm_id,
        AlgoliaReservationState {
            status: "queued",
            publication_disposition: "not_started",
            resumable: false,
            engine_ack_state: "pending",
        },
    )
    .await
    .expect("insert ordinary undispatched Algolia job");
    let ordinary_job_id: Uuid = sqlx::query_scalar(
        "SELECT id FROM algolia_import_jobs
         WHERE customer_id = $1 AND logical_target = 'ordinary_erased_row'",
    )
    .bind(customer_id)
    .fetch_one(&db.pool)
    .await
    .expect("select ordinary Algolia job");

    let customer_repo = PgCustomerRepo::new(db.pool.clone());
    customer_repo
        .soft_delete(customer_id)
        .await
        .expect("soft-delete customer before privacy erasure");
    let outcome = customer_repo
        .hard_delete(customer_id, CustomerHardDeleteKind::PrivacyErasure)
        .await
        .expect("hard-erase customer");
    let CustomerHardDeleteOutcome::Erased { seal_scrub_work } = outcome else {
        panic!("privacy erasure must return opaque scrub work");
    };
    assert_eq!(seal_scrub_work.len(), 2);

    assert_erased_job_has_no_live_reservation(&db.pool, dispatched_job_id).await;
    assert_erased_job_has_no_live_reservation(&db.pool, ordinary_job_id).await;
    assert_eq!(algolia_vm_blocker_count(&db.pool, vm_id).await, 1);

    sqlx::query(
        "UPDATE algolia_import_jobs
         SET cleanup_phase = 'exact_target_absent', engine_ack_state = 'outbox_pending'
         WHERE id = $1",
    )
    .bind(dispatched_job_id)
    .execute(&db.pool)
    .await
    .expect("record exact-target absence before durable ACK");
    assert_eq!(
        algolia_vm_blocker_count(&db.pool, vm_id).await,
        1,
        "proven absence alone must not release the retained VM"
    );

    sqlx::query(
        "UPDATE algolia_import_jobs
         SET engine_ack_state = 'acknowledged', tombstone_compacted_at = NOW()
         WHERE id = $1",
    )
    .bind(dispatched_job_id)
    .execute(&db.pool)
    .await
    .expect("confirm durable exact-target ACK");
    assert_eq!(
        algolia_vm_blocker_count(&db.pool, vm_id).await,
        0,
        "confirmed absence and ACK must release the VM; ordinary erased rows stay non-reserving"
    );
}

async fn algolia_vm_blocker_count(pool: &PgPool, vm_id: Uuid) -> i64 {
    sqlx::query_scalar(
        "SELECT blocker_count
         FROM vm_inventory_reference_blockers($1)
         WHERE owner = 'algolia_import_jobs' AND reference_column = 'destination_vm_id'",
    )
    .bind(vm_id)
    .fetch_one(pool)
    .await
    .expect("query Algolia VM blocker count")
}

async fn assert_erased_job_has_no_live_reservation(pool: &PgPool, job_id: Uuid) {
    let query = format!(
        "SELECT customer_id, logical_target, reserved_index_count,
                reserved_customer_storage_bytes, reserved_node_transient_bytes,
                ({}) AS active_reservation
         FROM algolia_import_jobs WHERE id = $1",
        PgAlgoliaImportJobRepo::active_reservation_predicate_for_contract_tests()
    );
    let row = sqlx::query(&query)
        .bind(job_id)
        .fetch_one(pool)
        .await
        .expect("query erased reservation identity");

    assert_eq!(row.get::<Option<Uuid>, _>("customer_id"), None);
    assert_eq!(row.get::<Option<String>, _>("logical_target"), None);
    assert_eq!(row.get::<Option<i64>, _>("reserved_index_count"), None);
    assert_eq!(
        row.get::<Option<i64>, _>("reserved_customer_storage_bytes"),
        None
    );
    assert_eq!(
        row.get::<Option<i64>, _>("reserved_node_transient_bytes"),
        None
    );
    assert!(!row.get::<bool, _>("active_reservation"));
}
