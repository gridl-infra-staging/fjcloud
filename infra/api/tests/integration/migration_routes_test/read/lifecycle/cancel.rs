use super::super::super::*;
use super::super::support::{
    get_json, post_job_action, seed_engine_linked_cancel_job, seed_retained_job_with_internals,
    seed_retained_job_with_status, serialized_job_row, setup_algolia_cancel_dispatch_app,
    setup_algolia_cloud_job_lifecycle_app,
};

#[tokio::test]
async fn algolia_cloud_job_cancel_queued_owned_job_returns_accepted_public_cancelling() {
    let db = connect_and_migrate_required("algolia_route_cancel_queued").await;
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, customer_id, _vm_id, http, _alerts) =
        setup_algolia_cancel_dispatch_app(db.pool.clone(), false, source_service).await;
    let id =
        seed_retained_job_with_internals(&db.pool, customer_id, "products", "cancel", Utc::now())
            .await;

    let (status, _headers, body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{id}/cancel"),
        json!({}),
    )
    .await;

    assert_eq!(status, StatusCode::ACCEPTED, "cancel response body: {body}");
    assert_eq!(body["id"], id.to_string());
    assert_eq!(body["status"], "cancelling");
    assert_eq!(body["source"], json!({ "name": "source_products" }));
    assert!(body["source"].get("appId").is_none());
    assert!(!body.to_string().contains("phys-secret-uid"));
    assert!(!body.to_string().contains("routing-secret-id"));
    assert!(!body.to_string().contains("idem-secret-cancel"));
    assert_eq!(http.request_count(), 0);
}

#[tokio::test]
async fn algolia_cloud_job_cancel_persists_before_send_and_retries_same_engine_intent() {
    let db = connect_and_migrate_required("algolia_route_cancel_dispatch_retry").await;
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, customer_id, vm_id, http, alerts) =
        setup_algolia_cancel_dispatch_app(db.pool.clone(), false, source_service).await;
    let (id, engine_job_id) =
        seed_engine_linked_cancel_job(&db.pool, customer_id, vm_id, "dispatch-retry").await;

    let first_observed_at = Arc::new(Mutex::new(None));
    let first_observed_at_hook = first_observed_at.clone();
    let first_pool = db.pool.clone();
    http.before_next_send(move || async move {
        let (status, requested_at): (String, Option<DateTime<Utc>>) = sqlx::query_as(
            "SELECT status, cancel_requested_at FROM algolia_import_jobs WHERE id = $1",
        )
        .bind(id)
        .fetch_one(&first_pool)
        .await
        .expect("observe durable cancel intent before first engine request");
        assert_eq!(status, "cancelling");
        let requested_at = requested_at.expect("cancel timestamp must precede engine request");
        *first_observed_at_hook.lock().unwrap() = Some(requested_at);
    });
    http.push_error(ProxyError::Timeout);

    let (first_status, _headers, first_body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{id}/cancel"),
        json!({}),
    )
    .await;

    assert_eq!(first_status, StatusCode::ACCEPTED, "body: {first_body}");
    assert_eq!(first_body["status"], "cancelling");
    assert_eq!(first_body["error"]["code"], "backend_unavailable");
    let original_requested_at = first_observed_at
        .lock()
        .unwrap()
        .expect("first request hook must run");

    let retry_pool = db.pool.clone();
    http.before_next_send(move || async move {
        let (status, requested_at): (String, Option<DateTime<Utc>>) = sqlx::query_as(
            "SELECT status, cancel_requested_at FROM algolia_import_jobs WHERE id = $1",
        )
        .bind(id)
        .fetch_one(&retry_pool)
        .await
        .expect("observe durable cancel intent before retry");
        assert_eq!(status, "cancelling");
        assert_eq!(requested_at, Some(original_requested_at));
    });
    http.push_error(ProxyError::Timeout);

    let (retry_status, _headers, retry_body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{id}/cancel"),
        json!({}),
    )
    .await;

    assert_eq!(retry_status, StatusCode::OK, "body: {retry_body}");
    assert_eq!(retry_body["status"], "cancelling");
    assert_eq!(retry_body["error"]["code"], "backend_unavailable");
    let requests = http.take_requests();
    assert_eq!(requests.len(), 2);
    for request in requests {
        assert_eq!(request.method, reqwest::Method::POST);
        assert_eq!(request.json_body, None);
        assert!(request
            .url
            .ends_with(&format!("/1/migrations/algolia/{engine_job_id}/cancel")));
    }
    assert_eq!(
        alerts.alert_count(),
        1,
        "ambiguous retry alert is deduplicated"
    );
}

