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

#[tokio::test]
async fn hosted_create_rejects_private_origin_before_eligibility_or_dispatch() {
    let (app, jwt) = setup_authenticated_app_with_algolia_flag(true).await;
    let response = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/typesense/jobs")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .header("idempotency-key", "private-origin-refusal")
                .body(Body::from(
                    json!({
                        "mode": "create",
                        "node": "https://10.0.0.1",
                        "apiKey": "TYPESENSE-PRIVATE-ORIGIN-KEY-CANARY",
                        "sourceIndex": "private_origin_source",
                        "target": { "eligibilityToken": "unused-token-canary" }
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let (_, body) = response_json(response).await;
    assert_eq!(
        body,
        json!({
            "error": "invalid_source_host",
            "code": AlgoliaImportErrorCode::IncompatibleData.as_str(),
        })
    );
    assert!(!body
        .to_string()
        .contains("TYPESENSE-PRIVATE-ORIGIN-KEY-CANARY"));
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
fn create_contract_meilisearch_wire_serialization_omits_absent_source_revision_children() {
    let request: api::routes::migration::CreateMeilisearchImportJobRequest =
        serde_json::from_value(json!({
            "mode": "create",
            "endpoint": "https://meili-serde-canary.invalid",
            "apiKey": "MEILI-SERDE-KEY-CANARY",
            "sourceIndex": "meili_serde_source_canary",
            "sourceRevision": { "documentCount": 42 },
            "target": { "eligibilityToken": "MEILI-SERDE-TOKEN-CANARY" }
        }))
        .expect("a hosted create body with only the required revision count must deserialize");

    assert_eq!(
        serde_json::to_value(&request).expect("the Meilisearch create DTO must serialize"),
        json!({
            "mode": "create",
            "endpoint": "[REDACTED]",
            "apiKey": "[REDACTED]",
            "sourceIndex": "[REDACTED]",
            "sourceRevision": { "documentCount": 42 },
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

#[derive(Clone, Copy)]
struct UnseededSharedVmCreateCase {
    provider: &'static str,
    schema_prefix: &'static str,
    source_name: &'static str,
}

impl UnseededSharedVmCreateCase {
    fn source_service(self) -> Arc<FakeAlgoliaSourceLister> {
        if self.provider == "algolia" {
            FakeAlgoliaSourceLister::with_inspect([Ok(inspected_source(
                "UNSEEDEDAPP",
                self.source_name,
                "rev-unseeded",
            ))])
        } else {
            FakeAlgoliaSourceLister::with_inspect([])
        }
    }

    fn request(self, target_token: String) -> serde_json::Value {
        match self.provider {
            "algolia" => json!({
                "mode": "create",
                "appId": "UNSEEDEDAPP",
                "apiKey": "unseeded-algolia-key",
                "sourceName": self.source_name,
                "target": { "eligibilityToken": target_token }
            }),
            "typesense" => json!({
                "mode": "create",
                "node": "https://typesense-unseeded.invalid",
                "apiKey": "unseeded-typesense-key",
                "sourceIndex": self.source_name,
                "target": { "eligibilityToken": target_token }
            }),
            _ => unreachable!("closed provider cases"),
        }
    }

    fn expected_submit_body(self, customer_id: Uuid) -> String {
        let target_index = test_flapjack_uid(customer_id, "products");
        match self.provider {
            "algolia" => format!(
                r#"{{"appId":"UNSEEDEDAPP","apiKey":"unseeded-algolia-key","sourceIndex":"{}","targetIndex":"{target_index}","overwrite":false}}"#,
                self.source_name
            ),
            "typesense" => format!(
                r#"{{"node":"https://typesense-unseeded.invalid","apiKey":"unseeded-typesense-key","sourceIndex":"{}","targetIndex":"{target_index}","overwrite":false}}"#,
                self.source_name
            ),
            _ => unreachable!("closed provider cases"),
        }
    }
}

async fn assert_unseeded_shared_vm_create(case: UnseededSharedVmCreateCase) {
    let db = connect_and_migrate_required(case.schema_prefix).await;
    let harness = setup_algolia_cloud_job_create_harness_with_node_key(
        db.pool.clone(),
        case.source_service(),
        false,
    )
    .await;
    assert_eq!(harness.node_secret_manager.secret_count(), 0);
    let app = algolia_cloud_job_create_app(harness.state.clone());
    let target_token = target_create_eligibility_token(&app, &harness.jwt).await;
    harness
        .flapjack_http
        .expect_sensitive_json_body(&case.expected_submit_body(harness.customer_id));
    harness.flapjack_http.push_sensitive_json_response(
        202,
        json!({
            "jobId": Uuid::new_v4(),
            "phase": "submitted",
            "disposition": "running",
            "createdAt": "2026-08-04T00:00:00Z",
            "updatedAt": "2026-08-04T00:00:00Z"
        }),
    );

    let (status, headers, body) = post_create_job_for_provider(
        app,
        &harness.jwt,
        case.provider,
        &format!("unseeded-{}", case.provider),
        case.request(target_token),
    )
    .await;

    assert_eq!(
        status,
        StatusCode::ACCEPTED,
        "{} must not return the pre-fix 503 for an unseeded shared VM: {body}",
        case.provider
    );
    assert_eq!(body["sourceProvider"], case.provider);
    assert_eq!(body["source"]["name"], case.source_name);
    let location_prefix = format!("/migration/{}/jobs/", case.provider);
    assert!(headers[http::header::LOCATION]
        .to_str()
        .expect("Location must be text")
        .starts_with(&location_prefix));
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 1);
    assert_eq!(harness.flapjack_http.take_sensitive_requests().len(), 1);
    assert!(
        harness
            .node_secret_manager
            .get_secret(&harness.vm_secret_id)
            .is_some(),
        "reservation must create the selected VM's admin key"
    );
}

#[tokio::test]
async fn create_contract_primes_unseeded_shared_vm_key_before_create_admission() {
    let _env = FlapjackIdentityEnvGuard::compatible();
    let cases = [
        UnseededSharedVmCreateCase {
            provider: "algolia",
            schema_prefix: "create_contract_unseeded_algolia",
            source_name: "algolia_seed_source",
        },
        UnseededSharedVmCreateCase {
            provider: "typesense",
            schema_prefix: "create_contract_unseeded_typesense",
            source_name: "typesense_seed_source",
        },
    ];

    for case in cases {
        assert_unseeded_shared_vm_create(case).await;
    }
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
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, customer_id, flapjack) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;
    let engine_job_id = Uuid::parse_str("9f11d0a0-4443-44d4-b6c6-1ed71dbeb0fc").unwrap();
    flapjack.expect_sensitive_json_body(&format!(
        r#"{{"endpoint":"https://meili-create-canary.invalid","apiKey":"MEILI-KEY-CANARY","sourceIndex":"meili_source_canary","targetIndex":"{}","overwrite":false}}"#,
        test_flapjack_uid(customer_id, "products")
    ));
    flapjack.push_sensitive_json_response(
        202,
        json!({
            "jobId": engine_job_id,
            "phase": "submitted",
            "disposition": "running",
            "createdAt": "2026-07-22T00:00:00Z",
            "updatedAt": "2026-07-22T00:00:00Z"
        }),
    );

    let (status, headers, body) = post_create_job_for_provider(
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

    assert!(source_service.inspect_requests().is_empty());
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(body["sourceProvider"], json!("meilisearch"));
    assert_eq!(body["source"]["name"], json!("meili_source_canary"));
    assert_eq!(
        headers
            .get(http::header::LOCATION)
            .and_then(|value| value.to_str().ok())
            .map(|value| value.starts_with("/migration/meilisearch/jobs/")),
        Some(true)
    );
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 1);
    assert!(!body.to_string().contains("MEILI-KEY-CANARY"));
    assert!(!body
        .to_string()
        .contains("https://meili-create-canary.invalid"));
    let observed = flapjack.take_sensitive_requests();
    assert_eq!(
        observed[0].url,
        "https://vm-algolia-create.flapjack.test/1/migrations/meilisearch"
    );
}

#[tokio::test]
async fn create_contract_preserves_typesense_node_and_source_index() {
    let db = connect_and_migrate_required("create_contract_typesense").await;
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, customer_id, flapjack) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;
    let engine_job_id = Uuid::parse_str("9f11d0a0-4443-44d4-b6c6-1ed71dbeb0fd").unwrap();
    flapjack.expect_sensitive_json_body(&format!(
        r#"{{"node":"https://typesense-create-canary.invalid","apiKey":"TYPESENSE-KEY-CANARY","sourceIndex":"typesense_source_canary","targetIndex":"{}","overwrite":false}}"#,
        test_flapjack_uid(customer_id, "products")
    ));
    flapjack.push_sensitive_json_response(
        202,
        json!({
            "jobId": engine_job_id,
            "phase": "submitted",
            "disposition": "running",
            "createdAt": "2026-07-22T00:00:00Z",
            "updatedAt": "2026-07-22T00:00:00Z"
        }),
    );

    let (status, headers, body) = post_create_job_for_provider(
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

    assert!(source_service.inspect_requests().is_empty());
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(body["sourceProvider"], json!("typesense"));
    assert_eq!(body["source"]["name"], json!("typesense_source_canary"));
    assert_eq!(
        headers
            .get(http::header::LOCATION)
            .and_then(|value| value.to_str().ok())
            .map(|value| value.starts_with("/migration/typesense/jobs/")),
        Some(true)
    );
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 1);
    assert!(!body.to_string().contains("TYPESENSE-KEY-CANARY"));
    assert!(!body
        .to_string()
        .contains("https://typesense-create-canary.invalid"));
    let observed = flapjack.take_sensitive_requests();
    assert_eq!(
        observed[0].url,
        "https://vm-algolia-create.flapjack.test/1/migrations/typesense"
    );
}

struct HostedResumeCase {
    provider: &'static str,
    connection_field: &'static str,
    connection: &'static str,
    api_key: &'static str,
    source_name: &'static str,
}

async fn mark_import_job_resumable(pool: &sqlx::PgPool, job_id: Uuid) {
    let observed_at = Utc::now();
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status='failed', error_code='internal', dispatch_intent_state='committed',
             resume_checkpoint='resume-checkpoint', resume_status_observed_at=$2,
             resume_deadline=$3, resumable=TRUE, publication_disposition='unchanged',
             engine_ack_state='pending'
         WHERE id=$1",
    )
    .bind(job_id)
    .bind(observed_at)
    .bind(observed_at + chrono::Duration::minutes(5))
    .execute(pool)
    .await
    .unwrap();
}

async fn assert_hosted_resume_uses_provider_adapter(case: HostedResumeCase) {
    let db = connect_and_migrate_required(&format!("resume_contract_{}", case.provider)).await;
    let source_service = FakeAlgoliaSourceLister::with_inspect([]);
    let (app, jwt, customer_id, flapjack) =
        setup_algolia_cloud_job_create_app(db.pool.clone(), source_service.clone()).await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;
    flapjack.expect_sensitive_json_body(&format!(
        r#"{{"{}":"{}","apiKey":"{}","sourceIndex":"{}","targetIndex":"{}","overwrite":false}}"#,
        case.connection_field,
        case.connection,
        case.api_key,
        case.source_name,
        test_flapjack_uid(customer_id, "products")
    ));
    flapjack.push_sensitive_json_response(
        202,
        json!({
            "jobId": Uuid::new_v4(),
            "phase": "submitted",
            "disposition": "running",
            "createdAt": "2026-08-07T00:00:00Z",
            "updatedAt": "2026-08-07T00:00:00Z"
        }),
    );

    let (create_status, _headers, create_body) = post_create_job_for_provider(
        app.clone(),
        &jwt,
        case.provider,
        &format!("resume-contract-{}", case.provider),
        json!({
            "mode": "create",
            case.connection_field: case.connection,
            "apiKey": case.api_key,
            "sourceIndex": case.source_name,
            "target": { "eligibilityToken": target_token }
        }),
    )
    .await;
    assert_eq!(create_status, StatusCode::ACCEPTED, "{create_body}");
    let job_id = Uuid::parse_str(create_body["id"].as_str().unwrap()).unwrap();
    mark_import_job_resumable(&db.pool, job_id).await;

    flapjack.expect_sensitive_json_body(&format!(
        r#"{{"{}":"{}","apiKey":"{}"}}"#,
        case.connection_field, case.connection, case.api_key
    ));
    flapjack.push_sensitive_json_response(
        200,
        json!({
            "indexes": [{
                "name": case.source_name,
                "primaryKey": "id",
                "entries": 1,
                "documentCount": 1,
                "createdAt": null,
                "updatedAt": null,
                "defaultSortingField": null
            }],
            "limit": 100,
            "offset": 0,
            "total": 1
        }),
    );

    let (resume_status, resume_body) =
        post_resume_job_for_provider(app, &jwt, case.provider, job_id, case.api_key).await;
    assert_eq!(resume_status, StatusCode::ACCEPTED, "{resume_body}");
    assert_eq!(resume_body["status"], json!("resuming"));
    assert!(source_service.inspect_requests().is_empty());
    let observed = flapjack.take_sensitive_requests();
    assert_eq!(observed.len(), 2);
    assert_eq!(
        observed[1].url,
        format!(
            "https://vm-algolia-create.flapjack.test/1/migrations/{}/list-indexes?offset=0&limit=100",
            case.provider
        )
    );
}

#[tokio::test]
async fn hosted_resume_validates_source_through_the_matching_provider_adapter() {
    let _env = FlapjackIdentityEnvGuard::compatible();
    for case in [
        HostedResumeCase {
            provider: "meilisearch",
            connection_field: "endpoint",
            connection: "https://meili-resume-canary.invalid",
            api_key: "MEILI-RESUME-KEY-CANARY",
            source_name: "meili_resume_canary",
        },
        HostedResumeCase {
            provider: "typesense",
            connection_field: "node",
            connection: "https://typesense-resume-canary.invalid",
            api_key: "TYPESENSE-RESUME-KEY-CANARY",
            source_name: "typesense_resume_canary",
        },
    ] {
        assert_hosted_resume_uses_provider_adapter(case).await;
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

#[path = "create_contract_source_revision.rs"]
mod source_revision;
