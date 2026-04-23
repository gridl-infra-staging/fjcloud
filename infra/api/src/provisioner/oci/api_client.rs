//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/provisioner/oci/api_client.rs.
use std::collections::HashMap;

use async_trait::async_trait;
use base64::Engine;
use chrono::Utc;
use rsa::pkcs1::DecodeRsaPrivateKey;
use rsa::pkcs1v15::SigningKey;
use rsa::pkcs8::DecodePrivateKey;
use rsa::signature::{SignatureEncoding, Signer};
use rsa::RsaPrivateKey;
use serde::de::DeserializeOwned;
use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::provisioner::VmProvisionerError;

#[derive(Debug, Deserialize)]
pub(crate) struct OciErrorResponse {
    #[serde(default)]
    code: String,
    #[serde(default)]
    message: String,
}

pub(crate) struct OciRequestSigner {
    key_id: String,
    private_key: RsaPrivateKey,
}

impl OciRequestSigner {
    pub(crate) fn from_config(
        config: &crate::provisioner::oci::OciProvisionerConfig,
    ) -> Result<Self, VmProvisionerError> {
        let private_key = parse_oci_private_key(&config.private_key_pem)
            .map_err(|e| VmProvisionerError::Api(format!("invalid OCI private key: {e}")))?;
        Ok(Self {
            key_id: format!(
                "{}/{}/{}",
                config.tenancy_ocid, config.user_ocid, config.key_fingerprint
            ),
            private_key,
        })
    }

    /// Builds OCI request signature headers: (request-target), host (with explicit port when present), date, and optional body headers (content-length, content-type, x-content-sha256). Signs with RSA-SHA256.
    pub(crate) fn signed_headers(
        &self,
        method: &reqwest::Method,
        url: &reqwest::Url,
        body: &[u8],
        include_body_headers: bool,
    ) -> Result<Vec<(String, String)>, VmProvisionerError> {
        let host = url
            .host_str()
            .ok_or_else(|| VmProvisionerError::Api("OCI URL host missing".to_string()))?;
        let host_header = match url.port() {
            Some(port) => format!("{host}:{port}"),
            None => host.to_string(),
        };
        let date = Utc::now().format("%a, %d %b %Y %H:%M:%S GMT").to_string();
        let request_target = format!(
            "{} {}",
            method.as_str().to_ascii_lowercase(),
            path_and_query(url)
        );

        let mut names = vec![
            "(request-target)".to_string(),
            "host".to_string(),
            "date".to_string(),
        ];
        let mut values = HashMap::new();
        values.insert("(request-target)".to_string(), request_target);
        values.insert("host".to_string(), host_header.clone());
        values.insert("date".to_string(), date.clone());

        if include_body_headers {
            let digest = Sha256::digest(body);
            let digest_b64 = base64::engine::general_purpose::STANDARD.encode(digest);
            names.push("content-length".to_string());
            names.push("content-type".to_string());
            names.push("x-content-sha256".to_string());
            values.insert("content-length".to_string(), body.len().to_string());
            values.insert("content-type".to_string(), "application/json".to_string());
            values.insert("x-content-sha256".to_string(), digest_b64);
        }

        let signing_input = names
            .iter()
            .map(|name| format!("{name}: {}", values.get(name).cloned().unwrap_or_default()))
            .collect::<Vec<_>>()
            .join("\n");

        let signing_key = SigningKey::<Sha256>::new(self.private_key.clone());
        let signature = signing_key.sign(signing_input.as_bytes());
        let signature_b64 = base64::engine::general_purpose::STANDARD.encode(signature.to_bytes());

        let authorization = format!(
            "Signature version=\"1\",keyId=\"{}\",algorithm=\"rsa-sha256\",headers=\"{}\",signature=\"{}\"",
            self.key_id,
            names.join(" "),
            signature_b64
        );

        let mut headers = vec![
            ("host".to_string(), host_header),
            ("date".to_string(), date),
            ("authorization".to_string(), authorization),
        ];
        if include_body_headers {
            headers.push((
                "content-length".to_string(),
                values.get("content-length").cloned().unwrap_or_default(),
            ));
            headers.push((
                "content-type".to_string(),
                values.get("content-type").cloned().unwrap_or_default(),
            ));
            headers.push((
                "x-content-sha256".to_string(),
                values.get("x-content-sha256").cloned().unwrap_or_default(),
            ));
        }

        Ok(headers)
    }
}

