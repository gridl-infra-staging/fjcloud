//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/provisioner/ssh.rs.
use async_trait::async_trait;
use base64::Engine;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use super::{CreateVmRequest, VmInstance, VmProvisioner, VmProvisionerError, VmStatus};

/// Maps a systemd service status string to our `VmStatus` enum.
///
/// Bare-metal "VM status" is determined by the flapjack systemd service
/// status on the server (retrieved via `systemctl is-active flapjack`).
pub fn map_ssh_status(status: &str) -> VmStatus {
    match status {
        "active" => VmStatus::Running,
        "inactive" | "deactivating" | "failed" => VmStatus::Stopped,
        "activating" => VmStatus::Pending,
        _ => VmStatus::Unknown,
    }
}

/// A pre-provisioned bare-metal server in the pool.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BareMetalServer {
    pub id: String,
    pub host: String,
    pub public_ip: String,
    #[serde(default)]
    pub private_ip: Option<String>,
    pub region: String,
}

/// Tracks allocation state of a bare-metal server.
#[derive(Debug, Clone, PartialEq, Eq)]
enum ServerAllocation {
    /// Server is available for new workloads.
    Available,
    /// Server is allocated to a provisioning request.
    Allocated,
}

/// Configuration for the SSH bare-metal provisioner.
#[derive(Debug, Clone)]
pub struct SshProvisionerConfig {
    pub ssh_key_path: String,
    pub ssh_user: String,
    pub ssh_port: u16,
    pub strict_host_key_checking: String,
    pub servers: Vec<BareMetalServer>,
}

const DEFAULT_SSH_STRICT_HOST_KEY_CHECKING: &str = "yes";

/// Validates the SSH strict host key checking value (yes/ask/accept-new/no/off, case-insensitive). Defaults to "yes" when absent.
fn parse_ssh_strict_host_key_checking(raw: Option<String>) -> Result<String, String> {
    let value = raw
        .map(|v| v.trim().to_ascii_lowercase())
        .unwrap_or_else(|| DEFAULT_SSH_STRICT_HOST_KEY_CHECKING.to_string());

    if value.is_empty() {
        return Err("SSH_STRICT_HOST_KEY_CHECKING is empty".to_string());
    }

    match value.as_str() {
        "yes" | "ask" | "accept-new" | "no" | "off" => Ok(value),
        _ => Err(format!(
            "SSH_STRICT_HOST_KEY_CHECKING must be one of: yes, ask, accept-new, no, off (got '{value}')"
        )),
    }
}

impl SshProvisionerConfig {
    /// Loads config from env vars. Requires `SSH_KEY_PATH` and `SSH_SERVERS` (JSON array of `BareMetalServer`). Defaults: user root, port 22.
    pub fn from_env() -> Result<Self, String> {
        let ssh_key_path =
            std::env::var("SSH_KEY_PATH").map_err(|_| "SSH_KEY_PATH not set".to_string())?;
        if ssh_key_path.trim().is_empty() {
            return Err("SSH_KEY_PATH is empty".to_string());
        }

        let ssh_user = std::env::var("SSH_USER").unwrap_or_else(|_| "root".to_string());

        let ssh_port = match std::env::var("SSH_PORT") {
            Ok(raw) => raw
                .trim()
                .parse::<u16>()
                .map_err(|_| format!("SSH_PORT must be a valid port number, got '{raw}'"))?,
            Err(_) => 22,
        };
        let strict_host_key_checking =
            parse_ssh_strict_host_key_checking(std::env::var("SSH_STRICT_HOST_KEY_CHECKING").ok())?;

        let servers_json =
            std::env::var("SSH_SERVERS").map_err(|_| "SSH_SERVERS not set".to_string())?;
        let servers: Vec<BareMetalServer> = serde_json::from_str(&servers_json)
            .map_err(|e| format!("SSH_SERVERS is not valid JSON: {e}"))?;
        if servers.is_empty() {
            return Err("SSH_SERVERS must contain at least one server".to_string());
        }

        Ok(Self {
            ssh_key_path,
            ssh_user,
            ssh_port,
            strict_host_key_checking,
            servers,
        })
    }
}

/// Trait abstracting SSH command execution for testability.
#[async_trait]
pub(crate) trait SshExecutor: Send + Sync {
    /// Execute a command on a remote host via SSH. Returns stdout on success.
    async fn execute(&self, host: &str, command: &str) -> Result<String, VmProvisionerError>;
}

