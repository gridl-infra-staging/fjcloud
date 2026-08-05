use super::*;
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::net::TcpListener;

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

fn search_request(source_name: &str, query: &str, hits_per_page: u32) -> AlgoliaSourceQueryRequest {
    AlgoliaSourceQueryRequest {
        app_id: APP_ID.to_string(),
        api_key: Zeroizing::new(API_KEY.to_string()),
        source_name: source_name.to_string(),
        query: query.to_string(),
        hits_per_page,
    }
}

fn search_response(object_ids: &[&str]) -> AlgoliaClientResponse {
    AlgoliaClientResponse {
        status: 200,
        body: serde_json::to_vec(&serde_json::json!({
            "hits": object_ids
                .iter()
                .map(|object_id| serde_json::json!({ "objectID": object_id }))
                .collect::<Vec<_>>()
        }))
        .expect("test search response serializes"),
    }
}

#[tokio::test]
async fn algolia_source_search_uses_bounded_query_request_and_redacts_credentials() {
    let client = FakeClient::with_search_responses([Ok(search_response(&["p1", "p2"]))]);
    let result = service(client.clone())
        .search_index(search_request("products/by category", "running shoes", 17))
        .await
        .unwrap();

    assert_eq!(
        result,
        AlgoliaSourceSearchResponse {
            hits: vec![
                AlgoliaSourceSearchHit {
                    object_id: "p1".to_string(),
                },
                AlgoliaSourceSearchHit {
                    object_id: "p2".to_string(),
                },
            ],
        }
    );

    let requests = client.search_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].url.as_str(),
        "https://testapp123.algolia.net/1/indexes/products%2Fby%20category/query"
    );
    assert_eq!(requests[0].query, "running shoes");
    assert_eq!(requests[0].hits_per_page, 17);

    let debug_client_request = format!("{:?}", requests[0]);
    assert!(debug_client_request.contains("url: \"[REDACTED]\""));
    assert!(debug_client_request.contains("app_id: \"[REDACTED]\""));
    assert!(debug_client_request.contains("api_key: \"[REDACTED]\""));
    assert!(!debug_client_request
        .to_ascii_lowercase()
        .contains(&APP_ID.to_ascii_lowercase()));
    assert!(!debug_client_request.contains(API_KEY));

    // This request is what `search_index` logs verbatim on failure, so nothing
    // identifying may survive its Debug view — not the credentials, not the
    // source index, and not the end user's raw search text.
    let debug_source_request = format!(
        "{:?}",
        search_request("secret_source_index", "customer@example.com", 5)
    );
    assert!(debug_source_request.contains("app_id: \"[REDACTED]\""));
    assert!(debug_source_request.contains("api_key: \"[REDACTED]\""));
    assert!(debug_source_request.contains("source_name: \"[REDACTED]\""));
    assert!(debug_source_request.contains("query: \"[REDACTED]\""));
    assert!(!debug_source_request.contains(APP_ID));
    assert!(!debug_source_request.contains(API_KEY));
    assert!(!debug_source_request.contains("secret_source_index"));
    assert!(!debug_source_request.contains("customer@example.com"));
}

#[tokio::test]
async fn algolia_source_search_maps_statuses_and_transport_errors() {
    for (upstream, expected) in [
        (
            Ok(AlgoliaClientResponse::status(401)),
            AlgoliaSourceError::InvalidCredentials,
        ),
        (
            Ok(AlgoliaClientResponse::status(403)),
            AlgoliaSourceError::SourcePermissionRequired,
        ),
        (
            Ok(AlgoliaClientResponse::status(404)),
            AlgoliaSourceError::SourceIndexNotFound,
        ),
        (
            Ok(AlgoliaClientResponse::status(400)),
            AlgoliaSourceError::InvalidApplicationId,
        ),
        (
            Ok(AlgoliaClientResponse::status(418)),
            AlgoliaSourceError::InvalidUpstreamResponse,
        ),
        (
            Err(AlgoliaClientError::Timeout),
            AlgoliaSourceError::TimedOut,
        ),
        (
            Err(AlgoliaClientError::Transport),
            AlgoliaSourceError::Unavailable,
        ),
    ] {
        let client = FakeClient::with_search_responses([upstream]);
        assert_eq!(
            service(client)
                .search_index(search_request("products", "shoe", 5))
                .await
                .unwrap_err(),
            expected
        );
    }
}

#[tokio::test]
async fn algolia_source_search_retries_only_bounded_retryable_statuses() {
    for retryable_status in [429, 500, 503] {
        let client = FakeClient::with_search_responses([
            Ok(AlgoliaClientResponse::status(retryable_status)),
            Ok(AlgoliaClientResponse::status(retryable_status)),
            Ok(AlgoliaClientResponse::status(retryable_status)),
        ]);

        assert_eq!(
            service(client.clone())
                .search_index(search_request("products", "shoe", 5))
                .await
                .unwrap_err(),
            AlgoliaSourceError::Unavailable
        );
        assert_eq!(client.search_requests().len(), 3);
    }
}

#[tokio::test]
async fn algolia_source_search_rejects_invalid_bounds_before_transport() {
    for request in [
        AlgoliaSourceQueryRequest {
            app_id: "example.com/path".to_string(),
            ..search_request("products", "shoe", 5)
        },
        search_request("", "shoe", 5),
        search_request("products", "shoe", 0),
        search_request("products", "shoe", 101),
        AlgoliaSourceQueryRequest {
            api_key: Zeroizing::new(String::new()),
            ..search_request("products", "shoe", 5)
        },
    ] {
        let client = FakeClient::with_search_responses([]);
        assert!(
            service(client.clone()).search_index(request).await.is_err(),
            "invalid search request must fail closed"
        );
        assert!(
            client.search_requests().is_empty(),
            "invalid search request must not reach Algolia transport"
        );
    }
}

#[tokio::test]
async fn algolia_http_transports_reject_oversized_bodies() {
    async fn stalled_oversized_chunked_response(
        path: &str,
    ) -> (reqwest::Url, tokio::task::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let url = format!("http://{address}{path}").parse().unwrap();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            socket
                .write_all(
                    b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n",
                )
                .await
                .unwrap();
            let body = vec![b'x'; MAX_UPSTREAM_BODY_BYTES + 1];
            socket
                .write_all(format!("{:X}\r\n", body.len()).as_bytes())
                .await
                .unwrap();
            socket.write_all(&body).await.unwrap();
            socket.write_all(b"\r\n").await.unwrap();
            std::future::pending::<()>().await;
        });
        (url, server)
    }

    let client = ReqwestAlgoliaSourceClient::new().unwrap();
    let (list_url, list_server) = stalled_oversized_chunked_response("/list").await;
    let list_error = tokio::time::timeout(
        Duration::from_secs(3),
        client.list_indexes(AlgoliaClientRequest::for_test(list_url, APP_ID, API_KEY, 0)),
    )
    .await
    .expect("list transport must reject the body without waiting for EOF")
    .expect_err("oversized list response must fail closed");
    list_server.abort();
    assert_eq!(list_error, AlgoliaClientError::Transport);

    let (search_url, search_server) = stalled_oversized_chunked_response("/query").await;
    let search_error = tokio::time::timeout(
        Duration::from_secs(3),
        client.search_index(AlgoliaSourceQueryClientRequest::for_test(
            search_url, APP_ID, API_KEY,
        )),
    )
    .await
    .expect("search transport must reject the body without waiting for EOF")
    .expect_err("oversized search response must fail closed");
    search_server.abort();
    assert_eq!(search_error, AlgoliaClientError::Transport);
}
