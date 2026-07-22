#![allow(clippy::await_holding_lock)]
#![allow(clippy::too_many_arguments)]
#![allow(clippy::useless_format)]
#![allow(clippy::bool_assert_comparison)]

use api::models::cold_snapshot::NewColdSnapshot;
use api::models::RateCardRow;
use api::repos::cold_snapshot_repo::ColdSnapshotRepo;
use api::repos::invoice_repo::{AdminInvoiceSummaryRow, InvoiceRepo, NewLineItem};
use api::repos::CustomerRepo;
use api::services::tenant_quota::FreeTierLimits;
use api::stripe::{
    invoice_create_idempotency_key, PaidInvoice, PaymentMethodSummary, StripeLastPaymentError,
};
use axum::body::Body;
use axum::http::{Method, Request, StatusCode};
use chrono::{NaiveDate, Utc};
use http_body_util::BodyExt;
use rust_decimal_macros::dec;
use serde_json::json;
use std::sync::Arc;
use tower::ServiceExt;
use uuid::Uuid;

use crate::common::stripe_webhook_test_support::webhook_request;
use crate::common::{
    create_test_jwt, mock_cold_snapshot_repo, mock_deployment_repo, mock_invoice_repo,
    mock_rate_card_repo, mock_repo, mock_stripe_service, mock_usage_repo,
    test_state_all_with_stripe, TestStateBuilder, TEST_ADMIN_KEY,
};

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

/// Build a test app with all repos and a custom stripe service.
fn test_app_with_stripe(
    customer_repo: std::sync::Arc<crate::common::MockCustomerRepo>,
    invoice_repo: std::sync::Arc<crate::common::MockInvoiceRepo>,
    stripe_service: std::sync::Arc<crate::common::MockStripeService>,
) -> axum::Router {
    TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_invoice_repo(invoice_repo)
        .with_stripe_service(stripe_service)
        .build_app()
}

fn test_app_with_upgrade_dependencies(
    customer_repo: std::sync::Arc<crate::common::MockCustomerRepo>,
    invoice_repo: std::sync::Arc<crate::common::MockInvoiceRepo>,
    rate_card_repo: std::sync::Arc<crate::common::MockRateCardRepo>,
    stripe_service: std::sync::Arc<crate::common::MockStripeService>,
) -> axum::Router {
    TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_invoice_repo(invoice_repo)
        .with_rate_card_repo(rate_card_repo)
        .with_stripe_service(stripe_service)
        .build_app()
}

fn test_app_with_publishable_key(stripe_publishable_key: Option<&str>) -> (axum::Router, Uuid) {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_stripe_publishable_key(stripe_publishable_key.map(str::to_string))
        .build_app();
    (app, customer.id)
}

#[derive(Clone, Copy)]
enum BillingUnauthorizedApp {
    Stripe,
    PublishableKey,
}

struct BillingUnauthorizedCase {
    name: &'static str,
    app: BillingUnauthorizedApp,
    method: Method,
    path: String,
    json_body: Option<serde_json::Value>,
    auth_header: Option<&'static str>,
    admin_header: Option<&'static str>,
    expected_status: StatusCode,
}

impl BillingUnauthorizedCase {
    fn request(&self) -> Request<Body> {
        let mut builder = Request::builder()
            .method(self.method.clone())
            .uri(self.path.as_str());

        if let Some(auth_header) = self.auth_header {
            builder = builder.header("authorization", auth_header);
        }
        if let Some(admin_header) = self.admin_header {
            builder = builder.header("x-admin-key", admin_header);
        }
        if self.json_body.is_some() {
            builder = builder.header("content-type", "application/json");
        }

        let body = self
            .json_body
            .clone()
            .map(|json| Body::from(json.to_string()))
            .unwrap_or_else(Body::empty);
        builder.body(body).unwrap()
    }

    fn app(&self) -> axum::Router {
        match self.app {
            BillingUnauthorizedApp::Stripe => {
                test_app_with_stripe(mock_repo(), mock_invoice_repo(), mock_stripe_service())
            }
            BillingUnauthorizedApp::PublishableKey => {
                test_app_with_publishable_key(Some("pk_test_123")).0
            }
        }
    }
}

fn billing_unauthorized_cases() -> Vec<BillingUnauthorizedCase> {
    vec![
        BillingUnauthorizedCase {
            name: "setup_intent_401_without_auth",
            app: BillingUnauthorizedApp::Stripe,
            method: Method::POST,
            path: "/billing/setup-intent".to_string(),
            json_body: None,
            auth_header: None,
            admin_header: None,
            expected_status: StatusCode::UNAUTHORIZED,
        },
        BillingUnauthorizedCase {
            name: "billing_publishable_key_401_without_auth",
            app: BillingUnauthorizedApp::PublishableKey,
            method: Method::GET,
            path: "/billing/publishable-key".to_string(),
            json_body: None,
            auth_header: None,
            admin_header: None,
            expected_status: StatusCode::UNAUTHORIZED,
        },
        BillingUnauthorizedCase {
            name: "billing_portal_401_without_auth",
            app: BillingUnauthorizedApp::Stripe,
            method: Method::POST,
            path: "/billing/portal".to_string(),
            json_body: Some(json!({"return_url":"http://localhost:5173/console"})),
            auth_header: None,
            admin_header: None,
            expected_status: StatusCode::UNAUTHORIZED,
        },
        BillingUnauthorizedCase {
            name: "billing_portal_401_invalid_auth_token",
            app: BillingUnauthorizedApp::Stripe,
            method: Method::POST,
            path: "/billing/portal".to_string(),
            json_body: Some(json!({"return_url":"http://localhost:5173/console"})),
            auth_header: Some("Bearer not-a-jwt"),
            admin_header: None,
            expected_status: StatusCode::UNAUTHORIZED,
        },
        BillingUnauthorizedCase {
            name: "admin_finalize_401_no_auth",
            app: BillingUnauthorizedApp::Stripe,
            method: Method::POST,
            path: format!("/admin/invoices/{}/finalize", Uuid::new_v4()),
            json_body: None,
            auth_header: None,
            admin_header: None,
            expected_status: StatusCode::UNAUTHORIZED,
        },
        BillingUnauthorizedCase {
            name: "reactivate_401_no_auth",
            app: BillingUnauthorizedApp::Stripe,
            method: Method::POST,
            path: format!("/admin/customers/{}/reactivate", Uuid::new_v4()),
            json_body: None,
            auth_header: None,
            admin_header: None,
            expected_status: StatusCode::UNAUTHORIZED,
        },
        BillingUnauthorizedCase {
            name: "batch_billing_run_401_no_auth",
            app: BillingUnauthorizedApp::Stripe,
            method: Method::POST,
            path: "/admin/billing/run".to_string(),
            json_body: Some(json!({"month":"2026-01"})),
            auth_header: None,
            admin_header: None,
            expected_status: StatusCode::UNAUTHORIZED,
        },
        BillingUnauthorizedCase {
            name: "list_payment_methods_401_without_auth",
            app: BillingUnauthorizedApp::Stripe,
            method: Method::GET,
            path: "/billing/payment-methods".to_string(),
            json_body: None,
            auth_header: None,
            admin_header: None,
            expected_status: StatusCode::UNAUTHORIZED,
        },
        BillingUnauthorizedCase {
            name: "delete_payment_method_401_without_auth",
            app: BillingUnauthorizedApp::Stripe,
            method: Method::DELETE,
            path: "/billing/payment-methods/pm_whatever".to_string(),
            json_body: None,
            auth_header: None,
            admin_header: None,
            expected_status: StatusCode::UNAUTHORIZED,
        },
        BillingUnauthorizedCase {
            name: "set_default_payment_method_401_without_auth",
            app: BillingUnauthorizedApp::Stripe,
            method: Method::POST,
            path: "/billing/payment-methods/pm_whatever/default".to_string(),
            json_body: None,
            auth_header: None,
            admin_header: None,
            expected_status: StatusCode::UNAUTHORIZED,
        },
        BillingUnauthorizedCase {
            name: "suspend_401_no_auth",
            app: BillingUnauthorizedApp::Stripe,
            method: Method::POST,
            path: format!("/admin/customers/{}/suspend", Uuid::new_v4()),
            json_body: None,
            auth_header: None,
            admin_header: None,
            expected_status: StatusCode::UNAUTHORIZED,
        },
    ]
}

/// Seed a customer with a stripe_customer_id set.
async fn seed_stripe_customer(
    repo: &crate::common::MockCustomerRepo,
    name: &str,
    email: &str,
) -> api::models::Customer {
    let customer = repo.seed(name, email);
    repo.set_stripe_customer_id(
        customer.id,
        &format!("cus_test_{}", &customer.id.to_string()[..8]),
    )
    .await
    .unwrap();
    repo.find_by_id(customer.id).await.unwrap().unwrap()
}

#[tokio::test]
async fn admin_invoice_detail_exposes_stripe_urls() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Invoice Detail", "invoice-detail@example.com");
    let invoice = invoice_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 1, 31).unwrap(),
        12000,
        13000,
        false,
        vec![NewLineItem {
            description: "Hot storage".to_string(),
            quantity: dec!(42.5),
            unit: "mb_month".to_string(),
            unit_price_cents: dec!(5),
            amount_cents: 12000,
            region: "us-east-1".to_string(),
            metadata: Some(json!({"source": "test"})),
        }],
    );
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_test_x",
            "https://invoice.stripe.com/i/acct_x/test_x",
            Some("https://invoice.stripe.com/i/acct_x/test_x/pdf"),
        )
        .await
        .unwrap();

    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_invoice_repo(invoice_repo)
        .build_app();

    let req = Request::builder()
        .uri(format!("/admin/invoices/{}", invoice.id))
        .header("x-admin-key", TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();
    let resp = app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    assert_eq!(json["id"], invoice.id.to_string());
    assert_eq!(json["customer_id"], customer.id.to_string());
    assert_eq!(json["stripe_invoice_id"], "in_test_x");
    assert_eq!(
        json["hosted_invoice_url"],
        "https://invoice.stripe.com/i/acct_x/test_x"
    );
    assert_eq!(
        json["pdf_url"],
        "https://invoice.stripe.com/i/acct_x/test_x/pdf"
    );
    assert_eq!(json["line_items"][0]["description"], "Hot storage");

    let missing_req = Request::builder()
        .uri(format!("/admin/invoices/{}", Uuid::new_v4()))
        .header("x-admin-key", TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();
    let missing_resp = app.clone().oneshot(missing_req).await.unwrap();
    assert_eq!(missing_resp.status(), StatusCode::NOT_FOUND);

    let no_key_req = Request::builder()
        .uri(format!("/admin/invoices/{}", invoice.id))
        .body(Body::empty())
        .unwrap();
    let no_key_resp = app.clone().oneshot(no_key_req).await.unwrap();
    assert_eq!(no_key_resp.status(), StatusCode::UNAUTHORIZED);

    let wrong_key_req = Request::builder()
        .uri(format!("/admin/invoices/{}", invoice.id))
        .header("x-admin-key", "wrong-key")
        .body(Body::empty())
        .unwrap();
    let wrong_key_resp = app.oneshot(wrong_key_req).await.unwrap();
    assert_eq!(wrong_key_resp.status(), StatusCode::UNAUTHORIZED);
}

fn seed_draft_invoice(
    repo: &crate::common::MockInvoiceRepo,
    customer_id: Uuid,
) -> api::models::InvoiceRow {
    repo.seed(
        customer_id,
        NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 1, 31).unwrap(),
        5000,
        5000,
        false,
        vec![NewLineItem {
            description: "Search requests".to_string(),
            quantity: dec!(1000),
            unit: "requests_1k".to_string(),
            unit_price_cents: dec!(5),
            amount_cents: 5000,
            region: "us-east-1".to_string(),
            metadata: None,
        }],
    )
}

#[tokio::test]
async fn onboarding_status_reports_configured_free_tier_limits_without_signed_fallback() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Free Tier", "free-tier@example.com");
    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_free_tier_limits(FreeTierLimits {
            max_indexes: u32::MAX,
            max_searches_per_month: u64::MAX,
            max_records: 100_000,
            max_storage_mb: 250,
        })
        .build_app();

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/onboarding/status")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    let free_tier_limits = body["free_tier_limits"]
        .as_object()
        .expect("free plan onboarding response must include free_tier_limits");
    assert_eq!(
        free_tier_limits["max_searches_per_month"].as_u64(),
        Some(u64::MAX),
        "response must expose the configured search limit instead of falling back to defaults"
    );
    assert_eq!(
        free_tier_limits["max_indexes"].as_u64(),
        Some(u64::from(u32::MAX)),
        "response must expose the configured index limit instead of falling back to defaults"
    );
    assert_eq!(free_tier_limits["max_records"].as_u64(), Some(100_000));
    assert_eq!(free_tier_limits["max_storage_mb"].as_u64(), Some(250));
}

// ===========================================================================
// POST /billing/setup-intent
// ===========================================================================

#[tokio::test]
async fn setup_intent_returns_client_secret() {
    let customer_repo = mock_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), mock_stripe_service());

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/setup-intent")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert!(
        body["client_secret"].as_str().is_some(),
        "should return client_secret"
    );
}

#[tokio::test]
async fn setup_intent_400_no_stripe_customer() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    // No stripe_customer_id set

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), mock_stripe_service());

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/setup-intent")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = body_json(resp).await;
    assert_eq!(body["error"], "no stripe customer linked");
}

// ===========================================================================
// POST /billing/portal
// ===========================================================================

// ===========================================================================
// GET /billing/publishable-key
// ===========================================================================

#[tokio::test]
async fn billing_publishable_key_returns_runtime_key_when_configured() {
    let (app, customer_id) = test_app_with_publishable_key(Some("pk_test_123"));
    let jwt = create_test_jwt(customer_id);

    let resp = app
        .oneshot(
            Request::get("/billing/publishable-key")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body, json!({ "publishableKey": "pk_test_123" }));
}

#[tokio::test]
async fn billing_publishable_key_503_when_unconfigured() {
    let (app, customer_id) = test_app_with_publishable_key(None);
    let jwt = create_test_jwt(customer_id);

    let resp = app
        .oneshot(
            Request::get("/billing/publishable-key")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = body_json(resp).await;
    assert_eq!(
        body,
        json!({ "error": "stripe_publishable_key_unavailable" })
    );
}

#[tokio::test]
async fn billing_portal_returns_portal_url_and_forwards_return_url() {
    let customer_repo = mock_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    let stripe_svc = mock_stripe_service();
    stripe_svc.set_billing_portal_url("https://billing.stripe.com/p/session/test_portal");
    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), stripe_svc.clone());

    let jwt = create_test_jwt(customer.id);
    let return_url = "http://localhost:5173/console";
    let resp = app
        .oneshot(
            Request::post("/billing/portal")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(json!({ "return_url": return_url }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(
        body["portal_url"],
        "https://billing.stripe.com/p/session/test_portal"
    );

    let calls = stripe_svc
        .billing_portal_session_calls
        .lock()
        .unwrap()
        .clone();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].0, customer.stripe_customer_id.unwrap());
    assert_eq!(calls[0].1, return_url);
}

#[tokio::test]
async fn billing_portal_400_no_stripe_customer() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), mock_stripe_service());

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/portal")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({"return_url":"http://localhost:5173/console"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = body_json(resp).await;
    assert_eq!(body["error"], "no stripe customer linked");
}

#[tokio::test]
async fn billing_portal_400_for_disallowed_return_url_origin() {
    let customer_repo = mock_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), mock_stripe_service());

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/portal")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({"return_url":"https://attacker.example/callback"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = body_json(resp).await;
    assert_eq!(body["error"], "return_url origin is not allowed");
}

