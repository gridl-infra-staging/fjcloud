//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar22_pm_2_utoipa_openapi_docs/fjcloud_dev/infra/api/src/routes/indexes/experiments.rs.
use super::*;

struct ExperimentProxyContext<'a> {
    state: &'a AppState,
    customer_id: Uuid,
    index_name: &'a str,
}

/// Resolve the flapjack target and forward an experiment API request.
///
/// Rejects cold/restoring indexes (503), then delegates to
/// `flapjack_proxy.proxy_experiment` with the given HTTP method,
/// path suffix, optional body, and query parameters.
async fn proxy_experiment_endpoint(
    context: &ExperimentProxyContext<'_>,
    method: &str,
    path_suffix: &str,
    body: Option<serde_json::Value>,
    query_params: &str,
) -> Result<serde_json::Value, ApiError> {
    let (_, target) = super::resolve_ready_index_target(
        context.state,
        context.customer_id,
        context.index_name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    context
        .state
        .flapjack_proxy
        .proxy_experiment(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            method,
            path_suffix,
            body,
            query_params,
        )
        .await
        .map_err(ApiError::from)
}

fn build_experiments_list_query(index_name: &str, raw_query: Option<&str>) -> String {
    let mut params = parse_query_pairs(raw_query);
    params.retain(|(key, _)| key != "indexPrefix");
    params.insert(0, ("indexPrefix".to_string(), index_name.to_string()));

    encode_query_pairs(&params)
}

/// Check whether an experiment targets the given index name.
///
/// Returns `true` if the experiment's top-level `index` field matches
/// or any entry in the `variants` array has an `index` field matching
/// the given name.
fn experiment_targets_index(experiment: &serde_json::Value, index_name: &str) -> bool {
    if experiment
        .get("index")
        .and_then(|v| v.as_str())
        .is_some_and(|value| value == index_name)
    {
        return true;
    }

    experiment
        .get("variants")
        .and_then(|v| v.as_array())
        .is_some_and(|variants| {
            variants.iter().any(|variant| {
                variant
                    .get("index")
                    .and_then(|v| v.as_str())
                    .is_some_and(|value| value == index_name)
            })
        })
}

/// GET /indexes/:name/experiments — list experiments for index.
#[utoipa::path(
    get,
    path = "/indexes/{name}/experiments",
    tag = "Experiments",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "List of experiments", body = serde_json::Value),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = crate::errors::ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = crate::errors::ErrorResponse),
        (status = 404, description = "Index not found", body = crate::errors::ErrorResponse),
    )
)]
pub async fn list_experiments(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    RawQuery(raw_query): RawQuery,
) -> Result<impl IntoResponse, ApiError> {
    let context = ExperimentProxyContext {
        state: &state,
        customer_id: auth.customer_id,
        index_name: &name,
    };
    let query_params = build_experiments_list_query(&name, raw_query.as_deref());
    let mut filtered = proxy_experiment_endpoint(&context, "GET", "", None, &query_params).await?;

    if let Some(obj) = filtered.as_object_mut() {
        if let Some(abtests) = obj.get_mut("abtests").and_then(|v| v.as_array_mut()) {
            abtests.retain(|experiment| experiment_targets_index(experiment, &name));
            let filtered_count = abtests.len() as u64;
            obj.insert("count".to_string(), serde_json::json!(filtered_count));
            obj.insert("total".to_string(), serde_json::json!(filtered_count));
        }
    }

    Ok(Json(filtered))
}

