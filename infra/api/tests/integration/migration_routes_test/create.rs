use super::*;

#[tokio::test]
async fn algolia_cloud_job_create_accepts_create_request_and_idempotent_replay() {
    let _env = FlapjackIdentityEnvGuard::compatible();
    let Some(db) = connect_and_migrate("algolia_cloud_job_create_accept").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([
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
    let engine_job_id = Uuid::parse_str("9f11d0a0-4443-44d4-b6c6-1ed71dbeb0fb").unwrap();
    flapjack_http.expect_sensitive_json_body(
        r#"{"appId":"TESTAPP123","apiKey":"temporary-create-key","sourceIndex":"source_products","targetIndex":"products","overwrite":false}"#,
    );
    flapjack_http.push_sensitive_json_response(
        202,
        json!({
            "jobId": engine_job_id,
            "phase": "submitted",
            "disposition": "running",
            "createdAt": "2026-07-22T00:00:00Z",
            "updatedAt": "2026-07-22T00:00:00Z"
        }),
    );
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
    assert_eq!(persisted.0, "committed");
    assert_eq!(persisted.1, Some(engine_job_id));
    // Replay short-circuits before source inspection and placement, so only the
    // create and the changed (conflicting) request inspect the source and run a
    // fresh engine-compatibility check; the exact replay does neither.
    assert_eq!(source_service.inspect_requests().len(), 2);
    assert_eq!(flapjack_http.request_count(), 3);
    assert_eq!(flapjack_http.take_sensitive_requests().len(), 1);
}

#[tokio::test]
async fn algolia_cloud_job_create_retains_ambiguous_job_when_socket_result_is_lost() {
    let _env = FlapjackIdentityEnvGuard::compatible();
    let Some(db) = connect_and_migrate("algolia_create_lost_socket").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([
        Ok(inspected_source("CANARYAPP123", "source_products", "rev-1")),
        Ok(inspected_source("CANARYAPP123", "source_products", "rev-1")),
    ]);
    let (app, jwt, _customer_id, flapjack_http, alert_service) =
        setup_algolia_cloud_job_create_app_with_alerts(db.pool.clone(), source_service.clone())
            .await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;
    let secret_canary = "secret-api-key-canary-lost-socket";
    flapjack_http.expect_sensitive_json_body(
        r#"{"appId":"CANARYAPP123","apiKey":"secret-api-key-canary-lost-socket","sourceIndex":"source_products","targetIndex":"products","overwrite":false}"#,
    );
    flapjack_http.push_error(ProxyError::Timeout);
    let request = create_request_with_app_and_key(
        "CANARYAPP123",
        "source_products",
        secret_canary,
        &target_token,
    );

    let (status, headers, body) =
        post_create_job(app.clone(), &jwt, "idem-lost-socket", request.clone()).await;
    assert_eq!(status, StatusCode::ACCEPTED, "body: {body}");
    let retained_id = Uuid::parse_str(body["id"].as_str().unwrap()).unwrap();
    let location = headers
        .get(http::header::LOCATION)
        .and_then(|value| value.to_str().ok())
        .expect("Location header");
    assert_eq!(location, format!("/migration/algolia/jobs/{retained_id}"));
    assert_ambiguous_without_engine_id(&db.pool, retained_id).await;
    assert_no_submit_canary_retained(
        secret_canary,
        "CANARYAPP123",
        &[
            body.clone(),
            serialized_import_job_row(&db.pool, retained_id).await,
        ],
        &alert_service.recorded_alerts(),
        &flapjack_http.take_sensitive_requests(),
        &source_service.inspect_requests(),
    );

    let (replay_status, _replay_headers, replay_body) =
        post_create_job(app, &jwt, "idem-lost-socket", request).await;
    assert_eq!(replay_status, StatusCode::ACCEPTED);
    assert_eq!(replay_body["id"], body["id"]);
    assert_eq!(flapjack_http.take_sensitive_requests().len(), 1);
    // The replay returns the retained ambiguous job without re-inspecting.
    assert_eq!(source_service.inspect_requests().len(), 1);
}

/// Linkage recording fails *after* a valid engine `202`. The dispatch guard is
/// released before committed-linkage recording runs, so the failure is injected
/// deterministically at the repository seam rather than by racing a lifecycle
/// mutation against the guard's customer-row lock (which would deadlock, since
/// the guard holds that lock across the send while any lifecycle write would
/// wait on it). The retained job must stay ambiguous with no engine id, exactly
/// one credential send must have occurred, and no credential may be retained.
#[tokio::test]
async fn algolia_cloud_job_create_retains_ambiguous_job_when_linkage_fails_after_engine_acceptance()
{
    let _env = FlapjackIdentityEnvGuard::compatible();
    let Some(db) = connect_and_migrate("algolia_create_linkage_fail").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([Ok(inspected_source(
        "CANARYAPP456",
        "source_products",
        "rev-1",
    ))]);
    let harness =
        setup_algolia_cloud_job_create_harness(db.pool.clone(), source_service.clone()).await;
    let secret_canary = "secret-api-key-canary-linkage-fail";
    harness.flapjack_http.expect_sensitive_json_body(
        r#"{"appId":"CANARYAPP456","apiKey":"secret-api-key-canary-linkage-fail","sourceIndex":"source_products","targetIndex":"products","overwrite":false}"#,
    );
    harness.flapjack_http.push_sensitive_json_response(
        202,
        json!({
            "jobId": "65ebbe28-0409-4c52-82d1-d62beaa66a88",
            "phase": "submitted",
            "disposition": "running",
            "createdAt": "2026-07-22T00:00:00Z",
            "updatedAt": "2026-07-22T00:00:00Z"
        }),
    );

    // A real repository owns admission, the guard, and the send; only
    // committed-linkage recording is forced to fail, after the guard releases.
    let failing_repo = RecordCommitFailingRepo::new(PgAlgoliaImportJobRepo::new(db.pool.clone()));
    let request = AlgoliaImportAdmissionRequest::new(
        AlgoliaImportTargetBinding::create(harness.customer_id, "products", "us-east-1"),
        Some(AlgoliaImportCreatePlacement {
            vm_id: harness.vm_id,
            physical_uid: "algolia-create-linkage-fail".to_string(),
        }),
        "CANARYAPP456".to_string(),
        secret_canary.to_string(),
        "source_products".to_string(),
        "idem-linkage-fail".to_string(),
    );

    let outcome = harness
        .state
        .algolia_import_service
        .admit_and_submit_with_repo(
            request,
            &failing_repo,
            source_service.as_ref(),
            harness.state.vm_inventory_repo.as_ref(),
            harness.alert_service.as_ref(),
        )
        .await
        .expect("admission returns the retained ambiguous job even when linkage fails");

    let retained_job = match outcome {
        AlgoliaImportAdmissionOutcome::New(job) => job,
        AlgoliaImportAdmissionOutcome::Replay(_) => {
            panic!("a linkage failure must not present as an idempotent replay")
        }
    };
    let retained_id = retained_job.id;
    assert_ambiguous_without_engine_id(&db.pool, retained_id).await;

    // Exactly one credential-bearing send occurred; linkage failure must never
    // trigger an automatic credential replay.
    assert_eq!(harness.flapjack_http.take_sensitive_requests().len(), 1);
    assert_eq!(source_service.inspect_requests().len(), 1);
    let alerts = harness.alert_service.recorded_alerts();
    assert_eq!(alerts.len(), 1, "one sanitized retention alert must fire");
    assert_eq!(alerts[0].metadata["reason"], "dispatch_linkage_failed");

    assert_no_submit_canary_retained(
        secret_canary,
        "CANARYAPP456",
        &[serialized_import_job_row(&db.pool, retained_id).await],
        &alerts,
        &harness.flapjack_http.take_sensitive_requests(),
        &source_service.inspect_requests(),
    );
}

#[tokio::test]
async fn algolia_cloud_job_create_hygiene_distinguishes_public_app_id_from_secret_api_key() {
    let _env = FlapjackIdentityEnvGuard::compatible();
    let Some(db) = connect_and_migrate("algolia_create_hygiene").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([Ok(inspected_source(
        "PUBLICAPPID789",
        "source_products",
        "rev-1",
    ))]);
    let (app, jwt, _customer_id, flapjack_http, alert_service) =
        setup_algolia_cloud_job_create_app_with_alerts(db.pool.clone(), source_service.clone())
            .await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;
    let secret_canary = "secret-api-key-canary-success";
    flapjack_http.expect_sensitive_json_body(
        r#"{"appId":"PUBLICAPPID789","apiKey":"secret-api-key-canary-success","sourceIndex":"source_products","targetIndex":"products","overwrite":false}"#,
    );
    flapjack_http.push_sensitive_json_response(
        202,
        json!({
            "jobId": "bb8b60db-77bf-4f6c-b88a-56b18860e631",
            "phase": "submitted",
            "disposition": "running",
            "createdAt": "2026-07-22T00:00:00Z",
            "updatedAt": "2026-07-22T00:00:00Z"
        }),
    );

    let (status, _headers, body) = post_create_job(
        app,
        &jwt,
        "idem-hygiene",
        create_request_with_app_and_key(
            "PUBLICAPPID789",
            "source_products",
            secret_canary,
            &target_token,
        ),
    )
    .await;

    assert_eq!(status, StatusCode::ACCEPTED, "body: {body}");
    assert_eq!(body["source"]["appId"], "PUBLICAPPID789");
    let retained_id = Uuid::parse_str(body["id"].as_str().unwrap()).unwrap();
    let retained_row = serialized_import_job_row(&db.pool, retained_id).await;
    assert_eq!(retained_row["algolia_app_id"], "PUBLICAPPID789");
    assert_no_submit_canary_retained(
        secret_canary,
        "PUBLICAPPID789",
        &[body, retained_row],
        &alert_service.recorded_alerts(),
        &flapjack_http.take_sensitive_requests(),
        &source_service.inspect_requests(),
    );
}

#[tokio::test]
async fn algolia_cloud_job_create_rejects_deleted_customer_create_replay_and_new_key_without_mutating_retained_job(
) {
    let _env = FlapjackIdentityEnvGuard::compatible();
    let Some(db) = connect_and_migrate("algolia_route_deleted_create").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([Ok(inspected_source(
        "TESTAPP123",
        "source_products",
        "rev-1",
    ))]);
    let (app, jwt, customer_id, flapjack_http) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;
    flapjack_http.expect_sensitive_json_body(
        r#"{"appId":"TESTAPP123","apiKey":"temporary-create-key","sourceIndex":"source_products","targetIndex":"products","overwrite":false}"#,
    );
    flapjack_http.push_sensitive_json_response(
        202,
        json!({
            "jobId": "7c1cfbdc-d966-43b8-ae80-68f663efde83",
            "phase": "submitted",
            "disposition": "running",
            "createdAt": "2026-07-22T00:00:00Z",
            "updatedAt": "2026-07-22T00:00:00Z"
        }),
    );
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
    // The soft-deleted-customer replay and new-key request are both refused at
    // the generation fence before any source inspection or placement admission,
    // so only the original create inspects the source and probes the engine.
    assert_eq!(source_service.inspect_requests().len(), 1);
    assert_eq!(flapjack_http.request_count(), 2);
    assert_eq!(flapjack_http.take_sensitive_requests().len(), 1);
}

#[tokio::test]
async fn algolia_cloud_job_create_accepts_replace_request_and_idempotent_replay() {
    let _env = FlapjackIdentityEnvGuard::compatible();
    let Some(db) = connect_and_migrate("algolia_cloud_job_replace_accept").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([Ok(inspected_source(
        "TESTAPP123",
        "source_products",
        "rev-1",
    ))]);
    let (app, jwt, customer_id, flapjack_http) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    seed_algolia_replace_target(&db.pool, customer_id, "products").await;
    let target_token = target_replace_eligibility_token(&app, &jwt, "products").await;
    let engine_job_id = Uuid::parse_str("8e447cc1-a0af-4014-a266-ce4a83f43136").unwrap();
    flapjack_http.expect_sensitive_json_body(
        r#"{"appId":"TESTAPP123","apiKey":"temporary-replace-key","sourceIndex":"source_products","targetIndex":"products","overwrite":true}"#,
    );
    flapjack_http.push_sensitive_json_response(
        202,
        json!({
            "jobId": engine_job_id,
            "phase": "submitted",
            "disposition": "running",
            "createdAt": "2026-07-22T00:00:00Z",
            "updatedAt": "2026-07-22T00:00:00Z"
        }),
    );
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
    assert_eq!(persisted.0, "committed");
    assert_eq!(persisted.1, Some(engine_job_id));
    // The exact replay returns the retained job without re-inspecting the source.
    assert_eq!(source_service.inspect_requests().len(), 1);
    assert_eq!(flapjack_http.request_count(), 1);
    assert_eq!(flapjack_http.take_sensitive_requests().len(), 1);
}

#[tokio::test]
async fn algolia_cloud_job_create_rechecks_persisted_vm_before_sensitive_submit() {
    let _env = FlapjackIdentityEnvGuard::compatible();
    let Some(db) = connect_and_migrate("algolia_create_post_persist_vm_drift").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([Ok(inspected_source(
        "DRIFTAPP123",
        "source_products",
        "rev-1",
    ))]);
    let harness =
        setup_algolia_cloud_job_create_harness(db.pool.clone(), source_service.clone()).await;
    let app = axum::Router::new()
        .route(
            "/migration/algolia/destination-eligibility",
            post(api::routes::migration::check_algolia_destination_eligibility),
        )
        .route(
            "/migration/algolia/jobs",
            post(api::routes::migration::create_algolia_import_job),
        )
        .with_state(harness.state.clone());
    let target_token = target_create_eligibility_token(&app, &harness.jwt).await;

    let vm_inventory_repo = harness.state.vm_inventory_repo.clone();
    let vm_id = harness.vm_id;
    harness.flapjack_http.after_next_send(move || {
        let vm_inventory_repo = vm_inventory_repo.clone();
        async move {
            vm_inventory_repo
                .set_status(vm_id, "draining")
                .await
                .expect("drift persisted destination after placement admission");
        }
    });

    let (status, headers, body) = post_create_job(
        app,
        &harness.jwt,
        "idem-post-persist-vm-drift",
        create_request_with_app_and_key(
            "DRIFTAPP123",
            "source_products",
            "drift-secret-canary",
            &target_token,
        ),
    )
    .await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "body: {body}");
    assert_eq!(
        headers
            .get(http::header::RETRY_AFTER)
            .and_then(|value| value.to_str().ok()),
        Some("30")
    );
    assert_eq!(
        body["code"],
        AlgoliaImportErrorCode::BackendUnavailable.as_str()
    );
    let retained: (String, Option<Uuid>, Option<String>, bool) = sqlx::query_as(
        "SELECT dispatch_intent_state, engine_job_id, error_code, retryable
         FROM algolia_import_jobs",
    )
    .fetch_one(&db.pool)
    .await
    .expect("read retained destination-drift job");
    assert_eq!(retained.0, "ambiguous");
    assert_eq!(retained.1, None);
    assert_eq!(
        retained.2.as_deref(),
        Some(AlgoliaImportErrorCode::BackendUnavailable.as_str())
    );
    assert!(retained.3);
    assert_eq!(harness.flapjack_http.request_count(), 1);
    assert_eq!(harness.flapjack_http.take_sensitive_requests().len(), 0);
    let alerts = harness.alert_service.recorded_alerts();
    assert_eq!(alerts.len(), 1);
    assert_eq!(alerts[0].metadata["reason"], "backend_unavailable");
    let exposed = format!("{body:?}{alerts:?}");
    assert!(!exposed.contains("drift-secret-canary"));
}

#[tokio::test]
async fn algolia_cloud_job_create_retains_retryable_pressure_without_sensitive_submit() {
    let _env = FlapjackIdentityEnvGuard::compatible();
    let Some(db) = connect_and_migrate("algolia_create_runtime_pressure").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([Ok(inspected_source(
        "PRESSUREAPP123",
        "source_products",
        "rev-1",
    ))]);
    let (app, jwt, _customer_id, flapjack_http, alert_service) =
        setup_algolia_cloud_job_create_app_with_alerts(db.pool.clone(), source_service.clone())
            .await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;
    flapjack_http.clear_responses();
    flapjack_http.push_json_response(
        200,
        json!({
            "version": "1.0.10",
            "producer_revision": "abc123",
            "build_id": "build-1",
            "binary_sha256": "sha-1",
            "dirty": false,
            "capabilities": ["vectorSearchLocal"]
        }),
    );
    flapjack_http.push_error(ProxyError::Timeout);
    let request = create_request_with_app_and_key(
        "PRESSUREAPP123",
        "source_products",
        "pressure-secret-canary",
        &target_token,
    );
    let (status, headers, body) =
        post_create_job(app.clone(), &jwt, "idem-runtime-pressure", request.clone()).await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "body: {body}");
    assert_eq!(
        headers
            .get(http::header::RETRY_AFTER)
            .and_then(|value| value.to_str().ok()),
        Some("30")
    );
    assert_eq!(
        body["code"],
        AlgoliaImportErrorCode::BackendUnavailable.as_str()
    );
    let retained: (Uuid, String, Option<Uuid>, Option<String>, bool, String) = sqlx::query_as(
        "SELECT id, dispatch_intent_state, engine_job_id, error_code, retryable,
                physical_uid
         FROM algolia_import_jobs",
    )
    .fetch_one(&db.pool)
    .await
    .expect("read retained pressure job");
    assert_eq!(retained.1, "ambiguous");
    assert_eq!(retained.2, None);
    assert_eq!(
        retained.3.as_deref(),
        Some(AlgoliaImportErrorCode::BackendUnavailable.as_str())
    );
    assert!(retained.4);
    assert_eq!(flapjack_http.take_sensitive_requests().len(), 0);

    let (replay_status, replay_headers, replay_body) =
        post_create_job(app.clone(), &jwt, "idem-runtime-pressure", request).await;
    assert_eq!(replay_status, StatusCode::ACCEPTED);
    assert_eq!(replay_body["id"], retained.0.to_string());
    let expected_location = format!("/migration/algolia/jobs/{}", retained.0);
    assert_eq!(
        replay_headers
            .get(http::header::LOCATION)
            .and_then(|value| value.to_str().ok()),
        Some(expected_location.as_str())
    );
    assert_eq!(source_service.inspect_requests().len(), 1);
    assert_eq!(flapjack_http.request_count(), 2);
    assert_eq!(flapjack_http.take_sensitive_requests().len(), 0);

    let (list_status, list_body) =
        super::read::support::get_json(&app, &jwt, "/migration/algolia/jobs").await;
    assert_eq!(list_status, StatusCode::OK);
    assert_eq!(list_body["jobs"].as_array().unwrap().len(), 1);
    assert_eq!(list_body["jobs"][0]["id"], retained.0.to_string());
    let (get_status, get_body) = super::read::support::get_json(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs/{}", retained.0),
    )
    .await;
    assert_eq!(get_status, StatusCode::OK);
    assert_eq!(get_body["id"], retained.0.to_string());

    let alerts = alert_service.recorded_alerts();
    assert_eq!(alerts.len(), 1);
    assert_eq!(alerts[0].metadata["reason"], "backend_unavailable");
    let exposed = format!("{body:?}{alerts:?}");
    assert!(!exposed.contains(&retained.5));
    assert!(!exposed.contains("pressure-secret-canary"));
}

