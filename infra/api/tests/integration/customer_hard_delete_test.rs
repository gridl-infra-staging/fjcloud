//! Admin `POST /admin/customers/:id/hard-erase` regression suite.
//!
//! These tests exercise the route handler's contract over the mock
//! `CustomerRepo` seam:
//! * 204 success when a soft-deleted customer is hard-erased.
//! * 404 not-found when no customer matches (or a prior call already
//!   erased the row).
//! * 400 precondition rejection when the customer is not soft-deleted
//!   (active/suspended).
//! * 409 conflict when the repo seam reports open invoices.
//!
//! Audit-row emission against a live `audit_log` table is verified in
//! `admin_audit_view_test.rs` to avoid duplicating the live-DB harness
//! here. These tests run without a real Postgres server (the default
//! `lazy_pool` fails to connect, so the best-effort audit write logs an
//! error but the action itself still succeeds).

use api::repos::CustomerRepo;
use api::services::audit_log::ACTION_CUSTOMER_HARD_ERASE;
use axum::body::Body;
use axum::http::{Method, Request, StatusCode};
use tower::ServiceExt;
use uuid::Uuid;

use crate::common::admin_audit_test_support::{
    app_with_pg_customer_repo, audit_row_count_for_action_and_nullable_target,
    audit_row_count_for_target, audit_rows_for_action_and_nullable_target,
    connect_isolated_and_migrate, create_soft_deleted_customer, customer_status,
    insert_prior_target_audit_row, install_scoped_audit_failure_trigger, register_operator,
    response_status_json_and_bytes, row_count_for_customer_id, seed_api_key_for_customer,
};

