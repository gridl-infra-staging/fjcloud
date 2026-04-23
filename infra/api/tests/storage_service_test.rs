use api::models::storage::{NewStorageAccessKey, NewStorageBucket, PreparedStorageAccessKey};
use api::repos::error::RepoError;
use api::repos::storage_bucket_repo::StorageBucketRepo;
use api::repos::storage_key_repo::StorageKeyRepo;
use api::repos::InMemoryStorageBucketRepo;
use api::repos::InMemoryStorageKeyRepo;
use api::services::storage::{
    GarageAdminClient, GarageBucketInfo, GarageKeyInfo, StorageError, StorageService,
};
use async_trait::async_trait;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::Mutex;
use uuid::Uuid;

fn test_master_key() -> [u8; 32] {
    [0x42; 32]
}

#[derive(Default)]
struct RecordingGarageAdminClient {
    state: Mutex<GarageAdminState>,
}

#[derive(Default)]
struct GarageAdminState {
    bucket_aliases: Vec<String>,
    bucket_ids_by_alias: HashMap<String, String>,
    deleted_bucket_ids: Vec<String>,
    created_key_names: Vec<String>,
    deleted_key_ids: Vec<String>,
    allow_calls: Vec<(String, String, bool, bool)>,
}

impl RecordingGarageAdminClient {
    fn bucket_aliases(&self) -> Vec<String> {
        self.state.lock().unwrap().bucket_aliases.clone()
    }

    fn deleted_bucket_ids(&self) -> Vec<String> {
        self.state.lock().unwrap().deleted_bucket_ids.clone()
    }

    fn deleted_key_ids(&self) -> Vec<String> {
        self.state.lock().unwrap().deleted_key_ids.clone()
    }

    fn allow_calls(&self) -> Vec<(String, String, bool, bool)> {
        self.state.lock().unwrap().allow_calls.clone()
    }
}

#[async_trait]
impl GarageAdminClient for RecordingGarageAdminClient {
    async fn create_bucket(&self, name: &str) -> Result<GarageBucketInfo, StorageError> {
        let mut state = self.state.lock().unwrap();
        let bucket_id = format!("bucket-{}", state.bucket_aliases.len() + 1);
        state.bucket_aliases.push(name.to_string());
        state
            .bucket_ids_by_alias
            .insert(name.to_string(), bucket_id.clone());
        Ok(GarageBucketInfo { id: bucket_id })
    }

    async fn get_bucket_by_alias(
        &self,
        global_alias: &str,
    ) -> Result<GarageBucketInfo, StorageError> {
        let state = self.state.lock().unwrap();
        let Some(bucket_id) = state.bucket_ids_by_alias.get(global_alias) else {
            return Err(StorageError::NotFound(format!(
                "garage bucket alias '{global_alias}' not found"
            )));
        };
        Ok(GarageBucketInfo {
            id: bucket_id.clone(),
        })
    }

    async fn delete_bucket(&self, id: &str) -> Result<(), StorageError> {
        self.state
            .lock()
            .unwrap()
            .deleted_bucket_ids
            .push(id.to_string());
        Ok(())
    }

    async fn create_key(&self, name: &str) -> Result<GarageKeyInfo, StorageError> {
        let mut state = self.state.lock().unwrap();
        let key_id = format!("garage-key-{}", state.created_key_names.len() + 1);
        state.created_key_names.push(name.to_string());
        Ok(GarageKeyInfo {
            id: key_id,
            secret_key: "garage-secret".to_string(),
        })
    }

    async fn delete_key(&self, id: &str) -> Result<(), StorageError> {
        self.state
            .lock()
            .unwrap()
            .deleted_key_ids
            .push(id.to_string());
        Ok(())
    }

    async fn allow_key(
        &self,
        bucket_id: &str,
        key_id: &str,
        allow_read: bool,
        allow_write: bool,
    ) -> Result<(), StorageError> {
        self.state.lock().unwrap().allow_calls.push((
            bucket_id.to_string(),
            key_id.to_string(),
            allow_read,
            allow_write,
        ));
        Ok(())
    }
}

struct FailingStorageKeyRepo;

#[async_trait]
impl StorageKeyRepo for FailingStorageKeyRepo {
    async fn create(
        &self,
        _key: PreparedStorageAccessKey,
    ) -> Result<api::models::storage::StorageAccessKeyRow, RepoError> {
        Err(RepoError::Conflict("simulated insert failure".to_string()))
    }

