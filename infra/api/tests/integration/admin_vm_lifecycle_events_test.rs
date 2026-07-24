use api::models::{NewVmLifecycleEvent, VmLifecycleEventType};
use api::repos::VmLifecycleEventRepo;
use api::router::build_router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{json, Value};
use std::sync::Arc;
use tower::ServiceExt;
use uuid::Uuid;

use crate::common::{
    MockVmInventoryRepo, MockVmLifecycleEventRepo, TestStateBuilder, TEST_ADMIN_KEY,
};

async fn response_json(response: axum::response::Response) -> Value {
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&body).unwrap()
}

fn admin_request(path: String) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(path)
        .header("X-Admin-Key", TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap()
}

fn mock_backed_admin_app() -> (
    axum::Router,
    Arc<MockVmInventoryRepo>,
    Arc<MockVmLifecycleEventRepo>,
) {
    let vm_inventory_repo = Arc::new(MockVmInventoryRepo::new());
    let vm_lifecycle_event_repo = Arc::new(MockVmLifecycleEventRepo::new());
    let state = TestStateBuilder::new()
        .with_vm_inventory_repo(vm_inventory_repo.clone())
        .with_vm_lifecycle_event_repo(vm_lifecycle_event_repo.clone())
        .build();
    (
        build_router(state),
        vm_inventory_repo,
        vm_lifecycle_event_repo,
    )
}

async fn append_event(
    repo: &MockVmLifecycleEventRepo,
    vm_id: Uuid,
    event_type: VmLifecycleEventType,
    detail: Value,
) -> api::models::VmLifecycleEvent {
    repo.append(NewVmLifecycleEvent {
        vm_id,
        event_type,
        detail,
    })
    .await
    .expect("append lifecycle event")
}

#[tokio::test]
async fn vm_lifecycle_events_requires_admin_key() {
    let app = build_router(TestStateBuilder::new().build());
    let vm_id = Uuid::new_v4();

    let response = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/admin/vms/{vm_id}/lifecycle-events"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn vm_lifecycle_events_returns_404_for_unknown_vm() {
    let (app, _vm_inventory_repo, _event_repo) = mock_backed_admin_app();
    let unknown_vm_id = Uuid::new_v4();

    let response = app
        .oneshot(admin_request(format!(
            "/admin/vms/{unknown_vm_id}/lifecycle-events"
        )))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn vm_lifecycle_events_returns_empty_array_for_known_vm_and_static_subroute_owns_path() {
    let (app, vm_inventory_repo, _event_repo) = mock_backed_admin_app();
    let vm = vm_inventory_repo.seed("us-east-1", "https://admin-lifecycle-empty.test");

    let response = app
        .oneshot(admin_request(format!(
            "/admin/vms/{}/lifecycle-events",
            vm.id
        )))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response_json(response).await, json!([]));
}

#[tokio::test]
async fn vm_lifecycle_events_returns_chronological_json_without_cross_vm_leakage() {
    let (app, vm_inventory_repo, event_repo) = mock_backed_admin_app();
    let vm = vm_inventory_repo.seed("us-east-1", "https://admin-lifecycle-primary.test");
    let other_vm = vm_inventory_repo.seed("us-east-1", "https://admin-lifecycle-other.test");

    let first = append_event(
        &event_repo,
        vm.id,
        VmLifecycleEventType::DetectedDead,
        json!({"detector":"host_status"}),
    )
    .await;
    tokio::time::sleep(std::time::Duration::from_millis(1)).await;
    append_event(
        &event_repo,
        other_vm.id,
        VmLifecycleEventType::ReplacementRefused,
        json!({"guardrail":"other_vm_guardrail"}),
    )
    .await;
    tokio::time::sleep(std::time::Duration::from_millis(1)).await;
    let second = append_event(
        &event_repo,
        vm.id,
        VmLifecycleEventType::ReplacementProvisioning,
        json!({"provider":"aws","region":"us-east-1"}),
    )
    .await;
    tokio::time::sleep(std::time::Duration::from_millis(1)).await;
    let third = append_event(
        &event_repo,
        vm.id,
        VmLifecycleEventType::ReplacementRefused,
        json!({"guardrail":"kill_switch_disabled"}),
    )
    .await;

    let response = app
        .oneshot(admin_request(format!(
            "/admin/vms/{}/lifecycle-events",
            vm.id
        )))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response_json(response).await,
        json!([
            {
                "id": first.id,
                "vm_id": vm.id,
                "event_type": "detected_dead",
                "detail": {"detector":"host_status"},
                "created_at": first.created_at,
            },
            {
                "id": second.id,
                "vm_id": vm.id,
                "event_type": "replacement_provisioning",
                "detail": {"provider":"aws","region":"us-east-1"},
                "created_at": second.created_at,
            },
            {
                "id": third.id,
                "vm_id": vm.id,
                "event_type": "replacement_refused",
                "detail": {"guardrail":"kill_switch_disabled"},
                "created_at": third.created_at,
            },
        ])
    );
}

#[tokio::test]
async fn vm_lifecycle_events_repository_failure_returns_error_not_empty_trail() {
    let (app, vm_inventory_repo, event_repo) = mock_backed_admin_app();
    let vm = vm_inventory_repo.seed("us-east-1", "https://admin-lifecycle-failure.test");
    event_repo.set_should_fail(true);

    let response = app
        .oneshot(admin_request(format!(
            "/admin/vms/{}/lifecycle-events",
            vm.id
        )))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
    assert_ne!(response_json(response).await, json!([]));
}
