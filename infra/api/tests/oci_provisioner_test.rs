use api::provisioner::oci::{map_oci_status, OciProvisionerConfig};
use api::provisioner::VmStatus;
use std::sync::{Mutex, OnceLock};

mod support;

use support::oci::write_test_key_file;

fn oci_env_lock() -> &'static Mutex<()> {
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
fn oci_config_from_env() {
    let _lock = oci_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let key_path = write_test_key_file();
    let _tenancy = EnvVarGuard::set("OCI_TENANCY_OCID", "ocid1.tenancy.oc1..aaaa");
    let _user = EnvVarGuard::set("OCI_USER_OCID", "ocid1.user.oc1..bbbb");
    let _fingerprint = EnvVarGuard::set("OCI_KEY_FINGERPRINT", "20:3b:97:13:55:1c:aa:66");
    let _private_key = EnvVarGuard::set(
        "OCI_PRIVATE_KEY_PATH",
        key_path.to_str().expect("path should be utf8"),
    );
    let _compartment = EnvVarGuard::set("OCI_COMPARTMENT_ID", "ocid1.compartment.oc1..cccc");
    let _availability_domain = EnvVarGuard::set("OCI_AVAILABILITY_DOMAIN", "Uocm:US-ASHBURN-AD-1");
    let _subnet = EnvVarGuard::set("OCI_SUBNET_ID", "ocid1.subnet.oc1.iad..dddd");
    let _image = EnvVarGuard::set("OCI_IMAGE_ID", "ocid1.image.oc1.iad..eeee");
    let _region = EnvVarGuard::set("OCI_REGION", "us-ashburn-1");
    let _shape = EnvVarGuard::set("OCI_SHAPE", "VM.Standard.E4.Flex");
    let _poll_attempts = EnvVarGuard::set("OCI_CREATE_POLL_ATTEMPTS", "7");
    let _poll_interval = EnvVarGuard::set("OCI_CREATE_POLL_INTERVAL_MS", "1500");

    let config = OciProvisionerConfig::from_env().expect("config should parse");
    assert_eq!(config.tenancy_ocid, "ocid1.tenancy.oc1..aaaa");
    assert_eq!(config.user_ocid, "ocid1.user.oc1..bbbb");
    assert_eq!(config.key_fingerprint, "20:3b:97:13:55:1c:aa:66");
    assert_eq!(config.compartment_id, "ocid1.compartment.oc1..cccc");
    assert_eq!(config.availability_domain, "Uocm:US-ASHBURN-AD-1");
    assert_eq!(config.subnet_id, "ocid1.subnet.oc1.iad..dddd");
    assert_eq!(config.image_id, "ocid1.image.oc1.iad..eeee");
    assert_eq!(config.region, "us-ashburn-1");
    assert_eq!(config.shape, "VM.Standard.E4.Flex");
    assert_eq!(config.create_poll_attempts, 7);
    assert_eq!(config.create_poll_interval_ms, 1500);
}

#[test]
fn oci_config_defaults() {
    let _lock = oci_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let key_path = write_test_key_file();
    let _tenancy = EnvVarGuard::set("OCI_TENANCY_OCID", "ocid1.tenancy.oc1..aaaa");
    let _user = EnvVarGuard::set("OCI_USER_OCID", "ocid1.user.oc1..bbbb");
    let _fingerprint = EnvVarGuard::set("OCI_KEY_FINGERPRINT", "20:3b:97:13:55:1c:aa:66");
    let _private_key = EnvVarGuard::set(
        "OCI_PRIVATE_KEY_PATH",
        key_path.to_str().expect("path should be utf8"),
    );
    let _compartment = EnvVarGuard::set("OCI_COMPARTMENT_ID", "ocid1.compartment.oc1..cccc");
    let _availability_domain = EnvVarGuard::set("OCI_AVAILABILITY_DOMAIN", "Uocm:US-ASHBURN-AD-1");
    let _subnet = EnvVarGuard::set("OCI_SUBNET_ID", "ocid1.subnet.oc1.iad..dddd");
    let _image = EnvVarGuard::set("OCI_IMAGE_ID", "ocid1.image.oc1.iad..eeee");
    let _region = EnvVarGuard::unset("OCI_REGION");
    let _shape = EnvVarGuard::unset("OCI_SHAPE");
    let _poll_attempts = EnvVarGuard::unset("OCI_CREATE_POLL_ATTEMPTS");
    let _poll_interval = EnvVarGuard::unset("OCI_CREATE_POLL_INTERVAL_MS");

    let config = OciProvisionerConfig::from_env().expect("config should parse");
    assert_eq!(config.region, "us-ashburn-1");
    assert_eq!(config.shape, "VM.Standard.E4.Flex");
    assert_eq!(config.create_poll_attempts, 10);
    assert_eq!(config.create_poll_interval_ms, 2000);
}

#[test]
fn oci_config_requires_auth_and_instance_fields() {
    let _lock = oci_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let _tenancy = EnvVarGuard::unset("OCI_TENANCY_OCID");
    let _user = EnvVarGuard::unset("OCI_USER_OCID");
    let _fingerprint = EnvVarGuard::unset("OCI_KEY_FINGERPRINT");
    let _private_key = EnvVarGuard::unset("OCI_PRIVATE_KEY_PATH");
    let _compartment = EnvVarGuard::unset("OCI_COMPARTMENT_ID");
    let _availability_domain = EnvVarGuard::unset("OCI_AVAILABILITY_DOMAIN");
    let _subnet = EnvVarGuard::unset("OCI_SUBNET_ID");
    let _image = EnvVarGuard::unset("OCI_IMAGE_ID");

    let err = match OciProvisionerConfig::from_env() {
        Ok(_) => panic!("missing env should fail"),
        Err(err) => err,
    };
    assert!(
        err.contains("OCI_TENANCY_OCID")
            || err.contains("OCI_USER_OCID")
            || err.contains("OCI_KEY_FINGERPRINT")
            || err.contains("OCI_PRIVATE_KEY_PATH")
            || err.contains("OCI_COMPARTMENT_ID")
            || err.contains("OCI_AVAILABILITY_DOMAIN")
            || err.contains("OCI_SUBNET_ID")
            || err.contains("OCI_IMAGE_ID"),
        "unexpected error: {err}"
    );
}

#[test]
fn oci_status_mapping_complete() {
    assert_eq!(map_oci_status("PROVISIONING"), VmStatus::Pending);
    assert_eq!(map_oci_status("STARTING"), VmStatus::Pending);
    assert_eq!(map_oci_status("MOVING"), VmStatus::Pending);
    assert_eq!(map_oci_status("CREATING_IMAGE"), VmStatus::Pending);
    assert_eq!(map_oci_status("RUNNING"), VmStatus::Running);
    assert_eq!(map_oci_status("STOPPING"), VmStatus::Stopped);
    assert_eq!(map_oci_status("STOPPED"), VmStatus::Stopped);
    assert_eq!(map_oci_status("TERMINATING"), VmStatus::Terminated);
    assert_eq!(map_oci_status("TERMINATED"), VmStatus::Terminated);
    assert_eq!(map_oci_status("UNKNOWN_STATUS"), VmStatus::Unknown);
}
