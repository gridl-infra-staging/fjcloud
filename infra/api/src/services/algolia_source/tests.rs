use super::*;
use async_trait::async_trait;
use chrono::{TimeZone, Utc};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

const CURSOR_KEY: &[u8] = b"algolia-cloud-discovery-test-cursor-key";
const APP_ID: &str = "TESTAPP123";
const API_KEY: &str = "volatile-secret-api-key";

#[derive(Default)]
struct FakeClient {
    responses: Mutex<VecDeque<Result<AlgoliaClientResponse, AlgoliaClientError>>>,
    requests: Mutex<Vec<AlgoliaClientRequest>>,
}

impl FakeClient {
    fn with_responses(
        responses: impl IntoIterator<Item = Result<AlgoliaClientResponse, AlgoliaClientError>>,
    ) -> Arc<Self> {
        Arc::new(Self {
            responses: Mutex::new(responses.into_iter().collect()),
            requests: Mutex::new(Vec::new()),
        })
    }

    fn requests(&self) -> Vec<AlgoliaClientRequest> {
        self.requests.lock().unwrap().clone()
    }
}

#[async_trait]
impl AlgoliaSourceClient for FakeClient {
    async fn list_indexes(
        &self,
        request: AlgoliaClientRequest,
    ) -> Result<AlgoliaClientResponse, AlgoliaClientError> {
        self.requests.lock().unwrap().push(request);
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("fake response configured")
    }
}

fn item(name: &str) -> AlgoliaIndexMetadata {
    AlgoliaIndexMetadata {
        name: name.to_string(),
        entries: 42,
        data_size: 2048,
        file_size: 4096,
        updated_at: Utc.with_ymd_and_hms(2026, 7, 15, 12, 30, 0).unwrap(),
        last_build_time_s: 3,
        pending_task: false,
        primary: Some("products".to_string()),
        replicas: vec!["products_price_asc".to_string()],
    }
}

fn response(page: u32, nb_pages: u32, items: Vec<AlgoliaIndexMetadata>) -> AlgoliaClientResponse {
    AlgoliaClientResponse::success(AlgoliaPage {
        items,
        page: Some(page),
        nb_pages,
    })
}

fn algolia_response_without_page(
    nb_pages: u32,
    items: Vec<AlgoliaIndexMetadata>,
) -> AlgoliaClientResponse {
    AlgoliaClientResponse {
        status: 200,
        body: serde_json::to_vec(&serde_json::json!({
            "items": items,
            "nbPages": nb_pages
        }))
        .expect("test response serializes"),
    }
}

fn request(cursor: Option<String>) -> AlgoliaSourceListRequest {
    request_with_key(API_KEY, cursor)
}

fn request_with_key(api_key: &str, cursor: Option<String>) -> AlgoliaSourceListRequest {
    AlgoliaSourceListRequest {
        app_id: APP_ID.to_string(),
        api_key: api_key.to_string(),
        cursor,
        hits_per_page: None,
    }
}

fn service(client: Arc<FakeClient>) -> AlgoliaSourceService {
    AlgoliaSourceService::new(client, CURSOR_KEY).unwrap()
}

#[tokio::test]
async fn algolia_cloud_discovery_returns_typed_picker_metadata_and_shape() {
    let client = FakeClient::with_responses([Ok(response(0, 1, vec![item("products")]))]);
    let result = service(client).list_indexes(request(None)).await.unwrap();

    assert_eq!(result.items, vec![item("products")]);
    assert_eq!(result.next_cursor, None);
    assert_eq!(
        serde_json::to_value(result).unwrap(),
        serde_json::json!({
            "items": [{
                "name": "products",
                "entries": 42,
                "dataSize": 2048,
                "fileSize": 4096,
                "updatedAt": "2026-07-15T12:30:00Z",
                "lastBuildTimeS": 3,
                "pendingTask": false,
                "primary": "products",
                "replicas": ["products_price_asc"]
            }],
            "nextCursor": null
        })
    );
}

#[tokio::test]
async fn algolia_cloud_discovery_accepts_live_list_response_without_page_field() {
    let client =
        FakeClient::with_responses([Ok(algolia_response_without_page(1, vec![item("products")]))]);
    let result = service(client.clone())
        .list_indexes(request(None))
        .await
        .unwrap();

    assert_eq!(result.items, vec![item("products")]);
    assert_eq!(result.next_cursor, None);
    assert_eq!(client.requests()[0].page, 0);
}

