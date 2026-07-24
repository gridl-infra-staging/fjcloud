use std::sync::Arc;

use api::models::vm_inventory::{NewVmInventory, VmInventory};
use api::repos::{CatalogLifecycleTargetIdentity, IndexMigrationRepo, TenantRepo, VmInventoryRepo};
use api::secrets::mock::MockNodeSecretManager;
use api::secrets::NodeSecretManager;
use api::services::flapjack_proxy::FlapjackProxy;
use api::services::migration::{MigrationHttpResponse, MigrationStatus};
use axum::body::Body;
use axum::http::{Method, Request, StatusCode};
use serde_json::{json, Value};
use tower::ServiceExt;
use uuid::Uuid;

use crate::common::engine_index_identity_test_support::{
    assert_flapjack_request_sequence, assert_migration_request_sequence,
    engine_index_identity_callers, engine_index_identity_inventory_json, CallerExpectation,
    ExpectedFlapjackRequest, ExpectedMigrationRequest, ExpectedUpstreamKind, MigrationFixture,
};
use crate::common::flapjack_proxy_test_support::{test_flapjack_uid, MockFlapjackHttpClient};
use crate::common::indexes_route_test_support::response_json;
use crate::common::{
    create_test_jwt, mock_deployment_repo, mock_repo, mock_tenant_repo, mock_vm_inventory_repo,
    TestStateBuilder, TEST_ADMIN_KEY,
};

const INDEX_NAME: &str = "products";
const REGION: &str = "us-east-1";
const FLAPJACK_URL: &str = "https://vm-shared.flapjack.foo";

fn caller_denominator() -> &'static [CallerExpectation] {
    engine_index_identity_callers()
}

#[test]
fn caller_denominator_inventory_is_complete() {
    let ids: Vec<_> = caller_denominator()
        .iter()
        .map(|row| row.caller_id)
        .collect();
    assert_eq!(
        ids,
        vec![
            "migration.protocol.start_replication",
            "migration.protocol.pause_index",
            "migration.protocol.resume_index",
            "migration.protocol.delete_index",
            "migration.recovery.rollback_replicating",
            "migration.recovery.recover_source_on_failure",
            "migration.replication.fetch_oplog_seq",
            "migration.replication.build_auth_headers",
            "routes.indexes.lifecycle.create_replica",
            "routes.indexes.lifecycle.list_replicas",
            "routes.indexes.lifecycle.delete_replica",
            "routes.indexes.lifecycle.delete_index",
            "routes.indexes.index_metrics_route.get_index_metrics",
            "routes.admin.migrations.validate_migration_request",
            "routes.admin.migrations.execute_migration",
            "routes.admin.migrations.list_migrations",
            "routes.admin.replicas.list_replicas",
        ]
    );
    assert!(caller_denominator()
        .iter()
        .all(|row| !row.owner_path.is_empty() && !row.auth_secret_owner.is_empty()));
    assert_eq!(
        caller_denominator()
            .iter()
            .filter(|row| row.expected_upstream_kind == ExpectedUpstreamKind::PhysicalUid)
            .count(),
        11
    );
    assert_eq!(
        caller_denominator()
            .iter()
            .filter(|row| row.expected_upstream_kind == ExpectedUpstreamKind::CatalogOnly)
            .count(),
        6
    );
}

#[test]
fn caller_denominator_fixture_matches_shared_owner() {
    let fixture_path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../scripts/tests/fixtures/engine_index_identity_callers.json"
    );
    let fixture: Value = serde_json::from_str(
        &std::fs::read_to_string(fixture_path).expect("caller fixture should be readable"),
    )
    .expect("caller fixture should be JSON");

    assert_eq!(fixture, engine_index_identity_inventory_json());
}

