use sqlx::PgPool;
use uuid::Uuid;

use super::vm_inventory_reference_guard_fixtures::{
    insert_algolia_import_job, insert_cold_snapshot, insert_customer, insert_deployment,
    insert_index_migration, insert_index_replica, insert_restore_job, insert_tenant,
    insert_tenant_without_vm, insert_vm, AlgoliaReservationState,
};

#[derive(Clone, Copy)]
enum ReferenceKind {
    Tenant,
    MigrationSource,
    MigrationDestination,
    ColdSnapshotSource,
    RestoreDestination,
    ReplicaPrimary,
    ReplicaDestination,
    AlgoliaDestination,
}

const REFERENCE_KINDS: [ReferenceKind; 8] = [
    ReferenceKind::Tenant,
    ReferenceKind::MigrationSource,
    ReferenceKind::MigrationDestination,
    ReferenceKind::ColdSnapshotSource,
    ReferenceKind::RestoreDestination,
    ReferenceKind::ReplicaPrimary,
    ReferenceKind::ReplicaDestination,
    ReferenceKind::AlgoliaDestination,
];

impl ReferenceKind {
    fn table_and_column(self) -> (&'static str, &'static str) {
        match self {
            Self::Tenant => ("customer_tenants", "vm_id"),
            Self::MigrationSource => ("index_migrations", "source_vm_id"),
            Self::MigrationDestination => ("index_migrations", "dest_vm_id"),
            Self::ColdSnapshotSource => ("cold_snapshots", "source_vm_id"),
            Self::RestoreDestination => ("restore_jobs", "dest_vm_id"),
            Self::ReplicaPrimary => ("index_replicas", "primary_vm_id"),
            Self::ReplicaDestination => ("index_replicas", "replica_vm_id"),
            Self::AlgoliaDestination => ("algolia_import_jobs", "destination_vm_id"),
        }
    }

    fn draining_allowed(self) -> bool {
        matches!(
            self,
            Self::MigrationSource | Self::ColdSnapshotSource | Self::ReplicaPrimary
        )
    }

    fn label(self) -> &'static str {
        let (table, column) = self.table_and_column();
        match (table, column) {
            ("customer_tenants", _) => "tenant",
            ("index_migrations", "source_vm_id") => "migration_source",
            ("index_migrations", _) => "migration_destination",
            ("cold_snapshots", _) => "snapshot_source",
            ("restore_jobs", _) => "restore_destination",
            ("index_replicas", "primary_vm_id") => "replica_primary",
            ("index_replicas", _) => "replica_destination",
            ("algolia_import_jobs", _) => "algolia_destination",
            _ => unreachable!("closed reference matrix"),
        }
    }
}

struct ReferenceSeed {
    customer_id: Uuid,
    deployment_id: Uuid,
    fallback_vm_id: Uuid,
}

impl ReferenceSeed {
    async fn new(pool: &PgPool, label: &str) -> Self {
        let customer_id = insert_customer(pool, label).await;
        let deployment_id = insert_deployment(pool, customer_id, &format!("{label}_node")).await;
        let fallback_vm_id = insert_vm(pool, &format!("{label}_fallback"), "active").await;
        Self {
            customer_id,
            deployment_id,
            fallback_vm_id,
        }
    }
}

pub async fn assert_status_reference_mutations(
    pool: &PgPool,
    target_vm_id: Uuid,
    target_status: &str,
) {
    for kind in REFERENCE_KINDS {
        let expected_allowed =
            target_status == "active" || (target_status == "draining" && kind.draining_allowed());
        assert_insert_behavior(pool, kind, target_vm_id, target_status, expected_allowed).await;
        assert_update_behavior(pool, kind, target_vm_id, target_status, expected_allowed).await;
    }
}

async fn assert_insert_behavior(
    pool: &PgPool,
    kind: ReferenceKind,
    target_vm_id: Uuid,
    target_status: &str,
    expected_allowed: bool,
) {
    let label = unique_label(kind, "insert", target_status);
    let seed = ReferenceSeed::new(pool, &label).await;
    let result = insert_reference(pool, kind, &seed, &label, target_vm_id).await;

    if expected_allowed {
        result.expect("allowed reference insert must persist");
        assert_eq!(
            stored_reference(pool, kind, seed.customer_id, &label).await,
            Some(target_vm_id)
        );
    } else {
        assert_reference_rejection(
            result.expect_err("forbidden reference insert must fail"),
            kind,
            target_vm_id,
            target_status,
        );
        assert_eq!(
            stored_reference(pool, kind, seed.customer_id, &label).await,
            None
        );
    }
}

async fn assert_update_behavior(
    pool: &PgPool,
    kind: ReferenceKind,
    target_vm_id: Uuid,
    target_status: &str,
    expected_allowed: bool,
) {
    let label = unique_label(kind, "update", target_status);
    let seed = ReferenceSeed::new(pool, &label).await;
    insert_reference(pool, kind, &seed, &label, seed.fallback_vm_id)
        .await
        .expect("baseline reference insert");

    let result = update_reference(pool, kind, seed.customer_id, &label, target_vm_id).await;
    let expected_vm_id = if expected_allowed {
        result.expect("allowed reference update must persist");
        target_vm_id
    } else {
        assert_reference_rejection(
            result.expect_err("forbidden reference update must fail"),
            kind,
            target_vm_id,
            target_status,
        );
        seed.fallback_vm_id
    };
    assert_eq!(
        stored_reference(pool, kind, seed.customer_id, &label).await,
        Some(expected_vm_id)
    );
}

