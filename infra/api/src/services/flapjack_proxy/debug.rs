use super::{FlapjackProxy, ProxyError};

impl FlapjackProxy {
    /// GET /1/events/debug?index={index_name}&... — event debugger proxy.
    pub async fn get_debug_events(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
        query_params: &str,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let mut url = format!("{flapjack_url}/1/events/debug?index={index_name}");

        let extra_params = Self::normalize_forwarded_query_params(query_params);
        if !extra_params.is_empty() {
            url.push('&');
            url.push_str(extra_params);
        }

        let resp = self
            .send_authenticated_request(reqwest::Method::GET, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(&resp.body, "failed to parse debug events response")
    }
}
