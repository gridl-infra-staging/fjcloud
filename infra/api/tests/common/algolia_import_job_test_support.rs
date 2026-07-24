use api::models::algolia_import_job::{
    AlgoliaImportCreateDestination, AlgoliaImportJob, AlgoliaImportSource,
    AlgoliaImportSourceMetadata, NewAlgoliaImportJob, NewAlgoliaReplaceImportJob,
};
use api::repos::{AlgoliaImportDispatchAdmission, AlgoliaImportJobRepo, PgAlgoliaImportJobRepo};
use serde_json::json;
use sqlx::PgPool;
use uuid::Uuid;

pub fn new_job(customer_id: Uuid, key: &str) -> NewAlgoliaImportJob {
    new_create_job(customer_id, "products", key)
}

pub fn new_create_job(customer_id: Uuid, target: &str, key: &str) -> NewAlgoliaImportJob {
    NewAlgoliaImportJob::create(
        customer_id,
        AlgoliaImportCreateDestination::new(target, "us-east-1"),
        AlgoliaImportSource::from_final_key_metadata(
            "AB12CD34EF",
            "Products",
            AlgoliaImportSourceMetadata::new(Some(12_345), Some(1_000), format!("revision-{key}")),
        ),
        key,
    )
}

pub fn replace_job(customer_id: Uuid, target: &str, key: &str) -> NewAlgoliaReplaceImportJob {
    NewAlgoliaReplaceImportJob::new(
        customer_id,
        target,
        AlgoliaImportSource::from_final_key_metadata(
            "AB12CD34EF",
            "Products",
            AlgoliaImportSourceMetadata::new(Some(12_345), Some(1_000), format!("revision-{key}")),
        ),
        key,
    )
}

pub async fn admit_create_dispatch(
    repo: &PgAlgoliaImportJobRepo,
    job: NewAlgoliaImportJob,
) -> AlgoliaImportJob {
    repo.admit_dispatch(AlgoliaImportDispatchAdmission::Create(job))
        .await
        .expect("admit create dispatch fixture")
        .into_job()
}

pub async fn admit_replace_dispatch(
    repo: &PgAlgoliaImportJobRepo,
    job: NewAlgoliaReplaceImportJob,
) -> AlgoliaImportJob {
    repo.admit_dispatch(AlgoliaImportDispatchAdmission::Replace(job))
        .await
        .expect("admit replace dispatch fixture")
        .into_job()
}

pub async fn seed_replace_target(pool: &PgPool, customer_id: Uuid, target: &str) {
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
