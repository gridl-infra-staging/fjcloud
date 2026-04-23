use std::sync::Arc;

use tracing::{error, info};
use uuid::Uuid;

use crate::dns::DnsManager;
use crate::models::Deployment;
use crate::provisioner::{CreateVmRequest, VmProvisioner};
use crate::repos::{CustomerRepo, DeploymentRepo};
use crate::secrets::NodeSecretManager;

mod auto_provision;

/// Maximum number of non-terminated deployments per customer.
pub const MAX_DEPLOYMENTS_PER_CUSTOMER: usize = 5;

/// Default DNS domain for VM hostnames.
pub const DEFAULT_DNS_DOMAIN: &str = "flapjack.foo";

/// Errors that can occur during VM provisioning: customer validation,
/// deployment limits, VM provisioner failures, DNS operations, secret
/// management, and repository persistence.
#[derive(Debug, thiserror::Error)]
pub enum ProvisioningError {
    #[error("customer not found")]
    CustomerNotFound,

    #[error("customer is suspended")]
    CustomerSuspended,

    #[error("deployment not found")]
    DeploymentNotFound,

    #[error("deployment not owned by customer")]
    NotOwned,

    #[error("invalid deployment state: {0}")]
    InvalidState(String),

    #[error("deployment limit reached (max {0})")]
    DeploymentLimitReached(usize),

    #[error("VM provisioner failed: {0}")]
    ProvisionerFailed(String),

    #[error("DNS operation failed: {0}")]
    DnsFailed(String),

    #[error("secret manager failed: {0}")]
    SecretFailed(String),

    #[error("repository error: {0}")]
    RepoError(String),
}

pub struct ProvisioningService {
    pub vm_provisioner: Arc<dyn VmProvisioner>,
    pub dns_manager: Arc<dyn DnsManager>,
    pub node_secret_manager: Arc<dyn NodeSecretManager>,
    pub deployment_repo: Arc<dyn DeploymentRepo + Send + Sync>,
    pub customer_repo: Arc<dyn CustomerRepo + Send + Sync>,
    pub dns_domain: String,
}

impl ProvisioningService {
    /// Creates a [`ProvisioningService`] from its required dependencies:
    /// VM provisioner, DNS manager, secret manager, deployment and customer
    /// repos, and the DNS domain for hostname generation.
    pub fn new(
        vm_provisioner: Arc<dyn VmProvisioner>,
        dns_manager: Arc<dyn DnsManager>,
        node_secret_manager: Arc<dyn NodeSecretManager>,
        deployment_repo: Arc<dyn DeploymentRepo + Send + Sync>,
        customer_repo: Arc<dyn CustomerRepo + Send + Sync>,
        dns_domain: String,
    ) -> Self {
        Self {
            vm_provisioner,
            dns_manager,
            node_secret_manager,
            deployment_repo,
            customer_repo,
            dns_domain,
        }
    }

    /// Marks a deployment as failed in the repo. Logs an error if the
    /// deployment is no longer in provisioning state or the repo call fails.
    async fn mark_provisioning_failed(&self, deployment_id: Uuid) {
        match self
            .deployment_repo
            .mark_failed_provisioning(deployment_id)
            .await
        {
            Ok(true) => {}
            Ok(false) => {
                error!(
                    "failed to mark deployment {deployment_id} as failed: deployment no longer in provisioning state"
                );
            }
            Err(e) => {
                error!(
                    "failed to mark deployment {deployment_id} as failed after provisioning error: {e}"
                );
            }
        }
    }

