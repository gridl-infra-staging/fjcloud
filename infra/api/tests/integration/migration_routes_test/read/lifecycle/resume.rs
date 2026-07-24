use super::super::super::*;
use super::super::support::{
    get_json, post_job_action, seed_replace_resumable_retained_job_without_target,
    seed_resumable_retained_job, seed_resumable_retained_job_with_status,
    seed_retained_job_with_internals, seed_retained_job_with_status, serialized_job_row,
    setup_algolia_cloud_job_lifecycle_app, status_generation_checkpoint_count,
};

#[tokio::test]
async fn algolia_cloud_job_resume_accepts_failed_and_interrupted_then_replays_resuming() {
    let db = connect_and_migrate_required("algolia_route_resume_accept_replay").await;
    let source = AlgoliaImportSource::from_final_key_metadata(
        "SERVERAPP123",
        "server_source",
        AlgoliaImportSourceMetadata::new(Some(4096), Some(10), "revision-resume"),
    );
    let source_service = FakeAlgoliaSourceLister::with_inspect([
        Ok(source.clone()),
        Ok(source.clone()),
        Ok(source.clone()),
        Ok(source),
    ]);
    let (app, jwt, customer_id) =
        setup_algolia_cloud_job_lifecycle_app(db.pool.clone(), true, source_service).await;

    for status in [
        AlgoliaImportJobStatus::Failed,
        AlgoliaImportJobStatus::Interrupted,
    ] {
        let key = format!("resume-{}", status.as_str());
        let id = seed_resumable_retained_job_with_status(
            &db.pool,
            customer_id,
            &key,
            &key,
            status,
            Utc::now() + chrono::Duration::hours(1),
        )
        .await;
        let before = status_generation_checkpoint_count(&db.pool, id).await;

        let (accepted_status, _headers, accepted_body) = post_job_action(
            &app,
            &jwt,
            &format!("/migration/algolia/jobs/{id}/resume"),
            json!({ "apiKey": "fresh-resume-key" }),
        )
        .await;

        assert_eq!(
            accepted_status,
            StatusCode::ACCEPTED,
            "body: {accepted_body}"
        );
        assert_eq!(accepted_body["status"], "resuming");
        let after = status_generation_checkpoint_count(&db.pool, id).await;
        assert_eq!(after.0, "resuming");
        assert_eq!(after.1, before.1 + 1);
        assert!(after.2.is_none());
        assert_eq!(after.3, before.3);

        let (replay_status, _headers, replay_body) = post_job_action(
            &app,
            &jwt,
            &format!("/migration/algolia/jobs/{id}/resume"),
            json!({ "apiKey": "fresh-resume-key-again" }),
        )
        .await;
        assert_eq!(replay_status, StatusCode::OK, "body: {replay_body}");
        let replayed = status_generation_checkpoint_count(&db.pool, id).await;
        assert_eq!(replayed, after);
    }
}

#[tokio::test]
async fn algolia_cloud_job_resume_rejects_deleted_customer_without_mutating_retained_job() {
    let db = connect_and_migrate_required("algolia_route_resume_deleted").await;
    let source = AlgoliaImportSource::from_final_key_metadata(
        "SERVERAPP123",
        "server_source",
        AlgoliaImportSourceMetadata::new(Some(4096), Some(10), "revision-deleted-resume"),
    );
    let source_service = FakeAlgoliaSourceLister::with_inspect([Ok(source)]);
    let (app, jwt, customer_id) =
        setup_algolia_cloud_job_lifecycle_app(db.pool.clone(), true, source_service.clone()).await;
    let id = seed_resumable_retained_job(
        &db.pool,
        customer_id,
        "products",
        "resume-deleted",
        Utc::now() + chrono::Duration::hours(1),
    )
    .await;
    let before = serialized_job_row(&db.pool, id).await;
    soft_delete_customer(&db.pool, customer_id).await;

    let (status, headers, body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{id}/resume"),
        json!({ "apiKey": "fresh-submitted-key" }),
    )
    .await;

    assert_eq!(status, StatusCode::CONFLICT, "resume response body: {body}");
    assert!(headers.get(http::header::LOCATION).is_none());
    assert_eq!(
        body,
        json!({
            "error": AlgoliaImportErrorCode::NotResumable.as_str(),
            "code": AlgoliaImportErrorCode::NotResumable.as_str(),
        })
    );
    assert!(!body.to_string().contains("fresh-submitted-key"));
    assert_eq!(source_service.inspect_requests().len(), 1);
    assert_eq!(serialized_job_row(&db.pool, id).await, before);
}