#[tokio::test]
async fn algolia_cloud_job_create_maps_pinned_capacity_refusal_to_retained_pressure() {
    let _env = FlapjackIdentityEnvGuard::compatible();
    let Some(db) = connect_and_migrate("algolia_create_capacity_pressure").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([Ok(inspected_source(
        "CAPACITYAPP123",
        "source_products",
        "rev-1",
    ))]);
    let (app, jwt, _customer_id, flapjack_http, alert_service) =
        setup_algolia_cloud_job_create_app_with_alerts(db.pool.clone(), source_service).await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;
    flapjack_http.expect_sensitive_json_body(
        r#"{"appId":"CAPACITYAPP123","apiKey":"capacity-secret-canary","sourceIndex":"source_products","targetIndex":"products","overwrite":false}"#,
    );
    flapjack_http.push_sensitive_json_response(
        503,
        json!({
            "code": "migration_capacity_exhausted",
            "message": "internal engine capacity detail"
        }),
    );

    let (status, headers, body) = post_create_job(
        app,
        &jwt,
        "idem-capacity-pressure",
        create_request_with_app_and_key(
            "CAPACITYAPP123",
            "source_products",
            "capacity-secret-canary",
            &target_token,
        ),
    )
    .await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "body: {body}");
    assert_eq!(
        headers
            .get(http::header::RETRY_AFTER)
            .and_then(|value| value.to_str().ok()),
        Some("30")
    );
    assert_eq!(
        body,
        json!({
            "error": AlgoliaImportErrorCode::BackendUnavailable.as_str(),
            "code": AlgoliaImportErrorCode::BackendUnavailable.as_str(),
        })
    );
    let retained: (String, Option<Uuid>, Option<String>, bool) = sqlx::query_as(
        "SELECT dispatch_intent_state, engine_job_id, error_code, retryable
         FROM algolia_import_jobs",
    )
    .fetch_one(&db.pool)
    .await
    .expect("read retained capacity refusal");
    assert_eq!(retained.0, "ambiguous");
    assert_eq!(retained.1, None);
    assert_eq!(
        retained.2.as_deref(),
        Some(AlgoliaImportErrorCode::BackendUnavailable.as_str())
    );
    assert!(retained.3);
    assert_eq!(flapjack_http.take_sensitive_requests().len(), 1);
    let alerts = alert_service.recorded_alerts();
    assert_eq!(alerts.len(), 1);
    assert_eq!(alerts[0].metadata["reason"], "backend_unavailable");
    let exposed = format!("{body:?}{alerts:?}");
    assert!(!exposed.contains("capacity-secret-canary"));
    assert!(!exposed.contains("internal engine capacity detail"));
}

