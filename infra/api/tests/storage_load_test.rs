//! Manual S3 load harness — concurrent object traffic through the real router.
//!
//! These tests are `#[ignore]` and run only via `cargo test -- --ignored`.
//! They exercise PUT/GET/DELETE and list-type=2 at moderate concurrency
//! against stateful wiremock-backed Garage stubs, then assert bucket metering
//! converges.

mod common;
mod storage_s3_auth_support;
#[allow(dead_code)]
#[path = "common/storage_s3_signed_router_harness.rs"]
mod storage_s3_signed_router_harness;

use api::repos::storage_bucket_repo::StorageBucketRepo;
use api::services::storage::s3_xml::{list_objects_v2_result, ListObjectsV2Params, ObjectEntry};
use axum::http::StatusCode;
use common::storage_metering_test_support::{wait_for_bucket_egress, wait_for_bucket_totals};
use http_body_util::BodyExt;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use storage_s3_signed_router_harness::{
    setup_signed_s3_router_with_rps, signed_s3_request, SignedS3RouterHarness,
};
use tokio::task::JoinSet;
use tower::ServiceExt;
use wiremock::matchers::{method, path, query_param};
use wiremock::{Mock, Request, Respond, ResponseTemplate};

const CONCURRENCY: usize = 10;
const OBJECT_BODY_SIZE: usize = 1024;

fn load_body(index: usize) -> Vec<u8> {
    vec![(index % 256) as u8; OBJECT_BODY_SIZE]
}

fn object_key(index: usize) -> String {
    format!("load-obj-{index:04}")
}

fn list_objects_v2_xml(keys: &[String]) -> String {
    let objects = keys
        .iter()
        .map(|key| ObjectEntry {
            key: key.clone(),
            last_modified: "2026-03-19T00:00:00Z".to_string(),
            etag: "\"loadtest\"".to_string(),
            size: OBJECT_BODY_SIZE as u64,
            storage_class: "STANDARD".to_string(),
        })
        .collect::<Vec<_>>();

    list_objects_v2_result(
        &ListObjectsV2Params {
            bucket: "gridl-internal-123".to_string(),
            prefix: String::new(),
            max_keys: CONCURRENCY as u32,
            key_count: objects.len() as u32,
            is_truncated: false,
            continuation_token: None,
            next_continuation_token: None,
        },
        &objects,
    )
}

#[derive(Clone, Default)]
struct GarageLoadStore {
    objects: Arc<Mutex<BTreeMap<String, Vec<u8>>>>,
}

impl GarageLoadStore {
    fn new() -> Self {
        Self::default()
    }

    fn object_body(&self, key: &str) -> Option<Vec<u8>> {
        self.objects.lock().unwrap().get(key).cloned()
    }

    fn put_object(&self, key: &str, body: Vec<u8>) {
        self.objects.lock().unwrap().insert(key.to_string(), body);
    }

    fn delete_object(&self, key: &str) {
        self.objects.lock().unwrap().remove(key);
    }

    fn list_xml(&self) -> String {
        let keys = self
            .objects
            .lock()
            .unwrap()
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        list_objects_v2_xml(&keys)
    }
}

struct StatefulHead {
    store: GarageLoadStore,
    object_key: String,
}

impl Respond for StatefulHead {
    fn respond(&self, _req: &Request) -> ResponseTemplate {
        match self.store.object_body(&self.object_key) {
            Some(body) => {
                ResponseTemplate::new(200).insert_header("content-length", body.len().to_string())
            }
            None => ResponseTemplate::new(404),
        }
    }
}

struct StatefulPut {
    store: GarageLoadStore,
    object_key: String,
}

impl Respond for StatefulPut {
    fn respond(&self, req: &Request) -> ResponseTemplate {
        self.store.put_object(&self.object_key, req.body.clone());
        ResponseTemplate::new(200).insert_header("etag", "\"loadtest\"")
    }
}

struct StatefulGet {
    store: GarageLoadStore,
    object_key: String,
}

impl Respond for StatefulGet {
    fn respond(&self, _req: &Request) -> ResponseTemplate {
        match self.store.object_body(&self.object_key) {
            Some(body) => ResponseTemplate::new(200)
                .set_body_bytes(body.clone())
                .insert_header("content-length", body.len().to_string()),
            None => ResponseTemplate::new(404),
        }
    }
}

struct StatefulDelete {
    store: GarageLoadStore,
    object_key: String,
}

impl Respond for StatefulDelete {
    fn respond(&self, _req: &Request) -> ResponseTemplate {
        self.store.delete_object(&self.object_key);
        ResponseTemplate::new(204)
    }
}

