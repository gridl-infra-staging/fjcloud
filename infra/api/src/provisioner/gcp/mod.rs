//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/provisioner/gcp/mod.rs.
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use super::env_config::{optional_env, parse_u32_env, parse_u64_env, required_env};
use super::{CreateVmRequest, VmInstance, VmProvisioner, VmProvisionerError, VmStatus};

mod api_client;
use api_client::{GcpApi, ReqwestGcpApiClient};

/// Maps a GCP instance status to our `VmStatus` enum.
pub fn map_gcp_status(status: &str) -> VmStatus {
    match status {
        "PROVISIONING" | "STAGING" | "REPAIRING" => VmStatus::Pending,
        "RUNNING" => VmStatus::Running,
        // GCP "TERMINATED" means the VM is stopped (still exists, can be restarted).
        // Deleted instances return 404, not a status string.
        "STOPPING" | "SUSPENDING" | "SUSPENDED" | "TERMINATED" => VmStatus::Stopped,
        _ => VmStatus::Unknown,
    }
}

/// Configuration for the GCP Compute provisioner.
#[derive(Debug, Clone)]
pub struct GcpProvisionerConfig {
    pub api_token: String,
    pub project_id: String,
    pub zone: String,
    pub machine_type: String,
    pub image: String,
    pub network: String,
    pub subnetwork: Option<String>,
    pub api_base_url: String,
    pub create_poll_attempts: u32,
    pub create_poll_interval_ms: u64,
}

impl GcpProvisionerConfig {
    /// Loads config from env vars. Requires `GCP_API_TOKEN` and `GCP_PROJECT_ID`. Defaults: zone us-central1-a, machine e2-standard-4. Configurable poll attempts/interval.
    pub fn from_env() -> Result<Self, String> {
        Ok(Self {
            api_token: required_env("GCP_API_TOKEN")?,
            project_id: required_env("GCP_PROJECT_ID")?,
            zone: std::env::var("GCP_ZONE").unwrap_or_else(|_| "us-central1-a".to_string()),
            machine_type: std::env::var("GCP_MACHINE_TYPE")
                .unwrap_or_else(|_| "e2-standard-4".to_string()),
            image: std::env::var("GCP_IMAGE").unwrap_or_else(|_| {
                "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts".to_string()
            }),
            network: std::env::var("GCP_NETWORK")
                .unwrap_or_else(|_| "global/networks/default".to_string()),
            subnetwork: optional_env("GCP_SUBNETWORK"),
            api_base_url: "https://compute.googleapis.com/compute/v1".to_string(),
            create_poll_attempts: parse_u32_env("GCP_CREATE_POLL_ATTEMPTS", 10)?,
            create_poll_interval_ms: parse_u64_env("GCP_CREATE_POLL_INTERVAL_MS", 2000)?,
        })
    }
}

#[derive(Debug, Clone, Serialize)]
struct CreateInstanceRequest {
    name: String,
    #[serde(rename = "machineType")]
    machine_type: String,
    disks: Vec<AttachedDisk>,
    #[serde(rename = "networkInterfaces")]
    network_interfaces: Vec<NetworkInterface>,
    labels: HashMap<String, String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    metadata: Option<Metadata>,
}

#[derive(Debug, Clone, Serialize)]
struct AttachedDisk {
    boot: bool,
    #[serde(rename = "autoDelete")]
    auto_delete: bool,
    #[serde(rename = "initializeParams")]
    initialize_params: InitializeParams,
}

#[derive(Debug, Clone, Serialize)]
struct InitializeParams {
    #[serde(rename = "sourceImage")]
    source_image: String,
}

#[derive(Debug, Clone, Serialize)]
struct NetworkInterface {
    network: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    subnetwork: Option<String>,
    #[serde(rename = "accessConfigs")]
    access_configs: Vec<AccessConfig>,
}

#[derive(Debug, Clone, Serialize)]
struct AccessConfig {
    name: String,
    #[serde(rename = "type")]
    access_type: String,
}

#[derive(Debug, Clone, Serialize)]
struct Metadata {
    items: Vec<MetadataItem>,
}

#[derive(Debug, Clone, Serialize)]
struct MetadataItem {
    key: String,
    value: String,
}

#[derive(Debug, Deserialize)]
struct GcpInstance {
    name: String,
    status: String,
    #[serde(default, rename = "networkInterfaces")]
    network_interfaces: Vec<GcpNetworkInterface>,
}