#[tokio::test]
async fn algolia_cloud_job_cancel_retains_vm_and_backpressure_ambiguity() {
    let db = connect_and_migrate_required("algolia_route_cancel_ambiguity").await;
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, customer_id, vm_id, http, alerts) =
        setup_algolia_cancel_dispatch_app(db.pool.clone(), false, source_service).await;

    let unresolved_vm_id = Uuid::new_v4();
    insert_vm_with_id(
        &db.pool,
        unresolved_vm_id,
        "algolia-cancel-unresolved",
        "active",
    )
    .await;
    let (unresolved_job_id, _) =
        seed_engine_linked_cancel_job(&db.pool, customer_id, unresolved_vm_id, "unresolved-vm")
            .await;
    let (status, _headers, body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{unresolved_job_id}/cancel"),
        json!({}),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED, "body: {body}");
    assert_eq!(body["status"], "cancelling");
    assert_eq!(body["error"]["code"], "backend_unavailable");
    assert_eq!(http.request_count(), 0);
    assert_eq!(alerts.alert_count(), 1);

    let (backpressured_job_id, _) =
        seed_engine_linked_cancel_job(&db.pool, customer_id, vm_id, "backpressure").await;
    http.push_error(ProxyError::FlapjackError {
        status: 503,
        message: json!({"code": "migration_capacity_exhausted"}).to_string(),
    });
    let (status, _headers, body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{backpressured_job_id}/cancel"),
        json!({}),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED, "body: {body}");
    assert_eq!(body["status"], "cancelling");
    assert_eq!(body["error"]["code"], "backend_unavailable");
    assert_eq!(http.request_count(), 1);
    assert_eq!(alerts.alert_count(), 2);
    assert!(alerts.recorded_alerts().iter().all(|alert| {
        alert.metadata["reason"] == AlgoliaImportErrorCode::BackendUnavailable.as_str()
    }));
}

#[tokio::test]
async fn algolia_cloud_job_cancel_too_late_retains_nonterminal_reconciliation_state() {
    let db = connect_and_migrate_required("algolia_route_cancel_too_late").await;
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, customer_id, vm_id, http, alerts) =
        setup_algolia_cancel_dispatch_app(db.pool.clone(), false, source_service).await;
    let (id, engine_job_id) =
        seed_engine_linked_cancel_job(&db.pool, customer_id, vm_id, "too-late").await;
    http.push_error(ProxyError::FlapjackError {
        status: 409,
        message: json!({"code": "cancel_too_late"}).to_string(),
    });

    let (status, _headers, body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{id}/cancel"),
        json!({}),
    )
    .await;

    assert_eq!(status, StatusCode::ACCEPTED, "body: {body}");
    assert_eq!(body["status"], "cancelling");
    assert_eq!(body["error"]["code"], "cancel_not_permitted");
    assert_eq!(body["resumable"], false);
    let persisted: (String, Option<DateTime<Utc>>, String, bool) = sqlx::query_as(
        "SELECT status, cancel_requested_at, error_code, retryable
         FROM algolia_import_jobs WHERE id = $1",
    )
    .bind(id)
    .fetch_one(&db.pool)
    .await
    .expect("read retained cancel race state");
    assert_eq!(persisted.0, "cancelling");
    assert!(persisted.1.is_some());
    assert_eq!(persisted.2, "cancel_not_permitted");
    assert!(!persisted.3);
    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(requests[0].json_body, None);
    assert!(requests[0]
        .url
        .ends_with(&format!("/1/migrations/algolia/{engine_job_id}/cancel")));
    assert_eq!(alerts.alert_count(), 0);
}