#[tokio::test]
async fn algolia_cloud_discovery_uses_fixed_validated_host_and_explicit_page_size() {
    let client = FakeClient::with_responses([Ok(response(0, 1, vec![]))]);
    service(client.clone())
        .list_indexes(request(None))
        .await
        .unwrap();

    let requests = client.requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].url.as_str(),
        "https://testapp123.algolia.net/1/indexes"
    );
    assert_eq!(requests[0].page, 0);
    assert_eq!(requests[0].hits_per_page, 100);

    let error = service(FakeClient::default().into())
        .list_indexes(AlgoliaSourceListRequest {
            app_id: "example.com/path".to_string(),
            api_key: API_KEY.to_string(),
            cursor: None,
            hits_per_page: None,
        })
        .await
        .unwrap_err();
    assert_eq!(error, AlgoliaSourceError::InvalidApplicationId);
}

#[tokio::test]
async fn algolia_cloud_discovery_credentials_are_redacted_and_never_enter_cursor() {
    let client = FakeClient::with_responses([Ok(response(0, 2, vec![item("products")]))]);
    let result = service(client.clone())
        .list_indexes(request(None))
        .await
        .unwrap();

    let debug_request = format!("{:?}", &client.requests()[0]);
    assert!(debug_request.contains("app_id: \"[REDACTED]\""));
    assert!(debug_request.contains("api_key: \"[REDACTED]\""));
    assert!(!debug_request.contains(APP_ID));
    assert!(!debug_request.contains(API_KEY));
    let debug_source_request = format!("{:?}", request(None));
    assert!(debug_source_request.contains("app_id: \"[REDACTED]\""));
    assert!(debug_source_request.contains("api_key: \"[REDACTED]\""));
    assert!(!debug_source_request.contains(APP_ID));
    assert!(!debug_source_request.contains(API_KEY));
    assert!(!result.next_cursor.as_deref().unwrap().contains(API_KEY));
    assert!(!result.next_cursor.as_deref().unwrap().contains(APP_ID));
}

#[tokio::test]
async fn algolia_cloud_discovery_cursors_are_bound_to_volatile_api_key() {
    let client = FakeClient::with_responses([
        Ok(response(0, 2, vec![item("probe-a")])),
        Ok(response(0, 2, vec![item("probe-b")])),
        Ok(response(1, 2, vec![item("probe-b-replica")])),
    ]);
    let source_service = service(client);

    let first_run = source_service
        .list_indexes(request_with_key("volatile-secret-api-key-a", None))
        .await
        .unwrap();
    let second_run = source_service
        .list_indexes(request_with_key("volatile-secret-api-key-b", None))
        .await
        .unwrap();

    let first_cursor = first_run.next_cursor.unwrap();
    let second_cursor = second_run.next_cursor.unwrap();
    assert_ne!(
        first_cursor, second_cursor,
        "independent volatile keys must not collide in the replay cache"
    );
    assert!(!second_cursor.contains("volatile-secret-api-key-b"));

    let second_page = source_service
        .list_indexes(request_with_key(
            "volatile-secret-api-key-b",
            Some(second_cursor),
        ))
        .await
        .unwrap();
    assert_eq!(second_page.items, vec![item("probe-b-replica")]);
    assert_eq!(
        source_service
            .list_indexes(request_with_key(
                "volatile-secret-api-key-b",
                Some(first_cursor),
            ))
            .await
            .unwrap_err(),
        AlgoliaSourceError::InvalidCursor
    );
}

#[tokio::test]
async fn algolia_cloud_discovery_fetches_at_most_one_page_per_call_and_tracks_progress() {
    let client = FakeClient::with_responses([
        Ok(response(0, 3, vec![item("first")])),
        Ok(response(1, 4, vec![item("second")])),
        Ok(response(2, 3, vec![item("third")])),
    ]);
    let source_service = service(client.clone());

    let first = source_service.list_indexes(request(None)).await.unwrap();
    assert_eq!(client.requests().len(), 1);
    let second = source_service
        .list_indexes(request(first.next_cursor))
        .await
        .unwrap();
    assert_eq!(client.requests().len(), 2);
    let third = source_service
        .list_indexes(request(second.next_cursor))
        .await
        .unwrap();

    assert_eq!(third.next_cursor, None);
    assert_eq!(
        client.requests().iter().map(|r| r.page).collect::<Vec<_>>(),
        vec![0, 1, 2]
    );
}

