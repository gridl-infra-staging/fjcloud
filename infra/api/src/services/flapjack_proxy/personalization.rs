use super::{FlapjackProxy, ProxyError};

impl FlapjackProxy {
    /// GET /1/strategies/personalization
    pub async fn get_personalization_strategy(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/strategies/personalization");

        let resp = self
            .send_authenticated_request(reqwest::Method::GET, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(
            &resp.body,
            "failed to parse get personalization strategy response",
        )
    }

    /// POST /1/strategies/personalization
    pub async fn save_personalization_strategy(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        strategy: serde_json::Value,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/strategies/personalization");

        let resp = self
            .send_authenticated_request(reqwest::Method::POST, url, api_key, Some(strategy))
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(
            &resp.body,
            "failed to parse save personalization strategy response",
        )
    }

    /// DELETE /1/strategies/personalization
    pub async fn delete_personalization_strategy(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/strategies/personalization");

        let resp = self
            .send_authenticated_request(reqwest::Method::DELETE, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(
            &resp.body,
            "failed to parse delete personalization strategy response",
        )
    }

    /// GET /1/profiles/personalization/{user_token}
    pub async fn get_personalization_profile(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        user_token: &str,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let encoded_user_token = Self::encode_path_segment(user_token);
        let url = format!("{flapjack_url}/1/profiles/personalization/{encoded_user_token}");

        let resp = self
            .send_authenticated_request(reqwest::Method::GET, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(
            &resp.body,
            "failed to parse get personalization profile response",
        )
    }

    /// DELETE /1/profiles/{user_token}
    pub async fn delete_personalization_profile(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        user_token: &str,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let encoded_user_token = Self::encode_path_segment(user_token);
        let url = format!("{flapjack_url}/1/profiles/{encoded_user_token}");

        let resp = self
            .send_authenticated_request(reqwest::Method::DELETE, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(
            &resp.body,
            "failed to parse delete personalization profile response",
        )
    }
}
