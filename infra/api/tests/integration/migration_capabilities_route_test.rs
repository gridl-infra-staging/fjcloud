use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tower::ServiceExt;

async fn response_json(response: axum::response::Response) -> (StatusCode, Value) {
    let status = response.status();
    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("availability response body")
        .to_bytes();
    let body = serde_json::from_slice(&bytes).expect("availability response JSON");
    (status, body)
}

fn availability_request(source_provider: &str, jwt: &str) -> Request<Body> {
    Request::builder()
        .uri(format!("/migration/{source_provider}/availability"))
        .header("authorization", format!("Bearer {jwt}"))
        .body(Body::empty())
        .expect("availability request")
}

fn availability_app() -> (axum::Router, String) {
    let customer_repo = crate::common::mock_repo();
    let customer =
        customer_repo.seed_verified_free_customer("Preview Customer", "preview@example.com");
    let state = crate::common::TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_algolia_migration_enabled(true)
        .build();
    (
        api::router::build_router(state),
        crate::common::create_test_jwt(customer.id),
    )
}

#[tokio::test]
async fn migration_availability_serves_provider_preview_capabilities() {
    let (app, jwt) = availability_app();

    for (source_provider, expected_preview, expected_verify) in [
        ("algolia", true, true),
        ("meilisearch", true, false),
        ("typesense", false, false),
    ] {
        let response = app
            .clone()
            .oneshot(availability_request(source_provider, &jwt))
            .await
            .expect("availability response");
        let (status, body) = response_json(response).await;

        assert_eq!(status, StatusCode::OK, "{source_provider} availability");
        assert_eq!(
            body,
            json!({
                "available": true,
                "message": "Algolia migration is available.",
                "capabilities": {
                    "cancel": true,
                    "preview": expected_preview,
                    "resume": false,
                    "replace": true,
                    "verify": expected_verify
                }
            }),
            "{source_provider} must publish its exact capability contract"
        );
    }
}

#[tokio::test]
async fn migration_availability_rejects_unsupported_provider() {
    let (app, jwt) = availability_app();

    let response = app
        .oneshot(availability_request("unsupported", &jwt))
        .await
        .expect("unsupported provider response");
    let (status, body) = response_json(response).await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body,
        json!({
            "error": "source_provider_unsupported",
            "code": "source_provider_unsupported"
        })
    );
}
