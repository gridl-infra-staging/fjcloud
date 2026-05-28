// Integration tests for ObjectStore trait against a live Garage S3 API.
//
// Gated on three env vars — tests skip when any is unset:
//   GARAGE_ENDPOINT   — Garage S3 API (e.g. http://127.0.0.1:3900)
//   GARAGE_S3_ACCESS_KEY — Garage S3 access key
//   GARAGE_S3_SECRET_KEY — Garage S3 secret key
//
// Optional:
//   GARAGE_REGION — defaults to "garage"
//   GARAGE_BUCKET — defaults to "cold-storage"
//
// Run:
//   GARAGE_ENDPOINT=http://127.0.0.1:3900 \
//   GARAGE_S3_ACCESS_KEY=<key> GARAGE_S3_SECRET_KEY=<secret> \
//   cargo test -p api --test garage_object_store_test

use api::services::object_store::{ObjectStore, ObjectStoreError, S3ObjectStoreConfig};
use sha2::{Digest, Sha256};
use std::sync::Arc;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Env-var helpers and gating
// ---------------------------------------------------------------------------

fn garage_endpoint() -> Option<String> {
    std::env::var("GARAGE_ENDPOINT").ok()
}

fn garage_region() -> String {
    std::env::var("GARAGE_REGION").unwrap_or_else(|_| "garage".to_string())
}

fn garage_bucket() -> String {
    std::env::var("GARAGE_BUCKET").unwrap_or_else(|_| "cold-storage".to_string())
}

fn garage_access_key() -> Option<String> {
    std::env::var("GARAGE_S3_ACCESS_KEY")
        .ok()
        .or_else(|| std::env::var("AWS_ACCESS_KEY_ID").ok())
}

fn garage_secret_key() -> Option<String> {
    std::env::var("GARAGE_S3_SECRET_KEY")
        .ok()
        .or_else(|| std::env::var("AWS_SECRET_ACCESS_KEY").ok())
}

fn garage_available() -> bool {
    garage_endpoint().is_some() && garage_access_key().is_some() && garage_secret_key().is_some()
}

/// Build an S3ObjectStore pointed at Garage with a `test/` prefix to isolate
/// test objects from production data.
async fn build_garage_store() -> Arc<dyn ObjectStore + Send + Sync> {
    let config = S3ObjectStoreConfig {
        bucket: garage_bucket(),
        prefix: "test".to_string(),
        region: garage_region(),
        endpoint: garage_endpoint(),
        access_key: garage_access_key(),
        secret_key: garage_secret_key(),
    };
    Arc::new(S3ObjectStoreConfig::build(config).await)
}

/// Build a raw `aws_sdk_s3::Client` for bucket management (the ObjectStore
/// trait does not expose bucket operations).
async fn build_raw_s3_client() -> aws_sdk_s3::Client {
    let endpoint = garage_endpoint().expect("GARAGE_ENDPOINT required");
    let region = garage_region();

    let aws_config = aws_config::defaults(aws_config::BehaviorVersion::latest())
        .region(aws_sdk_s3::config::Region::new(region))
        .load()
        .await;

    let credentials = aws_sdk_s3::config::Credentials::new(
        garage_access_key().expect("GARAGE_S3_ACCESS_KEY required"),
        garage_secret_key().expect("GARAGE_S3_SECRET_KEY required"),
        None,
        None,
        "garage-object-store-test-env",
    );
    let s3_config = aws_sdk_s3::config::Builder::from(&aws_config)
        .endpoint_url(&endpoint)
        .force_path_style(true)
        .credentials_provider(credentials)
        .build();

    aws_sdk_s3::Client::from_conf(s3_config)
}

