use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use super::env_config::{optional_env, required_env};
use super::{CreateVmRequest, VmInstance, VmProvisioner, VmProvisionerError, VmStatus};

const DEFAULT_HETZNER_SERVER_TYPE: &str = "cpx32";
const DEFAULT_HETZNER_IMAGE: &str = "ubuntu-22.04";
const DEFAULT_HETZNER_LOCATION: &str = "fsn1";
const DEFAULT_HETZNER_API_BASE_URL: &str = "https://api.hetzner.cloud";

/// Maps a Hetzner server status string to our `VmStatus` enum.
pub fn map_hetzner_status(status: &str) -> VmStatus {
    match status {
        "initializing" | "starting" | "migrating" | "rebuilding" => VmStatus::Pending,
        "running" => VmStatus::Running,
        "stopping" | "off" => VmStatus::Stopped,
        "deleting" => VmStatus::Terminated,
        _ => VmStatus::Unknown,
    }
}

fn validate_optional_numeric_id(key: &str, value: Option<&str>) -> Result<(), String> {
    if let Some(raw) = value {
        raw.parse::<i64>()
            .map_err(|_| format!("{key} must be a numeric ID, got '{raw}'"))?;
    }
    Ok(())
}

fn optional_env_or_default(key: &str, default: &str) -> String {
    optional_env(key).unwrap_or_else(|| default.to_string())
}

/// Configuration for the Hetzner Cloud provisioner.
#[derive(Debug, Clone)]
pub struct HetznerProvisionerConfig {
    pub api_token: String,
    pub server_type: String,
    pub image: String,
    pub ssh_key_name: Option<String>,
    pub firewall_id: Option<String>,
    pub network_id: Option<String>,
    pub location: String,
    pub api_base_url: String,
}

impl HetznerProvisionerConfig {
    pub fn from_env() -> Result<Self, String> {
        let api_token = required_env("HETZNER_API_TOKEN")?;

        let ssh_key_name = optional_env("HETZNER_SSH_KEY_NAME");
        let firewall_id = optional_env("HETZNER_FIREWALL_ID");
        let network_id = optional_env("HETZNER_NETWORK_ID");
        validate_optional_numeric_id("HETZNER_FIREWALL_ID", firewall_id.as_deref())?;
        validate_optional_numeric_id("HETZNER_NETWORK_ID", network_id.as_deref())?;

        Ok(Self {
            api_token,
            server_type: optional_env_or_default(
                "HETZNER_SERVER_TYPE",
                DEFAULT_HETZNER_SERVER_TYPE,
            ),
            image: optional_env_or_default("HETZNER_IMAGE", DEFAULT_HETZNER_IMAGE),
            ssh_key_name,
            firewall_id,
            network_id,
            location: optional_env_or_default("HETZNER_LOCATION", DEFAULT_HETZNER_LOCATION),
            api_base_url: DEFAULT_HETZNER_API_BASE_URL.to_string(),
        })
    }
}

// --- Hetzner API types ---

#[derive(Debug, Clone, Serialize)]
struct CreateServerRequest {
    name: String,
    server_type: String,
    image: String,
    location: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    user_data: Option<String>,
    labels: std::collections::HashMap<String, String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    ssh_keys: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    firewalls: Vec<FirewallRef>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    networks: Vec<i64>,
}

#[derive(Debug, Clone, Serialize)]
struct FirewallRef {
    firewall: i64,
}

#[derive(Debug, Deserialize)]
struct CreateServerResponse {
    server: HetznerServer,
}

#[derive(Debug, Deserialize)]
struct GetServerResponse {
    server: HetznerServer,
}

#[derive(Debug, Clone, Deserialize)]
struct HetznerServer {
    id: i64,
    status: String,
    public_net: PublicNet,
    #[serde(default)]
    private_net: Vec<PrivateNet>,
}

#[derive(Debug, Clone, Deserialize)]
struct PublicNet {
    ipv4: Option<Ipv4Info>,
}

#[derive(Debug, Clone, Deserialize)]
struct Ipv4Info {
    ip: String,
}

#[derive(Debug, Clone, Deserialize)]
struct PrivateNet {
    ip: String,
}

#[derive(Debug, Deserialize)]
struct HetznerErrorResponse {
    error: HetznerErrorDetail,
}

#[derive(Debug, Deserialize)]
struct HetznerErrorDetail {
    code: String,
    message: String,
}