#[tokio::test]
async fn algolia_cloud_job_create_rejects_deleted_customer_replace_replay_and_new_key_without_mutating_retained_job(
) {
    let _env = FlapjackIdentityEnvGuard::compatible();
    let Some(db) = connect_and_migrate("algolia_route_deleted_replace").await else {
        return;
    };
    let source_service = FakeAlgoliaSourceLister::with_inspect([Ok(inspected_source(
        "TESTAPP123",
        "source_products",
        "rev-1",
    ))]);
    let (app, jwt, customer_id, flapjack_http) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    seed_algolia_replace_target(&db.pool, customer_id, "products").await;
    let target_token = target_replace_eligibility_token(&app, &jwt, "products").await;
    flapjack_http.expect_sensitive_json_body(
        r#"{"appId":"TESTAPP123","apiKey":"temporary-replace-key","sourceIndex":"source_products","targetIndex":"products","overwrite":true}"#,
    );
    flapjack_http.push_sensitive_json_response(
        202,
        json!({
            "jobId": "a62a5b34-52d0-4330-b470-aa5c3b818527",
            "phase": "submitted",
            "disposition": "running",
            "createdAt": "2026-07-22T00:00:00Z",
            "updatedAt": "2026-07-22T00:00:00Z"
        }),
    );
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
    // The soft-deleted-customer replace replay and new-key request are refused
    // at the generation fence, so only the original replace inspects the source.
    assert_eq!(source_service.inspect_requests().len(), 1);
    assert_eq!(flapjack_http.request_count(), 1);
    assert_eq!(flapjack_http.take_sensitive_requests().len(), 1);
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
    create_request_with_app_and_key("TESTAPP123", source_name, api_key, target_token)
}

