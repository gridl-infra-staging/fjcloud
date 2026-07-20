use super::*;

#[tokio::test]
async fn algolia_cloud_job_create_accepts_create_request_and_idempotent_replay() {
    let _env = FlapjackIdentityEnvGuard::compatible();
    let Some(db) = connect_and_migrate("algolia_cloud_job_create_accept").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([
        Ok(inspected_source("TESTAPP123", "source_products", "rev-1")),
        Ok(inspected_source("TESTAPP123", "source_products", "rev-1")),
        Ok(inspected_source(
            "TESTAPP123",
            "source_products_v2",
            "rev-2",
        )),
    ]);
    let (app, jwt, _customer_id, flapjack_http) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;
    let request = json!({
        "mode": "create",
        "appId": "TESTAPP123",
        "apiKey": "temporary-create-key",
        "sourceName": "source_products",
        "target": { "eligibilityToken": target_token }
    });
    let changed_request = json!({
        "mode": "create",
        "appId": "TESTAPP123",
        "apiKey": "temporary-create-key",
        "sourceName": "source_products_v2",
        "target": { "eligibilityToken": target_token }
    });

    let (status, headers, body) =
        post_create_job(app.clone(), &jwt, "idem-create-1", request.clone()).await;
    assert_eq!(status, StatusCode::ACCEPTED, "create response body: {body}");
    let location = headers
        .get(http::header::LOCATION)
        .and_then(|value| value.to_str().ok())
        .expect("Location header");
    assert_eq!(
        location,
        format!("/migration/algolia/jobs/{}", body["id"].as_str().unwrap())
    );
    assert_public_job_body(&body, "create", "products", "us-east-1", "source_products");

    let (replay_status, replay_headers, replay_body) =
        post_create_job(app.clone(), &jwt, "idem-create-1", request).await;
    assert_eq!(replay_status, StatusCode::ACCEPTED);
    assert_eq!(replay_body, body);
    assert_eq!(
        replay_headers
            .get(http::header::LOCATION)
            .and_then(|value| value.to_str().ok()),
        Some(location)
    );

    let (changed_status, _changed_headers, changed_body) =
        post_create_job(app, &jwt, "idem-create-1", changed_request).await;
    assert_eq!(changed_status, StatusCode::CONFLICT);
    assert_eq!(
        changed_body,
        json!({
            "error": AlgoliaImportErrorCode::DestinationConflict.as_str(),
            "code": AlgoliaImportErrorCode::DestinationConflict.as_str(),
        })
    );

    let persisted: (String, Option<Uuid>) = sqlx::query_as(
        "SELECT dispatch_intent_state, engine_job_id FROM algolia_import_jobs WHERE id = $1",
    )
    .bind(Uuid::parse_str(body["id"].as_str().unwrap()).unwrap())
    .fetch_one(&db.pool)
    .await
    .expect("read persisted import job");
    assert_eq!(persisted.0, "absent");
    assert!(persisted.1.is_none());
    assert_eq!(source_service.inspect_requests().len(), 3);
    assert_eq!(flapjack_http.request_count(), 3);
}