#[tokio::test]
async fn algolia_cloud_job_resume_requires_fresh_non_empty_api_key_before_source_or_mutation() {
    let db = connect_and_migrate_required("algolia_route_resume_empty_key").await;
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, customer_id) =
        setup_algolia_cloud_job_lifecycle_app(db.pool.clone(), true, source_service.clone()).await;
    let id = seed_resumable_retained_job(
        &db.pool,
        customer_id,
        "products",
        "resume-empty-key",
        Utc::now() + chrono::Duration::hours(1),
    )
    .await;

    let (status, _headers, body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{id}/resume"),
        json!({ "apiKey": "" }),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body["code"],
        AlgoliaImportErrorCode::InvalidCredentials.as_str()
    );
    assert!(source_service.inspect_requests().is_empty());
    assert_eq!(
        status_generation_checkpoint_count(&db.pool, id).await,
        (
            "failed".to_string(),
            0,
            Some("opaque-checkpoint-secret".to_string()),
            0
        )
    );
}

#[tokio::test]
async fn algolia_cloud_job_resume_missing_and_foreign_return_identical_404_without_source() {
    let db = connect_and_migrate_required("algolia_route_resume_404").await;
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, _customer_id) =
        setup_algolia_cloud_job_lifecycle_app(db.pool.clone(), true, source_service.clone()).await;
    let other = Uuid::new_v4();
    insert_active_customer(&db.pool, other, 1).await;
    let foreign_id = seed_resumable_retained_job(
        &db.pool,
        other,
        "products",
        "foreign-resume",
        Utc::now() + chrono::Duration::hours(1),
    )
    .await;
    let missing_id = Uuid::new_v4();

    let (missing_status, _missing_headers, missing_body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{missing_id}/resume"),
        json!({ "apiKey": "fresh-key" }),
    )
    .await;
    let (foreign_status, _foreign_headers, foreign_body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{foreign_id}/resume"),
        json!({ "apiKey": "fresh-key" }),
    )
    .await;

    assert_eq!(missing_status, StatusCode::NOT_FOUND);
    assert_eq!(foreign_status, StatusCode::NOT_FOUND);
    assert_eq!(missing_body, foreign_body);
    assert!(source_service.inspect_requests().is_empty());
    assert_eq!(
        status_generation_checkpoint_count(&db.pool, foreign_id)
            .await
            .0,
        "failed"
    );
}

