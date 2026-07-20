use api::provisioner::VmStatus;
use api::repos::vm_inventory_repo::VmInventoryRepo;
use axum::http::{Request, StatusCode};
use serde_json::json;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use tower::ServiceExt;

use crate::common::{mock_vm_inventory_repo, TestStateBuilder, TEST_ADMIN_KEY};

use super::response_json;

fn process_env_lock() -> MutexGuard<'static, ()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(())).lock().unwrap()
}

struct EnvVarGuard {
    key: &'static str,
    previous: Option<String>,
}

impl EnvVarGuard {
    fn set(key: &'static str, value: &str) -> Self {
        let previous = std::env::var(key).ok();
        unsafe { std::env::set_var(key, value) };
        Self { key, previous }
    }
}

impl Drop for EnvVarGuard {
    fn drop(&mut self) {
        match &self.previous {
            Some(value) => unsafe { std::env::set_var(self.key, value) },
            None => unsafe { std::env::remove_var(self.key) },
        }
    }
}

fn warm_floor_test_app(
    vm_inventory_repo: Arc<crate::common::MockVmInventoryRepo>,
    vm_provisioner: Arc<api::provisioner::mock::MockVmProvisioner>,
) -> axum::Router {
    vm_provisioner.set_create_status(VmStatus::Running);
    TestStateBuilder::new()
        .with_vm_inventory_repo(vm_inventory_repo)
        .with_provisioner(vm_provisioner)
        .build_app()
}

async fn post_warm_floor(
    app: axum::Router,
    body: serde_json::Value,
    admin_key: Option<&str>,
) -> axum::response::Response {
    post_warm_floor_raw(app, body.to_string(), admin_key).await
}

async fn post_warm_floor_raw(
    app: axum::Router,
    body: String,
    admin_key: Option<&str>,
) -> axum::response::Response {
    let mut builder = Request::builder()
        .method("POST")
        .uri("/admin/vms/shared/warm-floor")
        .header("content-type", "application/json");
    if let Some(admin_key) = admin_key {
        builder = builder.header("x-admin-key", admin_key);
    }
    app.oneshot(builder.body(axum::body::Body::from(body)).unwrap())
        .await
        .unwrap()
}

fn expected_created_vms_json(vms: &[api::models::vm_inventory::VmInventory]) -> serde_json::Value {
    serde_json::to_value(vms).expect("VM inventory rows should serialize")
}