/// Real SSH executor using `tokio::process::Command`.
struct ProcessSshExecutor {
    key_path: String,
    user: String,
    port: u16,
    strict_host_key_checking: String,
}

#[async_trait]
impl SshExecutor for ProcessSshExecutor {
    /// Spawns an SSH process with StrictHostKeyChecking, BatchMode=yes, ConnectTimeout=10, and a `--` separator before the destination for safety.
    async fn execute(&self, host: &str, command: &str) -> Result<String, VmProvisionerError> {
        let destination = format!("{}@{}", self.user, host);
        let ssh_port = self.port.to_string();
        let strict_host_key_checking =
            format!("StrictHostKeyChecking={}", self.strict_host_key_checking);

        let output = tokio::process::Command::new("ssh")
            .arg("-o")
            .arg(strict_host_key_checking)
            .arg("-o")
            .arg("BatchMode=yes")
            .arg("-o")
            .arg("ConnectTimeout=10")
            .arg("-i")
            .arg(&self.key_path)
            .arg("-p")
            .arg(ssh_port)
            .arg("--")
            .arg(destination)
            .arg(command)
            .output()
            .await
            .map_err(|e| VmProvisionerError::Api(format!("SSH command failed to execute: {e}")))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(VmProvisionerError::Api(format!(
                "SSH command failed on {host}: {stderr}"
            )));
        }

        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    }
}

/// Bare-metal VM provisioner that manages pre-provisioned servers via SSH.
///
/// Instead of creating/destroying cloud VMs, this provisioner allocates servers
/// from a pre-configured pool and manages flapjack services via SSH commands.
pub struct SshVmProvisioner {
    executor: Arc<dyn SshExecutor>,
    config: SshProvisionerConfig,
    /// Tracks which servers are allocated vs. available.
    allocations: Mutex<HashMap<String, ServerAllocation>>,
    /// Maps server IDs to their config for quick lookup.
    server_map: HashMap<String, BareMetalServer>,
}

impl SshVmProvisioner {
    pub fn new(config: SshProvisionerConfig) -> Self {
        let executor = Arc::new(ProcessSshExecutor {
            key_path: config.ssh_key_path.clone(),
            user: config.ssh_user.clone(),
            port: config.ssh_port,
            strict_host_key_checking: config.strict_host_key_checking.clone(),
        });
        Self::with_executor(config, executor)
    }

    fn with_executor(config: SshProvisionerConfig, executor: Arc<dyn SshExecutor>) -> Self {
        let mut allocations = HashMap::new();
        let mut server_map = HashMap::new();
        for server in &config.servers {
            allocations.insert(server.id.clone(), ServerAllocation::Available);
            server_map.insert(server.id.clone(), server.clone());
        }
        Self {
            executor,
            config,
            allocations: Mutex::new(allocations),
            server_map,
        }
    }

    #[cfg(test)]
    fn with_executor_for_tests(
        config: SshProvisionerConfig,
        executor: Arc<dyn SshExecutor>,
    ) -> Self {
        Self::with_executor(config, executor)
    }

    /// Find an available server in the requested region and allocate it.
    fn allocate_server(&self, region: &str) -> Result<BareMetalServer, VmProvisionerError> {
        let mut allocs = self.allocations.lock().expect("allocations lock poisoned");
        for server in &self.config.servers {
            if server.region == region {
                if let Some(state) = allocs.get(&server.id) {
                    if *state == ServerAllocation::Available {
                        allocs.insert(server.id.clone(), ServerAllocation::Allocated);
                        return Ok(server.clone());
                    }
                }
            }
        }
        Err(VmProvisionerError::Api(format!(
            "no available bare-metal servers in region '{region}'"
        )))
    }

    /// Release a server back to the available pool.
    fn release_server(&self, server_id: &str) {
        let mut allocs = self.allocations.lock().expect("allocations lock poisoned");
        allocs.insert(server_id.to_string(), ServerAllocation::Available);
    }

    fn get_server(&self, server_id: &str) -> Result<&BareMetalServer, VmProvisionerError> {
        self.server_map
            .get(server_id)
            .ok_or_else(|| VmProvisionerError::VmNotFound(server_id.to_string()))
    }
}

