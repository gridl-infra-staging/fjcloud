// Integration tests for the FlapjackProxy path against a live stack.
//
// These tests require a running integration stack (Postgres + fjcloud API + flapjack).
// They are SKIPPED when INTEGRATION env var is not set.
//
// Run with: INTEGRATION=1 cargo test -p api --test integration_flapjack_proxy_test -- --test-threads=1

#[path = "common/integration_helpers.rs"]
mod integration_helpers;

use integration_helpers::{api_base, flapjack_base, http_client, register_and_login};
use serde_json::{json, Value};
use std::future::Future;
use std::time::Duration;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Generate a unique email for test isolation.
fn unique_email(prefix: &str) -> String {
    let id = Uuid::new_v4().to_string()[..8].to_string();
    format!("{prefix}-{id}@integration-test.local")
}

/// Generate a unique index name to avoid collisions across test runs.
fn unique_index_name(prefix: &str) -> String {
    let id = Uuid::new_v4().to_string()[..8].to_string();
    format!("{prefix}-{id}")
}

fn assert_search_hits_contain_titles(
    search_body: &Value,
    expected_titles: &[&str],
) -> Result<(), String> {
    let hits = search_body["hits"]
        .as_array()
        .ok_or_else(|| format!("search response missing 'hits' array: {search_body}"))?;
    if hits.is_empty() {
        return Err(format!(
            "search response returned empty hits array: {search_body}"
        ));
    }

    let found_titles = hits
        .iter()
        .filter_map(|hit| hit["title"].as_str())
        .collect::<Vec<_>>();
    for expected in expected_titles {
        if !found_titles.iter().any(|title| title == expected) {
            return Err(format!(
                "missing expected title '{expected}' in search hits titles {:?}",
                found_titles
            ));
        }
    }
    Ok(())
}

