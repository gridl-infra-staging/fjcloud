use api::dns::DnsManager;
use api::repos::tenant_repo::TenantRepo;
use api::repos::vm_inventory_repo::VmInventoryRepo;
use api::repos::DeploymentRepo;
use api::secrets::NodeSecretManager;
use axum::http::{Request, StatusCode};
use serde_json::json;
use serde_json::Value;
use std::sync::Arc;
use tower::ServiceExt;
use uuid::Uuid;

use crate::common::support::pg_schema_harness::connect_and_migrate;
use crate::common::vm_inventory_reference_guard_fixtures::{
    insert_all_live_vm_references, insert_customer, insert_deployment, insert_tenant, insert_vm,
};
use crate::common::{
    admin_vm_retirement_test_support::{
        admin_vm_pg_test_app, admin_vm_pg_test_app_with_state_mocks,
        assert_admin_route_inventory_lock_wins_publication,
        assert_admin_route_reference_publication_wins, expected_live_blockers_json,
        insert_terminal_reference_modes, inventory_status, AdminVmPgTestAppWithStateMocks,
    },
    mock_flapjack_proxy_with_secrets, mock_vm_inventory_repo, MockCustomerRepo, MockDeploymentRepo,
    TEST_ADMIN_KEY,
};

#[path = "admin_vms_warm_floor_test.rs"]
mod admin_vms_warm_floor_test;

async fn response_json(response: axum::response::Response) -> serde_json::Value {
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&body).unwrap()
}

fn admin_vm_test_app(vm_inventory_repo: Arc<crate::common::MockVmInventoryRepo>) -> axum::Router {
    crate::common::test_app_with_indexes_and_vm_inventory(
        Arc::new(MockCustomerRepo::new()),
        Arc::new(MockDeploymentRepo::new()),
        crate::common::mock_tenant_repo(),
        mock_flapjack_proxy_with_secrets(
            Arc::new(api::secrets::mock::MockNodeSecretManager::new()),
        ),
        vm_inventory_repo,
    )
}

async fn create_vm_fixture(
    vm_inventory_repo: &crate::common::MockVmInventoryRepo,
    region: &str,
    hostname: &str,
    capacity: Value,
) -> api::models::vm_inventory::VmInventory {
    vm_inventory_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: region.into(),
            provider: "aws".into(),
            hostname: hostname.into(),
            flapjack_url: format!("https://{hostname}"),
            capacity,
        })
        .await
        .unwrap()
}

async fn create_deployment_with_health(
    deployment_repo: &MockDeploymentRepo,
    customer_id: Uuid,
    node_id: &str,
    health_status: &str,
) -> Uuid {
    let deployment = deployment_repo
        .create(customer_id, node_id, "us-east-1", "t4g.medium", "aws", None)
        .await
        .unwrap();
    deployment_repo
        .update_health(deployment.id, health_status, chrono::Utc::now())
        .await
        .unwrap();
    deployment.id
}

async fn assign_tenant_to_vm(
    tenant_repo: &crate::common::MockTenantRepo,
    vm_id: Uuid,
    tenant: (Uuid, &str, Uuid),
) {
    let (customer_id, tenant_id, deployment_id) = tenant;
    tenant_repo
        .create(customer_id, tenant_id, deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, tenant_id, vm_id)
        .await
        .unwrap();
}

fn vm_entry<'a>(entries: &'a [Value], vm_id: Uuid, label: &str) -> &'a Value {
    entries
        .iter()
        .find(|entry| entry["id"] == json!(vm_id))
        .unwrap_or_else(|| panic!("{label} is present in /admin/vms response"))
}

fn removed_teardown_json() -> Value {
    json!({
        "instance": {"status": "removed", "clean": true},
        "dns_record": {"status": "removed", "clean": true},
        "node_api_key": {"status": "removed", "clean": true}
    })
}

fn no_instance_teardown_json() -> Value {
    json!({
        "instance": {"status": "not_applicable", "clean": true},
        "dns_record": {"status": "removed", "clean": true},
        "node_api_key": {"status": "removed", "clean": true}
    })
}

