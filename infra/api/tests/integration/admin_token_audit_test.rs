//! Route-level audit coverage for the impersonation-token path.
//!
//! ## What these tests prove (and don't)
//!
//! The pair below is mutually-discriminating, and both halves now drive the
//! real `POST /admin/tokens` handler rather than calling `write_audit_log`
//! directly:
//!
//!   * `post_admin_tokens_impersonation_writes_one_attributed_audit_row` —
//!     a request with `purpose="impersonation"` MUST write exactly one
//!     `audit_log` row, and that row MUST name the operator who made the
//!     request.
//!
//!   * `post_admin_tokens_without_purpose_still_writes_audit_row` — the same
//!     request WITHOUT `purpose` MUST still write an attributed `audit_log`
//!     row because the route always returns a customer JWT.
//!
//! Either test passing alone is a false positive:
//!   - "never writes a row" fails both.
//!   - "writes only when purpose=impersonation" passes the first but fails the second.
//!   - Only "writes for every successful mint and preserves purpose metadata" passes both.
//!
//! ## Why the direct-helper version was replaced
//!
//! The earlier form of this file called
//! `write_audit_log(&pool, <the nil sentinel actor>, ...)` itself and then
//! asserted `actor_id == Uuid::nil()`. That asserted the test's own argument
//! back to itself — it could not fail for any handler defect — and it
//! *blessed* the shared-credential sentinel as the desired admin actor, which
//! is exactly the model this lane removes (FJ-R-AUTHZ-01). The file's own
//! `TODO(T1.4 follow-up)` asked for the real-pool route fixture; the shared
//! live-DB harness in `common::admin_audit_test_support` is that fixture, so
//! these tests reuse it instead of standing up a second one.
//!
//! ## Why these tests are #[ignore]
//!
//! They require a live Postgres with the migrations applied. Set
//! `DATABASE_URL` to a per-developer test DB before invoking:
//!
//!   DATABASE_URL=postgres://user:pass@localhost/fjcloud_test \
//!     cargo test -p api --test auth_admin admin_token_audit_test:: -- --ignored
//!
//! Without `DATABASE_URL` they exit early with a SKIP message rather than
//! failing — same pattern as `pg_customer_repo_test.rs`.

use api::services::audit_log::ACTION_IMPERSONATION_TOKEN_CREATED;
use uuid::Uuid;

use crate::common::admin_audit_test_support::{
    actor_ids_for_action_and_target, admin_token_request_with_key, app_with_pg_customer_repo,
    audit_row_count, audit_row_count_for_action_and_nullable_target, audit_row_count_for_target,
    audit_rows_for_action_and_nullable_target, cleanup_target, connect_isolated_and_migrate,
    connect_shared_public_and_migrate as connect_and_migrate, create_active_customer,
    impersonation_app, install_scoped_audit_failure_trigger, register_operator, response_json,
    revoke_operator,
};
use axum::body::Body;
use axum::http::StatusCode;
use tower::ServiceExt;

// ---------------------------------------------------------------------------
// Test 1: purpose=impersonation writes exactly one attributed audit_log row
// ---------------------------------------------------------------------------

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn post_admin_tokens_impersonation_writes_one_attributed_audit_row() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let (operator_id, admin_credential) = register_operator(
        &pool,
        &format!("token-audit-{}@example.com", Uuid::new_v4()),
    )
    .await;

    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed("Token Audit Target", "token-audit-target@example.com");
    // Fresh customer UUID per run, but clear first so a crashed prior run
    // cannot make the counts below pass or fail for the wrong reason.
    cleanup_target(&pool, customer.id).await;
    assert_eq!(audit_row_count_for_target(&pool, customer.id).await, 0);

    let app = impersonation_app(pool.clone(), customer_repo);

    let resp = app
        .oneshot(admin_token_request_with_key(
            &admin_credential,
            customer.id,
            Some(3600),
            Some("impersonation"),
        ))
        .await
        .unwrap();
    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert!(body["token"].as_str().is_some());

    let actors =
        actor_ids_for_action_and_target(&pool, ACTION_IMPERSONATION_TOKEN_CREATED, customer.id)
            .await;
    assert_eq!(
        actors.len(),
        1,
        "audit-view coverage owns the route row-count contract; this file owns attribution"
    );
    assert_eq!(
        actors[0], operator_id,
        "the audit row must be attributed to the individual operator who made the request"
    );

    cleanup_target(&pool, customer.id).await;
    revoke_operator(&pool, operator_id).await;
}

