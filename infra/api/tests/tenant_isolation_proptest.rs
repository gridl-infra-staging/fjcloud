mod common;

use std::cell::{Cell, RefCell};
use std::sync::Arc;

use api::repos::tenant_repo::TenantRepo;
use api::secrets::NodeSecretManager;
use api::services::flapjack_proxy::{FlapjackHttpRequest, FlapjackProxy};
use axum::body::Body;
use axum::http::{self, Request, StatusCode};
use http_body_util::BodyExt;
use proptest::prelude::*;
use proptest::test_runner::{
    FailurePersistence, FileFailurePersistence, TestCaseError, TestRunner,
};
use serde_json::{json, Value};
use tower::ServiceExt;

use common::{
    create_test_jwt,
    flapjack_proxy_test_support::{test_flapjack_uid, MockFlapjackHttpClient},
    mock_deployment_repo, mock_repo, mock_tenant_repo, mock_vm_inventory_repo,
    test_app_with_indexes_and_vm_inventory,
};

const ALICE_INDEX_NAME: &str = "alice-index";
const BOB_INDEX_NAME: &str = "bob-index";
const ALICE_FLAPJACK_URL: &str = "https://vm-alice-test.flapjack.foo";
const BOB_FLAPJACK_URL: &str = "https://vm-bob-test.flapjack.foo";
const TENANT_ISOLATION_PROPTEST_REGRESSION_PATH: &str =
    "tests/proptest-regressions/tenant_isolation_proptest.txt";
const TENANT_ISOLATION_LEAK_PROOF_MARKER: &str = "LEAK_PROOF_SHARED_GATE_BYPASS";
const TENANT_ISOLATION_LEAK_FAILURE_SIGNATURE: &str =
    "bob-foreign-shared-helper-on-alice-index: foreign tenant should be denied";
const TENANT_ISOLATION_REPLAY_PROOF_MARKER: &str = "REPLAY_PROOF_SAVED_CASE_FIRST";
const TENANT_ISOLATION_REPLAY_COMMAND_MARKER: &str =
    "cd infra && cargo test -p api --test tenant_isolation_proptest \
     tenant_isolation_proptest_route_family -- --nocapture";

#[derive(Clone)]
struct TenantFixture {
    customer_id: uuid::Uuid,
    jwt: String,
    index_name: &'static str,
    flapjack_url: &'static str,
    expected_api_key: String,
}

struct TenantIsolationHarness {
    app: axum::Router,
    alice: TenantFixture,
    bob: TenantFixture,
    http_client: Arc<MockFlapjackHttpClient>,
}

#[derive(Clone, Debug)]
enum SuccessBodyExpectation {
    RuleObjectId(String),
    SettingsTaskId(i64),
    SearchNbHits(i64),
}

#[derive(Clone, Debug)]
struct RouteCase {
    label: &'static str,
    method: http::Method,
    route_path_suffix: String,
    json_body: Option<Value>,
    expected_success_status: StatusCode,
    expected_success_body: SuccessBodyExpectation,
    expected_proxy_method: reqwest::Method,
    expected_proxy_path_suffix: String,
}

impl RouteCase {
    fn rules_get(rule_id: String) -> Self {
        Self {
            label: "rules_get",
            method: http::Method::GET,
            route_path_suffix: format!("/rules/{rule_id}"),
            json_body: None,
            expected_success_status: StatusCode::OK,
            expected_success_body: SuccessBodyExpectation::RuleObjectId(rule_id.clone()),
            expected_proxy_method: reqwest::Method::GET,
            expected_proxy_path_suffix: format!("/rules/{rule_id}"),
        }
    }

    fn settings_update() -> Self {
        Self {
            label: "settings_update",
            method: http::Method::PUT,
            route_path_suffix: "/settings".to_string(),
            json_body: Some(json!({
                "searchableAttributes": ["title", "body"],
                "filterableAttributes": ["category"]
            })),
            expected_success_status: StatusCode::OK,
            expected_success_body: SuccessBodyExpectation::SettingsTaskId(42),
            expected_proxy_method: reqwest::Method::POST,
            expected_proxy_path_suffix: "/settings".to_string(),
        }
    }

