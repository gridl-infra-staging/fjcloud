//! RED tests for the stateless migration preview route.
use super::*;

fn preview_request(provider: &str, source_index: &str) -> serde_json::Value {
    match provider {
        "meilisearch" => json!({
            "endpoint": "https://preview.meilisearch.example",
            "apiKey": "temporary-preview-key",
            "sourceIndex": source_index
        }),
        _ => json!({
            "appId": "PREVIEWAPP123",
            "apiKey": "temporary-preview-key",
            "sourceIndex": source_index
        }),
    }
}

fn expected_preview_engine_body(provider: &str, source_index: &str) -> String {
    preview_request(provider, source_index).to_string()
}

fn preview_engine_response(provider: &str) -> serde_json::Value {
    json!({
        "sourceCounts": {
            "indexes": 3,
            "records": 42
        },
        "report": {
            "summary": {
                "totalEntries": 2,
                "hardRejections": 1,
                "warnings": 1,
                "scopeGaps": 0
            },
            "entries": [
                {
                    "severity": "Warning",
                    "code": "UnsupportedSourceField",
                    "resource": "Settings",
                    "jsonPath": "$.settings.attributesForFaceting[0]",
                    "pageIndex": null,
                    "itemIndex": 0
                },
                {
                    "severity": "HardRejection",
                    "code": "MalformedDocumentPayload",
                    "resource": "Document",
                    "jsonPath": "$.hits[7]",
                    "pageIndex": 1,
                    "itemIndex": 7
                }
            ],
            "reportDigest": format!("sha256:{provider}-preview-report")
        }
    })
}

async fn seed_preview_vm(
    vm_inventory_repo: &Arc<crate::common::MockVmInventoryRepo>,
) -> api::models::vm_inventory::VmInventory {
    vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-preview.flapjack.test".to_string(),
            flapjack_url: "https://vm-preview.flapjack.test".to_string(),
            capacity: json!({ "disk_bytes": 10_000_000_000_i64 }),
        })
        .await
        .expect("seed mock preview VM")
}

async fn setup_preview_app_with_inventory(
    algolia_migration_enabled: bool,
    vm_inventory_repo: Arc<crate::common::MockVmInventoryRepo>,
) -> (
    axum::Router,
    String,
    Arc<MockFlapjackHttpClient>,
    Arc<crate::common::MockVmInventoryRepo>,
) {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let node_secret_manager = Arc::new(MockNodeSecretManager::new());
    for vm in vm_inventory_repo
        .list_active(None)
        .await
        .expect("read seeded preview VM inventory")
    {
        node_secret_manager
            .create_node_api_key(vm.node_secret_id(), &vm.region)
            .await
            .expect("seed preview VM admin key");
    }
    let flapjack_http = Arc::new(MockFlapjackHttpClient::default());
    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        flapjack_http.clone(),
        node_secret_manager,
    ));
    let state = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_vm_inventory_repo(vm_inventory_repo.clone())
        .with_flapjack_proxy(flapjack_proxy)
        .with_algolia_migration_enabled(algolia_migration_enabled)
        .build();
    (
        build_router(state),
        create_test_jwt(customer.id),
        flapjack_http,
        vm_inventory_repo,
    )
}

async fn setup_preview_app(
    algolia_migration_enabled: bool,
) -> (axum::Router, String, Arc<MockFlapjackHttpClient>) {
    let vm_inventory_repo = crate::common::mock_vm_inventory_repo();
    seed_preview_vm(&vm_inventory_repo).await;
    let (app, jwt, flapjack_http, _) =
        setup_preview_app_with_inventory(algolia_migration_enabled, vm_inventory_repo).await;
    (app, jwt, flapjack_http)
}

async fn setup_preview_app_with_pool(
    pool: PgPool,
) -> (axum::Router, String, Arc<MockFlapjackHttpClient>) {
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let harness = setup_algolia_cloud_job_create_harness(pool, source_service.clone()).await;
    let jwt = harness.jwt.clone();
    let flapjack_http = harness.flapjack_http.clone();
    (build_router(harness.state), jwt, flapjack_http)
}