fn json_request(method: Method, uri: &str, jwt: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {jwt}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

async fn shared_index_app(
    index_name: &str,
    node_secret_manager: Arc<MockNodeSecretManager>,
) -> (
    axum::Router,
    Arc<MockFlapjackHttpClient>,
    VmInventory,
    String,
    Uuid,
) {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let customer_id = customer.id;
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        node_secret_manager.clone(),
    ));

    let deployment = deployment_repo.seed_provisioned(
        customer_id,
        "legacy-node-id",
        REGION,
        "t4g.small",
        "aws",
        "running",
        Some(FLAPJACK_URL),
    );
    tenant_repo.seed_deployment(
        deployment.id,
        REGION,
        Some(FLAPJACK_URL),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, index_name, deployment.id)
        .await
        .unwrap();
    let vm = vm_repo.seed(REGION, FLAPJACK_URL);
    tenant_repo
        .set_vm_id(customer_id, index_name, vm.id)
        .await
        .unwrap();
    let replica_vm = vm_repo.create(replica_vm_seed()).await.unwrap();
    vm_repo.update_load(replica_vm.id, json!({})).await.unwrap();
    let node_key = node_secret_manager
        .create_node_api_key(vm.node_secret_id(), REGION)
        .await
        .unwrap();

    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_deployment_repo(deployment_repo)
        .with_tenant_repo(tenant_repo)
        .with_vm_inventory_repo(vm_repo)
        .with_node_secret_manager(node_secret_manager)
        .with_flapjack_proxy(flapjack_proxy)
        .build_app();

    (app, http_client, vm, node_key, customer_id)
}

async fn shared_state_same_name_index_app() -> (
    axum::Router,
    Arc<MockFlapjackHttpClient>,
    String,
    Uuid,
    Uuid,
) {
    let customer_repo = mock_repo();
    let alice = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let bob = customer_repo.seed_verified_free_customer("Bob", "bob@example.com");
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_repo = mock_vm_inventory_repo();
    let node_secret_manager = Arc::new(MockNodeSecretManager::new());
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        node_secret_manager.clone(),
    ));

    let vm = vm_repo.seed(REGION, FLAPJACK_URL);
    for (customer_id, node_id) in [(alice.id, "alice-node-id"), (bob.id, "bob-node-id")] {
        let deployment = deployment_repo.seed_provisioned(
            customer_id,
            node_id,
            REGION,
            "t4g.small",
            "aws",
            "running",
            Some(FLAPJACK_URL),
        );
        tenant_repo.seed_deployment(
            deployment.id,
            REGION,
            Some(FLAPJACK_URL),
            "healthy",
            "running",
        );
        tenant_repo
            .create(customer_id, INDEX_NAME, deployment.id)
            .await
            .unwrap();
        tenant_repo
            .set_vm_id(customer_id, INDEX_NAME, vm.id)
            .await
            .unwrap();
    }

    let node_key = node_secret_manager
        .create_node_api_key(vm.node_secret_id(), REGION)
        .await
        .unwrap();

    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_deployment_repo(deployment_repo)
        .with_tenant_repo(tenant_repo)
        .with_vm_inventory_repo(vm_repo)
        .with_node_secret_manager(node_secret_manager)
        .with_flapjack_proxy(flapjack_proxy)
        .build_app();

    (app, http_client, node_key, alice.id, bob.id)
}

#[tokio::test]
async fn two_customers_with_same_logical_index_use_distinct_physical_uids() {
    let (app, http_client, node_key, alice_id, bob_id) = shared_state_same_name_index_app().await;
    let alice_uid = test_flapjack_uid(alice_id, INDEX_NAME);
    let bob_uid = test_flapjack_uid(bob_id, INDEX_NAME);

    http_client.push_text_response(200, &metrics_fixture(&alice_uid, &bob_uid));
    http_client.push_text_response(200, &metrics_fixture(&bob_uid, &alice_uid));

    let alice_resp = app
        .clone()
        .oneshot(metrics_request(&create_test_jwt(alice_id), INDEX_NAME))
        .await
        .unwrap();
    let bob_resp = app
        .oneshot(metrics_request(&create_test_jwt(bob_id), INDEX_NAME))
        .await
        .unwrap();

    let (alice_status, alice_body) = response_json(alice_resp).await;
    let (bob_status, bob_body) = response_json(bob_resp).await;
    assert_eq!(alice_status, StatusCode::OK);
    assert_eq!(bob_status, StatusCode::OK);
    assert_eq!(alice_body["documents_count"], 11);
    assert_eq!(bob_body["documents_count"], 11);

    let requests = http_client.take_requests();
    assert_flapjack_request_sequence(
        &requests,
        &[
            ExpectedFlapjackRequest::get(format!("{FLAPJACK_URL}/metrics"), &node_key),
            ExpectedFlapjackRequest::get(format!("{FLAPJACK_URL}/metrics"), &node_key),
        ],
    );
}

