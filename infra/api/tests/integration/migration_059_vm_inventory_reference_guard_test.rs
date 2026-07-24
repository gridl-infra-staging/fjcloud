//! PostgreSQL contracts for migration 059's VM inventory reference guard.

use std::collections::BTreeSet;

use api::repos::PgAlgoliaImportJobRepo;
use chrono::Utc;
use sqlx::Row;
use uuid::Uuid;

use crate::common::support::pg_schema_harness::connect_and_migrate;
use crate::common::vm_inventory_reference_guard_fixtures::{
    insert_algolia_import_job, insert_cold_snapshot, insert_customer, insert_deployment,
    insert_index_migration, insert_index_replica, insert_restore_job, insert_tenant,
    insert_tenant_without_vm, insert_vm, AlgoliaReservationState,
    EXPECTED_PERSISTED_VM_REFERENCE_COLUMNS, EXPECTED_VM_REFERENCE_COLUMNS,
};
use crate::common::vm_inventory_reference_guard_matrix::assert_status_reference_mutations;
use crate::common::vm_inventory_reference_guard_races::{
    assert_inventory_lock_wins_reference_publication,
    assert_reference_publication_wins_inventory_lock,
};
use crate::common::vm_inventory_repo_contract::{
    assert_decommissions_once_and_repeats_idempotently, assert_exact_live_reference_blockers,
    assert_rejects_blocked_unknown_and_non_active_retirement,
    assert_structured_identity_and_status_conflicts,
};
use crate::common::vm_inventory_repo_races::{
    assert_repo_inventory_lock_wins_publication, assert_repo_reference_publication_wins,
};

#[tokio::test]
async fn migration_059_vm_inventory_reference_guard_is_present() {
    let migrations = sqlx::migrate!("../migrations");
    let found = migrations.iter().any(|migration| {
        migration.version == 59
            && migration
                .description
                .contains("vm inventory reference guard")
    });

    assert!(
        found,
        "migration 059_vm_inventory_reference_guard must be present in the compiled migration set"
    );
}

#[tokio::test]
async fn migration_059_vm_inventory_reference_guard_exposes_canonical_sql_owners() {
    let Some(db) = connect_and_migrate("vm_ref_guard_owners").await else {
        return;
    };

    let function_names: BTreeSet<String> = sqlx::query(
        "SELECT p.proname
         FROM pg_proc p
         JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = current_schema()
           AND p.proname IN (
             'algolia_import_job_has_active_reservation',
             'vm_inventory_reference_blockers',
             'vm_inventory_reference_allowed',
             'enforce_vm_inventory_reference_allowed'
           )",
    )
    .fetch_all(&db.pool)
    .await
    .expect("query migration 059 function owners")
    .into_iter()
    .map(|row| row.get("proname"))
    .collect();

    assert_eq!(
        function_names,
        BTreeSet::from([
            "enforce_vm_inventory_reference_allowed".to_string(),
            "algolia_import_job_has_active_reservation".to_string(),
            "vm_inventory_reference_allowed".to_string(),
            "vm_inventory_reference_blockers".to_string(),
        ]),
        "migration 059 must expose one blocker owner, one eligibility owner, and one trigger owner"
    );
}

#[tokio::test]
async fn migration_059_vm_inventory_reference_guard_denominator_is_complete() {
    let Some(db) = connect_and_migrate("vm_ref_guard_denominator").await else {
        return;
    };

    let references: BTreeSet<(String, String)> = sqlx::query(
        "SELECT kcu.table_name, kcu.column_name
         FROM information_schema.table_constraints tc
         JOIN information_schema.key_column_usage kcu
           ON kcu.constraint_schema = tc.constraint_schema
          AND kcu.constraint_name = tc.constraint_name
         JOIN information_schema.constraint_column_usage ccu
           ON ccu.constraint_schema = tc.constraint_schema
          AND ccu.constraint_name = tc.constraint_name
         WHERE tc.constraint_schema = current_schema()
           AND tc.constraint_type = 'FOREIGN KEY'
           AND ccu.table_name = 'vm_inventory'
           AND ccu.column_name = 'id'
         ORDER BY kcu.table_name, kcu.column_name",
    )
    .fetch_all(&db.pool)
    .await
    .expect("query vm_inventory foreign key denominator")
    .into_iter()
    .map(|row| (row.get("table_name"), row.get("column_name")))
    .collect();

    let expected = EXPECTED_PERSISTED_VM_REFERENCE_COLUMNS
        .iter()
        .map(|(table, column)| ((*table).to_string(), (*column).to_string()))
        .collect();

    assert_eq!(
        references, expected,
        "test matrix must enumerate every persisted foreign-key reference to vm_inventory(id)"
    );
}

