use async_trait::async_trait;
use chrono::{TimeZone, Utc};
use rand::RngCore;
use std::collections::HashSet;

use super::{NodeSecretError, NodeSecretManager, NodeSecretRecord};
use aws_sdk_ssm::operation::get_parameter::GetParameterError;

const NODE_PARAMETER_PREFIX: &str = "/fjcloud/";
const NODE_KEY_SUFFIX: &str = "/api-key";
const PREVIOUS_NODE_KEY_SUFFIX: &str = "/api-key-previous";
const SSM_LIST_PAGE_SIZE: i32 = 50;

/// AWS SSM Parameter Store implementation of `NodeSecretManager`.
///
/// Stores per-node API keys as SecureString parameters at `/fjcloud/{node_id}/api-key`.
pub struct SsmNodeSecretManager {
    client: aws_sdk_ssm::Client,
}

impl SsmNodeSecretManager {
    pub fn new(client: aws_sdk_ssm::Client) -> Self {
        Self { client }
    }

    /// Generate a cryptographically random API key with the `fj_live_` prefix.
    fn generate_api_key() -> String {
        let mut key_bytes = [0u8; 32];
        rand::thread_rng().fill_bytes(&mut key_bytes);
        format!("fj_live_{}", hex::encode(key_bytes))
    }

    fn parameter_name(node_id: &str) -> String {
        format!("/fjcloud/{node_id}/api-key")
    }

    fn previous_parameter_name(node_id: &str) -> String {
        format!("/fjcloud/{node_id}/api-key-previous")
    }

    fn listed_node_id(path: &str) -> Option<&str> {
        let path = path.strip_prefix(NODE_PARAMETER_PREFIX)?;
        let node_id = path
            .strip_suffix(PREVIOUS_NODE_KEY_SUFFIX)
            .or_else(|| path.strip_suffix(NODE_KEY_SUFFIX))?;
        (!node_id.is_empty() && !node_id.contains('/')).then_some(node_id)
    }

    async fn delete_parameter_if_present(&self, param_name: &str) -> Result<(), NodeSecretError> {
        match self.client.delete_parameter().name(param_name).send().await {
            Ok(_) => Ok(()),
            // ParameterNotFound is not an error during cleanup — the param may
            // never have been created (e.g. provisioning failed before SSM write).
            Err(aws_sdk_ssm::error::SdkError::ServiceError(ref se))
                if se.err().is_parameter_not_found() =>
            {
                Ok(())
            }
            Err(e) => Err(NodeSecretError::Api(format!(
                "SSM DeleteParameter failed for {param_name}: {e}"
            ))),
        }
    }

    /// Preserve modeled missing-parameter errors before the AWS SDK's Display
    /// implementation collapses them into the generic "service error" string.
    /// Seed-index creation relies on this remaining distinguishable so the
    /// existing "create the missing key" recovery path can run.
    fn map_get_parameter_error<R>(
        param_name: &str,
        error: aws_sdk_ssm::error::SdkError<GetParameterError, R>,
    ) -> NodeSecretError {
        if error
            .as_service_error()
            .is_some_and(|service_error| service_error.is_parameter_not_found())
        {
            return NodeSecretError::Api(format!("parameter not found: {param_name}"));
        }

        NodeSecretError::Api(format!("SSM GetParameter failed: {error}"))
    }
}

#[async_trait]
impl NodeSecretManager for SsmNodeSecretManager {
    /// Generates an `fj_live_` API key and stores it as a SecureString parameter
    /// in SSM with overwrite enabled.
    async fn create_node_api_key(
        &self,
        node_id: &str,
        _region: &str,
    ) -> Result<String, NodeSecretError> {
        let api_key = Self::generate_api_key();
        let param_name = Self::parameter_name(node_id);

        self.client
            .put_parameter()
            .name(&param_name)
            .value(&api_key)
            .r#type(aws_sdk_ssm::types::ParameterType::SecureString)
            .overwrite(true)
            .description(format!("Flapjack API key for {node_id}"))
            .send()
            .await
            .map_err(|e| NodeSecretError::Api(format!("SSM PutParameter failed: {e}")))?;

        Ok(api_key)
    }