#[tokio::test]
async fn warm_floor_creates_one_shared_aws_vm_from_zero() {
    let vm_inventory_repo = mock_vm_inventory_repo();
    let vm_provisioner = crate::common::mock_vm_provisioner();
    let app = warm_floor_test_app(vm_inventory_repo.clone(), vm_provisioner.clone());

    let response = post_warm_floor(
        app,
        json!({"region":"us-east-1","provider":"aws","desired_count":1}),
        Some(TEST_ADMIN_KEY),
    )
    .await;

    assert_eq!(response.status(), StatusCode::OK);
    let body = response_json(response).await;
    assert_eq!(body["before_count"], 0);
    assert_eq!(body["created_count"], 1);
    assert_eq!(body["active_count"], 1);
    assert_eq!(vm_provisioner.create_call_count(), 1);
    let active_rows = vm_inventory_repo
        .list_active(Some("us-east-1"))
        .await
        .unwrap();
    assert_eq!(active_rows.len(), 1);
    assert_eq!(body["created_vms"], expected_created_vms_json(&active_rows));
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn warm_floor_ignores_local_dev_bypass_and_returns_managed_shared_vm() {
    let _env_guard = process_env_lock();
    let _local_url = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", "http://localhost:7700");
    let vm_inventory_repo = mock_vm_inventory_repo();
    let vm_provisioner = crate::common::mock_vm_provisioner();
    let app = warm_floor_test_app(vm_inventory_repo.clone(), vm_provisioner.clone());

    let response = post_warm_floor(
        app,
        json!({"region":"us-east-1","provider":"aws","desired_count":1}),
        Some(TEST_ADMIN_KEY),
    )
    .await;

    assert_eq!(response.status(), StatusCode::OK);
    let body = response_json(response).await;
    assert_eq!(body["before_count"], 0);
    assert_eq!(body["created_count"], 1);
    assert_eq!(body["active_count"], 1);
    assert_eq!(vm_provisioner.create_call_count(), 1);

    let active_rows = vm_inventory_repo
        .list_active(Some("us-east-1"))
        .await
        .unwrap();
    assert_eq!(active_rows.len(), 1);
    assert_eq!(active_rows[0].provider, "aws");
    assert!(active_rows[0].hostname.starts_with("vm-shared-"));
    assert_eq!(body["created_vms"], expected_created_vms_json(&active_rows));
}

#[tokio::test]
async fn warm_floor_reuses_existing_canonical_shared_aws_vm_only() {
    let vm_inventory_repo = mock_vm_inventory_repo();
    vm_inventory_repo.seed("us-east-1", "https://vm-shared-existing.flapjack.foo");
    vm_inventory_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "us-east-1".into(),
            provider: "aws".into(),
            hostname: "manual-existing.flapjack.foo".into(),
            flapjack_url: "https://manual-existing.flapjack.foo".into(),
            capacity: json!({}),
        })
        .await
        .unwrap();
    let vm_provisioner = crate::common::mock_vm_provisioner();
    vm_provisioner.seed_vm_for_hostname(
        "vm-shared-existing.flapjack.foo",
        "mock-existing",
        VmStatus::Running,
        "us-east-1",
    );
    let app = warm_floor_test_app(vm_inventory_repo, vm_provisioner.clone());

    let response = post_warm_floor(
        app,
        json!({"region":"us-east-1","provider":"aws","desired_count":1}),
        Some(TEST_ADMIN_KEY),
    )
    .await;

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response_json(response).await,
        json!({
            "before_count": 1,
            "created_count": 0,
            "active_count": 1,
            "created_vms": []
        })
    );
    assert_eq!(vm_provisioner.create_call_count(), 0);
}

#[tokio::test]
async fn warm_floor_ignores_canonical_inventory_row_without_running_provider_match() {
    let vm_inventory_repo = mock_vm_inventory_repo();
    vm_inventory_repo.seed("us-east-1", "https://vm-shared-stale.flapjack.foo");
    let vm_provisioner = crate::common::mock_vm_provisioner();
    let app = warm_floor_test_app(vm_inventory_repo.clone(), vm_provisioner.clone());

    let response = post_warm_floor(
        app,
        json!({"region":"us-east-1","provider":"aws","desired_count":1}),
        Some(TEST_ADMIN_KEY),
    )
    .await;

    assert_eq!(response.status(), StatusCode::OK);
    let body = response_json(response).await;
    assert_eq!(body["before_count"], 0);
    assert_eq!(body["created_count"], 1);
    assert_eq!(body["active_count"], 1);
    assert_eq!(vm_provisioner.create_call_count(), 1);

    let created_vms = body["created_vms"].as_array().unwrap();
    assert_eq!(created_vms.len(), 1);
    assert_ne!(created_vms[0]["hostname"], "vm-shared-stale.flapjack.foo");
    assert_eq!(
        vm_inventory_repo
            .list_active(Some("us-east-1"))
            .await
            .unwrap()
            .len(),
        2,
        "the stale inventory row remains, but it must not satisfy the floor"
    );
}

