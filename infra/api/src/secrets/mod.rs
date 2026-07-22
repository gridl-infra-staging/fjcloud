pub mod aws;
pub mod memory;
pub mod mock;

use async_trait::async_trait;
use chrono::{DateTime, Utc};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NodeSecretRecord {
    pub node_id: String,
    pub path: String,
    pub last_modified_at: DateTime<Utc>,
}

#[derive(Debug, thiserror::Error)]
pub enum NodeSecretError {
    #[error("secret store API error: {0}")]
    Api(String),

    #[error("secret store not configured")]
    NotConfigured,

    #[error("node secret listing is not supported")]
    ListingUnsupported,
}

/// Manages per-node secrets (API keys) stored in a secret backend (e.g. AWS SSM).
///
/// The provisioning service calls `create_node_api_key` before launching a VM
/// so the node can read its API key at boot. On termination, `delete_node_api_key`
/// cleans up both the current key and any previous rotation-overlap key.
///
/// Replication key rotation APIs are used when a node key is renewed for a
/// rolling rotation flow. `rotate_node_api_key` returns the `(old_key, new_key)`
/// pair so callsites can keep overlap windows until peers are updated.
#[async_trait]
pub trait NodeSecretManager: Send + Sync {
    /// Generate and store an API key for the given node. Returns the plaintext key.
    async fn create_node_api_key(
        &self,
        node_id: &str,
        region: &str,
    ) -> Result<String, NodeSecretError>;

    /// Delete stored API keys for the given node, including the current key and
    /// any previous rotation-overlap key (cleanup on termination).
    async fn delete_node_api_key(&self, node_id: &str, region: &str)
        -> Result<(), NodeSecretError>;

    /// Retrieve the stored API key for the given node.
    async fn get_node_api_key(
        &self,
        node_id: &str,
        region: &str,
    ) -> Result<String, NodeSecretError>;

    /// Rotate the stored API key for a node, returning old + new key values.
    ///
    /// Callers should continue accepting both keys during the overlap window.
    async fn rotate_node_api_key(
        &self,
        node_id: &str,
        region: &str,
    ) -> Result<(String, String), NodeSecretError>;

    /// Finalize a rotation by deleting the old key after an overlap period.
    async fn commit_rotation(
        &self,
        node_id: &str,
        region: &str,
        old_key: &str,
    ) -> Result<(), NodeSecretError>;

    /// Enumerate all current and rotation-overlap node API keys. Backends that
    /// cannot guarantee exhaustive enumeration must fail closed.
    async fn list_node_api_keys(&self) -> Result<Vec<NodeSecretRecord>, NodeSecretError> {
        Err(NodeSecretError::ListingUnsupported)
    }
}

/// Returns `NodeSecretError::NotConfigured` for all methods.
/// Used in dev mode when AWS SSM is not available.
pub struct UnconfiguredNodeSecretManager;

#[async_trait]
impl NodeSecretManager for UnconfiguredNodeSecretManager {
    async fn create_node_api_key(
        &self,
        _node_id: &str,
        _region: &str,
    ) -> Result<String, NodeSecretError> {
        Err(NodeSecretError::NotConfigured)
    }

    async fn delete_node_api_key(
        &self,
        _node_id: &str,
        _region: &str,
    ) -> Result<(), NodeSecretError> {
        Err(NodeSecretError::NotConfigured)
    }

    async fn get_node_api_key(
        &self,
        _node_id: &str,
        _region: &str,
    ) -> Result<String, NodeSecretError> {
        Err(NodeSecretError::NotConfigured)
    }

    async fn rotate_node_api_key(
        &self,
        _node_id: &str,
        _region: &str,
    ) -> Result<(String, String), NodeSecretError> {
        Err(NodeSecretError::NotConfigured)
    }

    async fn commit_rotation(
        &self,
        _node_id: &str,
        _region: &str,
        _old_key: &str,
    ) -> Result<(), NodeSecretError> {
        Err(NodeSecretError::NotConfigured)
    }
}
