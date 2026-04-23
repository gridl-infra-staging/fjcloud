mod common;

use api::provisioner::mock::MockVmProvisioner;
use api::provisioner::multi::MultiProviderProvisioner;
use api::provisioner::region_map::RegionConfig;
use api::provisioner::{CreateVmRequest, VmInstance, VmProvisioner, VmProvisionerError, VmStatus};
use async_trait::async_trait;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::{Mutex, OnceLock};
use uuid::Uuid;

fn make_multi(
    aws: Arc<MockVmProvisioner>,
    hetzner: Arc<MockVmProvisioner>,
) -> MultiProviderProvisioner {
    let mut providers: HashMap<String, Arc<dyn VmProvisioner>> = HashMap::new();
    providers.insert("aws".to_string(), aws);
    providers.insert("hetzner".to_string(), hetzner);
    MultiProviderProvisioner::new(providers, RegionConfig::defaults())
}

fn test_request(region: &str) -> CreateVmRequest {
    CreateVmRequest {
        region: region.to_string(),
        vm_type: "t3.small".to_string(),
        hostname: "fj-test".to_string(),
        customer_id: Uuid::new_v4(),
        node_id: "node-001".to_string(),
        user_data: None,
    }
}

fn region_env_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

struct EnvVarGuard {
    key: &'static str,
    previous: Option<String>,
}

impl EnvVarGuard {
    fn set(key: &'static str, value: &str) -> Self {
        let previous = std::env::var(key).ok();
        std::env::set_var(key, value);
        Self { key, previous }
    }
}

impl Drop for EnvVarGuard {
    fn drop(&mut self) {
        match &self.previous {
            Some(value) => std::env::set_var(self.key, value),
            None => std::env::remove_var(self.key),
        }
    }
}

struct RecordingProvisioner {
    last_region: Mutex<Option<String>>,
}

impl RecordingProvisioner {
    fn new() -> Self {
        Self {
            last_region: Mutex::new(None),
        }
    }

    fn last_region(&self) -> Option<String> {
        self.last_region.lock().unwrap().clone()
    }
}

#[async_trait]
impl VmProvisioner for RecordingProvisioner {
    async fn create_vm(&self, config: &CreateVmRequest) -> Result<VmInstance, VmProvisionerError> {
        *self.last_region.lock().unwrap() = Some(config.region.clone());
        Ok(VmInstance {
            provider_vm_id: "srv-1".to_string(),
            public_ip: None,
            private_ip: None,
            status: VmStatus::Pending,
            region: config.region.clone(),
        })
    }

    async fn destroy_vm(&self, _provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        Ok(())
    }

    async fn stop_vm(&self, _provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        Ok(())
    }

    async fn start_vm(&self, _provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        Ok(())
    }

    async fn get_vm_status(&self, _provider_vm_id: &str) -> Result<VmStatus, VmProvisionerError> {
        Ok(VmStatus::Running)
    }
}

