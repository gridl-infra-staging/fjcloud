use api::provisioner::gcp::{map_gcp_status, GcpProvisionerConfig};
use api::provisioner::VmStatus;
use std::sync::{Mutex, OnceLock};

fn gcp_env_lock() -> &'static Mutex<()> {
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

    fn unset(key: &'static str) -> Self {
        let previous = std::env::var(key).ok();
        std::env::remove_var(key);
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

#[test]
fn gcp_config_from_env() {
    let _lock = gcp_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let _token = EnvVarGuard::set("GCP_API_TOKEN", "ya29.test-token");
    let _project = EnvVarGuard::set("GCP_PROJECT_ID", "fjcloud-prod");
    let _zone = EnvVarGuard::set("GCP_ZONE", "us-central1-b");
    let _machine = EnvVarGuard::set("GCP_MACHINE_TYPE", "e2-standard-4");
    let _image = EnvVarGuard::set(
        "GCP_IMAGE",
        "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts",
    );
    let _network = EnvVarGuard::set("GCP_NETWORK", "global/networks/default");
    let _subnetwork = EnvVarGuard::set("GCP_SUBNETWORK", "regions/us-central1/subnetworks/default");

    let config = GcpProvisionerConfig::from_env().expect("config should parse");
    assert_eq!(config.api_token, "ya29.test-token");
    assert_eq!(config.project_id, "fjcloud-prod");
    assert_eq!(config.zone, "us-central1-b");
    assert_eq!(config.machine_type, "e2-standard-4");
    assert_eq!(
        config.image,
        "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts"
    );
    assert_eq!(config.network, "global/networks/default");
    assert_eq!(
        config.subnetwork.as_deref(),
        Some("regions/us-central1/subnetworks/default")
    );
}

#[test]
fn gcp_config_defaults() {
    let _lock = gcp_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let _token = EnvVarGuard::set("GCP_API_TOKEN", "ya29.default-token");
    let _project = EnvVarGuard::set("GCP_PROJECT_ID", "fjcloud-dev");
    let _zone = EnvVarGuard::unset("GCP_ZONE");
    let _machine = EnvVarGuard::unset("GCP_MACHINE_TYPE");
    let _image = EnvVarGuard::unset("GCP_IMAGE");
    let _network = EnvVarGuard::unset("GCP_NETWORK");
    let _subnetwork = EnvVarGuard::unset("GCP_SUBNETWORK");

    let config = GcpProvisionerConfig::from_env().expect("config should parse");
    assert_eq!(config.zone, "us-central1-a");
    assert_eq!(config.machine_type, "e2-standard-4");
    assert_eq!(
        config.image,
        "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts"
    );
    assert_eq!(config.network, "global/networks/default");
    assert!(config.subnetwork.is_none());
}

#[test]
fn gcp_config_requires_token_and_project() {
    let _lock = gcp_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let _token = EnvVarGuard::unset("GCP_API_TOKEN");
    let _project = EnvVarGuard::unset("GCP_PROJECT_ID");

    let err = GcpProvisionerConfig::from_env().expect_err("missing env should fail");
    assert!(
        err.contains("GCP_API_TOKEN") || err.contains("GCP_PROJECT_ID"),
        "unexpected error: {err}"
    );
}

#[test]
fn gcp_status_mapping_complete() {
    assert_eq!(map_gcp_status("PROVISIONING"), VmStatus::Pending);
    assert_eq!(map_gcp_status("STAGING"), VmStatus::Pending);
    assert_eq!(map_gcp_status("REPAIRING"), VmStatus::Pending);
    assert_eq!(map_gcp_status("RUNNING"), VmStatus::Running);
    assert_eq!(map_gcp_status("STOPPING"), VmStatus::Stopped);
    assert_eq!(map_gcp_status("SUSPENDING"), VmStatus::Stopped);
    assert_eq!(map_gcp_status("SUSPENDED"), VmStatus::Stopped);
    // GCP "TERMINATED" means stopped (instance exists, can be restarted).
    // Deleted instances return 404, not a status string.
    assert_eq!(map_gcp_status("TERMINATED"), VmStatus::Stopped);
    assert_eq!(map_gcp_status("UNKNOWN_STATUS"), VmStatus::Unknown);
}