    /// Deletes the current and previous SSM parameters for the node. Idempotent:
    /// treats `ParameterNotFound` as success and attempts both deletes before
    /// returning the first non-idempotent failure.
    async fn delete_node_api_key(
        &self,
        node_id: &str,
        _region: &str,
    ) -> Result<(), NodeSecretError> {
        let parameter_names = [
            Self::parameter_name(node_id),
            Self::previous_parameter_name(node_id),
        ];
        let mut first_error = None;

        for param_name in &parameter_names {
            if let Err(error) = self.delete_parameter_if_present(param_name).await {
                first_error.get_or_insert(error);
            }
        }

        first_error.map_or(Ok(()), Err)
    }

    /// Retrieves and decrypts the SSM parameter for the node.s API key.
    async fn get_node_api_key(
        &self,
        node_id: &str,
        _region: &str,
    ) -> Result<String, NodeSecretError> {
        let param_name = Self::parameter_name(node_id);

        let output = self
            .client
            .get_parameter()
            .name(&param_name)
            .with_decryption(true)
            .send()
            .await
            .map_err(|error| Self::map_get_parameter_error(&param_name, error))?;

        output
            .parameter()
            .and_then(|p| p.value())
            .map(|v| v.to_string())
            .ok_or_else(|| NodeSecretError::Api(format!("SSM parameter {param_name} has no value")))
    }

    /// Reads the current key, copies it to a `-previous` parameter, then
    /// generates and stores a new key in the main parameter.
    async fn rotate_node_api_key(
        &self,
        node_id: &str,
        _region: &str,
    ) -> Result<(String, String), NodeSecretError> {
        let old_key = self.get_node_api_key(node_id, _region).await?;

        let previous_param_name = Self::previous_parameter_name(node_id);
        self.client
            .put_parameter()
            .name(&previous_param_name)
            .value(&old_key)
            .r#type(aws_sdk_ssm::types::ParameterType::SecureString)
            .overwrite(true)
            .description(format!("Previous Flapjack API key for {node_id}"))
            .send()
            .await
            .map_err(|e| NodeSecretError::Api(format!("SSM PutParameter failed: {e}")))?;

        let new_key = Self::generate_api_key();
        let param_name = Self::parameter_name(node_id);
        self.client
            .put_parameter()
            .name(&param_name)
            .value(&new_key)
            .r#type(aws_sdk_ssm::types::ParameterType::SecureString)
            .overwrite(true)
            .description(format!("Flapjack API key for {node_id}"))
            .send()
            .await
            .map_err(|e| NodeSecretError::Api(format!("SSM PutParameter failed: {e}")))?;

        Ok((old_key, new_key))
    }

    /// Finalizes rotation by verifying the `-previous` parameter matches
    /// `old_key`, then deleting it. Idempotent: treats a missing
    /// `-previous` parameter as already committed.
    async fn commit_rotation(
        &self,
        node_id: &str,
        _region: &str,
        old_key: &str,
    ) -> Result<(), NodeSecretError> {
        let previous_param_name = Self::previous_parameter_name(node_id);

        let previous_key = match self
            .client
            .get_parameter()
            .name(&previous_param_name)
            .with_decryption(true)
            .send()
            .await
        {
            Ok(output) => output
                .parameter()
                .and_then(|p| p.value())
                .map(|v| v.to_string())
                .ok_or_else(|| {
                    NodeSecretError::Api(format!(
                        "SSM parameter {previous_param_name} has no value"
                    ))
                })?,
            // No previous key means nothing to commit (idempotent).
            Err(aws_sdk_ssm::error::SdkError::ServiceError(ref se))
                if se.err().is_parameter_not_found() =>
            {
                return Ok(());
            }
            Err(e) => {
                return Err(NodeSecretError::Api(format!(
                    "SSM GetParameter failed: {e}"
                )));
            }
        };

        if previous_key != old_key {
            return Err(NodeSecretError::Api(format!(
                "rotation commit old key mismatch for node {node_id}"
            )));
        }

        match self
            .client
            .delete_parameter()
            .name(&previous_param_name)
            .send()
            .await
        {
            Ok(_) => Ok(()),
            // ParameterNotFound is expected if no rotation was done.
            Err(aws_sdk_ssm::error::SdkError::ServiceError(ref se))
                if se.err().is_parameter_not_found() =>
            {
                Ok(())
            }
            Err(e) => Err(NodeSecretError::Api(format!(
                "SSM DeleteParameter failed: {e}"
            ))),
        }
    }

