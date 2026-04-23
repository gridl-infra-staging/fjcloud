use super::{FlapjackProxy, ProxyError};

impl FlapjackProxy {
    /// POST /1/algolia-list-indexes — list Algolia indexes via the flapjack engine.
    /// The caller supplies Algolia credentials in `body`; this method forwards them
    /// as-is without logging or transforming the credential fields.
    pub async fn algolia_list_indexes(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        body: serde_json::Value,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/algolia-list-indexes");

        let resp = self
            .send_authenticated_request(reqwest::Method::POST, url, api_key, Some(body))
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(&resp.body, "failed to parse algolia list indexes response")
    }

    /// POST /1/migrate-from-algolia — start an Algolia migration via the flapjack engine.
    /// The caller supplies Algolia credentials and source index in `body`; this method
    /// forwards them as-is without logging or transforming the credential fields.
    pub async fn migrate_from_algolia(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        body: serde_json::Value,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/migrate-from-algolia");

        let resp = self
            .send_authenticated_request(reqwest::Method::POST, url, api_key, Some(body))
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(&resp.body, "failed to parse migrate from algolia response")
    }
}