async fn insert_reference(
    pool: &PgPool,
    kind: ReferenceKind,
    seed: &ReferenceSeed,
    label: &str,
    target_vm_id: Uuid,
) -> Result<(), sqlx::Error> {
    match kind {
        ReferenceKind::Tenant => {
            insert_tenant(
                pool,
                seed.customer_id,
                seed.deployment_id,
                label,
                target_vm_id,
            )
            .await
        }
        ReferenceKind::MigrationSource => {
            insert_index_migration(
                pool,
                seed.customer_id,
                label,
                target_vm_id,
                seed.fallback_vm_id,
                "pending",
            )
            .await
        }
        ReferenceKind::MigrationDestination => {
            insert_index_migration(
                pool,
                seed.customer_id,
                label,
                seed.fallback_vm_id,
                target_vm_id,
                "pending",
            )
            .await
        }
        ReferenceKind::ColdSnapshotSource => {
            insert_cold_snapshot(pool, seed.customer_id, label, target_vm_id, "pending")
                .await
                .map(|_| ())
        }
        ReferenceKind::RestoreDestination => {
            insert_restore_job(
                pool,
                seed.customer_id,
                label,
                seed.fallback_vm_id,
                target_vm_id,
                "queued",
            )
            .await
        }
        ReferenceKind::ReplicaPrimary | ReferenceKind::ReplicaDestination => {
            insert_tenant_without_vm(pool, seed.customer_id, seed.deployment_id, label).await;
            let (primary_vm_id, replica_vm_id) = match kind {
                ReferenceKind::ReplicaPrimary => (target_vm_id, seed.fallback_vm_id),
                _ => (seed.fallback_vm_id, target_vm_id),
            };
            insert_index_replica(
                pool,
                seed.customer_id,
                label,
                primary_vm_id,
                replica_vm_id,
                "active",
            )
            .await
        }
        ReferenceKind::AlgoliaDestination => {
            insert_algolia_import_job(
                pool,
                seed.customer_id,
                label,
                target_vm_id,
                AlgoliaReservationState {
                    status: "queued",
                    publication_disposition: "not_started",
                    resumable: false,
                    engine_ack_state: "pending",
                },
            )
            .await
        }
    }
}

async fn update_reference(
    pool: &PgPool,
    kind: ReferenceKind,
    customer_id: Uuid,
    label: &str,
    target_vm_id: Uuid,
) -> Result<(), sqlx::Error> {
    let (table, column) = kind.table_and_column();
    let identity_column = match kind {
        ReferenceKind::Tenant
        | ReferenceKind::ColdSnapshotSource
        | ReferenceKind::RestoreDestination
        | ReferenceKind::ReplicaPrimary
        | ReferenceKind::ReplicaDestination => "tenant_id",
        ReferenceKind::MigrationSource | ReferenceKind::MigrationDestination => "index_name",
        ReferenceKind::AlgoliaDestination => "logical_target",
    };
    let statement = format!(
        "UPDATE {table} SET {column} = $1 WHERE customer_id = $2 AND {identity_column} = $3"
    );
    sqlx::query(&statement)
        .bind(target_vm_id)
        .bind(customer_id)
        .bind(label)
        .execute(pool)
        .await
        .map(|_| ())
}

async fn stored_reference(
    pool: &PgPool,
    kind: ReferenceKind,
    customer_id: Uuid,
    label: &str,
) -> Option<Uuid> {
    let (table, column) = kind.table_and_column();
    let identity_column = match kind {
        ReferenceKind::Tenant
        | ReferenceKind::ColdSnapshotSource
        | ReferenceKind::RestoreDestination
        | ReferenceKind::ReplicaPrimary
        | ReferenceKind::ReplicaDestination => "tenant_id",
        ReferenceKind::MigrationSource | ReferenceKind::MigrationDestination => "index_name",
        ReferenceKind::AlgoliaDestination => "logical_target",
    };
    let statement =
        format!("SELECT {column} FROM {table} WHERE customer_id = $1 AND {identity_column} = $2");
    sqlx::query_scalar(&statement)
        .bind(customer_id)
        .bind(label)
        .fetch_optional(pool)
        .await
        .expect("read persisted VM reference")
        .flatten()
}

fn assert_reference_rejection(
    error: sqlx::Error,
    kind: ReferenceKind,
    target_vm_id: Uuid,
    target_status: &str,
) {
    let database_error = error
        .as_database_error()
        .expect("guard must return a PostgreSQL error");
    let (table, column) = kind.table_and_column();
    assert_eq!(database_error.code().as_deref(), Some("23514"));
    assert_eq!(
        database_error.message(),
        format!(
            "vm_inventory reference {table}.{column} to VM {target_vm_id} is not allowed while VM status is {target_status}"
        )
    );
}

fn unique_label(kind: ReferenceKind, operation: &str, status: &str) -> String {
    format!(
        "{}_{}_{}_{}",
        kind.label(),
        operation,
        status,
        Uuid::new_v4().simple()
    )
}
