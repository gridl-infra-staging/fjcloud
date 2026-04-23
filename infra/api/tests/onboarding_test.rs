mod common;

use api::repos::tenant_repo::TenantRepo;
use api::repos::CustomerRepo;
use api::services::tenant_quota::FreeTierLimits;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{
    create_test_jwt, mock_api_key_repo, mock_deployment_repo, mock_flapjack_proxy, mock_repo,
    mock_stripe_service, mock_tenant_repo, test_app_with_onboarding, TestStateBuilder,
};
use http_body_util::BodyExt;
use tower::ServiceExt;

fn assert_free_tier_limits(body: &serde_json::Value) {
    assert_eq!(body["free_tier_limits"]["max_searches_per_month"], 50_000);
    assert_eq!(body["free_tier_limits"]["max_records"], 100_000);
    assert_eq!(body["free_tier_limits"]["max_storage_gb"], 10);
    assert_eq!(body["free_tier_limits"]["max_indexes"], 1);
}

async fn get_status(app: axum::Router, jwt: &str) -> (StatusCode, serde_json::Value) {
    let req = Request::builder()
        .uri("/onboarding/status")
        .header("Authorization", format!("Bearer {jwt}"))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    let status = resp.status();
    let body = Body::new(resp.into_body())
        .collect()
        .await
        .unwrap()
        .to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    (status, json)
}

/// Response uses `has_region`/`region_ready`, NOT `has_deployment`/`deployment_ready`.
#[tokio::test]
async fn status_response_uses_region_not_deployment_field_names() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("FieldNames", "fields@test.com");
    let jwt = create_test_jwt(customer.id);

    let app = test_app_with_onboarding(
        customer_repo,
        mock_deployment_repo(),
        mock_tenant_repo(),
        mock_api_key_repo(),
        mock_stripe_service(),
        mock_flapjack_proxy(),
    );

    let (status, body) = get_status(app, &jwt).await;
    assert_eq!(status, StatusCode::OK);

    // New field names must exist
    assert!(body.get("has_region").is_some(), "missing has_region");
    assert!(body.get("region_ready").is_some(), "missing region_ready");
    // Old field names must NOT exist
    assert!(
        body.get("has_deployment").is_none(),
        "has_deployment still present"
    );
    assert!(
        body.get("deployment_ready").is_none(),
        "deployment_ready still present"
    );
}

/// Fresh customer with no data — all flags should be false.
#[tokio::test]
async fn fresh_customer_returns_all_false() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Alice", "alice@test.com");
    let jwt = create_test_jwt(customer.id);

    let app = test_app_with_onboarding(
        customer_repo,
        mock_deployment_repo(),
        mock_tenant_repo(),
        mock_api_key_repo(),
        mock_stripe_service(),
        mock_flapjack_proxy(),
    );

    let (status, body) = get_status(app, &jwt).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["has_payment_method"], false);
    assert_eq!(body["has_region"], false);
    assert_eq!(body["region_ready"], false);
    assert_eq!(body["has_index"], false);
    assert_eq!(body["has_api_key"], false);
    assert_eq!(body["completed"], false);
    assert_eq!(body["flapjack_url"], serde_json::Value::Null);
    assert_eq!(body["billing_plan"], "free");
    assert_free_tier_limits(&body);
    // Free plan does not require payment — first step is creating an index
    assert_eq!(body["suggested_next_step"], "Create your first index");
}

