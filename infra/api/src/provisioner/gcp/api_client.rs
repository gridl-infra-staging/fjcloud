//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/provisioner/gcp/api_client.rs.
use async_trait::async_trait;
use serde::Deserialize;

use crate::provisioner::VmProvisionerError;

#[derive(Debug, Deserialize)]
pub(crate) struct GcpErrorResponse {
    error: GcpErrorBody,
}

#[derive(Debug, Deserialize)]
pub(crate) struct GcpErrorBody {
    code: i64,
    message: String,
    #[serde(default)]
    errors: Vec<GcpErrorDetail>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct GcpErrorDetail {
    #[serde(default)]
    reason: String,
    #[serde(default)]
    message: String,
}

/// GCP Compute Engine API abstraction for insert/delete/stop/start/get instance operations scoped by project and zone.
#[async_trait]
pub(crate) trait GcpApi: Send + Sync {
    async fn insert_instance(
        &self,
        project: &str,
        zone: &str,
        body: &super::CreateInstanceRequest,
    ) -> Result<(), VmProvisionerError>;

    async fn delete_instance(
        &self,
        project: &str,
        zone: &str,
        instance: &str,
    ) -> Result<(), VmProvisionerError>;

    async fn stop_instance(
        &self,
        project: &str,
        zone: &str,
        instance: &str,
    ) -> Result<(), VmProvisionerError>;

    async fn start_instance(
        &self,
        project: &str,
        zone: &str,
        instance: &str,
    ) -> Result<(), VmProvisionerError>;

    async fn get_instance(
        &self,
        project: &str,
        zone: &str,
        instance: &str,
    ) -> Result<super::GcpInstance, VmProvisionerError>;
}

pub(crate) struct ReqwestGcpApiClient {
    http: reqwest::Client,
    base_url: String,
    token: String,
}

impl ReqwestGcpApiClient {
    pub(crate) fn new(base_url: &str, token: &str) -> Self {
        Self {
            http: reqwest::Client::new(),
            base_url: base_url.to_string(),
            token: token.to_string(),
        }
    }

    /// Builds a Compute API URL for `/projects/{project}/zones/{zone}/instances[/{name}]`.
    pub(crate) fn instance_path(
        &self,
        project: &str,
        zone: &str,
        instance: Option<&str>,
    ) -> String {
        match instance {
            Some(name) => format!(
                "{}/projects/{project}/zones/{zone}/instances/{name}",
                self.base_url
            ),
            None => format!(
                "{}/projects/{project}/zones/{zone}/instances",
                self.base_url
            ),
        }
    }
}

#[async_trait]
impl GcpApi for ReqwestGcpApiClient {
    /// POSTs an instance creation request to the Compute API with bearer auth.
    async fn insert_instance(
        &self,
        project: &str,
        zone: &str,
        body: &super::CreateInstanceRequest,
    ) -> Result<(), VmProvisionerError> {
        let resp = self
            .http
            .post(self.instance_path(project, zone, None))
            .bearer_auth(&self.token)
            .json(body)
            .send()
            .await
            .map_err(|e| {
                VmProvisionerError::Api(format!("GCP insert_instance request failed: {e}"))
            })?;

        if !resp.status().is_success() {
            return Err(parse_error_response(resp).await);
        }

        Ok(())
    }

    /// DELETEs an instance. Returns `VmNotFound` on 404.
    async fn delete_instance(
        &self,
        project: &str,
        zone: &str,
        instance: &str,
    ) -> Result<(), VmProvisionerError> {
        let resp = self
            .http
            .delete(self.instance_path(project, zone, Some(instance)))
            .bearer_auth(&self.token)
            .send()
            .await
            .map_err(|e| {
                VmProvisionerError::Api(format!("GCP delete_instance request failed: {e}"))
            })?;

        if resp.status().as_u16() == 404 {
            return Err(VmProvisionerError::VmNotFound(instance.to_string()));
        }

        if !resp.status().is_success() {
            return Err(parse_error_response(resp).await);
        }

        Ok(())
    }

