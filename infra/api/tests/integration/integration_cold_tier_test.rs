// Integration tests for cold-tier lifecycle against S3-compatible cold storage.
//
// This test is intentionally gated:
// - INTEGRATION=1 (integration stack enabled)
// - COLD_STORAGE_ENDPOINT set and reachable
// - live API + flapjack endpoints reachable
//
// It validates a snapshot/restore round-trip using real HTTP paths and real DB state.

use crate::common::integration_helpers::{
    api_base, db_url, endpoint_reachable, flapjack_base, http_client, register_and_login,
};
use serde_json::json;
use sha2::Digest;
use uuid::Uuid;

fn unique_email(prefix: &str) -> String {
    let id = Uuid::new_v4().to_string();
    format!("{prefix}-{}@integration-test.local", &id[..8])
}

fn unique_index(prefix: &str) -> String {
    let id = Uuid::new_v4().to_string();
    format!("{prefix}-{}", &id[..8])
}

fn cold_storage_endpoint() -> Option<String> {
    cold_storage_config_from_env().endpoint
}

// The live integration path still reads COLD_STORAGE_* from the process env via
// cold_storage_config_from_env(); helper tests bypass the env entirely and supply
// values directly through cold_storage_config_from().

fn cold_storage_region() -> String {
    cold_storage_config_from_env().region
}

fn cold_storage_bucket() -> String {
    cold_storage_config_from_env().bucket
}

fn cold_storage_access_key() -> Option<String> {
    cold_storage_config_from_env().access_key
}

fn cold_storage_secret_key() -> Option<String> {
    cold_storage_config_from_env().secret_key
}

#[derive(Debug, PartialEq, Eq)]
struct ColdStorageConfig {
    endpoint: Option<String>,
    region: String,
    bucket: String,
    access_key: Option<String>,
    secret_key: Option<String>,
}

fn cold_storage_config_from_env() -> ColdStorageConfig {
    let endpoint = std::env::var("COLD_STORAGE_ENDPOINT").ok();
    let region = std::env::var("COLD_STORAGE_REGION").ok();
    let bucket = std::env::var("COLD_STORAGE_BUCKET").ok();
    let access_key = std::env::var("COLD_STORAGE_ACCESS_KEY").ok();
    let secret_key = std::env::var("COLD_STORAGE_SECRET_KEY").ok();

    cold_storage_config_from(
        endpoint.as_deref(),
        region.as_deref(),
        bucket.as_deref(),
        access_key.as_deref(),
        secret_key.as_deref(),
    )
}

/// Test-local mirror of `S3ObjectStoreConfig::from_env()`'s mapping rules.
///
/// The defaults below ("us-east-1", "fjcloud-cold") and the COLD_STORAGE_* names
/// read by `cold_storage_config_from_env()` duplicate the canonical owner,
/// `S3ObjectStoreConfig::from_env()` in `api/src/services/object_store.rs`, and
/// must stay in sync with it. This mirror exists so the helper tests can exercise
/// the mapping without mutating process env — env mutation here previously raced
/// the `--test platform storage` selection. The canonical parser's own env
/// contract is asserted in `object_store_test.rs`
/// (`s3_object_store_with_custom_endpoint_configures_correctly`,
/// `s3_object_store_default_uses_aws`), which is the sole env-mutating owner.
fn cold_storage_config_from(
    endpoint: Option<&str>,
    region: Option<&str>,
    bucket: Option<&str>,
    access_key: Option<&str>,
    secret_key: Option<&str>,
) -> ColdStorageConfig {
    ColdStorageConfig {
        endpoint: endpoint.map(str::to_string),
        region: region.unwrap_or("us-east-1").to_string(),
        bucket: bucket.unwrap_or("fjcloud-cold").to_string(),
        access_key: access_key.map(str::to_string),
        secret_key: secret_key.map(str::to_string),
    }
}

fn flapjack_admin_key() -> String {
    std::env::var("FLAPJACK_ADMIN_KEY")
        .unwrap_or_else(|_| "fj_local_dev_admin_key_000000000000".to_string())
}

fn admin_key() -> String {
    std::env::var("ADMIN_KEY").unwrap_or_else(|_| "local-dev-admin-key".to_string())
}

