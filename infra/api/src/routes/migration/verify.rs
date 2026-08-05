use std::fmt;

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::{Deserialize, Serialize, Serializer};
use std::collections::{BTreeMap, HashSet};
use utoipa::ToSchema;
use zeroize::Zeroizing;

use crate::auth::AuthenticatedTenant;
use crate::errors::{ApiError, MigrationErrorResponse};
use crate::models::algolia_import_job::SourceImportProvider;
use crate::models::AlgoliaImportErrorCode;
use crate::routes::indexes::{self, IndexNotReadyBehavior};
use crate::services::algolia_source::AlgoliaSourceQueryRequest;
use crate::services::flapjack_proxy::ProxyError;
use crate::state::AppState;
use crate::validation::{validate_length, MAX_SEARCH_QUERY_LEN};

use super::{
    map_algolia_source_error, migration_backend_unavailable, migration_error,
    migration_unavailable, validate_adapter_source_provider, MigrationSourcePath,
};

const MIN_VERIFY_RESULT_LIMIT: u32 = 1;
const MAX_VERIFY_RESULT_LIMIT: u32 = 100;
const MAX_VERIFY_QUERIES: usize = 20;

#[derive(Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub struct VerifySourceMigrationRequest {
    pub app_id: String,
    pub api_key: String,
    pub source_index: String,
    pub destination_index: String,
    #[schema(min_items = 1, max_items = 20, max_length = 512)]
    pub queries: Vec<String>,
    #[schema(minimum = 1, maximum = 100)]
    pub result_limit: u32,
}

impl Serialize for VerifySourceMigrationRequest {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct RedactedRequest<'a> {
            app_id: &'static str,
            api_key: &'static str,
            source_index: &'a str,
            destination_index: &'a str,
            queries: &'a [String],
            result_limit: u32,
        }

        RedactedRequest {
            app_id: "[REDACTED]",
            api_key: "[REDACTED]",
            source_index: &self.source_index,
            destination_index: &self.destination_index,
            queries: &self.queries,
            result_limit: self.result_limit,
        }
        .serialize(serializer)
    }
}

impl fmt::Debug for VerifySourceMigrationRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("VerifySourceMigrationRequest")
            .field("app_id", &"[REDACTED]")
            .field("api_key", &"[REDACTED]")
            .field("source_index", &self.source_index)
            .field("destination_index", &self.destination_index)
            .field("queries", &self.queries)
            .field("result_limit", &self.result_limit)
            .finish()
    }
}

#[derive(Debug, Serialize, ToSchema, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct VerifySourceMigrationResponse {
    pub source_index: String,
    pub destination_index: String,
    pub result_limit: u32,
    pub queries: Vec<VerifySourceMigrationQueryReport>,
}

#[derive(Debug, Serialize, ToSchema, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct VerifySourceMigrationQueryReport {
    pub query: String,
    pub overlap_count: usize,
    pub source_only: Vec<String>,
    pub destination_only: Vec<String>,
    pub hits: Vec<VerifySourceMigrationHitComparison>,
}

#[derive(Debug, Serialize, ToSchema, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct VerifySourceMigrationHitComparison {
    #[serde(rename = "objectID")]
    pub object_id: String,
    pub source_rank: usize,
    pub destination_rank: usize,
    pub rank_delta: i64,
}

#[derive(Debug, Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub struct VerifySourceMigrationBadRequestResponse {
    pub error: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<AlgoliaImportErrorCode>,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct VerifySourceMigrationRestoreStatusResponse {
    pub error: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub restore_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub poll_url: Option<String>,
}

#[derive(Debug, Serialize, ToSchema)]
#[serde(untagged)]
pub enum VerifySourceMigrationServiceUnavailableResponse {
    Migration(MigrationErrorResponse),
    RestoreStatus(VerifySourceMigrationRestoreStatusResponse),
}