#[tokio::test]
async fn suspended_customer_gets_403_on_billing_portal() {
    let customer_repo = mock_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    customer_repo.suspend(customer.id).await.unwrap();

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), mock_stripe_service());

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/portal")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({"return_url":"http://localhost:5173/console"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn billing_portal_503_when_stripe_unconfigured() {
    let customer_repo = mock_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    let stripe_svc = mock_stripe_service();
    stripe_svc.set_not_configured(true);
    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), stripe_svc);

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/portal")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({"return_url":"http://localhost:5173/console"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = body_json(resp).await;
    assert_eq!(body["error"], "service_not_configured");
}

// ===========================================================================
// GET /billing/payment-methods
// ===========================================================================

#[tokio::test]
async fn list_payment_methods_returns_cards() {
    let customer_repo = mock_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;

    let stripe_svc = mock_stripe_service();
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_test_1".to_string(),
        card_brand: "visa".to_string(),
        last4: "4242".to_string(),
        exp_month: 12,
        exp_year: 2027,
        is_default: false,
    });

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), stripe_svc);

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/billing/payment-methods")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    let methods = body.as_array().unwrap();
    assert_eq!(methods.len(), 1);
    assert_eq!(methods[0]["card_brand"], "visa");
    assert_eq!(methods[0]["last4"], "4242");
}

#[tokio::test]
async fn list_payment_methods_empty_returns_empty_array() {
    let customer_repo = mock_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), mock_stripe_service());

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/billing/payment-methods")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body.as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn list_payment_methods_400_no_stripe_customer() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), mock_stripe_service());

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/billing/payment-methods")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn list_payment_methods_returns_is_default_for_default_pm() {
    let customer_repo = mock_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;

    let stripe_svc = mock_stripe_service();
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_default".to_string(),
        card_brand: "visa".to_string(),
        last4: "4242".to_string(),
        exp_month: 12,
        exp_year: 2027,
        is_default: false,
    });
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_other".to_string(),
        card_brand: "mastercard".to_string(),
        last4: "5555".to_string(),
        exp_month: 6,
        exp_year: 2028,
        is_default: false,
    });
    *stripe_svc.default_pm.lock().unwrap() = Some("pm_default".to_string());

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), stripe_svc);

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/billing/payment-methods")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    let methods = body.as_array().unwrap();
    assert_eq!(methods.len(), 2);

    let default_pm = methods.iter().find(|m| m["id"] == "pm_default").unwrap();
    assert_eq!(
        default_pm["is_default"], true,
        "default PM should have is_default=true"
    );

    let other_pm = methods.iter().find(|m| m["id"] == "pm_other").unwrap();
    assert_eq!(
        other_pm["is_default"], false,
        "non-default PM should have is_default=false"
    );
}

#[tokio::test]
async fn list_payment_methods_no_default_all_false() {
    let customer_repo = mock_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;

    let stripe_svc = mock_stripe_service();
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_1".to_string(),
        card_brand: "visa".to_string(),
        last4: "4242".to_string(),
        exp_month: 12,
        exp_year: 2027,
        is_default: false,
    });
    // No default_pm set

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), stripe_svc);

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/billing/payment-methods")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    let methods = body.as_array().unwrap();
    assert_eq!(methods.len(), 1);
    assert_eq!(
        methods[0]["is_default"], false,
        "should be false when no default is set"
    );
}

// ===========================================================================
// DELETE /billing/payment-methods/:pm_id
// ===========================================================================

#[tokio::test]
async fn delete_payment_method_204() {
    let customer_repo = mock_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;

    let stripe_svc = mock_stripe_service();
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_to_delete".to_string(),
        card_brand: "visa".to_string(),
        last4: "1234".to_string(),
        exp_month: 6,
        exp_year: 2028,
        is_default: false,
    });

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), stripe_svc);

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::delete("/billing/payment-methods/pm_to_delete")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn delete_payment_method_400_no_stripe_customer() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    // No stripe_customer_id — this was the bug we fixed

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), mock_stripe_service());

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::delete("/billing/payment-methods/pm_whatever")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// ===========================================================================
// POST /billing/payment-methods/:pm_id/default
// ===========================================================================

#[tokio::test]
async fn set_default_payment_method_204() {
    let customer_repo = mock_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;

    let stripe_svc = mock_stripe_service();
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_123".to_string(),
        card_brand: "visa".to_string(),
        last4: "4242".to_string(),
        exp_month: 12,
        exp_year: 2027,
        is_default: false,
    });
    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), stripe_svc.clone());

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/payment-methods/pm_123/default")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    // Verify the mock recorded the default
    let default = stripe_svc.default_pm.lock().unwrap().clone();
    assert_eq!(default, Some("pm_123".to_string()));
}

#[tokio::test]
async fn set_default_400_no_stripe_customer() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), mock_stripe_service());

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/payment-methods/pm_123/default")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// ===========================================================================
// Cross-tenant PM isolation — tenant cannot operate on another tenant's PMs
// ===========================================================================

#[tokio::test]
async fn delete_payment_method_404_not_owned() {
    let customer_repo = mock_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;

    // PM exists in Stripe but is NOT owned by this customer (simulated by not seeding it)
    let stripe_svc = mock_stripe_service();
    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), stripe_svc);

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::delete("/billing/payment-methods/pm_other_customer")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(
        resp.status(),
        StatusCode::NOT_FOUND,
        "must return 404 when PM does not belong to authenticated customer"
    );
}

#[tokio::test]
async fn set_default_404_not_owned() {
    let customer_repo = mock_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;

    // PM is NOT in this customer's list
    let stripe_svc = mock_stripe_service();
    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), stripe_svc);

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/payment-methods/pm_other_customer/default")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(
        resp.status(),
        StatusCode::NOT_FOUND,
        "must return 404 when PM does not belong to authenticated customer"
    );
}

// ===========================================================================
// POST /webhooks/stripe
// ===========================================================================

#[tokio::test]
async fn webhook_retries_same_event_if_first_processing_attempt_fails() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_retry_same_event",
            "https://stripe.com/inv",
            None,
        )
        .await
        .unwrap();

    // Force first attempt to fail while handling payment_succeeded.
    invoice_repo.fail_next_mark_paid();

    let app = test_app_with_stripe(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        mock_stripe_service(),
    );

    let payload = r#"{"id":"evt_retry_same_event","type":"invoice.payment_succeeded","data":{"object":{"id":"in_retry_same_event"}}}"#;

    // First attempt fails and should return 500.
    let first = app.clone().oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(first.status(), StatusCode::INTERNAL_SERVER_ERROR);
    let after_first = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(after_first.status, "finalized");

    // Retry with the exact same Stripe event ID should process again and succeed.
    let second = app.oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(second.status(), StatusCode::OK);
    let after_second = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(
        after_second.status, "paid",
        "retry should process the event because first attempt failed"
    );
}

#[tokio::test]
async fn webhook_payment_failed_final_retry_suspends_customer() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(invoice.id, "in_stripe_fail", "https://stripe.com/inv", None)
        .await
        .unwrap();

    let app = test_app_with_stripe(
        customer_repo.clone(),
        invoice_repo.clone(),
        mock_stripe_service(),
    );

    // next_payment_attempt is null — Stripe exhausted retries
    let payload = format!(
        r#"{{"id":"evt_fail","type":"invoice.payment_failed","data":{{"object":{{"id":"in_stripe_fail","next_payment_attempt":null}}}}}}"#
    );
    let resp = app.oneshot(webhook_request(&payload)).await.unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    // Verify invoice is failed
    let updated_inv = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated_inv.status, "failed");

    // Verify customer is suspended
    let updated_cust = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(updated_cust.status, "suspended");
}

#[tokio::test]
async fn webhook_payment_failed_with_retry_does_not_suspend() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_retry",
            "https://stripe.com/inv",
            None,
        )
        .await
        .unwrap();

    let app = test_app_with_stripe(
        customer_repo.clone(),
        invoice_repo.clone(),
        mock_stripe_service(),
    );

    // next_payment_attempt is set — Stripe will retry
    let payload = format!(
        r#"{{"id":"evt_retry","type":"invoice.payment_failed","data":{{"object":{{"id":"in_stripe_retry","next_payment_attempt":1708300800}}}}}}"#
    );
    let resp = app.oneshot(webhook_request(&payload)).await.unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    // Invoice should still be finalized (not failed)
    let updated_inv = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated_inv.status, "finalized");

    // Customer should still be active (not suspended)
    let updated_cust = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(updated_cust.status, "active");
}

#[tokio::test]
async fn webhook_retries_same_failed_event_if_suspend_fails_after_mark_failed() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_suspend_retry_same_event",
            "https://stripe.com/inv",
            None,
        )
        .await
        .unwrap();

    let app = test_app_with_stripe(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        mock_stripe_service(),
    );

    // Force suspend to fail on the first attempt, after invoice mark_failed.
    *customer_repo.should_fail_suspend.lock().unwrap() = true;
    let payload = r#"{"id":"evt_suspend_retry_same_event","type":"invoice.payment_failed","data":{"object":{"id":"in_suspend_retry_same_event","next_payment_attempt":null}}}"#;

    let first = app.clone().oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(first.status(), StatusCode::INTERNAL_SERVER_ERROR);

    // Partial progress happened: invoice is failed, customer still active.
    let after_first_invoice = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(after_first_invoice.status, "failed");
    let after_first_customer = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(after_first_customer.status, "active");

    // Retry with the same event ID must still attempt suspend and complete.
    *customer_repo.should_fail_suspend.lock().unwrap() = false;
    let second = app.oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(second.status(), StatusCode::OK);

    let after_second_customer = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        after_second_customer.status, "suspended",
        "retry should suspend customer even if first attempt failed after mark_failed"
    );
}

#[tokio::test]
async fn webhook_payment_failed_does_not_suspend_if_already_paid() {
    // This tests the race condition fix: if payment_succeeded webhook was processed
    // before payment_failed (out of order), don't suspend the customer.
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(invoice.id, "in_stripe_race", "https://stripe.com/inv", None)
        .await
        .unwrap();
    // Simulate: payment_succeeded already processed, invoice is paid
    invoice_repo.mark_paid(invoice.id).await.unwrap();

    let app = test_app_with_stripe(
        customer_repo.clone(),
        invoice_repo.clone(),
        mock_stripe_service(),
    );

    // Late-arriving payment_failed with no retry
    let payload = format!(
        r#"{{"id":"evt_race","type":"invoice.payment_failed","data":{{"object":{{"id":"in_stripe_race","next_payment_attempt":null}}}}}}"#
    );
    let resp = app.oneshot(webhook_request(&payload)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Customer should NOT be suspended — invoice was already paid
    let updated_cust = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        updated_cust.status, "active",
        "customer must not be suspended when invoice is already paid"
    );

    // Invoice should still be paid
    let updated_inv = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated_inv.status, "paid");
}

// ===========================================================================
// POST /admin/invoices/:id/finalize
// ===========================================================================

#[tokio::test]
async fn admin_finalize_invoice_success() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    let stripe_svc = mock_stripe_service();

    let app = test_app_with_stripe(customer_repo, invoice_repo.clone(), stripe_svc.clone());

    let resp = app
        .oneshot(
            Request::post(format!("/admin/invoices/{}/finalize", invoice.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["status"], "finalized");
    assert!(body["stripe_invoice_id"].as_str().is_some());
    assert!(body["hosted_invoice_url"].as_str().is_some());
    assert!(body["finalized_at"].as_str().is_some());

    // Verify the invoice repo was updated
    let updated = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "finalized");
    assert!(updated.stripe_invoice_id.is_some());
    assert!(updated.hosted_invoice_url.is_some());

    let expected_key = invoice_create_idempotency_key(
        updated.id,
        customer.id,
        updated.period_start,
        updated.period_end,
    );
    let calls = stripe_svc.create_and_finalize_calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].1.as_deref(), Some(expected_key.as_str()));
}

