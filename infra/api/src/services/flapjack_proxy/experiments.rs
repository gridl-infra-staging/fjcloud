use super::{FlapjackProxy, ProxyError};

impl FlapjackProxy {
    /// Generic experiments proxy for flapjack /2/abtests endpoints.
    /// Supports GET/POST/PUT/DELETE with optional path, body, and query params.
    #[allow(clippy::too_many_arguments)]
    pub async fn proxy_experiment(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        method: &str,
        path_suffix: &str,
        body: Option<serde_json::Value>,
        query_params: &str,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let request_method = match method.to_ascii_uppercase().as_str() {
            "GET" => reqwest::Method::GET,
            "POST" => reqwest::Method::POST,
            "PUT" => reqwest::Method::PUT,
            "DELETE" => reqwest::Method::DELETE,
            other => {
                return Err(ProxyError::FlapjackError {
                    status: 400,
                    message: format!("unsupported experiments method: {other}"),
                });
            }
        };

        let mut url = format!("{flapjack_url}/2/abtests");
        let trimmed_path = path_suffix.trim().trim_matches('/');
        if !trimmed_path.is_empty() {
            url.push('/');
            url.push_str(trimmed_path);
        }

        let trimmed_query = Self::normalize_forwarded_query_params(query_params);
        if !trimmed_query.is_empty() {
            url.push('?');
            url.push_str(trimmed_query);
        }

        let resp = self
            .send_authenticated_request(request_method, url, api_key, body)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(&resp.body, "failed to parse experiments response")
    }
}