struct StatefulList {
    store: GarageLoadStore,
}

impl Respond for StatefulList {
    fn respond(&self, _req: &Request) -> ResponseTemplate {
        ResponseTemplate::new(200)
            .set_body_string(self.store.list_xml())
            .insert_header("content-type", "application/xml")
    }
}

async fn response_body_bytes(resp: axum::response::Response) -> Vec<u8> {
    resp.into_body()
        .collect()
        .await
        .expect("response body collect")
        .to_bytes()
        .to_vec()
}

async fn response_body_string(resp: axum::response::Response) -> String {
    String::from_utf8(response_body_bytes(resp).await).expect("response body should be utf8")
}

async fn mount_stateful_garage_mocks(
    s: &SignedS3RouterHarness,
    store: &GarageLoadStore,
    keys: &[String],
) {
    for key in keys {
        let garage_path = format!("/gridl-internal-123/{key}");

        Mock::given(method("HEAD"))
            .and(path(garage_path.as_str()))
            .respond_with(StatefulHead {
                store: store.clone(),
                object_key: key.clone(),
            })
            .mount(&s.mock)
            .await;
        Mock::given(method("PUT"))
            .and(path(garage_path.as_str()))
            .respond_with(StatefulPut {
                store: store.clone(),
                object_key: key.clone(),
            })
            .mount(&s.mock)
            .await;
        Mock::given(method("GET"))
            .and(path(garage_path.as_str()))
            .respond_with(StatefulGet {
                store: store.clone(),
                object_key: key.clone(),
            })
            .mount(&s.mock)
            .await;
        Mock::given(method("DELETE"))
            .and(path(garage_path.as_str()))
            .respond_with(StatefulDelete {
                store: store.clone(),
                object_key: key.clone(),
            })
            .mount(&s.mock)
            .await;
    }

    Mock::given(method("GET"))
        .and(path("/gridl-internal-123"))
        .and(query_param("list-type", "2"))
        .respond_with(StatefulList {
            store: store.clone(),
        })
        .mount(&s.mock)
        .await;
}

fn assert_list_body_contains_keys(body: &str, keys: &[String]) {
    for key in keys {
        assert!(
            body.contains(&format!("<Key>{key}</Key>")),
            "list response missing surviving key {key}: {body}"
        );
    }
}

/// Spawn concurrent PUTs for `count` objects and wait for all to finish.
async fn concurrent_puts(s: &SignedS3RouterHarness, count: usize) {
    let mut set = JoinSet::new();
    for i in 0..count {
        let router = s.router.clone();
        let ak = s.access_key.clone();
        let sk = s.secret_key.clone();
        let key = object_key(i);
        let body = load_body(i);
        set.spawn(async move {
            let uri = format!("/my-bucket/{key}");
            let req = signed_s3_request("PUT", &uri, &ak, &sk, body);
            let resp = router.oneshot(req).await.expect("PUT oneshot");
            assert_eq!(resp.status(), StatusCode::OK, "PUT {key} failed");
        });
    }
    while let Some(result) = set.join_next().await {
        result.expect("PUT task panicked");
    }
}

// ---------------------------------------------------------------------------
// PUT / GET concurrent load harness
// ---------------------------------------------------------------------------

#[tokio::test]
#[ignore = "manual load harness"]
async fn manual_put_get_load_harness_converges_bucket_metering() {
    let s = setup_signed_s3_router_with_rps(1000).await;
    let store = GarageLoadStore::new();
    let keys = (0..CONCURRENCY).map(object_key).collect::<Vec<_>>();
    mount_stateful_garage_mocks(&s, &store, &keys).await;

    // --- Concurrent PUTs ---
    concurrent_puts(&s, CONCURRENCY).await;

    let expected_size = (CONCURRENCY * OBJECT_BODY_SIZE) as i64;
    let expected_count = CONCURRENCY as i64;
    wait_for_bucket_totals(
        s.bucket_repo.as_ref(),
        s.bucket.id,
        expected_size,
        expected_count,
    )
    .await;

    // --- Concurrent GETs ---
    let mut get_set = JoinSet::new();
    for i in 0..CONCURRENCY {
        let router = s.router.clone();
        let ak = s.access_key.clone();
        let sk = s.secret_key.clone();
        let key = object_key(i);
        let expected_body = load_body(i);
        get_set.spawn(async move {
            let uri = format!("/my-bucket/{key}");
            let req = signed_s3_request("GET", &uri, &ak, &sk, vec![]);
            let resp = router.oneshot(req).await.expect("GET oneshot");
            assert_eq!(resp.status(), StatusCode::OK, "GET {key} failed");
            let body = response_body_bytes(resp).await;
            assert_eq!(body, expected_body, "GET {key} returned the wrong payload");
        });
    }
    while let Some(result) = get_set.join_next().await {
        result.expect("GET task panicked");
    }

    let expected_egress = (CONCURRENCY * OBJECT_BODY_SIZE) as i64;
    wait_for_bucket_egress(s.bucket_repo.as_ref(), s.bucket.id, expected_egress).await;

    // Final convergence check
    let bucket = s.bucket_repo.get(s.bucket.id).await.unwrap().unwrap();
    assert_eq!(bucket.size_bytes, expected_size);
    assert_eq!(bucket.object_count, expected_count);
    assert_eq!(bucket.egress_bytes, expected_egress);
}

