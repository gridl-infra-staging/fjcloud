use std::fmt;

use serde::ser::{SerializeStruct, Serializer};
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

use crate::models::algolia_import_job::AlgoliaImportDestinationKind;

use super::REDACTED_CREDENTIAL;

/// Source revision the picker pinned when the customer chose the index, carried
/// through create so admission can prove the source did not move between choice
/// and submit. A picker that never saw a determinate count pins nothing and the
/// guard stays out of the way rather than refusing on an unknown baseline.
#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreateImportJobSourceRevisionRequest {
    #[schema(format = Int64, minimum = 0)]
    pub(super) document_count: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schema(nullable = false)]
    pub(super) updated_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schema(nullable = false)]
    pub(super) revision: Option<String>,
}

#[derive(Deserialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreateAlgoliaImportJobRequest {
    pub(super) mode: AlgoliaImportDestinationKind,
    pub(super) app_id: String,
    pub(super) api_key: String,
    pub(super) source_name: String,
    #[serde(default)]
    #[schema(nullable = false)]
    pub(super) source_revision: Option<CreateImportJobSourceRevisionRequest>,
    pub(super) target: CreateAlgoliaImportJobTargetRequest,
}

impl fmt::Debug for CreateAlgoliaImportJobRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CreateAlgoliaImportJobRequest")
            .field("mode", &self.mode)
            .field("app_id", &REDACTED_CREDENTIAL)
            .field("api_key", &REDACTED_CREDENTIAL)
            .field("source_name", &REDACTED_CREDENTIAL)
            .field("source_revision", &self.source_revision)
            .field("target", &self.target)
            .finish()
    }
}

impl Serialize for CreateAlgoliaImportJobRequest {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut request = serializer.serialize_struct("CreateAlgoliaImportJobRequest", 6)?;
        request.serialize_field("mode", &self.mode)?;
        request.serialize_field("appId", REDACTED_CREDENTIAL)?;
        request.serialize_field("apiKey", REDACTED_CREDENTIAL)?;
        request.serialize_field("sourceName", REDACTED_CREDENTIAL)?;
        serialize_optional_source_revision(&mut request, &self.source_revision)?;
        request.serialize_field("target", &self.target)?;
        request.end()
    }
}

#[derive(Deserialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreateMeilisearchImportJobRequest {
    pub(super) mode: AlgoliaImportDestinationKind,
    pub(super) endpoint: String,
    pub(super) api_key: String,
    pub(super) source_index: String,
    #[serde(default)]
    #[schema(nullable = false)]
    pub(super) source_revision: Option<CreateImportJobSourceRevisionRequest>,
    pub(super) target: CreateAlgoliaImportJobTargetRequest,
}

impl fmt::Debug for CreateMeilisearchImportJobRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CreateMeilisearchImportJobRequest")
            .field("mode", &self.mode)
            .field("endpoint", &REDACTED_CREDENTIAL)
            .field("api_key", &REDACTED_CREDENTIAL)
            .field("source_index", &REDACTED_CREDENTIAL)
            .field("source_revision", &self.source_revision)
            .field("target", &self.target)
            .finish()
    }
}

impl Serialize for CreateMeilisearchImportJobRequest {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut request = serializer.serialize_struct("CreateMeilisearchImportJobRequest", 6)?;
        request.serialize_field("mode", &self.mode)?;
        request.serialize_field("endpoint", REDACTED_CREDENTIAL)?;
        request.serialize_field("apiKey", REDACTED_CREDENTIAL)?;
        request.serialize_field("sourceIndex", REDACTED_CREDENTIAL)?;
        serialize_optional_source_revision(&mut request, &self.source_revision)?;
        request.serialize_field("target", &self.target)?;
        request.end()
    }
}

#[derive(Deserialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreateTypesenseImportJobRequest {
    pub(super) mode: AlgoliaImportDestinationKind,
    pub(super) node: String,
    pub(super) api_key: String,
    pub(super) source_index: String,
    #[serde(default)]
    #[schema(nullable = false)]
    pub(super) source_revision: Option<CreateImportJobSourceRevisionRequest>,
    pub(super) target: CreateAlgoliaImportJobTargetRequest,
}

impl fmt::Debug for CreateTypesenseImportJobRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CreateTypesenseImportJobRequest")
            .field("mode", &self.mode)
            .field("node", &REDACTED_CREDENTIAL)
            .field("api_key", &REDACTED_CREDENTIAL)
            .field("source_index", &REDACTED_CREDENTIAL)
            .field("source_revision", &self.source_revision)
            .field("target", &self.target)
            .finish()
    }
}

impl Serialize for CreateTypesenseImportJobRequest {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut request = serializer.serialize_struct("CreateTypesenseImportJobRequest", 6)?;
        request.serialize_field("mode", &self.mode)?;
        request.serialize_field("node", REDACTED_CREDENTIAL)?;
        request.serialize_field("apiKey", REDACTED_CREDENTIAL)?;
        request.serialize_field("sourceIndex", REDACTED_CREDENTIAL)?;
        serialize_optional_source_revision(&mut request, &self.source_revision)?;
        request.serialize_field("target", &self.target)?;
        request.end()
    }
}

fn serialize_optional_source_revision<S: SerializeStruct>(
    request: &mut S,
    revision: &Option<CreateImportJobSourceRevisionRequest>,
) -> Result<(), S::Error> {
    match revision {
        Some(revision) => request.serialize_field("sourceRevision", revision),
        None => request.skip_field("sourceRevision"),
    }
}

#[derive(Deserialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct CreateAlgoliaImportJobTargetRequest {
    pub(super) eligibility_token: String,
}

impl fmt::Debug for CreateAlgoliaImportJobTargetRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CreateAlgoliaImportJobTargetRequest")
            .field("eligibility_token", &REDACTED_CREDENTIAL)
            .finish()
    }
}

impl Serialize for CreateAlgoliaImportJobTargetRequest {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut target = serializer.serialize_struct("CreateAlgoliaImportJobTargetRequest", 1)?;
        target.serialize_field("eligibilityToken", REDACTED_CREDENTIAL)?;
        target.end()
    }
}

/// Documentation-only union; runtime deserialization remains provider-selected in the handler.
#[derive(Serialize, ToSchema)]
#[serde(untagged)]
pub enum CreateSourceImportJobRequest {
    Algolia(CreateAlgoliaImportJobRequest),
    Meilisearch(CreateMeilisearchImportJobRequest),
    Typesense(CreateTypesenseImportJobRequest),
}