#[tokio::test]
async fn algolia_cloud_job_resume_non_resumable_states_and_elapsed_deadline_return_409() {
    let db = connect_and_migrate_required("algolia_route_resume_refused").await;
    let source = AlgoliaImportSource::from_final_key_metadata(
        "SERVERAPP123",
        "server_source",
        AlgoliaImportSourceMetadata::new(Some(4096), Some(10), "revision-refused"),
    );
    let source_service = FakeAlgoliaSourceLister::with_inspect(
        std::iter::repeat_with(|| Ok(source.clone())).take(12),
    );
    let (app, jwt, customer_id) =
        setup_algolia_cloud_job_lifecycle_app(db.pool.clone(), true, source_service).await;

    for status in [
        AlgoliaImportJobStatus::Queued,
        AlgoliaImportJobStatus::ValidatingSource,
        AlgoliaImportJobStatus::CopyingConfiguration,
        AlgoliaImportJobStatus::CopyingDocuments,
        AlgoliaImportJobStatus::Verifying,
        AlgoliaImportJobStatus::Promoting,
        AlgoliaImportJobStatus::Cancelling,
        AlgoliaImportJobStatus::Cancelled,
        AlgoliaImportJobStatus::Completed,
        AlgoliaImportJobStatus::CompletedWithWarnings,
    ] {
        let key = format!("resume-refused-{}", status.as_str());
        let id = seed_retained_job_with_status(&db.pool, customer_id, &key, &key, status).await;
        let (response_status, _headers, body) = post_job_action(
            &app,
            &jwt,
            &format!("/migration/algolia/jobs/{id}/resume"),
            json!({ "apiKey": "fresh-key" }),
        )
        .await;
        assert_eq!(response_status, StatusCode::CONFLICT, "status={status:?}");
        assert_eq!(body["code"], AlgoliaImportErrorCode::NotResumable.as_str());
        assert_eq!(
            status_generation_checkpoint_count(&db.pool, id).await.0,
            status.as_str()
        );
    }

    let elapsed = seed_resumable_retained_job(
        &db.pool,
        customer_id,
        "elapsed",
        "resume-elapsed",
        Utc::now() - chrono::Duration::seconds(1),
    )
    .await;
    let (elapsed_status, _headers, elapsed_body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{elapsed}/resume"),
        json!({ "apiKey": "fresh-key" }),
    )
    .await;
    assert_eq!(elapsed_status, StatusCode::CONFLICT);
    assert_eq!(
        elapsed_body["code"],
        AlgoliaImportErrorCode::NotResumable.as_str()
    );
    assert_eq!(
        status_generation_checkpoint_count(&db.pool, elapsed)
            .await
            .0,
        "failed"
    );
}

#[tokio::test]
async fn algolia_cloud_job_resume_validates_server_owned_source_before_mutation() {
    let db = connect_and_migrate_required("algolia_route_resume_source").await;
    let source_service =
        FakeAlgoliaSourceLister::with_inspect([Err(AlgoliaSourceError::InvalidCredentials)]);
    let (app, jwt, customer_id) =
        setup_algolia_cloud_job_lifecycle_app(db.pool.clone(), true, source_service.clone()).await;
    let id = seed_resumable_retained_job(
        &db.pool,
        customer_id,
        "products",
        "resume-source",
        Utc::now() + chrono::Duration::hours(1),
    )
    .await;

    let (status, _headers, body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{id}/resume"),
        json!({ "apiKey": "fresh-submitted-key" }),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body["code"],
        AlgoliaImportErrorCode::InvalidCredentials.as_str()
    );
    let requests = source_service.inspect_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].app_id, "SERVERAPP123");
    assert_eq!(requests[0].source_name, "server_source");
    assert_eq!(requests[0].api_key.as_str(), "fresh-submitted-key");
    let persisted: (String, i64, Option<String>) = sqlx::query_as(
        "SELECT status, resume_intent_generation, resume_checkpoint
         FROM algolia_import_jobs WHERE id = $1",
    )
    .bind(id)
    .fetch_one(&db.pool)
    .await
    .expect("read resume refusal state");
    assert_eq!(persisted.0, "failed");
    assert_eq!(persisted.1, 0);
    assert_eq!(persisted.2.as_deref(), Some("opaque-checkpoint-secret"));
    assert!(!body.to_string().contains("fresh-submitted-key"));
}