    /// Synchronous part: validate customer, check limits, create DB record, spawn background task.
    /// Returns the deployment immediately with status=provisioning.
    pub async fn provision_deployment(
        self: &Arc<Self>,
        customer_id: Uuid,
        region: &str,
        vm_type: &str,
        vm_provider: &str,
    ) -> Result<Deployment, ProvisioningError> {
        // 1. Verify customer exists and is active
        let customer = self
            .customer_repo
            .find_by_id(customer_id)
            .await
            .map_err(|e| ProvisioningError::RepoError(e.to_string()))?
            .ok_or(ProvisioningError::CustomerNotFound)?;

        match customer.status.as_str() {
            "suspended" => return Err(ProvisioningError::CustomerSuspended),
            "deleted" => return Err(ProvisioningError::CustomerNotFound),
            _ => {}
        }

        // 2. Check deployment limit.
        // "failed" deployments are dead records — they consumed no infrastructure and
        // cannot be retried. Counting them toward the limit would permanently block
        // customers from recovering after a provisioning failure, so only active
        // deployments (provisioning, running, stopped) count.
        let existing = self
            .deployment_repo
            .list_by_customer(customer_id, false)
            .await
            .map_err(|e| ProvisioningError::RepoError(e.to_string()))?;

        let active_count = existing.iter().filter(|d| d.status != "failed").count();
        if active_count >= MAX_DEPLOYMENTS_PER_CUSTOMER {
            return Err(ProvisioningError::DeploymentLimitReached(
                MAX_DEPLOYMENTS_PER_CUSTOMER,
            ));
        }

        // 3. Generate node_id
        let node_id = format!("node-{}", Uuid::new_v4());

        // 4. Create deployment record (status=provisioning)
        let deployment = self
            .deployment_repo
            .create(customer_id, &node_id, region, vm_type, vm_provider, None)
            .await
            .map_err(|e| ProvisioningError::RepoError(e.to_string()))?;

        // 5. Spawn background task
        let svc = Arc::clone(self);
        let deployment_id = deployment.id;
        tokio::spawn(async move {
            if let Err(e) = svc.complete_provisioning(deployment_id).await {
                error!("provisioning failed for deployment {deployment_id}: {e}");
            }
        });

        // 6. Return deployment immediately
        Ok(deployment)
    }

    pub async fn complete_provisioning(
        &self,
        deployment_id: Uuid,
    ) -> Result<(), ProvisioningError> {
        let deployment = self.load_and_claim_deployment(deployment_id).await?;
        let (hostname, flapjack_url) = self.derive_provisioning_hostname(&deployment.id);

        let (ip, vm_instance) = match self.create_node_secret_and_vm(&deployment, &hostname).await {
            Ok(result) => result,
            Err(e) => {
                self.mark_provisioning_failed(deployment_id).await;
                return Err(e);
            }
        };

        self.persist_dns_and_deployment(
            &deployment,
            &hostname,
            &flapjack_url,
            &vm_instance.provider_vm_id,
            &ip,
        )
        .await?;

        info!(
            "provisioning complete for deployment {deployment_id}: hostname={hostname}, vm_id={}",
            vm_instance.provider_vm_id
        );
        Ok(())
    }

    /// Load a deployment and atomically claim it for provisioning.
    /// Returns the deployment if it is in "provisioning" state and no other
    /// worker has claimed it. Fails fast otherwise.
    async fn load_and_claim_deployment(
        &self,
        deployment_id: Uuid,
    ) -> Result<Deployment, ProvisioningError> {
        let deployment = self
            .deployment_repo
            .find_by_id(deployment_id)
            .await
            .map_err(|e| ProvisioningError::RepoError(e.to_string()))?
            .ok_or(ProvisioningError::DeploymentNotFound)?;

        // Guard: only proceed if deployment is still in "provisioning" state.
        // It may have been terminated or failed between the HTTP response and
        // this background task running.
        if deployment.status != "provisioning" {
            return Err(ProvisioningError::InvalidState(format!(
                "deployment is in '{}' state, expected 'provisioning'",
                deployment.status
            )));
        }

        // Atomic claim: only one concurrent caller may proceed with mutating
        // side effects (secret/VM/DNS). Other callers must fail fast.
        let claimed = self
            .deployment_repo
            .claim_provisioning(deployment_id)
            .await
            .map_err(|e| ProvisioningError::RepoError(e.to_string()))?;
        if !claimed {
            return Err(ProvisioningError::InvalidState(
                "deployment is already being provisioned by another worker".into(),
            ));
        }

        Ok(deployment)
    }