#[utoipa::path(
    post,
    path = "/migration/{source_provider}/verify",
    operation_id = "verify_source_migration",
    tag = "Migration",
    params(
        ("source_provider" = SourceImportProvider, Path, description = "Source migration provider"),
    ),
    request_body = VerifySourceMigrationRequest,
    responses(
        (status = 200, description = "Read-only source/destination search parity report", body = VerifySourceMigrationResponse),
        (status = 400, description = "Unsupported provider, validation failure, destination not ready, duplicate IDs, or invalid source", body = VerifySourceMigrationBadRequestResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 403, description = "Source key lacks search permission", body = crate::errors::MigrationErrorResponse),
        (status = 404, description = "Destination index not owned or not found (shared search-admission body)", body = crate::errors::ErrorResponse),
        (status = 410, description = "Destination index is cold (shared search-admission restore body)", body = VerifySourceMigrationRestoreStatusResponse),
        (status = 429, description = "Rate limit or quota exceeded", body = serde_json::Value),
        (status = 503, description = "Source/destination backend unavailable, or destination restoring (shared search-admission restore body)", body = VerifySourceMigrationServiceUnavailableResponse),
    )
)]
pub async fn verify_source_migration(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(path): Path<MigrationSourcePath>,
    Json(request): Json<VerifySourceMigrationRequest>,
) -> Result<Response, ApiError> {
    let provider = validate_adapter_source_provider(path.source_provider.as_deref())?;
    if provider != SourceImportProvider::Algolia {
        let error_code = AlgoliaImportErrorCode::SourceProviderUnsupported;
        return Err(migration_error(
            StatusCode::BAD_REQUEST,
            error_code.as_str(),
            error_code,
        ));
    }
    if !state.algolia_migration_enabled {
        return Err(migration_unavailable());
    }
    validate_verify_request(&request)?;
    let target = match admit_destination_search(
        &state,
        auth.customer_id,
        &request.destination_index,
        request.queries.len() as u64,
    )
    .await?
    {
        indexes::search::SearchAdmission::ShortCircuit(response) => return Ok(response),
        indexes::search::SearchAdmission::Ready(target) => target,
    };

    let mut query_reports = Vec::with_capacity(request.queries.len());
    for (query_index, query) in request.queries.iter().enumerate() {
        if query_index > 0 {
            if let Some(throttled_response) = indexes::enforce_query_rate_limit(
                &state,
                auth.customer_id,
                &request.destination_index,
            )
            .await?
            {
                return Ok(throttled_response);
            }
        }
        let source_ids = search_source_ids(&state, &request, query).await?;
        state
            .flapjack_proxy
            .record_access(auth.customer_id, &request.destination_index);
        let destination_ids =
            search_destination_ids(&state, &target, query, request.result_limit).await?;
        let source_refs = source_ids.iter().map(String::as_str).collect::<Vec<_>>();
        let destination_refs = destination_ids
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>();
        query_reports.push(
            compare_ranked_object_ids(query, &source_refs, &destination_refs)
                .map_err(map_comparison_error)?,
        );
    }

    Ok(Json(VerifySourceMigrationResponse {
        source_index: request.source_index,
        destination_index: request.destination_index,
        result_limit: request.result_limit,
        queries: query_reports,
    })
    .into_response())
}

#[derive(Debug, PartialEq, Eq)]
pub struct VerifyComparisonError {
    message: String,
}

impl fmt::Display for VerifyComparisonError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

fn validate_verify_request(request: &VerifySourceMigrationRequest) -> Result<(), ApiError> {
    if request.queries.is_empty() || request.queries.len() > MAX_VERIFY_QUERIES {
        return Err(migration_error(
            StatusCode::BAD_REQUEST,
            "verify_queries_out_of_range",
            AlgoliaImportErrorCode::IncompatibleData,
        ));
    }
    if !(MIN_VERIFY_RESULT_LIMIT..=MAX_VERIFY_RESULT_LIMIT).contains(&request.result_limit) {
        return Err(migration_error(
            StatusCode::BAD_REQUEST,
            "verify_result_limit_out_of_range",
            AlgoliaImportErrorCode::SourceCatalogTooLarge,
        ));
    }
    for query in &request.queries {
        validate_length("query", query, MAX_SEARCH_QUERY_LEN)?;
    }
    Ok(())
}