#[tokio::test]
async fn source_deletion_uses_physical_uid_and_node_secret() {
    let (app, http_client, _vm, node_key, customer_id) =
        shared_index_app(INDEX_NAME, Arc::new(MockNodeSecretManager::new())).await;
    let expected_uid = test_flapjack_uid(customer_id, INDEX_NAME);
    http_client.push_text_response(204, "");

    let resp = app
        .oneshot(json_request(
            Method::DELETE,
            &format!("/indexes/{INDEX_NAME}"),
            &create_test_jwt(customer_id),
            json!({"confirm": true}),
        ))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    let requests = http_client.take_requests();
    assert_flapjack_request_sequence(
        &requests,
        &[ExpectedFlapjackRequest::delete(
            format!("{FLAPJACK_URL}/1/indexes/{expected_uid}"),
            &node_key,
        )],
    );
}

#[tokio::test]
async fn replica_routes_are_catalog_only_and_keep_terminal_semantics() {
    let (app, http_client, _vm, _node_key, customer_id) =
        shared_index_app(INDEX_NAME, Arc::new(MockNodeSecretManager::new())).await;
    let jwt = create_test_jwt(customer_id);

    let create_resp = app
        .clone()
        .oneshot(json_request(
            Method::POST,
            &format!("/indexes/{INDEX_NAME}/replicas"),
            &jwt,
            json!({"region": "eu-central-1"}),
        ))
        .await
        .unwrap();
    let (create_status, create_body) = response_json(create_resp).await;
    assert_eq!(create_status, StatusCode::CREATED, "body: {create_body}");
    assert_eq!(create_body["replica_region"], "eu-central-1");
    assert_eq!(create_body["status"], "provisioning");
    let replica_id = create_body["id"].as_str().expect("replica id");

    let list_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::GET)
                .uri(format!("/indexes/{INDEX_NAME}/replicas"))
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let (list_status, list_body) = response_json(list_resp).await;
    assert_eq!(list_status, StatusCode::OK, "body: {list_body}");
    assert_eq!(list_body.as_array().expect("replica list").len(), 1);
    assert_eq!(list_body[0]["id"], replica_id);

    let delete_resp = app
        .oneshot(
            Request::builder()
                .method(Method::DELETE)
                .uri(format!("/indexes/{INDEX_NAME}/replicas/{replica_id}"))
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(delete_resp.status(), StatusCode::NO_CONTENT);
    assert_eq!(http_client.take_requests().len(), 0);
}

#[tokio::test]
async fn admin_catalog_list_routes_are_catalog_only() {
    let (app, http_client, _vm, _node_key, customer_id) =
        shared_index_app(INDEX_NAME, Arc::new(MockNodeSecretManager::new())).await;
    let jwt = create_test_jwt(customer_id);
    let create_resp = app
        .clone()
        .oneshot(json_request(
            Method::POST,
            &format!("/indexes/{INDEX_NAME}/replicas"),
            &jwt,
            json!({"region": "eu-central-1"}),
        ))
        .await
        .unwrap();
    assert_eq!(create_resp.status(), StatusCode::CREATED);

    let migrations_resp = app
        .clone()
        .oneshot(admin_get_request(
            "/admin/migrations?status=active&limit=10",
        ))
        .await
        .unwrap();
    let (migrations_status, migrations_body) = response_json(migrations_resp).await;
    assert_eq!(migrations_status, StatusCode::OK, "body: {migrations_body}");
    assert_eq!(migrations_body.as_array().expect("migration list").len(), 0);

    let replicas_resp = app
        .oneshot(admin_get_request("/admin/replicas?status=provisioning"))
        .await
        .unwrap();
    let (replicas_status, replicas_body) = response_json(replicas_resp).await;
    assert_eq!(replicas_status, StatusCode::OK, "body: {replicas_body}");
    assert_eq!(
        replicas_body.as_array().expect("admin replica list").len(),
        1
    );
    assert_eq!(replicas_body[0]["tenant_id"], INDEX_NAME);
    assert_eq!(http_client.take_requests().len(), 0);
}

