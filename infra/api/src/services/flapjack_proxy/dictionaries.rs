use super::{FlapjackProxy, ProxyError};

impl FlapjackProxy {
    /// GET /1/dictionaries/*/languages — list available languages and custom entry counts.
    pub async fn get_dictionary_languages(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/dictionaries/*/languages");
        let resp = self
            .send_authenticated_request(reqwest::Method::GET, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;
        Self::parse_json_response(&resp.body, "failed to parse dictionary languages response")
    }

    /// POST /1/dictionaries/{dictionary_name}/search — search entries in a dictionary.
    pub async fn search_dictionary_entries(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        dictionary_name: &str,
        body: serde_json::Value,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/dictionaries/{dictionary_name}/search");
        let resp = self
            .send_authenticated_request(reqwest::Method::POST, url, api_key, Some(body))
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;
        Self::parse_json_response(&resp.body, "failed to parse dictionary search response")
    }

    /// POST /1/dictionaries/{dictionary_name}/batch — batch add/delete dictionary entries.
    pub async fn batch_dictionary_entries(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        dictionary_name: &str,
        body: serde_json::Value,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/dictionaries/{dictionary_name}/batch");
        let resp = self
            .send_authenticated_request(reqwest::Method::POST, url, api_key, Some(body))
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;
        Self::parse_json_response(&resp.body, "failed to parse dictionary batch response")
    }

    /// GET /1/dictionaries/*/settings — get dictionary settings.
    pub async fn get_dictionary_settings(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/dictionaries/*/settings");
        let resp = self
            .send_authenticated_request(reqwest::Method::GET, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;
        Self::parse_json_response(&resp.body, "failed to parse dictionary settings response")
    }

    /// PUT /1/dictionaries/*/settings — save dictionary settings.
    pub async fn save_dictionary_settings(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        body: serde_json::Value,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/dictionaries/*/settings");
        let resp = self
            .send_authenticated_request(reqwest::Method::PUT, url, api_key, Some(body))
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;
        Self::parse_json_response(
            &resp.body,
            "failed to parse save dictionary settings response",
        )
    }
}
