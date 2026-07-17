use api::models::NewRestoreJob;
use api::repos::{InMemoryRestoreJobRepo, RepoError, RestoreJobRepo};
use uuid::Uuid;

fn new_job(customer_id: Uuid, tenant_id: &str, idempotency_key: &str) -> NewRestoreJob {
    NewRestoreJob {
        customer_id,
        tenant_id: tenant_id.to_string(),
        snapshot_id: Uuid::new_v4(),
        dest_vm_id: Some(Uuid::new_v4()),
        idempotency_key: idempotency_key.to_string(),
    }
}

#[tokio::test]
async fn restore_job_create_and_idempotency() {
    let repo = InMemoryRestoreJobRepo::new();
    let customer_id = Uuid::new_v4();

    let created = repo
        .create(new_job(customer_id, "products", "cust:products"))
        .await
        .expect("create should succeed");

    assert_eq!(created.status, "queued");

    let duplicate = repo
        .create(new_job(customer_id, "products", "cust:products"))
        .await;

    assert!(
        matches!(duplicate, Err(RepoError::Conflict(_))),
        "duplicate active idempotency key should conflict"
    );
}

#[tokio::test]
async fn restore_job_status_transitions() {
    let repo = InMemoryRestoreJobRepo::new();
    let customer_id = Uuid::new_v4();

    let created = repo
        .create(new_job(customer_id, "products", "cust:products"))
        .await
        .expect("create should succeed");

    repo.update_status(created.id, "downloading", None)
        .await
        .expect("downloading transition should succeed");

    let after_downloading = repo
        .get(created.id)
        .await
        .expect("get should succeed")
        .expect("job should exist");
    assert_eq!(after_downloading.status, "downloading");
    assert!(after_downloading.started_at.is_some());

    repo.update_status(created.id, "importing", None)
        .await
        .expect("importing transition should succeed");
    repo.set_completed(created.id)
        .await
        .expect("set_completed should succeed");

    let completed = repo
        .get(created.id)
        .await
        .expect("get should succeed")
        .expect("job should exist");
    assert_eq!(completed.status, "completed");
    assert!(completed.started_at.is_some());
    assert!(completed.completed_at.is_some());
}

#[tokio::test]
async fn restore_job_list_active() {
    let repo = InMemoryRestoreJobRepo::new();
    let customer_id = Uuid::new_v4();

    let queued = repo
        .create(new_job(customer_id, "queued", "cust:queued"))
        .await
        .expect("queued create should succeed");

    let downloading = repo
        .create(new_job(customer_id, "downloading", "cust:downloading"))
        .await
        .expect("downloading create should succeed");
    repo.update_status(downloading.id, "downloading", None)
        .await
        .expect("set downloading should succeed");

    let importing = repo
        .create(new_job(customer_id, "importing", "cust:importing"))
        .await
        .expect("importing create should succeed");
    repo.update_status(importing.id, "importing", None)
        .await
        .expect("set importing should succeed");

    let completed = repo
        .create(new_job(customer_id, "completed", "cust:completed"))
        .await
        .expect("completed create should succeed");
    repo.set_completed(completed.id)
        .await
        .expect("set completed should succeed");

    let failed = repo
        .create(new_job(customer_id, "failed", "cust:failed"))
        .await
        .expect("failed create should succeed");
    repo.update_status(failed.id, "failed", Some("download failed"))
        .await
        .expect("set failed should succeed");

    let active = repo
        .list_active()
        .await
        .expect("list_active should succeed");
    let active_ids: Vec<Uuid> = active.iter().map(|job| job.id).collect();

    assert_eq!(active.len(), 3);
    assert!(active_ids.contains(&queued.id));
    assert!(active_ids.contains(&downloading.id));
    assert!(active_ids.contains(&importing.id));
    assert!(!active_ids.contains(&completed.id));
    assert!(!active_ids.contains(&failed.id));

    assert_eq!(repo.count_active().await.expect("count should succeed"), 3);
}

#[tokio::test]
async fn find_by_idempotency_key_returns_active_job() {
    let repo = InMemoryRestoreJobRepo::new();
    let customer_id = Uuid::new_v4();

    let created = repo
        .create(new_job(customer_id, "products", "cust:products"))
        .await
        .expect("create should succeed");

    // Active job should be found
    let found = repo
        .find_by_idempotency_key("cust:products")
        .await
        .expect("find should succeed")
        .expect("active job should be found");
    assert_eq!(found.id, created.id);

    // Non-existent key returns None
    let not_found = repo
        .find_by_idempotency_key("cust:nonexistent")
        .await
        .expect("find should succeed");
    assert!(not_found.is_none());

    // Completed job no longer found by idempotency key
    repo.set_completed(created.id).await.unwrap();
    let after_complete = repo
        .find_by_idempotency_key("cust:products")
        .await
        .expect("find should succeed");
    assert!(
        after_complete.is_none(),
        "completed job should not be returned by idempotency lookup"
    );
}
