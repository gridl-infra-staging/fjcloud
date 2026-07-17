use api::models::storage::PreparedStorageAccessKey;
use api::repos::storage_key_repo::StorageKeyRepo;
use api::repos::InMemoryStorageKeyRepo;
use uuid::Uuid;

fn repo() -> InMemoryStorageKeyRepo {
    InMemoryStorageKeyRepo::new()
}

fn dummy_encrypted() -> (Vec<u8>, Vec<u8>) {
    (vec![0xAA; 32], vec![0xBB; 12])
}

fn prepared_key(
    customer_id: Uuid,
    bucket_id: Uuid,
    label: &str,
    access_key: &str,
    garage_access_key_id: &str,
    enc: Vec<u8>,
    nonce: Vec<u8>,
) -> PreparedStorageAccessKey {
    PreparedStorageAccessKey {
        customer_id,
        bucket_id,
        access_key: access_key.to_string(),
        garage_access_key_id: garage_access_key_id.to_string(),
        secret_key_enc: enc,
        secret_key_nonce: nonce,
        label: label.to_string(),
    }
}

#[tokio::test]
async fn create_and_get_by_access_key() {
    let repo = repo();
    let cid = Uuid::new_v4();
    let bid = Uuid::new_v4();
    let (enc, nonce) = dummy_encrypted();

    let key = repo
        .create(prepared_key(
            cid,
            bid,
            "my key",
            "gridl_s3_testkey12345678ab",
            "garage-key-123",
            enc.clone(),
            nonce.clone(),
        ))
        .await
        .unwrap();

    assert_eq!(key.customer_id, cid);
    assert_eq!(key.bucket_id, bid);
    assert_eq!(key.access_key, "gridl_s3_testkey12345678ab");
    assert_eq!(key.garage_access_key_id, "garage-key-123");
    assert_eq!(key.secret_key_enc, enc);
    assert_eq!(key.secret_key_nonce, nonce);
    assert_eq!(key.label, "my key");
    assert!(key.revoked_at.is_none());

    let fetched = repo.get(key.id).await.unwrap().unwrap();
    assert_eq!(fetched.id, key.id);

    let found = repo
        .get_by_access_key("gridl_s3_testkey12345678ab")
        .await
        .unwrap();
    assert!(found.is_some());
    assert_eq!(found.unwrap().id, key.id);
}

#[tokio::test]
async fn get_by_access_key_returns_none_for_revoked() {
    let repo = repo();
    let (enc, nonce) = dummy_encrypted();

    let key = repo
        .create(prepared_key(
            Uuid::new_v4(),
            Uuid::new_v4(),
            "",
            "gridl_s3_revokedkey1234567",
            "garage-key-1",
            enc,
            nonce,
        ))
        .await
        .unwrap();

    repo.revoke(key.id).await.unwrap();

    let result = repo
        .get_by_access_key("gridl_s3_revokedkey1234567")
        .await
        .unwrap();
    assert!(result.is_none());
}

#[tokio::test]
async fn list_active_for_bucket() {
    let repo = repo();
    let bid = Uuid::new_v4();
    let cid = Uuid::new_v4();
    let (enc, nonce) = dummy_encrypted();

    let k1 = repo
        .create(prepared_key(
            cid,
            bid,
            "key1",
            "gridl_s3_key_one_1234567890",
            "garage-key-1",
            enc.clone(),
            nonce.clone(),
        ))
        .await
        .unwrap();
    let _k2 = repo
        .create(prepared_key(
            cid,
            bid,
            "key2",
            "gridl_s3_key_two_1234567890",
            "garage-key-2",
            enc.clone(),
            nonce.clone(),
        ))
        .await
        .unwrap();

    let active = repo.list_active_for_bucket(bid).await.unwrap();
    assert_eq!(active.len(), 2);

    repo.revoke(k1.id).await.unwrap();
    let active = repo.list_active_for_bucket(bid).await.unwrap();
    assert_eq!(active.len(), 1);
    assert_eq!(active[0].label, "key2");
}

#[tokio::test]
async fn duplicate_access_key_conflicts() {
    let repo = repo();
    let (enc, nonce) = dummy_encrypted();
    let ak = "gridl_s3_dup_key_123456789".to_string();

    repo.create(prepared_key(
        Uuid::new_v4(),
        Uuid::new_v4(),
        "",
        &ak,
        "garage-key-1",
        enc.clone(),
        nonce.clone(),
    ))
    .await
    .unwrap();

    let err = repo
        .create(prepared_key(
            Uuid::new_v4(),
            Uuid::new_v4(),
            "",
            &ak,
            "garage-key-2",
            enc,
            nonce,
        ))
        .await
        .unwrap_err();
    assert!(matches!(err, api::repos::RepoError::Conflict(_)));
}

#[tokio::test]
async fn duplicate_garage_access_key_id_conflicts() {
    let repo = repo();
    let (enc, nonce) = dummy_encrypted();

    repo.create(prepared_key(
        Uuid::new_v4(),
        Uuid::new_v4(),
        "",
        "gridl_s3_first_key_12345678",
        "garage-key-1",
        enc.clone(),
        nonce.clone(),
    ))
    .await
    .unwrap();

    let err = repo
        .create(prepared_key(
            Uuid::new_v4(),
            Uuid::new_v4(),
            "",
            "gridl_s3_second_key_1234567",
            "garage-key-1",
            enc,
            nonce,
        ))
        .await
        .unwrap_err();

    assert!(matches!(err, api::repos::RepoError::Conflict(_)));
}

#[tokio::test]
async fn revoke_nonexistent_returns_not_found() {
    let repo = repo();
    let err = repo.revoke(Uuid::new_v4()).await.unwrap_err();
    assert!(matches!(err, api::repos::RepoError::NotFound));
}

#[tokio::test]
async fn revoke_twice_returns_not_found() {
    let repo = repo();
    let (enc, nonce) = dummy_encrypted();

    let key = repo
        .create(prepared_key(
            Uuid::new_v4(),
            Uuid::new_v4(),
            "",
            "gridl_s3_revoke_twice_12345",
            "garage-key-1",
            enc,
            nonce,
        ))
        .await
        .unwrap();

    repo.revoke(key.id).await.unwrap();
    let err = repo.revoke(key.id).await.unwrap_err();
    assert!(matches!(err, api::repos::RepoError::NotFound));
}

#[tokio::test]
async fn list_active_for_different_bucket_returns_empty() {
    let repo = repo();
    let (enc, nonce) = dummy_encrypted();

    repo.create(prepared_key(
        Uuid::new_v4(),
        Uuid::new_v4(),
        "",
        "gridl_s3_other_key_12345678",
        "garage-key-1",
        enc,
        nonce,
    ))
    .await
    .unwrap();

    let result = repo.list_active_for_bucket(Uuid::new_v4()).await.unwrap();
    assert!(result.is_empty());
}

#[tokio::test]
async fn get_returns_none_for_missing_key() {
    let repo = repo();
    assert!(repo.get(Uuid::new_v4()).await.unwrap().is_none());
}
