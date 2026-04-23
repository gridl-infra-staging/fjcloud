//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/cold_tier/pipeline.rs.
use std::collections::HashMap;
use std::time::Duration as StdDuration;

use sha2::{Digest, Sha256};
use tracing::{info, warn};
use uuid::Uuid;

use crate::models::cold_snapshot::NewColdSnapshot;
use crate::services::alerting::{Alert, AlertSeverity};
use crate::services::flapjack_node::{flapjack_index_uid, get_or_create_node_api_key};

use super::{ColdTierCandidate, ColdTierError, ColdTierService};

struct SnapshotPayload {
    bytes: Vec<u8>,
    checksum: String,
    size_bytes: i64,
}

impl SnapshotPayload {
    fn from_bytes(bytes: Vec<u8>) -> Self {
        Self {
            checksum: hex::encode(Sha256::digest(&bytes)),
            size_bytes: bytes.len() as i64,
            bytes,
        }
    }
}

impl ColdTierService {
    /// Execute the full snapshot pipeline for a single candidate.
    /// The `region` parameter selects the cold storage endpoint for this snapshot.
    /// Returns the snapshot ID on success.
    pub async fn snapshot_candidate(
        &self,
        candidate: &ColdTierCandidate,
        flapjack_url: &str,
        region: &str,
    ) -> Result<Uuid, ColdTierError> {
        let object_key = Self::build_snapshot_object_key(candidate, region, Uuid::new_v4());
        let source_vm = self.source_vm_for_candidate(candidate).await?;
        let node_api_key = self.node_api_key_for_source_vm(&source_vm).await?;
        let flapjack_uid = flapjack_index_uid(candidate.customer_id, &candidate.tenant_id);
        let snapshot_id = self.begin_snapshot_record(candidate, &object_key).await?;
        let payload = self
            .export_snapshot_payload(flapjack_url, &flapjack_uid, &node_api_key)
            .await?;

        self.upload_snapshot_payload(region, &object_key, &payload)
            .await?;
        self.finalize_snapshot_record(snapshot_id, &payload).await?;
        self.transition_tenant_to_cold_storage(candidate, snapshot_id)
            .await?;
        self.evict_snapshot_source_index(flapjack_url, &flapjack_uid, &node_api_key)
            .await?;
        self.record_snapshot_success(candidate, snapshot_id, payload.size_bytes)
            .await;

        info!(
            customer_id = %candidate.customer_id,
            tenant_id = %candidate.tenant_id,
            snapshot_id = %snapshot_id,
            size_bytes = payload.size_bytes,
            "cold tier snapshot completed"
        );

        Ok(snapshot_id)
    }

    /// Handle a failed snapshot attempt: mark snapshot as failed, track retry count,
    /// reset tier to active if we haven't exceeded max retries, or fire critical alert.
    pub async fn handle_snapshot_failure(
        &self,
        candidate: &ColdTierCandidate,
        snapshot_id: Option<Uuid>,
        error: &str,
    ) {
        self.mark_snapshot_failed(snapshot_id, error).await;

        let retry_count = self.increment_snapshot_retry_count(candidate);
        self.rollback_tenant_snapshot_state(candidate).await;

        if self.reached_retry_limit(retry_count) {
            self.send_snapshot_failure_alert(
                candidate,
                retry_count,
                AlertSeverity::Critical,
                "Cold tier snapshot permanently failed",
                format!(
                    "Index '{}' (customer {}) failed cold snapshot after {} retries. Last error: {}",
                    candidate.tenant_id, candidate.customer_id, retry_count, error
                ),
            )
            .await;
            self.log_terminal_snapshot_failure(candidate, retry_count, error);
            return;
        }

        self.send_snapshot_failure_alert(
            candidate,
            retry_count,
            AlertSeverity::Warning,
            "Cold tier snapshot failed (will retry)",
            format!(
                "Index '{}' (customer {}) snapshot failed (attempt {}/{}): {}",
                candidate.tenant_id,
                candidate.customer_id,
                retry_count,
                self.config.max_snapshot_retries,
                error
            ),
        )
        .await;
        self.log_retryable_snapshot_failure(candidate, retry_count, error);
    }