/// Create the test bucket if it doesn't already exist.
async fn ensure_bucket_exists(client: &aws_sdk_s3::Client, bucket: &str) -> Result<(), String> {
    match client.create_bucket().bucket(bucket).send().await {
        Ok(_) => Ok(()),
        Err(err) => {
            let msg = err.to_string();
            if msg.contains("BucketAlreadyOwnedByYou") || msg.contains("BucketAlreadyExists") {
                Ok(())
            } else {
                Err(format!("failed to create bucket '{bucket}': {msg}"))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn garage_put_get_delete_lifecycle() {
    if !garage_available() {
        eprintln!("[skip] GARAGE_ENDPOINT or AWS credentials not set");
        return;
    }

    let raw_client = build_raw_s3_client().await;
    ensure_bucket_exists(&raw_client, &garage_bucket())
        .await
        .expect("bucket setup failed");

    let store = build_garage_store().await;
    let key = format!("{}.bin", Uuid::new_v4());
    let payload = b"hello-garage-1kb-payload-for-lifecycle-test";

    // PUT
    store.put(&key, payload).await.expect("put should succeed");

    // EXISTS + SIZE
    assert!(
        store.exists(&key).await.expect("exists should succeed"),
        "object should exist after put"
    );
    assert_eq!(
        store.size(&key).await.expect("size should succeed"),
        payload.len() as u64,
        "size should match payload length"
    );

    // GET
    let retrieved = store.get(&key).await.expect("get should succeed");
    assert_eq!(
        retrieved.as_slice(),
        payload,
        "retrieved bytes should match uploaded payload"
    );

    // DELETE
    store.delete(&key).await.expect("delete should succeed");

    assert!(
        !store
            .exists(&key)
            .await
            .expect("exists after delete should succeed"),
        "object should not exist after delete"
    );
    assert!(
        matches!(store.get(&key).await, Err(ObjectStoreError::NotFound(_))),
        "get after delete should return NotFound"
    );
}

#[tokio::test]
async fn garage_cold_tier_key_format() {
    if !garage_available() {
        eprintln!("[skip] GARAGE_ENDPOINT or AWS credentials not set");
        return;
    }

    let raw_client = build_raw_s3_client().await;
    ensure_bucket_exists(&raw_client, &garage_bucket())
        .await
        .expect("bucket setup failed");

    let store = build_garage_store().await;
    let customer_id = Uuid::new_v4();
    let snapshot_id = Uuid::new_v4();
    // Production key format: cold/{region}/{customer_id}/{tenant_id}/{snapshot_uuid}.fj
    let key = format!(
        "cold/us-east-1/{}/my-test-index/{}.fj",
        customer_id, snapshot_id
    );
    let payload = b"snapshot-bytes-for-key-format-test";

    store
        .put(&key, payload)
        .await
        .expect("put with nested key should succeed");

    let retrieved = store
        .get(&key)
        .await
        .expect("get with nested key should succeed");
    assert_eq!(retrieved.as_slice(), payload);

    assert!(store.exists(&key).await.expect("exists should succeed"));
    assert_eq!(
        store.size(&key).await.expect("size should succeed"),
        payload.len() as u64
    );

    // Cleanup
    store
        .delete(&key)
        .await
        .expect("delete nested key should succeed");
}

#[tokio::test]
async fn garage_large_object_integrity() {
    if !garage_available() {
        eprintln!("[skip] GARAGE_ENDPOINT or AWS credentials not set");
        return;
    }

    let raw_client = build_raw_s3_client().await;
    ensure_bucket_exists(&raw_client, &garage_bucket())
        .await
        .expect("bucket setup failed");

    let store = build_garage_store().await;
    let key = format!("large-{}.bin", Uuid::new_v4());

    // Generate 100MB of deterministic pseudo-random data.
    // Use a simple PRNG seeded from the key to avoid pulling in `rand`.
    let size: usize = 100 * 1024 * 1024;
    let mut data = vec![0u8; size];
    let mut state: u64 = 0xDEAD_BEEF_CAFE_BABE;
    for chunk in data.chunks_mut(8) {
        // xorshift64
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        let bytes = state.to_le_bytes();
        let len = chunk.len().min(8);
        chunk[..len].copy_from_slice(&bytes[..len]);
    }

    let sha_before = hex::encode(Sha256::digest(&data));

    store
        .put(&key, &data)
        .await
        .expect("put 100MB should succeed");

    let retrieved = store.get(&key).await.expect("get 100MB should succeed");
    assert_eq!(retrieved.len(), size, "downloaded size should match");

    let sha_after = hex::encode(Sha256::digest(&retrieved));
    assert_eq!(
        sha_before, sha_after,
        "SHA256 mismatch: data corrupted through Garage round-trip"
    );

    // Cleanup
    store
        .delete(&key)
        .await
        .expect("delete 100MB object should succeed");
}

#[tokio::test]
async fn garage_concurrent_writes() {
    if !garage_available() {
        eprintln!("[skip] GARAGE_ENDPOINT or AWS credentials not set");
        return;
    }

    let raw_client = build_raw_s3_client().await;
    ensure_bucket_exists(&raw_client, &garage_bucket())
        .await
        .expect("bucket setup failed");

    let store = build_garage_store().await;
    let count = 10;
    let payload_size = 64 * 1024; // 64KB each

    // Generate unique keys and payloads
    let items: Vec<(String, Vec<u8>)> = (0..count)
        .map(|i| {
            let key = format!("concurrent-{}-{}.bin", i, Uuid::new_v4());
            let mut payload = vec![0u8; payload_size];
            // Fill with index-specific pattern for verification
            for (j, byte) in payload.iter_mut().enumerate() {
                *byte = ((i * 251 + j * 37) % 256) as u8;
            }
            (key, payload)
        })
        .collect();

    // Spawn concurrent writes
    let mut handles = Vec::new();
    for (key, payload) in &items {
        let store = Arc::clone(&store);
        let key = key.clone();
        let payload = payload.clone();
        handles.push(tokio::spawn(async move {
            store
                .put(&key, &payload)
                .await
                .expect("concurrent put should succeed");
        }));
    }

    // Await all writes
    for handle in handles {
        handle.await.expect("task should not panic");
    }

    // Read back and verify each key
    for (key, expected_payload) in &items {
        let retrieved = store
            .get(key)
            .await
            .unwrap_or_else(|e| panic!("get '{}' failed: {}", key, e));
        assert_eq!(
            retrieved.as_slice(),
            expected_payload.as_slice(),
            "payload mismatch for key '{}'",
            key
        );
    }

    // Cleanup
    for (key, _) in &items {
        store
            .delete(key)
            .await
            .unwrap_or_else(|e| panic!("delete '{}' failed: {}", key, e));
    }
}

#[tokio::test]
async fn garage_overwrite_semantics() {
    if !garage_available() {
        eprintln!("[skip] GARAGE_ENDPOINT or AWS credentials not set");
        return;
    }

    let raw_client = build_raw_s3_client().await;
    ensure_bucket_exists(&raw_client, &garage_bucket())
        .await
        .expect("bucket setup failed");

    let store = build_garage_store().await;
    let key = format!("overwrite-{}.bin", Uuid::new_v4());

    let payload_v1 = b"first-version-of-the-object";
    let payload_v2 = b"second-version-replaces-first";

    store
        .put(&key, payload_v1)
        .await
        .expect("put v1 should succeed");
    store
        .put(&key, payload_v2)
        .await
        .expect("put v2 (overwrite) should succeed");

    let retrieved = store
        .get(&key)
        .await
        .expect("get after overwrite should succeed");
    assert_eq!(
        retrieved.as_slice(),
        payload_v2,
        "get should return the second payload after overwrite"
    );
    assert_eq!(
        store.size(&key).await.expect("size should succeed"),
        payload_v2.len() as u64,
        "size should reflect the overwritten payload"
    );

    // Cleanup
    store.delete(&key).await.expect("delete should succeed");
}
