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

#[tokio::test]
async fn algolia_availability_stays_unavailable_when_flag_is_enabled() {
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

/// The future eligibility/create/list/get operations must have complete utoipa
/// contracts that resolve their full schema cascade — but only in a test-only
/// generated document. F11 owns wiring them into the served `ApiDoc`, so the
/// same operations must stay absent from `api::openapi::ApiDoc` until then.
#[test]
fn algolia_cloud_job_future_contract_is_generated_but_stays_unserved() {
    use utoipa::OpenApi;

    #[derive(OpenApi)]
    #[openapi(paths(
        api::routes::migration::check_algolia_destination_eligibility,
        api::routes::migration::create_algolia_import_job,
        api::routes::migration::list_algolia_import_jobs,
        api::routes::migration::get_algolia_import_job,
        api::routes::migration::cancel_algolia_import_job,
        api::routes::migration::resume_algolia_import_job,
    ))]
    struct FutureMigrationApiDoc;

    let generated = serde_json::to_value(FutureMigrationApiDoc::openapi())
        .expect("test-only migration contract must serialize");
    let served = serde_json::to_value(api::openapi::ApiDoc::openapi())
        .expect("served ApiDoc must serialize");

    let future_ops = [
        ("/migration/algolia/destination-eligibility", "post"),
        ("/migration/algolia/jobs", "post"),
        ("/migration/algolia/jobs", "get"),
        ("/migration/algolia/jobs/{id}", "get"),
        ("/migration/algolia/jobs/{id}/cancel", "post"),
        ("/migration/algolia/jobs/{id}/resume", "post"),
    ];
    for (path, method) in future_ops {
        let pointer = format!("/paths/{}/{method}", path.replace('/', "~1"));
        assert!(
            generated.pointer(&pointer).is_some(),
            "test-only generated contract must document {method} {path}"
        );
        assert!(
            served.pointer(&pointer).is_none(),
            "{method} {path} must stay absent from the served ApiDoc until F11 activation"
        );
    }

    // Every schema in the DTO cascade must resolve, proving the ToSchema derives
    // reach the F3 domain enums the public job body embeds.
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
        "AlgoliaImportDestinationKind",
        "AlgoliaImportErrorCode",
    ] {
        assert!(
            generated
                .pointer(&format!("/components/schemas/{schema}"))
                .is_some(),
            "generated contract must register schema {schema}"
        );
    }
    assert!(
        generated
            .pointer("/components/schemas/PublicAlgoliaImportJob/properties/resumeCheckpoint")
            .is_none(),
        "public migration jobs must not expose the internal engine resume checkpoint"
    );
    assert!(
        generated
            .pointer("/components/schemas/PublicAlgoliaImportJob/properties/warnings")
            .is_none(),
        "public migration jobs must not expose raw warning payloads"
    );
    assert!(
        generated
            .pointer("/components/schemas/PublicAlgoliaImportSource/properties/appId")
            .is_none(),
        "public migration source must not expose Algolia App ID"
    );
    assert!(
        generated
            .pointer("/components/schemas/PublicAlgoliaImportError/properties/message")
            .is_none(),
        "public migration errors must not expose producer error messages"
    );
}
