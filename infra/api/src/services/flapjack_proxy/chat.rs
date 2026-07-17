use super::{FlapjackProxy, ProxyError};

impl FlapjackProxy {
    /// POST /1/indexes/{index_name}/chat
    pub async fn chat(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
        request_body: serde_json::Value,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/indexes/{index_name}/chat");

        let resp = self
            .send_authenticated_request(reqwest::Method::POST, url, api_key, Some(request_body))
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(&resp.body, "failed to parse chat response")
    }
}
