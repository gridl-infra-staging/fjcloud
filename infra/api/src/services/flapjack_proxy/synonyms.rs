use super::{FlapjackProxy, ProxyError};

impl FlapjackProxy {
    /// POST /1/indexes/{index_name}/synonyms/search — list/search synonyms.
    #[allow(clippy::too_many_arguments)]
    pub async fn search_synonyms(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
        query: &str,
        synonym_type: Option<&str>,
        page: usize,
        hits_per_page: usize,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/indexes/{index_name}/synonyms/search");

        let mut body = serde_json::Map::new();
        body.insert("query".to_string(), serde_json::json!(query));
        if let Some(synonym_type) = synonym_type {
            body.insert("type".to_string(), serde_json::json!(synonym_type));
        }
        body.insert("page".to_string(), serde_json::json!(page));
        body.insert("hitsPerPage".to_string(), serde_json::json!(hits_per_page));

        let resp = self
            .send_authenticated_request(
                reqwest::Method::POST,
                url,
                api_key,
                Some(serde_json::Value::Object(body)),
            )
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(&resp.body, "failed to parse synonyms search response")
    }

    /// PUT /1/indexes/{index_name}/synonyms/{object_id} — save (upsert) a synonym.
    pub async fn save_synonym(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
        object_id: &str,
        synonym: serde_json::Value,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/indexes/{index_name}/synonyms/{object_id}");

        let resp = self
            .send_authenticated_request(reqwest::Method::PUT, url, api_key, Some(synonym))
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(&resp.body, "failed to parse save synonym response")
    }

    /// GET /1/indexes/{index_name}/synonyms/{object_id} — get a single synonym.
    pub async fn get_synonym(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
        object_id: &str,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/indexes/{index_name}/synonyms/{object_id}");

        let resp = self
            .send_authenticated_request(reqwest::Method::GET, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(&resp.body, "failed to parse get synonym response")
    }

    /// DELETE /1/indexes/{index_name}/synonyms/{object_id} — delete a synonym.
    pub async fn delete_synonym(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
        object_id: &str,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/indexes/{index_name}/synonyms/{object_id}");

        let resp = self
            .send_authenticated_request(reqwest::Method::DELETE, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(&resp.body, "failed to parse delete synonym response")
    }
}
