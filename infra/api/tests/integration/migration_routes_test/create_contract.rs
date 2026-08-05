//! Provider-specific hosted-source create request contract tests.
use super::*;

fn create_body_refusal_observation(
    status: StatusCode,
    body: &serde_json::Value,
    provider: &str,
    offending_field: &str,
    secret_canaries: &[&str],
) -> serde_json::Value {
    let error = body
        .get("error")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default();
    let mut body_fields = body
        .as_object()
        .map(|object| object.keys().cloned().collect::<Vec<_>>())
        .unwrap_or_default();
    body_fields.sort();

    json!({
        "status": status.as_u16(),
        "code": body.get("code").cloned().unwrap_or(serde_json::Value::Null),
        "bodyFields": body_fields,
        "errorNamesProvider": error.contains(provider),
        "errorNamesOffendingField": error.contains(offending_field),
        "secretValuesRedacted": secret_canaries
            .iter()
            .all(|secret| !body.to_string().contains(secret)),
    })
}

fn assert_create_request_debug_redacts<T>(
    body: serde_json::Value,
    expected_type: &str,
    secret_canaries: &[&str],
) where
    T: serde::de::DeserializeOwned + std::fmt::Debug,
{
    let request: T = serde_json::from_value(body).expect("create body must deserialize");
    let debug = format!("{request:?}");
    assert!(debug.contains(expected_type), "unexpected Debug: {debug}");
    assert!(debug.contains("[REDACTED]"), "missing redaction: {debug}");
    for secret in secret_canaries {
        assert!(!debug.contains(secret), "Debug leaked {secret}: {debug}");
    }
}