#[tokio::test]
async fn algolia_cloud_job_resume_source_failures_preserve_internal_state_and_secret_boundaries() {
    let db = connect_and_migrate_required("algolia_route_resume_source_matrix").await;
    let source_service = FakeAlgoliaSourceLister::with_inspect([
        Err(AlgoliaSourceError::ListIndexesAclRequired),
        Err(AlgoliaSourceError::SourcePermissionRequired),
        Err(AlgoliaSourceError::SourceIndexNotFound),
        Err(AlgoliaSourceError::Unavailable),
    ]);
    let (app, jwt, customer_id) =
        setup_algolia_cloud_job_lifecycle_app(db.pool.clone(), true, source_service).await;

    for (suffix, source_error, expected_status, expected_code) in [
        (
            "list-acl",
            "list_acl",
            StatusCode::FORBIDDEN,
            AlgoliaImportErrorCode::MissingSourcePermission,
        ),
        (
            "final-acl",
            "final_acl",
            StatusCode::FORBIDDEN,
            AlgoliaImportErrorCode::MissingSourcePermission,
        ),
        (
            "not-found",
            "not_found",
            StatusCode::BAD_REQUEST,
            AlgoliaImportErrorCode::SourceNotFound,
        ),
        (
            "unavailable",
            "unavailable",
            StatusCode::SERVICE_UNAVAILABLE,
            AlgoliaImportErrorCode::BackendUnavailable,
        ),
    ] {
        let id = seed_resumable_retained_job(
            &db.pool,
            customer_id,
            &format!("products-{suffix}"),
            source_error,
            Utc::now() + chrono::Duration::hours(1),
        )
        .await;
        let before = status_generation_checkpoint_count(&db.pool, id).await;
        let submitted_key = format!("fresh-secret-{suffix}");

        let (status, headers, body) = post_job_action(
            &app,
            &jwt,
            &format!("/migration/algolia/jobs/{id}/resume"),
            json!({ "apiKey": submitted_key }),
        )
        .await;

        assert_eq!(status, expected_status, "body: {body}");
        assert_eq!(body["code"], expected_code.as_str());
        if expected_status == StatusCode::SERVICE_UNAVAILABLE {
            assert_eq!(
                headers
                    .get(http::header::RETRY_AFTER)
                    .and_then(|value| value.to_str().ok()),
                Some("30")
            );
        }
        assert_eq!(
            status_generation_checkpoint_count(&db.pool, id).await,
            before
        );
        assert!(!body.to_string().contains(&submitted_key));
        assert!(!serialized_job_row(&db.pool, id)
            .await
            .contains(&submitted_key));
    }
}

#[test]
fn algolia_cloud_job_resume_request_debug_redacts_api_key() {
    let request: api::routes::migration::ResumeAlgoliaImportJobRequest =
        serde_json::from_value(json!({ "apiKey": "fresh-debug-secret" }))
            .expect("resume request should deserialize");
    let output = format!("{request:?}");
    assert!(output.contains("[REDACTED]"));
    assert!(!output.contains("fresh-debug-secret"));
}

#[test]
fn algolia_cloud_job_resume_source_inspection_tracing_redacts_api_key() {
    let _guard = tracing_test_lock();
    let buffer = Arc::new(Mutex::new(Vec::new()));
    let writer = CapturedTraceWriter(buffer.clone());
    let subscriber = tracing_subscriber::registry().with(
        tracing_subscriber::fmt::layer()
            .json()
            .with_writer(writer)
            .with_current_span(true)
            .with_span_list(true),
    );
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("current-thread runtime should build");
    let submitted_key = "fresh-resume-secret-that-must-not-leak";

    tracing::subscriber::with_default(subscriber, || {
        tracing::callsite::rebuild_interest_cache();
        runtime.block_on(async {
            let service = AlgoliaSourceService::new(
                Arc::new(FailingAlgoliaSourceClient {
                    error: AlgoliaClientError::Timeout,
                }),
                b"migration-route-test-cursor-key-000000000000",
            )
            .expect("source service should build");

            let error = service
                .inspect_source(AlgoliaSourceInspectRequest {
                    app_id: "SERVERAPP123".to_string(),
                    api_key: zeroize::Zeroizing::new(submitted_key.to_string()),
                    source_name: "server_source".to_string(),
                })
                .await
                .expect_err("timeout should be surfaced");

            assert_eq!(error, AlgoliaSourceError::TimedOut);
        });
    });

    let output = String::from_utf8(buffer.lock().unwrap().clone())
        .expect("captured tracing output should be UTF-8");
    assert!(output.contains("Algolia source inspection failed"));
    assert!(output.contains("[REDACTED]"));
    assert!(!output.contains(submitted_key));
    assert!(!output.contains("SERVERAPP123"));
}

