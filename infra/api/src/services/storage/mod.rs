//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/storage/mod.rs.
// ---------------------------------------------------------------------------
// Stage 4 Protocol Decision: Manual SigV4 + quick-xml
// ---------------------------------------------------------------------------
//
// Evaluated `s3s` (v0.11, 47K LoC, Apache-2.0) vs manual implementation.
//
// Decision: **Manual**, using existing workspace crates.
//
// Why not s3s:
//   - s3s is a full S3 server framework (smithy-generated types, its own
//     hyper service, expects implementors to define an `S3` trait with all
//     operations). Our use case is a proxy: verify inbound SigV4, forward
//     to Garage with re-signed credentials, return streamed responses.
//   - s3s's request pipeline conflicts with Axum's extractors/middleware.
//   - Pulling in s3s adds ~47K LoC and a deep dependency tree for features
//     we don't need (multipart assembly, bucket policy eval, etc.).
//
// Why manual:
//   - `hmac 0.12`, `sha2 0.10`, `base64 0.22`, `hex 0.4` are already in
//     the workspace — all four are needed for SigV4 canonical-request
//     construction, signing-key derivation, and HMAC verification.
//   - Same pure helpers serve both inbound verification (`s3_auth.rs`) and
//     outbound re-signing (`s3_proxy.rs`), keeping signing logic DRY.
//   - `quick-xml` (new dep) handles the 3 XML response types we need
//     (`<Error>`, `ListBucketsResult`, `ListObjectsV2Result`). It's ~50x
//     faster than xml-rs and almost zero-copy.
//
// Dependency changes required:
//   - `infra/Cargo.toml`: add `quick-xml = "0.37"` to [workspace.dependencies]
//   - `infra/Cargo.toml`: add `"stream"` to reqwest features
//   - `infra/api/Cargo.toml`: add `quick-xml = { workspace = true }`
//
// Stage 4 service seam:
//
//   s3_auth.rs — SigV4 verification
//     Input:  HTTP request parts (method, uri, headers, content-sha256)
//             + StorageKeyRepo + master encryption key
//     Output: S3AuthContext { customer_id, bucket_id, access_key_row }
//             or S3AuthError (InvalidSignature | AccessDenied | ClockSkew)
//     Public pure helpers (reused by s3_proxy.rs):
//       canonical_uri(), canonical_query(), canonical_headers(),
//       canonical_request(), string_to_sign(), signing_key()
//
//   s3_proxy.rs — Garage request forwarding
//     Input:  S3AuthContext + original request (method, path, query, body)
//     Config: GARAGE_S3_ENDPOINT, GARAGE_S3_ACCESS_KEY, GARAGE_S3_SECRET_KEY
//     Output: streamed reqwest::Response from Garage
//     Re-signs outbound request using s3_auth.rs public helpers.
//     Strips inbound auth headers; preserves Content-Type, Range, etc.
//
//   s3_xml.rs — S3 XML response builders
//     Pure functions: error_response(), list_buckets_result(),
//     list_objects_v2_result(). Used by Stage 5 route handlers and by the
//     proxy-to-S3 error mapper.
//
// ---------------------------------------------------------------------------
// Stage 4 Protocol Policies (resolved during research)
// ---------------------------------------------------------------------------
//
// Clock skew: 15-minute window (matches S3 `RequestTimeTooSkewed`).
//   Source: AWS S3 auth docs + aws.amazon.com/blogs/developer/clock-skew-correction/
//
// Repeated headers: comma-join in original order, trim leading/trailing
//   spaces, collapse sequential spaces to single space. Do NOT re-sort
//   values within a multi-value header.
//   Source: IAM SigV4 canonical request spec (docs.aws.amazon.com)
//
// URI encoding: percent-encode all bytes except A-Z a-z 0-9 - . _ ~.
//   Forward slashes preserved in object key names (S3 does NOT normalize
//   URI paths — "my-object//example//photo.user" stays as-is).
//   Source: S3 SigV4 header-based auth docs
//
// x-amz-content-sha256: accept both hex(sha256(payload)) and the literal
//   string "UNSIGNED-PAYLOAD". Not required as a signed header (S3 uses
//   it automatically). Empty-body hash = e3b0c44298fc1c14...
//   Source: S3 SigV4 header-based auth docs
//
// Proxy response header allowlist (forward from Garage to client):
//   content-type, content-length, etag, last-modified, x-amz-request-id,
//   x-amz-id-2, x-amz-version-id, x-amz-delete-marker,
//   x-amz-server-side-encryption, content-range, accept-ranges,
//   cache-control, content-disposition, content-encoding, expires.
//   Strip hop-by-hop: connection, keep-alive, transfer-encoding,
//   proxy-authenticate, proxy-authorization, te, trailer, upgrade.
//   Strip Garage internals: server.
//   Source: S3 common response headers docs + RFC 2616 §13.5.1
//
// Garage error pass-through: Garage uses standard S3 error codes
//   (NoSuchKey, AccessDenied, BucketNotEmpty, InternalError, etc.).
//   No proprietary codes exist. Proxy passes Garage XML error bodies
//   through unmodified for recognized codes; unrecognized codes fall
//   back to InternalError (500).
//   Source: Garage src/api/s3/error.rs
//
// ---------------------------------------------------------------------------

