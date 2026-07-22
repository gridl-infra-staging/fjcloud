use sqlx::PgPool;
use uuid::Uuid;

pub const EXPECTED_VM_REFERENCE_COLUMNS: &[(&str, &str)] = &[
    ("customer_tenants", "vm_id"),
    ("index_migrations", "source_vm_id"),
    ("index_migrations", "dest_vm_id"),
    ("cold_snapshots", "source_vm_id"),
    ("restore_jobs", "dest_vm_id"),
    ("index_replicas", "primary_vm_id"),
    ("index_replicas", "replica_vm_id"),
    ("algolia_import_jobs", "destination_vm_id"),
];

pub const EXPECTED_PERSISTED_VM_REFERENCE_COLUMNS: &[(&str, &str)] = &[
    ("customer_tenants", "vm_id"),
    ("index_migrations", "source_vm_id"),
    ("index_migrations", "dest_vm_id"),
    ("cold_snapshots", "source_vm_id"),
    ("restore_jobs", "dest_vm_id"),
    ("index_replicas", "primary_vm_id"),
    ("index_replicas", "replica_vm_id"),
    ("algolia_import_jobs", "destination_vm_id"),
    ("vm_host_metrics", "vm_id"),
];

#[derive(Clone, Copy)]
pub struct AlgoliaReservationState<'a> {
    pub status: &'a str,
    pub publication_disposition: &'a str,
    pub resumable: bool,
    pub engine_ack_state: &'a str,
}

pub async fn insert_all_live_vm_references(
    pool: &PgPool,
    target_vm_id: Uuid,
    other_vm_id: Uuid,
    label: &str,
) {
    let customer_id = insert_customer(pool, label).await;
    let deployment_id = insert_deployment(pool, customer_id, &format!("{label}-node")).await;

    insert_tenant(
        pool,
        customer_id,
        deployment_id,
        &format!("{label}_tenant"),
        target_vm_id,
    )
    .await
    .expect("insert live tenant reference");
    insert_tenant_without_vm(
        pool,
        customer_id,
        deployment_id,
        &format!("{label}_replica"),
    )
    .await;
    insert_index_migration(
        pool,
        customer_id,
        &format!("{label}_migration"),
        target_vm_id,
        target_vm_id,
        "pending",
    )
    .await
    .expect("insert live migration references");
    insert_cold_snapshot(
        pool,
        customer_id,
        &format!("{label}_snapshot"),
        target_vm_id,
        "completed",
    )
    .await
    .expect("insert live snapshot reference");
    insert_restore_job(
        pool,
        customer_id,
        &format!("{label}_restore"),
        other_vm_id,
        target_vm_id,
        "importing",
    )
    .await
    .expect("insert live restore reference");
    insert_index_replica(
        pool,
        customer_id,
        &format!("{label}_replica"),
        target_vm_id,
        target_vm_id,
        "active",
    )
    .await
    .expect("insert live replica references");
    insert_algolia_import_job(
        pool,
        customer_id,
        &format!("{label}_algolia"),
        target_vm_id,
        AlgoliaReservationState {
            status: "queued",
            publication_disposition: "not_started",
            resumable: false,
            engine_ack_state: "pending",
        },
    )
    .await
    .expect("insert live Algolia reference");
}

pub async fn insert_vm(pool: &PgPool, hostname: &str, status: &str) -> Uuid {
    let vm_id = Uuid::new_v4();
    insert_vm_with_id(pool, vm_id, hostname, status).await;
    vm_id
}

pub async fn insert_vm_with_id(pool: &PgPool, vm_id: Uuid, hostname: &str, status: &str) {
    sqlx::query(
        "INSERT INTO vm_inventory (id, region, provider, hostname, flapjack_url, status)
         VALUES ($1, 'us-east-1', 'aws', $2, $3, $4)",
    )
    .bind(vm_id)
    .bind(hostname)
    .bind(format!("https://{hostname}.test"))
    .bind(status)
    .execute(pool)
    .await
    .expect("insert vm");
}

pub async fn insert_customer(pool: &PgPool, label: &str) -> Uuid {
    sqlx::query_scalar(
        "INSERT INTO customers (name, email, status)
         VALUES ($1, $2, 'active')
         RETURNING id",
    )
    .bind(label)
    .bind(format!("{label}@vm-reference-guard.test"))
    .fetch_one(pool)
    .await
    .expect("insert customer")
}

pub async fn insert_deployment(pool: &PgPool, customer_id: Uuid, node_id: &str) -> Uuid {
    sqlx::query_scalar(
        "INSERT INTO customer_deployments (customer_id, node_id, region, vm_type, vm_provider, status)
         VALUES ($1, $2, 'us-east-1', 't4g.small', 'aws', 'running')
         RETURNING id",
    )
    .bind(customer_id)
    .bind(node_id)
    .fetch_one(pool)
    .await
    .expect("insert deployment")
}

pub async fn insert_tenant(
    pool: &PgPool,
    customer_id: Uuid,
    deployment_id: Uuid,
    tenant_id: &str,
    vm_id: Uuid,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO customer_tenants (customer_id, tenant_id, deployment_id, vm_id)
         VALUES ($1, $2, $3, $4)",
    )
    .bind(customer_id)
    .bind(tenant_id)
    .bind(deployment_id)
    .bind(vm_id)
    .execute(pool)
    .await
    .map(|_| ())
}