fn flapjack_index_uid(customer_id: Uuid, index_name: &str) -> String {
    format!("{}_{}", customer_id.as_simple(), index_name)
}

async fn ensure_seed_vm_secret(
    client: &reqwest::Client,
    api_base: &str,
    customer_id: Uuid,
    flapjack_url: &str,
) {
    let seed_name = unique_index("cold-tier-secret-prime");
    let resp = client
        .post(format!("{api_base}/admin/tenants/{customer_id}/indexes"))
        .header("x-admin-key", admin_key())
        .json(&json!({
            "name": seed_name,
            "region": "us-east-1",
            "flapjack_url": flapjack_url
        }))
        .send()
        .await
        .expect("admin seed index request failed");
    assert!(
        resp.status().is_success(),
        "admin seed index should prime shared VM secret: {}",
        resp.text().await.unwrap_or_default()
    );
}

async fn build_s3_client(endpoint: &str, region: &str) -> aws_sdk_s3::Client {
    let config = aws_config::defaults(aws_config::BehaviorVersion::latest())
        .region(aws_sdk_s3::config::Region::new(region.to_string()))
        .load()
        .await;

    let mut s3_config_builder = aws_sdk_s3::config::Builder::from(&config)
        .endpoint_url(endpoint)
        .force_path_style(true);

    if let (Some(access_key), Some(secret_key)) =
        (cold_storage_access_key(), cold_storage_secret_key())
    {
        let credentials = aws_sdk_s3::config::Credentials::new(
            access_key,
            secret_key,
            None,
            None,
            "cold-storage-integration-env",
        );
        s3_config_builder = s3_config_builder.credentials_provider(credentials);
    }

    aws_sdk_s3::Client::from_conf(s3_config_builder.build())
}

async fn ensure_bucket_exists(client: &aws_sdk_s3::Client, bucket: &str) -> Result<(), String> {
    match client.create_bucket().bucket(bucket).send().await {
        Ok(_) => Ok(()),
        Err(err) => {
            let msg = err.to_string();
            let create_reported_existing_bucket =
                msg.contains("BucketAlreadyOwnedByYou") || msg.contains("BucketAlreadyExists");
            // Some S3-compatible stores report existing buckets differently, so
            // fall back to a HEAD check before treating create_bucket as fatal.
            let bucket_exists = create_reported_existing_bucket
                || client.head_bucket().bucket(bucket).send().await.is_ok();
            if bucket_exists {
                Ok(())
            } else {
                Err(format!(
                    "failed to create or verify cold storage bucket '{bucket}': {msg}"
                ))
            }
        }
    }
}

/// Polls restore-status until "completed" or a 20s deadline expires.
/// Uses bounded polling (250ms intervals + deadline) instead of fixed sleeps
/// to avoid flakiness while keeping the timeout deterministic.
async fn wait_for_restore_completed(
    client: &reqwest::Client,
    api_base: &str,
    token: &str,
    index_name: &str,
) -> Result<(), String> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    while std::time::Instant::now() < deadline {
        let resp = client
            .get(format!("{api_base}/indexes/{index_name}/restore-status"))
            .bearer_auth(token)
            .send()
            .await
            .map_err(|e| format!("restore-status request failed: {e}"))?;

        if !resp.status().is_success() {
            return Err(format!("restore-status returned {}", resp.status()));
        }
        let body: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| format!("restore-status body parse failed: {e}"))?;
        if body["status"] == "completed" {
            return Ok(());
        }

        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
    }
    Err("restore did not complete within timeout".to_string())
}

/// Polls search until the expected document title appears or a 20s deadline expires.
/// Bounded polling (250ms intervals + deadline) avoids flaky fixed sleeps.
async fn wait_for_search_hit(
    client: &reqwest::Client,
    api_base: &str,
    token: &str,
    index_name: &str,
    expected_title: &str,
) -> Result<(), String> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    while std::time::Instant::now() < deadline {
        let resp = client
            .post(format!("{api_base}/indexes/{index_name}/search"))
            .bearer_auth(token)
            .json(&json!({ "query": expected_title }))
            .send()
            .await
            .map_err(|e| format!("search request failed: {e}"))?;

        if resp.status().is_success() {
            let body: serde_json::Value = resp
                .json()
                .await
                .map_err(|e| format!("search body parse failed: {e}"))?;
            let has_hit = body["hits"]
                .as_array()
                .is_some_and(|hits| hits.iter().any(|hit| hit["title"] == expected_title));
            if has_hit {
                return Ok(());
            }
        }

        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
    }
    Err("search did not return expected hit within timeout".to_string())
}

