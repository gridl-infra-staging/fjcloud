use super::super::super::*;
use super::super::support::{
    post_job_action, seed_retained_job_with_internals, seed_retained_job_with_status,
    serialized_job_row, setup_algolia_cloud_job_lifecycle_app,
};

#[tokio::test]
async fn algolia_cloud_job_cancel_queued_owned_job_returns_accepted_public_cancelling() {
    let Some(db) = connect_and_migrate("algolia_route_cancel_queued").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, customer_id) =
        setup_algolia_cloud_job_lifecycle_app(db.pool.clone(), false, source_service).await;
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
    assert_eq!(body["source"]["appId"], "TESTAPP123");
    assert_eq!(body["source"]["name"], "source_products");
    assert!(!body.to_string().contains("phys-secret-uid"));
    assert!(!body.to_string().contains("routing-secret-id"));
    assert!(!body.to_string().contains("idem-secret-cancel"));
}

#[tokio::test]
async fn algolia_cloud_job_cancel_rejects_deleted_customer_without_mutating_retained_job() {
    let Some(db) = connect_and_migrate("algolia_route_cancel_deleted").await else {
        return;
    };
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

#[tokio::test]
async fn algolia_cloud_job_cancel_replays_cancelling_and_cancelled_as_ok() {
    let Some(db) = connect_and_migrate("algolia_route_cancel_replay").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, customer_id) =
        setup_algolia_cloud_job_lifecycle_app(db.pool.clone(), true, source_service).await;

    for (status, key) in [
        (AlgoliaImportJobStatus::Cancelling, "cancelling"),
        (AlgoliaImportJobStatus::Cancelled, "cancelled"),
    ] {
        let id = seed_retained_job_with_status(&db.pool, customer_id, key, key, status).await;
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
        let after: Option<chrono::DateTime<Utc>> =
            sqlx::query_scalar("SELECT cancel_requested_at FROM algolia_import_jobs WHERE id = $1")
                .bind(id)
                .fetch_one(&db.pool)
                .await
                .expect("read replayed cancel timestamp");
        assert_eq!(after, before);
    }
}

#[tokio::test]
async fn algolia_cloud_job_cancel_missing_and_foreign_return_identical_404() {
    let Some(db) = connect_and_migrate("algolia_route_cancel_404").await else {
        return;
    };
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
    let Some(db) = connect_and_migrate("algolia_route_cancel_refused").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, customer_id) =
        setup_algolia_cloud_job_lifecycle_app(db.pool.clone(), true, source_service).await;

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
}

#[tokio::test]
async fn algolia_cloud_job_cancel_rejects_api_key_body_before_mutation() {
    let Some(db) = connect_and_migrate("algolia_route_cancel_body").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, customer_id) =
        setup_algolia_cloud_job_lifecycle_app(db.pool.clone(), true, source_service).await;
    let id = seed_retained_job_with_internals(
        &db.pool,
        customer_id,
        "products",
        "cancel-body",
        Utc::now(),
    )
    .await;

    let (status, _headers, _body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{id}/cancel"),
        json!({ "apiKey": "must-not-be-accepted" }),
    )
    .await;

    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    let persisted_status: String =
        sqlx::query_scalar("SELECT status FROM algolia_import_jobs WHERE id = $1")
            .bind(id)
            .fetch_one(&db.pool)
            .await
            .expect("read cancelled job status");
    assert_eq!(persisted_status, "queued");
}

#[tokio::test]
async fn algolia_cloud_job_cancel_rejects_unknown_fields_before_mutation() {
    let Some(db) = connect_and_migrate("algolia_route_cancel_unknown_body").await else {
        return;
    };
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