/// Customer with a Stripe payment method — has_payment_method should be true.
#[tokio::test]
async fn customer_with_payment_method_returns_has_payment_method() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Bob", "bob@test.com");

    // Set stripe customer ID on the customer
    customer_repo
        .set_stripe_customer_id(customer.id, "cus_stripe_bob")
        .await
        .unwrap();

    let stripe_service = mock_stripe_service();
    stripe_service.seed_payment_method(api::stripe::PaymentMethodSummary {
        id: "pm_123".to_string(),
        card_brand: "visa".to_string(),
        last4: "4242".to_string(),
        exp_month: 12,
        exp_year: 2027,
        is_default: true,
    });

    let jwt = create_test_jwt(customer.id);

    let app = test_app_with_onboarding(
        customer_repo,
        mock_deployment_repo(),
        mock_tenant_repo(),
        mock_api_key_repo(),
        stripe_service,
        mock_flapjack_proxy(),
    );

    let (status, body) = get_status(app, &jwt).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["has_payment_method"], true);
    assert_eq!(body["has_region"], false);
    assert_eq!(body["completed"], false);
    assert_eq!(body["billing_plan"], "free");
    assert_free_tier_limits(&body);
    assert_eq!(body["suggested_next_step"], "Create your first index");
}

/// Customer with payment method + index (the real onboarding completion path) —
/// completed should be true even without an fjcloud API key, because flapjack
/// API keys (from POST /onboarding/credentials) live on the VM, not in api_key_repo.
#[tokio::test]
async fn fully_onboarded_returns_completed() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Carol", "carol@test.com");
    customer_repo
        .set_stripe_customer_id(customer.id, "cus_stripe_carol")
        .await
        .unwrap();

    // Payment method
    let stripe_service = mock_stripe_service();
    stripe_service.seed_payment_method(api::stripe::PaymentMethodSummary {
        id: "pm_456".to_string(),
        card_brand: "mastercard".to_string(),
        last4: "5555".to_string(),
        exp_month: 6,
        exp_year: 2028,
        is_default: true,
    });

    // Running deployment with flapjack_url
    let deployment_repo = mock_deployment_repo();
    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "node-carol",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-carol.flapjack.foo"),
    );

    // Index registered
    let tenant_repo = mock_tenant_repo();
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("https://vm-carol.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer.id, "my-index", deployment.id)
        .await
        .unwrap();

    // No fjcloud API key seeded — completed should still be true
    // (flapjack keys from POST /onboarding/credentials are on the VM)

    let jwt = create_test_jwt(customer.id);

    let app = test_app_with_onboarding(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_api_key_repo(),
        stripe_service,
        mock_flapjack_proxy(),
    );

    let (status, body) = get_status(app, &jwt).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["has_payment_method"], true);
    assert_eq!(body["has_region"], true);
    assert_eq!(body["region_ready"], true);
    assert_eq!(body["has_index"], true);
    assert_eq!(body["has_api_key"], false); // fjcloud management key not created yet
    assert_eq!(body["completed"], true); // completed only needs payment + index
    assert_eq!(body["billing_plan"], "free");
    assert_free_tier_limits(&body);
    assert_eq!(body["flapjack_url"], "https://vm-carol.flapjack.foo");
    assert_eq!(body["suggested_next_step"], "You're all set!");
}

/// Customer with payment method + provisioning deployment (not running) —
/// suggested step should be "Waiting for your search endpoint to be ready".
#[tokio::test]
async fn provisioning_deployment_shows_waiting_step() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Dave", "dave@test.com");
    customer_repo
        .set_stripe_customer_id(customer.id, "cus_stripe_dave")
        .await
        .unwrap();

    let stripe_service = mock_stripe_service();
    stripe_service.seed_payment_method(api::stripe::PaymentMethodSummary {
        id: "pm_789".to_string(),
        card_brand: "visa".to_string(),
        last4: "1234".to_string(),
        exp_month: 3,
        exp_year: 2028,
        is_default: true,
    });

    // Provisioning deployment (not yet running)
    let deployment_repo = mock_deployment_repo();
    deployment_repo.seed(
        customer.id,
        "node-dave",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
    );

    let jwt = create_test_jwt(customer.id);

    let app = test_app_with_onboarding(
        customer_repo,
        deployment_repo,
        mock_tenant_repo(),
        mock_api_key_repo(),
        stripe_service,
        mock_flapjack_proxy(),
    );

    let (status, body) = get_status(app, &jwt).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["has_payment_method"], true);
    assert_eq!(body["has_region"], true);
    assert_eq!(body["region_ready"], false);
    assert_eq!(body["has_index"], false);
    assert_eq!(body["completed"], false);
    assert_eq!(body["billing_plan"], "free");
    assert_free_tier_limits(&body);
    assert_eq!(
        body["suggested_next_step"],
        "Waiting for your search endpoint to be ready"
    );
}