    /// Derive hostname and flapjack URL from a deployment's short ID.
    fn derive_provisioning_hostname(&self, deployment_id: &Uuid) -> (String, String) {
        let short_id = &deployment_id.to_string()[..8];
        let hostname = format!("vm-{short_id}.{}", self.dns_domain);
        let flapjack_url = format!("https://{hostname}");
        (hostname, flapjack_url)
    }

    /// Create the per-node API key, build user-data, create the VM, and
    /// validate it has a public IP. On failure, cleans up any resources
    /// created during earlier steps (but does NOT mark the deployment as
    /// failed — the caller handles that).
    async fn create_node_secret_and_vm(
        &self,
        deployment: &Deployment,
        hostname: &str,
    ) -> Result<(String, crate::provisioner::VmInstance), ProvisioningError> {
        // Create per-node API key (stored for server-side lookups;
        // also embedded in user_data for Hetzner's Direct delivery).
        let api_key = self
            .node_secret_manager
            .create_node_api_key(&deployment.node_id, &deployment.region)
            .await
            .map_err(|e| {
                error!(
                    "failed to create API key for node {}: {e}",
                    deployment.node_id
                );
                ProvisioningError::SecretFailed(e.to_string())
            })?;

        // Build provider-appropriate user-data script.
        // AWS VMs read secrets from SSM at boot; Hetzner VMs receive secrets
        // directly in cloud-init (delivered over HTTPS, stored at 0600).
        let user_data = auto_provision::build_user_data(
            &deployment.vm_provider,
            &deployment.customer_id.to_string(),
            &deployment.node_id,
            &deployment.region,
            &api_key,
        );

        let vm_request = CreateVmRequest {
            region: deployment.region.clone(),
            vm_type: deployment.vm_type.clone(),
            hostname: hostname.to_string(),
            customer_id: deployment.customer_id,
            node_id: deployment.node_id.clone(),
            user_data: Some(user_data),
        };

        let vm_instance = match self.vm_provisioner.create_vm(&vm_request).await {
            Ok(vm) => vm,
            Err(e) => {
                self.cleanup_node_secret(&deployment.node_id, &deployment.region)
                    .await;
                return Err(ProvisioningError::ProvisionerFailed(e.to_string()));
            }
        };

        let ip = match vm_instance.public_ip.as_deref() {
            Some(ip) => ip.to_string(),
            None => {
                error!(
                    "VM {} has no public IP, cannot provision DNS for deployment {}",
                    vm_instance.provider_vm_id, deployment.id
                );
                self.rollback_provisioned_resources(
                    deployment,
                    Some(&vm_instance.provider_vm_id),
                    None,
                )
                .await;
                return Err(ProvisioningError::ProvisionerFailed(
                    "VM created without public IP".into(),
                ));
            }
        };

        Ok((ip, vm_instance))
    }

    /// Create DNS record and persist provisioning details to the deployment
    /// record. On any failure, rolls back all provisioned resources (VM, DNS,
    /// secret) and marks the deployment as failed.
    async fn persist_dns_and_deployment(
        &self,
        deployment: &Deployment,
        hostname: &str,
        flapjack_url: &str,
        provider_vm_id: &str,
        ip: &str,
    ) -> Result<(), ProvisioningError> {
        if let Err(e) = self.dns_manager.create_record(hostname, ip).await {
            self.rollback_provisioned_resources(deployment, Some(provider_vm_id), None)
                .await;
            self.mark_provisioning_failed(deployment.id).await;
            return Err(ProvisioningError::DnsFailed(e.to_string()));
        }

        match self
            .deployment_repo
            .update_provisioning(deployment.id, provider_vm_id, ip, hostname, flapjack_url)
            .await
        {
            Ok(Some(_row)) => Ok(()),
            Ok(None) => {
                // Deployment was deleted between VM creation and now — clean up
                error!(
                    "deployment {} vanished during provisioning, cleaning up VM and DNS",
                    deployment.id
                );
                self.rollback_provisioned_resources(
                    deployment,
                    Some(provider_vm_id),
                    Some(hostname),
                )
                .await;
                Err(ProvisioningError::DeploymentNotFound)
            }
            Err(e) => {
                error!(
                    "DB error updating deployment {}, cleaning up provisioned resources: {e}",
                    deployment.id
                );
                self.rollback_provisioned_resources(
                    deployment,
                    Some(provider_vm_id),
                    Some(hostname),
                )
                .await;
                self.mark_provisioning_failed(deployment.id).await;
                Err(ProvisioningError::RepoError(e.to_string()))
            }
        }
    }