pub mod encryption;
pub mod garage_admin;
pub mod object_metering;
pub mod s3_auth;
pub mod s3_error;
pub mod s3_proxy;
pub mod s3_xml;

pub use self::garage_admin::{GarageAdminClient, GarageBucketInfo, GarageKeyInfo};

use std::sync::Arc;

use uuid::Uuid;

use crate::models::storage::{
    NewStorageAccessKey, NewStorageBucket, PreparedStorageAccessKey, StorageAccessKey,
    StorageBucket,
};
use crate::repos::error::RepoError;
use crate::repos::storage_bucket_repo::StorageBucketRepo;
use crate::repos::storage_key_repo::StorageKeyRepo;

use self::encryption::{decrypt_secret, encrypt_secret, generate_access_key, generate_secret_key};

/// Errors that can occur in storage service operations.
#[derive(Debug, thiserror::Error)]
pub enum StorageError {
    #[error("repo error: {0}")]
    Repo(String),

    #[error("garage admin error: {0}")]
    GarageAdmin(String),

    #[error("encryption error: {0}")]
    Encryption(String),

    #[error("not found: {0}")]
    NotFound(String),

    #[error("conflict: {0}")]
    Conflict(String),
}

impl From<RepoError> for StorageError {
    fn from(err: RepoError) -> Self {
        match err {
            RepoError::NotFound => StorageError::NotFound("entity not found".to_string()),
            RepoError::Conflict(msg) => StorageError::Conflict(msg),
            RepoError::Other(msg) => StorageError::Repo(msg),
        }
    }
}

pub struct StorageService {
    bucket_repo: Arc<dyn StorageBucketRepo + Send + Sync>,
    key_repo: Arc<dyn StorageKeyRepo + Send + Sync>,
    garage_admin: Arc<dyn GarageAdminClient>,
    master_key: [u8; 32],
}

impl StorageService {
    pub fn new(
        bucket_repo: Arc<dyn StorageBucketRepo + Send + Sync>,
        key_repo: Arc<dyn StorageKeyRepo + Send + Sync>,
        garage_admin: Arc<dyn GarageAdminClient>,
        master_key: [u8; 32],
    ) -> Self {
        Self {
            bucket_repo,
            key_repo,
            garage_admin,
            master_key,
        }
    }

    /// Create a new bucket: provision in Garage, then persist metadata.
    pub async fn create_bucket(
        &self,
        input: NewStorageBucket,
    ) -> Result<StorageBucket, StorageError> {
        let garage_bucket = generate_garage_bucket_alias(input.customer_id);
        let garage_info = self
            .garage_admin
            .create_bucket(&garage_bucket)
            .await
            .map_err(|e| StorageError::GarageAdmin(e.to_string()))?;

        match self.bucket_repo.create(input, &garage_bucket).await {
            Ok(bucket) => Ok(bucket),
            Err(err) => {
                let _ = self.garage_admin.delete_bucket(&garage_info.id).await;
                Err(StorageError::from(err))
            }
        }
    }

    /// Soft-delete a bucket after its Garage bucket has been removed.
    pub async fn delete_bucket(&self, id: Uuid) -> Result<(), StorageError> {
        let bucket = self.active_bucket(id).await?;

        let garage_bucket = match self
            .garage_admin
            .get_bucket_by_alias(&bucket.garage_bucket)
            .await
        {
            Ok(garage_bucket) => Some(garage_bucket),
            Err(err) if garage_bucket_was_already_deleted(&err) => None,
            Err(err) => return Err(err),
        };

        if let Some(garage_bucket) = garage_bucket {
            self.garage_admin.delete_bucket(&garage_bucket.id).await?;
        }

        self.revoke_bucket_access_keys(id).await?;
        self.bucket_repo.set_deleted(id).await?;
        Ok(())
    }