fn hard_erase_request(customer_id: Uuid) -> Request<Body> {
    Request::builder()
        .method(Method::POST)
        .uri(format!("/admin/customers/{}/hard-erase", customer_id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .expect("build hard-erase request")
}

#[tokio::test]
async fn hard_erase_soft_deleted_customer_returns_204_and_removes_row() {
    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed_deleted("Erase Me", "erase-me@example.com");
    let app = crate::common::TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .build_app();

    let resp = app
        .oneshot(hard_erase_request(customer.id))
        .await
        .expect("dispatch hard-erase");
    assert_eq!(
        resp.status(),
        StatusCode::NO_CONTENT,
        "204 No Content on successful erase"
    );

    let lookup = customer_repo
        .find_by_id(customer.id)
        .await
        .expect("find_by_id after hard-erase");
    assert!(
        lookup.is_none(),
        "hard-erased customer row must not remain in repo"
    );
}

#[tokio::test]
async fn hard_erase_never_translates_privacy_work_into_engine_cancel() {
    let customer_repo = crate::common::mock_repo();
    let customer =
        customer_repo.seed_deleted("Erase Without Cancel", "erase-no-cancel@example.com");
    let (http, _secrets, proxy) = crate::common::flapjack_proxy_test_support::setup().await;
    let app = crate::common::TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_flapjack_proxy(std::sync::Arc::new(proxy))
        .build_app();

    let response = app
        .oneshot(hard_erase_request(customer.id))
        .await
        .expect("dispatch hard-erase");

    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert!(
        http.take_requests().is_empty(),
        "privacy hard erase must not invoke the cooperative migration cancel route"
    );
    assert!(
        http.take_sensitive_requests().is_empty(),
        "privacy hard erase must not send Algolia credentials"
    );
}

#[tokio::test]
async fn repeated_hard_erase_returns_404_after_prior_erase() {
    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed_deleted("Repeat Erase", "repeat-erase@example.com");
    let app = crate::common::TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .build_app();

    let first = app
        .clone()
        .oneshot(hard_erase_request(customer.id))
        .await
        .expect("first hard-erase");
    assert_eq!(first.status(), StatusCode::NO_CONTENT);

    let second = app
        .oneshot(hard_erase_request(customer.id))
        .await
        .expect("second hard-erase");
    assert_eq!(
        second.status(),
        StatusCode::NOT_FOUND,
        "404 on repeat — the row is already gone"
    );
}

#[tokio::test]
async fn hard_erase_unknown_customer_returns_404() {
    let customer_repo = crate::common::mock_repo();
    let app = crate::common::TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .build_app();

    let resp = app
        .oneshot(hard_erase_request(Uuid::new_v4()))
        .await
        .expect("dispatch hard-erase");
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn hard_erase_active_customer_rejected_with_400() {
    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed("Still Active", "active@example.com");
    let app = crate::common::TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .build_app();

    let resp = app
        .oneshot(hard_erase_request(customer.id))
        .await
        .expect("dispatch hard-erase");
    assert_eq!(
        resp.status(),
        StatusCode::BAD_REQUEST,
        "active customers must be soft-deleted first"
    );

    let lookup = customer_repo
        .find_by_id(customer.id)
        .await
        .expect("find_by_id")
        .expect("rejected hard-erase must not remove the customer row");
    assert_eq!(lookup.status, "active");
}

#[tokio::test]
async fn hard_erase_suspended_customer_rejected_with_400() {
    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed("Suspended", "suspended@example.com");
    customer_repo
        .suspend(
            customer.id,
            crate::common::customer_suspended_audit_entry(customer.id),
        )
        .await
        .expect("suspend seeded customer");
    let app = crate::common::TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .build_app();

    let resp = app
        .oneshot(hard_erase_request(customer.id))
        .await
        .expect("dispatch hard-erase");
    assert_eq!(
        resp.status(),
        StatusCode::BAD_REQUEST,
        "suspended customers must be soft-deleted first"
    );
}

#[tokio::test]
async fn hard_erase_blocked_by_open_invoices_returns_409() {
    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed_deleted("Has Open Invoice", "open-inv@example.com");
    // Arm the seam to surface the open-invoice conflict without standing
    // up the full MockInvoiceRepo (that flow is covered in pg_customer_repo_test).
    customer_repo.force_next_hard_delete_open_invoices_conflict();

    let app = crate::common::TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .build_app();

    let resp = app
        .oneshot(hard_erase_request(customer.id))
        .await
        .expect("dispatch hard-erase");
    assert_eq!(
        resp.status(),
        StatusCode::CONFLICT,
        "409 when repo seam reports open invoices"
    );

    let lookup = customer_repo
        .find_by_id(customer.id)
        .await
        .expect("find_by_id")
        .expect("blocked hard-erase must not remove the customer row");
    assert_eq!(lookup.status, "deleted");
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn hard_erase_customer_audit_transactional_failure_returns_500_and_preserves_customer_graph()
{
    let db = connect_isolated_and_migrate("hard_erase_audit_transactional_failure").await;
    let (operator_id, admin_credential) = register_operator(
        &db.pool,
        &format!(
            "hard-erase-transactional-failure-{}@example.com",
            Uuid::new_v4()
        ),
    )
    .await;
    let customer_id =
        create_soft_deleted_customer(&db.pool, "Hard Erase Audit Transactional Failure").await;
    seed_api_key_for_customer(&db.pool, customer_id).await;
    insert_prior_target_audit_row(&db.pool, operator_id, customer_id).await;
    install_scoped_audit_failure_trigger(&db.pool, ACTION_CUSTOMER_HARD_ERASE, operator_id, None)
        .await;
    let app = app_with_pg_customer_repo(db.pool.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri(format!("/admin/customers/{customer_id}/hard-erase"))
                .header("x-admin-key", admin_credential)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let (status, body, _bytes) = response_status_json_and_bytes(resp).await;

    // Capture the response AND every post-request PostgreSQL observation
    // before asserting, then compare them together in one aggregate
    // assertion. Asserting the status first would short-circuit on today's
    // buggy 204 and hide the erased graph; the aggregate form makes the RED
    // failure report that the customer/dependents/prior audit row were
    // actually removed after the scoped erasure-audit INSERT failed, not
    // merely that the status was unexpected.
    let observed_customer_status = customer_status(&db.pool, customer_id).await;
    let observed_api_keys = row_count_for_customer_id(&db.pool, "api_keys", customer_id).await;
    let observed_prior_audit_rows = audit_row_count_for_target(&db.pool, customer_id).await;
    let observed_erase_audit_rows =
        audit_row_count_for_action_and_nullable_target(&db.pool, ACTION_CUSTOMER_HARD_ERASE, None)
            .await;

    assert_eq!(
        (
            status,
            body.clone(),
            observed_customer_status.as_deref(),
            observed_api_keys,
            observed_prior_audit_rows,
            observed_erase_audit_rows,
        ),
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            serde_json::json!({"error": "internal server error"}),
            Some("deleted"),
            1,
            1,
            0,
        ),
        "audit INSERT failure must roll back hard erasure; \
         observed status={status}, body={body}, \
         customer_status={observed_customer_status:?}, api_keys={observed_api_keys}, \
         prior_audit_rows={observed_prior_audit_rows}, erase_audit_rows={observed_erase_audit_rows}"
    );
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn hard_erase_customer_audit_transactional_success_removes_graph_and_keeps_target_free_receipt(
) {
    let db = connect_isolated_and_migrate("hard_erase_audit_transactional_success").await;
    let (operator_id, admin_credential) = register_operator(
        &db.pool,
        &format!(
            "hard-erase-transactional-success-{}@example.com",
            Uuid::new_v4()
        ),
    )
    .await;
    let customer_id =
        create_soft_deleted_customer(&db.pool, "Hard Erase Audit Transactional Success").await;
    seed_api_key_for_customer(&db.pool, customer_id).await;
    insert_prior_target_audit_row(&db.pool, operator_id, customer_id).await;
    let app = app_with_pg_customer_repo(db.pool.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri(format!("/admin/customers/{customer_id}/hard-erase"))
                .header("x-admin-key", admin_credential)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let (status, body, bytes) = response_status_json_and_bytes(resp).await;

    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(bytes.is_empty(), "204 response body must be empty");
    assert_eq!(body, serde_json::Value::Null);
    assert_eq!(customer_status(&db.pool, customer_id).await, None);
    assert_eq!(
        row_count_for_customer_id(&db.pool, "api_keys", customer_id).await,
        0
    );
    assert_eq!(
        audit_row_count_for_target(&db.pool, customer_id).await,
        0,
        "prior target-bound audit row must be removed with the customer graph"
    );
    let rows =
        audit_rows_for_action_and_nullable_target(&db.pool, ACTION_CUSTOMER_HARD_ERASE, None).await;
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].actor_id, operator_id);
    assert_eq!(rows[0].action, ACTION_CUSTOMER_HARD_ERASE);
    assert_eq!(rows[0].target_tenant_id, None);
    assert_eq!(
        rows[0].metadata,
        serde_json::json!({"erased_algolia_job_count": 0})
    );
}