#[tokio::test]
async fn algolia_cloud_job_create_rejects_deleted_customer_create_replay_and_new_key_without_mutating_retained_job(
) {
    let _env = FlapjackIdentityEnvGuard::compatible();
    let Some(db) = connect_and_migrate("algolia_route_deleted_create").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([
        Ok(inspected_source("TESTAPP123", "source_products", "rev-1")),
        Ok(inspected_source("TESTAPP123", "source_products", "rev-1")),
        Ok(inspected_source("TESTAPP123", "source_products", "rev-2")),
    ]);
    let (app, jwt, customer_id, flapjack_http) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;
    let request = json!({
        "mode": "create",
        "appId": "TESTAPP123",
        "apiKey": "temporary-create-key",
        "sourceName": "source_products",
        "target": { "eligibilityToken": target_token }
    });

    let (accepted_status, _headers, accepted_body) =
        post_create_job(app.clone(), &jwt, "idem-deleted-create", request.clone()).await;
    assert_eq!(accepted_status, StatusCode::ACCEPTED);
    let retained_id = Uuid::parse_str(accepted_body["id"].as_str().unwrap()).unwrap();
    let retained_before = serialized_import_job_row(&db.pool, retained_id).await;
    soft_delete_customer(&db.pool, customer_id).await;

    let (replay_status, replay_headers, replay_body) =
        post_create_job(app.clone(), &jwt, "idem-deleted-create", request.clone()).await;
    assert_eq!(
        replay_status,
        StatusCode::BAD_REQUEST,
        "body: {replay_body}"
    );
    assert!(replay_headers.get(http::header::LOCATION).is_none());
    assert_eq!(
        replay_body,
        json!({
            "error": AlgoliaImportErrorCode::DestinationChanged.as_str(),
            "code": AlgoliaImportErrorCode::DestinationChanged.as_str(),
        })
    );
    assert!(!replay_body.to_string().contains("temporary-create-key"));

    let (new_status, new_headers, new_body) =
        post_create_job(app, &jwt, "idem-deleted-create-new", request).await;
    assert_eq!(new_status, StatusCode::BAD_REQUEST, "body: {new_body}");
    assert!(new_headers.get(http::header::LOCATION).is_none());
    assert_eq!(
        new_body["code"],
        AlgoliaImportErrorCode::DestinationChanged.as_str()
    );
    assert!(!new_body.to_string().contains("temporary-create-key"));

    assert_eq!(count_algolia_import_jobs(&db.pool).await, 1);
    assert_eq!(
        serialized_import_job_row(&db.pool, retained_id).await,
        retained_before
    );
    assert_eq!(source_service.inspect_requests().len(), 3);
    assert_eq!(flapjack_http.request_count(), 3);
}

#[tokio::test]
async fn algolia_cloud_job_create_accepts_replace_request_and_idempotent_replay() {
    let Some(db) = connect_and_migrate("algolia_cloud_job_replace_accept").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([
        Ok(inspected_source("TESTAPP123", "source_products", "rev-1")),
        Ok(inspected_source("TESTAPP123", "source_products", "rev-1")),
    ]);
    let (app, jwt, customer_id, flapjack_http) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    seed_algolia_replace_target(&db.pool, customer_id, "products").await;
    let target_token = target_replace_eligibility_token(&app, &jwt, "products").await;
    let request = json!({
        "mode": "replace",
        "appId": "TESTAPP123",
        "apiKey": "temporary-replace-key",
        "sourceName": "source_products",
        "target": { "eligibilityToken": target_token }
    });

    let (status, headers, body) =
        post_create_job(app.clone(), &jwt, "idem-replace-1", request.clone()).await;
    assert_eq!(
        status,
        StatusCode::ACCEPTED,
        "replace response body: {body}"
    );
    let location = headers
        .get(http::header::LOCATION)
        .and_then(|value| value.to_str().ok())
        .expect("Location header");
    assert_eq!(
        location,
        format!("/migration/algolia/jobs/{}", body["id"].as_str().unwrap())
    );
    assert_public_job_body(&body, "replace", "products", "us-east-1", "source_products");
    assert!(!body.to_string().contains("temporary-replace-key"));

    let (replay_status, replay_headers, replay_body) =
        post_create_job(app, &jwt, "idem-replace-1", request).await;
    assert_eq!(replay_status, StatusCode::ACCEPTED);
    assert_eq!(replay_body, body);
    assert_eq!(
        replay_headers
            .get(http::header::LOCATION)
            .and_then(|value| value.to_str().ok()),
        Some(location)
    );

    let persisted: (String, Option<Uuid>) = sqlx::query_as(
        "SELECT dispatch_intent_state, engine_job_id FROM algolia_import_jobs WHERE id = $1",
    )
    .bind(Uuid::parse_str(body["id"].as_str().unwrap()).unwrap())
    .fetch_one(&db.pool)
    .await
    .expect("read persisted replacement import job");
    assert_eq!(persisted.0, "absent");
    assert!(persisted.1.is_none());
    assert_eq!(source_service.inspect_requests().len(), 2);
    assert_eq!(flapjack_http.request_count(), 0);
}