#[tokio::test]
async fn migration_059_vm_inventory_reference_blockers_count_only_live_references() {
    let Some(db) = connect_and_migrate("vm_ref_guard_blockers").await else {
        return;
    };
    let vm_id = insert_vm(&db.pool, "blocker-vm", "active").await;
    let other_vm_id = insert_vm(&db.pool, "other-vm", "active").await;
    let customer_id = insert_customer(&db.pool, "blockers").await;
    let deployment_id = insert_deployment(&db.pool, customer_id, "blockers-node").await;

    insert_tenant(&db.pool, customer_id, deployment_id, "tenant_live", vm_id)
        .await
        .expect("insert live tenant");
    insert_tenant_without_vm(&db.pool, customer_id, deployment_id, "replica_live").await;
    insert_tenant_without_vm(&db.pool, customer_id, deployment_id, "replica_removing").await;
    insert_tenant_without_vm(&db.pool, customer_id, deployment_id, "replica_suspended").await;
    insert_index_migration(
        &db.pool,
        customer_id,
        "migration_live",
        vm_id,
        vm_id,
        "pending",
    )
    .await
    .expect("insert live migration");
    insert_index_migration(
        &db.pool,
        customer_id,
        "migration_completed",
        vm_id,
        vm_id,
        "completed",
    )
    .await
    .expect("insert completed migration");
    insert_index_migration(
        &db.pool,
        customer_id,
        "migration_failed",
        vm_id,
        vm_id,
        "failed",
    )
    .await
    .expect("insert failed migration");
    insert_cold_snapshot(&db.pool, customer_id, "snapshot_live", vm_id, "completed")
        .await
        .expect("insert live snapshot");
    insert_cold_snapshot(&db.pool, customer_id, "snapshot_failed", vm_id, "failed")
        .await
        .expect("insert failed snapshot");
    insert_restore_job(
        &db.pool,
        customer_id,
        "restore_live",
        vm_id,
        vm_id,
        "importing",
    )
    .await
    .expect("insert live restore");
    insert_restore_job(
        &db.pool,
        customer_id,
        "restore_completed",
        vm_id,
        vm_id,
        "completed",
    )
    .await
    .expect("insert completed restore");
    insert_index_replica(
        &db.pool,
        customer_id,
        "replica_live",
        vm_id,
        vm_id,
        "active",
    )
    .await
    .expect("insert live replica");
    insert_index_replica(
        &db.pool,
        customer_id,
        "replica_suspended",
        vm_id,
        other_vm_id,
        "suspended",
    )
    .await
    .expect("insert suspended replica");
    insert_index_replica(
        &db.pool,
        customer_id,
        "replica_removing",
        vm_id,
        other_vm_id,
        "removing",
    )
    .await
    .expect("insert removing replica");
    insert_algolia_import_job(
        &db.pool,
        customer_id,
        "algolia_live",
        vm_id,
        AlgoliaReservationState {
            status: "queued",
            publication_disposition: "not_started",
            resumable: false,
            engine_ack_state: "pending",
        },
    )
    .await
    .expect("insert live Algolia reservation");
    insert_algolia_import_job(
        &db.pool,
        customer_id,
        "algolia_terminal",
        vm_id,
        AlgoliaReservationState {
            status: "completed",
            publication_disposition: "promoted",
            resumable: false,
            engine_ack_state: "acknowledged",
        },
    )
    .await
    .expect("insert terminal Algolia reservation");

    let blockers = sqlx::query(
        "SELECT owner, reference_column, blocker_count
         FROM vm_inventory_reference_blockers($1)
         ORDER BY owner, reference_column",
    )
    .bind(vm_id)
    .fetch_all(&db.pool)
    .await
    .expect("query blocker counts");

    let actual = blockers
        .into_iter()
        .map(|row| {
            (
                row.get::<String, _>("owner"),
                row.get::<String, _>("reference_column"),
                row.get::<i64, _>("blocker_count"),
            )
        })
        .collect::<BTreeSet<_>>();

    assert_eq!(
        actual,
        BTreeSet::from([
            (
                "algolia_import_jobs".to_string(),
                "destination_vm_id".to_string(),
                1
            ),
            ("cold_snapshots".to_string(), "source_vm_id".to_string(), 1),
            ("customer_tenants".to_string(), "vm_id".to_string(), 1),
            ("index_migrations".to_string(), "dest_vm_id".to_string(), 1),
            (
                "index_migrations".to_string(),
                "source_vm_id".to_string(),
                1
            ),
            ("index_replicas".to_string(), "primary_vm_id".to_string(), 1),
            ("index_replicas".to_string(), "replica_vm_id".to_string(), 1),
            ("restore_jobs".to_string(), "dest_vm_id".to_string(), 1),
        ])
    );
}

