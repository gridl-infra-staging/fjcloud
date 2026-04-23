//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/secrets/memory.rs.
use std::collections::HashMap;
use std::sync::Mutex;

use async_trait::async_trait;
use rand::RngCore;

use super::{NodeSecretError, NodeSecretManager};

/// In-memory NodeSecretManager intended for local development.
///
/// Keys are process-local and lost on API restart.
pub struct InMemoryNodeSecretManager {
    secrets: Mutex<HashMap<String, String>>,
    previous_secrets: Mutex<HashMap<String, String>>,
    fixed_admin_key: Option<String>,
}

impl InMemoryNodeSecretManager {
    pub fn new() -> Self {
        Self {
            secrets: Mutex::new(HashMap::new()),
            previous_secrets: Mutex::new(HashMap::new()),
            fixed_admin_key: std::env::var("FLAPJACK_ADMIN_KEY")
                .ok()
                .filter(|key| !key.is_empty()),
        }
    }

    fn generate_api_key() -> String {
        let mut key_bytes = [0u8; 32];
        rand::thread_rng().fill_bytes(&mut key_bytes);
        format!("fj_live_{}", hex::encode(key_bytes))
    }
}

impl Default for InMemoryNodeSecretManager {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl NodeSecretManager for InMemoryNodeSecretManager {
    async fn create_node_api_key(
        &self,
        node_id: &str,
        _region: &str,
    ) -> Result<String, NodeSecretError> {
        let key = self
            .fixed_admin_key
            .clone()
            .unwrap_or_else(Self::generate_api_key);
        self.secrets
            .lock()
            .expect("memory secret map poisoned")
            .insert(node_id.to_string(), key.clone());
        Ok(key)
    }

    async fn delete_node_api_key(
        &self,
        node_id: &str,
        _region: &str,
    ) -> Result<(), NodeSecretError> {
        self.secrets
            .lock()
            .expect("memory secret map poisoned")
            .remove(node_id);
        self.previous_secrets
            .lock()
            .expect("memory previous-secret map poisoned")
            .remove(node_id);
        Ok(())
    }

    async fn get_node_api_key(
        &self,
        node_id: &str,
        _region: &str,
    ) -> Result<String, NodeSecretError> {
        self.secrets
            .lock()
            .expect("memory secret map poisoned")
            .get(node_id)
            .cloned()
            .ok_or_else(|| NodeSecretError::Api(format!("no key found for node {node_id}")))
    }

    /// Rotates the key using the same protocol as SSM: moves the old key to
    /// a `-previous` entry in the HashMap, then stores the new key.
    async fn rotate_node_api_key(
        &self,
        node_id: &str,
        _region: &str,
    ) -> Result<(String, String), NodeSecretError> {
        let mut secrets = self.secrets.lock().expect("memory secret map poisoned");
        let mut previous = self
            .previous_secrets
            .lock()
            .expect("memory previous-secret map poisoned");

        let old_key = secrets
            .get(node_id)
            .cloned()
            .ok_or_else(|| NodeSecretError::Api(format!("no key found for node {node_id}")))?;

        previous.insert(node_id.to_string(), old_key.clone());
        let new_key = Self::generate_api_key();
        secrets.insert(node_id.to_string(), new_key.clone());
        Ok((old_key, new_key))
    }

    /// Verifies `old_key` matches the `-previous` entry, then removes it.
    async fn commit_rotation(
        &self,
        node_id: &str,
        _region: &str,
        old_key: &str,
    ) -> Result<(), NodeSecretError> {
        let mut previous = self
            .previous_secrets
            .lock()
            .expect("memory previous-secret map poisoned");

        if previous
            .get(node_id)
            .is_some_and(|previous| previous == old_key)
        {
            previous.remove(node_id);
        }

        Ok(())
    }
}
