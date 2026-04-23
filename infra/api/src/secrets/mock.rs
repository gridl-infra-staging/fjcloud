//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/secrets/mock.rs.
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;

use super::{NodeSecretError, NodeSecretManager};

pub struct MockNodeSecretManager {
    secrets: Mutex<HashMap<String, String>>,
    previous_secrets: Mutex<HashMap<String, String>>,
    pub should_fail: Arc<AtomicBool>,
    next_key_counter: Mutex<u64>,
    get_call_count: AtomicU64,
}

impl MockNodeSecretManager {
    pub fn new() -> Self {
        Self {
            secrets: Mutex::new(HashMap::new()),
            previous_secrets: Mutex::new(HashMap::new()),
            should_fail: Arc::new(AtomicBool::new(false)),
            next_key_counter: Mutex::new(0),
            get_call_count: AtomicU64::new(0),
        }
    }

    /// Returns how many times `get_node_api_key` was called (for cache verification tests).
    pub fn get_read_count(&self) -> u64 {
        self.get_call_count.load(Ordering::SeqCst)
    }

    pub fn set_should_fail(&self, fail: bool) {
        self.should_fail.store(fail, Ordering::SeqCst);
    }

    /// Returns the number of secrets currently stored (for test assertions).
    pub fn secret_count(&self) -> usize {
        self.secrets.lock().unwrap().len()
    }

    /// Returns the stored API key for a given node_id, if any.
    pub fn get_secret(&self, node_id: &str) -> Option<String> {
        let secrets = self.secrets.lock().unwrap();
        secrets.get(node_id).cloned()
    }

    /// Returns the previous (pre-rotation) key for a given node_id, if any.
    /// Present only between `rotate_node_api_key` and `commit_rotation`.
    pub fn get_previous_secret(&self, node_id: &str) -> Option<String> {
        let previous = self.previous_secrets.lock().unwrap();
        previous.get(node_id).cloned()
    }

    fn generate_key(&self) -> String {
        let mut counter = self.next_key_counter.lock().unwrap();
        *counter += 1;
        let c = *counter;
        format!("fj_live_mock_{c:032x}")
    }

    fn check_failure(&self) -> Result<(), NodeSecretError> {
        if self.should_fail.load(Ordering::SeqCst) {
            Err(NodeSecretError::Api("injected failure".into()))
        } else {
            Ok(())
        }
    }
}

impl Default for MockNodeSecretManager {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl NodeSecretManager for MockNodeSecretManager {
    async fn create_node_api_key(
        &self,
        node_id: &str,
        _region: &str,
    ) -> Result<String, NodeSecretError> {
        self.check_failure()?;
        let key = self.generate_key();
        self.secrets
            .lock()
            .unwrap()
            .insert(node_id.to_string(), key.clone());

        Ok(key)
    }

    async fn delete_node_api_key(
        &self,
        node_id: &str,
        _region: &str,
    ) -> Result<(), NodeSecretError> {
        self.check_failure()?;
        self.secrets.lock().unwrap().remove(node_id);
        Ok(())
    }

    async fn get_node_api_key(
        &self,
        node_id: &str,
        _region: &str,
    ) -> Result<String, NodeSecretError> {
        self.check_failure()?;
        self.get_call_count.fetch_add(1, Ordering::SeqCst);
        self.secrets
            .lock()
            .unwrap()
            .get(node_id)
            .cloned()
            .ok_or_else(|| NodeSecretError::Api(format!("no key found for node {node_id}")))
    }

    /// Rotates the key using the same protocol as the real implementations,
    /// with injectable failure via `check_failure()`.
    async fn rotate_node_api_key(
        &self,
        node_id: &str,
        _region: &str,
    ) -> Result<(String, String), NodeSecretError> {
        self.check_failure()?;

        let mut secrets = self.secrets.lock().unwrap();
        let mut previous = self.previous_secrets.lock().unwrap();
        let old_key = secrets
            .get(node_id)
            .cloned()
            .ok_or_else(|| NodeSecretError::Api(format!("no key found for node {node_id}")))?;

        previous.insert(node_id.to_string(), old_key.clone());
        let new_key = self.generate_key();
        secrets.insert(node_id.to_string(), new_key.clone());

        Ok((old_key, new_key))
    }

    /// Commits rotation using the same protocol, with injectable failure.
    async fn commit_rotation(
        &self,
        node_id: &str,
        _region: &str,
        old_key: &str,
    ) -> Result<(), NodeSecretError> {
        self.check_failure()?;
        let mut previous = self.previous_secrets.lock().unwrap();

        if previous
            .get(node_id)
            .is_some_and(|previous| previous == old_key)
        {
            previous.remove(node_id);
        }

        Ok(())
    }
}