fn assert_exact_string_array(body: &Value, field: &str, expected: &[&str]) -> Result<(), String> {
    let current = body[field]
        .as_array()
        .ok_or_else(|| format!("'{field}' should be an array: {body}"))?;
    let current_values = current
        .iter()
        .map(|v| {
            v.as_str()
                .ok_or_else(|| format!("'{field}' should contain only strings: {body}"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    if current_values == expected {
        Ok(())
    } else {
        Err(format!(
            "'{field}' mismatch: expected {:?}, got {:?}",
            expected, current_values
        ))
    }
}

async fn retry_with_delay<F, Fut, T, E>(
    attempts: usize,
    delay: Duration,
    mut operation: F,
) -> Result<T, E>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T, E>>,
{
    assert!(attempts > 0, "attempts must be greater than zero");
    for attempt in 1..=attempts {
        match operation().await {
            Ok(value) => return Ok(value),
            Err(err) if attempt == attempts => return Err(err),
            Err(_) => tokio::time::sleep(delay).await,
        }
    }

    unreachable!("retry loop should always return or error before this point");
}

#[cfg(test)]
mod helper_tests {
    use super::{assert_exact_string_array, retry_with_delay};
    use serde_json::json;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::time::Duration;

    #[test]
    fn exact_string_array_accepts_exact_match() {
        let current = json!({
            "searchableAttributes": ["title", "body"]
        });
        assert!(
            assert_exact_string_array(&current, "searchableAttributes", &["title", "body"]).is_ok()
        );
    }

    #[test]
    fn exact_string_array_rejects_superset() {
        let current = json!({
            "searchableAttributes": ["title", "body", "extra"]
        });
        assert!(
            assert_exact_string_array(&current, "searchableAttributes", &["title", "body"])
                .is_err()
        );
    }

    #[tokio::test]
    async fn retry_with_delay_succeeds_after_transient_failures() {
        let attempts = Arc::new(AtomicUsize::new(0));
        let attempts_for_op = Arc::clone(&attempts);

        let result = retry_with_delay(3, Duration::from_millis(1), move || {
            let attempts_for_op = Arc::clone(&attempts_for_op);
            async move {
                let current = attempts_for_op.fetch_add(1, Ordering::SeqCst) + 1;
                if current < 3 {
                    Err("not yet")
                } else {
                    Ok("ready")
                }
            }
        })
        .await;

        assert_eq!(result.unwrap(), "ready");
        assert_eq!(attempts.load(Ordering::SeqCst), 3);
    }

    #[tokio::test]
    async fn retry_with_delay_returns_last_error_when_exhausted() {
        let attempts = Arc::new(AtomicUsize::new(0));
        let attempts_for_op = Arc::clone(&attempts);

        let result: Result<(), &str> = retry_with_delay(2, Duration::from_millis(1), move || {
            let attempts_for_op = Arc::clone(&attempts_for_op);
            async move {
                attempts_for_op.fetch_add(1, Ordering::SeqCst);
                Err("still failing")
            }
        })
        .await;

        assert_eq!(result.unwrap_err(), "still failing");
        assert_eq!(attempts.load(Ordering::SeqCst), 2);
    }
}

/// Seed a shared VM in the integration DB so that index creation has placement targets.
/// Returns the VM id. The VM is created in the given region with a flapjack_url pointing
/// to the local flapjack instance.
async fn seed_shared_vm(region: &str) -> Uuid {
    let db_url = integration_helpers::db_url();
    let pool = sqlx::PgPool::connect(&db_url)
        .await
        .expect("failed to connect to integration DB for VM seeding");

    let flapjack_url = flapjack_base();
    let vm_id = Uuid::new_v4();
    let hostname = format!("integration-vm-{}", &vm_id.to_string()[..8]);

    sqlx::query(
        "INSERT INTO vm_inventory (id, provider, region, hostname, flapjack_url, status, capacity, current_load, created_at, updated_at)
         VALUES ($1, 'integration', $2, $3, $4, 'active',
                 '{\"cpu_cores\": 8, \"memory_gb\": 32, \"disk_gb\": 500}',
                 '{\"cpu_cores\": 0, \"memory_gb\": 0, \"disk_gb\": 0}',
                 NOW(), NOW())
         ON CONFLICT (id) DO NOTHING"
    )
    .bind(vm_id)
    .bind(region)
    .bind(&hostname)
    .bind(&flapjack_url)
    .execute(&pool)
    .await
    .expect("failed to seed shared VM");

    vm_id
}

/// Check if flapjack is reachable at the integration base URL.
async fn flapjack_is_healthy(client: &reqwest::Client) -> bool {
    let base = flapjack_base();
    client
        .get(format!("{base}/health"))
        .send()
        .await
        .map(|r| r.status().is_success())
        .unwrap_or(false)
}

/// Create an index via the fjcloud API and return the response body.
async fn create_index_via_api(
    client: &reqwest::Client,
    base: &str,
    token: &str,
    name: &str,
    region: &str,
) -> reqwest::Response {
    client
        .post(format!("{base}/indexes"))
        .bearer_auth(token)
        .json(&json!({
            "name": name,
            "region": region
        }))
        .send()
        .await
        .expect("create index request failed")
}

/// Delete an index via the fjcloud API.
async fn delete_index_via_api(
    client: &reqwest::Client,
    base: &str,
    token: &str,
    name: &str,
) -> reqwest::Response {
    client
        .delete(format!("{base}/indexes/{name}"))
        .bearer_auth(token)
        .json(&json!({"confirm": true}))
        .send()
        .await
        .expect("delete index request failed")
}

// ===========================================================================
// Integration Harness Readiness
// ===========================================================================

integration_test!(integration_flapjack_health_check, async {
    let client = http_client();

    assert!(
        flapjack_is_healthy(&client).await,
        "flapjack should be healthy at {}",
        flapjack_base()
    );
});

// ===========================================================================
// Real Index Lifecycle Against Flapjack (TDD)
// ===========================================================================

integration_test!(integration_flapjack_proxy_register_and_login, async {
    let client = http_client();
    let base = api_base();
    let email = unique_email("proxy-auth");

    let token = register_and_login(&client, &base, &email).await;
    assert!(
        !token.is_empty(),
        "JWT token should be non-empty after login"
    );
});

integration_test!(integration_flapjack_proxy_create_index, async {
    let client = http_client();
    let base = api_base();
    let email = unique_email("proxy-create");
    let index_name = unique_index_name("test-idx");

    // Ensure a shared VM exists for us-east-1
    seed_shared_vm("us-east-1").await;

    let token = register_and_login(&client, &base, &email).await;

    let resp = create_index_via_api(&client, &base, &token, &index_name, "us-east-1").await;
    let status = resp.status().as_u16();
    let body: Value = resp.json().await.expect("create index response not JSON");

    assert_eq!(
        status, 201,
        "POST /indexes should return 201, got {status}: {body}"
    );
    assert_eq!(
        body["name"].as_str().unwrap(),
        index_name,
        "response name should match requested index name"
    );
    assert_eq!(
        body["region"].as_str().unwrap(),
        "us-east-1",
        "response region should match requested region"
    );
    assert!(
        body["endpoint"].as_str().is_some(),
        "response should include an endpoint URL"
    );
});

integration_test!(integration_flapjack_proxy_ingest_and_search, async {
    let client = http_client();
    let base = api_base();
    let fj_base = flapjack_base();
    let email = unique_email("proxy-search");
    let index_name = unique_index_name("search-idx");

    seed_shared_vm("us-east-1").await;
    let token = register_and_login(&client, &base, &email).await;

    // Create index via fjcloud API
    let create_resp = create_index_via_api(&client, &base, &token, &index_name, "us-east-1").await;
    assert_eq!(
        create_resp.status().as_u16(),
        201,
        "index creation should succeed"
    );

    // Create a search key via fjcloud so we can push docs directly to flapjack
    let key_resp = client
        .post(format!("{base}/indexes/{index_name}/keys"))
        .bearer_auth(&token)
        .json(&json!({
            "description": "integration test key",
            "acl": ["search", "addObject"]
        }))
        .send()
        .await
        .expect("create key request failed");
    assert_eq!(
        key_resp.status().as_u16(),
        201,
        "key creation should succeed"
    );
    let key_body: Value = key_resp.json().await.expect("key response not JSON");
    let search_key = key_body["key"]
        .as_str()
        .expect("key response should contain 'key'");

    // Push documents directly to flapjack using the search key
    let docs = json!([
        {"id": "doc1", "title": "Rust Programming Language", "body": "Systems programming"},
        {"id": "doc2", "title": "TypeScript Handbook", "body": "JavaScript with types"},
        {"id": "doc3", "title": "Rust Async Book", "body": "Futures and async/await in Rust"}
    ]);

    let ingest_resp = client
        .post(format!("{fj_base}/1/indexes/{index_name}/documents"))
        .header("X-Algolia-API-Key", search_key)
        .json(&docs)
        .send()
        .await
        .expect("document ingest request failed");

    // Flapjack may return 200 or 202 for async indexing
    let ingest_status = ingest_resp.status().as_u16();
    assert!(
        (200..300).contains(&ingest_status),
        "document ingest should succeed, got {ingest_status}"
    );

    // Poll search until the expected documents are visible to avoid fixed delays.
    let search_body = retry_with_delay(15, Duration::from_millis(75), || async {
        let search_resp = client
            .post(format!("{base}/indexes/{index_name}/search"))
            .bearer_auth(&token)
            .json(&json!({"query": "Rust"}))
            .send()
            .await
            .map_err(|e| format!("search request failed: {e}"))?;
        let search_status = search_resp.status().as_u16();
        let search_body: Value = search_resp
            .json()
            .await
            .map_err(|e| format!("search response not JSON: {e}"))?;

        if search_status != 200 {
            return Err(format!(
                "search should return 200, got {search_status}: {search_body}"
            ));
        }

        assert_search_hits_contain_titles(
            &search_body,
            &["Rust Programming Language", "Rust Async Book"],
        )
        .map_err(|e| format!("search results validation failed: {e}; body={search_body}"))?;
        Ok(search_body)
    })
    .await
    .unwrap_or_else(|e| panic!("search never became consistent: {e}"));

    // assert_search_hits_contain_titles is already validated inside retry_with_delay;
    // verify we got a non-null result as a final sanity check.
    assert!(
        search_body["hits"].is_array(),
        "final search_body should contain hits array"
    );
});

integration_test!(integration_flapjack_proxy_delete_index, async {
    let client = http_client();
    let base = api_base();
    let email = unique_email("proxy-delete");
    let index_name = unique_index_name("del-idx");

    seed_shared_vm("us-east-1").await;
    let token = register_and_login(&client, &base, &email).await;

    // Create index
    let create_resp = create_index_via_api(&client, &base, &token, &index_name, "us-east-1").await;
    assert_eq!(create_resp.status().as_u16(), 201);

    // Verify it appears in the list
    let list_resp = client
        .get(format!("{base}/indexes"))
        .bearer_auth(&token)
        .send()
        .await
        .expect("list indexes request failed");
    let list_body: Value = list_resp.json().await.expect("list response not JSON");
    let indexes = list_body.as_array().expect("list should be an array");
    assert!(
        indexes
            .iter()
            .any(|idx| idx["name"].as_str() == Some(&index_name)),
        "created index should appear in list"
    );

    // Delete index
    let del_resp = delete_index_via_api(&client, &base, &token, &index_name).await;
    assert!(
        del_resp.status().is_success(),
        "DELETE /indexes/{index_name} should succeed"
    );

    // Verify it no longer appears in the list
    let list_resp2 = client
        .get(format!("{base}/indexes"))
        .bearer_auth(&token)
        .send()
        .await
        .expect("list indexes request failed after delete");
    let list_body2: Value = list_resp2.json().await.expect("list response not JSON");
    let indexes2 = list_body2.as_array().expect("list should be an array");
    assert!(
        !indexes2
            .iter()
            .any(|idx| idx["name"].as_str() == Some(&index_name)),
        "deleted index should NOT appear in list"
    );
});

// ===========================================================================
// API Key Propagation (TDD)
// ===========================================================================

integration_test!(integration_flapjack_proxy_create_search_key, async {
    let client = http_client();
    let base = api_base();
    let email = unique_email("proxy-key");
    let index_name = unique_index_name("key-idx");

    seed_shared_vm("us-east-1").await;
    let token = register_and_login(&client, &base, &email).await;

    // Create index first
    let create_resp = create_index_via_api(&client, &base, &token, &index_name, "us-east-1").await;
    assert_eq!(create_resp.status().as_u16(), 201);

    // Create a search key
    let key_resp = client
        .post(format!("{base}/indexes/{index_name}/keys"))
        .bearer_auth(&token)
        .json(&json!({
            "description": "test search key",
            "acl": ["search"]
        }))
        .send()
        .await
        .expect("create key request failed");

    assert_eq!(
        key_resp.status().as_u16(),
        201,
        "key creation should return 201"
    );
    let key_body: Value = key_resp.json().await.expect("key response not JSON");
    let key = key_body["key"]
        .as_str()
        .expect("response should contain 'key'");
    assert!(!key.is_empty(), "returned key should be non-empty");
    assert!(
        key_body["createdAt"].as_str().is_some(),
        "response should contain 'createdAt'"
    );
});

integration_test!(
    integration_flapjack_proxy_key_authorizes_flapjack_search,
    async {
        let client = http_client();
        let base = api_base();
        let fj_base = flapjack_base();
        let email = unique_email("proxy-keyauth");
        let index_name = unique_index_name("keyauth-idx");

        seed_shared_vm("us-east-1").await;
        let token = register_and_login(&client, &base, &email).await;

        // Create index + search key
        let create_resp =
            create_index_via_api(&client, &base, &token, &index_name, "us-east-1").await;
        assert_eq!(create_resp.status().as_u16(), 201);

        let key_resp = client
            .post(format!("{base}/indexes/{index_name}/keys"))
            .bearer_auth(&token)
            .json(&json!({
                "description": "direct flapjack test key",
                "acl": ["search"]
            }))
            .send()
            .await
            .expect("create key request failed");
        assert_eq!(key_resp.status().as_u16(), 201);
        let key_body: Value = key_resp.json().await.unwrap();
        let search_key = key_body["key"].as_str().unwrap();

        // Use key directly against flapjack's search endpoint
        let fj_search = client
            .post(format!("{fj_base}/1/indexes/{index_name}/query"))
            .header("X-Algolia-API-Key", search_key)
            .json(&json!({"query": "", "hitsPerPage": 1}))
            .send()
            .await
            .expect("direct flapjack search request failed");

        assert!(
            fj_search.status().is_success(),
            "search with valid key should succeed against flapjack, got {}",
            fj_search.status()
        );
    }
);

integration_test!(integration_flapjack_proxy_bogus_key_rejected, async {
    let client = http_client();
    let fj_base = flapjack_base();

    // Try to search flapjack with a completely bogus key
    let resp = client
        .post(format!("{fj_base}/1/indexes/nonexistent/query"))
        .header("X-Algolia-API-Key", "bogus-invalid-key-12345")
        .json(&json!({"query": "test"}))
        .send()
        .await
        .expect("bogus key request failed");

    let status = resp.status().as_u16();
    // Flapjack should reject with 401 or 403
    assert!(
        status == 401 || status == 403,
        "flapjack should reject bogus key with 401/403, got {status}"
    );
});

// ===========================================================================
// Settings Propagation (TDD)
// ===========================================================================

integration_test!(integration_flapjack_proxy_update_settings, async {
    let client = http_client();
    let base = api_base();
    let email = unique_email("proxy-settings");
    let index_name = unique_index_name("settings-idx");

    seed_shared_vm("us-east-1").await;
    let token = register_and_login(&client, &base, &email).await;

    // Create index
    let create_resp = create_index_via_api(&client, &base, &token, &index_name, "us-east-1").await;
    assert_eq!(create_resp.status().as_u16(), 201);

    // Update settings via fjcloud API
    let settings_payload = json!({
        "searchableAttributes": ["title", "body"],
        "displayedAttributes": ["title", "body", "id"]
    });

    let update_resp = client
        .put(format!("{base}/indexes/{index_name}/settings"))
        .bearer_auth(&token)
        .json(&settings_payload)
        .send()
        .await
        .expect("update settings request failed");

    assert!(
        update_resp.status().is_success(),
        "PUT /indexes/{index_name}/settings should succeed, got {}",
        update_resp.status()
    );
});

integration_test!(
    integration_flapjack_proxy_read_settings_after_update,
    async {
        let client = http_client();
        let base = api_base();
        let email = unique_email("proxy-readset");
        let index_name = unique_index_name("readset-idx");

        seed_shared_vm("us-east-1").await;
        let token = register_and_login(&client, &base, &email).await;

        // Create index
        let create_resp =
            create_index_via_api(&client, &base, &token, &index_name, "us-east-1").await;
        assert_eq!(create_resp.status().as_u16(), 201);

        // Update settings
        let settings_payload = json!({
            "searchableAttributes": ["title", "description"]
        });
        let update_resp = client
            .put(format!("{base}/indexes/{index_name}/settings"))
            .bearer_auth(&token)
            .json(&settings_payload)
            .send()
            .await
            .expect("update settings request failed");
        assert!(update_resp.status().is_success());

        // Read settings back and verify
        let get_resp = client
            .get(format!("{base}/indexes/{index_name}/settings"))
            .bearer_auth(&token)
            .send()
            .await
            .expect("get settings request failed");
        assert_eq!(
            get_resp.status().as_u16(),
            200,
            "GET settings should return 200"
        );

        let settings: Value = get_resp.json().await.expect("settings response not JSON");
        // Verify the setting we wrote is present
        let searchable = &settings["searchableAttributes"];
        assert!(
            searchable.is_array(),
            "searchableAttributes should be an array in returned settings: {settings}"
        );
        let searchable_arr: Vec<&str> = searchable
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|v| v.as_str())
            .collect();
        assert!(
        searchable_arr.contains(&"title") && searchable_arr.contains(&"description"),
        "searchableAttributes should contain 'title' and 'description', got: {searchable_arr:?}"
    );
    }
);

integration_test!(
    integration_flapjack_proxy_invalid_settings_rejected,
    async {
        let client = http_client();
        let base = api_base();
        let email = unique_email("proxy-badset");
        let index_name = unique_index_name("badset-idx");

        seed_shared_vm("us-east-1").await;
        let token = register_and_login(&client, &base, &email).await;

        // Create index
        let create_resp =
            create_index_via_api(&client, &base, &token, &index_name, "us-east-1").await;
        assert_eq!(create_resp.status().as_u16(), 201);

        // Set known-good settings first so we can verify they survive the bad request
        let good_settings = json!({
            "searchableAttributes": ["title", "body"]
        });
        let good_resp = client
            .put(format!("{base}/indexes/{index_name}/settings"))
            .bearer_auth(&token)
            .json(&good_settings)
            .send()
            .await
            .expect("good settings request failed");
        assert!(
            good_resp.status().is_success(),
            "initial good settings PUT should succeed, got {}",
            good_resp.status()
        );

        // Send invalid settings (wrong type for a known field)
        let bad_settings = json!({
            "searchableAttributes": "not-an-array"
        });

        let resp = client
            .put(format!("{base}/indexes/{index_name}/settings"))
            .bearer_auth(&token)
            .json(&bad_settings)
            .send()
            .await
            .expect("bad settings request failed");

        let status = resp.status().as_u16();
        assert!(
            (400..500).contains(&status),
            "invalid settings should return 4xx, got {status}"
        );

        // Verify settings were NOT mutated — should still match the good settings
        let get_resp = client
            .get(format!("{base}/indexes/{index_name}/settings"))
            .bearer_auth(&token)
            .send()
            .await
            .expect("get settings after bad request failed");
        assert_eq!(get_resp.status().as_u16(), 200);

        let current: Value = get_resp.json().await.expect("settings response not JSON");
        assert_exact_string_array(&current, "searchableAttributes", &["title", "body"])
            .expect("settings should be unchanged after invalid request");
    }
);

// ===========================================================================
// Cross-Tenant Isolation on Real Stack (TDD)
// ===========================================================================

integration_test!(integration_flapjack_proxy_tenant_isolation_read, async {
    let client = http_client();
    let base = api_base();
    let email_a = unique_email("iso-a");
    let email_b = unique_email("iso-b");
    let index_name = unique_index_name("shared-name");

    seed_shared_vm("us-east-1").await;

    let token_a = register_and_login(&client, &base, &email_a).await;
    let token_b = register_and_login(&client, &base, &email_b).await;

    // Tenant A creates an index
    let resp_a = create_index_via_api(&client, &base, &token_a, &index_name, "us-east-1").await;
    assert_eq!(
        resp_a.status().as_u16(),
        201,
        "tenant A should create index"
    );

    // Tenant B should NOT see tenant A's index
    let get_resp = client
        .get(format!("{base}/indexes/{index_name}"))
        .bearer_auth(&token_b)
        .send()
        .await
        .expect("get index request failed");

    assert_eq!(
        get_resp.status().as_u16(),
        404,
        "tenant B should get 404 for tenant A's index"
    );

    // Tenant B cannot search tenant A's index
    let search_resp = client
        .post(format!("{base}/indexes/{index_name}/search"))
        .bearer_auth(&token_b)
        .json(&json!({"query": "test"}))
        .send()
        .await
        .expect("search request failed");

    assert_eq!(
        search_resp.status().as_u16(),
        404,
        "tenant B should get 404 searching tenant A's index"
    );

    // Tenant B cannot delete tenant A's index
    let del_resp = delete_index_via_api(&client, &base, &token_b, &index_name).await;
    assert_eq!(
        del_resp.status().as_u16(),
        404,
        "tenant B should get 404 deleting tenant A's index"
    );
});

integration_test!(
    integration_flapjack_proxy_tenant_independent_indexes,
    async {
        let client = http_client();
        let base = api_base();
        let email_a = unique_email("indep-a");
        let email_b = unique_email("indep-b");
        // Same index name for both tenants
        let index_name = unique_index_name("products");

        seed_shared_vm("us-east-1").await;

        let token_a = register_and_login(&client, &base, &email_a).await;
        let token_b = register_and_login(&client, &base, &email_b).await;

        // Both tenants create an index with the same name
        let resp_a = create_index_via_api(&client, &base, &token_a, &index_name, "us-east-1").await;
        assert_eq!(
            resp_a.status().as_u16(),
            201,
            "tenant A should create index"
        );

        let resp_b = create_index_via_api(&client, &base, &token_b, &index_name, "us-east-1").await;
        assert_eq!(
            resp_b.status().as_u16(),
            201,
            "tenant B should also create same-named index"
        );

        // Both tenants see only their own index in listings
        let list_a = client
            .get(format!("{base}/indexes"))
            .bearer_auth(&token_a)
            .send()
            .await
            .expect("list indexes A failed");
        let list_a_body: Value = list_a.json().await.unwrap();
        let list_a_arr = list_a_body.as_array().expect("list A should be array");
        assert_eq!(
            list_a_arr.len(),
            1,
            "tenant A should see exactly 1 index, got {}",
            list_a_arr.len()
        );
        assert_eq!(list_a_arr[0]["name"].as_str().unwrap(), index_name);

        let list_b = client
            .get(format!("{base}/indexes"))
            .bearer_auth(&token_b)
            .send()
            .await
            .expect("list indexes B failed");
        let list_b_body: Value = list_b.json().await.unwrap();
        let list_b_arr = list_b_body.as_array().expect("list B should be array");
        assert_eq!(
            list_b_arr.len(),
            1,
            "tenant B should see exactly 1 index, got {}",
            list_b_arr.len()
        );
        assert_eq!(list_b_arr[0]["name"].as_str().unwrap(), index_name);

        // Deleting tenant A's index does not affect tenant B
        let del_a = delete_index_via_api(&client, &base, &token_a, &index_name).await;
        assert!(
            del_a.status().is_success(),
            "tenant A delete should succeed"
        );

        let list_b_after = client
            .get(format!("{base}/indexes"))
            .bearer_auth(&token_b)
            .send()
            .await
            .expect("list indexes B after A delete failed");
        let list_b_after_body: Value = list_b_after.json().await.unwrap();
        let list_b_after_arr = list_b_after_body.as_array().unwrap();
        assert_eq!(
            list_b_after_arr.len(),
            1,
            "tenant B should still see 1 index after tenant A deletes theirs"
        );
    }
);

#[test]
fn search_hits_validation_rejects_empty_hits() {
    let body = json!({
        "hits": []
    });

    let err = assert_search_hits_contain_titles(&body, &["Rust Programming Language"])
        .expect_err("empty search hits should be rejected");
    assert!(
        err.contains("empty hits"),
        "error should mention empty hits, got: {err}"
    );
}

#[test]
fn search_hits_validation_requires_expected_titles() {
    let body = json!({
        "hits": [
            {"id": "doc1", "title": "TypeScript Handbook"}
        ]
    });

    let err = assert_search_hits_contain_titles(&body, &["Rust Programming Language"])
        .expect_err("missing expected title should fail");
    assert!(
        err.contains("missing expected title"),
        "error should mention missing expected title, got: {err}"
    );
}