    /// Runs the snapshot pipeline for a candidate with a timeout guard.
    /// On success, logs the result; on failure or timeout, delegates to
    /// [`handle_snapshot_error`] for rollback and alerting.
    pub(super) async fn snapshot_or_handle_failure(
        &self,
        candidate: &ColdTierCandidate,
        flapjack_url: &str,
        region: &str,
    ) {
        let snapshot_result = tokio::time::timeout(
            StdDuration::from_secs(self.config.snapshot_timeout_secs),
            self.snapshot_candidate(candidate, flapjack_url, region),
        )
        .await;

        match snapshot_result {
            Ok(Ok(snapshot_id)) => {
                info!(
                    tenant_id = %candidate.tenant_id,
                    snapshot_id = %snapshot_id,
                    "snapshot cycle: successfully snapshotted candidate"
                );
            }
            Ok(Err(e)) => {
                self.handle_snapshot_error(candidate, &e.to_string()).await;
            }
            Err(_) => {
                let timeout_error = format!(
                    "snapshot timed out after {} seconds",
                    self.config.snapshot_timeout_secs
                );
                self.handle_snapshot_error(candidate, &timeout_error).await;
            }
        }
    }

    fn build_snapshot_object_key(
        candidate: &ColdTierCandidate,
        region: &str,
        object_id: Uuid,
    ) -> String {
        format!(
            "cold/{}/{}/{}/{}.fj",
            region, candidate.customer_id, candidate.tenant_id, object_id
        )
    }

    /// Sets the tenant's tier to `"cold"`, creates a new snapshot record in
    /// the repo, and marks it as `"exporting"`. Returns the snapshot ID.
    async fn begin_snapshot_record(
        &self,
        candidate: &ColdTierCandidate,
        object_key: &str,
    ) -> Result<Uuid, ColdTierError> {
        self.tenant_repo
            .set_tier(candidate.customer_id, &candidate.tenant_id, "cold")
            .await
            .map_err(|e| ColdTierError::Repo(e.to_string()))?;

        let snapshot = self
            .cold_snapshot_repo
            .create(NewColdSnapshot {
                customer_id: candidate.customer_id,
                tenant_id: candidate.tenant_id.clone(),
                source_vm_id: candidate.source_vm_id,
                object_key: object_key.to_string(),
            })
            .await
            .map_err(|e| ColdTierError::Repo(e.to_string()))?;

        self.cold_snapshot_repo
            .set_exporting(snapshot.id)
            .await
            .map_err(|e| ColdTierError::Repo(e.to_string()))?;

        Ok(snapshot.id)
    }

    async fn export_snapshot_payload(
        &self,
        flapjack_url: &str,
        flapjack_uid: &str,
        node_api_key: &str,
    ) -> Result<SnapshotPayload, ColdTierError> {
        let bytes = self
            .node_client
            .export_index(flapjack_url, flapjack_uid, node_api_key)
            .await?;
        Ok(SnapshotPayload::from_bytes(bytes))
    }

    async fn source_vm_for_candidate(
        &self,
        candidate: &ColdTierCandidate,
    ) -> Result<crate::models::vm_inventory::VmInventory, ColdTierError> {
        self.vm_inventory_repo
            .get(candidate.source_vm_id)
            .await
            .map_err(|e| ColdTierError::Repo(e.to_string()))?
            .ok_or_else(|| {
                ColdTierError::Export(format!(
                    "source VM {} not found for index '{}'",
                    candidate.source_vm_id, candidate.tenant_id
                ))
            })
    }

    async fn node_api_key_for_source_vm(
        &self,
        vm: &crate::models::vm_inventory::VmInventory,
    ) -> Result<String, ColdTierError> {
        get_or_create_node_api_key(self.node_secret_manager.as_ref(), vm)
            .await
            .map_err(|e| {
                ColdTierError::Export(format!(
                    "failed to load admin key for source VM {}: {e}",
                    vm.id
                ))
            })
    }

    async fn upload_snapshot_payload(
        &self,
        region: &str,
        object_key: &str,
        payload: &SnapshotPayload,
    ) -> Result<(), ColdTierError> {
        let object_store = self.object_store_resolver.for_region(region);
        object_store
            .put(object_key, &payload.bytes)
            .await
            .map_err(|e| ColdTierError::Upload(e.to_string()))
    }

    async fn finalize_snapshot_record(
        &self,
        snapshot_id: Uuid,
        payload: &SnapshotPayload,
    ) -> Result<(), ColdTierError> {
        self.cold_snapshot_repo
            .set_completed(snapshot_id, payload.size_bytes, &payload.checksum)
            .await
            .map_err(|e| ColdTierError::Repo(e.to_string()))
    }

    /// Points the tenant at its completed cold snapshot and clears its VM
    /// assignment, completing the hot-to-cold transition.
    async fn transition_tenant_to_cold_storage(
        &self,
        candidate: &ColdTierCandidate,
        snapshot_id: Uuid,
    ) -> Result<(), ColdTierError> {
        self.tenant_repo
            .set_cold_snapshot_id(
                candidate.customer_id,
                &candidate.tenant_id,
                Some(snapshot_id),
            )
            .await
            .map_err(|e| ColdTierError::Repo(e.to_string()))?;

        self.tenant_repo
            .clear_vm_id(candidate.customer_id, &candidate.tenant_id)
            .await
            .map_err(|e| ColdTierError::Repo(e.to_string()))
    }