pub(crate) fn parse_oci_private_key(pem: &str) -> Result<RsaPrivateKey, String> {
    RsaPrivateKey::from_pkcs8_pem(pem)
        .or_else(|_| RsaPrivateKey::from_pkcs1_pem(pem))
        .map_err(|e| e.to_string())
}

pub(crate) fn path_and_query(url: &reqwest::Url) -> String {
    match url.query() {
        Some(query) => format!("{}?{}", url.path(), query),
        None => url.path().to_string(),
    }
}

/// OCI Compute API abstraction for launch, terminate, instance_action, get_instance, list_vnic_attachments, and get_vnic operations.
#[async_trait]
pub(crate) trait OciApi: Send + Sync {
    async fn launch_instance(
        &self,
        body: &crate::provisioner::oci::LaunchInstanceRequest,
    ) -> Result<crate::provisioner::oci::OciInstance, VmProvisionerError>;
    async fn terminate_instance(&self, instance_id: &str) -> Result<(), VmProvisionerError>;
    async fn instance_action(
        &self,
        instance_id: &str,
        action: &str,
    ) -> Result<(), VmProvisionerError>;
    async fn get_instance(
        &self,
        instance_id: &str,
    ) -> Result<crate::provisioner::oci::OciInstance, VmProvisionerError>;
    async fn list_vnic_attachments(
        &self,
        compartment_id: &str,
        instance_id: &str,
    ) -> Result<Vec<crate::provisioner::oci::OciVnicAttachment>, VmProvisionerError>;
    async fn get_vnic(
        &self,
        vnic_id: &str,
    ) -> Result<crate::provisioner::oci::OciVnic, VmProvisionerError>;
}

pub(crate) struct ReqwestOciApiClient {
    http: reqwest::Client,
    base_url: String,
    signer: OciRequestSigner,
}

impl ReqwestOciApiClient {
    pub(crate) fn new(
        config: &crate::provisioner::oci::OciProvisionerConfig,
    ) -> Result<Self, VmProvisionerError> {
        Ok(Self {
            http: reqwest::Client::new(),
            base_url: config.api_base_url.clone(),
            signer: OciRequestSigner::from_config(config)?,
        })
    }

    pub(crate) fn endpoint_url(&self, path: &str) -> String {
        format!("{}{}", self.base_url, path)
    }

    /// Attaches OCI-signed headers (host, date, authorization, and optional body headers) to a `reqwest::RequestBuilder`.
    pub(crate) fn apply_signed_headers(
        &self,
        mut builder: reqwest::RequestBuilder,
        method: &reqwest::Method,
        url: &reqwest::Url,
        body: &[u8],
        include_body_headers: bool,
    ) -> Result<reqwest::RequestBuilder, VmProvisionerError> {
        for (name, value) in self
            .signer
            .signed_headers(method, url, body, include_body_headers)?
        {
            builder = builder.header(name, value);
        }
        Ok(builder)
    }
}

async fn parse_json_response<T: DeserializeOwned>(
    resp: reqwest::Response,
    context: &str,
) -> Result<T, VmProvisionerError> {
    resp.json::<T>()
        .await
        .map_err(|e| VmProvisionerError::Api(format!("{context} parse failed: {e}")))
}

async fn parse_error_response(resp: reqwest::Response) -> VmProvisionerError {
    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    map_oci_api_error(status, &body)
}

fn map_oci_api_error(status: reqwest::StatusCode, body: &str) -> VmProvisionerError {
    match serde_json::from_str::<OciErrorResponse>(body) {
        Ok(err) if !err.code.is_empty() || !err.message.is_empty() => VmProvisionerError::Api(
            format!("OCI API error ({}): {} — {}", status, err.code, err.message),
        ),
        _ => VmProvisionerError::Api(format!("OCI API error: HTTP {status}")),
    }
}