fn skipped_after_indeterminate_instance_json() -> Value {
    json!({
        "instance": {
            "status": "indeterminate",
            "clean": false,
            "message": "VM provisioner API error: injected failure"
        },
        "dns_record": {
            "status": "skipped",
            "clean": false,
            "reason": "instance_teardown_failed"
        },
        "node_api_key": {
            "status": "skipped",
            "clean": false,
            "reason": "instance_teardown_failed"
        }
    })
}

async fn seed_retirement_resources(
    mocks: &AdminVmPgTestAppWithStateMocks,
    hostname: &str,
    provider_vm_id: &str,
) {
    mocks.vm_provisioner.seed_vm_for_hostname(
        hostname,
        provider_vm_id,
        api::provisioner::VmStatus::Running,
        "us-east-1",
    );
    mocks
        .dns_manager
        .create_record(hostname, "203.0.113.10")
        .await
        .expect("seed DNS record");
    mocks
        .node_secret_manager
        .create_node_api_key(hostname, "us-east-1")
        .await
        .expect("seed node key");
    mocks
        .node_secret_manager
        .rotate_node_api_key(hostname, "us-east-1")
        .await
        .expect("seed previous node key");
}

async fn seed_fleet_provider_id(
    mocks: &AdminVmPgTestAppWithStateMocks,
    hostname: &str,
    provider_vm_id: &str,
) {
    let customer_id = Uuid::new_v4();
    let deployment = mocks
        .deployment_repo
        .create(customer_id, hostname, "us-east-1", "t4g.small", "aws", None)
        .await
        .expect("seed fleet deployment");
    mocks
        .deployment_repo
        .update_provisioning(
            deployment.id,
            provider_vm_id,
            "203.0.113.10",
            hostname,
            &format!("https://{hostname}.test"),
        )
        .await
        .expect("seed fleet provider id");
}

async fn post_decommission(
    app: axum::Router,
    vm_id: Uuid,
    expected_hostname: &str,
) -> axum::response::Response {
    app.oneshot(
        Request::builder()
            .method("POST")
            .uri(format!("/admin/vms/{vm_id}/decommission"))
            .header("x-admin-key", TEST_ADMIN_KEY)
            .header("content-type", "application/json")
            .body(axum::body::Body::from(
                json!({"expected_hostname": expected_hostname}).to_string(),
            ))
            .unwrap(),
    )
    .await
    .unwrap()
}

