use api::provisioner::ssh::{map_ssh_status, BareMetalServer, SshProvisionerConfig};
use api::provisioner::VmStatus;
use std::sync::{Mutex, OnceLock};

fn ssh_env_lock() -> &'static Mutex<()> {
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
fn ssh_config_from_env() {
    let _lock = ssh_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let servers_json = serde_json::json!([
        {
            "id": "bm-fsn1-01",
            "host": "bm-01.fsn1.example.com",
            "public_ip": "203.0.113.10",
            "private_ip": "10.0.0.10",
            "region": "eu-central-bm"
        },
        {
            "id": "bm-fsn1-02",
            "host": "bm-02.fsn1.example.com",
            "public_ip": "203.0.113.11",
            "private_ip": "10.0.0.11",
            "region": "eu-central-bm"
        }
    ]);

    let _key_path = EnvVarGuard::set("SSH_KEY_PATH", "/home/deploy/.ssh/id_ed25519");
    let _user = EnvVarGuard::set("SSH_USER", "deploy");
    let _port = EnvVarGuard::set("SSH_PORT", "2222");
    let _servers = EnvVarGuard::set("SSH_SERVERS", &servers_json.to_string());

    let config = SshProvisionerConfig::from_env().expect("config should parse");
    assert_eq!(config.ssh_key_path, "/home/deploy/.ssh/id_ed25519");
    assert_eq!(config.ssh_user, "deploy");
    assert_eq!(config.ssh_port, 2222);
    assert_eq!(config.servers.len(), 2);
    assert_eq!(config.servers[0].id, "bm-fsn1-01");
    assert_eq!(config.servers[0].host, "bm-01.fsn1.example.com");
    assert_eq!(config.servers[0].public_ip, "203.0.113.10");
    assert_eq!(config.servers[0].private_ip.as_deref(), Some("10.0.0.10"));
    assert_eq!(config.servers[0].region, "eu-central-bm");
    assert_eq!(config.servers[1].id, "bm-fsn1-02");
}

#[test]
fn ssh_config_defaults_from_env() {
    let _lock = ssh_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let servers_json = serde_json::json!([
        {
            "id": "bm-01",
            "host": "bm-01.example.com",
            "public_ip": "198.51.100.1",
            "region": "us-east-bm"
        }
    ]);

    let _key_path = EnvVarGuard::set("SSH_KEY_PATH", "/root/.ssh/id_rsa");
    let _user = EnvVarGuard::unset("SSH_USER");
    let _port = EnvVarGuard::unset("SSH_PORT");
    let _servers = EnvVarGuard::set("SSH_SERVERS", &servers_json.to_string());

    let config = SshProvisionerConfig::from_env().expect("config should parse");
    assert_eq!(config.ssh_user, "root");
    assert_eq!(config.ssh_port, 22);
    assert_eq!(config.servers.len(), 1);
    assert!(config.servers[0].private_ip.is_none());
}

#[test]
fn ssh_config_rejects_missing_key_path() {
    let _lock = ssh_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let _key_path = EnvVarGuard::unset("SSH_KEY_PATH");
    let _servers = EnvVarGuard::set("SSH_SERVERS", "[]");

    let err = SshProvisionerConfig::from_env().expect_err("missing key path should fail");
    assert!(
        err.contains("SSH_KEY_PATH"),
        "error should mention SSH_KEY_PATH, got: {err}"
    );
}

#[test]
fn ssh_config_rejects_empty_key_path() {
    let _lock = ssh_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let servers_json = serde_json::json!([{
        "id": "bm-01", "host": "bm.example.com",
        "public_ip": "198.51.100.1", "region": "us-east-bm"
    }]);

    let _key_path = EnvVarGuard::set("SSH_KEY_PATH", "  ");
    let _servers = EnvVarGuard::set("SSH_SERVERS", &servers_json.to_string());

    let err = SshProvisionerConfig::from_env().expect_err("empty key path should fail");
    assert!(
        err.contains("SSH_KEY_PATH"),
        "error should mention SSH_KEY_PATH, got: {err}"
    );
}

#[test]
fn ssh_config_rejects_missing_servers() {
    let _lock = ssh_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let _key_path = EnvVarGuard::set("SSH_KEY_PATH", "/root/.ssh/id_rsa");
    let _servers = EnvVarGuard::unset("SSH_SERVERS");

    let err = SshProvisionerConfig::from_env().expect_err("missing servers should fail");
    assert!(
        err.contains("SSH_SERVERS"),
        "error should mention SSH_SERVERS, got: {err}"
    );
}

#[test]
fn ssh_config_rejects_empty_servers() {
    let _lock = ssh_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let _key_path = EnvVarGuard::set("SSH_KEY_PATH", "/root/.ssh/id_rsa");
    let _servers = EnvVarGuard::set("SSH_SERVERS", "[]");

    let err = SshProvisionerConfig::from_env().expect_err("empty servers should fail");
    assert!(
        err.contains("at least one server"),
        "error should mention empty servers, got: {err}"
    );
}

#[test]
fn ssh_config_rejects_invalid_port() {
    let _lock = ssh_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let servers_json = serde_json::json!([{
        "id": "bm-01", "host": "bm.example.com",
        "public_ip": "198.51.100.1", "region": "us-east-bm"
    }]);

    let _key_path = EnvVarGuard::set("SSH_KEY_PATH", "/root/.ssh/id_rsa");
    let _port = EnvVarGuard::set("SSH_PORT", "not-a-number");
    let _servers = EnvVarGuard::set("SSH_SERVERS", &servers_json.to_string());

    let err = SshProvisionerConfig::from_env().expect_err("invalid port should fail");
    assert!(
        err.contains("SSH_PORT"),
        "error should mention SSH_PORT, got: {err}"
    );
}

#[test]
fn ssh_status_mapping_complete() {
    // "active" = flapjack service is running on the bare-metal box
    assert_eq!(map_ssh_status("active"), VmStatus::Running);
    // "inactive" = flapjack service is stopped
    assert_eq!(map_ssh_status("inactive"), VmStatus::Stopped);
    // "activating" = service is starting up
    assert_eq!(map_ssh_status("activating"), VmStatus::Pending);
    // "deactivating" = service is shutting down
    assert_eq!(map_ssh_status("deactivating"), VmStatus::Stopped);
    // "failed" = service crashed
    assert_eq!(map_ssh_status("failed"), VmStatus::Stopped);
    // Anything else
    assert_eq!(map_ssh_status("something-else"), VmStatus::Unknown);
}

#[test]
fn bare_metal_server_deserializes_correctly() {
    let json = r#"{"id":"bm-01","host":"bm.example.com","public_ip":"1.2.3.4","private_ip":"10.0.0.1","region":"us-east-bm"}"#;
    let server: BareMetalServer = serde_json::from_str(json).expect("should deserialize");
    assert_eq!(server.id, "bm-01");
    assert_eq!(server.host, "bm.example.com");
    assert_eq!(server.public_ip, "1.2.3.4");
    assert_eq!(server.private_ip.as_deref(), Some("10.0.0.1"));
    assert_eq!(server.region, "us-east-bm");
}

#[test]
fn bare_metal_server_private_ip_optional() {
    let json =
        r#"{"id":"bm-02","host":"bm2.example.com","public_ip":"5.6.7.8","region":"eu-west-bm"}"#;
    let server: BareMetalServer = serde_json::from_str(json).expect("should deserialize");
    assert_eq!(server.id, "bm-02");
    assert!(server.private_ip.is_none());
}
