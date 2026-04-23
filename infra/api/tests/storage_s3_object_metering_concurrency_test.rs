//! Concurrency regressions for same-key object metering.

mod common;

use api::repos::storage_bucket_repo::StorageBucketRepo;
use axum::body::{Body, Bytes};
use axum::extract::{Path, State};
use axum::http::{Method, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{head, put};
use axum::Router;
use common::storage_metering_test_support::wait_for_bucket_totals;
use common::storage_s3_object_route_support::{
    s3_request, s3_request_with_body, setup_object_router,
};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio::sync::{Mutex, Notify};
use tower::ServiceExt;

#[derive(Clone, Copy)]
struct ObjectState {
    exists: bool,
    size_bytes: i64,
}

enum RequestSpec {
    Put(Vec<u8>),
    Delete,
}

struct ConcurrentMutationScenario {
    first_mutation_release: Notify,
    first_mutation_started: Notify,
    first_mutation_done: Notify,
    first_mutation_finished: AtomicBool,
    head_seen: Notify,
    head_count: AtomicUsize,
    mutation_count: AtomicUsize,
    object: Mutex<ObjectState>,
}

impl ConcurrentMutationScenario {
    fn new(object: ObjectState) -> Arc<Self> {
        Arc::new(Self {
            first_mutation_release: Notify::new(),
            first_mutation_started: Notify::new(),
            first_mutation_done: Notify::new(),
            first_mutation_finished: AtomicBool::new(false),
            head_seen: Notify::new(),
            head_count: AtomicUsize::new(0),
            mutation_count: AtomicUsize::new(0),
            object: Mutex::new(object),
        })
    }

    async fn wait_for_first_mutation_start(&self) {
        if self.mutation_count.load(Ordering::SeqCst) > 0 {
            return;
        }
        self.first_mutation_started.notified().await;
    }

    async fn wait_for_second_head_before_release(&self) -> bool {
        if self.head_count.load(Ordering::SeqCst) >= 2 {
            return true;
        }

        tokio::time::timeout(std::time::Duration::from_millis(200), async {
            loop {
                self.head_seen.notified().await;
                if self.head_count.load(Ordering::SeqCst) >= 2 {
                    break;
                }
            }
        })
        .await
        .is_ok()
    }

    fn release_first_mutation(&self) {
        self.first_mutation_release.notify_waiters();
    }

    async fn handle_head(&self) -> impl IntoResponse {
        self.head_count.fetch_add(1, Ordering::SeqCst);
        self.head_seen.notify_waiters();

        let object = *self.object.lock().await;
        if object.exists {
            (
                StatusCode::OK,
                [("content-length", object.size_bytes.to_string())],
            )
                .into_response()
        } else {
            StatusCode::NOT_FOUND.into_response()
        }
    }

    async fn handle_put(&self, body: Bytes) -> impl IntoResponse {
        let ordinal = self.mutation_count.fetch_add(1, Ordering::SeqCst) + 1;
        if ordinal == 1 {
            self.first_mutation_started.notify_waiters();
            self.first_mutation_release.notified().await;
        } else if !self.first_mutation_finished.load(Ordering::SeqCst) {
            self.first_mutation_done.notified().await;
        }

        let body_len = body.len() as i64;
        let mut object = self.object.lock().await;
        object.exists = true;
        object.size_bytes = body_len;
        drop(object);

        if ordinal == 1 {
            self.first_mutation_finished.store(true, Ordering::SeqCst);
            self.first_mutation_done.notify_waiters();
        }
        StatusCode::OK.into_response()
    }

    async fn handle_delete(&self) -> impl IntoResponse {
        let ordinal = self.mutation_count.fetch_add(1, Ordering::SeqCst) + 1;
        if ordinal == 1 {
            self.first_mutation_started.notify_waiters();
            self.first_mutation_release.notified().await;
        } else if !self.first_mutation_finished.load(Ordering::SeqCst) {
            self.first_mutation_done.notified().await;
        }

        let mut object = self.object.lock().await;
        object.exists = false;
        object.size_bytes = 0;
        drop(object);

        if ordinal == 1 {
            self.first_mutation_finished.store(true, Ordering::SeqCst);
            self.first_mutation_done.notify_waiters();
        }
        StatusCode::NO_CONTENT.into_response()
    }
}

async fn start_concurrent_garage(
    scenario: Arc<ConcurrentMutationScenario>,
) -> (String, tokio::task::JoinHandle<()>) {
    async fn head_handler(
        State(scenario): State<Arc<ConcurrentMutationScenario>>,
        Path((_bucket, _key)): Path<(String, String)>,
    ) -> impl IntoResponse {
        scenario.handle_head().await
    }

    async fn put_handler(
        State(scenario): State<Arc<ConcurrentMutationScenario>>,
        Path((_bucket, _key)): Path<(String, String)>,
        body: Bytes,
    ) -> impl IntoResponse {
        scenario.handle_put(body).await
    }

    async fn delete_handler(
        State(scenario): State<Arc<ConcurrentMutationScenario>>,
        Path((_bucket, _key)): Path<(String, String)>,
    ) -> impl IntoResponse {
        scenario.handle_delete().await
    }

    let app = Router::new()
        .route(
            "/:bucket/*key",
            head(head_handler).put(put_handler).delete(delete_handler),
        )
        .with_state(scenario);
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let addr = listener.local_addr().expect("local addr");
    let handle = tokio::spawn(async move {
        axum::serve(listener, app)
            .await
            .expect("garage test server");
    });

    (format!("http://{}", addr), handle)
}

async fn run_same_key_scenario(
    scenario: Arc<ConcurrentMutationScenario>,
    first_request: RequestSpec,
    second_request: RequestSpec,
    expected_statuses: (StatusCode, StatusCode),
    expected_totals: (i64, i64),
    initial_totals: (i64, i64),
) {
    let (mock, bucket_repo, _router, customer_id, bucket_id, bucket) = setup_object_router().await;
    bucket_repo
        .increment_size(bucket.id, initial_totals.0, initial_totals.1)
        .await
        .expect("seed bucket totals");

    let (endpoint, server_handle) = start_concurrent_garage(scenario.clone()).await;
    let garage_proxy = Arc::new(api::services::storage::s3_proxy::GarageProxy::new(
        reqwest::Client::new(),
        api::services::storage::s3_proxy::GarageProxyConfig {
            endpoint,
            access_key: "test-access-key".to_string(),
            secret_key: "test-secret-key".to_string(),
            region: "garage".to_string(),
        },
    ));
    drop(mock);

    let state = common::TestStateBuilder::new()
        .with_storage_bucket_repo(bucket_repo.clone())
        .with_garage_proxy(garage_proxy)
        .build();
    let router = Router::new()
        .route(
            "/:bucket/*key",
            put(api::routes::storage::objects::put_object)
                .delete(api::routes::storage::objects::delete_object),
        )
        .with_state(state);

    let first_request = build_request(first_request, customer_id, bucket_id);
    let second_request = build_request(second_request, customer_id, bucket_id);
    let first_handle = tokio::spawn(router.clone().oneshot(first_request));
    scenario.wait_for_first_mutation_start().await;

    let second_handle = tokio::spawn(router.clone().oneshot(second_request));
    let stale_head_seen = scenario.wait_for_second_head_before_release().await;
    assert!(
        !stale_head_seen,
        "same-key second HEAD reached Garage before the first mutation completed"
    );

    scenario.release_first_mutation();

    let first_response = first_handle
        .await
        .expect("first task")
        .expect("first response");
    let second_response = second_handle
        .await
        .expect("second task")
        .expect("second response");
    assert_eq!(first_response.status(), expected_statuses.0);
    assert_eq!(second_response.status(), expected_statuses.1);

    wait_for_bucket_totals(
        bucket_repo.as_ref(),
        bucket_id,
        expected_totals.0,
        expected_totals.1,
    )
    .await;

    server_handle.abort();
}

fn build_request(
    spec: RequestSpec,
    customer_id: uuid::Uuid,
    bucket_id: uuid::Uuid,
) -> axum::http::Request<Body> {
    match spec {
        RequestSpec::Put(body) => s3_request_with_body(
            Method::PUT,
            "/my-bucket/my-key.txt",
            customer_id,
            bucket_id,
            body,
        ),
        RequestSpec::Delete => s3_request(
            Method::DELETE,
            "/my-bucket/my-key.txt",
            customer_id,
            bucket_id,
        ),
    }
}

#[tokio::test]
async fn same_key_put_put_overwrite_keeps_bucket_totals_correct() {
    let scenario = ConcurrentMutationScenario::new(ObjectState {
        exists: false,
        size_bytes: 0,
    });

    run_same_key_scenario(
        scenario,
        RequestSpec::Put(b"first-body".to_vec()),
        RequestSpec::Put(b"replacement-body".to_vec()),
        (StatusCode::OK, StatusCode::OK),
        ("replacement-body".len() as i64, 1),
        (0, 0),
    )
    .await;
}

#[tokio::test]
async fn same_key_put_delete_keeps_bucket_totals_correct() {
    let scenario = ConcurrentMutationScenario::new(ObjectState {
        exists: true,
        size_bytes: 5,
    });

    run_same_key_scenario(
        scenario,
        RequestSpec::Put(b"0123456789".to_vec()),
        RequestSpec::Delete,
        (StatusCode::OK, StatusCode::NO_CONTENT),
        (0, 0),
        (5, 1),
    )
    .await;
}

#[tokio::test]
async fn same_key_delete_put_recreate_keeps_bucket_totals_correct() {
    let scenario = ConcurrentMutationScenario::new(ObjectState {
        exists: true,
        size_bytes: 5,
    });

    run_same_key_scenario(
        scenario,
        RequestSpec::Delete,
        RequestSpec::Put(b"recreated".to_vec()),
        (StatusCode::NO_CONTENT, StatusCode::OK),
        ("recreated".len() as i64, 1),
        (5, 1),
    )
    .await;
}