#[tokio::test]
async fn create_contract_rejects_non_json_content_type_at_http_boundary() {
    let (app, jwt) = setup_authenticated_app_with_algolia_flag(true).await;
    let response = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/algolia/jobs")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "text/plain")
                .header("idempotency-key", "non-json-content-type")
                .body(Body::from(
                    json!({
                        "mode": "create",
                        "appId": "CONTENT-TYPE-APP-CANARY",
                        "apiKey": "CONTENT-TYPE-KEY-CANARY",
                        "sourceName": "content_type_source",
                        "target": { "eligibilityToken": "unused-token-canary" }
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::UNSUPPORTED_MEDIA_TYPE);
    let (_, body) = response_json(response).await;
    assert_eq!(
        body,
        json!({
            "error": "content_type_must_be_application_json",
            "code": AlgoliaImportErrorCode::IncompatibleData.as_str(),
        })
    );
}

#[test]
fn create_contract_wire_debug_redacts_every_provider_shape() {
    assert_create_request_debug_redacts::<api::routes::migration::CreateAlgoliaImportJobRequest>(
        json!({
            "mode": "create",
            "appId": "ALGOLIA-DEBUG-APP-CANARY",
            "apiKey": "ALGOLIA-DEBUG-KEY-CANARY",
            "sourceName": "algolia_debug_source_canary",
            "target": { "eligibilityToken": "ALGOLIA-DEBUG-TOKEN-CANARY" }
        }),
        "CreateAlgoliaImportJobRequest",
        &[
            "ALGOLIA-DEBUG-APP-CANARY",
            "ALGOLIA-DEBUG-KEY-CANARY",
            "algolia_debug_source_canary",
            "ALGOLIA-DEBUG-TOKEN-CANARY",
        ],
    );
    assert_create_request_debug_redacts::<api::routes::migration::CreateMeilisearchImportJobRequest>(
        json!({
            "mode": "create",
            "endpoint": "MEILI-DEBUG-ENDPOINT-CANARY",
            "apiKey": "MEILI-DEBUG-KEY-CANARY",
            "sourceIndex": "meili_debug_source_canary",
            "target": { "eligibilityToken": "MEILI-DEBUG-TOKEN-CANARY" }
        }),
        "CreateMeilisearchImportJobRequest",
        &[
            "MEILI-DEBUG-ENDPOINT-CANARY",
            "MEILI-DEBUG-KEY-CANARY",
            "meili_debug_source_canary",
            "MEILI-DEBUG-TOKEN-CANARY",
        ],
    );
    assert_create_request_debug_redacts::<api::routes::migration::CreateTypesenseImportJobRequest>(
        json!({
            "mode": "replace",
            "node": "TYPESENSE-DEBUG-NODE-CANARY",
            "apiKey": "TYPESENSE-DEBUG-KEY-CANARY",
            "sourceIndex": "typesense_debug_source_canary",
            "target": { "eligibilityToken": "TYPESENSE-DEBUG-TOKEN-CANARY" }
        }),
        "CreateTypesenseImportJobRequest",
        &[
            "TYPESENSE-DEBUG-NODE-CANARY",
            "TYPESENSE-DEBUG-KEY-CANARY",
            "typesense_debug_source_canary",
            "TYPESENSE-DEBUG-TOKEN-CANARY",
        ],
    );
}

/// Serde emission must honor the same credential-redaction invariant the hand-written
/// `Debug` impls enforce. These DTOs derive `ToSchema` for the published create union,
/// so `Serialize` is structurally required; without a redacting impl it would become a
/// second plaintext rendering path for live source credentials.
#[test]
fn create_contract_algolia_wire_serialization_redacts_every_sensitive_field() {
    let request: api::routes::migration::CreateAlgoliaImportJobRequest =
        serde_json::from_value(json!({
            "mode": "create",
            "appId": "ALGOLIA-SERDE-APP-CANARY",
            "apiKey": "ALGOLIA-SERDE-KEY-CANARY",
            "sourceName": "algolia_serde_source_canary",
            "target": { "eligibilityToken": "ALGOLIA-SERDE-TOKEN-CANARY" }
        }))
        .expect("the established Algolia create body must remain deserializable");

    assert_eq!(
        serde_json::to_value(&request).expect("the Algolia create DTO must serialize"),
        json!({
            "mode": "create",
            "appId": "[REDACTED]",
            "apiKey": "[REDACTED]",
            "sourceName": "[REDACTED]",
            "target": { "eligibilityToken": "[REDACTED]" }
        })
    );
}

#[test]
fn create_contract_meilisearch_wire_serialization_redacts_every_sensitive_field() {
    let request: api::routes::migration::CreateMeilisearchImportJobRequest =
        serde_json::from_value(json!({
            "mode": "create",
            "endpoint": "https://meili-serde-canary.invalid",
            "apiKey": "MEILI-SERDE-KEY-CANARY",
            "sourceIndex": "meili_serde_source_canary",
            "target": { "eligibilityToken": "MEILI-SERDE-TOKEN-CANARY" }
        }))
        .expect("the established Meilisearch create body must remain deserializable");

    assert_eq!(
        serde_json::to_value(&request).expect("the Meilisearch create DTO must serialize"),
        json!({
            "mode": "create",
            "endpoint": "[REDACTED]",
            "apiKey": "[REDACTED]",
            "sourceIndex": "[REDACTED]",
            "target": { "eligibilityToken": "[REDACTED]" }
        })
    );
}

#[test]
fn create_contract_typesense_wire_serialization_redacts_every_sensitive_field() {
    let request: api::routes::migration::CreateTypesenseImportJobRequest =
        serde_json::from_value(json!({
            "mode": "create",
            "node": "https://typesense-serde-canary.invalid",
            "apiKey": "TYPESENSE-SERDE-KEY-CANARY",
            "sourceIndex": "typesense_serde_source_canary",
            "target": { "eligibilityToken": "TYPESENSE-SERDE-TOKEN-CANARY" }
        }))
        .expect("the established Typesense create body must remain deserializable");

    assert_eq!(
        serde_json::to_value(&request).expect("the Typesense create DTO must serialize"),
        json!({
            "mode": "create",
            "node": "[REDACTED]",
            "apiKey": "[REDACTED]",
            "sourceIndex": "[REDACTED]",
            "target": { "eligibilityToken": "[REDACTED]" }
        })
    );
}

#[tokio::test]
async fn create_contract_preserves_algolia_body_fields_through_handler_dispatch() {
    let db = connect_and_migrate_required("create_contract_algolia_compat").await;
    let source_service =
        FakeAlgoliaSourceLister::with_inspect([Err(AlgoliaSourceError::SourceIndexNotFound)]);
    let (app, jwt, _customer_id, _flapjack) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;

    let (status, _headers, body) = post_create_job_for_provider(
        app,
        &jwt,
        "algolia",
        "create-contract-algolia",
        json!({
            "mode": "create",
            "appId": "ALGOLIA-APP-CANARY",
            "apiKey": "ALGOLIA-KEY-CANARY",
            "sourceName": "algolia_source_canary",
            "target": { "eligibilityToken": target_token }
        }),
    )
    .await;

    let observed = source_service.inspect_requests();
    assert_eq!(
        observed.len(),
        1,
        "the unchanged Algolia body must reach source inspection"
    );
    assert_eq!(observed[0].app_id, "ALGOLIA-APP-CANARY");
    assert_eq!(observed[0].api_key.as_str(), "ALGOLIA-KEY-CANARY");
    assert_eq!(observed[0].source_name, "algolia_source_canary");
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body,
        json!({
            "error": "algolia_source_index_not_found",
            "code": AlgoliaImportErrorCode::SourceNotFound.as_str(),
        })
    );
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 0);

    let debug = format!("{:?}", observed[0]);
    assert!(debug.contains("[REDACTED]"));
    for secret in [
        "ALGOLIA-APP-CANARY",
        "ALGOLIA-KEY-CANARY",
        "algolia_source_canary",
    ] {
        assert!(!debug.contains(secret), "Debug leaked {secret}: {debug}");
    }
}

#[tokio::test]
async fn create_contract_preserves_meilisearch_endpoint_and_source_index() {
    let db = connect_and_migrate_required("create_contract_meilisearch").await;
    let source_service =
        FakeAlgoliaSourceLister::with_inspect([Err(AlgoliaSourceError::SourceIndexNotFound)]);
    let (app, jwt, _customer_id, _flapjack) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;

    let (status, _headers, body) = post_create_job_for_provider(
        app,
        &jwt,
        "meilisearch",
        "create-contract-meilisearch",
        json!({
            "mode": "create",
            "endpoint": "https://meili-create-canary.invalid",
            "apiKey": "MEILI-KEY-CANARY",
            "sourceIndex": "meili_source_canary",
            "target": { "eligibilityToken": target_token }
        }),
    )
    .await;

    let observed = source_service.inspect_requests();
    assert_eq!(
        observed.len(),
        1,
        "the Meilisearch endpoint body must reach handler-owned source inspection"
    );
    assert_eq!(
        observed[0].app_id, "https://meili-create-canary.invalid",
        "the hosted endpoint must remain intact through normalization"
    );
    assert_eq!(observed[0].api_key.as_str(), "MEILI-KEY-CANARY");
    assert_eq!(
        observed[0].source_name, "meili_source_canary",
        "sourceIndex must normalize to the existing internal source name"
    );
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body,
        json!({
            "error": "algolia_source_index_not_found",
            "code": AlgoliaImportErrorCode::SourceNotFound.as_str(),
        })
    );
    assert!(!body.to_string().contains("MEILI-KEY-CANARY"));
    assert!(!body
        .to_string()
        .contains("https://meili-create-canary.invalid"));
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 0);

    let debug = format!("{:?}", observed[0]);
    assert!(debug.contains("[REDACTED]"));
    for secret in [
        "https://meili-create-canary.invalid",
        "MEILI-KEY-CANARY",
        "meili_source_canary",
    ] {
        assert!(!debug.contains(secret), "Debug leaked {secret}: {debug}");
    }
}

