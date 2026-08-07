use super::*;

/// Hosted-source drift specimen. `sourceRevision` carries the record count the
/// picker showed for the chosen index; create re-reads the same engine
/// discovery surface and must refuse a source that moved underneath the
/// customer's choice, before any destination placement is reserved and before
/// any retained job exists.
#[derive(Clone, Copy)]
struct HostedSourceRevisionCase {
    provider: &'static str,
    schema_prefix: &'static str,
    source_name: &'static str,
    connection_id: &'static str,
    api_key: &'static str,
    /// What the picker pinned at discovery.
    pinned_document_count: i64,
    pinned_updated_at: Option<&'static str>,
    pinned_revision: Option<&'static str>,
    /// What the fresh create-time re-read reports, or `None` when the re-read
    /// can no longer find the index at all.
    observed_document_count: Option<i64>,
    observed_updated_at: Option<&'static str>,
    observed_revision: Option<&'static str>,
}

impl HostedSourceRevisionCase {
    fn credential_field(self) -> &'static str {
        match self.provider {
            "meilisearch" => "endpoint",
            "typesense" => "node",
            _ => unreachable!("the source-revision guard is hosted-provider only"),
        }
    }

    fn create_body(self, target_token: String) -> serde_json::Value {
        let mut source_revision = json!({
            "documentCount": self.pinned_document_count,
            "updatedAt": self.pinned_updated_at
        });
        if let Some(revision) = self.pinned_revision {
            source_revision["revision"] = json!(revision);
        }
        json!({
            "mode": "create",
            self.credential_field(): self.connection_id,
            "apiKey": self.api_key,
            "sourceIndex": self.source_name,
            "sourceRevision": source_revision,
            "target": { "eligibilityToken": target_token }
        })
    }

    /// Engine discovery re-read body: the same credential envelope the picker
    /// used, so the re-read observes exactly the source the customer chose.
    fn expected_discovery_body(self) -> String {
        format!(
            r#"{{"{}":"{}","apiKey":"{}"}}"#,
            self.credential_field(),
            self.connection_id,
            self.api_key
        )
    }

    fn discovery_response(self) -> serde_json::Value {
        let indexes = match self.observed_document_count {
            Some(count) => {
                let mut index = json!({
                "name": self.source_name,
                "primaryKey": "id",
                "entries": count,
                "documentCount": count,
                "createdAt": null,
                "updatedAt": self.observed_updated_at,
                "defaultSortingField": null
                });
                if let Some(revision) = self.observed_revision {
                    index["revision"] = json!(revision);
                }
                json!([index])
            }
            None => json!([]),
        };
        json!({ "indexes": indexes, "limit": 100, "offset": 0, "total": 1 })
    }
}

