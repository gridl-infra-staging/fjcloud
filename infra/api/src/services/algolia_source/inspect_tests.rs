use super::*;

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