#[tokio::test]
async fn create_contract_preserves_typesense_node_and_source_index() {
    let db = connect_and_migrate_required("create_contract_typesense").await;
    let source_service =
        FakeAlgoliaSourceLister::with_inspect([Err(AlgoliaSourceError::SourceIndexNotFound)]);
    let (app, jwt, _customer_id, _flapjack) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;

    let (status, _headers, body) = post_create_job_for_provider(
        app,
        &jwt,
        "typesense",
        "create-contract-typesense",
        json!({
            "mode": "create",
            "node": "https://typesense-create-canary.invalid",
            "apiKey": "TYPESENSE-KEY-CANARY",
            "sourceIndex": "typesense_source_canary",
            "target": { "eligibilityToken": target_token }
        }),
    )
    .await;

    let observed = source_service.inspect_requests();
    assert_eq!(
        observed.len(),
        1,
        "the Typesense node body must reach handler-owned source inspection"
    );
    assert_eq!(
        observed[0].app_id, "https://typesense-create-canary.invalid",
        "the hosted node must remain intact through normalization"
    );
    assert_eq!(observed[0].api_key.as_str(), "TYPESENSE-KEY-CANARY");
    assert_eq!(
        observed[0].source_name, "typesense_source_canary",
        "sourceIndex must normalize to the existing internal source name"
    );
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body,
        json!({
            "error": "algolia_source_index_not_found",
            "code": AlgoliaImportErrorCode::SourceNotFound.as_str(),
        })
    );
    assert!(!body.to_string().contains("TYPESENSE-KEY-CANARY"));
    assert!(!body
        .to_string()
        .contains("https://typesense-create-canary.invalid"));
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 0);

    let debug = format!("{:?}", observed[0]);
    assert!(debug.contains("[REDACTED]"));
    for secret in [
        "https://typesense-create-canary.invalid",
        "TYPESENSE-KEY-CANARY",
        "typesense_source_canary",
    ] {
        assert!(!debug.contains(secret), "Debug leaked {secret}: {debug}");
    }
}