#[tokio::test]
async fn admin_finalize_non_draft_returns_400() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();

    let app = test_app_with_stripe(customer_repo, invoice_repo, mock_stripe_service());

    let resp = app
        .oneshot(
            Request::post(format!("/admin/invoices/{}/finalize", invoice.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn admin_finalize_404_deleted_customer() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed_deleted("Gone Corp", "gone@example.com");
    let invoice = seed_draft_invoice(&invoice_repo, customer.id);

    let app = test_app_with_stripe(customer_repo, invoice_repo, mock_stripe_service());

    let resp = app
        .oneshot(
            Request::post(format!("/admin/invoices/{}/finalize", invoice.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn admin_finalize_404_unknown_invoice() {
    let app = test_app_with_stripe(mock_repo(), mock_invoice_repo(), mock_stripe_service());

    let resp = app
        .oneshot(
            Request::post(format!("/admin/invoices/{}/finalize", Uuid::new_v4()))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn admin_finalize_400_no_stripe_customer() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    // No stripe_customer_id
    let invoice = seed_draft_invoice(&invoice_repo, customer.id);

    let app = test_app_with_stripe(customer_repo, invoice_repo, mock_stripe_service());

    let resp = app
        .oneshot(
            Request::post(format!("/admin/invoices/{}/finalize", invoice.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// ===========================================================================
// Finalize advances egress watermark
// ===========================================================================

#[tokio::test]
async fn admin_finalize_advances_egress_watermark() {
    use crate::common::mock_storage_bucket_repo;
    use api::models::storage::NewStorageBucket;
    use api::repos::StorageBucketRepo;

    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let stripe_svc = mock_stripe_service();

    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    rate_card_repo.seed_active_card(test_rate_card());

    // Create two buckets with unbilled egress
    let one_gb = billing::types::BYTES_PER_GIB;
    let bucket_a = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id: customer.id,
                name: "bucket-a".to_string(),
            },
            "garage-bucket-a",
        )
        .await
        .unwrap();
    storage_bucket_repo
        .increment_egress(bucket_a.id, one_gb * 10)
        .await
        .unwrap();
    storage_bucket_repo
        .update_egress_watermark(bucket_a.id, one_gb * 3)
        .await
        .unwrap();

    let bucket_b = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id: customer.id,
                name: "bucket-b".to_string(),
            },
            "garage-bucket-b",
        )
        .await
        .unwrap();
    storage_bucket_repo
        .increment_egress(bucket_b.id, one_gb * 5)
        .await
        .unwrap();
    // bucket_b watermark stays at 0

    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .with_invoice_repo(invoice_repo)
        .with_rate_card_repo(rate_card_repo)
        .with_stripe_service(stripe_svc)
        .with_storage_bucket_repo(storage_bucket_repo.clone())
        .build_app();

    let create_resp = app
        .clone()
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(create_resp.status(), StatusCode::CREATED);
    let created_body = body_json(create_resp).await;
    let invoice_id = created_body["id"]
        .as_str()
        .expect("invoice id should be present");

    let resp = app
        .oneshot(
            Request::post(format!("/admin/invoices/{invoice_id}/finalize"))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    // After finalization, watermarks should be advanced to current egress_bytes
    let a = storage_bucket_repo.get(bucket_a.id).await.unwrap().unwrap();
    assert_eq!(
        a.egress_watermark_bytes,
        one_gb * 10,
        "bucket_a watermark should advance to egress_bytes after finalization"
    );

    let b = storage_bucket_repo.get(bucket_b.id).await.unwrap().unwrap();
    assert_eq!(
        b.egress_watermark_bytes,
        one_gb * 5,
        "bucket_b watermark should advance to egress_bytes after finalization"
    );
}

#[tokio::test]
async fn admin_finalize_stripe_failure_does_not_advance_watermark() {
    use crate::common::mock_storage_bucket_repo;
    use api::models::storage::NewStorageBucket;
    use api::repos::StorageBucketRepo;

    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let stripe_svc = mock_stripe_service();
    stripe_svc.set_should_fail(true);

    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    customer_repo
        .set_object_storage_egress_carryforward_cents(customer.id, dec!(0.6))
        .await
        .unwrap();
    rate_card_repo.seed_active_card(test_rate_card());

    let one_gb = billing::types::BYTES_PER_GIB;
    let bucket = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id: customer.id,
                name: "bucket-fail".to_string(),
            },
            "garage-bucket-fail",
        )
        .await
        .unwrap();
    storage_bucket_repo
        .increment_egress(bucket.id, one_gb * 10)
        .await
        .unwrap();

    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .with_invoice_repo(invoice_repo)
        .with_rate_card_repo(rate_card_repo)
        .with_stripe_service(stripe_svc)
        .with_storage_bucket_repo(storage_bucket_repo.clone())
        .build_app();

    let create_resp = app
        .clone()
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(create_resp.status(), StatusCode::CREATED);
    let created_body = body_json(create_resp).await;
    let invoice_id = created_body["id"]
        .as_str()
        .expect("invoice id should be present");

    let resp = app
        .oneshot(
            Request::post(format!("/admin/invoices/{invoice_id}/finalize"))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    // Finalization should fail (500 from stripe error)
    assert_ne!(resp.status(), StatusCode::OK);

    // Watermark must NOT advance when stripe fails
    let b = storage_bucket_repo.get(bucket.id).await.unwrap().unwrap();
    assert_eq!(
        b.egress_watermark_bytes, 0,
        "watermark must not advance when stripe finalization fails"
    );
    let customer_after = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        customer_after.object_storage_egress_carryforward_cents,
        dec!(0.6),
        "carry-forward must remain unchanged when stripe finalization fails"
    );
}

#[tokio::test]
async fn admin_finalize_updates_egress_watermark_and_carryforward_from_draft_snapshot() {
    use crate::common::mock_storage_bucket_repo;
    use api::models::storage::NewStorageBucket;
    use api::repos::StorageBucketRepo;

    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let stripe_svc = mock_stripe_service();

    rate_card_repo.seed_active_card(test_rate_card());
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    customer_repo
        .set_object_storage_egress_carryforward_cents(customer.id, dec!(0.6))
        .await
        .unwrap();

    let one_gb = billing::types::BYTES_PER_GIB;
    let bucket = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id: customer.id,
                name: "bucket-carryforward-success".to_string(),
            },
            "garage-bucket-carryforward-success",
        )
        .await
        .unwrap();
    storage_bucket_repo
        .increment_egress(bucket.id, one_gb / 2)
        .await
        .unwrap();

    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .with_invoice_repo(invoice_repo)
        .with_rate_card_repo(rate_card_repo)
        .with_storage_bucket_repo(storage_bucket_repo.clone())
        .with_stripe_service(stripe_svc)
        .build_app();

    let create_resp = app
        .clone()
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(create_resp.status(), StatusCode::CREATED);
    let created_body = body_json(create_resp).await;
    let invoice_id = created_body["id"]
        .as_str()
        .expect("invoice id should be present");
    let egress_item = created_body["line_items"]
        .as_array()
        .expect("line_items should be an array")
        .iter()
        .find(|item| item["unit"] == "object_storage_egress_gb")
        .expect("object storage egress line item should be present");
    assert_eq!(egress_item["amount_cents"], 1);

    let finalize_resp = app
        .oneshot(
            Request::post(format!("/admin/invoices/{invoice_id}/finalize"))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(finalize_resp.status(), StatusCode::OK);

    let bucket_after = storage_bucket_repo.get(bucket.id).await.unwrap().unwrap();
    assert_eq!(
        bucket_after.egress_watermark_bytes,
        one_gb / 2,
        "watermark should advance to the draft egress snapshot"
    );
    let customer_after = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        customer_after.object_storage_egress_carryforward_cents,
        dec!(0.1),
        "finalization should persist post-billing egress remainder from draft metadata"
    );
}

#[tokio::test]
async fn admin_finalize_rolls_back_egress_watermark_and_carryforward_on_finalize_write_failure() {
    use crate::common::mock_storage_bucket_repo;
    use api::models::storage::NewStorageBucket;
    use api::repos::StorageBucketRepo;

    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let stripe_svc = mock_stripe_service();

    rate_card_repo.seed_active_card(test_rate_card());
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    customer_repo
        .set_object_storage_egress_carryforward_cents(customer.id, dec!(0.6))
        .await
        .unwrap();

    let one_gb = billing::types::BYTES_PER_GIB;
    let bucket = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id: customer.id,
                name: "bucket-carryforward-rollback".to_string(),
            },
            "garage-bucket-carryforward-rollback",
        )
        .await
        .unwrap();
    storage_bucket_repo
        .increment_egress(bucket.id, one_gb / 2)
        .await
        .unwrap();

    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .with_invoice_repo(invoice_repo.clone())
        .with_rate_card_repo(rate_card_repo)
        .with_storage_bucket_repo(storage_bucket_repo.clone())
        .with_stripe_service(stripe_svc)
        .build_app();

    let create_resp = app
        .clone()
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(create_resp.status(), StatusCode::CREATED);
    let created_body = body_json(create_resp).await;
    let invoice_id = Uuid::parse_str(
        created_body["id"]
            .as_str()
            .expect("invoice id should be present"),
    )
    .expect("invoice id should parse as UUID");

    invoice_repo.fail_next_finalize();

    let finalize_resp = app
        .oneshot(
            Request::post(format!("/admin/invoices/{invoice_id}/finalize"))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_ne!(finalize_resp.status(), StatusCode::OK);

    let invoice_after = invoice_repo.find_by_id(invoice_id).await.unwrap().unwrap();
    assert_eq!(
        invoice_after.status, "draft",
        "invoice should remain draft when finalize persistence fails"
    );

    let bucket_after = storage_bucket_repo.get(bucket.id).await.unwrap().unwrap();
    assert_eq!(
        bucket_after.egress_watermark_bytes, 0,
        "watermark should roll back when finalize persistence fails"
    );
    let customer_after = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        customer_after.object_storage_egress_carryforward_cents,
        dec!(0.6),
        "carry-forward should roll back when finalize persistence fails"
    );
}

#[tokio::test]
async fn admin_finalize_rolls_back_partial_watermark_advance_when_second_update_fails() {
    use crate::common::mock_storage_bucket_repo;
    use api::models::storage::NewStorageBucket;
    use api::repos::StorageBucketRepo;

    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let stripe_svc = mock_stripe_service();

    rate_card_repo.seed_active_card(test_rate_card());
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    customer_repo
        .set_object_storage_egress_carryforward_cents(customer.id, dec!(0.6))
        .await
        .unwrap();

    let one_gb = billing::types::BYTES_PER_GIB;
    let bucket_a = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id: customer.id,
                name: "bucket-partial-watermark-a".to_string(),
            },
            "garage-bucket-partial-watermark-a",
        )
        .await
        .unwrap();
    let bucket_b = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id: customer.id,
                name: "bucket-partial-watermark-b".to_string(),
            },
            "garage-bucket-partial-watermark-b",
        )
        .await
        .unwrap();
    storage_bucket_repo
        .increment_egress(bucket_a.id, one_gb / 2)
        .await
        .unwrap();
    storage_bucket_repo
        .increment_egress(bucket_b.id, one_gb / 2)
        .await
        .unwrap();

    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .with_invoice_repo(invoice_repo)
        .with_rate_card_repo(rate_card_repo)
        .with_storage_bucket_repo(storage_bucket_repo.clone())
        .with_stripe_service(stripe_svc)
        .build_app();

    let create_resp = app
        .clone()
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(create_resp.status(), StatusCode::CREATED);
    let created_body = body_json(create_resp).await;
    let invoice_id = created_body["id"]
        .as_str()
        .expect("invoice id should be present")
        .to_string();

    storage_bucket_repo.fail_update_egress_watermark_after(1);

    let finalize_resp = app
        .oneshot(
            Request::post(format!("/admin/invoices/{invoice_id}/finalize"))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_ne!(finalize_resp.status(), StatusCode::OK);

    let bucket_a_after = storage_bucket_repo.get(bucket_a.id).await.unwrap().unwrap();
    let bucket_b_after = storage_bucket_repo.get(bucket_b.id).await.unwrap().unwrap();
    assert_eq!(
        bucket_a_after.egress_watermark_bytes, 0,
        "first watermark update must roll back if a later watermark update fails"
    );
    assert_eq!(
        bucket_b_after.egress_watermark_bytes, 0,
        "failed finalize attempt must leave every draft snapshot watermark unchanged"
    );
    let customer_after = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        customer_after.object_storage_egress_carryforward_cents,
        dec!(0.6),
        "carry-forward must remain unchanged when watermark advancement fails before persistence"
    );
}

#[tokio::test]
async fn admin_finalize_uses_draft_egress_snapshot_for_watermark() {
    use crate::common::mock_storage_bucket_repo;
    use api::models::storage::NewStorageBucket;
    use api::repos::StorageBucketRepo;

    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let stripe_svc = mock_stripe_service();

    rate_card_repo.seed_active_card(test_rate_card());
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;

    let one_gb = billing::types::BYTES_PER_GIB;
    let bucket = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id: customer.id,
                name: "bucket-stale".to_string(),
            },
            "garage-bucket-stale",
        )
        .await
        .unwrap();
    storage_bucket_repo
        .increment_egress(bucket.id, one_gb * 5)
        .await
        .unwrap();

    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .with_invoice_repo(invoice_repo)
        .with_rate_card_repo(rate_card_repo)
        .with_storage_bucket_repo(storage_bucket_repo.clone())
        .with_stripe_service(stripe_svc)
        .build_app();

    let create_resp = app
        .clone()
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(create_resp.status(), StatusCode::CREATED);
    let created_body = body_json(create_resp).await;
    let invoice_id = created_body["id"]
        .as_str()
        .expect("invoice id should be present");

    storage_bucket_repo
        .increment_egress(bucket.id, one_gb * 3)
        .await
        .unwrap();

    let finalize_resp = app
        .oneshot(
            Request::post(format!("/admin/invoices/{invoice_id}/finalize"))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(finalize_resp.status(), StatusCode::OK);

    let bucket_after = storage_bucket_repo.get(bucket.id).await.unwrap().unwrap();
    assert_eq!(bucket_after.egress_bytes, one_gb * 8);
    assert_eq!(
        bucket_after.egress_watermark_bytes,
        one_gb * 5,
        "finalization must advance only the egress snapshot billed on the draft invoice"
    );
}

#[tokio::test]
async fn admin_finalize_advances_watermark_and_persists_remainder_for_zero_cent_object_egress() {
    use crate::common::mock_storage_bucket_repo;
    use api::models::storage::NewStorageBucket;
    use api::repos::StorageBucketRepo;

    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let stripe_svc = mock_stripe_service();

    rate_card_repo.seed_active_card(test_rate_card());
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;

    // 0.5 GB egress at $0.01/GB = 0.5 cents -> billed as 0 cents, retained as carry-forward.
    let one_gb = billing::types::BYTES_PER_GIB;
    let bucket = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id: customer.id,
                name: "bucket-subcent".to_string(),
            },
            "garage-bucket-subcent",
        )
        .await
        .unwrap();
    storage_bucket_repo
        .increment_egress(bucket.id, one_gb / 2)
        .await
        .unwrap();

    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .with_invoice_repo(invoice_repo)
        .with_rate_card_repo(rate_card_repo)
        .with_storage_bucket_repo(storage_bucket_repo.clone())
        .with_stripe_service(stripe_svc)
        .build_app();

    let create_resp = app
        .clone()
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(create_resp.status(), StatusCode::CREATED);
    let created_body = body_json(create_resp).await;
    let invoice_id = created_body["id"]
        .as_str()
        .expect("invoice id should be present")
        .to_string();

    let egress_item = created_body["line_items"]
        .as_array()
        .expect("line_items should be an array")
        .iter()
        .find(|item| item["unit"] == "object_storage_egress_gb")
        .expect("object storage egress line item should be present");
    assert_eq!(
        egress_item["amount_cents"], 0,
        "test setup must produce a zero-cent object storage egress line item"
    );

    let finalize_resp = app
        .oneshot(
            Request::post(format!("/admin/invoices/{invoice_id}/finalize"))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(finalize_resp.status(), StatusCode::OK);

    let bucket_after = storage_bucket_repo.get(bucket.id).await.unwrap().unwrap();
    assert_eq!(
        bucket_after.egress_watermark_bytes,
        one_gb / 2,
        "watermark must advance from the draft snapshot even when billed egress is 0 cents"
    );
    let customer_after = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        customer_after.object_storage_egress_carryforward_cents,
        dec!(0.5),
        "zero-cent billed egress should persist as fractional carry-forward"
    );
}

