//! Provider-neutral source-discovery dispatch and refusal contracts.
use super::super::*;
use sha2::{Digest, Sha256};

fn hosted_discovery_response(provider: &str) -> serde_json::Value {
    let (name, primary_key, entries, document_count, created_at, updated_at, sorting_field) =
        match provider {
            "meilisearch" => (
                "meili_products",
                json!("sku"),
                serde_json::Value::Null,
                json!(42),
                json!("2026-08-03T12:00:00Z"),
                json!("2026-08-03T12:30:00Z"),
                serde_json::Value::Null,
            ),
            "typesense" => (
                "typesense_products",
                serde_json::Value::Null,
                serde_json::Value::Null,
                json!(42),
                json!(1785758400),
                serde_json::Value::Null,
                json!("price"),
            ),
            _ => panic!("unsupported hosted discovery provider {provider}"),
        };
    json!({
        "indexes": [{
            "name": name,
            "primaryKey": primary_key,
            "entries": entries,
            "documentCount": document_count,
            "createdAt": created_at,
            "updatedAt": updated_at,
            "defaultSortingField": sorting_field
        }],
        "limit": 2,
        "offset": 7,
        "total": 19
    })
}

async fn assert_hosted_discovery_dispatch(
    provider: &str,
    query: Option<&str>,
    request_body: serde_json::Value,
) {
    let source_service = FakeAlgoliaSourceLister::new([Ok(discovery_response(None))]);
    let (app, jwt, flapjack_http) =
        setup_source_discovery_app_with_flag(source_service.clone(), true, true).await;
    let expected_response = hosted_discovery_response(provider);
    flapjack_http.expect_sensitive_json_body(&request_body.to_string());
    flapjack_http.push_sensitive_json_response(200, expected_response.clone());

    let (status, body) = post_discovery(app, Some(&jwt), provider, query, request_body).await;

    assert_eq!(status, StatusCode::OK, "{provider} discovery body: {body}");
    assert_eq!(body, expected_response);
    assert!(source_service.requests().is_empty());
    let requests = flapjack_http.take_sensitive_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, http::Method::POST);
    assert_eq!(
        requests[0].url,
        match query {
            Some(query) => format!(
                "https://vm-source-discovery.flapjack.test/1/migrations/{provider}/list-indexes?{query}"
            ),
            None => format!(
                "https://vm-source-discovery.flapjack.test/1/migrations/{provider}/list-indexes"
            ),
        }
    );
}

#[tokio::test]
async fn meilisearch_discovery_dispatches_published_body_and_pagination_to_engine() {
    assert_hosted_discovery_dispatch(
        "meilisearch",
        Some("offset=7&limit=2"),
        json!({
            "endpoint": "https://meili-discovery-canary.invalid",
            "apiKey": "MEILI-DISCOVERY-KEY-CANARY"
        }),
    )
    .await;
}

#[tokio::test]
async fn typesense_discovery_dispatches_published_body_and_pagination_to_engine() {
    assert_hosted_discovery_dispatch(
        "typesense",
        Some("offset=7&limit=2"),
        json!({
            "node": "https://typesense-discovery-canary.invalid",
            "apiKey": "TYPESENSE-DISCOVERY-KEY-CANARY"
        }),
    )
    .await;
}

#[tokio::test]
async fn meilisearch_discovery_accepts_omitted_pagination_parameters() {
    assert_hosted_discovery_dispatch(
        "meilisearch",
        None,
        json!({
            "endpoint": "https://meili-no-pagination-canary.invalid",
            "apiKey": "MEILI-NO-PAGINATION-KEY-CANARY"
        }),
    )
    .await;
}

#[tokio::test]
async fn typesense_discovery_accepts_omitted_pagination_parameters() {
    assert_hosted_discovery_dispatch(
        "typesense",
        None,
        json!({
            "node": "https://typesense-no-pagination-canary.invalid",
            "apiKey": "TYPESENSE-NO-PAGINATION-KEY-CANARY"
        }),
    )
    .await;
}

