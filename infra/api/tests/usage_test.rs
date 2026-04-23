mod common;

use api::repos::CustomerRepo;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{NaiveDate, Utc};
use http_body_util::BodyExt;
use tower::ServiceExt;
use uuid::Uuid;

use common::{
    create_test_jwt, mock_deployment_repo, mock_rate_card_repo, mock_repo, mock_usage_repo,
    test_app_full, TEST_ADMIN_KEY,
};

// ---------------------------------------------------------------------------
// Tenant: GET /usage
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_usage_200_aggregated_totals() {
    let customer_repo = mock_repo();
    let usage_repo = mock_usage_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    // Seed two days of data in us-east-1
    usage_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        "us-east-1",
        1000,
        100,
        billing::types::BYTES_PER_GIB, // 1 GB
        5000,
    );
    usage_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 2, 2).unwrap(),
        "us-east-1",
        2000,
        200,
        billing::types::BYTES_PER_GIB * 3, // 3 GB
        7000,
    );

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        mock_rate_card_repo(),
    );
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::get("/usage?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();

    assert_eq!(body["month"], "2026-02");
    assert_eq!(body["total_search_requests"], 3000);
    assert_eq!(body["total_write_operations"], 300);
    // avg storage: (1GB + 3GB) / 2 days = 2.0 GB
    let avg_gb = body["avg_storage_gb"].as_f64().unwrap();
    assert!((avg_gb - 2.0).abs() < 0.001, "expected ~2.0, got {avg_gb}");
    assert_eq!(body["avg_document_count"], 6000);
    assert_eq!(body["by_region"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn get_usage_200_empty_month() {
    let customer_repo = mock_repo();
    let usage_repo = mock_usage_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        mock_rate_card_repo(),
    );
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::get("/usage?month=2026-03")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();

    assert_eq!(body["month"], "2026-03");
    assert_eq!(body["total_search_requests"], 0);
    assert_eq!(body["total_write_operations"], 0);
    assert_eq!(body["avg_storage_gb"], 0.0);
    assert_eq!(body["avg_document_count"], 0);
    assert!(body["by_region"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn get_usage_200_by_region_breakdown() {
    let customer_repo = mock_repo();
    let usage_repo = mock_usage_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    // Seed data in 2 regions on the same day
    usage_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        "us-east-1",
        1000,
        100,
        billing::types::BYTES_PER_GIB,
        4000,
    );
    usage_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        "eu-west-1",
        500,
        50,
        billing::types::BYTES_PER_GIB * 2,
        6000,
    );

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        mock_rate_card_repo(),
    );
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::get("/usage?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();

    let regions = body["by_region"].as_array().unwrap();
    assert_eq!(regions.len(), 2);
    // Alphabetically sorted: eu-west-1 before us-east-1
    assert_eq!(regions[0]["region"], "eu-west-1");
    assert_eq!(regions[0]["search_requests"], 500);
    assert_eq!(regions[1]["region"], "us-east-1");
    assert_eq!(regions[1]["search_requests"], 1000);

    // Cross-region totals: day 1 total storage = 1GB + 2GB = 3GB, 1 unique day → 3.0 GB
    let avg_gb = body["avg_storage_gb"].as_f64().unwrap();
    assert!((avg_gb - 3.0).abs() < 0.001, "expected ~3.0, got {avg_gb}");
}

#[tokio::test]
async fn get_usage_200_default_month() {
    let customer_repo = mock_repo();
    let usage_repo = mock_usage_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        mock_rate_card_repo(),
    );
    let jwt = create_test_jwt(customer.id);

    // No month param — defaults to current month
    let resp = app
        .oneshot(
            Request::get("/usage")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();

    // Should have a valid month string in YYYY-MM format
    let month = body["month"].as_str().unwrap();
    assert_eq!(month.len(), 7);
    assert!(month.contains('-'));
}

#[tokio::test]
async fn get_usage_400_invalid_month_format() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
    );
    let jwt = create_test_jwt(customer.id);

    // Invalid month: 13 is not a valid month
    let resp = app
        .oneshot(
            Request::get("/usage?month=2026-13")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn get_usage_400_garbage_month() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
    );
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::get("/usage?month=bad")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn get_usage_401_missing_auth() {
    let app = test_app_full(
        mock_repo(),
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
    );

    let resp = app
        .oneshot(
            Request::get("/usage?month=2026-02")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

// ---------------------------------------------------------------------------
// Admin: GET /admin/tenants/:id/usage
// ---------------------------------------------------------------------------

#[tokio::test]
async fn admin_get_usage_200() {
    let customer_repo = mock_repo();
    let usage_repo = mock_usage_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    usage_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        "us-east-1",
        5000,
        500,
        billing::types::BYTES_PER_GIB * 2,
        10000,
    );

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        mock_rate_card_repo(),
    );

    let resp = app
        .oneshot(
            Request::get(format!(
                "/admin/tenants/{}/usage?month=2026-02",
                customer.id
            ))
            .header("x-admin-key", TEST_ADMIN_KEY)
            .body(Body::empty())
            .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();

    assert_eq!(body["total_search_requests"], 5000);
    assert_eq!(body["total_write_operations"], 500);
}

#[tokio::test]
async fn admin_get_usage_404_unknown_tenant() {
    let app = test_app_full(
        mock_repo(),
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
    );

    let resp = app
        .oneshot(
            Request::get(format!(
                "/admin/tenants/{}/usage?month=2026-02",
                uuid::Uuid::new_v4()
            ))
            .header("x-admin-key", TEST_ADMIN_KEY)
            .body(Body::empty())
            .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn admin_get_usage_401_missing_auth() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
    );

    let resp = app
        .oneshot(
            Request::get(format!(
                "/admin/tenants/{}/usage?month=2026-02",
                customer.id
            ))
            .body(Body::empty())
            .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

// ---------------------------------------------------------------------------
// MT-01: Tenant usage isolation — tenant B cannot see tenant A's data
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_usage_200_tenant_isolation() {
    let customer_repo = mock_repo();
    let usage_repo = mock_usage_repo();
    let tenant_a = customer_repo.seed("Tenant A", "a@example.com");
    let tenant_b = customer_repo.seed("Tenant B", "b@example.com");

    // Seed usage only for tenant A
    usage_repo.seed(
        tenant_a.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        "us-east-1",
        9999,
        999,
        billing::types::BYTES_PER_GIB,
        5000,
    );

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        mock_rate_card_repo(),
    );

    // Tenant B makes the request — must see only their own (empty) data
    let jwt = create_test_jwt(tenant_b.id);
    let resp = app
        .oneshot(
            Request::get("/usage?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(
        body["total_search_requests"], 0,
        "tenant B must not see tenant A's usage"
    );
    assert_eq!(body["total_write_operations"], 0);
    assert!(body["by_region"].as_array().unwrap().is_empty());
}

// ---------------------------------------------------------------------------
// MT-05: Admin usage 404 for deleted tenant
// ---------------------------------------------------------------------------

#[tokio::test]
async fn admin_get_usage_404_deleted_tenant() {
    let customer_repo = mock_repo();
    let deleted = customer_repo.seed_deleted("Gone Corp", "gone@example.com");

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
    );

    let resp = app
        .oneshot(
            Request::get(format!("/admin/tenants/{}/usage?month=2026-02", deleted.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ---------------------------------------------------------------------------
// MT-07: parse_month boundary — December wraps to next year correctly
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_usage_200_december_month_boundary() {
    let customer_repo = mock_repo();
    let usage_repo = mock_usage_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    // Seed data on Dec 31 — must be included in the 2026-12 range
    usage_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 12, 31).unwrap(),
        "us-east-1",
        1000,
        100,
        0,
        0,
    );
    // Seed data on Jan 1 next year — must NOT be included
    usage_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2027, 1, 1).unwrap(),
        "us-east-1",
        9999,
        9999,
        0,
        0,
    );

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        mock_rate_card_repo(),
    );
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::get("/usage?month=2026-12")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(
        body["total_search_requests"], 1000,
        "Dec 31 must be included"
    );
}

// ---------------------------------------------------------------------------
// Tenant: GET /usage/daily
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_usage_daily_200_returns_daily_rows() {
    let customer_repo = mock_repo();
    let usage_repo = mock_usage_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    // Seed two days in us-east-1 and one day in eu-west-1
    usage_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        "us-east-1",
        1000,
        100,
        billing::types::BYTES_PER_GIB, // 1 GB
        5000,
    );
    usage_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 2, 2).unwrap(),
        "us-east-1",
        2000,
        200,
        billing::types::BYTES_PER_GIB * 3, // 3 GB
        7000,
    );
    usage_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        "eu-west-1",
        500,
        50,
        billing::types::BYTES_PER_GIB * 2, // 2 GB
        3000,
    );

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        mock_rate_card_repo(),
    );
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::get("/usage/daily?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: Vec<serde_json::Value> =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();

    // 3 rows total: 2 days for us-east-1, 1 day for eu-west-1
    assert_eq!(body.len(), 3);

    // Check first row shape
    let row0 = &body[0];
    assert!(row0.get("date").is_some());
    assert!(row0.get("region").is_some());
    assert!(row0.get("search_requests").is_some());
    assert!(row0.get("write_operations").is_some());
    assert!(row0.get("storage_gb").is_some());
    assert!(row0.get("document_count").is_some());

    // Verify storage_gb is converted from bytes (1 GB bytes → 1.0 GB)
    let first_us_east = body
        .iter()
        .find(|r| r["date"] == "2026-02-01" && r["region"] == "us-east-1")
        .expect("should have us-east-1 on 2026-02-01");
    let storage_gb = first_us_east["storage_gb"].as_f64().unwrap();
    assert!(
        (storage_gb - 1.0).abs() < 0.001,
        "expected ~1.0 GB, got {storage_gb}"
    );
    assert_eq!(first_us_east["search_requests"], 1000);
    assert_eq!(first_us_east["write_operations"], 100);
    assert_eq!(first_us_east["document_count"], 5000);
}