#[tokio::test]
async fn create_contract_refuses_hosted_source_that_changed_since_discovery() {
    let _env = FlapjackIdentityEnvGuard::compatible();
    let cases = [
        // Meilisearch parity run 3: the seeded bundle's three configured_pk rows
        // gain the bundle mutation row after the picker pinned three.
        HostedSourceRevisionCase {
            provider: "meilisearch",
            schema_prefix: "create_contract_revision_meilisearch",
            source_name: "configured_pk",
            connection_id: "https://meili-revision-canary.invalid",
            api_key: "MEILI-REVISION-KEY-CANARY",
            pinned_document_count: 3,
            pinned_updated_at: Some("2026-08-05T00:00:00Z"),
            pinned_revision: None,
            observed_document_count: Some(4),
            observed_updated_at: Some("2026-08-05T00:00:01Z"),
            observed_revision: None,
        },
        HostedSourceRevisionCase {
            provider: "typesense",
            schema_prefix: "create_contract_revision_typesense",
            source_name: "fj_ts_migration_products",
            connection_id: "https://typesense-revision-canary.invalid",
            api_key: "TYPESENSE-REVISION-KEY-CANARY",
            pinned_document_count: 3,
            pinned_updated_at: Some("2026-08-05T00:00:00Z"),
            pinned_revision: None,
            observed_document_count: Some(4),
            observed_updated_at: Some("2026-08-05T00:00:01Z"),
            observed_revision: None,
        },
        HostedSourceRevisionCase {
            provider: "typesense",
            schema_prefix: "create_contract_revision_typesense_same_count",
            source_name: "fj_ts_migration_products",
            connection_id: "https://typesense-revision-canary.invalid",
            api_key: "TYPESENSE-REVISION-KEY-CANARY",
            pinned_document_count: 3,
            pinned_updated_at: Some("2026-08-05T00:00:00Z"),
            pinned_revision: None,
            observed_document_count: Some(3),
            observed_updated_at: Some("2026-08-05T00:00:01Z"),
            observed_revision: None,
        },
        HostedSourceRevisionCase {
            provider: "typesense",
            schema_prefix: "create_contract_revision_typesense_same_count_null_timestamp",
            source_name: "fj_ts_migration_products",
            connection_id: "https://typesense-revision-canary.invalid",
            api_key: "TYPESENSE-REVISION-KEY-CANARY",
            pinned_document_count: 3,
            pinned_updated_at: None,
            pinned_revision: Some("sha256:before-content"),
            observed_document_count: Some(3),
            observed_updated_at: None,
            observed_revision: Some("sha256:after-content"),
        },
        // A source that vanished between choice and submit is not "unchanged":
        // an indeterminate re-read must never read as proof the source held still.
        HostedSourceRevisionCase {
            provider: "meilisearch",
            schema_prefix: "create_contract_revision_vanished",
            source_name: "configured_pk",
            connection_id: "https://meili-revision-canary.invalid",
            api_key: "MEILI-REVISION-KEY-CANARY",
            pinned_document_count: 3,
            pinned_updated_at: Some("2026-08-05T00:00:00Z"),
            pinned_revision: None,
            observed_document_count: None,
            observed_updated_at: None,
            observed_revision: None,
        },
    ];

    for case in cases {
        let db = connect_and_migrate_required(case.schema_prefix).await;
        let (app, jwt, _customer_id, flapjack) = setup_algolia_cloud_job_create_app(
            db.pool.clone(),
            FakeAlgoliaSourceLister::with_inspect([]),
        )
        .await;
        let target_token = target_create_eligibility_token(&app, &jwt).await;
        flapjack.expect_sensitive_json_body(&case.expected_discovery_body());
        flapjack.push_sensitive_json_response(200, case.discovery_response());

        let (status, _headers, body) = post_create_job_for_provider(
            app,
            &jwt,
            case.provider,
            &format!("revision-drift-{}", case.schema_prefix),
            case.create_body(target_token),
        )
        .await;

        assert_eq!(
            status,
            StatusCode::BAD_REQUEST,
            "{} must refuse a changed source: {body}",
            case.schema_prefix
        );
        assert_eq!(
            body["code"],
            json!(AlgoliaImportErrorCode::SourceChanged.as_str()),
            "{} must refuse with the source_changed contract code: {body}",
            case.schema_prefix
        );
        assert_eq!(
            count_algolia_import_jobs(&db.pool).await,
            0,
            "{} must not retain a job for a source it refused",
            case.schema_prefix
        );
        let observed = flapjack.take_sensitive_requests();
        assert_eq!(
            observed.len(),
            1,
            "{} must re-read discovery and stop before submit: {observed:?}",
            case.schema_prefix
        );
        assert!(
            observed[0].url.ends_with(&format!(
                "/1/migrations/{}/list-indexes?offset=0&limit=100",
                case.provider
            )),
            "{} re-read must use the engine discovery route: {}",
            case.schema_prefix,
            observed[0].url
        );
        assert!(
            !body.to_string().contains(case.api_key),
            "{} refusal must not echo the source credential: {body}",
            case.schema_prefix
        );
    }
}

