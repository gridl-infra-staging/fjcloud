use api::models::NewColdSnapshot;
use api::repos::{ColdSnapshotRepo, InMemoryColdSnapshotRepo, RepoError};
use chrono::{Datelike, NaiveDate};
use uuid::Uuid;

fn new_snapshot(customer_id: Uuid, tenant_id: &str, source_vm_id: Uuid) -> NewColdSnapshot {
    NewColdSnapshot {
        customer_id,
        tenant_id: tenant_id.to_string(),
        source_vm_id,
        object_key: format!("cold/{customer_id}/{tenant_id}/snapshot.fj"),
    }
}

#[tokio::test]
async fn cold_snapshot_create_and_get() {
    let repo = InMemoryColdSnapshotRepo::new();
    let customer_id = Uuid::new_v4();
    let source_vm_id = Uuid::new_v4();

    let created = repo
        .create(new_snapshot(customer_id, "products", source_vm_id))
        .await
        .expect("create should succeed");

    let fetched = repo
        .get(created.id)
        .await
        .expect("get should succeed")
        .expect("snapshot should exist");

    assert_eq!(fetched.id, created.id);
    assert_eq!(fetched.customer_id, customer_id);
    assert_eq!(fetched.tenant_id, "products");
    assert_eq!(fetched.source_vm_id, source_vm_id);
    assert_eq!(fetched.status, "pending");
    assert_eq!(fetched.size_bytes, 0);
    assert!(fetched.checksum.is_none());
    assert!(fetched.completed_at.is_none());
}

#[tokio::test]
async fn cold_snapshot_status_transitions() {
    let repo = InMemoryColdSnapshotRepo::new();
    let customer_id = Uuid::new_v4();

    let created = repo
        .create(new_snapshot(customer_id, "products", Uuid::new_v4()))
        .await
        .expect("create should succeed");

    repo.set_exporting(created.id)
        .await
        .expect("set_exporting should succeed");
    repo.set_completed(created.id, 4096, "abc123")
        .await
        .expect("set_completed should succeed");

    let completed = repo
        .get(created.id)
        .await
        .expect("get should succeed")
        .expect("snapshot should exist");

    assert_eq!(completed.status, "completed");
    assert_eq!(completed.size_bytes, 4096);
    assert_eq!(completed.checksum.as_deref(), Some("abc123"));
    assert!(completed.completed_at.is_some());
}

#[tokio::test]
async fn cold_snapshot_duplicate_prevention() {
    let repo = InMemoryColdSnapshotRepo::new();
    let customer_id = Uuid::new_v4();
    let source_vm_id = Uuid::new_v4();

    repo.create(new_snapshot(customer_id, "products", source_vm_id))
        .await
        .expect("first snapshot should succeed");

    let duplicate = repo
        .create(new_snapshot(customer_id, "products", source_vm_id))
        .await;

    assert!(
        matches!(duplicate, Err(RepoError::Conflict(_))),
        "second active snapshot for same index should conflict"
    );
}

#[tokio::test]
async fn cold_snapshot_find_active_for_index() {
    let repo = InMemoryColdSnapshotRepo::new();
    let customer_id = Uuid::new_v4();

    let first = repo
        .create(new_snapshot(customer_id, "products", Uuid::new_v4()))
        .await
        .expect("create should succeed");
    repo.set_exporting(first.id)
        .await
        .expect("set_exporting should succeed");
    repo.set_completed(first.id, 100, "hash-1")
        .await
        .expect("set_completed should succeed");

    let active = repo
        .find_active_for_index(customer_id, "products")
        .await
        .expect("find active should succeed")
        .expect("completed snapshot should be active");
    assert_eq!(active.id, first.id);

    repo.set_expired(first.id)
        .await
        .expect("set_expired should succeed");
    let none_after_expired = repo
        .find_active_for_index(customer_id, "products")
        .await
        .expect("find active should succeed after expiration");
    assert!(none_after_expired.is_none());

    let failed = repo
        .create(new_snapshot(customer_id, "products", Uuid::new_v4()))
        .await
        .expect("new snapshot should be allowed after expired");
    repo.set_failed(failed.id, "upload failed")
        .await
        .expect("set_failed should succeed");

    let none_after_failed = repo
        .find_active_for_index(customer_id, "products")
        .await
        .expect("find active should succeed after failure");
    assert!(none_after_failed.is_none());
}

#[tokio::test]
async fn cold_snapshot_set_failed() {
    let repo = InMemoryColdSnapshotRepo::new();
    let customer_id = Uuid::new_v4();

    let first = repo
        .create(new_snapshot(customer_id, "products", Uuid::new_v4()))
        .await
        .expect("first snapshot should succeed");

    repo.set_failed(first.id, "export timeout")
        .await
        .expect("set_failed should succeed");

    let second = repo
        .create(new_snapshot(customer_id, "products", Uuid::new_v4()))
        .await
        .expect("new snapshot should be allowed after failed status");

    assert_eq!(second.status, "pending");
    assert_ne!(second.id, first.id);
}

#[tokio::test]
async fn list_completed_for_billing_returns_completed_only() {
    let repo = InMemoryColdSnapshotRepo::new();
    let customer_id = Uuid::new_v4();

    // Create and complete a snapshot
    let completed = repo
        .create(new_snapshot(customer_id, "products", Uuid::new_v4()))
        .await
        .expect("create should succeed");
    repo.set_exporting(completed.id).await.unwrap();
    repo.set_completed(completed.id, 5000, "hash-c1")
        .await
        .unwrap();

    // Create a failed snapshot (different index)
    let failed = repo
        .create(new_snapshot(customer_id, "logs", Uuid::new_v4()))
        .await
        .expect("create should succeed");
    repo.set_failed(failed.id, "upload error").await.unwrap();

    // Create a pending snapshot (different index)
    let _pending = repo
        .create(new_snapshot(customer_id, "events", Uuid::new_v4()))
        .await
        .expect("create should succeed");

    // Use the persisted completion timestamp so the billing window always matches the snapshot.
    let completed_snapshot = repo
        .get(completed.id)
        .await
        .expect("get should succeed")
        .expect("completed snapshot should exist");
    let completed_date = completed_snapshot
        .completed_at
        .expect("completed snapshot should have completed_at")
        .naive_utc()
        .date();
    let period_start =
        NaiveDate::from_ymd_opt(completed_date.year(), completed_date.month(), 1).unwrap();
    let period_end = (period_start + chrono::Months::new(1)) - chrono::Duration::days(1);

    let results = repo
        .list_completed_for_billing(period_start, period_end)
        .await
        .expect("list should succeed");

    assert_eq!(results.len(), 1);
    assert_eq!(results[0].id, completed.id);
    assert_eq!(results[0].size_bytes, 5000);
    assert_eq!(results[0].status, "completed");
}