#[tokio::test]
async fn warm_floor_ignores_canonical_shared_vm_from_different_dns_domain() {
    let vm_inventory_repo = mock_vm_inventory_repo();
    vm_inventory_repo.seed(
        "us-east-1",
        "http://vm-shared-staging.staging.flapjack.foo:7700",
    );
    let vm_provisioner = crate::common::mock_vm_provisioner();
    vm_provisioner.set_create_status(VmStatus::Running);
    let app = TestStateBuilder::new()
        .with_dns_domain("flapjack.foo")
        .with_vm_inventory_repo(vm_inventory_repo.clone())
        .with_provisioner(vm_provisioner.clone())
        .build_app();

    let response = post_warm_floor(
        app,
        json!({"region":"us-east-1","provider":"aws","desired_count":1}),
        Some(TEST_ADMIN_KEY),
    )
    .await;

    assert_eq!(response.status(), StatusCode::OK);
    let body = response_json(response).await;
    assert_eq!(body["before_count"], 0);
    assert_eq!(body["created_count"], 1);
    assert_eq!(body["active_count"], 1);
    assert_eq!(vm_provisioner.create_call_count(), 1);

    let active_prod_rows: Vec<_> = vm_inventory_repo
        .list_active(Some("us-east-1"))
        .await
        .unwrap()
        .into_iter()
        .filter(|vm| vm.provider == "aws" && vm.hostname.ends_with(".flapjack.foo"))
        .filter(|vm| !vm.hostname.ends_with(".staging.flapjack.foo"))
        .collect();
    assert_eq!(active_prod_rows.len(), 1);
    assert_eq!(
        body["created_vms"],
        expected_created_vms_json(&active_prod_rows)
    );
}

#[tokio::test]
async fn warm_floor_ignores_distractors_then_sequential_retry_reuses_created_vm() {
    let vm_inventory_repo = mock_vm_inventory_repo();
    vm_inventory_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "us-east-1".into(),
            provider: "hetzner".into(),
            hostname: "vm-shared-hetzner.flapjack.foo".into(),
            flapjack_url: "https://vm-shared-hetzner.flapjack.foo".into(),
            capacity: json!({}),
        })
        .await
        .unwrap();
    vm_inventory_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "us-west-2".into(),
            provider: "aws".into(),
            hostname: "vm-shared-west.flapjack.foo".into(),
            flapjack_url: "https://vm-shared-west.flapjack.foo".into(),
            capacity: json!({}),
        })
        .await
        .unwrap();
    vm_inventory_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "us-east-1".into(),
            provider: "aws".into(),
            hostname: "manual-existing.flapjack.foo".into(),
            flapjack_url: "https://manual-existing.flapjack.foo".into(),
            capacity: json!({}),
        })
        .await
        .unwrap();
    let vm_provisioner = crate::common::mock_vm_provisioner();
    let first = post_warm_floor(
        warm_floor_test_app(vm_inventory_repo.clone(), vm_provisioner.clone()),
        json!({"region":"us-east-1","provider":"aws","desired_count":1}),
        Some(TEST_ADMIN_KEY),
    )
    .await;

    assert_eq!(first.status(), StatusCode::OK);
    let first_body = response_json(first).await;
    assert_eq!(first_body["before_count"], 0);
    assert_eq!(first_body["created_count"], 1);
    assert_eq!(first_body["active_count"], 1);
    assert_eq!(first_body["created_vms"].as_array().unwrap().len(), 1);
    assert_eq!(first_body["created_vms"][0]["status"], "active");
    assert_eq!(
        first_body["created_vms"][0]["flapjack_url"],
        format!(
            "http://{}:7700",
            first_body["created_vms"][0]["hostname"].as_str().unwrap()
        )
    );
    assert_eq!(vm_provisioner.create_call_count(), 1);

    let retry = post_warm_floor(
        warm_floor_test_app(vm_inventory_repo.clone(), vm_provisioner.clone()),
        json!({"region":"us-east-1","provider":"aws","desired_count":1}),
        Some(TEST_ADMIN_KEY),
    )
    .await;

    assert_eq!(retry.status(), StatusCode::OK);
    assert_eq!(
        response_json(retry).await,
        json!({
            "before_count": 1,
            "created_count": 0,
            "active_count": 1,
            "created_vms": []
        })
    );
    assert_eq!(vm_provisioner.create_call_count(), 1);
    let canonical_shared_rows = vm_inventory_repo
        .list_active(Some("us-east-1"))
        .await
        .unwrap()
        .into_iter()
        .filter(|vm| vm.provider == "aws" && vm.hostname.starts_with("vm-shared-"))
        .count();
    assert_eq!(canonical_shared_rows, 1);
}