    fn search() -> Self {
        Self {
            label: "search",
            method: http::Method::POST,
            route_path_suffix: "/search".to_string(),
            json_body: Some(json!({
                "query": "laptop",
                "page": 0,
                "hitsPerPage": 10
            })),
            expected_success_status: StatusCode::OK,
            expected_success_body: SuccessBodyExpectation::SearchNbHits(1),
            expected_proxy_method: reqwest::Method::POST,
            expected_proxy_path_suffix: "/query".to_string(),
        }
    }

    fn route_uri(&self, index_name: &str) -> String {
        format!("/indexes/{index_name}{}", self.route_path_suffix)
    }

    fn expected_proxy_suffix(&self, target: &TenantFixture) -> String {
        let flapjack_uid = test_flapjack_uid(target.customer_id, target.index_name);
        format!(
            "/1/indexes/{flapjack_uid}{}",
            self.expected_proxy_path_suffix
        )
    }

    fn expected_proxy_body(&self) -> Option<Value> {
        self.json_body.clone()
    }

    fn allowed_response_body(&self) -> Value {
        match &self.expected_success_body {
            SuccessBodyExpectation::RuleObjectId(rule_id) => {
                json!({"objectID": rule_id, "description": "rule"})
            }
            SuccessBodyExpectation::SettingsTaskId(task_id) => {
                json!({"updatedAt": "2026-02-25T00:00:00Z", "taskID": task_id})
            }
            SuccessBodyExpectation::SearchNbHits(nb_hits) => json!({
                "hits": [{"objectID": "1", "title": "Laptop"}],
                "nbHits": nb_hits,
                "page": 0,
                "hitsPerPage": 10
            }),
        }
    }

    fn assert_success_body(&self, body: &Value, operation_label: &str) {
        match &self.expected_success_body {
            SuccessBodyExpectation::RuleObjectId(rule_id) => {
                assert_eq!(
                    body["objectID"], *rule_id,
                    "{operation_label}: unexpected rule body"
                );
            }
            SuccessBodyExpectation::SettingsTaskId(task_id) => {
                assert_eq!(
                    body["taskID"], *task_id,
                    "{operation_label}: unexpected settings task ID"
                );
            }
            SuccessBodyExpectation::SearchNbHits(nb_hits) => {
                assert_eq!(
                    body["nbHits"], *nb_hits,
                    "{operation_label}: unexpected search nbHits"
                );
            }
        }
    }
}

fn shared_owner_route_case_strategy() -> impl Strategy<Value = RouteCase> {
    prop_oneof![
        "[a-z][a-z0-9_-]{2,8}".prop_map(RouteCase::rules_get),
        Just(RouteCase::settings_update()),
    ]
}

async fn setup_tenant_isolation_harness() -> TenantIsolationHarness {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let alice = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let bob = customer_repo.seed_verified_free_customer("Bob", "bob@example.com");
    let alice_jwt = create_test_jwt(alice.id);
    let bob_jwt = create_test_jwt(bob.id);

    let alice_api_key = node_secret_manager
        .create_node_api_key("node-a1", "us-east-1")
        .await
        .unwrap();
    let bob_api_key = node_secret_manager
        .create_node_api_key("node-b1", "us-east-1")
        .await
        .unwrap();

    let alice_deployment = deployment_repo.seed_provisioned(
        alice.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some(ALICE_FLAPJACK_URL),
    );
    tenant_repo.seed_deployment(
        alice_deployment.id,
        "us-east-1",
        Some(ALICE_FLAPJACK_URL),
        "healthy",
        "running",
    );
    tenant_repo
        .create(alice.id, ALICE_INDEX_NAME, alice_deployment.id)
        .await
        .unwrap();

    let alice_vm = vm_inventory_repo.seed("us-east-1", ALICE_FLAPJACK_URL);
    tenant_repo
        .set_vm_id(alice.id, ALICE_INDEX_NAME, alice_vm.id)
        .await
        .unwrap();

    let bob_deployment = deployment_repo.seed_provisioned(
        bob.id,
        "node-b1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some(BOB_FLAPJACK_URL),
    );
    tenant_repo.seed_deployment(
        bob_deployment.id,
        "us-east-1",
        Some(BOB_FLAPJACK_URL),
        "healthy",
        "running",
    );
    tenant_repo
        .create(bob.id, BOB_INDEX_NAME, bob_deployment.id)
        .await
        .unwrap();

    let bob_vm = vm_inventory_repo.seed("us-east-1", BOB_FLAPJACK_URL);
    tenant_repo
        .set_vm_id(bob.id, BOB_INDEX_NAME, bob_vm.id)
        .await
        .unwrap();

    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        node_secret_manager,
    ));
    let app = test_app_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo,
        flapjack_proxy,
        vm_inventory_repo,
    );

    TenantIsolationHarness {
        app,
        alice: TenantFixture {
            customer_id: alice.id,
            jwt: alice_jwt,
            index_name: ALICE_INDEX_NAME,
            flapjack_url: ALICE_FLAPJACK_URL,
            expected_api_key: alice_api_key,
        },
        bob: TenantFixture {
            customer_id: bob.id,
            jwt: bob_jwt,
            index_name: BOB_INDEX_NAME,
            flapjack_url: BOB_FLAPJACK_URL,
            expected_api_key: bob_api_key,
        },
        http_client,
    }
}