async fn post_preview(
    app: axum::Router,
    jwt: &str,
    provider: &str,
    body: serde_json::Value,
) -> (StatusCode, http::HeaderMap, serde_json::Value) {
    let response = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri(format!("/migration/{provider}/preview"))
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(body.to_string()))
                .expect("build preview request"),
        )
        .await
        .expect("preview response");
    let status = response.status();
    let headers = response.headers().clone();
    let (_, body) = response_json(response).await;
    (status, headers, body)
}

fn assert_preview_error_matches_published_schema(status: StatusCode, body: &serde_json::Value) {
    let spec = crate::common::openapi_spec_json();
    let response_schema_ref = spec
        .pointer(&format!(
            "/paths/~1migration~1{{source_provider}}~1preview/post/responses/{}/content/application~1json/schema/$ref",
            status.as_u16()
        ))
        .and_then(serde_json::Value::as_str)
        .expect("preview error response must reference a published schema");
    let schema_name = response_schema_ref
        .strip_prefix("#/components/schemas/")
        .expect("preview error response must reference a component schema");
    let mut published_fields = spec
        .pointer(&format!("/components/schemas/{schema_name}/required"))
        .and_then(serde_json::Value::as_array)
        .expect("preview error schema must declare required fields")
        .iter()
        .map(|field| {
            field
                .as_str()
                .expect("preview error required field must be a string")
                .to_string()
        })
        .collect::<Vec<_>>();
    published_fields.sort();

    // Exact field-set identity, not mere presence: a served body carrying an
    // undocumented field (such as the migration-family `code`) must fail here
    // rather than pass because every published field happened to be present.
    let mut served_fields = body
        .as_object()
        .unwrap_or_else(|| panic!("served preview {status} body must be an object: {body}"))
        .keys()
        .cloned()
        .collect::<Vec<_>>();
    served_fields.sort();

    assert_eq!(
        served_fields, published_fields,
        "served preview {status} body fields must match published {schema_name} exactly: {body}"
    );
}

async fn assert_provider_preview_preserves_engine_report(provider: &str) {
    let (app, jwt, flapjack_http) = setup_preview_app(true).await;
    let expected_response = preview_engine_response(provider);
    flapjack_http.expect_sensitive_json_body(&expected_preview_engine_body(provider, "products"));
    flapjack_http.push_sensitive_json_response(200, expected_response.clone());

    let (status, _headers, body) =
        post_preview(app, &jwt, provider, preview_request(provider, "products")).await;

    assert_eq!(status, StatusCode::OK, "{provider} preview body: {body}");
    assert_eq!(body, expected_response);
    let requests = flapjack_http.take_sensitive_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert!(
        requests[0]
            .url
            .ends_with(&format!("/1/migrations/{provider}/preview")),
        "preview must call the provider-specific engine route: {:?}",
        requests[0]
    );
}

fn assert_published_source_provider(provider: &str) {
    let spec = crate::common::openapi_spec_json();
    let published_providers = spec
        .pointer("/components/schemas/SourceImportProvider/enum")
        .and_then(serde_json::Value::as_array)
        .expect("SourceImportProvider must publish its closed provider enum");

    assert!(
        published_providers
            .iter()
            .any(|published| published.as_str() == Some(provider)),
        "{provider} must remain a recognized source provider: {published_providers:?}"
    );
}

async fn assert_preview_refuses_provider_without_engine_call(provider: &str) {
    let (app, jwt, flapjack_http) = setup_preview_app(true).await;

    let (status, _headers, body) =
        post_preview(app, &jwt, provider, preview_request(provider, "products")).await;

    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "{provider} preview body: {body}"
    );
    assert_eq!(
        body,
        json!({
            "error": "source_provider_unsupported",
            "code": AlgoliaImportErrorCode::SourceProviderUnsupported.as_str(),
        })
    );
    assert_preview_error_matches_published_schema(status, &body);
    assert_eq!(flapjack_http.request_count(), 0);
    assert!(flapjack_http.take_sensitive_requests().is_empty());
}

