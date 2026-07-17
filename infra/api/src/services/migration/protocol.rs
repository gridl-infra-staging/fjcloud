use std::time::Instant;

use reqwest::Method;
use serde_json::json;
use tracing::warn;
use uuid::Uuid;

use crate::models::vm_inventory::VmInventory;
use crate::services::engine_index_identity_observer::{
    record_physical_caller, PhysicalCallerObservation,
};
use crate::services::flapjack_node::flapjack_index_uid;
use crate::services::replication_error::{INTERNAL_APP_ID_HEADER, INTERNAL_AUTH_HEADER};

use super::{
    endpoint_url, ExecuteProgress, MigrationError, MigrationHttpRequest, MigrationRequest,
    MigrationService, MigrationStatus,
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
        progress: &mut ExecuteProgress,
    ) -> Result<(), MigrationError> {
        self.begin_replication_protocol(req, migration_id, source_vm, dest_vm, progress)
            .await?;
        progress.replication_started = true;

        self.cut_over_migration(
            req,
            migration_id,
            source_vm,
            dest_vm,
            migration_started,
            long_running_warning_sent,
        )
        .await?;

        self.finalize_protocol(req, migration_id, dest_vm, progress)
            .await?;

        Ok(())
    }

    pub async fn probe_rollback_after_replication(
        &self,
        req: MigrationRequest,
    ) -> Result<Uuid, MigrationError> {
        self.ensure_execute_capacity().await?;
        let (source_vm, dest_vm) = self.validate_request(&req).await?;
        let intent = self.begin_migration_intent(&req).await?;
        self.pause_after_migration_intent_for_tests().await;
        let mut progress = ExecuteProgress {
            intent_identity: Some(intent.target_identity.clone()),
            ..Default::default()
        };

        self.begin_replication_protocol(&req, intent.row.id, &source_vm, &dest_vm, &mut progress)
            .await?;
        self.rollback(intent.row.id).await?;

        Ok(intent.row.id)
    }

    pub async fn probe_failure_after_replication(
        &self,
        req: MigrationRequest,
    ) -> Result<Uuid, MigrationError> {
        self.ensure_execute_capacity().await?;
        let (source_vm, dest_vm) = self.validate_request(&req).await?;
        let intent = self.begin_migration_intent(&req).await?;
        self.pause_after_migration_intent_for_tests().await;
        let mut progress = ExecuteProgress {
            intent_identity: Some(intent.target_identity.clone()),
            ..Default::default()
        };

        self.begin_replication_protocol(&req, intent.row.id, &source_vm, &dest_vm, &mut progress)
            .await?;
        progress.replication_started = true;
        let synthetic_failure = MigrationError::Protocol(
            "engine index identity probe injected failure after replication start".to_string(),
        );
        self.handle_execute_failure(
            intent.row.id,
            &req,
            &source_vm,
            &dest_vm,
            &synthetic_failure,
            &progress,
        )
        .await;

        Ok(intent.row.id)
    }

    /// Issues the HTTP POST to the destination VM's `/internal/replicate`
    /// endpoint to start oplog streaming from the source. The durable
    /// migrating intent is persisted before this remote step.
    async fn begin_replication_protocol(
        &self,
        req: &MigrationRequest,
        _migration_id: Uuid,
        source_vm: &VmInventory,
        dest_vm: &VmInventory,
        progress: &mut ExecuteProgress,
    ) -> Result<(), MigrationError> {
        let index_uid = flapjack_index_uid(req.customer_id, &req.index_name);
        progress.start_replication_auth_header_value = Some(
            self.start_replication(&index_uid, source_vm, dest_vm)
                .await?,
        );
        Ok(())
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
        let index_uid = flapjack_index_uid(req.customer_id, &req.index_name);

        self.wait_for_replication_lag(
            req,
            source_vm,
            dest_vm,
            &index_uid,
            self.replication_near_zero_lag_ops,
            migration_started,
            long_running_warning_sent,
        )
        .await?;

        self.migration_repo
            .update_status(migration_id, MigrationStatus::CuttingOver.as_str(), None)
            .await
            .map_err(|err| MigrationError::Repo(err.to_string()))?;

        self.pause_index(source_vm, &index_uid).await?;

        self.wait_for_replication_lag(
            req,
            source_vm,
            dest_vm,
            &index_uid,
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
        migration_id: Uuid,
        dest_vm: &VmInventory,
        progress: &mut ExecuteProgress,
    ) -> Result<(), MigrationError> {
        let expected_identity = progress.intent_identity.as_ref().ok_or_else(|| {
            MigrationError::Protocol(format!(
                "migration '{migration_id}' missing catalog lifecycle intent identity"
            ))
        })?;
        let mut destination_identity = expected_identity.clone();
        destination_identity.vm_id = Some(req.dest_vm_id);
        self.guarded_target_mutation(
            req.customer_id,
            &req.index_name,
            Some(expected_identity),
            || async {
                self.tenant_repo
                    .set_vm_id(req.customer_id, &req.index_name, req.dest_vm_id)
                    .await
            },
        )
        .await?;
        progress.intent_identity = Some(destination_identity.clone());

        self.discovery_cache
            .invalidate(req.customer_id, &req.index_name);

        let index_uid = flapjack_index_uid(req.customer_id, &req.index_name);
        self.set_source_restore_allowed(migration_id, false).await?;
        if let Err(err) = self.resume_index(dest_vm, &index_uid).await {
            self.reopen_source_restore_after_destination_resume_failure(migration_id, req, &err)
                .await;
            return Err(err);
        }
        progress.destination_write_admitted = true;

        self.guarded_target_mutation(
            req.customer_id,
            &req.index_name,
            Some(&destination_identity),
            || async {
                self.tenant_repo
                    .set_tier(req.customer_id, &req.index_name, "active")
                    .await
            },
        )
        .await
    }

    async fn reopen_source_restore_after_destination_resume_failure(
        &self,
        migration_id: Uuid,
        req: &MigrationRequest,
        resume_err: &MigrationError,
    ) {
        if let Err(fence_err) = self.set_source_restore_allowed(migration_id, true).await {
            warn!(
                migration_id = %migration_id,
                customer_id = %req.customer_id,
                index_name = %req.index_name,
                resume_error = %resume_err,
                error = %fence_err,
                "failed to reopen source rollback fence after destination resume failure"
            );
        }
    }

    /// Sends the source VM's current oplog batch to the destination VM's
    /// `/internal/replicate` endpoint.
    pub(super) async fn start_replication(
        &self,
        index_uid: &str,
        source_vm: &VmInventory,
        dest_vm: &VmInventory,
    ) -> Result<String, MigrationError> {
        let ops = self.fetch_source_ops(index_uid, source_vm).await?;
        let replicate_url = endpoint_url(&dest_vm.flapjack_url, "/internal/replicate");
        self.send_observed_http_request(
            "migration.protocol.start_replication",
            index_uid,
            dest_vm,
            MigrationHttpRequest {
                method: Method::POST,
                url: replicate_url,
                json_body: Some(json!({
                    "tenant_id": index_uid,
                    "ops": ops
                })),
                headers: self.build_auth_headers(dest_vm).await?,
            },
        )
        .await
    }

    async fn fetch_source_ops(
        &self,
        index_uid: &str,
        source_vm: &VmInventory,
    ) -> Result<serde_json::Value, MigrationError> {
        let ops_url = endpoint_url(
            &source_vm.flapjack_url,
            &format!(
                "/internal/ops?tenant_id={}&since_seq=0",
                urlencoding::encode(index_uid)
            ),
        );
        let request = MigrationHttpRequest {
            method: Method::GET,
            url: ops_url.clone(),
            json_body: None,
            headers: self.build_auth_headers(source_vm).await?,
        };
        let response = self
            .http_client
            .send(request)
            .await
            .map_err(|err| MigrationError::Http(err.to_string()))?;

        if !(200..300).contains(&response.status) {
            return Err(MigrationError::Http(format!(
                "GET {} returned HTTP {}: {}",
                ops_url, response.status, response.body
            )));
        }

        let payload: serde_json::Value = serde_json::from_str(&response.body).map_err(|err| {
            MigrationError::Protocol(format!(
                "GET {ops_url} returned invalid replication ops JSON: {err}"
            ))
        })?;
        payload.get("ops").cloned().ok_or_else(|| {
            MigrationError::Protocol(format!(
                "GET {ops_url} response missing replication ops array"
            ))
        })
    }

    pub(super) async fn pause_index(
        &self,
        vm: &VmInventory,
        index_name: &str,
    ) -> Result<(), MigrationError> {
        let pause_url = endpoint_url(&vm.flapjack_url, &format!("/internal/pause/{index_name}"));
        self.send_observed_http_request(
            "migration.protocol.pause_index",
            index_name,
            vm,
            MigrationHttpRequest {
                method: Method::POST,
                url: pause_url,
                json_body: None,
                headers: self.build_auth_headers(vm).await?,
            },
        )
        .await
        .map(|_| ())
    }

    pub(super) async fn resume_index(
        &self,
        vm: &VmInventory,
        index_name: &str,
    ) -> Result<(), MigrationError> {
        let resume_url = endpoint_url(&vm.flapjack_url, &format!("/internal/resume/{index_name}"));
        self.send_observed_http_request(
            "migration.protocol.resume_index",
            index_name,
            vm,
            MigrationHttpRequest {
                method: Method::POST,
                url: resume_url,
                json_body: None,
                headers: self.build_auth_headers(vm).await?,
            },
        )
        .await
        .map(|_| ())
    }

    pub(super) async fn delete_index_observing(
        &self,
        caller_id: &str,
        vm: &VmInventory,
        index_uid: &str,
    ) -> Result<(), MigrationError> {
        let delete_url = endpoint_url(&vm.flapjack_url, &format!("/1/indexes/{index_uid}"));
        let request = MigrationHttpRequest {
            method: Method::DELETE,
            url: delete_url,
            json_body: None,
            headers: self.build_auth_headers(vm).await?,
        };
        let response = self
            .http_client
            .send(request.clone())
            .await
            .map_err(|err| MigrationError::Http(err.to_string()))?;

        record_migration_boundary(caller_id, index_uid, vm, &request, response.status);
        if caller_id != "migration.protocol.delete_index" {
            record_migration_boundary(
                "migration.protocol.delete_index",
                index_uid,
                vm,
                &request,
                response.status,
            );
        }
        record_migration_boundary(
            "migration.replication.build_auth_headers",
            index_uid,
            vm,
            &request,
            response.status,
        );

        if (200..300).contains(&response.status) {
            Ok(())
        } else {
            Err(MigrationError::Http(format!(
                "{} {} returned HTTP {}: {}",
                request.method, request.url, response.status, response.body
            )))
        }
    }

    async fn send_observed_http_request(
        &self,
        caller_id: &str,
        index_uid: &str,
        vm: &VmInventory,
        request: MigrationHttpRequest,
    ) -> Result<String, MigrationError> {
        let auth_header_value = request
            .headers
            .get(INTERNAL_AUTH_HEADER)
            .cloned()
            .unwrap_or_default();
        let response = self
            .http_client
            .send(request.clone())
            .await
            .map_err(|err| MigrationError::Http(err.to_string()))?;

        record_migration_boundary(caller_id, index_uid, vm, &request, response.status);
        record_migration_boundary(
            "migration.replication.build_auth_headers",
            index_uid,
            vm,
            &request,
            response.status,
        );

        if (200..300).contains(&response.status) {
            Ok(auth_header_value)
        } else {
            Err(MigrationError::Http(format!(
                "{} {} returned HTTP {}: {}",
                request.method, request.url, response.status, response.body
            )))
        }
    }
}

