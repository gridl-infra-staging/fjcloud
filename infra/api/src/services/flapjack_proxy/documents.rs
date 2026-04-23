use super::{FlapjackProxy, ProxyError};

impl FlapjackProxy {
    /// POST /1/indexes/{index_name}/batch — batch add/update/delete documents.
    pub async fn batch_documents(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
        body: serde_json::Value,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/indexes/{index_name}/batch");

        let resp = self
            .send_authenticated_request(reqwest::Method::POST, url, api_key, Some(body))
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(&resp.body, "failed to parse batch documents response")
    }

    /// POST /1/indexes/{index_name}/browse — browse documents with optional cursor.
    pub async fn browse_documents(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
        body: serde_json::Value,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/indexes/{index_name}/browse");

        let resp = self
            .send_authenticated_request(reqwest::Method::POST, url, api_key, Some(body))
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(&resp.body, "failed to parse browse documents response")
    }

    /// GET /1/indexes/{index_name}/{object_id} — get a single document.
    pub async fn get_document(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
        object_id: &str,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/indexes/{index_name}/{object_id}");

        let resp = self
            .send_authenticated_request(reqwest::Method::GET, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(&resp.body, "failed to parse get document response")
    }

    /// DELETE /1/indexes/{index_name}/{object_id} — delete a single document.
    pub async fn delete_document(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
        object_id: &str,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/indexes/{index_name}/{object_id}");

        let resp = self
            .send_authenticated_request(reqwest::Method::DELETE, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(&resp.body, "failed to parse delete document response")
    }
}