#[tokio::test]
async fn algolia_cloud_job_lifecycle_responses_reject_client_state_and_hide_sentinels() {
    let db = connect_and_migrate_required("algolia_route_lifecycle_sentinels").await;
    let source = AlgoliaImportSource::from_final_key_metadata(
        "SERVERAPP123",
        "server_source",
        AlgoliaImportSourceMetadata::new(Some(4096), Some(10), "revision-sentinel"),
    );
    let source_service = FakeAlgoliaSourceLister::with_inspect([Ok(source)]);
    let (app, jwt, customer_id) =
        setup_algolia_cloud_job_lifecycle_app(db.pool.clone(), true, source_service).await;
    let cancel_id = seed_retained_job_with_internals(
        &db.pool,
        customer_id,
        "cancel-sentinel",
        "cancel-sentinel",
        Utc::now(),
    )
    .await;
    let resume_id = seed_resumable_retained_job(
        &db.pool,
        customer_id,
        "resume-sentinel",
        "resume-sentinel",
        Utc::now() + chrono::Duration::hours(1),
    )
    .await;
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET worker_claimed_at = NOW(), worker_lease_expires_at = NOW() + INTERVAL '1 minute'
         WHERE id IN ($1, $2)",
    )
    .bind(cancel_id)
    .bind(resume_id)
    .execute(&db.pool)
    .await
    .expect("seed lifecycle sentinels");

    for (id, action, body) in [
        (cancel_id, "cancel", json!({})),
        (
            resume_id,
            "resume",
            json!({ "apiKey": "fresh-sentinel-key" }),
        ),
    ] {
        let (status, _headers, response) = post_job_action(
            &app,
            &jwt,
            &format!("/migration/algolia/jobs/{id}/{action}"),
            body,
        )
        .await;
        assert!(matches!(status, StatusCode::ACCEPTED | StatusCode::OK));
        let serialized = response.to_string();
        for forbidden in [
            "resumeCheckpoint",
            "idempotencyKey",
            "canonicalFingerprint",
            "engineJobId",
            "workerLeaseExpiresAt",
            "workerClaimedAt",
            "routingIdentity",
            "physicalUid",
            "reservedIndexCount",
            "reservedCustomerStorageBytes",
            "reservedNodeTransientBytes",
            "opaque-checkpoint-secret",
            "idem-secret",
            "secret-fingerprint",
            "routing-secret-id",
            "phys-secret-uid",
            "fresh-sentinel-key",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "{action} response leaked {forbidden}: {serialized}"
            );
        }
    }

    let before = status_generation_checkpoint_count(&db.pool, resume_id).await;
    for body in [
        json!({ "apiKey": "fresh-key", "resumeCheckpoint": "client-checkpoint" }),
        json!({ "apiKey": "fresh-key", "source": { "name": "override" } }),
        json!({ "apiKey": "fresh-key", "appId": "CLIENTAPP123" }),
        json!({ "apiKey": "fresh-key", "target": "override" }),
        json!({ "apiKey": "fresh-key", "unexpected": true }),
    ] {
        let (status, _headers, _body) = post_job_action(
            &app,
            &jwt,
            &format!("/migration/algolia/jobs/{resume_id}/resume"),
            body,
        )
        .await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    }
    assert_eq!(
        status_generation_checkpoint_count(&db.pool, resume_id).await,
        before
    );
}

