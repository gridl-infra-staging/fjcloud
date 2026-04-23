//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/provisioner/oci/mod.rs.
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use base64::Engine;
use serde::{Deserialize, Serialize};

use super::env_config::{parse_f32_env, parse_u32_env, parse_u64_env, required_env};
use super::{CreateVmRequest, VmInstance, VmProvisioner, VmProvisionerError, VmStatus};

mod api_client;
use api_client::{OciApi, ReqwestOciApiClient};

#[cfg(test)]
#[path = "../../../tests/support/oci.rs"]
mod test_support;

/// Maps an OCI instance lifecycle state to our `VmStatus` enum.
pub fn map_oci_status(state: &str) -> VmStatus {
    match state {
        "PROVISIONING" | "STARTING" | "MOVING" | "CREATING_IMAGE" => VmStatus::Pending,
        "RUNNING" => VmStatus::Running,
        "STOPPING" | "STOPPED" => VmStatus::Stopped,
        "TERMINATING" | "TERMINATED" => VmStatus::Terminated,
        _ => VmStatus::Unknown,
    }
}

/// Configuration for the OCI Compute provisioner.
#[derive(Clone)]
pub struct OciProvisionerConfig {
    pub tenancy_ocid: String,
    pub user_ocid: String,
    pub key_fingerprint: String,
    pub private_key_pem: String,
    pub compartment_id: String,
    pub availability_domain: String,
    pub subnet_id: String,
    pub image_id: String,
    pub region: String,
    pub shape: String,
    pub shape_ocpus: f32,
    pub shape_memory_gbs: f32,
    pub api_base_url: String,
    pub create_poll_attempts: u32,
    pub create_poll_interval_ms: u64,
}

impl OciProvisionerConfig {
    /// Loads config from env vars. Reads the RSA private key from `OCI_PRIVATE_KEY_PATH` (PKCS#8 or PKCS#1). Many required OCIDs; flex shape with configurable OCPUs/memory. Defaults: us-ashburn-1, VM.Standard.E4.Flex.
    pub fn from_env() -> Result<Self, String> {
        let private_key_path = required_env("OCI_PRIVATE_KEY_PATH")?;
        let private_key_pem = std::fs::read_to_string(&private_key_path)
            .map_err(|e| format!("failed to read OCI private key '{}': {e}", private_key_path))?;
        api_client::parse_oci_private_key(&private_key_pem)?;

        let region = std::env::var("OCI_REGION").unwrap_or_else(|_| "us-ashburn-1".to_string());
        let api_base_url = std::env::var("OCI_API_BASE_URL")
            .unwrap_or_else(|_| format!("https://iaas.{region}.oraclecloud.com"));

        Ok(Self {
            tenancy_ocid: required_env("OCI_TENANCY_OCID")?,
            user_ocid: required_env("OCI_USER_OCID")?,
            key_fingerprint: required_env("OCI_KEY_FINGERPRINT")?,
            private_key_pem,
            compartment_id: required_env("OCI_COMPARTMENT_ID")?,
            availability_domain: required_env("OCI_AVAILABILITY_DOMAIN")?,
            subnet_id: required_env("OCI_SUBNET_ID")?,
            image_id: required_env("OCI_IMAGE_ID")?,
            region,
            shape: std::env::var("OCI_SHAPE").unwrap_or_else(|_| "VM.Standard.E4.Flex".to_string()),
            shape_ocpus: parse_f32_env("OCI_SHAPE_OCPUS", 4.0)?,
            shape_memory_gbs: parse_f32_env("OCI_SHAPE_MEMORY_GBS", 16.0)?,
            api_base_url,
            create_poll_attempts: parse_u32_env("OCI_CREATE_POLL_ATTEMPTS", 10)?,
            create_poll_interval_ms: parse_u64_env("OCI_CREATE_POLL_INTERVAL_MS", 2000)?,
        })
    }
}

