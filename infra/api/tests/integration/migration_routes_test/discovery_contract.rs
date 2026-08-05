//! Provider-neutral source-discovery dispatch and refusal contracts.
use super::super::*;

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