#[tokio::test]
async fn get_admin_vms_returns_counts_and_health_contract() {
    let customer_a = Uuid::new_v4();
    let customer_b = Uuid::new_v4();

    let vm_inventory_repo = mock_vm_inventory_repo();
    let vm_a = create_vm_fixture(
        &vm_inventory_repo,
        "us-east-1",
        "vm-a.flapjack.foo",
        json!({"cpu_cores": 8, "ram_mb": 16384, "disk_gb": 200}),
    )
    .await;
    let vm_b = create_vm_fixture(
        &vm_inventory_repo,
        "us-west-2",
        "vm-b.flapjack.foo",
        json!({"cpu_cores": 4, "ram_mb": 8192, "disk_gb": 100}),
    )
    .await;
    let tenant_repo = crate::common::mock_tenant_repo();
    let deployment_repo = MockDeploymentRepo::new();
    let dep_a_1 =
        create_deployment_with_health(&deployment_repo, customer_a, "vm-a-node-1", "healthy").await;
    let dep_a_2 =
        create_deployment_with_health(&deployment_repo, customer_a, "vm-a-node-2", "unhealthy")
            .await;
    let dep_b_1 =
        create_deployment_with_health(&deployment_repo, customer_b, "vm-a-node-3", "healthy").await;

    for (customer_id, tenant_id, deployment_id) in [
        (customer_a, "products", dep_a_1),
        (customer_a, "orders", dep_a_2),
        (customer_b, "reports", dep_b_1),
    ] {
        assign_tenant_to_vm(
            &tenant_repo,
            vm_a.id,
            (customer_id, tenant_id, deployment_id),
        )
        .await;
    }

    let app = crate::common::test_app_with_indexes_and_vm_inventory(
        Arc::new(MockCustomerRepo::new()),
        Arc::new(deployment_repo),
        tenant_repo,
        mock_flapjack_proxy_with_secrets(
            Arc::new(api::secrets::mock::MockNodeSecretManager::new()),
        ),
        vm_inventory_repo,
    );

    let response = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/admin/vms")
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let json = response_json(response).await;
    let entries = json.as_array().expect("GET /admin/vms returns an array");
    let vm_a_json = vm_entry(entries, vm_a.id, "VM-A");
    let vm_b_json = vm_entry(entries, vm_b.id, "VM-B");

    assert_eq!(vm_a_json["hostname"], "vm-a.flapjack.foo");
    assert_eq!(vm_a_json["region"], "us-east-1");
    assert_eq!(vm_a_json["provider"], "aws");
    assert_eq!(vm_a_json["status"], "active");
    assert_eq!(vm_a_json["capacity"]["cpu_cores"], 8);
    assert_eq!(vm_a_json["tenant_count"], 2);
    assert_eq!(vm_a_json["index_count"], 3);
    assert_eq!(vm_a_json["health"], "unhealthy");

    assert_eq!(vm_b_json["tenant_count"], 0);
    assert_eq!(vm_b_json["index_count"], 0);
    assert_eq!(vm_b_json["health"], "unknown");
}

#[tokio::test]
async fn get_vm_detail_returns_vm_with_tenant_breakdown() {
    let customer_id = Uuid::new_v4();

    let vm_inventory_repo = mock_vm_inventory_repo();
    let vm = vm_inventory_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "us-east-1".into(),
            provider: "aws".into(),
            hostname: "vm-test.flapjack.foo".into(),
            flapjack_url: "https://vm-test.flapjack.foo".into(),
            capacity: json!({"cpu_cores": 4, "ram_mb": 8192, "disk_gb": 100}),
        })
        .await
        .unwrap();

    let tenant_repo = crate::common::mock_tenant_repo();
    let deployment_repo = MockDeploymentRepo::new();
    let dep = deployment_repo
        .create(
            customer_id,
            "node-1",
            "us-east-1",
            "t4g.medium",
            "aws",
            None,
        )
        .await
        .unwrap();
    deployment_repo
        .update_provisioning(
            dep.id,
            "aws:i-test1234567890",
            "203.0.113.10",
            "vm-test.flapjack.foo",
            "https://vm-test.flapjack.foo",
        )
        .await
        .unwrap();

    tenant_repo
        .create(customer_id, "products", dep.id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "products", vm.id)
        .await
        .unwrap();

    let proxy = mock_flapjack_proxy_with_secrets(std::sync::Arc::new(
        api::secrets::mock::MockNodeSecretManager::new(),
    ));

    let app = crate::common::test_app_with_indexes_and_vm_inventory(
        std::sync::Arc::new(MockCustomerRepo::new()),
        std::sync::Arc::new(deployment_repo),
        tenant_repo,
        proxy,
        vm_inventory_repo,
    );

    let response = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/admin/vms/{}", vm.id))
                .header("X-Admin-Key", TEST_ADMIN_KEY)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();

    assert_eq!(json["vm"]["hostname"], "vm-test.flapjack.foo");
    assert_eq!(json["vm"]["region"], "us-east-1");
    assert_eq!(json["vm"]["status"], "active");
    assert_eq!(json["vm"]["provider_vm_id"], "i-test1234567890");
    assert_eq!(json["tenants"][0]["tenant_id"], "products");
}

