mod common;

use api::secrets::mock::MockNodeSecretManager;
use api::secrets::{
    memory::InMemoryNodeSecretManager, NodeSecretError, NodeSecretManager,
    UnconfiguredNodeSecretManager,
};

#[tokio::test]
async fn get_after_create_returns_key() {
    let mgr = MockNodeSecretManager::new();

    let created_key = mgr
        .create_node_api_key("node-1", "us-east-1")
        .await
        .unwrap();
    let fetched_key = mgr.get_node_api_key("node-1", "us-east-1").await.unwrap();

    assert_eq!(created_key, fetched_key);
}

#[tokio::test]
async fn get_non_existent_returns_error() {
    let mgr = MockNodeSecretManager::new();

    let result = mgr.get_node_api_key("no-such-node", "us-east-1").await;
    assert!(result.is_err());
    assert!(
        matches!(result.unwrap_err(), NodeSecretError::Api(_)),
        "should return Api error for missing key"
    );
}

#[tokio::test]
async fn unconfigured_get_returns_not_configured() {
    let mgr = UnconfiguredNodeSecretManager;

    let result = mgr.get_node_api_key("node-1", "us-east-1").await;
    assert!(result.is_err());
    assert!(
        matches!(result.unwrap_err(), NodeSecretError::NotConfigured),
        "should return NotConfigured error"
    );
}

#[tokio::test]
async fn rotate_returns_old_and_new_keys() {
    let mgr = MockNodeSecretManager::new();

    let old_key = mgr
        .create_node_api_key("node-1", "us-east-1")
        .await
        .unwrap();
    let (returned_old, returned_new) = mgr
        .rotate_node_api_key("node-1", "us-east-1")
        .await
        .unwrap();

    assert_eq!(old_key, returned_old);
    assert_ne!(old_key, returned_new);

    let fetched = mgr.get_node_api_key("node-1", "us-east-1").await.unwrap();
    assert_eq!(returned_new, fetched);
}

#[tokio::test]
async fn rotate_fails_when_key_missing() {
    let mgr = MockNodeSecretManager::new();

    let result = mgr.rotate_node_api_key("node-missing", "us-east-1").await;
    assert!(result.is_err());
    assert!(
        matches!(result.unwrap_err(), NodeSecretError::Api(_)),
        "rotate should return Api error when key is missing"
    );
}

#[tokio::test]
async fn commit_rotation_keeps_current_key() {
    let mgr = MockNodeSecretManager::new();

    let old_key = mgr
        .create_node_api_key("node-1", "us-east-1")
        .await
        .unwrap();
    let (returned_old, new_key) = mgr
        .rotate_node_api_key("node-1", "us-east-1")
        .await
        .unwrap();
    mgr.commit_rotation("node-1", "us-east-1", &old_key)
        .await
        .unwrap();

    assert_eq!(returned_old, old_key);
    let fetched = mgr.get_node_api_key("node-1", "us-east-1").await.unwrap();
    assert_eq!(new_key, fetched);
}

#[tokio::test]
async fn rotate_retains_previous_key_for_overlap() {
    let mgr = MockNodeSecretManager::new();

    let old_key = mgr
        .create_node_api_key("node-1", "us-east-1")
        .await
        .unwrap();

    assert!(
        mgr.get_previous_secret("node-1").is_none(),
        "no previous key before rotation"
    );

    let (returned_old, new_key) = mgr
        .rotate_node_api_key("node-1", "us-east-1")
        .await
        .unwrap();

    assert_eq!(returned_old, old_key);
    // Current key is now the new key.
    assert_eq!(
        mgr.get_secret("node-1").unwrap(),
        new_key,
        "current key should be updated to new key"
    );
    // Previous key is retained for overlap window.
    assert_eq!(
        mgr.get_previous_secret("node-1").unwrap(),
        old_key,
        "previous key should be retained during overlap"
    );
}