/// Customer with payment method + running deployment but no indexes —
/// suggested step should be "Create your first index".
#[tokio::test]
async fn running_deployment_no_index_shows_create_step() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Eve", "eve@test.com");
    customer_repo
        .set_stripe_customer_id(customer.id, "cus_stripe_eve")
        .await
        .unwrap();

    let stripe_service = mock_stripe_service();
    stripe_service.seed_payment_method(api::stripe::PaymentMethodSummary {
        id: "pm_abc".to_string(),
        card_brand: "amex".to_string(),
        last4: "9876".to_string(),
        exp_month: 9,
        exp_year: 2029,
        is_default: true,
    });

    // Running deployment but no indexes created yet
    let deployment_repo = mock_deployment_repo();
    deployment_repo.seed_provisioned(
        customer.id,
        "node-eve",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-eve.flapjack.foo"),
    );

    let jwt = create_test_jwt(customer.id);

    let app = test_app_with_onboarding(
        customer_repo,
        deployment_repo,
        mock_tenant_repo(),
        mock_api_key_repo(),
        stripe_service,
        mock_flapjack_proxy(),
    );

    let (status, body) = get_status(app, &jwt).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["has_payment_method"], true);
    assert_eq!(body["has_region"], true);
    assert_eq!(body["region_ready"], true);
    assert_eq!(body["has_index"], false);
    assert_eq!(body["completed"], false);
    assert_eq!(body["billing_plan"], "free");
    assert_free_tier_limits(&body);
    assert_eq!(body["flapjack_url"], "https://vm-eve.flapjack.foo");
    assert_eq!(body["suggested_next_step"], "Create your first index");
}
/// Free plan customer with just an index (no payment) — completed should be true.
#[tokio::test]
async fn free_customer_completed_with_just_index_even_if_plan_is_uppercase() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Fay", "fay@test.com");
    customer_repo
        .set_billing_plan(customer.id, "FREE")
        .await
        .unwrap();

    // Running deployment with flapjack_url
    let deployment_repo = mock_deployment_repo();
    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "node-fay",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-fay.flapjack.foo"),
    );

    // Index registered
    let tenant_repo = mock_tenant_repo();
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("https://vm-fay.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer.id, "my-index", deployment.id)
        .await
        .unwrap();

    let jwt = create_test_jwt(customer.id);

    let app = test_app_with_onboarding(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_api_key_repo(),
        mock_stripe_service(),
        mock_flapjack_proxy(),
    );

    let (status, body) = get_status(app, &jwt).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["billing_plan"], "free");
    assert_free_tier_limits(&body);
    assert_eq!(body["has_payment_method"], false);
    assert_eq!(body["has_index"], true);
    assert_eq!(body["completed"], true, "free plan only needs an index");
    assert_eq!(body["suggested_next_step"], "You're all set!");
}

#[tokio::test]
async fn free_customer_ignores_stripe_lookup_failures() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Finn", "finn@test.com");
    customer_repo
        .set_stripe_customer_id(customer.id, "cus_stripe_finn")
        .await
        .unwrap();

    let stripe_service = mock_stripe_service();
    stripe_service.set_should_fail(true);

    let jwt = create_test_jwt(customer.id);

    let app = test_app_with_onboarding(
        customer_repo,
        mock_deployment_repo(),
        mock_tenant_repo(),
        mock_api_key_repo(),
        stripe_service,
        mock_flapjack_proxy(),
    );

    let (status, body) = get_status(app, &jwt).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["billing_plan"], "free");
    assert_free_tier_limits(&body);
    assert_eq!(body["has_payment_method"], false);
    assert_eq!(body["completed"], false);
    assert_eq!(body["suggested_next_step"], "Create your first index");
}