#[tokio::test]
async fn algolia_cloud_job_create_rejects_deleted_customer_replace_replay_and_new_key_without_mutating_retained_job(
) {
    let Some(db) = connect_and_migrate("algolia_route_deleted_replace").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([
        Ok(inspected_source("TESTAPP123", "source_products", "rev-1")),
        Ok(inspected_source("TESTAPP123", "source_products", "rev-1")),
        Ok(inspected_source("TESTAPP123", "source_products", "rev-2")),
    ]);
    let (app, jwt, customer_id, _flapjack_http) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    seed_algolia_replace_target(&db.pool, customer_id, "products").await;
    let target_token = target_replace_eligibility_token(&app, &jwt, "products").await;
    let request = json!({
        "mode": "replace",
        "appId": "TESTAPP123",
        "apiKey": "temporary-replace-key",
        "sourceName": "source_products",
        "target": { "eligibilityToken": target_token }
    });

    let (accepted_status, _headers, accepted_body) =
        post_create_job(app.clone(), &jwt, "idem-deleted-replace", request.clone()).await;
    assert_eq!(accepted_status, StatusCode::ACCEPTED);
    let retained_id = Uuid::parse_str(accepted_body["id"].as_str().unwrap()).unwrap();
    let retained_before = serialized_import_job_row(&db.pool, retained_id).await;
    soft_delete_customer(&db.pool, customer_id).await;

    let (replay_status, replay_headers, replay_body) =
        post_create_job(app.clone(), &jwt, "idem-deleted-replace", request.clone()).await;
    assert_eq!(
        replay_status,
        StatusCode::BAD_REQUEST,
        "body: {replay_body}"
    );
    assert!(replay_headers.get(http::header::LOCATION).is_none());
    assert_eq!(
        replay_body["code"],
        AlgoliaImportErrorCode::DestinationChanged.as_str()
    );
    assert!(!replay_body.to_string().contains("temporary-replace-key"));

    let (new_status, new_headers, new_body) =
        post_create_job(app, &jwt, "idem-deleted-replace-new", request).await;
    assert_eq!(new_status, StatusCode::BAD_REQUEST, "body: {new_body}");
    assert!(new_headers.get(http::header::LOCATION).is_none());
    assert_eq!(
        new_body["code"],
        AlgoliaImportErrorCode::DestinationChanged.as_str()
    );
    assert!(!new_body.to_string().contains("temporary-replace-key"));

    assert_eq!(count_algolia_import_jobs(&db.pool).await, 1);
    assert_eq!(
        serialized_import_job_row(&db.pool, retained_id).await,
        retained_before
    );
    assert_eq!(source_service.inspect_requests().len(), 3);
}

// ---------------------------------------------------------------------------
// Create-job refusal / atomicity matrix (Stage 2, group 2)
// ---------------------------------------------------------------------------
//
// Every refusal must emit the canonical `AlgoliaImportErrorCode` at the
// intended status, carry a bounded `Retry-After` on 503, never echo the
// submitted temporary key, and — critically — leave no persisted job. These
// tests reuse the create harness and assert the empty `algolia_import_jobs`
// table after each refusal.

fn create_request_with_key(
    source_name: &str,
    api_key: &str,
    target_token: &str,
) -> serde_json::Value {
    json!({
        "mode": "create",
        "appId": "TESTAPP123",
        "apiKey": api_key,
        "sourceName": source_name,
        "target": { "eligibilityToken": target_token }
    })
}

#[tokio::test]
async fn algolia_cloud_job_create_rejects_missing_credentials_without_source_call() {
    let Some(db) = connect_and_migrate("algolia_cloud_job_missing_creds").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, _customer_id, _flapjack) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;

    let (status, _headers, body) = post_create_job(
        app,
        &jwt,
        "idem-missing-creds",
        create_request_with_key("source_products", "", &target_token),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body,
        json!({
            "error": "invalid_algolia_credentials",
            "code": AlgoliaImportErrorCode::InvalidCredentials.as_str(),
        })
    );
    assert!(source_service.inspect_requests().is_empty());
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 0);
}

