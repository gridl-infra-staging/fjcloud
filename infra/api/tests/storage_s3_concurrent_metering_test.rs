//! Concurrent same-key object metering regression tests.
//!
//! Proves that `S3ObjectMeteringService`'s per-key lock keeps `size_bytes`
//! and `object_count` correct across overlapping PUT/DELETE interleavings.
//! Uses stateful wiremock responders that simulate Garage's actual behavior
//! (HEAD reflects prior PUTs/DELETEs), ensuring metering deltas stay
//! self-consistent under all possible orderings.

mod common;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use api::models::storage::NewStorageBucket;
use api::repos::storage_bucket_repo::StorageBucketRepo;
use api::services::storage::object_metering::{
    MeteredMutationKind, MeteredObjectMutation, S3ObjectMeteringService,
};
use api::services::storage::s3_proxy::{GarageProxy, GarageProxyConfig};
use common::storage_metering_test_support::{ObservedStorageBucketRepo, SizeWriteTracker};
use tokio::sync::Barrier;
use uuid::Uuid;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, Request, Respond, ResponseTemplate};

// ---------------------------------------------------------------------------
// Stateful Garage mock — tracks per-key object state
// ---------------------------------------------------------------------------

/// Simulates Garage's per-object state so HEAD responses reflect prior mutations.
#[derive(Clone, Default)]
struct GarageObjectStore {
    objects: Arc<Mutex<HashMap<String, i64>>>,
}

impl GarageObjectStore {
    fn new() -> Self {
        Self::default()
    }

    fn seed(&self, key: &str, size: i64) {
        self.objects.lock().unwrap().insert(key.to_string(), size);
    }

    fn get_size(&self, key: &str) -> Option<i64> {
        self.objects.lock().unwrap().get(key).copied()
    }
}

/// Responds to HEAD: 200+content-length if object exists, 404 otherwise.
struct StatefulHead {
    store: GarageObjectStore,
    object_key: String,
}

impl Respond for StatefulHead {
    fn respond(&self, _req: &Request) -> ResponseTemplate {
        let objects = self.store.objects.lock().unwrap();
        match objects.get(&self.object_key) {
            Some(&size) => {
                ResponseTemplate::new(200).insert_header("content-length", size.to_string())
            }
            None => ResponseTemplate::new(404),
        }
    }
}

/// Responds to PUT by storing body length; returns 200.
struct StatefulPut {
    store: GarageObjectStore,
    object_key: String,
}

impl Respond for StatefulPut {
    fn respond(&self, req: &Request) -> ResponseTemplate {
        let size = req.body.len() as i64;
        self.store
            .objects
            .lock()
            .unwrap()
            .insert(self.object_key.clone(), size);
        ResponseTemplate::new(200)
    }
}

/// Responds to DELETE by removing the object; returns 204.
struct StatefulDelete {
    store: GarageObjectStore,
    object_key: String,
}

impl Respond for StatefulDelete {
    fn respond(&self, _req: &Request) -> ResponseTemplate {
        self.store.objects.lock().unwrap().remove(&self.object_key);
        ResponseTemplate::new(204)
    }
}

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------

struct MeteringHarness {
    bucket_repo: Arc<ObservedStorageBucketRepo>,
    metering: Arc<S3ObjectMeteringService>,
    garage_store: GarageObjectStore,
    size_writes: Arc<SizeWriteTracker>,
    bucket_id: Uuid,
    garage_bucket: String,
}

async fn setup_harness(mock: &MockServer) -> MeteringHarness {
    setup_harness_with_size_writes(mock, SizeWriteTracker::new(true)).await
}

async fn setup_harness_with_size_writes(
    mock: &MockServer,
    size_writes: Arc<SizeWriteTracker>,
) -> MeteringHarness {
    let bucket_repo = Arc::new(ObservedStorageBucketRepo::new(size_writes.clone()));
    let customer_id = Uuid::new_v4();
    let garage_proxy = Arc::new(GarageProxy::new(
        reqwest::Client::new(),
        GarageProxyConfig {
            endpoint: mock.uri(),
            access_key: "test-ak".to_string(),
            secret_key: "test-sk".to_string(),
            region: "garage".to_string(),
        },
    ));

    let bucket = bucket_repo
        .create(
            NewStorageBucket {
                customer_id,
                name: "test-bucket".to_string(),
            },
            "gbkt",
        )
        .await
        .expect("seed bucket");

    let metering = Arc::new(S3ObjectMeteringService::new(
        bucket_repo.clone(),
        garage_proxy,
    ));

    MeteringHarness {
        bucket_repo,
        metering,
        garage_store: GarageObjectStore::new(),
        size_writes,
        bucket_id: bucket.id,
        garage_bucket: "gbkt".to_string(),
    }
}

