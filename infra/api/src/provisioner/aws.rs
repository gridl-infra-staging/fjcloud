use async_trait::async_trait;
use aws_sdk_ec2::types::{
    Filter, IamInstanceProfileSpecification, InstanceMetadataOptionsRequest, InstanceType,
    ResourceType, Tag, TagSpecification,
};
use std::time::Duration;

use super::env_config::{optional_env, required_env};
use super::{CreateVmRequest, VmInstance, VmProvisioner, VmProvisionerError, VmStatus};

const CREATE_VM_PUBLIC_IP_POLL_ATTEMPTS: usize = 30;
const CREATE_VM_PUBLIC_IP_POLL_INTERVAL: Duration = Duration::from_secs(2);

/// Maps an EC2 instance state name string to our `VmStatus` enum.
/// Exposed as a public function so it can be unit-tested without AWS credentials.
pub fn map_ec2_state(state: &str) -> VmStatus {
    match state {
        "pending" => VmStatus::Pending,
        "running" => VmStatus::Running,
        "stopping" | "stopped" => VmStatus::Stopped,
        "shutting-down" | "terminated" => VmStatus::Terminated,
        _ => VmStatus::Unknown,
    }
}

/// Configuration for the AWS EC2 provisioner, loaded from environment variables.
#[derive(Debug, Clone)]
pub struct AwsProvisionerConfig {
    pub ami_id: String,
    pub security_group_ids: Vec<String>,
    pub subnet_id: String,
    pub key_pair_name: String,
    /// IAM instance profile name. Required for VMs to access SSM parameters at boot.
    pub instance_profile_name: Option<String>,
}

impl AwsProvisionerConfig {
    pub fn new(
        ami_id: String,
        security_group_ids: Vec<String>,
        subnet_id: String,
        key_pair_name: String,
        instance_profile_name: Option<String>,
    ) -> Self {
        Self {
            ami_id,
            security_group_ids,
            subnet_id,
            key_pair_name,
            instance_profile_name,
        }
    }

    pub fn from_env() -> Result<Self, String> {
        let ami_id = required_env("AWS_AMI_ID")?;
        let security_group_ids =
            Self::parse_security_group_ids(&required_env("AWS_SECURITY_GROUP_IDS")?)?;
        let subnet_id = required_env("AWS_SUBNET_ID")?;
        let key_pair_name = required_env("AWS_KEY_PAIR_NAME")?;
        let instance_profile_name = optional_env("AWS_INSTANCE_PROFILE_NAME");

        Ok(Self::new(
            ami_id,
            security_group_ids,
            subnet_id,
            key_pair_name,
            instance_profile_name,
        ))
    }

    fn parse_security_group_ids(raw: &str) -> Result<Vec<String>, String> {
        let security_group_ids: Vec<String> = raw
            .split(',')
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
            .collect();

        if security_group_ids.is_empty() {
            return Err("AWS_SECURITY_GROUP_IDS is empty".to_string());
        }

        Ok(security_group_ids)
    }
}

/// AWS EC2 implementation of the `VmProvisioner` trait.
pub struct AwsVmProvisioner {
    client: aws_sdk_ec2::Client,
    config: AwsProvisionerConfig,
}

impl AwsVmProvisioner {
    pub fn new(config: AwsProvisionerConfig, ec2_client: aws_sdk_ec2::Client) -> Self {
        Self {
            client: ec2_client,
            config,
        }
    }

    /// Builds an EC2 `TagSpecification` with Name (`fj-{hostname}`), `customer_id`, `node_id`, and `managed-by=fjcloud` tags.
    fn build_tags(&self, req: &CreateVmRequest) -> TagSpecification {
        TagSpecification::builder()
            .resource_type(ResourceType::Instance)
            .tags(
                Tag::builder()
                    .key("Name")
                    .value(format!("fj-{}", req.hostname))
                    .build(),
            )
            .tags(
                Tag::builder()
                    .key("customer_id")
                    .value(req.customer_id.to_string())
                    .build(),
            )
            .tags(Tag::builder().key("node_id").value(&req.node_id).build())
            .tags(Tag::builder().key("managed-by").value("fjcloud").build())
            .build()
    }

    fn instance_to_vm_instance(
        instance: &aws_sdk_ec2::types::Instance,
        region: &str,
    ) -> Result<VmInstance, VmProvisionerError> {
        let provider_vm_id = instance
            .instance_id()
            .ok_or_else(|| VmProvisionerError::Api("no instance ID returned".to_string()))?
            .to_string();

        let status = instance
            .state()
            .and_then(|s| s.name())
            .map(|n| map_ec2_state(n.as_str()))
            .unwrap_or(VmStatus::Unknown);

        Ok(VmInstance {
            provider_vm_id,
            public_ip: instance.public_ip_address().map(|s| s.to_string()),
            private_ip: instance.private_ip_address().map(|s| s.to_string()),
            status,
            region: region.to_string(),
        })
    }

