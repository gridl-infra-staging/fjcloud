//! Index search route handlers.
use super::*;

/// Enforce the monthly search quota for free-tier customers.
///
/// Returns `Ok(Some(429))` with a `quota_exceeded` body when the customer
/// has used all allowed searches this month. At ≥80 % usage, fires a
/// one-per-month warning email (and persists `quota_warning_sent_at`)
/// in a background task so the response is not delayed. Paid-plan
/// customers skip this check entirely.
async fn enforce_free_tier_search_limit(
    state: &AppState,
    customer: &crate::models::customer::Customer,
    requested_searches: u64,
) -> Result<Option<Response>, ApiError> {
    if customer.billing_plan_enum() != BillingPlan::Free {
        return Ok(None);
    }

    let now = Utc::now();
    let monthly_search_count = state
        .usage_repo
        .get_monthly_search_count(customer.id, now.year(), now.month())
        .await?;
    let max_searches_per_month = state.free_tier_limits.max_searches_per_month;
    let projected_search_count =
        monthly_search_count.saturating_add(i64::try_from(requested_searches).unwrap_or(i64::MAX));
    let warning_percent_used = if max_searches_per_month == 0 {
        100.0
    } else {
        (monthly_search_count as f64 / max_searches_per_month as f64) * 100.0
    };

    if warning_percent_used >= 80.0 {
        let warning_already_sent_this_month = customer
            .quota_warning_sent_at
            .is_some_and(|sent_at| sent_at.year() == now.year() && sent_at.month() == now.month());

        if !warning_already_sent_this_month {
            let email_service = state.email_service.clone();
            let customer_repo = state.customer_repo.clone();
            let customer_id = customer.id;
            let customer_email = customer.email.clone();
            let current_usage = monthly_search_count.max(0) as u64;

            tokio::spawn(async move {
                if let Err(e) = email_service
                    .send_quota_warning_email(
                        &customer_email,
                        "monthly_searches",
                        warning_percent_used,
                        current_usage,
                        max_searches_per_month,
                    )
                    .await
                {
                    tracing::warn!(
                        customer_id = %customer_id,
                        error = %e,
                        "failed to send quota warning email"
                    );
                    return;
                }

                if let Err(e) = customer_repo
                    .set_quota_warning_sent_at(customer_id, Utc::now())
                    .await
                {
                    tracing::warn!(
                        customer_id = %customer_id,
                        error = %e,
                        "failed to persist quota_warning_sent_at"
                    );
                }
            });
        }
    }

    let max_searches_per_month = i64::try_from(max_searches_per_month).unwrap_or(i64::MAX);
    if projected_search_count <= max_searches_per_month {
        return Ok(None);
    }

    Ok(Some(
        (
            StatusCode::TOO_MANY_REQUESTS,
            Json(serde_json::json!({
                "error": "quota_exceeded",
                "limit": "monthly_searches",
                "upgrade_url": "/billing/upgrade",
            })),
        )
            .into_response(),
    ))
}

pub(crate) async fn admit_monthly_search_allowance(
    state: &AppState,
    customer_id: Uuid,
    requested_searches: u64,
) -> Result<Option<Response>, ApiError> {
    let customer = state
        .customer_repo
        .find_by_id(customer_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("customer not found".into()))?;

    enforce_free_tier_search_limit(state, &customer, requested_searches).await
}

