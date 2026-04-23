//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/storage/garage_admin.rs.
use async_trait::async_trait;
use serde::de::DeserializeOwned;
use serde::Deserialize;

use super::StorageError;

/// Info returned when Garage creates a bucket.
#[derive(Debug, Clone)]
pub struct GarageBucketInfo {
    pub id: String,
}

/// Info returned when Garage creates an access key.
#[derive(Debug, Clone)]
pub struct GarageKeyInfo {
    pub id: String,
    pub secret_key: String,
}

/// Async trait for interacting with the Garage admin API.
/// Production: `ReqwestGarageAdminClient`. Tests: `MockGarageAdminClient`.
#[async_trait]
pub trait GarageAdminClient: Send + Sync {
    /// Create a new bucket in Garage.
    async fn create_bucket(&self, name: &str) -> Result<GarageBucketInfo, StorageError>;

    /// Resolve a bucket's Garage ID from its global alias.
    async fn get_bucket_by_alias(
        &self,
        global_alias: &str,
    ) -> Result<GarageBucketInfo, StorageError>;

    /// Delete a bucket from Garage by its Garage-internal ID.
    async fn delete_bucket(&self, id: &str) -> Result<(), StorageError>;

    /// Create a new API key in Garage.
    async fn create_key(&self, name: &str) -> Result<GarageKeyInfo, StorageError>;

    /// Delete an API key from Garage.
    async fn delete_key(&self, id: &str) -> Result<(), StorageError>;

    /// Grant read/write permissions on a bucket to a key.
    async fn allow_key(
        &self,
        bucket_id: &str,
        key_id: &str,
        allow_read: bool,
        allow_write: bool,
    ) -> Result<(), StorageError>;
}

/// Production client using reqwest + bearer-token auth against Garage admin API.
pub struct ReqwestGarageAdminClient {
    client: reqwest::Client,
    endpoint: String,
    token: String,
}

impl ReqwestGarageAdminClient {
    pub fn new(client: reqwest::Client, endpoint: String, token: String) -> Self {
        Self {
            client,
            endpoint,
            token,
        }
    }

    pub fn from_env(client: reqwest::Client) -> Self {
        let endpoint = std::env::var("GARAGE_ADMIN_ENDPOINT")
            .unwrap_or_else(|_| "http://127.0.0.1:3903".to_string());
        let token = std::env::var("GARAGE_ADMIN_TOKEN").unwrap_or_default();
        Self::new(client, endpoint, token)
    }

    fn url(&self, path: &str) -> String {
        format!("{}/v2/{}", self.endpoint.trim_end_matches('/'), path)
    }

    /// Sends a pre-built request and checks for a success status. Returns
    /// the response on 2xx; on failure reads the body and returns a
    /// [`StorageError::GarageAdmin`] with the HTTP status and body text.
    async fn send(
        &self,
        request: reqwest::RequestBuilder,
        action: &str,
    ) -> Result<reqwest::Response, StorageError> {
        let response = request
            .send()
            .await
            .map_err(|e| StorageError::GarageAdmin(format!("{action} request failed: {e}")))?;

        if response.status().is_success() {
            return Ok(response);
        }

        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        Err(StorageError::GarageAdmin(format!(
            "{action} returned HTTP {status}: {body}"
        )))
    }

    /// POSTs a JSON body to the Garage admin v2 API with bearer-token
    /// authentication, then deserializes the response into `T`.
    async fn post_json<T: DeserializeOwned>(
        &self,
        path: &str,
        action: &str,
        body: serde_json::Value,
    ) -> Result<T, StorageError> {
        let response = self
            .send(
                self.client
                    .post(self.url(path))
                    .bearer_auth(&self.token)
                    .json(&body),
                action,
            )
            .await?;

        response.json().await.map_err(|e| {
            StorageError::GarageAdmin(format!("failed to parse {action} response: {e}"))
        })
    }

    /// GETs a JSON resource from the Garage admin v2 API with bearer-token
    /// authentication and optional query parameters, then deserializes the
    /// response into `T`.
    async fn get_json<T: DeserializeOwned>(
        &self,
        path: &str,
        action: &str,
        query: &[(&str, &str)],
    ) -> Result<T, StorageError> {
        let response = self
            .send(
                self.client
                    .get(self.url(path))
                    .bearer_auth(&self.token)
                    .query(query),
                action,
            )
            .await?;

        response.json().await.map_err(|e| {
            StorageError::GarageAdmin(format!("failed to parse {action} response: {e}"))
        })
    }

    /// POSTs to the Garage admin v2 API with bearer-token authentication
    /// and query parameters but no request body. Discards the response on
    /// success.
    async fn post_without_body(
        &self,
        path: &str,
        action: &str,
        query: &[(&str, &str)],
    ) -> Result<(), StorageError> {
        self.send(
            self.client
                .post(self.url(path))
                .bearer_auth(&self.token)
                .query(query),
            action,
        )
        .await?;
        Ok(())
    }
}

// Response types for Garage admin API JSON deserialization.

#[derive(Deserialize)]
struct GarageBucketResponse {
    id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GarageKeyResponse {
    access_key_id: String,
    secret_access_key: String,
}

#[async_trait]
impl GarageAdminClient for ReqwestGarageAdminClient {
    async fn create_bucket(&self, name: &str) -> Result<GarageBucketInfo, StorageError> {
        self.post_json(
            "CreateBucket",
            "create bucket",
            serde_json::json!({
                "globalAlias": name
            }),
        )
        .await
        .map(|parsed: GarageBucketResponse| GarageBucketInfo { id: parsed.id })
    }

    async fn get_bucket_by_alias(
        &self,
        global_alias: &str,
    ) -> Result<GarageBucketInfo, StorageError> {
        self.get_json(
            "GetBucketInfo",
            "get bucket info",
            &[("globalAlias", global_alias)],
        )
        .await
        .map(|parsed: GarageBucketResponse| GarageBucketInfo { id: parsed.id })
    }

    async fn delete_bucket(&self, id: &str) -> Result<(), StorageError> {
        self.post_without_body("DeleteBucket", "delete bucket", &[("id", id)])
            .await
    }

    async fn create_key(&self, name: &str) -> Result<GarageKeyInfo, StorageError> {
        self.post_json(
            "CreateKey",
            "create key",
            serde_json::json!({ "name": name }),
        )
        .await
        .map(|parsed: GarageKeyResponse| GarageKeyInfo {
            id: parsed.access_key_id,
            secret_key: parsed.secret_access_key,
        })
    }

    async fn delete_key(&self, id: &str) -> Result<(), StorageError> {
        self.post_without_body("DeleteKey", "delete key", &[("id", id)])
            .await
    }

    /// Grants read and/or write permissions for an access key on a bucket
    /// via the Garage `AllowBucketKey` admin endpoint. The `owner`
    /// permission is always set to `false`.
    async fn allow_key(
        &self,
        bucket_id: &str,
        key_id: &str,
        allow_read: bool,
        allow_write: bool,
    ) -> Result<(), StorageError> {
        let _: serde_json::Value = self
            .post_json(
                "AllowBucketKey",
                "allow key",
                serde_json::json!({
                    "bucketId": bucket_id,
                    "accessKeyId": key_id,
                    "permissions": {
                        "read": allow_read,
                        "write": allow_write,
                        "owner": false
                    }
                }),
            )
            .await?;
        Ok(())
    }
}