    /// Create a new access key for a bucket: generate key pair, encrypt secret,
    /// provision in Garage with bucket permissions, persist to DB.
    pub async fn create_access_key(
        &self,
        input: NewStorageAccessKey,
    ) -> Result<StorageAccessKey, StorageError> {
        let bucket = self.active_bucket(input.bucket_id).await?;

        if bucket.customer_id != input.customer_id {
            return Err(StorageError::NotFound(
                "bucket not found for customer".to_string(),
            ));
        }

        let access_key = generate_access_key();
        let secret_key = generate_secret_key();

        let (encrypted, nonce) = encrypt_secret(&secret_key, &self.master_key)
            .map_err(|e| StorageError::Encryption(e.to_string()))?;

        let garage_bucket = self
            .garage_admin
            .get_bucket_by_alias(&bucket.garage_bucket)
            .await
            .map_err(|e| StorageError::GarageAdmin(e.to_string()))?;

        let garage_key = self
            .garage_admin
            .create_key(&access_key)
            .await
            .map_err(|e| StorageError::GarageAdmin(e.to_string()))?;

        if let Err(err) = self
            .garage_admin
            .allow_key(&garage_bucket.id, &garage_key.id, true, true)
            .await
        {
            let _ = self.garage_admin.delete_key(&garage_key.id).await;
            return Err(StorageError::GarageAdmin(err.to_string()));
        }

        let prepared = PreparedStorageAccessKey {
            customer_id: input.customer_id,
            bucket_id: input.bucket_id,
            access_key: access_key.clone(),
            garage_access_key_id: garage_key.id.clone(),
            secret_key_enc: encrypted,
            secret_key_nonce: nonce,
            label: input.label,
        };

        let row = match self.key_repo.create(prepared).await {
            Ok(row) => row,
            Err(err) => {
                let _ = self.garage_admin.delete_key(&garage_key.id).await;
                return Err(StorageError::from(err));
            }
        };

        Ok(StorageAccessKey {
            id: row.id,
            customer_id: row.customer_id,
            bucket_id: row.bucket_id,
            access_key,
            secret_key,
            label: row.label,
            created_at: row.created_at,
        })
    }

    /// Revoke an access key after deleting the backing Garage key.
    pub async fn revoke_access_key(&self, id: Uuid) -> Result<(), StorageError> {
        let key = self
            .key_repo
            .get(id)
            .await?
            .ok_or_else(|| StorageError::NotFound("access key not found".to_string()))?;

        if key.revoked_at.is_some() {
            return Err(StorageError::NotFound("access key not found".to_string()));
        }

        self.garage_admin
            .delete_key(&key.garage_access_key_id)
            .await
            .map_err(|e| StorageError::GarageAdmin(e.to_string()))?;

        self.key_repo.revoke(id).await.map_err(StorageError::from)
    }

    /// List all active buckets for a customer.
    pub async fn list_buckets(
        &self,
        customer_id: Uuid,
    ) -> Result<Vec<StorageBucket>, StorageError> {
        self.bucket_repo
            .list_by_customer(customer_id)
            .await
            .map_err(StorageError::from)
    }

    /// Get a single bucket by ID.
    pub async fn get_bucket(&self, id: Uuid) -> Result<Option<StorageBucket>, StorageError> {
        self.bucket_repo
            .get(id)
            .await
            .map(|bucket| bucket.filter(is_active_bucket))
            .map_err(StorageError::from)
    }

    /// Decrypt the secret key from a stored access key row.
    pub fn decrypt_key_secret(
        &self,
        encrypted: &[u8],
        nonce: &[u8],
    ) -> Result<String, StorageError> {
        decrypt_secret(encrypted, nonce, &self.master_key)
            .map_err(|e| StorageError::Encryption(e.to_string()))
    }

    async fn active_bucket(&self, id: Uuid) -> Result<StorageBucket, StorageError> {
        self.bucket_repo
            .get(id)
            .await
            .map_err(StorageError::from)?
            .filter(is_active_bucket)
            .ok_or_else(|| StorageError::NotFound("bucket not found".to_string()))
    }

    /// Revokes all active access keys for a bucket: deletes each key from
    /// Garage via the admin API, then marks it revoked in the local repo.
    async fn revoke_bucket_access_keys(&self, bucket_id: Uuid) -> Result<(), StorageError> {
        let active_keys = self
            .key_repo
            .list_active_for_bucket(bucket_id)
            .await
            .map_err(StorageError::from)?;

        for key in active_keys {
            self.garage_admin
                .delete_key(&key.garage_access_key_id)
                .await
                .map_err(|e| StorageError::GarageAdmin(e.to_string()))?;
            self.key_repo
                .revoke(key.id)
                .await
                .map_err(StorageError::from)?;
        }

        Ok(())
    }
}

fn is_active_bucket(bucket: &StorageBucket) -> bool {
    bucket.status != "deleted"
}

fn garage_bucket_was_already_deleted(err: &StorageError) -> bool {
    matches!(err, StorageError::GarageAdmin(message) if message.contains("HTTP 404"))
}

fn generate_garage_bucket_alias(customer_id: Uuid) -> String {
    let customer = customer_id.simple().to_string();
    let suffix = Uuid::new_v4().simple().to_string();
    format!("gridl-{customer}-{}", &suffix[..12])
}
