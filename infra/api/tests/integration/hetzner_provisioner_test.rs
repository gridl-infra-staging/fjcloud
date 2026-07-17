use api::provisioner::hetzner::{map_hetzner_status, HetznerProvisionerConfig};
use api::provisioner::VmStatus;
use std::sync::{Mutex, OnceLock};

fn hetzner_env_lock() -> &'static Mutex<()> {
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
fn hetzner_config_from_env() {
    let _lock = hetzner_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _token = EnvVarGuard::set("HETZNER_API_TOKEN", "tok-from-env");
    let _server_type = EnvVarGuard::set("HETZNER_SERVER_TYPE", "ccx23");
    let _image = EnvVarGuard::set("HETZNER_IMAGE", "ubuntu-24.04");
    let _ssh_key = EnvVarGuard::set("HETZNER_SSH_KEY_NAME", "ssh-main");
    let _firewall = EnvVarGuard::set("HETZNER_FIREWALL_ID", "12345");
    let _network = EnvVarGuard::set("HETZNER_NETWORK_ID", "777");
    let _location = EnvVarGuard::set("HETZNER_LOCATION", "hel1");

    let config = HetznerProvisionerConfig::from_env().expect("config should parse");
    assert_eq!(config.api_token, "tok-from-env");
    assert_eq!(config.server_type, "ccx23");
    assert_eq!(config.image, "ubuntu-24.04");
    assert_eq!(config.ssh_key_name.as_deref(), Some("ssh-main"));
    assert_eq!(config.firewall_id.as_deref(), Some("12345"));
    assert_eq!(config.network_id.as_deref(), Some("777"));
    assert_eq!(config.location, "hel1");
}

#[test]
fn hetzner_config_from_env_rejects_invalid_numeric_ids() {
    let _lock = hetzner_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _token = EnvVarGuard::set("HETZNER_API_TOKEN", "tok");
    let _firewall = EnvVarGuard::set("HETZNER_FIREWALL_ID", "fw-not-a-number");
    let _network = EnvVarGuard::unset("HETZNER_NETWORK_ID");

    let err = HetznerProvisionerConfig::from_env().expect_err("invalid ID should fail");
    assert!(
        err.contains("HETZNER_FIREWALL_ID"),
        "error should mention invalid env var, got: {err}"
    );
}

#[test]
fn hetzner_config_defaults_from_env() {
    let _lock = hetzner_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _token = EnvVarGuard::set("HETZNER_API_TOKEN", "tok-min");
    let _server_type = EnvVarGuard::unset("HETZNER_SERVER_TYPE");
    let _image = EnvVarGuard::unset("HETZNER_IMAGE");
    let _ssh_key = EnvVarGuard::unset("HETZNER_SSH_KEY_NAME");
    let _firewall = EnvVarGuard::unset("HETZNER_FIREWALL_ID");
    let _network = EnvVarGuard::unset("HETZNER_NETWORK_ID");
    let _location = EnvVarGuard::unset("HETZNER_LOCATION");

    let config = HetznerProvisionerConfig::from_env().expect("config should parse");
    assert_eq!(config.server_type, "cpx32");
    assert_eq!(config.image, "ubuntu-22.04");
    assert_eq!(config.location, "fsn1");
    assert!(config.ssh_key_name.is_none());
    assert!(config.firewall_id.is_none());
    assert!(config.network_id.is_none());
}

// --- Tests locking shared-helper behavior for token + defaultable fields ---

#[test]
fn hetzner_from_env_trims_token_whitespace() {
    let _lock = hetzner_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _token = EnvVarGuard::set("HETZNER_API_TOKEN", "  tok-padded  ");
    let _server_type = EnvVarGuard::unset("HETZNER_SERVER_TYPE");
    let _image = EnvVarGuard::unset("HETZNER_IMAGE");
    let _ssh_key = EnvVarGuard::unset("HETZNER_SSH_KEY_NAME");
    let _firewall = EnvVarGuard::unset("HETZNER_FIREWALL_ID");
    let _network = EnvVarGuard::unset("HETZNER_NETWORK_ID");
    let _location = EnvVarGuard::unset("HETZNER_LOCATION");

    let config = HetznerProvisionerConfig::from_env().expect("should parse");
    assert_eq!(config.api_token, "tok-padded");
}