#[async_trait]
impl OciApi for ReqwestOciApiClient {
    /// POSTs to `/20160918/instances` with OCI signature auth and returns the launched `OciInstance`.
    async fn launch_instance(
        &self,
        body: &crate::provisioner::oci::LaunchInstanceRequest,
    ) -> Result<crate::provisioner::oci::OciInstance, VmProvisionerError> {
        let url = self.endpoint_url("/20160918/instances");
        let parsed_url = reqwest::Url::parse(&url)
            .map_err(|e| VmProvisionerError::Api(format!("invalid OCI URL '{url}': {e}")))?;
        let bytes = serde_json::to_vec(body).map_err(|e| {
            VmProvisionerError::Api(format!("OCI launch payload serialize failed: {e}"))
        })?;

        let builder = self.http.post(url).body(bytes.clone());
        let builder =
            self.apply_signed_headers(builder, &reqwest::Method::POST, &parsed_url, &bytes, true)?;

        let resp = builder.send().await.map_err(|e| {
            VmProvisionerError::Api(format!("OCI launch_instance request failed: {e}"))
        })?;
        if !resp.status().is_success() {
            return Err(parse_error_response(resp).await);
        }
        parse_json_response(resp, "OCI launch_instance").await
    }

    /// DELETEs `/20160918/instances/{id}` with OCI signature auth. Returns `VmNotFound` on 404.
    async fn terminate_instance(&self, instance_id: &str) -> Result<(), VmProvisionerError> {
        let url = self.endpoint_url(&format!("/20160918/instances/{instance_id}"));
        let parsed_url = reqwest::Url::parse(&url)
            .map_err(|e| VmProvisionerError::Api(format!("invalid OCI URL '{url}': {e}")))?;
        let builder = self.http.delete(url);
        let builder =
            self.apply_signed_headers(builder, &reqwest::Method::DELETE, &parsed_url, &[], false)?;

        let resp = builder.send().await.map_err(|e| {
            VmProvisionerError::Api(format!("OCI terminate_instance request failed: {e}"))
        })?;
        if resp.status().as_u16() == 404 {
            return Err(VmProvisionerError::VmNotFound(instance_id.to_string()));
        }
        if !resp.status().is_success() {
            return Err(parse_error_response(resp).await);
        }
        Ok(())
    }

    /// POSTs to `/20160918/instances/{id}?action={action}` with OCI signature auth. Returns `VmNotFound` on 404.
    async fn instance_action(
        &self,
        instance_id: &str,
        action: &str,
    ) -> Result<(), VmProvisionerError> {
        let url = self.endpoint_url(&format!(
            "/20160918/instances/{instance_id}?action={action}"
        ));
        let parsed_url = reqwest::Url::parse(&url)
            .map_err(|e| VmProvisionerError::Api(format!("invalid OCI URL '{url}': {e}")))?;
        let body: Vec<u8> = Vec::new();
        let builder = self.http.post(url).body(body.clone());
        let builder =
            self.apply_signed_headers(builder, &reqwest::Method::POST, &parsed_url, &body, true)?;

        let resp = builder.send().await.map_err(|e| {
            VmProvisionerError::Api(format!("OCI instance_action request failed: {e}"))
        })?;
        if resp.status().as_u16() == 404 {
            return Err(VmProvisionerError::VmNotFound(instance_id.to_string()));
        }
        if !resp.status().is_success() {
            return Err(parse_error_response(resp).await);
        }
        Ok(())
    }

    /// GETs `/20160918/instances/{id}` with OCI signature auth. Returns `VmNotFound` on 404.
    async fn get_instance(
        &self,
        instance_id: &str,
    ) -> Result<crate::provisioner::oci::OciInstance, VmProvisionerError> {
        let url = self.endpoint_url(&format!("/20160918/instances/{instance_id}"));
        let parsed_url = reqwest::Url::parse(&url)
            .map_err(|e| VmProvisionerError::Api(format!("invalid OCI URL '{url}': {e}")))?;
        let builder = self.http.get(url);
        let builder =
            self.apply_signed_headers(builder, &reqwest::Method::GET, &parsed_url, &[], false)?;

        let resp = builder.send().await.map_err(|e| {
            VmProvisionerError::Api(format!("OCI get_instance request failed: {e}"))
        })?;
        if resp.status().as_u16() == 404 {
            return Err(VmProvisionerError::VmNotFound(instance_id.to_string()));
        }
        if !resp.status().is_success() {
            return Err(parse_error_response(resp).await);
        }
        parse_json_response(resp, "OCI get_instance").await
    }