#[tokio::test]
async fn migration_059_algolia_reservation_predicate_matches_the_rust_owner() {
    let Some(db) = connect_and_migrate("vm_ref_guard_algolia_parity").await else {
        return;
    };
    let erased_at = Utc::now();
    let engine_job_id = Uuid::new_v4();
    let cases = [
        (
            None,
            "unknown",
            false,
            "completed",
            "acknowledged",
            "committed",
            Some(engine_job_id),
            true,
        ),
        (
            None,
            "promoted",
            true,
            "failed",
            "acknowledged",
            "committed",
            Some(engine_job_id),
            true,
        ),
        (
            None,
            "not_started",
            false,
            "queued",
            "pending",
            "ambiguous",
            None,
            true,
        ),
        (
            None,
            "promoted",
            false,
            "completed",
            "pending",
            "committed",
            Some(engine_job_id),
            true,
        ),
        (
            None,
            "promoted",
            false,
            "completed",
            "acknowledged",
            "committed",
            Some(engine_job_id),
            false,
        ),
        (
            None,
            "not_started",
            false,
            "failed",
            "not_applicable",
            "absent",
            None,
            false,
        ),
        (
            Some(erased_at),
            "unknown",
            true,
            "queued",
            "pending",
            "ambiguous",
            None,
            false,
        ),
    ];

    for (
        erased_at,
        disposition,
        resumable,
        status,
        acknowledgement,
        dispatch_intent_state,
        engine_job_id,
        expected,
    ) in cases
    {
        let rust_owner_sql = format!(
            "SELECT ({}) FROM (VALUES (
                 $1::timestamptz, $2::text, $3::boolean, $4::text, $5::text, $6::text, $7::uuid
             )) AS reservation(
                 erased_at, publication_disposition, resumable, status, engine_ack_state,
                 dispatch_intent_state, engine_job_id
             )",
            PgAlgoliaImportJobRepo::active_reservation_predicate_for_contract_tests()
        );
        let rust_owner_value: bool = sqlx::query_scalar(&rust_owner_sql)
            .bind(erased_at)
            .bind(disposition)
            .bind(resumable)
            .bind(status)
            .bind(acknowledgement)
            .bind(dispatch_intent_state)
            .bind(engine_job_id)
            .fetch_one(&db.pool)
            .await
            .expect("evaluate canonical Rust reservation predicate");
        let migration_owner_value: bool = sqlx::query_scalar(
            "SELECT algolia_import_job_has_active_reservation($1, $2, $3, $4, $5, $6, $7)",
        )
        .bind(erased_at)
        .bind(disposition)
        .bind(resumable)
        .bind(status)
        .bind(acknowledgement)
        .bind(dispatch_intent_state)
        .bind(engine_job_id)
        .fetch_one(&db.pool)
        .await
        .expect("evaluate migration-owned reservation predicate");

        assert_eq!(rust_owner_value, expected, "unexpected Rust owner result");
        assert_eq!(
            migration_owner_value, rust_owner_value,
            "migration predicate drifted for erased_at={erased_at:?}, disposition={disposition}, \
             resumable={resumable}, status={status}, acknowledgement={acknowledgement}"
        );
    }
}