impl GcpInstance {
    fn first_private_ip(&self) -> Option<String> {
        self.network_interfaces
            .first()
            .and_then(|ni| ni.network_ip.clone())
    }

    fn first_public_ip(&self) -> Option<String> {
        self.network_interfaces
            .first()
            .and_then(|ni| ni.access_configs.first().and_then(|ac| ac.nat_ip.clone()))
    }
}

#[derive(Debug, Deserialize)]
struct GcpNetworkInterface {
    #[serde(default, rename = "networkIP")]
    network_ip: Option<String>,
    #[serde(default, rename = "accessConfigs")]
    access_configs: Vec<GcpAccessConfig>,
}

#[derive(Debug, Deserialize)]
struct GcpAccessConfig {
    #[serde(default, rename = "natIP")]
    nat_ip: Option<String>,
}

pub struct GcpVmProvisioner {
    client: Arc<dyn GcpApi>,
    config: GcpProvisionerConfig,
}

impl GcpVmProvisioner {
    pub fn new(config: GcpProvisionerConfig) -> Self {
        let client = Arc::new(ReqwestGcpApiClient::new(
            &config.api_base_url,
            &config.api_token,
        ));
        Self { client, config }
    }

    fn parse_provider_vm_id(provider_vm_id: &str) -> Result<(&str, &str), VmProvisionerError> {
        provider_vm_id.split_once('/').ok_or_else(|| {
            VmProvisionerError::Api(format!(
                "invalid GCP VM ID (expected 'zone/instance'): {provider_vm_id}"
            ))
        })
    }

    fn zone_for_create(&self, req: &CreateVmRequest) -> String {
        let trimmed = req.region.trim();
        if trimmed.is_empty() {
            self.config.zone.clone()
        } else {
            trimmed.to_string()
        }
    }

    #[cfg(test)]
    fn with_client_for_tests(config: GcpProvisionerConfig, client: Arc<dyn GcpApi>) -> Self {
        Self { client, config }
    }
}

#[async_trait]
impl VmProvisioner for GcpVmProvisioner {
    /// Inserts a GCP instance then polls for a public IP via `get_instance`. User data becomes a `startup-script` metadata item. Provider VM ID is `zone/instance_name`.
    async fn create_vm(&self, req: &CreateVmRequest) -> Result<VmInstance, VmProvisionerError> {
        let zone = self.zone_for_create(req);

        let mut labels = HashMap::new();
        labels.insert("customer_id".to_string(), req.customer_id.to_string());
        labels.insert("node_id".to_string(), req.node_id.clone());
        labels.insert("managed-by".to_string(), "fjcloud".to_string());

        let metadata = req.user_data.as_ref().map(|user_data| Metadata {
            items: vec![MetadataItem {
                key: "startup-script".to_string(),
                value: user_data.clone(),
            }],
        });

        let body = CreateInstanceRequest {
            name: req.hostname.clone(),
            machine_type: format!("zones/{zone}/machineTypes/{}", self.config.machine_type),
            disks: vec![AttachedDisk {
                boot: true,
                auto_delete: true,
                initialize_params: InitializeParams {
                    source_image: self.config.image.clone(),
                },
            }],
            network_interfaces: vec![NetworkInterface {
                network: self.config.network.clone(),
                subnetwork: self.config.subnetwork.clone(),
                access_configs: vec![AccessConfig {
                    name: "External NAT".to_string(),
                    access_type: "ONE_TO_ONE_NAT".to_string(),
                }],
            }],
            labels,
            metadata,
        };

        self.client
            .insert_instance(&self.config.project_id, &zone, &body)
            .await?;

        let attempts = self.config.create_poll_attempts.max(1);
        let mut last_instance: Option<GcpInstance> = None;

        for attempt in 0..attempts {
            let instance = self
                .client
                .get_instance(&self.config.project_id, &zone, &req.hostname)
                .await?;

            let public_ip = instance.first_public_ip();
            if public_ip.is_some() {
                let private_ip = instance.first_private_ip();
                return Ok(VmInstance {
                    provider_vm_id: format!("{zone}/{}", instance.name),
                    public_ip,
                    private_ip,
                    status: map_gcp_status(&instance.status),
                    region: req.region.clone(),
                });
            }

            last_instance = Some(instance);

            if attempt + 1 < attempts {
                tokio::time::sleep(Duration::from_millis(self.config.create_poll_interval_ms))
                    .await;
            }
        }

        let status = last_instance
            .as_ref()
            .map(|i| i.status.as_str())
            .unwrap_or("unknown");

        Err(VmProvisionerError::Api(format!(
            "GCP instance '{}' created in zone '{}' but has no public IP after {} attempts (status: {})",
            req.hostname, zone, attempts, status
        )))
    }

