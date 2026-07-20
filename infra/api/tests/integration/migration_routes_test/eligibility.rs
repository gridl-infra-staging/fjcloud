use super::*;

#[tokio::test]
async fn algolia_cloud_job_eligibility_provider_accepts_available_aws_create_regions() {
    let (app, jwt) = setup_algolia_cloud_job_test_app(true).await;

    for region in ["us-east-1", "eu-west-1"] {
        let (status, _headers, body) = post_destination_eligibility(
            app.clone(),
            Some(&jwt),
            json!({
                "phase": "provider",
                "mode": "create",
                "target": { "region": region, "name": "products" }
            }),
        )
        .await;

        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["phase"], "provider");
        assert_eq!(body["mode"], "create");
        assert_eq!(body["provider"], "aws");
        assert_eq!(body["target"]["kind"], "create");
        assert_eq!(body["target"]["region"], region);
        assert_eq!(body["target"]["name"], "products");
        assert!(body["eligibilityToken"]
            .as_str()
            .is_some_and(|token| token.len() > 64));
        assert!(body["expiresAt"].as_str().is_some());
        assert_no_secret_eligibility_fields(&body);
    }
}

#[tokio::test]
async fn algolia_cloud_job_eligibility_provider_rejects_non_aws_create_targets() {
    let (app, jwt) = setup_algolia_cloud_job_test_app(true).await;

    for region in [
        "eu-central-1",
        "eu-north-1",
        "us-east-2",
        "us-west-1",
        "unknown",
    ] {
        let (status, _headers, body) = post_destination_eligibility(
            app.clone(),
            Some(&jwt),
            json!({
                "phase": "provider",
                "mode": "create",
                "target": { "region": region, "name": "products" }
            }),
        )
        .await;

        assert_eq!(status, StatusCode::BAD_REQUEST, "{region}");
        assert_eq!(
            body,
            json!({
                "error": "migration_provider_unsupported",
                "code": AlgoliaImportErrorCode::MigrationProviderUnsupported.as_str(),
            }),
            "{region}"
        );
    }
}

#[tokio::test]
async fn algolia_cloud_job_eligibility_exposure_disabled_returns_retryable_backend_unavailable() {
    let (app, jwt) = setup_algolia_cloud_job_test_app(false).await;

    let (status, headers, body) = post_destination_eligibility(
        app,
        Some(&jwt),
        json!({
            "phase": "provider",
            "mode": "create",
            "target": { "region": "us-east-1", "name": "products" }
        }),
    )
    .await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        body,
        json!({
            "error": "backend_unavailable",
            "code": AlgoliaImportErrorCode::BackendUnavailable.as_str(),
        })
    );
    assert_eq!(
        headers
            .get(http::header::RETRY_AFTER)
            .and_then(|value| value.to_str().ok()),
        Some("30")
    );
}

#[tokio::test]
async fn algolia_cloud_job_eligibility_schema_rejects_credentials_and_checkpoints() {
    let (app, jwt) = setup_algolia_cloud_job_test_app(true).await;

    for forbidden in [
        json!({"apiKey": "secret"}),
        json!({"credential": "secret"}),
        json!({"sourceSizeBytes": 99}),
        json!({"checkpoint": "opaque"}),
    ] {
        let mut body = json!({
            "phase": "provider",
            "mode": "create",
            "target": { "region": "us-east-1", "name": "products" }
        });
        body.as_object_mut()
            .unwrap()
            .extend(forbidden.as_object().unwrap().clone());

        let (status, _headers, response) =
            post_destination_eligibility(app.clone(), Some(&jwt), body).await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
        assert!(!response.to_string().contains("secret"));
    }
}

#[tokio::test]
async fn algolia_cloud_job_eligibility_target_finalizes_valid_provider_envelope() {
    let (app, jwt) = setup_algolia_cloud_job_test_app(true).await;
    let token = provider_eligibility_token(&app, &jwt).await;

    let (status, _headers, body) = post_destination_eligibility(
        app,
        Some(&jwt),
        json!({
            "phase": "target",
            "mode": "create",
            "target": { "region": "us-east-1", "name": "products" },
            "eligibilityToken": token,
        }),
    )
    .await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["phase"], "target");
    assert_eq!(body["mode"], "create");
    assert_eq!(body["provider"], "aws");
    assert_eq!(body["target"]["kind"], "create");
    assert_eq!(body["target"]["region"], "us-east-1");
    assert_eq!(body["target"]["name"], "products");
    assert!(body["eligibilityToken"]
        .as_str()
        .is_some_and(|token| token.len() > 64));
    assert!(body["expiresAt"].as_str().is_some());
    assert_no_secret_eligibility_fields(&body);
}