#[test]
fn hetzner_from_env_rejects_empty_token() {
    let _lock = hetzner_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _token = EnvVarGuard::set("HETZNER_API_TOKEN", "   ");
    let _server_type = EnvVarGuard::unset("HETZNER_SERVER_TYPE");
    let _image = EnvVarGuard::unset("HETZNER_IMAGE");
    let _ssh_key = EnvVarGuard::unset("HETZNER_SSH_KEY_NAME");
    let _firewall = EnvVarGuard::unset("HETZNER_FIREWALL_ID");
    let _network = EnvVarGuard::unset("HETZNER_NETWORK_ID");
    let _location = EnvVarGuard::unset("HETZNER_LOCATION");

    let err = HetznerProvisionerConfig::from_env().expect_err("empty token should fail");
    assert!(
        err.contains("HETZNER_API_TOKEN"),
        "error should mention the var, got: {err}"
    );
}

#[test]
fn hetzner_from_env_defaultable_fields_trim_and_reject_empty() {
    let _lock = hetzner_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _token = EnvVarGuard::set("HETZNER_API_TOKEN", "tok");
    // Set defaultable fields to whitespace-only — should fall back to defaults
    let _server_type = EnvVarGuard::set("HETZNER_SERVER_TYPE", "  ");
    let _image = EnvVarGuard::set("HETZNER_IMAGE", "  ");
    let _location = EnvVarGuard::set("HETZNER_LOCATION", "  ");
    let _ssh_key = EnvVarGuard::unset("HETZNER_SSH_KEY_NAME");
    let _firewall = EnvVarGuard::unset("HETZNER_FIREWALL_ID");
    let _network = EnvVarGuard::unset("HETZNER_NETWORK_ID");

    let config = HetznerProvisionerConfig::from_env().expect("should parse with defaults");
    assert_eq!(
        config.server_type, "cpx32",
        "empty server_type should default"
    );
    assert_eq!(config.image, "ubuntu-22.04", "empty image should default");
    assert_eq!(config.location, "fsn1", "empty location should default");
}

#[test]
fn hetzner_from_env_defaultable_fields_trimmed_when_set() {
    let _lock = hetzner_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _token = EnvVarGuard::set("HETZNER_API_TOKEN", "tok");
    let _server_type = EnvVarGuard::set("HETZNER_SERVER_TYPE", " ccx23 ");
    let _image = EnvVarGuard::set("HETZNER_IMAGE", " ubuntu-24.04 ");
    let _location = EnvVarGuard::set("HETZNER_LOCATION", " hel1 ");
    let _ssh_key = EnvVarGuard::unset("HETZNER_SSH_KEY_NAME");
    let _firewall = EnvVarGuard::unset("HETZNER_FIREWALL_ID");
    let _network = EnvVarGuard::unset("HETZNER_NETWORK_ID");

    let config = HetznerProvisionerConfig::from_env().expect("should parse");
    assert_eq!(config.server_type, "ccx23");
    assert_eq!(config.image, "ubuntu-24.04");
    assert_eq!(config.location, "hel1");
}

#[test]
fn hetzner_status_mapping_complete() {
    assert_eq!(map_hetzner_status("initializing"), VmStatus::Pending);
    assert_eq!(map_hetzner_status("starting"), VmStatus::Pending);
    assert_eq!(map_hetzner_status("running"), VmStatus::Running);
    assert_eq!(map_hetzner_status("stopping"), VmStatus::Stopped);
    assert_eq!(map_hetzner_status("off"), VmStatus::Stopped);
    assert_eq!(map_hetzner_status("deleting"), VmStatus::Terminated);
    assert_eq!(map_hetzner_status("migrating"), VmStatus::Pending);
    assert_eq!(map_hetzner_status("rebuilding"), VmStatus::Pending);
    assert_eq!(map_hetzner_status("unknown"), VmStatus::Unknown);
    assert_eq!(map_hetzner_status("something-else"), VmStatus::Unknown);
}