#[tokio::test]
async fn get_vm_detail_returns_404_for_unknown_vm() {
    let app = crate::common::test_app();

    let unknown_id = Uuid::new_v4();
    let response = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/admin/vms/{}", unknown_id))
                .header("X-Admin-Key", TEST_ADMIN_KEY)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn get_vm_detail_ignores_stale_deployment_provider_vm_id() {
    let customer_id = Uuid::new_v4();

    let vm_inventory_repo = mock_vm_inventory_repo();
    let vm = vm_inventory_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "us-east-1".into(),
            provider: "aws".into(),
            hostname: "vm-test.flapjack.foo".into(),
            flapjack_url: "https://vm-test.flapjack.foo".into(),
            capacity: json!({"cpu_cores": 4, "ram_mb": 8192, "disk_gb": 100}),
        })
        .await
        .unwrap();

    let tenant_repo = crate::common::mock_tenant_repo();
    let deployment_repo = MockDeploymentRepo::new();

    let active_dep = deployment_repo
        .create(
            customer_id,
            "node-good",
            "us-east-1",
            "t4g.medium",
            "aws",
            None,
        )
        .await
        .unwrap();
    deployment_repo
        .update_provisioning(
            active_dep.id,
            "aws:i-good123",
            "203.0.113.10",
            "vm-test.flapjack.foo",
            "https://vm-test.flapjack.foo",
        )
        .await
        .unwrap();

    let stale_dep = deployment_repo
        .create(
            customer_id,
            "node-stale",
            "us-east-1",
            "t4g.medium",
            "aws",
            None,
        )
        .await
        .unwrap();
    deployment_repo
        .update_provisioning(
            stale_dep.id,
            "aws:i-aaa-stale",
            "203.0.113.11",
            "vm-old.flapjack.foo",
            "https://vm-old.flapjack.foo",
        )
        .await
        .unwrap();

    tenant_repo
        .create(customer_id, "products", active_dep.id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "products", vm.id)
        .await
        .unwrap();
    tenant_repo
        .create(customer_id, "orders", stale_dep.id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "orders", vm.id)
        .await
        .unwrap();

    let proxy = mock_flapjack_proxy_with_secrets(std::sync::Arc::new(
        api::secrets::mock::MockNodeSecretManager::new(),
    ));

    let app = crate::common::test_app_with_indexes_and_vm_inventory(
        std::sync::Arc::new(MockCustomerRepo::new()),
        std::sync::Arc::new(deployment_repo),
        tenant_repo,
        proxy,
        vm_inventory_repo,
    );

    let response = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/admin/vms/{}", vm.id))
                .header("X-Admin-Key", TEST_ADMIN_KEY)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(json["vm"]["provider_vm_id"], "i-good123");
}

#[tokio::test]
async fn retirement_blockers_reports_eligible_active_vm() {
    let vm_inventory_repo = mock_vm_inventory_repo();
    let vm = vm_inventory_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "us-east-1".into(),
            provider: "aws".into(),
            hostname: "vm-retire.flapjack.foo".into(),
            flapjack_url: "https://vm-retire.flapjack.foo".into(),
            capacity: json!({"cpu_cores": 4, "ram_mb": 8192, "disk_gb": 100}),
        })
        .await
        .unwrap();
    let app = admin_vm_test_app(vm_inventory_repo);

    let response = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!(
                    "/admin/vms/{}/retirement-blockers?expected_hostname={}",
                    vm.id, vm.hostname
                ))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response_json(response).await,
        json!({
            "vm_id": vm.id,
            "hostname": "vm-retire.flapjack.foo",
            "status": "active",
            "result": "eligible",
            "blockers": [],
            "blocking_reference_count": 0
        })
    );
}