#[tokio::test]
async fn migration_059_vm_inventory_reference_allowed_matrix_is_closed() {
    let Some(db) = connect_and_migrate("vm_ref_guard_allowed").await else {
        return;
    };
    let active_vm_id = insert_vm(&db.pool, "allowed-active", "active").await;
    let draining_vm_id = insert_vm(&db.pool, "allowed-draining", "draining").await;
    let decommissioned_vm_id =
        insert_vm(&db.pool, "allowed-decommissioned", "decommissioned").await;

    for (table, column) in EXPECTED_VM_REFERENCE_COLUMNS {
        assert_reference_allowed(&db.pool, active_vm_id, table, column, true).await;
        assert_reference_allowed(&db.pool, decommissioned_vm_id, table, column, false).await;
    }

    for (table, column, expected) in [
        ("customer_tenants", "vm_id", false),
        ("index_migrations", "source_vm_id", true),
        ("index_migrations", "dest_vm_id", false),
        ("cold_snapshots", "source_vm_id", true),
        ("restore_jobs", "dest_vm_id", false),
        ("index_replicas", "primary_vm_id", true),
        ("index_replicas", "replica_vm_id", false),
        ("algolia_import_jobs", "destination_vm_id", false),
    ] {
        assert_reference_allowed(&db.pool, draining_vm_id, table, column, expected).await;
    }
}

#[tokio::test]
async fn migration_059_vm_inventory_reference_triggers_enforce_the_closed_status_matrix() {
    let Some(db) = connect_and_migrate("vm_ref_guard_mutations").await else {
        return;
    };
    let active_vm_id = insert_vm(&db.pool, "mutation-active", "active").await;
    let draining_vm_id = insert_vm(&db.pool, "mutation-draining", "draining").await;
    let decommissioned_vm_id =
        insert_vm(&db.pool, "mutation-decommissioned", "decommissioned").await;

    assert_status_reference_mutations(&db.pool, active_vm_id, "active").await;
    assert_status_reference_mutations(&db.pool, draining_vm_id, "draining").await;
    assert_status_reference_mutations(&db.pool, decommissioned_vm_id, "decommissioned").await;
}

#[tokio::test]
async fn migration_059_inventory_lock_wins_without_deadlocking_reference_publication() {
    let Some(db) = connect_and_migrate("vm_ref_guard_inventory_first").await else {
        return;
    };
    assert_inventory_lock_wins_reference_publication(&db.schema, &db.pool).await;
}

#[tokio::test]
async fn migration_059_reference_publication_wins_without_deadlocking_inventory_lock() {
    let Some(db) = connect_and_migrate("vm_ref_guard_reference_first").await else {
        return;
    };
    assert_reference_publication_wins_inventory_lock(&db.schema, &db.pool).await;
}

#[tokio::test]
async fn pg_vm_inventory_repo_reports_exact_live_reference_blockers() {
    let Some(db) = connect_and_migrate("vm_retirement_repo_blockers").await else {
        return;
    };
    assert_exact_live_reference_blockers(&db.pool).await;
}

#[tokio::test]
async fn pg_vm_inventory_repo_returns_structured_identity_and_status_conflicts() {
    let Some(db) = connect_and_migrate("vm_retirement_repo_conflicts").await else {
        return;
    };
    assert_structured_identity_and_status_conflicts(&db.pool).await;
}

#[tokio::test]
async fn pg_vm_inventory_repo_decommissions_once_and_repeats_idempotently() {
    let Some(db) = connect_and_migrate("vm_retirement_repo_success").await else {
        return;
    };
    assert_decommissions_once_and_repeats_idempotently(&db.pool).await;
}

#[tokio::test]
async fn pg_vm_inventory_repo_rejects_blocked_unknown_and_non_active_retirement() {
    let Some(db) = connect_and_migrate("vm_retirement_repo_rejections").await else {
        return;
    };
    assert_rejects_blocked_unknown_and_non_active_retirement(&db.pool).await;
}

#[tokio::test]
async fn pg_vm_inventory_repo_inventory_lock_wins_reference_publication() {
    let Some(db) = connect_and_migrate("vm_retirement_repo_inventory_first").await else {
        return;
    };
    assert_repo_inventory_lock_wins_publication(&db.schema, &db.pool).await;
}

#[tokio::test]
async fn pg_vm_inventory_repo_reference_publication_wins_inventory_lock() {
    let Some(db) = connect_and_migrate("vm_retirement_repo_reference_first").await else {
        return;
    };
    assert_repo_reference_publication_wins(&db.schema, &db.pool).await;
}

async fn assert_reference_allowed(
    pool: &sqlx::PgPool,
    vm_id: Uuid,
    table: &str,
    column: &str,
    expected: bool,
) {
    let actual: bool = sqlx::query_scalar("SELECT vm_inventory_reference_allowed($1, $2, $3)")
        .bind(vm_id)
        .bind(table)
        .bind(column)
        .fetch_one(pool)
        .await
        .expect("query reference eligibility");

    assert_eq!(
        actual, expected,
        "eligibility mismatch for {table}.{column}"
    );
}
