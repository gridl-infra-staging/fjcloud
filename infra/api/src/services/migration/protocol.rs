//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/migration/protocol.rs.
use std::collections::HashMap;
use std::time::Instant;

use reqwest::Method;
use serde_json::json;
use uuid::Uuid;

use crate::models::vm_inventory::VmInventory;

use super::{
    endpoint_url, MigrationError, MigrationHttpRequest, MigrationRequest, MigrationService,
    MigrationStatus,
};

impl MigrationService {
    /// Drives the three-phase migration protocol: begin replication, wait
    /// for lag convergence and cut over (pausing the source), then finalize
    /// (reassign tenant, invalidate discovery cache, resume on destination).
    /// Sets `replication_started` once replication begins so the caller
    /// knows whether destination cleanup is needed on failure.
    #[allow(clippy::too_many_arguments)]
    pub(super) async fn execute_protocol(
        &self,
        req: &MigrationRequest,
        migration_id: Uuid,
        source_vm: &VmInventory,
        dest_vm: &VmInventory,
        migration_started: Instant,
        long_running_warning_sent: &mut bool,
        replication_started: &mut bool,
    ) -> Result<(), MigrationError> {
        self.begin_replication_protocol(req, migration_id, source_vm, dest_vm)
            .await?;
        *replication_started = true;

        self.cut_over_migration(
            req,
            migration_id,
            source_vm,
            dest_vm,
            migration_started,
            long_running_warning_sent,
        )
        .await?;

        self.finalize_protocol(req, dest_vm).await?;

        Ok(())
    }

    /// Sets the tenant tier to "migrating", transitions the migration record
    /// to `Replicating` status, and issues the HTTP POST to the destination
    /// VM's `/internal/replicate` endpoint to start oplog streaming from
    /// the source.
    async fn begin_replication_protocol(
        &self,
        req: &MigrationRequest,
        migration_id: Uuid,
        source_vm: &VmInventory,
        dest_vm: &VmInventory,
    ) -> Result<(), MigrationError> {
        self.tenant_repo
            .set_tier(req.customer_id, &req.index_name, "migrating")
            .await
            .map_err(|err| MigrationError::Repo(err.to_string()))?;

        self.migration_repo
            .update_status(migration_id, MigrationStatus::Replicating.as_str(), None)
            .await
            .map_err(|err| MigrationError::Repo(err.to_string()))?;

        self.start_replication(req, source_vm, dest_vm).await
    }

    /// Two-phase cut-over: first waits for replication lag to drop to
    /// `near_zero_lag_ops`, then pauses the source index and waits for
    /// exact zero lag. Transitions the migration record to `CuttingOver`
    /// between the two waits.
    async fn cut_over_migration(
        &self,
        req: &MigrationRequest,
        migration_id: Uuid,
        source_vm: &VmInventory,
        dest_vm: &VmInventory,
        migration_started: Instant,
        long_running_warning_sent: &mut bool,
    ) -> Result<(), MigrationError> {
        self.wait_for_replication_lag(
            req,
            source_vm,
            dest_vm,
            &req.index_name,
            self.replication_near_zero_lag_ops,
            migration_started,
            long_running_warning_sent,
        )
        .await?;

        self.migration_repo
            .update_status(migration_id, MigrationStatus::CuttingOver.as_str(), None)
            .await
            .map_err(|err| MigrationError::Repo(err.to_string()))?;

        self.pause_index(source_vm, &req.index_name).await?;

        self.wait_for_replication_lag(
            req,
            source_vm,
            dest_vm,
            &req.index_name,
            0,
            migration_started,
            long_running_warning_sent,
        )
        .await
    }

    /// Completes the migration: reassigns the tenant's `vm_id` to the
    /// destination, invalidates the discovery cache so routing picks up
    /// the new location, resumes the index on the destination VM, and
    /// resets the tenant tier to "active".
    async fn finalize_protocol(
        &self,
        req: &MigrationRequest,
        dest_vm: &VmInventory,
    ) -> Result<(), MigrationError> {
        self.tenant_repo
            .set_vm_id(req.customer_id, &req.index_name, req.dest_vm_id)
            .await
            .map_err(|err| MigrationError::Repo(err.to_string()))?;

        self.discovery_cache
            .invalidate(req.customer_id, &req.index_name);

        self.resume_index(dest_vm, &req.index_name).await?;

        self.tenant_repo
            .set_tier(req.customer_id, &req.index_name, "active")
            .await
            .map_err(|err| MigrationError::Repo(err.to_string()))
    }

    /// Sends a POST to the destination VM's `/internal/replicate` endpoint
    /// with the index name and source flapjack URL, initiating oplog-based
    /// replication from source to destination.
    pub(super) async fn start_replication(
        &self,
        req: &MigrationRequest,
        source_vm: &VmInventory,
        dest_vm: &VmInventory,
    ) -> Result<(), MigrationError> {
        let replicate_url = endpoint_url(&dest_vm.flapjack_url, "/internal/replicate");
        self.send_http_request(MigrationHttpRequest {
            method: Method::POST,
            url: replicate_url,
            json_body: Some(json!({
                "index_name": req.index_name,
                "source_flapjack_url": source_vm.flapjack_url.as_str()
            })),
            headers: self.build_auth_headers(dest_vm).await?,
        })
        .await
    }

    pub(super) async fn pause_index(
        &self,
        vm: &VmInventory,
        index_name: &str,
    ) -> Result<(), MigrationError> {
        let pause_url = endpoint_url(&vm.flapjack_url, &format!("/internal/pause/{index_name}"));
        self.send_http_request(MigrationHttpRequest {
            method: Method::POST,
            url: pause_url,
            json_body: None,
            headers: self.build_auth_headers(vm).await?,
        })
        .await
    }

    pub(super) async fn resume_index(
        &self,
        vm: &VmInventory,
        index_name: &str,
    ) -> Result<(), MigrationError> {
        let resume_url = endpoint_url(&vm.flapjack_url, &format!("/internal/resume/{index_name}"));
        self.send_http_request(MigrationHttpRequest {
            method: Method::POST,
            url: resume_url,
            json_body: None,
            headers: self.build_auth_headers(vm).await?,
        })
        .await
    }

    pub(super) async fn delete_index(
        &self,
        flapjack_url: &str,
        index_name: &str,
    ) -> Result<(), MigrationError> {
        let delete_url = endpoint_url(flapjack_url, &format!("/1/indexes/{index_name}"));
        self.send_http_request(MigrationHttpRequest {
            method: Method::DELETE,
            url: delete_url,
            json_body: None,
            headers: HashMap::new(),
        })
        .await
    }

    /// Sends a [`MigrationHttpRequest`] via the injected HTTP client and
    /// maps the response: 2xx returns `Ok(())`, anything else returns
    /// [`MigrationError::Http`] with the method, URL, status, and body.
    pub(super) async fn send_http_request(
        &self,
        request: MigrationHttpRequest,
    ) -> Result<(), MigrationError> {
        let response = self
            .http_client
            .send(request.clone())
            .await
            .map_err(|err| MigrationError::Http(err.to_string()))?;

        if (200..300).contains(&response.status) {
            Ok(())
        } else {
            Err(MigrationError::Http(format!(
                "{} {} returned HTTP {}: {}",
                request.method, request.url, response.status, response.body
            )))
        }
    }
}