#[tokio::test]
async fn decommission_transitions_eligible_vm_through_atomic_repo_owner() {
    let vm_inventory_repo = mock_vm_inventory_repo();
    let vm = vm_inventory_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "us-east-1".into(),
            provider: "aws".into(),
            hostname: "vm-decommission.flapjack.foo".into(),
            flapjack_url: "https://vm-decommission.flapjack.foo".into(),
            capacity: json!({"cpu_cores": 4, "ram_mb": 8192, "disk_gb": 100}),
        })
        .await
        .unwrap();
    let app = admin_vm_test_app(vm_inventory_repo.clone());

    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/admin/vms/{}/decommission", vm.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(axum::body::Body::from(
                    json!({"expected_hostname": "vm-decommission.flapjack.foo"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response_json(response).await,
        json!({
            "vm_id": vm.id,
            "hostname": "vm-decommission.flapjack.foo",
            "status": "decommissioned",
            "result": "decommissioned",
            "blockers": [],
            "blocking_reference_count": 0,
            "teardown": no_instance_teardown_json()
        })
    );
    assert_eq!(
        vm_inventory_repo.get(vm.id).await.unwrap().unwrap().status,
        "decommissioned"
    );
}

#[tokio::test]
async fn retirement_operations_require_admin_auth() {
    let vm_inventory_repo = mock_vm_inventory_repo();
    let vm = vm_inventory_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "us-east-1".into(),
            provider: "aws".into(),
            hostname: "vm-auth.flapjack.foo".into(),
            flapjack_url: "https://vm-auth.flapjack.foo".into(),
            capacity: json!({}),
        })
        .await
        .unwrap();

    let get_without_auth = admin_vm_test_app(vm_inventory_repo.clone())
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!(
                    "/admin/vms/{}/retirement-blockers?expected_hostname={}",
                    vm.id, vm.hostname
                ))
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(get_without_auth.status(), StatusCode::UNAUTHORIZED);

    let post_with_invalid_auth = admin_vm_test_app(vm_inventory_repo)
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/admin/vms/{}/decommission", vm.id))
                .header("x-admin-key", "wrong")
                .header("content-type", "application/json")
                .body(axum::body::Body::from(
                    json!({"expected_hostname": "vm-auth.flapjack.foo"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(post_with_invalid_auth.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn retirement_blockers_endpoint_reports_postgres_reference_owners() {
    let Some(db) = connect_and_migrate("admin_vm_retirement_blockers").await else {
        return;
    };
    let vm_id = insert_vm(&db.pool, "admin-blocked-vm", "active").await;
    let other_vm_id = insert_vm(&db.pool, "admin-blocked-peer", "active").await;
    insert_all_live_vm_references(&db.pool, vm_id, other_vm_id, "admin_blockers").await;
    insert_terminal_reference_modes(&db.pool, vm_id, other_vm_id, "admin_terminal").await;

    let response = admin_vm_pg_test_app(db.pool.clone())
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!(
                    "/admin/vms/{vm_id}/retirement-blockers?expected_hostname=admin-blocked-vm"
                ))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response_json(response).await,
        json!({
            "vm_id": vm_id,
            "hostname": "admin-blocked-vm",
            "status": "active",
            "result": "blocked",
            "blockers": expected_live_blockers_json(),
            "blocking_reference_count": 8
        })
    );
}

#[tokio::test]
async fn retirement_blockers_endpoint_maps_postgres_conflicts() {
    let Some(db) = connect_and_migrate("admin_vm_retirement_conflicts").await else {
        return;
    };
    let unknown_vm_id = Uuid::new_v4();
    let mismatch_vm_id = insert_vm(&db.pool, "admin-mismatch-vm", "active").await;
    let draining_vm_id = insert_vm(&db.pool, "admin-draining-vm", "draining").await;
    let app = admin_vm_pg_test_app(db.pool.clone());

    let unknown = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!(
                    "/admin/vms/{unknown_vm_id}/retirement-blockers?expected_hostname=unknown-vm"
                ))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(unknown.status(), StatusCode::NOT_FOUND);
    assert_eq!(
        response_json(unknown).await,
        json!({"error": format!("VM not found: {unknown_vm_id}")})
    );

    let mismatch = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!(
                    "/admin/vms/{mismatch_vm_id}/retirement-blockers?expected_hostname=wrong-hostname"
                ))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(mismatch.status(), StatusCode::CONFLICT);
    assert_eq!(
        response_json(mismatch).await,
        json!({"error": "hostname mismatch: expected wrong-hostname, found admin-mismatch-vm"})
    );

    let non_active = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!(
                    "/admin/vms/{draining_vm_id}/retirement-blockers?expected_hostname=admin-draining-vm"
                ))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(non_active.status(), StatusCode::CONFLICT);
    assert_eq!(
        response_json(non_active).await,
        json!({"error": "VM status does not allow retirement: draining"})
    );
}