#[tokio::test]
async fn create_contract_submits_hosted_job_when_source_revision_still_matches() {
    let _env = FlapjackIdentityEnvGuard::compatible();
    let case = HostedSourceRevisionCase {
        provider: "meilisearch",
        schema_prefix: "create_contract_revision_match",
        source_name: "configured_pk",
        connection_id: "https://meili-revision-canary.invalid",
        api_key: "MEILI-REVISION-KEY-CANARY",
        pinned_document_count: 3,
        pinned_updated_at: Some("2026-08-05T00:00:00Z"),
        pinned_revision: None,
        observed_document_count: Some(3),
        observed_updated_at: Some("2026-08-05T00:00:00Z"),
        observed_revision: None,
    };
    let db = connect_and_migrate_required(case.schema_prefix).await;
    let (app, jwt, customer_id, flapjack) = setup_algolia_cloud_job_create_app(
        db.pool.clone(),
        FakeAlgoliaSourceLister::with_inspect([]),
    )
    .await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;
    flapjack.expect_sensitive_json_body(&case.expected_discovery_body());
    flapjack.push_sensitive_json_response(200, case.discovery_response());
    flapjack.expect_sensitive_json_body(&format!(
        r#"{{"endpoint":"{}","apiKey":"{}","sourceIndex":"{}","targetIndex":"{}","overwrite":false}}"#,
        case.connection_id,
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
            "createdAt": "2026-08-05T00:00:00Z",
            "updatedAt": "2026-08-05T00:00:00Z"
        }),
    );

    let (status, _headers, body) = post_create_job_for_provider(
        app,
        &jwt,
        case.provider,
        "revision-match-meilisearch",
        case.create_body(target_token),
    )
    .await;

    assert_eq!(
        status,
        StatusCode::ACCEPTED,
        "an unchanged source must still submit: {body}"
    );
    assert_eq!(body["error"], serde_json::Value::Null, "{body}");
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 1);
    assert_eq!(
        flapjack.take_sensitive_requests().len(),
        2,
        "an unchanged source must re-read discovery and then submit"
    );
}

