mod common;

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use api::services::alerting::{Alert, AlertService, AlertSeverity, MockAlertService};
use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use tower::ServiceExt;

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

fn app_with_alert_service(alert_service: Arc<dyn AlertService>) -> axum::Router {
    let mut state = common::test_state();
    state.alert_service = alert_service;
    api::router::build_router(state)
}

#[tokio::test]
async fn admin_alerts_returns_recent_alerts_in_desc_order_with_limit() {
    let alert_service = Arc::new(MockAlertService::new());

    for (title, severity) in [
        ("First alert", AlertSeverity::Info),
        ("Second alert", AlertSeverity::Warning),
        ("Third alert", AlertSeverity::Critical),
    ] {
        alert_service
            .send_alert(Alert {
                severity,
                title: title.to_string(),
                message: format!("{title} message"),
                metadata: HashMap::new(),
            })
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    let app = app_with_alert_service(Arc::clone(&alert_service) as Arc<dyn AlertService>);

    let req = Request::builder()
        .uri("/admin/alerts?limit=2")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let alerts = json.as_array().expect("response should be an array");
    assert_eq!(alerts.len(), 2);
    assert_eq!(alerts[0]["title"], "Third alert");
    assert_eq!(alerts[1]["title"], "Second alert");
}

#[tokio::test]
async fn admin_alerts_severity_filter_returns_only_matching_alerts() {
    let alert_service = Arc::new(MockAlertService::new());

    for (title, severity) in [
        ("Informational alert", AlertSeverity::Info),
        ("Warning alert", AlertSeverity::Warning),
        ("Critical alert", AlertSeverity::Critical),
    ] {
        alert_service
            .send_alert(Alert {
                severity,
                title: title.to_string(),
                message: format!("{title} message"),
                metadata: HashMap::new(),
            })
            .await
            .unwrap();
    }

    let app = app_with_alert_service(Arc::clone(&alert_service) as Arc<dyn AlertService>);

    let req = Request::builder()
        .uri("/admin/alerts?severity=critical")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let alerts = json.as_array().expect("response should be an array");
    assert_eq!(alerts.len(), 1);
    assert_eq!(alerts[0]["title"], "Critical alert");
    assert_eq!(alerts[0]["severity"], "critical");
}
