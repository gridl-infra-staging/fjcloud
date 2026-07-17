use api::repos::{InMemoryIndexReplicaRepo, IndexReplicaRepo, PgIndexReplicaRepo};
use uuid::Uuid;

/// Verify PgIndexReplicaRepo implements IndexReplicaRepo trait (compile-time check).
fn _assert_pg_impl_trait(repo: PgIndexReplicaRepo) {
    let _: Box<dyn IndexReplicaRepo> = Box::new(repo);
}

// --- All functional tests run against the InMemoryIndexReplicaRepo ---
// PgIndexReplicaRepo is verified only at compile time (trait impl check above).
// Its SQL methods are not yet covered by automated tests.

#[tokio::test]
async fn replica_create_and_get() {
    let repo = InMemoryIndexReplicaRepo::new();
    let customer_id = Uuid::new_v4();
    let primary_vm_id = Uuid::new_v4();
    let replica_vm_id = Uuid::new_v4();

    let created = repo
        .create(
            customer_id,
            "products",
            primary_vm_id,
            replica_vm_id,
            "eu-central-1",
        )
        .await
        .expect("create should succeed");

    assert_eq!(created.customer_id, customer_id);
    assert_eq!(created.tenant_id, "products");
    assert_eq!(created.primary_vm_id, primary_vm_id);
    assert_eq!(created.replica_vm_id, replica_vm_id);
    assert_eq!(created.replica_region, "eu-central-1");
    assert_eq!(created.status, "provisioning");
    assert_eq!(created.lag_ops, 0);

    let fetched = repo.get(created.id).await.expect("get should succeed");
    assert!(fetched.is_some());
    assert_eq!(fetched.unwrap().id, created.id);
}

#[tokio::test]
async fn replica_list_by_index() {
    let repo = InMemoryIndexReplicaRepo::new();
    let customer_id = Uuid::new_v4();
    let primary_vm_id = Uuid::new_v4();

    repo.create(
        customer_id,
        "products",
        primary_vm_id,
        Uuid::new_v4(),
        "eu-central-1",
    )
    .await
    .unwrap();
    repo.create(
        customer_id,
        "products",
        primary_vm_id,
        Uuid::new_v4(),
        "eu-north-1",
    )
    .await
    .unwrap();
    repo.create(
        customer_id,
        "other-index",
        primary_vm_id,
        Uuid::new_v4(),
        "eu-central-1",
    )
    .await
    .unwrap();

    let replicas = repo.list_by_index(customer_id, "products").await.unwrap();
    assert_eq!(replicas.len(), 2);
}

#[tokio::test]
async fn replica_list_healthy_only_active() {
    let repo = InMemoryIndexReplicaRepo::new();
    let customer_id = Uuid::new_v4();
    let primary_vm_id = Uuid::new_v4();

    let active = repo
        .create(
            customer_id,
            "products",
            primary_vm_id,
            Uuid::new_v4(),
            "eu-central-1",
        )
        .await
        .unwrap();
    let syncing = repo
        .create(
            customer_id,
            "products",
            primary_vm_id,
            Uuid::new_v4(),
            "eu-north-1",
        )
        .await
        .unwrap();

    repo.set_status(active.id, "active").await.unwrap();
    repo.set_status(syncing.id, "syncing").await.unwrap();

    let healthy = repo
        .list_healthy_by_index(customer_id, "products")
        .await
        .unwrap();
    assert_eq!(healthy.len(), 1);
    assert_eq!(healthy[0].id, active.id);
}

#[tokio::test]
async fn replica_set_lag_does_not_update_timestamp() {
    let repo = InMemoryIndexReplicaRepo::new();
    let customer_id = Uuid::new_v4();

    let created = repo
        .create(
            customer_id,
            "products",
            Uuid::new_v4(),
            Uuid::new_v4(),
            "eu-central-1",
        )
        .await
        .unwrap();

    let before = repo.get(created.id).await.unwrap().unwrap().updated_at;
    // set_lag should NOT update updated_at (important for syncing timeout tracking)
    repo.set_lag(created.id, 500).await.unwrap();
    let after = repo.get(created.id).await.unwrap().unwrap();

    assert_eq!(after.lag_ops, 500);
    assert_eq!(after.updated_at, before);
}

#[tokio::test]
async fn replica_unique_constraint() {
    let repo = InMemoryIndexReplicaRepo::new();
    let customer_id = Uuid::new_v4();
    let primary_vm_id = Uuid::new_v4();
    let replica_vm_id = Uuid::new_v4();

    repo.create(
        customer_id,
        "products",
        primary_vm_id,
        replica_vm_id,
        "eu-central-1",
    )
    .await
    .unwrap();

    let result = repo
        .create(
            customer_id,
            "products",
            primary_vm_id,
            replica_vm_id,
            "eu-central-1",
        )
        .await;

    assert!(
        result.is_err(),
        "duplicate (customer, tenant, vm) should be rejected"
    );
}

#[tokio::test]
async fn replica_list_actionable_excludes_terminal() {
    let repo = InMemoryIndexReplicaRepo::new();
    let customer_id = Uuid::new_v4();
    let primary_vm_id = Uuid::new_v4();

    let r1 = repo
        .create(
            customer_id,
            "p",
            primary_vm_id,
            Uuid::new_v4(),
            "eu-central-1",
        )
        .await
        .unwrap();
    let r2 = repo
        .create(
            customer_id,
            "p",
            primary_vm_id,
            Uuid::new_v4(),
            "eu-north-1",
        )
        .await
        .unwrap();
    let r3 = repo
        .create(customer_id, "p", primary_vm_id, Uuid::new_v4(), "us-east-2")
        .await
        .unwrap();

    repo.set_status(r1.id, "active").await.unwrap();
    repo.set_status(r2.id, "failed").await.unwrap();
    repo.set_status(r3.id, "removing").await.unwrap();

    let actionable = repo.list_actionable().await.unwrap();
    assert_eq!(actionable.len(), 1);
    assert_eq!(actionable[0].id, r1.id);
}

#[tokio::test]
async fn replica_delete() {
    let repo = InMemoryIndexReplicaRepo::new();
    let customer_id = Uuid::new_v4();

    let created = repo
        .create(
            customer_id,
            "products",
            Uuid::new_v4(),
            Uuid::new_v4(),
            "eu-central-1",
        )
        .await
        .unwrap();

    let deleted = repo.delete(created.id).await.unwrap();
    assert!(deleted);

    let fetched = repo.get(created.id).await.unwrap();
    assert!(fetched.is_none());

    // Deleting again returns false
    let deleted_again = repo.delete(created.id).await.unwrap();
    assert!(!deleted_again);
}

#[tokio::test]
async fn replica_count_by_index() {
    let repo = InMemoryIndexReplicaRepo::new();
    let customer_id = Uuid::new_v4();
    let primary_vm_id = Uuid::new_v4();

    repo.create(
        customer_id,
        "products",
        primary_vm_id,
        Uuid::new_v4(),
        "eu-central-1",
    )
    .await
    .unwrap();
    repo.create(
        customer_id,
        "products",
        primary_vm_id,
        Uuid::new_v4(),
        "eu-north-1",
    )
    .await
    .unwrap();

    let count = repo.count_by_index(customer_id, "products").await.unwrap();
    assert_eq!(count, 2);

    let other_count = repo.count_by_index(customer_id, "other").await.unwrap();
    assert_eq!(other_count, 0);
}