    /// Clean up provisioned resources in reverse creation order. Each resource
    /// is optional — only populated resources are cleaned up. Cleanup errors
    /// are logged but do not propagate (best-effort).
    async fn rollback_provisioned_resources(
        &self,
        deployment: &Deployment,
        provider_vm_id: Option<&str>,
        dns_hostname: Option<&str>,
    ) {
        if let Some(hostname) = dns_hostname {
            if let Err(e) = self.dns_manager.delete_record(hostname).await {
                error!("rollback: failed to delete DNS record for {hostname}: {e}");
            }
        }
        if let Some(vm_id) = provider_vm_id {
            if let Err(e) = self.vm_provisioner.destroy_vm(vm_id).await {
                error!("rollback: failed to destroy VM {vm_id}: {e}");
            }
        }
        self.cleanup_node_secret(&deployment.node_id, &deployment.region)
            .await;
    }

    /// Delete a node's API key. Logs errors but does not propagate them.
    async fn cleanup_node_secret(&self, node_id: &str, region: &str) {
        if let Err(e) = self
            .node_secret_manager
            .delete_node_api_key(node_id, region)
            .await
        {
            error!("rollback: failed to clean up SSM key for {node_id}: {e}");
        }
    }

    /// Stop a running deployment.
    pub async fn stop_deployment(
        &self,
        deployment_id: Uuid,
        customer_id: Uuid,
    ) -> Result<Deployment, ProvisioningError> {
        let deployment = self
            .get_owned_deployment(deployment_id, customer_id)
            .await?;

        if deployment.status != "running" {
            return Err(ProvisioningError::InvalidState(format!(
                "cannot stop deployment in '{}' status, must be 'running'",
                deployment.status
            )));
        }

        let provider_vm_id = deployment
            .provider_vm_id
            .as_deref()
            .ok_or_else(|| ProvisioningError::InvalidState("no provider VM ID".into()))?;

        self.vm_provisioner
            .stop_vm(provider_vm_id)
            .await
            .map_err(|e| ProvisioningError::ProvisionerFailed(e.to_string()))?;

        let updated = self
            .deployment_repo
            .update(deployment_id, None, Some("stopped"))
            .await
            .map_err(|e| ProvisioningError::RepoError(e.to_string()))?
            .ok_or(ProvisioningError::DeploymentNotFound)?;

        Ok(updated)
    }

    /// Start a stopped deployment.
    pub async fn start_deployment(
        &self,
        deployment_id: Uuid,
        customer_id: Uuid,
    ) -> Result<Deployment, ProvisioningError> {
        let deployment = self
            .get_owned_deployment(deployment_id, customer_id)
            .await?;

        if deployment.status != "stopped" {
            return Err(ProvisioningError::InvalidState(format!(
                "cannot start deployment in '{}' status, must be 'stopped'",
                deployment.status
            )));
        }

        let provider_vm_id = deployment
            .provider_vm_id
            .as_deref()
            .ok_or_else(|| ProvisioningError::InvalidState("no provider VM ID".into()))?;

        self.vm_provisioner
            .start_vm(provider_vm_id)
            .await
            .map_err(|e| ProvisioningError::ProvisionerFailed(e.to_string()))?;

        // Status goes to "provisioning" — health monitor will flip to "running"
        let updated = self
            .deployment_repo
            .update(deployment_id, None, Some("provisioning"))
            .await
            .map_err(|e| ProvisioningError::RepoError(e.to_string()))?
            .ok_or(ProvisioningError::DeploymentNotFound)?;

        Ok(updated)
    }

