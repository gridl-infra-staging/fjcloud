use super::{FlapjackProxy, ProxyError};
use uuid::Uuid;

impl FlapjackProxy {
    /// POST /1/indexes/{index_name}/query — forwards the full search body to flapjack.
    pub async fn test_search(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
        search_body: serde_json::Value,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/indexes/{index_name}/query");

        let resp = self
            .send_authenticated_request(reqwest::Method::POST, url, api_key, Some(search_body))
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(&resp.body, "failed to parse search response")
    }

    /// Record an index access event for cold-tier inactivity tracking.
    /// `index_name` is the customer-facing name (not the flapjack UID).
    pub fn record_access(&self, customer_id: Uuid, index_name: &str) {
        if let Some(access_tracker) = &self.access_tracker {
            access_tracker.record_access(customer_id, index_name);
        }
    }
}