async fn mount_stateful_mocks(mock: &MockServer, store: &GarageObjectStore, garage_path: &str) {
    Mock::given(method("HEAD"))
        .and(path(garage_path))
        .respond_with(StatefulHead {
            store: store.clone(),
            object_key: garage_path.to_string(),
        })
        .mount(mock)
        .await;
    Mock::given(method("PUT"))
        .and(path(garage_path))
        .respond_with(StatefulPut {
            store: store.clone(),
            object_key: garage_path.to_string(),
        })
        .mount(mock)
        .await;
    Mock::given(method("DELETE"))
        .and(path(garage_path))
        .respond_with(StatefulDelete {
            store: store.clone(),
            object_key: garage_path.to_string(),
        })
        .mount(mock)
        .await;
}

async fn read_aggregate(h: &MeteringHarness) -> (i64, i64) {
    let bucket = h.bucket_repo.get(h.bucket_id).await.unwrap().unwrap();
    (bucket.size_bytes, bucket.object_count)
}

async fn wait_for_aggregate(
    h: &MeteringHarness,
    expected_size: i64,
    expected_count: i64,
    expected_size_writes: usize,
) {
    tokio::time::timeout(std::time::Duration::from_secs(2), async {
        h.size_writes.wait_for_completed(expected_size_writes).await;
        loop {
            let aggregate = read_aggregate(h).await;
            if aggregate == (expected_size, expected_count) {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("bucket aggregates should converge");
}

// ---------------------------------------------------------------------------
// PUT + PUT overwrite
// ---------------------------------------------------------------------------

#[tokio::test]
async fn concurrent_put_put_overwrite_aggregates_are_correct() {
    let mock = MockServer::start().await;
    let h = setup_harness(&mock).await;
    let garage_path = format!("/{}/same-key.bin", h.garage_bucket);
    mount_stateful_mocks(&mock, &h.garage_store, &garage_path).await;

    let body_a = vec![0u8; 100];
    let body_b = vec![0u8; 250];
    let barrier = Arc::new(Barrier::new(2));

    let m1 = h.metering.clone();
    let gb1 = h.garage_bucket.clone();
    let bid1 = h.bucket_id;
    let ba = body_a.clone();
    let b1 = barrier.clone();
    let t1 = tokio::spawn(async move {
        b1.wait().await;
        m1.execute(MeteredObjectMutation {
            bucket_id: bid1,
            garage_bucket: &gb1,
            key: "same-key.bin",
            headers: &[],
            body: &ba,
            kind: MeteredMutationKind::Put,
        })
        .await
    });

    let m2 = h.metering.clone();
    let gb2 = h.garage_bucket.clone();
    let bid2 = h.bucket_id;
    let bb = body_b.clone();
    let b2 = barrier.clone();
    let t2 = tokio::spawn(async move {
        b2.wait().await;
        m2.execute(MeteredObjectMutation {
            bucket_id: bid2,
            garage_bucket: &gb2,
            key: "same-key.bin",
            headers: &[],
            body: &bb,
            kind: MeteredMutationKind::Put,
        })
        .await
    });

    let (r1, r2) = tokio::join!(t1, t2);
    r1.unwrap().expect("put A should succeed");
    r2.unwrap().expect("put B should succeed");

    let garage_size = h.garage_store.get_size(&garage_path).unwrap_or(0);
    wait_for_aggregate(&h, garage_size, 1, 2).await;

    let (size, count) = read_aggregate(&h).await;
    // Lock serialises: either A-then-B or B-then-A. Both produce count=1.
    // size equals whichever PUT ran last (the overwriter).
    assert_eq!(
        count, 1,
        "object_count must be 1 after two PUTs to the same key"
    );
    assert!(
        size == body_a.len() as i64 || size == body_b.len() as i64,
        "size_bytes ({size}) must equal the last-writer's body length (100 or 250)"
    );
    // Cross-check: DB size matches Garage's current object size.
    assert_eq!(
        size, garage_size,
        "DB size_bytes must match Garage object size"
    );
}

#[tokio::test]
async fn wait_for_aggregate_does_not_finish_before_blocked_metering_writes_complete() {
    let mock = MockServer::start().await;
    let size_writes = SizeWriteTracker::new(false);
    let h = setup_harness_with_size_writes(&mock, size_writes.clone()).await;
    let repo_a = h.bucket_repo.clone();
    let first_bucket_id = h.bucket_id;
    let first_write =
        tokio::spawn(async move { repo_a.increment_size(first_bucket_id, 75, 1).await });

    let repo_b = h.bucket_repo.clone();
    let second_bucket_id = h.bucket_id;
    let second_write =
        tokio::spawn(async move { repo_b.increment_size(second_bucket_id, -75, -1).await });

    size_writes.wait_for_started(2).await;
    let premature_wait = tokio::time::timeout(
        std::time::Duration::from_millis(100),
        wait_for_aggregate(&h, 0, 0, 2),
    )
    .await;
    assert!(
        premature_wait.is_err(),
        "aggregate wait must not return while size writes are still blocked"
    );

    size_writes.release();
    first_write
        .await
        .unwrap()
        .expect("first size write should succeed");
    second_write
        .await
        .unwrap()
        .expect("second size write should succeed");
    wait_for_aggregate(&h, 0, 0, 2).await;
}

// ---------------------------------------------------------------------------
// PUT + DELETE (initially empty)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn concurrent_put_delete_initially_empty_aggregates_are_correct() {
    let mock = MockServer::start().await;
    let h = setup_harness(&mock).await;
    let garage_path = format!("/{}/ephemeral.bin", h.garage_bucket);
    mount_stateful_mocks(&mock, &h.garage_store, &garage_path).await;

    let body = vec![1u8; 75];
    let barrier = Arc::new(Barrier::new(2));

    let m1 = h.metering.clone();
    let gb1 = h.garage_bucket.clone();
    let bid1 = h.bucket_id;
    let bdy = body.clone();
    let b1 = barrier.clone();
    let put_handle = tokio::spawn(async move {
        b1.wait().await;
        m1.execute(MeteredObjectMutation {
            bucket_id: bid1,
            garage_bucket: &gb1,
            key: "ephemeral.bin",
            headers: &[],
            body: &bdy,
            kind: MeteredMutationKind::Put,
        })
        .await
    });

    let m2 = h.metering.clone();
    let gb2 = h.garage_bucket.clone();
    let bid2 = h.bucket_id;
    let b2 = barrier.clone();
    let delete_handle = tokio::spawn(async move {
        b2.wait().await;
        m2.execute(MeteredObjectMutation {
            bucket_id: bid2,
            garage_bucket: &gb2,
            key: "ephemeral.bin",
            headers: &[],
            body: &[],
            kind: MeteredMutationKind::Delete,
        })
        .await
    });

    let (r1, r2) = tokio::join!(put_handle, delete_handle);
    r1.unwrap().expect("put should succeed");
    r2.unwrap().expect("delete should succeed");

    let garage_exists = h.garage_store.get_size(&garage_path).is_some();
    let expected = if garage_exists {
        (body.len() as i64, 1)
    } else {
        (0, 0)
    };
    let expected_size_writes = if garage_exists { 1 } else { 2 };

    wait_for_aggregate(&h, expected.0, expected.1, expected_size_writes).await;

    let (size, count) = read_aggregate(&h).await;

    if garage_exists {
        // DELETE ran first (no-op on missing), then PUT created the object.
        assert_eq!(size, body.len() as i64);
        assert_eq!(count, 1);
    } else {
        // PUT ran first (created), then DELETE removed it.
        assert_eq!(size, 0);
        assert_eq!(count, 0);
    }
}

// ---------------------------------------------------------------------------
// DELETE + PUT recreate (initially present)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn concurrent_delete_put_recreate_aggregates_are_correct() {
    let mock = MockServer::start().await;
    let h = setup_harness(&mock).await;
    let garage_path = format!("/{}/existing.bin", h.garage_bucket);
    mount_stateful_mocks(&mock, &h.garage_store, &garage_path).await;

    // Pre-seed: object exists in Garage (50 bytes) and DB reflects it.
    h.garage_store.seed(&garage_path, 50);
    h.bucket_repo
        .increment_size(h.bucket_id, 50, 1)
        .await
        .unwrap();
    h.size_writes.reset();

    let new_body = vec![2u8; 200];
    let barrier = Arc::new(Barrier::new(2));

    let m1 = h.metering.clone();
    let gb1 = h.garage_bucket.clone();
    let bid1 = h.bucket_id;
    let b1 = barrier.clone();
    let delete_handle = tokio::spawn(async move {
        b1.wait().await;
        m1.execute(MeteredObjectMutation {
            bucket_id: bid1,
            garage_bucket: &gb1,
            key: "existing.bin",
            headers: &[],
            body: &[],
            kind: MeteredMutationKind::Delete,
        })
        .await
    });

    let m2 = h.metering.clone();
    let gb2 = h.garage_bucket.clone();
    let bid2 = h.bucket_id;
    let nb = new_body.clone();
    let b2 = barrier.clone();
    let put_handle = tokio::spawn(async move {
        b2.wait().await;
        m2.execute(MeteredObjectMutation {
            bucket_id: bid2,
            garage_bucket: &gb2,
            key: "existing.bin",
            headers: &[],
            body: &nb,
            kind: MeteredMutationKind::Put,
        })
        .await
    });

    let (r1, r2) = tokio::join!(delete_handle, put_handle);
    r1.unwrap().expect("delete should succeed");
    r2.unwrap().expect("put should succeed");

    let garage_obj = h.garage_store.get_size(&garage_path);
    let expected = match garage_obj {
        Some(garage_size) => (garage_size, 1),
        None => (0, 0),
    };

    wait_for_aggregate(&h, expected.0, expected.1, 2).await;

    let (size, count) = read_aggregate(&h).await;

    match garage_obj {
        Some(garage_size) => {
            // DELETE ran first, then PUT recreated.
            assert_eq!(size, garage_size);
            assert_eq!(size, new_body.len() as i64);
            assert_eq!(count, 1);
        }
        None => {
            // PUT ran first (overwrite: 50→200), then DELETE removed.
            assert_eq!(size, 0);
            assert_eq!(count, 0);
        }
    }
}