#[tokio::test]
async fn admin_finalize_legacy_zero_cent_egress_without_metadata_still_succeeds() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    customer_repo
        .set_object_storage_egress_carryforward_cents(customer.id, dec!(0.6))
        .await
        .unwrap();

    let invoice = invoice_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 1, 31).unwrap(),
        0,
        0,
        false,
        vec![NewLineItem {
            description: "Object storage egress (legacy draft)".to_string(),
            quantity: dec!(0.5),
            unit: "object_storage_egress_gb".to_string(),
            unit_price_cents: dec!(1),
            amount_cents: 0,
            region: "us-east-1".to_string(),
            metadata: None,
        }],
    );

    let app = test_app_with_stripe(
        customer_repo.clone(),
        invoice_repo.clone(),
        mock_stripe_service(),
    );

    let resp = app
        .oneshot(
            Request::post(format!("/admin/invoices/{}/finalize", invoice.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    let finalized = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(finalized.status, "finalized");
    let customer_after = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        customer_after.object_storage_egress_carryforward_cents,
        dec!(0.6),
        "legacy zero-cent drafts without metadata should finalize without mutating carry-forward"
    );
}

// ===========================================================================
// POST /admin/customers/:id/sync-stripe
// ===========================================================================

#[tokio::test]
async fn sync_stripe_creates_customer() {
    let customer_repo = mock_repo();
    let stripe_svc = mock_stripe_service();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    // No stripe_customer_id yet

    let app = test_app_with_stripe(
        customer_repo.clone(),
        mock_invoice_repo(),
        stripe_svc.clone(),
    );

    let resp = app
        .oneshot(
            Request::post(format!("/admin/customers/{}/sync-stripe", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert!(body["stripe_customer_id"].as_str().is_some());
    assert!(body["message"]
        .as_str()
        .unwrap()
        .contains("created and linked"));

    // Verify Stripe customer was created in mock
    let customers = stripe_svc.customers.lock().unwrap();
    assert_eq!(customers.len(), 1);
    assert_eq!(customers[0].1, "Acme");

    // Verify customer repo was updated
    let updated = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert!(updated.stripe_customer_id.is_some());
}

#[tokio::test]
async fn sync_stripe_noop_if_already_linked() {
    let customer_repo = mock_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;

    let stripe_svc = mock_stripe_service();
    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), stripe_svc.clone());

    let resp = app
        .oneshot(
            Request::post(format!("/admin/customers/{}/sync-stripe", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert!(body["message"].as_str().unwrap().contains("already linked"));

    // Stripe service should NOT have been called
    let customers = stripe_svc.customers.lock().unwrap();
    assert_eq!(customers.len(), 0);
}

#[tokio::test]
async fn sync_stripe_404_unknown_customer() {
    let app = test_app_with_stripe(mock_repo(), mock_invoice_repo(), mock_stripe_service());

    let resp = app
        .oneshot(
            Request::post(format!("/admin/customers/{}/sync-stripe", Uuid::new_v4()))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn sync_stripe_404_deleted_customer() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_deleted("Deleted", "del@example.com");

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), mock_stripe_service());

    let resp = app
        .oneshot(
            Request::post(format!("/admin/customers/{}/sync-stripe", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ===========================================================================
// POST /admin/customers/:id/reactivate
// ===========================================================================

#[tokio::test]
async fn reactivate_suspended_customer_success() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    customer_repo.suspend(customer.id).await.unwrap();

    let app = test_app_with_stripe(
        customer_repo.clone(),
        mock_invoice_repo(),
        mock_stripe_service(),
    );

    let resp = app
        .oneshot(
            Request::post(format!("/admin/customers/{}/reactivate", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["message"], "customer reactivated");

    // Verify customer is active
    let updated = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(updated.status, "active");
}

#[tokio::test]
async fn reactivate_non_suspended_returns_400() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    // Customer is active, not suspended

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), mock_stripe_service());

    let resp = app
        .oneshot(
            Request::post(format!("/admin/customers/{}/reactivate", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = body_json(resp).await;
    assert_eq!(body["error"], "customer is not suspended");
}

#[tokio::test]
async fn reactivate_404_unknown_customer() {
    let app = test_app_with_stripe(mock_repo(), mock_invoice_repo(), mock_stripe_service());

    let resp = app
        .oneshot(
            Request::post(format!("/admin/customers/{}/reactivate", Uuid::new_v4()))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    let body = body_json(resp).await;
    assert_eq!(body["error"], "customer not found");
}

#[tokio::test]
async fn reactivate_deleted_customer_returns_400_without_calling_reactivate() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_deleted("Deleted Acme", "deleted-acme@example.com");
    let app = test_app_with_stripe(
        customer_repo.clone(),
        mock_invoice_repo(),
        mock_stripe_service(),
    );

    let resp = app
        .oneshot(
            Request::post(format!("/admin/customers/{}/reactivate", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = body_json(resp).await;
    assert_eq!(body, json!({ "error": "customer is not suspended" }));
    assert_eq!(
        customer_repo.reactivate_call_count(),
        0,
        "deleted customer pre-check must return 400 before calling reactivate"
    );

    // The deleted fixture is unchanged.
    let after = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .expect("deleted customer row is retained");
    assert_eq!(after.status, "deleted");
}

// ===========================================================================
// Register + Stripe integration
// ===========================================================================
//
// The register → Stripe-customer happy path is covered in
// `signup_abuse_test.rs`:
//   - `stripe_customer_is_created_only_after_email_verification`
//     (post-verification path under default config)
//   - `skip_email_verification_uses_shared_post_verification_stripe_path_exactly_once`
//     (SKIP_EMAIL_VERIFICATION + ENVIRONMENT=local bypass path)
// Those tests use the env-guard / serialization infra already wired up there.
// Do NOT re-add a register-only Stripe assertion here: post-Apr27, Stripe
// customer creation moved to the verify-email path, so a register-only
// assertion would either fail or pass for the wrong reason.

// `register_succeeds_even_if_stripe_fails` was removed: post-Apr27, register
// itself does not call Stripe, so the test was a no-op assertion (passing
// regardless of `stripe_svc.set_should_fail`). Stripe-failure resilience is
// now exercised through the verify-email best-effort path.

// ===========================================================================
// POST /admin/billing/run — batch billing
// ===========================================================================

fn test_rate_card() -> RateCardRow {
    RateCardRow {
        id: Uuid::new_v4(),
        name: "default".to_string(),
        effective_from: chrono::Utc::now(),
        effective_until: None,
        storage_rate_per_mb_month: dec!(0.20),
        region_multipliers: json!({}),
        minimum_spend_cents: 500,
        shared_minimum_spend_cents: 200,
        cold_storage_rate_per_gb_month: dec!(0.02),
        object_storage_rate_per_gb_month: dec!(0.024),
        object_storage_egress_rate_per_gb: dec!(0.01),
        created_at: chrono::Utc::now(),
    }
}

fn admin_summary_row(
    customer_id: Uuid,
    customer_name: &str,
    customer_email: &str,
    period_start: NaiveDate,
    total_cents: i64,
    status: &str,
) -> AdminInvoiceSummaryRow {
    AdminInvoiceSummaryRow {
        id: Uuid::new_v4(),
        customer_id,
        customer_name: customer_name.to_string(),
        customer_email: customer_email.to_string(),
        period_start,
        period_end: period_start
            .checked_add_days(chrono::Days::new(30))
            .expect("fixture period end"),
        subtotal_cents: total_cents,
        tax_cents: 0,
        total_cents,
        currency: "usd".to_string(),
        status: status.to_string(),
        minimum_applied: false,
        stripe_invoice_id: None,
        hosted_invoice_url: None,
        pdf_url: None,
        created_at: Utc::now(),
        finalized_at: None,
        paid_at: (status == "paid").then(Utc::now),
    }
}

async fn get_admin_billing_summary(
    app: axum::Router,
    admin_key: Option<&str>,
) -> axum::response::Response {
    let mut request = Request::get("/admin/billing/summary");
    if let Some(admin_key) = admin_key {
        request = request.header("x-admin-key", admin_key);
    }
    app.oneshot(request.body(Body::empty()).unwrap())
        .await
        .unwrap()
}

#[tokio::test]
async fn admin_billing_summary_sums_hand_calculated_dollars() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();

    let mut rate_card = test_rate_card();
    rate_card.shared_minimum_spend_cents = 400;
    rate_card_repo.seed_active_card(rate_card);

    let shared_a = seed_stripe_customer(&customer_repo, "Shared A", "shared-a@example.com").await;
    customer_repo
        .set_billing_plan(shared_a.id, "shared")
        .await
        .unwrap();
    let shared_b = seed_stripe_customer(&customer_repo, "Shared B", "shared-b@example.com").await;
    customer_repo
        .set_billing_plan(shared_b.id, "shared")
        .await
        .unwrap();
    let malformed_plan = seed_stripe_customer(
        &customer_repo,
        "Malformed Plan",
        "malformed-plan@example.com",
    )
    .await;
    customer_repo
        .set_billing_plan(malformed_plan.id, "malformed")
        .await
        .unwrap();
    let free = seed_stripe_customer(&customer_repo, "Free", "free-summary@example.com").await;
    customer_repo
        .set_billing_plan(free.id, "free")
        .await
        .unwrap();
    let suspended =
        seed_stripe_customer(&customer_repo, "Suspended", "suspended-summary@example.com").await;
    customer_repo
        .set_billing_plan(suspended.id, "shared")
        .await
        .unwrap();
    customer_repo.suspend(suspended.id).await.unwrap();

    let current = NaiveDate::from_ymd_opt(2026, 7, 1).unwrap();
    let preceding = NaiveDate::from_ymd_opt(2026, 6, 1).unwrap();
    invoice_repo.seed_revenue_summary_rows(vec![
        admin_summary_row(
            shared_a.id,
            "Shared A",
            "shared-a@example.com",
            current,
            1000,
            "paid",
        ),
        admin_summary_row(
            shared_b.id,
            "Shared B",
            "shared-b@example.com",
            current,
            2500,
            "paid",
        ),
        admin_summary_row(
            shared_a.id,
            "Shared A",
            "shared-a@example.com",
            preceding,
            500,
            "paid",
        ),
        admin_summary_row(
            shared_a.id,
            "Shared A",
            "shared-a@example.com",
            current,
            1000,
            "draft",
        ),
        admin_summary_row(
            shared_b.id,
            "Shared B",
            "shared-b@example.com",
            current,
            2000,
            "finalized",
        ),
        admin_summary_row(
            free.id,
            "Free",
            "free-summary@example.com",
            current,
            900,
            "failed",
        ),
        admin_summary_row(
            suspended.id,
            "Suspended",
            "suspended-summary@example.com",
            current,
            700,
            "refunded",
        ),
    ]);

    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .with_invoice_repo(invoice_repo.clone())
        .with_rate_card_repo(rate_card_repo.clone())
        .build_app();

    let resp = get_admin_billing_summary(app, Some(TEST_ADMIN_KEY)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;

    assert_eq!(body["status_totals"]["paid"]["total_cents"], 4000);
    assert_eq!(body["status_totals"]["paid"]["count"], 3);
    assert_eq!(body["status_totals"]["draft"]["total_cents"], 1000);
    assert_eq!(body["status_totals"]["draft"]["count"], 1);
    assert_eq!(body["status_totals"]["finalized"]["total_cents"], 2000);
    assert_eq!(body["status_totals"]["finalized"]["count"], 1);
    assert_eq!(body["status_totals"]["failed"]["total_cents"], 900);
    assert_eq!(body["status_totals"]["failed"]["count"], 1);
    assert_eq!(body["status_totals"]["refunded"]["total_cents"], 700);
    assert_eq!(body["status_totals"]["refunded"]["count"], 1);
    assert_eq!(body["pending_total_cents"], 3000);
    assert_eq!(body["pending_count"], 2);
    assert_eq!(body["total_count"], 7);
    assert_eq!(body["mrr_proxy_cents"], 1200);
    assert_eq!(body["by_month"][0]["month"], "2026-06");
    assert_eq!(body["by_month"][0]["paid_total_cents"], 500);
    assert_eq!(body["by_month"][1]["month"], "2026-07");
    assert_eq!(body["by_month"][1]["paid_total_cents"], 3500);
    assert_eq!(body["invoices"].as_array().unwrap().len(), 7);

    assert_eq!(invoice_repo.revenue_summary_call_count(), 1);
    assert_eq!(customer_repo.list_call_count(), 1);
    assert_eq!(rate_card_repo.get_active_call_count(), 1);
    assert_eq!(rate_card_repo.get_override_call_count(), 0);
}

#[tokio::test]
async fn admin_billing_summary_unknown_status_returns_500() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(test_rate_card());
    let customer =
        seed_stripe_customer(&customer_repo, "Unknown", "unknown-summary@example.com").await;
    invoice_repo.seed_revenue_summary_rows(vec![admin_summary_row(
        customer.id,
        "Unknown",
        "unknown-summary@example.com",
        NaiveDate::from_ymd_opt(2026, 7, 1).unwrap(),
        100,
        "void",
    )]);

    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_invoice_repo(invoice_repo)
        .with_rate_card_repo(rate_card_repo)
        .build_app();

    let resp = get_admin_billing_summary(app, Some(TEST_ADMIN_KEY)).await;
    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);
}

#[tokio::test]
async fn admin_billing_summary_checked_addition_overflow_returns_500() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(test_rate_card());
    let customer =
        seed_stripe_customer(&customer_repo, "Overflow", "overflow-summary@example.com").await;
    let month = NaiveDate::from_ymd_opt(2026, 7, 1).unwrap();
    invoice_repo.seed_revenue_summary_rows(vec![
        admin_summary_row(
            customer.id,
            "Overflow",
            "overflow-summary@example.com",
            month,
            i64::MAX,
            "paid",
        ),
        admin_summary_row(
            customer.id,
            "Overflow",
            "overflow-summary@example.com",
            month,
            1,
            "paid",
        ),
    ]);

    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_invoice_repo(invoice_repo)
        .with_rate_card_repo(rate_card_repo)
        .build_app();

    let resp = get_admin_billing_summary(app, Some(TEST_ADMIN_KEY)).await;
    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);
}

#[test]
fn admin_billing_summary_checked_multiplication_overflow_returns_error() {
    assert!(
        api::routes::admin::invoices::checked_revenue_product(i64::MAX, 2).is_err(),
        "MRR proxy multiplication must fail closed on overflow"
    );
}

#[tokio::test]
async fn admin_billing_summary_missing_key_returns_401() {
    let app = TestStateBuilder::new().build_app();
    let resp = get_admin_billing_summary(app, None).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn admin_billing_summary_wrong_key_returns_401() {
    let app = TestStateBuilder::new().build_app();
    let resp = get_admin_billing_summary(app, Some("not-the-admin-key")).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn batch_billing_run_creates_invoices() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let stripe_svc = mock_stripe_service();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();

    rate_card_repo.seed_active_card(test_rate_card());

    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    customer_repo
        .set_billing_plan(customer.id, "shared")
        .await
        .unwrap();

    // Seed usage for Jan 2026
    usage_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 1, 15).unwrap(),
        "us-east-1",
        10000,
        1000,
        0,
        0,
    );

    let state = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        invoice_repo.clone(),
        stripe_svc.clone(),
    );
    let app = api::router::build_router(state);

    let resp = app
        .oneshot(
            Request::post("/admin/billing/run")
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["invoices_created"], 1);
    assert_eq!(body["invoices_skipped"], 0);

    // Verify invoice was created and finalized
    let invoices = invoice_repo.list_by_customer(customer.id).await.unwrap();
    assert_eq!(invoices.len(), 1);
    assert_eq!(invoices[0].status, "finalized");
    assert!(invoices[0].stripe_invoice_id.is_some());
    assert!(invoices[0].hosted_invoice_url.is_some());

    // Verify Stripe invoice was created
    let stripe_invoices = stripe_svc.invoices_created.lock().unwrap();
    assert_eq!(stripe_invoices.len(), 1);
    let created = invoice_repo
        .find_by_id(invoices[0].id)
        .await
        .unwrap()
        .unwrap();
    let expected_key = invoice_create_idempotency_key(
        created.id,
        customer.id,
        created.period_start,
        created.period_end,
    );

    let calls = stripe_svc.create_and_finalize_calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].1.as_deref(), Some(expected_key.as_str()));
}

#[tokio::test]
async fn batch_billing_run_includes_cold_storage_when_no_hot_usage() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let stripe_svc = mock_stripe_service();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let cold_snapshot_repo = mock_cold_snapshot_repo();

    rate_card_repo.seed_active_card(test_rate_card());

    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    customer_repo
        .set_billing_plan(customer.id, "shared")
        .await
        .unwrap();

    // 200 GB cold snapshot should bill at 200 * $0.02 = $4.00 (400 cents).
    let snapshot = cold_snapshot_repo
        .create(NewColdSnapshot {
            customer_id: customer.id,
            tenant_id: "cold-only-index".to_string(),
            source_vm_id: Uuid::new_v4(),
            object_key: "cold/test/snapshot.fj".to_string(),
        })
        .await
        .expect("create snapshot");
    cold_snapshot_repo
        .set_exporting(snapshot.id)
        .await
        .expect("set exporting");
    cold_snapshot_repo
        .set_completed(snapshot.id, billing::types::BYTES_PER_GIB * 200, "abc123")
        .await
        .expect("set completed");

    let mut state = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        invoice_repo.clone(),
        stripe_svc,
    );
    state.cold_snapshot_repo = cold_snapshot_repo.clone();
    let app = api::router::build_router(state);

    // Use the persisted completion timestamp so the billing month always matches the snapshot.
    let completed_snapshot = cold_snapshot_repo
        .get(snapshot.id)
        .await
        .expect("load completed snapshot")
        .expect("completed snapshot should exist");
    let completed_at = completed_snapshot
        .completed_at
        .expect("completed snapshot should have completed_at");
    let body_str = json!({ "month": completed_at.format("%Y-%m").to_string() }).to_string();

    let resp = app
        .oneshot(
            Request::post("/admin/billing/run")
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(body_str))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["invoices_created"], 1);
    assert_eq!(body["invoices_skipped"], 0);

    let invoices = invoice_repo.list_by_customer(customer.id).await.unwrap();
    assert_eq!(invoices.len(), 1);
    assert_eq!(invoices[0].subtotal_cents, 400);
    // 400 cents cold storage > 200 shared minimum → no minimum applied
    assert_eq!(invoices[0].total_cents, 400);
    assert!(!invoices[0].minimum_applied);

    let line_items = invoice_repo.get_line_items(invoices[0].id).await.unwrap();
    let cold = line_items
        .iter()
        .find(|li| li.unit == "cold_gb_months")
        .expect("cold storage line item missing");
    assert_eq!(cold.amount_cents, 400);
}

#[tokio::test]
async fn batch_billing_run_shared_plan_uses_shared_minimum() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let stripe_svc = mock_stripe_service();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();

    rate_card_repo.seed_active_card(test_rate_card());

    let customer =
        seed_stripe_customer(&customer_repo, "Shared Acme", "shared-acme@example.com").await;
    customer_repo
        .set_billing_plan(customer.id, "shared")
        .await
        .unwrap();

    let state = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        invoice_repo.clone(),
        stripe_svc,
    );
    let app = api::router::build_router(state);

    let resp = app
        .oneshot(
            Request::post("/admin/billing/run")
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["invoices_created"], 1);
    assert_eq!(body["invoices_skipped"], 0);

    let invoices = invoice_repo.list_by_customer(customer.id).await.unwrap();
    assert_eq!(invoices.len(), 1);
    assert_eq!(invoices[0].subtotal_cents, 0);
    assert_eq!(invoices[0].total_cents, 200);
    assert!(invoices[0].minimum_applied);
}

