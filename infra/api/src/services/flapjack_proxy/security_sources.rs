use super::{FlapjackProxy, ProxyError};

impl FlapjackProxy {
    /// GET /1/security/sources
    pub async fn get_security_sources(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/security/sources");

        let resp = self
            .send_authenticated_request(reqwest::Method::GET, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(&resp.body, "failed to parse get security sources response")
    }

    /// POST /1/security/sources/append
    pub async fn append_security_source(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        source: serde_json::Value,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/security/sources/append");

        let resp = self
            .send_authenticated_request(reqwest::Method::POST, url, api_key, Some(source))
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(
            &resp.body,
            "failed to parse append security source response",
        )
    }

    /// DELETE /1/security/sources/{source}
    pub async fn delete_security_source(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        source: &str,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let encoded_source = Self::encode_path_segment(source);
        let url = format!("{flapjack_url}/1/security/sources/{encoded_source}");

        let resp = self
            .send_authenticated_request(reqwest::Method::DELETE, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(
            &resp.body,
            "failed to parse delete security source response",
        )
    }
}