pub async fn insert_tenant_without_vm(
    pool: &PgPool,
    customer_id: Uuid,
    deployment_id: Uuid,
    tenant_id: &str,
) {
    sqlx::query(
        "INSERT INTO customer_tenants (customer_id, tenant_id, deployment_id, vm_id)
         VALUES ($1, $2, $3, NULL)",
    )
    .bind(customer_id)
    .bind(tenant_id)
    .bind(deployment_id)
    .execute(pool)
    .await
    .expect("insert tenant without vm");
}

pub async fn insert_index_migration(
    pool: &PgPool,
    customer_id: Uuid,
    index_name: &str,
    source_vm_id: Uuid,
    dest_vm_id: Uuid,
    status: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO index_migrations
            (index_name, customer_id, source_vm_id, dest_vm_id, status, requested_by)
         VALUES ($1, $2, $3, $4, $5, 'test')",
    )
    .bind(index_name)
    .bind(customer_id)
    .bind(source_vm_id)
    .bind(dest_vm_id)
    .bind(status)
    .execute(pool)
    .await
    .map(|_| ())
}

pub async fn insert_cold_snapshot(
    pool: &PgPool,
    customer_id: Uuid,
    tenant_id: &str,
    source_vm_id: Uuid,
    status: &str,
) -> Result<Uuid, sqlx::Error> {
    sqlx::query_scalar(
        "INSERT INTO cold_snapshots
            (customer_id, tenant_id, source_vm_id, object_key, status)
         VALUES ($1, $2, $3, $4, $5)
         RETURNING id",
    )
    .bind(customer_id)
    .bind(tenant_id)
    .bind(source_vm_id)
    .bind(format!("{tenant_id}/snapshot"))
    .bind(status)
    .fetch_one(pool)
    .await
}

pub async fn insert_restore_job(
    pool: &PgPool,
    customer_id: Uuid,
    tenant_id: &str,
    snapshot_source_vm_id: Uuid,
    dest_vm_id: Uuid,
    status: &str,
) -> Result<(), sqlx::Error> {
    let snapshot_id = insert_cold_snapshot(
        pool,
        customer_id,
        &format!("{tenant_id}_snapshot"),
        snapshot_source_vm_id,
        "expired",
    )
    .await?;

    sqlx::query(
        "INSERT INTO restore_jobs
            (customer_id, tenant_id, snapshot_id, dest_vm_id, status, idempotency_key)
         VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(customer_id)
    .bind(tenant_id)
    .bind(snapshot_id)
    .bind(dest_vm_id)
    .bind(status)
    .bind(format!("{tenant_id}-key"))
    .execute(pool)
    .await
    .map(|_| ())
}

pub async fn insert_index_replica(
    pool: &PgPool,
    customer_id: Uuid,
    tenant_id: &str,
    primary_vm_id: Uuid,
    replica_vm_id: Uuid,
    status: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO index_replicas
            (customer_id, tenant_id, primary_vm_id, replica_vm_id, replica_region, status)
         VALUES ($1, $2, $3, $4, 'us-west-2', $5)",
    )
    .bind(customer_id)
    .bind(tenant_id)
    .bind(primary_vm_id)
    .bind(replica_vm_id)
    .bind(status)
    .execute(pool)
    .await
    .map(|_| ())
}

pub async fn insert_algolia_import_job(
    pool: &PgPool,
    customer_id: Uuid,
    logical_target: &str,
    destination_vm_id: Uuid,
    state: AlgoliaReservationState<'_>,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO algolia_import_jobs
            (customer_id, tenant_id, algolia_app_id, destination_kind, logical_target,
             destination_region, destination_vm_id, physical_uid, source_name,
             lifecycle_generation, idempotency_key, canonical_fingerprint, routing_identity,
             source_size_bytes, status, publication_disposition, resumable, engine_ack_state,
             dispatch_intent_state, engine_job_id, terminal_at)
         VALUES
            ($1, $2, 'ALGOLIA1', 'create', $2, 'us-east-1', $3, $4, $5,
             1, $6, $7, $8, 0, $9, $10, $11, $12,
             CASE WHEN $9 IN ('completed', 'completed_with_warnings') THEN 'committed' ELSE 'absent' END,
             CASE WHEN $9 IN ('completed', 'completed_with_warnings') THEN gen_random_uuid() ELSE NULL END,
             CASE WHEN $9 IN ('completed', 'completed_with_warnings') THEN NOW() ELSE NULL END)",
    )
    .bind(customer_id)
    .bind(logical_target)
    .bind(destination_vm_id)
    .bind(format!("{logical_target}-physical"))
    .bind(format!("{logical_target}_source"))
    .bind(format!("{logical_target}-key"))
    .bind(format!("{logical_target}-fingerprint"))
    .bind(format!("{logical_target}-route"))
    .bind(state.status)
    .bind(state.publication_disposition)
    .bind(state.resumable)
    .bind(state.engine_ack_state)
    .execute(pool)
    .await
    .map(|_| ())
}
