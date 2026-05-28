use api::password::hash_password;
use api::repos::CustomerRepo;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{Duration, Utc};
use http_body_util::BodyExt;
use tower::ServiceExt;

fn json_post(uri: &str, body: serde_json::Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .expect("request should build")
}

async fn response_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp
        .into_body()
        .collect()
        .await
        .expect("response body should collect")
        .to_bytes();
    serde_json::from_slice(&bytes).expect("response body should parse as json")
}

async fn seed_password_customer(
    repo: &crate::common::MockCustomerRepo,
    name: &str,
    email: &str,
    password: &str,
) {
    let hash = hash_password(password).expect("password hash should be generated");
    repo.create_with_password(name, email, &hash)
        .await
        .expect("customer should be seeded");
}

#[tokio::test]
async fn login_prelocked_account_returns_429_with_retry_after() {
    let repo = crate::common::mock_repo();
    seed_password_customer(
        &repo,
        "Locked User",
        "locked@example.com",
        "correct-password-123",
    )
    .await;

    let customer = repo
        .find_by_email("locked@example.com")
        .await
        .expect("find_by_email should succeed")
        .expect("customer should exist");

    for _ in 0..5 {
        repo.record_failed_login(customer.id)
            .await
            .expect("record_failed_login should succeed");
    }

    let app = crate::common::test_app_with_repo(repo);
    let resp = app
        .oneshot(json_post(
            "/auth/login",
            serde_json::json!({
                "email": "locked@example.com",
                "password": "correct-password-123"
            }),
        ))
        .await
        .expect("request should succeed");

    assert_eq!(resp.status(), StatusCode::TOO_MANY_REQUESTS);
    assert!(
        resp.headers().get("retry-after").is_some(),
        "pre-locked login response should include retry-after"
    );
}

#[tokio::test]
async fn login_five_failed_attempts_trigger_lockout() {
    let repo = crate::common::mock_repo();
    seed_password_customer(
        &repo,
        "Threshold User",
        "threshold@example.com",
        "correct-password-123",
    )
    .await;

    let app = crate::common::test_app_with_repo(repo);

    for attempt in 1..=4 {
        let resp = app
            .clone()
            .oneshot(json_post(
                "/auth/login",
                serde_json::json!({
                    "email": "threshold@example.com",
                    "password": "wrong-password"
                }),
            ))
            .await
            .expect("request should succeed");
        assert_eq!(
            resp.status(),
            StatusCode::BAD_REQUEST,
            "attempt {attempt} should still be generic invalid credentials"
        );
    }

    let fifth = app
        .oneshot(json_post(
            "/auth/login",
            serde_json::json!({
                "email": "threshold@example.com",
                "password": "wrong-password"
            }),
        ))
        .await
        .expect("request should succeed");
    assert_eq!(fifth.status(), StatusCode::TOO_MANY_REQUESTS);
    assert!(
        fifth.headers().get("retry-after").is_some(),
        "threshold-crossing response should include retry-after"
    );
}

#[tokio::test]
async fn login_success_clears_failed_login_counters_and_lockout() {
    let repo = crate::common::mock_repo();
    seed_password_customer(
        &repo,
        "Reset User",
        "reset@example.com",
        "correct-password-123",
    )
    .await;

    let app = crate::common::test_app_with_repo(repo.clone());

    for _ in 0..3 {
        let resp = app
            .clone()
            .oneshot(json_post(
                "/auth/login",
                serde_json::json!({
                    "email": "reset@example.com",
                    "password": "wrong-password"
                }),
            ))
            .await
            .expect("request should succeed");
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }

    let success = app
        .clone()
        .oneshot(json_post(
            "/auth/login",
            serde_json::json!({
                "email": "reset@example.com",
                "password": "correct-password-123"
            }),
        ))
        .await
        .expect("request should succeed");
    assert_eq!(success.status(), StatusCode::OK);

    let row = repo
        .find_by_email("reset@example.com")
        .await
        .expect("find_by_email should succeed")
        .expect("customer should exist");
    assert_eq!(row.failed_login_count, 0);
    assert!(row.failed_login_window_start.is_none());
    assert!(row.login_locked_until.is_none());

    let next_failure = app
        .oneshot(json_post(
            "/auth/login",
            serde_json::json!({
                "email": "reset@example.com",
                "password": "wrong-password"
            }),
        ))
        .await
        .expect("request should succeed");
    assert_eq!(next_failure.status(), StatusCode::BAD_REQUEST);

    let updated = repo
        .find_by_email("reset@example.com")
        .await
        .expect("find_by_email should succeed")
        .expect("customer should exist");
    assert_eq!(
        updated.failed_login_count, 1,
        "failed-login counter should restart from 1 after successful login reset"
    );
}

#[tokio::test]
async fn login_returns_500_if_lockout_reset_write_is_not_applied() {
    let repo = crate::common::mock_repo();
    seed_password_customer(
        &repo,
        "Boundary User",
        "boundary@example.com",
        "correct-password-123",
    )
    .await;
    repo.fail_next_record_successful_login();

    let app = crate::common::test_app_with_repo(repo);
    let resp = app
        .oneshot(json_post(
            "/auth/login",
            serde_json::json!({
                "email": "boundary@example.com",
                "password": "correct-password-123"
            }),
        ))
        .await
        .expect("request should succeed");

    assert_eq!(
        resp.status(),
        StatusCode::INTERNAL_SERVER_ERROR,
        "login must fail closed if the lockout-reset write is not applied"
    );

    let body = response_json(resp).await;
    assert_eq!(body["error"], "internal server error");
}

#[tokio::test]
async fn lock_expiry_allows_login_again() {
    let repo = crate::common::mock_repo();
    seed_password_customer(
        &repo,
        "Expiry User",
        "expiry@example.com",
        "correct-password-123",
    )
    .await;

    let customer = repo
        .find_by_email("expiry@example.com")
        .await
        .expect("find_by_email should succeed")
        .expect("customer should exist");

    for _ in 0..5 {
        repo.record_failed_login(customer.id)
            .await
            .expect("record_failed_login should succeed");
    }

    let expired_at = Utc::now() - Duration::seconds(1);
    let updated = repo.set_login_locked_until_for_test(customer.id, Some(expired_at));
    assert!(updated, "test fixture lockout timestamp should update");

    let app = crate::common::test_app_with_repo(repo);
    let resp = app
        .oneshot(json_post(
            "/auth/login",
            serde_json::json!({
                "email": "expiry@example.com",
                "password": "correct-password-123"
            }),
        ))
        .await
        .expect("request should succeed");

    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn oauth_only_account_does_not_increment_login_lockout_state() {
    let repo = crate::common::mock_repo();
    repo.seed("OAuth User", "oauth-only@example.com");
    let app = crate::common::test_app_with_repo(repo.clone());

    let resp = app
        .oneshot(json_post(
            "/auth/login",
            serde_json::json!({
                "email": "oauth-only@example.com",
                "password": "any-password"
            }),
        ))
        .await
        .expect("request should succeed");
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let body = response_json(resp).await;
    assert_eq!(body["error"], "invalid email or password");

    let customer = repo
        .find_by_email("oauth-only@example.com")
        .await
        .expect("find_by_email should succeed")
        .expect("customer should exist");
    assert_eq!(customer.failed_login_count, 0);
    assert!(customer.failed_login_window_start.is_none());
    assert!(customer.login_locked_until.is_none());
}