#[tokio::test]
async fn algolia_cloud_discovery_empty_application_has_no_cursor() {
    let client = FakeClient::with_responses([Ok(response(0, 0, vec![]))]);
    let result = service(client).list_indexes(request(None)).await.unwrap();
    assert!(result.items.is_empty());
    assert_eq!(result.next_cursor, None);
}

#[tokio::test]
async fn algolia_cloud_discovery_refuses_empty_tampered_repeated_and_wrong_source_cursors() {
    let client = FakeClient::with_responses([
        Ok(response(0, 2, vec![item("one")])),
        Ok(response(1, 2, vec![item("two")])),
    ]);
    let source_service = service(client);

    assert_eq!(
        source_service
            .list_indexes(request(Some(String::new())))
            .await
            .unwrap_err(),
        AlgoliaSourceError::InvalidCursor
    );

    let first = source_service.list_indexes(request(None)).await.unwrap();
    let cursor = first.next_cursor.unwrap();
    let mut tampered = cursor.clone();
    tampered.push('x');
    assert_eq!(
        source_service
            .list_indexes(request(Some(tampered)))
            .await
            .unwrap_err(),
        AlgoliaSourceError::InvalidCursor
    );

    let wrong_source = AlgoliaSourceListRequest {
        app_id: "OTHERAPP12".to_string(),
        api_key: API_KEY.to_string(),
        cursor: Some(cursor.clone()),
        hits_per_page: None,
    };
    assert_eq!(
        source_service.list_indexes(wrong_source).await.unwrap_err(),
        AlgoliaSourceError::InvalidCursor
    );

    source_service
        .list_indexes(request(Some(cursor.clone())))
        .await
        .unwrap();
    assert_eq!(
        source_service
            .list_indexes(request(Some(cursor)))
            .await
            .unwrap_err(),
        AlgoliaSourceError::InvalidCursor
    );
}

#[tokio::test]
async fn algolia_cloud_discovery_rejects_non_progress_page_response() {
    let client = FakeClient::with_responses([
        Ok(response(0, 2, vec![item("one")])),
        Ok(response(0, 2, vec![item("same-page")])),
    ]);
    let source_service = service(client);
    let first = source_service.list_indexes(request(None)).await.unwrap();
    assert_eq!(
        source_service
            .list_indexes(request(first.next_cursor))
            .await
            .unwrap_err(),
        AlgoliaSourceError::InvalidUpstreamResponse
    );
}

#[tokio::test]
async fn algolia_cloud_discovery_maps_acl_auth_timeout_and_transport_failures() {
    let cases = [
        (
            AlgoliaClientResponse::status(401),
            AlgoliaSourceError::InvalidCredentials,
        ),
        (
            AlgoliaClientResponse::status(403),
            AlgoliaSourceError::ListIndexesAclRequired,
        ),
    ];
    for (upstream, expected) in cases {
        let client = FakeClient::with_responses([Ok(upstream)]);
        assert_eq!(
            service(client)
                .list_indexes(request(None))
                .await
                .unwrap_err(),
            expected
        );
    }

    let timeout = FakeClient::with_responses([Err(AlgoliaClientError::Timeout)]);
    assert_eq!(
        service(timeout)
            .list_indexes(request(None))
            .await
            .unwrap_err(),
        AlgoliaSourceError::TimedOut
    );
    let transport = FakeClient::with_responses([Err(AlgoliaClientError::Transport)]);
    assert_eq!(
        service(transport)
            .list_indexes(request(None))
            .await
            .unwrap_err(),
        AlgoliaSourceError::Unavailable
    );
}

#[tokio::test]
async fn algolia_cloud_discovery_retries_only_bounded_retryable_statuses() {
    for retryable_status in [429, 500, 503] {
        let client = FakeClient::with_responses([
            Ok(AlgoliaClientResponse::status(retryable_status)),
            Ok(AlgoliaClientResponse::status(retryable_status)),
            Ok(AlgoliaClientResponse::status(retryable_status)),
        ]);
        assert_eq!(
            service(client.clone())
                .list_indexes(request(None))
                .await
                .unwrap_err(),
            AlgoliaSourceError::Unavailable
        );
        assert_eq!(client.requests().len(), 3);
    }
}