#[tokio::test]
async fn algolia_cloud_job_eligibility_target_requires_an_envelope() {
    let (app, jwt) = setup_algolia_cloud_job_test_app(true).await;

    let (status, _headers, body) = post_destination_eligibility(
        app,
        Some(&jwt),
        json!({
            "phase": "target",
            "mode": "create",
            "target": { "region": "us-east-1", "name": "products" }
        }),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body,
        json!({
            "error": "eligibility_token_required",
            "code": AlgoliaImportErrorCode::DestinationChanged.as_str(),
        })
    );
}

#[tokio::test]
async fn algolia_cloud_job_eligibility_provider_rejects_supplied_envelope() {
    let (app, jwt) = setup_algolia_cloud_job_test_app(true).await;
    let token = provider_eligibility_token(&app, &jwt).await;

    let (status, _headers, body) = post_destination_eligibility(
        app,
        Some(&jwt),
        json!({
            "phase": "provider",
            "mode": "create",
            "target": { "region": "us-east-1", "name": "products" },
            "eligibilityToken": token,
        }),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body,
        json!({
            "error": "unexpected_eligibility_token",
            "code": AlgoliaImportErrorCode::DestinationChanged.as_str(),
        })
    );
}

#[tokio::test]
async fn algolia_cloud_job_eligibility_target_rejects_tampered_envelope() {
    let (app, jwt) = setup_algolia_cloud_job_test_app(true).await;
    let token = provider_eligibility_token(&app, &jwt).await;
    // Flip the final signature character so the HMAC no longer verifies.
    let last = token.chars().last().unwrap();
    let flipped = if last == 'A' { 'B' } else { 'A' };
    let tampered = format!("{}{}", &token[..token.len() - 1], flipped);
    assert_ne!(tampered, token);

    let (status, _headers, body) = post_destination_eligibility(
        app,
        Some(&jwt),
        json!({
            "phase": "target",
            "mode": "create",
            "target": { "region": "us-east-1", "name": "products" },
            "eligibilityToken": tampered,
        }),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body,
        json!({
            "error": "invalid_eligibility_token",
            "code": AlgoliaImportErrorCode::DestinationChanged.as_str(),
        })
    );
}

#[tokio::test]
async fn algolia_cloud_job_eligibility_target_rejects_replayed_target_envelope() {
    let (app, jwt) = setup_algolia_cloud_job_test_app(true).await;
    let provider_token = provider_eligibility_token(&app, &jwt).await;

    let (finalize_status, _headers, finalize_body) = post_destination_eligibility(
        app.clone(),
        Some(&jwt),
        json!({
            "phase": "target",
            "mode": "create",
            "target": { "region": "us-east-1", "name": "products" },
            "eligibilityToken": provider_token,
        }),
    )
    .await;
    assert_eq!(finalize_status, StatusCode::OK);
    let target_token = finalize_body["eligibilityToken"]
        .as_str()
        .unwrap()
        .to_string();

    // Replaying a target-phase envelope back into the target phase is a
    // phase mismatch: only provider envelopes may be finalized.
    let (status, _headers, body) = post_destination_eligibility(
        app,
        Some(&jwt),
        json!({
            "phase": "target",
            "mode": "create",
            "target": { "region": "us-east-1", "name": "products" },
            "eligibilityToken": target_token,
        }),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body,
        json!({
            "error": "eligibility_phase_mismatch",
            "code": AlgoliaImportErrorCode::DestinationChanged.as_str(),
        })
    );
}