    async fn get(
        &self,
        _id: Uuid,
    ) -> Result<Option<api::models::storage::StorageAccessKeyRow>, RepoError> {
        Ok(None)
    }

    async fn get_by_access_key(
        &self,
        _access_key: &str,
    ) -> Result<Option<api::models::storage::StorageAccessKeyRow>, RepoError> {
        Ok(None)
    }

    async fn list_active_for_bucket(
        &self,
        _bucket_id: Uuid,
    ) -> Result<Vec<api::models::storage::StorageAccessKeyRow>, RepoError> {
        Ok(Vec::new())
    }

    async fn revoke(&self, _id: Uuid) -> Result<(), RepoError> {
        Err(RepoError::NotFound)
    }
}

fn build_service() -> (
    StorageService,
    Arc<InMemoryStorageBucketRepo>,
    Arc<InMemoryStorageKeyRepo>,
    Arc<RecordingGarageAdminClient>,
) {
    let bucket_repo = Arc::new(InMemoryStorageBucketRepo::new());
    let key_repo = Arc::new(InMemoryStorageKeyRepo::new());
    let garage = Arc::new(RecordingGarageAdminClient::default());
    let service = StorageService::new(
        bucket_repo.clone(),
        key_repo.clone(),
        garage.clone(),
        test_master_key(),
    );
    (service, bucket_repo, key_repo, garage)
}

#[tokio::test]
async fn create_bucket_persists_to_repo() {
    let (service, bucket_repo, _, _) = build_service();
    let cid = Uuid::new_v4();

    let bucket = service
        .create_bucket(NewStorageBucket {
            customer_id: cid,
            name: "my-bucket".to_string(),
        })
        .await
        .unwrap();

    assert_eq!(bucket.customer_id, cid);
    assert_eq!(bucket.name, "my-bucket");
    assert_eq!(bucket.status, "active");
    assert!(!bucket.garage_bucket.is_empty());

    // Verify it's in the repo
    let fetched = bucket_repo.get(bucket.id).await.unwrap().unwrap();
    assert_eq!(fetched.id, bucket.id);
}

#[tokio::test]
async fn create_access_key_returns_decrypted_secret() {
    let (service, _, key_repo, garage) = build_service();
    let cid = Uuid::new_v4();

    let bucket = service
        .create_bucket(NewStorageBucket {
            customer_id: cid,
            name: "keys-bucket".to_string(),
        })
        .await
        .unwrap();

    let access_key = service
        .create_access_key(NewStorageAccessKey {
            customer_id: cid,
            bucket_id: bucket.id,
            label: "test-key".to_string(),
        })
        .await
        .unwrap();

    assert_eq!(
        garage.allow_calls(),
        vec![(
            "bucket-1".to_string(),
            "garage-key-1".to_string(),
            true,
            true
        )]
    );
    assert!(access_key.access_key.starts_with("gridl_s3_"));
    assert_eq!(access_key.access_key.len(), 29); // "gridl_s3_" (9) + 20 random
    assert_eq!(access_key.secret_key.len(), 40);
    assert_eq!(access_key.label, "test-key");
    assert_eq!(access_key.customer_id, cid);
    assert_eq!(access_key.bucket_id, bucket.id);

    // Verify the encrypted secret in the repo can be decrypted back
    let row = key_repo.get(access_key.id).await.unwrap().unwrap();
    assert_eq!(row.garage_access_key_id, "garage-key-1");
    let by_access_key = key_repo
        .get_by_access_key(&access_key.access_key)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(by_access_key.id, row.id);
    let decrypted = service
        .decrypt_key_secret(&row.secret_key_enc, &row.secret_key_nonce)
        .unwrap();
    assert_eq!(decrypted, access_key.secret_key);
}

#[tokio::test]
async fn revoke_access_key() {
    let (service, _, key_repo, garage) = build_service();
    let cid = Uuid::new_v4();

    let bucket = service
        .create_bucket(NewStorageBucket {
            customer_id: cid,
            name: "revoke-bucket".to_string(),
        })
        .await
        .unwrap();

    let access_key = service
        .create_access_key(NewStorageAccessKey {
            customer_id: cid,
            bucket_id: bucket.id,
            label: "".to_string(),
        })
        .await
        .unwrap();

    service.revoke_access_key(access_key.id).await.unwrap();
    assert_eq!(garage.deleted_key_ids(), vec!["garage-key-1".to_string()]);

    // Should no longer be findable by access key
    let result = key_repo
        .get_by_access_key(&access_key.access_key)
        .await
        .unwrap();
    assert!(result.is_none());
}