/// POST /indexes/:name/experiments — create experiment.
#[utoipa::path(
    post,
    path = "/indexes/{name}/experiments",
    tag = "Experiments",
    params(("name" = String, Path, description = "Index name")),
    request_body = serde_json::Value,
    responses(
        (status = 200, description = "Experiment created", body = serde_json::Value),
        (status = 400, description = "Bad request", body = crate::errors::ErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = crate::errors::ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = crate::errors::ErrorResponse),
        (status = 404, description = "Index not found", body = crate::errors::ErrorResponse),
    )
)]
pub async fn create_experiment(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<impl IntoResponse, ApiError> {
    let context = ExperimentProxyContext {
        state: &state,
        customer_id: auth.customer_id,
        index_name: &name,
    };
    let result = proxy_experiment_endpoint(&context, "POST", "", Some(body), "").await?;

    Ok(Json(result))
}

/// GET /indexes/:name/experiments/:id — get experiment by id.
#[utoipa::path(
    get,
    path = "/indexes/{name}/experiments/{id}",
    tag = "Experiments",
    params(
        ("name" = String, Path, description = "Index name"),
        ("id" = String, Path, description = "Experiment identifier"),
    ),
    responses(
        (status = 200, description = "Experiment details", body = serde_json::Value),
        (status = 400, description = "Bad request", body = crate::errors::ErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = crate::errors::ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = crate::errors::ErrorResponse),
        (status = 404, description = "Index or experiment not found", body = crate::errors::ErrorResponse),
    )
)]
pub async fn get_experiment(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path((name, id)): Path<(String, String)>,
) -> Result<impl IntoResponse, ApiError> {
    validate_path_segment("experiment_id", &id)?;
    let context = ExperimentProxyContext {
        state: &state,
        customer_id: auth.customer_id,
        index_name: &name,
    };
    let result = proxy_experiment_endpoint(&context, "GET", &id, None, "").await?;

    Ok(Json(result))
}

/// PUT /indexes/:name/experiments/:id — update experiment.
#[utoipa::path(
    put,
    path = "/indexes/{name}/experiments/{id}",
    tag = "Experiments",
    params(
        ("name" = String, Path, description = "Index name"),
        ("id" = String, Path, description = "Experiment identifier"),
    ),
    request_body = serde_json::Value,
    responses(
        (status = 200, description = "Experiment updated", body = serde_json::Value),
        (status = 400, description = "Bad request", body = crate::errors::ErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = crate::errors::ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = crate::errors::ErrorResponse),
        (status = 404, description = "Index or experiment not found", body = crate::errors::ErrorResponse),
    )
)]
pub async fn update_experiment(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path((name, id)): Path<(String, String)>,
    Json(body): Json<serde_json::Value>,
) -> Result<impl IntoResponse, ApiError> {
    validate_path_segment("experiment_id", &id)?;
    let context = ExperimentProxyContext {
        state: &state,
        customer_id: auth.customer_id,
        index_name: &name,
    };
    let result = proxy_experiment_endpoint(&context, "PUT", &id, Some(body), "").await?;

    Ok(Json(result))
}

/// DELETE /indexes/:name/experiments/:id — delete experiment.
#[utoipa::path(
    delete,
    path = "/indexes/{name}/experiments/{id}",
    tag = "Experiments",
    params(
        ("name" = String, Path, description = "Index name"),
        ("id" = String, Path, description = "Experiment identifier"),
    ),
    responses(
        (status = 200, description = "Experiment deleted", body = serde_json::Value),
        (status = 400, description = "Bad request", body = crate::errors::ErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = crate::errors::ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = crate::errors::ErrorResponse),
        (status = 404, description = "Index or experiment not found", body = crate::errors::ErrorResponse),
    )
)]
pub async fn delete_experiment(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path((name, id)): Path<(String, String)>,
) -> Result<impl IntoResponse, ApiError> {
    validate_path_segment("experiment_id", &id)?;
    let context = ExperimentProxyContext {
        state: &state,
        customer_id: auth.customer_id,
        index_name: &name,
    };
    let result = proxy_experiment_endpoint(&context, "DELETE", &id, None, "").await?;

    Ok(Json(result))
}