async fn response_json(resp: axum::http::Response<Body>) -> (StatusCode, Value) {
    let status = resp.status();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let json: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, json)
}

/// TODO: Document run_case_operation.
/// Every property case executes two route seams with mirrored allow/deny flows:
/// one route that resolves ownership via `resolve_ready_index_target()` and one
/// `search` route that still performs inline tenant lookup. This asymmetric
/// sequence is what catches leaks in either authorization seam.
async fn run_case_operation(
    harness: &TenantIsolationHarness,
    route_case: &RouteCase,
    actor: &TenantFixture,
    target: &TenantFixture,
    expect_allowed: bool,
    sequence_label: &str,
) {
    let uri = route_case.route_uri(target.index_name);
    let mut request_builder = Request::builder()
        .method(route_case.method.clone())
        .uri(&uri)
        .header("authorization", format!("Bearer {}", actor.jwt));

    let body = match route_case.json_body.clone() {
        Some(body) => {
            request_builder = request_builder.header("content-type", "application/json");
            Body::from(body.to_string())
        }
        None => Body::empty(),
    };

    let before_count = harness.http_client.request_count();
    let response = harness
        .app
        .clone()
        .oneshot(request_builder.body(body).unwrap())
        .await
        .unwrap();
    let (status, response_body) = response_json(response).await;
    let after_count = harness.http_client.request_count();

    if expect_allowed {
        assert_eq!(
            status, route_case.expected_success_status,
            "{sequence_label}: expected success status for {}",
            route_case.label
        );
        route_case.assert_success_body(&response_body, sequence_label);
        assert_eq!(
            after_count,
            before_count + 1,
            "{sequence_label}: expected exactly one new proxy request for {}",
            route_case.label
        );

        let requests = harness.http_client.take_requests();
        assert_eq!(
            requests.len(),
            after_count,
            "{sequence_label}: request recorder length should match request_count()"
        );
        let new_request = requests
            .last()
            .expect("allowed operation should have at least one request");
        assert_proxy_target(
            new_request,
            route_case,
            target,
            sequence_label,
            route_case.expected_proxy_body(),
        );
    } else {
        assert_eq!(
            status,
            StatusCode::NOT_FOUND,
            "{sequence_label}: foreign tenant should be denied"
        );
        assert!(
            response_body["error"]
                .as_str()
                .unwrap_or_default()
                .contains("not found"),
            "{sequence_label}: expected not-found ownership error body, got: {response_body}"
        );
        assert_eq!(
            after_count, before_count,
            "{sequence_label}: foreign tenant request must not proxy"
        );
    }
}

