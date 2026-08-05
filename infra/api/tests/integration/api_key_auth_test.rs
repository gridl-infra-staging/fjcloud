use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{Duration, Utc};
use tower::ServiceExt;

use crate::common::api_key_auth_support::*;
use crate::common::integration_helpers::{test_env_lock, TestEnvVarGuard};
use api::auth::api_key::{ApiKeyAuth, Stage1ApiKeyCompatDecision};
use api::repos::ApiKeyRepo;

// ---- Tests (RED phase — these should fail until ApiKeyAuth is implemented) ----

#[tokio::test]
async fn valid_key_authenticates() {
    let customer_repo = crate::common::mock_repo();
    let api_key_repo = crate::common::mock_api_key_repo();

    let customer = customer_repo.seed("Acme Corp", "acme@example.com");
    let key_hash = hash_key(TEST_KEY);
    let seeded = api_key_repo.seed(
        customer.id,
        "prod-key",
        &key_hash,
        TEST_KEY_PREFIX,
        vec!["read".into(), "write".into()],
    );

    let app = build_test_app(customer_repo, api_key_repo);

    let resp = authenticate(app, TEST_KEY).await;

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["customer_id"], customer.id.to_string());
    assert_eq!(body["key_id"], seeded.id.to_string());
    assert_eq!(body["scopes"], serde_json::json!(["read", "write"]));
}