#[tokio::test]
async fn create_contract_refuses_ambiguous_discriminators_inside_the_named_provider_handler() {
    let (app, jwt) = setup_authenticated_app_with_algolia_flag(true).await;
    let request = json!({
        "mode": "create",
        "appId": "AMBIGUOUS-APP-CANARY",
        "endpoint": "https://ambiguous-endpoint-canary.invalid",
        "apiKey": "AMBIGUOUS-KEY-CANARY",
        "sourceName": "algolia_source",
        "sourceIndex": "hosted_source",
        "target": { "eligibilityToken": "unused-token-canary" }
    });
    let mut observed = Vec::new();

    for (provider, offending_field) in [
        ("algolia", "endpoint"),
        ("meilisearch", "appId"),
        ("typesense", "appId"),
    ] {
        let (status, _headers, body) = post_create_job_for_provider(
            app.clone(),
            &jwt,
            provider,
            &format!("ambiguous-{provider}"),
            request.clone(),
        )
        .await;
        observed.push(create_body_refusal_observation(
            status,
            &body,
            provider,
            offending_field,
            &[
                "AMBIGUOUS-APP-CANARY",
                "https://ambiguous-endpoint-canary.invalid",
                "AMBIGUOUS-KEY-CANARY",
            ],
        ));
    }

    let expected = ["algolia", "meilisearch", "typesense"]
        .map(|_| {
            json!({
                "status": StatusCode::BAD_REQUEST.as_u16(),
                "code": AlgoliaImportErrorCode::IncompatibleData.as_str(),
                "bodyFields": ["code", "error"],
                "errorNamesProvider": true,
                "errorNamesOffendingField": true,
                "secretValuesRedacted": true,
            })
        })
        .to_vec();
    assert_eq!(
        observed, expected,
        "ambiguous bodies must be rejected by the named provider handler, not Axum's 422 extractor"
    );
}

#[tokio::test]
async fn create_contract_labels_provider_body_mismatches_instead_of_returning_422() {
    let (app, jwt) = setup_authenticated_app_with_algolia_flag(true).await;
    let cases = [
        (
            "meilisearch",
            "appId",
            json!({
                "mode": "create",
                "appId": "MISMATCH-APP-CANARY",
                "apiKey": "MISMATCH-MEILI-KEY-CANARY",
                "sourceIndex": "hosted_source",
                "target": { "eligibilityToken": "unused-token-canary" }
            }),
            vec!["MISMATCH-APP-CANARY", "MISMATCH-MEILI-KEY-CANARY"],
        ),
        (
            "algolia",
            "endpoint",
            json!({
                "mode": "create",
                "endpoint": "https://mismatch-endpoint-canary.invalid",
                "apiKey": "MISMATCH-ALGOLIA-KEY-CANARY",
                "sourceName": "algolia_source",
                "target": { "eligibilityToken": "unused-token-canary" }
            }),
            vec![
                "https://mismatch-endpoint-canary.invalid",
                "MISMATCH-ALGOLIA-KEY-CANARY",
            ],
        ),
    ];
    let mut observed = Vec::new();

    for (provider, offending_field, body, secret_canaries) in cases {
        let (status, _headers, body) = post_create_job_for_provider(
            app.clone(),
            &jwt,
            provider,
            &format!("mismatch-{provider}"),
            body,
        )
        .await;
        observed.push(create_body_refusal_observation(
            status,
            &body,
            provider,
            offending_field,
            &secret_canaries,
        ));
    }

    let expected = ["meilisearch", "algolia"]
        .map(|_| {
            json!({
                "status": StatusCode::BAD_REQUEST.as_u16(),
                "code": AlgoliaImportErrorCode::IncompatibleData.as_str(),
                "bodyFields": ["code", "error"],
                "errorNamesProvider": true,
                "errorNamesOffendingField": true,
                "secretValuesRedacted": true,
            })
        })
        .to_vec();
    assert_eq!(
        observed, expected,
        "provider/body mismatches must be labelled inside the handler instead of rejected by the extractor"
    );
}
