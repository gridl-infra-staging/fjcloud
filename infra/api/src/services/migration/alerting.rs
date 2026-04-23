//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/migration/alerting.rs.
use std::collections::HashMap;
use std::time::Duration;

use tracing::warn;

use crate::services::alerting::{Alert, AlertSeverity};

use super::{MigrationRequest, MigrationService};

impl MigrationService {
    /// Sends an `Info`-severity alert on successful migration completion.
    /// Metadata includes index name, customer ID, source/dest VM IDs,
    /// requester, and total duration in milliseconds.
    pub(super) async fn send_success_alert(&self, req: &MigrationRequest, elapsed: Duration) {
        let mut metadata = HashMap::new();
        metadata.insert("index_name".to_string(), req.index_name.clone());
        metadata.insert("customer_id".to_string(), req.customer_id.to_string());
        metadata.insert("source_vm_id".to_string(), req.source_vm_id.to_string());
        metadata.insert("dest_vm_id".to_string(), req.dest_vm_id.to_string());
        metadata.insert("requested_by".to_string(), req.requested_by.clone());
        metadata.insert("duration_ms".to_string(), elapsed.as_millis().to_string());

        let alert = Alert {
            severity: AlertSeverity::Info,
            title: "Index migration completed".to_string(),
            message: format!(
                "Index '{}' migrated from {} to {}",
                req.index_name, req.source_vm_id, req.dest_vm_id
            ),
            metadata,
        };

        if let Err(err) = self.alert_service.send_alert(alert).await {
            warn!(index_name = %req.index_name, error = %err, "failed to send migration success alert");
        }
    }

    /// Sends a `Warning`-severity alert when a migration exceeds
    /// `long_running_warning_threshold`. Includes the elapsed duration
    /// and threshold in metadata for operational triage.
    pub(super) async fn send_long_running_warning_alert(
        &self,
        req: &MigrationRequest,
        elapsed: Duration,
    ) {
        let mut metadata = HashMap::new();
        metadata.insert("index_name".to_string(), req.index_name.clone());
        metadata.insert("customer_id".to_string(), req.customer_id.to_string());
        metadata.insert("source_vm_id".to_string(), req.source_vm_id.to_string());
        metadata.insert("dest_vm_id".to_string(), req.dest_vm_id.to_string());
        metadata.insert("requested_by".to_string(), req.requested_by.clone());
        metadata.insert("duration_ms".to_string(), elapsed.as_millis().to_string());
        metadata.insert(
            "warning_threshold_secs".to_string(),
            self.long_running_warning_threshold.as_secs().to_string(),
        );

        let alert = Alert {
            severity: AlertSeverity::Warning,
            title: "Index migration running longer than expected".to_string(),
            message: format!(
                "Index '{}' migration has been running for {}s",
                req.index_name,
                elapsed.as_secs()
            ),
            metadata,
        };

        if let Err(err) = self.alert_service.send_alert(alert).await {
            warn!(index_name = %req.index_name, error = %err, "failed to send long-running migration warning alert");
        }
    }

    /// Sends a `Critical`-severity alert on migration failure. Metadata
    /// includes the error message alongside the standard migration
    /// identifiers (index, customer, source/dest VMs, requester).
    pub(super) async fn send_failure_alert(&self, req: &MigrationRequest, error: &str) {
        let mut metadata = HashMap::new();
        metadata.insert("index_name".to_string(), req.index_name.clone());
        metadata.insert("customer_id".to_string(), req.customer_id.to_string());
        metadata.insert("source_vm_id".to_string(), req.source_vm_id.to_string());
        metadata.insert("dest_vm_id".to_string(), req.dest_vm_id.to_string());
        metadata.insert("requested_by".to_string(), req.requested_by.clone());
        metadata.insert("error".to_string(), error.to_string());

        let alert = Alert {
            severity: AlertSeverity::Critical,
            title: "Index migration failed".to_string(),
            message: format!(
                "Index '{}' migration failed from {} to {}",
                req.index_name, req.source_vm_id, req.dest_vm_id
            ),
            metadata,
        };

        if let Err(err) = self.alert_service.send_alert(alert).await {
            warn!(index_name = %req.index_name, error = %err, "failed to send migration failure alert");
        }
    }
}