#[async_trait]
trait HetznerApi: Send + Sync {
    async fn create_server(
        &self,
        body: &CreateServerRequest,
    ) -> Result<HetznerServer, VmProvisionerError>;
    async fn delete_server(&self, id: &str) -> Result<(), VmProvisionerError>;
    async fn shutdown_server(&self, id: &str) -> Result<(), VmProvisionerError>;
    async fn poweron_server(&self, id: &str) -> Result<(), VmProvisionerError>;
    async fn get_server(&self, id: &str) -> Result<HetznerServer, VmProvisionerError>;
}

/// Thin Hetzner Cloud API client using `reqwest`.
struct ReqwestHetznerApiClient {
    http: reqwest::Client,
    base_url: String,
    token: String,
}

impl ReqwestHetznerApiClient {
    fn new(base_url: &str, token: &str) -> Self {
        Self {
            http: reqwest::Client::new(),
            base_url: base_url.to_string(),
            token: token.to_string(),
        }
    }
}

#[async_trait]
impl HetznerApi for ReqwestHetznerApiClient {
    /// POSTs to `/v1/servers` with bearer auth and returns the created `HetznerServer`.
    async fn create_server(
        &self,
        body: &CreateServerRequest,
    ) -> Result<HetznerServer, VmProvisionerError> {
        let resp = self
            .http
            .post(format!("{}/v1/servers", self.base_url))
            .bearer_auth(&self.token)
            .json(body)
            .send()
            .await
            .map_err(|e| {
                VmProvisionerError::Api(format!("Hetzner create_server request failed: {e}"))
            })?;

        if !resp.status().is_success() {
            return Err(parse_error_response(resp).await);
        }

        let parsed: CreateServerResponse = resp.json().await.map_err(|e| {
            VmProvisionerError::Api(format!("Hetzner create_server parse failed: {e}"))
        })?;

        Ok(parsed.server)
    }

    /// DELETEs `/v1/servers/{id}` with bearer auth.
    async fn delete_server(&self, id: &str) -> Result<(), VmProvisionerError> {
        let resp = self
            .http
            .delete(format!("{}/v1/servers/{}", self.base_url, id))
            .bearer_auth(&self.token)
            .send()
            .await
            .map_err(|e| {
                VmProvisionerError::Api(format!("Hetzner delete_server request failed: {e}"))
            })?;

        if !resp.status().is_success() {
            return Err(parse_error_response(resp).await);
        }
        Ok(())
    }

    /// POSTs to `/v1/servers/{id}/actions/shutdown` with bearer auth.
    async fn shutdown_server(&self, id: &str) -> Result<(), VmProvisionerError> {
        let resp = self
            .http
            .post(format!(
                "{}/v1/servers/{}/actions/shutdown",
                self.base_url, id
            ))
            .bearer_auth(&self.token)
            .send()
            .await
            .map_err(|e| {
                VmProvisionerError::Api(format!("Hetzner shutdown_server request failed: {e}"))
            })?;

        if !resp.status().is_success() {
            return Err(parse_error_response(resp).await);
        }
        Ok(())
    }

    /// POSTs to `/v1/servers/{id}/actions/poweron` with bearer auth.
    async fn poweron_server(&self, id: &str) -> Result<(), VmProvisionerError> {
        let resp = self
            .http
            .post(format!(
                "{}/v1/servers/{}/actions/poweron",
                self.base_url, id
            ))
            .bearer_auth(&self.token)
            .send()
            .await
            .map_err(|e| {
                VmProvisionerError::Api(format!("Hetzner poweron_server request failed: {e}"))
            })?;

        if !resp.status().is_success() {
            return Err(parse_error_response(resp).await);
        }
        Ok(())
    }

    /// GETs `/v1/servers/{id}` with bearer auth. Returns `VmNotFound` on 404.
    async fn get_server(&self, id: &str) -> Result<HetznerServer, VmProvisionerError> {
        let resp = self
            .http
            .get(format!("{}/v1/servers/{}", self.base_url, id))
            .bearer_auth(&self.token)
            .send()
            .await
            .map_err(|e| {
                VmProvisionerError::Api(format!("Hetzner get_server request failed: {e}"))
            })?;

        if resp.status().as_u16() == 404 {
            return Err(VmProvisionerError::VmNotFound(id.to_string()));
        }

        if !resp.status().is_success() {
            return Err(parse_error_response(resp).await);
        }

        let parsed: GetServerResponse = resp.json().await.map_err(|e| {
            VmProvisionerError::Api(format!("Hetzner get_server parse failed: {e}"))
        })?;

        Ok(parsed.server)
    }
}

async fn parse_error_response(resp: reqwest::Response) -> VmProvisionerError {
    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    map_hetzner_api_error(status, &body)
}