#[tokio::test]
async fn free_customer_status_uses_configured_free_tier_limits() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Fjord", "fjord@test.com");
    let jwt = create_test_jwt(customer.id);

    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_onboarding(
            mock_tenant_repo(),
            mock_api_key_repo(),
            mock_stripe_service(),
            mock_flapjack_proxy(),
        )
        .with_deployment_repo(mock_deployment_repo())
        .with_free_tier_limits(FreeTierLimits {
            max_searches_per_month: 123_456,
            max_indexes: 7,
        })
        .build_app();

    let (status, body) = get_status(app, &jwt).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["billing_plan"], "free");
    assert_eq!(body["free_tier_limits"]["max_searches_per_month"], 123_456);
    assert_eq!(body["free_tier_limits"]["max_records"], 100_000);
    assert_eq!(body["free_tier_limits"]["max_storage_gb"], 10);
    assert_eq!(body["free_tier_limits"]["max_indexes"], 7);
}

#[tokio::test]
async fn shared_customer_still_surfaces_stripe_lookup_failures() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_shared_customer("Gina", "gina@test.com");
    customer_repo
        .set_stripe_customer_id(customer.id, "cus_stripe_gina")
        .await
        .unwrap();

    let stripe_service = mock_stripe_service();
    stripe_service.set_should_fail(true);

    let jwt = create_test_jwt(customer.id);

    let app = test_app_with_onboarding(
        customer_repo,
        mock_deployment_repo(),
        mock_tenant_repo(),
        mock_api_key_repo(),
        stripe_service,
        mock_flapjack_proxy(),
    );

    let (status, body) = get_status(app, &jwt).await;

    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(body["error"], "internal server error");
}

/// Shared plan customer without payment — should suggest adding payment method.
#[tokio::test]
async fn shared_customer_suggests_payment_first() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_shared_customer("Greg", "greg@test.com");
    let jwt = create_test_jwt(customer.id);

    let app = test_app_with_onboarding(
        customer_repo,
        mock_deployment_repo(),
        mock_tenant_repo(),
        mock_api_key_repo(),
        mock_stripe_service(),
        mock_flapjack_proxy(),
    );

    let (status, body) = get_status(app, &jwt).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["billing_plan"], "shared");
    assert_eq!(body["free_tier_limits"], serde_json::Value::Null);
    assert_eq!(body["has_payment_method"], false);
    assert_eq!(body["completed"], false);
    assert_eq!(body["suggested_next_step"], "Add a payment method");
}

/// Shared plan customer with index but no payment — not completed.
#[tokio::test]
async fn shared_customer_needs_payment_for_completion() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_shared_customer("Hana", "hana@test.com");

    // Running deployment
    let deployment_repo = mock_deployment_repo();
    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "node-hana",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-hana.flapjack.foo"),
    );

    // Index registered
    let tenant_repo = mock_tenant_repo();
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("https://vm-hana.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer.id, "my-index", deployment.id)
        .await
        .unwrap();

    let jwt = create_test_jwt(customer.id);

    let app = test_app_with_onboarding(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_api_key_repo(),
        mock_stripe_service(),
        mock_flapjack_proxy(),
    );

    let (status, body) = get_status(app, &jwt).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["billing_plan"], "shared");
    assert_eq!(body["free_tier_limits"], serde_json::Value::Null);
    assert_eq!(body["has_payment_method"], false);
    assert_eq!(body["has_index"], true);
    assert_eq!(
        body["completed"], false,
        "shared plan needs payment + index"
    );
    assert_eq!(body["suggested_next_step"], "Add a payment method");
}
