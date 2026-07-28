use super::*;

#[tokio::test]
async fn algolia_availability_requires_auth() {
    let (app, _jwt) = setup_authenticated_app().await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/migration/algolia/availability")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _) = response_json(resp).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn algolia_availability_returns_typed_unavailable_payload() {
    let (app, jwt) = setup_authenticated_app().await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/migration/algolia/availability")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        body,
        json!({
            "available": false,
            "reason": "temporarily_unavailable",
            "message": "Algolia migration is temporarily unavailable while we replace the importer.",
            "capabilities": {
                "cancel": false,
                "resume": false,
                "replace": false
            }
        })
    );
}

/// The availability route is locally decidable: it depends only on API config
/// and code-owned engine support declarations, not on live external calls.
#[tokio::test]
async fn algolia_availability_flips_available_when_flag_enabled_and_engine_supports() {
    let (app, jwt) = setup_authenticated_app_with_algolia_flag(true).await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/migration/algolia/availability")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        body,
        json!({
            "available": true,
            "message": "Algolia migration is available.",
            "capabilities": {
                "cancel": true,
                "resume": false,
                "replace": true
            }
        })
    );
    assert!(body.get("reason").is_none());
}

#[tokio::test]
async fn algolia_cloud_discovery_list_indexes_requires_auth() {
    let service = FakeAlgoliaSourceLister::new([Ok(discovery_response(None))]);
    let (app, _) = setup_algolia_cloud_discovery_app(service.clone()).await;
    let (status, _) = post_discovery(
        app,
        None,
        json!({"appId": "TESTAPP123", "apiKey": "volatile-key"}),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert!(service.requests().is_empty());
}

#[tokio::test]
async fn list_indexes_is_gated_closed_when_migration_unavailable() {
    let service = FakeAlgoliaSourceLister::new([Ok(discovery_response(None))]);
    let (app, jwt) = setup_algolia_cloud_discovery_app_with_flag(service.clone(), false).await;

    let (status, body) = post_discovery(
        app,
        Some(&jwt),
        json!({"appId": "TESTAPP123", "apiKey": "volatile-key"}),
    )
    .await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        body,
        json!({
            "error": AlgoliaImportErrorCode::BackendUnavailable.as_str(),
            "code": AlgoliaImportErrorCode::BackendUnavailable.as_str(),
        })
    );
    assert!(service.requests().is_empty());
}

#[tokio::test]
async fn algolia_cloud_discovery_allows_zero_index_customer_without_deployment_lookup() {
    let service = FakeAlgoliaSourceLister::new([
        Ok(discovery_response(Some("opaque-next"))),
        Ok(discovery_response(None)),
    ]);
    let (app, jwt) = setup_algolia_cloud_discovery_app(service.clone()).await;

    let (first_status, first_body) = post_discovery(
        app.clone(),
        Some(&jwt),
        json!({"appId": "TESTAPP123", "apiKey": "volatile-key"}),
    )
    .await;
    assert_eq!(first_status, StatusCode::OK);
    assert_eq!(first_body["nextCursor"], "opaque-next");

    let (second_status, _) = post_discovery(
        app,
        Some(&jwt),
        json!({
            "appId": "TESTAPP123",
            "apiKey": "volatile-key",
            "cursor": "opaque-next"
        }),
    )
    .await;
    assert_eq!(second_status, StatusCode::OK);
    let requests = service.requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].cursor, None);
    assert_eq!(requests[1].cursor.as_deref(), Some("opaque-next"));
    assert_eq!(requests[1].api_key, "volatile-key");
}

