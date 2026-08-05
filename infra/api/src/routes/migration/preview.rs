use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde::Serialize;
use utoipa::ToSchema;

use crate::auth::AuthenticatedTenant;
use crate::errors::ApiError;
use crate::models::AlgoliaImportErrorCode;
use crate::state::AppState;

use super::source::MigrationProxyOperation;
use super::{
    migration_error, migration_unavailable, require_json_content_type, validate_source_provider,
    MigrationSourcePath,
};

#[derive(Serialize, ToSchema)]
#[serde(untagged)]
pub enum MigrationPreviewRequest {
    Algolia(AlgoliaMigrationPreviewRequest),
    Meilisearch(MeilisearchMigrationPreviewRequest),
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub struct AlgoliaMigrationPreviewRequest {
    pub app_id: String,
    pub api_key: String,
    pub source_index: String,
    pub target_index: Option<String>,
    #[serde(default)]
    pub overwrite: bool,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub struct MeilisearchMigrationPreviewRequest {
    pub endpoint: String,
    pub api_key: String,
    pub source_index: String,
    pub target_index: Option<String>,
    #[serde(default)]
    pub overwrite: bool,
}

#[derive(ToSchema)]
#[schema(rename_all = "camelCase")]
pub struct MigrationPreviewResponse {
    pub report: MigrationPreviewReport,
    pub source_counts: MigrationPreviewSourceCounts,
}

#[derive(ToSchema)]
pub struct MigrationPreviewSourceCounts {
    pub indexes: usize,
    pub records: usize,
}

#[derive(ToSchema)]
#[schema(rename_all = "camelCase")]
pub struct MigrationPreviewReport {
    pub entries: Vec<MigrationPreviewReportEntry>,
    pub summary: MigrationPreviewReportSummary,
    pub report_digest: Option<String>,
}

#[derive(ToSchema)]
#[schema(rename_all = "camelCase")]
pub struct MigrationPreviewReportSummary {
    pub total_entries: usize,
    pub hard_rejections: usize,
    pub warnings: usize,
    pub scope_gaps: usize,
}

#[derive(ToSchema)]
#[schema(rename_all = "camelCase")]
pub struct MigrationPreviewReportEntry {
    pub severity: MigrationPreviewReportSeverity,
    pub code: MigrationPreviewReportCode,
    pub resource: MigrationPreviewReportResource,
    pub page_index: Option<usize>,
    pub item_index: Option<usize>,
    pub json_path: String,
}

#[derive(ToSchema)]
pub enum MigrationPreviewReportSeverity {
    ScopeGap,
    Warning,
    HardRejection,
}

#[derive(ToSchema)]
pub enum MigrationPreviewReportResource {
    Analytics,
    ApiKeys,
    Document,
    Events,
    Experiments,
    Recommend,
    Rule,
    Settings,
    Synonym,
}

#[derive(ToSchema)]
pub enum MigrationPreviewReportCode {
    ProductNotMigrated,
    PersistedNoBehaviorSetting,
    ReadOnlySourceField,
    ReplicaTopologyNotMigrated,
    UnsupportedSourceField,
    UnsupportedRuleSchema,
    UnsupportedSynonymSchema,
    InvalidObjectId,
    DuplicateObjectId,
    MalformedSettingsPayload,
    MalformedDocumentPayload,
    MalformedRulePayload,
    MalformedSynonymPayload,
    ReplicaUnknownRankingToken,
    ReplicaExhaustiveSortApproximated,
    ReplicaPrimaryRelevancyStrictnessDropped,
    ReplicaRelevancyStrictnessSemanticMismatch,
    ReplicaMatchingCriticalFieldDiverges,
    MeilisearchDocumentOrderNotContractual,
    MeilisearchSearchPaginationNotExportBound,
    MeilisearchSettingNotMigrated,
    MeilisearchSettingValueNormalized,
    TypesenseSettingNotMigrated,
}

/// Report-only migration preview. This forwards source credentials to the
/// engine preview path, but unlike create/import it never transitions a job and
/// never writes `algolia_import_jobs`.
#[utoipa::path(
    post,
    path = "/migration/{source_provider}/preview",
    operation_id = "preview_source_migration",
    tag = "Migration",
    params(
        ("source_provider" = crate::models::algolia_import_job::SourceImportProvider, Path, description = "Migration source provider", example = "algolia"),
    ),
    request_body = MigrationPreviewRequest,
    responses(
        (status = 200, description = "Stateless migration source counts and translation report", body = MigrationPreviewResponse),
        (status = 400, description = "Unsupported provider, invalid request, or source rejected by the migration engine", body = crate::errors::MigrationErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 415, description = "Request body must use a JSON media type", body = crate::errors::MigrationErrorResponse),
        (status = 503, description = "Migration preview unavailable", body = crate::errors::MigrationErrorResponse),
        (status = 500, description = "Migration preview failed internally", body = crate::errors::MigrationErrorResponse),
    )
)]
pub async fn preview_source_migration(
    _auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(path): Path<MigrationSourcePath>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<serde_json::Value>, ApiError> {
    let source_provider = validate_source_provider(path.source_provider.as_deref())?;
    if !state.algolia_migration_enabled {
        return Err(migration_unavailable());
    }

    // Keep media-type refusal ahead of UTF-8 decoding and engine proxying while
    // preserving the route's opaque byte pass-through for valid JSON requests.
    require_json_content_type(&headers)?;
    let body = std::str::from_utf8(&body).map_err(|_| {
        migration_error(
            StatusCode::BAD_REQUEST,
            "request body must be valid UTF-8",
            AlgoliaImportErrorCode::IncompatibleData,
        )
    })?;
    let target = MigrationProxyOperation::Preview
        .backend_target(&state)
        .await?;
    let response = state
        .flapjack_proxy
        .preview_source_migration(
            &target.flapjack_url,
            &target.node_secret_id,
            &target.region,
            source_provider,
            body,
        )
        .await
        .map_err(|error| MigrationProxyOperation::Preview.map_proxy_error(error))?;

    Ok(Json(response))
}