/// OCI launch payload: availability domain, compartment, shape config (flex OCPUs/memory), VNIC details, freeform tags, and optional base64-encoded user_data metadata.
#[derive(Debug, Clone, Serialize)]
struct LaunchInstanceRequest {
    #[serde(rename = "availabilityDomain")]
    availability_domain: String,
    #[serde(rename = "compartmentId")]
    compartment_id: String,
    shape: String,
    #[serde(rename = "sourceDetails")]
    source_details: SourceDetails,
    #[serde(rename = "createVnicDetails")]
    create_vnic_details: CreateVnicDetails,
    #[serde(rename = "displayName")]
    display_name: String,
    #[serde(rename = "freeformTags")]
    freeform_tags: HashMap<String, String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    metadata: Option<LaunchMetadata>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "shapeConfig")]
    shape_config: Option<ShapeConfig>,
}

#[derive(Debug, Clone, Serialize)]
struct SourceDetails {
    #[serde(rename = "sourceType")]
    source_type: String,
    #[serde(rename = "imageId")]
    image_id: String,
}

#[derive(Debug, Clone, Serialize)]
struct CreateVnicDetails {
    #[serde(rename = "subnetId")]
    subnet_id: String,
    #[serde(rename = "assignPublicIp")]
    assign_public_ip: bool,
    #[serde(rename = "displayName")]
    display_name: String,
}

#[derive(Debug, Clone, Serialize)]
struct LaunchMetadata {
    user_data: String,
}

#[derive(Debug, Clone, Serialize)]
struct ShapeConfig {
    ocpus: f32,
    #[serde(rename = "memoryInGBs")]
    memory_in_gbs: f32,
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct OciInstance {
    pub id: String,
    #[serde(rename = "lifecycleState")]
    pub lifecycle_state: String,
}

#[derive(Debug, Clone, Deserialize)]
struct OciVnicAttachmentList {
    items: Vec<OciVnicAttachment>,
}

#[derive(Debug, Clone, Deserialize)]
struct OciVnicAttachment {
    #[serde(rename = "vnicId")]
    vnic_id: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct OciVnic {
    #[serde(rename = "publicIp")]
    public_ip: Option<String>,
    #[serde(rename = "privateIp")]
    private_ip: Option<String>,
}

pub struct OciVmProvisioner {
    client: Arc<dyn OciApi>,
    config: OciProvisionerConfig,
}

/// Returns an `OciProvisionerConfig` with test OCIDs and a generated RSA key for unit tests. Poll attempts set to 1 for fast test execution.
#[cfg(test)]
pub(crate) fn test_oci_provisioner_config() -> OciProvisionerConfig {
    OciProvisionerConfig {
        tenancy_ocid: "ocid1.tenancy.oc1..aaaa".to_string(),
        user_ocid: "ocid1.user.oc1..bbbb".to_string(),
        key_fingerprint: "20:3b:97:13:55:1c:aa:66".to_string(),
        private_key_pem: test_support::TEST_PRIVATE_KEY_PEM.to_string(),
        compartment_id: "ocid1.compartment.oc1..cccc".to_string(),
        availability_domain: "Uocm:US-ASHBURN-AD-1".to_string(),
        subnet_id: "ocid1.subnet.oc1.iad..dddd".to_string(),
        image_id: "ocid1.image.oc1.iad..eeee".to_string(),
        region: "us-ashburn-1".to_string(),
        shape: "VM.Standard.E4.Flex".to_string(),
        shape_ocpus: 4.0,
        shape_memory_gbs: 16.0,
        api_base_url: "https://iaas.us-ashburn-1.oraclecloud.com".to_string(),
        create_poll_attempts: 1,
        create_poll_interval_ms: 1,
    }
}

impl OciVmProvisioner {
    pub fn new(config: OciProvisionerConfig) -> Result<Self, VmProvisionerError> {
        let client = Arc::new(ReqwestOciApiClient::new(&config)?);
        Ok(Self { client, config })
    }

    fn validate_vm_id(instance_id: &str) -> Result<(), VmProvisionerError> {
        if instance_id.trim().is_empty() {
            return Err(VmProvisionerError::Api(
                "invalid OCI VM ID: empty instance ID".to_string(),
            ));
        }
        Ok(())
    }

    fn availability_domain_for_create(&self, req: &CreateVmRequest) -> String {
        let trimmed = req.region.trim();
        if trimmed.is_empty() {
            self.config.availability_domain.clone()
        } else {
            trimmed.to_string()
        }
    }

