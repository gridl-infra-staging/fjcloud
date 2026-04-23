mod common;

use axum::body::Body;
use axum::http::{self, Request, StatusCode};
use common::{create_test_jwt, mock_deployment_repo, mock_repo, test_app_with_repos};
use serde_json::json;
use tower::ServiceExt;
use uuid::Uuid;

async fn setup() -> (axum::Router, String, Uuid) {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let customer = customer_repo.seed("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);
    let app = test_app_with_repos(customer_repo, deployment_repo);
    (app, jwt, Uuid::new_v4())
}

#[tokio::test]
async fn post_deployments_returns_404() {
    let (app, jwt, _) = setup().await;
    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/deployments")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({
                        "region": "us-east-1",
                        "vm_type": "t4g.small"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn all_removed_customer_deployment_routes_return_404() {
    let (app, jwt, deployment_id) = setup().await;
    let requests = vec![
        (
            http::Method::GET,
            "/deployments".to_string(),
            Body::empty(),
            None,
        ),
        (
            http::Method::GET,
            format!("/deployments/{deployment_id}"),
            Body::empty(),
            None,
        ),
        (
            http::Method::DELETE,
            format!("/deployments/{deployment_id}"),
            Body::from(json!({"confirm": true}).to_string()),
            Some("application/json"),
        ),
        (
            http::Method::POST,
            format!("/deployments/{deployment_id}/stop"),
            Body::empty(),
            None,
        ),
        (
            http::Method::POST,
            format!("/deployments/{deployment_id}/start"),
            Body::empty(),
            None,
        ),
    ];

    for (method, uri, body, content_type) in requests {
        let label = format!("{method} {uri}");
        let mut req = Request::builder()
            .method(method)
            .uri(&uri)
            .header("authorization", format!("Bearer {jwt}"));
        if let Some(ct) = content_type {
            req = req.header("content-type", ct);
        }

        let resp = app.clone().oneshot(req.body(body).unwrap()).await.unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::NOT_FOUND,
            "{label} should be removed and return 404"
        );
    }
}