#[tokio::test]
async fn rollback_cleanup_uses_physical_uid_and_node_secret() {
    let fixture = MigrationFixture::setup(INDEX_NAME).await;
    let migration = fixture.migration_repo.seed(
        INDEX_NAME,
        fixture.customer_id,
        fixture.source_vm.id,
        fixture.dest_vm.id,
        "replicating",
    );
    let tenant = fixture
        .tenant_repo
        .find_raw(fixture.customer_id, INDEX_NAME)
        .await
        .unwrap()
        .unwrap();
    let identity = CatalogLifecycleTargetIdentity {
        deployment_id: tenant.deployment_id,
        vm_id: tenant.vm_id,
        tier: tenant.tier,
        cold_snapshot_id: tenant.cold_snapshot_id,
        service_type: tenant.service_type,
    };
    let metadata = migration.metadata_with_intent_target_identity(&identity);
    fixture
        .migration_repo
        .update_metadata(migration.id, metadata)
        .await
        .unwrap();
    fixture.http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));

    fixture.service.rollback(migration.id).await.unwrap();

    let requests = fixture.http_client.recorded_requests();
    assert_migration_request_sequence(
        &requests,
        &[ExpectedMigrationRequest::delete(
            format!(
                "{}/1/indexes/{}",
                fixture.dest_vm.flapjack_url, fixture.physical_uid
            ),
            &fixture.dest_key,
        )],
    );
}

#[tokio::test]
async fn rollback_refuses_missing_intent_target_identity_before_cleanup() {
    let fixture = MigrationFixture::setup(INDEX_NAME).await;
    let migration = fixture.migration_repo.seed(
        INDEX_NAME,
        fixture.customer_id,
        fixture.source_vm.id,
        fixture.dest_vm.id,
        "replicating",
    );

    let err = fixture
        .service
        .rollback(migration.id)
        .await
        .expect_err("missing intent target identity should refuse rollback");
    let api::services::migration::MigrationError::Protocol(message) = err else {
        panic!("expected wrapped protocol error, got {err:?}");
    };
    assert!(
        message.contains("cannot roll back without captured catalog lifecycle identity"),
        "unexpected protocol message: {message}"
    );
    assert!(
        message.contains("missing intent target identity"),
        "unexpected protocol message: {message}"
    );
    assert!(
        fixture.http_client.recorded_requests().is_empty(),
        "rollback without intent identity must not attempt cleanup"
    );
}

#[tokio::test]
async fn failure_recovery_cleanup_uses_physical_uid_and_node_secret() {
    let fixture = MigrationFixture::setup(INDEX_NAME).await;
    fixture.queue_destination_resume_failure_protocol();

    fixture
        .service
        .execute(api::services::migration::MigrationRequest {
            index_name: INDEX_NAME.to_string(),
            customer_id: fixture.customer_id,
            source_vm_id: fixture.source_vm.id,
            dest_vm_id: fixture.dest_vm.id,
            requested_by: "stage-1-test".to_string(),
        })
        .await
        .expect_err("destination resume failure should trigger recovery cleanup");

    let requests = fixture.http_client.recorded_requests();
    let expected = fixture
        .successful_protocol_requests()
        .into_iter()
        .chain([
            ExpectedMigrationRequest::post(
                format!(
                    "{}/internal/resume/{}",
                    fixture.source_vm.flapjack_url, fixture.physical_uid
                ),
                None,
                &fixture.source_key,
            ),
            ExpectedMigrationRequest::delete(
                format!(
                    "{}/1/indexes/{}",
                    fixture.dest_vm.flapjack_url, fixture.physical_uid
                ),
                &fixture.dest_key,
            ),
        ])
        .collect::<Vec<_>>();
    assert_migration_request_sequence(&requests, &expected);
}