async fn admit_destination_search(
    state: &AppState,
    customer_id: uuid::Uuid,
    destination_index: &str,
    requested_searches: u64,
) -> Result<indexes::search::SearchAdmission, ApiError> {
    indexes::search::admit_ready_search(
        state,
        customer_id,
        destination_index,
        indexes::search::SearchAdmissionOptions::batch(
            IndexNotReadyBehavior::BadRequest,
            requested_searches,
        ),
    )
    .await
}

async fn search_source_ids(
    state: &AppState,
    request: &VerifySourceMigrationRequest,
    query: &str,
) -> Result<Vec<String>, ApiError> {
    let response = state
        .algolia_source_service
        .search_index(AlgoliaSourceQueryRequest {
            app_id: request.app_id.clone(),
            // Per-query copy of the tenant's source key is scrubbed on drop.
            api_key: Zeroizing::new(request.api_key.clone()),
            source_name: request.source_index.clone(),
            query: query.to_string(),
            hits_per_page: request.result_limit,
        })
        .await
        .map_err(map_algolia_source_error)?;
    Ok(response
        .hits
        .into_iter()
        .take(request.result_limit as usize)
        .map(|hit| hit.object_id)
        .collect())
}

async fn search_destination_ids(
    state: &AppState,
    target: &indexes::ResolvedFlapjackTarget,
    query: &str,
    result_limit: u32,
) -> Result<Vec<String>, ApiError> {
    let response = state
        .flapjack_proxy
        .test_search(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
            serde_json::json!({
                "query": query,
                "hitsPerPage": result_limit,
            }),
        )
        .await
        .map_err(map_destination_proxy_error)?;
    object_ids_from_search_response(&response, result_limit)
}

fn map_destination_proxy_error(error: ProxyError) -> ApiError {
    match error {
        ProxyError::Unreachable(message) => {
            tracing::warn!("migration verify destination backend unreachable: {message}");
            migration_backend_unavailable(AlgoliaImportErrorCode::BackendUnavailable.as_str())
        }
        ProxyError::Timeout => {
            migration_backend_unavailable(AlgoliaImportErrorCode::BackendUnavailable.as_str())
        }
        other => other.into(),
    }
}

fn object_ids_from_search_response(
    response: &serde_json::Value,
    result_limit: u32,
) -> Result<Vec<String>, ApiError> {
    let hits = response
        .get("hits")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(invalid_destination_search_response)?;
    hits.iter()
        .take(result_limit as usize)
        .map(|hit| {
            hit.get("objectID")
                .and_then(serde_json::Value::as_str)
                .map(str::to_string)
                .ok_or_else(invalid_destination_search_response)
        })
        .collect()
}

fn invalid_destination_search_response() -> ApiError {
    migration_error(
        StatusCode::BAD_REQUEST,
        "invalid_destination_search_response",
        AlgoliaImportErrorCode::IncompatibleData,
    )
}

fn map_comparison_error(error: VerifyComparisonError) -> ApiError {
    migration_error(
        StatusCode::BAD_REQUEST,
        error.to_string(),
        AlgoliaImportErrorCode::IncompatibleData,
    )
}