#[tokio::test]
async fn batch_billing_run_unknown_plan_bills_with_shared_safe_fallback() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let stripe_svc = mock_stripe_service();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();

    rate_card_repo.seed_active_card(test_rate_card());

    let customer =
        seed_stripe_customer(&customer_repo, "Unknown Acme", "unknown-acme@example.com").await;
    customer_repo
        .set_billing_plan(customer.id, "enterprise")
        .await
        .unwrap();

    let state = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        invoice_repo.clone(),
        stripe_svc,
    );
    let app = api::router::build_router(state);

    let resp = app
        .oneshot(
            Request::post("/admin/billing/run")
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["invoices_created"], 1);
    assert_eq!(body["invoices_skipped"], 0);

    let results = body["results"].as_array().unwrap();
    assert_eq!(results[0]["status"], "created");
    assert_eq!(results[0]["reason"], serde_json::Value::Null);

    let invoices = invoice_repo.list_by_customer(customer.id).await.unwrap();
    assert_eq!(invoices.len(), 1);
    assert_eq!(invoices[0].total_cents, 200);
    assert!(
        invoices[0].minimum_applied,
        "unknown plans must use paid-safe minimum billing semantics"
    );
}

#[tokio::test]
async fn batch_billing_run_free_plan_customer_reported_skipped_with_no_invoice_rows() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();

    rate_card_repo.seed_active_card(test_rate_card());

    let free_customer = customer_repo.seed_verified_free_customer("Free", "free@example.com");

    usage_repo.seed(
        free_customer.id,
        NaiveDate::from_ymd_opt(2026, 1, 15).unwrap(),
        "us-east-1",
        20000,
        2000,
        0,
        0,
    );

    let state = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        invoice_repo.clone(),
        mock_stripe_service(),
    );
    let app = api::router::build_router(state);

    let resp = app
        .oneshot(
            Request::post("/admin/billing/run")
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["invoices_created"], 0);
    assert_eq!(body["invoices_skipped"], 1);
    let results = body["results"].as_array().unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0]["status"], "skipped");
    assert_eq!(results[0]["reason"], "free_plan");

    let invoices = invoice_repo
        .list_by_customer(free_customer.id)
        .await
        .unwrap();
    assert_eq!(invoices.len(), 0);
}

#[tokio::test]
async fn batch_billing_run_mixed_cohort_skips_free_and_creates_shared() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let stripe_svc = mock_stripe_service();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();

    rate_card_repo.seed_active_card(test_rate_card());

    let free_customer = customer_repo.seed_verified_free_customer("Free", "free@example.com");
    let shared_customer =
        seed_stripe_customer(&customer_repo, "Shared", "shared@example.com").await;
    customer_repo
        .set_billing_plan(shared_customer.id, "shared")
        .await
        .unwrap();

    usage_repo.seed(
        free_customer.id,
        NaiveDate::from_ymd_opt(2026, 1, 15).unwrap(),
        "us-east-1",
        20000,
        2000,
        0,
        0,
    );
    usage_repo.seed(
        shared_customer.id,
        NaiveDate::from_ymd_opt(2026, 1, 15).unwrap(),
        "us-east-1",
        10000,
        1000,
        0,
        0,
    );

    let state = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        invoice_repo.clone(),
        stripe_svc,
    );
    let app = api::router::build_router(state);

    let resp = app
        .oneshot(
            Request::post("/admin/billing/run")
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["invoices_created"], 1);
    assert_eq!(body["invoices_skipped"], 1);

    let results = body["results"].as_array().unwrap();
    let free_result = results
        .iter()
        .find(|result| result["customer_id"] == free_customer.id.to_string())
        .expect("free customer result missing");
    assert_eq!(free_result["status"], "skipped");
    assert_eq!(free_result["reason"], "free_plan");

    let shared_result = results
        .iter()
        .find(|result| result["customer_id"] == shared_customer.id.to_string())
        .expect("shared customer result missing");
    assert_eq!(shared_result["status"], "created");

    let free_invoices = invoice_repo
        .list_by_customer(free_customer.id)
        .await
        .unwrap();
    assert_eq!(free_invoices.len(), 0);

    let shared_invoices = invoice_repo
        .list_by_customer(shared_customer.id)
        .await
        .unwrap();
    assert_eq!(shared_invoices.len(), 1);
}

#[tokio::test]
async fn batch_billing_run_skips_existing_invoices() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let stripe_svc = mock_stripe_service();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();

    rate_card_repo.seed_active_card(test_rate_card());

    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    customer_repo
        .set_billing_plan(customer.id, "shared")
        .await
        .unwrap();

    // Seed usage
    usage_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 1, 15).unwrap(),
        "us-east-1",
        10000,
        1000,
        0,
        0,
    );

    // Pre-create an invoice for the same period
    invoice_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 1, 31).unwrap(),
        5000,
        5000,
        false,
        vec![],
    );

    let state = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        invoice_repo,
        stripe_svc,
    );
    let app = api::router::build_router(state);

    let resp = app
        .oneshot(
            Request::post("/admin/billing/run")
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["invoices_created"], 0);
    assert_eq!(body["invoices_skipped"], 1);

    let results = body["results"].as_array().unwrap();
    assert_eq!(results[0]["reason"], "already_invoiced");
}

#[tokio::test]
async fn batch_billing_run_skips_no_stripe_customer() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();

    rate_card_repo.seed_active_card(test_rate_card());

    // Customer without stripe_customer_id (shared plan to pass free-plan check)
    let customer = customer_repo.seed("NoStripe", "nostripe@example.com");
    customer_repo
        .set_billing_plan(customer.id, "shared")
        .await
        .unwrap();

    usage_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 1, 15).unwrap(),
        "us-east-1",
        10000,
        1000,
        0,
        0,
    );

    let state = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        invoice_repo,
        mock_stripe_service(),
    );
    let app = api::router::build_router(state);

    let resp = app
        .oneshot(
            Request::post("/admin/billing/run")
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["invoices_created"], 0);
    assert_eq!(body["invoices_skipped"], 1);

    let results = body["results"].as_array().unwrap();
    assert_eq!(results[0]["reason"], "no_stripe_account");
}

#[tokio::test]
async fn batch_billing_run_skips_suspended_customer() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();

    rate_card_repo.seed_active_card(test_rate_card());

    // Suspended customer with stripe — should be skipped
    let customer = seed_stripe_customer(&customer_repo, "Suspended", "sus@example.com").await;
    customer_repo.suspend(customer.id).await.unwrap();

    usage_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 1, 15).unwrap(),
        "us-east-1",
        10000,
        1000,
        0,
        0,
    );

    let state = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        invoice_repo,
        mock_stripe_service(),
    );
    let app = api::router::build_router(state);

    let resp = app
        .oneshot(
            Request::post("/admin/billing/run")
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["invoices_created"], 0);
    assert_eq!(body["invoices_skipped"], 1);

    let results = body["results"].as_array().unwrap();
    assert_eq!(results[0]["reason"], "customer_suspended");
}

#[tokio::test]
async fn batch_billing_run_400_invalid_month() {
    let app = test_app_with_stripe(mock_repo(), mock_invoice_repo(), mock_stripe_service());

    let resp = app
        .oneshot(
            Request::post("/admin/billing/run")
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"not-a-month"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn batch_billing_run_continues_on_stripe_failure() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let stripe_svc = mock_stripe_service();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();

    rate_card_repo.seed_active_card(test_rate_card());

    // Make Stripe fail — batch should still return OK with "failed" result
    stripe_svc.set_should_fail(true);

    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    customer_repo
        .set_billing_plan(customer.id, "shared")
        .await
        .unwrap();

    usage_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 1, 15).unwrap(),
        "us-east-1",
        10000,
        1000,
        0,
        0,
    );

    let state = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        invoice_repo.clone(),
        stripe_svc,
    );
    let app = api::router::build_router(state);

    let resp = app
        .oneshot(
            Request::post("/admin/billing/run")
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    // Should return 200 with per-customer error details, not 500
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["invoices_created"], 0);
    assert_eq!(body["invoices_skipped"], 1);

    let results = body["results"].as_array().unwrap();
    assert_eq!(results[0]["status"], "failed");
    assert!(
        results[0]["reason"]
            .as_str()
            .unwrap()
            .contains("stripe_error"),
        "reason should mention stripe_error"
    );

    // Draft invoice should still exist in DB (admin can retry manually)
    let invoices = invoice_repo.list_by_customer(customer.id).await.unwrap();
    assert_eq!(invoices.len(), 1);
    assert_eq!(invoices[0].status, "draft");
}

// ===========================================================================
// Suspended tenant — 403 enforcement
// ===========================================================================

#[tokio::test]
async fn suspended_customer_gets_403_on_usage() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    customer_repo.suspend(customer.id).await.unwrap();

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), mock_stripe_service());

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/usage")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn suspended_customer_gets_403_on_invoices() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    customer_repo.suspend(customer.id).await.unwrap();

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), mock_stripe_service());

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/invoices")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn suspended_customer_gets_403_on_billing() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    customer_repo.suspend(customer.id).await.unwrap();

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), mock_stripe_service());

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/setup-intent")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

// ===========================================================================
// Webhook edge cases — unknown invoices, status guards, missing fields
// ===========================================================================

#[tokio::test]
async fn webhook_payment_succeeded_unknown_invoice_returns_200() {
    let app = test_app_with_stripe(mock_repo(), mock_invoice_repo(), mock_stripe_service());

    // Stripe invoice ID doesn't match any local invoice — should still return 200
    let payload = r#"{"id":"evt_unk_pay","type":"invoice.payment_succeeded","data":{"object":{"id":"in_nonexistent"}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn webhook_payment_failed_unknown_invoice_returns_200() {
    let app = test_app_with_stripe(mock_repo(), mock_invoice_repo(), mock_stripe_service());

    let payload = r#"{"id":"evt_unk_fail","type":"invoice.payment_failed","data":{"object":{"id":"in_nonexistent","next_payment_attempt":null}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn webhook_charge_refunded_unknown_invoice_returns_200() {
    let app = test_app_with_stripe(mock_repo(), mock_invoice_repo(), mock_stripe_service());

    let payload = r#"{"id":"evt_unk_ref","type":"charge.refunded","data":{"object":{"id":"ch_999","invoice":"in_nonexistent"}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn webhook_charge_refunded_no_invoice_field_returns_200() {
    // Charge with no associated invoice — should be silently skipped
    let app = test_app_with_stripe(mock_repo(), mock_invoice_repo(), mock_stripe_service());

    let payload =
        r#"{"id":"evt_nofield","type":"charge.refunded","data":{"object":{"id":"ch_standalone"}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn webhook_charge_refunded_on_finalized_invoice_ignored() {
    // Invoice is finalized but not paid — refund should be silently ignored
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_refguard",
            "https://stripe.com/inv",
            None,
        )
        .await
        .unwrap();

    let app = test_app_with_stripe(customer_repo, invoice_repo.clone(), mock_stripe_service());

    let payload = format!(
        r#"{{"id":"evt_refguard","type":"charge.refunded","data":{{"object":{{"id":"ch_abc","invoice":"in_stripe_refguard"}}}}}}"#
    );
    let resp = app.oneshot(webhook_request(&payload)).await.unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    // Invoice should remain finalized — not refunded
    let updated = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(
        updated.status, "finalized",
        "refund on non-paid invoice must not change status"
    );
}

#[tokio::test]
async fn webhook_payment_succeeded_on_already_paid_invoice_ignored() {
    // Double payment_succeeded webhook — invoice already paid, should be idempotent
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_double",
            "https://stripe.com/inv",
            None,
        )
        .await
        .unwrap();
    invoice_repo.mark_paid(invoice.id).await.unwrap();

    let app = test_app_with_stripe(customer_repo, invoice_repo.clone(), mock_stripe_service());

    // Second payment_succeeded for same invoice (different event ID so not caught by idempotency)
    let payload = r#"{"id":"evt_double_pay","type":"invoice.payment_succeeded","data":{"object":{"id":"in_stripe_double"}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    // Invoice should still be paid — no error, no status change
    let updated = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "paid");
}

// ===========================================================================
// Batch billing — Free-plan skip
// ===========================================================================

#[tokio::test]
async fn batch_billing_run_skips_free_plan_customer() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();

    rate_card_repo.seed_active_card(test_rate_card());

    let free_customer = seed_stripe_customer(&customer_repo, "FreeCo", "free@example.com").await;

    usage_repo.seed(
        free_customer.id,
        NaiveDate::from_ymd_opt(2026, 1, 15).unwrap(),
        "us-east-1",
        1000,
        100,
        0,
        0,
    );

    let state = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        invoice_repo.clone(),
        mock_stripe_service(),
    );
    let app = api::router::build_router(state);

    let resp = app
        .oneshot(
            Request::post("/admin/billing/run")
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["invoices_created"], 0);
    assert_eq!(body["invoices_skipped"], 1);

    let results = body["results"].as_array().unwrap();
    assert_eq!(results[0]["status"], "skipped");
    assert_eq!(results[0]["reason"], "free_plan");

    let invoices = invoice_repo
        .list_by_customer(free_customer.id)
        .await
        .unwrap();
    assert_eq!(
        invoices.len(),
        0,
        "Free customer must have zero persisted invoice rows"
    );
}