pub(super) fn record_migration_boundary(
    caller_id: &str,
    index_uid: &str,
    vm: &VmInventory,
    request: &MigrationHttpRequest,
    http_status: u16,
) {
    let logical_uid = logical_uid_from_physical_uid(index_uid);
    let upstream_path = upstream_path_from_url(&request.url);
    let application_id = request
        .headers
        .get(INTERNAL_APP_ID_HEADER)
        .map(String::as_str)
        .unwrap_or_default();
    let auth_header_value = request
        .headers
        .get(INTERNAL_AUTH_HEADER)
        .map(String::as_str)
        .unwrap_or_default();
    record_physical_caller(
        caller_id,
        PhysicalCallerObservation {
            physical_uid: index_uid,
            logical_uid: &logical_uid,
            node_secret_id: vm.node_secret_id(),
            auth_secret_id: vm.node_secret_id(),
            auth_header_value,
            upstream_path: &upstream_path,
            application_id,
            http_status,
        },
    );
}

fn logical_uid_from_physical_uid(index_uid: &str) -> String {
    index_uid
        .split_once('_')
        .map(|(_, logical)| logical.to_string())
        .unwrap_or_else(|| index_uid.to_string())
}

fn upstream_path_from_url(url: &str) -> String {
    let Some(after_scheme) = url.split_once("://").map(|(_, rest)| rest) else {
        return url.to_string();
    };
    after_scheme
        .find('/')
        .map(|path_start| after_scheme[path_start..].to_string())
        .unwrap_or_else(|| "/".to_string())
}