/// `POST /indexes/{name}/search` — execute a search query against an index.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Validates query length, rejects cold/restoring indexes, enforces the
/// free-tier monthly search cap and per-index query rate limit before
/// proxying to flapjack. Extra fields in the request body (`page`,
/// `hitsPerPage`, `facets`, etc.) are forwarded as-is; the validated
/// `query` key is inserted last so it cannot be overridden via `extra`.
/// Records an access timestamp for cold-tier inactivity tracking.
#[utoipa::path(
    post,
    path = "/indexes/{name}/search",
    tag = "Search",
    params(("name" = String, Path, description = "Index name")),
    request_body = SearchRequest,
    responses(
        (status = 200, description = "Search results (JSON from search engine)", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
        (status = 429, description = "Rate limit or quota exceeded", body = serde_json::Value),
    )
)]
pub async fn test_search(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    Json(req): Json<SearchRequest>,
) -> Result<impl IntoResponse, ApiError> {
    validate_length("query", &req.query, MAX_SEARCH_QUERY_LEN)?;

    let target = match admit_ready_search(
        &state,
        auth.customer_id,
        &name,
        SearchAdmissionOptions::single(IndexNotReadyBehavior::BadRequest),
    )
    .await?
    {
        SearchAdmission::ShortCircuit(response) => return Ok(response),
        SearchAdmission::Ready(target) => target,
    };

    // Build search body: extend extra first, then insert validated query so it can't be
    // overridden by a duplicate "query" key smuggled through the flattened extra params.
    let mut search_body = serde_json::Map::new();
    search_body.extend(req.extra);
    search_body.insert("query".to_string(), serde_json::Value::String(req.query));
    let search_body = serde_json::Value::Object(search_body);

    // Record access with the customer-facing name for cold-tier tracking,
    // then search using the tenant-scoped flapjack UID.
    state.flapjack_proxy.record_access(auth.customer_id, &name);
    let result = state
        .flapjack_proxy
        .test_search(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
            search_body,
        )
        .await?;

    Ok(Json(result).into_response())
}

/// Outcome of the shared read-search admission flow: either a ready flapjack
/// target, or a short-circuit `Response` (cold/restoring tier, free-tier quota,
/// or query rate limit) that the caller must return verbatim.
pub(crate) enum SearchAdmission {
    Ready(ResolvedFlapjackTarget),
    ShortCircuit(Response),
}

pub(super) async fn resolve_flapjack_target_from_summary(
    state: &AppState,
    summary: &CustomerTenantSummary,
) -> Result<Option<ResolvedFlapjackTarget>, ApiError> {
    let Some(vm_id) = summary.vm_id else {
        return Ok(None);
    };

    super::resolve_flapjack_target_from_parts(
        state,
        summary.customer_id,
        &summary.tenant_id,
        summary.deployment_id,
        vm_id,
    )
    .await
}

#[derive(Clone, Copy)]
pub(crate) struct SearchAdmissionOptions {
    not_ready_behavior: IndexNotReadyBehavior,
    requested_searches: u64,
}

impl SearchAdmissionOptions {
    pub(crate) fn single(not_ready_behavior: IndexNotReadyBehavior) -> Self {
        Self::batch(not_ready_behavior, 1)
    }

    pub(crate) fn batch(
        not_ready_behavior: IndexNotReadyBehavior,
        requested_searches: u64,
    ) -> Self {
        Self {
            not_ready_behavior,
            requested_searches,
        }
    }
}

/// Run the read-side admission checks that must pass before an authenticated
/// tenant's search may reach flapjack: index existence, cold/restoring tier,
/// free-tier monthly quota, and per-index query rate limit. This is the single
/// owner of that sequence, shared by the index search route and the migration
/// verify route so neither duplicates the quota/rate-limit/ready-target logic.
pub(crate) async fn admit_ready_search(
    state: &AppState,
    customer_id: Uuid,
    index_name: &str,
    options: SearchAdmissionOptions,
) -> Result<SearchAdmission, ApiError> {
    let summary = state
        .tenant_repo
        .find_by_name(customer_id, index_name)
        .await?
        .ok_or_else(|| ApiError::NotFound(format!("index '{index_name}' not found")))?;

    // Cold/restoring tiers surface their own customer-facing restore/poll bodies.
    if let Some(response) = super::lifecycle::cold_tier_response_for_tier(&summary.tier, index_name)
    {
        return Ok(SearchAdmission::ShortCircuit(response));
    }

    if let Some(limited_response) =
        admit_monthly_search_allowance(state, customer_id, options.requested_searches).await?
    {
        return Ok(SearchAdmission::ShortCircuit(limited_response));
    }

    if let Some(throttled) = super::enforce_query_rate_limit(state, customer_id, index_name).await?
    {
        return Ok(SearchAdmission::ShortCircuit(throttled));
    }

    let target = resolve_flapjack_target_from_summary(state, &summary)
        .await?
        .ok_or_else(|| options.not_ready_behavior.into_error(index_name))?;
    Ok(SearchAdmission::Ready(target))
}
