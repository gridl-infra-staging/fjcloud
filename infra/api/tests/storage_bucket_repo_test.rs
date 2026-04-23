use api::models::storage::NewStorageBucket;
use api::repos::storage_bucket_repo::StorageBucketRepo;
use api::repos::InMemoryStorageBucketRepo;
use uuid::Uuid;

fn repo() -> InMemoryStorageBucketRepo {
    InMemoryStorageBucketRepo::new()
}

fn new_bucket(customer_id: Uuid) -> NewStorageBucket {
    NewStorageBucket {
        customer_id,
        name: "test-bucket".to_string(),
    }
}

#[tokio::test]
async fn create_and_get_bucket() {
    let repo = repo();
    let cid = Uuid::new_v4();
    let bucket = repo
        .create(new_bucket(cid), "garage-internal-abc123")
        .await
        .unwrap();

    assert_eq!(bucket.customer_id, cid);
    assert_eq!(bucket.name, "test-bucket");
    assert_eq!(bucket.garage_bucket, "garage-internal-abc123");
    assert_eq!(bucket.status, "active");
    assert_eq!(bucket.size_bytes, 0);
    assert_eq!(bucket.object_count, 0);
    assert_eq!(bucket.egress_bytes, 0);

    let fetched = repo.get(bucket.id).await.unwrap().unwrap();
    assert_eq!(fetched.id, bucket.id);
}

#[tokio::test]
async fn get_by_name_returns_active_only() {
    let repo = repo();
    let cid = Uuid::new_v4();
    let bucket = repo.create(new_bucket(cid), "garage-1").await.unwrap();

    let found = repo.get_by_name(cid, "test-bucket").await.unwrap();
    assert!(found.is_some());
    assert_eq!(found.unwrap().id, bucket.id);

    // After soft-delete, get_by_name should return None
    repo.set_deleted(bucket.id).await.unwrap();
    let gone = repo.get_by_name(cid, "test-bucket").await.unwrap();
    assert!(gone.is_none());
}

#[tokio::test]
async fn list_by_customer_excludes_deleted() {
    let repo = repo();
    let cid = Uuid::new_v4();

    let b1 = repo
        .create(
            NewStorageBucket {
                customer_id: cid,
                name: "bucket-a".to_string(),
            },
            "g-a",
        )
        .await
        .unwrap();
    let _b2 = repo
        .create(
            NewStorageBucket {
                customer_id: cid,
                name: "bucket-b".to_string(),
            },
            "g-b",
        )
        .await
        .unwrap();

    assert_eq!(repo.list_by_customer(cid).await.unwrap().len(), 2);

    repo.set_deleted(b1.id).await.unwrap();
    assert_eq!(repo.list_by_customer(cid).await.unwrap().len(), 1);
}

#[tokio::test]
async fn duplicate_active_name_conflicts() {
    let repo = repo();
    let cid = Uuid::new_v4();
    repo.create(new_bucket(cid), "g-1").await.unwrap();

    let err = repo.create(new_bucket(cid), "g-2").await.unwrap_err();
    assert!(matches!(err, api::repos::RepoError::Conflict(_)));
}

#[tokio::test]
async fn deleted_name_can_be_reused() {
    let repo = repo();
    let cid = Uuid::new_v4();
    let b1 = repo.create(new_bucket(cid), "g-1").await.unwrap();
    repo.set_deleted(b1.id).await.unwrap();

    // Same name should now succeed
    let b2 = repo.create(new_bucket(cid), "g-2").await.unwrap();
    assert_ne!(b1.id, b2.id);
    assert_eq!(b2.name, "test-bucket");
}

#[tokio::test]
async fn increment_size_positive_and_negative() {
    let repo = repo();
    let cid = Uuid::new_v4();
    let bucket = repo.create(new_bucket(cid), "g-1").await.unwrap();

    repo.increment_size(bucket.id, 1024, 1).await.unwrap();
    let b = repo.get(bucket.id).await.unwrap().unwrap();
    assert_eq!(b.size_bytes, 1024);
    assert_eq!(b.object_count, 1);

    repo.increment_size(bucket.id, -512, -1).await.unwrap();
    let b = repo.get(bucket.id).await.unwrap().unwrap();
    assert_eq!(b.size_bytes, 512);
    assert_eq!(b.object_count, 0);
}

#[tokio::test]
async fn increment_egress() {
    let repo = repo();
    let cid = Uuid::new_v4();
    let bucket = repo.create(new_bucket(cid), "g-1").await.unwrap();

    repo.increment_egress(bucket.id, 2048).await.unwrap();
    repo.increment_egress(bucket.id, 1024).await.unwrap();
    let b = repo.get(bucket.id).await.unwrap().unwrap();
    assert_eq!(b.egress_bytes, 3072);
}

#[tokio::test]
async fn update_egress_watermark() {
    let repo = repo();
    let cid = Uuid::new_v4();
    let bucket = repo.create(new_bucket(cid), "g-1").await.unwrap();

    repo.update_egress_watermark(bucket.id, 5000).await.unwrap();
    let b = repo.get(bucket.id).await.unwrap().unwrap();
    assert_eq!(b.egress_watermark_bytes, 5000);
}

#[tokio::test]
async fn increment_on_nonexistent_returns_not_found() {
    let repo = repo();
    let err = repo
        .increment_size(Uuid::new_v4(), 10, 1)
        .await
        .unwrap_err();
    assert!(matches!(err, api::repos::RepoError::NotFound));
}

#[tokio::test]
async fn list_all_returns_active_across_customers() {
    let repo = repo();
    let c1 = Uuid::new_v4();
    let c2 = Uuid::new_v4();

    repo.create(
        NewStorageBucket {
            customer_id: c1,
            name: "a".to_string(),
        },
        "g-a",
    )
    .await
    .unwrap();
    repo.create(
        NewStorageBucket {
            customer_id: c2,
            name: "b".to_string(),
        },
        "g-b",
    )
    .await
    .unwrap();

    assert_eq!(repo.list_all().await.unwrap().len(), 2);
}