#[tokio::test]
async fn algolia_cloud_discovery_forwards_probe_page_size_override() {
    let service = FakeAlgoliaSourceLister::new([Ok(discovery_response(Some("opaque-next")))]);
    let (app, jwt) = setup_algolia_cloud_discovery_app(service.clone()).await;

    let (status, _) = post_discovery(
        app,
        Some(&jwt),
        json!({
            "appId": "TESTAPP123",
            "apiKey": "volatile-key",
            "hitsPerPage": 1
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let requests = service.requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].hits_per_page, Some(1));
}

#[tokio::test]
async fn algolia_cloud_discovery_rejects_out_of_range_page_size_without_upstream_call() {
    for hits_per_page in [0, 101] {
        let service = FakeAlgoliaSourceLister::new([Ok(discovery_response(None))]);
        let (app, jwt) = setup_algolia_cloud_discovery_app(service.clone()).await;

        let (status, body) = post_discovery(
            app,
            Some(&jwt),
            json!({
                "appId": "TESTAPP123",
                "apiKey": "volatile-key",
                "hitsPerPage": hits_per_page
            }),
        )
        .await;

        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(
            body,
            json!({
                "error": "source_catalog_too_large",
                "code": AlgoliaImportErrorCode::SourceCatalogTooLarge.as_str(),
            })
        );
        assert!(service.requests().is_empty());
    }
}

#[tokio::test]
async fn algolia_cloud_discovery_requires_volatile_api_key_on_every_cursor_request() {
    let debug_request = format!(
        "{:?}",
        ListAlgoliaIndexesRequest {
            app_id: "TESTAPP123".to_string(),
            api_key: "do-not-log-this-key".to_string(),
            cursor: Some("opaque-next".to_string()),
            hits_per_page: None,
        }
    );
    assert!(debug_request.contains("app_id: \"[REDACTED]\""));
    assert!(debug_request.contains("api_key: \"[REDACTED]\""));
    assert!(!debug_request.contains("TESTAPP123"));
    assert!(!debug_request.contains("do-not-log-this-key"));

    let malformed_body = json!({"appId": "TESTAPP123", "cursor": "opaque-next"});
    let service = FakeAlgoliaSourceLister::new([Ok(discovery_response(None))]);
    let (app, jwt) = setup_algolia_cloud_discovery_app(service.clone()).await;
    let (status, response) = post_discovery(app, Some(&jwt), malformed_body).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert!(response.get("code").is_none());
    assert!(!response.to_string().contains("do-not-echo-this-key"));
    assert!(service.requests().is_empty());

    let service = FakeAlgoliaSourceLister::new([Ok(discovery_response(None))]);
    let (app, jwt) = setup_algolia_cloud_discovery_app(service.clone()).await;
    let (status, response) = post_discovery(
        app,
        Some(&jwt),
        json!({"appId": "TESTAPP123", "apiKey": "", "cursor": "opaque-next"}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        response,
        json!({
            "error": "invalid_algolia_credentials",
            "code": AlgoliaImportErrorCode::InvalidCredentials.as_str(),
        })
    );
    assert!(!response.to_string().contains("do-not-echo-this-key"));
    assert!(service.requests().is_empty());
}

fn assert_coded_discovery_error(
    body: &serde_json::Value,
    expected_message: &str,
    expected_code: AlgoliaImportErrorCode,
) {
    assert_eq!(
        body,
        &json!({
            "error": expected_message,
            "code": expected_code.as_str(),
        })
    );
}

#[tokio::test]
async fn algolia_cloud_discovery_empty_key_returns_typed_invalid_credentials() {
    let service = FakeAlgoliaSourceLister::new([Ok(discovery_response(None))]);
    let (app, jwt) = setup_algolia_cloud_discovery_app(service.clone()).await;
    let (status, body) = post_discovery(
        app,
        Some(&jwt),
        json!({"appId": "TESTAPP123", "apiKey": ""}),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_coded_discovery_error(
        &body,
        "invalid_algolia_credentials",
        AlgoliaImportErrorCode::InvalidCredentials,
    );
    assert!(!body.to_string().contains("do-not-echo-this-key"));
    assert!(service.requests().is_empty());
}

#[tokio::test]
async fn algolia_cloud_discovery_returns_display_only_metadata_semantics() {
    let service = FakeAlgoliaSourceLister::new([Ok(discovery_response(None))]);
    let (app, jwt) = setup_algolia_cloud_discovery_app(service).await;
    let (status, body) = post_discovery(
        app,
        Some(&jwt),
        json!({"appId": "TESTAPP123", "apiKey": "volatile-key"}),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        body,
        json!({
            "items": [{
                "name": "products",
                "entries": 42,
                "dataSize": 2048,
                "fileSize": 4096,
                "updatedAt": "2026-07-15T12:30:00Z",
                "lastBuildTimeS": 3,
                "pendingTask": false,
                "primary": "products",
                "replicas": ["products_price_asc"]
            }],
            "nextCursor": null
        })
    );
}

#[tokio::test]
async fn algolia_cloud_discovery_maps_service_errors_without_echoing_api_key() {
    let cases = [
        (
            AlgoliaSourceError::InvalidApplicationId,
            StatusCode::BAD_REQUEST,
            "invalid_algolia_application_id",
            AlgoliaImportErrorCode::SourceNotFound,
        ),
        (
            AlgoliaSourceError::InvalidCredentials,
            StatusCode::BAD_REQUEST,
            "invalid_algolia_credentials",
            AlgoliaImportErrorCode::InvalidCredentials,
        ),
        (
            AlgoliaSourceError::InvalidCursor,
            StatusCode::BAD_REQUEST,
            "invalid_algolia_discovery_cursor",
            AlgoliaImportErrorCode::SourceChanged,
        ),
        (
            AlgoliaSourceError::SourceCatalogTooLarge,
            StatusCode::BAD_REQUEST,
            "source_catalog_too_large",
            AlgoliaImportErrorCode::SourceCatalogTooLarge,
        ),
        (
            AlgoliaSourceError::TimedOut,
            StatusCode::SERVICE_UNAVAILABLE,
            "algolia_discovery_timed_out",
            AlgoliaImportErrorCode::BackendUnavailable,
        ),
        (
            AlgoliaSourceError::Unavailable,
            StatusCode::SERVICE_UNAVAILABLE,
            "algolia_discovery_unavailable",
            AlgoliaImportErrorCode::BackendUnavailable,
        ),
        (
            AlgoliaSourceError::InvalidUpstreamResponse,
            StatusCode::SERVICE_UNAVAILABLE,
            "algolia_discovery_unavailable",
            AlgoliaImportErrorCode::BackendUnavailable,
        ),
        (
            AlgoliaSourceError::InvalidCursorKey,
            StatusCode::SERVICE_UNAVAILABLE,
            "algolia_discovery_unavailable",
            AlgoliaImportErrorCode::BackendUnavailable,
        ),
    ];
    for (error, expected_status, expected_message, expected_code) in cases {
        let service = FakeAlgoliaSourceLister::new([Err(error)]);
        let (app, jwt) = setup_algolia_cloud_discovery_app(service).await;
        let (status, body) = post_discovery(
            app,
            Some(&jwt),
            json!({"appId": "TESTAPP123", "apiKey": "do-not-echo-this-key"}),
        )
        .await;
        assert_eq!(status, expected_status);
        assert_coded_discovery_error(&body, expected_message, expected_code);
        assert!(!body.to_string().contains("do-not-echo-this-key"));
    }
}

#[tokio::test]
async fn algolia_cloud_discovery_acl_error_explains_discovery_and_migration_permissions() {
    let service = FakeAlgoliaSourceLister::new([Err(AlgoliaSourceError::ListIndexesAclRequired)]);
    let (app, jwt) = setup_algolia_cloud_discovery_app(service).await;
    let (status, body) = post_discovery(
        app,
        Some(&jwt),
        json!({"appId": "TESTAPP123", "apiKey": "do-not-echo-this-key"}),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_coded_discovery_error(
        &body,
        api::routes::migration::ALGOLIA_ACL_GUIDANCE,
        AlgoliaImportErrorCode::MissingSourcePermission,
    );
    let guidance = body["error"].as_str().unwrap();
    assert!(guidance.contains("listIndexes"));
    assert!(guidance.contains("settings"));
    assert!(guidance.contains("browse"));
    assert!(guidance.contains("seeUnretrievableAttributes"));
    assert!(!guidance.contains("do-not-echo-this-key"));
}

#[tokio::test]
async fn algolia_cloud_discovery_migrate_route_remains_unregistered() {
    let (app, jwt) = setup_authenticated_app().await;
    let response = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/algolia/migrate")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn algolia_cloud_job_routes_are_mounted_but_admission_stays_disabled_before_activation() {
    let (app, jwt) = setup_authenticated_app().await;
    let job_id = "01890f4f-a0b1-7298-9f0b-7e6fdf45d111";
    let mounted_cases = [
        (
            http::Method::POST,
            "/migration/algolia/destination-eligibility".to_string(),
        ),
        (http::Method::POST, "/migration/algolia/jobs".to_string()),
        (http::Method::GET, "/migration/algolia/jobs".to_string()),
        (
            http::Method::GET,
            format!("/migration/algolia/jobs/{job_id}"),
        ),
        (
            http::Method::POST,
            format!("/migration/algolia/jobs/{job_id}/cancel"),
        ),
        (
            http::Method::POST,
            format!("/migration/algolia/jobs/{job_id}/resume"),
        ),
    ];

    for (method, uri) in mounted_cases {
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(uri)
                    .header("content-type", "application/json")
                    .body(Body::from("{}"))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    let disabled_admission_cases = [
        (
            http::Method::POST,
            "/migration/algolia/destination-eligibility",
            json!({
                "phase": "provider",
                "mode": "create",
                "target": {
                    "region": "us-east-1",
                    "name": "products"
                }
            }),
        ),
        (
            http::Method::POST,
            "/migration/algolia/jobs",
            json!({
                "mode": "create",
                "appId": "APP123",
                "apiKey": "key",
                "sourceName": "products",
                "target": {
                    "eligibilityToken": "token"
                }
            }),
        ),
        (
            http::Method::POST,
            &format!("/migration/algolia/jobs/{job_id}/resume"),
            json!({
                "apiKey": "key"
            }),
        ),
    ];

    for (method, uri, body) in disabled_admission_cases {
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(uri)
                    .header("authorization", format!("Bearer {jwt}"))
                    .header("content-type", "application/json")
                    .body(Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    }
}

fn migration_route_registration<'a>(source: &'a str, path: &str) -> Option<&'a str> {
    let quoted_path = format!("\"{path}\"");
    let path_start = source.find(&quoted_path)?;
    let route_start = source[..path_start].rfind(".route(")?;
    let after_path = path_start + quoted_path.len();
    let route_end = source[after_path..]
        .find(".route(")
        .map(|offset| after_path + offset)
        .unwrap_or(source.len());
    Some(&source[route_start..route_end])
}

fn migration_handler_owners(registration: &str) -> Vec<&str> {
    registration
        .split(|character: char| {
            !(character.is_ascii_alphanumeric() || character == '_' || character == ':')
        })
        .filter(|token| token.starts_with("migration::"))
        .collect()
}

#[test]
fn legacy_algolia_routes_share_parameterized_neutral_handler_owners() {
    const ROUTE_OWNER: &str = include_str!("../../../src/router/route_assembly.rs");
    const MIGRATION_ROOT: &str = include_str!("../../../src/routes/migration.rs");
    const CAPABILITIES_OWNER: &str = include_str!("../../../src/routes/migration/capabilities.rs");
    const ELIGIBILITY_OWNER: &str = include_str!("../../../src/routes/migration/eligibility.rs");
    const JOBS_OWNER: &str = include_str!("../../../src/routes/migration/jobs.rs");
    const SOURCE_OWNER: &str = include_str!("../../../src/routes/migration/source.rs");

    let route_aliases = [
        (
            "/migration/algolia/availability",
            "/migration/:source_provider/availability",
        ),
        (
            "/migration/algolia/list-indexes",
            "/migration/:source_provider/list-indexes",
        ),
        (
            "/migration/algolia/destination-eligibility",
            "/migration/:source_provider/destination-eligibility",
        ),
        (
            "/migration/algolia/jobs",
            "/migration/:source_provider/jobs",
        ),
        (
            "/migration/algolia/jobs/:id",
            "/migration/:source_provider/jobs/:id",
        ),
        (
            "/migration/algolia/jobs/:id/cancel",
            "/migration/:source_provider/jobs/:id/cancel",
        ),
        (
            "/migration/algolia/jobs/:id/resume",
            "/migration/:source_provider/jobs/:id/resume",
        ),
    ];

    for (legacy_path, parameterized_path) in route_aliases {
        let legacy_registration = migration_route_registration(ROUTE_OWNER, legacy_path)
            .unwrap_or_else(|| panic!("legacy migration route {legacy_path} is not registered"));
        let parameterized_registration =
            migration_route_registration(ROUTE_OWNER, parameterized_path).unwrap_or_else(|| {
                panic!(
                    "parameterized migration route {parameterized_path} is missing; \
                     source_provider must be routed through the same neutral owner as {legacy_path}"
                )
            });
        let legacy_handlers = migration_handler_owners(legacy_registration);
        let parameterized_handlers = migration_handler_owners(parameterized_registration);
        assert!(
            !legacy_handlers.is_empty(),
            "legacy migration route {legacy_path} must have a handler owner"
        );
        assert_eq!(
            legacy_handlers, parameterized_handlers,
            "legacy route {legacy_path} and parameterized route {parameterized_path} \
             must invoke the same neutral handler owner"
        );
    }

    for algolia_only_handler in [
        "migration::algolia_availability",
        "migration::list_algolia_indexes",
        "migration::check_algolia_destination_eligibility",
        "migration::create_algolia_import_job",
        "migration::list_algolia_import_jobs",
        "migration::get_algolia_import_job",
        "migration::cancel_algolia_import_job",
        "migration::resume_algolia_import_job",
    ] {
        assert!(
            !ROUTE_OWNER.contains(algolia_only_handler),
            "legacy aliases must not retain Algolia-only handler owner {algolia_only_handler}"
        );
    }

    let migration_handler_modules = [
        MIGRATION_ROOT,
        CAPABILITIES_OWNER,
        ELIGIBILITY_OWNER,
        JOBS_OWNER,
        SOURCE_OWNER,
    ]
    .join("\n");
    assert!(
        !migration_handler_modules.contains("PgAlgoliaImportJobRepo::new"),
        "legacy alias handlers must not construct a private Algolia lifecycle repository"
    );
}

fn assert_schema_exists(spec: &serde_json::Value, schema: &str) {
    assert!(
        spec.pointer(&format!("/components/schemas/{schema}"))
            .is_some(),
        "served contract must register schema {schema}"
    );
}

fn assert_schema_property_absent(spec: &serde_json::Value, schema: &str, property: &str) {
    assert_schema_exists(spec, schema);
    assert!(
        spec.pointer(&format!(
            "/components/schemas/{schema}/properties/{property}"
        ))
        .is_none(),
        "served {schema} schema must not expose sensitive property {property}"
    );
}

fn assert_schema_property_exists(spec: &serde_json::Value, schema: &str, property: &str) {
    assert_schema_exists(spec, schema);
    assert!(
        spec.pointer(&format!(
            "/components/schemas/{schema}/properties/{property}"
        ))
        .is_some(),
        "served {schema} schema must expose property {property}"
    );
}

/// The eligibility/create/list/get operations must be registered in the served
/// `ApiDoc` with their full schema cascade and privacy-sensitive fields absent.
#[test]
fn algolia_cloud_job_contract_is_served_with_schema_and_privacy_guards() {
    use utoipa::OpenApi;

    let served = serde_json::to_value(api::openapi::ApiDoc::openapi())
        .expect("served ApiDoc must serialize");

    let served_ops = [
        ("/migration/algolia/destination-eligibility", "post"),
        ("/migration/algolia/jobs", "post"),
        ("/migration/algolia/jobs", "get"),
        ("/migration/algolia/jobs/{id}", "get"),
        ("/migration/algolia/jobs/{id}/cancel", "post"),
        ("/migration/algolia/jobs/{id}/resume", "post"),
    ];
    assert_eq!(served_ops.len(), 6);
    for (path, method) in served_ops {
        let pointer = format!("/paths/{}/{method}", path.replace('/', "~1"));
        assert!(
            served.pointer(&pointer).is_some(),
            "served contract must document {method} {path}"
        );
    }

    // Every schema in the DTO cascade must resolve, proving the ToSchema derives
    // reach the domain enums the public job body embeds.
    for schema in [
        "AlgoliaDestinationEligibilityRequest",
        "AlgoliaDestinationEligibilityResponse",
        "CreateAlgoliaImportJobRequest",
        "CancelAlgoliaImportJobRequest",
        "ResumeAlgoliaImportJobRequest",
        "PublicAlgoliaImportJob",
        "PublicAlgoliaImportJobPage",
        "AlgoliaImportJobStatus",
        "AlgoliaImportSummary",
        "AlgoliaImportWarning",
        "AlgoliaImportDestinationKind",
        "AlgoliaImportErrorCode",
    ] {
        assert_schema_exists(&served, schema);
    }
    assert_schema_property_exists(&served, "PublicAlgoliaImportJob", "terminalOutcomeObserved");
    assert_schema_property_exists(&served, "PublicAlgoliaImportJob", "warnings");
    assert_schema_property_absent(&served, "PublicAlgoliaImportJob", "resumeCheckpoint");
    assert_schema_property_absent(&served, "PublicAlgoliaImportSource", "appId");
    assert_schema_property_absent(&served, "PublicAlgoliaImportError", "message");
}