#[tokio::test]
async fn algolia_cloud_discovery_fails_closed_when_catalog_caps_are_exceeded() {
    let too_many_items = vec![item("oversized"); MAX_TOTAL_ITEMS + 1];
    let client = FakeClient::with_responses([Ok(response(0, 1, too_many_items))]);
    assert_eq!(
        service(client)
            .list_indexes(request(None))
            .await
            .unwrap_err(),
        AlgoliaSourceError::SourceCatalogTooLarge
    );

    let client = FakeClient::with_responses([Ok(response(0, MAX_TOTAL_PAGES + 1, vec![]))]);
    assert_eq!(
        service(client)
            .list_indexes(request(None))
            .await
            .unwrap_err(),
        AlgoliaSourceError::SourceCatalogTooLarge
    );

    let huge_name = "x".repeat(MAX_METADATA_BYTES + 1);
    let client = FakeClient::with_responses([Ok(response(0, 1, vec![item(&huge_name)]))]);
    assert_eq!(
        service(client)
            .list_indexes(request(None))
            .await
            .unwrap_err(),
        AlgoliaSourceError::SourceCatalogTooLarge
    );
}

#[tokio::test]
async fn algolia_cloud_discovery_rejects_redirects() {
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/redirect"))
        .respond_with(ResponseTemplate::new(302).insert_header("Location", "/credentials-capture"))
        .mount(&server)
        .await;
    let client = ReqwestAlgoliaSourceClient::new().unwrap();
    let result = client
        .list_indexes(AlgoliaClientRequest::for_test(
            format!("{}/redirect", server.uri()).parse().unwrap(),
            APP_ID,
            API_KEY,
            0,
        ))
        .await
        .unwrap();

    assert_eq!(result.status, 302);
    assert_eq!(server.received_requests().await.unwrap().len(), 1);
}

// ---------------------------------------------------------------------------
// Final temporary-key source inspection (create admission input)
// ---------------------------------------------------------------------------

fn sized_item(name: &str, entries: u64, data_size: u64, file_size: u64) -> AlgoliaIndexMetadata {
    AlgoliaIndexMetadata {
        name: name.to_string(),
        entries,
        data_size,
        file_size,
        updated_at: Utc.with_ymd_and_hms(2026, 7, 15, 12, 30, 0).unwrap(),
        last_build_time_s: 3,
        pending_task: false,
        primary: None,
        replicas: vec![],
    }
}

fn inspect_request(source_name: &str) -> AlgoliaSourceInspectRequest {
    AlgoliaSourceInspectRequest {
        app_id: APP_ID.to_string(),
        api_key: Zeroizing::new(API_KEY.to_string()),
        source_name: source_name.to_string(),
    }
}

fn expected_source(item: &AlgoliaIndexMetadata) -> AlgoliaImportSource {
    AlgoliaImportSource::from_final_key_metadata(
        APP_ID,
        &item.name,
        AlgoliaImportSourceMetadata::new(
            i64::try_from(item.file_size).ok(),
            i64::try_from(item.entries).ok(),
            format!(
                "{}:{}",
                item.updated_at.to_rfc3339(),
                item.last_build_time_s
            ),
        ),
    )
}

#[tokio::test]
async fn algolia_cloud_job_inspect_source_builds_source_from_server_metadata_only() {
    let server_item = sized_item("products", 42, 2048, 4096);
    let client = FakeClient::with_responses([
        Ok(response(0, 1, vec![server_item.clone()])),
        Ok(AlgoliaClientResponse::status(200)),
        Ok(AlgoliaClientResponse::status(200)),
    ]);

    let source = service(client)
        .inspect_source(inspect_request("products"))
        .await
        .unwrap();

    // The on-disk (file) size is the authoritative source size, never the
    // record-data size and never any browser-supplied number.
    assert_eq!(source.source_size_bytes(), 4096);
    assert_eq!(
        source.canonical_fingerprint(),
        expected_source(&server_item).canonical_fingerprint()
    );
}

#[tokio::test]
async fn algolia_cloud_job_inspect_source_uses_server_size_not_client_picker_numbers() {
    // Two server responses for the same index name differing only in the
    // server-reported file size must yield different fingerprints, proving the
    // fingerprint is driven by the re-fetched server metadata rather than any
    // client-provided count or size (the request carries none).
    let small = sized_item("products", 42, 2048, 4096);
    let large = sized_item("products", 42, 2048, 9999);

    let small_source = service(FakeClient::with_responses([
        Ok(response(0, 1, vec![small.clone()])),
        Ok(AlgoliaClientResponse::status(200)),
        Ok(AlgoliaClientResponse::status(200)),
    ]))
    .inspect_source(inspect_request("products"))
    .await
    .unwrap();
    let large_source = service(FakeClient::with_responses([
        Ok(response(0, 1, vec![large.clone()])),
        Ok(AlgoliaClientResponse::status(200)),
        Ok(AlgoliaClientResponse::status(200)),
    ]))
    .inspect_source(inspect_request("products"))
    .await
    .unwrap();

    assert_eq!(small_source.source_size_bytes(), 4096);
    assert_eq!(large_source.source_size_bytes(), 9999);
    assert_ne!(
        small_source.canonical_fingerprint(),
        large_source.canonical_fingerprint()
    );
    assert_eq!(
        large_source.canonical_fingerprint(),
        expected_source(&large).canonical_fingerprint()
    );
}

