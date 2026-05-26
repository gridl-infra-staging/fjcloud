mod common;

use common::{mock_api_key_repo, MockApiKeyRepo};
use std::sync::Arc;
use uuid::Uuid;

use api::repos::api_key_repo::{ApiKeyManagedKeyParams, ApiKeyRepo};

fn setup() -> Arc<MockApiKeyRepo> {
    mock_api_key_repo()
}

fn empty_managed_params() -> ApiKeyManagedKeyParams {
    ApiKeyManagedKeyParams {
        description: None,
        indexes: Vec::new(),
        restrict_sources: Vec::new(),
        expires_at: None,
        max_hits_per_query: None,
        max_queries_per_ip_per_hour: None,
    }
}

#[tokio::test]
async fn create_stores_key() {
    let repo = setup();
    let customer_id = Uuid::new_v4();
    let scopes = vec!["read".to_string(), "write".to_string()];

    let key = repo
        .create(
            customer_id,
            "My Key",
            "hash123",
            "fj_live_",
            &scopes,
            empty_managed_params(),
        )
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
        .create(
            customer_id,
            "Key 1",
            "h1",
            "fj_live_",
            &[],
            empty_managed_params(),
        )
        .await
        .unwrap();
    let _key2 = repo
        .create(
            customer_id,
            "Key 2",
            "h2",
            "fj_live_",
            &[],
            empty_managed_params(),
        )
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

    repo.create(
        customer_id,
        "Key A",
        "ha",
        "fj_live_a",
        &[],
        empty_managed_params(),
    )
    .await
    .unwrap();
    repo.create(
        customer_id,
        "Key B",
        "hb",
        "fj_live_b",
        &[],
        empty_managed_params(),
    )
    .await
    .unwrap();
    repo.create(
        customer_id,
        "Key C",
        "hc",
        "fj_live_a",
        &[],
        empty_managed_params(),
    )
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
        .create(
            customer_id,
            "Key",
            "h",
            "fj_live_",
            &[],
            empty_managed_params(),
        )
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
        .create(
            customer_id,
            "Key",
            "h",
            "fj_live_",
            &[],
            empty_managed_params(),
        )
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
        .create(
            customer_id,
            "Key",
            "h",
            "fj_live_",
            &[],
            empty_managed_params(),
        )
        .await
        .unwrap();
    assert!(key.last_used_at.is_none());

    repo.update_last_used(key.id).await.unwrap();

    let updated = repo.find_by_id(key.id).await.unwrap().unwrap();
    assert!(updated.last_used_at.is_some());
}

#[tokio::test]
async fn create_find_list_round_trip_managed_key_parity_fields() {
    let repo = setup();
    let customer_id = Uuid::new_v4();
    let scopes = vec!["indexes:read".to_string(), "indexes:write".to_string()];
    let indexes = vec!["products".to_string(), "catalog".to_string()];
    let restrict_sources = vec!["10.0.0.0/8".to_string(), "192.168.1.0/24".to_string()];
    let expires_at = chrono::DateTime::parse_from_rfc3339("2030-01-02T03:04:05Z")
        .unwrap()
        .with_timezone(&chrono::Utc);

    let created = repo
        .create(
            customer_id,
            "Managed Key",
            "hash-managed",
            "fjc_live_abcdef",
            &scopes,
            ApiKeyManagedKeyParams {
                description: Some("Managed key for storefront search".to_string()),
                indexes: indexes.clone(),
                restrict_sources: restrict_sources.clone(),
                expires_at: Some(expires_at),
                max_hits_per_query: Some(120),
                max_queries_per_ip_per_hour: Some(5000),
            },
        )
        .await
        .unwrap();

    assert_eq!(
        created.description.as_deref(),
        Some("Managed key for storefront search")
    );
    assert_eq!(created.indexes, indexes);
    assert_eq!(created.restrict_sources, restrict_sources);
    assert_eq!(created.expires_at, Some(expires_at));
    assert_eq!(created.max_hits_per_query, Some(120));
    assert_eq!(created.max_queries_per_ip_per_hour, Some(5000));

    let found = repo.find_by_id(created.id).await.unwrap().unwrap();
    assert_eq!(found.description, created.description);
    assert_eq!(found.indexes, created.indexes);
    assert_eq!(found.restrict_sources, created.restrict_sources);
    assert_eq!(found.expires_at, created.expires_at);
    assert_eq!(found.max_hits_per_query, created.max_hits_per_query);
    assert_eq!(
        found.max_queries_per_ip_per_hour,
        created.max_queries_per_ip_per_hour
    );

    let listed = repo.list_by_customer(customer_id).await.unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].description, created.description);
    assert_eq!(listed[0].indexes, created.indexes);
    assert_eq!(listed[0].restrict_sources, created.restrict_sources);
    assert_eq!(listed[0].expires_at, created.expires_at);
    assert_eq!(listed[0].max_hits_per_query, created.max_hits_per_query);
    assert_eq!(
        listed[0].max_queries_per_ip_per_hour,
        created.max_queries_per_ip_per_hour
    );
}