// ---------------------------------------------------------------------------
// Test 2 (no-false-positive guard): purpose unset still writes audit_log row
// ---------------------------------------------------------------------------

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn post_admin_tokens_without_purpose_still_writes_audit_row() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let (operator_id, admin_credential) = register_operator(
        &pool,
        &format!("token-audit-no-purpose-{}@example.com", Uuid::new_v4()),
    )
    .await;

    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed("No Purpose Target", "no-purpose-target@example.com");
    cleanup_target(&pool, customer.id).await;

    let app = impersonation_app(pool.clone(), customer_repo);

    // Same handler, same customer, only `purpose` omitted. This is the arm
    // the old file could not test, because it never invoked the handler.
    let resp = app
        .oneshot(admin_token_request_with_key(
            &admin_credential,
            customer.id,
            Some(3600),
            None,
        ))
        .await
        .unwrap();
    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        body["token"].as_str().is_some(),
        "omitting purpose must still mint a token"
    );

    let rows = audit_rows_for_action_and_nullable_target(
        &pool,
        ACTION_IMPERSONATION_TOKEN_CREATED,
        Some(customer.id),
    )
    .await;
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].actor_id, operator_id);
    assert_eq!(rows[0].target_tenant_id, Some(customer.id));
    assert_eq!(
        rows[0].metadata,
        serde_json::json!({
            "duration_secs": 3600,
            "purpose": "admin",
        })
    );
    assert_eq!(
        audit_row_count(&pool, ACTION_IMPERSONATION_TOKEN_CREATED, customer.id).await,
        1
    );
    assert_eq!(audit_row_count_for_target(&pool, customer.id).await, 1);

    cleanup_target(&pool, customer.id).await;
    revoke_operator(&pool, operator_id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn post_admin_tokens_audit_transactional_failure_returns_500_without_token_or_audit_row() {
    let db = connect_isolated_and_migrate("admin_token_audit_transactional_failure").await;
    let (operator_id, admin_credential) = register_operator(
        &db.pool,
        &format!(
            "token-audit-transactional-failure-{}@example.com",
            Uuid::new_v4()
        ),
    )
    .await;
    let customer_id = create_active_customer(&db.pool, "Token Audit Transactional Failure").await;
    install_scoped_audit_failure_trigger(
        &db.pool,
        ACTION_IMPERSONATION_TOKEN_CREATED,
        operator_id,
        Some(customer_id),
    )
    .await;
    let app = app_with_pg_customer_repo(db.pool.clone());

    let resp = app
        .oneshot(admin_token_request_with_key(
            &admin_credential,
            customer_id,
            Some(3600),
            Some("impersonation"),
        ))
        .await
        .unwrap();
    let (status, body) = response_json(resp).await;

    assert_eq!(
        status,
        StatusCode::INTERNAL_SERVER_ERROR,
        "audit INSERT failure must hide the impersonation token; body={body}"
    );
    assert_eq!(body, serde_json::json!({"error": "internal server error"}));
    assert!(
        body.get("token").is_none(),
        "failure envelope must not expose a usable impersonation token"
    );
    assert_eq!(
        audit_row_count_for_action_and_nullable_target(
            &db.pool,
            ACTION_IMPERSONATION_TOKEN_CREATED,
            Some(customer_id)
        )
        .await,
        0
    );
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn post_admin_tokens_audit_transactional_success_persists_actor_target_and_token_authenticates(
) {
    let db = connect_isolated_and_migrate("admin_token_audit_transactional_success").await;
    let (operator_id, admin_credential) = register_operator(
        &db.pool,
        &format!(
            "token-audit-transactional-success-{}@example.com",
            Uuid::new_v4()
        ),
    )
    .await;
    let customer_id = create_active_customer(&db.pool, "Token Audit Transactional Success").await;
    let app = app_with_pg_customer_repo(db.pool.clone());

    let resp = app
        .clone()
        .oneshot(admin_token_request_with_key(
            &admin_credential,
            customer_id,
            Some(3600),
            Some("impersonation"),
        ))
        .await
        .unwrap();
    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    let token = body["token"]
        .as_str()
        .expect("successful impersonation response must include a token");

    let account_resp = app
        .oneshot(
            axum::http::Request::get("/account")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let (account_status, account_body) = response_json(account_resp).await;
    assert_eq!(account_status, StatusCode::OK);
    assert_eq!(account_body["id"], customer_id.to_string());

    let rows = audit_rows_for_action_and_nullable_target(
        &db.pool,
        ACTION_IMPERSONATION_TOKEN_CREATED,
        Some(customer_id),
    )
    .await;
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].actor_id, operator_id);
    assert_eq!(rows[0].target_tenant_id, Some(customer_id));
    assert_eq!(
        rows[0].metadata,
        serde_json::json!({
            "duration_secs": 3600,
            "purpose": "impersonation",
        })
    );
}