#[tokio::test]
async fn algolia_cloud_job_inspect_source_finds_index_on_later_page() {
    let target = sized_item("products", 7, 1024, 2048);
    let client = FakeClient::with_responses([
        Ok(response(0, 2, vec![sized_item("other", 1, 1, 1)])),
        Ok(response(1, 2, vec![target.clone()])),
        Ok(AlgoliaClientResponse::status(200)),
        Ok(AlgoliaClientResponse::status(200)),
    ]);
    let handle = client.clone();

    let source = service(client)
        .inspect_source(inspect_request("products"))
        .await
        .unwrap();

    assert_eq!(
        source.canonical_fingerprint(),
        expected_source(&target).canonical_fingerprint()
    );
    // Two list pages to find the index on page 1, then the settings and browse
    // permission probes.
    assert_eq!(handle.requests().len(), 4);
}

#[tokio::test]
async fn algolia_cloud_job_inspect_source_missing_index_is_source_index_not_found() {
    let client = FakeClient::with_responses([
        Ok(response(0, 2, vec![sized_item("other", 1, 1, 1)])),
        Ok(response(1, 2, vec![sized_item("another", 1, 1, 1)])),
    ]);
    assert_eq!(
        service(client)
            .inspect_source(inspect_request("products"))
            .await
            .unwrap_err(),
        AlgoliaSourceError::SourceIndexNotFound
    );
}

#[tokio::test]
async fn algolia_cloud_job_inspect_source_maps_credential_and_acl_failures() {
    let client = FakeClient::with_responses([Ok(AlgoliaClientResponse::status(401))]);
    assert_eq!(
        service(client)
            .inspect_source(inspect_request("products"))
            .await
            .unwrap_err(),
        AlgoliaSourceError::InvalidCredentials
    );

    let client = FakeClient::with_responses([Ok(AlgoliaClientResponse::status(403))]);
    assert_eq!(
        service(client)
            .inspect_source(inspect_request("products"))
            .await
            .unwrap_err(),
        AlgoliaSourceError::ListIndexesAclRequired
    );

    let empty_key =
        FakeClient::with_responses([Ok(response(0, 1, vec![sized_item("products", 1, 1, 1)]))]);
    let handle = empty_key.clone();
    assert_eq!(
        service(empty_key)
            .inspect_source(AlgoliaSourceInspectRequest {
                app_id: APP_ID.to_string(),
                api_key: Zeroizing::new(String::new()),
                source_name: "products".to_string(),
            })
            .await
            .unwrap_err(),
        AlgoliaSourceError::InvalidCredentials
    );
    assert!(handle.requests().is_empty());
}

// ---------------------------------------------------------------------------
// Final temporary-key permission validation (settings + browse ACLs)
// ---------------------------------------------------------------------------

/// A key that can list indexes and see the selected index but lacks the
/// `settings` ACL must be refused before any source is returned — and therefore
/// before the route can persist a job. Known-answer probe: 403 on the settings
/// endpoint means the permission is absent.
#[tokio::test]
async fn algolia_cloud_job_inspect_source_refuses_key_missing_settings_permission() {
    let client = FakeClient::with_responses([
        Ok(response(0, 1, vec![sized_item("products", 42, 2048, 4096)])),
        Ok(AlgoliaClientResponse::status(403)),
    ]);
    let handle = client.clone();

    assert_eq!(
        service(client)
            .inspect_source(inspect_request("products"))
            .await
            .unwrap_err(),
        AlgoliaSourceError::SourcePermissionRequired
    );

    // The settings endpoint for the selected index is the probe that was denied;
    // browse is never reached once settings fails.
    let requests = handle.requests();
    assert_eq!(requests.len(), 2);
    assert!(requests[1]
        .url
        .as_str()
        .ends_with("/1/indexes/products/settings"));
}