async fn seed_shared_vm(
    pool: &sqlx::PgPool,
    region: &str,
    flapjack_url: &str,
) -> Result<Uuid, String> {
    let vm_id = Uuid::new_v4();
    let hostname = format!("cold-tier-vm-{}", &vm_id.to_string()[..8]);

    sqlx::query(
        "INSERT INTO vm_inventory (id, provider, region, hostname, flapjack_url, status, capacity, current_load, load_scraped_at, created_at, updated_at)
         VALUES ($1, 'bare_metal', $2, $3, $4, 'active',
                 '{\"cpu_weight\": 8.0, \"mem_rss_bytes\": 34359738368, \"disk_bytes\": 536870912000, \"query_rps\": 1000.0, \"indexing_rps\": 1000.0}',
                 '{\"cpu_weight\": 0.0, \"mem_rss_bytes\": 0, \"disk_bytes\": 0, \"query_rps\": 0.0, \"indexing_rps\": 0.0}',
                 NOW(), NOW(), NOW())
         ON CONFLICT (id) DO NOTHING",
    )
    .bind(vm_id)
    .bind(region)
    .bind(&hostname)
    .bind(flapjack_url)
    .execute(pool)
    .await
    .map_err(|e| format!("failed to seed VM: {e}"))?;

    Ok(vm_id)
}