#[tokio::test]
async fn get_usage_daily_200_defaults_to_current_month() {
    let customer_repo = mock_repo();
    let usage_repo = mock_usage_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    // Seed data for today's date so the default-month logic can be verified
    let today = Utc::now().date_naive();
    usage_repo.seed(
        customer.id,
        today,
        "us-east-1",
        777,
        77,
        billing::types::BYTES_PER_GIB,
        3000,
    );

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        mock_rate_card_repo(),
    );
    let jwt = create_test_jwt(customer.id);

    // No month param — should default to current month and return today's data
    let resp = app
        .oneshot(
            Request::get("/usage/daily")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: Vec<serde_json::Value> =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    // Must return the row seeded for today
    assert_eq!(
        body.len(),
        1,
        "expected 1 row for current month, got {}",
        body.len()
    );
    assert_eq!(body[0]["search_requests"], 777);
    assert_eq!(body[0]["region"], "us-east-1");
}

#[tokio::test]
async fn get_usage_daily_200_empty_when_no_data() {
    let customer_repo = mock_repo();
    let usage_repo = mock_usage_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        mock_rate_card_repo(),
    );
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::get("/usage/daily?month=2026-03")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: Vec<serde_json::Value> =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert!(body.is_empty());
}

#[tokio::test]
async fn get_usage_daily_401_missing_auth() {
    let app = test_app_full(
        mock_repo(),
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
    );

    let resp = app
        .oneshot(
            Request::get("/usage/daily?month=2026-02")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

// ---------------------------------------------------------------------------
// Tenant: GET /usage/daily — input validation
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_usage_daily_400_invalid_month_format() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
    );
    let jwt = create_test_jwt(customer.id);

    // Invalid month: 13 is not a valid month
    let resp = app
        .oneshot(
            Request::get("/usage/daily?month=2026-13")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn get_usage_daily_400_garbage_month() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
    );
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::get("/usage/daily?month=bad")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// ---------------------------------------------------------------------------
// MT-17: parse_month boundary — December wraps correctly for /usage/daily
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_usage_daily_200_december_month_boundary() {
    let customer_repo = mock_repo();
    let usage_repo = mock_usage_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    // Seed data on Dec 31 — must be included in the 2026-12 range
    usage_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 12, 31).unwrap(),
        "us-east-1",
        1000,
        100,
        0,
        0,
    );
    // Seed data on Jan 1 next year — must NOT be included
    usage_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2027, 1, 1).unwrap(),
        "us-east-1",
        9999,
        9999,
        0,
        0,
    );

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        mock_rate_card_repo(),
    );
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::get("/usage/daily?month=2026-12")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: Vec<serde_json::Value> =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(
        body.len(),
        1,
        "only Dec 31 row should be returned, not Jan 1"
    );
    assert_eq!(body[0]["search_requests"], 1000);
    assert_eq!(body[0]["date"], "2026-12-31");
}