    async fn evict_snapshot_source_index(
        &self,
        flapjack_url: &str,
        flapjack_uid: &str,
        node_api_key: &str,
    ) -> Result<(), ColdTierError> {
        self.node_client
            .delete_index(flapjack_url, flapjack_uid, node_api_key)
            .await
    }

    /// Invalidates the discovery cache, sends an informational alert, and
    /// clears the retry count for this candidate after a successful snapshot.
    async fn record_snapshot_success(
        &self,
        candidate: &ColdTierCandidate,
        snapshot_id: Uuid,
        size_bytes: i64,
    ) {
        self.discovery_service
            .invalidate(candidate.customer_id, &candidate.tenant_id);

        if let Err(error) = self
            .alert_service
            .send_alert(Alert {
                severity: AlertSeverity::Info,
                title: "Index moved to cold storage".to_string(),
                message: format!(
                    "Index '{}' (customer {}) snapshotted to cold storage. Size: {} bytes",
                    candidate.tenant_id, candidate.customer_id, size_bytes
                ),
                metadata: HashMap::from([
                    ("customer_id".to_string(), candidate.customer_id.to_string()),
                    ("tenant_id".to_string(), candidate.tenant_id.clone()),
                    ("snapshot_id".to_string(), snapshot_id.to_string()),
                    ("size_bytes".to_string(), size_bytes.to_string()),
                ]),
            })
            .await
        {
            warn!(
                customer_id = %candidate.customer_id,
                tenant_id = %candidate.tenant_id,
                snapshot_id = %snapshot_id,
                error = %error,
                "failed to send cold-tier success alert"
            );
        }

        self.clear_snapshot_retry_count(candidate);
    }

    fn clear_snapshot_retry_count(&self, candidate: &ColdTierCandidate) {
        self.retry_counts
            .lock()
            .unwrap()
            .remove(&(candidate.customer_id, candidate.tenant_id.clone()));
    }

    async fn mark_snapshot_failed(&self, snapshot_id: Option<Uuid>, error: &str) {
        if let Some(snapshot_id) = snapshot_id {
            if let Err(repo_error) = self.cold_snapshot_repo.set_failed(snapshot_id, error).await {
                warn!(
                    snapshot_id = %snapshot_id,
                    error = %repo_error,
                    "failed to mark cold snapshot as failed"
                );
            }
        }
    }

    fn increment_snapshot_retry_count(&self, candidate: &ColdTierCandidate) -> u32 {
        let mut retry_counts = self.retry_counts.lock().unwrap();
        let retry_count = retry_counts
            .entry((candidate.customer_id, candidate.tenant_id.clone()))
            .or_insert(0);
        *retry_count += 1;
        *retry_count
    }

    /// Best-effort rollback: clears the tenant's `cold_snapshot_id`, restores
    /// its original `vm_id`, and resets its tier to `"active"`. Logs warnings
    /// on individual repo failures rather than propagating them.
    async fn rollback_tenant_snapshot_state(&self, candidate: &ColdTierCandidate) {
        if let Err(repo_error) = self
            .tenant_repo
            .set_cold_snapshot_id(candidate.customer_id, &candidate.tenant_id, None)
            .await
        {
            warn!(
                customer_id = %candidate.customer_id,
                tenant_id = %candidate.tenant_id,
                error = %repo_error,
                "failed to clear tenant cold_snapshot_id during rollback"
            );
        }

        if let Err(repo_error) = self
            .tenant_repo
            .set_vm_id(
                candidate.customer_id,
                &candidate.tenant_id,
                candidate.source_vm_id,
            )
            .await
        {
            warn!(
                customer_id = %candidate.customer_id,
                tenant_id = %candidate.tenant_id,
                source_vm_id = %candidate.source_vm_id,
                error = %repo_error,
                "failed to restore tenant vm_id during rollback"
            );
        }

        if let Err(repo_error) = self
            .tenant_repo
            .set_tier(candidate.customer_id, &candidate.tenant_id, "active")
            .await
        {
            warn!(
                customer_id = %candidate.customer_id,
                tenant_id = %candidate.tenant_id,
                error = %repo_error,
                "failed to reset tenant tier during rollback"
            );
        }
    }

    fn reached_retry_limit(&self, retry_count: u32) -> bool {
        retry_count >= self.config.max_snapshot_retries
    }

    async fn handle_snapshot_error(&self, candidate: &ColdTierCandidate, error: &str) {
        let snapshot_id = self.find_active_snapshot_id(candidate).await;
        self.handle_snapshot_failure(candidate, snapshot_id, error)
            .await;
    }