#[tokio::test]
async fn revoke_access_key_rejects_already_revoked_key() {
    let (service, _, _, garage) = build_service();
    let cid = Uuid::new_v4();

    let bucket = service
        .create_bucket(NewStorageBucket {
            customer_id: cid,
            name: "revoke-twice".to_string(),
        })
        .await
        .unwrap();

    let access_key = service
        .create_access_key(NewStorageAccessKey {
            customer_id: cid,
            bucket_id: bucket.id,
            label: "".to_string(),
        })
        .await
        .unwrap();

    service.revoke_access_key(access_key.id).await.unwrap();

    let result = service.revoke_access_key(access_key.id).await;
    assert!(matches!(result, Err(StorageError::NotFound(_))));
    assert_eq!(garage.deleted_key_ids(), vec!["garage-key-1".to_string()]);
}

#[tokio::test]
async fn delete_bucket_marks_deleted() {
    let (service, bucket_repo, _, garage) = build_service();
    let cid = Uuid::new_v4();

    let bucket = service
        .create_bucket(NewStorageBucket {
            customer_id: cid,
            name: "delete-me".to_string(),
        })
        .await
        .unwrap();

    service.delete_bucket(bucket.id).await.unwrap();
    assert_eq!(garage.deleted_bucket_ids(), vec!["bucket-1".to_string()]);

    let fetched = bucket_repo.get(bucket.id).await.unwrap().unwrap();
    assert_eq!(fetched.status, "deleted");
}

#[tokio::test]
async fn delete_bucket_revokes_active_access_keys() {
    let (service, bucket_repo, key_repo, garage) = build_service();
    let customer_id = Uuid::new_v4();

    let bucket = service
        .create_bucket(NewStorageBucket {
            customer_id,
            name: "delete-with-keys".to_string(),
        })
        .await
        .unwrap();

    service
        .create_access_key(NewStorageAccessKey {
            customer_id,
            bucket_id: bucket.id,
            label: "key-1".to_string(),
        })
        .await
        .unwrap();
    service
        .create_access_key(NewStorageAccessKey {
            customer_id,
            bucket_id: bucket.id,
            label: "key-2".to_string(),
        })
        .await
        .unwrap();

    service.delete_bucket(bucket.id).await.unwrap();

    assert_eq!(garage.deleted_bucket_ids(), vec!["bucket-1".to_string()]);
    assert_eq!(
        garage.deleted_key_ids(),
        vec!["garage-key-1".to_string(), "garage-key-2".to_string()]
    );
    assert!(key_repo
        .list_active_for_bucket(bucket.id)
        .await
        .unwrap()
        .is_empty());

    let fetched = bucket_repo.get(bucket.id).await.unwrap().unwrap();
    assert_eq!(fetched.status, "deleted");
}

#[tokio::test]
async fn delete_bucket_rejects_deleted_bucket() {
    let (service, _, _, garage) = build_service();
    let cid = Uuid::new_v4();

    let bucket = service
        .create_bucket(NewStorageBucket {
            customer_id: cid,
            name: "delete-once".to_string(),
        })
        .await
        .unwrap();

    service.delete_bucket(bucket.id).await.unwrap();

    let result = service.delete_bucket(bucket.id).await;
    assert!(matches!(result, Err(StorageError::NotFound(_))));
    assert_eq!(garage.deleted_bucket_ids(), vec!["bucket-1".to_string()]);
}

#[tokio::test]
async fn list_buckets_for_customer() {
    let (service, _, _, _) = build_service();
    let cid = Uuid::new_v4();

    service
        .create_bucket(NewStorageBucket {
            customer_id: cid,
            name: "b1".to_string(),
        })
        .await
        .unwrap();
    service
        .create_bucket(NewStorageBucket {
            customer_id: cid,
            name: "b2".to_string(),
        })
        .await
        .unwrap();

    let buckets = service.list_buckets(cid).await.unwrap();
    assert_eq!(buckets.len(), 2);

    // Other customer sees nothing
    let other = service.list_buckets(Uuid::new_v4()).await.unwrap();
    assert!(other.is_empty());
}

#[tokio::test]
async fn get_bucket_returns_none_for_missing() {
    let (service, _, _, _) = build_service();
    let result = service.get_bucket(Uuid::new_v4()).await.unwrap();
    assert!(result.is_none());
}

