use crate::errors::ApiError;
use crate::models::algolia_import_job::AlgoliaImportErrorCode;
use crate::services::flapjack_proxy::FlapjackEngineRequirements;
use crate::state::AppState;

pub(crate) async fn ensure_algolia_import_engine_compatible(
    state: &AppState,
    flapjack_url: &str,
) -> Result<(), ApiError> {
    let requirements = match FlapjackEngineRequirements::from_env() {
        Ok(requirements) => requirements,
        Err(error) => {
            tracing::warn!(
                flapjack_url,
                error = %error,
                "Algolia import admission requires complete expected Flapjack engine identity configuration"
            );
            return Err(algolia_engine_upgrade_required());
        }
    };

    let result = state
        .flapjack_proxy
        .check_engine_compatibility(flapjack_url, &requirements)
        .await;
    if result.is_match() {
        return Ok(());
    }

    tracing::warn!(
        flapjack_url,
        reason = result.reason.as_str(),
        "selected shared VM Flapjack engine is incompatible with Algolia import admission"
    );
    Err(algolia_engine_upgrade_required())
}

fn algolia_engine_upgrade_required() -> ApiError {
    ApiError::BadRequest(
        AlgoliaImportErrorCode::EngineUpgradeRequired
            .as_str()
            .into(),
    )
}
