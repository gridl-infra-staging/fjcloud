use axum::extract::State;
use axum::response::IntoResponse;
use axum::Json;

use crate::auth::AuthenticatedTenant;
use crate::errors::ApiError;
use crate::state::AppState;

// ---------------------------------------------------------------------------
// Shared deployment targeting
// ---------------------------------------------------------------------------

/// Resolved migration target: the flapjack URL, node ID, and region from the
/// newest eligible deployment (i.e. the first `list_by_customer` entry that
/// has a present `flapjack_url`).
struct MigrationTarget {
    flapjack_url: String,
    node_id: String,
    region: String,
}

/// Walk the customer's non-terminated deployments (already ordered by
/// `created_at DESC` from the repository) and return the first one that has a
/// `flapjack_url`. Returns `ServiceUnavailable` if none qualifies.
async fn resolve_migration_target(
    state: &AppState,
    customer_id: uuid::Uuid,
) -> Result<MigrationTarget, ApiError> {
    let deployments = state
        .deployment_repo
        .list_by_customer(customer_id, false)
        .await?;

    deployments
        .into_iter()
        .find_map(|d| {
            d.flapjack_url.map(|url| MigrationTarget {
                flapjack_url: url,
                node_id: d.node_id,
                region: d.region,
            })
        })
        .ok_or_else(|| {
            ApiError::ServiceUnavailable(
                "migration requires an active deployment with a ready search endpoint".into(),
            )
        })
}

// ---------------------------------------------------------------------------
// Validation helpers
// ---------------------------------------------------------------------------

/// Validate that the body is a JSON object containing string `appId` and `apiKey`.
fn validate_algolia_credentials(body: &serde_json::Value) -> Result<(), ApiError> {
    if !body.is_object() {
        return Err(ApiError::BadRequest(
            "request body must be a JSON object".into(),
        ));
    }
    if !body.get("appId").is_some_and(|v| v.is_string()) {
        return Err(ApiError::BadRequest("appId must be a string".into()));
    }
    if !body.get("apiKey").is_some_and(|v| v.is_string()) {
        return Err(ApiError::BadRequest("apiKey must be a string".into()));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// POST /migration/algolia/list-indexes — list indexes from the customer's
/// Algolia account via the flapjack engine.
#[utoipa::path(
    post,
    path = "/migration/algolia/list-indexes",
    tag = "Migration",
    request_body = serde_json::Value,
    responses(
        (status = 200, description = "List of Algolia indexes", body = serde_json::Value),
        (status = 400, description = "Bad request", body = crate::errors::ErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 503, description = "Migration target unavailable", body = crate::errors::ErrorResponse),
    )
)]
pub async fn algolia_list_indexes(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Json(body): Json<serde_json::Value>,
) -> Result<impl IntoResponse, ApiError> {
    validate_algolia_credentials(&body)?;

    let target = resolve_migration_target(&state, auth.customer_id).await?;
    let result = state
        .flapjack_proxy
        .algolia_list_indexes(&target.flapjack_url, &target.node_id, &target.region, body)
        .await?;

    Ok(Json(result))
}

/// POST /migration/algolia/migrate — start an Algolia-to-fjcloud migration
/// via the flapjack engine.
#[utoipa::path(
    post,
    path = "/migration/algolia/migrate",
    tag = "Migration",
    request_body = serde_json::Value,
    responses(
        (status = 200, description = "Migration started", body = serde_json::Value),
        (status = 400, description = "Bad request", body = crate::errors::ErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 503, description = "Migration target unavailable", body = crate::errors::ErrorResponse),
    )
)]
pub async fn algolia_migrate(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Json(body): Json<serde_json::Value>,
) -> Result<impl IntoResponse, ApiError> {
    validate_algolia_credentials(&body)?;

    if !body.get("sourceIndex").is_some_and(|v| v.is_string()) {
        return Err(ApiError::BadRequest("sourceIndex must be a string".into()));
    }

    let target = resolve_migration_target(&state, auth.customer_id).await?;
    let result = state
        .flapjack_proxy
        .migrate_from_algolia(&target.flapjack_url, &target.node_id, &target.region, body)
        .await?;

    Ok(Json(result))
}
