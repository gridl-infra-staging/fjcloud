use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use uuid::Uuid;

use crate::repos::CatalogLifecycleTargetIdentity;

const INTENT_TARGET_IDENTITY_KEY: &str = "intent_target_identity";
const SOURCE_RESTORE_ALLOWED_KEY: &str = "source_restore_allowed";

#[derive(Debug, thiserror::Error)]
pub enum IndexMigrationMetadataError {
    #[error("missing intent target identity")]
    MissingIntentTargetIdentity,
    #[error("invalid intent target identity: {0}")]
    InvalidIntentTargetIdentity(String),
}

#[derive(Debug, Deserialize, Serialize)]
struct IntentTargetIdentityMetadata {
    deployment_id: Uuid,
    vm_id: Option<Uuid>,
    tier: String,
    cold_snapshot_id: Option<Uuid>,
    service_type: String,
}

impl From<&CatalogLifecycleTargetIdentity> for IntentTargetIdentityMetadata {
    fn from(identity: &CatalogLifecycleTargetIdentity) -> Self {
        Self {
            deployment_id: identity.deployment_id,
            vm_id: identity.vm_id,
            tier: identity.tier.clone(),
            cold_snapshot_id: identity.cold_snapshot_id,
            service_type: identity.service_type.clone(),
        }
    }
}

impl From<IntentTargetIdentityMetadata> for CatalogLifecycleTargetIdentity {
    fn from(metadata: IntentTargetIdentityMetadata) -> Self {
        Self {
            deployment_id: metadata.deployment_id,
            vm_id: metadata.vm_id,
            tier: metadata.tier,
            cold_snapshot_id: metadata.cold_snapshot_id,
            service_type: metadata.service_type,
        }
    }
}

/// A row from `index_migrations` tracking index movement across VMs.
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct IndexMigration {
    pub id: Uuid,
    pub index_name: String,
    pub customer_id: Uuid,
    pub source_vm_id: Uuid,
    pub dest_vm_id: Uuid,
    pub status: String,
    pub requested_by: String,
    pub started_at: DateTime<Utc>,
    pub completed_at: Option<DateTime<Utc>>,
    pub error: Option<String>,
    pub metadata: serde_json::Value,
}

impl IndexMigration {
    pub fn source_restore_allowed(&self) -> bool {
        self.metadata
            .get(SOURCE_RESTORE_ALLOWED_KEY)
            .and_then(Value::as_bool)
            .unwrap_or(self.status != "completed")
    }

    pub fn metadata_with_source_restore_allowed(&self, allowed: bool) -> Value {
        let mut object = self.metadata.as_object().cloned().unwrap_or_else(Map::new);
        object.insert(SOURCE_RESTORE_ALLOWED_KEY.to_string(), Value::Bool(allowed));
        Value::Object(object)
    }

    pub fn metadata_with_intent_target_identity(
        &self,
        identity: &CatalogLifecycleTargetIdentity,
    ) -> Value {
        Self::metadata_with_intent_target_identity_from(&self.metadata, identity)
    }

    pub fn metadata_with_intent_target_identity_from(
        metadata: &Value,
        identity: &CatalogLifecycleTargetIdentity,
    ) -> Value {
        let mut object = metadata.as_object().cloned().unwrap_or_else(Map::new);
        object.insert(
            INTENT_TARGET_IDENTITY_KEY.to_string(),
            serde_json::to_value(IntentTargetIdentityMetadata::from(identity))
                .expect("intent target identity should serialize"),
        );
        Value::Object(object)
    }

    pub fn intent_target_identity(
        &self,
    ) -> Result<CatalogLifecycleTargetIdentity, IndexMigrationMetadataError> {
        let value = self
            .metadata
            .get(INTENT_TARGET_IDENTITY_KEY)
            .ok_or(IndexMigrationMetadataError::MissingIntentTargetIdentity)?;
        serde_json::from_value::<IntentTargetIdentityMetadata>(value.clone())
            .map(CatalogLifecycleTargetIdentity::from)
            .map_err(|err| {
                IndexMigrationMetadataError::InvalidIntentTargetIdentity(err.to_string())
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::repos::CatalogLifecycleTargetIdentity;

    fn migration_with_metadata(metadata: Value) -> IndexMigration {
        IndexMigration {
            id: Uuid::nil(),
            index_name: "products".to_string(),
            customer_id: Uuid::from_u128(1),
            source_vm_id: Uuid::from_u128(2),
            dest_vm_id: Uuid::from_u128(3),
            status: "replicating".to_string(),
            requested_by: "test".to_string(),
            started_at: Utc::now(),
            completed_at: None,
            error: None,
            metadata,
        }
    }

    #[test]
    fn intent_target_identity_metadata_round_trips_and_preserves_existing_keys() {
        let deployment_id = Uuid::from_u128(10);
        let vm_id = Uuid::from_u128(11);
        let cold_snapshot_id = Uuid::from_u128(12);
        let migration = migration_with_metadata(serde_json::json!({
            "source_restore_allowed": false,
            "operator_note": "keep-me"
        }));
        let identity = CatalogLifecycleTargetIdentity {
            deployment_id,
            vm_id: Some(vm_id),
            tier: "migrating".to_string(),
            cold_snapshot_id: Some(cold_snapshot_id),
            service_type: "flapjack".to_string(),
        };

        let metadata = migration.metadata_with_intent_target_identity(&identity);
        let restored = migration_with_metadata(metadata)
            .intent_target_identity()
            .expect("intent target identity should decode");

        assert_eq!(restored, identity);
        assert_eq!(
            migration_with_metadata(serde_json::json!({
                "source_restore_allowed": false,
                "operator_note": "keep-me",
                "intent_target_identity": {
                    "deployment_id": deployment_id,
                    "vm_id": vm_id,
                    "tier": "migrating",
                    "cold_snapshot_id": cold_snapshot_id,
                    "service_type": "flapjack"
                }
            }))
            .metadata,
            migration_with_metadata(migration.metadata_with_intent_target_identity(&identity))
                .metadata
        );
    }
}
