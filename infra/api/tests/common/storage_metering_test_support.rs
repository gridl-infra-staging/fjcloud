//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/tests/common/storage_metering_test_support.rs.
use async_trait::async_trait;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;

use api::models::storage::{NewStorageBucket, StorageBucket};
use api::repos::error::RepoError;
use api::repos::storage_bucket_repo::StorageBucketRepo;
use api::repos::InMemoryStorageBucketRepo;
use tokio::sync::Notify;
use uuid::Uuid;

pub struct SizeWriteTracker {
    release_writes: AtomicBool,
    started: AtomicUsize,
    completed: AtomicUsize,
    started_notify: Notify,
    completed_notify: Notify,
    release_notify: Notify,
}

impl SizeWriteTracker {
    pub fn new(release_writes: bool) -> Arc<Self> {
        Arc::new(Self {
            release_writes: AtomicBool::new(release_writes),
            started: AtomicUsize::new(0),
            completed: AtomicUsize::new(0),
            started_notify: Notify::new(),
            completed_notify: Notify::new(),
            release_notify: Notify::new(),
        })
    }

    pub async fn wait_for_started(&self, expected: usize) {
        while self.started.load(Ordering::SeqCst) < expected {
            self.started_notify.notified().await;
        }
    }

    pub async fn wait_for_completed(&self, expected: usize) {
        while self.completed.load(Ordering::SeqCst) < expected {
            self.completed_notify.notified().await;
        }
    }

    pub async fn before_write(&self) {
        self.started.fetch_add(1, Ordering::SeqCst);
        self.started_notify.notify_waiters();
        while !self.release_writes.load(Ordering::SeqCst) {
            self.release_notify.notified().await;
        }
    }

    pub fn finish_write(&self) {
        self.completed.fetch_add(1, Ordering::SeqCst);
        self.completed_notify.notify_waiters();
    }

    pub fn release(&self) {
        self.release_writes.store(true, Ordering::SeqCst);
        self.release_notify.notify_waiters();
    }

    pub fn reset(&self) {
        self.started.store(0, Ordering::SeqCst);
        self.completed.store(0, Ordering::SeqCst);
    }
}

/// Polls the bucket repo until `size_bytes` and `object_count` match the
/// expected values, or panics after a 2-second timeout. Used by metering
/// integration tests to wait for asynchronous size-update propagation.
pub async fn wait_for_bucket_totals(
    bucket_repo: &dyn StorageBucketRepo,
    bucket_id: Uuid,
    expected_size_bytes: i64,
    expected_object_count: i64,
) {
    wait_for_bucket_state(
        bucket_repo,
        bucket_id,
        "bucket totals should converge",
        |bucket| {
            bucket.size_bytes == expected_size_bytes && bucket.object_count == expected_object_count
        },
    )
    .await;
}

pub async fn wait_for_bucket_egress(
    bucket_repo: &dyn StorageBucketRepo,
    bucket_id: Uuid,
    expected_egress_bytes: i64,
) {
    wait_for_bucket_state(
        bucket_repo,
        bucket_id,
        "bucket egress should converge",
        |bucket| bucket.egress_bytes == expected_egress_bytes,
    )
    .await;
}

/// Generic poll-until-match loop for bucket state assertions. Reads the
/// bucket every 10 ms and returns once `matches_expected` is true, or
/// panics with `timeout_message` after 2 seconds.
async fn wait_for_bucket_state(
    bucket_repo: &dyn StorageBucketRepo,
    bucket_id: Uuid,
    timeout_message: &'static str,
    matches_expected: impl Fn(&StorageBucket) -> bool,
) {
    tokio::time::timeout(std::time::Duration::from_secs(2), async {
        loop {
            let bucket = bucket_repo
                .get(bucket_id)
                .await
                .expect("bucket repo get")
                .expect("bucket should exist");
            if matches_expected(&bucket) {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await
    .expect(timeout_message);
}

pub struct ObservedStorageBucketRepo {
    inner: Arc<InMemoryStorageBucketRepo>,
    size_writes: Arc<SizeWriteTracker>,
}

impl ObservedStorageBucketRepo {
    pub fn new(size_writes: Arc<SizeWriteTracker>) -> Self {
        Self {
            inner: Arc::new(InMemoryStorageBucketRepo::new()),
            size_writes,
        }
    }
}

#[async_trait]
impl StorageBucketRepo for ObservedStorageBucketRepo {
    async fn create(
        &self,
        bucket: NewStorageBucket,
        garage_bucket: &str,
    ) -> Result<StorageBucket, RepoError> {
        self.inner.create(bucket, garage_bucket).await
    }

    async fn get(&self, id: Uuid) -> Result<Option<StorageBucket>, RepoError> {
        self.inner.get(id).await
    }

    async fn get_by_name(
        &self,
        customer_id: Uuid,
        name: &str,
    ) -> Result<Option<StorageBucket>, RepoError> {
        self.inner.get_by_name(customer_id, name).await
    }

    async fn list_by_customer(&self, customer_id: Uuid) -> Result<Vec<StorageBucket>, RepoError> {
        self.inner.list_by_customer(customer_id).await
    }

    async fn list_all(&self) -> Result<Vec<StorageBucket>, RepoError> {
        self.inner.list_all().await
    }

    async fn increment_size(
        &self,
        id: Uuid,
        size_delta: i64,
        count_delta: i64,
    ) -> Result<(), RepoError> {
        self.size_writes.before_write().await;
        let result = self.inner.increment_size(id, size_delta, count_delta).await;
        self.size_writes.finish_write();
        result
    }

    async fn increment_egress(&self, id: Uuid, bytes: i64) -> Result<(), RepoError> {
        self.inner.increment_egress(id, bytes).await
    }

    async fn update_egress_watermark(&self, id: Uuid, new_watermark: i64) -> Result<(), RepoError> {
        self.inner.update_egress_watermark(id, new_watermark).await
    }

    async fn set_deleted(&self, id: Uuid) -> Result<(), RepoError> {
        self.inner.set_deleted(id).await
    }
}
