//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/in_memory_storage_key_repo.rs.
use async_trait::async_trait;
use chrono::Utc;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use uuid::Uuid;

use crate::models::storage::{PreparedStorageAccessKey, StorageAccessKeyRow};
use crate::repos::error::RepoError;
use crate::repos::storage_key_repo::{duplicate_storage_access_key_error, StorageKeyRepo};

#[derive(Clone, Default)]
pub struct InMemoryStorageKeyRepo {
    keys: Arc<Mutex<HashMap<Uuid, StorageAccessKeyRow>>>,
}

impl InMemoryStorageKeyRepo {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl StorageKeyRepo for InMemoryStorageKeyRepo {
    /// In-memory access-key creation for tests/local dev. Rejects with
    /// `Conflict` if access_key or garage_access_key_id already exists.
    async fn create(
        &self,
        key: PreparedStorageAccessKey,
    ) -> Result<StorageAccessKeyRow, RepoError> {
        let mut keys = self.keys.lock().unwrap();

        if keys.values().any(|k| k.access_key == key.access_key) {
            return Err(duplicate_storage_access_key_error());
        }

        if keys
            .values()
            .any(|k| k.garage_access_key_id == key.garage_access_key_id)
        {
            return Err(duplicate_storage_access_key_error());
        }

        let row = StorageAccessKeyRow {
            id: Uuid::new_v4(),
            customer_id: key.customer_id,
            bucket_id: key.bucket_id,
            access_key: key.access_key,
            garage_access_key_id: key.garage_access_key_id,
            secret_key_enc: key.secret_key_enc,
            secret_key_nonce: key.secret_key_nonce,
            label: key.label,
            revoked_at: None,
            created_at: Utc::now(),
        };
        keys.insert(row.id, row.clone());
        Ok(row)
    }

    async fn get(&self, id: Uuid) -> Result<Option<StorageAccessKeyRow>, RepoError> {
        Ok(self.keys.lock().unwrap().get(&id).cloned())
    }

    async fn get_by_access_key(
        &self,
        access_key: &str,
    ) -> Result<Option<StorageAccessKeyRow>, RepoError> {
        Ok(self
            .keys
            .lock()
            .unwrap()
            .values()
            .find(|k| k.access_key == access_key && k.revoked_at.is_none())
            .cloned())
    }

    async fn list_active_for_bucket(
        &self,
        bucket_id: Uuid,
    ) -> Result<Vec<StorageAccessKeyRow>, RepoError> {
        let keys = self.keys.lock().unwrap();
        let mut rows: Vec<StorageAccessKeyRow> = keys
            .values()
            .filter(|k| k.bucket_id == bucket_id && k.revoked_at.is_none())
            .cloned()
            .collect();
        rows.sort_by_key(|k| k.created_at);
        Ok(rows)
    }

    async fn revoke(&self, id: Uuid) -> Result<(), RepoError> {
        let mut keys = self.keys.lock().unwrap();
        match keys.get_mut(&id) {
            Some(k) => {
                if k.revoked_at.is_some() {
                    return Err(RepoError::NotFound);
                }
                k.revoked_at = Some(Utc::now());
                Ok(())
            }
            None => Err(RepoError::NotFound),
        }
    }
}