#[tokio::test]
async fn multi_provisioner_routes_to_correct_provider() {
    let aws = Arc::new(MockVmProvisioner::new());
    let hetzner = Arc::new(MockVmProvisioner::new());
    let multi = make_multi(aws.clone(), hetzner.clone());

    // us-east-1 → aws
    let result = multi.create_vm(&test_request("us-east-1")).await.unwrap();
    assert!(
        result.provider_vm_id.starts_with("aws:"),
        "us-east-1 should route to aws, got: {}",
        result.provider_vm_id
    );
    assert_eq!(aws.vm_count(), 1);
    assert_eq!(hetzner.vm_count(), 0);

    // eu-central-1 → hetzner
    let result = multi
        .create_vm(&test_request("eu-central-1"))
        .await
        .unwrap();
    assert!(
        result.provider_vm_id.starts_with("hetzner:"),
        "eu-central-1 should route to hetzner, got: {}",
        result.provider_vm_id
    );
    assert_eq!(aws.vm_count(), 1);
    assert_eq!(hetzner.vm_count(), 1);
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn multi_provisioner_routes_custom_region_to_gcp() {
    let _lock = region_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let json = serde_json::json!({
        "custom-gcp-1": {
            "provider": "gcp",
            "provider_location": "us-central1-b",
            "display_name": "GCP US Central",
            "available": true
        }
    });
    let _region_config = EnvVarGuard::set("REGION_CONFIG", &json.to_string());

    let gcp = Arc::new(MockVmProvisioner::new());
    let mut providers: HashMap<String, Arc<dyn VmProvisioner>> = HashMap::new();
    providers.insert("gcp".to_string(), gcp.clone());

    let multi = MultiProviderProvisioner::new(providers, RegionConfig::from_env());

    let result = multi
        .create_vm(&test_request("custom-gcp-1"))
        .await
        .unwrap();
    assert!(
        result.provider_vm_id.starts_with("gcp:"),
        "custom-gcp-1 should route to gcp, got: {}",
        result.provider_vm_id
    );
    assert_eq!(gcp.vm_count(), 1);
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn multi_provisioner_routes_custom_region_to_oci() {
    let _lock = region_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let json = serde_json::json!({
        "custom-oci-1": {
            "provider": "oci",
            "provider_location": "Uocm:US-ASHBURN-AD-1",
            "display_name": "OCI US Ashburn AD1",
            "available": true
        }
    });
    let _region_config = EnvVarGuard::set("REGION_CONFIG", &json.to_string());

    let oci = Arc::new(MockVmProvisioner::new());
    let mut providers: HashMap<String, Arc<dyn VmProvisioner>> = HashMap::new();
    providers.insert("oci".to_string(), oci.clone());

    let multi = MultiProviderProvisioner::new(providers, RegionConfig::from_env());

    let result = multi
        .create_vm(&test_request("custom-oci-1"))
        .await
        .unwrap();
    assert!(
        result.provider_vm_id.starts_with("oci:"),
        "custom-oci-1 should route to oci, got: {}",
        result.provider_vm_id
    );
    assert_eq!(oci.vm_count(), 1);
}

#[tokio::test]
async fn multi_provisioner_unknown_region_returns_error() {
    let aws = Arc::new(MockVmProvisioner::new());
    let hetzner = Arc::new(MockVmProvisioner::new());
    let multi = make_multi(aws, hetzner);

    let result = multi.create_vm(&test_request("us-west-99")).await;
    assert!(result.is_err());
    match result.unwrap_err() {
        VmProvisionerError::Api(msg) => {
            assert!(msg.contains("unknown region"), "got: {msg}");
        }
        other => panic!("expected Api error, got: {other:?}"),
    }
}

#[tokio::test]
async fn multi_provisioner_with_single_provider_works() {
    let aws = Arc::new(MockVmProvisioner::new());
    let mut providers: HashMap<String, Arc<dyn VmProvisioner>> = HashMap::new();
    providers.insert("aws".to_string(), aws.clone());

    let multi = MultiProviderProvisioner::new(providers, RegionConfig::defaults());

    // AWS region works
    let result = multi.create_vm(&test_request("us-east-1")).await.unwrap();
    assert!(result.provider_vm_id.starts_with("aws:"));

    // Hetzner region fails because provider not configured
    let result = multi.create_vm(&test_request("eu-central-1")).await;
    assert!(result.is_err());
}

#[tokio::test]
async fn multi_provisioner_passes_provider_location_and_preserves_customer_region() {
    let aws = Arc::new(MockVmProvisioner::new());
    let hetzner = Arc::new(RecordingProvisioner::new());

    let mut providers: HashMap<String, Arc<dyn VmProvisioner>> = HashMap::new();
    providers.insert("aws".to_string(), aws);
    providers.insert("hetzner".to_string(), hetzner.clone());

    let multi = MultiProviderProvisioner::new(providers, RegionConfig::defaults());
    let instance = multi
        .create_vm(&test_request("eu-central-1"))
        .await
        .expect("create should succeed");

    assert_eq!(
        hetzner.last_region().as_deref(),
        Some("fsn1"),
        "provider should receive provider_location"
    );
    assert_eq!(
        instance.region, "eu-central-1",
        "customer-facing region must stay canonical"
    );
    assert!(
        instance.provider_vm_id.starts_with("hetzner:"),
        "VM id should stay provider-qualified"
    );
}

#[tokio::test]
async fn multi_provisioner_destroy_uses_composite_id() {
    let aws = Arc::new(MockVmProvisioner::new());
    let hetzner = Arc::new(MockVmProvisioner::new());
    let multi = make_multi(aws.clone(), hetzner.clone());

    // Create a VM through the multi provisioner
    let instance = multi.create_vm(&test_request("us-east-1")).await.unwrap();
    assert_eq!(aws.vm_count(), 1);

    // Destroy using composite ID
    multi.destroy_vm(&instance.provider_vm_id).await.unwrap();
    assert_eq!(aws.vm_count(), 0);
}

#[tokio::test]
async fn multi_provisioner_malformed_composite_id_returns_error() {
    let aws = Arc::new(MockVmProvisioner::new());
    let hetzner = Arc::new(MockVmProvisioner::new());
    let multi = make_multi(aws, hetzner);

    // Missing colon separator
    let err = multi.destroy_vm("no-colon-here").await.unwrap_err();
    match err {
        VmProvisionerError::Api(msg) => {
            assert!(
                msg.contains("invalid composite VM ID"),
                "expected composite ID error, got: {msg}"
            );
        }
        other => panic!("expected Api error, got: {other:?}"),
    }

    // Empty string
    let err = multi.stop_vm("").await.unwrap_err();
    assert!(matches!(err, VmProvisionerError::Api(_)));

    // Colon but unknown provider
    let err = multi.start_vm("gcp:srv-1").await.unwrap_err();
    match err {
        VmProvisionerError::Api(msg) => {
            assert!(
                msg.contains("not configured"),
                "expected provider not configured error, got: {msg}"
            );
        }
        other => panic!("expected Api error, got: {other:?}"),
    }
}

#[tokio::test]
async fn multi_provisioner_stop_start_status_route_correctly() {
    let aws = Arc::new(MockVmProvisioner::new());
    let hetzner = Arc::new(MockVmProvisioner::new());
    let multi = make_multi(aws.clone(), hetzner.clone());

    // Create VMs on each provider (mock creates VMs in Pending state)
    let aws_instance = multi.create_vm(&test_request("us-east-1")).await.unwrap();
    let hetzner_instance = multi
        .create_vm(&test_request("eu-central-1"))
        .await
        .unwrap();

    // get_vm_status routes correctly — new VMs start as Pending
    let status = multi
        .get_vm_status(&aws_instance.provider_vm_id)
        .await
        .unwrap();
    assert_eq!(status, VmStatus::Pending);

    // start_vm transitions Pending → Running via correct provider
    multi.start_vm(&aws_instance.provider_vm_id).await.unwrap();
    let status = multi
        .get_vm_status(&aws_instance.provider_vm_id)
        .await
        .unwrap();
    assert_eq!(status, VmStatus::Running);

    // stop_vm transitions Running → Stopped via correct provider
    multi.stop_vm(&aws_instance.provider_vm_id).await.unwrap();
    let status = multi
        .get_vm_status(&aws_instance.provider_vm_id)
        .await
        .unwrap();
    assert_eq!(status, VmStatus::Stopped);

    // Hetzner VM is still Pending (untouched — proves routing isolation)
    let status = multi
        .get_vm_status(&hetzner_instance.provider_vm_id)
        .await
        .unwrap();
    assert_eq!(status, VmStatus::Pending);
}

#[test]
fn region_config_get_available_excludes_unavailable() {
    let json = serde_json::json!({
        "active-region": {
            "provider": "aws",
            "provider_location": "us-east-1",
            "display_name": "Active Region",
            "available": true
        },
        "disabled-region": {
            "provider": "hetzner",
            "provider_location": "fsn1",
            "display_name": "Disabled Region",
            "available": false
        }
    });

    let _lock = region_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _guard = EnvVarGuard::set("REGION_CONFIG", &json.to_string());
    let config = RegionConfig::from_env();

    // get_region returns both
    assert!(config.get_region("active-region").is_some());
    assert!(config.get_region("disabled-region").is_some());

    // get_available_region filters out unavailable
    assert!(config.get_available_region("active-region").is_some());
    assert!(
        config.get_available_region("disabled-region").is_none(),
        "unavailable region must be excluded from get_available_region"
    );

    // available_regions only returns available ones
    let available = config.available_regions();
    assert_eq!(available.len(), 1);
    assert_eq!(available[0].0, "active-region");

    // available_region_ids matches
    let ids = config.available_region_ids();
    assert_eq!(ids, vec!["active-region"]);
}

#[test]
fn region_config_defaults_include_both_providers() {
    let config = RegionConfig::defaults();
    let available = config.available_regions();

    // Should have 6 regions total
    assert_eq!(available.len(), 6);

    // Should have both providers
    let providers: std::collections::HashSet<&str> =
        available.iter().map(|(_, e)| e.provider.as_str()).collect();
    assert!(providers.contains("aws"));
    assert!(providers.contains("hetzner"));

    // Verify specific mappings
    assert_eq!(config.provider_for_region("us-east-1"), Some("aws"));
    assert_eq!(config.provider_for_region("eu-west-1"), Some("aws"));
    assert_eq!(config.provider_for_region("eu-central-1"), Some("hetzner"));
    assert_eq!(config.provider_for_region("eu-north-1"), Some("hetzner"));
    assert_eq!(config.provider_for_region("us-east-2"), Some("hetzner"));
    assert_eq!(config.provider_for_region("us-west-1"), Some("hetzner"));
    assert!(config.provider_for_region("us-west-99").is_none());
}

#[test]
fn region_config_from_env_parses_json() {
    let _lock = region_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let json = serde_json::json!({
        "custom-region-1": {
            "provider": "aws",
            "provider_location": "ap-southeast-1",
            "display_name": "Asia (Singapore)",
            "available": true
        }
    });

    let _region_config = EnvVarGuard::set("REGION_CONFIG", &json.to_string());
    let config = RegionConfig::from_env();

    assert_eq!(config.provider_for_region("custom-region-1"), Some("aws"));
    assert!(config.provider_for_region("us-east-1").is_none()); // defaults not included
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn multi_provisioner_routes_custom_region_to_bare_metal() {
    let _lock = region_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let json = serde_json::json!({
        "eu-central-bm": {
            "provider": "bare_metal",
            "provider_location": "fsn1-rack3",
            "display_name": "EU Central (Bare Metal)",
            "available": true
        }
    });
    let _region_config = EnvVarGuard::set("REGION_CONFIG", &json.to_string());

    let bm = Arc::new(MockVmProvisioner::new());
    let mut providers: HashMap<String, Arc<dyn VmProvisioner>> = HashMap::new();
    providers.insert("bare_metal".to_string(), bm.clone());

    let multi = MultiProviderProvisioner::new(providers, RegionConfig::from_env());

    let result = multi
        .create_vm(&test_request("eu-central-bm"))
        .await
        .unwrap();
    assert!(
        result.provider_vm_id.starts_with("bare_metal:"),
        "eu-central-bm should route to bare_metal, got: {}",
        result.provider_vm_id
    );
    assert_eq!(bm.vm_count(), 1);
}

#[tokio::test]
async fn build_vm_provisioner_empty_map_falls_back_to_unconfigured() {
    let provisioner =
        api::provisioner::build_vm_provisioner(HashMap::new(), RegionConfig::defaults());

    let err = provisioner
        .create_vm(&test_request("us-east-1"))
        .await
        .expect_err("empty provider map should return unconfigured provisioner");

    assert!(matches!(err, VmProvisionerError::NotConfigured));
}

#[tokio::test]
async fn build_vm_provisioner_single_provider_uses_multi_provider_routing() {
    let aws = Arc::new(MockVmProvisioner::new());
    let mut providers: HashMap<String, Arc<dyn VmProvisioner>> = HashMap::new();
    providers.insert("aws".to_string(), aws.clone());

    let provisioner = api::provisioner::build_vm_provisioner(providers, RegionConfig::defaults());
    let instance = provisioner
        .create_vm(&test_request("us-east-1"))
        .await
        .expect("single provider must still route through multi provider logic");

    assert!(
        instance.provider_vm_id.starts_with("aws:"),
        "provider-qualified id expected from multi provider path"
    );
    assert_eq!(
        aws.vm_count(),
        1,
        "create should be delegated to aws provider"
    );

    let err = provisioner
        .create_vm(&test_request("eu-central-1"))
        .await
        .expect_err("unsupported provider regions should be filtered out");
    match err {
        VmProvisionerError::Api(msg) => {
            assert!(
                msg.contains("unknown region"),
                "expected unknown region error, got: {msg}"
            );
        }
        other => panic!("expected Api error, got: {other:?}"),
    }
}