#[tokio::test]
async fn warm_floor_concurrent_retry_at_one_does_not_call_provisioning() {
    let vm_inventory_repo = mock_vm_inventory_repo();
    vm_inventory_repo.seed("us-east-1", "https://vm-shared-existing.flapjack.foo");
    let vm_provisioner = crate::common::mock_vm_provisioner();
    vm_provisioner.seed_vm_for_hostname(
        "vm-shared-existing.flapjack.foo",
        "mock-existing",
        VmStatus::Running,
        "us-east-1",
    );
    let app = warm_floor_test_app(vm_inventory_repo.clone(), vm_provisioner.clone());
    let request = json!({"region":"us-east-1","provider":"aws","desired_count":1});

    let (left, right) = tokio::join!(
        post_warm_floor(app.clone(), request.clone(), Some(TEST_ADMIN_KEY)),
        post_warm_floor(app, request, Some(TEST_ADMIN_KEY))
    );

    assert_eq!(left.status(), StatusCode::OK);
    assert_eq!(right.status(), StatusCode::OK);
    assert_eq!(vm_provisioner.create_call_count(), 0);
    let active_rows = vm_inventory_repo
        .list_active(Some("us-east-1"))
        .await
        .unwrap();
    assert_eq!(active_rows.len(), 1);
}

#[tokio::test]
async fn warm_floor_rejects_invalid_requests_before_provisioning() {
    let invalid_cases = [
        (
            None,
            json!({"region":"us-east-1","provider":"aws","desired_count":1}),
            StatusCode::UNAUTHORIZED,
        ),
        (
            Some(TEST_ADMIN_KEY),
            json!({"region":"us-east-1","provider":"aws","desired_count":1,"extra":true}),
            StatusCode::UNPROCESSABLE_ENTITY,
        ),
        (
            Some(TEST_ADMIN_KEY),
            json!({"region":"us-east-1","provider":"hetzner","desired_count":1}),
            StatusCode::BAD_REQUEST,
        ),
        (
            Some(TEST_ADMIN_KEY),
            json!({"region":"eu-west-1","provider":"aws","desired_count":1}),
            StatusCode::BAD_REQUEST,
        ),
        (
            Some(TEST_ADMIN_KEY),
            json!({"region":"unknown-region","provider":"aws","desired_count":1}),
            StatusCode::BAD_REQUEST,
        ),
        (
            Some(TEST_ADMIN_KEY),
            json!({"region":"us-east-1","provider":"aws","desired_count":0}),
            StatusCode::BAD_REQUEST,
        ),
        (
            Some(TEST_ADMIN_KEY),
            json!({"region":"us-east-1","provider":"aws","desired_count":2}),
            StatusCode::BAD_REQUEST,
        ),
    ];

    for (admin_key, body, expected_status) in invalid_cases {
        let vm_inventory_repo = mock_vm_inventory_repo();
        let vm_provisioner = crate::common::mock_vm_provisioner();
        let response = post_warm_floor(
            warm_floor_test_app(vm_inventory_repo, vm_provisioner.clone()),
            body,
            admin_key,
        )
        .await;
        assert_eq!(response.status(), expected_status);
        assert_eq!(vm_provisioner.create_call_count(), 0);
    }

    let vm_provisioner = crate::common::mock_vm_provisioner();
    let malformed = post_warm_floor_raw(
        warm_floor_test_app(mock_vm_inventory_repo(), vm_provisioner.clone()),
        "{".to_string(),
        Some(TEST_ADMIN_KEY),
    )
    .await;
    assert_eq!(malformed.status(), StatusCode::BAD_REQUEST);
    assert_eq!(vm_provisioner.create_call_count(), 0);
}

#[tokio::test]
async fn warm_floor_returns_service_unavailable_without_persisting_on_provision_failure() {
    let vm_inventory_repo = mock_vm_inventory_repo();
    let vm_provisioner = crate::common::mock_vm_provisioner();
    vm_provisioner.set_should_fail(true);
    let app = warm_floor_test_app(vm_inventory_repo.clone(), vm_provisioner.clone());

    let response = post_warm_floor(
        app,
        json!({"region":"us-east-1","provider":"aws","desired_count":1}),
        Some(TEST_ADMIN_KEY),
    )
    .await;

    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(vm_provisioner.create_call_count(), 1);
    assert!(vm_inventory_repo
        .list_active(Some("us-east-1"))
        .await
        .unwrap()
        .is_empty());
}