    async fn destroy_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        let (zone, instance) = Self::parse_provider_vm_id(provider_vm_id)?;
        self.client
            .delete_instance(&self.config.project_id, zone, instance)
            .await
    }

    async fn stop_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        let (zone, instance) = Self::parse_provider_vm_id(provider_vm_id)?;
        self.client
            .stop_instance(&self.config.project_id, zone, instance)
            .await
    }

    async fn start_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        let (zone, instance) = Self::parse_provider_vm_id(provider_vm_id)?;
        self.client
            .start_instance(&self.config.project_id, zone, instance)
            .await
    }

    async fn get_vm_status(&self, provider_vm_id: &str) -> Result<VmStatus, VmProvisionerError> {
        let (zone, instance) = Self::parse_provider_vm_id(provider_vm_id)?;
        let instance = self
            .client
            .get_instance(&self.config.project_id, zone, instance)
            .await?;
        Ok(map_gcp_status(&instance.status))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::sync::Mutex;
    use uuid::Uuid;

    struct MockGcpApiClient {
        insert_calls: Mutex<Vec<(String, String, CreateInstanceRequest)>>,
        delete_calls: Mutex<Vec<(String, String, String)>>,
        stop_calls: Mutex<Vec<(String, String, String)>>,
        start_calls: Mutex<Vec<(String, String, String)>>,
        get_calls: Mutex<Vec<(String, String, String)>>,
        insert_responses: Mutex<VecDeque<Result<(), VmProvisionerError>>>,
        get_responses: Mutex<VecDeque<Result<GcpInstance, VmProvisionerError>>>,
    }

    impl MockGcpApiClient {
        fn with_insert_and_get(
            insert: Result<(), VmProvisionerError>,
            get: Result<GcpInstance, VmProvisionerError>,
        ) -> Self {
            Self {
                insert_calls: Mutex::new(Vec::new()),
                delete_calls: Mutex::new(Vec::new()),
                stop_calls: Mutex::new(Vec::new()),
                start_calls: Mutex::new(Vec::new()),
                get_calls: Mutex::new(Vec::new()),
                insert_responses: Mutex::new(VecDeque::from([insert])),
                get_responses: Mutex::new(VecDeque::from([get])),
            }
        }

        fn with_get(get: Result<GcpInstance, VmProvisionerError>) -> Self {
            Self {
                insert_calls: Mutex::new(Vec::new()),
                delete_calls: Mutex::new(Vec::new()),
                stop_calls: Mutex::new(Vec::new()),
                start_calls: Mutex::new(Vec::new()),
                get_calls: Mutex::new(Vec::new()),
                insert_responses: Mutex::new(VecDeque::new()),
                get_responses: Mutex::new(VecDeque::from([get])),
            }
        }
    }

    #[async_trait]
    impl GcpApi for MockGcpApiClient {
        /// Records the insert_instance call and returns the next queued response.
        async fn insert_instance(
            &self,
            project: &str,
            zone: &str,
            body: &CreateInstanceRequest,
        ) -> Result<(), VmProvisionerError> {
            self.insert_calls
                .lock()
                .expect("insert_calls lock poisoned")
                .push((project.to_string(), zone.to_string(), body.clone()));
            self.insert_responses
                .lock()
                .expect("insert_responses lock poisoned")
                .pop_front()
                .expect("missing mocked insert response")
        }

        async fn delete_instance(
            &self,
            project: &str,
            zone: &str,
            instance: &str,
        ) -> Result<(), VmProvisionerError> {
            self.delete_calls
                .lock()
                .expect("delete_calls lock poisoned")
                .push((project.to_string(), zone.to_string(), instance.to_string()));
            Ok(())
        }

        async fn stop_instance(
            &self,
            project: &str,
            zone: &str,
            instance: &str,
        ) -> Result<(), VmProvisionerError> {
            self.stop_calls
                .lock()
                .expect("stop_calls lock poisoned")
                .push((project.to_string(), zone.to_string(), instance.to_string()));
            Ok(())
        }

        async fn start_instance(
            &self,
            project: &str,
            zone: &str,
            instance: &str,
        ) -> Result<(), VmProvisionerError> {
            self.start_calls
                .lock()
                .expect("start_calls lock poisoned")
                .push((project.to_string(), zone.to_string(), instance.to_string()));
            Ok(())
        }

        /// Returns the next queued `get_responses` entry and records the call for assertion.
        async fn get_instance(
            &self,
            project: &str,
            zone: &str,
            instance: &str,
        ) -> Result<GcpInstance, VmProvisionerError> {
            self.get_calls
                .lock()
                .expect("get_calls lock poisoned")
                .push((project.to_string(), zone.to_string(), instance.to_string()));
            self.get_responses
                .lock()
                .expect("get_responses lock poisoned")
                .pop_front()
                .expect("missing mocked get response")
        }
    }

    fn test_config() -> GcpProvisionerConfig {
        GcpProvisionerConfig {
            api_token: "tok".to_string(),
            project_id: "fjcloud-test".to_string(),
            zone: "us-central1-a".to_string(),
            machine_type: "e2-standard-4".to_string(),
            image: "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts".to_string(),
            network: "global/networks/default".to_string(),
            subnetwork: Some("regions/us-central1/subnetworks/default".to_string()),
            api_base_url: "https://compute.googleapis.com/compute/v1".to_string(),
            create_poll_attempts: 1,
            create_poll_interval_ms: 1,
        }
    }

    fn test_request() -> CreateVmRequest {
        CreateVmRequest {
            region: "us-central1-b".to_string(),
            vm_type: "e2-standard-4".to_string(),
            hostname: "fj-gcp-node".to_string(),
            customer_id: Uuid::new_v4(),
            node_id: "node-001".to_string(),
            user_data: Some("#!/bin/bash\necho gcp".to_string()),
        }
    }

    fn running_instance() -> GcpInstance {
        GcpInstance {
            name: "fj-gcp-node".to_string(),
            status: "RUNNING".to_string(),
            network_interfaces: vec![GcpNetworkInterface {
                network_ip: Some("10.128.0.5".to_string()),
                access_configs: vec![GcpAccessConfig {
                    nat_ip: Some("203.0.113.22".to_string()),
                }],
            }],
        }
    }

    /// Verifies `create_vm` sends the correct GCP insert payload: zone-qualified machine type, boot disk image, subnetwork, startup-script metadata, and `managed-by: fjcloud` label.
    #[tokio::test]
    async fn create_vm_builds_expected_payload() {
        let mock = Arc::new(MockGcpApiClient::with_insert_and_get(
            Ok(()),
            Ok(running_instance()),
        ));
        let provisioner = GcpVmProvisioner::with_client_for_tests(test_config(), mock.clone());

        provisioner
            .create_vm(&test_request())
            .await
            .expect("create should succeed");

        let calls = mock
            .insert_calls
            .lock()
            .expect("insert_calls lock poisoned");
        assert_eq!(calls.len(), 1);
        let (project, zone, body) = &calls[0];
        assert_eq!(project, "fjcloud-test");
        assert_eq!(zone, "us-central1-b");
        assert_eq!(body.name, "fj-gcp-node");
        assert_eq!(
            body.machine_type,
            "zones/us-central1-b/machineTypes/e2-standard-4"
        );
        assert_eq!(body.disks.len(), 1);
        assert_eq!(
            body.disks[0].initialize_params.source_image,
            "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts"
        );
        assert_eq!(body.network_interfaces.len(), 1);
        assert_eq!(
            body.network_interfaces[0].subnetwork.as_deref(),
            Some("regions/us-central1/subnetworks/default")
        );
        let metadata = body.metadata.as_ref().expect("metadata should be set");
        assert_eq!(metadata.items.len(), 1);
        assert_eq!(metadata.items[0].key, "startup-script");
        assert_eq!(metadata.items[0].value, "#!/bin/bash\necho gcp");
        assert_eq!(
            body.labels.get("managed-by").map(String::as_str),
            Some("fjcloud")
        );
    }

    /// Confirms `create_vm` returns a `VmInstance` with the zone-qualified provider ID, extracted public/private IPs, `Running` status, and correct region.
    #[tokio::test]
    async fn create_vm_returns_instance_with_ip() {
        let mock = Arc::new(MockGcpApiClient::with_insert_and_get(
            Ok(()),
            Ok(running_instance()),
        ));
        let provisioner = GcpVmProvisioner::with_client_for_tests(test_config(), mock);

        let instance = provisioner
            .create_vm(&test_request())
            .await
            .expect("create should succeed");

        assert_eq!(instance.provider_vm_id, "us-central1-b/fj-gcp-node");
        assert_eq!(instance.public_ip.as_deref(), Some("203.0.113.22"));
        assert_eq!(instance.private_ip.as_deref(), Some("10.128.0.5"));
        assert_eq!(instance.status, VmStatus::Running);
        assert_eq!(instance.region, "us-central1-b");
    }

    /// Ensures `destroy_vm` parses the `zone/name` composite ID and calls `delete_instance` with the correct project, zone, and instance name.
    #[tokio::test]
    async fn destroy_vm_calls_delete() {
        let mock = Arc::new(MockGcpApiClient::with_get(Ok(running_instance())));
        let provisioner = GcpVmProvisioner::with_client_for_tests(test_config(), mock.clone());

        provisioner
            .destroy_vm("us-central1-a/fj-gcp-node")
            .await
            .expect("destroy should succeed");

        let calls = mock
            .delete_calls
            .lock()
            .expect("delete_calls lock poisoned");
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].0, "fjcloud-test");
        assert_eq!(calls[0].1, "us-central1-a");
        assert_eq!(calls[0].2, "fj-gcp-node");
    }

    /// Verifies `stop_vm` and `start_vm` each delegate to the corresponding GCP API action method with the correct project, zone, and instance name.
    #[tokio::test]
    async fn stop_and_start_vm_call_actions() {
        let mock = Arc::new(MockGcpApiClient::with_get(Ok(running_instance())));
        let provisioner = GcpVmProvisioner::with_client_for_tests(test_config(), mock.clone());

        provisioner
            .stop_vm("us-central1-a/fj-gcp-node")
            .await
            .expect("stop should succeed");
        provisioner
            .start_vm("us-central1-a/fj-gcp-node")
            .await
            .expect("start should succeed");

        let stop_calls = mock.stop_calls.lock().expect("stop_calls lock poisoned");
        let start_calls = mock.start_calls.lock().expect("start_calls lock poisoned");
        assert_eq!(stop_calls.len(), 1);
        assert_eq!(start_calls.len(), 1);
        assert_eq!(stop_calls[0].2, "fj-gcp-node");
        assert_eq!(start_calls[0].2, "fj-gcp-node");
    }

    #[tokio::test]
    async fn get_vm_status_maps_status() {
        let mock = Arc::new(MockGcpApiClient::with_get(Ok(GcpInstance {
            name: "fj-gcp-node".to_string(),
            status: "STOPPING".to_string(),
            network_interfaces: Vec::new(),
        })));
        let provisioner = GcpVmProvisioner::with_client_for_tests(test_config(), mock);

        let status = provisioner
            .get_vm_status("us-central1-a/fj-gcp-node")
            .await
            .expect("status should succeed");
        assert_eq!(status, VmStatus::Stopped);
    }

    /// Confirms that when the GCP instance has no access config (no NAT IP), `create_vm` returns an `Api` error containing "no public IP" rather than succeeding with a `None` IP.
    #[tokio::test]
    async fn create_vm_without_public_ip_returns_error() {
        let no_ip = GcpInstance {
            name: "fj-gcp-node".to_string(),
            status: "PROVISIONING".to_string(),
            network_interfaces: vec![GcpNetworkInterface {
                network_ip: Some("10.128.0.5".to_string()),
                access_configs: Vec::new(),
            }],
        };
        let mock = Arc::new(MockGcpApiClient::with_insert_and_get(Ok(()), Ok(no_ip)));
        let provisioner = GcpVmProvisioner::with_client_for_tests(test_config(), mock);

        let err = provisioner
            .create_vm(&test_request())
            .await
            .expect_err("missing IP should fail fast");

        match err {
            VmProvisionerError::Api(message) => {
                assert!(message.contains("no public IP"), "got: {message}");
            }
            other => panic!("expected Api error, got {other:?}"),
        }
    }
}