#[tokio::test]
async fn create_contract_refuses_typesense_same_count_content_drift_with_null_updated_at() {
    use sha2::{Digest, Sha256};
    use wiremock::matchers::{header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    let _env = FlapjackIdentityEnvGuard::compatible_with_loopback_source_origins();
    let db = connect_and_migrate_required("create_contract_revision_typesense_content").await;
    let (app, jwt, _customer_id, flapjack) = setup_algolia_cloud_job_create_app(
        db.pool.clone(),
        FakeAlgoliaSourceLister::with_inspect([]),
    )
    .await;
    let source = MockServer::start().await;
    let before = br#"{"id":"sku-1","title":"before"}"#;
    let after = r#"{"id":"sku-1","title":"after"}"#;
    let pinned_revision = format!("sha256:{}", hex::encode(Sha256::digest(before)));
    let expected_observed_revision = format!("sha256:{}", hex::encode(Sha256::digest(after)));
    Mock::given(method("GET"))
        .and(path(
            "/collections/fj_ts_migration_products/documents/export",
        ))
        .and(header(
            "x-typesense-api-key",
            "TYPESENSE-REVISION-KEY-CANARY",
        ))
        .respond_with(ResponseTemplate::new(200).set_body_string(after))
        .mount(&source)
        .await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;
    flapjack.expect_sensitive_json_body(&format!(
        r#"{{"node":"{}","apiKey":"TYPESENSE-REVISION-KEY-CANARY"}}"#,
        source.uri()
    ));
    flapjack.push_sensitive_json_response(
        200,
        json!({
            "indexes": [{
                "name": "fj_ts_migration_products",
                "primaryKey": "id",
                "entries": 3,
                "documentCount": 3,
                "createdAt": null,
                "updatedAt": null,
                "defaultSortingField": null
            }],
            "limit": 100,
            "offset": 0,
            "total": 1
        }),
    );

    let (status, _headers, body) = post_create_job_for_provider(
        app,
        &jwt,
        "typesense",
        "revision-drift-typesense-content",
        json!({
            "mode": "create",
            "node": source.uri(),
            "apiKey": "TYPESENSE-REVISION-KEY-CANARY",
            "sourceIndex": "fj_ts_migration_products",
            "sourceRevision": {
                "documentCount": 3,
                "revision": pinned_revision
            },
            "target": { "eligibilityToken": target_token }
        }),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert_eq!(
        body["code"],
        json!(AlgoliaImportErrorCode::SourceChanged.as_str()),
        "same-count Typesense content drift must be refused: {body}"
    );
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 0);
    assert_eq!(flapjack.take_sensitive_requests().len(), 1);
    assert_ne!(
        pinned_revision, expected_observed_revision,
        "the control must compare different content hashes"
    );
    assert!(!body.to_string().contains("TYPESENSE-REVISION-KEY-CANARY"));
}

/// A create that pins nothing must not pay for a discovery re-read, and must not
/// be refused for a baseline the picker never established.
#[tokio::test]
async fn create_contract_skips_the_source_revision_guard_when_nothing_was_pinned() {
    let _env = FlapjackIdentityEnvGuard::compatible();
    let db = connect_and_migrate_required("create_contract_revision_unpinned").await;
    let (app, jwt, customer_id, flapjack) = setup_algolia_cloud_job_create_app(
        db.pool.clone(),
        FakeAlgoliaSourceLister::with_inspect([]),
    )
    .await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;
    flapjack.expect_sensitive_json_body(&format!(
        r#"{{"endpoint":"https://meili-unpinned-canary.invalid","apiKey":"MEILI-UNPINNED-KEY-CANARY","sourceIndex":"configured_pk","targetIndex":"{}","overwrite":false}}"#,
        test_flapjack_uid(customer_id, "products")
    ));
    flapjack.push_sensitive_json_response(
        202,
        json!({
            "jobId": Uuid::new_v4(),
            "phase": "submitted",
            "disposition": "running",
            "createdAt": "2026-08-05T00:00:00Z",
            "updatedAt": "2026-08-05T00:00:00Z"
        }),
    );

    let (status, _headers, body) = post_create_job_for_provider(
        app,
        &jwt,
        "meilisearch",
        "revision-unpinned-meilisearch",
        json!({
            "mode": "create",
            "endpoint": "https://meili-unpinned-canary.invalid",
            "apiKey": "MEILI-UNPINNED-KEY-CANARY",
            "sourceIndex": "configured_pk",
            "target": { "eligibilityToken": target_token }
        }),
    )
    .await;

    assert_eq!(status, StatusCode::ACCEPTED, "{body}");
    assert_eq!(
        flapjack.take_sensitive_requests().len(),
        1,
        "an unpinned create must submit without a discovery re-read"
    );
}

/// The revision guard has to be able to fail on the specimen the released
/// engine actually produces: Typesense discovery reports `updatedAt: null`, so
/// when the export read cannot be completed there is no timestamp left to
/// distinguish "unchanged" from "unknown". An indeterminate re-read must be
/// refused, not admitted on a pair of nulls.
#[tokio::test]
async fn create_contract_refuses_typesense_when_the_export_revision_is_indeterminate() {
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    let _env = FlapjackIdentityEnvGuard::compatible_with_loopback_source_origins();
    let db = connect_and_migrate_required("create_contract_revision_typesense_indeterminate").await;
    let (app, jwt, _customer_id, flapjack) = setup_algolia_cloud_job_create_app(
        db.pool.clone(),
        FakeAlgoliaSourceLister::with_inspect([]),
    )
    .await;
    let source = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path(
            "/collections/fj_ts_migration_products/documents/export",
        ))
        .respond_with(ResponseTemplate::new(503))
        .mount(&source)
        .await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;
    flapjack.expect_sensitive_json_body(&format!(
        r#"{{"node":"{}","apiKey":"TYPESENSE-REVISION-KEY-CANARY"}}"#,
        source.uri()
    ));
    flapjack.push_sensitive_json_response(
        200,
        json!({
            "indexes": [{
                "name": "fj_ts_migration_products",
                "primaryKey": "id",
                "entries": 3,
                "documentCount": 3,
                "createdAt": null,
                "updatedAt": null,
                "defaultSortingField": null
            }],
            "limit": 100,
            "offset": 0,
            "total": 1
        }),
    );

    let (status, _headers, body) = post_create_job_for_provider(
        app,
        &jwt,
        "typesense",
        "revision-indeterminate-typesense",
        json!({
            "mode": "create",
            "node": source.uri(),
            "apiKey": "TYPESENSE-REVISION-KEY-CANARY",
            "sourceIndex": "fj_ts_migration_products",
            "sourceRevision": { "documentCount": 3 },
            "target": { "eligibilityToken": target_token }
        }),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert_eq!(
        body["code"],
        json!(AlgoliaImportErrorCode::SourceChanged.as_str()),
        "an unreadable Typesense export must not be admitted as unchanged: {body}"
    );
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 0);
    assert_eq!(flapjack.take_sensitive_requests().len(), 1);
    assert!(!body.to_string().contains("TYPESENSE-REVISION-KEY-CANARY"));
}