// ---------------------------------------------------------------------------
// DELETE / list churn workload
// ---------------------------------------------------------------------------

#[tokio::test]
#[ignore = "manual load harness"]
async fn manual_delete_list_churn_keeps_visibility_and_totals_consistent() {
    let s = setup_signed_s3_router_with_rps(1000).await;
    let store = GarageLoadStore::new();
    let all_keys = (0..CONCURRENCY).map(object_key).collect::<Vec<_>>();
    mount_stateful_garage_mocks(&s, &store, &all_keys).await;
    let delete_count = CONCURRENCY / 2;
    let remaining_keys = (delete_count..CONCURRENCY)
        .map(object_key)
        .collect::<Vec<_>>();
    let expected_list_body = list_objects_v2_xml(&remaining_keys);

    // Phase 1: seed objects via concurrent PUTs
    concurrent_puts(&s, CONCURRENCY).await;

    let expected_size = (CONCURRENCY * OBJECT_BODY_SIZE) as i64;
    let expected_count = CONCURRENCY as i64;
    wait_for_bucket_totals(
        s.bucket_repo.as_ref(),
        s.bucket.id,
        expected_size,
        expected_count,
    )
    .await;

    // Phase 2: delete the first half while list requests observe live object state.
    let list_count = CONCURRENCY - delete_count;

    let mut churn_set = JoinSet::new();
    for i in 0..delete_count {
        let router = s.router.clone();
        let ak = s.access_key.clone();
        let sk = s.secret_key.clone();
        let key = object_key(i);
        churn_set.spawn(async move {
            let uri = format!("/my-bucket/{key}");
            let req = signed_s3_request("DELETE", &uri, &ak, &sk, vec![]);
            let resp = router.oneshot(req).await.expect("DELETE oneshot");
            assert_eq!(resp.status(), StatusCode::NO_CONTENT, "DELETE {key} failed");
        });
    }
    for _ in 0..list_count {
        let router = s.router.clone();
        let ak = s.access_key.clone();
        let sk = s.secret_key.clone();
        let remaining_keys = remaining_keys.clone();
        churn_set.spawn(async move {
            let req = signed_s3_request("GET", "/my-bucket?list-type=2", &ak, &sk, vec![]);
            let resp = router.oneshot(req).await.expect("list oneshot");
            assert_eq!(resp.status(), StatusCode::OK, "list-type=2 failed");
            let body = response_body_string(resp).await;
            assert_list_body_contains_keys(&body, &remaining_keys);
        });
    }
    while let Some(result) = churn_set.join_next().await {
        result.expect("churn task panicked");
    }

    // After deleting half, metering converges to remaining objects.
    let remaining_count = (CONCURRENCY - delete_count) as i64;
    let remaining_size = remaining_count * OBJECT_BODY_SIZE as i64;
    wait_for_bucket_totals(
        s.bucket_repo.as_ref(),
        s.bucket.id,
        remaining_size,
        remaining_count,
    )
    .await;

    let bucket = s.bucket_repo.get(s.bucket.id).await.unwrap().unwrap();
    assert_eq!(bucket.size_bytes, remaining_size);
    assert_eq!(bucket.object_count, remaining_count);

    let req = signed_s3_request(
        "GET",
        "/my-bucket?list-type=2",
        &s.access_key,
        &s.secret_key,
        vec![],
    );
    let resp = s
        .router
        .clone()
        .oneshot(req)
        .await
        .expect("final list oneshot");
    assert_eq!(resp.status(), StatusCode::OK);
    let body = response_body_string(resp).await;
    assert_eq!(
        body, expected_list_body,
        "final list should match the surviving objects after delete churn"
    );
}