fn assert_proxy_target(
    request: &FlapjackHttpRequest,
    route_case: &RouteCase,
    target: &TenantFixture,
    sequence_label: &str,
    expected_proxy_body: Option<Value>,
) {
    let expected_suffix = route_case.expected_proxy_suffix(target);
    assert_eq!(
        request.method, route_case.expected_proxy_method,
        "{sequence_label}: unexpected proxy HTTP method for {}",
        route_case.label
    );
    assert!(
        request.url.starts_with(target.flapjack_url),
        "{sequence_label}: proxy base URL mismatch, got {}",
        request.url
    );
    assert!(
        request.url.ends_with(&expected_suffix),
        "{sequence_label}: proxy path suffix mismatch, expected suffix {expected_suffix}, got {}",
        request.url
    );
    assert_eq!(
        request.api_key, target.expected_api_key,
        "{sequence_label}: proxy should use target tenant node key"
    );
    assert_eq!(
        request.json_body, expected_proxy_body,
        "{sequence_label}: proxy body mismatch for {}",
        route_case.label
    );
}

fn tenant_isolation_proptest_config() -> ProptestConfig {
    ProptestConfig {
        cases: 1,
        failure_persistence: Some(Box::new(FileFailurePersistence::Direct(
            TENANT_ISOLATION_PROPTEST_REGRESSION_PATH,
        ))),
        ..ProptestConfig::default()
    }
}

fn read_committed_regression_artifact() -> String {
    std::fs::read_to_string(TENANT_ISOLATION_PROPTEST_REGRESSION_PATH).expect(
        "tenant isolation proptest regression artifact must exist so committed \
         replay evidence remains auditable",
    )
}

fn replay_only_runner() -> TestRunner {
    let mut config = tenant_isolation_proptest_config();
    config.cases = 0;
    TestRunner::new(config)
}

#[test]
fn tenant_isolation_proptest_config_uses_direct_failure_persistence() {
    let config = tenant_isolation_proptest_config();
    let actual_failure_persistence = config.failure_persistence.expect(
        "tenant isolation property must persist failures for replay at \
         {TENANT_ISOLATION_PROPTEST_REGRESSION_PATH}",
    );
    let expected_failure_persistence: Box<dyn FailurePersistence> = Box::new(
        FileFailurePersistence::Direct(TENANT_ISOLATION_PROPTEST_REGRESSION_PATH),
    );
    assert!(
        actual_failure_persistence == expected_failure_persistence,
        "tenant isolation property must pin FileFailurePersistence::Direct to \
         {TENANT_ISOLATION_PROPTEST_REGRESSION_PATH}"
    );
    assert!(
        TENANT_ISOLATION_PROPTEST_REGRESSION_PATH.starts_with("tests/proptest-regressions/"),
        "regression file must live under tests/, not source-parallel src/"
    );
}

#[test]
fn tenant_isolation_proptest_regression_artifact_has_durable_proof_markers() {
    let regression_artifact = read_committed_regression_artifact();
    assert!(
        regression_artifact.contains(TENANT_ISOLATION_LEAK_PROOF_MARKER),
        "regression artifact must record the shared-gate leak-proof marker: \
         {TENANT_ISOLATION_LEAK_PROOF_MARKER}"
    );
    assert!(
        regression_artifact.contains(TENANT_ISOLATION_REPLAY_PROOF_MARKER),
        "regression artifact must record the replay-proof marker: \
         {TENANT_ISOLATION_REPLAY_PROOF_MARKER}"
    );
    assert!(
        regression_artifact.contains(TENANT_ISOLATION_REPLAY_COMMAND_MARKER),
        "regression artifact must capture the exact replay proof command marker: \
         {TENANT_ISOLATION_REPLAY_COMMAND_MARKER}"
    );
    assert!(
        regression_artifact.contains(TENANT_ISOLATION_LEAK_FAILURE_SIGNATURE),
        "regression artifact must capture the leak failure signature marker: \
         {TENANT_ISOLATION_LEAK_FAILURE_SIGNATURE}"
    );
    assert!(
        regression_artifact.contains("shared_owner_route_case = RouteCase"),
        "regression artifact must preserve the shared owner route-case shrink payload"
    );
    assert!(
        regression_artifact
            .lines()
            .any(|line| line.starts_with("cc ")),
        "regression artifact must keep at least one persisted proptest seed"
    );
}

