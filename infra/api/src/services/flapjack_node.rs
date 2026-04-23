use crate::models::vm_inventory::VmInventory;
use crate::secrets::{NodeSecretError, NodeSecretManager};
use uuid::Uuid;

pub const FLAPJACK_AUTH_HEADER: &str = "X-Algolia-API-Key";
pub const FLAPJACK_APP_ID_HEADER: &str = "X-Algolia-Application-Id";
pub const FLAPJACK_APP_ID_VALUE: &str = "flapjack";

/// Build the flapjack-side index UID that isolates same-name indexes across
/// tenants. Format: `{customer_id_hex}_{index_name}`.
pub fn flapjack_index_uid(customer_id: Uuid, index_name: &str) -> String {
    format!("{}_{}", customer_id.as_simple(), index_name)
}

pub fn is_missing_node_secret_error(error: &NodeSecretError) -> bool {
    match error {
        NodeSecretError::Api(message) => {
            let normalized = message.to_ascii_lowercase();
            normalized.contains("no key found for node")
                || normalized.contains("parameter not found")
                || normalized.contains("parameternotfound")
        }
        NodeSecretError::NotConfigured => false,
    }
}

/// Load the admin API key for a VM, creating it when the local/dev secret
/// backend reports that no key has been primed yet.
pub async fn get_or_create_node_api_key(
    node_secret_manager: &dyn NodeSecretManager,
    vm: &VmInventory,
) -> Result<String, NodeSecretError> {
    let secret_id = vm.node_secret_id();
    match node_secret_manager
        .get_node_api_key(secret_id, &vm.region)
        .await
    {
        Ok(key) => Ok(key),
        Err(error) if is_missing_node_secret_error(&error) => {
            node_secret_manager
                .create_node_api_key(secret_id, &vm.region)
                .await
        }
        Err(error) => Err(error),
    }
}