#[async_trait]
impl VmProvisioner for SshVmProvisioner {
    /// Allocates a server from the pool in the requested region, base64-encodes user_data for safe SSH transfer, and releases the server on setup failure.
    async fn create_vm(&self, req: &CreateVmRequest) -> Result<VmInstance, VmProvisionerError> {
        let server = self.allocate_server(&req.region)?;

        // Run the setup script on the bare-metal server via SSH.
        // If user_data is provided (cloud-init script), execute it remotely.
        // We base64-encode the script to prevent heredoc delimiter injection
        // (user_data containing "FJEOF" could break out of a heredoc).
        if let Some(ref user_data) = req.user_data {
            let encoded = base64::engine::general_purpose::STANDARD.encode(user_data.as_bytes());
            let setup_cmd = format!(
                "echo '{encoded}' | base64 -d > /tmp/fjcloud-setup.sh && chmod +x /tmp/fjcloud-setup.sh && /tmp/fjcloud-setup.sh"
            );
            if let Err(e) = self.executor.execute(&server.host, &setup_cmd).await {
                // Setup failed — release the server back to the pool
                self.release_server(&server.id);
                return Err(VmProvisionerError::Api(format!(
                    "failed to run setup on {}: {e}",
                    server.id
                )));
            }
        }

        Ok(VmInstance {
            provider_vm_id: server.id.clone(),
            public_ip: Some(server.public_ip.clone()),
            private_ip: server.private_ip.clone(),
            status: VmStatus::Pending,
            region: req.region.clone(),
        })
    }

    async fn destroy_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        let server = self.get_server(provider_vm_id)?;

        // Stop services and clean up flapjack data
        let cleanup_cmd = "systemctl stop flapjack fj-metering-agent 2>/dev/null; rm -rf /var/lib/flapjack/data /etc/flapjack/env /etc/flapjack/metering-env /tmp/fjcloud-setup.sh 2>/dev/null; true";
        self.executor.execute(&server.host, cleanup_cmd).await?;