    async fn list_node_api_keys(&self) -> Result<Vec<NodeSecretRecord>, NodeSecretError> {
        let name_filter = aws_sdk_ssm::types::ParameterStringFilter::builder()
            .key("Name")
            .option("BeginsWith")
            .values(NODE_PARAMETER_PREFIX)
            .build()
            .map_err(|error| NodeSecretError::Api(format!("invalid SSM list filter: {error}")))?;
        let mut records = Vec::new();
        let mut next_token: Option<String> = None;
        let mut seen_tokens = HashSet::new();

        loop {
            let output = self
                .client
                .describe_parameters()
                .parameter_filters(name_filter.clone())
                .max_results(SSM_LIST_PAGE_SIZE)
                .set_next_token(next_token.clone())
                .send()
                .await
                .map_err(|error| {
                    NodeSecretError::Api(format!("SSM DescribeParameters failed: {error}"))
                })?;

            for parameter in output.parameters() {
                let Some(path) = parameter.name() else {
                    return Err(NodeSecretError::Api(
                        "SSM listed a parameter without a name".to_string(),
                    ));
                };
                let Some(node_id) = Self::listed_node_id(path) else {
                    continue;
                };
                let modified = parameter.last_modified_date().ok_or_else(|| {
                    NodeSecretError::Api(format!(
                        "SSM parameter {path} has no last-modified timestamp"
                    ))
                })?;
                let last_modified_at = Utc
                    .timestamp_opt(modified.secs(), modified.subsec_nanos())
                    .single()
                    .ok_or_else(|| {
                        NodeSecretError::Api(format!(
                            "SSM parameter {path} has an invalid last-modified timestamp"
                        ))
                    })?;
                records.push(NodeSecretRecord {
                    node_id: node_id.to_string(),
                    path: path.to_string(),
                    last_modified_at,
                });
            }

            let Some(token) = output.next_token().map(str::to_string) else {
                return Ok(records);
            };
            if !seen_tokens.insert(token.clone()) {
                return Err(NodeSecretError::Api(
                    "SSM DescribeParameters repeated a pagination token".to_string(),
                ));
            }
            next_token = Some(token);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use aws_sdk_ssm::error::SdkError;
    use aws_sdk_ssm::types::error::ParameterNotFound;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use wiremock::matchers::method;
    use wiremock::{Mock, MockServer, ResponseTemplate};

    async fn ssm_client_for_mock_server(server: &MockServer) -> aws_sdk_ssm::Client {
        let aws_config = aws_config::defaults(aws_config::BehaviorVersion::latest())
            .region(aws_sdk_ssm::config::Region::new("us-east-1"))
            .load()
            .await;
        let credentials = aws_sdk_ssm::config::Credentials::new(
            "test-access-key",
            "test-secret-key",
            None,
            None,
            "orphan-report-test",
        );
        let config = aws_sdk_ssm::config::Builder::from(&aws_config)
            .endpoint_url(server.uri())
            .credentials_provider(credentials)
            .build();
        aws_sdk_ssm::Client::from_conf(config)
    }

    /// Verifies the generated key has the `fj_live_` prefix and is 72
    /// characters long.
    #[test]
    fn generate_api_key_has_correct_format() {
        let key = SsmNodeSecretManager::generate_api_key();
        assert!(
            key.starts_with("fj_live_"),
            "key must start with fj_live_ prefix"
        );
        // fj_live_ (8 chars) + 64 hex chars = 72 chars
        assert_eq!(
            key.len(),
            72,
            "key must be 72 characters (8 prefix + 64 hex)"
        );
        // Verify the hex portion is valid hex
        let hex_part = &key[8..];
        assert!(
            hex::decode(hex_part).is_ok(),
            "key suffix must be valid hex"
        );
    }

    #[test]
    fn generate_api_key_is_unique() {
        let key1 = SsmNodeSecretManager::generate_api_key();
        let key2 = SsmNodeSecretManager::generate_api_key();
        assert_ne!(key1, key2, "generated keys must be unique");
    }

    #[test]
    fn parameter_name_format() {
        assert_eq!(
            SsmNodeSecretManager::parameter_name("node-abc123"),
            "/fjcloud/node-abc123/api-key"
        );
    }

    #[tokio::test]
    async fn orphan_report_ssm_listing_exhausts_current_and_previous_key_pages() {
        let server = MockServer::start().await;
        let calls = Arc::new(AtomicUsize::new(0));
        let responder_calls = calls.clone();
        Mock::given(method("POST"))
            .respond_with(move |_request: &wiremock::Request| {
                let page = responder_calls.fetch_add(1, Ordering::SeqCst);
                match page {
                    0 => ResponseTemplate::new(200).set_body_json(serde_json::json!({
                        "Parameters": [{
                            "Name": "/fjcloud/vm-shared-first.flapjack.foo/api-key",
                            "LastModifiedDate": 1784548800.0
                        }],
                        "NextToken": "page-two"
                    })),
                    1 => ResponseTemplate::new(200).set_body_json(serde_json::json!({
                        "Parameters": [{
                            "Name": "/fjcloud/vm-shared-second.flapjack.foo/api-key-previous",
                            "LastModifiedDate": 1784548800.0
                        }]
                    })),
                    unexpected => panic!("unexpected SSM page request {unexpected}"),
                }
            })
            .mount(&server)
            .await;

        let manager = SsmNodeSecretManager::new(ssm_client_for_mock_server(&server).await);
        let records = manager
            .list_node_api_keys()
            .await
            .expect("all SSM pages should be listed");

        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert_eq!(records.len(), 2);
        assert_eq!(
            records[0].path,
            "/fjcloud/vm-shared-first.flapjack.foo/api-key"
        );
        assert_eq!(records[0].node_id, "vm-shared-first.flapjack.foo");
        assert_eq!(
            records[1].path,
            "/fjcloud/vm-shared-second.flapjack.foo/api-key-previous"
        );
        assert_eq!(records[1].node_id, "vm-shared-second.flapjack.foo");
    }

    #[test]
    fn maps_parameter_not_found_get_error_to_missing_secret_error() {
        let sdk_error = SdkError::service_error(
            GetParameterError::ParameterNotFound(
                ParameterNotFound::builder()
                    .message("missing parameter")
                    .build(),
            ),
            (),
        );

        let mapped = SsmNodeSecretManager::map_get_parameter_error(
            "/fjcloud/node-abc123/api-key",
            sdk_error,
        );

        assert!(
            crate::services::flapjack_node::is_missing_node_secret_error(&mapped),
            "mapped missing-parameter errors must stay recognizable so seeded deployments can backfill the missing key"
        );
        assert!(
            matches!(mapped, NodeSecretError::Api(message) if message.contains("parameter not found")),
            "mapped missing-parameter errors should preserve an actionable missing-secret message"
        );
    }
}