#[tokio::test]
async fn algolia_cloud_job_cancel_win_finalizes_terminal_truth() {
    let db = connect_and_migrate_required("algolia_route_cancel_wins").await;
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, customer_id, vm_id, http, alerts) =
        setup_algolia_cancel_dispatch_app(db.pool.clone(), false, source_service).await;
    let (id, engine_job_id) =
        seed_engine_linked_cancel_job(&db.pool, customer_id, vm_id, "cancel-wins").await;
    http.push_json_response(
        200,
        json!({
            "jobId": engine_job_id,
            "phase": "activating",
            "disposition": "cancelled",
            "createdAt": "2026-07-22T00:00:00Z",
            "updatedAt": "2026-07-22T00:00:01Z",
            "terminalAt": "2026-07-22T00:00:02Z",
            "exportProgress": {"completed": 12, "total": 20}
        }),
    );

    let (status, _headers, body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{id}/cancel"),
        json!({}),
    )
    .await;

    assert_eq!(status, StatusCode::ACCEPTED, "body: {body}");
    assert_eq!(body["status"], "cancelled");
    assert_eq!(body["publicationDisposition"], "unchanged");
    assert_eq!(body["resumable"], false);
    assert!(body["error"].is_null());
    let persisted: (
        String,
        String,
        String,
        Option<DateTime<Utc>>,
        Option<DateTime<Utc>>,
    ) = sqlx::query_as(
        "SELECT status, publication_disposition, engine_ack_state, cancel_requested_at, terminal_at
         FROM algolia_import_jobs WHERE id = $1",
    )
    .bind(id)
    .fetch_one(&db.pool)
    .await
    .expect("read retained terminal fact state");
    assert_eq!(persisted.0, "cancelled");
    assert_eq!(persisted.1, "unchanged");
    assert_eq!(persisted.2, "outbox_pending");
    assert!(persisted.3.is_some());
    assert_eq!(
        persisted.4,
        Some("2026-07-22T00:00:02Z".parse::<DateTime<Utc>>().unwrap())
    );
    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(requests[0].json_body, None);
    assert_eq!(alerts.alert_count(), 0);
}

#[tokio::test]
async fn algolia_cloud_job_cancel_rejects_deleted_customer_without_mutating_retained_job() {
    let db = connect_and_migrate_required("algolia_route_cancel_deleted").await;
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, customer_id) =
        setup_algolia_cloud_job_lifecycle_app(db.pool.clone(), true, source_service.clone()).await;
    let id = seed_retained_job_with_internals(
        &db.pool,
        customer_id,
        "products",
        "cancel-deleted",
        Utc::now(),
    )
    .await;
    let before = serialized_job_row(&db.pool, id).await;
    soft_delete_customer(&db.pool, customer_id).await;

    let (status, headers, body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{id}/cancel"),
        json!({}),
    )
    .await;

    assert_eq!(status, StatusCode::CONFLICT, "cancel response body: {body}");
    assert!(headers.get(http::header::LOCATION).is_none());
    assert_eq!(
        body,
        json!({
            "error": AlgoliaImportErrorCode::CancelNotPermitted.as_str(),
            "code": AlgoliaImportErrorCode::CancelNotPermitted.as_str(),
        })
    );
    assert!(source_service.inspect_requests().is_empty());
    assert_eq!(serialized_job_row(&db.pool, id).await, before);
}