async fn assert_typesense_preview_forwards_engine_refusal() {
    let provider = "typesense";
    let (app, jwt, flapjack_http) = setup_preview_app(true).await;
    flapjack_http.expect_sensitive_json_body(&expected_preview_engine_body(provider, "products"));
    flapjack_http.push_sensitive_json_response(
        400,
        json!({
            "message": "Source provider is not supported",
            "code": "source_provider_unsupported",
        }),
    );

    let (status, _headers, body) =
        post_preview(app, &jwt, provider, preview_request(provider, "products")).await;

    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "Typesense preview body: {body}"
    );
    assert_eq!(
        body,
        json!({
            "error": "migration_preview_rejected",
            "code": AlgoliaImportErrorCode::IncompatibleData.as_str(),
        })
    );
    assert_preview_error_matches_published_schema(status, &body);
    let requests = flapjack_http.take_sensitive_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert!(
        requests[0].url.ends_with("/1/migrations/typesense/preview"),
        "Typesense preview must reach the engine capability authority: {:?}",
        requests[0]
    );
}

#[tokio::test]
async fn algolia_preview_preserves_engine_report() {
    assert_provider_preview_preserves_engine_report("algolia").await;
}

#[tokio::test]
async fn meilisearch_preview_preserves_engine_report() {
    assert_provider_preview_preserves_engine_report("meilisearch").await;
}

#[tokio::test]
async fn typesense_preview_asserts_current_engine_refusal() {
    // Current authority: engine/flapjack-http/src/handlers/migration/mod.rs:1038,2046-2051.
    // Producer lane flapjack_dev/chats/icg/aug02_5am_5_typesense_preview_and_settings_translation.md
    // legitimately flips this expectation when Typesense preview becomes supported.
    assert_published_source_provider("typesense");
    assert_typesense_preview_forwards_engine_refusal().await;
}

#[tokio::test]
async fn algolia_preview_does_not_create_import_job_row() {
    let db = connect_and_migrate_required("algolia_preview_stateless").await;
    let (app, jwt, flapjack_http) = setup_preview_app_with_pool(db.pool.clone()).await;
    let before_count = count_algolia_import_jobs(&db.pool).await;
    flapjack_http.expect_sensitive_json_body(&expected_preview_engine_body("algolia", "products"));
    flapjack_http.push_sensitive_json_response(200, preview_engine_response("algolia"));

    let (status, _headers, _body) =
        post_preview(app, &jwt, "algolia", preview_request("algolia", "products")).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        count_algolia_import_jobs(&db.pool).await,
        before_count,
        "preview must remain stateless and avoid algolia_import_jobs writes"
    );
}

#[tokio::test]
async fn unsupported_preview_provider_fails_closed_without_engine_call() {
    assert_preview_refuses_provider_without_engine_call("unsupported").await;
}

#[tokio::test]
async fn preview_is_gated_closed_when_migration_unavailable() {
    let (app, jwt, flapjack_http) = setup_preview_app(false).await;

    let (status, headers, body) =
        post_preview(app, &jwt, "algolia", preview_request("algolia", "products")).await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        headers
            .get("retry-after")
            .expect("disabled migration preview must include Retry-After")
            .to_str()
            .expect("Retry-After must be valid header text"),
        "30"
    );
    assert_eq!(
        body,
        json!({
            "error": AlgoliaImportErrorCode::BackendUnavailable.as_str(),
            "code": AlgoliaImportErrorCode::BackendUnavailable.as_str(),
        })
    );
    assert_preview_error_matches_published_schema(status, &body);
    assert_eq!(flapjack_http.request_count(), 0);
    assert!(flapjack_http.take_sensitive_requests().is_empty());
}

#[tokio::test]
async fn preview_returns_backend_unavailable_when_no_active_vm_exists() {
    let vm_inventory_repo = crate::common::mock_vm_inventory_repo();
    let (app, jwt, flapjack_http, _) =
        setup_preview_app_with_inventory(true, vm_inventory_repo).await;

    let (status, headers, body) =
        post_preview(app, &jwt, "algolia", preview_request("algolia", "products")).await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        headers
            .get("retry-after")
            .expect("preview without backend must include Retry-After")
            .to_str()
            .expect("Retry-After must be valid header text"),
        "30"
    );
    assert_eq!(
        body,
        json!({
            "error": AlgoliaImportErrorCode::BackendUnavailable.as_str(),
            "code": AlgoliaImportErrorCode::BackendUnavailable.as_str(),
        })
    );
    assert_preview_error_matches_published_schema(status, &body);
    assert_eq!(flapjack_http.request_count(), 0);
    assert!(flapjack_http.take_sensitive_requests().is_empty());
}