fn expected_replayed_route_label(regression_artifact: &str) -> Option<String> {
    regression_artifact.lines().find_map(|line| {
        let marker = "shared_owner_route_case = RouteCase { label: \"";
        let (_, after_marker) = line.split_once(marker)?;
        let (label, _) = after_marker.split_once('"')?;
        Some(label.to_string())
    })
}

#[test]
fn tenant_isolation_proptest_saved_case_replays_before_random_generation() {
    let replay_invocations = Cell::new(0usize);
    let mut runner = replay_only_runner();
    let result = runner.run(&shared_owner_route_case_strategy(), |_| {
        replay_invocations.set(replay_invocations.get() + 1);
        Err(TestCaseError::fail(
            "saved case replay should execute before random generation",
        ))
    });

    assert!(
        result.is_err(),
        "with cases=0 the only way to reach property execution is replaying persisted failures"
    );
    assert!(
        replay_invocations.get() >= 1,
        "expected at least one replayed invocation from saved failures"
    );
}

#[test]
fn tenant_isolation_proptest_saved_case_replays_committed_route_label_first() {
    let regression_artifact = read_committed_regression_artifact();
    let expected_route_label = expected_replayed_route_label(&regression_artifact).expect(
        "regression artifact must include a shared_owner_route_case shrink payload with route label",
    );

    let replayed_case_label = RefCell::new(None::<String>);
    let mut runner = replay_only_runner();
    let result = runner.run(&shared_owner_route_case_strategy(), |route_case| {
        if replayed_case_label.borrow().is_none() {
            replayed_case_label.replace(Some(route_case.label.to_string()));
        }
        Err(TestCaseError::fail(
            "stop after capturing replayed first case label",
        ))
    });

    assert!(
        result.is_err(),
        "with cases=0 the first invocation must come from saved-case replay"
    );
    let observed_route_label = replayed_case_label
        .into_inner()
        .expect("expected first replayed route case label to be captured from saved seed replay");
    assert_eq!(
        observed_route_label, expected_route_label,
        "first replayed case should match the committed regression artifact shrink payload"
    );
}

proptest! {
    #![proptest_config(tenant_isolation_proptest_config())]

    #[test]
    fn tenant_isolation_proptest_route_family(shared_owner_route_case in shared_owner_route_case_strategy()) {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        runtime.block_on(async {
            let harness = setup_tenant_isolation_harness().await;
            let search_route_case = RouteCase::search();

            let shared_owner_allowed_response = shared_owner_route_case.allowed_response_body();
            let search_allowed_response = search_route_case.allowed_response_body();
            harness
                .http_client
                .push_json_response(
                    shared_owner_route_case.expected_success_status.as_u16(),
                    shared_owner_allowed_response,
                );
            harness
                .http_client
                .push_json_response(
                    search_route_case.expected_success_status.as_u16(),
                    search_allowed_response,
                );

            // Shared owner-helper seam: same-tenant control on Alice index.
            run_case_operation(
                &harness,
                &shared_owner_route_case,
                &harness.alice,
                &harness.alice,
                true,
                "alice-control-shared-helper-on-alice-index",
            )
            .await;
            // Shared owner-helper seam: foreign access Bob -> Alice must deny and never proxy.
            run_case_operation(
                &harness,
                &shared_owner_route_case,
                &harness.bob,
                &harness.alice,
                false,
                "bob-foreign-shared-helper-on-alice-index",
            )
            .await;
            // Search seam keeps its own inline tenant lookup: same-tenant control on Bob index.
            run_case_operation(
                &harness,
                &search_route_case,
                &harness.bob,
                &harness.bob,
                true,
                "bob-control-search-inline-on-bob-index",
            )
            .await;
            // Search seam foreign direction Alice -> Bob must also deny and never proxy.
            run_case_operation(
                &harness,
                &search_route_case,
                &harness.alice,
                &harness.bob,
                false,
                "alice-foreign-search-inline-on-bob-index",
            )
            .await;

            assert_eq!(
                harness.http_client.request_count(),
                2,
                "exactly the two same-tenant control operations should proxy"
            );
        });
    }
}