#[tokio::test]
async fn typesense_discovery_attaches_content_revision_when_updated_at_is_null() {
    use wiremock::matchers::{header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    let _env = FlapjackIdentityEnvGuard::compatible_with_loopback_source_origins();
    let source = MockServer::start().await;
    let exported_documents = r#"{"id":"sku-1","title":"before"}"#;
    let expected_revision = format!(
        "sha256:{}",
        hex::encode(Sha256::digest(exported_documents.as_bytes()))
    );
    Mock::given(method("GET"))
        .and(path("/collections/typesense_products/documents/export"))
        .and(header(
            "x-typesense-api-key",
            "TYPESENSE-REVISION-KEY-CANARY",
        ))
        .respond_with(ResponseTemplate::new(200).set_body_string(exported_documents))
        .mount(&source)
        .await;
    let source_service = FakeAlgoliaSourceLister::new([Ok(discovery_response(None))]);
    let (app, jwt, flapjack_http) =
        setup_source_discovery_app_with_flag(source_service.clone(), true, true).await;
    let request_body = json!({
        "node": source.uri(),
        "apiKey": "TYPESENSE-REVISION-KEY-CANARY"
    });
    flapjack_http.expect_sensitive_json_body(&format!(
        r#"{{"apiKey":"TYPESENSE-REVISION-KEY-CANARY","node":"{}"}}"#,
        source.uri()
    ));
    flapjack_http.push_sensitive_json_response(
        200,
        json!({
            "indexes": [{
                "name": "typesense_products",
                "primaryKey": null,
                "entries": null,
                "documentCount": 42,
                "createdAt": 1785758400,
                "updatedAt": null,
                "defaultSortingField": "price"
            }],
            "limit": 2,
            "offset": 7,
            "total": 19
        }),
    );

    let (status, body) = post_discovery(app, Some(&jwt), "typesense", None, request_body).await;

    assert_eq!(status, StatusCode::OK, "typesense discovery body: {body}");
    assert_eq!(body["indexes"][0]["revision"], json!(expected_revision));
    assert_eq!(body["indexes"][0]["updatedAt"], serde_json::Value::Null);
    assert!(!body.to_string().contains("TYPESENSE-REVISION-KEY-CANARY"));
}

#[tokio::test]
async fn hosted_discovery_rejects_private_origins_before_engine_dispatch() {
    for (provider, request_body) in [
        (
            "meilisearch",
            json!({
                "endpoint": "https://169.254.169.254",
                "apiKey": "MEILI-PRIVATE-ORIGIN-KEY-CANARY"
            }),
        ),
        (
            "typesense",
            json!({
                "node": "https://10.0.0.1",
                "apiKey": "TYPESENSE-PRIVATE-ORIGIN-KEY-CANARY"
            }),
        ),
    ] {
        let (status, body, no_source_or_engine_call) =
            observe_discovery_request(provider, None, Some("application/json"), request_body).await;

        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(
            body,
            json!({
                "error": "invalid_source_host",
                "code": AlgoliaImportErrorCode::IncompatibleData.as_str(),
            })
        );
        assert!(no_source_or_engine_call);
    }
}

#[tokio::test]
async fn hosted_discovery_forwards_only_the_canonical_validated_origin() {
    let source_service = FakeAlgoliaSourceLister::new([Ok(discovery_response(None))]);
    let (app, jwt, flapjack_http) =
        setup_source_discovery_app_with_flag(source_service, true, true).await;
    flapjack_http.expect_sensitive_json_body(
        &json!({
            "endpoint": "https://meili-canonical-canary.invalid",
            "apiKey": "MEILI-CANONICAL-KEY-CANARY"
        })
        .to_string(),
    );
    flapjack_http.push_sensitive_json_response(200, hosted_discovery_response("meilisearch"));

    let (status, body) = post_discovery(
        app,
        Some(&jwt),
        "meilisearch",
        None,
        json!({
            "endpoint": "HTTPS://MEILI-CANONICAL-CANARY.INVALID:443/",
            "apiKey": "MEILI-CANONICAL-KEY-CANARY"
        }),
    )
    .await;

    assert_eq!(status, StatusCode::OK, "canonical discovery body: {body}");
    assert_eq!(flapjack_http.take_sensitive_requests().len(), 1);
}

struct MediaTypeCase {
    provider: &'static str,
    content_type: Option<&'static str>,
    body: serde_json::Value,
}

async fn observe_discovery_request(
    provider: &str,
    query: Option<&str>,
    content_type: Option<&str>,
    body: serde_json::Value,
) -> (StatusCode, serde_json::Value, bool) {
    let source_service = FakeAlgoliaSourceLister::new([Ok(discovery_response(None))]);
    let (app, jwt, flapjack_http) =
        setup_source_discovery_app_with_flag(source_service.clone(), true, true).await;
    let query = query.map(|value| format!("?{value}")).unwrap_or_default();
    let mut request = Request::builder()
        .method(http::Method::POST)
        .uri(format!("/migration/{provider}/list-indexes{query}"))
        .header("authorization", format!("Bearer {jwt}"));
    if let Some(content_type) = content_type {
        request = request.header("content-type", content_type);
    }
    let response = app
        .oneshot(request.body(Body::from(body.to_string())).unwrap())
        .await
        .unwrap();
    let (status, body) = response_json(response).await;
    let no_source_or_engine_call = source_service.requests().is_empty()
        && flapjack_http.request_count() == 0
        && flapjack_http.take_sensitive_requests().is_empty();
    (status, body, no_source_or_engine_call)
}

#[tokio::test]
async fn discovery_rejects_missing_and_non_json_content_type_with_coded_415() {
    let cases = [
        MediaTypeCase {
            provider: "algolia",
            content_type: None,
            body: json!({
                "appId": "ALGOLIA-MISSING-CONTENT-TYPE-APP-CANARY",
                "apiKey": "ALGOLIA-MISSING-CONTENT-TYPE-KEY-CANARY"
            }),
        },
        MediaTypeCase {
            provider: "algolia",
            content_type: Some("text/plain"),
            body: json!({
                "appId": "ALGOLIA-TEXT-CONTENT-TYPE-APP-CANARY",
                "apiKey": "ALGOLIA-TEXT-CONTENT-TYPE-KEY-CANARY"
            }),
        },
        MediaTypeCase {
            provider: "meilisearch",
            content_type: None,
            body: json!({
                "endpoint": "https://meili-missing-content-type-canary.invalid",
                "apiKey": "MEILI-MISSING-CONTENT-TYPE-KEY-CANARY"
            }),
        },
        MediaTypeCase {
            provider: "typesense",
            content_type: Some("text/plain"),
            body: json!({
                "node": "https://typesense-text-content-type-canary.invalid",
                "apiKey": "TYPESENSE-TEXT-CONTENT-TYPE-KEY-CANARY"
            }),
        },
    ];

    for case in cases {
        let (status, body, no_source_or_engine_call) =
            observe_discovery_request(case.provider, None, case.content_type, case.body).await;
        assert_eq!(status, StatusCode::UNSUPPORTED_MEDIA_TYPE);
        assert_eq!(
            body,
            json!({
                "error": "content_type_must_be_application_json",
                "code": AlgoliaImportErrorCode::IncompatibleData.as_str(),
            })
        );
        assert!(no_source_or_engine_call);
    }
}

#[tokio::test]
async fn discovery_rejects_invalid_pagination_without_leaking_query_values() {
    let cases = [
        ("meilisearch", "offset=notanumber", "offset"),
        ("typesense", "limit=-1", "limit"),
    ];

    for (provider, query, parameter) in cases {
        let request_body = match provider {
            "meilisearch" => {
                json!({"endpoint": "https://meili-query-canary.invalid", "apiKey": "MEILI-QUERY-KEY-CANARY"})
            }
            "typesense" => {
                json!({"node": "https://typesense-query-canary.invalid", "apiKey": "TYPESENSE-QUERY-KEY-CANARY"})
            }
            _ => unreachable!("closed hosted provider test matrix"),
        };
        let (status, body, no_source_or_engine_call) = observe_discovery_request(
            provider,
            Some(query),
            Some("application/json"),
            request_body,
        )
        .await;

        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(
            body,
            json!({
                "error": format!("invalid source discovery query parameter `{parameter}`"),
                "code": AlgoliaImportErrorCode::IncompatibleData.as_str(),
            })
        );
        assert!(!body.to_string().contains(query.split_once('=').unwrap().1));
        assert!(no_source_or_engine_call);
    }
}

#[tokio::test]
async fn discovery_labels_valid_json_non_object_bodies_as_incompatible() {
    for provider in ["algolia", "meilisearch", "typesense"] {
        let (status, body, no_source_or_engine_call) = observe_discovery_request(
            provider,
            None,
            Some("application/json"),
            json!("NON-OBJECT-BODY-CANARY"),
        )
        .await;

        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(
            body,
            json!({
                "error": format!("invalid {provider} discovery request: request body is incompatible"),
                "code": AlgoliaImportErrorCode::IncompatibleData.as_str(),
            })
        );
        assert!(!body.to_string().contains("NON-OBJECT-BODY-CANARY"));
        assert!(no_source_or_engine_call);
    }
}

struct RefusalCase {
    provider: &'static str,
    offending_field: &'static str,
    body: serde_json::Value,
}

fn refusal_case(
    provider: &'static str,
    offending_field: &'static str,
    body: serde_json::Value,
) -> RefusalCase {
    RefusalCase {
        provider,
        offending_field,
        body,
    }
}

fn refusal_observation(
    case: &RefusalCase,
    status: StatusCode,
    body: &serde_json::Value,
    no_source_or_engine_call: bool,
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
    let serialized_response = body.to_string();
    let request_values_redacted = case
        .body
        .as_object()
        .expect("refusal case body must be an object")
        .values()
        .filter_map(serde_json::Value::as_str)
        .all(|value| !serialized_response.contains(value));
    json!({
        "status": status.as_u16(),
        "statusIsNotAxum422": status != StatusCode::UNPROCESSABLE_ENTITY,
        "code": body.get("code").cloned().unwrap_or(serde_json::Value::Null),
        "bodyFields": body_fields,
        "errorNamesProvider": error.contains(case.provider),
        "errorNamesOffendingField": error.contains(case.offending_field),
        "canaryValuesRedacted": request_values_redacted,
        "noSourceOrEngineCall": no_source_or_engine_call,
    })
}

fn ambiguous_refusal_cases() -> Vec<RefusalCase> {
    let ambiguous = json!({
        "appId": "AMBIGUOUS-APP-CANARY",
        "endpoint": "https://ambiguous-meili-canary.invalid",
        "node": "https://ambiguous-typesense-canary.invalid",
        "apiKey": "AMBIGUOUS-KEY-CANARY"
    });
    vec![
        refusal_case("algolia", "endpoint", ambiguous.clone()),
        refusal_case("meilisearch", "appId", ambiguous.clone()),
        refusal_case("typesense", "appId", ambiguous),
    ]
}

fn pairwise_discriminator_refusal_cases() -> Vec<RefusalCase> {
    let algolia_meilisearch = json!({
        "appId": "PAIR-ALGOLIA-MEILI-APP-CANARY",
        "endpoint": "https://pair-algolia-meili-endpoint-canary.invalid",
        "apiKey": "PAIR-ALGOLIA-MEILI-KEY-CANARY"
    });
    let algolia_typesense = json!({
        "appId": "PAIR-ALGOLIA-TYPESENSE-APP-CANARY",
        "node": "https://pair-algolia-typesense-node-canary.invalid",
        "apiKey": "PAIR-ALGOLIA-TYPESENSE-KEY-CANARY"
    });
    let meilisearch_typesense = json!({
        "endpoint": "https://pair-meili-typesense-endpoint-canary.invalid",
        "node": "https://pair-meili-typesense-node-canary.invalid",
        "apiKey": "PAIR-MEILI-TYPESENSE-KEY-CANARY"
    });
    vec![
        refusal_case("algolia", "endpoint", algolia_meilisearch.clone()),
        refusal_case("meilisearch", "appId", algolia_meilisearch.clone()),
        refusal_case("typesense", "appId", algolia_meilisearch),
        refusal_case("algolia", "node", algolia_typesense.clone()),
        refusal_case("meilisearch", "appId", algolia_typesense.clone()),
        refusal_case("typesense", "appId", algolia_typesense),
        refusal_case("algolia", "endpoint", meilisearch_typesense.clone()),
        refusal_case("meilisearch", "node", meilisearch_typesense.clone()),
        refusal_case("typesense", "endpoint", meilisearch_typesense),
    ]
}

fn provider_body_mismatch_refusal_cases() -> Vec<RefusalCase> {
    vec![
        refusal_case(
            "algolia",
            "endpoint",
            json!({"endpoint": "https://mismatch-meili-algolia-canary.invalid", "apiKey": "MISMATCH-MEILI-ALGOLIA-KEY-CANARY"}),
        ),
        refusal_case(
            "meilisearch",
            "appId",
            json!({"appId": "MISMATCH-APP-CANARY", "apiKey": "MISMATCH-ALGOLIA-KEY-CANARY"}),
        ),
        refusal_case(
            "typesense",
            "appId",
            json!({"appId": "MISMATCH-ALGOLIA-TYPESENSE-APP-CANARY", "apiKey": "MISMATCH-ALGOLIA-TYPESENSE-KEY-CANARY"}),
        ),
        refusal_case(
            "typesense",
            "endpoint",
            json!({"endpoint": "https://mismatch-meili-canary.invalid", "apiKey": "MISMATCH-MEILI-KEY-CANARY"}),
        ),
        refusal_case(
            "meilisearch",
            "node",
            json!({"node": "https://mismatch-typesense-meili-canary.invalid", "apiKey": "MISMATCH-TYPESENSE-MEILI-KEY-CANARY"}),
        ),
        refusal_case(
            "algolia",
            "node",
            json!({"node": "https://mismatch-typesense-canary.invalid", "apiKey": "MISMATCH-TYPESENSE-KEY-CANARY"}),
        ),
    ]
}

fn console_host_refusal_cases() -> Vec<RefusalCase> {
    vec![
        refusal_case(
            "meilisearch",
            "host",
            json!({"host": "MEILI-CONSOLE-HOST-CANARY", "apiKey": "MEILI-CONSOLE-KEY-CANARY"}),
        ),
        refusal_case(
            "typesense",
            "host",
            json!({"host": "TYPESENSE-CONSOLE-HOST-CANARY", "apiKey": "TYPESENSE-CONSOLE-KEY-CANARY"}),
        ),
    ]
}

async fn observe_refusal_case(case: &RefusalCase) -> serde_json::Value {
    let (status, body, no_source_or_engine_call) = observe_discovery_request(
        case.provider,
        None,
        Some("application/json"),
        case.body.clone(),
    )
    .await;
    refusal_observation(case, status, &body, no_source_or_engine_call)
}

fn expected_refusal_observation() -> serde_json::Value {
    json!({
        "status": StatusCode::BAD_REQUEST.as_u16(),
        "statusIsNotAxum422": true,
        "code": AlgoliaImportErrorCode::IncompatibleData.as_str(),
        "bodyFields": ["code", "error"],
        "errorNamesProvider": true,
        "errorNamesOffendingField": true,
        "canaryValuesRedacted": true,
        "noSourceOrEngineCall": true,
    })
}

#[tokio::test]
async fn discovery_labels_ambiguous_mismatched_and_console_host_bodies_inside_handler() {
    let cases = ambiguous_refusal_cases()
        .into_iter()
        .chain(pairwise_discriminator_refusal_cases())
        .chain(provider_body_mismatch_refusal_cases())
        .chain(console_host_refusal_cases())
        .collect::<Vec<_>>();
    let mut observed = Vec::with_capacity(cases.len());
    for case in &cases {
        observed.push(observe_refusal_case(case).await);
    }
    assert_eq!(observed, vec![expected_refusal_observation(); cases.len()]);
}

async fn observe_hosted_discovery_engine_failure(
    engine_status: u16,
    engine_body: serde_json::Value,
) -> (StatusCode, serde_json::Value) {
    let source_service = FakeAlgoliaSourceLister::new([Ok(discovery_response(None))]);
    let (app, jwt, flapjack_http) =
        setup_source_discovery_app_with_flag(source_service.clone(), true, true).await;
    let request_body = json!({
        "endpoint": "https://meili-engine-failure-canary.invalid",
        "apiKey": "MEILI-ENGINE-FAILURE-KEY-CANARY"
    });
    flapjack_http.expect_sensitive_json_body(&request_body.to_string());
    flapjack_http.push_sensitive_json_response(engine_status, engine_body);

    let (status, body) = post_discovery(app, Some(&jwt), "meilisearch", None, request_body).await;

    assert!(source_service.requests().is_empty());
    assert!(!body.to_string().contains("MEILI-ENGINE-FAILURE-KEY-CANARY"));
    (status, body)
}

#[tokio::test]
async fn hosted_discovery_redacts_credential_reflected_by_engine_rejection() {
    let (status, body) = observe_hosted_discovery_engine_failure(
        400,
        json!({"error": "rejected API key MEILI-ENGINE-FAILURE-KEY-CANARY"}),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body,
        json!({
            "error": "migration_source_discovery_rejected",
            "code": AlgoliaImportErrorCode::IncompatibleData.as_str(),
        })
    );
}

#[tokio::test]
async fn hosted_discovery_maps_engine_internal_failure_to_discovery_coded_500() {
    let (status, body) = observe_hosted_discovery_engine_failure(
        500,
        json!({"error": "ENGINE-INTERNAL-DIAGNOSTIC-CANARY"}),
    )
    .await;

    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(
        body,
        json!({
            "error": "migration_source_discovery_failed",
            "code": AlgoliaImportErrorCode::Internal.as_str(),
        })
    );
    assert!(!body
        .to_string()
        .contains("ENGINE-INTERNAL-DIAGNOSTIC-CANARY"));
}

#[tokio::test]
async fn hosted_discovery_rejects_engine_success_outside_the_published_schema() {
    let invalid_responses = [
        json!({"ENGINE-MISSING-INDEXES-CANARY": true}),
        json!({
            "indexes": [],
            "apiKey": "ENGINE-REFLECTED-TOP-LEVEL-KEY-CANARY"
        }),
        json!({"indexes": [{"name": "ENGINE-MISSING-SUMMARY-FIELDS-CANARY"}]}),
        json!({
            "indexes": [{
                "name": "products",
                "primaryKey": null,
                "entries": null,
                "documentCount": null,
                "createdAt": null,
                "updatedAt": null,
                "defaultSortingField": null,
                "apiKey": "ENGINE-REFLECTED-INDEX-KEY-CANARY"
            }]
        }),
        json!({
            "indexes": [{
                "name": "ENGINE-NEGATIVE-COUNT-CANARY",
                "primaryKey": null,
                "entries": -1,
                "documentCount": null,
                "createdAt": null,
                "updatedAt": null,
                "defaultSortingField": null
            }]
        }),
    ];

    for invalid_response in invalid_responses {
        let (status, body) = observe_hosted_discovery_engine_failure(200, invalid_response).await;

        assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(
            body,
            json!({
                "error": "migration_source_discovery_failed",
                "code": AlgoliaImportErrorCode::Internal.as_str(),
            })
        );
        assert!(!body.to_string().contains("ENGINE-"));
    }
}

#[tokio::test]
async fn hosted_discovery_rejects_non_utf8_body_before_engine_dispatch() {
    let source_service = FakeAlgoliaSourceLister::new([Ok(discovery_response(None))]);
    let (app, jwt, flapjack_http) =
        setup_source_discovery_app_with_flag(source_service.clone(), true, true).await;

    let response = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/meilisearch/list-indexes")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(vec![
                    b'{', b'"', b'e', b'"', b':', b'"', 0xff, b'"', b'}',
                ]))
                .unwrap(),
        )
        .await
        .unwrap();
    let (status, body) = response_json(response).await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body,
        json!({
            "error": "invalid source discovery request: request body must be valid UTF-8",
            "code": AlgoliaImportErrorCode::IncompatibleData.as_str(),
        })
    );
    assert_eq!(flapjack_http.request_count(), 0);
    assert!(flapjack_http.take_sensitive_requests().is_empty());
    assert!(source_service.requests().is_empty());
}