fn compare_ranked_object_ids(
    query: &str,
    source_ids: &[&str],
    destination_ids: &[&str],
) -> Result<VerifySourceMigrationQueryReport, VerifyComparisonError> {
    let source_ranks = ranked_ids("source", source_ids)?;
    let destination_ranks = ranked_ids("destination", destination_ids)?;
    let mut source_only = Vec::new();
    let mut hits = Vec::new();

    for source_id in source_ids {
        let source_rank = source_ranks[source_id];
        match destination_ranks.get(source_id) {
            Some(destination_rank) => hits.push(VerifySourceMigrationHitComparison {
                object_id: (*source_id).to_string(),
                source_rank,
                destination_rank: *destination_rank,
                rank_delta: *destination_rank as i64 - source_rank as i64,
            }),
            None => source_only.push((*source_id).to_string()),
        }
    }

    let source_set = source_ranks.keys().copied().collect::<HashSet<_>>();
    let destination_only = destination_ids
        .iter()
        .filter(|destination_id| !source_set.contains(**destination_id))
        .map(|destination_id| (*destination_id).to_string())
        .collect::<Vec<_>>();

    Ok(VerifySourceMigrationQueryReport {
        query: query.to_string(),
        overlap_count: hits.len(),
        source_only,
        destination_only,
        hits,
    })
}

fn ranked_ids<'a>(
    side: &str,
    ids: &'a [&'a str],
) -> Result<BTreeMap<&'a str, usize>, VerifyComparisonError> {
    let mut ranks = BTreeMap::new();
    for (index, id) in ids.iter().enumerate() {
        if ranks.insert(*id, index + 1).is_some() {
            return Err(VerifyComparisonError {
                message: format!("duplicate {side} objectID '{id}'"),
            });
        }
    }
    Ok(ranks)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_debug_and_json_redact_credentials() {
        let request = VerifySourceMigrationRequest {
            app_id: "sensitive-app".to_string(),
            api_key: "sensitive-key".to_string(),
            source_index: "legacy_products".to_string(),
            destination_index: "products".to_string(),
            queries: vec!["shoe".to_string()],
            result_limit: 20,
        };

        let debug = format!("{request:?}");
        assert!(debug.contains("[REDACTED]"));
        assert!(!debug.contains("sensitive-app"));
        assert!(!debug.contains("sensitive-key"));

        let json = serde_json::to_value(&request).expect("request serializes");
        assert_eq!(json["appId"], "[REDACTED]");
        assert_eq!(json["apiKey"], "[REDACTED]");
        assert_eq!(json["sourceIndex"], "legacy_products");
        assert_eq!(json["destinationIndex"], "products");
    }

    #[test]
    fn comparison_reports_hand_calculated_overlap_and_rank_delta() {
        let report = compare_ranked_object_ids(
            "running shoes",
            &["p1", "p2", "p3", "p4"],
            &["p3", "p5", "p1", "p4"],
        )
        .expect("unique object IDs compare");

        assert_eq!(
            report,
            VerifySourceMigrationQueryReport {
                query: "running shoes".to_string(),
                overlap_count: 3,
                source_only: vec!["p2".to_string()],
                destination_only: vec!["p5".to_string()],
                hits: vec![
                    VerifySourceMigrationHitComparison {
                        object_id: "p1".to_string(),
                        source_rank: 1,
                        destination_rank: 3,
                        rank_delta: 2,
                    },
                    VerifySourceMigrationHitComparison {
                        object_id: "p3".to_string(),
                        source_rank: 3,
                        destination_rank: 1,
                        rank_delta: -2,
                    },
                    VerifySourceMigrationHitComparison {
                        object_id: "p4".to_string(),
                        source_rank: 4,
                        destination_rank: 4,
                        rank_delta: 0,
                    },
                ],
            }
        );
    }

    #[test]
    fn comparison_refuses_duplicate_source_identifier() {
        let error = compare_ranked_object_ids("boots", &["p1", "p1"], &["p1"])
            .expect_err("duplicate source objectID must be rejected");

        assert_eq!(error.to_string(), "duplicate source objectID 'p1'");
    }

    #[test]
    fn comparison_refuses_duplicate_destination_identifier() {
        let error = compare_ranked_object_ids("boots", &["p1"], &["p1", "p1"])
            .expect_err("duplicate destination objectID must be rejected");

        assert_eq!(error.to_string(), "duplicate destination objectID 'p1'");
    }
}
