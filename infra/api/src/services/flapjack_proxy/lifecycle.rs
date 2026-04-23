use super::{
    FlapjackApiKey, FlapjackIndexInfo, FlapjackIndexListResponse, FlapjackProxy, ProxyError,
};

impl FlapjackProxy {
    /// POST /1/indexes with {"uid": index_name}
    pub async fn create_index(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
    ) -> Result<(), ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/indexes");

        let resp = self
            .send_authenticated_request(
                reqwest::Method::POST,
                url,
                api_key,
                Some(serde_json::json!({"uid": index_name})),
            )
            .await?;

        Self::check_response_status(resp.status, &resp.body)
    }

    /// DELETE /1/indexes/{index_name}
    pub async fn delete_index(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
    ) -> Result<(), ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/indexes/{index_name}");

        let resp = self
            .send_authenticated_request(reqwest::Method::DELETE, url, api_key, None)
            .await?;

        Self::check_response_status(resp.status, &resp.body)
    }

    /// GET /1/indexes — returns list of indexes on the VM.
    /// Flapjack returns {"items": [...], "nbPages": 1}.
    pub async fn list_indexes(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
    ) -> Result<Vec<FlapjackIndexInfo>, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/indexes");

        let resp = self
            .send_authenticated_request(reqwest::Method::GET, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        let parsed: FlapjackIndexListResponse =
            Self::parse_json_response(&resp.body, "failed to parse index list")?;

        Ok(parsed.items)
    }

    /// Stats for a single index. Fetches all via list_indexes and filters by name.
    /// Acceptable for Phase 1 (small index count per VM).
    pub async fn get_index_stats(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
    ) -> Result<FlapjackIndexInfo, ProxyError> {
        let indexes = self.list_indexes(flapjack_url, node_id, region).await?;
        indexes
            .into_iter()
            .find(|idx| idx.name == index_name)
            .ok_or_else(|| ProxyError::FlapjackError {
                status: 404,
                message: format!("index '{index_name}' not found"),
            })
    }

    /// POST /1/keys — create a flapjack API key scoped to specific indexes.
    /// `acl` must contain only valid flapjack ACLs: `"search"`, `"browse"`, `"addObject"`.
    /// Returns the key value (shown once — flapjack only returns {key, createdAt}).
    pub async fn create_search_key(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        indexes: &[&str],
        acl: &[&str],
        description: &str,
    ) -> Result<FlapjackApiKey, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/keys");

        let resp = self
            .send_authenticated_request(
                reqwest::Method::POST,
                url,
                api_key,
                Some(serde_json::json!({
                    "acl": acl,
                    "indexes": indexes,
                    "description": description,
                })),
            )
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(&resp.body, "failed to parse key response")
    }
}
