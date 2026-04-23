use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// A row from `storage_buckets` — customer-facing bucket mapped to an internal Garage bucket.
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct StorageBucket {
    pub id: Uuid,
    pub customer_id: Uuid,
    pub name: String,
    pub garage_bucket: String,
    pub size_bytes: i64,
    pub object_count: i64,
    pub egress_bytes: i64,
    pub egress_watermark_bytes: i64,
    pub status: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// Input struct for creating a new storage bucket.
#[derive(Debug, Clone)]
pub struct NewStorageBucket {
    pub customer_id: Uuid,
    pub name: String,
}

/// A row from `storage_access_keys` — encrypted secret stored in DB.
#[derive(Debug, Clone, sqlx::FromRow)]
pub struct StorageAccessKeyRow {
    pub id: Uuid,
    pub customer_id: Uuid,
    pub bucket_id: Uuid,
    pub access_key: String,
    pub garage_access_key_id: String,
    pub secret_key_enc: Vec<u8>,
    pub secret_key_nonce: Vec<u8>,
    pub label: String,
    pub revoked_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

/// Decrypted view of a storage access key — never persisted, only returned to the caller.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StorageAccessKey {
    pub id: Uuid,
    pub customer_id: Uuid,
    pub bucket_id: Uuid,
    pub access_key: String,
    pub secret_key: String,
    pub label: String,
    pub created_at: DateTime<Utc>,
}

/// Input struct for creating a new storage access key.
#[derive(Debug, Clone)]
pub struct NewStorageAccessKey {
    pub customer_id: Uuid,
    pub bucket_id: Uuid,
    pub label: String,
}

/// A fully prepared access key ready for persistence (generated key + encrypted secret).
#[derive(Debug, Clone)]
pub struct PreparedStorageAccessKey {
    pub customer_id: Uuid,
    pub bucket_id: Uuid,
    pub access_key: String,
    pub garage_access_key_id: String,
    pub secret_key_enc: Vec<u8>,
    pub secret_key_nonce: Vec<u8>,
    pub label: String,
}
