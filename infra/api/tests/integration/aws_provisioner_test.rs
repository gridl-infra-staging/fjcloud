use api::provisioner::aws::{map_ec2_state, AwsProvisionerConfig};
use api::provisioner::VmStatus;
use std::sync::{Mutex, OnceLock};

fn aws_env_lock() -> &'static Mutex<()> {
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
fn ec2_state_to_vm_status_mapping() {
    assert_eq!(map_ec2_state("pending"), VmStatus::Pending);
    assert_eq!(map_ec2_state("running"), VmStatus::Running);
    assert_eq!(map_ec2_state("stopping"), VmStatus::Stopped);
    assert_eq!(map_ec2_state("stopped"), VmStatus::Stopped);
    assert_eq!(map_ec2_state("shutting-down"), VmStatus::Terminated);
    assert_eq!(map_ec2_state("terminated"), VmStatus::Terminated);
    assert_eq!(map_ec2_state("something-else"), VmStatus::Unknown);
}

#[test]
fn aws_config_parses_from_values() {
    let config = AwsProvisionerConfig::new(
        "ami-0123456789abcdef0".to_string(),
        vec!["sg-abc123".to_string(), "sg-def456".to_string()],
        "subnet-abc123".to_string(),
        "fj-keypair".to_string(),
        Some("fjcloud-instance-profile".to_string()),
    );

    assert_eq!(config.ami_id, "ami-0123456789abcdef0");
    assert_eq!(config.security_group_ids.len(), 2);
    assert_eq!(config.subnet_id, "subnet-abc123");
    assert_eq!(config.key_pair_name, "fj-keypair");
    assert_eq!(
        config.instance_profile_name.as_deref(),
        Some("fjcloud-instance-profile")
    );
}

#[test]
fn aws_config_instance_profile_optional() {
    let config = AwsProvisionerConfig::new(
        "ami-0123456789abcdef0".to_string(),
        vec!["sg-abc123".to_string()],
        "subnet-abc123".to_string(),
        "fj-keypair".to_string(),
        None,
    );

    assert!(config.instance_profile_name.is_none());
}

// --- from_env tests (TDD: these lock the shared-helper behavior) ---

#[test]
fn aws_from_env_happy_path() {
    let _lock = aws_env_lock().lock().unwrap_or_else(|p| p.into_inner());
    let _ami = EnvVarGuard::set("AWS_AMI_ID", "ami-abc123");
    let _sg = EnvVarGuard::set("AWS_SECURITY_GROUP_IDS", "sg-1,sg-2,sg-3");
    let _subnet = EnvVarGuard::set("AWS_SUBNET_ID", "subnet-xyz");
    let _key = EnvVarGuard::set("AWS_KEY_PAIR_NAME", "my-keypair");
    let _profile = EnvVarGuard::set("AWS_INSTANCE_PROFILE_NAME", "my-profile");

    let config = AwsProvisionerConfig::from_env().expect("should parse");
    assert_eq!(config.ami_id, "ami-abc123");
    assert_eq!(config.security_group_ids, vec!["sg-1", "sg-2", "sg-3"]);
    assert_eq!(config.subnet_id, "subnet-xyz");
    assert_eq!(config.key_pair_name, "my-keypair");
    assert_eq!(config.instance_profile_name.as_deref(), Some("my-profile"));
}

#[test]
fn aws_from_env_trims_required_values() {
    let _lock = aws_env_lock().lock().unwrap_or_else(|p| p.into_inner());
    let _ami = EnvVarGuard::set("AWS_AMI_ID", "  ami-trimmed  ");
    let _sg = EnvVarGuard::set("AWS_SECURITY_GROUP_IDS", " sg-a , sg-b ");
    let _subnet = EnvVarGuard::set("AWS_SUBNET_ID", "\tsubnet-trimmed\t");
    let _key = EnvVarGuard::set("AWS_KEY_PAIR_NAME", "  keypair-trimmed  ");
    let _profile = EnvVarGuard::unset("AWS_INSTANCE_PROFILE_NAME");

    let config = AwsProvisionerConfig::from_env().expect("should parse");
    assert_eq!(config.ami_id, "ami-trimmed");
    assert_eq!(config.subnet_id, "subnet-trimmed");
    assert_eq!(config.key_pair_name, "keypair-trimmed");
    // Security groups are already trimmed per-element by the split logic
    assert_eq!(config.security_group_ids, vec!["sg-a", "sg-b"]);
}