    /// Queries the repo for an active (non-failed) cold snapshot for this
    /// candidate's index. Returns `None` if no snapshot exists or the query fails.
    async fn find_active_snapshot_id(&self, candidate: &ColdTierCandidate) -> Option<Uuid> {
        match self
            .cold_snapshot_repo
            .find_active_for_index(candidate.customer_id, &candidate.tenant_id)
            .await
        {
            Ok(snapshot) => snapshot.map(|active_snapshot| active_snapshot.id),
            Err(repo_error) => {
                warn!(
                    customer_id = %candidate.customer_id,
                    tenant_id = %candidate.tenant_id,
                    error = %repo_error,
                    "failed to fetch active cold snapshot for failure handling"
                );
                None
            }
        }
    }

    /// Sends a cold-tier failure alert with the given severity and retry
    /// metadata. Logs a warning if the alert service call itself fails.
    async fn send_snapshot_failure_alert(
        &self,
        candidate: &ColdTierCandidate,
        retry_count: u32,
        severity: AlertSeverity,
        title: &str,
        message: String,
    ) {
        if let Err(error) = self
            .alert_service
            .send_alert(Alert {
                severity,
                title: title.to_string(),
                message,
                metadata: Self::snapshot_failure_metadata(candidate, retry_count),
            })
            .await
        {
            warn!(
                customer_id = %candidate.customer_id,
                tenant_id = %candidate.tenant_id,
                retry_count,
                error = %error,
                "failed to send cold-tier failure alert"
            );
        }
    }

    fn snapshot_failure_metadata(
        candidate: &ColdTierCandidate,
        retry_count: u32,
    ) -> HashMap<String, String> {
        HashMap::from([
            ("customer_id".to_string(), candidate.customer_id.to_string()),
            ("tenant_id".to_string(), candidate.tenant_id.clone()),
            ("retry_count".to_string(), retry_count.to_string()),
        ])
    }

    fn log_terminal_snapshot_failure(
        &self,
        candidate: &ColdTierCandidate,
        retry_count: u32,
        error: &str,
    ) {
        warn!(
            customer_id = %candidate.customer_id,
            tenant_id = %candidate.tenant_id,
            retry_count,
            error,
            "cold tier snapshot permanently failed"
        );
    }

    fn log_retryable_snapshot_failure(
        &self,
        candidate: &ColdTierCandidate,
        retry_count: u32,
        error: &str,
    ) {
        warn!(
            customer_id = %candidate.customer_id,
            tenant_id = %candidate.tenant_id,
            retry_count,
            max_retries = self.config.max_snapshot_retries,
            error,
            "cold tier snapshot failed, will retry"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_candidate() -> ColdTierCandidate {
        ColdTierCandidate {
            customer_id: Uuid::parse_str("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa").unwrap(),
            tenant_id: "my-index".to_string(),
            source_vm_id: Uuid::nil(),
            last_accessed_at: None,
        }
    }

    #[test]
    fn build_snapshot_object_key_format() {
        let candidate = test_candidate();
        let object_id = Uuid::parse_str("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb").unwrap();
        let key = ColdTierService::build_snapshot_object_key(&candidate, "us-east-1", object_id);
        assert_eq!(
            key,
            "cold/us-east-1/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/my-index/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.fj"
        );
    }

    #[test]
    fn build_snapshot_object_key_different_region() {
        let candidate = test_candidate();
        let object_id = Uuid::nil();
        let key = ColdTierService::build_snapshot_object_key(&candidate, "eu-west-1", object_id);
        assert!(key.starts_with("cold/eu-west-1/"));
    }

    #[test]
    fn snapshot_payload_from_bytes_checksum() {
        let payload = SnapshotPayload::from_bytes(b"hello world".to_vec());
        // SHA-256 of "hello world"
        assert_eq!(
            payload.checksum,
            "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
        );
        assert_eq!(payload.size_bytes, 11);
        assert_eq!(payload.bytes, b"hello world");
    }

    #[test]
    fn snapshot_payload_empty_bytes() {
        let payload = SnapshotPayload::from_bytes(vec![]);
        // SHA-256 of empty input
        assert_eq!(
            payload.checksum,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(payload.size_bytes, 0);
    }

    #[test]
    fn snapshot_failure_metadata_contains_all_fields() {
        let candidate = test_candidate();
        let meta = ColdTierService::snapshot_failure_metadata(&candidate, 3);
        assert_eq!(
            meta.get("customer_id").unwrap(),
            &candidate.customer_id.to_string()
        );
        assert_eq!(meta.get("tenant_id").unwrap(), "my-index");
        assert_eq!(meta.get("retry_count").unwrap(), "3");
        assert_eq!(meta.len(), 3);
    }
}