#[tokio::test]
async fn preview_inventory_read_failure_returns_coded_500_without_engine_call() {
    let vm_inventory_repo = crate::common::mock_vm_inventory_repo();
    seed_preview_vm(&vm_inventory_repo).await;
    let (app, jwt, flapjack_http, vm_inventory_repo) =
        setup_preview_app_with_inventory(true, vm_inventory_repo).await;
    vm_inventory_repo.set_should_fail(true);

    let (status, _headers, body) =
        post_preview(app, &jwt, "algolia", preview_request("algolia", "products")).await;

    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(
        body,
        json!({
            "error": "migration_preview_failed",
            "code": AlgoliaImportErrorCode::Internal.as_str(),
        })
    );
    assert_preview_error_matches_published_schema(status, &body);
    assert_eq!(flapjack_http.request_count(), 0);
    assert!(flapjack_http.take_sensitive_requests().is_empty());
}

#[tokio::test]
async fn preview_engine_rejection_redacts_reflected_credential() {
    let (app, jwt, flapjack_http) = setup_preview_app(true).await;
    flapjack_http.expect_sensitive_json_body(&expected_preview_engine_body("algolia", "products"));
    flapjack_http.push_sensitive_json_response(
        400,
        json!({"message": "rejected API key temporary-preview-key"}),
    );

    let (status, _headers, body) =
        post_preview(app, &jwt, "algolia", preview_request("algolia", "products")).await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body,
        json!({
            "error": "migration_preview_rejected",
            "code": AlgoliaImportErrorCode::IncompatibleData.as_str(),
        }),
        "engine-owned 4xx responses must not reflect source credentials"
    );
    assert_preview_error_matches_published_schema(status, &body);
}

#[tokio::test]
async fn preview_engine_not_found_stays_inside_the_published_bad_request_envelope() {
    let (app, jwt, flapjack_http) = setup_preview_app(true).await;
    flapjack_http.expect_sensitive_json_body(&expected_preview_engine_body("algolia", "products"));
    flapjack_http.push_sensitive_json_response(404, json!({"message": "source index missing"}));

    let (status, _headers, body) =
        post_preview(app, &jwt, "algolia", preview_request("algolia", "products")).await;

    // Preview owns no fjcloud resource, so an engine 404 is a rejected source
    // request rather than a missing fjcloud entity. It must not escape as an
    // undocumented 404.
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body,
        json!({
            "error": "migration_preview_rejected",
            "code": AlgoliaImportErrorCode::IncompatibleData.as_str(),
        })
    );
    assert_preview_error_matches_published_schema(status, &body);
}

#[tokio::test]
async fn preview_engine_conflict_stays_inside_the_published_bad_request_envelope() {
    let (app, jwt, flapjack_http) = setup_preview_app(true).await;
    flapjack_http.expect_sensitive_json_body(&expected_preview_engine_body("algolia", "products"));
    flapjack_http.push_sensitive_json_response(409, json!({"message": "source is locked"}));

    let (status, _headers, body) =
        post_preview(app, &jwt, "algolia", preview_request("algolia", "products")).await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body,
        json!({
            "error": "migration_preview_rejected",
            "code": AlgoliaImportErrorCode::IncompatibleData.as_str(),
        })
    );
    assert_preview_error_matches_published_schema(status, &body);
}

#[tokio::test]
async fn preview_engine_internal_failure_matches_published_error_schema() {
    let (app, jwt, flapjack_http) = setup_preview_app(true).await;
    flapjack_http.expect_sensitive_json_body(&expected_preview_engine_body("algolia", "products"));
    flapjack_http.push_sensitive_json_response(500, json!({"message": "engine failed"}));

    let (status, _headers, body) =
        post_preview(app, &jwt, "algolia", preview_request("algolia", "products")).await;

    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
    // The engine's own message stays out of both the response and application logs.
    assert_eq!(
        body,
        json!({
            "error": "migration_preview_failed",
            "code": AlgoliaImportErrorCode::Internal.as_str(),
        })
    );
    assert!(
        !body.to_string().contains("engine failed"),
        "preview 500 must not return the engine's internal diagnostic: {body}"
    );
    assert_preview_error_matches_published_schema(status, &body);
}