/// Regression: the retained migration proxy must create the shared VM's node
/// admin key on demand. In local/dev the in-memory secret store holds no key
/// until one is created, and the proxy's own `get_admin_key` does not
/// create-on-missing, so an unprimed freshly auto-provisioned shared VM used to
/// fail every browser-driven discovery with a secret-store error
/// ("no key found for node ..."). `backend_target` now primes the key via
/// `get_or_create_node_api_key` before proxying. This test wires one shared
/// secret manager to both the provisioning service and the proxy (mirroring the
/// production Arc sharing) and intentionally leaves it unseeded.
#[tokio::test]
async fn hosted_discovery_primes_missing_shared_vm_admin_key() {
    let source_service = FakeAlgoliaSourceLister::new([Ok(discovery_response(None))]);
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);

    let vm_inventory_repo = crate::common::mock_vm_inventory_repo();
    let vm = vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-source-discovery.flapjack.test".to_string(),
            flapjack_url: "https://vm-source-discovery.flapjack.test".to_string(),
            capacity: json!({ "disk_bytes": 10_000_000_000_i64 }),
        })
        .await
        .expect("seed mock source-discovery VM");

    // One shared secret manager for both provisioning and proxy, mirroring the
    // production wiring where they clone the same Arc. Intentionally NOT seeded:
    // the fix under test must create the admin key on demand.
    let node_secret_manager = Arc::new(MockNodeSecretManager::new());
    assert!(
        node_secret_manager
            .get_secret(vm.node_secret_id())
            .is_none(),
        "precondition: shared VM admin key must be unprimed"
    );
    let flapjack_http = Arc::new(MockFlapjackHttpClient::default());
    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        flapjack_http.clone(),
        node_secret_manager.clone(),
    ));

    let request_body = json!({
        "endpoint": "https://meili-unprimed-canary.invalid",
        "apiKey": "MEILI-UNPRIMED-KEY-CANARY"
    });
    let expected_response = hosted_discovery_response("meilisearch");
    flapjack_http.expect_sensitive_json_body(&request_body.to_string());
    flapjack_http.push_sensitive_json_response(200, expected_response.clone());

    let state = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_algolia_source_service(source_service.clone())
        .with_algolia_migration_enabled(true)
        .with_node_secret_manager(node_secret_manager.clone())
        .with_vm_inventory_repo(vm_inventory_repo)
        .with_flapjack_proxy(flapjack_proxy)
        .build();
    let app = axum::Router::new()
        .route(
            "/migration/:source_provider/list-indexes",
            post(api::routes::migration::list_source_indexes),
        )
        .with_state(state);

    let (status, body) = post_discovery(app, Some(&jwt), "meilisearch", None, request_body).await;

    assert_eq!(status, StatusCode::OK, "discovery body: {body}");
    assert_eq!(body, expected_response);
    // The proxy actually dispatched to the engine; this would be zero if the
    // secret lookup had failed before dispatch (the pre-fix behavior).
    let requests = flapjack_http.take_sensitive_requests();
    assert_eq!(requests.len(), 1);
    // The admin key was created on demand and now exists in the shared store.
    assert!(
        node_secret_manager
            .get_secret(vm.node_secret_id())
            .is_some(),
        "backend_target must create the shared VM admin key on demand"
    );
    assert!(source_service.requests().is_empty());
}