fn map_hetzner_api_error(status: reqwest::StatusCode, body: &str) -> VmProvisionerError {
    match serde_json::from_str::<HetznerErrorResponse>(body) {
        Ok(err) => VmProvisionerError::Api(format!(
            "Hetzner API error ({}): {} — {}",
            status, err.error.code, err.error.message
        )),
        Err(_) => VmProvisionerError::Api(format!("Hetzner API error: HTTP {status}")),
    }
}

/// Hetzner Cloud implementation of the `VmProvisioner` trait.
pub struct HetznerVmProvisioner {
    client: Arc<dyn HetznerApi>,
    config: HetznerProvisionerConfig,
}

impl HetznerVmProvisioner {
    pub fn new(config: HetznerProvisionerConfig) -> Self {
        let client = Arc::new(ReqwestHetznerApiClient::new(
            &config.api_base_url,
            &config.api_token,
        ));
        Self { client, config }
    }

    #[cfg(test)]
    fn with_client_for_tests(
        config: HetznerProvisionerConfig,
        client: Arc<dyn HetznerApi>,
    ) -> Self {
        Self { client, config }
    }
}

#[async_trait]
impl VmProvisioner for HetznerVmProvisioner {
    /// Creates a Hetzner server with labels (customer_id, node_id, managed-by), optional SSH keys/firewall/network, and returns a `VmInstance` with the Hetzner server ID.
    async fn create_vm(&self, req: &CreateVmRequest) -> Result<VmInstance, VmProvisionerError> {
        let mut labels = std::collections::HashMap::new();
        labels.insert("customer_id".to_string(), req.customer_id.to_string());
        labels.insert("node_id".to_string(), req.node_id.clone());
        labels.insert("managed-by".to_string(), "fjcloud".to_string());

        let mut ssh_keys = Vec::new();
        if let Some(ref key_name) = self.config.ssh_key_name {
            ssh_keys.push(key_name.clone());
        }

        let mut firewalls = Vec::new();
        if let Some(ref fw_id) = self.config.firewall_id {
            let id = fw_id.parse::<i64>().map_err(|_| {
                VmProvisionerError::Api(format!(
                    "invalid Hetzner firewall ID '{}': expected numeric ID",
                    fw_id
                ))
            })?;
            firewalls.push(FirewallRef { firewall: id });
        }

        let mut networks = Vec::new();
        if let Some(ref net_id) = self.config.network_id {
            let id = net_id.parse::<i64>().map_err(|_| {
                VmProvisionerError::Api(format!(
                    "invalid Hetzner network ID '{}': expected numeric ID",
                    net_id
                ))
            })?;
            networks.push(id);
        }

        let body = CreateServerRequest {
            name: req.hostname.clone(),
            server_type: self.config.server_type.clone(),
            image: self.config.image.clone(),
            location: self.config.location.clone(),
            user_data: req.user_data.clone(),
            labels,
            ssh_keys,
            firewalls,
            networks,
        };

        let server = self.client.create_server(&body).await?;

        let public_ip = server.public_net.ipv4.map(|v4| v4.ip);
        let private_ip = server.private_net.first().map(|pn| pn.ip.clone());

        Ok(VmInstance {
            provider_vm_id: server.id.to_string(),
            public_ip,
            private_ip,
            status: map_hetzner_status(&server.status),
            region: req.region.clone(),
        })
    }

