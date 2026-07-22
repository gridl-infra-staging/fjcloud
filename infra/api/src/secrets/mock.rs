use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use chrono::{DateTime, Utc};

use super::{NodeSecretError, NodeSecretManager, NodeSecretRecord};

pub struct MockNodeSecretManager {
    secrets: Mutex<HashMap<String, String>>,
    previous_secrets: Mutex<HashMap<String, String>>,
    modified_at: Mutex<HashMap<String, DateTime<Utc>>>,
    previous_modified_at: Mutex<HashMap<String, DateTime<Utc>>>,
    pub should_fail: Arc<AtomicBool>,
    next_key_counter: Mutex<u64>,
    get_call_count: AtomicU64,
    delete_call_count: AtomicU64,
}

impl MockNodeSecretManager {
    pub fn new() -> Self {
        Self {
            secrets: Mutex::new(HashMap::new()),
            previous_secrets: Mutex::new(HashMap::new()),
            modified_at: Mutex::new(HashMap::new()),
            previous_modified_at: Mutex::new(HashMap::new()),
            should_fail: Arc::new(AtomicBool::new(false)),
            next_key_counter: Mutex::new(0),
            get_call_count: AtomicU64::new(0),
            delete_call_count: AtomicU64::new(0),
        }
    }

    /// Returns how many times `get_node_api_key` was called (for cache verification tests).
    pub fn get_read_count(&self) -> u64 {
        self.get_call_count.load(Ordering::SeqCst)
    }

    pub fn set_should_fail(&self, fail: bool) {
        self.should_fail.store(fail, Ordering::SeqCst);
    }

    pub fn delete_call_count(&self) -> u64 {
        self.delete_call_count.load(Ordering::SeqCst)
    }

    pub fn seed_listed_key_at(&self, node_id: &str, previous: bool, modified_at: DateTime<Utc>) {
        let key = format!("seed-{node_id}");
        if previous {
            self.previous_secrets
                .lock()
                .unwrap()
                .insert(node_id.to_string(), key);
            self.previous_modified_at
                .lock()
                .unwrap()
                .insert(node_id.to_string(), modified_at);
        } else {
            self.secrets
                .lock()
                .unwrap()
                .insert(node_id.to_string(), key);
            self.modified_at
                .lock()
                .unwrap()
                .insert(node_id.to_string(), modified_at);
        }
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
        self.modified_at
            .lock()
            .unwrap()
            .insert(node_id.to_string(), Utc::now());

        Ok(key)
    }

    async fn delete_node_api_key(
        &self,
        node_id: &str,
        _region: &str,
    ) -> Result<(), NodeSecretError> {
        self.delete_call_count.fetch_add(1, Ordering::SeqCst);
        self.check_failure()?;
        self.secrets.lock().unwrap().remove(node_id);
        self.previous_secrets.lock().unwrap().remove(node_id);
        self.modified_at.lock().unwrap().remove(node_id);
        self.previous_modified_at.lock().unwrap().remove(node_id);
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
        self.previous_modified_at
            .lock()
            .unwrap()
            .insert(node_id.to_string(), Utc::now());
        let new_key = self.generate_key();
        secrets.insert(node_id.to_string(), new_key.clone());
        self.modified_at
            .lock()
            .unwrap()
            .insert(node_id.to_string(), Utc::now());

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
            self.previous_modified_at.lock().unwrap().remove(node_id);
        }

        Ok(())
    }

    async fn list_node_api_keys(&self) -> Result<Vec<NodeSecretRecord>, NodeSecretError> {
        self.check_failure()?;
        let current = self.secrets.lock().unwrap();
        let current_modified = self.modified_at.lock().unwrap();
        let previous = self.previous_secrets.lock().unwrap();
        let previous_modified = self.previous_modified_at.lock().unwrap();
        let mut listed = current
            .keys()
            .map(|node_id| NodeSecretRecord {
                node_id: node_id.clone(),
                path: format!("/fjcloud/nodes/{node_id}/api-key"),
                last_modified_at: current_modified
                    .get(node_id)
                    .cloned()
                    .unwrap_or_else(Utc::now),
            })
            .chain(previous.keys().map(|node_id| {
                NodeSecretRecord {
                    node_id: node_id.clone(),
                    path: format!("/fjcloud/nodes/{node_id}/api-key-previous"),
                    last_modified_at: previous_modified
                        .get(node_id)
                        .cloned()
                        .unwrap_or_else(Utc::now),
                }
            }))
            .collect::<Vec<_>>();
        listed.sort_by(|left, right| left.path.cmp(&right.path));
        Ok(listed)
    }
}
