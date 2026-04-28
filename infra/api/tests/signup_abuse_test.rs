#![allow(clippy::await_holding_lock)]

mod common;

use api::repos::CustomerRepo;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use serde_json::json;
use std::sync::{Mutex, OnceLock};
use tower::ServiceExt;

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let body = resp
        .into_body()
        .collect()
        .await
        .expect("response body should collect")
        .to_bytes();
    serde_json::from_slice(&body).expect("response body should be valid json")
}

fn json_post(uri: &str, body: serde_json::Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

fn signup_abuse_env_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

struct EnvVarGuard {
    key: &'static str,
    previous: Option<String>,
}

impl EnvVarGuard {
    fn set(key: &'static str, value: &str) -> Self {
        let previous = std::env::var(key).ok();
        std::env::set_var(key, value);
        Self { key, previous }
    }

    fn remove(key: &'static str) -> Self {
        let previous = std::env::var(key).ok();
        std::env::remove_var(key);
        Self { key, previous }
    }
}

impl Drop for EnvVarGuard {
    fn drop(&mut self) {
        match &self.previous {
            Some(value) => std::env::set_var(self.key, value),
            None => std::env::remove_var(self.key),
        }
    }
}

fn blocked_domain_from_snapshot() -> &'static str {
    include_str!("../src/auth/disposable_email_domains.txt")
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty() && !line.starts_with('#'))
        .expect("disposable email domain snapshot should contain at least one domain")
}

fn build_signup_app(
    customer_repo: std::sync::Arc<common::MockCustomerRepo>,
    stripe_service: std::sync::Arc<common::MockStripeService>,
) -> axum::Router {
    common::TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_stripe_service(stripe_service)
        .build_app()
}

#[tokio::test]
async fn register_rejects_disposable_domain_without_creating_customer_or_stripe_customer() {
    let customer_repo = common::mock_repo();
    let stripe_service = common::mock_stripe_service();
    let app = build_signup_app(customer_repo.clone(), stripe_service.clone());
    let blocked_domain = blocked_domain_from_snapshot();
    let blocked_email = format!("abuse@{blocked_domain}");

    let response = app
        .oneshot(json_post(
            "/auth/register",
            json!({
                "name": "Disposable",
                "email": blocked_email,
                "password": "strongpassword123"
            }),
        ))
        .await
        .expect("request should complete");

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let response_json = body_json(response).await;
    assert_eq!(response_json["error"], "email domain is not allowed");
    assert!(
        customer_repo
            .find_by_email(&format!("abuse@{blocked_domain}"))
            .await
            .expect("repo lookup should succeed")
            .is_none(),
        "blocked disposable signup must not create a customer row"
    );
    assert_eq!(
        stripe_service.customers.lock().unwrap().len(),
        0,
        "blocked disposable signup must not create a Stripe customer"
    );
}

#[tokio::test]
async fn stripe_customer_is_created_only_after_email_verification() {
    let _lock = signup_abuse_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _skip_guard = EnvVarGuard::remove("SKIP_EMAIL_VERIFICATION");

    let customer_repo = common::mock_repo();
    let stripe_service = common::mock_stripe_service();
    let app = build_signup_app(customer_repo.clone(), stripe_service.clone());

    let register_response = app
        .clone()
        .oneshot(json_post(
            "/auth/register",
            json!({
                "name": "Verified Later",
                "email": "verifylater@example.com",
                "password": "strongpassword123"
            }),
        ))
        .await
        .expect("request should complete");
    assert_eq!(register_response.status(), StatusCode::CREATED);

    let pre_verify_customer = customer_repo
        .find_by_email("verifylater@example.com")
        .await
        .expect("repo lookup should succeed")
        .expect("customer should exist");
    assert!(
        pre_verify_customer.stripe_customer_id.is_none(),
        "register without verify-email should keep stripe_customer_id empty"
    );
    assert_eq!(
        stripe_service.customers.lock().unwrap().len(),
        0,
        "register without verify-email should not call Stripe create_customer"
    );

    let verify_token = pre_verify_customer
        .email_verify_token
        .clone()
        .expect("registration should create verify token");
    let verify_response = app
        .oneshot(json_post(
            "/auth/verify-email",
            json!({ "token": verify_token }),
        ))
        .await
        .expect("request should complete");
    assert_eq!(verify_response.status(), StatusCode::OK);

    let post_verify_customer = customer_repo
        .find_by_email("verifylater@example.com")
        .await
        .expect("repo lookup should succeed")
        .expect("customer should exist");
    assert!(
        post_verify_customer.stripe_customer_id.is_some(),
        "verify-email should persist stripe_customer_id"
    );
    assert_eq!(
        stripe_service.customers.lock().unwrap().len(),
        1,
        "signup plus verify-email should create exactly one Stripe customer"
    );
}

#[tokio::test]
async fn skip_email_verification_uses_shared_post_verification_stripe_path_exactly_once() {
    let _lock = signup_abuse_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _skip_guard = EnvVarGuard::set("SKIP_EMAIL_VERIFICATION", "1");
    let _environment_guard = EnvVarGuard::set("ENVIRONMENT", "local");

    let customer_repo = common::mock_repo();
    let stripe_service = common::mock_stripe_service();
    let app = build_signup_app(customer_repo.clone(), stripe_service.clone());

    let register_response = app
        .oneshot(json_post(
            "/auth/register",
            json!({
                "name": "Skip Verify",
                "email": "skipverify@example.com",
                "password": "strongpassword123"
            }),
        ))
        .await
        .expect("request should complete");
    assert_eq!(register_response.status(), StatusCode::CREATED);

    let customer = customer_repo
        .find_by_email("skipverify@example.com")
        .await
        .expect("repo lookup should succeed")
        .expect("customer should exist");
    assert!(
        customer.email_verified_at.is_some(),
        "SKIP_EMAIL_VERIFICATION=1 should auto-verify customer"
    );
    assert!(
        customer.stripe_customer_id.is_some(),
        "SKIP_EMAIL_VERIFICATION=1 should persist stripe_customer_id via post-verification path"
    );
    assert_eq!(
        stripe_service.customers.lock().unwrap().len(),
        1,
        "auto-verify path should create exactly one Stripe customer"
    );
}

#[tokio::test]
async fn skip_email_verification_is_ignored_outside_local_environment() {
    let _lock = signup_abuse_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _skip_guard = EnvVarGuard::set("SKIP_EMAIL_VERIFICATION", "1");
    let _environment_guard = EnvVarGuard::set("ENVIRONMENT", "staging");

    let customer_repo = common::mock_repo();
    let stripe_service = common::mock_stripe_service();
    let app = build_signup_app(customer_repo.clone(), stripe_service.clone());

    let register_response = app
        .oneshot(json_post(
            "/auth/register",
            json!({
                "name": "Skip Verify Staging",
                "email": "skipverify-staging@example.com",
                "password": "strongpassword123"
            }),
        ))
        .await
        .expect("request should complete");
    assert_eq!(register_response.status(), StatusCode::CREATED);

    let customer = customer_repo
        .find_by_email("skipverify-staging@example.com")
        .await
        .expect("repo lookup should succeed")
        .expect("customer should exist");
    assert!(
        customer.email_verified_at.is_none(),
        "SKIP_EMAIL_VERIFICATION must not auto-verify outside local environments"
    );
    assert!(
        customer.stripe_customer_id.is_none(),
        "non-local registration must not persist stripe_customer_id before verify-email"
    );
    assert_eq!(
        stripe_service.customers.lock().unwrap().len(),
        0,
        "non-local registration must not call Stripe create_customer before verify-email"
    );
}