    fn should_wait_for_public_ip(instance: &aws_sdk_ec2::types::Instance) -> bool {
        if instance.public_ip_address().is_some() {
            return false;
        }

        matches!(
            instance
                .state()
                .and_then(|state| state.name())
                .map(|state| map_ec2_state(state.as_str())),
            Some(VmStatus::Pending | VmStatus::Running)
        )
    }

    async fn wait_for_public_ip(
        &self,
        provider_vm_id: &str,
        region: &str,
    ) -> Result<VmInstance, VmProvisionerError> {
        for attempt in 0..CREATE_VM_PUBLIC_IP_POLL_ATTEMPTS {
            let filter = Filter::builder()
                .name("instance-id")
                .values(provider_vm_id)
                .build();

            let output = self
                .client
                .describe_instances()
                .filters(filter)
                .send()
                .await
                .map_err(|e| {
                    VmProvisionerError::Api(format!("EC2 DescribeInstances failed: {e}"))
                })?;

            let Some(instance) = output
                .reservations()
                .iter()
                .flat_map(|reservation| reservation.instances())
                .next()
            else {
                if attempt + 1 < CREATE_VM_PUBLIC_IP_POLL_ATTEMPTS {
                    tokio::time::sleep(CREATE_VM_PUBLIC_IP_POLL_INTERVAL).await;
                    continue;
                }
                return Err(VmProvisionerError::VmNotFound(provider_vm_id.to_string()));
            };

            let vm_instance = Self::instance_to_vm_instance(instance, region)?;
            if vm_instance.public_ip.is_some() || !Self::should_wait_for_public_ip(instance) {
                return Ok(vm_instance);
            }

            if attempt + 1 < CREATE_VM_PUBLIC_IP_POLL_ATTEMPTS {
                tokio::time::sleep(CREATE_VM_PUBLIC_IP_POLL_INTERVAL).await;
            }
        }

        Err(VmProvisionerError::Api(format!(
            "EC2 instance '{}' created but has no public IP after {} attempts",
            provider_vm_id, CREATE_VM_PUBLIC_IP_POLL_ATTEMPTS
        )))
    }
}

#[async_trait]
impl VmProvisioner for AwsVmProvisioner {
    /// Launches an EC2 instance with IMDSv2, optional IAM profile for SSM, base64-encoded user_data, and returns a `VmInstance`.
    async fn create_vm(&self, req: &CreateVmRequest) -> Result<VmInstance, VmProvisionerError> {
        use base64::Engine;

        let instance_type = InstanceType::from(req.vm_type.as_str());
        let tags = self.build_tags(req);

        // Enable IMDS tags so bootstrap.sh can read customer_id/node_id from
        // instance metadata without needing ec2:DescribeTags IAM permissions.
        let metadata_options = InstanceMetadataOptionsRequest::builder()
            .http_tokens("required".into()) // IMDSv2 only
            .instance_metadata_tags("enabled".into())
            .build();

        let mut run_req = self
            .client
            .run_instances()
            .image_id(&self.config.ami_id)
            .instance_type(instance_type)
            .min_count(1)
            .max_count(1)
            .subnet_id(&self.config.subnet_id)
            .key_name(&self.config.key_pair_name)
            .tag_specifications(tags)
            .metadata_options(metadata_options);

        // Attach IAM instance profile (required for SSM access at boot)
        if let Some(ref profile_name) = self.config.instance_profile_name {
            let iam_profile = IamInstanceProfileSpecification::builder()
                .name(profile_name)
                .build();
            run_req = run_req.iam_instance_profile(iam_profile);
        }

        for sg in &self.config.security_group_ids {
            run_req = run_req.security_group_ids(sg);
        }

        if let Some(user_data) = &req.user_data {
            let encoded = base64::engine::general_purpose::STANDARD.encode(user_data);
            run_req = run_req.user_data(encoded);
        }

        let output = run_req
            .send()
            .await
            .map_err(|e| VmProvisionerError::Api(format!("EC2 RunInstances failed: {e}")))?;

        let instance = output
            .instances()
            .first()
            .ok_or_else(|| VmProvisionerError::Api("no instance returned".to_string()))?;

        let vm_instance = Self::instance_to_vm_instance(instance, &req.region)?;
        if Self::should_wait_for_public_ip(instance) {
            return self
                .wait_for_public_ip(&vm_instance.provider_vm_id, &req.region)
                .await;
        }

        Ok(vm_instance)
    }

    async fn destroy_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        self.client
            .terminate_instances()
            .instance_ids(provider_vm_id)
            .send()
            .await
            .map_err(|e| VmProvisionerError::Api(format!("EC2 TerminateInstances failed: {e}")))?;