// ---------------------------------------------------------------------------
// MT-16: Tenant usage isolation for /usage/daily
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_usage_daily_200_tenant_isolation() {
    let customer_repo = mock_repo();
    let usage_repo = mock_usage_repo();
    let tenant_a = customer_repo.seed("Tenant A", "a@example.com");
    let tenant_b = customer_repo.seed("Tenant B", "b@example.com");

    // Seed daily usage only for tenant A
    usage_repo.seed(
        tenant_a.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        "us-east-1",
        9999,
        999,
        billing::types::BYTES_PER_GIB,
        5000,
    );

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        mock_rate_card_repo(),
    );

    // Tenant B requests daily usage — must see only their own (empty) data
    let jwt = create_test_jwt(tenant_b.id);
    let resp = app
        .oneshot(
            Request::get("/usage/daily?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: Vec<serde_json::Value> =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert!(
        body.is_empty(),
        "tenant B must not see tenant A's daily usage"
    );
}

// ---------------------------------------------------------------------------
// Suspended tenant: GET /usage/daily returns 403
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_usage_daily_403_suspended_customer() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    customer_repo.suspend(customer.id).await.unwrap();

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
    );
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::get("/usage/daily?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

// ---------------------------------------------------------------------------
// MT-15: Tenant JWT on admin endpoint must return 401
// ---------------------------------------------------------------------------

#[tokio::test]
async fn admin_endpoint_rejects_tenant_jwt() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
    );

    // Use a tenant Bearer JWT (not the x-admin-key) on an admin endpoint
    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get(format!(
                "/admin/tenants/{}/usage?month=2026-02",
                Uuid::new_v4()
            ))
            .header("authorization", format!("Bearer {jwt}"))
            .body(Body::empty())
            .unwrap(),
        )
        .await
        .unwrap();

    // Admin extractor checks x-admin-key header; Bearer JWT is ignored → 401
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}
