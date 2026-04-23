//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/migration/replication.rs.
use std::collections::HashMap;
use std::time::Instant;

use reqwest::Method;

use crate::models::vm_inventory::VmInventory;
use crate::services::prometheus_parser::{extract_label, parse_metrics};
use crate::services::replication_error::{
    INTERNAL_APP_ID_HEADER, INTERNAL_AUTH_HEADER, REPLICATION_APP_ID,
};

use super::{
    endpoint_url, MigrationError, MigrationHttpRequest, MigrationRequest, MigrationService,
    OPLOG_SEQ_METRIC,
};

impl MigrationService {
    /// Polls the oplog sequence metric on both source and destination VMs
    /// until `|source_seq - dest_seq| <= max_lag_ops`. Sleeps
    /// `replication_poll_interval` between polls and returns
    /// [`MigrationError::ReplicationLagTimeout`] if convergence is not
    /// reached within `replication_timeout`. Checks for long-running
    /// warnings on each iteration.
    #[allow(clippy::too_many_arguments)]
    pub(super) async fn wait_for_replication_lag(
        &self,
        req: &MigrationRequest,
        source_vm: &VmInventory,
        dest_vm: &VmInventory,
        index_name: &str,
        max_lag_ops: i64,
        migration_started: Instant,
        long_running_warning_sent: &mut bool,
    ) -> Result<(), MigrationError> {
        let started = Instant::now();
        loop {
            self.maybe_send_long_running_warning(req, migration_started, long_running_warning_sent)
                .await;

            let source_seq = self.fetch_oplog_seq(source_vm, index_name).await?;
            let dest_seq = self.fetch_oplog_seq(dest_vm, index_name).await?;
            let lag = (source_seq - dest_seq).abs();
            if lag <= max_lag_ops {
                return Ok(());
            }

            if started.elapsed() >= self.replication_timeout {
                return Err(MigrationError::ReplicationLagTimeout {
                    index_name: index_name.to_string(),
                    source_seq,
                    dest_seq,
                    waited_secs: started.elapsed().as_secs(),
                });
            }

            tokio::time::sleep(self.replication_poll_interval).await;
        }
    }

    /// Fires a one-shot warning alert if the migration has been running
    /// longer than `long_running_warning_threshold`. Uses the
    /// `long_running_warning_sent` flag to ensure the alert is sent at
    /// most once per migration execution.
    pub(super) async fn maybe_send_long_running_warning(
        &self,
        req: &MigrationRequest,
        migration_started: Instant,
        long_running_warning_sent: &mut bool,
    ) {
        if *long_running_warning_sent {
            return;
        }

        let elapsed = migration_started.elapsed();
        if elapsed < self.long_running_warning_threshold {
            return;
        }

        self.send_long_running_warning_alert(req, elapsed).await;
        *long_running_warning_sent = true;
    }

    /// Fetches the current oplog sequence number for `index_name` from a
    /// VM's `/metrics` endpoint. Parses the Prometheus text format, finds
    /// the `OPLOG_SEQ_METRIC` series matching the index label, and returns
    /// the floored integer value. Errors if the metric or index label is
    /// missing.
    pub(super) async fn fetch_oplog_seq(
        &self,
        vm: &VmInventory,
        index_name: &str,
    ) -> Result<i64, MigrationError> {
        let metrics_url = endpoint_url(&vm.flapjack_url, "/metrics");
        let response = self
            .http_client
            .send(MigrationHttpRequest {
                method: Method::GET,
                url: metrics_url.clone(),
                json_body: None,
                headers: self.build_auth_headers(vm).await?,
            })
            .await
            .map_err(|err| MigrationError::Http(err.to_string()))?;

        if !(200..300).contains(&response.status) {
            return Err(MigrationError::Http(format!(
                "GET {} returned HTTP {}: {}",
                metrics_url, response.status, response.body
            )));
        }

        let parsed = parse_metrics(&response.body);
        let Some(series) = parsed.get(OPLOG_SEQ_METRIC) else {
            return Err(MigrationError::Protocol(format!(
                "metric '{OPLOG_SEQ_METRIC}' missing for index '{index_name}'"
            )));
        };

        for (labels, value) in series {
            if extract_label(labels, "index").as_deref() == Some(index_name) {
                return Ok((*value).floor() as i64);
            }
        }

        Err(MigrationError::Protocol(format!(
            "metric '{OPLOG_SEQ_METRIC}' missing index label for '{index_name}'"
        )))
    }

    /// Builds internal authentication headers for requests to a VM's
    /// flapjack engine. Retrieves the node API key via the
    /// [`NodeSecretManager`] and sets the replication app-ID header.
    pub(super) async fn build_auth_headers(
        &self,
        vm: &VmInventory,
    ) -> Result<HashMap<String, String>, MigrationError> {
        let key = self
            .node_secret_manager
            .get_node_api_key(&vm.id.to_string(), &vm.region)
            .await
            .map_err(|err| {
                MigrationError::Http(format!(
                    "failed to load internal key for vm {} in {}: {}",
                    vm.id, vm.region, err
                ))
            })?;

        Ok(HashMap::from([
            (INTERNAL_AUTH_HEADER.to_string(), key),
            (
                INTERNAL_APP_ID_HEADER.to_string(),
                REPLICATION_APP_ID.to_string(),
            ),
        ]))
    }
}