#[tokio::test]
async fn decommission_endpoint_handles_postgres_success_and_idempotency() {
    let Some(db) = connect_and_migrate("admin_vm_decommission_success").await else {
        return;
    };
    let vm_id = insert_vm(&db.pool, "admin-retire-once", "active").await;
    let mocks = admin_vm_pg_test_app_with_state_mocks(db.pool.clone());
    seed_retirement_resources(&mocks, "admin-retire-once", "mock-admin-retire-once").await;
    seed_fleet_provider_id(&mocks, "admin-retire-once", "mock-admin-retire-once").await;

    let first = post_decommission(mocks.app.clone(), vm_id, "admin-retire-once").await;
    assert_eq!(first.status(), StatusCode::OK);
    assert_eq!(
        response_json(first).await,
        json!({
            "vm_id": vm_id,
            "hostname": "admin-retire-once",
            "status": "decommissioned",
            "result": "decommissioned",
            "blockers": [],
            "blocking_reference_count": 0,
            "teardown": removed_teardown_json()
        })
    );
    assert_eq!(inventory_status(&db.pool, vm_id).await, "decommissioned");
    assert_eq!(mocks.vm_provisioner.vm_count(), 0);
    assert!(
        mocks.dns_manager.get_records().is_empty(),
        "DNS record must be removed after successful retirement"
    );
    assert!(
        mocks
            .node_secret_manager
            .get_secret("admin-retire-once")
            .is_none(),
        "current node key must be removed after successful retirement"
    );
    assert!(
        mocks
            .node_secret_manager
            .get_previous_secret("admin-retire-once")
            .is_none(),
        "previous node key must be removed after successful retirement"
    );

    let retry = post_decommission(mocks.app, vm_id, "admin-retire-once").await;
    assert_eq!(retry.status(), StatusCode::OK);
    assert_eq!(
        response_json(retry).await,
        json!({
            "vm_id": vm_id,
            "hostname": "admin-retire-once",
            "status": "decommissioned",
            "result": "already_decommissioned",
            "blockers": [],
            "blocking_reference_count": 0,
            "teardown": removed_teardown_json()
        })
    );
}

#[tokio::test]
async fn decommission_endpoint_reports_indeterminate_provider_lookup_and_preserves_later_resources()
{
    let Some(db) = connect_and_migrate("admin_vm_decommission_unresolved_provider").await else {
        return;
    };
    let hostname = "admin-retire-provider-lookup";
    let vm_id = insert_vm(&db.pool, hostname, "active").await;
    let mocks = admin_vm_pg_test_app_with_state_mocks(db.pool.clone());
    seed_retirement_resources(&mocks, hostname, "mock-provider-lookup").await;
    mocks.vm_provisioner.set_should_fail(true);

    let response = post_decommission(mocks.app, vm_id, hostname).await;

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response_json(response).await,
        json!({
            "vm_id": vm_id,
            "hostname": hostname,
            "status": "decommissioned",
            "result": "decommissioned",
            "blockers": [],
            "blocking_reference_count": 0,
            "teardown": skipped_after_indeterminate_instance_json()
        })
    );
    assert_eq!(inventory_status(&db.pool, vm_id).await, "decommissioned");
    assert_eq!(mocks.vm_provisioner.vm_count(), 1);
    assert_eq!(
        mocks.dns_manager.get_records().get(hostname),
        Some(&"203.0.113.10".to_string())
    );
    assert!(
        mocks.node_secret_manager.get_secret(hostname).is_some(),
        "current node key must remain after indeterminate provider lookup"
    );
    assert!(
        mocks
            .node_secret_manager
            .get_previous_secret(hostname)
            .is_some(),
        "previous node key must remain after indeterminate provider lookup"
    );
}

