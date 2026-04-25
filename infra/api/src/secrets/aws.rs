//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/secrets/aws.rs.
use async_trait::async_trait;
use rand::RngCore;

use super::{NodeSecretError, NodeSecretManager};
use aws_sdk_ssm::operation::get_parameter::GetParameterError;

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

    /// Deletes the SSM parameter for the node. Idempotent: treats
    /// `ParameterNotFound` as success.
    async fn delete_node_api_key(
        &self,
        node_id: &str,
        _region: &str,
    ) -> Result<(), NodeSecretError> {
        let param_name = Self::parameter_name(node_id);

        match self
            .client
            .delete_parameter()
            .name(&param_name)
            .send()
            .await
        {
            Ok(_) => Ok(()),
            // ParameterNotFound is not an error during cleanup — the param may
            // never have been created (e.g. provisioning failed before SSM write).
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use aws_sdk_ssm::error::SdkError;
    use aws_sdk_ssm::types::error::ParameterNotFound;

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