/// POST /indexes/:name/experiments/:id/start — start experiment.
#[utoipa::path(
    post,
    path = "/indexes/{name}/experiments/{id}/start",
    tag = "Experiments",
    params(
        ("name" = String, Path, description = "Index name"),
        ("id" = String, Path, description = "Experiment identifier"),
    ),
    responses(
        (status = 200, description = "Experiment started", body = serde_json::Value),
        (status = 400, description = "Bad request", body = crate::errors::ErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = crate::errors::ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = crate::errors::ErrorResponse),
        (status = 404, description = "Index or experiment not found", body = crate::errors::ErrorResponse),
    )
)]
pub async fn start_experiment(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path((name, id)): Path<(String, String)>,
) -> Result<impl IntoResponse, ApiError> {
    validate_path_segment("experiment_id", &id)?;
    let context = ExperimentProxyContext {
        state: &state,
        customer_id: auth.customer_id,
        index_name: &name,
    };
    let result =
        proxy_experiment_endpoint(&context, "POST", &format!("{id}/start"), None, "").await?;

    Ok(Json(result))
}

/// POST /indexes/:name/experiments/:id/stop — stop experiment.
#[utoipa::path(
    post,
    path = "/indexes/{name}/experiments/{id}/stop",
    tag = "Experiments",
    params(
        ("name" = String, Path, description = "Index name"),
        ("id" = String, Path, description = "Experiment identifier"),
    ),
    responses(
        (status = 200, description = "Experiment stopped", body = serde_json::Value),
        (status = 400, description = "Bad request", body = crate::errors::ErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = crate::errors::ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = crate::errors::ErrorResponse),
        (status = 404, description = "Index or experiment not found", body = crate::errors::ErrorResponse),
    )
)]
pub async fn stop_experiment(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path((name, id)): Path<(String, String)>,
) -> Result<impl IntoResponse, ApiError> {
    validate_path_segment("experiment_id", &id)?;
    let context = ExperimentProxyContext {
        state: &state,
        customer_id: auth.customer_id,
        index_name: &name,
    };
    let result =
        proxy_experiment_endpoint(&context, "POST", &format!("{id}/stop"), None, "").await?;

    Ok(Json(result))
}

/// POST /indexes/:name/experiments/:id/conclude — conclude experiment.
#[utoipa::path(
    post,
    path = "/indexes/{name}/experiments/{id}/conclude",
    tag = "Experiments",
    params(
        ("name" = String, Path, description = "Index name"),
        ("id" = String, Path, description = "Experiment identifier"),
    ),
    request_body = serde_json::Value,
    responses(
        (status = 200, description = "Experiment concluded", body = serde_json::Value),
        (status = 400, description = "Bad request", body = crate::errors::ErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = crate::errors::ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = crate::errors::ErrorResponse),
        (status = 404, description = "Index or experiment not found", body = crate::errors::ErrorResponse),
    )
)]
pub async fn conclude_experiment(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path((name, id)): Path<(String, String)>,
    Json(body): Json<serde_json::Value>,
) -> Result<impl IntoResponse, ApiError> {
    validate_path_segment("experiment_id", &id)?;
    let context = ExperimentProxyContext {
        state: &state,
        customer_id: auth.customer_id,
        index_name: &name,
    };
    let result =
        proxy_experiment_endpoint(&context, "POST", &format!("{id}/conclude"), Some(body), "")
            .await?;

    Ok(Json(result))
}

/// GET /indexes/:name/experiments/:id/results — experiment results.
#[utoipa::path(
    get,
    path = "/indexes/{name}/experiments/{id}/results",
    tag = "Experiments",
    params(
        ("name" = String, Path, description = "Index name"),
        ("id" = String, Path, description = "Experiment identifier"),
    ),
    responses(
        (status = 200, description = "Experiment results", body = serde_json::Value),
        (status = 400, description = "Bad request", body = crate::errors::ErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = crate::errors::ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = crate::errors::ErrorResponse),
        (status = 404, description = "Index or experiment not found", body = crate::errors::ErrorResponse),
    )
)]
pub async fn get_experiment_results(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path((name, id)): Path<(String, String)>,
) -> Result<impl IntoResponse, ApiError> {
    validate_path_segment("experiment_id", &id)?;
    let context = ExperimentProxyContext {
        state: &state,
        customer_id: auth.customer_id,
        index_name: &name,
    };
    let result =
        proxy_experiment_endpoint(&context, "GET", &format!("{id}/results"), None, "").await?;

    Ok(Json(result))
}