#[tokio::test]
async fn failure_recovery_cleanup_auth_failure_keeps_source_routing_visible() {
    let fixture = MigrationFixture::setup(INDEX_NAME).await;
    fixture.queue_destination_cleanup_failure_after_replication_started_protocol();

    let err = fixture
        .service
        .execute(api::services::migration::MigrationRequest {
            index_name: INDEX_NAME.to_string(),
            customer_id: fixture.customer_id,
            source_vm_id: fixture.source_vm.id,
            dest_vm_id: fixture.dest_vm.id,
            requested_by: "stage-3-test".to_string(),
        })
        .await
        .expect_err("destination resume failure should trigger recovery cleanup");
    assert!(matches!(
        err,
        api::services::migration::MigrationError::Http(_)
    ));

    let tenant = fixture
        .tenant_repo
        .find_raw(fixture.customer_id, INDEX_NAME)
        .await
        .expect("tenant lookup should succeed")
        .expect("tenant should exist");
    assert_eq!(tenant.vm_id, Some(fixture.source_vm.id));

    let discovered = fixture
        .state()
        .discovery_service
        .discover(fixture.customer_id, INDEX_NAME)
        .await
        .expect("source discovery should remain visible");
    assert_eq!(discovered.vm, fixture.source_vm.hostname);

    let migration = fixture
        .migration_repo
        .list_recent(1)
        .await
        .expect("migration lookup should succeed");
    assert_eq!(migration.len(), 1);
    assert_eq!(
        migration[0].status,
        MigrationStatus::Failed(String::new()).as_str()
    );
    assert!(
        migration[0]
            .error
            .as_deref()
            .is_some_and(|message| message.contains("destination resume failed")),
        "terminal error should preserve the primary execute failure"
    );

    let expected = fixture
        .successful_protocol_requests()
        .into_iter()
        .chain([
            fixture.source_resume_request(),
            fixture.destination_delete_request(),
        ])
        .collect::<Vec<_>>();
    let requests = fixture.http_client.recorded_requests();
    assert_migration_request_sequence(&requests, &expected);
}

#[tokio::test]
async fn admin_migration_completion_uses_physical_uid_and_node_secret() {
    let fixture = MigrationFixture::setup(INDEX_NAME).await;
    fixture.queue_successful_protocol();
    let expected_requests = fixture.successful_protocol_requests();
    let mut state = fixture.state();
    state.migration_service = Arc::new(fixture.service);
    let app = api::router::build_router(state);

    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/admin/migrations")
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({"index_name": INDEX_NAME, "dest_vm_id": fixture.dest_vm.id}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK, "body: {body}");
    assert!(body["migration_id"].is_string(), "body: {body}");
    assert_eq!(
        body["status"].as_str(),
        Some(MigrationStatus::Completed.as_str())
    );

    let requests = fixture.http_client.recorded_requests();
    assert_migration_request_sequence(&requests, &expected_requests);
}

fn metrics_request(jwt: &str, index_name: &str) -> Request<Body> {
    Request::builder()
        .method(Method::GET)
        .uri(format!("/indexes/{index_name}/metrics"))
        .header("authorization", format!("Bearer {jwt}"))
        .body(Body::empty())
        .unwrap()
}

fn admin_get_request(uri: &str) -> Request<Body> {
    Request::builder()
        .method(Method::GET)
        .uri(uri)
        .header("x-admin-key", TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap()
}

fn metrics_fixture(in_scope_uid: &str, other_uid: &str) -> String {
    format!(
        "flapjack_documents_count{{index=\"{in_scope_uid}\"}} 11\n\
         flapjack_documents_count{{index=\"{other_uid}\"}} 999\n\
         flapjack_storage_bytes{{index=\"{in_scope_uid}\"}} 22\n\
         flapjack_search_requests_total{{index=\"{in_scope_uid}\"}} 33\n\
         flapjack_documents_indexed_total{{index=\"{in_scope_uid}\"}} 44\n"
    )
}

fn replica_vm_seed() -> NewVmInventory {
    NewVmInventory {
        region: "eu-central-1".to_string(),
        provider: "hetzner".to_string(),
        hostname: "vm-replica.flapjack.foo".to_string(),
        flapjack_url: "https://vm-replica.flapjack.foo".to_string(),
        capacity: json!({
            "cpu_weight": 100.0,
            "mem_rss_bytes": 10_000_000_000_u64,
            "disk_bytes": 10_000_000_000_u64,
            "query_rps": 10_000.0,
            "indexing_rps": 10_000.0
        }),
    }
}
