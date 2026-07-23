use uuid::Uuid;

use super::{
    AlgoliaImportCreateDestination, AlgoliaImportDestination, AlgoliaImportDestinationKind,
    AlgoliaImportErrorCode, AlgoliaImportSource, NewAlgoliaImportJob, NewAlgoliaReplaceImportJob,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlgoliaImportTargetBinding {
    pub(super) customer_id: Uuid,
    pub(super) mode: AlgoliaImportDestinationKind,
    pub(super) logical_target: String,
    pub(super) region: String,
    lifecycle_generation: Option<i64>,
    routing_identity: Option<String>,
}

impl AlgoliaImportTargetBinding {
    pub fn create(
        customer_id: Uuid,
        logical_target: impl Into<String>,
        region: impl Into<String>,
    ) -> Self {
        Self {
            customer_id,
            mode: AlgoliaImportDestinationKind::Create,
            logical_target: logical_target.into(),
            region: region.into(),
            lifecycle_generation: None,
            routing_identity: None,
        }
    }

    pub fn replace(
        customer_id: Uuid,
        logical_target: impl Into<String>,
        region: impl Into<String>,
        lifecycle_generation: i64,
        routing_identity: impl Into<String>,
    ) -> Self {
        Self {
            customer_id,
            mode: AlgoliaImportDestinationKind::Replace,
            logical_target: logical_target.into(),
            region: region.into(),
            lifecycle_generation: Some(lifecycle_generation),
            routing_identity: Some(routing_identity.into()),
        }
    }

    pub fn mode(&self) -> AlgoliaImportDestinationKind {
        self.mode
    }

    pub fn customer_id(&self) -> Uuid {
        self.customer_id
    }

    pub fn logical_target(&self) -> &str {
        &self.logical_target
    }

    pub fn region(&self) -> &str {
        &self.region
    }

    fn validate(
        &self,
        customer_id: Uuid,
        destination: &AlgoliaImportDestination,
        lifecycle_generation: i64,
    ) -> Result<(), AlgoliaImportErrorCode> {
        let common_matches = self.customer_id == customer_id
            && self.mode == destination.kind()
            && self.logical_target == destination.logical_target()
            && self.region == destination.region();
        let state_matches = match self.mode {
            AlgoliaImportDestinationKind::Create => {
                self.lifecycle_generation.is_none() && self.routing_identity.is_none()
            }
            AlgoliaImportDestinationKind::Replace => {
                self.lifecycle_generation == Some(lifecycle_generation)
                    && self.routing_identity.as_deref() == destination.routing_identity()
            }
        };
        if common_matches && state_matches {
            Ok(())
        } else {
            Err(AlgoliaImportErrorCode::DestinationChanged)
        }
    }
}

impl NewAlgoliaReplaceImportJob {
    pub fn from_target_binding(
        target_binding: AlgoliaImportTargetBinding,
        source: AlgoliaImportSource,
        idempotency_key: impl Into<String>,
    ) -> Result<Self, AlgoliaImportErrorCode> {
        if target_binding.mode != AlgoliaImportDestinationKind::Replace {
            return Err(AlgoliaImportErrorCode::DestinationChanged);
        }
        Ok(Self {
            customer_id: target_binding.customer_id,
            logical_target: target_binding.logical_target.clone(),
            source,
            idempotency_key: idempotency_key.into(),
            target_binding: Some(target_binding),
        })
    }
}

impl NewAlgoliaImportJob {
    pub fn create_from_target_binding(
        target_binding: AlgoliaImportTargetBinding,
        source: AlgoliaImportSource,
        idempotency_key: impl Into<String>,
    ) -> Result<Self, AlgoliaImportErrorCode> {
        if target_binding.mode != AlgoliaImportDestinationKind::Create {
            return Err(AlgoliaImportErrorCode::DestinationChanged);
        }
        let destination = AlgoliaImportCreateDestination::new(
            target_binding.logical_target.clone(),
            target_binding.region.clone(),
        );
        Ok(Self::from_destination(
            target_binding.customer_id,
            AlgoliaImportDestination::Create(destination),
            source,
            idempotency_key,
            Some(target_binding),
        ))
    }

    pub(crate) fn validate_target_binding(
        &self,
        lifecycle_generation: i64,
    ) -> Result<(), AlgoliaImportErrorCode> {
        self.target_binding.as_ref().map_or(Ok(()), |binding| {
            binding.validate(self.customer_id, &self.destination, lifecycle_generation)
        })
    }
}
