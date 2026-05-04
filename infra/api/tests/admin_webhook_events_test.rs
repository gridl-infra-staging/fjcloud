mod common;

use std::sync::Arc;

use api::repos::webhook_event_repo::WebhookEventRow;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::Utc;
use http_body_util::BodyExt;
use tower::ServiceExt;

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

fn app_with_webhook_repo(webhook_event_repo: Arc<common::MockWebhookEventRepo>) -> axum::Router {
    common::TestStateBuilder::new()
        .with_webhook_event_repo(webhook_event_repo)
        .build_app()
}

#[tokio::test]
async fn admin_webhook_events_requires_admin_auth() {
    let webhook_event_repo = common::mock_webhook_event_repo();
    let app = app_with_webhook_repo(webhook_event_repo);

    let req = Request::builder()
        .uri("/admin/webhook-events?stripe_event_id=evt_test_auth")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn admin_webhook_events_returns_seeded_row() {
    let webhook_event_repo = common::mock_webhook_event_repo();
    let seeded_row = WebhookEventRow {
        stripe_event_id: "evt_test_lookup".to_string(),
        event_type: "invoice.payment_succeeded".to_string(),
        payload: serde_json::json!({
            "id": "evt_test_lookup",
            "object": "event",
            "data": { "object": { "id": "in_test_lookup" } }
        }),
        processed_at: Some(Utc::now()),
        created_at: Utc::now(),
    };
    webhook_event_repo.seed_row(seeded_row.clone());

    let app = app_with_webhook_repo(webhook_event_repo);

    let req = Request::builder()
        .uri("/admin/webhook-events?stripe_event_id=evt_test_lookup")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    assert_eq!(json, serde_json::to_value(&seeded_row).unwrap());
}

#[tokio::test]
async fn admin_webhook_events_returns_404_for_unknown_event_id() {
    let webhook_event_repo = common::mock_webhook_event_repo();
    let app = app_with_webhook_repo(webhook_event_repo);

    let req = Request::builder()
        .uri("/admin/webhook-events?stripe_event_id=evt_test_missing")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    let json = body_json(resp).await;
    assert_eq!(
        json,
        serde_json::json!({ "error": "webhook event not found" })
    );
}

#[tokio::test]
async fn admin_webhook_events_returns_400_for_missing_or_blank_stripe_event_id() {
    let webhook_event_repo = common::mock_webhook_event_repo();
    let app = app_with_webhook_repo(webhook_event_repo);

    let missing_param_req = Request::builder()
        .uri("/admin/webhook-events")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();
    let missing_param_resp = app.clone().oneshot(missing_param_req).await.unwrap();
    assert_eq!(missing_param_resp.status(), StatusCode::BAD_REQUEST);
    assert_eq!(
        body_json(missing_param_resp).await,
        serde_json::json!({ "error": "stripe_event_id query parameter is required" })
    );

    let blank_param_req = Request::builder()
        .uri("/admin/webhook-events?stripe_event_id=")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();
    let blank_param_resp = app.oneshot(blank_param_req).await.unwrap();
    assert_eq!(blank_param_resp.status(), StatusCode::BAD_REQUEST);
    assert_eq!(
        body_json(blank_param_resp).await,
        serde_json::json!({ "error": "stripe_event_id query parameter is required" })
    );
}
