use std::sync::Arc;

use api::provisioner::VmStatus;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{Duration, Utc};
use serde_json::{json, Value};
use tower::ServiceExt;

use crate::common::{MockVmInventoryRepo, TestStateBuilder, TEST_ADMIN_KEY};

async fn response_json(response: axum::response::Response) -> Value {
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("read response body");
    serde_json::from_slice(&body).expect("response is JSON")
}

fn request(method: &str, path: &str, authenticated: bool, body: Body) -> Request<Body> {
    let mut builder = Request::builder()
        .method(method)
        .uri(path)
        .header("content-type", "application/json");
    if authenticated {
        builder = builder.header("x-admin-key", TEST_ADMIN_KEY);
    }
    builder.body(body).expect("build request")
}

#[tokio::test]
async fn orphan_report_route_requires_admin_auth() {
    let response = TestStateBuilder::new()
        .build_app()
        .oneshot(request("GET", "/admin/vms/orphans", false, Body::empty()))
        .await
        .expect("route response");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn orphan_report_route_returns_source_denominators_without_mutation() {
    let inventory = Arc::new(MockVmInventoryRepo::new());
    let vm = inventory.seed("us-east-1", "https://vm-shared-live.flapjack.foo");
    let dns = Arc::new(api::dns::mock::MockDnsManager::new());
    dns.seed_a_record_at(
        &vm.hostname,
        "203.0.113.21",
        Utc::now() - Duration::hours(2),
    );
    let secrets = Arc::new(api::secrets::mock::MockNodeSecretManager::new());
    secrets.seed_listed_key_at(&vm.hostname, false, Utc::now() - Duration::hours(2));
    secrets.seed_listed_key_at(&vm.hostname, true, Utc::now() - Duration::hours(2));
    let provisioner = Arc::new(api::provisioner::mock::MockVmProvisioner::new());
    provisioner.seed_vm_for_hostname(&vm.hostname, "i-live", VmStatus::Stopped, "us-east-1");
    let app = TestStateBuilder::new()
        .with_vm_inventory_repo(inventory.clone())
        .with_dns_manager(dns.clone())
        .with_node_secret_manager(secrets.clone())
        .with_provisioner(provisioner.clone())
        .build_app();

    let response = app
        .oneshot(request("GET", "/admin/vms/orphans", true, Body::empty()))
        .await
        .expect("route response");

    assert_eq!(response.status(), StatusCode::OK);
    let body = response_json(response).await;
    assert_eq!(body["status"], "clean");
    assert_eq!(body["sources"]["dns"]["records_scanned"], 1);
    assert_eq!(body["sources"]["ssm"]["keys_scanned"], 2);
    assert_eq!(body["sources"]["inventory"]["inventory_scanned"], 1);
    assert_eq!(body["sources"]["instances"]["instances_found"], 1);
    assert_eq!(body["orphans_found"], 0);
    assert_eq!(body["non_orphans"][0]["hostname"], vm.hostname);
    assert_eq!(inventory.status_mutation_call_count(), 0);
    assert_eq!(dns.delete_call_count(), 0);
    assert_eq!(secrets.delete_call_count(), 0);
    assert_eq!(provisioner.destroy_call_count(), 0);
}

#[tokio::test]
async fn orphan_report_route_returns_indeterminate_report_on_source_failure() {
    let dns = Arc::new(api::dns::mock::MockDnsManager::new());
    dns.set_should_fail(true);
    let app = TestStateBuilder::new().with_dns_manager(dns).build_app();

    let response = app
        .oneshot(request("GET", "/admin/vms/orphans", true, Body::empty()))
        .await
        .expect("route response");

    assert_eq!(response.status(), StatusCode::OK);
    let body = response_json(response).await;
    assert_eq!(body["status"], "indeterminate");
    assert_eq!(body["sources"]["dns"]["status"], "error");
    assert_eq!(body["sources"]["dns"]["enumeration_incomplete"], true);
}

#[tokio::test]
async fn orphan_report_route_preserves_vm_detail_and_warm_floor_routes() {
    let inventory = Arc::new(MockVmInventoryRepo::new());
    let vm = inventory.seed("us-east-1", "https://vm-shared-existing.flapjack.foo");
    let provisioner = Arc::new(api::provisioner::mock::MockVmProvisioner::new());
    provisioner.seed_vm_for_hostname(&vm.hostname, "i-existing", VmStatus::Running, "us-east-1");
    let app = TestStateBuilder::new()
        .with_vm_inventory_repo(inventory)
        .with_provisioner(provisioner)
        .build_app();

    let detail = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/admin/vms/{}", vm.id),
            true,
            Body::empty(),
        ))
        .await
        .expect("detail route response");
    assert_eq!(detail.status(), StatusCode::OK);

    let warm_floor = app
        .oneshot(request(
            "POST",
            "/admin/vms/shared/warm-floor",
            true,
            Body::from(
                json!({"region":"us-east-1","provider":"aws","desired_count":1}).to_string(),
            ),
        ))
        .await
        .expect("warm-floor route response");
    assert_eq!(warm_floor.status(), StatusCode::OK);
}