fn create_request_with_app_and_key(
    app_id: &str,
    source_name: &str,
    api_key: &str,
    target_token: &str,
) -> serde_json::Value {
    json!({
        "mode": "create",
        "appId": app_id,
        "apiKey": api_key,
        "sourceName": source_name,
        "target": { "eligibilityToken": target_token }
    })
}

async fn assert_ambiguous_without_engine_id(pool: &PgPool, id: Uuid) {
    let persisted: (String, Option<Uuid>) = sqlx::query_as(
        "SELECT dispatch_intent_state, engine_job_id FROM algolia_import_jobs WHERE id = $1",
    )
    .bind(id)
    .fetch_one(pool)
    .await
    .expect("read persisted dispatch proof");
    assert_eq!(persisted.0, "ambiguous");
    assert_eq!(persisted.1, None);
}

fn assert_no_submit_canary_retained(
    api_key_canary: &str,
    app_id_canary: &str,
    retained_json_values: &[serde_json::Value],
    alerts: &[api::services::alerting::AlertRecord],
    sensitive_requests: &[crate::common::flapjack_proxy_test_support::SensitiveRequestObservation],
    source_inspect_requests: &[AlgoliaSourceInspectRequest],
) {
    for value in retained_json_values {
        assert!(
            !value.to_string().contains(api_key_canary),
            "retained JSON must not include API-key canary: {value}"
        );
    }
    for alert in alerts {
        let encoded = serde_json::to_string(alert).expect("serialize alert record");
        assert!(!encoded.contains(api_key_canary));
        assert!(!encoded.contains(app_id_canary));
    }
    for request in sensitive_requests {
        let encoded = format!("{request:?}");
        assert!(!encoded.contains(api_key_canary));
        assert!(!encoded.contains(app_id_canary));
    }
    // The source lister keeps every inspection request it observed. Its retained
    // key lives under zeroizing ownership (scrubbed on drop) and its only
    // exposed surface is `Debug`, which redacts both credentials — assert that
    // surface never carries either canary so a retained observation cannot be
    // the silent leak vector the credential-hygiene contract forbids.
    for request in source_inspect_requests {
        let encoded = format!("{request:?}");
        assert!(
            !encoded.contains(api_key_canary),
            "retained source observation must not expose the API-key canary: {encoded}"
        );
        assert!(
            !encoded.contains(app_id_canary),
            "retained source observation must not expose the app-id canary: {encoded}"
        );
    }
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
                    api_key: zeroize::Zeroizing::new(temporary_key.to_string()),
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