#[tokio::test]
async fn batch_billing_run_mixed_cohort_skips_free_invoices_shared() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let stripe_svc = mock_stripe_service();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();

    rate_card_repo.seed_active_card(test_rate_card());

    // Shared customer — should be invoiced
    let shared = seed_stripe_customer(&customer_repo, "SharedCo", "shared@example.com").await;
    customer_repo
        .set_billing_plan(shared.id, "shared")
        .await
        .unwrap();
    usage_repo.seed(
        shared.id,
        NaiveDate::from_ymd_opt(2026, 1, 15).unwrap(),
        "us-east-1",
        10000,
        1000,
        0,
        0,
    );

    // Free customer — should be skipped
    let free = seed_stripe_customer(&customer_repo, "FreeCo", "free@example.com").await;
    usage_repo.seed(
        free.id,
        NaiveDate::from_ymd_opt(2026, 1, 15).unwrap(),
        "us-east-1",
        5000,
        500,
        0,
        0,
    );

    let state = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        invoice_repo.clone(),
        stripe_svc.clone(),
    );
    let app = api::router::build_router(state);

    let resp = app
        .oneshot(
            Request::post("/admin/billing/run")
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(
        body["invoices_created"], 1,
        "only the shared customer should be invoiced"
    );
    assert_eq!(
        body["invoices_skipped"], 1,
        "free customer should be skipped"
    );

    let results = body["results"].as_array().unwrap();
    let free_result = results
        .iter()
        .find(|r| r["customer_id"] == free.id.to_string())
        .expect("free customer must appear in results");
    assert_eq!(free_result["status"], "skipped");
    assert_eq!(free_result["reason"], "free_plan");

    let shared_result = results
        .iter()
        .find(|r| r["customer_id"] == shared.id.to_string())
        .expect("shared customer must appear in results");
    assert_eq!(shared_result["status"], "created");

    let free_invoices = invoice_repo.list_by_customer(free.id).await.unwrap();
    assert_eq!(
        free_invoices.len(),
        0,
        "Free customer must have zero persisted invoice rows"
    );

    let shared_invoices = invoice_repo.list_by_customer(shared.id).await.unwrap();
    assert_eq!(
        shared_invoices.len(),
        1,
        "Shared customer must have one invoice"
    );
}

// ===========================================================================
// Batch billing edge cases
// ===========================================================================

#[tokio::test]
async fn batch_billing_run_404_no_rate_card() {
    let app = test_app_with_stripe(mock_repo(), mock_invoice_repo(), mock_stripe_service());

    // No rate card seeded — should return 404
    let resp = app
        .oneshot(
            Request::post("/admin/billing/run")
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn batch_billing_run_multiple_customers_mixed() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let stripe_svc = mock_stripe_service();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();

    rate_card_repo.seed_active_card(test_rate_card());

    // Customer 1: active + shared + has Stripe + has usage → should get invoiced
    let c1 = seed_stripe_customer(&customer_repo, "Alpha", "alpha@example.com").await;
    customer_repo
        .set_billing_plan(c1.id, "shared")
        .await
        .unwrap();
    usage_repo.seed(
        c1.id,
        NaiveDate::from_ymd_opt(2026, 1, 15).unwrap(),
        "us-east-1",
        10000,
        1000,
        0,
        0,
    );

    // Customer 2: active + shared + has Stripe + has usage → should get invoiced
    let c2 = seed_stripe_customer(&customer_repo, "Beta", "beta@example.com").await;
    customer_repo
        .set_billing_plan(c2.id, "shared")
        .await
        .unwrap();
    usage_repo.seed(
        c2.id,
        NaiveDate::from_ymd_opt(2026, 1, 15).unwrap(),
        "us-east-1",
        5000,
        500,
        0,
        0,
    );

    // Customer 3: active but free plan → skipped
    let _c3 = customer_repo.seed("Gamma", "gamma@example.com");

    let state = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        invoice_repo.clone(),
        stripe_svc.clone(),
    );
    let app = api::router::build_router(state);

    let resp = app
        .oneshot(
            Request::post("/admin/billing/run")
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(
        body["invoices_created"], 2,
        "two eligible customers should be invoiced"
    );
    assert_eq!(
        body["invoices_skipped"], 1,
        "one free-plan customer should be skipped"
    );

    let results = body["results"].as_array().unwrap();
    assert_eq!(
        results.len(),
        3,
        "should have results for all three customers"
    );

    // Verify Stripe got 2 invoice creation calls
    let stripe_invoices = stripe_svc.invoices_created.lock().unwrap();
    assert_eq!(stripe_invoices.len(), 2);
}

// ===========================================================================
// Auth edge case — deleted customer
// ===========================================================================

#[tokio::test]
async fn deleted_customer_auth_returns_401() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_deleted("Gone Corp", "gone@example.com");

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), mock_stripe_service());

    // JWT is valid but customer is deleted — should return 401
    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/usage")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

// ===========================================================================
// Webhook malformed payloads — must return 200, never 500
// ===========================================================================

#[tokio::test]
async fn webhook_payment_succeeded_missing_invoice_id_returns_200() {
    // invoice.payment_succeeded with no data.object.id — should return 200, not 500
    let app = test_app_with_stripe(mock_repo(), mock_invoice_repo(), mock_stripe_service());

    let payload =
        r#"{"id":"evt_malformed_pay","type":"invoice.payment_succeeded","data":{"object":{}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "malformed webhook payload must return 200 to prevent Stripe retry loops"
    );
}

#[tokio::test]
async fn webhook_payment_failed_missing_invoice_id_returns_200() {
    // invoice.payment_failed with no data.object.id — should return 200, not 500
    let app = test_app_with_stripe(mock_repo(), mock_invoice_repo(), mock_stripe_service());

    let payload = r#"{"id":"evt_malformed_fail","type":"invoice.payment_failed","data":{"object":{"next_payment_attempt":null}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "malformed webhook payload must return 200 to prevent Stripe retry loops"
    );
}

// ===========================================================================
// 401 without auth — billing payment-method endpoints
// ===========================================================================

#[tokio::test]
async fn billing_unauthorized_routes_return_401() {
    let cases = billing_unauthorized_cases();
    assert_eq!(
        cases.len(),
        11,
        "billing unauthorized table must stay parity-matched with the deleted tests"
    );

    for case in cases {
        let resp = case.app().oneshot(case.request()).await.unwrap();

        assert_eq!(
            resp.status(),
            case.expected_status,
            "{} should return {:?}",
            case.name,
            case.expected_status
        );
    }
}

// ===========================================================================
// Suspended customer — 403 enforcement on billing payment-method endpoints
// ===========================================================================

#[tokio::test]
async fn suspended_customer_gets_403_on_list_payment_methods() {
    let customer_repo = mock_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    customer_repo.suspend(customer.id).await.unwrap();

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), mock_stripe_service());

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/billing/payment-methods")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn suspended_customer_gets_403_on_delete_payment_method() {
    let customer_repo = mock_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    customer_repo.suspend(customer.id).await.unwrap();

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), mock_stripe_service());

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::delete("/billing/payment-methods/pm_whatever")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn suspended_customer_gets_403_on_set_default_payment_method() {
    let customer_repo = mock_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    customer_repo.suspend(customer.id).await.unwrap();

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), mock_stripe_service());

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/payment-methods/pm_whatever/default")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

// ===========================================================================
// POST /billing/upgrade
// ===========================================================================

#[tokio::test]
async fn billing_upgrade_200_promotes_free_to_shared_after_successful_charge() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let stripe_svc = mock_stripe_service();
    let mut card = test_rate_card();
    card.shared_minimum_spend_cents = 1234;
    rate_card_repo.seed_active_card(card);

    let customer = seed_stripe_customer(&customer_repo, "Upgrade", "upgrade@example.com").await;
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_upgrade_default".to_string(),
        card_brand: "visa".to_string(),
        last4: "4242".to_string(),
        exp_month: 12,
        exp_year: 2030,
        is_default: false,
    });
    *stripe_svc.default_pm.lock().unwrap() = Some("pm_upgrade_default".to_string());
    stripe_svc.set_pay_invoice_result_default(PaidInvoice {
        id: "in_mock_default".to_string(),
        status: "paid".to_string(),
        amount_paid_cents: 1234,
        last_payment_error: None,
    });

    let app = test_app_with_upgrade_dependencies(
        customer_repo.clone(),
        invoice_repo,
        rate_card_repo.clone(),
        stripe_svc.clone(),
    );
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::post("/billing/upgrade")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["billing_plan"], "shared");
    assert_eq!(body["activation_amount_cents"], 1234);
    assert!(body["subscription_cycle_anchor_at"].is_string());
    assert!(body["stripe_invoice_id"].is_string());

    let upgraded = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .expect("customer should still exist after upgrade");
    assert_eq!(upgraded.billing_plan, "shared");
    assert!(
        upgraded.subscription_cycle_anchor_at.is_some(),
        "successful upgrade must persist cycle anchor"
    );

    assert_eq!(rate_card_repo.get_active_call_count(), 1);
    assert_eq!(
        stripe_svc.create_and_finalize_calls.lock().unwrap().len(),
        1
    );
    assert_eq!(stripe_svc.pay_invoice_calls.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn billing_upgrade_200_accepts_submicro_anchor_drift_after_paid_charge() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let stripe_svc = mock_stripe_service();
    let mut card = test_rate_card();
    card.shared_minimum_spend_cents = 1450;
    rate_card_repo.seed_active_card(card);

    let customer = seed_stripe_customer(
        &customer_repo,
        "Upgrade Precision Drift",
        "upgrade-precision-drift@example.com",
    )
    .await;
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_upgrade_precision_drift".to_string(),
        card_brand: "visa".to_string(),
        last4: "5151".to_string(),
        exp_month: 11,
        exp_year: 2031,
        is_default: false,
    });
    *stripe_svc.default_pm.lock().unwrap() = Some("pm_upgrade_precision_drift".to_string());
    stripe_svc.set_pay_invoice_result_default(PaidInvoice {
        id: "in_mock_default".to_string(),
        status: "paid".to_string(),
        amount_paid_cents: 1450,
        last_payment_error: None,
    });

    let customer_repo_for_callback = customer_repo.clone();
    stripe_svc.set_on_pay_invoice(Arc::new(move || {
        customer_repo_for_callback.nudge_subscription_cycle_anchor_submicro_for_test(customer.id);
    }));

    let app = test_app_with_upgrade_dependencies(
        customer_repo.clone(),
        invoice_repo,
        rate_card_repo.clone(),
        stripe_svc.clone(),
    );
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::post("/billing/upgrade")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["billing_plan"], "shared");
    assert_eq!(body["activation_amount_cents"], 1450);
    assert!(
        body["subscription_cycle_anchor_at"].is_string(),
        "response should keep successful upgrade contract even with sub-micro anchor drift"
    );
    assert_eq!(
        stripe_svc.void_invoice_calls.lock().unwrap().len(),
        0,
        "sub-micro anchor drift should not trigger rollback+void against a paid invoice"
    );
}

#[tokio::test]
async fn billing_upgrade_400_without_stripe_customer_id() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let stripe_svc = mock_stripe_service();
    rate_card_repo.seed_active_card(test_rate_card());

    let customer = customer_repo.seed("No Stripe", "nostripe@example.com");
    let app = test_app_with_upgrade_dependencies(
        customer_repo.clone(),
        invoice_repo,
        rate_card_repo,
        stripe_svc.clone(),
    );
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::post("/billing/upgrade")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = body_json(resp).await;
    assert_eq!(body["error"], "no stripe customer linked");
    assert_eq!(
        stripe_svc.create_and_finalize_calls.lock().unwrap().len(),
        0
    );
}

#[tokio::test]
async fn billing_upgrade_400_without_default_payment_method() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let stripe_svc = mock_stripe_service();
    rate_card_repo.seed_active_card(test_rate_card());

    let customer =
        seed_stripe_customer(&customer_repo, "No Default PM", "no-default-pm@example.com").await;
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_non_default".to_string(),
        card_brand: "visa".to_string(),
        last4: "0005".to_string(),
        exp_month: 8,
        exp_year: 2029,
        is_default: false,
    });
    let app = test_app_with_upgrade_dependencies(
        customer_repo.clone(),
        invoice_repo,
        rate_card_repo,
        stripe_svc.clone(),
    );
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::post("/billing/upgrade")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = body_json(resp).await;
    assert_eq!(body["error"], "default payment method required");
    assert_eq!(
        stripe_svc.create_and_finalize_calls.lock().unwrap().len(),
        0
    );
}

#[tokio::test]
async fn billing_upgrade_402_on_declined_payment_and_rolls_back_free_plan() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let stripe_svc = mock_stripe_service();
    rate_card_repo.seed_active_card(test_rate_card());

    let customer = seed_stripe_customer(&customer_repo, "Decline", "decline@example.com").await;
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_decline_default".to_string(),
        card_brand: "visa".to_string(),
        last4: "0341".to_string(),
        exp_month: 9,
        exp_year: 2028,
        is_default: false,
    });
    *stripe_svc.default_pm.lock().unwrap() = Some("pm_decline_default".to_string());
    stripe_svc.set_pay_invoice_result_default(PaidInvoice {
        id: "in_mock_default".to_string(),
        status: "open".to_string(),
        amount_paid_cents: 0,
        last_payment_error: Some(StripeLastPaymentError {
            code: Some("card_declined".to_string()),
            decline_code: Some("insufficient_funds".to_string()),
            message: Some("declined".to_string()),
        }),
    });

    let app = test_app_with_upgrade_dependencies(
        customer_repo.clone(),
        invoice_repo,
        rate_card_repo,
        stripe_svc.clone(),
    );
    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/upgrade")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::PAYMENT_REQUIRED);
    let body = body_json(resp).await;
    assert_eq!(body["error"], "payment_required");
    assert_eq!(body["code"], "card_declined");

    let reverted = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .expect("customer should still exist after rollback");
    assert_eq!(reverted.billing_plan, "free");
    assert_eq!(reverted.subscription_cycle_anchor_at, None);
    let created_invoice_id = stripe_svc.invoices_created.lock().unwrap()[0]
        .stripe_invoice_id
        .clone();
    let void_calls = stripe_svc.void_invoice_calls.lock().unwrap();
    assert_eq!(void_calls.len(), 1);
    assert_eq!(void_calls[0], created_invoice_id);
}

#[tokio::test]
async fn billing_upgrade_402_on_requires_action_and_rolls_back_free_plan() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let stripe_svc = mock_stripe_service();
    rate_card_repo.seed_active_card(test_rate_card());

    let customer = seed_stripe_customer(
        &customer_repo,
        "Action Required",
        "action-required@example.com",
    )
    .await;
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_action_default".to_string(),
        card_brand: "visa".to_string(),
        last4: "3184".to_string(),
        exp_month: 10,
        exp_year: 2029,
        is_default: false,
    });
    *stripe_svc.default_pm.lock().unwrap() = Some("pm_action_default".to_string());
    stripe_svc.set_pay_invoice_result_default(PaidInvoice {
        id: "in_mock_default".to_string(),
        status: "open".to_string(),
        amount_paid_cents: 0,
        last_payment_error: Some(StripeLastPaymentError {
            code: Some("invoice_payment_intent_requires_action".to_string()),
            decline_code: None,
            message: Some("action required".to_string()),
        }),
    });

    let app = test_app_with_upgrade_dependencies(
        customer_repo.clone(),
        invoice_repo,
        rate_card_repo,
        stripe_svc.clone(),
    );
    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/upgrade")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::PAYMENT_REQUIRED);
    let body = body_json(resp).await;
    assert_eq!(body["error"], "payment_required");
    assert_eq!(body["code"], "invoice_payment_intent_requires_action");

    let reverted = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .expect("customer should still exist after rollback");
    assert_eq!(reverted.billing_plan, "free");
    assert_eq!(reverted.subscription_cycle_anchor_at, None);
    let created_invoice_id = stripe_svc.invoices_created.lock().unwrap()[0]
        .stripe_invoice_id
        .clone();
    let void_calls = stripe_svc.void_invoice_calls.lock().unwrap();
    assert_eq!(void_calls.len(), 1);
    assert_eq!(void_calls[0], created_invoice_id);
}