    /// POSTs to `instances/{name}/stop` with bearer auth. Returns `VmNotFound` on 404.
    async fn stop_instance(
        &self,
        project: &str,
        zone: &str,
        instance: &str,
    ) -> Result<(), VmProvisionerError> {
        let resp = self
            .http
            .post(format!(
                "{}/stop",
                self.instance_path(project, zone, Some(instance))
            ))
            .bearer_auth(&self.token)
            .send()
            .await
            .map_err(|e| {
                VmProvisionerError::Api(format!("GCP stop_instance request failed: {e}"))
            })?;

        if resp.status().as_u16() == 404 {
            return Err(VmProvisionerError::VmNotFound(instance.to_string()));
        }

        if !resp.status().is_success() {
            return Err(parse_error_response(resp).await);
        }

        Ok(())
    }

    /// POSTs to `instances/{name}/start` with bearer auth. Returns `VmNotFound` on 404.
    async fn start_instance(
        &self,
        project: &str,
        zone: &str,
        instance: &str,
    ) -> Result<(), VmProvisionerError> {
        let resp = self
            .http
            .post(format!(
                "{}/start",
                self.instance_path(project, zone, Some(instance))
            ))
            .bearer_auth(&self.token)
            .send()
            .await
            .map_err(|e| {
                VmProvisionerError::Api(format!("GCP start_instance request failed: {e}"))
            })?;

        if resp.status().as_u16() == 404 {
            return Err(VmProvisionerError::VmNotFound(instance.to_string()));
        }

        if !resp.status().is_success() {
            return Err(parse_error_response(resp).await);
        }

        Ok(())
    }

    /// GETs an instance by name. Returns `VmNotFound` on 404, parses `GcpInstance` on success.
    async fn get_instance(
        &self,
        project: &str,
        zone: &str,
        instance: &str,
    ) -> Result<super::GcpInstance, VmProvisionerError> {
        let resp = self
            .http
            .get(self.instance_path(project, zone, Some(instance)))
            .bearer_auth(&self.token)
            .send()
            .await
            .map_err(|e| {
                VmProvisionerError::Api(format!("GCP get_instance request failed: {e}"))
            })?;

        if resp.status().as_u16() == 404 {
            return Err(VmProvisionerError::VmNotFound(instance.to_string()));
        }

        if !resp.status().is_success() {
            return Err(parse_error_response(resp).await);
        }

        resp.json::<super::GcpInstance>()
            .await
            .map_err(|e| VmProvisionerError::Api(format!("GCP get_instance parse failed: {e}")))
    }
}

async fn parse_error_response(resp: reqwest::Response) -> VmProvisionerError {
    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    map_gcp_api_error(status, &body)
}

/// Parses a GCP JSON error response into a `VmProvisionerError`. Falls back to the HTTP status string on parse failure.
fn map_gcp_api_error(status: reqwest::StatusCode, body: &str) -> VmProvisionerError {
    match serde_json::from_str::<GcpErrorResponse>(body) {
        Ok(err) => {
            let detail = err
                .error
                .errors
                .first()
                .map(|e| format!("{} {}", e.reason, e.message))
                .unwrap_or_default();
            VmProvisionerError::Api(format!(
                "GCP API error ({} / code {}): {} {}",
                status, err.error.code, err.error.message, detail
            ))
        }
        Err(_) => VmProvisionerError::Api(format!("GCP API error: HTTP {status}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn api_error_json_maps_to_provisioner_error() {
        let err = map_gcp_api_error(
            reqwest::StatusCode::BAD_REQUEST,
            r#"{"error":{"code":400,"message":"Invalid value","errors":[{"reason":"invalid","message":"bad machine type"}]}}"#,
        );

        match err {
            VmProvisionerError::Api(message) => {
                assert!(message.contains("Invalid value"));
                assert!(message.contains("invalid"));
                assert!(message.contains("bad machine type"));
            }
            other => panic!("expected Api error, got {other:?}"),
        }
    }
}