    /// GETs `/20160918/vnicAttachments` filtered by compartment and instance. Returns the attachment list.
    async fn list_vnic_attachments(
        &self,
        compartment_id: &str,
        instance_id: &str,
    ) -> Result<Vec<crate::provisioner::oci::OciVnicAttachment>, VmProvisionerError> {
        let url = self.endpoint_url(&format!(
            "/20160918/vnicAttachments?compartmentId={compartment_id}&instanceId={instance_id}"
        ));
        let parsed_url = reqwest::Url::parse(&url)
            .map_err(|e| VmProvisionerError::Api(format!("invalid OCI URL '{url}': {e}")))?;
        let builder = self.http.get(url);
        let builder =
            self.apply_signed_headers(builder, &reqwest::Method::GET, &parsed_url, &[], false)?;

        let resp = builder.send().await.map_err(|e| {
            VmProvisionerError::Api(format!("OCI list_vnic_attachments request failed: {e}"))
        })?;
        if !resp.status().is_success() {
            return Err(parse_error_response(resp).await);
        }
        let parsed: crate::provisioner::oci::OciVnicAttachmentList =
            parse_json_response(resp, "OCI list_vnic_attachments").await?;
        Ok(parsed.items)
    }

    /// GETs `/20160918/vnics/{id}` with OCI signature auth and returns the `OciVnic` (public/private IPs).
    async fn get_vnic(
        &self,
        vnic_id: &str,
    ) -> Result<crate::provisioner::oci::OciVnic, VmProvisionerError> {
        let url = self.endpoint_url(&format!("/20160918/vnics/{vnic_id}"));
        let parsed_url = reqwest::Url::parse(&url)
            .map_err(|e| VmProvisionerError::Api(format!("invalid OCI URL '{url}': {e}")))?;
        let builder = self.http.get(url);
        let builder =
            self.apply_signed_headers(builder, &reqwest::Method::GET, &parsed_url, &[], false)?;

        let resp = builder
            .send()
            .await
            .map_err(|e| VmProvisionerError::Api(format!("OCI get_vnic request failed: {e}")))?;
        if !resp.status().is_success() {
            return Err(parse_error_response(resp).await);
        }
        parse_json_response(resp, "OCI get_vnic").await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn api_error_json_maps_to_provisioner_error() {
        let err = map_oci_api_error(
            reqwest::StatusCode::BAD_REQUEST,
            r#"{"code":"InvalidParameter","message":"shape is not available"}"#,
        );
        match err {
            VmProvisionerError::Api(msg) => {
                assert!(msg.contains("InvalidParameter"), "got: {msg}");
                assert!(msg.contains("shape is not available"), "got: {msg}");
            }
            other => panic!("expected Api error, got: {other:?}"),
        }
    }

    /// Verifies the host header includes the explicit port (e.g. `host:8443`) for OCI signature parity.
    #[test]
    fn signed_headers_include_explicit_port_in_host() {
        use reqwest::Url;

        let config = crate::provisioner::oci::test_oci_provisioner_config();
        let signer = OciRequestSigner::from_config(&config).expect("signer should initialize");
        let url = Url::parse("https://iaas.example.test:8443/20160918/instances")
            .expect("url should parse");

        let headers = signer
            .signed_headers(&reqwest::Method::GET, &url, &[], false)
            .expect("headers should sign");
        let host_header = headers
            .iter()
            .find(|(name, _)| name == "host")
            .map(|(_, value)| value.as_str());

        assert_eq!(
            host_header,
            Some("iaas.example.test:8443"),
            "host header must include explicit port for OCI signature parity"
        );
    }
}