        // Return server to pool
        self.release_server(provider_vm_id);
        Ok(())
    }

    async fn stop_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        let server = self.get_server(provider_vm_id)?;
        self.executor
            .execute(&server.host, "systemctl stop flapjack fj-metering-agent")
            .await?;
        Ok(())
    }

    async fn start_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        let server = self.get_server(provider_vm_id)?;
        self.executor
            .execute(&server.host, "systemctl start flapjack fj-metering-agent")
            .await?;
        Ok(())
    }

    async fn get_vm_status(&self, provider_vm_id: &str) -> Result<VmStatus, VmProvisionerError> {
        let server = self.get_server(provider_vm_id)?;
        // `systemctl is-active` returns "active", "inactive", "failed", etc.
        // It returns exit code 3 for inactive/failed, so we need to handle that.
        let result = self
            .executor
            .execute(
                &server.host,
                "systemctl is-active flapjack 2>/dev/null || echo inactive",
            )
            .await?;
        Ok(map_ssh_status(result.trim()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use uuid::Uuid;

    struct MockSshExecutor {
        calls: Mutex<Vec<(String, String)>>,
        responses: Mutex<VecDeque<Result<String, VmProvisionerError>>>,
    }

    impl MockSshExecutor {
        fn new(responses: Vec<Result<String, VmProvisionerError>>) -> Self {
            Self {
                calls: Mutex::new(Vec::new()),
                responses: Mutex::new(VecDeque::from(responses)),
            }
        }

        fn calls(&self) -> Vec<(String, String)> {
            self.calls.lock().expect("calls lock poisoned").clone()
        }
    }

    #[async_trait]
    impl SshExecutor for MockSshExecutor {
        async fn execute(&self, host: &str, command: &str) -> Result<String, VmProvisionerError> {
            self.calls
                .lock()
                .expect("calls lock poisoned")
                .push((host.to_string(), command.to_string()));
            self.responses
                .lock()
                .expect("responses lock poisoned")
                .pop_front()
                .expect("missing mocked SSH response")
        }
    }

    /// Returns an `SshProvisionerConfig` with three test bare-metal servers across two regions.
    fn test_config() -> SshProvisionerConfig {
        SshProvisionerConfig {
            ssh_key_path: "/root/.ssh/id_ed25519".to_string(),
            ssh_user: "root".to_string(),
            ssh_port: 22,
            strict_host_key_checking: DEFAULT_SSH_STRICT_HOST_KEY_CHECKING.to_string(),
            servers: vec![
                BareMetalServer {
                    id: "bm-01".to_string(),
                    host: "bm-01.example.com".to_string(),
                    public_ip: "203.0.113.10".to_string(),
                    private_ip: Some("10.0.0.10".to_string()),
                    region: "eu-central-bm".to_string(),
                },
                BareMetalServer {
                    id: "bm-02".to_string(),
                    host: "bm-02.example.com".to_string(),
                    public_ip: "203.0.113.11".to_string(),
                    private_ip: None,
                    region: "eu-central-bm".to_string(),
                },
                BareMetalServer {
                    id: "bm-us-01".to_string(),
                    host: "bm-us-01.example.com".to_string(),
                    public_ip: "198.51.100.1".to_string(),
                    private_ip: None,
                    region: "us-east-bm".to_string(),
                },
            ],
        }
    }

    fn test_create_request(region: &str) -> CreateVmRequest {
        CreateVmRequest {
            region: region.to_string(),
            vm_type: "bare_metal".to_string(),
            hostname: "fj-test-node".to_string(),
            customer_id: Uuid::new_v4(),
            node_id: "node-001".to_string(),
            user_data: Some("#!/bin/bash\necho hello".to_string()),
        }
    }

    #[test]
    fn map_ssh_status_active_is_running() {
        assert_eq!(map_ssh_status("active"), VmStatus::Running);
    }

    #[test]
    fn map_ssh_status_inactive_is_stopped() {
        assert_eq!(map_ssh_status("inactive"), VmStatus::Stopped);
    }

    #[test]
    fn map_ssh_status_deactivating_is_stopped() {
        assert_eq!(map_ssh_status("deactivating"), VmStatus::Stopped);
    }

    #[test]
    fn map_ssh_status_failed_is_stopped() {
        assert_eq!(map_ssh_status("failed"), VmStatus::Stopped);
    }

    #[test]
    fn map_ssh_status_activating_is_pending() {
        assert_eq!(map_ssh_status("activating"), VmStatus::Pending);
    }

    #[test]
    fn map_ssh_status_unknown_input_returns_unknown() {
        assert_eq!(map_ssh_status("reloading"), VmStatus::Unknown);
        assert_eq!(map_ssh_status(""), VmStatus::Unknown);
        assert_eq!(map_ssh_status("maintenance"), VmStatus::Unknown);
    }

    #[test]
    fn strict_host_key_checking_defaults_to_yes() {
        let parsed =
            parse_ssh_strict_host_key_checking(None).expect("default should parse successfully");
        assert_eq!(parsed, DEFAULT_SSH_STRICT_HOST_KEY_CHECKING);
    }

    #[test]
    fn strict_host_key_checking_accepts_known_values_case_insensitively() {
        let parsed = parse_ssh_strict_host_key_checking(Some(" YES ".to_string()))
            .expect("YES should parse");
        assert_eq!(parsed, "yes");

        let parsed = parse_ssh_strict_host_key_checking(Some("Accept-New".to_string()))
            .expect("accept-new should parse");
        assert_eq!(parsed, "accept-new");
    }

    #[test]
    fn strict_host_key_checking_rejects_invalid_value() {
        let err = parse_ssh_strict_host_key_checking(Some("sometimes".to_string()))
            .expect_err("invalid value should fail");
        assert!(err.contains("SSH_STRICT_HOST_KEY_CHECKING must be one of"));
    }

    /// Verifies `create_vm` allocates the first available server, runs a base64-encoded setup script via SSH, and returns the correct `VmInstance`.
    #[tokio::test]
    async fn create_vm_allocates_server_and_runs_setup() {
        let mock = Arc::new(MockSshExecutor::new(vec![
            Ok("setup complete".to_string()), // setup script result
        ]));
        let provisioner = SshVmProvisioner::with_executor_for_tests(test_config(), mock.clone());

        let result = provisioner
            .create_vm(&test_create_request("eu-central-bm"))
            .await
            .expect("create_vm should succeed");

        assert_eq!(result.provider_vm_id, "bm-01");
        assert_eq!(result.public_ip.as_deref(), Some("203.0.113.10"));
        assert_eq!(result.private_ip.as_deref(), Some("10.0.0.10"));
        assert_eq!(result.status, VmStatus::Pending);
        assert_eq!(result.region, "eu-central-bm");

        let calls = mock.calls();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].0, "bm-01.example.com");
        assert!(
            calls[0].1.contains("base64 -d"),
            "setup script should be base64-encoded for safe transfer"
        );
        // Verify the base64 payload decodes to the original script
        let encoded =
            base64::engine::general_purpose::STANDARD.encode("#!/bin/bash\necho hello".as_bytes());
        assert!(
            calls[0].1.contains(&encoded),
            "base64 payload should contain encoded user_data"
        );
    }

    /// Verifies that a second `create_vm` in the same region allocates the next available server when the first is already in use.
    #[tokio::test]
    async fn create_vm_allocates_second_server_when_first_taken() {
        let mock = Arc::new(MockSshExecutor::new(vec![
            Ok("ok".to_string()), // first create
            Ok("ok".to_string()), // second create
        ]));
        let provisioner = SshVmProvisioner::with_executor_for_tests(test_config(), mock.clone());

        let first = provisioner
            .create_vm(&test_create_request("eu-central-bm"))
            .await
            .expect("first create should succeed");
        assert_eq!(first.provider_vm_id, "bm-01");

        let second = provisioner
            .create_vm(&test_create_request("eu-central-bm"))
            .await
            .expect("second create should succeed");
        assert_eq!(second.provider_vm_id, "bm-02");
    }

    /// Verifies that `create_vm` returns an error when all servers in the requested region are allocated.
    #[tokio::test]
    async fn create_vm_no_capacity_returns_error() {
        let mock = Arc::new(MockSshExecutor::new(vec![
            Ok("ok".to_string()), // allocate bm-us-01
        ]));
        let provisioner = SshVmProvisioner::with_executor_for_tests(test_config(), mock.clone());

        // Allocate the only US server
        provisioner
            .create_vm(&test_create_request("us-east-bm"))
            .await
            .expect("first US create should succeed");

        // Second US request should fail — no more servers in that region
        let err = provisioner
            .create_vm(&test_create_request("us-east-bm"))
            .await
            .expect_err("second US create should fail");
        match err {
            VmProvisionerError::Api(msg) => {
                assert!(
                    msg.contains("no available bare-metal servers"),
                    "expected capacity error, got: {msg}"
                );
            }
            other => panic!("expected Api error, got: {other:?}"),
        }
    }

    /// Verifies that a failed setup script releases the server back to the pool so a retry can succeed.
    #[tokio::test]
    async fn create_vm_setup_failure_releases_server() {
        let mock = Arc::new(MockSshExecutor::new(vec![
            Err(VmProvisionerError::Api(
                "SSH connection refused".to_string(),
            )), // setup fails
            Ok("ok".to_string()), // retry succeeds after release
        ]));
        let provisioner = SshVmProvisioner::with_executor_for_tests(test_config(), mock.clone());

        // First attempt fails
        let err = provisioner
            .create_vm(&test_create_request("us-east-bm"))
            .await
            .expect_err("setup failure should propagate");
        assert!(matches!(err, VmProvisionerError::Api(_)));

        // Server should be released — second attempt should succeed
        let result = provisioner
            .create_vm(&test_create_request("us-east-bm"))
            .await
            .expect("retry should succeed after release");
        assert_eq!(result.provider_vm_id, "bm-us-01");
    }

    /// Verifies `destroy_vm` runs cleanup commands (systemctl stop, rm data) and releases the server for reuse.
    #[tokio::test]
    async fn destroy_vm_cleans_up_and_releases() {
        let mock = Arc::new(MockSshExecutor::new(vec![
            Ok("ok".to_string()),         // create setup
            Ok("cleanup ok".to_string()), // destroy cleanup
            Ok("ok".to_string()),         // re-create setup (proving server was released)
        ]));
        let provisioner = SshVmProvisioner::with_executor_for_tests(test_config(), mock.clone());

        // Create then destroy
        let instance = provisioner
            .create_vm(&test_create_request("us-east-bm"))
            .await
            .unwrap();
        provisioner
            .destroy_vm(&instance.provider_vm_id)
            .await
            .expect("destroy should succeed");

        // Verify cleanup command was executed
        let calls = mock.calls();
        assert_eq!(calls.len(), 2);
        assert!(
            calls[1].1.contains("systemctl stop"),
            "should stop services"
        );
        assert!(calls[1].1.contains("rm -rf"), "should clean up data");

        // Server should be available again
        let reused = provisioner
            .create_vm(&test_create_request("us-east-bm"))
            .await
            .expect("server should be available after destroy");
        assert_eq!(reused.provider_vm_id, "bm-us-01");
    }

    /// Verifies `stop_vm` executes `systemctl stop flapjack fj-metering-agent` on the correct host.
    #[tokio::test]
    async fn stop_vm_runs_systemctl_stop() {
        let mock = Arc::new(MockSshExecutor::new(vec![
            Ok("".to_string()), // stop result
        ]));
        let provisioner = SshVmProvisioner::with_executor_for_tests(test_config(), mock.clone());

        provisioner
            .stop_vm("bm-01")
            .await
            .expect("stop should succeed");

        let calls = mock.calls();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].0, "bm-01.example.com");
        assert!(calls[0].1.contains("systemctl stop flapjack"));
    }

    /// Verifies `start_vm` executes `systemctl start flapjack fj-metering-agent` on the correct host.
    #[tokio::test]
    async fn start_vm_runs_systemctl_start() {
        let mock = Arc::new(MockSshExecutor::new(vec![
            Ok("".to_string()), // start result
        ]));
        let provisioner = SshVmProvisioner::with_executor_for_tests(test_config(), mock.clone());

        provisioner
            .start_vm("bm-01")
            .await
            .expect("start should succeed");

        let calls = mock.calls();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].0, "bm-01.example.com");
        assert!(calls[0].1.contains("systemctl start flapjack"));
    }

    #[tokio::test]
    async fn get_vm_status_returns_correct_status() {
        let mock = Arc::new(MockSshExecutor::new(vec![Ok("active".to_string())]));
        let provisioner = SshVmProvisioner::with_executor_for_tests(test_config(), mock.clone());

        let status = provisioner
            .get_vm_status("bm-01")
            .await
            .expect("status should succeed");
        assert_eq!(status, VmStatus::Running);
    }

    #[tokio::test]
    async fn get_vm_status_inactive_returns_stopped() {
        let mock = Arc::new(MockSshExecutor::new(vec![Ok("inactive".to_string())]));
        let provisioner = SshVmProvisioner::with_executor_for_tests(test_config(), mock.clone());

        let status = provisioner
            .get_vm_status("bm-02")
            .await
            .expect("status should succeed");
        assert_eq!(status, VmStatus::Stopped);
    }

    /// Verifies that operations on an unknown server ID return `VmNotFound` for stop, start, get_status, and destroy.
    #[tokio::test]
    async fn unknown_server_id_returns_not_found() {
        let mock = Arc::new(MockSshExecutor::new(vec![]));
        let provisioner = SshVmProvisioner::with_executor_for_tests(test_config(), mock);

        let err = provisioner
            .stop_vm("nonexistent")
            .await
            .expect_err("unknown server should fail");
        assert!(matches!(err, VmProvisionerError::VmNotFound(_)));

        // Test for other operations too
        let provisioner2 = SshVmProvisioner::with_executor_for_tests(
            test_config(),
            Arc::new(MockSshExecutor::new(vec![])),
        );
        assert!(provisioner2.start_vm("nonexistent").await.is_err());
        assert!(provisioner2.get_vm_status("nonexistent").await.is_err());
        assert!(provisioner2.destroy_vm("nonexistent").await.is_err());
    }

    #[tokio::test]
    async fn create_vm_without_user_data_skips_setup() {
        let mock = Arc::new(MockSshExecutor::new(vec![])); // no SSH calls expected
        let provisioner = SshVmProvisioner::with_executor_for_tests(test_config(), mock.clone());

        let mut req = test_create_request("eu-central-bm");
        req.user_data = None;

        let result = provisioner.create_vm(&req).await.expect("should succeed");
        assert_eq!(result.provider_vm_id, "bm-01");
        assert!(
            mock.calls().is_empty(),
            "no SSH calls when user_data is None"
        );
    }

    #[tokio::test]
    async fn create_vm_wrong_region_returns_error() {
        let mock = Arc::new(MockSshExecutor::new(vec![]));
        let provisioner = SshVmProvisioner::with_executor_for_tests(test_config(), mock);

        let err = provisioner
            .create_vm(&test_create_request("ap-southeast-1"))
            .await
            .expect_err("unknown region should fail");
        match err {
            VmProvisionerError::Api(msg) => {
                assert!(msg.contains("no available bare-metal servers"));
            }
            other => panic!("expected Api error, got: {other:?}"),
        }
    }
}