#[tokio::test]
async fn algolia_cloud_job_create_rejects_missing_source_permission_without_persisting() {
    let Some(db) = connect_and_migrate("algolia_cloud_job_missing_acl").await else {
        return;
    };
    let source_service =
        FakeAlgoliaSourceLister::with_inspect([Err(AlgoliaSourceError::ListIndexesAclRequired)]);
    let (app, jwt, _customer_id, _flapjack) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;

    let (status, _headers, body) = post_create_job(
        app,
        &jwt,
        "idem-missing-acl",
        create_request_with_key("source_products", "temporary-secret-key", &target_token),
    )
    .await;

    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(
        body["code"],
        AlgoliaImportErrorCode::MissingSourcePermission.as_str()
    );
    assert!(!body.to_string().contains("temporary-secret-key"));
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 0);
}

/// A final key that can list and see the index but fails the settings/browse
/// permission probe surfaces the same `403 missing_source_permission` and
/// persists nothing, so a list-only key can never create a job.
#[tokio::test]
async fn algolia_cloud_job_create_rejects_final_key_source_permission_without_persisting() {
    let Some(db) = connect_and_migrate("algolia_cloud_job_missing_final_acl").await else {
        return;
    };
    let source_service =
        FakeAlgoliaSourceLister::with_inspect([Err(AlgoliaSourceError::SourcePermissionRequired)]);
    let (app, jwt, _customer_id, _flapjack) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;

    let (status, _headers, body) = post_create_job(
        app,
        &jwt,
        "idem-missing-final-acl",
        create_request_with_key("source_products", "temporary-secret-key", &target_token),
    )
    .await;

    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(
        body["code"],
        AlgoliaImportErrorCode::MissingSourcePermission.as_str()
    );
    assert!(!body.to_string().contains("temporary-secret-key"));
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 0);
}

#[test]
fn algolia_cloud_job_inspect_source_tracing_never_reveals_temporary_key() {
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
    let temporary_key = "temporary-secret-key-that-must-not-leak";

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
                    app_id: "TESTAPP123".to_string(),
                    api_key: temporary_key.to_string(),
                    source_name: "source_products".to_string(),
                })
                .await
                .expect_err("timeout should be surfaced");

            assert_eq!(error, AlgoliaSourceError::TimedOut);
        });
    });

    let output = String::from_utf8(buffer.lock().unwrap().clone())
        .expect("captured tracing output should be UTF-8");
    assert!(
        output.contains("Algolia source inspection failed"),
        "captured output should include the inspect_source failure event: {output}"
    );
    assert!(output.contains("AlgoliaSourceInspectRequest"));
    assert!(output.contains("[REDACTED]"));
    assert!(!output.contains(temporary_key));
    assert!(!output.contains("TESTAPP123"));
}

#[tokio::test]
async fn algolia_cloud_job_create_rejects_source_not_found_without_persisting() {
    let Some(db) = connect_and_migrate("algolia_cloud_job_source_missing").await else {
        return;
    };
    let source_service =
        FakeAlgoliaSourceLister::with_inspect([Err(AlgoliaSourceError::SourceIndexNotFound)]);
    let (app, jwt, _customer_id, _flapjack) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;

    let (status, _headers, body) = post_create_job(
        app,
        &jwt,
        "idem-source-missing",
        create_request_with_key("ghost_source", "temporary-secret-key", &target_token),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body["code"],
        AlgoliaImportErrorCode::SourceNotFound.as_str()
    );
    assert!(!body.to_string().contains("temporary-secret-key"));
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 0);
}

#[tokio::test]
async fn algolia_cloud_job_create_unavailable_source_returns_retryable_503() {
    let Some(db) = connect_and_migrate("algolia_cloud_job_source_down").await else {
        return;
    };
    let source_service =
        FakeAlgoliaSourceLister::with_inspect([Err(AlgoliaSourceError::Unavailable)]);
    let (app, jwt, _customer_id, _flapjack) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;

    let response = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/algolia/jobs")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .header("idempotency-key", "idem-source-down")
                .body(Body::from(
                    create_request_with_key(
                        "source_products",
                        "temporary-secret-key",
                        &target_token,
                    )
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        response
            .headers()
            .get(http::header::RETRY_AFTER)
            .and_then(|value| value.to_str().ok()),
        Some("30"),
        "create 503 backend_unavailable must carry the bounded Retry-After",
    );
    let (_, body) = response_json(response).await;
    assert_eq!(
        body["code"],
        AlgoliaImportErrorCode::BackendUnavailable.as_str()
    );
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 0);
}