    #[cfg(test)]
    fn with_client_for_tests(config: OciProvisionerConfig, client: Arc<dyn OciApi>) -> Self {
        Self { client, config }
    }
}

#[async_trait]
impl VmProvisioner for OciVmProvisioner {
    /// Launches an OCI instance, then polls for VNIC attachment and public IP. Provider VM ID is the OCI instance OCID.
    async fn create_vm(&self, req: &CreateVmRequest) -> Result<VmInstance, VmProvisionerError> {
        let availability_domain = self.availability_domain_for_create(req);

        let mut tags = HashMap::new();
        tags.insert("customer_id".to_string(), req.customer_id.to_string());
        tags.insert("node_id".to_string(), req.node_id.clone());
        tags.insert("managed-by".to_string(), "fjcloud".to_string());

        let metadata = req.user_data.as_ref().map(|user_data| LaunchMetadata {
            user_data: base64::engine::general_purpose::STANDARD.encode(user_data),
        });

        let body = LaunchInstanceRequest {
            availability_domain,
            compartment_id: self.config.compartment_id.clone(),
            shape: self.config.shape.clone(),
            source_details: SourceDetails {
                source_type: "image".to_string(),
                image_id: self.config.image_id.clone(),
            },
            create_vnic_details: CreateVnicDetails {
                subnet_id: self.config.subnet_id.clone(),
                assign_public_ip: true,
                display_name: req.hostname.clone(),
            },
            display_name: req.hostname.clone(),
            freeform_tags: tags,
            metadata,
            shape_config: Some(ShapeConfig {
                ocpus: self.config.shape_ocpus,
                memory_in_gbs: self.config.shape_memory_gbs,
            }),
        };

        let launched = self.client.launch_instance(&body).await?;
        let attempts = self.config.create_poll_attempts.max(1);
        let mut last_state = launched.lifecycle_state.clone();

        for attempt in 0..attempts {
            let instance = self.client.get_instance(&launched.id).await?;
            last_state = instance.lifecycle_state.clone();
            let attachments = self
                .client
                .list_vnic_attachments(&self.config.compartment_id, &launched.id)
                .await?;
            let vnic_id = attachments.into_iter().find_map(|att| att.vnic_id);

            if let Some(vnic_id) = vnic_id {
                let vnic = self.client.get_vnic(&vnic_id).await?;
                if let Some(public_ip) = vnic.public_ip {
                    return Ok(VmInstance {
                        provider_vm_id: launched.id.clone(),
                        public_ip: Some(public_ip),
                        private_ip: vnic.private_ip,
                        status: map_oci_status(&instance.lifecycle_state),
                        region: req.region.clone(),
                    });
                }
            }

            if attempt + 1 < attempts {
                tokio::time::sleep(Duration::from_millis(self.config.create_poll_interval_ms))
                    .await;
            }
        }

        Err(VmProvisionerError::Api(format!(
            "OCI instance '{}' created but has no public IP after {} attempts (status: {})",
            launched.id, attempts, last_state
        )))
    }

    async fn destroy_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        Self::validate_vm_id(provider_vm_id)?;
        self.client.terminate_instance(provider_vm_id).await
    }

    async fn stop_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        Self::validate_vm_id(provider_vm_id)?;
        self.client
            .instance_action(provider_vm_id, "SOFTSTOP")
            .await
    }

