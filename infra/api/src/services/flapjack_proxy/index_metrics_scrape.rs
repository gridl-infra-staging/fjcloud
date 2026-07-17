use super::{FlapjackProxy, ProxyError};

impl FlapjackProxy {
    pub async fn fetch_metrics_text(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
    ) -> Result<String, ProxyError> {
        let (body, _) = self
            .fetch_metrics_text_with_auth_observation(flapjack_url, node_id, region)
            .await?;
        Ok(body)
    }

    pub async fn fetch_metrics_text_with_auth_observation(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
    ) -> Result<(String, String), ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/metrics");

        let resp = self
            .send_authenticated_request(reqwest::Method::GET, url, api_key, None)
            .await?;

        Self::check_response_status(resp.status, &resp.body)?;
        Ok((resp.body, resp.request_api_key))
    }
}