#[tokio::test]
async fn decommission_endpoint_rejects_blocked_and_mismatched_postgres_rows() {
    let Some(db) = connect_and_migrate("admin_vm_decommission_reject").await else {
        return;
    };
    let blocked_vm_id = insert_vm(&db.pool, "admin-blocked-retire", "active").await;
    let customer_id = insert_customer(&db.pool, "admin_decommission_reject").await;
    let deployment_id =
        insert_deployment(&db.pool, customer_id, "admin-decommission-reject-node").await;
    insert_tenant(
        &db.pool,
        customer_id,
        deployment_id,
        "admin_decommission_reject_tenant",
        blocked_vm_id,
    )
    .await
    .expect("insert blocking tenant");
    let decommissioned_vm_id = insert_vm(&db.pool, "admin-retired-mismatch", "active").await;
    let mocks = admin_vm_pg_test_app_with_state_mocks(db.pool.clone());
    seed_retirement_resources(&mocks, "admin-blocked-retire", "mock-blocked-retire").await;

    let blocked = post_decommission(mocks.app.clone(), blocked_vm_id, "admin-blocked-retire").await;
    assert_eq!(blocked.status(), StatusCode::CONFLICT);
    let blocked_json = response_json(blocked).await;
    assert_eq!(
        blocked_json,
        json!({
            "vm_id": blocked_vm_id,
            "hostname": "admin-blocked-retire",
            "status": "active",
            "result": "blocked",
            "blockers": [{
                "owner": "customer_tenants",
                "reference_column": "vm_id",
                "count": 1
            }],
            "blocking_reference_count": 1
        })
    );
    assert!(blocked_json.get("teardown").is_none());
    assert_eq!(inventory_status(&db.pool, blocked_vm_id).await, "active");
    assert_eq!(mocks.vm_provisioner.vm_count(), 1);
    assert_eq!(
        mocks.dns_manager.get_records().get("admin-blocked-retire"),
        Some(&"203.0.113.10".to_string())
    );
    assert!(mocks
        .node_secret_manager
        .get_secret("admin-blocked-retire")
        .is_some());
    assert!(mocks
        .node_secret_manager
        .get_previous_secret("admin-blocked-retire")
        .is_some());

    let retired = post_decommission(
        mocks.app.clone(),
        decommissioned_vm_id,
        "admin-retired-mismatch",
    )
    .await;
    assert_eq!(retired.status(), StatusCode::OK);

    let mismatch_retry = post_decommission(mocks.app, decommissioned_vm_id, "wrong-hostname").await;
    assert_eq!(mismatch_retry.status(), StatusCode::CONFLICT);
    let mismatch_json = response_json(mismatch_retry).await;
    assert_eq!(
        mismatch_json,
        json!({"error": "hostname mismatch: expected wrong-hostname, found admin-retired-mismatch"})
    );
    assert!(mismatch_json.get("teardown").is_none());
    assert_eq!(
        inventory_status(&db.pool, decommissioned_vm_id).await,
        "decommissioned"
    );
}

#[tokio::test]
async fn decommission_endpoint_wins_concurrent_reference_publication_after_inventory_lock() {
    let Some(db) = connect_and_migrate("admin_vm_route_inventory_wins").await else {
        return;
    };

    assert_admin_route_inventory_lock_wins_publication(&db.schema, &db.pool, TEST_ADMIN_KEY).await;
}

#[tokio::test]
async fn decommission_endpoint_reports_blockers_when_reference_publication_wins() {
    let Some(db) = connect_and_migrate("admin_vm_route_reference_wins").await else {
        return;
    };

    assert_admin_route_reference_publication_wins(&db.schema, &db.pool, TEST_ADMIN_KEY).await;
}