/// An export larger than one buffered read must still produce a determinate
/// hash. Giving up past a byte ceiling made every large collection
/// indeterminate, which is how a same-count content mutation on a big
/// collection reached submit.
#[tokio::test]
async fn create_contract_refuses_typesense_large_export_content_drift() {
    use sha2::{Digest, Sha256};
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    let _env = FlapjackIdentityEnvGuard::compatible_with_loopback_source_origins();
    let db = connect_and_migrate_required("create_contract_revision_typesense_large_drift").await;
    let (app, jwt, _customer_id, flapjack) = setup_algolia_cloud_job_create_app(
        db.pool.clone(),
        FakeAlgoliaSourceLister::with_inspect([]),
    )
    .await;
    let source = MockServer::start().await;
    // Both bodies are well past the 2 MiB buffer ceiling the old reader gave up
    // at, and differ only in a single document — the same-count content
    // mutation the guard exists to catch.
    let filler = "a".repeat(3 * 1024 * 1024);
    let before = format!(r#"{{"id":"sku-1","title":"before","pad":"{filler}"}}"#);
    let after = format!(r#"{{"id":"sku-1","title":"after","pad":"{filler}"}}"#);
    let pinned_revision = format!("sha256:{}", hex::encode(Sha256::digest(before.as_bytes())));
    Mock::given(method("GET"))
        .and(path(
            "/collections/fj_ts_migration_products/documents/export",
        ))
        .respond_with(ResponseTemplate::new(200).set_body_string(after.clone()))
        .mount(&source)
        .await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;
    flapjack.expect_sensitive_json_body(&format!(
        r#"{{"node":"{}","apiKey":"TYPESENSE-REVISION-KEY-CANARY"}}"#,
        source.uri()
    ));
    flapjack.push_sensitive_json_response(
        200,
        json!({
            "indexes": [{
                "name": "fj_ts_migration_products",
                "primaryKey": "id",
                "entries": 3,
                "documentCount": 3,
                "createdAt": null,
                "updatedAt": null,
                "defaultSortingField": null
            }],
            "limit": 100,
            "offset": 0,
            "total": 1
        }),
    );

    let (status, _headers, body) = post_create_job_for_provider(
        app,
        &jwt,
        "typesense",
        "revision-large-drift-typesense",
        json!({
            "mode": "create",
            "node": source.uri(),
            "apiKey": "TYPESENSE-REVISION-KEY-CANARY",
            "sourceIndex": "fj_ts_migration_products",
            "sourceRevision": {
                "documentCount": 3,
                "revision": pinned_revision
            },
            "target": { "eligibilityToken": target_token }
        }),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert_eq!(
        body["code"],
        json!(AlgoliaImportErrorCode::SourceChanged.as_str()),
        "a large-export content mutation must be refused: {body}"
    );
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 0);
    assert_eq!(flapjack.take_sensitive_requests().len(), 1);
}

/// The fail-closed reading must not simply refuse every large collection: an
/// unchanged oversized export still hashes to the pinned revision and still
/// submits. This is the control that keeps the refusal above meaningful.
#[tokio::test]
async fn create_contract_submits_typesense_large_export_when_content_is_unchanged() {
    use sha2::{Digest, Sha256};
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    let _env = FlapjackIdentityEnvGuard::compatible_with_loopback_source_origins();
    let db = connect_and_migrate_required("create_contract_revision_typesense_large_match").await;
    let (app, jwt, customer_id, flapjack) = setup_algolia_cloud_job_create_app(
        db.pool.clone(),
        FakeAlgoliaSourceLister::with_inspect([]),
    )
    .await;
    let source = MockServer::start().await;
    let filler = "a".repeat(3 * 1024 * 1024);
    let export = format!(r#"{{"id":"sku-1","title":"before","pad":"{filler}"}}"#);
    let pinned_revision = format!("sha256:{}", hex::encode(Sha256::digest(export.as_bytes())));
    Mock::given(method("GET"))
        .and(path(
            "/collections/fj_ts_migration_products/documents/export",
        ))
        .respond_with(ResponseTemplate::new(200).set_body_string(export.clone()))
        .mount(&source)
        .await;
    let target_token = target_create_eligibility_token(&app, &jwt).await;
    flapjack.expect_sensitive_json_body(&format!(
        r#"{{"node":"{}","apiKey":"TYPESENSE-REVISION-KEY-CANARY"}}"#,
        source.uri()
    ));
    flapjack.push_sensitive_json_response(
        200,
        json!({
            "indexes": [{
                "name": "fj_ts_migration_products",
                "primaryKey": "id",
                "entries": 3,
                "documentCount": 3,
                "createdAt": null,
                "updatedAt": null,
                "defaultSortingField": null
            }],
            "limit": 100,
            "offset": 0,
            "total": 1
        }),
    );
    flapjack.expect_sensitive_json_body(&format!(
        r#"{{"node":"{}","apiKey":"TYPESENSE-REVISION-KEY-CANARY","sourceIndex":"fj_ts_migration_products","targetIndex":"{}","overwrite":false}}"#,
        source.uri(),
        test_flapjack_uid(customer_id, "products")
    ));
    flapjack.push_sensitive_json_response(
        202,
        json!({
            "jobId": Uuid::new_v4(),
            "phase": "submitted",
            "disposition": "running",
            "createdAt": "2026-08-05T00:00:00Z",
            "updatedAt": "2026-08-05T00:00:00Z"
        }),
    );

    let (status, _headers, body) = post_create_job_for_provider(
        app,
        &jwt,
        "typesense",
        "revision-large-match-typesense",
        json!({
            "mode": "create",
            "node": source.uri(),
            "apiKey": "TYPESENSE-REVISION-KEY-CANARY",
            "sourceIndex": "fj_ts_migration_products",
            "sourceRevision": {
                "documentCount": 3,
                "revision": pinned_revision
            },
            "target": { "eligibilityToken": target_token }
        }),
    )
    .await;

    assert_eq!(
        status,
        StatusCode::ACCEPTED,
        "an unchanged oversized export must still submit: {body}"
    );
    assert_eq!(body["error"], serde_json::Value::Null, "{body}");
    assert_eq!(count_algolia_import_jobs(&db.pool).await, 1);
    assert_eq!(flapjack.take_sensitive_requests().len(), 2);
}