#[tokio::test]
async fn missing_auth_header_returns_401() {
    let app = build_test_app(
        crate::common::mock_repo(),
        crate::common::mock_api_key_repo(),
    );

    let resp = app
        .oneshot(Request::get("/test").body(Body::empty()).unwrap())
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn invalid_key_returns_401() {
    let app = build_test_app(
        crate::common::mock_repo(),
        crate::common::mock_api_key_repo(),
    );

    let resp = app
        .oneshot(
            Request::get("/test")
                .header(
                    "authorization",
                    "Bearer fj_live_ffffffffffffffffffffffffffffffff",
                )
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn expired_api_key_returns_invalid_token_shape() {
    let customer_repo = crate::common::mock_repo();
    let api_key_repo = crate::common::mock_api_key_repo();

    let customer = customer_repo.seed("Acme Corp", "acme@example.com");
    let seeded = create_managed_test_key(
        &api_key_repo,
        customer.id,
        TEST_KEY,
        Some(Utc::now() - Duration::minutes(5)),
    )
    .await;

    let app = build_test_app(customer_repo, api_key_repo.clone());

    let resp = authenticate(app, TEST_KEY).await;

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(
        body_json(resp).await,
        serde_json::json!({"error": "invalid or expired token"})
    );

    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    let updated = api_key_repo.find_by_id(seeded.id).await.unwrap().unwrap();
    assert!(
        updated.last_used_at.is_none(),
        "expired key presentations must not count as successful auth usage"
    );
}

#[tokio::test]
async fn expired_api_key_for_suspended_customer_returns_invalid_token_shape() {
    let customer_repo = crate::common::mock_repo();
    let api_key_repo = crate::common::mock_api_key_repo();

    let customer = customer_repo.seed("Acme Corp", "acme@example.com");
    create_managed_test_key(
        &api_key_repo,
        customer.id,
        TEST_KEY,
        Some(Utc::now() - Duration::minutes(5)),
    )
    .await;

    use api::repos::CustomerRepo;
    customer_repo
        .suspend(
            customer.id,
            crate::common::customer_suspended_audit_entry(customer.id),
        )
        .await
        .unwrap();

    let response = authenticate(build_test_app(customer_repo, api_key_repo), TEST_KEY).await;

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(
        body_json(response).await,
        serde_json::json!({"error": "invalid or expired token"})
    );
}

#[tokio::test]
async fn future_expires_at_api_key_authenticates() {
    let customer_repo = crate::common::mock_repo();
    let api_key_repo = crate::common::mock_api_key_repo();

    let customer = customer_repo.seed("Acme Corp", "acme@example.com");
    let seeded = create_managed_test_key(
        &api_key_repo,
        customer.id,
        TEST_KEY,
        Some(Utc::now() + Duration::minutes(5)),
    )
    .await;

    let app = build_test_app(customer_repo, api_key_repo);

    let resp = authenticate(app, TEST_KEY).await;

    assert_eq!(resp.status(), StatusCode::OK);
    assert_successful_auth_body(body_json(resp).await, customer.id, seeded.id);
}

#[tokio::test]
async fn null_expires_at_api_key_authenticates() {
    let customer_repo = crate::common::mock_repo();
    let api_key_repo = crate::common::mock_api_key_repo();

    let customer = customer_repo.seed("Acme Corp", "acme@example.com");
    let seeded = create_managed_test_key(&api_key_repo, customer.id, TEST_KEY, None).await;

    let app = build_test_app(customer_repo, api_key_repo);

    let resp = authenticate(app, TEST_KEY).await;

    assert_eq!(resp.status(), StatusCode::OK);
    assert_successful_auth_body(body_json(resp).await, customer.id, seeded.id);
}

#[tokio::test]
async fn revoked_key_returns_401() {
    let customer_repo = crate::common::mock_repo();
    let api_key_repo = crate::common::mock_api_key_repo();

    let customer = customer_repo.seed("Acme Corp", "acme@example.com");
    let key_hash = hash_key(TEST_KEY);
    let seeded = api_key_repo.seed(
        customer.id,
        "prod-key",
        &key_hash,
        TEST_KEY_PREFIX,
        vec!["read".into()],
    );

    // Revoke the key
    api_key_repo.revoke(seeded.id).await.unwrap();

    let app = build_test_app(customer_repo, api_key_repo);

    let resp = app
        .oneshot(
            Request::get("/test")
                .header("authorization", format!("Bearer {TEST_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn wrong_hash_returns_401() {
    let customer_repo = crate::common::mock_repo();
    let api_key_repo = crate::common::mock_api_key_repo();

    let customer = customer_repo.seed("Acme Corp", "acme@example.com");
    // Seed with a DIFFERENT hash than what TEST_KEY produces
    api_key_repo.seed(
        customer.id,
        "prod-key",
        "badhash_not_a_real_sha256_value_at_all_aaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        TEST_KEY_PREFIX,
        vec!["read".into()],
    );

    let app = build_test_app(customer_repo, api_key_repo);

    let resp = app
        .oneshot(
            Request::get("/test")
                .header("authorization", format!("Bearer {TEST_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn suspended_customer_returns_403() {
    let customer_repo = crate::common::mock_repo();
    let api_key_repo = crate::common::mock_api_key_repo();

    let customer = customer_repo.seed("Acme Corp", "acme@example.com");
    let key_hash = hash_key(TEST_KEY);
    api_key_repo.seed(
        customer.id,
        "prod-key",
        &key_hash,
        TEST_KEY_PREFIX,
        vec!["read".into()],
    );

    // Suspend the customer
    use api::repos::CustomerRepo;
    customer_repo
        .suspend(
            customer.id,
            crate::common::customer_suspended_audit_entry(customer.id),
        )
        .await
        .unwrap();

    let app = build_test_app(customer_repo, api_key_repo);

    let resp = app
        .oneshot(
            Request::get("/test")
                .header("authorization", format!("Bearer {TEST_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn scope_check_passes() {
    let customer_repo = crate::common::mock_repo();
    let api_key_repo = crate::common::mock_api_key_repo();

    let customer = customer_repo.seed("Acme Corp", "acme@example.com");
    let key_hash = hash_key(TEST_KEY);
    api_key_repo.seed(
        customer.id,
        "prod-key",
        &key_hash,
        TEST_KEY_PREFIX,
        vec!["read".into(), "write".into()],
    );

    let app = build_test_app(customer_repo, api_key_repo);

    // The /scoped endpoint requires "read" scope — this key has it
    let resp = app
        .oneshot(
            Request::get("/scoped")
                .header("authorization", format!("Bearer {TEST_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn scope_check_fails_returns_403() {
    let customer_repo = crate::common::mock_repo();
    let api_key_repo = crate::common::mock_api_key_repo();

    let customer = customer_repo.seed("Acme Corp", "acme@example.com");
    let key_hash = hash_key(TEST_KEY);
    // Key only has "write" scope, not "read"
    api_key_repo.seed(
        customer.id,
        "prod-key",
        &key_hash,
        TEST_KEY_PREFIX,
        vec!["write".into()],
    );

    let app = build_test_app(customer_repo, api_key_repo);

    // The /scoped endpoint requires "read" scope — this key doesn't have it
    let resp = app
        .oneshot(
            Request::get("/scoped")
                .header("authorization", format!("Bearer {TEST_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn last_used_at_updated() {
    let customer_repo = crate::common::mock_repo();
    let api_key_repo = crate::common::mock_api_key_repo();

    let customer = customer_repo.seed("Acme Corp", "acme@example.com");
    let key_hash = hash_key(TEST_KEY);
    let seeded = api_key_repo.seed(
        customer.id,
        "prod-key",
        &key_hash,
        TEST_KEY_PREFIX,
        vec!["read".into()],
    );

    // Verify initially null
    assert!(seeded.last_used_at.is_none());

    let app = build_test_app(customer_repo, api_key_repo.clone());

    let resp = app
        .oneshot(
            Request::get("/test")
                .header("authorization", format!("Bearer {TEST_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    // Give the fire-and-forget task a moment to complete
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    // Check that last_used_at was updated
    let updated = api_key_repo.find_by_id(seeded.id).await.unwrap().unwrap();
    assert!(updated.last_used_at.is_some());
}

#[tokio::test]
async fn deleted_customer_returns_401() {
    let customer_repo = crate::common::mock_repo();
    let api_key_repo = crate::common::mock_api_key_repo();

    let customer = customer_repo.seed_deleted("Gone Corp", "gone@example.com");
    let key_hash = hash_key(TEST_KEY);
    api_key_repo.seed(
        customer.id,
        "prod-key",
        &key_hash,
        TEST_KEY_PREFIX,
        vec!["read".into()],
    );

    let app = build_test_app(customer_repo, api_key_repo);

    let resp = app
        .oneshot(
            Request::get("/test")
                .header("authorization", format!("Bearer {TEST_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn non_fj_live_prefix_returns_401() {
    let app = build_test_app(
        crate::common::mock_repo(),
        crate::common::mock_api_key_repo(),
    );

    let resp = app
        .oneshot(
            Request::get("/test")
                .header("authorization", "Bearer sk_test_1234567890abcdef")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn fjc_live_key_authenticates() {
    let customer_repo = crate::common::mock_repo();
    let api_key_repo = crate::common::mock_api_key_repo();

    let customer = customer_repo.seed("Flapjack Cloud Corp", "customer@example.com");
    let key_hash = hash_key(TEST_KEY);
    let seeded = api_key_repo.seed(
        customer.id,
        "fjc-key",
        &key_hash,
        TEST_KEY_PREFIX,
        vec!["read".into(), "search".into()],
    );

    let app = build_test_app(customer_repo, api_key_repo);

    let resp = app
        .oneshot(
            Request::get("/test")
                .header("authorization", format!("Bearer {TEST_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["customer_id"], customer.id.to_string());
    assert_eq!(body["key_id"], seeded.id.to_string());
}

// --- Stage 2 restrict_sources source-boundary tests ---

#[tokio::test]
async fn empty_restrict_sources_stays_unrestricted() {
    let (customer_repo, api_key_repo) = seed_restricted_key(Vec::new()).await;
    let app = build_test_app(customer_repo, api_key_repo);

    // No ConnectInfo attached at all: an unrestricted key must still authenticate.
    let resp = authenticate(app, TEST_KEY).await;

    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn peer_inside_listed_cidr_authenticates() {
    let (customer_repo, api_key_repo) =
        seed_restricted_key(vec!["10.0.0.0/8".into(), "192.168.1.0/24".into()]).await;
    let app = build_test_app(customer_repo, api_key_repo);

    let resp = authenticate_from_socket(app, TEST_KEY, "10.1.2.3:44321").await;

    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn bound_api_server_supplies_connect_info_for_restricted_key() {
    let (customer_repo, api_key_repo) = seed_restricted_key(vec!["127.0.0.1/32".into()]).await;
    let app = build_test_app(customer_repo, api_key_repo);

    let (status, body) = authenticate_over_bound_api_server(app, TEST_KEY).await;

    assert_eq!(status, reqwest::StatusCode::OK);
    assert_eq!(body["scopes"], serde_json::json!(["read", "write"]));
}

#[tokio::test]
async fn peer_outside_every_cidr_is_rejected_with_invalid_token_shape() {
    let (customer_repo, api_key_repo) =
        seed_restricted_key(vec!["10.0.0.0/8".into(), "192.168.1.0/24".into()]).await;
    let app = build_test_app(customer_repo, api_key_repo);

    let resp = authenticate_from_socket(app, TEST_KEY, "203.0.113.9:44321").await;

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(
        body_json(resp).await,
        serde_json::json!({"error": "invalid or expired token"})
    );
}

#[tokio::test]
async fn unresolvable_peer_with_restrict_sources_fails_closed() {
    let (customer_repo, api_key_repo) = seed_restricted_key(vec!["10.0.0.0/8".into()]).await;
    let app = build_test_app(customer_repo, api_key_repo);

    // No ConnectInfo, no forwarded headers: the client IP is unknown, so a
    // restricted key must be denied rather than allowed by default.
    let resp = authenticate(app, TEST_KEY).await;

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn malformed_stored_cidr_fails_closed_without_panicking() {
    let (customer_repo, api_key_repo) =
        seed_restricted_key(vec!["10.0.0.0/8".into(), "not-a-cidr".into()]).await;
    let app = build_test_app(customer_repo, api_key_repo);

    // A matching valid entry must not mask a corrupt sibling entry: the entire
    // stored allowlist is untrustworthy and must fail closed.
    let resp = authenticate_from_socket(app, TEST_KEY, "10.1.2.3:44321").await;

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn forwarded_header_inside_cidr_is_denied_even_when_proxy_trust_enabled() {
    let _env_lock = test_env_lock();
    let _trust_proxy = TestEnvVarGuard::set("TRUST_PROXY_HEADERS_FOR_RATE_LIMIT", "1");

    let (customer_repo, api_key_repo) = seed_restricted_key(vec!["10.0.0.0/8".into()]).await;
    let app = build_test_app(customer_repo, api_key_repo);

    // No ConnectInfo; the in-CIDR value arrives only via a spoofable header.
    // restrict_sources must not honor it even though rate limiting trusts it.
    let request = Request::get("/test")
        .header("authorization", format!("Bearer {TEST_KEY}"))
        .header("x-forwarded-for", "10.1.2.3")
        .body(Body::empty())
        .unwrap();
    let resp = app.oneshot(request).await.unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

// --- Stage 3 max_queries_per_ip_per_hour tests ---

#[tokio::test]
async fn api_key_hourly_limit_none_remains_unlimited() {
    assert_none_limit_remains_unlimited().await;
}

#[tokio::test]
async fn api_key_hourly_limit_returns_retry_after_and_isolates_buckets() {
    assert_hourly_limit_retry_after_and_bucket_isolation().await;
}

#[tokio::test]
async fn api_key_hourly_limit_reopens_at_one_hour_boundary() {
    assert_hourly_limit_reopens_at_boundary().await;
}

#[tokio::test]
async fn api_key_hourly_limit_non_positive_stored_value_fails_closed() {
    assert_non_positive_limit_fails_closed().await;
}

// --- Stage 1 compatibility-token tests ---

// Stage 1 decision artifact (`docs/research/20260524T174343Z_fj_live_prod_usage.md`)
// resolved to HARD_CUT, so Stage 2 locks the audited branch to HardCutOk.
const AUDITED_STAGE1_DECISION: Stage1ApiKeyCompatDecision = Stage1ApiKeyCompatDecision::HardCutOk;

#[tokio::test]
async fn gridl_live_behavior_matches_stage1_decision_token() {
    let customer_repo = crate::common::mock_repo();
    let api_key_repo = crate::common::mock_api_key_repo();

    let customer = customer_repo.seed("Flapjack Cloud Corp", "customer@example.com");
    let key_hash = hash_key(GRIDL_KEY);
    let _seeded = api_key_repo.seed(
        customer.id,
        "gridl-key",
        &key_hash,
        GRIDL_KEY_PREFIX,
        vec!["read".into(), "search".into()],
    );

    let app = build_test_app(customer_repo, api_key_repo);

    let resp = send_gridl_test_request(app).await;

    assert_eq!(
        AUDITED_STAGE1_DECISION,
        Stage1ApiKeyCompatDecision::HardCutOk
    );
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn gridl_live_ignores_request_extension_override() {
    let customer_repo = crate::common::mock_repo();
    let api_key_repo = crate::common::mock_api_key_repo();

    let customer = customer_repo.seed("Flapjack Cloud Corp", "customer@example.com");
    let key_hash = hash_key(GRIDL_KEY);
    let _seeded = api_key_repo.seed(
        customer.id,
        "gridl-key",
        &key_hash,
        GRIDL_KEY_PREFIX,
        vec!["read".into(), "search".into()],
    );

    let app = build_test_app(customer_repo, api_key_repo);
    let mut request = Request::get("/test")
        .header("authorization", format!("Bearer {GRIDL_KEY}"))
        .body(Body::empty())
        .unwrap();
    request
        .extensions_mut()
        .insert(Stage1ApiKeyCompatDecision::HardCutOk);

    let resp = app.oneshot(request).await.unwrap();

    assert_eq!(
        AUDITED_STAGE1_DECISION,
        Stage1ApiKeyCompatDecision::HardCutOk
    );
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[test]
fn active_stage1_decision_matches_audited_verdict() {
    assert_eq!(
        ApiKeyAuth::active_stage1_compat_decision(),
        AUDITED_STAGE1_DECISION
    );
}

#[test]
fn stage1_token_parser_accepts_hard_cut_literals() {
    assert_eq!(
        Stage1ApiKeyCompatDecision::from_token("HARD_CUT"),
        Stage1ApiKeyCompatDecision::HardCutOk
    );
    assert_eq!(
        Stage1ApiKeyCompatDecision::from_token("HARD_CUT_OK"),
        Stage1ApiKeyCompatDecision::HardCutOk
    );
}

#[tokio::test]
async fn api_key_fj_live_extractor_accepts_when_decision_is_keep_legacy_accept() {
    let auth = extract_gridl_auth_with_decision(
        Stage1ApiKeyCompatDecision::KeepLegacyAccept,
        LEGACY_FJ_LIVE_KEY,
        LEGACY_FJ_LIVE_KEY_PREFIX,
    )
    .await
    .expect("fj_live_ key should authenticate when KEEP_LEGACY_ACCEPT is active");
    assert!(!auth.scopes.is_empty());
}

#[tokio::test]
async fn gridl_live_extractor_rejects_when_decision_is_hard_cut_ok() {
    let err = extract_gridl_auth_with_decision(
        Stage1ApiKeyCompatDecision::HardCutOk,
        GRIDL_KEY,
        GRIDL_KEY_PREFIX,
    )
    .await
    .expect_err("gridl_live_ key should be rejected when HARD_CUT is active");
    assert!(matches!(err, api::auth::error::AuthError::InvalidToken));
}

#[tokio::test]
async fn api_key_fj_live_extractor_rejects_when_decision_is_hard_cut_ok() {
    // If Stage 1 had resolved DUAL_ACCEPT, this assertion would invert to expect success.
    let err = extract_gridl_auth_with_decision(
        Stage1ApiKeyCompatDecision::HardCutOk,
        LEGACY_FJ_LIVE_KEY,
        LEGACY_FJ_LIVE_KEY_PREFIX,
    )
    .await
    .expect_err("fj_live_ key should be rejected when HARD_CUT is active");
    assert!(matches!(err, api::auth::error::AuthError::InvalidToken));
}

#[tokio::test]
async fn api_key_legacy_fj_live_key_rejected_under_hard_cut() {
    // HARD_CUT contract: legacy fj_live_ keys must now be rejected.
    let customer_repo = crate::common::mock_repo();
    let api_key_repo = crate::common::mock_api_key_repo();

    let customer = customer_repo.seed("Legacy Corp", "legacy@example.com");
    let key_hash = hash_key(LEGACY_FJ_LIVE_KEY);
    api_key_repo.seed(
        customer.id,
        "legacy-key",
        &key_hash,
        LEGACY_FJ_LIVE_KEY_PREFIX,
        vec!["read".into()],
    );

    let app = build_test_app(customer_repo, api_key_repo);

    let resp = app
        .oneshot(
            Request::get("/test")
                .header("authorization", format!("Bearer {LEGACY_FJ_LIVE_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    let body = body_json(resp).await;
    assert_eq!(body["error"], "invalid or expired token");
}

#[tokio::test]
async fn unrecognized_prefix_returns_401() {
    let app = build_test_app(
        crate::common::mock_repo(),
        crate::common::mock_api_key_repo(),
    );

    let resp = app
        .oneshot(
            Request::get("/test")
                .header(
                    "authorization",
                    "Bearer unknown_live_0123456789abcdef0123456789abcdef",
                )
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn short_key_returns_401() {
    let app = build_test_app(
        crate::common::mock_repo(),
        crate::common::mock_api_key_repo(),
    );

    // Key starts with fj_live_ but is too short for prefix extraction
    let resp = app
        .oneshot(
            Request::get("/test")
                .header("authorization", "Bearer fj_live_short")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}
