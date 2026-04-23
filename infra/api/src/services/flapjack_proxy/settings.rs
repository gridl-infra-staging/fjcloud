use super::{FlapjackProxy, ProxyError};

impl FlapjackProxy {
    /// GET /1/indexes/{index_name}/settings
    pub async fn get_index_settings(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/indexes/{index_name}/settings");

        let resp = self
            .send_authenticated_request(reqwest::Method::GET, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(&resp.body, "failed to parse settings response")
    }

    /// POST /1/indexes/{index_name}/settings — partial-merge update of index settings.
    pub async fn update_index_settings(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
        settings: serde_json::Value,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/indexes/{index_name}/settings");

        let resp = self
            .send_authenticated_request(reqwest::Method::POST, url, api_key, Some(settings))
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(&resp.body, "failed to parse settings update response")
    }
}
