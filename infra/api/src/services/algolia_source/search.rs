use super::*;

#[derive(Clone)]
pub struct AlgoliaSourceQueryRequest {
    pub app_id: String,
    // Source credential held under zeroizing ownership, matching
    // `AlgoliaSourceInspectRequest`: verify clones this request once per query
    // and `search_index` clones it again for the failure trace, so every
    // retained copy must scrub itself on drop rather than leave the tenant's
    // Algolia key in freed heap.
    pub api_key: Zeroizing<String>,
    pub source_name: String,
    pub query: String,
    pub hits_per_page: u32,
}

impl fmt::Debug for AlgoliaSourceQueryRequest {
    // This request is logged verbatim on every source-search failure, so the
    // Debug view carries only non-identifying shape. `source_name` is redacted
    // for the same reason as `AlgoliaSourceInspectRequest`, and `query` is raw
    // end-user search text that must not reach application logs.
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AlgoliaSourceQueryRequest")
            .field("app_id", &"[REDACTED]")
            .field("api_key", &"[REDACTED]")
            .field("source_name", &"[REDACTED]")
            .field("query", &"[REDACTED]")
            .field("hits_per_page", &self.hits_per_page)
            .finish()
    }
}

#[derive(Clone)]
pub struct AlgoliaSourceQueryClientRequest {
    pub url: reqwest::Url,
    pub query: String,
    pub hits_per_page: u32,
    app_id: String,
    api_key: Zeroizing<String>,
}

#[cfg(test)]
impl AlgoliaSourceQueryClientRequest {
    pub(super) fn for_test(url: reqwest::Url, app_id: &str, api_key: &str) -> Self {
        Self {
            url,
            query: "shoe".to_string(),
            hits_per_page: 5,
            app_id: app_id.to_string(),
            api_key: Zeroizing::new(api_key.to_string()),
        }
    }
}

impl fmt::Debug for AlgoliaSourceQueryClientRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AlgoliaSourceQueryClientRequest")
            .field("url", &"[REDACTED]")
            .field("query", &self.query)
            .field("hits_per_page", &self.hits_per_page)
            .field("app_id", &"[REDACTED]")
            .field("api_key", &"[REDACTED]")
            .finish()
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, ToSchema, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AlgoliaSourceSearchResponse {
    pub hits: Vec<AlgoliaSourceSearchHit>,
}

#[derive(Debug, Clone, Deserialize, Serialize, ToSchema, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AlgoliaSourceSearchHit {
    #[serde(rename = "objectID")]
    pub object_id: String,
}

impl ReqwestAlgoliaSourceClient {
    pub(super) async fn execute_search(
        &self,
        request: AlgoliaSourceQueryClientRequest,
    ) -> Result<AlgoliaClientResponse, AlgoliaClientError> {
        let response = self
            .http
            .post(request.url)
            .header("X-Algolia-Application-Id", request.app_id)
            .header("X-Algolia-API-Key", request.api_key.as_str())
            .json(&serde_json::json!({
                "query": request.query,
                "hitsPerPage": request.hits_per_page,
            }))
            .send()
            .await
            .map_err(classify_reqwest_error)?;
        read_bounded_response(response).await
    }
}

pub(super) async fn read_bounded_response(
    mut response: reqwest::Response,
) -> Result<AlgoliaClientResponse, AlgoliaClientError> {
    if response
        .content_length()
        .is_some_and(|length| length > MAX_UPSTREAM_BODY_BYTES as u64)
    {
        return Err(AlgoliaClientError::Transport);
    }

    let status = response.status().as_u16();
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(classify_reqwest_error)? {
        if chunk.len() > MAX_UPSTREAM_BODY_BYTES.saturating_sub(body.len()) {
            return Err(AlgoliaClientError::Transport);
        }
        body.extend_from_slice(&chunk);
    }
    Ok(AlgoliaClientResponse { status, body })
}

impl AlgoliaSourceService {
    pub async fn search_index(
        &self,
        request: AlgoliaSourceQueryRequest,
    ) -> Result<AlgoliaSourceSearchResponse, AlgoliaSourceError> {
        let trace_request = request.clone();
        let operation = self.search_index_with_budget(request);
        let result = match tokio::time::timeout(HANDLER_BUDGET, operation).await {
            Ok(result) => result,
            Err(_) => Err(AlgoliaSourceError::TimedOut),
        };
        if let Err(error) = &result {
            tracing::warn!(
                request = ?trace_request,
                error = ?error,
                "Algolia source search failed"
            );
        }
        result
    }

    async fn search_index_with_budget(
        &self,
        request: AlgoliaSourceQueryRequest,
    ) -> Result<AlgoliaSourceSearchResponse, AlgoliaSourceError> {
        let base_url = algolia_list_url(&request.app_id, self.source_base_url.as_ref())?;
        if request.api_key.is_empty() {
            return Err(AlgoliaSourceError::InvalidCredentials);
        }
        if request.source_name.is_empty() {
            return Err(AlgoliaSourceError::SourceIndexNotFound);
        }
        let hits_per_page = validated_hits_per_page(Some(request.hits_per_page))?;
        let url = algolia_index_action_url(&base_url, &request.source_name, "query")?;
        let client_request = AlgoliaSourceQueryClientRequest {
            url,
            query: request.query,
            hits_per_page,
            app_id: request.app_id,
            api_key: request.api_key,
        };
        let response = self.fetch_search_with_retries(client_request).await?;
        serde_json::from_slice(&response.body)
            .map_err(|_| AlgoliaSourceError::InvalidUpstreamResponse)
    }

    async fn fetch_search_with_retries(
        &self,
        request: AlgoliaSourceQueryClientRequest,
    ) -> Result<AlgoliaClientResponse, AlgoliaSourceError> {
        for attempt in 0..MAX_RETRY_ATTEMPTS {
            let response = self
                .client
                .search_index(request.clone())
                .await
                .map_err(map_client_error)?;
            if matches!(response.status, 429 | 500..=599) && attempt + 1 < MAX_RETRY_ATTEMPTS {
                tokio::time::sleep(Duration::from_millis(50 * (attempt as u64 + 1))).await;
                continue;
            }
            return interpret_search_status(response);
        }
        Err(AlgoliaSourceError::Unavailable)
    }
}

fn interpret_search_status(
    response: AlgoliaClientResponse,
) -> Result<AlgoliaClientResponse, AlgoliaSourceError> {
    match response.status {
        200 => Ok(response),
        401 => Err(AlgoliaSourceError::InvalidCredentials),
        403 => Err(AlgoliaSourceError::SourcePermissionRequired),
        404 => Err(AlgoliaSourceError::SourceIndexNotFound),
        400 => Err(AlgoliaSourceError::InvalidApplicationId),
        429 | 500..=599 | 300..=399 => Err(AlgoliaSourceError::Unavailable),
        _ => Err(AlgoliaSourceError::InvalidUpstreamResponse),
    }
}