#[tokio::test]
async fn billing_upgrade_409_when_atomic_upgrade_claim_is_lost_without_duplicate_invoice_creation()
{
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let stripe_svc = mock_stripe_service();
    rate_card_repo.seed_active_card(test_rate_card());

    let customer = seed_stripe_customer(
        &customer_repo,
        "Already Shared",
        "already-shared@example.com",
    )
    .await;
    customer_repo
        .set_billing_plan(customer.id, "shared")
        .await
        .unwrap();
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_existing_default".to_string(),
        card_brand: "visa".to_string(),
        last4: "1111".to_string(),
        exp_month: 1,
        exp_year: 2030,
        is_default: false,
    });
    *stripe_svc.default_pm.lock().unwrap() = Some("pm_existing_default".to_string());

    let app = test_app_with_upgrade_dependencies(
        customer_repo.clone(),
        invoice_repo,
        rate_card_repo,
        stripe_svc.clone(),
    );
    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/upgrade")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CONFLICT);
    assert_eq!(
        stripe_svc.create_and_finalize_calls.lock().unwrap().len(),
        0
    );
    assert_eq!(stripe_svc.invoices_created.lock().unwrap().len(), 0);
}

#[tokio::test]
async fn billing_upgrade_rolls_back_and_voids_invoice_when_post_charge_validation_fails() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let stripe_svc = mock_stripe_service();
    let mut card = test_rate_card();
    card.shared_minimum_spend_cents = 1200;
    rate_card_repo.seed_active_card(card);

    let customer =
        seed_stripe_customer(&customer_repo, "Void Rollback", "void-rollback@example.com").await;
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_void_default".to_string(),
        card_brand: "visa".to_string(),
        last4: "2222".to_string(),
        exp_month: 2,
        exp_year: 2031,
        is_default: false,
    });
    *stripe_svc.default_pm.lock().unwrap() = Some("pm_void_default".to_string());
    stripe_svc.set_pay_invoice_result_default(PaidInvoice {
        id: "in_mock_default".to_string(),
        status: "paid".to_string(),
        amount_paid_cents: 100,
        last_payment_error: None,
    });

    let app = test_app_with_upgrade_dependencies(
        customer_repo.clone(),
        invoice_repo,
        rate_card_repo,
        stripe_svc.clone(),
    );
    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/upgrade")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);
    let reverted = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .expect("customer should still exist after rollback");
    assert_eq!(reverted.billing_plan, "free");
    assert_eq!(reverted.subscription_cycle_anchor_at, None);
    assert_eq!(stripe_svc.void_invoice_calls.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn billing_upgrade_attempts_invoice_void_when_rollback_plan_reset_fails() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let stripe_svc = mock_stripe_service();
    let mut card = test_rate_card();
    card.shared_minimum_spend_cents = 1200;
    rate_card_repo.seed_active_card(card);

    let customer = seed_stripe_customer(
        &customer_repo,
        "Rollback Fails",
        "rollback-fails@example.com",
    )
    .await;
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_rollback_fails".to_string(),
        card_brand: "visa".to_string(),
        last4: "1881".to_string(),
        exp_month: 8,
        exp_year: 2033,
        is_default: false,
    });
    *stripe_svc.default_pm.lock().unwrap() = Some("pm_rollback_fails".to_string());
    stripe_svc.set_pay_invoice_result_default(PaidInvoice {
        id: "in_mock_default".to_string(),
        status: "paid".to_string(),
        amount_paid_cents: 100,
        last_payment_error: None,
    });

    customer_repo.fail_next_set_billing_plan();

    let app = test_app_with_upgrade_dependencies(
        customer_repo.clone(),
        invoice_repo,
        rate_card_repo,
        stripe_svc.clone(),
    );
    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/upgrade")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(
        stripe_svc.void_invoice_calls.lock().unwrap().len(),
        1,
        "invoice void should still be attempted even when rollback reset fails"
    );
    let persisted = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .expect("customer should still exist");
    assert_eq!(
        persisted.billing_plan, "shared",
        "rollback persistence failure should leave prior shared state untouched"
    );
    assert!(
        persisted.subscription_cycle_anchor_at.is_some(),
        "rollback persistence failure should preserve the claimed shared anchor"
    );
}

#[tokio::test]
async fn billing_upgrade_rollback_does_not_partially_reset_plan_when_anchor_reset_fails() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let stripe_svc = mock_stripe_service();
    let mut card = test_rate_card();
    card.shared_minimum_spend_cents = 1200;
    rate_card_repo.seed_active_card(card);

    let customer = seed_stripe_customer(
        &customer_repo,
        "Anchor Reset Fails",
        "anchor-reset-fails@example.com",
    )
    .await;
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_anchor_reset_fails".to_string(),
        card_brand: "visa".to_string(),
        last4: "6781".to_string(),
        exp_month: 8,
        exp_year: 2035,
        is_default: false,
    });
    *stripe_svc.default_pm.lock().unwrap() = Some("pm_anchor_reset_fails".to_string());
    stripe_svc.set_pay_invoice_result_default(PaidInvoice {
        id: "in_mock_default".to_string(),
        status: "paid".to_string(),
        amount_paid_cents: 100,
        last_payment_error: None,
    });
    customer_repo.fail_next_set_subscription_cycle_anchor();

    let app = test_app_with_upgrade_dependencies(
        customer_repo.clone(),
        invoice_repo,
        rate_card_repo,
        stripe_svc.clone(),
    );
    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/upgrade")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(
        stripe_svc.void_invoice_calls.lock().unwrap().len(),
        1,
        "invoice void should still be attempted when rollback persistence fails"
    );
    let persisted = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .expect("customer should still exist");
    assert_eq!(
        persisted.billing_plan, "shared",
        "failed rollback persistence must not leave a partial free-plan write"
    );
    assert!(
        persisted.subscription_cycle_anchor_at.is_some(),
        "failed rollback persistence must preserve original upgrade anchor"
    );
}

#[tokio::test]
async fn billing_upgrade_same_day_retry_uses_distinct_activation_idempotency_keys() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let stripe_svc = mock_stripe_service();
    rate_card_repo.seed_active_card(test_rate_card());

    let customer = seed_stripe_customer(&customer_repo, "Retry Key", "retry-key@example.com").await;
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_retry_default".to_string(),
        card_brand: "visa".to_string(),
        last4: "1881".to_string(),
        exp_month: 3,
        exp_year: 2032,
        is_default: false,
    });
    *stripe_svc.default_pm.lock().unwrap() = Some("pm_retry_default".to_string());
    stripe_svc.set_pay_invoice_result_default(PaidInvoice {
        id: "in_mock_default".to_string(),
        status: "open".to_string(),
        amount_paid_cents: 0,
        last_payment_error: Some(StripeLastPaymentError {
            code: Some("card_declined".to_string()),
            decline_code: Some("insufficient_funds".to_string()),
            message: Some("declined".to_string()),
        }),
    });

    let app = test_app_with_upgrade_dependencies(
        customer_repo.clone(),
        invoice_repo,
        rate_card_repo,
        stripe_svc.clone(),
    );
    let jwt = create_test_jwt(customer.id);

    let first = app
        .clone()
        .oneshot(
            Request::post("/billing/upgrade")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::PAYMENT_REQUIRED);

    let second = app
        .oneshot(
            Request::post("/billing/upgrade")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(second.status(), StatusCode::PAYMENT_REQUIRED);

    let calls = stripe_svc.create_and_finalize_calls.lock().unwrap();
    assert_eq!(calls.len(), 2);
    let first_key = calls[0].1.clone().expect("first upgrade should set key");
    let second_key = calls[1].1.clone().expect("second upgrade should set key");
    assert_ne!(
        first_key, second_key,
        "same-day retries must not reuse activation invoice idempotency keys"
    );
}

#[tokio::test]
async fn billing_upgrade_rolls_back_and_voids_invoice_when_persisted_state_is_missing_after_charge()
{
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let stripe_svc = mock_stripe_service();
    let mut card = test_rate_card();
    card.shared_minimum_spend_cents = 1300;
    rate_card_repo.seed_active_card(card);

    let customer = seed_stripe_customer(&customer_repo, "No Reload", "no-reload@example.com").await;
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_no_reload_default".to_string(),
        card_brand: "visa".to_string(),
        last4: "7711".to_string(),
        exp_month: 7,
        exp_year: 2032,
        is_default: false,
    });
    *stripe_svc.default_pm.lock().unwrap() = Some("pm_no_reload_default".to_string());
    stripe_svc.set_pay_invoice_result_default(PaidInvoice {
        id: "in_mock_default".to_string(),
        status: "paid".to_string(),
        amount_paid_cents: 1300,
        last_payment_error: None,
    });

    let customer_repo_for_callback = customer_repo.clone();
    stripe_svc.set_on_pay_invoice(Arc::new(move || {
        customer_repo_for_callback.clear_subscription_cycle_anchor_for_test(customer.id);
    }));

    let app = test_app_with_upgrade_dependencies(
        customer_repo.clone(),
        invoice_repo,
        rate_card_repo,
        stripe_svc.clone(),
    );
    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/upgrade")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);
    let reverted = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .expect("customer should still exist after rollback");
    assert_eq!(reverted.billing_plan, "free");
    assert_eq!(reverted.subscription_cycle_anchor_at, None);
    assert_eq!(stripe_svc.void_invoice_calls.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn billing_upgrade_voids_invoice_when_persisted_anchor_mismatches_claimed_anchor() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let stripe_svc = mock_stripe_service();
    let mut card = test_rate_card();
    card.shared_minimum_spend_cents = 1300;
    rate_card_repo.seed_active_card(card);

    let customer = seed_stripe_customer(
        &customer_repo,
        "Mismatched Anchor",
        "mismatched-anchor@example.com",
    )
    .await;
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_mismatched_anchor_default".to_string(),
        card_brand: "visa".to_string(),
        last4: "6321".to_string(),
        exp_month: 9,
        exp_year: 2033,
        is_default: false,
    });
    *stripe_svc.default_pm.lock().unwrap() = Some("pm_mismatched_anchor_default".to_string());
    stripe_svc.set_pay_invoice_result_default(PaidInvoice {
        id: "in_mock_default".to_string(),
        status: "paid".to_string(),
        amount_paid_cents: 1300,
        last_payment_error: None,
    });

    let customer_repo_for_callback = customer_repo.clone();
    stripe_svc.set_on_pay_invoice(Arc::new(move || {
        customer_repo_for_callback.set_subscription_cycle_anchor_for_test(
            customer.id,
            chrono::Utc::now() + chrono::Duration::minutes(5),
        );
    }));

    let app = test_app_with_upgrade_dependencies(
        customer_repo.clone(),
        invoice_repo,
        rate_card_repo,
        stripe_svc.clone(),
    );
    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/upgrade")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);
    let reverted = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .expect("customer should still exist after rollback");
    assert_eq!(
        reverted.billing_plan, "free",
        "mismatched persisted anchor must still restore customer plan to free"
    );
    assert_eq!(
        reverted.subscription_cycle_anchor_at, None,
        "mismatched persisted anchor must clear subscription anchor on rollback"
    );
    assert_eq!(
        stripe_svc.void_invoice_calls.lock().unwrap().len(),
        1,
        "paid activation invoice must be voided when persisted anchor mismatches claimed anchor"
    );
}

#[tokio::test]
async fn billing_upgrade_voids_invoice_when_post_charge_customer_reload_is_missing() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let stripe_svc = mock_stripe_service();
    let mut card = test_rate_card();
    card.shared_minimum_spend_cents = 1300;
    rate_card_repo.seed_active_card(card);

    let customer = seed_stripe_customer(
        &customer_repo,
        "Deleted Reload",
        "deleted-reload@example.com",
    )
    .await;
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_deleted_reload_default".to_string(),
        card_brand: "visa".to_string(),
        last4: "7631".to_string(),
        exp_month: 1,
        exp_year: 2034,
        is_default: false,
    });
    *stripe_svc.default_pm.lock().unwrap() = Some("pm_deleted_reload_default".to_string());
    stripe_svc.set_pay_invoice_result_default(PaidInvoice {
        id: "in_mock_default".to_string(),
        status: "paid".to_string(),
        amount_paid_cents: 1300,
        last_payment_error: None,
    });
    let customer_repo_for_callback = customer_repo.clone();
    stripe_svc.set_on_pay_invoice(Arc::new(move || {
        customer_repo_for_callback.delete_customer_for_test(customer.id);
    }));

    let app = test_app_with_upgrade_dependencies(
        customer_repo,
        invoice_repo,
        rate_card_repo,
        stripe_svc.clone(),
    );
    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/upgrade")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(
        stripe_svc.void_invoice_calls.lock().unwrap().len(),
        1,
        "paid activation invoice must be voided even when persisted reload returns no customer"
    );
}

#[tokio::test]
async fn billing_upgrade_voids_invoice_when_post_charge_customer_reload_errors() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let stripe_svc = mock_stripe_service();
    let mut card = test_rate_card();
    card.shared_minimum_spend_cents = 1300;
    rate_card_repo.seed_active_card(card);

    let customer = seed_stripe_customer(
        &customer_repo,
        "Errored Reload",
        "errored-reload@example.com",
    )
    .await;
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_errored_reload_default".to_string(),
        card_brand: "visa".to_string(),
        last4: "6471".to_string(),
        exp_month: 6,
        exp_year: 2034,
        is_default: false,
    });
    *stripe_svc.default_pm.lock().unwrap() = Some("pm_errored_reload_default".to_string());
    stripe_svc.set_pay_invoice_result_default(PaidInvoice {
        id: "in_mock_default".to_string(),
        status: "paid".to_string(),
        amount_paid_cents: 1300,
        last_payment_error: None,
    });
    let customer_repo_for_callback = customer_repo.clone();
    stripe_svc.set_on_pay_invoice(Arc::new(move || {
        customer_repo_for_callback.fail_next_find_by_id();
    }));

    let app = test_app_with_upgrade_dependencies(
        customer_repo,
        invoice_repo,
        rate_card_repo,
        stripe_svc.clone(),
    );
    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::post("/billing/upgrade")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(
        stripe_svc.void_invoice_calls.lock().unwrap().len(),
        1,
        "paid activation invoice must be voided even when persisted reload errors"
    );
}

// ===========================================================================
// GET /account/upgrade-status
// ===========================================================================

#[tokio::test]
async fn account_upgrade_status_reports_upgrade_ready_when_default_payment_method_exists() {
    let customer_repo = mock_repo();
    let customer =
        seed_stripe_customer(&customer_repo, "Upgrade Ready", "upgrade-ready@example.com").await;
    let stripe_svc = mock_stripe_service();
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_ready_default".to_string(),
        card_brand: "visa".to_string(),
        last4: "9999".to_string(),
        exp_month: 11,
        exp_year: 2032,
        is_default: false,
    });
    *stripe_svc.default_pm.lock().unwrap() = Some("pm_ready_default".to_string());
    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), stripe_svc);

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/account/upgrade-status")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(
        body["stripe_customer_id"],
        customer.stripe_customer_id.unwrap()
    );
    assert_eq!(body["has_default_payment_method"], true);
    assert_eq!(body["upgrade_ready"], true);
}