    async fn start_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        Self::validate_vm_id(provider_vm_id)?;
        self.client.instance_action(provider_vm_id, "START").await
    }

    async fn get_vm_status(&self, provider_vm_id: &str) -> Result<VmStatus, VmProvisionerError> {
        Self::validate_vm_id(provider_vm_id)?;
        let instance = self.client.get_instance(provider_vm_id).await?;
        Ok(map_oci_status(&instance.lifecycle_state))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::sync::Mutex;
    use uuid::Uuid;

    struct MockOciApiClient {
        launch_calls: Mutex<Vec<LaunchInstanceRequest>>,
        terminate_calls: Mutex<Vec<String>>,
        action_calls: Mutex<Vec<(String, String)>>,
        get_instance_calls: Mutex<Vec<String>>,
        list_vnic_attachments_calls: Mutex<Vec<(String, String)>>,
        get_vnic_calls: Mutex<Vec<String>>,
        launch_responses: Mutex<VecDeque<Result<OciInstance, VmProvisionerError>>>,
        get_instance_responses: Mutex<VecDeque<Result<OciInstance, VmProvisionerError>>>,
        list_vnic_attachments_responses:
            Mutex<VecDeque<Result<Vec<OciVnicAttachment>, VmProvisionerError>>>,
        get_vnic_responses: Mutex<VecDeque<Result<OciVnic, VmProvisionerError>>>,
    }

    impl MockOciApiClient {
        /// Constructs a mock pre-loaded with one response for each API call in the create_vm flow: launch, get_instance, list_vnic_attachments, get_vnic.
        fn with_create_responses(
            launch: Result<OciInstance, VmProvisionerError>,
            get_instance: Result<OciInstance, VmProvisionerError>,
            attachments: Result<Vec<OciVnicAttachment>, VmProvisionerError>,
            vnic: Result<OciVnic, VmProvisionerError>,
        ) -> Self {
            Self {
                launch_calls: Mutex::new(Vec::new()),
                terminate_calls: Mutex::new(Vec::new()),
                action_calls: Mutex::new(Vec::new()),
                get_instance_calls: Mutex::new(Vec::new()),
                list_vnic_attachments_calls: Mutex::new(Vec::new()),
                get_vnic_calls: Mutex::new(Vec::new()),
                launch_responses: Mutex::new(VecDeque::from([launch])),
                get_instance_responses: Mutex::new(VecDeque::from([get_instance])),
                list_vnic_attachments_responses: Mutex::new(VecDeque::from([attachments])),
                get_vnic_responses: Mutex::new(VecDeque::from([vnic])),
            }
        }

        fn with_get_instance(get_instance: Result<OciInstance, VmProvisionerError>) -> Self {
            Self {
                launch_calls: Mutex::new(Vec::new()),
                terminate_calls: Mutex::new(Vec::new()),
                action_calls: Mutex::new(Vec::new()),
                get_instance_calls: Mutex::new(Vec::new()),
                list_vnic_attachments_calls: Mutex::new(Vec::new()),
                get_vnic_calls: Mutex::new(Vec::new()),
                launch_responses: Mutex::new(VecDeque::new()),
                get_instance_responses: Mutex::new(VecDeque::from([get_instance])),
                list_vnic_attachments_responses: Mutex::new(VecDeque::new()),
                get_vnic_responses: Mutex::new(VecDeque::new()),
            }
        }
    }

    #[async_trait]
    impl OciApi for MockOciApiClient {
        async fn launch_instance(
            &self,
            body: &LaunchInstanceRequest,
        ) -> Result<OciInstance, VmProvisionerError> {
            self.launch_calls
                .lock()
                .expect("launch_calls lock poisoned")
                .push(body.clone());
            self.launch_responses
                .lock()
                .expect("launch_responses lock poisoned")
                .pop_front()
                .expect("missing mocked launch response")
        }

        async fn terminate_instance(&self, instance_id: &str) -> Result<(), VmProvisionerError> {
            self.terminate_calls
                .lock()
                .expect("terminate_calls lock poisoned")
                .push(instance_id.to_string());
            Ok(())
        }

        async fn instance_action(
            &self,
            instance_id: &str,
            action: &str,
        ) -> Result<(), VmProvisionerError> {
            self.action_calls
                .lock()
                .expect("action_calls lock poisoned")
                .push((instance_id.to_string(), action.to_string()));
            Ok(())
        }

        async fn get_instance(&self, instance_id: &str) -> Result<OciInstance, VmProvisionerError> {
            self.get_instance_calls
                .lock()
                .expect("get_instance_calls lock poisoned")
                .push(instance_id.to_string());
            self.get_instance_responses
                .lock()
                .expect("get_instance_responses lock poisoned")
                .pop_front()
                .expect("missing mocked get_instance response")
        }

        async fn list_vnic_attachments(
            &self,
            compartment_id: &str,
            instance_id: &str,
        ) -> Result<Vec<OciVnicAttachment>, VmProvisionerError> {
            self.list_vnic_attachments_calls
                .lock()
                .expect("list_vnic_attachments_calls lock poisoned")
                .push((compartment_id.to_string(), instance_id.to_string()));
            self.list_vnic_attachments_responses
                .lock()
                .expect("list_vnic_attachments_responses lock poisoned")
                .pop_front()
                .expect("missing mocked list_vnic_attachments response")
        }

        async fn get_vnic(&self, vnic_id: &str) -> Result<OciVnic, VmProvisionerError> {
            self.get_vnic_calls
                .lock()
                .expect("get_vnic_calls lock poisoned")
                .push(vnic_id.to_string());
            self.get_vnic_responses
                .lock()
                .expect("get_vnic_responses lock poisoned")
                .pop_front()
                .expect("missing mocked get_vnic response")
        }
    }

    fn test_request() -> CreateVmRequest {
        CreateVmRequest {
            region: "Uocm:US-ASHBURN-AD-1".to_string(),
            vm_type: "VM.Standard.E4.Flex".to_string(),
            hostname: "fj-oci-node".to_string(),
            customer_id: Uuid::new_v4(),
            node_id: "node-oci-001".to_string(),
            user_data: Some("#!/bin/bash\necho oci".to_string()),
        }
    }

    fn launched_instance() -> OciInstance {
        OciInstance {
            id: "ocid1.instance.oc1.iad..xyz".to_string(),
            lifecycle_state: "PROVISIONING".to_string(),
        }
    }

    fn running_instance() -> OciInstance {
        OciInstance {
            id: "ocid1.instance.oc1.iad..xyz".to_string(),
            lifecycle_state: "RUNNING".to_string(),
        }
    }

    /// Verifies `create_vm` sends the correct OCI launch payload: availability domain, compartment, shape, base64-encoded user-data metadata, subnet with public IP, display name, and `managed-by`/`node_id` freeform tags. Also checks the returned `VmInstance` has the correct OCID, IPs, and status.
    #[tokio::test]
    async fn create_vm_builds_expected_payload() {
        let mock = Arc::new(MockOciApiClient::with_create_responses(
            Ok(launched_instance()),
            Ok(running_instance()),
            Ok(vec![OciVnicAttachment {
                vnic_id: Some("ocid1.vnic.oc1.iad..v1".to_string()),
            }]),
            Ok(OciVnic {
                public_ip: Some("198.51.100.22".to_string()),
                private_ip: Some("10.0.0.12".to_string()),
            }),
        ));
        let provisioner =
            OciVmProvisioner::with_client_for_tests(test_oci_provisioner_config(), mock.clone());

        let req = test_request();
        let result = provisioner
            .create_vm(&req)
            .await
            .expect("create_vm should succeed");

        let calls = mock.launch_calls.lock().expect("launch calls lock");
        assert_eq!(calls.len(), 1);
        let launch = &calls[0];
        assert_eq!(launch.availability_domain, "Uocm:US-ASHBURN-AD-1");
        assert_eq!(launch.compartment_id, "ocid1.compartment.oc1..cccc");
        assert_eq!(launch.shape, "VM.Standard.E4.Flex");
        assert_eq!(launch.source_details.source_type, "image");
        assert_eq!(launch.source_details.image_id, "ocid1.image.oc1.iad..eeee");
        assert_eq!(
            launch.create_vnic_details.subnet_id,
            "ocid1.subnet.oc1.iad..dddd"
        );
        assert!(launch.create_vnic_details.assign_public_ip);
        assert_eq!(launch.display_name, "fj-oci-node");
        assert_eq!(
            launch
                .metadata
                .as_ref()
                .map(|m| m.user_data.clone())
                .as_deref(),
            Some("IyEvYmluL2Jhc2gKZWNobyBvY2k="),
            "OCI metadata user_data must be base64-encoded"
        );
        assert_eq!(
            launch.freeform_tags.get("managed-by"),
            Some(&"fjcloud".to_string())
        );
        assert_eq!(
            launch.freeform_tags.get("node_id"),
            Some(&"node-oci-001".to_string())
        );

        assert_eq!(result.provider_vm_id, "ocid1.instance.oc1.iad..xyz");
        assert_eq!(result.public_ip.as_deref(), Some("198.51.100.22"));
        assert_eq!(result.private_ip.as_deref(), Some("10.0.0.12"));
        assert_eq!(result.status, VmStatus::Running);
        assert_eq!(result.region, "Uocm:US-ASHBURN-AD-1");
    }

    /// Ensures `destroy_vm` delegates to `terminate_instance` with the correct OCID.
    #[tokio::test]
    async fn destroy_vm_calls_terminate() {
        let mock = Arc::new(MockOciApiClient::with_get_instance(Ok(running_instance())));
        let provisioner =
            OciVmProvisioner::with_client_for_tests(test_oci_provisioner_config(), mock.clone());

        provisioner
            .destroy_vm("ocid1.instance.oc1.iad..xyz")
            .await
            .expect("destroy_vm should succeed");

        let calls = mock.terminate_calls.lock().expect("terminate_calls lock");
        assert_eq!(
            calls.as_slice(),
            &["ocid1.instance.oc1.iad..xyz".to_string()]
        );
    }

    /// Verifies `stop_vm` issues a `SOFTSTOP` instance action (graceful shutdown) for the given OCID.
    #[tokio::test]
    async fn stop_vm_calls_softstop_action() {
        let mock = Arc::new(MockOciApiClient::with_get_instance(Ok(running_instance())));
        let provisioner =
            OciVmProvisioner::with_client_for_tests(test_oci_provisioner_config(), mock.clone());

        provisioner
            .stop_vm("ocid1.instance.oc1.iad..xyz")
            .await
            .expect("stop_vm should succeed");

        let calls = mock.action_calls.lock().expect("action_calls lock");
        assert_eq!(
            calls.as_slice(),
            &[(
                "ocid1.instance.oc1.iad..xyz".to_string(),
                "SOFTSTOP".to_string()
            )]
        );
    }

    /// Verifies `start_vm` issues a `START` instance action for the given OCID.
    #[tokio::test]
    async fn start_vm_calls_start_action() {
        let mock = Arc::new(MockOciApiClient::with_get_instance(Ok(running_instance())));
        let provisioner =
            OciVmProvisioner::with_client_for_tests(test_oci_provisioner_config(), mock.clone());

        provisioner
            .start_vm("ocid1.instance.oc1.iad..xyz")
            .await
            .expect("start_vm should succeed");

        let calls = mock.action_calls.lock().expect("action_calls lock");
        assert_eq!(
            calls.as_slice(),
            &[(
                "ocid1.instance.oc1.iad..xyz".to_string(),
                "START".to_string()
            )]
        );
    }

    #[tokio::test]
    async fn get_vm_status_returns_correct_status() {
        let mock = Arc::new(MockOciApiClient::with_get_instance(Ok(OciInstance {
            id: "ocid1.instance.oc1.iad..xyz".to_string(),
            lifecycle_state: "STOPPED".to_string(),
        })));
        let provisioner =
            OciVmProvisioner::with_client_for_tests(test_oci_provisioner_config(), mock);

        let status = provisioner
            .get_vm_status("ocid1.instance.oc1.iad..xyz")
            .await
            .expect("status should succeed");
        assert_eq!(status, VmStatus::Stopped);
    }

    /// Confirms that when the VNIC has no public IP, `create_vm` returns an `Api` error rather than succeeding with a `None` IP.
    #[tokio::test]
    async fn create_vm_without_public_ip_returns_error() {
        let mock = Arc::new(MockOciApiClient::with_create_responses(
            Ok(launched_instance()),
            Ok(running_instance()),
            Ok(vec![OciVnicAttachment {
                vnic_id: Some("ocid1.vnic.oc1.iad..v1".to_string()),
            }]),
            Ok(OciVnic {
                public_ip: None,
                private_ip: Some("10.0.0.12".to_string()),
            }),
        ));
        let provisioner =
            OciVmProvisioner::with_client_for_tests(test_oci_provisioner_config(), mock);

        let err = provisioner
            .create_vm(&test_request())
            .await
            .expect_err("create_vm should fail without public IP");
        match err {
            VmProvisionerError::Api(msg) => {
                assert!(
                    msg.contains("no public IP"),
                    "expected no public IP error, got: {msg}"
                );
            }
            other => panic!("expected Api error, got: {other:?}"),
        }
    }
}