    async fn destroy_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        self.client.delete_server(provider_vm_id).await
    }

    async fn stop_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        self.client.shutdown_server(provider_vm_id).await
    }

    async fn start_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        self.client.poweron_server(provider_vm_id).await
    }

    async fn get_vm_status(&self, provider_vm_id: &str) -> Result<VmStatus, VmProvisionerError> {
        let server = self.client.get_server(provider_vm_id).await?;
        Ok(map_hetzner_status(&server.status))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::sync::Mutex;
    use uuid::Uuid;

    struct MockHetznerApiClient {
        create_calls: Mutex<Vec<CreateServerRequest>>,
        delete_calls: Mutex<Vec<String>>,
        shutdown_calls: Mutex<Vec<String>>,
        poweron_calls: Mutex<Vec<String>>,
        create_responses: Mutex<VecDeque<Result<HetznerServer, VmProvisionerError>>>,
        get_responses: Mutex<VecDeque<Result<HetznerServer, VmProvisionerError>>>,
    }

    impl MockHetznerApiClient {
        fn with_create_response(response: Result<HetznerServer, VmProvisionerError>) -> Self {
            Self {
                create_calls: Mutex::new(Vec::new()),
                delete_calls: Mutex::new(Vec::new()),
                shutdown_calls: Mutex::new(Vec::new()),
                poweron_calls: Mutex::new(Vec::new()),
                create_responses: Mutex::new(VecDeque::from([response])),
                get_responses: Mutex::new(VecDeque::new()),
            }
        }

        fn with_get_response(response: Result<HetznerServer, VmProvisionerError>) -> Self {
            Self {
                create_calls: Mutex::new(Vec::new()),
                delete_calls: Mutex::new(Vec::new()),
                shutdown_calls: Mutex::new(Vec::new()),
                poweron_calls: Mutex::new(Vec::new()),
                create_responses: Mutex::new(VecDeque::new()),
                get_responses: Mutex::new(VecDeque::from([response])),
            }
        }
    }

    #[async_trait]
    impl HetznerApi for MockHetznerApiClient {
        async fn create_server(
            &self,
            body: &CreateServerRequest,
        ) -> Result<HetznerServer, VmProvisionerError> {
            self.create_calls
                .lock()
                .expect("create_calls lock poisoned")
                .push(body.clone());
            self.create_responses
                .lock()
                .expect("create_responses lock poisoned")
                .pop_front()
                .expect("missing mocked create response")
        }

        async fn delete_server(&self, id: &str) -> Result<(), VmProvisionerError> {
            self.delete_calls
                .lock()
                .expect("delete_calls lock poisoned")
                .push(id.to_string());
            Ok(())
        }

        async fn shutdown_server(&self, id: &str) -> Result<(), VmProvisionerError> {
            self.shutdown_calls
                .lock()
                .expect("shutdown_calls lock poisoned")
                .push(id.to_string());
            Ok(())
        }

        async fn poweron_server(&self, id: &str) -> Result<(), VmProvisionerError> {
            self.poweron_calls
                .lock()
                .expect("poweron_calls lock poisoned")
                .push(id.to_string());
            Ok(())
        }

        async fn get_server(&self, _id: &str) -> Result<HetznerServer, VmProvisionerError> {
            self.get_responses
                .lock()
                .expect("get_responses lock poisoned")
                .pop_front()
                .expect("missing mocked get response")
        }
    }

    fn test_config() -> HetznerProvisionerConfig {
        HetznerProvisionerConfig {
            api_token: "tok".to_string(),
            server_type: "cpx32".to_string(),
            image: "ubuntu-22.04".to_string(),
            ssh_key_name: Some("fj-deploy".to_string()),
            firewall_id: Some("12345".to_string()),
            network_id: Some("777".to_string()),
            location: "fsn1".to_string(),
            api_base_url: "https://api.hetzner.cloud".to_string(),
        }
    }

    fn test_create_request() -> CreateVmRequest {
        CreateVmRequest {
            region: "eu-central-1".to_string(),
            vm_type: "cpx32".to_string(),
            hostname: "fj-test-node".to_string(),
            customer_id: Uuid::new_v4(),
            node_id: "node-001".to_string(),
            user_data: Some("#!/bin/bash\necho hello".to_string()),
        }
    }

    fn running_server_with_ips(public_ip: &str, private_ip: &str) -> HetznerServer {
        HetznerServer {
            id: 42,
            status: "running".to_string(),
            public_net: PublicNet {
                ipv4: Some(Ipv4Info {
                    ip: public_ip.to_string(),
                }),
            },
            private_net: vec![PrivateNet {
                ip: private_ip.to_string(),
            }],
        }
    }

    /// Verifies the Hetzner create_server payload includes hostname, server type, image, location, user_data, SSH keys, firewall, network, and labels.
    #[tokio::test]
    async fn create_vm_builds_expected_payload() {
        let mock_api = Arc::new(MockHetznerApiClient::with_create_response(Ok(
            running_server_with_ips("203.0.113.42", "10.0.0.5"),
        )));
        let provisioner =
            HetznerVmProvisioner::with_client_for_tests(test_config(), mock_api.clone());

        provisioner
            .create_vm(&test_create_request())
            .await
            .expect("create_vm should succeed");

        let calls = mock_api
            .create_calls
            .lock()
            .expect("create_calls lock poisoned");
        assert_eq!(calls.len(), 1);
        let body = &calls[0];
        assert_eq!(body.name, "fj-test-node");
        assert_eq!(body.server_type, "cpx32");
        assert_eq!(body.image, "ubuntu-22.04");
        assert_eq!(body.location, "fsn1");
        assert_eq!(body.user_data.as_deref(), Some("#!/bin/bash\necho hello"));
        assert_eq!(body.ssh_keys, vec!["fj-deploy".to_string()]);
        assert_eq!(body.firewalls.len(), 1);
        assert_eq!(body.firewalls[0].firewall, 12345);
        assert_eq!(body.networks, vec![777]);
        assert_eq!(
            body.labels.get("managed-by").map(String::as_str),
            Some("fjcloud")
        );
        assert_eq!(
            body.labels.get("node_id").map(String::as_str),
            Some("node-001")
        );
    }

    /// Verifies that `destroy_vm` delegates to `delete_server` with the correct server ID.
    #[tokio::test]
    async fn destroy_vm_calls_delete() {
        let mock_api = Arc::new(MockHetznerApiClient::with_create_response(Ok(
            running_server_with_ips("203.0.113.42", "10.0.0.5"),
        )));
        let provisioner =
            HetznerVmProvisioner::with_client_for_tests(test_config(), mock_api.clone());

        provisioner
            .destroy_vm("42")
            .await
            .expect("destroy_vm should succeed");

        let calls = mock_api
            .delete_calls
            .lock()
            .expect("delete_calls lock poisoned");
        assert_eq!(&*calls, &[String::from("42")]);
    }

    /// Verifies the returned `VmInstance` carries the Hetzner server ID, public/private IPs, status, and region.
    #[tokio::test]
    async fn create_vm_returns_instance_with_ip() {
        let mock_api = Arc::new(MockHetznerApiClient::with_create_response(Ok(
            running_server_with_ips("198.51.100.5", "10.0.0.5"),
        )));
        let provisioner =
            HetznerVmProvisioner::with_client_for_tests(test_config(), mock_api.clone());
        let req = test_create_request();

        let result = provisioner
            .create_vm(&req)
            .await
            .expect("create_vm should succeed");

        assert_eq!(result.provider_vm_id, "42");
        assert_eq!(result.public_ip.as_deref(), Some("198.51.100.5"));
        assert_eq!(result.private_ip.as_deref(), Some("10.0.0.5"));
        assert_eq!(result.status, VmStatus::Running);
        assert_eq!(result.region, "eu-central-1");
    }

    #[test]
    fn api_error_json_maps_to_provisioner_error() {
        let err = map_hetzner_api_error(
            reqwest::StatusCode::UNPROCESSABLE_ENTITY,
            r#"{"error":{"code":"uniqueness_error","message":"server name is already used"}}"#,
        );

        match err {
            VmProvisionerError::Api(message) => {
                assert!(message.contains("uniqueness_error"));
                assert!(message.contains("already used"));
            }
            other => panic!("expected Api error, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn get_vm_status_returns_correct_status() {
        let mock_api = Arc::new(MockHetznerApiClient::with_get_response(Ok(
            running_server_with_ips("203.0.113.42", "10.0.0.5"),
        )));
        let provisioner =
            HetznerVmProvisioner::with_client_for_tests(test_config(), mock_api.clone());

        let status = provisioner
            .get_vm_status("42")
            .await
            .expect("status request should succeed");
        assert_eq!(status, VmStatus::Running);
    }

    /// Verifies that `stop_vm` delegates to `shutdown_server` with the correct server ID.
    #[tokio::test]
    async fn stop_vm_calls_shutdown() {
        let mock_api = Arc::new(MockHetznerApiClient::with_get_response(Ok(
            running_server_with_ips("203.0.113.42", "10.0.0.5"),
        )));
        let provisioner =
            HetznerVmProvisioner::with_client_for_tests(test_config(), mock_api.clone());

        provisioner
            .stop_vm("42")
            .await
            .expect("stop_vm should succeed");

        let calls = mock_api
            .shutdown_calls
            .lock()
            .expect("shutdown_calls lock poisoned");
        assert_eq!(&*calls, &[String::from("42")]);
    }

    /// Verifies that `start_vm` delegates to `poweron_server` with the correct server ID.
    #[tokio::test]
    async fn start_vm_calls_poweron() {
        let mock_api = Arc::new(MockHetznerApiClient::with_get_response(Ok(
            running_server_with_ips("203.0.113.42", "10.0.0.5"),
        )));
        let provisioner =
            HetznerVmProvisioner::with_client_for_tests(test_config(), mock_api.clone());

        provisioner
            .start_vm("42")
            .await
            .expect("start_vm should succeed");

        let calls = mock_api
            .poweron_calls
            .lock()
            .expect("poweron_calls lock poisoned");
        assert_eq!(&*calls, &[String::from("42")]);
    }
}