        Ok(())
    }

    async fn stop_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        self.client
            .stop_instances()
            .instance_ids(provider_vm_id)
            .send()
            .await
            .map_err(|e| VmProvisionerError::Api(format!("EC2 StopInstances failed: {e}")))?;

        Ok(())
    }

    async fn start_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        self.client
            .start_instances()
            .instance_ids(provider_vm_id)
            .send()
            .await
            .map_err(|e| VmProvisionerError::Api(format!("EC2 StartInstances failed: {e}")))?;

        Ok(())
    }

    /// Queries EC2 DescribeInstances with an instance-id filter and maps the state via `map_ec2_state`.
    async fn get_vm_status(&self, provider_vm_id: &str) -> Result<VmStatus, VmProvisionerError> {
        let filter = Filter::builder()
            .name("instance-id")
            .values(provider_vm_id)
            .build();

        let output = self
            .client
            .describe_instances()
            .filters(filter)
            .send()
            .await
            .map_err(|e| VmProvisionerError::Api(format!("EC2 DescribeInstances failed: {e}")))?;

        let instance = output
            .reservations()
            .iter()
            .flat_map(|r| r.instances())
            .next()
            .ok_or_else(|| VmProvisionerError::VmNotFound(provider_vm_id.to_string()))?;

        let status = instance
            .state()
            .and_then(|s| s.name())
            .map(|n| map_ec2_state(n.as_str()))
            .unwrap_or(VmStatus::Unknown);

        Ok(status)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use aws_sdk_ec2::types::{Instance, InstanceState, InstanceStateName};

    fn instance_fixture(state: InstanceStateName, public_ip: Option<&str>) -> Instance {
        let mut builder = Instance::builder()
            .instance_id("i-abc123")
            .private_ip_address("10.0.0.25")
            .state(InstanceState::builder().name(state).build());
        if let Some(ip) = public_ip {
            builder = builder.public_ip_address(ip);
        }
        builder.build()
    }

    #[test]
    fn map_ec2_state_pending() {
        assert_eq!(map_ec2_state("pending"), VmStatus::Pending);
    }

    #[test]
    fn map_ec2_state_running() {
        assert_eq!(map_ec2_state("running"), VmStatus::Running);
    }

    #[test]
    fn map_ec2_state_stopping() {
        assert_eq!(map_ec2_state("stopping"), VmStatus::Stopped);
    }

    #[test]
    fn map_ec2_state_stopped() {
        assert_eq!(map_ec2_state("stopped"), VmStatus::Stopped);
    }

    #[test]
    fn map_ec2_state_shutting_down() {
        assert_eq!(map_ec2_state("shutting-down"), VmStatus::Terminated);
    }

    #[test]
    fn map_ec2_state_terminated() {
        assert_eq!(map_ec2_state("terminated"), VmStatus::Terminated);
    }

    #[test]
    fn map_ec2_state_unknown_string() {
        assert_eq!(map_ec2_state("rebooting"), VmStatus::Unknown);
    }

    #[test]
    fn map_ec2_state_empty_string() {
        assert_eq!(map_ec2_state(""), VmStatus::Unknown);
    }

    /// Verifies that `AwsProvisionerConfig::new` stores all fields verbatim.
    #[test]
    fn config_new_stores_all_fields() {
        let config = AwsProvisionerConfig::new(
            "ami-123".into(),
            vec!["sg-a".into(), "sg-b".into()],
            "subnet-1".into(),
            "keypair".into(),
            Some("profile-name".into()),
        );
        assert_eq!(config.ami_id, "ami-123");
        assert_eq!(config.security_group_ids, vec!["sg-a", "sg-b"]);
        assert_eq!(config.subnet_id, "subnet-1");
        assert_eq!(config.key_pair_name, "keypair");
        assert_eq!(
            config.instance_profile_name.as_deref(),
            Some("profile-name")
        );
    }

    #[test]
    fn config_new_without_instance_profile() {
        let config = AwsProvisionerConfig::new(
            "ami-456".into(),
            vec!["sg-x".into()],
            "subnet-2".into(),
            "kp2".into(),
            None,
        );
        assert!(config.instance_profile_name.is_none());
    }

    #[test]
    fn should_wait_for_public_ip_while_instance_is_pending() {
        let instance = instance_fixture(InstanceStateName::Pending, None);
        assert!(AwsVmProvisioner::should_wait_for_public_ip(&instance));
    }

    #[test]
    fn should_not_wait_when_public_ip_is_already_present() {
        let instance = instance_fixture(InstanceStateName::Running, Some("198.51.100.10"));
        assert!(!AwsVmProvisioner::should_wait_for_public_ip(&instance));
    }

    #[test]
    fn should_not_wait_once_instance_is_no_longer_launching() {
        let instance = instance_fixture(InstanceStateName::Stopped, None);
        assert!(!AwsVmProvisioner::should_wait_for_public_ip(&instance));
    }

    #[test]
    fn instance_to_vm_instance_maps_addresses_and_status() {
        let instance = instance_fixture(InstanceStateName::Running, Some("198.51.100.10"));
        let vm = AwsVmProvisioner::instance_to_vm_instance(&instance, "us-east-1")
            .expect("fixture should map cleanly");
        assert_eq!(vm.provider_vm_id, "i-abc123");
        assert_eq!(vm.public_ip.as_deref(), Some("198.51.100.10"));
        assert_eq!(vm.private_ip.as_deref(), Some("10.0.0.25"));
        assert_eq!(vm.status, VmStatus::Running);
        assert_eq!(vm.region, "us-east-1");
    }
}