#[tokio::test]
async fn algolia_cloud_job_eligibility_target_rejects_cross_customer_envelope() {
    let (app, alice_jwt, bob_jwt) = setup_two_customer_eligibility_app().await;
    let alice_token = provider_eligibility_token(&app, &alice_jwt).await;

    // Bob replays an envelope Alice minted; it must be refused before any state read.
    let (status, _headers, body) = post_destination_eligibility(
        app,
        Some(&bob_jwt),
        json!({
            "phase": "target",
            "mode": "create",
            "target": { "region": "us-east-1", "name": "products" },
            "eligibilityToken": alice_token,
        }),
    )
    .await;

    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(
        body,
        json!({
            "error": "eligibility_customer_mismatch",
            "code": AlgoliaImportErrorCode::DestinationChanged.as_str(),
        })
    );
}

#[tokio::test]
async fn algolia_cloud_job_eligibility_target_accepts_owned_healthy_replace_target() {
    let Some(db) = connect_and_migrate("algolia_eligibility_replace_route_ok").await else {
        return;
    };
    let (app, jwt, customer_id, source_service) =
        setup_algolia_cloud_job_eligibility_app_with_pool(db.pool.clone(), true).await;
    seed_algolia_replace_target(&db.pool, customer_id, "products").await;

    let (status, _headers, body) = post_destination_eligibility(
        app,
        Some(&jwt),
        json!({
            "phase": "target",
            "mode": "replace",
            "target": { "region": "us-east-1", "name": "products" },
        }),
    )
    .await;

    assert_eq!(status, StatusCode::OK, "replace eligibility body: {body}");
    assert_eq!(body["phase"], "target");
    assert_eq!(body["mode"], "replace");
    assert_eq!(body["provider"], "aws");
    assert_eq!(body["target"]["kind"], "replace");
    assert_eq!(body["target"]["region"], "us-east-1");
    assert_eq!(body["target"]["name"], "products");
    assert!(body["eligibilityToken"]
        .as_str()
        .is_some_and(|token| token.len() > 64));
    assert!(body["expiresAt"].as_str().is_some());
    assert_no_secret_eligibility_fields(&body);
    assert!(source_service.inspect_requests().is_empty());
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 0);
}

#[tokio::test]
async fn algolia_cloud_job_eligibility_target_rejects_missing_replace_target_without_source_call() {
    let Some(db) = connect_and_migrate("algolia_eligibility_replace_route_missing").await else {
        return;
    };
    let (app, jwt, _customer_id, source_service) =
        setup_algolia_cloud_job_eligibility_app_with_pool(db.pool.clone(), true).await;

    let (status, _headers, body) = post_destination_eligibility(
        app,
        Some(&jwt),
        json!({
            "phase": "target",
            "mode": "replace",
            "target": { "region": "us-east-1", "name": "products" },
        }),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body,
        json!({
            "error": "destination_changed",
            "code": AlgoliaImportErrorCode::DestinationChanged.as_str(),
        })
    );
    assert!(source_service.inspect_requests().is_empty());
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 0);
}

#[tokio::test]
async fn algolia_cloud_job_eligibility_target_rejects_unhealthy_replace_target_as_backpressure() {
    let Some(db) = connect_and_migrate("algolia_eligibility_replace_route_unhealthy").await else {
        return;
    };
    let (app, jwt, customer_id, source_service) =
        setup_algolia_cloud_job_eligibility_app_with_pool(db.pool.clone(), true).await;
    seed_algolia_replace_target(&db.pool, customer_id, "products").await;
    sqlx::query(
        "UPDATE customer_deployments SET health_status = 'degraded' WHERE customer_id = $1",
    )
    .bind(customer_id)
    .execute(&db.pool)
    .await
    .expect("degrade replace target");

    let (status, headers, body) = post_destination_eligibility(
        app,
        Some(&jwt),
        json!({
            "phase": "target",
            "mode": "replace",
            "target": { "region": "us-east-1", "name": "products" },
        }),
    )
    .await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        body,
        json!({
            "error": "backend_unavailable",
            "code": AlgoliaImportErrorCode::BackendUnavailable.as_str(),
        })
    );
    assert_eq!(
        headers
            .get(http::header::RETRY_AFTER)
            .and_then(|value| value.to_str().ok()),
        Some("30")
    );
    assert!(source_service.inspect_requests().is_empty());
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 0);
}
