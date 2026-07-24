//! Stub summary for infra/api/src/routes/indexes/algolia_import_engine.rs.
use crate::repos::AlgoliaImportJobAdmissionError;
use crate::state::AppState;

/// TODO: Document ensure_algolia_import_engine_compatible.
pub(crate) async fn ensure_algolia_import_engine_compatible(
    state: &AppState,
    flapjack_url: &str,
) -> Result<(), AlgoliaImportJobAdmissionError> {
    state
        .algolia_import_service
        .ensure_engine_compatible(flapjack_url)
        .await
        .map_err(AlgoliaImportJobAdmissionError::Refused)
}