#[tokio::test]
async fn get_bucket_returns_none_for_deleted_bucket() {
    let (service, _, _, _) = build_service();
    let cid = Uuid::new_v4();

    let bucket = service
        .create_bucket(NewStorageBucket {
            customer_id: cid,
            name: "hidden".to_string(),
        })
        .await
        .unwrap();
    service.delete_bucket(bucket.id).await.unwrap();

    let result = service.get_bucket(bucket.id).await.unwrap();
    assert!(result.is_none());
}

#[tokio::test]
async fn delete_nonexistent_bucket_errors() {
    let (service, _, _, _) = build_service();
    let result = service.delete_bucket(Uuid::new_v4()).await;
    assert!(result.is_err());
}

#[tokio::test]
async fn create_bucket_uses_unique_internal_garage_aliases() {
    let (service, _, _, garage) = build_service();

    let first = service
        .create_bucket(NewStorageBucket {
            customer_id: Uuid::new_v4(),
            name: "shared-name".to_string(),
        })
        .await
        .unwrap();
    let second = service
        .create_bucket(NewStorageBucket {
            customer_id: Uuid::new_v4(),
            name: "shared-name".to_string(),
        })
        .await
        .unwrap();

    let aliases = garage.bucket_aliases();
    assert_eq!(
        aliases,
        vec![first.garage_bucket.clone(), second.garage_bucket.clone()]
    );
    assert_ne!(first.garage_bucket, "shared-name");
    assert_ne!(second.garage_bucket, "shared-name");
    assert_ne!(first.garage_bucket, second.garage_bucket);
}

#[tokio::test]
async fn create_bucket_deletes_garage_bucket_when_repo_insert_conflicts() {
    let (service, _, _, garage) = build_service();
    let customer_id = Uuid::new_v4();

    service
        .create_bucket(NewStorageBucket {
            customer_id,
            name: "duplicate".to_string(),
        })
        .await
        .unwrap();

    let result = service
        .create_bucket(NewStorageBucket {
            customer_id,
            name: "duplicate".to_string(),
        })
        .await;
    assert!(matches!(result, Err(StorageError::Conflict(_))));
    assert_eq!(garage.deleted_bucket_ids(), vec!["bucket-2".to_string()]);
}

#[tokio::test]
async fn create_access_key_rejects_bucket_customer_mismatch() {
    let (service, _, _, _) = build_service();
    let owner_id = Uuid::new_v4();

    let bucket = service
        .create_bucket(NewStorageBucket {
            customer_id: owner_id,
            name: "owned".to_string(),
        })
        .await
        .unwrap();

    let result = service
        .create_access_key(NewStorageAccessKey {
            customer_id: Uuid::new_v4(),
            bucket_id: bucket.id,
            label: "wrong-owner".to_string(),
        })
        .await;

    assert!(matches!(result, Err(StorageError::NotFound(_))));
}

#[tokio::test]
async fn create_access_key_rejects_deleted_bucket() {
    let (service, _, _, garage) = build_service();
    let customer_id = Uuid::new_v4();

    let bucket = service
        .create_bucket(NewStorageBucket {
            customer_id,
            name: "deleted-bucket".to_string(),
        })
        .await
        .unwrap();
    service.delete_bucket(bucket.id).await.unwrap();

    let result = service
        .create_access_key(NewStorageAccessKey {
            customer_id,
            bucket_id: bucket.id,
            label: "should-fail".to_string(),
        })
        .await;

    assert!(matches!(result, Err(StorageError::NotFound(_))));
    assert!(garage.allow_calls().is_empty());
    assert!(garage.deleted_key_ids().is_empty());
}

#[tokio::test]
async fn create_access_key_deletes_garage_key_when_repo_insert_fails() {
    let bucket_repo = Arc::new(InMemoryStorageBucketRepo::new());
    let garage = Arc::new(RecordingGarageAdminClient::default());
    let service = StorageService::new(
        bucket_repo.clone(),
        Arc::new(FailingStorageKeyRepo),
        garage.clone(),
        test_master_key(),
    );
    let customer_id = Uuid::new_v4();

    let bucket = service
        .create_bucket(NewStorageBucket {
            customer_id,
            name: "cleanup".to_string(),
        })
        .await
        .unwrap();

    let result = service
        .create_access_key(NewStorageAccessKey {
            customer_id,
            bucket_id: bucket.id,
            label: "cleanup-key".to_string(),
        })
        .await;

    assert!(matches!(result, Err(StorageError::Conflict(_))));
    assert_eq!(garage.deleted_key_ids(), vec!["garage-key-1".to_string()]);
}