#[test]
fn aws_from_env_rejects_empty_required_vars() {
    let _lock = aws_env_lock().lock().unwrap_or_else(|p| p.into_inner());
    // Set AMI to empty — should be rejected
    let _ami = EnvVarGuard::set("AWS_AMI_ID", "   ");
    let _sg = EnvVarGuard::set("AWS_SECURITY_GROUP_IDS", "sg-1");
    let _subnet = EnvVarGuard::set("AWS_SUBNET_ID", "subnet-1");
    let _key = EnvVarGuard::set("AWS_KEY_PAIR_NAME", "keypair");
    let _profile = EnvVarGuard::unset("AWS_INSTANCE_PROFILE_NAME");

    let err = AwsProvisionerConfig::from_env().expect_err("empty AMI should fail");
    assert!(
        err.contains("AWS_AMI_ID"),
        "error should mention the var, got: {err}"
    );
}

#[test]
fn aws_from_env_security_groups_split_cleanly() {
    let _lock = aws_env_lock().lock().unwrap_or_else(|p| p.into_inner());
    let _ami = EnvVarGuard::set("AWS_AMI_ID", "ami-1");
    let _sg = EnvVarGuard::set("AWS_SECURITY_GROUP_IDS", "sg-a,,sg-b, ,sg-c");
    let _subnet = EnvVarGuard::set("AWS_SUBNET_ID", "subnet-1");
    let _key = EnvVarGuard::set("AWS_KEY_PAIR_NAME", "keypair");
    let _profile = EnvVarGuard::unset("AWS_INSTANCE_PROFILE_NAME");

    let config = AwsProvisionerConfig::from_env().expect("should parse");
    // Empty segments from ",," and ", " are filtered out
    assert_eq!(config.security_group_ids, vec!["sg-a", "sg-b", "sg-c"]);
}

#[test]
fn aws_from_env_empty_instance_profile_returns_none() {
    let _lock = aws_env_lock().lock().unwrap_or_else(|p| p.into_inner());
    let _ami = EnvVarGuard::set("AWS_AMI_ID", "ami-1");
    let _sg = EnvVarGuard::set("AWS_SECURITY_GROUP_IDS", "sg-1");
    let _subnet = EnvVarGuard::set("AWS_SUBNET_ID", "subnet-1");
    let _key = EnvVarGuard::set("AWS_KEY_PAIR_NAME", "keypair");
    let _profile = EnvVarGuard::set("AWS_INSTANCE_PROFILE_NAME", "");

    let config = AwsProvisionerConfig::from_env().expect("should parse");
    // After migration to optional_env: empty string → None (not Some(""))
    assert!(
        config.instance_profile_name.is_none(),
        "empty profile should be None, got: {:?}",
        config.instance_profile_name
    );
}

#[test]
fn aws_from_env_unset_instance_profile_returns_none() {
    let _lock = aws_env_lock().lock().unwrap_or_else(|p| p.into_inner());
    let _ami = EnvVarGuard::set("AWS_AMI_ID", "ami-1");
    let _sg = EnvVarGuard::set("AWS_SECURITY_GROUP_IDS", "sg-1");
    let _subnet = EnvVarGuard::set("AWS_SUBNET_ID", "subnet-1");
    let _key = EnvVarGuard::set("AWS_KEY_PAIR_NAME", "keypair");
    let _profile = EnvVarGuard::unset("AWS_INSTANCE_PROFILE_NAME");

    let config = AwsProvisionerConfig::from_env().expect("should parse");
    assert!(config.instance_profile_name.is_none());
}