#[tokio::test]
async fn algolia_cloud_job_resume_repository_backpressure_is_retryable_503_and_reads_cancel_survive(
) {
    let db = connect_and_migrate_required("algolia_route_resume_repo_backpressure").await;
    let source = AlgoliaImportSource::from_final_key_metadata(
        "SERVERAPP123",
        "server_source",
        AlgoliaImportSourceMetadata::new(Some(4096), Some(10), "revision-backpressure"),
    );
    let source_service = FakeAlgoliaSourceLister::with_inspect([Ok(source)]);
    let (app, jwt, customer_id) =
        setup_algolia_cloud_job_lifecycle_app(db.pool.clone(), true, source_service).await;
    let resume_id = seed_replace_resumable_retained_job_without_target(
        &db.pool,
        customer_id,
        "missing-replace-target",
        "resume-backpressure",
    )
    .await;
    let cancel_id = seed_retained_job_with_internals(
        &db.pool,
        customer_id,
        "cancel-backpressure",
        "cancel-backpressure",
        Utc::now(),
    )
    .await;

    let (resume_status, resume_headers, resume_body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{resume_id}/resume"),
        json!({ "apiKey": "fresh-key" }),
    )
    .await;
    assert_eq!(resume_status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        resume_headers
            .get(http::header::RETRY_AFTER)
            .and_then(|value| value.to_str().ok()),
        Some("30")
    );
    assert_eq!(
        resume_body["code"],
        AlgoliaImportErrorCode::BackendUnavailable.as_str()
    );
    assert_eq!(
        status_generation_checkpoint_count(&db.pool, resume_id)
            .await
            .0,
        "failed"
    );

    let (list_status, list_body) = get_json(&app, &jwt, "/migration/algolia/jobs").await;
    assert_eq!(list_status, StatusCode::OK);
    assert!(list_body["jobs"]
        .as_array()
        .unwrap()
        .iter()
        .any(|job| job["id"] == cancel_id.to_string()));
    let (get_status, get_body) =
        get_json(&app, &jwt, &format!("/migration/algolia/jobs/{cancel_id}")).await;
    assert_eq!(get_status, StatusCode::OK);
    assert_eq!(get_body["id"], cancel_id.to_string());

    let (cancel_status, cancel_headers, cancel_body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{cancel_id}/cancel"),
        json!({}),
    )
    .await;
    assert_eq!(cancel_status, StatusCode::ACCEPTED);
    assert!(cancel_headers.get(http::header::RETRY_AFTER).is_none());
    assert_eq!(cancel_body["status"], "cancelling");
}

#[tokio::test]
async fn algolia_cloud_job_resume_exposure_disabled_returns_retryable_503_but_cancel_still_works() {
    let db = connect_and_migrate_required("algolia_route_resume_exposure").await;
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, customer_id) =
        setup_algolia_cloud_job_lifecycle_app(db.pool.clone(), false, source_service.clone()).await;
    let resumable_id = seed_resumable_retained_job(
        &db.pool,
        customer_id,
        "resume-products",
        "resume-exposure",
        Utc::now() + chrono::Duration::hours(1),
    )
    .await;
    let cancel_id = seed_retained_job_with_internals(
        &db.pool,
        customer_id,
        "cancel-products",
        "cancel-exposure",
        Utc::now(),
    )
    .await;

    let (resume_status, resume_headers, resume_body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{resumable_id}/resume"),
        json!({ "apiKey": "fresh-key" }),
    )
    .await;
    assert_eq!(resume_status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        resume_headers
            .get(http::header::RETRY_AFTER)
            .and_then(|value| value.to_str().ok()),
        Some("30")
    );
    assert_eq!(
        resume_body["code"],
        AlgoliaImportErrorCode::BackendUnavailable.as_str()
    );
    assert!(source_service.inspect_requests().is_empty());

    let (cancel_status, _headers, cancel_body) = post_job_action(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{cancel_id}/cancel"),
        json!({}),
    )
    .await;
    assert_eq!(cancel_status, StatusCode::ACCEPTED);
    assert_eq!(cancel_body["status"], "cancelling");
    assert_eq!(cancel_body["resumable"], false);
    assert!(source_service.inspect_requests().is_empty());
}