#[tokio::test]
async fn account_upgrade_status_reports_not_ready_without_stripe_customer_and_profile_shape_is_unchanged(
) {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("No Stripe", "account-status@example.com");
    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), mock_stripe_service());

    let jwt = create_test_jwt(customer.id);
    let status_resp = app
        .clone()
        .oneshot(
            Request::get("/account/upgrade-status")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(status_resp.status(), StatusCode::OK);
    let status_body = body_json(status_resp).await;
    assert_eq!(status_body["stripe_customer_id"], serde_json::Value::Null);
    assert_eq!(status_body["has_default_payment_method"], false);
    assert_eq!(status_body["upgrade_ready"], false);

    let profile_resp = app
        .oneshot(
            Request::get("/account")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(profile_resp.status(), StatusCode::OK);
    let profile_body = body_json(profile_resp).await;
    assert!(
        profile_body.get("upgrade_ready").is_none(),
        "CustomerProfileResponse must remain unchanged for /account"
    );
    assert!(
        profile_body.get("has_default_payment_method").is_none(),
        "CustomerProfileResponse must remain unchanged for /account"
    );
}

#[tokio::test]
async fn account_upgrade_status_reports_not_ready_for_existing_shared_customer() {
    let customer_repo = mock_repo();
    let customer = seed_stripe_customer(
        &customer_repo,
        "Already Shared Status",
        "already-shared-status@example.com",
    )
    .await;
    customer_repo
        .set_billing_plan(customer.id, "shared")
        .await
        .unwrap();
    let stripe_svc = mock_stripe_service();
    stripe_svc.seed_payment_method(PaymentMethodSummary {
        id: "pm_shared_status_default".to_string(),
        card_brand: "visa".to_string(),
        last4: "9087".to_string(),
        exp_month: 12,
        exp_year: 2034,
        is_default: false,
    });
    *stripe_svc.default_pm.lock().unwrap() = Some("pm_shared_status_default".to_string());

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), stripe_svc);
    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/account/upgrade-status")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["has_default_payment_method"], true);
    assert_eq!(
        body["upgrade_ready"], false,
        "shared customers are ineligible for free-to-shared upgrade and must not be marked ready"
    );
}

// ===========================================================================
// Stage 5: End-to-End Commerce Pipeline Tests
// ===========================================================================

#[tokio::test]
async fn legacy_subscription_routes_return_404_and_preserved_billing_routes_remain_reachable() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let stripe_service = mock_stripe_service();

    rate_card_repo.seed_active_card(test_rate_card());

    let customer =
        seed_stripe_customer(&customer_repo, "Pipeline Test", "pipeline@example.com").await;
    let seeded_invoice = seed_draft_invoice(&invoice_repo, customer.id);

    let state = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        invoice_repo,
        stripe_service,
    );
    let app = api::router::build_router(state);

    let jwt = create_test_jwt(customer.id);
    let auth = format!("Bearer {jwt}");

    let checkout_resp = app
        .clone()
        .oneshot(
            Request::post("/billing/checkout-session")
                .header("authorization", auth.as_str())
                .header("content-type", "application/json")
                .body(Body::from(json!({"plan_tier":"starter"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(checkout_resp.status(), StatusCode::NOT_FOUND);

    let subscription_resp = app
        .clone()
        .oneshot(
            Request::get("/billing/subscription")
                .header("authorization", auth.as_str())
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(subscription_resp.status(), StatusCode::NOT_FOUND);

    let cancel_resp = app
        .clone()
        .oneshot(
            Request::post("/billing/subscription/cancel")
                .header("authorization", auth.as_str())
                .header("content-type", "application/json")
                .body(Body::from(json!({"cancel_at_period_end":true}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(cancel_resp.status(), StatusCode::NOT_FOUND);

    let upgrade_resp = app
        .clone()
        .oneshot(
            Request::post("/billing/subscription/upgrade")
                .header("authorization", auth.as_str())
                .header("content-type", "application/json")
                .body(Body::from(json!({"plan_tier":"pro"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(upgrade_resp.status(), StatusCode::NOT_FOUND);

    let downgrade_resp = app
        .clone()
        .oneshot(
            Request::post("/billing/subscription/downgrade")
                .header("authorization", auth.as_str())
                .header("content-type", "application/json")
                .body(Body::from(json!({"plan_tier":"starter"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(downgrade_resp.status(), StatusCode::NOT_FOUND);

    let setup_intent_resp = app
        .clone()
        .oneshot(
            Request::post("/billing/setup-intent")
                .header("authorization", auth.as_str())
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(setup_intent_resp.status(), StatusCode::OK);

    let portal_resp = app
        .clone()
        .oneshot(
            Request::post("/billing/portal")
                .header("authorization", auth.as_str())
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({"return_url":"http://localhost:5173/console"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(portal_resp.status(), StatusCode::OK);

    let estimate_resp = app
        .clone()
        .oneshot(
            Request::get("/billing/estimate?month=2026-03")
                .header("authorization", auth.as_str())
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(estimate_resp.status(), StatusCode::OK);

    let invoices_resp = app
        .clone()
        .oneshot(
            Request::get("/invoices")
                .header("authorization", auth.as_str())
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(invoices_resp.status(), StatusCode::OK);

    let invoice_detail_resp = app
        .oneshot(
            Request::get(format!("/invoices/{}", seeded_invoice.id))
                .header("authorization", auth.as_str())
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(invoice_detail_resp.status(), StatusCode::OK);
}

/// Test: Complete usage-to-payment pipeline
/// usage accumulation → monthly billing run → invoice finalized → payment confirmation webhook
#[tokio::test]
async fn commerce_pipeline_usage_to_payment_confirmation() {
    // -------------------------------------------------------------------------
    // Setup: Create customer with Stripe ID and seed usage data
    // -------------------------------------------------------------------------
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let stripe_svc = mock_stripe_service();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();

    rate_card_repo.seed_active_card(test_rate_card());

    let customer =
        seed_stripe_customer(&customer_repo, "Usage Pipeline", "usage@example.com").await;
    customer_repo
        .set_billing_plan(customer.id, "shared")
        .await
        .unwrap();

    // Seed usage for March 2026 (hot storage drives billable line items).
    usage_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 3, 15).unwrap(),
        "us-east-1",
        10000,                               // search_requests (metering only)
        1000,                                // write_operations (metering only)
        billing::types::BYTES_PER_MB * 5000, // storage_bytes_avg
        0,                                   // documents_count_avg
    );

    let state = test_state_all_with_stripe(
        customer_repo.clone(),
        mock_deployment_repo(),
        usage_repo.clone(),
        rate_card_repo.clone(),
        invoice_repo.clone(),
        stripe_svc.clone(),
    );
    let app = api::router::build_router(state);

    // -------------------------------------------------------------------------
    // Step 1: Run monthly billing (usage → invoice creation)
    // -------------------------------------------------------------------------
    let resp = app
        .clone()
        .oneshot(
            Request::post("/admin/billing/run")
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-03"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["invoices_created"], 1);
    assert_eq!(body["invoices_skipped"], 0);

    // Verify invoice was created and finalized
    let invoices = invoice_repo.list_by_customer(customer.id).await.unwrap();
    assert_eq!(invoices.len(), 1);
    let invoice = &invoices[0];
    assert_eq!(invoice.status, "finalized");
    assert!(invoice.stripe_invoice_id.is_some());
    assert!(invoice.hosted_invoice_url.is_some());
    assert!(invoice.paid_at.is_none(), "invoice should not be paid yet");

    let stripe_invoice_id = invoice.stripe_invoice_id.clone().unwrap();
    let invoice_id = invoice.id;

    // Verify Stripe invoice was created with idempotency key
    let stripe_invoices = stripe_svc.invoices_created.lock().unwrap();
    assert_eq!(stripe_invoices.len(), 1);
    drop(stripe_invoices);

    // -------------------------------------------------------------------------
    // Step 2: Simulate Stripe webhook - payment succeeded
    // -------------------------------------------------------------------------
    let webhook_payload = json!({
        "id": "evt_payment_001",
        "type": "invoice.payment_succeeded",
        "data": {
            "object": {
                "id": stripe_invoice_id,
                "customer": format!("cus_test_{}", &customer.id.to_string()[..8]),
                "status": "paid",
                "amount_paid": invoice.total_cents,
                "currency": "usd"
            }
        }
    })
    .to_string();

    let resp = app
        .clone()
        .oneshot(webhook_request(&webhook_payload))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // -------------------------------------------------------------------------
    // Step 3: Verify invoice is marked as paid
    // -------------------------------------------------------------------------
    let updated_invoice = invoice_repo.find_by_id(invoice_id).await.unwrap().unwrap();
    assert_eq!(updated_invoice.status, "paid");
    assert!(updated_invoice.paid_at.is_some(), "paid_at should be set");

    // Verify line items exist
    let line_items = invoice_repo.get_line_items(invoice_id).await.unwrap();
    assert!(!line_items.is_empty(), "invoice should have line items");

    // Verify storage-based charges are present
    let hot_storage_item = line_items.iter().find(|li| li.unit == "mb_months");
    assert!(
        hot_storage_item.is_some(),
        "should have hot storage usage line item"
    );
}

// ===========================================================================
// Multi-cycle egress carry-forward regression
// ===========================================================================

/// Proves that egress carry-forward survives across two billing cycles:
/// cycle 1 produces a sub-cent remainder, finalization persists it, and
/// cycle 2's draft invoice consumes the remainder (adding it to new egress).
#[tokio::test]
async fn admin_finalize_multi_cycle_egress_carryforward_consumed_in_next_cycle() {
    use crate::common::mock_storage_bucket_repo;
    use api::models::storage::NewStorageBucket;
    use api::repos::StorageBucketRepo;

    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let rate_card_repo = mock_rate_card_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let stripe_svc = mock_stripe_service();

    rate_card_repo.seed_active_card(test_rate_card());
    let customer = seed_stripe_customer(&customer_repo, "Acme Multi", "multi@example.com").await;
    // Fresh customer — no carry-forward yet
    assert_eq!(
        customer.object_storage_egress_carryforward_cents,
        dec!(0),
        "customer should start with zero carry-forward"
    );

    let one_gb = billing::types::BYTES_PER_GIB;
    let bucket = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id: customer.id,
                name: "bucket-multi-cycle".to_string(),
            },
            "garage-bucket-multi-cycle",
        )
        .await
        .unwrap();

    // Cycle 1: 1.5 GB egress × $0.01/GB = 1.5 cents raw → floor = 1 cent, remainder = 0.5
    storage_bucket_repo
        .increment_egress(bucket.id, one_gb + one_gb / 2)
        .await
        .unwrap();

    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .with_invoice_repo(invoice_repo.clone())
        .with_rate_card_repo(rate_card_repo)
        .with_storage_bucket_repo(storage_bucket_repo.clone())
        .with_stripe_service(stripe_svc)
        .build_app();

    // ---- Generate cycle 1 draft ----
    let c1_resp = app
        .clone()
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(c1_resp.status(), StatusCode::CREATED);
    let c1_body = body_json(c1_resp).await;
    let c1_invoice_id = c1_body["id"].as_str().expect("cycle 1 invoice id");

    // Verify cycle 1 egress line item
    let c1_egress = c1_body["line_items"]
        .as_array()
        .expect("line_items array")
        .iter()
        .find(|li| li["unit"] == "object_storage_egress_gb")
        .expect("cycle 1 should have egress line item");
    assert_eq!(
        c1_egress["amount_cents"], 1,
        "1.5 cents floored = 1 cent billed"
    );

    // ---- Finalize cycle 1 ----
    let fin1_resp = app
        .clone()
        .oneshot(
            Request::post(format!("/admin/invoices/{c1_invoice_id}/finalize"))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(fin1_resp.status(), StatusCode::OK);

    // Verify carry-forward persisted after cycle 1 finalization
    let customer_after_c1 = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        customer_after_c1.object_storage_egress_carryforward_cents,
        dec!(0.5),
        "cycle 1 should leave 0.5 cents carry-forward (1.5 - 1.0)"
    );

    // Verify watermark advanced
    let bucket_after_c1 = storage_bucket_repo.get(bucket.id).await.unwrap().unwrap();
    assert_eq!(
        bucket_after_c1.egress_watermark_bytes,
        one_gb + one_gb / 2,
        "watermark should advance to cycle 1 egress_bytes"
    );

    // ---- Cycle 2: add 0.75 GB more egress ----
    // New billable = 0.75 GB → 0.75 cents + 0.5 carry-forward = 1.25 cents → floor = 1, remainder = 0.25
    let egress_cycle_2_bytes = one_gb * 3 / 4; // 0.75 GB (exact — BYTES_PER_GIB is divisible by 4)
    storage_bucket_repo
        .increment_egress(bucket.id, egress_cycle_2_bytes)
        .await
        .unwrap();

    // ---- Generate cycle 2 draft ----
    let c2_resp = app
        .clone()
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-02"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(c2_resp.status(), StatusCode::CREATED);
    let c2_body = body_json(c2_resp).await;

    // Verify cycle 2 egress line item includes carry-forward from cycle 1
    let c2_egress = c2_body["line_items"]
        .as_array()
        .expect("line_items array")
        .iter()
        .find(|li| li["unit"] == "object_storage_egress_gb")
        .expect("cycle 2 should have egress line item");
    assert_eq!(
        c2_egress["amount_cents"], 1,
        "0.75 raw + 0.5 carryforward = 1.25 cents → floor = 1 cent"
    );

    // Verify metadata carry-forward via repo (metadata is not exposed in HTTP response)
    let c2_invoice_id: uuid::Uuid = c2_body["id"]
        .as_str()
        .expect("cycle 2 invoice id")
        .parse()
        .unwrap();
    let c2_line_items = invoice_repo.get_line_items(c2_invoice_id).await.unwrap();
    let c2_egress_row = c2_line_items
        .iter()
        .find(|li| li.unit == "object_storage_egress_gb")
        .expect("cycle 2 should have egress line item in repo");
    let c2_meta = c2_egress_row
        .metadata
        .as_ref()
        .expect("egress line item should have metadata");
    let c2_next_carryforward: rust_decimal::Decimal = c2_meta["next_cycle_carryforward_cents"]
        .as_str()
        .expect("carryforward should be a string decimal")
        .parse()
        .unwrap();
    assert_eq!(
        c2_next_carryforward,
        dec!(0.25),
        "1.25 - 1.0 = 0.25 cents carry-forward for next cycle"
    );
}

// ===========================================================================
// POST /admin/customers/:id/suspend
// ===========================================================================

#[tokio::test]
async fn suspend_active_customer_success() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    // Customer starts as active by default

    let app = test_app_with_stripe(
        customer_repo.clone(),
        mock_invoice_repo(),
        mock_stripe_service(),
    );

    let resp = app
        .oneshot(
            Request::post(format!("/admin/customers/{}/suspend", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["message"], "customer suspended");

    // Verify customer is now suspended
    let updated = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(updated.status, "suspended");
}

#[tokio::test]
async fn suspend_non_active_returns_400() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    // Suspend first so it's no longer active
    customer_repo.suspend(customer.id).await.unwrap();

    let app = test_app_with_stripe(customer_repo, mock_invoice_repo(), mock_stripe_service());

    let resp = app
        .oneshot(
            Request::post(format!("/admin/customers/{}/suspend", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = body_json(resp).await;
    assert_eq!(body["error"], "customer is not active");
}

#[tokio::test]
async fn suspend_404_unknown_customer() {
    let app = test_app_with_stripe(mock_repo(), mock_invoice_repo(), mock_stripe_service());

    let resp = app
        .oneshot(
            Request::post(format!("/admin/customers/{}/suspend", Uuid::new_v4()))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    let body = body_json(resp).await;
    assert_eq!(body["error"], "customer not found");
}