// LIVE integration test: exercises real HTTP + DB + S3 round-trip.
// Requires INTEGRATION=1 and a running stack (API, flapjack, SeaweedFS/S3, Postgres).
// For the fast in-memory unit tests of cold-tier logic, see cold_tier_test.rs.
crate::integration_test!(cold_tier_full_lifecycle_s3_round_trip, async {
    let client = http_client();
    let base = api_base();
    let flapjack = flapjack_base();

    crate::require_live!(
        endpoint_reachable(&base).await,
        "API endpoint unreachable for cold-tier test"
    );
    crate::require_live!(
        endpoint_reachable(&flapjack).await,
        "flapjack endpoint unreachable for cold-tier test"
    );
    crate::require_live!(
        cold_storage_endpoint().is_some(),
        "COLD_STORAGE_ENDPOINT env var is not set"
    );
    let endpoint = cold_storage_endpoint().unwrap();
    crate::require_live!(
        endpoint_reachable(&endpoint).await,
        "cold storage endpoint unreachable for cold-tier test"
    );

    let region = cold_storage_region();
    let bucket = cold_storage_bucket();
    let s3_client = build_s3_client(&endpoint, &region).await;
    ensure_bucket_exists(&s3_client, &bucket)
        .await
        .expect("cold storage bucket setup failed");

    let pool = sqlx::PgPool::connect(&db_url())
        .await
        .expect("failed to connect to integration database");

    let _vm_id = seed_shared_vm(&pool, "us-east-1", &flapjack)
        .await
        .expect("failed to seed shared VM");

    let email = unique_email("cold-tier");
    let token = register_and_login(&client, &base, &email).await;

    let customer_id: Uuid = sqlx::query_scalar("SELECT id FROM customers WHERE email = $1")
        .bind(&email)
        .fetch_one(&pool)
        .await
        .expect("failed to resolve customer id");

    let index_name = unique_index("cold-tier");

    let create_resp = client
        .post(format!("{base}/indexes"))
        .bearer_auth(&token)
        .json(&json!({ "name": index_name, "region": "us-east-1" }))
        .send()
        .await
        .expect("create index request failed");
    assert!(
        create_resp.status().is_success(),
        "create index failed: {}",
        create_resp.text().await.unwrap_or_default()
    );

    ensure_seed_vm_secret(&client, &base, customer_id, &flapjack).await;

    let insert_resp = client
        .post(format!("{base}/indexes/{index_name}/batch"))
        .bearer_auth(&token)
        .json(&json!({
            "requests": [
                {
                    "action": "addObject",
                    "body": { "objectID": "1", "title": "cold restore widget", "price": 9.99 }
                }
            ]
        }))
        .send()
        .await
        .expect("insert objects request failed");
    assert!(
        insert_resp.status().is_success(),
        "insert objects failed: {}",
        insert_resp.text().await.unwrap_or_default()
    );

    wait_for_search_hit(&client, &base, &token, &index_name, "cold restore widget")
        .await
        .expect("pre-snapshot search should return seeded document");

    let source_vm_id: Uuid = sqlx::query_scalar(
        "SELECT vm_id FROM customer_tenants WHERE customer_id = $1 AND tenant_id = $2",
    )
    .bind(customer_id)
    .bind(&index_name)
    .fetch_one(&pool)
    .await
    .expect("expected source vm_id on active tenant");

    let flapjack_uid = flapjack_index_uid(customer_id, &index_name);
    let export_resp = client
        .get(format!("{flapjack}/1/indexes/{flapjack_uid}/export"))
        .header("X-Algolia-API-Key", flapjack_admin_key())
        .header("X-Algolia-Application-Id", "flapjack")
        .send()
        .await
        .expect("flapjack export request failed");
    assert_eq!(
        export_resp.status().as_u16(),
        200,
        "flapjack export should succeed"
    );
    let export_bytes = export_resp
        .bytes()
        .await
        .expect("failed to read export bytes")
        .to_vec();
    assert!(
        !export_bytes.is_empty(),
        "flapjack export should produce non-empty snapshot bytes"
    );

    let snapshot_id = Uuid::new_v4();
    let object_key = format!(
        "cold/us-east-1/{}/{}/{}.fj",
        customer_id, index_name, snapshot_id
    );
    s3_client
        .put_object()
        .bucket(&bucket)
        .key(&object_key)
        .body(aws_sdk_s3::primitives::ByteStream::from(
            export_bytes.clone(),
        ))
        .send()
        .await
        .expect("failed to upload snapshot to S3 cold storage");

    let checksum = hex::encode(sha2::Sha256::digest(&export_bytes));
    sqlx::query(
        "INSERT INTO cold_snapshots
         (id, customer_id, tenant_id, source_vm_id, object_key, size_bytes, checksum, status, completed_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7, 'completed', NOW())",
    )
    .bind(snapshot_id)
    .bind(customer_id)
    .bind(&index_name)
    .bind(source_vm_id)
    .bind(&object_key)
    .bind(export_bytes.len() as i64)
    .bind(&checksum)
    .execute(&pool)
    .await
    .expect("failed to insert completed snapshot record");

    sqlx::query(
        "UPDATE customer_tenants
         SET tier = 'cold',
             cold_snapshot_id = $3,
             vm_id = NULL,
             last_accessed_at = NOW() - INTERVAL '31 days'
         WHERE customer_id = $1 AND tenant_id = $2",
    )
    .bind(customer_id)
    .bind(&index_name)
    .bind(snapshot_id)
    .execute(&pool)
    .await
    .expect("failed to mark tenant as cold");

    let delete_resp = client
        .delete(format!("{flapjack}/1/indexes/{flapjack_uid}"))
        .header("X-Algolia-API-Key", flapjack_admin_key())
        .header("X-Algolia-Application-Id", "flapjack")
        .send()
        .await
        .expect("flapjack delete request failed");
    assert!(
        delete_resp.status().is_success(),
        "flapjack delete should succeed before restore"
    );

    let cold_search_resp = client
        .post(format!("{base}/indexes/{index_name}/search"))
        .bearer_auth(&token)
        .json(&json!({ "query": "cold restore widget" }))
        .send()
        .await
        .expect("cold-tier query request failed");
    assert_eq!(
        cold_search_resp.status().as_u16(),
        410,
        "cold index search should return 410 with restore instructions"
    );

    let restore_resp = client
        .post(format!("{base}/indexes/{index_name}/restore"))
        .bearer_auth(&token)
        .send()
        .await
        .expect("restore request failed");
    assert_eq!(
        restore_resp.status().as_u16(),
        202,
        "restore initiation should return 202"
    );

    wait_for_restore_completed(&client, &base, &token, &index_name)
        .await
        .expect("restore should complete");

    wait_for_search_hit(&client, &base, &token, &index_name, "cold restore widget")
        .await
        .expect("restored index should be searchable");

    let (tier, vm_id, cold_snapshot_id): (String, Option<Uuid>, Option<Uuid>) = sqlx::query_as(
        "SELECT tier, vm_id, cold_snapshot_id
         FROM customer_tenants
         WHERE customer_id = $1 AND tenant_id = $2",
    )
    .bind(customer_id)
    .bind(&index_name)
    .fetch_one(&pool)
    .await
    .expect("failed to fetch tenant row after restore");

    assert_eq!(tier, "active");
    assert!(vm_id.is_some(), "tenant should be re-assigned to a VM");
    assert!(
        cold_snapshot_id.is_none(),
        "cold_snapshot_id should be cleared after successful restore"
    );

    let head_resp = s3_client
        .head_object()
        .bucket(&bucket)
        .key(&object_key)
        .send()
        .await;
    assert!(
        head_resp.is_ok(),
        "snapshot object should remain in S3 after restore"
    );
});