/// TODO: Document algolia_cloud_job_cancel_replays_cancelled_as_ok.
#[tokio::test]
async fn algolia_cloud_job_cancel_replays_cancelled_as_ok_without_engine_request() {
    let db = connect_and_migrate_required("algolia_route_cancel_replay").await;
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, customer_id, _vm_id, http, _alerts) =
        setup_algolia_cancel_dispatch_app(db.pool.clone(), false, source_service).await;
    let status = AlgoliaImportJobStatus::Cancelled;
    let id = seed_retained_job_with_status(&db.pool, customer_id, "cancelled", "cancelled", status)
        .await;
    let before: Option<chrono::DateTime<Utc>> =
        sqlx::query_scalar("SELECT cancel_requested_at FROM algolia_import_jobs WHERE id = $1")
            .bind(id)
            .fetch_one(&db.pool)
            .await
            .expect("read cancel timestamp");

    let (response_status, _headers, body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{id}/cancel"),
        json!({}),
    )
    .await;

    assert_eq!(response_status, StatusCode::OK, "body: {body}");
    assert_eq!(body["status"], status.as_str());
    assert_eq!(body["resumable"], false);
    let after: Option<chrono::DateTime<Utc>> =
        sqlx::query_scalar("SELECT cancel_requested_at FROM algolia_import_jobs WHERE id = $1")
            .bind(id)
            .fetch_one(&db.pool)
            .await
            .expect("read replayed cancel timestamp");
    assert_eq!(after, before);
    assert_eq!(http.request_count(), 0);

    let reservation_query = format!(
        "SELECT ({}) FROM algolia_import_jobs WHERE id = $1",
        PgAlgoliaImportJobRepo::active_reservation_predicate_for_contract_tests()
    );
    let reserved_before_ack: bool = sqlx::query_scalar(&reservation_query)
        .bind(id)
        .fetch_one(&db.pool)
        .await
        .expect("evaluate retained cancelled reservation");
    assert!(reserved_before_ack);

    let (list_status, list_body) = get_json(&app, &jwt, "/migration/algolia/jobs").await;
    assert_eq!(list_status, StatusCode::OK);
    assert!(list_body["jobs"]
        .as_array()
        .unwrap()
        .iter()
        .any(|job| job["id"] == id.to_string()));
    let (get_status, get_body) =
        get_json(&app, &jwt, &format!("/migration/algolia/jobs/{id}")).await;
    assert_eq!(get_status, StatusCode::OK);
    assert_eq!(get_body["status"], "cancelled");
    assert_eq!(get_body["resumable"], false);

    PgAlgoliaImportJobRepo::new(db.pool.clone())
        .mark_engine_acknowledged(id)
        .await
        .expect("F10-owned ACK completion remains available");
    let reserved_after_ack: bool = sqlx::query_scalar(&reservation_query)
        .bind(id)
        .fetch_one(&db.pool)
        .await
        .expect("evaluate acknowledged cancelled reservation");
    assert!(!reserved_after_ack);
}

#[tokio::test]
async fn algolia_cloud_job_cancel_missing_and_foreign_return_identical_404() {
    let db = connect_and_migrate_required("algolia_route_cancel_404").await;
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, _customer_id) =
        setup_algolia_cloud_job_lifecycle_app(db.pool.clone(), true, source_service).await;
    let other = Uuid::new_v4();
    insert_active_customer(&db.pool, other, 1).await;
    let foreign_id =
        seed_retained_job_with_internals(&db.pool, other, "products", "foreign-cancel", Utc::now())
            .await;
    let missing_id = Uuid::new_v4();

    let (missing_status, _missing_headers, missing_body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{missing_id}/cancel"),
        json!({}),
    )
    .await;
    let (foreign_status, _foreign_headers, foreign_body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{foreign_id}/cancel"),
        json!({}),
    )
    .await;

    assert_eq!(missing_status, StatusCode::NOT_FOUND);
    assert_eq!(foreign_status, StatusCode::NOT_FOUND);
    assert_eq!(missing_body, foreign_body);
    let foreign_status: String =
        sqlx::query_scalar("SELECT status FROM algolia_import_jobs WHERE id = $1")
            .bind(foreign_id)
            .fetch_one(&db.pool)
            .await
            .expect("read foreign cancel status");
    assert_eq!(foreign_status, "queued");
}

