use crate::common::indexes_route_test_support::response_json;
use crate::common::{create_test_jwt, mock_repo, TestStateBuilder};
use api::routes::migration::ListAlgoliaIndexesRequest;
use api::services::algolia_source::{
    AlgoliaIndexMetadata, AlgoliaSourceError, AlgoliaSourceListRequest, AlgoliaSourceListResponse,
    AlgoliaSourceLister,
};
use async_trait::async_trait;
use axum::body::Body;
use axum::http::{self, Request, StatusCode};
use chrono::{TimeZone, Utc};
use serde_json::json;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

use api::router::build_router;

async fn setup_authenticated_app() -> (axum::Router, String) {
    setup_authenticated_app_with_algolia_flag(false).await
}

async fn setup_authenticated_app_with_algolia_flag(
    algolia_migration_enabled: bool,
) -> (axum::Router, String) {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);
    let app = build_router(
        TestStateBuilder::new()
            .with_customer_repo(customer_repo)
            .with_algolia_migration_enabled(algolia_migration_enabled)
            .build(),
    );

    (app, jwt)
}

struct FakeAlgoliaSourceLister {
    responses: Mutex<VecDeque<Result<AlgoliaSourceListResponse, AlgoliaSourceError>>>,
    requests: Mutex<Vec<AlgoliaSourceListRequest>>,
}

impl FakeAlgoliaSourceLister {
    fn new(
        responses: impl IntoIterator<Item = Result<AlgoliaSourceListResponse, AlgoliaSourceError>>,
    ) -> Arc<Self> {
        Arc::new(Self {
            responses: Mutex::new(responses.into_iter().collect()),
            requests: Mutex::new(Vec::new()),
        })
    }

    fn requests(&self) -> Vec<AlgoliaSourceListRequest> {
        self.requests.lock().unwrap().clone()
    }
}

#[async_trait]
impl AlgoliaSourceLister for FakeAlgoliaSourceLister {
    async fn list_indexes(
        &self,
        request: AlgoliaSourceListRequest,
    ) -> Result<AlgoliaSourceListResponse, AlgoliaSourceError> {
        self.requests.lock().unwrap().push(request);
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("fake Algolia response configured")
    }
}

async fn setup_algolia_cloud_discovery_app(
    service: Arc<dyn AlgoliaSourceLister>,
) -> (axum::Router, String) {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);
    let app = build_router(
        TestStateBuilder::new()
            .with_customer_repo(customer_repo)
            .with_algolia_source_service(service)
            .build(),
    );
    (app, jwt)
}

fn discovery_response(next_cursor: Option<&str>) -> AlgoliaSourceListResponse {
    AlgoliaSourceListResponse {
        items: vec![AlgoliaIndexMetadata {
            name: "products".to_string(),
            entries: 42,
            data_size: 2048,
            file_size: 4096,
            updated_at: Utc.with_ymd_and_hms(2026, 7, 15, 12, 30, 0).unwrap(),
            last_build_time_s: 3,
            pending_task: false,
            primary: Some("products".to_string()),
            replicas: vec!["products_price_asc".to_string()],
        }],
        next_cursor: next_cursor.map(str::to_string),
    }
}

async fn post_discovery(
    app: axum::Router,
    jwt: Option<&str>,
    body: serde_json::Value,
) -> (StatusCode, serde_json::Value) {
    let mut request = Request::builder()
        .method(http::Method::POST)
        .uri("/migration/algolia/list-indexes")
        .header("content-type", "application/json");
    if let Some(jwt) = jwt {
        request = request.header("authorization", format!("Bearer {jwt}"));
    }
    let response = app
        .oneshot(request.body(Body::from(body.to_string())).unwrap())
        .await
        .unwrap();
    response_json(response).await
}

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
            "message": "Algolia migration is temporarily unavailable while we replace the importer."
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
            "message": "Algolia migration is temporarily unavailable while we replace the importer."
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

    for body in [
        json!({"appId": "TESTAPP123", "cursor": "opaque-next"}),
        json!({"appId": "TESTAPP123", "apiKey": "", "cursor": "opaque-next"}),
    ] {
        let service = FakeAlgoliaSourceLister::new([Ok(discovery_response(None))]);
        let (app, jwt) = setup_algolia_cloud_discovery_app(service.clone()).await;
        let (status, response) = post_discovery(app, Some(&jwt), body).await;
        assert!(
            matches!(
                status,
                StatusCode::UNPROCESSABLE_ENTITY | StatusCode::BAD_REQUEST
            ),
            "unexpected response: {response}"
        );
        assert!(service.requests().is_empty());
    }
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
        ),
        (
            AlgoliaSourceError::InvalidCredentials,
            StatusCode::BAD_REQUEST,
            "invalid_algolia_credentials",
        ),
        (
            AlgoliaSourceError::InvalidCursor,
            StatusCode::BAD_REQUEST,
            "invalid_algolia_discovery_cursor",
        ),
        (
            AlgoliaSourceError::SourceCatalogTooLarge,
            StatusCode::BAD_REQUEST,
            "source_catalog_too_large",
        ),
        (
            AlgoliaSourceError::TimedOut,
            StatusCode::SERVICE_UNAVAILABLE,
            "algolia_discovery_timed_out",
        ),
        (
            AlgoliaSourceError::Unavailable,
            StatusCode::SERVICE_UNAVAILABLE,
            "algolia_discovery_unavailable",
        ),
        (
            AlgoliaSourceError::InvalidUpstreamResponse,
            StatusCode::SERVICE_UNAVAILABLE,
            "algolia_discovery_unavailable",
        ),
        (
            AlgoliaSourceError::InvalidCursorKey,
            StatusCode::SERVICE_UNAVAILABLE,
            "algolia_discovery_unavailable",
        ),
    ];
    for (error, expected_status, expected_message) in cases {
        let service = FakeAlgoliaSourceLister::new([Err(error)]);
        let (app, jwt) = setup_algolia_cloud_discovery_app(service).await;
        let (status, body) = post_discovery(
            app,
            Some(&jwt),
            json!({"appId": "TESTAPP123", "apiKey": "do-not-echo-this-key"}),
        )
        .await;
        assert_eq!(status, expected_status);
        assert_eq!(body, json!({"error": expected_message}));
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