#[tokio::test]
async fn algolia_cloud_job_create_rejects_tampered_eligibility_before_source() {
    let Some(db) = connect_and_migrate("algolia_cloud_job_tampered_create").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, _customer_id, _flapjack) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;
    let last = target_token.chars().last().unwrap();
    let flipped = if last == 'A' { 'B' } else { 'A' };
    let tampered = format!("{}{}", &target_token[..target_token.len() - 1], flipped);

    let (status, _headers, body) = post_create_job(
        app,
        &jwt,
        "idem-tampered",
        create_request_with_key("source_products", "temporary-secret-key", &tampered),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body["code"],
        AlgoliaImportErrorCode::DestinationChanged.as_str()
    );
    // The envelope is verified before any source access or persistence.
    assert!(source_service.inspect_requests().is_empty());
    assert!(!body.to_string().contains("temporary-secret-key"));
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 0);
}

#[tokio::test]
async fn algolia_cloud_job_create_rejects_unknown_request_field() {
    let Some(db) = connect_and_migrate("algolia_cloud_job_unknown_field").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, _customer_id, _flapjack) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;

    let (status, _headers, _body) = post_create_job(
        app,
        &jwt,
        "idem-unknown-field",
        json!({
            "mode": "create",
            "appId": "TESTAPP123",
            "apiKey": "temporary-secret-key",
            "sourceName": "source_products",
            "resumeCheckpoint": "opaque-smuggled-state",
            "target": { "eligibilityToken": target_token }
        }),
    )
    .await;

    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert!(source_service.inspect_requests().is_empty());
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 0);
}

#[tokio::test]
async fn algolia_cloud_job_create_replace_rejects_stale_generation_binding() {
    let Some(db) = connect_and_migrate("algolia_cloud_job_stale_binding").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([Ok(inspected_source(
        "TESTAPP123",
        "source_products",
        "rev-1",
    ))]);
    let (app, jwt, customer_id, _flapjack) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    seed_algolia_replace_target(&db.pool, customer_id, "products").await;
    let target_token = target_replace_eligibility_token(&app, &jwt, "products").await;

    // The customer's lifecycle generation advances after the token was minted:
    // the transactional revalidation must reject the now-stale routing binding.
    sqlx::query(
        "UPDATE customers SET lifecycle_generation = lifecycle_generation + 1 WHERE id = $1",
    )
    .bind(customer_id)
    .execute(&db.pool)
    .await
    .expect("advance customer generation");

    let (status, _headers, body) = post_create_job(
        app,
        &jwt,
        "idem-stale-binding",
        json!({
            "mode": "replace",
            "appId": "TESTAPP123",
            "apiKey": "temporary-secret-key",
            "sourceName": "source_products",
            "target": { "eligibilityToken": target_token }
        }),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body["code"],
        AlgoliaImportErrorCode::DestinationChanged.as_str()
    );
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 0);
}

#[tokio::test]
async fn algolia_cloud_job_create_rejects_when_exposure_disabled() {
    let Some(db) = connect_and_migrate("algolia_cloud_job_exposure_off").await else {
        return;
    };
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    insert_active_customer(&db.pool, customer.id, 1).await;
    let jwt = create_test_jwt(customer.id);
    let app = axum::Router::new()
        .route(
            "/migration/algolia/jobs",
            post(api::routes::migration::create_algolia_import_job),
        )
        .with_state(
            TestStateBuilder::new()
                .with_pool(db.pool.clone())
                .with_customer_repo(customer_repo)
                .with_algolia_migration_enabled(false)
                .build(),
        );

    let response = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/algolia/jobs")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .header("idempotency-key", "idem-exposure-off")
                .body(Body::from(
                    create_request_with_key(
                        "source_products",
                        "temporary-secret-key",
                        "unused.token",
                    )
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        response
            .headers()
            .get(http::header::RETRY_AFTER)
            .and_then(|value| value.to_str().ok()),
        Some("30"),
    );
    let (_, body) = response_json(response).await;
    assert_eq!(
        body["code"],
        AlgoliaImportErrorCode::BackendUnavailable.as_str()
    );
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 0);
}