#[cfg(test)]
mod helper_tests {
    use super::cold_storage_config_from;

    // The `*_reads_env` names are historical: these tests now exercise the pure
    // mapper and read no process env. They are deliberately NOT renamed here —
    // `cold_storage_endpoint_reads_env` is the verbatim referent of the open P2
    // row at `ROADMAP.md:177`, which FS-9 owns and matches by title. Rename them
    // together with that row's closure, not before.

    #[test]
    fn cold_storage_endpoint_reads_env() {
        let config =
            cold_storage_config_from(Some("http://localhost:8333"), None, None, None, None);
        assert_eq!(config.endpoint, Some("http://localhost:8333".to_string()));

        let config = cold_storage_config_from(None, None, None, None, None);
        assert_eq!(config.endpoint, None);
    }

    #[test]
    fn cold_storage_bucket_defaults_to_fjcloud_cold() {
        let config = cold_storage_config_from(None, None, None, None, None);
        assert_eq!(config.bucket, "fjcloud-cold");

        let config = cold_storage_config_from(None, None, Some("custom-bucket"), None, None);
        assert_eq!(config.bucket, "custom-bucket");
    }

    #[test]
    fn cold_storage_access_key_reads_env() {
        let config = cold_storage_config_from(None, None, None, Some("local-key"), None);
        assert_eq!(config.access_key, Some("local-key".to_string()));

        let config = cold_storage_config_from(None, None, None, None, None);
        assert_eq!(config.access_key, None);
    }

    #[test]
    fn cold_storage_region_defaults_to_us_east_1() {
        let config = cold_storage_config_from(None, None, None, None, None);
        assert_eq!(config.region, "us-east-1");

        let config = cold_storage_config_from(None, Some("eu-central-1"), None, None, None);
        assert_eq!(config.region, "eu-central-1");
    }

    #[test]
    fn cold_storage_secret_key_passes_through_and_defaults_to_none() {
        let config = cold_storage_config_from(None, None, None, None, Some("local-secret"));
        assert_eq!(config.secret_key, Some("local-secret".to_string()));

        let config = cold_storage_config_from(None, None, None, None, None);
        assert_eq!(config.secret_key, None);
    }

    /// Each field must come from its own argument — a positional swap between the
    /// five same-typed `Option<&str>` parameters would otherwise go undetected.
    #[test]
    fn cold_storage_config_from_maps_each_argument_to_its_own_field() {
        let config = cold_storage_config_from(
            Some("http://endpoint"),
            Some("region-value"),
            Some("bucket-value"),
            Some("access-value"),
            Some("secret-value"),
        );

        assert_eq!(config.endpoint, Some("http://endpoint".to_string()));
        assert_eq!(config.region, "region-value");
        assert_eq!(config.bucket, "bucket-value");
        assert_eq!(config.access_key, Some("access-value".to_string()));
        assert_eq!(config.secret_key, Some("secret-value".to_string()));
    }
}