#[tokio::test]
async fn commit_removes_previous_key_state() {
    let mgr = MockNodeSecretManager::new();

    let old_key = mgr
        .create_node_api_key("node-1", "us-east-1")
        .await
        .unwrap();
    let (_returned_old, new_key) = mgr
        .rotate_node_api_key("node-1", "us-east-1")
        .await
        .unwrap();

    // Before commit: previous key exists.
    assert!(mgr.get_previous_secret("node-1").is_some());

    mgr.commit_rotation("node-1", "us-east-1", &old_key)
        .await
        .unwrap();

    // After commit: previous key is removed.
    assert!(
        mgr.get_previous_secret("node-1").is_none(),
        "previous key should be removed after commit"
    );
    // Current key unchanged.
    assert_eq!(mgr.get_secret("node-1").unwrap(), new_key);
}

#[tokio::test]
async fn failed_rotate_preserves_current_key() {
    let mgr = MockNodeSecretManager::new();

    let original_key = mgr
        .create_node_api_key("node-1", "us-east-1")
        .await
        .unwrap();

    // Inject failure before rotate.
    mgr.set_should_fail(true);
    let result = mgr.rotate_node_api_key("node-1", "us-east-1").await;
    assert!(
        result.is_err(),
        "rotate should fail when should_fail is set"
    );

    // Current key unchanged — no unauthenticated fallback risk.
    mgr.set_should_fail(false);
    let fetched = mgr.get_node_api_key("node-1", "us-east-1").await.unwrap();
    assert_eq!(
        fetched, original_key,
        "original key should survive a failed rotation"
    );
    assert!(
        mgr.get_previous_secret("node-1").is_none(),
        "no previous key should exist after failed rotation"
    );
}

#[tokio::test]
async fn failed_commit_preserves_overlap_state() {
    let mgr = MockNodeSecretManager::new();

    let old_key = mgr
        .create_node_api_key("node-1", "us-east-1")
        .await
        .unwrap();
    let (_returned_old, new_key) = mgr
        .rotate_node_api_key("node-1", "us-east-1")
        .await
        .unwrap();

    // Inject failure before commit.
    mgr.set_should_fail(true);
    let result = mgr.commit_rotation("node-1", "us-east-1", &old_key).await;
    assert!(
        result.is_err(),
        "commit should fail when should_fail is set"
    );

    // Both keys remain valid — overlap window stays open.
    mgr.set_should_fail(false);
    let fetched = mgr.get_node_api_key("node-1", "us-east-1").await.unwrap();
    assert_eq!(fetched, new_key, "current key should still be the new key");
    assert_eq!(
        mgr.get_previous_secret("node-1").unwrap(),
        old_key,
        "previous key should still be retained after failed commit"
    );
}

#[tokio::test]
async fn in_memory_create_and_get_roundtrip() {
    let mgr = InMemoryNodeSecretManager::new();

    let created = mgr
        .create_node_api_key("node-local-1", "us-east-1")
        .await
        .expect("create should succeed");
    let fetched = mgr
        .get_node_api_key("node-local-1", "us-east-1")
        .await
        .expect("get should succeed");

    assert_eq!(created, fetched, "fetched key should match created key");
}

#[tokio::test]
async fn in_memory_get_missing_returns_api_error() {
    let mgr = InMemoryNodeSecretManager::new();

    let err = mgr
        .get_node_api_key("missing-node", "us-east-1")
        .await
        .expect_err("missing key should fail");

    assert!(
        matches!(err, NodeSecretError::Api(_)),
        "missing key should return Api error"
    );
}

#[tokio::test]
async fn in_memory_rotate_and_commit_keeps_new_key() {
    let mgr = InMemoryNodeSecretManager::new();
    let old = mgr
        .create_node_api_key("node-local-rotate", "us-east-1")
        .await
        .expect("seed key should succeed");

    let (returned_old, new_key) = mgr
        .rotate_node_api_key("node-local-rotate", "us-east-1")
        .await
        .expect("rotate should succeed");
    assert_eq!(returned_old, old, "rotate must return previous key");

    mgr.commit_rotation("node-local-rotate", "us-east-1", &old)
        .await
        .expect("commit should succeed");

    let fetched = mgr
        .get_node_api_key("node-local-rotate", "us-east-1")
        .await
        .expect("get should succeed after commit");
    assert_eq!(fetched, new_key, "new key should remain after commit");
}