    /// Terminate a deployment: destroy VM, delete DNS, mark terminated.
    pub async fn terminate_deployment(
        &self,
        deployment_id: Uuid,
        customer_id: Uuid,
    ) -> Result<(), ProvisioningError> {
        let deployment = self
            .get_owned_deployment(deployment_id, customer_id)
            .await?;

        if deployment.status == "terminated" {
            return Err(ProvisioningError::InvalidState(
                "deployment is already terminated".into(),
            ));
        }

        // Destroy VM if we have a provider ID
        if let Some(ref provider_vm_id) = deployment.provider_vm_id {
            self.vm_provisioner
                .destroy_vm(provider_vm_id)
                .await
                .map_err(|e| ProvisioningError::ProvisionerFailed(e.to_string()))?;
        }

        // Delete DNS record if we have a hostname — best effort.
        // The VM is already destroyed at this point, so DNS failure must not
        // prevent the deployment from being marked as terminated.
        if let Some(ref hostname) = deployment.hostname {
            if let Err(e) = self.dns_manager.delete_record(hostname).await {
                error!(
                    "failed to delete DNS record for {hostname} during termination of {deployment_id}: {e}"
                );
            }
        }

        // Delete per-node SSM API key — best effort cleanup
        if let Err(e) = self
            .node_secret_manager
            .delete_node_api_key(&deployment.node_id, &deployment.region)
            .await
        {
            error!(
                "failed to delete SSM key for {} during termination of {deployment_id}: {e}",
                deployment.node_id
            );
        }

        // Mark terminated in DB
        self.deployment_repo
            .terminate(deployment_id)
            .await
            .map_err(|e| ProvisioningError::RepoError(e.to_string()))?;

        info!("deployment {deployment_id} terminated");

        Ok(())
    }

    /// Helper: fetch deployment and verify ownership.
    async fn get_owned_deployment(
        &self,
        deployment_id: Uuid,
        customer_id: Uuid,
    ) -> Result<Deployment, ProvisioningError> {
        let deployment = self
            .deployment_repo
            .find_by_id(deployment_id)
            .await
            .map_err(|e| ProvisioningError::RepoError(e.to_string()))?
            .ok_or(ProvisioningError::DeploymentNotFound)?;

        if deployment.customer_id != customer_id {
            return Err(ProvisioningError::NotOwned);
        }

        Ok(deployment)
    }
}

// Shared VM auto-provision helpers and tests now live in `auto_provision`.

/// Resolve the DNS domain from `DNS_DOMAIN` env var, falling back to [`DEFAULT_DNS_DOMAIN`].
///
/// Both the Route53 DNS manager and ProvisioningService should use this
/// function so the fallback domain is defined in exactly one place.
pub fn resolve_dns_domain() -> String {
    std::env::var("DNS_DOMAIN").unwrap_or_else(|_| DEFAULT_DNS_DOMAIN.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    struct EnvVarGuard {
        key: &'static str,
        previous: Option<String>,
    }

    impl EnvVarGuard {
        fn set(key: &'static str, value: Option<&str>) -> Self {
            let previous = std::env::var(key).ok();
            match value {
                Some(v) => std::env::set_var(key, v),
                None => std::env::remove_var(key),
            }
            Self { key, previous }
        }
    }

    impl Drop for EnvVarGuard {
        fn drop(&mut self) {
            match &self.previous {
                Some(val) => std::env::set_var(self.key, val),
                None => std::env::remove_var(self.key),
            }
        }
    }

    #[test]
    fn dns_domain_falls_back_to_default() {
        let _guard = env_lock().lock().expect("env lock poisoned");
        let _env = EnvVarGuard::set("DNS_DOMAIN", None);

        let result = resolve_dns_domain();
        assert_eq!(
            result, "flapjack.foo",
            "resolve_dns_domain must fall back to the canonical Flapjack Cloud domain"
        );
    }

    #[test]
    fn dns_domain_respects_env_override() {
        let _guard = env_lock().lock().expect("env lock poisoned");
        let _env = EnvVarGuard::set("DNS_DOMAIN", Some("custom.example.com"));

        let result = resolve_dns_domain();
        assert_eq!(result, "custom.example.com");
    }
}