#[tokio::test]
async fn algolia_cloud_job_cancel_non_cancellable_states_return_stable_409() {
    let db = connect_and_migrate_required("algolia_route_cancel_refused").await;
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, customer_id, _vm_id, http, _alerts) =
        setup_algolia_cancel_dispatch_app(db.pool.clone(), true, source_service).await;

    for status in [
        AlgoliaImportJobStatus::Completed,
        AlgoliaImportJobStatus::CompletedWithWarnings,
        AlgoliaImportJobStatus::Failed,
        AlgoliaImportJobStatus::Interrupted,
    ] {
        let key = format!("cancel-refused-{}", status.as_str());
        let id = seed_retained_job_with_status(&db.pool, customer_id, &key, &key, status).await;
        let (response_status, _headers, body) = post_job_action(
            &app,
            &jwt,
            &format!("/migration/algolia/jobs/{id}/cancel"),
            json!({}),
        )
        .await;

        assert_eq!(response_status, StatusCode::CONFLICT, "status={status:?}");
        assert_eq!(
            body["code"],
            AlgoliaImportErrorCode::CancelNotPermitted.as_str()
        );
        let persisted: String =
            sqlx::query_scalar("SELECT status FROM algolia_import_jobs WHERE id = $1")
                .bind(id)
                .fetch_one(&db.pool)
                .await
                .expect("read refused cancel status");
        assert_eq!(persisted, status.as_str());
    }
    assert_eq!(http.request_count(), 0);
}

#[tokio::test]
async fn algolia_cloud_job_cancel_rejects_api_key_body_before_mutation() {
    let db = connect_and_migrate_required("algolia_route_cancel_body").await;
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, customer_id, _vm_id, http, alerts) =
        setup_algolia_cancel_dispatch_app(db.pool.clone(), false, source_service).await;
    let id = seed_retained_job_with_internals(
        &db.pool,
        customer_id,
        "products",
        "cancel-body",
        Utc::now(),
    )
    .await;

    let credential_canary = "cancel-customer-credential-canary";
    let (status, _headers, body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{id}/cancel"),
        json!({ "apiKey": credential_canary }),
    )
    .await;

    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert!(!body.to_string().contains(credential_canary));
    let persisted_status: String =
        sqlx::query_scalar("SELECT status FROM algolia_import_jobs WHERE id = $1")
            .bind(id)
            .fetch_one(&db.pool)
            .await
            .expect("read cancelled job status");
    assert_eq!(persisted_status, "queued");
    assert!(!serialized_job_row(&db.pool, id)
        .await
        .to_string()
        .contains(credential_canary));
    assert!(http.take_requests().is_empty());
    assert!(alerts.recorded_alerts().iter().all(|alert| {
        !serde_json::to_string(alert)
            .unwrap()
            .contains(credential_canary)
    }));
    let (get_status, get_body) =
        get_json(&app, &jwt, &format!("/migration/algolia/jobs/{id}")).await;
    assert_eq!(get_status, StatusCode::OK);
    assert!(!get_body.to_string().contains(credential_canary));
}

#[tokio::test]
async fn algolia_cloud_job_cancel_rejects_unknown_fields_before_mutation() {
    let db = connect_and_migrate_required("algolia_route_cancel_unknown_body").await;
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, customer_id) =
        setup_algolia_cloud_job_lifecycle_app(db.pool.clone(), true, source_service).await;
    let id = seed_retained_job_with_internals(
        &db.pool,
        customer_id,
        "products",
        "cancel-unknown",
        Utc::now(),
    )
    .await;

    for body in [
        json!({ "unexpected": true }),
        json!({ "resumeCheckpoint": "client-owned-checkpoint" }),
    ] {
        let (status, _headers, _body) = post_job_action(
            &app,
            &jwt,
            &format!("/migration/algolia/jobs/{id}/cancel"),
            body,
        )
        .await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    }

    let persisted_status: String =
        sqlx::query_scalar("SELECT status FROM algolia_import_jobs WHERE id = $1")
            .bind(id)
            .fetch_one(&db.pool)
            .await
            .expect("read cancel unknown-field status");
    assert_eq!(persisted_status, "queued");
}
