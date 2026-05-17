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

mod common;

use api::repos::CustomerRepo;
use axum::body::Body;
use axum::http::{Method, Request, StatusCode};
use tower::ServiceExt;
use uuid::Uuid;

fn hard_erase_request(customer_id: Uuid) -> Request<Body> {
    Request::builder()
        .method(Method::POST)
        .uri(format!("/admin/customers/{}/hard-erase", customer_id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .expect("build hard-erase request")
}

#[tokio::test]
async fn hard_erase_soft_deleted_customer_returns_204_and_removes_row() {
    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed_deleted("Erase Me", "erase-me@example.com");
    let app = common::TestStateBuilder::new()
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
async fn repeated_hard_erase_returns_404_after_prior_erase() {
    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed_deleted("Repeat Erase", "repeat-erase@example.com");
    let app = common::TestStateBuilder::new()
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
    let customer_repo = common::mock_repo();
    let app = common::TestStateBuilder::new()
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
    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed("Still Active", "active@example.com");
    let app = common::TestStateBuilder::new()
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
    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed("Suspended", "suspended@example.com");
    customer_repo
        .suspend(customer.id)
        .await
        .expect("suspend seeded customer");
    let app = common::TestStateBuilder::new()
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
    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed_deleted("Has Open Invoice", "open-inv@example.com");
    // Arm the seam to surface the open-invoice conflict without standing
    // up the full MockInvoiceRepo (that flow is covered in pg_customer_repo_test).
    customer_repo.force_next_hard_delete_open_invoices_conflict();

    let app = common::TestStateBuilder::new()
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