/// A key that holds `settings` but not `browse` is likewise refused. `browse`
/// is probed only after `settings` passes, proving both permissions are
/// required, not just one.
#[tokio::test]
async fn algolia_cloud_job_inspect_source_refuses_key_missing_browse_permission() {
    let client = FakeClient::with_responses([
        Ok(response(0, 1, vec![sized_item("products", 42, 2048, 4096)])),
        Ok(AlgoliaClientResponse::status(200)),
        Ok(AlgoliaClientResponse::status(403)),
    ]);
    let handle = client.clone();

    assert_eq!(
        service(client)
            .inspect_source(inspect_request("products"))
            .await
            .unwrap_err(),
        AlgoliaSourceError::SourcePermissionRequired
    );

    let requests = handle.requests();
    assert_eq!(requests.len(), 3);
    assert!(requests[1]
        .url
        .as_str()
        .ends_with("/1/indexes/products/settings"));
    assert!(requests[2]
        .url
        .as_str()
        .ends_with("/1/indexes/products/browse"));
}

/// A key that lists, sees the selected index, and holds both `settings` and
/// `browse` is accepted, and both permission probes carry the same redacted
/// credentials against the selected index.
#[tokio::test]
async fn algolia_cloud_job_inspect_source_accepts_key_with_settings_and_browse() {
    let server_item = sized_item("products", 42, 2048, 4096);
    let client = FakeClient::with_responses([
        Ok(response(0, 1, vec![server_item.clone()])),
        Ok(AlgoliaClientResponse::status(200)),
        Ok(AlgoliaClientResponse::status(200)),
    ]);
    let handle = client.clone();

    let source = service(client)
        .inspect_source(inspect_request("products"))
        .await
        .unwrap();

    assert_eq!(
        source.canonical_fingerprint(),
        expected_source(&server_item).canonical_fingerprint()
    );
    let requests = handle.requests();
    assert_eq!(requests.len(), 3);
    assert!(requests[0].url.as_str().ends_with("/1/indexes"));
    assert!(requests[1]
        .url
        .as_str()
        .ends_with("/1/indexes/products/settings"));
    assert!(requests[2]
        .url
        .as_str()
        .ends_with("/1/indexes/products/browse"));
    let probe_debug = format!("{:?}", requests[1]);
    assert!(probe_debug.contains("api_key: \"[REDACTED]\""));
    assert!(!probe_debug.contains(API_KEY));
}

/// A permission-probe timeout maps to the transient discovery error, so a slow
/// upstream never masquerades as a missing permission.
#[tokio::test]
async fn algolia_cloud_job_inspect_source_permission_probe_timeout_is_transient() {
    let client = FakeClient::with_responses([
        Ok(response(0, 1, vec![sized_item("products", 42, 2048, 4096)])),
        Err(AlgoliaClientError::Timeout),
    ]);
    assert_eq!(
        service(client)
            .inspect_source(inspect_request("products"))
            .await
            .unwrap_err(),
        AlgoliaSourceError::TimedOut
    );
}

#[tokio::test]
async fn algolia_cloud_job_inspect_source_rejects_oversized_catalog() {
    let client = FakeClient::with_responses([Ok(response(
        0,
        MAX_TOTAL_PAGES + 1,
        vec![sized_item("other", 1, 1, 1)],
    ))]);
    assert_eq!(
        service(client)
            .inspect_source(inspect_request("products"))
            .await
            .unwrap_err(),
        AlgoliaSourceError::SourceCatalogTooLarge
    );
}

#[tokio::test]
async fn algolia_cloud_job_inspect_source_request_and_result_never_reveal_key() {
    let secret = "do-not-log-this-temporary-key";
    let request = AlgoliaSourceInspectRequest {
        app_id: "TESTAPP123".to_string(),
        api_key: Zeroizing::new(secret.to_string()),
        source_name: "products".to_string(),
    };
    let debug_request = format!("{request:?}");
    assert!(debug_request.contains("app_id: \"[REDACTED]\""));
    assert!(debug_request.contains("api_key: \"[REDACTED]\""));
    assert!(debug_request.contains("source_name: \"[REDACTED]\""));
    assert!(!debug_request.contains(secret));
    assert!(!debug_request.contains("TESTAPP123"));
    assert!(!debug_request.contains("products"));

    let server_item = sized_item("products", 42, 2048, 4096);
    let source = service(FakeClient::with_responses([
        Ok(response(0, 1, vec![server_item])),
        Ok(AlgoliaClientResponse::status(200)),
        Ok(AlgoliaClientResponse::status(200)),
    ]))
    .inspect_source(request)
    .await
    .unwrap();
    assert!(!format!("{source:?}").contains(secret));
}
