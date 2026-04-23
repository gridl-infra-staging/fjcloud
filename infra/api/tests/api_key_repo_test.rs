mod common;

use common::{mock_api_key_repo, MockApiKeyRepo};
use std::sync::Arc;
use uuid::Uuid;

use api::repos::api_key_repo::ApiKeyRepo;

fn setup() -> Arc<MockApiKeyRepo> {
    mock_api_key_repo()
}

#[tokio::test]
async fn create_stores_key() {
    let repo = setup();
    let customer_id = Uuid::new_v4();
    let scopes = vec!["read".to_string(), "write".to_string()];

    let key = repo
        .create(customer_id, "My Key", "hash123", "fj_live_", &scopes)
        .await
        .unwrap();

    assert_eq!(key.customer_id, customer_id);
    assert_eq!(key.name, "My Key");
    assert_eq!(key.key_hash, "hash123");
    assert_eq!(key.key_prefix, "fj_live_");
    assert_eq!(key.scopes, scopes);
    assert!(key.revoked_at.is_none());
    assert!(key.last_used_at.is_none());

    // Verify it's findable
    let found = repo.find_by_id(key.id).await.unwrap();
    assert!(found.is_some());
    assert_eq!(found.unwrap().id, key.id);
}

#[tokio::test]
async fn list_returns_non_revoked_only() {
    let repo = setup();
    let customer_id = Uuid::new_v4();

    let key1 = repo
        .create(customer_id, "Key 1", "h1", "fj_live_", &[])
        .await
        .unwrap();
    let _key2 = repo
        .create(customer_id, "Key 2", "h2", "fj_live_", &[])
        .await
        .unwrap();

    // Revoke key1
    repo.revoke(key1.id).await.unwrap();

    let listed = repo.list_by_customer(customer_id).await.unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].name, "Key 2");
}

#[tokio::test]
async fn find_by_prefix_returns_matches() {
    let repo = setup();
    let customer_id = Uuid::new_v4();

    repo.create(customer_id, "Key A", "ha", "fj_live_a", &[])
        .await
        .unwrap();
    repo.create(customer_id, "Key B", "hb", "fj_live_b", &[])
        .await
        .unwrap();
    repo.create(customer_id, "Key C", "hc", "fj_live_a", &[])
        .await
        .unwrap();

    let found = repo.find_by_prefix("fj_live_a").await.unwrap();
    assert_eq!(found.len(), 2);

    let found_b = repo.find_by_prefix("fj_live_b").await.unwrap();
    assert_eq!(found_b.len(), 1);

    let found_none = repo.find_by_prefix("fj_live_z").await.unwrap();
    assert!(found_none.is_empty());
}

#[tokio::test]
async fn revoke_sets_timestamp() {
    let repo = setup();
    let customer_id = Uuid::new_v4();

    let key = repo
        .create(customer_id, "Key", "h", "fj_live_", &[])
        .await
        .unwrap();
    assert!(key.revoked_at.is_none());

    let revoked = repo.revoke(key.id).await.unwrap();
    assert!(revoked.revoked_at.is_some());

    // Verify it's really revoked in storage
    let found = repo.find_by_id(key.id).await.unwrap().unwrap();
    assert!(found.revoked_at.is_some());
}

#[tokio::test]
async fn revoke_already_revoked_errors() {
    let repo = setup();
    let customer_id = Uuid::new_v4();

    let key = repo
        .create(customer_id, "Key", "h", "fj_live_", &[])
        .await
        .unwrap();

    repo.revoke(key.id).await.unwrap();

    let result = repo.revoke(key.id).await;
    assert!(result.is_err());
}

#[tokio::test]
async fn update_last_used_updates_timestamp() {
    let repo = setup();
    let customer_id = Uuid::new_v4();

    let key = repo
        .create(customer_id, "Key", "h", "fj_live_", &[])
        .await
        .unwrap();
    assert!(key.last_used_at.is_none());

    repo.update_last_used(key.id).await.unwrap();

    let updated = repo.find_by_id(key.id).await.unwrap().unwrap();
    assert!(updated.last_used_at.is_some());
}
